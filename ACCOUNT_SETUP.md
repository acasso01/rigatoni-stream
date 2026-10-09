# Rigatoni Stream — invite-only accounts

This is the **account UI scaffold**, not a finished production auth gate or credential vault. The existing IPTV player remains accessible directly. Do not invite external users until access controls and the backend are finished.

## Set up Supabase

1. Create a Supabase project at https://supabase.com/dashboard.
2. In **Authentication > Providers > Email**, disable **Allow new users to sign up** / public self-registration. Leave email/password sign-in enabled. (Dashboard wording may vary.)
3. In **Authentication > URL Configuration**, add the precise HTTPS URL for `auth.html` under redirect allow-list. Set the site URL accordingly. GitHub Pages is HTTPS. Use the hosted HTTPS account page, not the Pi's HTTP test page, for real account passwords.
4. In the repository `config.js`, replace placeholders with the project's **URL** and **publishable/anon** key. These are public browser values; **never** commit the secret/service_role key.
5. Open `https://acasso01.github.io/rigatoni-stream/auth.html` and test a sign-in.
6. Invite users from Supabase Dashboard > Authentication > Users > **Invite user**. Supabase sends the invite email. Confirm email templates and redirects before inviting others. Invited users can set a password via the account page's invitation flow; use password reset if needed.

## Before making this a public service

- Add a real authorization gate to every backend API and streaming endpoint; hiding a page is not access control.
- Move the Pi proxy off publicly reachable HTTP. Use HTTPS for account/password flows and any provider credential submission; Tailscale is a private tunnel but the browser's HTTP origin is not suitable for a public login service.
- Implement encrypted-at-rest provider settings using a trusted server-side key (AES-GCM or managed secrets). Keep decryption keys in server environment variables, never in JavaScript, Supabase public config, or GitHub. Enforce per-user access and audit invitations.
- Store favorites/profiles in per-user tables protected by Supabase Row Level Security.
- Add rate limits, credential rotation, session management, recovery testing, and an admin invite workflow.
- The current `xtream.html` stores provider credentials in tab memory only; it does **not** save or sync provider settings yet.
