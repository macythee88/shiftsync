-- LINE account mapping is private server-side data. Never expose LINE user IDs through employee queries.
create table if not exists public.line_accounts (
  line_user_id text primary key,
  auth_user_id uuid unique references auth.users(id) on delete cascade,
  linked_at timestamptz,
  is_following boolean not null default false,
  followed_at timestamptz,
  unfollowed_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists line_accounts_auth_user_id_idx
  on public.line_accounts(auth_user_id);
alter table public.line_accounts enable row level security;
revoke all on table public.line_accounts from anon, authenticated;
-- No client policies: only Edge Functions using the service-role key may read or write this table.
