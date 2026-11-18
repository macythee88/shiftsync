-- ShiftSync GPS + fixed QR attendance (Phase 1)
-- Additive migration draft. Review and run manually in Supabase SQL Editor only after approval.
-- Does NOT drop or rewrite existing tables or historical emp_data.punches.
-- Store timezone follows the existing punch_me() behavior: Asia/Taipei.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.stores (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  radius_m integer not null default 15 check (radius_m between 1 and 500),
  timezone text not null default 'Asia/Taipei',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Seed the one confirmed store. ON CONFLICT DO NOTHING avoids overwriting
-- any store coordinates that an administrator may later correct.
insert into public.stores
  (slug, name, latitude, longitude, radius_m, timezone)
values
  ('main-store', '撈汁黍到山＋東北麻辣燙', 25.0876558, 121.4703595, 15, 'Asia/Taipei')
on conflict (slug) do nothing;

-- Only a SHA-256 hash is stored. The raw QR token is returned once by
-- issue_fixed_attendance_qr() and must be encoded into the printed QR image.
create table if not exists public.attendance_qr (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id),
  token_hash bytea not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  disabled_at timestamptz
);

create unique index if not exists attendance_qr_one_active_per_store
  on public.attendance_qr(store_id) where is_active;

-- Audit log: successful punches, failed attempts, and manager corrections.
create table if not exists public.attendance_events (
  id bigint generated always as identity primary key,
  emp_id text not null references public.emp_data(emp_id),
  store_id uuid references public.stores(id),
  work_date date not null,
  punch_type text not null check (punch_type in ('in', 'out')),
  source text not null check (source in ('employee_qr_gps', 'manager_manual')),
  success boolean not null,
  failure_reason text,
  recorded_at timestamptz not null default now(),
  local_time numeric(6,2),
  latitude double precision,
  longitude double precision,
  accuracy_m double precision,
  distance_m double precision,
  qr_valid boolean,
  previous_time numeric(6,2),
  note text,
  performed_by uuid references auth.users(id)
);

create index if not exists attendance_events_emp_date_idx
  on public.attendance_events(emp_id, work_date desc, recorded_at desc);

alter table public.stores enable row level security;
alter table public.attendance_qr enable row level security;
alter table public.attendance_events enable row level security;

drop policy if exists stores_read_staff on public.stores;
create policy stores_read_staff on public.stores
  for select to authenticated
  using (
    public.is_mgr()
    or exists (select 1 from public.emp_data e where e.user_id = auth.uid())
  );

drop policy if exists attendance_events_read_self_or_manager on public.attendance_events;
create policy attendance_events_read_self_or_manager on public.attendance_events
  for select to authenticated
  using (
    public.is_mgr()
    or exists (
      select 1 from public.emp_data e
      where e.emp_id = attendance_events.emp_id
        and e.user_id = auth.uid()
    )
  );

-- No direct client writes to store settings, QR credentials, or attendance audit.
revoke all on public.stores from anon, authenticated;
grant select on public.stores to authenticated;
revoke all on public.attendance_qr from anon, authenticated;
revoke all on public.attendance_events from anon, authenticated;
grant select on public.attendance_events to authenticated;
grant usage, select on sequence public.attendance_events_id_seq to authenticated;

