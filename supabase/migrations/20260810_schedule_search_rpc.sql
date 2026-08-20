-- Full-text search over schedule_history, index-backed.
--
-- WHY: sbSearchScheduleHistory used per-term ILIKE '%term%' which cannot use
-- the existing GIN full-text index (schedule_history_fts_idx) and capped at 200
-- rows. This RPC matches with the SAME to_tsvector expression the index is built
-- on, so the planner uses the index — fast, thorough search with a higher cap.
-- The Dart layer keeps an ILIKE fallback for short/partial (substring) terms.

create or replace function search_schedule_history(
  q         text,
  start_ts  timestamptz default null,
  end_ts    timestamptz default null,
  max_rows  int default 1000
)
returns setof schedule_history
language sql
stable
security definer
set search_path = public
as $$
  select *
  from schedule_history
  where
    to_tsvector('english',
      coalesce(title, '') || ' ' ||
      coalesce(notes, '') || ' ' ||
      coalesce(location, '') || ' ' ||
      coalesce(assigned_user_names, '')
    ) @@ websearch_to_tsquery('english', q)
    and (start_ts is null or start_time >= start_ts)
    and (end_ts   is null or start_time <= end_ts)
  order by start_time desc
  limit max_rows;
$$;

-- Match the single-shared-password (anon key) access model used elsewhere.
grant execute on function search_schedule_history(text, timestamptz, timestamptz, int) to anon;
