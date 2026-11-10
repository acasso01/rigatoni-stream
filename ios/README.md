# Ant Streams native iPhone test app

SwiftUI interface and VLCKit playback, with Live TV and Movies. This is a native app, not a Safari wrapper. It connects directly to user-configured HTTPS and HTTP Xtream Codes providers, without requiring a Pi gateway. HTTP requests are unencrypted and may expose provider credentials or viewing activity to network observers. Prefer HTTPS provider URLs when available. VLC receives the original media (including MKV), without the Safari-compatible rolling conversion. Source resolution is retained, including HD/4K where the source, hardware, and connection support it.

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
   Setup generates an app that supports user-entered HTTP and HTTPS IPTV hostnames without putting provider URLs or credentials into the build. The gateway is optional. Your Supabase account URL remains HTTPS. Note that HTTP provider requests are inherently unencrypted.

4. Open **RigatoniStream.xcworkspace**, not the `.xcodeproj`. Select the RigatoniStream application target → Signing & Capabilities. Enable automatic signing and choose your Personal Team. Add your Apple account in Xcode Settings → Accounts if necessary. If the bundle identifier is unavailable, change it to a unique identifier under your name.
5. Connect and unlock your iPhone, trust your Mac, and select your iPhone as the run destination. Enable Developer Mode on the iPhone when prompted (Settings → Privacy & Security → Developer Mode), then restart and confirm.
6. Press Run (⌘R). If iOS asks you to trust the developer, use Settings → General → VPN & Device Management.
7. Sign in with your existing Ant Streams account. Your saved provider should populate automatically; the gateway preference can remain blank or unused. Movies opens a featured movie and lazy category shelves with filled portrait posters. Live TV retains category browsing and pins. The Search tab searches movies and channels together, with All / Movies / Live TV filters.

With a free Personal Team, the provisioning expires after seven days. Run the project again from Xcode to renew it. A paid developer account is not required for this initial on-device test. CI builds an ad hoc signed simulator app and an unsigned physical iPhone build; neither is an installable, personally signed iPhone IPA.

## Update an existing Mac installation

Quit Xcode, then run these commands in Terminal. This path updates an existing generated project while preserving signing and build version numbers:

```sh
cd ~/rigatoni-stream
git pull --ff-only
cd ios
export PATH="$(brew --prefix ruby)/bin:$PATH"
bundle exec ruby update_project.rb
bundle exec pod install
open RigatoniStream.xcworkspace
```

Then select your iPhone and press Run (⌘R). Keep the same signing team and bundle identifier to update the installed app. Before uploading a new App Store Connect build, manually increase the build number above the current uploaded build. Provider settings remain in the account vault and session tokens stay in Keychain. The update helper adds the native PiP bridge and background audio mode without rerunning XcodeGen or replacing signing settings. CocoaPods reapplies the iOS 17 dependency minimum required by newer Xcode versions.

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
- Direct HTTP access is enabled for user-supplied provider hosts through the app-wide `NSAllowsArbitraryLoads` ATS exception. Catalog and streaming requests may traverse unencrypted HTTP, exposing credentials and viewing activity to network observers. Prefer HTTPS providers wherever available. App account and Supabase endpoints still use HTTPS, and the native Pi gateway is optional.
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


TV Shows is available in the iPhone tab bar. Categories load separately; open a show to fetch seasons and episodes. Episodes use the native VLC player, retain original quality and support Continue/Restart with progress stored separately from movies. Series requires direct provider access (HTTP or HTTPS); the HTTPS gateway does not expose series yet. Existing installations can add the new source files with `bundle exec ruby update_project.rb` from `ios/`, then build and run the workspace.


The interface update includes Dark, iOS Light and Xfinity-inspired navy themes. Apple TV has a left navigation rail with Guide and Saved, plus movie/show hero banners. The guide uses provider short-EPG data with at most four concurrent requests and a bounded, account/provider-scoped memory cache; gateway/no-EPG providers retain playable Live rows. Saved favorites persist IDs and metadata only, respect hidden movie/live categories and channels, and open movie details with Continue/Restart. New source files are added to existing Xcode projects by `bundle exec ruby update_project.rb`; signing and new direct HTTP configuration are preserved.

### Matching the Apple TV experience

The phone uses Home, Live TV, Movies and Search in the bottom bar. More exposes
Guide, TV Shows, Saved and Settings (and every primary section). Home includes
last watched and pinned live categories; movie and show pages use full-width
hero banners. Hold a title/channel to save it, or use the bookmark action in
movie/show details. Saved and history contain only account/provider-scoped
catalog metadata, never provider passwords, poster URLs or playback URLs.
These lists are device-local, just like the Apple TV lists.

Run `bundle exec ruby update_project.rb` in `ios` after pulling this update so
existing Xcode projects include MobileExperience.swift without changing signing
or direct HTTP settings.

## HTTP IPTV compatibility and App Store review

The app enables `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = YES` for user-entered third-party HTTP IPTV servers. There is no fixed provider hostname list, and live TV, movies and series use direct provider connections through the native player. The gateway remains available for legacy/web workflows, not as a prerequisite for iOS. This setting is **app-wide**, not limited to media requests; HTTPS account and Supabase requests still use HTTPS, but ATS's extra enforcement is relaxed for the app. Do not assume HTTP provider credentials or viewing history are private from network observers. Only connect to IPTV services you are authorized to use.

Apple requires a written justification for this ATS exception during App Store review. A suitable factual explanation is: "Ant Streams is a user-configured client for third-party IPTV services. Users supply their own service address; many independently managed services do not offer HTTPS and their hostnames cannot be predetermined. Direct HTTP access is needed for compatible catalog and media endpoints. Our application authentication backend uses HTTPS. We recommend HTTPS IPTV providers whenever available."

After generating or updating the local Xcode project, verify its built `Info.plist` contains `NSAppTransportSecurity` with `NSAllowsArbitraryLoads` set to `YES`. `project.yml` changes alone do not affect an already generated Xcode project; run `bundle exec ruby update_project.rb` as documented above. Test live catalog, channel playback, movie playback, series, provider redirects and cellular networking on a physical device before TestFlight distribution. Provider behavior and App Store approval cannot be guaranteed by a configuration change alone.
