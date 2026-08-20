-- Nightly cron: archive aged-out TSheets events into schedule_history.
--
-- WHY: the archive-schedule edge function was written to run nightly, but the
-- cron that calls it was never registered (it sat commented out in schema.sql).
-- As a result nothing has been archived since the April 2026 backfill, and any
-- event older than the 7-day live window but newer than that backfill is
-- invisible to schedule search. Registering this cron stops the gap from
-- growing; a one-time backfill (scripts/migrate_schedule_history.sh) closes the
-- existing gap.
--
-- Requires the pg_cron and pg_net extensions (enabled in Supabase by default).
--
-- !! BEFORE RUNNING: replace <SERVICE_ROLE_KEY> below with the project's real
--    service role key (Project Settings -> API). The key is intentionally NOT
--    committed. Run this once in the Supabase SQL Editor.
--
-- Verify:  select * from cron.job;
-- Remove:  select cron.unschedule('archive-schedule-nightly');

-- Idempotent: drop any existing registration first so re-running is safe.
select cron.unschedule('archive-schedule-nightly')
where exists (select 1 from cron.job where jobname = 'archive-schedule-nightly');

select cron.schedule(
  'archive-schedule-nightly',
  '0 5 * * *',  -- 5:00 AM UTC daily (1 AM ET)
  $$
  select net.http_post(
    url := 'https://kaujczbhtajqfrjgbxft.supabase.co/functions/v1/archive-schedule',
    headers := '{"Authorization": "Bearer <SERVICE_ROLE_KEY>", "Content-Type": "application/json"}'::jsonb
  )
  $$
);
