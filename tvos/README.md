> **Native iOS/tvOS update:** use the [standalone provider setup and installation guide](../NATIVE_STANDALONE.md). Native apps now use direct providers and local Keychain profiles; older account/gateway instructions below apply only to legacy builds.

# Ant Streams for Apple TV

Native SwiftUI interface with VLCKit playback, Live TV, Movies, search,
local category pins and your existing encrypted Supabase provider vault.
Provider and gateway settings load after signing in. Pins and buffer preferences
are local to each device; they do not sync from your iPhone.

## Prepare on your Mac

Xcode, Homebrew Ruby, Bundler and XcodeGen must be installed (same tools as iOS).

```bash
cd ~/rigatoni-stream
git pull --ff-only
export PATH="$(brew --prefix ruby)/bin:$PATH"
cd tvos
bash setup.sh
```

At the HTTP prompt, enter your provider's DNS hostname only (no `http://`, port,
username or password). This creates a provider-specific ATS exception in an
ignored local plist. HTTPS account and gateway requests remain HTTPS. Enter `-`
for gateway-only playback. HTTP providers otherwise require the HTTPS gateway;
private Tailscale gateways require Tailscale connectivity on the Apple TV.
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
6. Sign in with your Ant Streams account; saved provider and gateway settings load.

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


TV Shows uses direct provider access and supports season/episode browsing. Live TV keeps full-height categories, long-press pinning and channel logos. With playback controls hidden, left/right switches channels; with controls visible, left/right navigates the buttons. Last watched is scoped to the signed-in account and provider; movie entries open details with Continue/Restart, and episodes restore their own playback position. History stores IDs, titles and timestamps, never credentials or artwork/stream URLs.

The Ant Streams update keeps the original bundle identifiers, Keychain service and preference keys so installed apps retain settings. From the repository root, run `cd ios && bundle exec ruby update_project.rb` for iPhone or `cd tvos && bundle exec ruby update_project.rb` for Apple TV, then build and run the corresponding workspace.


The interface update includes Dark, iOS Light and Xfinity-inspired navy themes. Apple TV has a left navigation rail with Guide and Saved, plus movie/show hero banners. The guide uses provider short-EPG data with at most four concurrent requests and a bounded, account/provider-scoped memory cache; gateway/no-EPG providers retain playable Live rows. Saved favorites persist IDs and metadata only, respect hidden movie/live categories and channels, and open movie details with Continue/Restart. New source files are added to existing Xcode projects by `bundle exec ruby update_project.rb`; signing and local HTTP exceptions are preserved.
