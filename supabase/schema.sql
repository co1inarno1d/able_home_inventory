-- =============================================================
-- ABLE HOME INVENTORY — Supabase Schema
-- Run this in the Supabase SQL Editor (Project → SQL Editor → New query)
-- =============================================================

-- ---------------------------------------------------------------
-- LIFTS MASTER
-- ---------------------------------------------------------------
create table if not exists lifts (
  id              bigserial primary key,
  lift_id         text unique not null,
  serial_number   text,
  brand           text,
  series          text,
  orientation     text,
  fold_type       text,
  condition       text,
  date_acquired   text,
  status          text,
  current_location text,
  current_job     text,
  install_date    text,
  installer_name  text,
  prepped_status  text,
  last_prep_date  text,
  notes           text,
  bin_number      text,
  clean_batteries_status text,
  photo_urls      text[] default '{}',
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- ---------------------------------------------------------------
-- LIFT HISTORY
-- ---------------------------------------------------------------
create table if not exists lift_history (
  id              bigserial primary key,
  timestamp       timestamptz default now(),
  lift_id         text,
  serial_number   text,
  event_type      text,
  from_status     text,
  to_status       text,
  from_location   text,
  to_location     text,
  from_customer   text,
  to_customer     text,
  job_ref         text,
  note            text,
  user_email      text,
  user_name       text
);

create index if not exists lift_history_serial_idx on lift_history(serial_number);
create index if not exists lift_history_lift_id_idx on lift_history(lift_id);

-- ---------------------------------------------------------------
-- LIFT SERVICE RECORDS
-- ---------------------------------------------------------------
create table if not exists lift_service (
  id              bigserial primary key,
  timestamp       timestamptz default now(),
  lift_id         text,
  serial_number   text,
  service_date    text,
  service_type    text,
  description     text,
  invoice_number  text,
  technician_name text,
  job_ref         text,
  customer_name   text,
  notes           text,
  entered_by_email text,
  entered_by_name  text
);

create index if not exists lift_service_serial_idx on lift_service(serial_number);
create index if not exists lift_service_lift_id_idx on lift_service(lift_id);

-- ---------------------------------------------------------------
-- PREP CHECKLISTS
-- ---------------------------------------------------------------
create table if not exists prep_checklists (
  id              bigserial primary key,
  checklist_id    text unique not null,
  timestamp       timestamptz default now(),
  lift_id         text,
  serial_number   text,
  brand           text,
  series          text,
  prep_date       text,
  prepped_by_name text,
  prepped_by_email text,
  notes           text,
  checklist_items jsonb default '{}'
);

create index if not exists prep_checklists_serial_idx on prep_checklists(serial_number);
create index if not exists prep_checklists_lift_id_idx on prep_checklists(lift_id);

-- ---------------------------------------------------------------
-- INVENTORY — STAIRLIFTS (quantity-based)
-- ---------------------------------------------------------------
create table if not exists inventory_stairlifts (
  id          bigserial primary key,
  item_id     text unique not null,
  brand       text,
  series      text,
  orientation text,
  fold_type   text,
  condition   text,
  min_qty     integer default 0,
  current_qty integer default 0,
  active      text default 'Y',
  notes       text
);

-- ---------------------------------------------------------------
-- INVENTORY — RAMPS (quantity-based)
-- ---------------------------------------------------------------
create table if not exists inventory_ramps (
  id          bigserial primary key,
  item_id     text unique not null,
  brand       text,
  size        text,
  condition   text,
  current_qty integer default 0,
  min_qty     integer default 0
);

-- ---------------------------------------------------------------
-- INVENTORY CHANGES LOG
-- ---------------------------------------------------------------
create table if not exists inventory_changes (
  id            bigserial primary key,
  timestamp     timestamptz default now(),
  user_email    text,
  user_name     text,
  change_type   text,
  item_id       text,
  brand         text,
  series_or_size text,
  orientation   text,
  condition     text,
  old_qty       integer,
  new_qty       integer,
  delta         integer,
  job_ref       text
);

-- ---------------------------------------------------------------
-- PICKUP LIST
-- ---------------------------------------------------------------
create table if not exists pickup_list (
  id            text primary key,
  item          text,
  added_by      text,
  added_at      timestamptz default now(),
  completed     boolean default false,
  completed_by  text,
  completed_at  timestamptz
);

-- ---------------------------------------------------------------
-- ROW LEVEL SECURITY
-- Allow full access via anon key (internal tool, no auth needed)
-- ---------------------------------------------------------------
alter table lifts                enable row level security;
alter table lift_history         enable row level security;
alter table lift_service         enable row level security;
alter table prep_checklists      enable row level security;
alter table inventory_stairlifts enable row level security;
alter table inventory_ramps      enable row level security;
alter table inventory_changes    enable row level security;
alter table pickup_list          enable row level security;

-- Allow all operations for anonymous users (internal tool)
create policy "allow_all" on lifts                for all using (true) with check (true);
create policy "allow_all" on lift_history         for all using (true) with check (true);
create policy "allow_all" on lift_service         for all using (true) with check (true);
create policy "allow_all" on prep_checklists      for all using (true) with check (true);
create policy "allow_all" on inventory_stairlifts for all using (true) with check (true);
create policy "allow_all" on inventory_ramps      for all using (true) with check (true);
create policy "allow_all" on inventory_changes    for all using (true) with check (true);
create policy "allow_all" on pickup_list          for all using (true) with check (true);
