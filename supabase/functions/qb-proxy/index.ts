// supabase/functions/qb-proxy/index.ts
//
// Handles all QuickBooks Online API interactions server-side:
//   POST /qb-proxy/auth-url      → returns the QB OAuth2 authorization URL + state token
//   POST /qb-proxy/callback      → verifies state, exchanges auth code for tokens, stores them
//   POST /qb-proxy/search        → searches QB customers by name
//   POST /qb-proxy/disconnect    → removes stored tokens
//   GET  /qb-proxy/status        → returns whether tokens are stored
//
// Error handling:
//   a. Expired access token  — proactive refresh before expiry; 401 retry with fresh token
//   b. Expired refresh token — detected via invalid_grant; tokens deleted, 401 returned so
//                              the app knows to show "reconnect" UI
//   c. Invalid grant         — same path as (b); any token exchange failure clears storage
//   d. CSRF                  — state param stored in qb_oauth_state table, verified on callback

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const QB_CLIENT_ID = Deno.env.get('QB_CLIENT_ID')!;
const QB_CLIENT_SECRET = Deno.env.get('QB_CLIENT_SECRET')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// ---------------------------------------------------------------------------
// Structured error logging
// Writes to qb_error_logs table and also logs to console for Supabase log viewer.
// ---------------------------------------------------------------------------

interface QbErrorEntry {
  action: string;
  intuit_tid?: string;
  http_status?: number;
  error_code?: string;
  error_message: string;
  fault_errors?: unknown;
  context?: unknown;
}

async function logError(entry: QbErrorEntry) {
  const row = { ...entry, created_at: new Date().toISOString() };
  // Always write to console — visible in Supabase Edge Function logs dashboard
  console.error('[qb-proxy error]', JSON.stringify(row));
  // Best-effort write to DB for shareable troubleshooting logs
  try {
    await sb().from('qb_error_logs').insert(row);
  } catch (_) {
    // Don't let logging failure break the actual response
  }
}

const QB_TOKEN_URL = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
const QB_API_BASE = 'https://quickbooks.api.intuit.com/v3/company';
const QB_SCOPE = 'com.intuit.quickbooks.accounting';

// State tokens expire after 10 minutes (OAuth flow must complete in that window)
const STATE_TTL_MS = 10 * 60 * 1000;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function err(msg: string, status = 400) {
  return json({ error: msg }, status);
}

// ---------------------------------------------------------------------------
// Supabase client (service role — bypasses RLS for token storage)
// ---------------------------------------------------------------------------

function sb() {
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
}

// ---------------------------------------------------------------------------
// Token storage
// ---------------------------------------------------------------------------

async function saveTokens(realmId: string, accessToken: string, refreshToken: string, expiresAt: number) {
  await sb().from('qb_tokens').upsert({
    realm_id: realmId,
    access_token: accessToken,
    refresh_token: refreshToken,
    expires_at: new Date(expiresAt).toISOString(),
    updated_at: new Date().toISOString(),
  }, { onConflict: 'realm_id' });
}

async function loadTokens() {
  const { data } = await sb().from('qb_tokens').select('*').limit(1).maybeSingle();
  return data as { realm_id: string; access_token: string; refresh_token: string; expires_at: string } | null;
}

// Delete all stored tokens — called when refresh token is known to be dead.
async function clearTokens() {
  await sb().from('qb_tokens').delete().neq('realm_id', '');
}

// ---------------------------------------------------------------------------
// Token refresh
// Returns fresh access token, or throws a typed error.
// Callers must catch and handle appropriately.
// ---------------------------------------------------------------------------

class RefreshTokenExpiredError extends Error {
  constructor() { super('QB refresh token expired — please reconnect QuickBooks'); }
}

class InvalidGrantError extends Error {
  constructor(detail: string) { super(`QB invalid_grant: ${detail}`); }
}

