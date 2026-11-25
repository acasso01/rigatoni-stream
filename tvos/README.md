> **Native iOS/tvOS update:** use the [standalone provider setup and installation guide](../NATIVE_STANDALONE.md). Native apps now use direct providers and local Keychain profiles; older account/gateway instructions below apply only to legacy builds.

# Ant Streams for Apple TV

Native SwiftUI interface with VLCKit playback, Live TV, Movies, search,
local provider profiles stored in Keychain. No Ant Streams account is required:
enter the IPTV server URL, username, password, and an optional name. That login
is stored in the Apple TV Keychain for this device only and is never written to
preferences, logs, or caches. Pins, favorites, history, and buffer choices stay
on this Apple TV; they do not sync from your iPhone. Optional **Sign in to
sync** in Settings still uses the encrypted provider vault. The HTTPS gateway
needs that sign-in and does not block a direct provider.

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
provider hosts work; no hostname prompt, no per-host exception, and no
Raspberry Pi gateway needed for native playback. Setup enables direct HTTP and
HTTPS connections to user-configured IPTV services. Provider credentials and
stream paths transmitted over HTTP are unencrypted; use HTTPS whenever
available. The account backend remains HTTPS and HTTPS trust remains enforced.
Do not put credentials in source files, shell commands or preferences.

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
6. On first launch the provider setup screen opens with focus on **Server URL**
   (the same focus target Settings uses). Enter the provider and start watching.
   No account is required. After a provider is saved, move to Settings and press
   right: focus still lands on **Server URL**. **Sign in to sync** is optional.
   If you are already signed in, the saved vault provider loads as before.
   You can also select or add a local provider later in Settings.

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
provider playback; those checks happen on the paired device. Shared provider
Keychain, vault, and catalog logic remains covered by the existing iOS test workflow.


TV Shows uses direct provider access and supports season/episode browsing. Live TV and Guide both open the All Channels guide with category chips, star pins, channel logos, now/next listings and a preview with sound, and Live TV keeps full-height categories with long-press pinning. With playback controls hidden, left/right switches channels; with controls visible, left/right navigates the buttons. Last watched is scoped to the signed-in account or the on-device provider; movie entries open details with Continue/Restart, and episodes restore their own playback position. History stores IDs, titles and timestamps, never credentials or artwork/stream URLs.

The Ant Streams update keeps the original bundle identifiers, session Keychain service, and signed-in preference keys so installed apps retain account settings. Provider logins entered without an account use a separate this-device Keychain item. From the repository root, run `cd ios && bundle exec ruby update_project.rb` for iPhone or `cd tvos && bundle exec ruby update_project.rb` for Apple TV so existing projects pick up `LocalProviders.swift`, then build and run the corresponding workspace.


The interface update includes Dark, iOS Light, Ghost and Nebula themes. Apple TV has a left navigation rail with Guide and Saved, plus movie/show hero banners. The guide uses provider short-EPG data with at most four concurrent requests and a bounded, account/provider-scoped memory cache; gateway/no-EPG providers retain playable Live rows. Saved favorites persist IDs and metadata only, respect hidden movie/live categories and channels, and open movie details with Continue/Restart. New source files are added to existing Xcode projects by `bundle exec ruby update_project.rb`; signing is preserved while direct HTTP IPTV access is enabled.

### Review demo mode

On a clean install, select **Explore Demo** from provider setup to browse a small local demo catalog without provider credentials. The sample film is the complete *Sintel* release from Blender Foundation, licensed CC BY 3.0; keep its ending credit roll intact. The “Demo Channel” reuses that prerecorded footage and is labeled as simulated, not a live broadcast. The stream is served from Blender's linked mirror. Demo playback is excluded from watch history and progress. License: https://durian.blender.org/about/ .

## Refresh an existing installation (0.2.3, build 5)

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
4. Settings must show **Version 0.2.3 (5)**. Live TV and Guide should show
   **All Channels**, a time bar, category chips and the preview pane.
5. Pause focus on a channel for 250 ms: VLC starts a preview with sound after buffering.
   Rapid focus moves, category changes, leaving the guide and opening playback
   cancel pending previews and stop the old stream. Click the channel for fullscreen
   playback with sound through the selected normal playback engine. Test Back,
   star pins and page/category controls too.
6. Check the Home Screen icon. If Settings confirms build 5 but the icon still
   shows cached artwork, restart Apple TV and check again. Keep the app installed
   so local profiles and preferences remain available.

Provider playback, sound, remote focus transitions and Home Screen icon caching
require verification on a paired Apple TV. Git updates do not update installed apps.

The 0.2.2 layout widens the menu and distributes its buttons through the full left
column. The guide heading and preview share one row, category chips have a bounded
height, and channel rows fill the remaining height. Previews automatically play
with sound; selecting a channel stops the preview before fullscreen playback starts.

Ghost uses #0A0A0B / #141416 surfaces and white accents. Nebula uses #060609 /
#0E0E14 surfaces with a #A78BFA to #22D3EE accent gradient. Midnight has been
removed from both native theme pickers; existing Midnight selections migrate to
Nebula without changing provider profiles or preferences unrelated to appearance.

## Direct provider playback

Apple TV shares the same provider and catalog code as iPhone. Both builds now permit user-entered HTTP IPTV hosts without a gateway. The tvOS `Info.plist` includes `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = YES`. Apple requires an explanation for this broad ATS exception at review because provider hostnames are chosen by the user and many third-party providers only offer HTTP. This exception weakens app-wide ATS enforcement; prefer HTTPS provider URLs whenever possible.

For an existing Apple TV project, pull the branch and run `cd tvos && bundle exec ruby update_project.rb` before building; increment the build number separately for TestFlight. Apple TV playback must be tested on physical hardware before release.

## Guide refresh and vertical categories

Guide now has a focusable vertical category sidebar next to the existing timeline, matching Live TV's vertical category navigation. Guide and Settings → Live TV Guide offer **Refresh EPG**, with shared progress, last fully successful manual refresh time, and error feedback. It forces fresh short-guide requests for displayed/recently requested channels without changing favorites, visibility preferences, playback, or timeline calculations. Refresh status is memory-only for the session. Direct providers are supported; the current gateway API does not expose guide data.

Check on Apple TV: navigate between the sidebar, refresh button and timeline with the Siri Remote; switch categories; play a channel; refresh with the provider online/offline; confirm hidden categories/channels and favorites are unchanged.
