# Rigatoni Stream for Apple TV (tvOS)

Native tvOS app for Rigatoni Stream — same account, same provider, same
encrypted vault as the iPhone build, rebuilt for the Siri Remote.

## How it is organized

This work lives on the `tvos` branch and is **additive only**: nothing under
`ios/`, and none of the web files, were modified. Everything new is in `tvos/`.

| File | What it is |
|---|---|
| `project.yml` | XcodeGen spec for the `RigatoniStreamTV` tvOS target |
| `configure_http.py` | Optional one-host ATS exception for a direct HTTP provider (streams + logo artwork); mirrors the iPhone build's script |
| `RigatoniStreamTV/TVApp.swift` | `@main` app entry; owns the shared `AppModel`; theme-aware tint + color scheme |
| `RigatoniStreamTV/TVRootView.swift` | Sign-in gate → X1-style left nav rail (Home, Guide, Live TV, Movies, TV Shows, Saved, Search, Settings) |
| `RigatoniStreamTV/TVHomeView.swift` | "Welcome back" greeting + "Last watched" rail |
| `RigatoniStreamTV/TVLastWatched.swift` | Last-watched persistence (UserDefaults, per provider host, no credentials/URLs stored) |
| `RigatoniStreamTV/TVGuideView.swift` | X1-style program guide: channels × 30-minute time slots, EPG via `get_short_epg` (direct providers), graceful LIVE fallback |
| `RigatoniStreamTV/TVLiveView.swift` | Live TV tab: full-height category sidebar + channel list, long-press pin/unpin, channel logos |
| `RigatoniStreamTV/TVShowsView.swift` | TV Shows tab: hero banner, series categories → poster grid → seasons/episodes → VLC playback |
| `RigatoniStreamTV/TVMoviesView.swift` | Movies tab (thin wrapper) |
| `RigatoniStreamTV/TVHeroBanner.swift` | Shared X1-style hero banner (Movies, TV Shows) |
| `RigatoniStreamTV/TVSavedView.swift` | Saved tab: favorited channels, movies and shows |
| `RigatoniStreamTV/TVFavorites.swift` | Favorites persistence (UserDefaults, per provider host, no credentials/URLs stored) |
| `RigatoniStreamTV/TVCatalogBrowser.swift` | Shared focus-engine catalog browser: category bar, pin/unpin, card grid, movie hero banner |
| `RigatoniStreamTV/TVSearchView.swift` | Full-catalog search with the same fast path + fallback as iOS |
| `RigatoniStreamTV/TVSettingsView.swift` | Sign-in screen + appearance (theme picker) + provider/gateway/buffer settings, sign out |
| `RigatoniStreamTV/TVPlayerView.swift` | VLC playback, Siri Remote controls, left/right channel zapping, auto-hiding overlay |
| `RigatoniStreamTV/TVTheme.swift` | Three user-selectable themes (Dark, Light, Xfinity) with full token sets; theme-driven `TVTheme` accessors |
| `RigatoniStreamTV/TVLibraryStore.swift` | tvOS catalog store mirroring the iPhone `LibraryView` data flow |
| `Podfile` / `Gemfile` | CocoaPods setup; VLCKit via the existing `ios/VLCKit.podspec` (declares a tvOS target) |
| `setup.sh` | `xcodegen generate` → optional `configure_http.py` → `pod install` → open the workspace |

### Reused from the iPhone build (by relative path, not copied)

`project.yml` compiles these straight out of `ios/RigatoniStream/`:

- **`Core.swift`** — Supabase auth, session Keychain, encrypted
  `provider-vault` calls, Xtream catalog API, gateway routing, `AppModel`.
  Untouched: the tvOS app signs in with the existing Rigatoni account and
  the saved provider / gateway / favorites sync with the iPhone build.
- **`Library.swift`** — `BoundedTransfer`, `CatalogIndex`, `CatalogLoader`,
  `CategoryPins`, `ProviderPoster`. Pins use the same `CategoryPins` key, so
  pinned categories appear on both devices.

`Player.swift` and `App.swift` are iOS-only and were **not** reused; the tvOS
player (`TVNativePlayer`) and login/settings screens are rewritten for tvOS.

## Build it on a Mac

Requirements: Xcode (Mac App Store), Homebrew, an Apple ID (free Personal
Team is enough for sideloading).

```sh
git clone https://github.com/acasso01/rigatoni-stream.git
cd rigatoni-stream
git checkout tvos
cd tvos
bash setup.sh
```

`setup.sh` runs `xcodegen generate`, installs the pinned CocoaPods, and opens
`RigatoniStreamTV.xcworkspace`. In Xcode, select the `RigatoniStreamTV`
target → Signing & Capabilities → enable automatic signing → choose your
Personal Team. If the bundle identifier is taken, make it unique under your
name.

## Sideload it to your Apple TV

