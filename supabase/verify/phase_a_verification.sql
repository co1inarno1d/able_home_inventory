-- ===========================================================================
-- PHASE A VERIFICATION — run this in the Supabase SQL Editor before building.
--
-- This script only READS. It changes nothing. Run it top to bottom and read
-- the NOTICE output; each section says what a good result looks like.
--
-- Why this exists: several assumptions underpin the whole metrics plan, and
-- all of them are cheap to check and expensive to get wrong. A dashboard that
-- silently aggregates zero rows is worse than no dashboard.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. RLS — can the anon key actually read the core tables?
--
-- The app talks to Supabase with the ANON key and auth is currently bypassed,
-- so there is no `authenticated` JWT. Migration 20260622_missing_schema.sql
-- dropped anon access on ops_jobs and user_profiles. 20260612_full_schema.sql
-- appears to recreate it (line 56), but filename ordering vs. actual apply
-- order is not something to trust — verify empirically.
--
-- GOOD RESULT: every table below shows a policy with roles containing 'anon'.
-- ---------------------------------------------------------------------------

select tablename,
       policyname,
       roles::text  as applies_to_roles,
       cmd          as command,
       qual::text   as using_clause
from pg_policies
where schemaname = 'public'
  and tablename in ('ops_jobs','customers','user_profiles','lifts',
                    'lift_history','customer_activities','app_config',
                    'web_leads','inventory_changes','schedule_history',
                    'service_jobs','removal_jobs','annuals')
order by tablename, policyname;


-- The ground-truth test: impersonate anon and count rows.
-- GOOD RESULT: non-zero counts (assuming the tables have data).
-- A zero on ops_jobs is the single most dangerous outcome — it means every
-- job metric would compute cleanly and be completely wrong.
do $$
declare
  r record;
  n bigint;
  tbls text[] := array['ops_jobs','customers','lifts','lift_history',
                       'app_config','web_leads','customer_activities',
                       'inventory_changes','schedule_history'];
  t text;
begin
  raise notice '--- Row counts as ANON ---';
  set local role anon;
  foreach t in array tbls loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      raise notice '  anon sees %: % rows', rpad(t, 22), n;
    exception when others then
      raise notice '  anon sees %: BLOCKED (%)', rpad(t, 22), sqlerrm;
    end;
  end loop;
  reset role;
end $$;

-- Compare against the true counts (as the privileged role you're running as).
-- GOOD RESULT: these match the anon numbers above.
select 'ops_jobs' as tbl, count(*) from ops_jobs
union all select 'customers',          count(*) from customers
union all select 'lifts',              count(*) from lifts
union all select 'lift_history',       count(*) from lift_history
union all select 'app_config',         count(*) from app_config
union all select 'web_leads',          count(*) from web_leads
union all select 'customer_activities',count(*) from customer_activities
union all select 'schedule_history',   count(*) from schedule_history
order by 1;


-- ---------------------------------------------------------------------------
-- 2. ENUM DRIFT — the schema has ZERO check constraints and ZERO native enums.
--
-- Every "enum" is a bare text column whose allowed values live only in SQL
-- comments and Dart switch statements. Expect casing variants, empty strings,
-- and values nobody remembers adding.
--
-- GOOD RESULT: values match the documented sets below. Anything unexpected
-- must be handled by norm_status() before it reaches a metric.
--
-- Documented sets:
--   ops_jobs.job_type   stairlift_install | stairlift_removal | buyback |
--                       stairlift_service | ramp_install | ramp_removal |
--                       annual_service | web_lead
--   ops_jobs.status     needs_info | waiting_agency_confirmation |
--                       ready_to_schedule | scheduled | completed
--   customers.lifecycle_status  new_lead | contacted | eval_scheduled |
--                       quoted | won | active | past | dormant | lost
--   lifts.status        New | Assigned | Installed | Removed | Scrapped
-- ---------------------------------------------------------------------------

select 'ops_jobs.status' as col, coalesce(nullif(status,''),'(empty)') as value, count(*)
  from ops_jobs group by 2
union all
select 'ops_jobs.job_type', coalesce(nullif(job_type,''),'(empty)'), count(*)
  from ops_jobs group by 2
union all
select 'ops_jobs.funding_source', coalesce(nullif(funding_source,''),'(empty)'), count(*)
  from ops_jobs group by 2
union all
select 'customers.lifecycle_status', coalesce(nullif(lifecycle_status,''),'(empty)'), count(*)
  from customers group by 2
union all
select 'lifts.status', coalesce(nullif(status,''),'(empty)'), count(*)
  from lifts group by 2
union all
select 'lifts.condition', coalesce(nullif(condition,''),'(empty)'), count(*)
  from lifts group by 2
union all
select 'lifts.acquisition_source', coalesce(nullif(acquisition_source,''),'(empty)'), count(*)
  from lifts group by 2
order by 1, 3 desc;


-- ---------------------------------------------------------------------------
-- 3. CRON — is the schedule archive job actually registered?
--
-- 20260810_schedule_archive_cron.sql requires a hand-pasted service-role key,
-- and its own header says so. If it was never run, schedule_history has been
-- accumulating a gap since the April 2026 backfill, and that gap widens daily.
--
-- GOOD RESULT: a row named 'archive-schedule-nightly' with active = true.
-- If the table doesn't exist, pg_cron isn't installed.
-- ---------------------------------------------------------------------------

select extname, extversion from pg_extension where extname in ('pg_cron','pg_net','pg_trgm');

do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema='cron' and table_name='job') then
    raise notice '--- pg_cron jobs ---';
  else
    raise notice 'pg_cron is NOT installed — no scheduled jobs exist.';
  end if;
