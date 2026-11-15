import SwiftUI
import AppKit

/// Pieces shared by the welcome (main window, nothing paired yet) and the "Pair a Phone" window.

/// The pairing QR code, dimmed with a big symbol once it has been used, has expired or failed.
struct PairingQR: View {
    let p: PairingUIState
    var size: CGFloat = 236

    var body: some View {
        let dimmed = p.phase != .waiting
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            if let img = QRCode.image(for: p.uri) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .opacity(dimmed ? 0.12 : 1)
                    .accessibilityLabel(Text("Pairing QR code"))
            }
            switch p.phase {
            case .waiting: EmptyView()
            case .success:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.octagon.fill").font(.system(size: 64)).foregroundStyle(.red)
            case .expired:
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 60)).foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.2), value: p.phase)
    }
}

/// Under the QR code while it is live, or what went wrong plus the way out.
struct PairingStatus: View {
    @ObservedObject var model: AppModel
    let p: PairingUIState

    var body: some View {
        switch p.phase {
        case .waiting:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(p.expiresAt.timeIntervalSince(ctx.date).rounded(.up)))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your phone… This QR code works for \(left / 60):\(String(format: "%02d", left % 60)) more.")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        case .success:
            EmptyView()
        case .failed, .expired:
            VStack(spacing: 6) {
                if p.phase == .expired {
                    Text("This QR code no longer works").font(.headline)
                } else {
                    Text("Pairing didn't work").font(.headline)
                }
                Text("Show a new QR code and scan it again with your phone.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Show a New QR Code") { model.beginPairing() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// "No ATA on the phone yet?": a second, clearly separate QR code that opens the place to get the Android app.
struct GetAndroidAppBox: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let img = QRCode.image(for: Links.getAndroidApp.absoluteString) {
                Image(nsImage: img)
                    .interpolation(.none).resizable().scaledToFit()
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    .frame(width: 96, height: 96)
                    .accessibilityLabel(Text("QR code to get the Android app"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("No ATA on your phone yet?").font(.headline)
                Text("Scan this with your phone's camera to get it, or open \(Self.shortAddress) on your phone.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    /// The address without "https://" so it is easy to type.
    static var shortAddress: String {
        let s = Links.getAndroidApp.absoluteString
        return s.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// After the first pairing: the result, what to do next, Open at Login (with its switch), the firewall line.
struct PairedNextSteps: View {
    @ObservedObject var model: AppModel
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Paired with “\(name)”").font(.headline)
            Text("Now, in Photos or any app on your phone, tap Share and choose “Send to Mac”. Your files arrive on this Mac.")
                .font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.openAtLoginTurnedOnForYou {
                VStack(spacing: 6) {
                    Text("ATA will now open by itself when you start your Mac, so your phone can always find it.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.userSetLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                }
            }
            if model.localNetworkQuestionComing {
                Text("If your Mac asks whether ATA may “find devices on your local network”, click “Allow” so sending works smoothly on the same Wi-Fi.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.firewallQuestionComing || model.showFirewallTip {
                Text("If your Mac asks whether ATA may accept incoming network connections, click “Allow” so your phone can deliver files.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
