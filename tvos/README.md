# Rigatoni Stream for Apple TV (tvOS)

Native tvOS app for Rigatoni Stream — same account, same provider, same
encrypted vault as the iPhone build, rebuilt for the Siri Remote.

## How it is organized

This work lives on the `tvos` branch and is **additive only**: nothing under
`ios/`, and none of the web files, were modified. Everything new is in `tvos/`.

| File | What it is |
|---|---|
| `project.yml` | XcodeGen spec for the `RigatoniStreamTV` tvOS target |
| `RigatoniStreamTV/TVApp.swift` | `@main` app entry; owns the shared `AppModel` |
| `RigatoniStreamTV/TVRootView.swift` | Sign-in gate → top tab bar (Home, Live TV, Movies, Search, Settings) |
| `RigatoniStreamTV/TVHomeView.swift` | Quick-access rows for pinned Live TV categories |
| `RigatoniStreamTV/TVLiveView.swift` | Live TV tab (thin wrapper) |
| `RigatoniStreamTV/TVMoviesView.swift` | Movies tab (thin wrapper) |
| `RigatoniStreamTV/TVCatalogBrowser.swift` | Shared focus-engine catalog browser: category bar, pin/unpin, card grid |
| `RigatoniStreamTV/TVSearchView.swift` | Full-catalog search with the same fast path + fallback as iOS |
| `RigatoniStreamTV/TVSettingsView.swift` | Sign-in screen + provider/gateway/buffer settings, sign out |
| `RigatoniStreamTV/TVPlayerView.swift` | VLC playback, Siri Remote controls, auto-hiding overlay |
| `RigatoniStreamTV/TVTheme.swift` | Design tokens from the web app (`#09090b`, `#fafafa`, `#e50914`) |
| `RigatoniStreamTV/TVLibraryStore.swift` | tvOS catalog store mirroring the iPhone `LibraryView` data flow |
| `Podfile` / `Gemfile` | CocoaPods setup; VLCKit via the existing `ios/VLCKit.podspec` (declares a tvOS target) |
| `setup.sh` | `xcodegen generate` → `pod install` → open the workspace |

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

- **Siri Remote:** move focus with swipes/clicks, press **Play/Pause** to
  toggle playback, press **Menu** to go back out of the player.
- **Live TV:** pick a category from the bar, open a channel, use the
  on-screen Previous/Next buttons to zap. Pin categories for quick access
  from Home.
- **Movies:** poster wall; the slider seeks when the provider serves
  seekable content. Controls hide after 4 seconds.
- **Search:** Live TV / Movies switch, full-catalog fast path with
  per-category fallback, same as the iPhone build.

## Notes and limits

- **tvOS parity target is the iPhone v1:** Live TV + Movies + pins +
  search. EPG, series, AirPlay and downloads are out of scope here, same as
  on iOS.
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
