/**
 * archive-schedule
 *
 * Fetches TSheets schedule events and upserts them into the
 * `schedule_history` Supabase table. Safe to run repeatedly —
 * upsert on tsheets_id means no duplicates.
 *
 * Nightly cron mode (no params): archives the window that just aged out
 * of the 7-day live TSheets window (looks back 60 days to catch any misses).
 *
 * Migration mode (query params): pass ?start=YYYY-MM-DD&end=YYYY-MM-DD
 * to archive any arbitrary date range. Used for the one-time full backfill.
 *
 * Called nightly by Supabase cron (see schema.sql for setup SQL).
 */

const TSHEETS_TOKEN = 'S.6__bc39aa448aae631d140c82d5a694c54b4fd94ebd';
const TSHEETS_BASE = 'https://rest.tsheets.com/api/v1';
const CALENDAR_ID = '123571';

// Nightly mode: how far back to look (catches anything missed in prior runs)
const LOOKBACK_DAYS = 60;
// Nightly mode: events newer than this stay in the live TSheets window
const LIVE_WINDOW_DAYS = 7;

function dateOnly(d: Date): string {
  return d.toISOString().slice(0, 10);
}

async function fetchTsheetsUsers(): Promise<Record<string, string>> {
  const url = `${TSHEETS_BASE}/users?active=yes&per_page=200`;
  const resp = await fetch(url, {
    headers: { Authorization: `Bearer ${TSHEETS_TOKEN}` },
  });
  if (!resp.ok) return {};
  const body = await resp.json();
  const usersMap: Record<string, any> = body?.results?.users ?? {};
  const idToName: Record<string, string> = {};
  for (const [id, u] of Object.entries(usersMap)) {
    const first = (u as any).first_name ?? '';
    const last = (u as any).last_name ?? '';
    idToName[id] = `${first} ${last}`.trim();
  }
  return idToName;
}

async function fetchTsheetsEvents(start: Date, end: Date): Promise<any[]> {
  const startIso = `${dateOnly(start)}T00:00:00+00:00`;
  const endIso = `${dateOnly(end)}T23:59:59+00:00`;

  const all: any[] = [];
  let page = 1;

  while (true) {
    const url =
      `${TSHEETS_BASE}/schedule_events` +
      `?schedule_calendar_ids=${CALENDAR_ID}` +
      `&start=${encodeURIComponent(startIso)}` +
      `&end=${encodeURIComponent(endIso)}` +
      `&active=both` +
      `&per_page=200` +
      `&page=${page}`;

    const resp = await fetch(url, {
      headers: { Authorization: `Bearer ${TSHEETS_TOKEN}` },
    });

    if (!resp.ok) {
      throw new Error(`TSheets error ${resp.status}: ${await resp.text()}`);
    }

    const body = await resp.json();
    const eventsMap: Record<string, any> =
      body?.results?.schedule_events ?? {};

    all.push(...Object.values(eventsMap));

    if (body.more !== true) break;
    page++;
  }

  return all;
}

Deno.serve(async (req: Request) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    const url = new URL(req.url);
    const paramStart = url.searchParams.get('start');
    const paramEnd = url.searchParams.get('end');

    let archiveStart: Date;
    let archiveEnd: Date;

    if (paramStart && paramEnd) {
      // Migration mode: use the provided date range exactly
      archiveStart = new Date(`${paramStart}T00:00:00Z`);
      archiveEnd = new Date(`${paramEnd}T23:59:59Z`);
    } else {
      // Nightly mode: archive the window that just aged out
      const now = new Date();
      archiveEnd = new Date(now);
      archiveEnd.setDate(archiveEnd.getDate() - LIVE_WINDOW_DAYS);
      archiveStart = new Date(now);
      archiveStart.setDate(archiveStart.getDate() - LOOKBACK_DAYS);
    }

    // Fetch users and events in parallel
    const [idToName, rawEvents] = await Promise.all([
      fetchTsheetsUsers(),
      fetchTsheetsEvents(archiveStart, archiveEnd),
    ]);

    if (rawEvents.length === 0) {
      return new Response(
        JSON.stringify({ archived: 0, message: 'No events to archive' }),
        { headers: { 'Content-Type': 'application/json' } },
      );
    }

    // Deduplicate by (title + start + end) — same logic as the app
    const dedupMap = new Map<string, any>();
    for (const e of rawEvents) {
      const key = `${e.title}|${e.start}|${e.end}`;
      if (dedupMap.has(key)) {
        const existing = dedupMap.get(key)!;
        const existingIds: string[] = existing.assigned_user_ids
          ? existing.assigned_user_ids.split(',').map((s: string) => s.trim())
          : [];
        const newIds: string[] = e.assigned_user_ids
          ? e.assigned_user_ids.split(',').map((s: string) => s.trim())
          : [];
        const merged = [...new Set([...existingIds, ...newIds])].join(',');
        dedupMap.set(key, { ...existing, assigned_user_ids: merged });
      } else {
        dedupMap.set(key, e);
      }
    }

    const rows = Array.from(dedupMap.values()).map((e) => {
      const ids: string[] = e.assigned_user_ids
        ? e.assigned_user_ids.split(',').map((s: string) => s.trim()).filter(Boolean)
        : [];
      const names = ids.map((id) => idToName[id] ?? '').filter(Boolean).join(', ');
      return {
        tsheets_id: String(e.id),
        title: e.title ?? '',
        notes: e.notes ?? '',
        start_time: e.start,
        end_time: e.end,
        all_day: e.all_day === true,
        location: e.location ?? '',
        color: e.color ?? '#2196F3',
        assigned_user_ids: ids.join(','),
        assigned_user_names: names,
        active: e.active !== false,
      };
    });

    // Upsert in batches of 200
    const batchSize = 200;
    let totalUpserted = 0;
    for (let i = 0; i < rows.length; i += batchSize) {
      const batch = rows.slice(i, i + batchSize);
      const resp = await fetch(
        `${supabaseUrl}/rest/v1/schedule_history`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${serviceKey}`,
            'apikey': serviceKey,
            'Prefer': 'resolution=merge-duplicates',
          },
          body: JSON.stringify(batch),
        },
      );
      if (!resp.ok) {
        const err = await resp.text();
        throw new Error(`Supabase upsert error ${resp.status}: ${err}`);
      }
      totalUpserted += batch.length;
    }

    return new Response(
      JSON.stringify({ archived: totalUpserted }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ error: err.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
