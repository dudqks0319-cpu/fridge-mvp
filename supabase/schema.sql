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
