# Customer reconciliation

Offline scripts that build a customer list out of five years of schedule
events. These run **outside the Flutter app** — the app reads the result, it
never does the migration.

Nothing here writes to the database yet. `extract.py` and the scoring step
only read; the write step comes later and is separate on purpose, so the
output can be inspected before anything lands.

## Why this is needed

The schedule lives in QuickBooks Time, and an event's title is almost always
a **town plus a job type** — "Boylston Install", "Fitchburg SL service" — not
a customer's name. The customer's identity is spread across the address field
and the free-text notes.

Meanwhile the app has 182 installed lifts with **no customer attached to any
of them**, and one customer record total. The history exists; the index into
it does not.

## What extraction finds

Measured over all 25,129 archived events:

| signal | coverage |
|---|---|
| usable street address | 59% |
| phone number | 56% |
| customer name | 43% |
| **address or phone (groupable)** | **62%** |
| looks like real work but has no address | 11% |

That yields **6,283 distinct households**, 3,255 of them visited more than
once. Those repeat households are where the service history worth having
lives.

The remaining ~25% are genuinely not customer work — "Leave from home",
"Chimney sweep", "Check Subaru" — and are left alone.

## The rules this follows

**Blank beats wrong.** Every extractor returns only what it is confident
about. A gap is visible and can be filled in review; a wrong value silently
attaches one household's history to another, and a tech seeing the wrong
service history is worse than a tech seeing none.

**Merge on a match, never split on a mismatch.** A shared phone or address is
strong evidence two records are the same household. Different numbers prove
nothing — people have a landline and a mobile, a spouse's phone, a daughter
who coordinates for them. 12% of addresses already show two or more numbers.

**A human decision is final.** Once a match is confirmed or rejected it is
locked, and re-running never asks again.

## Files

- `extract.py` — pulls names, phones and addresses out of one event

## Known extraction limits

Worth knowing before trusting the output:

- **Nicknames and typos** produce near-duplicates at one address: `Phil
  Bourgeault` / `Philip Bourgeault` / `Philip Bourgeualt`. Fuzzy matching in
  the scoring step collapses these.
- **Spouses** legitimately give two names for one household (`Debbie
  Robideaux` / `Mark Robideaux`). Not an error — one household, two contacts.
- **Business customers** appear as names (`Carabetta Companies`, a property
  manager). Correct, but they behave differently from a household.
- **884 addresses** currently resolve to more than one name. Most collapse via
  the two cases above; the rest go to review.
