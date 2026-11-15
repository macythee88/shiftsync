import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function verifySignature(rawBody: string, signature: string, secret: string): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody)));
  const expected = toBase64(digest);
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method === "GET") return json({ ok: true, service: "ShiftSync LINE webhook" });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const secret = Deno.env.get("LINE_MESSAGING_CHANNEL_SECRET");
    const signature = req.headers.get("x-line-signature") ?? "";
    if (!secret || !signature) return json({ error: "Missing webhook configuration or signature" }, 401);

    // Verify the exact raw body before parsing JSON, as required by LINE.
    const rawBody = await req.text();
    if (!await verifySignature(rawBody, signature, secret)) {
      return json({ error: "Invalid LINE webhook signature" }, 401);
    }

    const payload = JSON.parse(rawBody);
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return json({ error: "Server configuration missing" }, 500);
    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

    for (const event of payload.events ?? []) {
      const lineUserId = event.source?.userId;
      if (!lineUserId) continue;

      if (event.type === "follow") {
        const { error } = await admin.from("line_accounts").upsert({
          line_user_id: lineUserId,
          is_following: true,
          followed_at: new Date().toISOString(),
          unfollowed_at: null,
          updated_at: new Date().toISOString(),
        }, { onConflict: "line_user_id" });
        if (error) throw error;
      } else if (event.type === "unfollow") {
        const { error } = await admin.from("line_accounts").update({
          is_following: false,
          unfollowed_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }).eq("line_user_id", lineUserId);
        if (error) throw error;
      }
    }

    return json({ ok: true });
  } catch (error) {
    console.error("LINE webhook error", error);
    return json({ error: "Webhook processing failed" }, 500);
  }
});
