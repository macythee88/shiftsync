import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    },
  });

type EventName =
  | "intent_submitted"
  | "intent_updated"
  | "intent_cancelled"
  | "intent_cancel_accepted"
  | "schedule_published"
  | "intent_adopted";

const labels: Record<EventName, string> = {
  intent_submitted: "提交了排班意向",
  intent_updated: "更新了排班意向",
  intent_cancelled: "申请取消排班意向",
  intent_cancel_accepted: "店长已确认取消意向",
  schedule_published: "店长已发布正式班表",
  intent_adopted: "店长已采纳您的排班意向",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const bearer = authHeader.replace(/^Bearer\s+/i, "");
    if (!bearer) return json({ error: "Authentication required" }, 401);

    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const accessToken = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN");
    if (!url || !anonKey || !serviceKey || !accessToken) {
      return json({ error: "LINE notifications are not configured yet" }, 503);
    }

    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${bearer}` } },
      auth: { persistSession: false },
    });
    const { data: authData, error: authError } = await caller.auth.getUser(bearer);
    if (authError || !authData.user) return json({ error: "Invalid session" }, 401);
    const { data: manager, error: managerError } = await caller.rpc("is_mgr");
    if (managerError) throw managerError;

    const body = await req.json();
    const event = String(body.event ?? "") as EventName;
    if (!(event in labels)) return json({ error: "Unsupported notification event" }, 400);

    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    let employee: { emp_id: string; name: string; user_id: string | null } | null = null;
    let recipientUserIds: string[] = [];

    if (event === "intent_submitted" || event === "intent_updated" || event === "intent_cancelled") {
      if (manager) return json({ error: "This event is for employee accounts only" }, 403);
      const { data, error } = await admin.from("emp_data")
        .select("emp_id,name,user_id").eq("user_id", authData.user.id).maybeSingle();
      if (error) throw error;
      employee = data;
      if (!employee) return json({ error: "No employee profile is linked to this account" }, 403);

      const { data: managerRows, error: mgrRowsError } = await admin.from("managers").select("email");
      if (mgrRowsError) throw mgrRowsError;
      for (const row of managerRows ?? []) {
        const { data: profile, error: profileError } = await admin.from("emp_data")
          .select("user_id").ilike("email", row.email).maybeSingle();
        if (profileError) throw profileError;
        if (profile?.user_id) recipientUserIds.push(profile.user_id);
      }
    } else {
      if (!manager) return json({ error: "Only managers can send this notification" }, 403);
      const empId = String(body.emp_id ?? "");
      if (!empId) return json({ error: "Missing employee ID" }, 400);
      const { data, error } = await admin.from("emp_data")
        .select("emp_id,name,user_id").eq("emp_id", empId).maybeSingle();
      if (error) throw error;
      employee = data;
      if (!employee?.user_id) return json({ error: "Employee has no linked login account" }, 404);
      recipientUserIds.push(employee.user_id);
    }

    const uniqueIds = [...new Set(recipientUserIds)];
    if (!uniqueIds.length) return json({ ok: true, sent: 0, skipped: "No linked recipients" });

    const { data: links, error: linkError } = await admin.from("line_accounts")
      .select("line_user_id").in("auth_user_id", uniqueIds).eq("is_following", true);
    if (linkError) throw linkError;
    const lineIds = [...new Set((links ?? []).map((x) => x.line_user_id))];
    if (!lineIds.length) return json({ ok: true, sent: 0, skipped: "Recipients have not followed the official account or linked LINE" });

    const workDate = String(body.work_date ?? "");
    const detail = typeof body.summary === "string" ? body.summary.slice(0, 500) : "";
    const message = [
      `ShiftSync：${employee?.name ?? "員工"}${labels[event]}`,
      workDate ? `日期：${workDate}` : "",
      detail,
      "請開啟 ShiftSync 查看詳情。",
    ].filter(Boolean).join("\n");

    const results = await Promise.all(lineIds.map(async (to) => {
      const response = await fetch("https://api.line.me/v2/bot/message/push", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ to, messages: [{ type: "text", text: message }] }),
      });
      return { ok: response.ok, status: response.status };
    }));
    const sent = results.filter((x) => x.ok).length;
    const failed = results.length - sent;
    if (failed) console.error("Some LINE pushes failed", results.filter((x) => !x.ok));
    return json({ ok: true, sent, failed });
  } catch (error) {
    console.error("LINE notify error", error);
    // The app's existing in-app notifications remain the source of truth.
    return json({ error: "LINE push failed; in-app notification is unaffected" }, 502);
  }
});
