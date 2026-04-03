const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const payload = await req.json();
    const record = payload.record;

    const message = [
      `Name: ${record.name}`,
      `Email: ${record.email}`,
      record.phone ? `Phone: ${record.phone}` : null,
      `Message: ${record.message}`,
      `Source: ${record.source === 'hero_form' ? 'Hero Form' : 'Contact Form'}`,
    ].filter(Boolean).join('\n');

    const pushRes = await fetch('https://api.pushover.net/1/messages.json', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        token: Deno.env.get('PUSHOVER_TOKEN'),
        user: Deno.env.get('PUSHOVER_USER_KEY'),
        title: `New Web Lead: ${record.name}`,
        message,
        priority: 0,
      }),
    });

    const pushBody = await pushRes.json();

    return new Response(JSON.stringify({ ok: true, pushover: pushBody }), {
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
