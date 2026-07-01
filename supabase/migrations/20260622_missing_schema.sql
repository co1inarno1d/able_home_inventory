-- =============================================================================
-- Able Home Accessibility — Missing schema patch
-- Run this in the Supabase SQL editor:
-- https://supabase.com/dashboard/project/kaujczbhtajqfrjgbxft/sql/new
--
-- This covers everything not included in the previous migrations:
--   1. lift_history — user_name + user_email + event_type columns (for audit log)
--   2. lifts — acquisition_source column
--   3. qb_tokens — QuickBooks OAuth token storage
--   4. RLS policies updated to authenticated (not anon) for security
-- =============================================================================


-- =============================================================================
-- 1. lift_history — ensure it exists and has all required columns
-- =============================================================================
-- The app writes to this table on every status change, edit, and deletion.
-- If it doesn't exist yet, create it. If it does, add the missing columns.

create table if not exists lift_history (
  id            bigserial primary key,
  timestamp     timestamptz not null default now(),
  lift_id       text not null default '',
  serial_number text not null default '',
  event_type    text not null default '',   -- Created | Updated | Deleted | Status Change
  from_status   text not null default '',
  to_status     text not null default '',
  from_location text not null default '',
  to_location   text not null default '',
  from_customer text not null default '',
  to_customer   text not null default '',
  job_ref       text not null default '',
  note          text not null default '',
  user_email    text not null default '',
  user_name     text not null default ''
);

-- Add columns if table already existed without them
alter table lift_history add column if not exists user_email    text not null default '';
alter table lift_history add column if not exists user_name     text not null default '';
alter table lift_history add column if not exists event_type    text not null default '';
alter table lift_history add column if not exists serial_number text not null default '';
alter table lift_history add column if not exists lift_id       text not null default '';

create index if not exists lift_history_serial_idx   on lift_history (serial_number);
create index if not exists lift_history_lift_id_idx  on lift_history (lift_id);
create index if not exists lift_history_timestamp_idx on lift_history (timestamp desc);

alter table lift_history enable row level security;
drop policy if exists "auth full access" on lift_history;
create policy "auth full access" on lift_history
  for all to authenticated using (true) with check (true);


-- =============================================================================
-- 2. lifts — acquisition_source column
-- =============================================================================

alter table lifts
  add column if not exists acquisition_source text not null default '';


-- =============================================================================
-- 3. qb_tokens — QuickBooks OAuth token storage
-- =============================================================================

create table if not exists qb_tokens (
  realm_id      text primary key,
  access_token  text not null,
  refresh_token text not null,
  expires_at    timestamptz not null,
  updated_at    timestamptz not null default now()
);

alter table qb_tokens enable row level security;
-- No client-side access — edge function owns this via service role key


-- =============================================================================
-- 4. Tighten RLS on sensitive tables to authenticated only (not anon)
-- =============================================================================
-- Previous migrations used "anon" access for simplicity. Now that we have
-- Supabase Auth with individual logins, lock these down to authenticated users.

drop policy if exists "anon full access" on user_profiles;
drop policy if exists "auth full access" on user_profiles;
create policy "auth full access" on user_profiles
  for all to authenticated using (true) with check (true);

drop policy if exists "anon full access" on customers;
drop policy if exists "auth full access" on customers;
create policy "auth full access" on customers
  for all to authenticated using (true) with check (true);

drop policy if exists "anon full access" on ops_jobs;
drop policy if exists "auth full access" on ops_jobs;
create policy "auth full access" on ops_jobs
  for all to authenticated using (true) with check (true);
