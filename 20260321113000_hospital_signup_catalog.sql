-- Hospital signup catalog for employer onboarding
-- Source dataset: CNH_2025.xlsx (Directorio de Hospitales)

create table if not exists public.hospital_signup_catalog (
  id uuid primary key default extensions.uuid_generate_v4(),
  source_year integer not null default 2025,
  source_file text not null default 'CNH_2025.xlsx',
  ccn text,
  codcnh text not null unique,
  name text not null,
  normalized_name text not null,
  address text,
  phone text,
  municipality_code text,
  municipality text,
  province_code text,
  province text,
  ccaa_code text,
  ccaa text,
  postal_code text,
  beds integer,
  center_class_code text,
  center_class text,
  dependency_code text,
  dependency_name text,
  part_of_complex boolean not null default false,
  complex_code text,
  complex_name text,
  is_deregistered boolean not null default false,
  email text,
  ownership_type text not null default 'other' check (ownership_type in ('public', 'private', 'other')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_hospital_signup_catalog_name
  on public.hospital_signup_catalog (name);

create index if not exists idx_hospital_signup_catalog_ownership
  on public.hospital_signup_catalog (ownership_type);

create index if not exists idx_hospital_signup_catalog_region
  on public.hospital_signup_catalog (ccaa, province, municipality);

create or replace function public.set_updated_at_timestamp_hospital_signup_catalog()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_hospital_signup_catalog_updated_at on public.hospital_signup_catalog;
create trigger trg_hospital_signup_catalog_updated_at
before update on public.hospital_signup_catalog
for each row execute function public.set_updated_at_timestamp_hospital_signup_catalog();

create table if not exists public.employer_org_signup_hospital (
  org_id uuid primary key references public.employer_org(id) on delete cascade,
  hospital_catalog_id uuid not null references public.hospital_signup_catalog(id),
  contact_person_name text,
  contact_person_phone text,
  position_title text,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (hospital_catalog_id)
);

create index if not exists idx_employer_org_signup_hospital_catalog
  on public.employer_org_signup_hospital (hospital_catalog_id);

alter table public.hospital_signup_catalog enable row level security;
alter table public.employer_org_signup_hospital enable row level security;

do $$
begin
  create policy hospital_signup_catalog_public_read
    on public.hospital_signup_catalog
    for select
    using (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy employer_org_signup_hospital_allow_all
    on public.employer_org_signup_hospital
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

grant select on table public.hospital_signup_catalog to anon, authenticated, service_role;
grant all on table public.hospital_signup_catalog to service_role;
grant all on table public.employer_org_signup_hospital to anon, authenticated, service_role;
