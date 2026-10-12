> **Native iOS/tvOS update:** use the [standalone provider setup and installation guide](NATIVE_STANDALONE.md). Native apps now use direct providers and local Keychain profiles; older account/gateway instructions below apply only to legacy builds.

# Ant Streams

Interactive IPTV PWA design preview. No live streams, provider accounts, or copyrighted content are included.

## Install on iPhone
1. Open the live URL in Safari.
2. Tap Share → Add to Home Screen.
3. Tap Add. Ant Streams will open full-screen like an app.

## Files
- `index.html` — app UI
- `manifest.webmanifest` — PWA manifest
- `sw.js` — offline cache
- `icon-*.png`, `icon.svg` — app icons

Movies are loaded on demand from the provider’s VOD catalog through the private gateway, with bounded category paging, search, movie favorites, posters and byte-range seeking. Save provider & gateway stores the gateway as a non-secret Supabase user preference; existing provider credentials stay in the encrypted provider-vault function. Rebuild the Pi gateway to enable the movie endpoint.
