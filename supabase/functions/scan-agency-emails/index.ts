// supabase/functions/scan-agency-emails/index.ts
//
// Supabase Edge Function — scans Colin's Gmail inbox for agency confirmation
// emails (VA, CCALS, NaviCare, Summit, Fallon, Mass Health) and advances
// matching ops_jobs from 'waiting_agency_confirmation' → 'ready_to_schedule'.
//
// SETUP:
//   1. Set these Supabase secrets (supabase secrets set KEY=value):
//      GMAIL_CLIENT_ID       — from Google Cloud Console OAuth credentials
//      GMAIL_CLIENT_SECRET   — from Google Cloud Console OAuth credentials
//      GMAIL_REFRESH_TOKEN   — from OAuth2 playground (colin@loml.org account)
//      SUPABASE_URL          — your project URL (auto-set in Edge Functions)
//      SUPABASE_SERVICE_KEY  — service role key (needed to update ops_jobs)
//
//   2. Deploy:  supabase functions deploy scan-agency-emails
//
//   3. Schedule via Supabase cron (Dashboard > Database > Cron Jobs):
//      Function: scan-agency-emails
//      Schedule: every 30 minutes  →  */30 * * * *
//
//   4. First-time Gmail OAuth setup:
//      - Go to https://developers.google.com/oauthplayground
//      - Select Gmail API v1 scope: https://www.googleapis.com/auth/gmail.readonly
//      - Authorize with colin@loml.org
//      - Exchange auth code for tokens → copy the refresh_token
//      - Set as GMAIL_REFRESH_TOKEN secret above
//
// HOW IT WORKS:
//   1. Gets a fresh Gmail access token using the stored refresh token
//   2. Searches Gmail for unread emails from known agency domains
//   3. For each matching email, parses customer name from subject/body
//   4. Finds the corresponding ops_job with status='waiting_agency_confirmation'
//   5. Advances it to 'ready_to_schedule' and logs which email triggered it
//   6. Labels the Gmail email as processed so it isn't re-scanned

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ---------------------------------------------------------------------------
// AGENCY MATCHING CONFIG
// ---------------------------------------------------------------------------
// Each entry: email domains/addresses to watch, keywords that indicate
// a confirmation (not a rejection/request), and the funding_source value
// it maps to in the database.
//
// Tune these once real examples come in. Currently conservative —
// any email from the domain with any confirmation keyword counts.

const AGENCIES = [
  {
    fundingSource: 'VA',
    domains: ['va.gov', 'va.com'],
    senders: [],
    confirmationKeywords: ['approved', 'authorization', 'authorized', 'confirm', 'proceed'],
    rejectionKeywords: ['denied', 'rejected', 'not approved'],
  },
  {
    fundingSource: 'CCALS',
    domains: [],
    senders: ['ccals@'],
    confirmationKeywords: ['approved', 'confirm', 'authorized', 'proceed'],
    rejectionKeywords: ['denied', 'rejected'],
  },
  {
    fundingSource: 'NaviCare',
    domains: ['navicare.org', 'navicare.com'],
    senders: [],
    confirmationKeywords: ['approved', 'authorization', 'confirm'],
    rejectionKeywords: ['denied', 'not approved'],
  },
  {
    fundingSource: 'Summit',
    domains: ['summiteldercare.net', 'summiteldercare.com'],
    senders: [],
    confirmationKeywords: ['approved', 'authorization', 'confirm'],
    rejectionKeywords: ['denied'],
  },
  {
    fundingSource: 'Fallon',
    domains: ['fallonhealth.org', 'fchp.org'],
    senders: [],
    confirmationKeywords: ['approved', 'authorization', 'confirm'],
    rejectionKeywords: ['denied'],
  },
  {
    fundingSource: 'Mass Health',
    domains: ['masshealth.net', 'mass.gov'],
    senders: [],
    confirmationKeywords: ['approved', 'authorization', 'confirm'],
    rejectionKeywords: ['denied'],
  },
];

// Gmail label applied to processed emails so they aren't re-matched
const PROCESSED_LABEL = 'AbleHome/Processed';

// ---------------------------------------------------------------------------
// GMAIL HELPERS
// ---------------------------------------------------------------------------

async function getAccessToken(): Promise<string> {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id:     Deno.env.get('GMAIL_CLIENT_ID')!,
      client_secret: Deno.env.get('GMAIL_CLIENT_SECRET')!,
      refresh_token: Deno.env.get('GMAIL_REFRESH_TOKEN')!,
      grant_type:    'refresh_token',
    }),
  });
  const data = await res.json();
  if (!data.access_token) throw new Error(`Gmail token error: ${JSON.stringify(data)}`);
  return data.access_token;
}

