// netlify/functions/apps_script_proxy.js

// Your existing Google Apps Script web app URL:
const SCRIPT_URL = "https://script.google.com/macros/s/AKfycbxfBAlm90vMrh0I1xiIh3fJtbesTmxcfHBHxcwpYmKunCIu270_xgQUE0WFbM9XdMagCg/exec";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
};

exports.handler = async (event, context) => {
  const method = event.httpMethod || "GET";

  // Handle CORS preflight requests
  if (method === "OPTIONS") {
    return { statusCode: 200, headers: CORS_HEADERS, body: "" };
  }

  try {
    const query = event.rawQuery ? `?${event.rawQuery}` : "";
    const body = (method !== "GET" && method !== "HEAD") ? event.body : undefined;
    const headers = {
      "Content-Type": event.headers["content-type"] || "application/json",
    };

    // First request — disable automatic redirect following so we can
    // re-POST the body to the redirect target. Apps Script responds to
    // POST /exec with a 302 to the actual run URL; that URL must also
    // receive the POST body so doPost(e) fires with the payload.
    let res = await fetch(SCRIPT_URL + query, {
      method,
      headers,
      body,
      redirect: "manual",
    });

    // Apps Script redirects POST /exec → 302 → run URL.
    // The run URL executes the script. We must re-POST the body to it so
    // doPost(e) fires with the original payload. Follow all redirects as POST.
    let hops = 0;
    while ((res.status === 301 || res.status === 302 || res.status === 303 ||
            res.status === 307 || res.status === 308) && hops < 3) {
      const location = res.headers.get("location");
      if (!location) break;
      res = await fetch(location, {
        method,
        headers,
        body,
        redirect: "manual",
      });
      hops++;
    }

    const text = await res.text();

    return {
      statusCode: res.status,
      headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      body: text,
    };
  } catch (err) {
    console.error("Proxy error:", err);
    return {
      statusCode: 500,
      headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      body: JSON.stringify({ status: "error", message: String(err) }),
    };
  }
};
