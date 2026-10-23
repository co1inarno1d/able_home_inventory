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
- `cluster.py` — groups events into households and triages them

## How many customers is this, really?

The archive starts **September 2019** — nothing older survives in QuickBooks
Time, so this is 7 years, not all time.

| | |
|---|---|
| candidate households (Sept 2019 →) | 5,703 |
| new households per year | ~700–890, steady |
| visited once | 2,448 (42%) |
| visited 2+ times | 3,255 (57%) |
| visited 5+ times | 945 |
| **seen in the last 2 years** | **2,662** |
| not seen since before 2023 | 1,724 |

Two caveats. The count is *candidates*: a customer who moved appears twice if
no phone links the addresses, so review will settle it somewhat lower. And at
~800 new households a year, the pre-2019 customer base is probably comparable
in size — recoverable only from QuickBooks, if at all.

The operationally useful figure is **2,662 seen in the last two years**.

## Clustering results

25,129 events → **5,703 candidate households**, split by who can answer the
question:

| tier | households | events | what it means |
|---|---|---|---|
| `accept` | 2,958 | 7,037 | one name, one address, usually one phone — linked automatically |
| `confirm_family` | 314 | 1,492 | several names sharing a surname at one address, i.e. spouses. Obvious at a glance, still confirmed |
| `decide` | 1,104 | 5,274 | genuinely ambiguous — **your queue** |
| `await_qb` | 1,273 | 1,923 | coherent household, no name in the schedule. QuickBooks knows it; no point asking you to type it |
| `thin` | 54 | 54 | one event, almost no signal. Parked |

Of the 1,104 real decisions, **792 have 3+ events**, so working the queue in
event-count order puts the valuable history first.

Nothing in the `accept` tier has conflicting names or conflicting addresses —
verified, not assumed.

### Why the queue got smaller

A first pass put 2,146 items in front of you, which is not a workable ask.
Three changes cut it to 1,104 without lowering the bar:

- **Hub suppression.** One cluster had grown to 120 events, 29 names and 10
  addresses, because `67 W Boylston St` — our own shop — appears on 62 events
  with 13 different customer names, and identity is transitive, so everything
  touching the shop chained into one blob. Addresses carrying more than 4
  distinct names, and phones spanning more than 3 distinct addresses, are no
  longer treated as identity. 22 addresses and 5 phones are suppressed; the
  largest cluster is now 28 events.
- **`await_qb`.** 1,273 clusters are internally consistent but have no name in
  the schedule. QuickBooks is the authoritative name source, so these resolve
  on the QB cross-reference rather than by asking you to type names.
- **`confirm_family`.** 314 clusters are plainly one family — `Marshall Mills`
  / `Sue Mills`, `Frances Sadowski` / `Paul Sadowski`. Still confirmed, but in
  a fast lane separate from cases that need thought, like `Darlyn Scott` /
  `Donald Bevelander` / `Gretchen Sting` at one address.

## Still to come

The schedule is one of three sources. Both of these are planned, not
forgotten:

- **QuickBooks** — the authoritative source for customer *names* and billing
  addresses, and the only place with a clean customer list. Needs paged
  retrieval: the existing `qb-proxy` search caps at 200 records with
  client-side filtering, which cannot enumerate a full customer base.
- **Quo call history** — inbound numbers matched to customers via
  `customer_phones`. Live capture should start as early as possible since Quo
  has no bulk history endpoint, so any call not captured is lost permanently.

Each source is cross-referenced into the same crosswalk, so a customer ends up
with one identity regardless of which system it was first seen in.

## The three note formats this handles

Per Colin, these cover most customer-name entries, and all three are accepted:

1. **Stacked** — name, then address, then town, then phone on consecutive
   lines. How Colin writes them, especially for evals. A line is read as a
   name when the next segment starts with a house number, which is strong
   positional evidence even when the line alone is ambiguous.
2. **`Meet [name]`** — Matt's habit. Leading verbs are stripped (`meet`,
   `call`, `contact`, `see`, `text`, `talk to`, …) so "Meet Diane Baruch"
   yields "Diane Baruch".
3. **`[name] [phone]`** — Ryan's habit, e.g. `Zach Taylor 978-360-9213`. This
   is the single most common layout; supporting it moved name coverage from
   32% to 43%.

Crew labelling is rejected: **"Ryan Job" means Ryan Clark's job**, not a
customer named Ryan Job — and it previously outranked the real customer on the
same note. Same for "Matt job".

## Same name, different people

This is real in the data, not hypothetical: `john burke`, `scott hill` and
`kimm simpson` each appear at 3-4 genuinely unrelated addresses. **A name is
never an identity on its own.**

The discriminator that works is phone. Across 314 names appearing at more than
one address:

- **279 share a phone number across those addresses** — almost certainly one
  person who moved. `david boston` shows up at Gardner and then Sterling on
  the same number.
- **94 share no phone** — likely different people with the same name, and they
  must stay separate.

So the rule is: a repeated name is evidence of *nothing* until an address or
phone agrees. Two households keep separate records unless something besides
the name links them.

Three distinct shapes, all of which look identical if you only compare names:

| shape | example | handling |
|---|---|---|
| one person, moved | `david boston` Gardner → Sterling, same phone | merge, keep both addresses |
| different people, same name | `scott hill` × 4 addresses, no shared phone | keep separate |
| business / property manager | `carabetta companies` × 10 addresses | one record, many sites |

## Agency contacts are not customers

VA, CCALS, Summit and NaviCare work arrives with a coordinator's name attached,
and that person is not the customer. VA work orders pasted into notes name
both, in a consistent shape (116 events):

```
VAMC Requestor: Bryant Cooper   <- VA coordinator, NOT our customer
Vet | James McGrath             <- the veteran, whose home we visit
```

Taking the requestor would attach dozens of unrelated households to one
coordinator — the same failure the shop address caused. So coordinator fields
(`VAMC Requestor`, `requester`, `case manager`, `coordinator`, `social
worker`, `contact is`) are extracted specifically in order to be **excluded**,
and the `Vet` marker is read as the customer.

Checked afterwards: no coordinator name now spans multiple addresses. The
agency-funded events resolve to patients at a single address each, which is
what they should be.

## Known extraction limits

Worth knowing before trusting the output:

- **Nicknames and typos** produce near-duplicates at one address: `Phil
  Bourgeault` / `Philip Bourgeault` / `Philip Bourgeualt`. Fuzzy matching in
  the scoring step collapses these.
- **Spouses** legitimately give two names for one household (`Debbie
  Robideaux` / `Mark Robideaux`). Not an error — one household, two contacts.
- **Business customers** appear as names (`Carabetta Companies`, a property
  manager). Correct, but they behave differently from a household.
- **951 addresses** currently resolve to more than one name.
- **Address spelling variants** at one house produce separate keys: `182
  justice hill cut off` / `cut-off`, `48 victoria heights rd` / `victoria
  hights road`. Fuzzy street matching in the scoring step handles these.
- Addresses written in notes often **omit the town**, so `street_key`
  (house + street, no town) exists as a join candidate. It is deliberately not
  treated as an identity, since two towns can share a street name and number. Most collapse via
  the two cases above; the rest go to review.
