import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders,
  });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const bearer = authHeader.replace(/^Bearer\s+/i, "");
    if (!bearer) return json({ error: "Please sign in to ShiftSync first" }, 401);

    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const loginChannelId = Deno.env.get("LINE_LOGIN_CHANNEL_ID");
    if (!url || !anonKey || !serviceKey || !loginChannelId) {
      return json({ error: "LINE account-linking is not configured yet" }, 500);
    }

    const userClient = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${bearer}` } },
      auth: { persistSession: false },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser(bearer);
    if (userError || !userData.user) return json({ error: "Invalid ShiftSync session" }, 401);

    const body = await req.json();
    const idToken = String(body.id_token ?? "");
    if (!idToken) return json({ error: "Missing LINE ID token" }, 400);

    // LINE verifies the ID token and audience. Never trust a userId supplied by the browser.
    const verifyBody = new URLSearchParams({ id_token: idToken, client_id: loginChannelId });
    const verifyResponse = await fetch("https://api.line.me/oauth2/v2.1/verify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: verifyBody,
    });
    if (!verifyResponse.ok) return json({ error: "LINE identity verification failed" }, 401);
    const identity = await verifyResponse.json();
    const lineUserId = String(identity.sub ?? "");
    if (!lineUserId) return json({ error: "LINE did not return a user identity" }, 401);

    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const { data: currentLink, error: currentError } = await admin
      .from("line_accounts").select("line_user_id").eq("auth_user_id", userData.user.id).maybeSingle();
    if (currentError) throw currentError;
    if (currentLink && currentLink.line_user_id !== lineUserId) {
      return json({ error: "This ShiftSync account is already linked to another LINE account. Contact the manager to change it." }, 409);
    }

    const { data: otherLink, error: otherError } = await admin
      .from("line_accounts").select("auth_user_id").eq("line_user_id", lineUserId).maybeSingle();
    if (otherError) throw otherError;
    if (otherLink?.auth_user_id && otherLink.auth_user_id !== userData.user.id) {
      return json({ error: "This LINE account is already linked to another ShiftSync account." }, 409);
    }

    const now = new Date().toISOString();
    const { error: saveError } = await admin.from("line_accounts").upsert({
      line_user_id: lineUserId,
      auth_user_id: userData.user.id,
      linked_at: now,
      updated_at: now,
    }, { onConflict: "line_user_id" });
    if (saveError) throw saveError;

    return json({ ok: true, linked: true });
  } catch (error) {
    console.error("LINE link error", error);
    return json({ error: "Could not link LINE account" }, 500);
  }
});