end $$;

select jobid, jobname, schedule, active, command
from cron.job
order by jobname;


-- ---------------------------------------------------------------------------
-- 4. THE SCHEDULE_HISTORY GAP — how bad is it?
--
-- GOOD RESULT: max(start_time) is within the last ~7 days.
-- If it's months old, the archive cron never ran and live TSheets events are
-- vanishing past the 7-day API window rather than being archived.
-- ---------------------------------------------------------------------------

select count(*)                        as total_events,
       min(start_time)::date           as earliest,
       max(start_time)::date           as latest,
       current_date - max(start_time)::date as days_stale,
       count(*) filter (where start_time > now() - interval '30 days') as last_30d
from schedule_history;

-- Monthly coverage — makes any gap visually obvious.
select date_trunc('month', start_time)::date as month, count(*) as events
from schedule_history
group by 1 order by 1 desc limit 24;


-- ---------------------------------------------------------------------------
-- 5. TABLES WITH NO MIGRATION FILE
--
-- app_config, web_leads, schedule_history, and inventory_changes exist only in
-- the live DB — there is no DDL for them in the repo. Any migration touching
-- them must be written defensively against their ACTUAL shape, so dump it.
-- ---------------------------------------------------------------------------

select table_name, ordinal_position, column_name, data_type,
       is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in ('app_config','web_leads','schedule_history','inventory_changes')
order by table_name, ordinal_position;


-- ---------------------------------------------------------------------------
-- 6. app_config KEY SHAPE — this EAV table holds the ONLY record that a
-- scheduled job was completed (`completed_event_<id>` = 'true'). Phase D's
-- completion backfill depends on it.
--
-- GOOD RESULT: a meaningful count of completed_event_ keys.
-- ---------------------------------------------------------------------------

select split_part(key, '_', 1) || '_' || split_part(key, '_', 2) as key_prefix,
       count(*)
from app_config
group by 1
order by 2 desc;

-- How many completions can be matched to an archived schedule event?
-- Unmatched ones fall in the archive gap: their only date is when someone
-- ticked the box, not when the work happened. They get confidence='low'.
select count(*)                                    as completed_flags,
       count(sh.tsheets_id)                        as matchable_to_schedule,
       count(*) - count(sh.tsheets_id)             as unmatchable_low_confidence
from app_config c
left join schedule_history sh
       on sh.tsheets_id = replace(c.key, 'completed_event_', '')
where c.key like 'completed_event_%' and c.value = 'true';


-- ---------------------------------------------------------------------------
-- 7. BACKFILL FEASIBILITY — how much history is actually recoverable?
--
-- The plan's biggest free win: install events are ALREADY in lift_history with
-- real timestamps. This quantifies that claim.
-- ---------------------------------------------------------------------------

-- Install transitions already logged. These need no backfill — just a query.
select count(*)                          as install_events_logged,
       count(distinct lift_id)           as distinct_lifts,
       min(timestamp)::date              as earliest_install,
       max(timestamp)::date              as latest_install
