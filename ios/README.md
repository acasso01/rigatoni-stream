# Ant Streams native iPhone test app

SwiftUI interface and VLCKit playback, with Live TV and Movies. This is a native app, not a Safari wrapper. It connects directly to HTTPS Xtream Codes providers and to the HTTP provider hostname explicitly configured during Mac setup. Other HTTP providers use your saved HTTPS Pi gateway. VLC receives the original media (including MKV), without the Safari-compatible rolling conversion. Source resolution is retained, including HD/4K where the source, hardware, and connection support it.

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
   Setup asks for your HTTP provider **hostname only**, copied from your saved server URL: no `http://`, port, path, username or password. This configures a single-host iOS HTTP exception in the generated app. Your hostname is saved only in ignored local build files, never committed to GitHub. Supabase and the gateway keep HTTPS. Blank keeps an existing setting; `-` removes direct HTTP access. Rerun `bash setup.sh` and rebuild to change the host.

4. Open **RigatoniStream.xcworkspace**, not the `.xcodeproj`. Select the RigatoniStream application target → Signing & Capabilities. Enable automatic signing and choose your Personal Team. Add your Apple account in Xcode Settings → Accounts if necessary. If the bundle identifier is unavailable, change it to a unique identifier under your name.
5. Connect and unlock your iPhone, trust your Mac, and select your iPhone as the run destination. Enable Developer Mode on the iPhone when prompted (Settings → Privacy & Security → Developer Mode), then restart and confirm.
6. Press Run (⌘R). If iOS asks you to trust the developer, use Settings → General → VPN & Device Management.
7. Sign in with your existing Ant Streams account. Your saved provider and gateway should populate automatically. Movies opens a featured movie and lazy category shelves with filled portrait posters. Live TV retains category browsing and pins. The Search tab searches movies and channels together, with All / Movies / Live TV filters.

With a free Personal Team, the provisioning expires after seven days. Run the project again from Xcode to renew it. A paid developer account is not required for this initial on-device test. CI builds an ad hoc signed simulator app and an unsigned physical iPhone build; neither is an installable, personally signed iPhone IPA.

## Update an existing Mac installation

Quit Xcode, then run these commands in Terminal:

```sh
cd ~/rigatoni-stream
git pull --ff-only
cd ios
export PATH="$(brew --prefix ruby)/bin:$PATH"
bundle exec ruby update_project.rb
bundle exec pod install
open RigatoniStream.xcworkspace
```

Then select your iPhone and press Run (⌘R). Keep the same signing team and bundle identifier to update the installed app. Provider settings remain in the account vault, session tokens in Keychain, and the locally configured HTTP hostname stays in ignored files. The update helper adds the native PiP bridge and background audio mode without rerunning XcodeGen or replacing signing settings. CocoaPods reapplies the iOS 17 dependency minimum required by newer Xcode versions.

## Playback and test scope

- The video uses the whole player surface. Controls overlay the picture and hide after four seconds of playback; tap the video to show them. Fit preserves the whole picture, Fill crops to cover the screen, and Zoom crops further by 1.25×. The source aspect ratio is preserved in every mode.
- Tap the video to reveal a large Play/Pause button for movies and Live TV. Live TV also has Previous/Next buttons, following the loaded channel list across catalog pages without wrapping at the ends. Changing channel stops the previous stream before starting the next.
- All categories search first tries a single full-catalog request for direct providers (32 MiB, 100,000 titles, 20-second total timeout). If unsupported or oversized, it falls back to category requests and displays partial results as they arrive. Loaded global results and the most recent category stay in memory during the session; Retry, settings changes and sign-out clear them. Gateway providers use the category fallback. No catalog or credentials are written to disk. Search is debounced by 200 ms and filtered off the main thread. The provider still must supply catalog data before complete local search; no undocumented server-side title search is assumed.
- VLC handles MKV/MP4/TS directly, with full movie seeking when the provider serves seekable content. There is no rolling Pi movie conversion.
- Settings offers a low-delay live buffer (1.5 seconds), balanced (3 seconds), or larger (6 seconds). Movies use a separate 4/8/12 second buffer. Source encoding and network delays remain outside the app's control.
- Transparent controls retain 44-point tap targets and use a UIKit tap recognizer on the video parent so VLC subviews cannot swallow tap-to-show. Controls hide after four seconds.
- The PiP button uses VLCKit's native sample-buffer Picture in Picture. It becomes available after VLC creates the video output. Leaving the foreground while playing also requests PiP. Background audio remains active when you switch apps or lock the phone; lock-screen play/pause is supported. Calls and disconnected headphones pause playback. Back closes the player and stops playback; force-quitting the app stops playback. Test PiP and background behavior on a physical iPhone.
- Pin the selected Live TV category using the pin button. Pinned categories appear first and have quick-access chips. Pins persist locally per account/provider using a hashed namespace and category IDs only; no provider credentials are written to preferences.
- AirPlay, series, My List, EPG and Apple TV are not implemented in this native build. The website retains its existing features.
- Direct HTTP access is enabled only for the locally configured provider hostname, with `NSIncludesSubdomains` disabled and no global ATS exception. Provider HTTP login and media traffic are unencrypted in transit, as approved for this test. The encrypted vault and account access always use HTTPS. Other HTTP provider hosts use the saved HTTPS gateway, requiring Tailscale. If a catalog redirects to another HTTP host, use the gateway; the app does not silently widen its HTTP exception.
- No private credentials or signing certificates are included. Do not paste provider credentials into GitHub issues or build logs.
- `Native iOS build` in GitHub Actions compiles the app and runs URL/container/gateway validation tests. Actual provider playback and login must also be checked on an iPhone.

## Dependency license

VLCKit 4.0.0a25 is pinned using VideoLAN's official podspec (source commit 2e0868f5ed40fe59cd92f377645fdcc260c6e759) and SHA-256-verified download. Version 4 is a prerelease required for native VLC PiP; recheck live/movie playback on device after upgrading. Its license is LGPL 2.1; its downloaded framework includes the license material. [VLCKit source](https://code.videolan.org/videolan/VLCKit). Review notices and LGPL distribution/relinking requirements before distributing release builds. This repository does not redistribute the binary or claim to copy Chillio's proprietary player implementation.

## Movies home and shared search

- The supplied RS artwork is the app icon. Existing Mac installs must run `bundle exec ruby update_project.rb` before `bundle exec pod install` to add the asset catalog and Discovery.swift without resetting signing.
- Movie posters fill 2:3 cards. The featured artwork uses aspect-fill with a title/Play overlay; rows show actual provider categories, with See all for complete category browsing. No invented ratings, dates, or viewing history are displayed.
- The Search tab starts loading only after two characters, with one shared full-catalog job per media type. It retains completed catalogs for this account session, debounces filtering, displays results progressively and separates movie/channel IDs. Partial catalog errors remain retryable. Settings changes and sign-out clear catalogs. Initial complete search still needs the provider's metadata.
- Category metadata is bounded to 100,000 titles across at most six cached categories; complete search is bounded to 100,000 titles per media type. Shelves retain only 20 items. Images are downsampled and cached only in memory (48 MiB / 100 images).
- A video tap reveals controls only. Play/Pause remains an explicit button action; no tap reaches VLC's internal controls.
