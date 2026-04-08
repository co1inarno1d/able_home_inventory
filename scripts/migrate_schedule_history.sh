#!/usr/bin/env bash
# =============================================================================
# migrate_schedule_history.sh
#
# One-time full backfill of TSheets schedule events into the Supabase
# `schedule_history` table. Calls the archive-schedule edge function
# year-by-year so each request stays well within timeout limits.
#
# USAGE:
#   1. Set your Supabase service role key (Project Settings → API):
#        export SUPABASE_SERVICE_ROLE_KEY="eyJ..."
#
#   2. Run:
#        chmod +x scripts/migrate_schedule_history.sh
#        ./scripts/migrate_schedule_history.sh
#
#   Safe to re-run — the edge function upserts by TSheets event ID,
#   so no duplicates will be created.
# =============================================================================

set -euo pipefail

FUNCTION_URL="https://kaujczbhtajqfrjgbxft.supabase.co/functions/v1/archive-schedule"

# ---------------------------------------------------------------------------
# Change START_YEAR to the earliest year you have TSheets data.
# The script will archive from Jan 1 of that year up to 7 days ago.
# ---------------------------------------------------------------------------
START_YEAR=2019

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  echo "ERROR: SUPABASE_SERVICE_ROLE_KEY is not set."
  echo "  Export it first:  export SUPABASE_SERVICE_ROLE_KEY=\"eyJ...\""
  exit 1
fi

# End date = 7 days ago (keep last 7 days in the live TSheets window)
END_DATE=$(date -v -7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)
END_YEAR=$(echo "$END_DATE" | cut -d- -f1)

echo "================================================"
echo "  Able Home — Schedule History Migration"
echo "  Range: $START_YEAR-01-01 → $END_DATE"
echo "  Calling: $FUNCTION_URL"
echo "================================================"
echo ""

TOTAL_ARCHIVED=0

for (( year=START_YEAR; year<=END_YEAR; year++ )); do
  # For the final year, cap end at END_DATE
  if [ "$year" -eq "$END_YEAR" ]; then
    range_end="$END_DATE"
  else
    range_end="${year}-12-31"
  fi
  range_start="${year}-01-01"

  echo -n "  Archiving $range_start → $range_end ... "

  response=$(curl -sf \
    -X POST \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    "${FUNCTION_URL}?start=${range_start}&end=${range_end}" \
  )

  # Parse the "archived" count from the JSON response
  count=$(echo "$response" | grep -o '"archived":[0-9]*' | grep -o '[0-9]*' || echo "?")
  error=$(echo "$response" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "")

  if [ -n "$error" ]; then
    echo "ERROR: $error"
    echo "  Full response: $response"
    echo ""
    echo "Migration stopped. Fix the error and re-run — progress is saved."
    exit 1
  fi

  echo "archived $count events"

  if [[ "$count" =~ ^[0-9]+$ ]]; then
    TOTAL_ARCHIVED=$((TOTAL_ARCHIVED + count))
  fi

  # Brief pause to be polite to both APIs
  sleep 1
done

echo ""
echo "================================================"
echo "  Done! Total events archived: $TOTAL_ARCHIVED"
echo "================================================"
