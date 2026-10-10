# Rigatoni Stream accounts

The account page supports sign-in, account creation, email confirmation and resend, password recovery, and existing invitations. The home page and IPTV player share the account page's charcoal and red theme.

## Supabase configuration

- Project: `edjejdftwjiasfhpffmc`.
- In Authentication → Sign In / Providers, **Allow new users to sign up** must be enabled to use Create Account. Keep **Confirm email** enabled. Signup was disabled when this change was prepared; enabling it requires owner approval.
- Keep the existing site URL `https://acasso01.github.io/rigatoni-stream/` and the allowed redirect `https://acasso01.github.io/rigatoni-stream/auth.html`.
- Confirm that email delivery is configured for the intended users. Supabase's default email sender has delivery restrictions and rate limits; broader signup may require custom SMTP.
- `config.js` contains only public configuration. Never put the service-role key, encryption secret, or IPTV credentials in source code.
- Preserve `PROVIDER_ENCRYPTION_KEY` in Edge Function Secrets. Replacing it without a data migration can make existing saved passwords unreadable.

## User flow

1. Open the home page and choose **Create an account**.
2. Enter your email and a matching password of at least eight characters.
3. Confirm your email using the link Supabase sends, then sign in.
4. Open the player, enter your authorized IPTV provider, and choose **Save provider securely** without connecting first. Account and IPTV passwords are separate. For HTTP playback on GitHub Pages, install the private gateway using [gateway/README.md](gateway/README.md), then enter its HTTPS URL and connect.

An app account does not include an IPTV subscription. Live playback depends on the provider, browser support, HTTPS compatibility, and provider CORS configuration. Movies and series remain forthcoming in the existing player.

## Validation

Run `node tests/auth.mjs` for the account state and API-contract checks (uses a fake auth client, creates no users, sends no emails). Check the home, account, and provider pages on desktop and mobile. Complete a real email-confirmation signup after enabling registration with owner approval.

The player restores the encrypted vault into the form without automatically connecting. The gateway reuses the existing Supabase vault backend. The service worker caches only named static app assets and excludes account callbacks, external provider requests, and Supabase responses.
