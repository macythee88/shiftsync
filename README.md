# ShiftSync 餐飲排班與考勤（Vercel + Supabase）

純靜態網站（index.html），沒有建置步驟。

## 1. Supabase
1. 建立專案，打開 SQL Editor，貼上並執行 `supabase/schema.sql`。
2. Authentication → Sign In / Providers：保留 Email，關閉「Allow new users to sign up」。
3. Authentication → Users → Add user：建立店長帳號（勾選 Auto Confirm）。
4. SQL Editor 執行：`insert into managers(email) values ('店長的email');`
5. Project Settings → API：複製 Project URL 與 anon public key，填入 `config.js`。

## 2. 推到 Git 並部署
1. 這個資料夾 `git init`、commit、push 到 GitHub。
2. Vercel → Add New Project → 匯入該 repo，Framework 選 Other，不需要 build，Deploy。

## 3. 網域 staff-xc.upin-global.com
1. 先移除 WordPress.com 中 `staff-xc` 原有的連接與 DNS 記錄。
2. Vercel 專案 → Settings → Domains → 新增 `staff-xc.upin-global.com`，記下它顯示的 CNAME 值。
3. WordPress.com → Domains → upin-global.com → DNS records：新增 CNAME，名稱 `staff-xc`，值填 Vercel 顯示的內容。

## 4. 部署 Edge Function（新增/刪除員工、重設密碼）
需要先安裝 Supabase CLI。在專案資料夾執行：
```
supabase login
supabase link --project-ref <你的 project ref>
supabase functions deploy manage-staff
```
函式內的 SUPABASE_URL、SUPABASE_ANON_KEY、SUPABASE_SERVICE_ROLE_KEY 由 Supabase 自動提供，不需要另外設定，也不會出現在前端。

## 5. 新增員工
店長登入 → 店長端 → 員工管理，填姓名、職位、時薪、Email 與臨時密碼，按「新增員工」，系統會同時建立登入帳號。
員工用該 Email 與密碼登入，只會看到自己的排班；店長可在「員工管理」重設密碼或刪除員工（會一併刪除登入帳號）。
