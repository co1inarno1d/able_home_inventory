-- Shared normalization helpers for the metrics platform.
--
-- WHY: this schema has ZERO check constraints and ZERO native enum types.
-- Every "enum" is a bare text column whose allowed values live only in SQL
-- comments and Dart switch statements, so production contains casing variants
-- ('Completed' vs 'completed'), empty strings, and stray whitespace. Likewise
-- every phone number is free text: '(508) 555-1234', '508-555-1234',
-- '5085551234' and '+15085551234' all refer to the same person.
--
-- Aggregating over those columns raw produces silently wrong numbers — a
-- GROUP BY that splits one status into three buckets looks like data, not a
-- bug. Every view and RPC in the metrics layer routes status comparisons
-- through norm_status() and phone comparisons through normalize_e164().
--
-- Deliberately NOT adding check constraints: they would reject existing rows
-- and break writes mid-flight. Normalize on read instead, and let the Phase A
-- verification script surface whatever drift actually exists.
--
-- Both functions are IMMUTABLE so they can be used in generated columns,
-- index expressions, and query plans without re-evaluation.

-- ---------------------------------------------------------------------------
-- norm_status — canonical form of any status/enum-ish text column.
-- Lowercases, trims, and collapses empty string to NULL so that a missing
-- value is never confused with a real one.
--   norm_status('  Completed ') -> 'completed'
--   norm_status('')             -> null
--   norm_status(null)           -> null
-- ---------------------------------------------------------------------------
create or replace function norm_status(s text)
returns text
language sql
immutable
parallel safe
as $$
  select nullif(lower(btrim(coalesce(s, ''))), '')
$$;

comment on function norm_status(text) is
  'Canonical lowercase/trimmed form of a free-text status column; empty -> NULL. '
  'Use in every metrics view/RPC — the schema has no check constraints, so '
  'casing and whitespace drift is expected in production data.';

-- ---------------------------------------------------------------------------
-- normalize_e164 — best-effort E.164 phone normalization for matching.
--
-- Strips every non-digit, then interprets by length:
--   10 digits           -> +1XXXXXXXXXX   (US, no country code)
--   11 digits, leading 1-> +1XXXXXXXXXX   (US, with country code)
--   11-15 digits        -> +<digits>      (assume already international)
--   anything shorter    -> NULL           (unusable for matching)
--
-- Returning NULL rather than a garbage value is deliberate: an unmatched call
-- is a visible gap, while a wrongly-matched call silently attaches a
-- conversation to the wrong customer.
--
-- Note this drops extensions ('555-1234 x2' -> the base number), which is
-- correct for caller matching since inbound calls never carry an extension.
-- ---------------------------------------------------------------------------
create or replace function normalize_e164(p text)
returns text
language sql
immutable
parallel safe
as $$
  select case
    when d is null or length(d) < 10 then null
    when length(d) = 10 then '+1' || d
    when length(d) = 11 and left(d, 1) = '1' then '+' || d
    when length(d) between 11 and 15 then '+' || d
    else null
  end
  from (
    select nullif(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '') as d
  ) t
$$;

comment on function normalize_e164(text) is
  'Best-effort E.164 normalization of a free-text phone number for matching. '
  'Returns NULL when the input cannot yield a usable number — an unmatched '
  'call is better than a mismatched one.';

-- ---------------------------------------------------------------------------
-- parse_flexible_date — text -> date for the mixed-format legacy columns.
--
-- lifts.install_date, lifts.date_acquired, lifts.last_prep_date and the
-- service_jobs/removal_jobs date columns are all TEXT holding a mix of
-- 'YYYY-MM-DD' and 'M/D/YYYY'. Anything else returns NULL rather than raising,
-- so a single malformed row can't abort a backfill over thousands.
-- ---------------------------------------------------------------------------
create or replace function parse_flexible_date(s text)
returns date
language plpgsql
immutable
parallel safe
as $$
declare
  t text := btrim(coalesce(s, ''));
begin
  if t = '' then
    return null;
  elsif t ~ '^\d{4}-\d{2}-\d{2}' then
    return substring(t from 1 for 10)::date;
  elsif t ~ '^\d{1,2}/\d{1,2}/\d{4}$' then
    return to_date(t, 'FMMM/FMDD/YYYY');
  end if;
  return null;
exception when others then
  -- Impossible dates like '02/31/2025' land here.
  return null;
end $$;

comment on function parse_flexible_date(text) is
  'Parses the mixed YYYY-MM-DD / M/D/YYYY text date columns to date. Returns '
  'NULL on anything unparseable instead of raising, so one bad row cannot '
  'abort a bulk backfill.';

grant execute on function norm_status(text)        to anon, authenticated;
grant execute on function normalize_e164(text)     to anon, authenticated;
grant execute on function parse_flexible_date(text) to anon, authenticated;