1. On the Apple TV: **Settings → General → Privacy**, then press
   **Play/Pause 4 times** to reveal and enable **Developer Mode**. The TV
   restarts.
2. On the Mac: **Xcode → Window → Devices and Simulators**. The Apple TV
   appears on the same Wi-Fi network — select it and click **Pair**, then
   confirm the code on the TV.
3. In Xcode, choose the Apple TV as the run destination and press **⌘R**.
   Sign in with the existing Rigatoni account; the saved provider and
   gateway populate automatically.
4. With a free Personal Team the certificate expires after **7 days** — just
   run again from Xcode to renew. No paid developer account is needed to test.

## Using it

- **Nav rail:** Home, Guide, Live TV, Movies, TV Shows, Saved, Search,
  Settings — X1-style left rail with focus states, replacing the old top
  tab bar.
- **Themes:** Settings → Appearance → Dark, Light, or Xfinity. Dark is the
  original look (`#09090b` / `#e50914`), Light is iOS-style
  (`#F2F2F7` / white cards), Xfinity is X1-inspired deep navy (`#0B1B33`)
  with a bright blue accent (`#3B9DFF`). The choice is per-device
  (UserDefaults) and applies instantly. The Xfinity theme copies the X1
  *layout language* only — no Xfinity/Comcast logos or trademarks.
- **Guide:** channels × 30-minute time slots. Program data comes from the
  Xtream `get_short_epg` endpoint on direct providers (up to 40 channels
  per category, loaded concurrently and cached for the session). If a
  channel has no EPG it shows a LIVE block; if the provider returns no
  EPG at all — or a gateway is in use — the guide falls back to channel
  rows with LIVE badges. The grid is never empty.
- **Saved:** long-press (hold) any channel, movie or show to add it to
  Saved; long-press again (or use the Saved tab's context menu) to
  remove it.
- **Siri Remote:** move focus with swipes/clicks, press **Play/Pause** to
  toggle playback, press **Menu** to go back out of the player.
- **Live TV:** the sidebar and channel list each fill the screen
  top-to-bottom. Long-press a category row (or use the Pin button) to
  pin/unpin it — pins sync with the iPhone build. Open a channel, then use
  the **left/right arrows** to zap to the previous/next channel.
- **TV Shows:** hero banner, series categories → poster grid → pick a
  season → episode list → plays through VLC. Needs a direct provider
  connection (not available through the gateway yet).
- **Home:** "Welcome back" plus a "Last watched" rail that picks up
  channels, movies and episodes across tabs.
- **Movies:** hero banner + poster wall; the slider seeks when the
  provider serves seekable content. Controls hide after 4 seconds.
- **Search:** Live TV / Movies switch, full-catalog fast path with
  per-category fallback, same as the iPhone build.

## Channel logos (why they were blank, and the fix)

Two paths, two causes:

1. **Direct provider:** logos load straight from the provider's
   `stream_icon` URL via `ProviderPoster` (same bounded fetch as the
   iPhone build). HTTP icon URLs are blocked by tvOS unless you allow the
   one provider hostname at build time: `setup.sh` now runs
   `tvos/configure_http.py` (twin of the iPhone build's script). Blank
   keeps gateway-only.
2. **Gateway provider:** the gateway deliberately strips live channel
   icons (`stream_icon:''` in `gateway/server.mjs`, `/api/connect` —
   "Provider icons can be HTTP or carry provider credentials"), so the app
   never receives a logo URL and no client-side change can restore it.
   The follow-up (outside this branch's scope) is a gateway change:
   relay channel icons through `session.register(...)` opaque `/media`
   tickets the same way movie posters already are, e.g.
   `stream_icon: c.stream_icon ? register(new URL(c.stream_icon)) : ''`
   inside a try/catch. Logos then load over HTTPS with no provider
   credentials in any URL.

## Notes and limits

- **tvOS parity target is the iPhone v1 plus TV shows and the guide:**
  Live TV + TV Shows + Movies + pins + search + last-watched + a
  `get_short_epg`-backed program guide. AirPlay and downloads are out of
  scope here, same as on iOS.
- **No secrets in this repo.** Sign-in tokens go to the tvOS Keychain;
  provider credentials stay in memory and the encrypted account vault.
- **First-build caveat:** `Library.swift` is shared with the iPhone target
  and its iOS `LibraryView` uses `.navigationBarTitleDisplayMode`, which
  does not exist on tvOS. If Xcode flags it, wrap `LibraryView` in
  `#if !os(tvOS) … #endif` (a two-line, owner-approved edit to the iOS
  file — deliberately not made on this branch). Everything the tvOS UI
  actually uses (`BoundedTransfer`, `CatalogLoader`, `CategoryPins`,
  `ProviderPoster`) compiles for tvOS.
- tvOS builds were not compiled on Linux — a Mac with Xcode is required to
  verify the build. See the build report for what was validated.