from lift_history
where lower(btrim(coalesce(to_status,''))) = 'installed';

-- Monthly install history that becomes available immediately.
select date_trunc('month', timestamp)::date as month, count(*) as installs
from lift_history
where lower(btrim(coalesce(to_status,''))) = 'installed'
group by 1 order by 1 desc limit 24;

-- lifts.install_date is TEXT in mixed formats. How parseable is it?
-- GOOD RESULT: 'iso' + 'us_slash' account for nearly all non-empty values.
select case
         when coalesce(btrim(install_date),'') = '' then '(empty)'
         when install_date ~ '^\d{4}-\d{2}-\d{2}'   then 'iso (YYYY-MM-DD)'
         when install_date ~ '^\d{1,2}/\d{1,2}/\d{4}$' then 'us_slash (M/D/YYYY)'
         else 'UNPARSEABLE'
       end as format,
       count(*)
from lifts
group by 1 order by 2 desc;

-- Show the unparseable ones so they can be fixed by hand if few.
select lift_id, install_date
from lifts
where coalesce(btrim(install_date),'') <> ''
  and install_date !~ '^\d{4}-\d{2}-\d{2}'
  and install_date !~ '^\d{1,2}/\d{1,2}/\d{4}$'
limit 50;

-- Buyback cost basis — the one place real margin is computable.
select count(*)                                        as buyback_lifts,
       count(buyback_price)                            as with_price,
       sum(buyback_price)                              as total_capital,
       count(*) filter (where status = 'Installed')    as resold,
       count(*) filter (where status <> 'Installed')   as in_inventory
from lifts
where lower(coalesce(acquisition_source,'')) = 'buyback';


-- ---------------------------------------------------------------------------
-- 8. PHONE DATA QUALITY — Phase E matches Quo calls to customers by phone.
-- customers.phone is free text with no formatting discipline.
--
-- GOOD RESULT: most rows land in 10-digit or 11-digit. Anything else won't
-- match an inbound call until cleaned.
-- ---------------------------------------------------------------------------

select case
         when coalesce(btrim(phone),'') = '' then '(empty)'
         when length(regexp_replace(phone, '\D', '', 'g')) = 10 then '10 digits'
         when length(regexp_replace(phone, '\D', '', 'g')) = 11 then '11 digits'
         when length(regexp_replace(phone, '\D', '', 'g')) < 10 then 'TOO SHORT'
         else 'other / has extension'
       end as phone_shape,
       count(*)
from customers
group by 1 order by 2 desc;

-- Duplicate phone numbers would make call→customer matching ambiguous.
-- GOOD RESULT: few or no rows.
select regexp_replace(phone, '\D', '', 'g') as digits,
       count(*) as customer_count,
       string_agg(name, ' | ' order by name) as customers
from customers
where length(regexp_replace(phone, '\D', '', 'g')) >= 10
group by 1 having count(*) > 1
order by 2 desc limit 25;


-- ---------------------------------------------------------------------------
-- 9. QUICKBOOKS LINKAGE — qb_customer_id is the ONLY bridge between a job and
-- its revenue. Attribution coverage is capped by how many customers have one.
--
-- GOOD RESULT: a high linked percentage. A low one means Phase F's revenue
-- attribution will lean heavily on fuzzy name matching.
-- ---------------------------------------------------------------------------

select count(*)                                                as total_customers,
       count(*) filter (where coalesce(btrim(qb_customer_id),'') <> '') as linked_to_qb,
       round(100.0 * count(*) filter (where coalesce(btrim(qb_customer_id),'') <> '')
             / nullif(count(*),0), 1)                          as pct_linked
from customers;

-- ops_jobs.customer_id is nullable and inconsistently backfilled; jobs without
-- it can only be matched by fuzzy customer_name (tier 4).
select count(*)                                      as total_jobs,
       count(customer_id)                            as with_customer_fk,
       count(*) - count(customer_id)                 as name_only,
       round(100.0 * count(customer_id) / nullif(count(*),0), 1) as pct_linked
from ops_jobs;


-- ---------------------------------------------------------------------------
-- 10. QB TOKEN HEALTH — every dashboard revenue number depends on this.
-- GOOD RESULT: one row, expires_at in the future (or refreshable).
-- ---------------------------------------------------------------------------

select realm_id,
       expires_at,
       expires_at > now() as access_token_valid,
       updated_at
from qb_tokens;
