-- ShiftSync security hardening migration
-- Safe to run on an existing production database: changes policies/functions only.
-- Does not delete, truncate, rewrite, or reseed employee or attendance records.

drop policy if exists emp_read on public.emp_data;
drop policy if exists emp_mgr on public.emp_data;
drop policy if exists emp_self on public.emp_data;

-- A manager can read all rows. A staff account can read only its own bound row.
create policy emp_read on public.emp_data
  for select
  using (public.is_mgr() or user_id = auth.uid());

create policy emp_mgr on public.emp_data
  for all
  using (public.is_mgr())
  with check (public.is_mgr());

create policy emp_self on public.emp_data
  for update
  using (user_id = auth.uid() and not public.is_mgr())
  with check (user_id = auth.uid() and not public.is_mgr());

-- The manager lookup and binding helpers are intentionally SECURITY DEFINER.
-- Restrict their execution to authenticated users; anon must not call them.
revoke all on function public.is_mgr() from public, anon;
grant execute on function public.is_mgr() to authenticated;
revoke all on function public.is_staff() from public, anon;
grant execute on function public.is_staff() to authenticated;
revoke all on function public.claim_me() from public, anon;
grant execute on function public.claim_me() to authenticated;
revoke all on function public.punch_me() from public, anon;
grant execute on function public.punch_me() to authenticated;
