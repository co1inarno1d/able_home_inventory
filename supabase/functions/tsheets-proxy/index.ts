const TSHEETS_TOKEN = 'S.6__bc39aa448aae631d140c82d5a694c54b4fd94ebd';
const TSHEETS_BASE = 'https://rest.tsheets.com/api/v1';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  // Extract the TSheets path + query from the request URL
  // Expected: /tsheets-proxy/schedule_events?foo=bar
  //        → https://rest.tsheets.com/api/v1/schedule_events?foo=bar
  const url = new URL(req.url);
  const pathAfterProxy = url.pathname.replace(/^\/tsheets-proxy\/?/, '').replace(/^functions\/v1\/tsheets-proxy\/?/, '');
  const tsheetsUrl = `${TSHEETS_BASE}/${pathAfterProxy}${url.search}`;

  const tsheetsResp = await fetch(tsheetsUrl, {
    method: req.method,
    headers: {
      'Authorization': `Bearer ${TSHEETS_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: ['GET', 'HEAD', 'DELETE'].includes(req.method) ? undefined : await req.text(),
  });

  const body = await tsheetsResp.text();

  return new Response(body, {
    status: tsheetsResp.status,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'application/json',
    },
  });
});
