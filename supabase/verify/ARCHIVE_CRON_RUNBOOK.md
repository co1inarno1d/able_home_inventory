# Fixing the schedule history gap

**Symptom:** searching the schedule finds recent jobs and a block of older
ones, but nothing in between.

**Cause:** the schedule lives in QuickBooks Time, not in this app's database.
Only the last ~7 days are readable live; anything older has to be copied into
the `schedule_history` table by a nightly job. **That nightly job was never
turned on.** The migration that registers it
(`supabase/migrations/20260810_schedule_archive_cron.sql`) shipped with a
placeholder where the key goes, so running it required a manual edit — and it
never got run. Nothing has been archived since the April 2026 backfill.

Two steps: turn the job on so the gap stops growing, then backfill what's
already missing.

---

## Step 1 — store the key (once)

Supabase Dashboard → **Project Settings → API → service_role**. Copy it.

Then in the **SQL Editor**, run this with your key pasted in:

```sql
select vault.create_secret(
  'eyJ...YOUR_SERVICE_ROLE_KEY...',
  'archive_schedule_service_key',
  'Service role key used by the nightly schedule archive cron'
);
```

This puts the key in Supabase Vault, so the cron can read it without the key
ever appearing in a file. **Don't commit the key anywhere.**

If you've already stored it before, replace it instead of adding a second one:

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'archive_schedule_service_key'),
  'eyJ...NEW_KEY...'
);
```

## Step 2 — register the nightly job

Paste the whole of
`supabase/migrations/20261022_schedule_archive_cron_vault.sql` into the SQL
Editor and run it. It's safe to re-run, and it will stop with a clear error if
Step 1 was skipped.

Confirm it registered:

```sql
select jobname, schedule, active from cron.job
 where jobname = 'archive-schedule-nightly';
```

Expect one row, `0 5 * * *`, `active = true`.

## Step 3 — confirm it actually ran

Check after 1 AM ET the next day. This matters: a job that's registered but
failing looks exactly like one that's working.

```sql
select status, return_message, start_time
  from cron.job_run_details
 where jobname = 'archive-schedule-nightly'
 order by start_time desc limit 5;

select max(start_time) as newest_event,
       current_date - max(start_time)::date as days_stale
  from schedule_history;
```

`days_stale` should be under about 7. If it hasn't moved, the job is firing but
the function is failing — check the edge function logs in the dashboard.

## Step 4 — backfill the existing gap

Once Step 3 is green:

```bash
export SUPABASE_SERVICE_ROLE_KEY="eyJ..."
./scripts/migrate_schedule_history.sh
```

This walks year by year from 2014. It's best-effort: only events still inside
QuickBooks Time's own retention can be recovered. Anything older than that is
gone regardless, which is the cost of the job having been off this long.

Re-running is safe — events are matched on their TSheets ID, so nothing
duplicates.

---

## Also worth doing

`supabase/functions/archive-schedule/index.ts` has a QuickBooks Time token
written directly into the source, which means it's in git history. It should be
rotated and moved to an environment variable.

## In the app

The schedule now shows an amber warning when history looks stale, on both
phone and desktop. It distinguishes "stopped archiving on <date>" from "no
archived history at all" — previously the empty case, the worst one, showed no
warning.