async function listMessages(token: string, query: string): Promise<string[]> {
  const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages?q=${encodeURIComponent(query)}&maxResults=20`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  const data = await res.json();
  return (data.messages ?? []).map((m: { id: string }) => m.id);
}

async function getMessage(token: string, id: string): Promise<{ from: string; subject: string; snippet: string }> {
  const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  const data = await res.json();
  const headers: { name: string; value: string }[] = data.payload?.headers ?? [];
  const get = (name: string) => headers.find(h => h.name === name)?.value ?? '';
  return { from: get('From'), subject: get('Subject'), snippet: data.snippet ?? '' };
}

async function labelMessage(token: string, id: string, labelName: string): Promise<void> {
  // Get or create the label
  const labelsRes = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/labels', {
    headers: { Authorization: `Bearer ${token}` },
  });
  const labelsData = await labelsRes.json();
  let label = (labelsData.labels ?? []).find((l: { name: string }) => l.name === labelName);

  if (!label) {
    const createRes = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/labels', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: labelName, messageListVisibility: 'show', labelListVisibility: 'labelShow' }),
    });
    label = await createRes.json();
  }

  await fetch(`https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}/modify`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ addLabelIds: [label.id], removeLabelIds: ['UNREAD'] }),
  });
}

// ---------------------------------------------------------------------------
// MATCHING LOGIC
// ---------------------------------------------------------------------------

function matchAgency(from: string, subject: string, snippet: string) {
  const fromLower = from.toLowerCase();
  const text = `${subject} ${snippet}`.toLowerCase();

  for (const agency of AGENCIES) {
    // Check if email is from this agency
    const domainMatch = agency.domains.some(d => fromLower.includes(d));
    const senderMatch = agency.senders.some(s => fromLower.includes(s));
    if (!domainMatch && !senderMatch) continue;

    // Check for rejection keywords first — don't false-positive a denial
    if (agency.rejectionKeywords.some(k => text.includes(k))) continue;

    // Check for confirmation keywords
    if (agency.confirmationKeywords.some(k => text.includes(k))) {
      return agency.fundingSource;
    }
  }
  return null;
}

// Extract a customer name from subject line.
// Common patterns: "RE: Able Home - John Smith", "Authorization for John Smith", etc.
// Falls back to empty string if no clear name found.
function extractCustomerName(subject: string): string {
  const patterns = [
    /(?:for|re:|authorization|approval)[:\s]+([A-Z][a-z]+ [A-Z][a-z]+)/i,
    /([A-Z][a-z]+ [A-Z][a-z]+)\s*[-–]\s*(?:stairlift|ramp|lift)/i,
    /(?:patient|client|customer)[:\s]+([A-Z][a-z]+ [A-Z][a-z]+)/i,
  ];
  for (const p of patterns) {
    const m = subject.match(p);
    if (m) return m[1].trim();
  }
  return '';
}

// ---------------------------------------------------------------------------
// MAIN HANDLER
// ---------------------------------------------------------------------------

Deno.serve(async (_req) => {
  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_KEY')!,
    );

    const token = await getAccessToken();

    // Search for unread emails not yet labelled as processed
    // from any known agency domain
    const agencyDomains = AGENCIES.flatMap(a => [...a.domains, ...a.senders]);
    const fromQuery = agencyDomains.map(d => `from:${d}`).join(' OR ');
    const query = `is:unread -label:${PROCESSED_LABEL.replace('/', '/')} (${fromQuery})`;

    const messageIds = await listMessages(token, query);
    const results: string[] = [];

    for (const id of messageIds) {
      const { from, subject, snippet } = await getMessage(token, id);
      const fundingSource = matchAgency(from, subject, snippet);

      if (!fundingSource) {
        // Doesn't match any confirmation pattern — add to review queue
        await supabase.from('app_config').upsert({
          key: `email_review_${id}`,
          value: JSON.stringify({ from, subject, snippet, scannedAt: new Date().toISOString() }),
          updated_at: new Date().toISOString(),
        }, { onConflict: 'key' });
        results.push(`[REVIEW] ${id}: ${subject}`);
        continue;
      }

      const customerName = extractCustomerName(subject);

      // Find matching job: waiting_agency_confirmation + same funding_source
      // Optionally match customer name if we could extract one
      let query2 = supabase
        .from('ops_jobs')
        .select('job_id, customer_name, status')
        .eq('status', 'waiting_agency_confirmation')
        .eq('funding_source', fundingSource);

      if (customerName) {
        query2 = query2.ilike('customer_name', `%${customerName}%`);
      }

      const { data: jobs } = await query2.limit(1);

      if (jobs && jobs.length > 0) {
        const job = jobs[0];
        await supabase
          .from('ops_jobs')
          .update({
            status: 'ready_to_schedule',
            notes: `${job.notes ?? ''}\n[Auto] Agency confirmation received ${new Date().toLocaleDateString()} — Gmail ID: ${id}`.trim(),
            updated_at: new Date().toISOString(),
          })
          .eq('job_id', job.job_id);

        results.push(`[MATCHED] ${fundingSource} → job ${job.job_id} (${job.customer_name})`);
      } else {
        // No matching job found — log for manual review
        await supabase.from('app_config').upsert({
          key: `email_unmatched_${id}`,
          value: JSON.stringify({
            from, subject, snippet, fundingSource, customerName,
            scannedAt: new Date().toISOString(),
          }),
          updated_at: new Date().toISOString(),
        }, { onConflict: 'key' });
        results.push(`[UNMATCHED] ${fundingSource} from ${from} — no job found`);
      }

      // Label the email as processed regardless of match outcome
      await labelMessage(token, id, PROCESSED_LABEL);
    }

    return new Response(
      JSON.stringify({ scanned: messageIds.length, results }),
      { headers: { 'Content-Type': 'application/json' } },
    );

  } catch (err) {
    console.error('scan-agency-emails error:', err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
