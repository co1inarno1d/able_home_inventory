-- Nightly cron: archive aged-out TSheets events into schedule_history.
--
-- WHY THIS SUPERSEDES 20260810_schedule_archive_cron.sql:
-- That migration was correct but carried a literal <SERVICE_ROLE_KEY>
-- placeholder that had to be hand-substituted before running. It never got
-- run. As the runbook put it: a migration you can't apply unattended is a
-- migration that doesn't get applied. The consequence is that nothing has
-- been archived since the April 2026 backfill, so every event older than the
-- 7-day live TSheets window but newer than that backfill exists in neither
-- place and is invisible to schedule search.
--
-- This version reads the key from Supabase Vault instead of inlining it, so
-- the SQL is safe to commit, safe to re-run, and contains no secret.
--
-- Requires pg_cron and pg_net (enabled by default on Supabase).
--
-- ===========================================================================
-- STEP 1 — store the service role key once (Project Settings -> API ->
--          service_role). Run this separately and do NOT commit the key.
--
--   select vault.create_secret(
--     'eyJ...PASTE_SERVICE_ROLE_KEY_HERE...',
--     'archive_schedule_service_key',
--     'Service role key used by the nightly schedule archive cron'
--   );
--
-- To rotate later, replace it rather than creating a duplicate:
--   select vault.update_secret(
--     (select id from vault.secrets where name = 'archive_schedule_service_key'),
--     'eyJ...NEW_KEY...'
--   );
--
-- STEP 2 — run everything below. It is idempotent.
-- ===========================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Fail loudly and early if step 1 was skipped, rather than registering a cron
-- that 401s silently every night for months.
do $$
begin
  if not exists (
    select 1 from vault.decrypted_secrets
     where name = 'archive_schedule_service_key'
       and coalesce(decrypted_secret, '') <> ''
  ) then
    raise exception
      'Vault secret "archive_schedule_service_key" is missing or empty. Run STEP 1 in the header first.';
  end if;
end $$;

-- Idempotent: drop any existing registration so re-running is safe.
select cron.unschedule('archive-schedule-nightly')
where exists (select 1 from cron.job where jobname = 'archive-schedule-nightly');

select cron.schedule(
  'archive-schedule-nightly',
  '0 5 * * *',  -- 05:00 UTC daily (1 AM ET)
  $cron$
  select net.http_post(
    url := 'https://kaujczbhtajqfrjgbxft.supabase.co/functions/v1/archive-schedule',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
         where name = 'archive_schedule_service_key'
      ),
      'Content-Type', 'application/json'
    )
  )
  $cron$
);

-- ===========================================================================
-- VERIFY
--
-- 1. The job is registered and active:
--      select jobname, schedule, active from cron.job
--       where jobname = 'archive-schedule-nightly';
--    Expect one row: '0 5 * * *', active = true.
--
-- 2. After the next 05:00 UTC run, confirm it actually succeeded. A registered
--    cron that fails looks identical to one that works, so check both:
--      select status, return_message, start_time
--        from cron.job_run_details
--       where jobname = 'archive-schedule-nightly'
--       order by start_time desc limit 5;
--
--      select max(start_time) as newest_event,
--             current_date - max(start_time)::date as days_stale
--        from schedule_history;
--    days_stale should sit under ~7. If it has not moved, the cron is firing
--    but the function is failing — check the edge function logs.
--
-- 3. Close the pre-existing gap (once, after the above is green):
--      ./scripts/migrate_schedule_history.sh
--    Best-effort: only events still inside TSheets' retention can be
--    recovered.
--
-- Remove:  select cron.unschedule('archive-schedule-nightly');
-- ===========================================================================
