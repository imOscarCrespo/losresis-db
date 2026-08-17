-- Landlord housing portal (vivienda.losresis.com)
--
-- Adds the paid publication model for landlords on top of the existing
-- housing_ad tables, without touching how residents publish today.
--
-- Model:
--   * A landlord buys a pack of publication credits (one-off Stripe payment).
--   * Spending 1 credit publishes one house for 30 days.
--   * After 30 days the publication expires and the house leaves the app list.
--     Reactivating it spends another credit.
--   * "Destacado" (premium) is a separate one-off per house, also 30 days.
--
-- Backwards compatibility: ads created from losresis-app by residents keep
-- source = 'app' and published_until = NULL, which means "never expires" and
-- "free". Only source = 'landlord_portal' ads are subject to expiry.

begin;

create extension if not exists "uuid-ossp" with schema extensions;
-- citext already lives in public in this database (housing_ad.contact_email
-- uses public.citext); keep it there so the type reference below resolves.
create extension if not exists citext with schema public;

-- ---------------------------------------------------------------------------
-- 1. Landlord identity
-- ---------------------------------------------------------------------------

alter table public.users
  add column if not exists is_landlord boolean not null default false;

create index if not exists idx_users_is_landlord
  on public.users(is_landlord)
  where is_landlord;

create table if not exists public.landlord_profile (
  user_id uuid primary key references public.users(id) on delete cascade,
  display_name text not null,
  company_name text,
  tax_id text,
  phone text,
  billing_email public.citext,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_landlord_profile_updated_at on public.landlord_profile;
create trigger trg_landlord_profile_updated_at
before update on public.landlord_profile
for each row execute function public.set_updated_at_timestamp_generic();

-- ---------------------------------------------------------------------------
-- 2. Catalogue: credit packs and the premium add-on
-- ---------------------------------------------------------------------------

create table if not exists public.housing_plan (
  id uuid primary key default extensions.uuid_generate_v4(),
  code text not null unique check (code in ('basico', 'profesional', 'agencia')),
  name text not null,
  description text,
  credits integer not null check (credits > 0),
  -- Prices in cents. list_price_cents is the pre-discount reference shown
  -- struck through; price_cents is what the landlord actually pays.
  list_price_cents integer not null check (list_price_cents >= 0),
  price_cents integer not null check (price_cents >= 0),
  currency text not null default 'eur',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint housing_plan_price_le_list_ck check (price_cents <= list_price_cents)
);

drop trigger if exists trg_housing_plan_updated_at on public.housing_plan;
create trigger trg_housing_plan_updated_at
before update on public.housing_plan
for each row execute function public.set_updated_at_timestamp_generic();

create table if not exists public.housing_addon (
  code text primary key check (code in ('premium_30d')),
  name text not null,
  description text,
  list_price_cents integer not null check (list_price_cents >= 0),
  price_cents integer not null check (price_cents >= 0),
  currency text not null default 'eur',
  duration_days integer not null default 30 check (duration_days > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint housing_addon_price_le_list_ck check (price_cents <= list_price_cents)
);

drop trigger if exists trg_housing_addon_updated_at on public.housing_addon;
create trigger trg_housing_addon_updated_at
before update on public.housing_addon
for each row execute function public.set_updated_at_timestamp_generic();

-- Launch pricing: first-year -25% discount off the list price.
insert into public.housing_plan
  (code, name, description, credits, list_price_cents, price_cents, sort_order)
values
  -- La descripcion no repite el precio por vivienda: la interfaz lo calcula a
  -- partir de price_cents / credits y quedarian dos cifras distintas en la
  -- misma tarjeta.
  ('basico', 'Básico', 'Publica una vivienda durante 30 días', 1, 3900, 2900, 1),
  ('profesional', 'Profesional', 'Cinco publicaciones de 30 días, al mejor precio por vivienda', 5, 17500, 13100, 2),
  ('agencia', 'Agencia', 'Veinte publicaciones de 30 días para carteras grandes', 20, 56000, 42000, 3)
on conflict (code) do update
set
  name = excluded.name,
  description = excluded.description,
  credits = excluded.credits,
  list_price_cents = excluded.list_price_cents,
  price_cents = excluded.price_cents,
  sort_order = excluded.sort_order,
  updated_at = now();

insert into public.housing_addon
  (code, name, description, list_price_cents, price_cents, duration_days)
values
  ('premium_30d', 'Destacado', 'Tu vivienda aparece la primera de la lista durante 30 días', 1900, 1400, 30)
on conflict (code) do update
set
  name = excluded.name,
  description = excluded.description,
  list_price_cents = excluded.list_price_cents,
  price_cents = excluded.price_cents,
  duration_days = excluded.duration_days,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- 3. Payments
-- ---------------------------------------------------------------------------

create table if not exists public.housing_payment (
  id uuid primary key default extensions.uuid_generate_v4(),
  user_id uuid not null references public.users(id) on delete cascade,
  kind text not null check (kind in ('plan', 'premium')),
  plan_id uuid references public.housing_plan(id),
  ad_id uuid references public.housing_ad(id) on delete set null,
  credits_granted integer not null default 0 check (credits_granted >= 0),
  amount_cents integer not null check (amount_cents >= 0),
  currency text not null default 'eur',
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'failed', 'refunded')),
  stripe_checkout_session_id text unique,
  stripe_payment_intent_id text,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A plan purchase must name its plan; a premium purchase must name its ad.
  constraint housing_payment_kind_target_ck check (
    (kind = 'plan' and plan_id is not null)
    or (kind = 'premium' and ad_id is not null)
  )
);

