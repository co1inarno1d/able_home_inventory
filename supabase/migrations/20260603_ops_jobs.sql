-- Operations Hub: unified pending work queue for Able Home Accessibility
-- Run this in the Supabase SQL editor for project kaujczbhtajqfrjgbxft

create table if not exists ops_jobs (
  job_id          uuid primary key default gen_random_uuid(),
  job_type        text not null,  -- stairlift_install | stairlift_removal | buyback | stairlift_service | ramp_install | ramp_removal | annual_service | web_lead
  status          text not null default 'ready_to_schedule',  -- needs_info | waiting_agency_confirmation | ready_to_schedule | scheduled | completed
  customer_name   text not null default '',
  address         text not null default '',
  city            text not null default '',  -- extracted city for geo clustering
  phone           text not null default '',
  lift_type       text not null default '',
  lift_id         text not null default '',
  serial_number   text not null default '',
  funding_source  text not null default 'Private',  -- Private | VA | CCALS | NaviCare | Summit | Fallon | Mass Health | Other
  notes           text not null default '',
  date_requested  timestamptz,
  scheduled_date  timestamptz,
  buyback_offer_price numeric(10,2),  -- null for non-buyback jobs
  source_table    text not null default 'ops_jobs',  -- which table this originated from (for back-links)
  source_id       text not null default '',          -- ID in the source table
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- Index for the common query pattern: active jobs ordered by date_requested
create index if not exists ops_jobs_active_idx
  on ops_jobs (status, date_requested)
  where status != 'completed';

-- Index for city-based geo clustering lookups
create index if not exists ops_jobs_city_idx on ops_jobs (city);

-- Index for job type filtering
create index if not exists ops_jobs_type_idx on ops_jobs (job_type);

-- Auto-update updated_at on any row change
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

-- Enable row-level security (match existing tables in this project)
alter table ops_jobs enable row level security;

-- Allow anon key full access (matches current app auth model — single shared password)
create policy "anon full access" on ops_jobs
  for all to anon using (true) with check (true);
