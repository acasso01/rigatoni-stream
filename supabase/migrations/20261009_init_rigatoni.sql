-- Rigatoni Stream: profiles, encrypted IPTV providers, favorites
-- Run in Supabase SQL Editor. No secrets in this file.
-- Provider passwords are NEVER stored plaintext: the provider-vault Edge
-- Function encrypts with AES-GCM (key = PROVIDER_ENCRYPTION_KEY function
-- secret) and stores only ciphertext + iv here.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.iptv_providers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  label text not null default 'My provider',
  server_url text not null,
  username text not null,
  password_ciphertext text not null,
  password_iv text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.favorites (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  channel_id text not null,
  channel_name text,
  created_at timestamptz not null default now(),
  unique (user_id, channel_id)
);

alter table public.profiles enable row level security;
alter table public.iptv_providers enable row level security;
alter table public.favorites enable row level security;

drop policy if exists "profiles own read" on public.profiles;
create policy "profiles own read" on public.profiles
  for select using (auth.uid() = id);
drop policy if exists "profiles own update" on public.profiles;
create policy "profiles own update" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "providers own all" on public.iptv_providers;
create policy "providers own all" on public.iptv_providers
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "favorites own all" on public.favorites;
create policy "favorites own all" on public.favorites
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do update set email = excluded.email, updated_at = now();
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
