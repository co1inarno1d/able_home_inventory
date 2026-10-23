-- Customer identity: make the event <-> customer relationship queryable.
--
-- THE PROBLEM
-- The link between a schedule event and a customer is currently a JSON blob
-- in app_config under 'event_customer_<id>'. That cannot be queried in
-- reverse, so the app literally cannot answer "show me every job at this
-- house" -- the core of what the Customers tab needs. Worse, 182 of 182
-- installed lifts have no customer_id at all, and there is exactly 1 customer
-- row in the database.
--
-- WHAT THE DATA ACTUALLY LOOKS LIKE (surveyed, not assumed, across 3-5k
-- recent events in schedule_history):
--
--   * Event TITLES are mostly TOWN names, not customer names:
--     "Boylston Install", "Fitchburg SL service", "Winthrop Eval".
--     Matching on title would be matching on geography.
--   * The street address is in `location`:        56% of events
--   * A phone number appears in `notes`:          58% of events
--   * A person-name line appears in `notes`:      43% of events
--   * Address OR phone present:                   62%  <- identifiable
--   * 1,753 distinct addresses; 681 visited more than once (one 9 times).
--     Those repeat households are the ones with real service history.
--
-- SO: address is the strongest grouping key, phone is the strongest IDENTITY
-- key (it survives a move; an address does not), and the customer's NAME is
-- the real-world identity but has to be extracted from notes or QuickBooks.
-- A customer can legitimately have several addresses -- they moved, and we
-- have or had equipment at both.
--
-- Nothing here deletes or rewrites existing data. The app_config blobs stay
-- as they are; these tables are populated alongside them and become the
-- queryable path.

-- ---------------------------------------------------------------------------
-- app_config: retroactive DDL
--
-- This table exists ONLY in the live database -- there is no definition
-- anywhere in the repo, so a rebuild from migrations produces a broken app.
-- Shape confirmed against production (it has a bigserial `id`, which was not
-- obvious and would have been guessed wrong).
-- ---------------------------------------------------------------------------
create table if not exists app_config (
  id         bigserial primary key,
  key        text not null unique,
  value      text,
  updated_at timestamptz not null default now()
);

alter table app_config enable row level security;
drop policy if exists "anon full access" on app_config;
create policy "anon full access" on app_config
  for all to anon using (true) with check (true);

-- The reconciliation pipeline scans by key prefix ('event_customer_%').
-- text_pattern_ops makes that index-backed; the default opclass cannot serve
-- prefix LIKE under a non-C collation.
create index if not exists app_config_key_prefix_idx
  on app_config (key text_pattern_ops);

-- ---------------------------------------------------------------------------
-- customers: identity + matching keys
-- ---------------------------------------------------------------------------

