import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "Content-Type": "application/json", ...corsHeaders },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const channelId = Deno.env.get("LINE_LOGIN_CHANNEL_ID");
    if (!url || !serviceKey || !channelId) return json({ error: "LINE login is not configured" }, 500);

    const body = await req.json().catch(() => ({}));
    const idToken = String(body.id_token ?? "");
    if (!idToken) return json({ error: "Missing LINE ID token" }, 400);

    // Validate signature, audience, issuer and expiry with LINE. Never trust a client-supplied LINE user ID.
    const verify = await fetch("https://api.line.me/oauth2/v2.1/verify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ id_token: idToken, client_id: channelId }),
    });
    if (!verify.ok) return json({ error: "LINE identity verification failed" }, 401);
    const identity = await verify.json();
    const lineUserId = String(identity.sub ?? "");
    if (!lineUserId) return json({ error: "LINE identity is missing" }, 401);

    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: link, error: linkError } = await admin
      .from("line_accounts").select("auth_user_id").eq("line_user_id", lineUserId).maybeSingle();
    if (linkError) throw linkError;
    if (!link?.auth_user_id) {
      return json({ error: "This LINE account is not linked yet. Sign in with your ShiftSync email and password once from this LINE app first." }, 403);
    }

    const { data: userResult, error: userError } = await admin.auth.admin.getUserById(link.auth_user_id);
    if (userError || !userResult.user?.email || !userResult.user.email_confirmed_at) {
      return json({ error: "The linked ShiftSync account is unavailable. Please contact the manager." }, 403);
    }

    // Create a short-lived, single-use Supabase magic-link token. The browser only receives
    // the one-time token hash, never the service-role key or a reusable admin credential.
    const { data: generated, error: generateError } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email: userResult.user.email,
    });
    if (generateError) throw generateError;
    const tokenHash = generated?.properties?.hashed_token;
    if (!tokenHash) throw new Error("Supabase did not return a one-time token hash");
    return json({ ok: true, token_hash: tokenHash });
  } catch (error) {
    console.error("LINE login error", error);
    return json({ error: "Could not sign in with LINE. Please use email login." }, 500);
  }
});
