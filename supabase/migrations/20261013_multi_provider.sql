-- Ant Streams: multi-provider support (2026-10-13).
-- Run in Supabase SQL Editor AFTER 20261009_init_rigatoni.sql. No secrets in this file.
--
-- Drops the one-provider-per-user unique constraint so a user can save several
-- IPTV providers. Provider identity becomes (user_id, label). Existing rows
-- keep working: their labels default to 'My provider' and stay unique per user.

alter table public.iptv_providers
  drop constraint if exists iptv_providers_user_id_key;

create unique index if not exists iptv_providers_user_label_unique
  on public.iptv_providers (user_id, label);
