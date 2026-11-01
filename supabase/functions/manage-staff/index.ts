// 店長專用：新增員工(同時建立登入帳號)、刪除員工(同時刪除帳號)、重設密碼
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // 以呼叫者身分檢查是否為店長
    const me = createClient(url, anon, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: isMgr } = await me.rpc("is_mgr");
    if (!isMgr) return json({ error: "只有店長可以執行此操作" }, 403);

    const admin = createClient(url, svc, { auth: { persistSession: false } });
    const b = await req.json();

    if (b.action === "add") {
      const name = String(b.name ?? "").trim();
      const email = String(b.email ?? "").trim().toLowerCase();
      const pw = String(b.password ?? "");
      if (!name || !email || pw.length < 6) return json({ error: "請填姓名、Email，密碼至少 6 碼" }, 400);
      const c = await admin.auth.admin.createUser({ email, password: pw, email_confirm: true });
      if (c.error) return json({ error: c.error.message }, 400);
      const id = "e" + Date.now().toString(36);
      const i = await admin.from("emp_data").insert({
        emp_id: id, name, title: b.title || "員工", rate: Number(b.rate) || 0,
        email, user_id: c.data.user.id,
      });
      if (i.error) {
        await admin.auth.admin.deleteUser(c.data.user.id);
        return json({ error: i.error.message }, 400);
      }
      return json({ ok: true, emp_id: id });
    }

    if (b.action === "remove") {
      const r = await admin.from("emp_data").select("user_id,email").eq("emp_id", b.emp_id).maybeSingle();
      if (!r.data) return json({ error: "找不到這位員工" }, 404);
      // 店長自己的帳號不刪
      const m = await admin.from("managers").select("email").ilike("email", r.data.email ?? "").maybeSingle();
      await admin.from("emp_data").delete().eq("emp_id", b.emp_id);
      if (r.data.user_id && !m.data) await admin.auth.admin.deleteUser(r.data.user_id);
      return json({ ok: true });
    }

    if (b.action === "reset") {
      const pw = String(b.password ?? "");
      if (pw.length < 6) return json({ error: "密碼至少 6 碼" }, 400);
      const r = await admin.from("emp_data").select("user_id").eq("emp_id", b.emp_id).maybeSingle();
      if (!r.data?.user_id) return json({ error: "這位員工還沒有登入帳號" }, 400);
      const u = await admin.auth.admin.updateUserById(r.data.user_id, { password: pw });
      if (u.error) return json({ error: u.error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: "未知的操作" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
