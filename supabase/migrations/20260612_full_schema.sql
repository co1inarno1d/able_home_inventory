-- =============================================================================
-- Able Home Accessibility — Complete schema migration
-- Run this in the Supabase SQL editor (safe to re-run — uses IF NOT EXISTS):
-- https://supabase.com/dashboard/project/kaujczbhtajqfrjgbxft/sql/new
-- =============================================================================


-- =============================================================================
-- 1. ops_jobs table
-- =============================================================================

create table if not exists ops_jobs (
  job_id              uuid primary key default gen_random_uuid(),
  job_type            text not null,
  status              text not null default 'ready_to_schedule',
  customer_name       text not null default '',
  address             text not null default '',
  city                text not null default '',
  phone               text not null default '',
  lift_type           text not null default '',
  lift_id             text not null default '',
  serial_number       text not null default '',
  funding_source      text not null default 'Private',
  notes               text not null default '',
  date_requested      timestamptz,
  scheduled_date      timestamptz,
  buyback_offer_price numeric(10,2),
  source_table        text not null default 'ops_jobs',
  source_id           text not null default '',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists ops_jobs_active_idx
  on ops_jobs (status, date_requested)
  where status != 'completed';

create index if not exists ops_jobs_city_idx on ops_jobs (city);
create index if not exists ops_jobs_type_idx on ops_jobs (job_type);

create or replace function update_ops_jobs_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists ops_jobs_updated_at_trigger on ops_jobs;
create trigger ops_jobs_updated_at_trigger
  before update on ops_jobs
  for each row execute function update_ops_jobs_updated_at();

alter table ops_jobs enable row level security;

drop policy if exists "anon full access" on ops_jobs;
create policy "anon full access" on ops_jobs
  for all to anon using (true) with check (true);

drop policy if exists "auth full access" on ops_jobs;
create policy "auth full access" on ops_jobs
  for all to authenticated using (true) with check (true);


-- =============================================================================
-- 2. customers table
-- =============================================================================

create table if not exists customers (
  customer_id    uuid primary key default gen_random_uuid(),
  name           text not null default '',
  address        text not null default '',
  city           text not null default '',
  phone          text not null default '',
  email          text not null default '',
  funding_source text not null default 'Private',
  qb_customer_id text not null default '',
  notes          text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
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

drop policy if exists "auth full access" on customers;
create policy "auth full access" on customers
  for all to authenticated using (true) with check (true);


-- =============================================================================
-- 3. user_profiles table
-- =============================================================================
-- One row per team member. user_id links to auth.users.
-- Roles: admin | owner | assessor | service | installer

create table if not exists user_profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null default '',
  name       text not null default '',
  role       text not null default 'installer',
  created_at timestamptz not null default now()
);

alter table user_profiles enable row level security;

drop policy if exists "anon full access" on user_profiles;
create policy "anon full access" on user_profiles
  for all to anon using (true) with check (true);

drop policy if exists "auth full access" on user_profiles;
create policy "auth full access" on user_profiles
  for all to authenticated using (true) with check (true);


-- =============================================================================
-- 4. Add columns to service_jobs
-- =============================================================================

alter table service_jobs
  add column if not exists funding_source text not null default 'Private';


-- =============================================================================
-- 5. Add columns to removal_jobs
-- =============================================================================

alter table removal_jobs
  add column if not exists funding_source text not null default 'Private';


-- =============================================================================
-- 6. Add columns to lifts
-- =============================================================================

alter table lifts
  add column if not exists customer_id      uuid references customers(customer_id) on delete set null,
  add column if not exists customer_name    text not null default '',
  add column if not exists warranty_expiry  date,
  add column if not exists buyback_price    numeric(10,2),
  add column if not exists acquisition_source text not null default '';

create index if not exists lifts_customer_id_idx on lifts (customer_id)
  where customer_id is not null;

-- Back-fill warranty_expiry for installed lifts with an ISO-format install_date
update lifts
set warranty_expiry = (install_date::date + interval '2 years')::date
where warranty_expiry is null
  and install_date is not null
  and install_date != ''
  and install_date ~ '^\d{4}-\d{2}-\d{2}$';


-- =============================================================================
-- 7. Add customer_id to lift_service
-- =============================================================================

alter table lift_service
  add column if not exists customer_id uuid references customers(customer_id) on delete set null;

create index if not exists lift_service_customer_id_idx on lift_service (customer_id)
  where customer_id is not null;


-- =============================================================================
-- 8. RLS on remaining tables (authenticated role)
-- =============================================================================
-- Adds authenticated-user policies to the original tables so Supabase Auth
-- sessions (not just anon key) can read/write them.

-- lifts
alter table lifts enable row level security;
drop policy if exists "auth full access" on lifts;
create policy "auth full access" on lifts
  for all to authenticated using (true) with check (true);

-- lift_service
alter table lift_service enable row level security;
drop policy if exists "auth full access" on lift_service;
create policy "auth full access" on lift_service
  for all to authenticated using (true) with check (true);

-- service_jobs
alter table service_jobs enable row level security;
drop policy if exists "auth full access" on service_jobs;
create policy "auth full access" on service_jobs
  for all to authenticated using (true) with check (true);

-- removal_jobs
alter table removal_jobs enable row level security;
drop policy if exists "auth full access" on removal_jobs;
create policy "auth full access" on removal_jobs
  for all to authenticated using (true) with check (true);

-- app_config
alter table app_config enable row level security;
drop policy if exists "auth full access" on app_config;
create policy "auth full access" on app_config
  for all to authenticated using (true) with check (true);

-- annual_records (if it exists)
do $$ begin
  if exists (select 1 from information_schema.tables where table_name = 'annual_records') then
    execute 'alter table annual_records enable row level security';
    execute 'drop policy if exists "auth full access" on annual_records';
    execute 'create policy "auth full access" on annual_records for all to authenticated using (true) with check (true)';
  end if;
end $$;

-- web_leads (if it exists)
do $$ begin
  if exists (select 1 from information_schema.tables where table_name = 'web_leads') then
    execute 'alter table web_leads enable row level security';
    execute 'drop policy if exists "auth full access" on web_leads';
    execute 'create policy "auth full access" on web_leads for all to authenticated using (true) with check (true)';
  end if;
end $$;


-- =============================================================================
-- Done.
-- Tables created/altered:
--   NEW:     ops_jobs, customers, user_profiles
--   ALTERED: lifts (+customer_id, +customer_name, +warranty_expiry,
--                    +buyback_price, +acquisition_source)
--            lift_service   (+customer_id)
--            service_jobs   (+funding_source)
--            removal_jobs   (+funding_source)
--   RLS:     all tables now allow both anon key and authenticated sessions
-- =============================================================================
