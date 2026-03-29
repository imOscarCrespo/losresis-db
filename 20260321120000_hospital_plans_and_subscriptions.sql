-- Hospital plans / subscriptions / visibility
-- Keep this migration in sync with losresis-app/supabase/migrations because both apps share the same database.

begin;

create extension if not exists "uuid-ossp" with schema extensions;

create or replace function public.set_updated_at_timestamp_generic()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.billing_plan (
  id uuid primary key default extensions.uuid_generate_v4(),
  code text not null unique check (code in ('free', 'standard', 'premium')),
  name text not null,
  description text,
  monthly_price_eur integer not null default 0 check (monthly_price_eur >= 0),
  yearly_price_eur integer not null default 0 check (yearly_price_eur >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_billing_plan_updated_at on public.billing_plan;
create trigger trg_billing_plan_updated_at
before update on public.billing_plan
for each row execute function public.set_updated_at_timestamp_generic();

create table if not exists public.billing_plan_feature (
  id uuid primary key default extensions.uuid_generate_v4(),
  plan_id uuid not null references public.billing_plan(id) on delete cascade,
  feature_key text not null,
  feature_value jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (plan_id, feature_key)
);

create index if not exists idx_billing_plan_feature_plan_id
  on public.billing_plan_feature(plan_id);

create index if not exists idx_billing_plan_feature_key
  on public.billing_plan_feature(feature_key);

drop trigger if exists trg_billing_plan_feature_updated_at on public.billing_plan_feature;
create trigger trg_billing_plan_feature_updated_at
before update on public.billing_plan_feature
for each row execute function public.set_updated_at_timestamp_generic();

create table if not exists public.org_subscription (
  id uuid primary key default extensions.uuid_generate_v4(),
  org_id uuid not null references public.employer_org(id) on delete cascade,
  plan_id uuid not null references public.billing_plan(id),
  status text not null check (status in ('trialing', 'active', 'past_due', 'canceled', 'expired')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  trial_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  external_provider text,
  external_subscription_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_org_subscription_org_id
  on public.org_subscription(org_id);

create index if not exists idx_org_subscription_plan_id
  on public.org_subscription(plan_id);

create index if not exists idx_org_subscription_status
  on public.org_subscription(status);

create unique index if not exists idx_org_subscription_external_provider_id
  on public.org_subscription(external_provider, external_subscription_id)
  where external_provider is not null and external_subscription_id is not null;

drop trigger if exists trg_org_subscription_updated_at on public.org_subscription;
create trigger trg_org_subscription_updated_at
before update on public.org_subscription
for each row execute function public.set_updated_at_timestamp_generic();

create table if not exists public.org_subscription_event (
  id uuid primary key default extensions.uuid_generate_v4(),
  org_subscription_id uuid not null references public.org_subscription(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_org_subscription_event_subscription_id
  on public.org_subscription_event(org_subscription_id);

create index if not exists idx_org_subscription_event_event_type
  on public.org_subscription_event(event_type);

insert into public.billing_plan (code, name, description, monthly_price_eur, yearly_price_eur, is_active)
values
  ('free', 'Free', 'Presencia basica para hospitales', 0, 0, true),
  ('standard', 'Standard', 'Mas publicaciones y mejor visibilidad', 9900, 99000, true),
  ('premium', 'Premium', 'Maxima visibilidad y prioridad en listados', 19900, 199000, true)
on conflict (code) do update
set
  name = excluded.name,
  description = excluded.description,
  monthly_price_eur = excluded.monthly_price_eur,
  yearly_price_eur = excluded.yearly_price_eur,
  is_active = excluded.is_active,
  updated_at = now();

with plan_features as (
  select bp.id as plan_id, x.feature_key, x.feature_value
  from public.billing_plan bp
  join (
    values
      ('free', 'max_active_courses', '{"limit":1}'::jsonb),
      ('free', 'max_active_jobs', '{"limit":1}'::jsonb),
      ('free', 'hospital_profile_enabled', '{"enabled":true}'::jsonb),
      ('free', 'priority_boost', '{"weight":0}'::jsonb),
      ('free', 'featured_badge', '{"enabled":false}'::jsonb),
      ('free', 'homepage_spotlight', '{"enabled":false}'::jsonb),

      ('standard', 'max_active_courses', '{"limit":5}'::jsonb),
      ('standard', 'max_active_jobs', '{"limit":5}'::jsonb),
      ('standard', 'hospital_profile_enabled', '{"enabled":true}'::jsonb),
      ('standard', 'priority_boost', '{"weight":10}'::jsonb),
      ('standard', 'featured_badge', '{"enabled":true}'::jsonb),
      ('standard', 'homepage_spotlight', '{"enabled":false}'::jsonb),

      ('premium', 'max_active_courses', '{"limit":null}'::jsonb),
      ('premium', 'max_active_jobs', '{"limit":null}'::jsonb),
      ('premium', 'hospital_profile_enabled', '{"enabled":true}'::jsonb),
      ('premium', 'priority_boost', '{"weight":50}'::jsonb),
      ('premium', 'featured_badge', '{"enabled":true}'::jsonb),
      ('premium', 'homepage_spotlight', '{"enabled":true}'::jsonb)
  ) as x(plan_code, feature_key, feature_value)
    on x.plan_code = bp.code
)
insert into public.billing_plan_feature (plan_id, feature_key, feature_value)
select plan_id, feature_key, feature_value
from plan_features
on conflict (plan_id, feature_key) do update
set
  feature_value = excluded.feature_value,
  updated_at = now();

insert into public.org_subscription (
  org_id,
  plan_id,
  status,
  starts_at
)
select
  eo.id,
  bp.id,
  'active',
  now()
from public.employer_org eo
cross join public.billing_plan bp
where bp.code = 'free'
  and not exists (
    select 1
    from public.org_subscription os
    where os.org_id = eo.id
  );

insert into public.org_subscription_event (
  org_subscription_id,
  event_type,
  payload
)
select
  os.id,
  'subscription_initialized',
  jsonb_build_object(
    'source', 'migration',
    'plan_code', bp.code
  )
from public.org_subscription os
join public.billing_plan bp on bp.id = os.plan_id
where not exists (
  select 1
  from public.org_subscription_event ose
  where ose.org_subscription_id = os.id
    and ose.event_type = 'subscription_initialized'
);

alter table public.courses
  add column if not exists org_id uuid references public.employer_org(id) on delete cascade,
  add column if not exists status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  add column if not exists published_at timestamptz,
  add column if not exists visibility_score integer not null default 0,
  add column if not exists is_featured boolean not null default false,
  add column if not exists featured_until timestamptz;

create index if not exists idx_courses_org_id
  on public.courses(org_id);

create index if not exists idx_courses_status
  on public.courses(status);

create index if not exists idx_courses_featured
  on public.courses(is_featured, featured_until);

update public.courses c
set org_id = (
  select ea.org_id
  from public.employer_account ea
  where ea.user_id = c.created_by_id
  order by ea.is_active desc, ea.created_at asc
  limit 1
)
where c.org_id is null;

alter table public.job
  add column if not exists visibility_score integer not null default 0,
  add column if not exists is_featured boolean not null default false,
  add column if not exists featured_until timestamptz;

create index if not exists idx_job_featured
  on public.job(is_featured, featured_until);

create index if not exists idx_job_visibility_score
  on public.job(visibility_score desc);

create or replace function public.get_org_current_subscription(p_org_id uuid)
returns table (
  subscription_id uuid,
  org_id uuid,
  plan_id uuid,
  plan_code text,
  plan_name text,
  subscription_status text,
  starts_at timestamptz,
  ends_at timestamptz,
  trial_ends_at timestamptz,
  cancel_at_period_end boolean
)
language sql
stable
as $$
  with ranked_subscriptions as (
    select
      os.id as subscription_id,
      os.org_id,
      os.plan_id,
      bp.code as plan_code,
      bp.name as plan_name,
      os.status as subscription_status,
      os.starts_at,
      os.ends_at,
      os.trial_ends_at,
      os.cancel_at_period_end,
      row_number() over (
        partition by os.org_id
        order by
          case
            when os.status in ('active', 'trialing', 'past_due') then 0
            else 1
          end,
          coalesce(os.ends_at, 'infinity'::timestamptz) desc,
          os.created_at desc
      ) as rn
    from public.org_subscription os
    join public.billing_plan bp on bp.id = os.plan_id
    where os.org_id = p_org_id
  )
  select
    subscription_id,
    org_id,
    plan_id,
    plan_code,
    plan_name,
    subscription_status,
    starts_at,
    ends_at,
    trial_ends_at,
    cancel_at_period_end
  from ranked_subscriptions
  where rn = 1;
$$;

create or replace function public.get_org_plan_features(p_org_id uuid)
returns table (
  org_id uuid,
  subscription_id uuid,
  plan_id uuid,
  plan_code text,
  plan_name text,
  subscription_status text,
  features jsonb
)
language sql
stable
as $$
  with current_subscription as (
    select *
    from public.get_org_current_subscription(p_org_id)
  )
  select
    cs.org_id,
    cs.subscription_id,
    cs.plan_id,
    cs.plan_code,
    cs.plan_name,
    cs.subscription_status,
    coalesce(
      jsonb_object_agg(bpf.feature_key, bpf.feature_value)
        filter (where bpf.feature_key is not null),
      '{}'::jsonb
    ) as features
  from current_subscription cs
  left join public.billing_plan_feature bpf
    on bpf.plan_id = cs.plan_id
  group by
    cs.org_id,
    cs.subscription_id,
    cs.plan_id,
    cs.plan_code,
    cs.plan_name,
    cs.subscription_status;
$$;

create or replace function public.can_org_publish_job(p_org_id uuid)
returns boolean
language plpgsql
stable
as $$
declare
  v_features jsonb;
  v_limit integer;
  v_current_count integer;
begin
  select features
  into v_features
  from public.get_org_plan_features(p_org_id);

  if v_features is null then
    return false;
  end if;

  if (v_features -> 'max_active_jobs' ->> 'limit') is null then
    return true;
  end if;

  v_limit := (v_features -> 'max_active_jobs' ->> 'limit')::integer;

  select count(*)
  into v_current_count
  from public.job j
  where j.org_id = p_org_id
    and j.status = 'published';

  return v_current_count < v_limit;
end;
$$;

create or replace function public.can_org_publish_course(p_org_id uuid)
returns boolean
language plpgsql
stable
as $$
declare
  v_features jsonb;
  v_limit integer;
  v_current_count integer;
begin
  select features
  into v_features
  from public.get_org_plan_features(p_org_id);

  if v_features is null then
    return false;
  end if;

  if (v_features -> 'max_active_courses' ->> 'limit') is null then
    return true;
  end if;

  v_limit := (v_features -> 'max_active_courses' ->> 'limit')::integer;

  select count(*)
  into v_current_count
  from public.courses c
  where c.org_id = p_org_id
    and c.status = 'published';

  return v_current_count < v_limit;
end;
$$;

create or replace function public.get_org_priority_boost(p_org_id uuid)
returns integer
language plpgsql
stable
as $$
declare
  v_features jsonb;
begin
  select features
  into v_features
  from public.get_org_plan_features(p_org_id);

  if v_features is null then
    return 0;
  end if;

  return coalesce((v_features -> 'priority_boost' ->> 'weight')::integer, 0);
end;
$$;

create or replace function public.refresh_job_visibility_score(p_job_id uuid)
returns void
language plpgsql
as $$
declare
  v_org_id uuid;
  v_boost integer;
begin
  select org_id into v_org_id
  from public.job
  where id = p_job_id;

  if v_org_id is null then
    return;
  end if;

  v_boost := public.get_org_priority_boost(v_org_id);

  update public.job
  set visibility_score = v_boost
  where id = p_job_id;
end;
$$;

create or replace function public.refresh_course_visibility_score(p_course_id uuid)
returns void
language plpgsql
as $$
declare
  v_org_id uuid;
  v_boost integer;
begin
  select org_id into v_org_id
  from public.courses
  where id = p_course_id;

  if v_org_id is null then
    return;
  end if;

  v_boost := public.get_org_priority_boost(v_org_id);

  update public.courses
  set visibility_score = v_boost
  where id = p_course_id;
end;
$$;

alter table public.billing_plan enable row level security;
alter table public.billing_plan_feature enable row level security;
alter table public.org_subscription enable row level security;
alter table public.org_subscription_event enable row level security;

do $$
begin
  create policy billing_plan_public_read
    on public.billing_plan
    for select
    using (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy billing_plan_feature_public_read
    on public.billing_plan_feature
    for select
    using (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy org_subscription_allow_all
    on public.org_subscription
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy org_subscription_event_allow_all
    on public.org_subscription_event
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

grant select on table public.billing_plan to anon, authenticated, service_role;
grant select on table public.billing_plan_feature to anon, authenticated, service_role;
grant all on table public.org_subscription to anon, authenticated, service_role;
grant all on table public.org_subscription_event to anon, authenticated, service_role;

grant execute on function public.get_org_current_subscription(uuid) to anon, authenticated, service_role;
grant execute on function public.get_org_plan_features(uuid) to anon, authenticated, service_role;
grant execute on function public.can_org_publish_job(uuid) to anon, authenticated, service_role;
grant execute on function public.can_org_publish_course(uuid) to anon, authenticated, service_role;
grant execute on function public.get_org_priority_boost(uuid) to anon, authenticated, service_role;
grant execute on function public.refresh_job_visibility_score(uuid) to anon, authenticated, service_role;
grant execute on function public.refresh_course_visibility_score(uuid) to anon, authenticated, service_role;

commit;
