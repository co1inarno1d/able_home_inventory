-- Restore anon full access on the customers table.
--
-- 20260622_missing_schema.sql dropped the "anon full access" policy on
-- customers and left only "auth full access", but the app talks to Supabase
-- with the anon key (single shared-password auth model). That broke inserts
-- with: "new row violates row-level security policy for table customers".
--
-- This realigns customers with ops_jobs and customer_activities, which both
-- carry an "anon full access" policy.

drop policy if exists "anon full access" on customers;
create policy "anon full access" on customers
  for all to anon using (true) with check (true);
