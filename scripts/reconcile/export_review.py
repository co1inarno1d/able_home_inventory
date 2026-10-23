#!/usr/bin/env python3
"""
Write the review spreadsheet.

Produces one CSV of the clusters a human has to resolve, ordered so the most
valuable decisions come first. Open it in Excel or Sheets, fill in the
`decision` column, save as CSV, and hand it back.

DESIGN NOTES
`decision` is column A so the cursor lands there on open. Nothing else needs
editing. `y`/`n` covers the overwhelming majority of rows, so almost no typing
is required -- the ids are present but only needed for the rare manual
reassignment.

Rows are sorted by event count descending, because a household with 20 visits
carries twenty times the history of one with a single visit. Working top-down
means stopping halfway still captures most of the value.

Usage:
    python3 export_review.py              # writes work/review_<date>.csv
    python3 export_review.py --limit 300  # just the top N, for a first pass
"""

from __future__ import annotations

import argparse
import csv
import datetime
import json
import os
import sys

from cluster import build_households
from extract import extract_event

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")

COLUMNS = [
    "decision",          # <- the only column you edit
    "who",               # suggested customer name
    "address",
    "town",
    "phone",
    "visits",
    "first_visit",
    "last_visit",
    "question",          # what we need you to decide
    "other_names",
    "other_addresses",
    "other_phones",
    "agency",
    "agency_contact",
    "confidence",
    "cluster_id",        # internal; do not edit
    "note",              # free text, optional
]

DECISION_HELP = """\
How to fill in the `decision` column
====================================

Leave it BLANK to skip a row — nothing happens to it, and it comes back next
time. You can stop whenever you like.

  y            Yes, this is all one customer. Use the name in `who`.
  n            No, this is not one customer. Nothing is linked; the events
               stay unlinked and searchable in the schedule.
  <a name>     One customer, but the name is wrong — type the right one.
               e.g.  Philip Bourgeault
  split        These are separate households that got merged. Flagged for a
               closer look rather than guessed at.
  notacustomer Not a customer at all (our shop, a supplier, an internal note).

Anything unrecognised stops the import and tells you which row, so a typo
never silently does the wrong thing.
"""


def _load_events(path: str) -> list[dict]:
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


def _question_for(h) -> str:
    """Plain-language prompt for what needs deciding."""
    forms = h.distinct_name_forms
    if len(forms) > 1:
        surnames = {f.split()[-1].lower() for f in forms}
        if len(surnames) == 1:
            return f"Same family? ({' / '.join(forms[:4])})"
        return f"One household or several? ({' / '.join(forms[:4])})"
    if len(h.addresses) > 1 and not h._addresses_agree():
        return "Did they move, or are these different households?"
    if not h.names:
        return "No name in the schedule — who is this?"
    return "Weak evidence — is this one customer?"


def build_rows(households, limit: int | None = None) -> list[dict]:
    """Rows for every cluster a human must resolve, most valuable first."""
    needing = [h for h in households if h.triage in ("decide", "confirm_family")]
    needing.sort(key=lambda h: (-h.event_count, h.best_name))
    if limit:
        needing = needing[:limit]

    rows = []
    for h in needing:
        forms = h.distinct_name_forms
        addrs = [a for a, _ in h.addresses.most_common()]
        phones = [p for p, _ in h.phones.most_common()]
        rows.append(
            {
                "decision": "",
                "who": h.best_name,
                "address": addrs[0].replace("|", " ") if addrs else "",
                "town": h.cities.most_common(1)[0][0] if h.cities else "",
                "phone": phones[0] if phones else "",
                "visits": h.event_count,
                "first_visit": h.first_seen[:10],
                "last_visit": h.last_seen[:10],
                "question": _question_for(h),
                "other_names": " / ".join(f for f in forms if f != h.best_name),
                "other_addresses": " / ".join(
                    a.replace("|", " ") for a in addrs[1:4]
                ),
                "other_phones": " / ".join(phones[1:4]),
                "agency": h.best_agency,
                "agency_contact": h.agency_contact_list,
                "confidence": h.confidence,
                "cluster_id": h.cluster_id,
                "note": "",
            }
        )
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--events",
        default=os.path.join(WORK, "events.jsonl"),
        help="schedule_history rows as JSONL (default: work/events.jsonl)",
    )
    ap.add_argument("--limit", type=int, default=None,
                    help="only the top N rows, for a first pass")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if not os.path.exists(args.events):
        print(f"No event file at {args.events}", file=sys.stderr)
        print("Pull one with pull_sources.py, or pass --events.",
              file=sys.stderr)
        return 1

    rows_in = _load_events(args.events)
    sigs = [extract_event(r) for r in rows_in]
    households = build_households(sigs)
    rows = build_rows(households, args.limit)

    os.makedirs(WORK, exist_ok=True)
    stamp = datetime.date.today().isoformat()
    out = args.out or os.path.join(WORK, f"review_{stamp}.csv")
    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)

    help_path = os.path.join(WORK, "HOW_TO_FILL_IN.txt")
    with open(help_path, "w") as fh:
        fh.write(DECISION_HELP)

    # Report what was produced and what was handled without asking.
    counts: dict[str, int] = {}
    for h in households:
        counts[h.triage] = counts.get(h.triage, 0) + 1

    print(f"events            {len(rows_in)}")
    print(f"households        {len(households)}")
    print()
    print(f"  auto-accepted   {counts.get('accept', 0)}")
    print(f"  waiting on QB   {counts.get('await_qb', 0)}")
    print(f"  parked (thin)   {counts.get('thin', 0)}")
    print(f"  FOR YOU         {len(rows)}"
          f"  ({counts.get('confirm_family', 0)} quick family confirms,"
          f" {counts.get('decide', 0)} real decisions)")
    print()
    print(f"wrote {out}")
    print(f"      {help_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
