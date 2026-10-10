# Private HTTPS playback gateway

Run this on the Raspberry Pi already connected to your Tailscale network. The GitHub Pages player stays where it is. Tailscale Serve terminates HTTPS and forwards requests to the gateway's loopback-only Docker port. No router port forwarding is needed. Every playback device must have Tailscale connected and permission to reach the Pi.

## Start on the Pi

Docker Compose and Tailscale must already be installed. These commands create a dedicated checkout, without changing your other Pi services:

```bash
git clone https://github.com/acasso01/rigatoni-stream.git ~/rigatoni-stream-gateway
cd ~/rigatoni-stream-gateway/gateway
docker compose up -d --build
curl http://127.0.0.1:8787/health
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8787
```

Use port 8443 to avoid replacing an existing Tailscale HTTPS service on port 443. Tailscale may print a link to enable HTTPS in your tailnet; complete that setup if prompted. Read the HTTPS URL printed by `tailscale serve`; do not substitute the Pi's raw IP. Check configuration with `tailscale serve status`.

## Use the deployed player

1. Turn on Tailscale on your iPhone/Mac.
2. Open https://acasso01.github.io/rigatoni-stream/xtream.html and sign in.
3. Enter your authorized provider URL, username, and password and click **Save provider securely**. Saving does not contact the provider.
4. Enter the Pi's exact HTTPS URL (including `:8443`) in **HTTPS gateway URL**.
5. Click **Connect & Watch**. The gateway uses the provider saved in your account. Save again before connecting if you changed the form.

The gateway URL is kept only in the current form. Re-enter it after reloading. A browser may request local-network permission; allow it for this site to reach your private gateway. Safari/iPhone native HLS is the first playback target, matching the existing player. Codec support, subscription limits, and provider availability still apply. There is no transcoding; movies and series are unchanged.

When native playback fails but its playlist is reachable, the player asks the gateway to inspect the media with FFprobe. This reports video/audio codecs and the actual resolution without reducing quality. FFprobe accesses only the gateway's opaque relay paths, so nested playlists, segments and keys retain the same destination checks. One probe can run at a time, with a 20-second process timeout; results for up to 20 channels per session are cached. Output contains only codec/resolution fields, and provider URLs, metadata and stderr are never returned or logged. The Docker image includes FFmpeg for this check. This diagnoses compatibility; it does not add new Safari decoders or promise playback of every HD/4K stream.

## How credentials are protected

The browser sends its Supabase access token to the private gateway in an Authorization header. The gateway uses that token to call the existing `provider-vault` Edge Function. Only that signed-in user's provider is retrieved. It needs the public Supabase key, never a service-role key or encryption secret. Credentials are used in memory to contact the provider, never written to disk or logged.

Playback uses random temporary paths. The gateway rewrites HLS playlists, segments, encryption keys, and nested playlists so browser-facing URLs contain no provider login details. Sessions expire after four hours or immediately when the gateway restarts. Treat temporary media links as secrets: anyone with a link and access to the private gateway can use it until expiry. Deleting saved settings prevents future connections; existing playback tickets remain valid until expiry/restart. To revoke all tickets immediately, run `docker compose restart`.

Provider destinations and every redirect are resolved and pinned to public IP addresses. Private, loopback, link-local, Tailscale, and reserved addresses are rejected. This does not proxy local-network providers. Only the GitHub Pages origin is allowed by CORS. Credentials are never placed in GitHub, browser localStorage, or service-worker caches. Public config in compose.yaml is intentionally non-secret. HTTP provider traffic between the Pi and provider remains HTTP; the gateway cannot encrypt a provider's HTTP-only endpoint.

## Verify after installation

- Health returns `{"ok":true,"service":"rigatoni-gateway"}`.
- Save an authorized provider, reload, and confirm its settings restore without connecting.
- Add the gateway URL, connect, select a channel, and confirm video plays.
- Browser network requests for playlists/segments should use the Pi's HTTPS `/media/` paths.
- Run `docker compose logs --tail=20` for startup status; this gateway never logs credentials or request URLs.

Tests from the repository root:

```bash
node tests/auth.mjs
node tests/provider-vault.mjs
node tests/gateway.mjs
node tests/playback.mjs
node tests/catalog.mjs
# Requires FFmpeg/FFprobe locally; generates a dummy HD HLS stream:
node tests/media-probe.mjs
```

These tests use dummy provider data and mock upstream streams, not a real subscription. Deployment and real playback require running the Pi setup and testing with your provider.

To update an existing gateway checkout, run `git pull --ff-only`, then `docker compose up -d --build` from its gateway directory. To stop it, run `docker compose down`. This does not change Home Assistant, Samba, MQTT, or your port-8090 Pi test server.

Large catalogs are parsed incrementally and only the fields used by the player are retained. Limits are 128 MiB of upstream JSON, 100,000 live channels, 10,000 categories and 2 MiB per item. The container has a 512 MiB memory cap. Oversized or malformed responses are rejected without logging their contents.

If you changed the host port to 8788, preserve that mapping when pulling updates. The restore below resets only the gateway Compose file; reapply any other customizations before starting it:

```bash
cd ~/rigatoni-stream-gateway
git restore gateway/compose.yaml
git pull --ff-only
cd gateway
sed -i 's/127.0.0.1:8787:8787/127.0.0.1:8788:8787/' compose.yaml
docker compose up -d --build
curl http://127.0.0.1:8788/health
```
