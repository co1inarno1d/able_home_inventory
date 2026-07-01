-- =============================================================================
-- Able Home Accessibility — All Supabase schema changes
-- Run these in order in the Supabase SQL editor:
-- https://supabase.com/dashboard/project/kaujczbhtajqfrjgbxft/sql/new
-- =============================================================================


-- =============================================================================
-- 1. ops_jobs table (Operations Hub)
-- =============================================================================
-- Unified pending work queue — replaces the physical whiteboards and scattered
-- service/removal/annuals tabs. All pending jobs flow through here.

create table if not exists ops_jobs (
  job_id          uuid primary key default gen_random_uuid(),
  job_type        text not null,
  -- stairlift_install | stairlift_removal | buyback | stairlift_service
  -- | ramp_install | ramp_removal | annual_service | web_lead
  status          text not null default 'ready_to_schedule',
  -- needs_info | waiting_agency_confirmation | ready_to_schedule | scheduled | completed
  customer_name   text not null default '',
  address         text not null default '',
  city            text not null default '',
  phone           text not null default '',
  lift_type       text not null default '',
  lift_id         text not null default '',
  serial_number   text not null default '',
  funding_source  text not null default 'Private',
  -- Private | VA | CCALS | NaviCare | Summit | Fallon | Mass Health | Other
  notes           text not null default '',
  date_requested  timestamptz,
  scheduled_date  timestamptz,
  buyback_offer_price numeric(10,2),
  source_table    text not null default 'ops_jobs',
  source_id       text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
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


-- =============================================================================
-- 2. Add funding_source column to service_jobs
-- =============================================================================
-- Tracks whether a service job is Private, VA, CCALS, NaviCare, etc.
-- Defaults to 'Private' for all existing rows.

alter table service_jobs
  add column if not exists funding_source text not null default 'Private';


-- =============================================================================
-- 3. Add funding_source column to removal_jobs
-- =============================================================================
-- Same as above for removal jobs.

alter table removal_jobs
  add column if not exists funding_source text not null default 'Private';


-- =============================================================================
-- Done.
-- =============================================================================
-- The app_config table already exists and requires no schema changes.
-- Funding source for schedule events is stored as key-value rows with the
-- pattern:  key = 'event_funding_<eventId>',  value = 'CCALS' (etc.)
-- No new columns needed — uses existing app_config structure.
-- =============================================================================