async function refreshAccessToken(row: { realm_id: string; refresh_token: string }): Promise<string> {
  const creds = btoa(`${QB_CLIENT_ID}:${QB_CLIENT_SECRET}`);
  const res = await fetch(QB_TOKEN_URL, {
    method: 'POST',
    headers: {
      'Authorization': `Basic ${creds}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: row.refresh_token,
    }),
  });

  const intuitTid = res.headers.get('intuit_tid') ?? undefined;
  const data = await res.json();

  if (!res.ok || !data.access_token) {
    const errorCode = data.error ?? '';
    const detail = data.error_description ?? errorCode ?? 'Unknown error';

    await logError({
      action: 'refresh_token',
      intuit_tid: intuitTid,
      http_status: res.status,
      error_code: errorCode,
      error_message: detail,
    });

    if (errorCode === 'invalid_grant' || errorCode === 'refresh_token_expired' || res.status === 400) {
      await clearTokens();
      if (errorCode === 'invalid_grant') throw new InvalidGrantError(detail);
      throw new RefreshTokenExpiredError();
    }

    throw new Error(`Token refresh failed: ${detail}`);
  }

  const expiresAt = Date.now() + data.expires_in * 1000;
  await saveTokens(row.realm_id, data.access_token, data.refresh_token ?? row.refresh_token, expiresAt);
  return data.access_token as string;
}

async function getValidAccessToken(): Promise<string> {
  const row = await loadTokens();
  if (!row) throw new Error('QB not connected');
  const expiresAt = new Date(row.expires_at).getTime();
  // Proactively refresh if within 5 minutes of expiry (handles scenario a)
  if (Date.now() > expiresAt - 5 * 60 * 1000) {
    return await refreshAccessToken(row); // may throw RefreshTokenExpiredError or InvalidGrantError
  }
  return row.access_token;
}

// ---------------------------------------------------------------------------
// CSRF state management (handles scenario d)
// Stored in qb_oauth_state table, verified on callback, then deleted.
// ---------------------------------------------------------------------------

async function saveState(state: string) {
  await sb().from('qb_oauth_state').upsert({
    state,
    expires_at: new Date(Date.now() + STATE_TTL_MS).toISOString(),
  });
}

async function verifyAndConsumeState(state: string): Promise<boolean> {
  if (!state) return false;
  const { data } = await sb()
    .from('qb_oauth_state')
    .select('state, expires_at')
    .eq('state', state)
    .maybeSingle();

  // Always delete whether valid or not (one-time use)
  await sb().from('qb_oauth_state').delete().eq('state', state);

  if (!data) return false;
  // Check expiry
  if (new Date(data.expires_at).getTime() < Date.now()) return false;
  return true;
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

async function handleAuthUrl(req: Request) {
  const body = await req.json().catch(() => ({}));
  const redirectUri = body.redirect_uri ?? '';
  if (!redirectUri) return err('redirect_uri required');

  const state = crypto.randomUUID();
  await saveState(state); // store for CSRF verification on callback

  const params = new URLSearchParams({
    client_id: QB_CLIENT_ID,
    response_type: 'code',
    scope: QB_SCOPE,
    redirect_uri: redirectUri,
    state,
  });
  const url = `https://appcenter.intuit.com/connect/oauth2?${params}`;
  return json({ url, state });
}

async function handleCallback(req: Request) {
  const body = await req.json().catch(() => ({}));
  const { code, realm_id, redirect_uri, state } = body;
  if (!code || !realm_id || !redirect_uri) return err('code, realm_id, and redirect_uri required');

  // CSRF check (scenario d) — reject if state missing or doesn't match what we issued
  if (!state) {
    await logError({ action: 'callback_csrf', error_message: 'Missing state parameter', context: { realm_id } });
    return err('Missing state parameter — possible CSRF attempt', 400);
  }
  const stateValid = await verifyAndConsumeState(state);
  if (!stateValid) {
    await logError({ action: 'callback_csrf', error_message: 'Invalid or expired state', context: { realm_id, state } });
    return err('Invalid or expired state parameter — possible CSRF attempt', 400);
  }

  const creds = btoa(`${QB_CLIENT_ID}:${QB_CLIENT_SECRET}`);
  const res = await fetch(QB_TOKEN_URL, {
    method: 'POST',
    headers: {
      'Authorization': `Basic ${creds}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri,
    }),
  });

  const data = await res.json();

  // Invalid grant on initial code exchange (scenario c) — code already used or expired
  if (!res.ok || !data.access_token) {
    const errorCode = data.error ?? '';
    const detail = data.error_description ?? errorCode ?? 'Token exchange failed';
    const intuitTid = res.headers.get('intuit_tid') ?? undefined;
    await logError({
      action: 'callback',
      intuit_tid: intuitTid,
      http_status: res.status,
      error_code: errorCode,
      error_message: detail,
    });
    if (errorCode === 'invalid_grant') {
      return err(`Authorization code already used or expired. Please reconnect QuickBooks. (${detail})`, 400);
    }
    return err(detail, 400);
  }

  const expiresAt = Date.now() + data.expires_in * 1000;
  await saveTokens(realm_id, data.access_token, data.refresh_token, expiresAt);
  return json({ ok: true, realm_id });
}

async function handleSearch(req: Request) {
  const body = await req.json().catch(() => ({}));
  const { query } = body;
  if (!query || query.trim().length < 2) return err('query must be at least 2 characters');

  const row = await loadTokens();
  if (!row) return err('QB not connected — please connect QuickBooks first', 401);

  let accessToken: string;
  try {
    accessToken = await getValidAccessToken();
  } catch (e) {
    // Refresh token expired or invalid_grant — tokens already cleared, tell app to reconnect
    const isAuthError = e instanceof RefreshTokenExpiredError || e instanceof InvalidGrantError;
    return err((e as Error).message, isAuthError ? 401 : 500);
  }

  const sql = encodeURIComponent(
    `SELECT Id, DisplayName, PrimaryEmailAddr, PrimaryPhone, BillAddr FROM Customer WHERE DisplayName LIKE '%${query.replace(/'/g, "''")}%' MAXRESULTS 20`
  );

  const apiRes = await fetch(
    `${QB_API_BASE}/${row.realm_id}/query?query=${sql}&minorversion=65`,
    {
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Accept': 'application/json',
      },
    }
  );

  const intuitTid = apiRes.headers.get('intuit_tid') ?? undefined;
  const apiData = await apiRes.json();

  if (!apiRes.ok) {
    // Expired access token slipped through (scenario a) — try one refresh
    if (apiRes.status === 401) {
      try {
        const fresh = await refreshAccessToken(row);
        const retry = await fetch(
          `${QB_API_BASE}/${row.realm_id}/query?query=${sql}&minorversion=65`,
          { headers: { 'Authorization': `Bearer ${fresh}`, 'Accept': 'application/json' } }
        );
        const retryTid = retry.headers.get('intuit_tid') ?? undefined;
        const retryData = await retry.json();
        if (!retry.ok) {
          const faultErrors = retryData?.Fault?.Error ?? retryData?.fault?.error;
          await logError({
            action: 'search_retry',
            intuit_tid: retryTid,
            http_status: retry.status,
            error_code: faultErrors?.[0]?.code ?? String(retry.status),
            error_message: faultErrors?.[0]?.Message ?? faultErrors?.[0]?.message ?? 'Retry failed',
            fault_errors: faultErrors,
            context: { query },
          });
          return err('QB session expired — please reconnect QuickBooks', 401);
        }
        return json({ customers: (retryData?.QueryResponse?.Customer ?? []).map(mapCustomer) });
      } catch (e) {
        // RefreshTokenExpiredError or InvalidGrantError — tokens already cleared
        return err((e as Error).message, 401);
      }
    }

    // All other QB API errors — capture full fault detail including all error objects,
    // validation errors, and the intuit_tid for support troubleshooting.
    const faultErrors = apiData?.Fault?.Error ?? apiData?.fault?.error ?? [];
    const firstCode = faultErrors?.[0]?.code ?? faultErrors?.[0]?.errorCode ?? String(apiRes.status);
    const firstMessage = faultErrors?.[0]?.Message ?? faultErrors?.[0]?.message
      ?? apiData?.message ?? JSON.stringify(apiData);

    await logError({
      action: 'search',
      intuit_tid: intuitTid,
      http_status: apiRes.status,
      error_code: firstCode,
      error_message: firstMessage,
      fault_errors: faultErrors,      // full array, not just [0]
      context: { query, realm_id: row.realm_id },
    });

    // Surface a clean message to the client; full detail is in the log
    return err(`QB API error (${apiRes.status}): ${firstMessage}`, 502);
  }

  return json({ customers: (apiData?.QueryResponse?.Customer ?? []).map(mapCustomer) });
}

function mapCustomer(c: Record<string, unknown>) {
  const addr = c.BillAddr as Record<string, string> | undefined;
  const phone = (c.PrimaryPhone as Record<string, string> | undefined)?.FreeFormNumber ?? '';
  const email = (c.PrimaryEmailAddr as Record<string, string> | undefined)?.Address ?? '';
  const line1 = addr?.Line1 ?? '';
  const city = addr?.City ?? '';
  const state = addr?.CountrySubDivisionCode ?? '';
  const zip = addr?.PostalCode ?? '';
  const address = [line1, city, state, zip].filter(Boolean).join(', ');
  return { id: c.Id, name: c.DisplayName, phone, email, address };
}

// ---------------------------------------------------------------------------
// Financials — revenue, payments, outstanding invoices for a date range
// ---------------------------------------------------------------------------

type QbQueryResponse = { QueryResponse?: Record<string, unknown[]> };

async function handleFinancials(req: Request) {
  const body = await req.json().catch(() => ({}));
  const { start_date, end_date } = body; // ISO date strings e.g. "2026-01-01"
  if (!start_date || !end_date) return err('start_date and end_date required');

  const row = await loadTokens();
  if (!row) return err('QB not connected', 401);

  let accessToken: string;
  try {
    accessToken = await getValidAccessToken();
  } catch (e) {
    const isAuthError = e instanceof RefreshTokenExpiredError || e instanceof InvalidGrantError;
    return err((e as Error).message, isAuthError ? 401 : 500);
  }

  // Helper to run a QB SQL query
  async function qbQuery(sql: string): Promise<{ data: unknown; tid: string | null }> {
    const res = await fetch(
      `${QB_API_BASE}/${row!.realm_id}/query?query=${encodeURIComponent(sql)}&minorversion=65`,
      { headers: { 'Authorization': `Bearer ${accessToken}`, 'Accept': 'application/json' } }
    );
    const tid = res.headers.get('intuit_tid');
    const data = await res.json();
    if (!res.ok) {
      const faultErrors = data?.Fault?.Error ?? [];
      await logError({
        action: 'financials_query',
        intuit_tid: tid ?? undefined,
        http_status: res.status,
        error_code: faultErrors[0]?.code ?? String(res.status),
        error_message: faultErrors[0]?.Message ?? 'QB query failed',
        fault_errors: faultErrors,
        context: { sql: sql.substring(0, 100) },
      });
      throw new Error(faultErrors[0]?.Message ?? 'QB query failed');
    }
    return { data, tid };
  }

  try {
    // 1. Invoices created in range — to calculate billed revenue
    const invoiceSql = `SELECT Id, TotalAmt, Balance, DueDate, TxnDate FROM Invoice WHERE TxnDate >= '${start_date}' AND TxnDate <= '${end_date}' MAXRESULTS 1000`;
    // 2. Payments received in range
    const paymentSql = `SELECT Id, TotalAmt, TxnDate FROM Payment WHERE TxnDate >= '${start_date}' AND TxnDate <= '${end_date}' MAXRESULTS 1000`;

    const [invoiceRes, paymentRes] = await Promise.all([
      qbQuery(invoiceSql),
      qbQuery(paymentSql),
    ]);

    const invoices = ((invoiceRes.data as QbQueryResponse)?.QueryResponse?.['Invoice'] ?? []) as Record<string, unknown>[];
    const payments = ((paymentRes.data as QbQueryResponse)?.QueryResponse?.['Payment'] ?? []) as Record<string, unknown>[];

    // Aggregate
    let totalBilled = 0;
    let totalOutstanding = 0;
    let invoiceCount = 0;
    for (const inv of invoices as Record<string, unknown>[]) {
      const amt = parseFloat(String(inv.TotalAmt ?? 0));
      const bal = parseFloat(String(inv.Balance ?? 0));
      totalBilled += amt;
      totalOutstanding += bal;
      invoiceCount++;
    }

    let totalCollected = 0;
    let paymentCount = 0;
    for (const p of payments as Record<string, unknown>[]) {
      totalCollected += parseFloat(String(p.TotalAmt ?? 0));
      paymentCount++;
    }

    // Outstanding invoices (any unpaid, not just in this range) — separate query
    const outstandingSql = `SELECT Id, TotalAmt, Balance, DueDate, CustomerRef FROM Invoice WHERE Balance > '0' MAXRESULTS 100`;
    const outstandingRes = await qbQuery(outstandingSql);
    const outstanding = ((outstandingRes.data as QbQueryResponse)?.QueryResponse?.['Invoice'] ?? []) as Record<string, unknown>[];
    const totalOwed = (outstanding as Record<string, unknown>[]).reduce(
      (sum, inv) => sum + parseFloat(String(inv.Balance ?? 0)), 0
    );
    const overdueCount = (outstanding as Record<string, unknown>[]).filter((inv) => {
      const due = inv.DueDate ? new Date(String(inv.DueDate)) : null;
      return due && due < new Date();
    }).length;

    return json({
      period: { start_date, end_date },
      billed: Math.round(totalBilled * 100) / 100,
      collected: Math.round(totalCollected * 100) / 100,
      outstanding_in_period: Math.round(totalOutstanding * 100) / 100,
      invoice_count: invoiceCount,
      payment_count: paymentCount,
      total_owed: Math.round(totalOwed * 100) / 100,
      overdue_count: overdueCount,
    });
  } catch (e) {
    return err((e as Error).message, 502);
  }
}

// ---------------------------------------------------------------------------
// Append a note to a QB customer record
// ---------------------------------------------------------------------------

async function handleAppendNote(req: Request) {
  const body = await req.json().catch(() => ({}));
  const { qb_customer_id, note } = body;
  if (!qb_customer_id || !note) return err('qb_customer_id and note required');

  const row = await loadTokens();
  if (!row) return err('QB not connected', 401);

  let accessToken: string;
  try {
    accessToken = await getValidAccessToken();
  } catch (e) {
    const isAuthError = e instanceof RefreshTokenExpiredError || e instanceof InvalidGrantError;
    return err((e as Error).message, isAuthError ? 401 : 500);
  }

  // Fetch current customer to get SyncToken and existing notes
  const getRes = await fetch(
    `${QB_API_BASE}/${row.realm_id}/customer/${qb_customer_id}?minorversion=65`,
    { headers: { 'Authorization': `Bearer ${accessToken}`, 'Accept': 'application/json' } }
  );
  const getTid = getRes.headers.get('intuit_tid');
  const getData = await getRes.json();

  if (!getRes.ok) {
    const faultErrors = getData?.Fault?.Error ?? [];
    await logError({
      action: 'append_note_get',
      intuit_tid: getTid ?? undefined,
      http_status: getRes.status,
      error_code: faultErrors[0]?.code ?? String(getRes.status),
      error_message: faultErrors[0]?.Message ?? 'Failed to fetch customer',
      fault_errors: faultErrors,
      context: { qb_customer_id },
    });
    return err(`Failed to fetch QB customer: ${faultErrors[0]?.Message ?? getRes.status}`, 502);
  }

  const customer = getData.Customer;
  const existingNotes: string = customer?.Notes ?? '';
  const timestamp = new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  const newNotes = existingNotes
    ? `${existingNotes}\n\n[${timestamp}] ${note}`
    : `[${timestamp}] ${note}`;

  // Sparse update — only send fields we're changing + SyncToken
  const updateRes = await fetch(
    `${QB_API_BASE}/${row.realm_id}/customer?minorversion=65`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        Id: qb_customer_id,
        SyncToken: customer.SyncToken,
        sparse: true,
        Notes: newNotes,
      }),
    }
  );
  const updateTid = updateRes.headers.get('intuit_tid');
  const updateData = await updateRes.json();

  if (!updateRes.ok) {
    const faultErrors = updateData?.Fault?.Error ?? [];
    await logError({
      action: 'append_note_update',
      intuit_tid: updateTid ?? undefined,
      http_status: updateRes.status,
      error_code: faultErrors[0]?.code ?? String(updateRes.status),
      error_message: faultErrors[0]?.Message ?? 'Failed to update customer',
      fault_errors: faultErrors,
      context: { qb_customer_id },
    });
    return err(`Failed to update QB customer notes: ${faultErrors[0]?.Message ?? updateRes.status}`, 502);
  }

  return json({ ok: true });
}

