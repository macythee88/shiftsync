-- ShiftSync：在 Supabase 的 SQL Editor 整段貼上執行
create table if not exists managers(email text primary key);
create table if not exists cfg(id int primary key default 1 check(id=1), closed jsonb not null default '{"wd":[],"dates":{}}');
insert into cfg(id) values(1) on conflict do nothing;
create table if not exists emp_data(
 emp_id text primary key, name text not null, title text, rate numeric default 0,
 email text, user_id uuid references auth.users(id) on delete set null,
 av jsonb not null default '{}', off jsonb not null default '{}', acks jsonb not null default '{}',
 punches jsonb not null default '{}', sub jsonb not null default '{}', obj jsonb not null default '{}');
alter table managers enable row level security;
alter table cfg enable row level security;
alter table emp_data enable row level security;

create or replace function is_mgr() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from managers where lower(email)=lower(auth.email())) $$;
create or replace function is_staff() returns boolean language sql stable security definer set search_path=public as
$$ select is_mgr() or exists(select 1 from emp_data where user_id=auth.uid()) $$;

drop policy if exists cfg_read on cfg; drop policy if exists cfg_write on cfg;
drop policy if exists emp_read on emp_data; drop policy if exists emp_mgr on emp_data; drop policy if exists emp_self on emp_data;
create policy cfg_read on cfg for select using (is_mgr() or is_staff());
create policy cfg_write on cfg for all using (is_mgr()) with check (is_mgr());

-- Managers can access all employee rows; each employee can read only the row bound to their auth.uid().
-- Do not use is_staff() as a blanket emp_data read policy: that exposes every employee row to any staff account.
create policy emp_read on emp_data for select using (is_mgr() or user_id = auth.uid());
create policy emp_mgr on emp_data for all using (is_mgr()) with check (is_mgr());
create policy emp_self on emp_data for update using (user_id = auth.uid() and not is_mgr())
 with check (user_id = auth.uid() and not is_mgr());

-- 員工只能改自己的申報(av)、意向(sub/obj)、確認(acks)；班次、打卡、薪資、身分一律還原
create or replace function emp_guard() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if not is_mgr() and coalesce(current_setting('app.bypass',true),'')<>'1' then
  new.emp_id:=old.emp_id; new.name:=old.name; new.title:=old.title; new.rate:=old.rate;
  new.email:=old.email; new.user_id:=old.user_id; new.off:=old.off; new.punches:=old.punches;
 end if;
 return new;
end $$;
drop trigger if exists emp_guard on emp_data;
create trigger emp_guard before update on emp_data for each row execute function emp_guard();

-- 登入時把 Email 相符的員工資料綁到這個帳號
create or replace function claim_me() returns void language plpgsql security definer set search_path=public as $$
begin
 perform set_config('app.bypass','1',true);
 update emp_data set user_id=auth.uid() where user_id is null and lower(email)=lower(auth.email());
end $$;

-- 員工打卡：時間由伺服器（台北時區）記錄，無法自行改時間
create or replace function punch_me() returns void language plpgsql security definer set search_path=public as $$
declare e text; z timestamp:=now() at time zone 'Asia/Taipei'; d text:=to_char(z,'YYYY-MM-DD');
 h numeric:=extract(hour from z)+extract(minute from z)/60.0; cur jsonb;
begin
 select emp_id into e from emp_data where user_id=auth.uid();
 if e is null then raise exception 'not bound'; end if;
 select coalesce(punches->d,'{}'::jsonb) into cur from emp_data where emp_id=e;
 if cur ? 'o' then return; end if;
 cur:=cur||jsonb_build_object(case when cur ? 'i' then 'o' else 'i' end,round(h,2));
 perform set_config('app.bypass','1',true);
 update emp_data set punches=jsonb_set(punches,array[d],cur,true) where emp_id=e;
end $$;