create or replace function public.issue_fixed_attendance_qr(p_store_id uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token text;
begin
  if not public.is_mgr() then
    raise exception 'manager_only';
  end if;

  if not exists (select 1 from public.stores where id = p_store_id and is_active) then
    raise exception 'store_not_found_or_inactive';
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  update public.attendance_qr
     set is_active = false, disabled_at = now()
   where store_id = p_store_id and is_active;

  insert into public.attendance_qr(store_id, token_hash)
  values (
    p_store_id,
    extensions.digest(convert_to(v_token, 'UTF8'), 'sha256')
  );

  -- Display this value once as the QR payload. Do not put it in source code.
  return v_token;
end;
$$;

create or replace function public.record_attendance_with_qr(
  p_qr_token text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m double precision
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_emp_id text;
  v_store_id uuid;
  v_store_lat double precision;
  v_store_lon double precision;
  v_radius integer;
  v_timezone text;
  v_distance double precision;
  v_local timestamp;
  v_work_date date;
  v_local_time numeric(6,2);
  v_punches jsonb;
  v_day jsonb;
  v_action text;
  v_reason text;
  v_qr_valid boolean := false;
begin
  if auth.uid() is null then
    raise exception 'authentication_required';
  end if;

  select e.emp_id
    into v_emp_id
    from public.emp_data e
   where e.user_id = auth.uid()
   limit 1
   for update;

  if v_emp_id is null then
    raise exception 'employee_account_not_linked';
  end if;

  -- Resolve QR token. The raw token is never stored.
  if p_qr_token is not null and length(p_qr_token) between 32 and 128 then
    select s.id, s.latitude, s.longitude, s.radius_m, s.timezone
      into v_store_id, v_store_lat, v_store_lon, v_radius, v_timezone
      from public.attendance_qr q
      join public.stores s on s.id = q.store_id
     where q.token_hash = extensions.digest(convert_to(p_qr_token, 'UTF8'), 'sha256')
       and q.is_active
       and s.is_active
     limit 1;
    v_qr_valid := found;
  end if;

  v_timezone := coalesce(v_timezone, 'Asia/Taipei');
  v_local := now() at time zone v_timezone;
  v_work_date := v_local::date;
  v_local_time := round(
    extract(hour from v_local)
    + extract(minute from v_local) / 60.0
    + extract(second from v_local) / 3600.0,
    2
  );

  if not v_qr_valid then
    v_reason := 'invalid_qr';
  elsif p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90
     or p_longitude not between -180 and 180 then
    v_reason := 'invalid_location';
  elsif p_accuracy_m is null or p_accuracy_m < 0 or p_accuracy_m > 20 then
    v_reason := 'gps_accuracy_too_low';
  else
    -- Haversine distance is calculated on the server from submitted coordinates.
    v_distance := 6371000 * 2 * asin(sqrt(least(1.0, greatest(0.0,
      power(sin(radians(p_latitude - v_store_lat) / 2), 2)
      + cos(radians(v_store_lat)) * cos(radians(p_latitude))
      * power(sin(radians(p_longitude - v_store_lon) / 2), 2)
    ))));

    if v_distance > v_radius then
      v_reason := 'outside_store_radius';
    end if;
  end if;

  select coalesce(e.punches, '{}'::jsonb)
    into v_punches
    from public.emp_data e
   where e.emp_id = v_emp_id;

  v_day := coalesce(v_punches -> v_work_date::text, '{}'::jsonb);

  if v_reason is null then
    if v_day ? 'o' then
      v_reason := 'already_checked_out';
    else
      v_action := case when v_day ? 'i' then 'out' else 'in' end;
    end if;
  end if;

  if v_reason is not null then
    insert into public.attendance_events
      (emp_id, store_id, work_date, punch_type, source, success,
       failure_reason, latitude, longitude, accuracy_m, distance_m,
       qr_valid, performed_by)
    values
      (v_emp_id, v_store_id, v_work_date, coalesce(v_action, 'in'),
       'employee_qr_gps', false, v_reason,
       p_latitude, p_longitude, p_accuracy_m, v_distance,
       v_qr_valid, auth.uid());

    return jsonb_build_object(
      'ok', false,
      'reason', v_reason,
      'distance_m', v_distance,
      'radius_m', v_radius
    );
  end if;

  v_day := v_day || jsonb_build_object(v_action, v_local_time);
  perform set_config('app.bypass', '1', true);

  update public.emp_data
     set punches = jsonb_set(v_punches, array[v_work_date::text], v_day, true)
   where emp_id = v_emp_id;

  insert into public.attendance_events
    (emp_id, store_id, work_date, punch_type, source, success,
     local_time, latitude, longitude, accuracy_m, distance_m,
     qr_valid, performed_by)
  values
    (v_emp_id, v_store_id, v_work_date, v_action, 'employee_qr_gps', true,
     v_local_time, p_latitude, p_longitude, p_accuracy_m, v_distance,
     true, auth.uid());

  return jsonb_build_object(
    'ok', true,
    'action', v_action,
    'work_date', v_work_date,
    'local_time', v_local_time,
    'distance_m', round(v_distance::numeric, 1)
  );
end;
$$;

create or replace function public.manager_adjust_attendance(
  p_emp_id text,
  p_work_date date,
  p_action text,
  p_time time without time zone,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_punches jsonb;
  v_day jsonb;
  v_previous numeric(6,2);
  v_new_time numeric(6,2);
begin
  if not public.is_mgr() then
    raise exception 'manager_only';
  end if;
  if p_action not in ('in', 'out') then
    raise exception 'invalid_punch_action';
  end if;
  if p_time is null then
    raise exception 'time_required';
  end if;
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception 'correction_reason_required';
  end if;

  select e.punches
    into v_punches
    from public.emp_data e
   where e.emp_id = p_emp_id
   for update;

  if not found then
    raise exception 'employee_not_found';
  end if;

  v_punches := coalesce(v_punches, '{}'::jsonb);
  v_day := coalesce(v_punches -> p_work_date::text, '{}'::jsonb);
  v_previous := nullif(v_day ->> p_action, '')::numeric;
  v_new_time := round(
    extract(hour from p_time)
    + extract(minute from p_time) / 60.0
    + extract(second from p_time) / 3600.0,
    2
  );

  v_day := v_day || jsonb_build_object(p_action, v_new_time);
  perform set_config('app.bypass', '1', true);

  update public.emp_data
     set punches = jsonb_set(v_punches, array[p_work_date::text], v_day, true)
   where emp_id = p_emp_id;

  insert into public.attendance_events
    (emp_id, store_id, work_date, punch_type, source, success,
     local_time, previous_time, note, performed_by)
  values
    (p_emp_id,
     (select id from public.stores where slug = 'main-store' limit 1),
     p_work_date, p_action, 'manager_manual', true,
     v_new_time, v_previous, trim(p_reason), auth.uid());

  return jsonb_build_object(
    'ok', true,
    'previous_time', v_previous,
    'new_time', v_new_time,
    'work_date', p_work_date
  );
end;
$$;

revoke all on function public.issue_fixed_attendance_qr(uuid) from public, anon;
revoke all on function public.record_attendance_with_qr(text, double precision, double precision, double precision) from public, anon;
revoke all on function public.manager_adjust_attendance(text, date, text, time without time zone, text) from public, anon;
grant execute on function public.issue_fixed_attendance_qr(uuid) to authenticated;
grant execute on function public.record_attendance_with_qr(text, double precision, double precision, double precision) to authenticated;
grant execute on function public.manager_adjust_attendance(text, date, text, time without time zone, text) to authenticated;

-- After reviewing this migration, the administrator can issue the one-time QR token:
-- select public.issue_fixed_attendance_qr(id) from public.stores where slug = 'main-store';
-- Keep the returned token private and encode it into the printed QR image.
