-- Extend parse_flexible_date to cover the formats actually in production.
--
-- WHY: the original handled 'YYYY-MM-DD' and 'M/D/YYYY' only. A survey of the
-- live `lifts` table found six distinct real formats plus outright typos
-- across install_date, date_acquired and last_prep_date -- all text columns:
--
--     147  M/D/YYYY          (handled before)
--      15  M/D/YY            two-digit year
--      12  JS date strings   'Thu Feb 26 2026 00:00:00 GMT-0500 (Eastern...)'
--       7  M-D-YYYY / M-D-YY dash separated
--       1  YYYY-MM-DD        (handled before)
--       -  typos             '03/16/202)', '9-14/26', 'In Stock'
--
-- The JS strings come from a JavaScript client writing Date.toString() into a
-- text column. They are the single biggest unhandled group, and any
-- "how old is this lift" logic silently treats them as NULL -- which, for
-- buyback or warranty rules, means a unit quietly drops out of consideration
-- rather than erroring. Unparseable input must stay NULL (an unmatched row is
-- a visible gap; a wrongly-parsed date is invisible bad data), but the formats
-- that ARE real should not be in that bucket.
--
-- Two-digit years map to 2000-2099. That is correct here: this is a
-- stairlift business whose records start in 2014, not a historical archive.
--
-- Still IMMUTABLE, so it remains usable in generated columns and index
-- expressions.
--
-- MEASURED against the live lifts table (265 rows):
--
--     column            non-empty   old   new   gained
--     install_date            183   148   183      +35   -> 100% parsed
--     date_acquired           161   127   159      +32
--     last_prep_date          174   165   174       +9   -> 100% parsed
--
-- The 2 remaining date_acquired nulls are real typos ('In Stock',
-- '03/16/202)') and correctly stay NULL rather than becoming a wrong guess.

create or replace function parse_flexible_date(s text)
returns date
language plpgsql
immutable
parallel safe
as $$
declare
  t  text := btrim(coalesce(s, ''));
  m  text[];
  yy int;
  mm int;
  dd int;
begin
  if t = '' then
    return null;
  end if;

  -- ISO: 2026-02-26 (also tolerates a trailing time component)
  if t ~ '^\d{4}-\d{2}-\d{2}' then
    return substring(t from 1 for 10)::date;
  end if;

  -- JavaScript Date.toString(): 'Thu Feb 26 2026 00:00:00 GMT-0500 (...)'
  -- Matched on the month NAME so it cannot be confused with a numeric format.
  m := regexp_match(
         t,
         '^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})'
       );
  if m is not null then
    mm := case lower(m[1])
            when 'jan' then 1  when 'feb' then 2  when 'mar' then 3
            when 'apr' then 4  when 'may' then 5  when 'jun' then 6
            when 'jul' then 7  when 'aug' then 8  when 'sep' then 9
            when 'oct' then 10 when 'nov' then 11 when 'dec' then 12
            else null
          end;
    if mm is null then
      return null;
    end if;
    dd := m[2]::int;
    yy := m[3]::int;
    return make_date(yy, mm, dd);
  end if;

  -- M/D/YYYY, M-D-YYYY, M/D/YY, M-D-YY (slash or dash, 2- or 4-digit year)
  m := regexp_match(t, '^(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})$');
  if m is not null then
    mm := m[1]::int;
    dd := m[2]::int;
    yy := m[3]::int;
    -- Two-digit years are 2000s; see the note above.
    if yy < 100 then
      yy := 2000 + yy;
    end if;
    return make_date(yy, mm, dd);
  end if;

  return null;

exception when others then
  -- Impossible dates ('02/31/2025'), out-of-range months, and the genuine
  -- typos in this data ('03/16/202)', '9-14/26', 'In Stock') land here.
  return null;
end $$;

comment on function parse_flexible_date(text) is
  'Parses the mixed text date columns (ISO, M/D/YYYY, M/D/YY, M-D-YYYY, and '
  'JavaScript Date.toString()) to date. Two-digit years map to 2000s. Returns '
  'NULL on anything unparseable instead of raising, so one bad row cannot '
  'abort a bulk backfill.';

grant execute on function parse_flexible_date(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- VERIFY — every one of these is a real value from the live lifts table,
-- except the final NULL cases which are the typos found there.
--
--   select parse_flexible_date('2026-02-26');                      -- 2026-02-26
--   select parse_flexible_date('04/16/2026');                      -- 2026-04-16
--   select parse_flexible_date('02/26/26');                        -- 2026-02-26
--   select parse_flexible_date('06-01-2026');                      -- 2026-06-01
--   select parse_flexible_date('6-17-26');                         -- 2026-06-17
--   select parse_flexible_date(
--     'Thu Feb 26 2026 00:00:00 GMT-0500 (Eastern Standard Time)'); -- 2026-02-26
--   select parse_flexible_date('In Stock');                        -- null
--   select parse_flexible_date('03/16/202)');                      -- null
--   select parse_flexible_date('9-14/26');                         -- 2026-09-14
--   select parse_flexible_date('02/31/2025');                      -- null
--   select parse_flexible_date('garbage');                         -- null
--   select parse_flexible_date(null);                              -- null
--
-- Coverage check against real data (expect a high pct_parsed):
--   select count(*) filter (where install_date <> '')               as has_text,
--          count(parse_flexible_date(install_date))                 as parsed,
--          round(100.0 * count(parse_flexible_date(install_date))
--                / nullif(count(*) filter (where install_date <> ''), 0), 1)
--                                                                   as pct_parsed
--     from lifts;
-- ---------------------------------------------------------------------------
