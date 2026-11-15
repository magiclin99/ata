# Third-party notices

ATA for Mac is released under the MIT License (see `LICENSE`). The app bundle also contains the following
third-party software, which keeps its own license.

## WebRTC (`ATA.app/Contents/Frameworks/WebRTC.framework`)

Google's WebRTC library (libwebrtc), milestone M157, as prebuilt by the github.com/stasel/WebRTC project
(release `157.0.0`, `WebRTC-M157.xcframework.zip`, SHA-256
`ffb1221be2138ecc6bc92300ae4f0157e18694d652db9921e4251992ea91a328`). Source: https://webrtc.googlesource.com/src.
ATA uses it unmodified, for the encrypted data channel only (no audio or video).

License (copied verbatim from the `LICENSE` file shipped in that xcframework):

```
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

WebRTC also comes with an additional patent grant from Google ("Additional IP Rights Grant (Patents)"), published at
https://webrtc.googlesource.com/src/+/refs/heads/main/PATENTS.

### Libraries compiled into WebRTC.framework

libwebrtc statically includes other open-source projects. The following were identified in the shipped binary
(by their embedded identification strings). Each is distributed under the license named here; the full texts are
at the links.

| Component | License | Upstream |
|---|---|---|
| BoringSSL | OpenSSL / SSLeay / ISC (older code), Apache-2.0 (newer code) | https://boringssl.googlesource.com/boringssl/+/HEAD/LICENSE |
| libsrtp | BSD-3-Clause (Cisco Systems, Inc.) | https://github.com/cisco/libsrtp/blob/main/LICENSE |
| Abseil (absl) | Apache-2.0 | https://github.com/abseil/abseil-cpp/blob/master/LICENSE |
| Protocol Buffers (lite) | BSD-3-Clause (Google Inc.) | https://github.com/protocolbuffers/protobuf/blob/main/LICENSE |
| libvpx | BSD-3-Clause (The WebM Project authors) | https://chromium.googlesource.com/webm/libvpx/+/HEAD/LICENSE |
| libaom | BSD-2-Clause + AOMedia Patent License 1.0 | https://aomedia.googlesource.com/aom/+/HEAD/LICENSE |
| dav1d | BSD-2-Clause (VideoLAN and dav1d authors) | https://code.videolan.org/videolan/dav1d/-/blob/master/COPYING |
| libyuv | BSD-3-Clause (The LibYuv Project Authors) | https://chromium.googlesource.com/libyuv/libyuv/+/HEAD/LICENSE |
| Opus | BSD-3-Clause (Xiph.Org Foundation and contributors) | https://opus-codec.org/license/ |

The authoritative, per-build list is generated from the WebRTC source tree with
`tools_webrtc/libs/generate_licenses.py`; if you redistribute a build made from a different WebRTC release, check
it against that output.

## Artwork

The app icon and menu bar image are ATA's own brand artwork (`Resources/brand/`, built by `scripts/make-icon.sh`).
SF Symbols appear inside the app only as interface glyphs (status, device and result icons), never as the app icon
or logo, under Apple's SF Symbols license. No other
third-party code, fonts or images are included.
