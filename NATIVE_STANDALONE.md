# Ant Streams: standalone iPhone and Apple TV

Native iOS/tvOS apps connect directly to a user's authorized Xtream Codes provider or extended M3U playlist. They do not require an Ant Streams account, Supabase, a Raspberry Pi, Tailscale, or a gateway. Existing website/backend/Pi deployment files are unchanged; no running services are modified. Ant Streams supplies no channels, subscriptions or copyrighted content.

## Set up and migrate

Open **Welcome to Ant Streams** → **Add Xtream Codes Provider** or **Add M3U Playlist**. Enter a friendly name and the complete server/playlist URL. Xtream also requires the provider username and password. Authentication/playlist validation completes before saving. The library opens automatically on future launches. Use **Settings → Add, edit or switch providers** for management; up to 20 profiles are supported.

Existing cloud-vault users must enter their provider once on each device. The native app no longer contacts that vault; old cloud records and Pi services are not deleted. Provider profiles are not synced. Preserve the bundle identifier and signing team when updating to retain the device's Keychain access.

Profiles, credentials, playlist/guide URLs and the selected provider ID are stored together in Apple's Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Catalogs, artwork and playback URLs are held in memory. UserDefaults stores only display preferences, opaque profile IDs, item metadata/IDs and watch progress. Deleting a profile removes its local preferences, favorites and progress. Keychain read failures prevent overwriting the vault. Do not put provider secrets in issue reports or diagnostic screenshots.

## Transport and formats

Both generated and upgraded projects include **NSAppTransportSecurity → NSAllowsArbitraryLoads = YES**. This is necessary for arbitrary user-entered HTTP hostnames; no build-time provider hostname or private configuration is needed. Do not add `NSAllowsArbitraryLoadsForMedia`, `NSAllowsLocalNetworking`, or per-host exceptions that override the broad setting. URLs retain their HTTP/HTTPS scheme, custom port and base path. HTTPS certificate validation remains enabled. No certificate trust bypass is installed in the app.

The setup screen explains that HTTP can expose credentials and viewing activity to network observers. HTTP sources are also labelled in Settings. Redirects are supported, including HTTPS to HTTP; authorization/cookie headers are not copied across origins by the catalog transport. The provider controls URLs in its response and redirects. Use HTTPS when the provider supports it. Local-network providers may require device local-network permission.

[Apple's NSAllowsArbitraryLoads documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads) says this setting requires App Store review justification. Explain in review notes that users supply independent IPTV hosts whose domains cannot be known in advance, some supply HTTP-only catalogs, XMLTV and media, the app warns before connecting, and HTTPS trust is retained. Provide authorized test access or synthetic streams for reviewers. Approval is not guaranteed. Review VideoLAN's LGPL distribution/source obligations before distribution.

- Xtream: live and movie category indexes load automatically; large catalogs load on demand or during unified search. Seasons/episodes load when a series is opened. EPG loads for visible channels with bounded concurrency/cache.
- M3U: extended UTF-8/Latin-1 playlists, `group-title`, `tvg-id`, `tvg-logo`, relative HTTP/HTTPS links and XMLTV header URLs are supported. A custom XMLTV URL can override the header. Positive-duration/known video-container entries appear in Movies; other entries appear in Live TV. A single HLS media manifest is not a channel catalog. M3U does not define a reliable seasons/episodes hierarchy: use Xtream for TV Shows.
- XMLTV: numeric timezone offsets, bounded current/recent entries, uncompressed XML or standard HTTP compression. Entity declarations are rejected. Downloadable `.xml.gz` files without HTTP content encoding are not supported.
- Automatic playback uses AVPlayer for HLS/MP4/M4V/MOV, with VLC fallback on failure. VLC handles TS/MKV and other supported codecs. Container labels do not guarantee codec support. Settings can force VLC or Apple playback. Source quality is preserved, with no transcoding or SD downgrade. HD/4K still depends on the source, codec, network and device.
- Apple live playback retries failures twice; existing VLC Retry controls remain available. Fullscreen playback, resume and channel navigation remain. Device PiP/background behavior must be checked on hardware.

## Install this branch on your Mac

First commit or stash any local source edits. Do not discard local signing changes blindly.

```bash
cd ~/rigatoni-stream
git fetch origin
git switch standalone-providers
git pull --ff-only
export PATH="$(brew --prefix ruby)/bin:$PATH"
```

For an existing iPhone project (preserves signing):

```bash
cd ~/rigatoni-stream/ios
bundle install
bundle exec ruby update_project.rb
bundle exec pod install
open RigatoniStream.xcworkspace
```

For an existing Apple TV project:

```bash
cd ~/rigatoni-stream/tvos
bundle install
bundle exec ruby update_project.rb
bundle exec pod install
open RigatoniStreamTV.xcworkspace
```

For a first-time project, run `bash setup.sh` from `ios/` or `tvos/` instead. Run it from a full repository checkout: tvOS shares sources and `configure_http.py` with iOS. Setup no longer asks for your provider hostname.

In Xcode choose the app scheme, your signing team and the connected iPhone/paired Apple TV, then **Product → Run**. Keep Developer Mode enabled. Updating code here does not automatically update a sideloaded app: rebuild/install from your Mac. Free personal-team provisioning needs periodic reinstallation.

## Verification

CI compiles simulator and unsigned physical-device targets for both platforms. iOS runs parser, Keychain CRUD, URL preservation, privacy, guide/cache, search, playback routing and layout helper tests. A loopback-only Python fixture supplies mock Xtream/M3U/XMLTV endpoints over HTTP and HTTPS. CI generates a one-day localhost certificate and trusts it only in its disposable simulator; generated keys/media are ignored. Synthetic FFmpeg media verifies actual AVPlayer video/time progression. No real provider access is used.

Manual device acceptance still required:

1. Add HTTP and HTTPS providers, edit, switch, restart and delete; confirm credentials never need re-entry after a normal restart.
2. Check live, VOD seek/resume, episodes and guide against authorized real providers, including redirected media and encrypted HLS.
3. On Apple TV, move from sidebar to Guide chips/rows, open Search keyboard, enter text, select results, navigate Settings and provider forms, and use Menu/Back to return.
4. On iPhone, swipe movie/series category strips to both ends; check safe areas, rotation, transparent controls, PiP/background and interruption recovery.
5. Check sustained playback and 4K on target hardware. Simulator compilation/tests cannot establish remote ergonomics, codec hardware decoding or real-provider uptime.
