import Foundation
import Darwin

public struct IfAddr: Equatable { public let name: String; public let ip: String }

/// IPv4 addresses on up, running, non-loopback interfaces, skipping tunnels/AWDL and link-local 169.254/16.
public func lanIPv4Addresses() -> [IfAddr] {
    var result: [IfAddr] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = p {
        defer { p = ifa.pointee.ifa_next }
        let flags = Int32(ifa.pointee.ifa_flags)
        guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
        let name = String(cString: ifa.pointee.ifa_name)
        if ["utun", "awdl", "llw", "ipsec", "bridge", "anpi", "ap"].contains(where: { name.hasPrefix($0) }) { continue }
        let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipString($0.pointee.sin_addr) }
        if ip.hasPrefix("169.254.") { continue }
        result.append(IfAddr(name: name, ip: ip))
    }
    return result
}

public func ipString(_ a: in_addr) -> String {
    var a = a
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}

public struct POSIXErr: Error, CustomStringConvertible {
    public let description: String
    public init(_ what: String, _ code: Int32 = errno) {
        description = "\(what): \(String(cString: strerror(code))) (errno \(code))"
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case timeout, closed, cancelled
    public var description: String {
        switch self {
        case .timeout: return "timed out"
        case .closed: return "connection closed by peer"
        case .cancelled: return "cancelled"
        }
    }
}

/// Blocking IPv4 TCP socket with poll-based timeouts. `shutdown()` may be called from any thread to wake a reader.
public final class TCPSocket {
    public let fd: Int32
    public let peer: String
    private let lock = NSLock()
    private var closed = false

    public init(fd: Int32, peer: String) {
        self.fd = fd
        self.peer = peer
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// Connects to ip:port with a timeout (used by the fake phone).
    public static func connect(ip: String, port: UInt16, timeout: TimeInterval) throws -> TCPSocket {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { throw POSIXErr("socket") }
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { Darwin.close(s); throw POSIXErr("inet_pton", EINVAL) }
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 {
            guard errno == EINPROGRESS else { let e = POSIXErr("connect"); Darwin.close(s); throw e }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(timeout * 1000))
            if pr <= 0 { Darwin.close(s); throw SocketError.timeout }
            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { Darwin.close(s); throw POSIXErr("connect", err) }
        }
        _ = fcntl(s, F_SETFL, flags)
        return TCPSocket(fd: s, peer: "\(ip):\(port)")
    }

    /// Reads exactly n bytes; `timeout` bounds the wait for each chunk (idle timeout, not total).
    public func readExact(_ n: Int, timeout: TimeInterval) throws -> Data {
        var out = Data(capacity: n)
        var buf = [UInt8](repeating: 0, count: min(max(n, 1), 256 * 1024))
        while out.count < n {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(timeout * 1000))
            if pr == 0 { throw SocketError.timeout }
            if pr < 0 { if errno == EINTR { continue }; throw POSIXErr("poll") }
            let want = min(buf.count, n - out.count)
            let r = recv(fd, &buf, want, 0)
            if r == 0 { throw SocketError.closed }
            if r < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw POSIXErr("recv") }
            out.append(contentsOf: buf[0..<r])
        }
        return out
    }

    public func writeAll(_ d: Data) throws {
        try d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let r = Darwin.send(fd, p.baseAddress! + off, p.count - off, 0)
                if r < 0 { if errno == EINTR { continue }; throw POSIXErr("send") }
                off += r
            }
        }
    }

    /// Wakes any blocked reader; idempotent.
    public func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

/// Poll-based IPv4 listener; the accept loop runs on its own thread and stops promptly on `stop()`.
public final class TCPListener {
    public private(set) var port: UInt16 = 0
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    private let name: String

    public init(name: String) { self.name = name }

    /// `loopbackOnly` binds 127.0.0.1, otherwise 0.0.0.0. Port 0 = ephemeral.
    public func start(port wanted: UInt16, loopbackOnly: Bool, onAccept: @escaping (TCPSocket) -> Void) throws {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { throw POSIXErr("socket") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = wanted.bigEndian
        addr.sin_addr.s_addr = loopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { let e = POSIXErr("bind"); Darwin.close(s); throw e }
        guard listen(s, 8) == 0 else { let e = POSIXErr("listen"); Darwin.close(s); throw e }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = UInt16(bigEndian: bound.sin_port)
        let t = Thread { [self] in acceptLoop(onAccept) }
        t.name = "ata.\(name).accept"
        t.start()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop(_ onAccept: @escaping (TCPSocket) -> Void) {
        defer { Darwin.close(fd) }
        while !isStopped {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 250)
            if pr <= 0 { continue }
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) } }
            if c < 0 { continue }
            if isStopped { Darwin.close(c); break }
            onAccept(TCPSocket(fd: c, peer: "\(ipString(from.sin_addr)):\(UInt16(bigEndian: from.sin_port))"))
        }
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }
}
