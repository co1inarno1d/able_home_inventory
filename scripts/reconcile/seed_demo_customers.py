#!/usr/bin/env python3
"""
Seed real customer records into the customers table.

PURPOSE
The Customers tab is built but has nothing to show -- one record, whose city
field holds a whole street address. This inserts genuine households taken from
the highest-confidence clusters so the tab can be demonstrated with real data
rather than invented names.

SAFETY
  * Only clusters triaged `accept` with confidence >= 0.9, and only those with
    a name, an address, a phone AND a town. These are the clusters with one
    consistent identity across every event -- no conflicting names, no
    conflicting addresses.
  * Skips any customer whose name already exists, so re-running does not
    create duplicates.
  * --dry-run by default. Nothing is written without --write.

This is a convenience for the demo, not the migration. The real import
(apply_review.py) also records the per-event links and the crosswalk; this
only creates customer rows so the tab has content.

Usage:
    python3 seed_demo_customers.py                 # preview 25
    python3 seed_demo_customers.py --limit 100     # preview 100
    python3 seed_demo_customers.py --limit 100 --write
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

from cluster import build_households
from extract import extract_event

SUPABASE_URL = "https://kaujczbhtajqfrjgbxft.supabase.co"
# The anon key is already embedded in the Flutter client; this is the same
# public key, and customers has anon full access by policy.
ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImthdWpjemJodGFqcWZyamdieGZ0Iiwicm9sZSI6"
    "ImFub24iLCJpYXQiOjE3NzE0NDI3NjYsImV4cCI6MjA4NzAxODc2Nn0."
    "WbxeNDGKlOVEy7_2F_VBoa0oRv0JHqK1NdpP1G6LDbk"
)

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")

# Agency name -> the funding_source value the app already understands.
_AGENCY_TO_FUNDING = {
    "VA": "VA",
    "CCALS": "CCALS",
    "NaviCare": "NaviCare",
    "Summit": "Summit",
    "Fallon": "Fallon",
    "Mass Health": "Mass Health",
}


def _request(method: str, path: str, body=None, extra_headers=None):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {
        "apikey": ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
        "Content-Type": "application/json",
    }
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else []
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} on {method} {path}: {e.read().decode()[:400]}",
              file=sys.stderr)
        raise


def title_case_town(t: str) -> str:
    """'north brookfield' -> 'North Brookfield'."""
    return " ".join(w.capitalize() for w in t.split())


def pretty_address(street_key: str, town: str) -> str:
    """Rebuild a human-readable address from the grouping key."""
    parts = street_key.split("|")
    if len(parts) < 2:
        return street_key
    house, street = parts[0], parts[1]
    street = " ".join(w.capitalize() for w in street.split())
    addr = f"{house} {street}".strip()
    if town:
        addr = f"{addr}, {title_case_town(town)}"
    return addr


def candidates(households, limit: int):
    """The households safe enough to seed, most-visited first."""
    out = []
    for h in households:
        if h.triage != "accept" or h.confidence < 0.9:
            continue
        if not (h.names and h.addresses and h.phones and h.cities):
            continue
        out.append(h)
    out.sort(key=lambda h: -h.event_count)
    return out[:limit]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", default=os.path.join(WORK, "events.jsonl"))
    ap.add_argument("--limit", type=int, default=25)
    ap.add_argument("--write", action="store_true",
                    help="actually insert (default is a preview)")
    args = ap.parse_args()

    if not os.path.exists(args.events):
        print(f"No event file at {args.events}", file=sys.stderr)
        return 1

    rows = [json.loads(l) for l in open(args.events) if l.strip()]
    sigs = [extract_event(r) for r in rows]
    households = build_households(sigs)
    picked = candidates(households, args.limit)

    existing = {
        (c.get("name") or "").strip().lower()
        for c in _request("GET", "customers?select=name")
    }

    payload = []
    for h in picked:
        name = h.best_name
        if name.strip().lower() in existing:
            continue
        town = title_case_town(h.cities.most_common(1)[0][0])
        payload.append(
            {
                "name": name,
                "address": pretty_address(h.best_address, town),
                "city": town,
                "phone": h.best_phone,
                "email": "",
                "funding_source": _AGENCY_TO_FUNDING.get(
                    h.best_agency, "Private"
                ),
                "notes": (
                    f"{h.event_count} visits on record "
                    f"({h.first_seen[:10]} to {h.last_seen[:10]})."
                    + (
                        f" Agency contact: {h.agency_contact_list}."
                        if h.agency_contact_list
                        else ""
                    )
                ),
                # Long-standing service customers are active, not new leads.
                "lifecycle_status": "active",
            }
        )

    print(f"{len(households)} households, {len(picked)} eligible, "
          f"{len(payload)} new to insert\n")
    for p in payload[:12]:
        print(f"  {p['name'][:24]:26} {p['address'][:38]:40} "
              f"{p['funding_source']}")
    if len(payload) > 12:
        print(f"  ... and {len(payload) - 12} more")

    if not args.write:
        print("\nPreview only. Re-run with --write to insert.")
        return 0
    if not payload:
        print("\nNothing new to insert.")
        return 0

    # Insert in batches so one oversized request cannot fail the lot.
    inserted = 0
    for i in range(0, len(payload), 50):
        batch = payload[i : i + 50]
        _request("POST", "customers", batch,
                 {"Prefer": "return=minimal"})
        inserted += len(batch)
        print(f"  inserted {inserted}/{len(payload)}")
    print(f"\nDone: {inserted} customers.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
