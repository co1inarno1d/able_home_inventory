// netlify/functions/apps_script_proxy.js

// Your existing Google Apps Script web app URL:
const SCRIPT_URL = "https://script.google.com/macros/s/AKfycbxfBAlm90vMrh0I1xiIh3fJtbesTmxcfHBHxcwpYmKunCIu270_xgQUE0WFbM9XdMagCg/exec";

exports.handler = async (event, context) => {
  const method = event.httpMethod || "GET";

  // Handle CORS preflight requests
  if (method === "OPTIONS") {
    return {
      statusCode: 200,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
      },
      body: "",
    };
  }

  try {
    // Forward query string for GET/HEAD requests
    const query = event.rawQuery ? `?${event.rawQuery}` : "";
    const targetUrl = SCRIPT_URL + query;

    // Pass through content-type if present
    const headers = {
      "Content-Type": event.headers["content-type"] || "application/json",
    };

    const fetchOptions = {
      method,
      headers,
    };

    // Forward body for non-GET requests (POST)
    if (method !== "GET" && method !== "HEAD") {
      fetchOptions.body = event.body;
    }

    // Send the request to Apps Script
    const res = await fetch(targetUrl, fetchOptions);
    const text = await res.text();

    return {
      statusCode: res.status,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
      },
      body: text,
    };
  } catch (err) {
    console.error("Proxy error:", err);
    return {
      statusCode: 500,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
      body: JSON.stringify({ status: "error", message: String(err) }),
    };
  }
};