alter table customers
  -- Freeform tech-facing notes ("heavy accent", "frequent flyer", "call
  -- ahead"). Deliberately SEPARATE from `notes`, which is shown alongside
  -- QuickBooks and can be pushed there via the qb-proxy append-note action --
  -- an unflattering remark must never sync to a customer-visible system.
  add column if not exists field_notes text not null default '',
  -- Soft-merge target. Duplicates are never deleted: FKs from lifts,
  -- lift_service and customer_activities would orphan or cascade. The loser
  -- is tombstoned and points at the survivor; all queries filter
  -- `merged_into is null`.
  add column if not exists merged_into uuid references customers(customer_id)
    on delete set null,
  add column if not exists qb_synced_at timestamptz;

-- Normalized phone as a STORED GENERATED column, not application logic.
-- normalize_e164 is IMMUTABLE precisely so matching can be structural and
-- cannot be forgotten at one call site.
alter table customers
  add column if not exists phone_e164 text
    generated always as (normalize_e164(phone)) stored;

create index if not exists customers_phone_e164_idx
  on customers (phone_e164) where phone_e164 is not null;
create index if not exists customers_qb_id_idx
  on customers (qb_customer_id) where qb_customer_id <> '';
create index if not exists customers_merged_into_idx
  on customers (merged_into) where merged_into is not null;
create index if not exists customers_active_idx
  on customers (name) where merged_into is null;

-- ---------------------------------------------------------------------------
-- customer_addresses: one customer, many addresses
--
-- Needed because customers move and we keep equipment at both the old and new
-- place. Without this, a move either splits one customer into two records or
-- silently attaches the old house's history to the new one.
--
-- `addr_key` is the normalized form used for grouping and joining; `address`
-- keeps whatever was actually written so nothing is lost.
-- ---------------------------------------------------------------------------
create table if not exists customer_addresses (
  address_id  uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(customer_id) on delete cascade,
  address     text not null default '',
  addr_key    text not null,
  city        text not null default '',
  label       text not null default 'primary',  -- primary | prior | second
  first_seen  date,
  last_seen   date,
  created_at  timestamptz not null default now()
);

create index if not exists customer_addresses_customer_idx
  on customer_addresses (customer_id);
create index if not exists customer_addresses_key_idx
  on customer_addresses (addr_key);
-- One customer should not hold the same address twice.
create unique index if not exists customer_addresses_uniq
  on customer_addresses (customer_id, addr_key);

-- ---------------------------------------------------------------------------
-- event_customer_links: the durable decision record
--
-- Keyed on bare tsheets_id with NO foreign key, deliberately: a LIVE TSheets
-- event (the last ~7 days) has no schedule_history row until the nightly
-- archive runs, and a match decision has to survive that gap.
--
-- `locked` is the idempotency guarantee -- the matcher skips locked rows, so a
-- human decision is never re-asked and never overwritten by a later run.
-- A deliberate "this event belongs to nobody" is
-- (customer_id = null, locked = true), which is distinct from "not yet
-- examined" (null, false).
-- ---------------------------------------------------------------------------
create table if not exists event_customer_links (
  tsheets_id       text primary key,
  customer_id      uuid references customers(customer_id) on delete cascade,
  match_confidence numeric(4,3),   -- 0.000..1.000; null = never attempted
  match_method     text not null default '',
                   -- phone_e164 | address | qb_id | app_explicit | manual
                   -- | unmatched | ambiguous
  locked           boolean not null default false,
  reviewed_by      text not null default '',
  note             text not null default '',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists event_customer_links_customer_idx
  on event_customer_links (customer_id) where customer_id is not null;
create index if not exists event_customer_links_locked_idx
  on event_customer_links (locked) where locked;

-- ---------------------------------------------------------------------------
-- schedule_history: denormalized hot-path columns
--
-- The customer tab's history query and the deep search both run against this
-- table; they need a plain indexed column, not a join through a link table.
-- Mirrors how `lifts` already carries both customer_id and customer_name.
-- ---------------------------------------------------------------------------
alter table schedule_history
  add column if not exists customer_id uuid
    references customers(customer_id) on delete set null,
  add column if not exists customer_name text not null default '',
  add column if not exists match_confidence numeric(4,3),
  add column if not exists match_method text not null default '',
  add column if not exists matched_at timestamptz;

create index if not exists schedule_history_customer_idx
  on schedule_history (customer_id, start_time desc)
  where customer_id is not null;

-- Drives the review queue: what still needs a customer.
create index if not exists schedule_history_unmatched_idx
  on schedule_history (start_time desc) where customer_id is null;

-- ---------------------------------------------------------------------------
-- Keep the two in sync, in both directions.
--
-- Direction 1: a decision recorded in event_customer_links is pushed onto the
-- schedule_history row if it exists.
-- ---------------------------------------------------------------------------
create or replace function sync_schedule_history_customer()
returns trigger language plpgsql as $$
begin
  update schedule_history sh
     set customer_id      = new.customer_id,
         customer_name    = coalesce(
                              (select c.name from customers c
                                where c.customer_id = new.customer_id), ''),
         match_confidence = new.match_confidence,
         match_method     = new.match_method,
         matched_at       = now()
   where sh.tsheets_id = new.tsheets_id;
  return new;
end $$;

drop trigger if exists event_customer_links_sync on event_customer_links;
create trigger event_customer_links_sync
  after insert or update of customer_id on event_customer_links
  for each row execute function sync_schedule_history_customer();

-- Direction 2: when the nightly archive inserts a row for an event that was
-- already decided, the decision is applied on the way in.
--
-- This is what lets the archive-schedule edge function stay COMPLETELY
-- UNCHANGED -- it keeps upserting exactly as it does today and the trigger
-- decorates each row. That function is load-bearing (it holds 25,129 events
-- back to 2019) so not touching it is a feature.
create or replace function apply_event_customer_link()
returns trigger language plpgsql as $$
declare l record;
begin
  select * into l from event_customer_links
   where tsheets_id = new.tsheets_id;
  if found then
    new.customer_id      := l.customer_id;
    new.customer_name    := coalesce(
                              (select c.name from customers c
                                where c.customer_id = l.customer_id), '');
    new.match_confidence := l.match_confidence;
    new.match_method     := l.match_method;
    new.matched_at       := now();
  end if;
  return new;
end $$;

-- Fires on UPDATE as well as INSERT. The archive function upserts with
-- `Prefer: resolution=merge-duplicates`, so a re-archived event arrives as an
-- UPDATE, not an INSERT. An insert-only trigger would silently drop the
-- customer link every time an event was re-archived -- and since the cron
-- re-archives a rolling window, that would quietly undo matching.
--
-- Guarded so it only writes when the row does not already carry a link,
-- which keeps a human correction made directly on schedule_history from being
-- reverted by the next archive pass.
drop trigger if exists schedule_history_apply_link on schedule_history;
create trigger schedule_history_apply_link
  before insert or update on schedule_history
  for each row
  when (new.customer_id is null)
  execute function apply_event_customer_link();

-- ---------------------------------------------------------------------------
-- Tags
--
-- A join table against a controlled vocabulary, NOT a text[] column. An array
-- would reproduce the casing drift this schema already suffers ('VA' / 'va' /
-- 'V.A.' becoming three tags) and leaves nowhere to hang a colour or to
-- rename a tag across thousands of customers.
--
-- This is the one place to add a real constraint, deliberately: the FK on
-- tag_slug is what PREVENTS the drift. It is safe because the table is
-- greenfield -- there are no existing rows to reject, which was the stated
-- reason for avoiding constraints in 20260824_metrics_helpers.sql.
-- ---------------------------------------------------------------------------
create table if not exists customer_tags (
  slug       text primary key,
  label      text not null,
  color      text not null default '#607D8B',
  sort_order int  not null default 100,
  created_at timestamptz not null default now()
);

create table if not exists customer_tag_links (
  customer_id uuid not null references customers(customer_id) on delete cascade,
  tag_slug    text not null references customer_tags(slug)    on delete cascade,
  created_at  timestamptz not null default now(),
  created_by  text not null default '',
  primary key (customer_id, tag_slug)
);

create index if not exists customer_tag_links_tag_idx
  on customer_tag_links (tag_slug);

insert into customer_tags (slug, label, color, sort_order) values
  ('va',          'VA',          '#1565C0', 10),
  ('private_pay', 'Private Pay', '#2E7D32', 20),
  ('ccals',       'CCALS',       '#6A1B9A', 30),
  ('summit',      'Summit',      '#EF6C00', 40),
  ('navicare',    'NaviCare',    '#00838F', 50),
  ('mass_health', 'MassHealth',  '#0277BD', 60),
  ('fallon',      'Fallon',      '#558B2F', 70)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------
-- RLS — the app authenticates with the ANON key only, so anon access is
-- load-bearing. Dropping it is what broke customer inserts once before
-- (see 20260724_customers_anon_rls.sql).
-- ---------------------------------------------------------------------------
alter table customer_addresses    enable row level security;
alter table event_customer_links  enable row level security;
alter table customer_tags         enable row level security;
alter table customer_tag_links    enable row level security;

drop policy if exists "anon full access" on customer_addresses;
create policy "anon full access" on customer_addresses
  for all to anon using (true) with check (true);

drop policy if exists "anon full access" on event_customer_links;
create policy "anon full access" on event_customer_links
  for all to anon using (true) with check (true);

drop policy if exists "anon read tags" on customer_tags;
create policy "anon read tags" on customer_tags
  for all to anon using (true) with check (true);

drop policy if exists "anon full access" on customer_tag_links;
create policy "anon full access" on customer_tag_links
  for all to anon using (true) with check (true);

-- ---------------------------------------------------------------------------
-- updated_at maintenance, matching the existing trigger style.
-- ---------------------------------------------------------------------------
create or replace function update_event_customer_links_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists event_customer_links_updated_at on event_customer_links;
create trigger event_customer_links_updated_at
  before update on event_customer_links
  for each row execute function update_event_customer_links_updated_at();

-- ---------------------------------------------------------------------------
-- VERIFY
--
--   -- all new objects exist
--   select table_name from information_schema.tables
--    where table_name in ('app_config','customer_addresses',
--                         'event_customer_links','customer_tags',
--                         'customer_tag_links');
--
--   -- generated column works (expect +15085551234)
--   insert into customers (name, phone) values ('Test', '(508) 555-1234')
--     returning name, phone, phone_e164;
--   delete from customers where name = 'Test';
--
--   -- new schedule_history columns present and empty for now
--   select count(*) as total,
--          count(customer_id) as linked
--     from schedule_history;
--
--   -- seeded tags
--   select slug, label from customer_tags order by sort_order;
-- ---------------------------------------------------------------------------