create index if not exists idx_housing_payment_user_id
  on public.housing_payment(user_id);

create index if not exists idx_housing_payment_status
  on public.housing_payment(status);

drop trigger if exists trg_housing_payment_updated_at on public.housing_payment;
create trigger trg_housing_payment_updated_at
before update on public.housing_payment
for each row execute function public.set_updated_at_timestamp_generic();

-- ---------------------------------------------------------------------------
-- 4. Credit ledger (append-only; balance is the sum of deltas)
-- ---------------------------------------------------------------------------

create table if not exists public.landlord_credit_ledger (
  id uuid primary key default extensions.uuid_generate_v4(),
  user_id uuid not null references public.users(id) on delete cascade,
  delta integer not null check (delta <> 0),
  reason text not null
    check (reason in ('purchase', 'publication', 'reactivation', 'refund', 'grant', 'adjustment')),
  ad_id uuid references public.housing_ad(id) on delete set null,
  payment_id uuid references public.housing_payment(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists idx_landlord_credit_ledger_user_id
  on public.landlord_credit_ledger(user_id);

create index if not exists idx_landlord_credit_ledger_ad_id
  on public.landlord_credit_ledger(ad_id);

-- One credit grant per payment, so a replayed Stripe webhook cannot double-grant.
create unique index if not exists uq_landlord_credit_ledger_purchase_payment
  on public.landlord_credit_ledger(payment_id)
  where payment_id is not null and reason = 'purchase';

-- ---------------------------------------------------------------------------
-- 5. housing_ad: publication window, premium, provenance
-- ---------------------------------------------------------------------------

alter table public.housing_ad
  add column if not exists source text not null default 'app',
  add column if not exists published_at timestamptz,
  add column if not exists published_until timestamptz,
  add column if not exists is_premium boolean not null default false,
  add column if not exists premium_until timestamptz;

do $$
begin
  alter table public.housing_ad
    add constraint housing_ad_source_ck check (source in ('app', 'landlord_portal'));
exception
  when duplicate_object then null;
end $$;

-- Ordering index for the app list: premium first, then most recent.
create index if not exists housing_ad_premium_created_idx
  on public.housing_ad(is_premium desc, created_at desc);

create index if not exists housing_ad_published_until_idx
  on public.housing_ad(published_until)
  where published_until is not null;

create index if not exists housing_ad_source_idx
  on public.housing_ad(source);

-- ---------------------------------------------------------------------------
-- 6. Functions
-- ---------------------------------------------------------------------------

create or replace function public.get_landlord_credit_balance(p_user_id uuid)
returns integer
language sql
stable
as $$
  select coalesce(sum(delta), 0)::integer
  from public.landlord_credit_ledger
  where user_id = p_user_id;
$$;

-- Publishes (or reactivates) a house for p_days days, spending one credit.
-- Atomic: the advisory lock serialises concurrent publishes by the same
-- landlord so the balance cannot go negative through a race.
create or replace function public.publish_housing_ad(
  p_ad_id uuid,
  p_days integer default 30
)
returns table (
  ad_id uuid,
  published_at timestamptz,
  published_until timestamptz,
  credits_left integer
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_owner_id uuid;
  v_deleted_at timestamptz;
  v_was_published boolean;
  v_caller uuid := auth.uid();
  v_balance integer;
  v_now timestamptz := now();
  v_until timestamptz;
begin
  if p_days is null or p_days <= 0 then
    raise exception 'La duración de la publicación debe ser positiva';
  end if;

  select ha.user_id, ha.deleted_at, ha.published_at is not null
  into v_owner_id, v_deleted_at, v_was_published
  from public.housing_ad ha
  where ha.id = p_ad_id;

  if v_owner_id is null then
    raise exception 'La vivienda no existe';
  end if;

  if v_deleted_at is not null then
    raise exception 'La vivienda está eliminada';
  end if;

  -- When called with a user session, only the owner may publish. When called
  -- from the server with the service role, auth.uid() is null and the caller
  -- is responsible for having authenticated the landlord.
  if v_caller is not null and v_caller <> v_owner_id then
    raise exception 'No autorizado';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_owner_id::text, 0));

  select public.get_landlord_credit_balance(v_owner_id) into v_balance;

  if v_balance < 1 then
    raise exception 'No te quedan créditos de publicación';
  end if;

  v_until := v_now + make_interval(days => p_days);

  insert into public.landlord_credit_ledger (user_id, delta, reason, ad_id, note)
  values (
    v_owner_id,
    -1,
    case when v_was_published then 'reactivation' else 'publication' end,
    p_ad_id,
    format('Publicación de %s días', p_days)
  );

  update public.housing_ad ha
  set
    is_active = true,
    source = 'landlord_portal',
    published_at = v_now,
    published_until = v_until,
    updated_at = v_now
  where ha.id = p_ad_id;

  return query
  select
    p_ad_id,
    v_now,
    v_until,
    public.get_landlord_credit_balance(v_owner_id);
end;
$$;

-- Marks a house as premium for p_days days. Called after a successful
-- one-off Stripe payment for the destacado add-on.
create or replace function public.grant_housing_ad_premium(
  p_ad_id uuid,
  p_days integer default 30
)
returns timestamptz
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_owner_id uuid;
  v_caller uuid := auth.uid();
  v_current timestamptz;
  v_until timestamptz;
begin
  if p_days is null or p_days <= 0 then
    raise exception 'La duración del destacado debe ser positiva';
  end if;

  select ha.user_id, ha.premium_until
  into v_owner_id, v_current
  from public.housing_ad ha
  where ha.id = p_ad_id and ha.deleted_at is null;

  if v_owner_id is null then
    raise exception 'La vivienda no existe';
  end if;

  if v_caller is not null and v_caller <> v_owner_id then
    raise exception 'No autorizado';
  end if;

  -- Stack on top of any remaining premium time rather than truncating it.
  v_until := greatest(coalesce(v_current, now()), now()) + make_interval(days => p_days);

  update public.housing_ad ha
  set
    is_premium = true,
    premium_until = v_until,
    updated_at = now()
  where ha.id = p_ad_id;

  return v_until;
end;
$$;

-- Retires expired publications and expired premium flags. Only touches ads
-- with an explicit publication window, so resident ads from the app are safe.
create or replace function public.expire_housing_ads()
returns table (expired_ads integer, expired_premium integer)
language plpgsql
as $$
declare
  v_expired_ads integer := 0;
  v_expired_premium integer := 0;
begin
  with deactivated as (
    update public.housing_ad
    set is_active = false, updated_at = now()
    where is_active
      and deleted_at is null
      and published_until is not null
      and published_until <= now()
    returning 1
  )
  select count(*)::integer into v_expired_ads from deactivated;

  with unfeatured as (
    update public.housing_ad
    set is_premium = false, updated_at = now()
    where is_premium
      and (premium_until is null or premium_until <= now())
    returning 1
  )
  select count(*)::integer into v_expired_premium from unfeatured;

  return query select v_expired_ads, v_expired_premium;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Hourly expiry job
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('expire-housing-ads')
    where exists (select 1 from cron.job where jobname = 'expire-housing-ads');

    perform cron.schedule(
      'expire-housing-ads',
      '5 * * * *',
      $cron$select public.expire_housing_ads();$cron$
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. RLS
-- ---------------------------------------------------------------------------

alter table public.landlord_profile enable row level security;
alter table public.housing_plan enable row level security;
alter table public.housing_addon enable row level security;
alter table public.housing_payment enable row level security;
alter table public.landlord_credit_ledger enable row level security;

do $$
begin
  create policy housing_plan_public_read
    on public.housing_plan for select using (true);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy housing_addon_public_read
    on public.housing_addon for select using (true);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy landlord_profile_own_select
    on public.landlord_profile for select using (auth.uid() = user_id);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy landlord_profile_own_upsert
    on public.landlord_profile for insert with check (auth.uid() = user_id);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy landlord_profile_own_update
    on public.landlord_profile for update
    using (auth.uid() = user_id) with check (auth.uid() = user_id);
exception when duplicate_object then null;
end $$;

-- Payments and the ledger are read-only to the landlord: they are written by
-- the server (service role) after Stripe confirms, never by the browser.
do $$
begin
  create policy housing_payment_own_select
    on public.housing_payment for select using (auth.uid() = user_id);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy landlord_credit_ledger_own_select
    on public.landlord_credit_ledger for select using (auth.uid() = user_id);
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------------

grant select on table public.housing_plan to anon, authenticated, service_role;
grant select on table public.housing_addon to anon, authenticated, service_role;
grant select, insert, update on table public.landlord_profile to authenticated, service_role;
grant select on table public.housing_payment to authenticated;
grant all on table public.housing_payment to service_role;
grant select on table public.landlord_credit_ledger to authenticated;
grant all on table public.landlord_credit_ledger to service_role;

grant execute on function public.get_landlord_credit_balance(uuid) to authenticated, service_role;
grant execute on function public.publish_housing_ad(uuid, integer) to authenticated, service_role;
grant execute on function public.grant_housing_ad_premium(uuid, integer) to service_role;
grant execute on function public.expire_housing_ads() to service_role;

commit;
