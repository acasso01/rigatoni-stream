# Rigatoni Stream native iPhone test app

SwiftUI interface and MobileVLCKit playback, with Live TV and Movies. This is a native app, not a Safari wrapper. It connects directly to HTTPS Xtream Codes providers. HTTP providers use your saved HTTPS Pi gateway in this first build. VLC receives the original media (including MKV), without the Safari-compatible rolling conversion. Source resolution is retained, including HD/4K where the source, hardware, and connection support it.

The app reuses your existing Supabase account and encrypted `provider-vault`. Provider credentials stay in memory and the account vault; they are never written to preferences, source control, logs, or disk caches. Account session tokens are in iOS Keychain. The optional gateway preference is saved to the same account metadata used by the website. Saving settings does not contact the provider. Browsing does.

## Install on your iPhone from your Mac

1. Install Xcode from the Mac App Store, open it once, and finish the components setup. If needed, choose Xcode in Settings → Locations → Command Line Tools.
2. Install [Homebrew](https://brew.sh) if you do not already have it. Then install build tools:
   ```sh
   brew install xcodegen ruby
   ```
   Use the Homebrew Ruby PATH shown by `brew info ruby` so `ruby -v` reports Ruby 3.x; macOS's system Ruby is too old for this setup.
3. Clone this repository into a new directory (or pull your existing clean checkout):
   ```sh
   git clone https://github.com/acasso01/rigatoni-stream.git
   cd rigatoni-stream/ios
   gem install bundler
   bash setup.sh
   ```
4. Open **RigatoniStream.xcworkspace**, not the `.xcodeproj`. Select the RigatoniStream application target → Signing & Capabilities. Enable automatic signing and choose your Personal Team. Add your Apple account in Xcode Settings → Accounts if necessary. If the bundle identifier is unavailable, change it to a unique identifier under your name.
5. Connect and unlock your iPhone, trust your Mac, and select your iPhone as the run destination. Enable Developer Mode on the iPhone when prompted (Settings → Privacy & Security → Developer Mode), then restart and confirm.
6. Press Run (⌘R). If iOS asks you to trust the developer, use Settings → General → VPN & Device Management.
7. Sign in with your existing Rigatoni account. Your saved provider and gateway should populate automatically. The app's Live TV and Movies tabs browse by category; search covers the current category.

With a free Personal Team, the provisioning expires after seven days. Run the project again from Xcode to renew it. A paid developer account is not required for this initial on-device test. CI builds unsigned simulator code only; they do not create an installable, signed iPhone IPA.

## Playback and test scope

- VLC handles MKV/MP4/TS directly, with full movie seeking when the provider serves seekable content. There is no rolling Pi movie conversion.
- Settings offers a low-delay live buffer (1.5 seconds), balanced (3 seconds), or larger (6 seconds). Movies use a separate 4/8/12 second buffer. Source encoding and network delays remain outside the app's control.
- Playback stops on closing the player; it pauses when the app leaves the foreground. Background playback, AirPlay, series, My List, EPG and Apple TV are not implemented in this first native build. The website retains its existing features.
- iOS transport security remains enabled. HTTP providers route through the saved HTTPS Tailscale gateway; Tailscale must be connected for that route. Direct HTTP access would require a separately authorized transport-security change. Account/vault access always uses HTTPS.
- No private credentials or signing certificates are included. Do not paste provider credentials into GitHub issues or build logs.
- `Native iOS build` in GitHub Actions compiles the app and runs URL/container/gateway validation tests. Actual provider playback and login must also be checked on an iPhone.

## Dependency license

MobileVLCKit 3.7.4 is downloaded by CocoaPods from VideoLAN using the checksum in the public CocoaPods spec. Its license is LGPL 2.1; its downloaded framework includes the license material. [VLCKit source](https://code.videolan.org/videolan/VLCKit). Review notices and LGPL distribution/relinking requirements before distributing release builds. This repository does not redistribute the binary or claim to copy Chillio's proprietary player implementation.
