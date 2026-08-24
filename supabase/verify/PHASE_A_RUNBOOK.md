# Phase A Runbook

Four things to run against the live database. Everything else in Phase A is code
and is already committed.

Two of these need the service-role key pasted in by hand, which is exactly why
the schedule archive cron has never run — the migration that registers it has
carried a `<SERVICE_ROLE_KEY>` placeholder since it was written, and a migration
you can't apply unattended is a migration that doesn't get applied.

Get the key from **Supabase Dashboard → Project Settings → API → service_role**.
Never commit it.

---

## 1. Run the verification script

Paste `supabase/verify/phase_a_verification.sql` into the **SQL Editor** and run
it top to bottom. It only reads; it changes nothing.

Send me the output. What I'm looking for:

| Check | Good result | If it's bad |
|---|---|---|
| §1 anon row counts | non-zero, matching the privileged counts | **Stop.** Every job metric would silently read zero rows. Fix RLS before anything else. |
| §2 enum drift | values match the documented sets | Unexpected values get handled in `norm_status()` — tell me what showed up |
| §3 cron | `archive-schedule-nightly`, `active = true` | Run step 3 below |
| §4 schedule gap | `days_stale` under ~7 | Confirms the gap; step 3 stops it growing, step 4 closes it |
| §7 install history | non-zero `install_events_logged` | This is the free win — installs/month back to inception |
| §9 QB linkage | high `pct_linked` | Low means revenue attribution leans on fuzzy name matching |

Sections 5–10 are informational and shape later phases — no action needed now.

---

## 2. Apply the helpers migration

`supabase/migrations/20260824_metrics_helpers.sql` adds three functions —
`norm_status`, `normalize_e164`, `parse_flexible_date`. No tables are touched
and nothing is dropped.

Either paste it into the SQL Editor, or if the CLI is authenticated
(`supabase login`) run:

```bash
supabase db push
```

Verify:

```sql
select norm_status('  Completed ');        -- 'completed'
select normalize_e164('(508) 555-1234');   -- '+15085551234'
select parse_flexible_date('3/7/2025');    -- 2025-03-07
select parse_flexible_date('garbage');     -- null (must not error)
```

---

## 3. Register the schedule archive cron

**This is the one that's been broken.** `schedule_history` stops receiving data
past the 7-day TSheets window without it, and the gap widens every day.

Open `supabase/migrations/20260810_schedule_archive_cron.sql`, replace
`<SERVICE_ROLE_KEY>` with the real key, and run it in the SQL Editor. It's
idempotent — it unschedules any existing registration first, so re-running is
safe.

Verify:

```sql
select jobname, schedule, active from cron.job;
```

You want `archive-schedule-nightly`, `0 5 * * *`, `active = true`. Check again
tomorrow that `max(start_time)` in `schedule_history` has moved:

```sql
select max(start_time), current_date - max(start_time)::date as days_stale
from schedule_history;
```

If it hasn't, the cron is registered but the function is failing — check
`cron.job_run_details` and the edge function logs.

---

## 4. Backfill the existing gap (optional, after step 3)

Step 3 stops the gap growing. `scripts/migrate_schedule_history.sh` closes what's
already there — but only for events still inside TSheets' retention. Anything
older than that window is gone regardless, so this is best-effort.

Worth doing because `schedule_history` is the second-best time series in the
system and Phase D's completion backfill joins against it. Every unmatched
completion falls back to "when someone ticked the box" rather than when the work
happened, and gets tagged low-confidence.

---

## What's already done in code

- `dart:html` removed from `lib/integrations/quickbooks_service.dart` — the OAuth
  CSRF token now goes through `SharedPreferences`. This was the only thing
  pinning the app to web, so iOS/Android builds are now viable. The PWA is still
  the plan for field use; this just removes the wall.
- Photo uploads now compress on **web as well as native**
  (`lib/supabase_api.dart`, both `sbUploadLiftPhoto` and `sbUploadEventPhoto`).
  The web path previously uploaded raw camera bytes — 3–8 MB per photo. Now
  ~200–400 KB. This is a prerequisite for the forced-photo step in the tech
  flow: on weak basement LTE, raw upload is the difference between three seconds
  and forty-five, and techs abandon flows that stall.
- Both changes verified with `flutter analyze` — same 6 pre-existing issues
  before and after, none introduced.

## Next

Phase A closes when steps 1–3 are green. Then the fork:

- **Phase E (Quo)** — highest value per effort, and time-sensitive. There's no
  bulk call-history endpoint, so phone-lead data only exists from the day the
  webhook goes live. Every week of delay is permanently lost data.
- **Phase B** — `job_assignments`, the event-capture spine the tech flow needs.

These are independent and can run in either order.
