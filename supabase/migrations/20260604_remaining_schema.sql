-- =============================================================================
-- Able Home Accessibility — Remaining schema changes (2026-06-04)
-- Run in Supabase SQL editor:
-- https://supabase.com/dashboard/project/kaujczbhtajqfrjgbxft/sql/new
-- =============================================================================
-- Run the previous migration first if you haven't already:
--   supabase/migrations/20260603_all_schema_changes.sql
-- =============================================================================


-- =============================================================================
-- 1. user_profiles table (P4 — Role-based auth)
-- =============================================================================
-- One row per team member. user_id links to Supabase Auth (auth.users).
-- After running this SQL, create each user in the Supabase Auth dashboard
-- (Authentication > Users > Invite user), then insert a row here with their
-- user_id and the correct role.
--
-- Roles: admin | owner | assessor | service | installer

create table if not exists user_profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text not null default '',
  name        text not null default '',
  role        text not null default 'installer',
  -- admin | owner | assessor | service | installer
  created_at  timestamptz not null default now()
);

alter table user_profiles enable row level security;

-- Allow anon key full access — matches the pattern used by all other tables
-- in this app. The app authenticates users at the application layer (Supabase Auth)
-- rather than relying on row-level JWT policies.
drop policy if exists "anon full access" on user_profiles;
create policy "anon full access" on user_profiles
  for all to anon using (true) with check (true);

-- =============================================================================
-- AFTER RUNNING: Create your team in Supabase Auth, then run inserts like:
--
--   insert into user_profiles (user_id, email, name, role) values
--     ('<uuid-from-auth>', 'colin@loml.org',      'Colin',  'admin'),
--     ('<uuid-from-auth>', 'matt@ableha.com',      'Matt',   'owner'),
--     ('<uuid-from-auth>', 'chris@ableha.com',     'Chris',  'owner'),
--     ('<uuid-from-auth>', 'assessor@ableha.com',  'James',  'assessor'),
--     ('<uuid-from-auth>', 'service@ableha.com',   'Tech',   'service'),
--     ('<uuid-from-auth>', 'installer@ableha.com', 'Crew',   'installer');
-- =============================================================================


-- =============================================================================
-- 2. customers table (P2 — Customer profiles)
-- =============================================================================

create table if not exists customers (
  customer_id   uuid primary key default gen_random_uuid(),
  name          text not null default '',
  address       text not null default '',
  city          text not null default '',
  phone         text not null default '',
  email         text not null default '',
  funding_source text not null default 'Private',
  qb_customer_id text not null default '',  -- QuickBooks Online nameId for deep-link
  notes         text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists customers_name_idx on customers (name);
create index if not exists customers_city_idx on customers (city);

create or replace function update_customers_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists customers_updated_at_trigger on customers;
create trigger customers_updated_at_trigger
  before update on customers
  for each row execute function update_customers_updated_at();

alter table customers enable row level security;

drop policy if exists "anon full access" on customers;
create policy "anon full access" on customers
  for all to anon using (true) with check (true);

-- Optional: also allow authenticated users (for when we switch to full auth)
drop policy if exists "auth full access" on customers;
create policy "auth full access" on customers
  for all to authenticated using (true) with check (true);


-- =============================================================================
-- 3. Add customer_id to lifts table (P2 — link lifts to customers)
-- =============================================================================
-- Nullable — legacy lifts won't have a customer_id until manually linked.
-- The customer profile screen fetches lifts by customer_id.

alter table lifts
  add column if not exists customer_id uuid references customers(customer_id) on delete set null;

create index if not exists lifts_customer_id_idx on lifts (customer_id)
  where customer_id is not null;


-- =============================================================================
-- 4. Add customer_id to lift_service table (P2 — service history per customer)
-- =============================================================================

alter table lift_service
  add column if not exists customer_id uuid references customers(customer_id) on delete set null;

create index if not exists lift_service_customer_id_idx on lift_service (customer_id)
  where customer_id is not null;


-- =============================================================================
-- 5. Add warranty_expiry + buyback_price to lifts table (P5 + P7)
-- =============================================================================

alter table lifts
  add column if not exists warranty_expiry  date,
  add column if not exists buyback_price    numeric(10,2),
  add column if not exists customer_name    text not null default '';

-- Back-fill warranty_expiry for all currently-installed lifts that have an
-- install_date but no warranty_expiry (2-year warranty from install date).
-- This only sets it if install_date is a parseable date string.
update lifts
set warranty_expiry = (install_date::date + interval '2 years')::date
where warranty_expiry is null
  and install_date is not null
  and install_date != ''
  and install_date ~ '^\d{4}-\d{2}-\d{2}$';  -- only ISO-format dates


-- =============================================================================
-- 6. Update ops_jobs RLS to also allow authenticated users (future-proofing)
-- =============================================================================

drop policy if exists "auth full access" on ops_jobs;
create policy "auth full access" on ops_jobs
  for all to authenticated using (true) with check (true);


-- =============================================================================
-- Summary of all tables touched across both migrations:
-- =============================================================================
--  NEW tables:    ops_jobs, user_profiles, customers
--  ALTERED:       service_jobs  (+funding_source)
--                 removal_jobs  (+funding_source)
--                 lifts         (+customer_id, +warranty_expiry, +buyback_price)
--                 lift_service  (+customer_id)
--  NO CHANGE:     app_config (event_funding_ keys added at app level, no DDL needed)
-- =============================================================================
