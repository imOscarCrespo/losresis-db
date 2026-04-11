do $$
begin
  if not exists (
    select 1
    from pg_type
    where typname = 'resident_lifecycle_state'
      and typnamespace = 'public'::regnamespace
  ) then
    create type public.resident_lifecycle_state as enum (
      'active',
      'pending_corporate_email_seasonal',
      'locked_missing_corporate_email'
    );
  end if;
end
$$;

alter type public.resident_lifecycle_state owner to postgres;

create table if not exists public.resident_transition_config (
  key text primary key,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  target_resident_year smallint not null default 1,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint resident_transition_config_target_resident_year_check
    check (target_resident_year >= 1 and target_resident_year <= 5),
  constraint resident_transition_config_range_check
    check (starts_at < ends_at)
);

alter table public.resident_transition_config owner to postgres;

create or replace function public.update_resident_transition_config_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trigger_update_resident_transition_config_updated_at
on public.resident_transition_config;

create trigger trigger_update_resident_transition_config_updated_at
before update on public.resident_transition_config
for each row
execute function public.update_resident_transition_config_updated_at();

insert into public.resident_transition_config (
  key,
  starts_at,
  ends_at,
  target_resident_year,
  enabled
)
values (
  'mir_r1_corporate_email_grace',
  '2026-04-25T00:00:00+00',
  '2026-07-31T23:59:59+00',
  1,
  true
)
on conflict (key) do update
set
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at,
  target_resident_year = excluded.target_resident_year,
  enabled = excluded.enabled,
  updated_at = now();

alter table public.users
  add column if not exists resident_state public.resident_lifecycle_state,
  add column if not exists resident_transition_started_at timestamptz,
  add column if not exists resident_transition_expires_at timestamptz;

create or replace function public.get_active_resident_transition_config(
  p_now timestamptz default now()
)
returns public.resident_transition_config
language sql
stable
as $$
  select rtc.*
  from public.resident_transition_config rtc
  where rtc.enabled = true
    and rtc.starts_at <= p_now
    and rtc.ends_at >= p_now
  order by rtc.starts_at desc
  limit 1;
$$;

create or replace function public.apply_resident_lifecycle_state()
returns trigger
language plpgsql
as $$
declare
  v_transition public.resident_transition_config;
  v_has_corporate_email boolean;
begin
  if coalesce(new.is_resident, false) = false then
    new.resident_state := null;
    new.resident_transition_started_at := null;
    new.resident_transition_expires_at := null;
    return new;
  end if;

  v_has_corporate_email := nullif(trim(coalesce(new.work_email, '')), '') is not null;
  select *
  into v_transition
  from public.get_active_resident_transition_config(now());

  if v_has_corporate_email then
    new.resident_state := 'active';
    return new;
  end if;

  if v_transition.key is not null
     and coalesce(new.resident_year, 0) = coalesce(v_transition.target_resident_year, 1) then
    new.resident_state := 'pending_corporate_email_seasonal';

    if new.resident_transition_started_at is null then
      new.resident_transition_started_at := now();
    end if;

    new.resident_transition_expires_at := v_transition.ends_at;
    return new;
  end if;

  new.resident_state := 'locked_missing_corporate_email';

  if new.resident_transition_started_at is null then
    new.resident_transition_started_at := now();
  end if;

  if new.resident_transition_expires_at is null then
    new.resident_transition_expires_at := now();
  end if;

  return new;
end;
$$;

drop trigger if exists trigger_apply_resident_lifecycle_state
on public.users;

create trigger trigger_apply_resident_lifecycle_state
before insert or update on public.users
for each row
execute function public.apply_resident_lifecycle_state();

create or replace function public.refresh_resident_lifecycle_states(
  p_now timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows integer := 0;
begin
  update public.users
  set
    resident_state = 'locked_missing_corporate_email',
    resident_transition_expires_at = coalesce(resident_transition_expires_at, p_now)
  where coalesce(is_resident, false) = true
    and resident_state = 'pending_corporate_email_seasonal'
    and resident_transition_expires_at is not null
    and resident_transition_expires_at < p_now
    and nullif(trim(coalesce(work_email, '')), '') is null;

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

update public.users
set
  resident_state = case
    when coalesce(is_resident, false) = false then null
    when nullif(trim(coalesce(work_email, '')), '') is not null then 'active'::public.resident_lifecycle_state
    when coalesce(resident_year, 0) = 1
      and exists (
        select 1
        from public.resident_transition_config rtc
        where rtc.key = 'mir_r1_corporate_email_grace'
          and rtc.enabled = true
          and rtc.starts_at <= now()
          and rtc.ends_at >= now()
      )
      then 'pending_corporate_email_seasonal'::public.resident_lifecycle_state
    else 'locked_missing_corporate_email'::public.resident_lifecycle_state
  end,
  resident_transition_started_at = case
    when coalesce(is_resident, false) = true
      and coalesce(resident_year, 0) = 1
      and nullif(trim(coalesce(work_email, '')), '') is null
      and resident_transition_started_at is null
      then now()
    else resident_transition_started_at
  end,
  resident_transition_expires_at = case
    when coalesce(is_resident, false) = true
      and coalesce(resident_year, 0) = 1
      and nullif(trim(coalesce(work_email, '')), '') is null
      then (
        select rtc.ends_at
        from public.resident_transition_config rtc
        where rtc.key = 'mir_r1_corporate_email_grace'
      )
    when coalesce(is_resident, false) = false then null
    else resident_transition_expires_at
  end;

grant select on public.resident_transition_config to anon, authenticated, service_role;
grant all on public.resident_transition_config to service_role;
grant execute on function public.get_active_resident_transition_config(timestamptz)
to anon, authenticated, service_role;
grant execute on function public.refresh_resident_lifecycle_states(timestamptz)
to service_role;
grant execute on function public.update_resident_transition_config_updated_at()
to service_role;
grant execute on function public.apply_resident_lifecycle_state()
to service_role;

select cron.unschedule('resident-lifecycle-refresh-daily')
where exists (
  select 1
  from cron.job
  where jobname = 'resident-lifecycle-refresh-daily'
);

select cron.schedule(
  'resident-lifecycle-refresh-daily',
  '15 3 * * *',
  $$select public.refresh_resident_lifecycle_states();$$
);
