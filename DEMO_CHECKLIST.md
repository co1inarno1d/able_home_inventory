# Demo checklist

Everything below is deployed to `main` as of 2026-10-23 and builds clean.
Nothing here needs a code change before showing it.

## Check first, on a phone

The app ships as a web PWA, so test on the device the techs actually use.

1. **Open the Schedule.** It should land on today, not a week back. This was
   the most-reported field complaint.
2. **Tap an event.** The date is now shown alongside the time.
3. **Search `today`**, then a town name, then `april 2025`. All three work,
   including dates alone, which previously returned nothing from history.
4. **Open the Hub** from the icon in the Schedule's top bar.

## Worth showing

### Schedule → Hub as one system
The point to make: these are not two lists. Every schedule event appears in
exactly one Hub bucket, and tapping a Hub row opens the same event detail
screen. Check a job off in one view and it is checked off in the other,
because there is only one record.

Buckets: Installs and Removals each split into straight SL / curve SL / ramp,
Service splits from Annual, plus Leads, To Schedule and Reminders.

### Leads
**142 real web leads**, 117 still marked New going back to May. These existed
in the database the whole time but were invisible — the tab was filtering a
job type nothing ever created. Phone and email buttons work from the card.

### Job check-off
On a ramp job, completing it now **requires** the quantities. Previously there
was a Skip button, and skipping left inventory silently wrong. If the tech
backs out, the job stays open rather than being marked done with bad counts.

On a service job, the **invoice photo is required** to save the record. The
office builds the service entry from the photo, so the tech types nothing.

### Customers
**41 real customers** with addresses, phones, funding sources, and visit
history in the notes. Worth saying plainly: this is a sample. 5,703 households
have been identified from seven years of schedule history and are being
reviewed before import.

### Who's paying
Event details now show funding source (Private / VA / CCALS / NaviCare /
Summit / Fallon / Mass Health) instead of where the lead came from. CCALS jobs
correctly draw from the separate CCALS ramp pool.

## Known gaps — say these rather than be asked

- **Customers tab is a sample, not the full list.** The reconciliation is in
  progress; the spreadsheet of ambiguous cases is being worked through now.
- **No call history yet.** Quo integration is designed but not built.
- **Customer detail is still a single scrolling page**, not the tabbed view
  (Summary / Service / Events / Calls / Equipment / Photos / Notes).
- **No offline queue.** Photo uploads retry on weak signal, but a force-quit
  mid-upload still loses the image.
- **Prep is unchanged**, as agreed.

## If something looks wrong

The schedule reads live from QuickBooks Time, so a TSheets outage shows as an
error banner with a Retry button rather than an empty screen. History older
than ~7 days comes from the archive, which is now updating nightly —
confirmed running, 25,129 events back to September 2019.
