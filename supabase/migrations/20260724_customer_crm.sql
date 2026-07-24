-- Customer Lifecycle CRM: turns the customers table into a status-based CRM
-- (lead -> close -> active -> past) with a reminder layer that feeds ops_jobs.
-- Run this in the Supabase SQL editor for project kaujczbhtajqfrjgbxft.

-- ---------------------------------------------------------------------------
-- 1. customers: lifecycle status + follow-up tracking columns
-- ---------------------------------------------------------------------------
alter table customers
  add column if not exists lifecycle_status text not null default 'new_lead',
  -- new_lead | contacted | eval_scheduled | quoted | won | active | past | dormant | lost
  add column if not exists last_contact_at  timestamptz,
  add column if not exists annual_due_date  timestamptz;  -- denormalized for the Follow-ups view

create index if not exists customers_lifecycle_idx on customers (lifecycle_status);

-- ---------------------------------------------------------------------------
-- 2. ops_jobs: real FK to the canonical customer record
--    (customer_name is kept denormalized, mirroring how lifts stores both)
-- ---------------------------------------------------------------------------
alter table ops_jobs
  add column if not exists customer_id uuid references customers(customer_id) on delete set null;

create index if not exists ops_jobs_customer_idx on ops_jobs (customer_id);

-- ---------------------------------------------------------------------------
-- 3. customer_activities: the reminder / "clock" layer that feeds ops_jobs
--    review          -> queued on install completion; never becomes a job
--    annual          -> due = install completion + 1yr; acting spawns annual_service ops_job
--    buyback_candidate -> flag; acting spawns a buyback ops_job
--    (service/repairs are real ops_jobs, not tracked here)
-- ---------------------------------------------------------------------------
create table if not exists customer_activities (
  activity_id     uuid primary key default gen_random_uuid(),
  customer_id     uuid not null references customers(customer_id) on delete cascade,
  type            text not null,                    -- review | annual | buyback_candidate
  status          text not null default 'pending',  -- pending | done | dismissed
  due_date        timestamptz,                      -- when it surfaces (annual); null = immediate (review)
  completed_at    timestamptz,
  source_event_id text not null default '',         -- schedule event that triggered it (install completion)
  spawned_job_id  uuid,                             -- ops_job created when acted on (annual/buyback)
  notes           text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists customer_activities_customer_idx on customer_activities (customer_id);
-- Drives the "what's due" query in the Follow-ups view
create index if not exists customer_activities_due_idx
  on customer_activities (status, due_date)
  where status = 'pending';

create or replace function update_customer_activities_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists customer_activities_updated_at_trigger on customer_activities;
create trigger customer_activities_updated_at_trigger
  before update on customer_activities
  for each row execute function update_customer_activities_updated_at();

-- Enable RLS + anon full access (matches current single-shared-password auth model)
alter table customer_activities enable row level security;

create policy "anon full access" on customer_activities
  for all to anon using (true) with check (true);
