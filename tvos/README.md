> **Native iOS/tvOS update:** use the [standalone provider setup and installation guide](../NATIVE_STANDALONE.md). Native apps now use direct providers and local Keychain profiles; older account/gateway instructions below apply only to legacy builds.

# Ant Streams for Apple TV

Native SwiftUI interface with VLCKit playback, Live TV, Movies, search,
local provider profiles stored in Keychain. Pins and buffer preferences are
local to each device; they do not sync from your iPhone.

## Prepare on your Mac

Xcode, Homebrew Ruby, Bundler and XcodeGen must be installed (same tools as iOS).

```bash
cd ~/rigatoni-stream
git pull --ff-only
export PATH="$(brew --prefix ruby)/bin:$PATH"
cd tvos
bash setup.sh
```

Setup applies `NSAllowsArbitraryLoads` to the generated app so user-entered HTTP
provider hosts work; no hostname prompt and no per-host exception. HTTPS trust
remains enforced. Do not put credentials in source files, shell commands or
preferences.

Setup opens `RigatoniStreamTV.xcworkspace`, including the player dependency.
Use the workspace rather than the `.xcodeproj`.

## Pair and install

1. Connect your Mac and Apple TV to the same network.
2. On Apple TV, open **Settings > Remotes and Devices > Remote App and Devices**.
3. In Xcode, open **Device Hub** (run destination > Manage Devices, or
   Xcode > Open Developer Tool > Device Hub). Older Xcode versions use
   **Window > Devices and Simulators**. In Device Hub click **+ > Pair Nearby
   Device**, choose **Apple TV**, select the discovered TV and enter its
   on-screen verification code. Allow local network access if asked. If discovery
   fails, check that your network has IPv6 enabled as Apple requires.
4. Select the **RigatoniStreamTV** target's **Signing & Capabilities**.
   Enable automatic signing and select your Apple account / Personal Team.
   Keep the Apple TV app's bundle identifier distinct from the iPhone app.
5. Choose **RigatoniStreamTV** as the scheme and your paired Apple TV as the
   run destination. Press **Command-R** to build, install and launch.
6. Open Settings to select or add your local provider.

Apple pairing instructions:
https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub

This is a development installation, not an App Store release. A free Personal
Team has short-lived provisioning; rebuild with Xcode when it expires. Paid
Apple Developer membership enables the TestFlight/App Store distribution path.
A GitHub update alone does not update the app already installed on Apple TV.
Pull the changes, rebuild, and run again. Re-running setup regenerates the
project, so reselect your signing team afterward.

## Remote controls

- Play/Pause button toggles playback.
- Click or move the remote to reveal hidden controls.
- Back reveals controls first; Back again leaves playback.
- Previous/next buttons change live channels in the current list.
- Movies offer 10-second seek buttons when the provider stream supports seeking.

Source video resolution is preserved. HD/4K availability depends on the provider,
codec, Apple TV model and connection. No transcoding is performed.

## Verification

`.github/workflows/tvos-build.yml` compiles simulator and physical Apple TV
variants without signing. It does not install on your Apple TV or prove real
provider playback; those checks happen on the paired device. Shared vault and
catalog logic remains covered by the existing iOS test workflow.


TV Shows uses direct provider access and supports season/episode browsing. Live TV and Guide both open the All Channels guide with category chips, star pins, channel logos, now/next listings and a muted preview. With playback controls hidden, left/right switches channels; with controls visible, left/right navigates the buttons. Last watched is scoped to the signed-in account and provider; movie entries open details with Continue/Restart, and episodes restore their own playback position. History stores IDs, titles and timestamps, never credentials or artwork/stream URLs.

The Ant Streams update keeps the original bundle identifiers, Keychain service and preference keys so installed apps retain settings. From the repository root, run `cd ios && bundle exec ruby update_project.rb` for iPhone or `cd tvos && bundle exec ruby update_project.rb` for Apple TV, then build and run the corresponding workspace.


The interface update includes Dark, iOS Light and Midnight themes. Apple TV has a left navigation rail with Guide and Saved, plus movie/show hero banners. The guide uses provider short-EPG data with at most four concurrent requests and a bounded, account/provider-scoped memory cache; gateway/no-EPG providers retain playable Live rows. Saved favorites persist IDs and metadata only, respect hidden movie/live categories and channels, and open movie details with Continue/Restart. New source files are added to existing Xcode projects by `bundle exec ruby update_project.rb`; signing and local HTTP exceptions are preserved.

## Refresh an existing installation (0.2.1, build 3)

The generated Xcode project is local and ignored by Git. Matching branch HEAD
alone does not establish target membership or which app was installed. Previously
Live TV opened the older browser even when Guide opened TVGuideView. Both now
open the redesigned guide. The icon had a square badge padded inside the wide
tile; the replacement fills the rectangular canvas.

Quit Xcode, then refresh the existing project while preserving signing:

```bash
cd ~/rigatoni-stream
git switch ui-polish
git pull --ff-only origin ui-polish
export PATH="$(brew --prefix ruby)/bin:$PATH"
cd tvos
bundle install
bundle exec ruby update_project.rb
bundle exec pod install
open "$PWD/RigatoniStreamTV.xcworkspace"
```

If the project does not exist, use `bash setup.sh` instead and reselect your signing
team afterward. The updater includes every tvOS Swift source and the asset catalog,
sets AppIcon and updates the Info.plist/version without changing bundle identity.

1. Choose scheme **RigatoniStreamTV** and your paired **Living room TV**.
2. Retain the installed app's signing team and bundle identifier in Signing &
   Capabilities. The repository default is `com.acasso01.rigatonistreamtv`; keep
   any customized identifier so Xcode updates the same app and preserves data.
3. **Product > Clean Build Folder** (Shift-Command-K), then **Product > Run**
   (Command-R). Confirm Xcode launches the app on that TV.
4. Settings must show **Version 0.2.1 (3)**. Live TV and Guide should show
   **All Channels**, a time bar, category chips and the preview pane.
5. Pause focus on a channel for 250 ms: VLC starts a silent preview after buffering.
   Rapid focus moves, category changes, leaving the guide and opening playback
   cancel pending previews and stop the old stream. Click the channel for fullscreen
   playback with sound through the selected normal playback engine. Test Back,
   star pins and page/category controls too.
6. Check the Home Screen icon. If Settings confirms build 3 but the icon still
   shows cached artwork, restart Apple TV and check again. Keep the app installed
   so local profiles and preferences remain available.

Provider playback, sound, remote focus transitions and Home Screen icon caching
require verification on a paired Apple TV. Git updates do not update installed apps.
