-- fridge-mvp app state table
-- Run this in Supabase SQL Editor before enabling cloud sync.

create table if not exists public.fridge_app_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.fridge_app_state enable row level security;

create policy if not exists "fridge_app_state_select_own"
on public.fridge_app_state
for select
using (auth.uid() = user_id);

create policy if not exists "fridge_app_state_insert_own"
on public.fridge_app_state
for insert
with check (auth.uid() = user_id);

create policy if not exists "fridge_app_state_update_own"
on public.fridge_app_state
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy if not exists "fridge_app_state_delete_own"
on public.fridge_app_state
for delete
using (auth.uid() = user_id);

-- mobile stack tables (OneSignal + RevenueCat)
create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.notification_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('ios', 'android', 'web')),
  onesignal_subscription_id text not null,
  push_token text,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, platform, onesignal_subscription_id)
);

alter table public.notification_devices enable row level security;

create policy if not exists "notification_devices_select_own"
on public.notification_devices
for select
using (auth.uid() = user_id);

create policy if not exists "notification_devices_insert_own"
on public.notification_devices
for insert
with check (auth.uid() = user_id);

create policy if not exists "notification_devices_update_own"
on public.notification_devices
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy if not exists "notification_devices_delete_own"
on public.notification_devices
for delete
using (auth.uid() = user_id);

drop trigger if exists trg_notification_devices_updated_at on public.notification_devices;
create trigger trg_notification_devices_updated_at
before update on public.notification_devices
for each row execute function public.set_updated_at();

create index if not exists idx_notification_devices_user_id
on public.notification_devices(user_id);

create table if not exists public.subscription_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  provider text not null default 'revenuecat',
  entitlement_ids text[] not null default '{}',
  status text not null default 'inactive',
  expires_at timestamptz,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.subscription_state enable row level security;

create policy if not exists "subscription_state_select_own"
on public.subscription_state
for select
using (auth.uid() = user_id);

create policy if not exists "subscription_state_upsert_own"
on public.subscription_state
for insert
with check (auth.uid() = user_id);

create policy if not exists "subscription_state_update_own"
on public.subscription_state
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop trigger if exists trg_subscription_state_updated_at on public.subscription_state;
create trigger trg_subscription_state_updated_at
before update on public.subscription_state
for each row execute function public.set_updated_at();

create table if not exists public.revenuecat_events (
  event_id text primary key,
  user_id uuid references auth.users(id) on delete set null,
  event_type text not null,
  payload jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.revenuecat_events enable row level security;

create policy if not exists "revenuecat_events_select_own"
on public.revenuecat_events
for select
using (auth.uid() = user_id);