// ---------------------------------------------------------------------------
// Customer summary — pulls QB invoice history + notes for service call context
// ---------------------------------------------------------------------------

async function handleCustomerSummary(req: Request) {
  const body = await req.json().catch(() => ({}));
  const { qb_customer_id } = body;
  if (!qb_customer_id) return err('qb_customer_id required');

  const row = await loadTokens();
  if (!row) return err('QB not connected', 401);

  let accessToken: string;
  try {
    accessToken = await getValidAccessToken();
  } catch (e) {
    const isAuthError = e instanceof RefreshTokenExpiredError || e instanceof InvalidGrantError;
    return err((e as Error).message, isAuthError ? 401 : 500);
  }

  // Fetch customer record (name, notes, balance)
  const custRes = await fetch(
    `${QB_API_BASE}/${row.realm_id}/customer/${qb_customer_id}?minorversion=65`,
    { headers: { 'Authorization': `Bearer ${accessToken}`, 'Accept': 'application/json' } }
  );
  const custTid = custRes.headers.get('intuit_tid');
  const custData = await custRes.json();
  if (!custRes.ok) {
    const faultErrors = custData?.Fault?.Error ?? [];
    await logError({
      action: 'customer_summary_get',
      intuit_tid: custTid ?? undefined,
      http_status: custRes.status,
      error_code: faultErrors[0]?.code ?? String(custRes.status),
      error_message: faultErrors[0]?.Message ?? 'Failed to fetch customer',
      fault_errors: faultErrors,
      context: { qb_customer_id },
    });
    return err(`Failed to fetch QB customer: ${faultErrors[0]?.Message ?? custRes.status}`, 502);
  }
  const customer = custData.Customer;

  // Fetch last 5 invoices for this customer
  const invSql = `SELECT Id, TxnDate, TotalAmt, Balance, PrivateNote FROM Invoice WHERE CustomerRef = '${qb_customer_id}' ORDERBY TxnDate DESC MAXRESULTS 5`;
  const invRes = await fetch(
    `${QB_API_BASE}/${row.realm_id}/query?query=${encodeURIComponent(invSql)}&minorversion=65`,
    { headers: { 'Authorization': `Bearer ${accessToken}`, 'Accept': 'application/json' } }
  );
  const invData = await invRes.json();
  const invoices = ((invData as QbQueryResponse)?.QueryResponse?.['Invoice'] ?? []) as Record<string, unknown>[];

  return json({
    customer_name: customer?.DisplayName ?? '',
    balance: customer?.Balance ?? 0,
    notes: customer?.Notes ?? '',
    invoices: invoices.map((inv) => ({
      date: inv.TxnDate,
      amount: inv.TotalAmt,
      balance: inv.Balance,
      note: inv.PrivateNote ?? '',
    })),
  });
}

async function handleStatus() {
  const row = await loadTokens();
  return json({ connected: !!row, realm_id: row?.realm_id ?? null });
}

async function handleDisconnect() {
  await clearTokens();
  return json({ ok: true });
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS });
  }

  const url = new URL(req.url);
  const action = url.pathname.split('/').pop();

  try {
    switch (action) {
      case 'auth-url':   return await handleAuthUrl(req);
      case 'callback':   return await handleCallback(req);
      case 'search':     return await handleSearch(req);
      case 'financials':    return await handleFinancials(req);
      case 'append-note':       return await handleAppendNote(req);
      case 'customer-summary':  return await handleCustomerSummary(req);
      case 'status':        return await handleStatus();
      case 'disconnect': return await handleDisconnect();
      default:           return err('Unknown action', 404);
    }
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    await logError({ action: action ?? 'unknown', error_message: msg, context: { stack: (e as Error).stack } });
    return err(msg, 500);
  }
});
