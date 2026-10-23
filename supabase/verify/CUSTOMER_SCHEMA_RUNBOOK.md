# Customer schema — what to run

Two SQL files, both safe to re-run, neither deletes or rewrites anything.
Paste each into the Supabase **SQL Editor** and run top to bottom.

No service-role key needed this time, and nothing to hand-edit.

---

## 1. `supabase/migrations/20261023_parse_flexible_date_v2.sql`

Replaces one function. No tables touched.

Your date columns are text and hold six different formats — including full
JavaScript date strings like `Thu Feb 26 2026 00:00:00 GMT-0500 (Eastern
Standard Time)`. The old parser understood two of them, so the rest came back
as "no date". That matters for anything age-based: a lift with an unreadable
install date silently drops out of consideration rather than erroring.

Measured on your actual 265 lifts:

| column | has a value | parsed before | parsed now |
|---|---|---|---|
| install_date | 183 | 148 | **183** |
| date_acquired | 161 | 127 | 159 |
| last_prep_date | 174 | 165 | **174** |

The two still unparsed are real typos — `In Stock` and `03/16/202)`. They stay
empty on purpose; a wrong date is worse than a blank one.

**Check it worked:**

```sql
select parse_flexible_date('Thu Feb 26 2026 00:00:00 GMT-0500 (Eastern Standard Time)');
-- expect 2026-02-26

select count(*) filter (where install_date <> '') as has_text,
       count(parse_flexible_date(install_date))   as parsed
  from lifts;
-- expect both numbers equal (183)
```

---

## 2. `supabase/migrations/20261023_customer_identity.sql`

The real one. Adds five tables, some columns, and three triggers.

**Check it worked:**

```sql
select table_name from information_schema.tables
 where table_name in ('app_config','customer_addresses',
                      'event_customer_links','customer_tags',
                      'customer_tag_links')
 order by table_name;
-- expect 5 rows
```

```sql
select slug, label from customer_tags order by sort_order;
-- expect va, private_pay, ccals, summit, navicare, mass_health, fallon
```

```sql
insert into customers (name, phone) values ('ZZ Test', '(508) 555-1234')
  returning name, phone, phone_e164;
-- phone_e164 should read +15085551234
delete from customers where name = 'ZZ Test';
```

```sql
select count(*) as total, count(customer_id) as linked
  from schedule_history;
-- expect total ~25,129 and linked 0 — nothing is matched yet, that's next
```

### If something fails

Most likely cause is the `phone_e164` generated column, which needs
`normalize_e164` to already exist. Confirm with:

```sql
select normalize_e164('(508) 555-1234');   -- +15085551234
```

If that errors, run `supabase/migrations/20260824_metrics_helpers.sql` first.

---

## What this does and doesn't do

**Does:** gives every schedule event a real place to record which customer it
belongs to, lets one customer hold several addresses (for when someone moves
and we have equipment at both), and adds tags.

**Doesn't:** match anything yet. After this runs, `linked` is 0. Filling it in
is the reconciliation step, which runs outside the app and is the next piece
of work.

## One thing worth knowing

Your event titles are mostly town names — "Boylston Install", "Fitchburg SL
service" — so the customer's identity isn't in the title. It's in the address
field (56% of events) and the notes, which often hold a name and phone number
(58% have a phone). Phone is the most reliable key because it survives a move.

That's why matching needs a review step rather than being fully automatic, and
why the schema records a confidence score and a method for every link.
