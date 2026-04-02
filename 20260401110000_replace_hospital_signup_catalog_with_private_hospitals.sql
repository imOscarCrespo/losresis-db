create table if not exists public.hospitals_private (
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
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_hospitals_private_name
  on public.hospitals_private (name);

create index if not exists idx_hospitals_private_region
  on public.hospitals_private (ccaa, province, municipality);

create or replace function public.set_updated_at_timestamp_hospitals_private()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_hospitals_private_updated_at on public.hospitals_private;
create trigger trg_hospitals_private_updated_at
before update on public.hospitals_private
for each row execute function public.set_updated_at_timestamp_hospitals_private();

insert into public.hospitals_private (
  id,
  source_year,
  source_file,
  ccn,
  codcnh,
  name,
  normalized_name,
  address,
  phone,
  municipality_code,
  municipality,
  province_code,
  province,
  ccaa_code,
  ccaa,
  postal_code,
  beds,
  center_class_code,
  center_class,
  dependency_code,
  dependency_name,
  part_of_complex,
  complex_code,
  complex_name,
  is_deregistered,
  email,
  created_at,
  updated_at
)
select
  extensions.uuid_generate_v5(
    '6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid,
    'losresis-private-hospital:' || hsc.codcnh
  ),
  hsc.source_year,
  hsc.source_file,
  hsc.ccn,
  hsc.codcnh,
  hsc.name,
  hsc.normalized_name,
  hsc.address,
  hsc.phone,
  hsc.municipality_code,
  hsc.municipality,
  hsc.province_code,
  hsc.province,
  hsc.ccaa_code,
  hsc.ccaa,
  hsc.postal_code,
  hsc.beds,
  hsc.center_class_code,
  hsc.center_class,
  hsc.dependency_code,
  hsc.dependency_name,
  hsc.part_of_complex,
  hsc.complex_code,
  hsc.complex_name,
  hsc.is_deregistered,
  hsc.email,
  hsc.created_at,
  hsc.updated_at
from public.hospital_signup_catalog hsc
where hsc.ownership_type = 'private'
on conflict (id) do update
set
  source_year = excluded.source_year,
  source_file = excluded.source_file,
  ccn = excluded.ccn,
  codcnh = excluded.codcnh,
  name = excluded.name,
  normalized_name = excluded.normalized_name,
  address = excluded.address,
  phone = excluded.phone,
  municipality_code = excluded.municipality_code,
  municipality = excluded.municipality,
  province_code = excluded.province_code,
  province = excluded.province,
  ccaa_code = excluded.ccaa_code,
  ccaa = excluded.ccaa,
  postal_code = excluded.postal_code,
  beds = excluded.beds,
  center_class_code = excluded.center_class_code,
  center_class = excluded.center_class,
  dependency_code = excluded.dependency_code,
  dependency_name = excluded.dependency_name,
  part_of_complex = excluded.part_of_complex,
  complex_code = excluded.complex_code,
  complex_name = excluded.complex_name,
  is_deregistered = excluded.is_deregistered,
  email = excluded.email,
  updated_at = now();

alter table public.employer_org
  add column if not exists ownership_type text,
  add column if not exists hospital_id uuid references public.hospitals(id),
  add column if not exists hospital_private_id uuid references public.hospitals_private(id);

do $$
declare
  has_legacy_public_hospital_id boolean;
begin
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'employer_org_signup_hospital'
      and column_name = 'hospital_id'
  ) into has_legacy_public_hospital_id;

  if has_legacy_public_hospital_id then
    execute $sql$
      update public.employer_org eo
      set
        ownership_type = case
          when eosh.hospital_id is not null then 'public'
          when hp.id is not null then 'private'
          else eo.ownership_type
        end,
        hospital_id = eosh.hospital_id,
        hospital_private_id = hp.id
      from public.employer_org_signup_hospital eosh
      left join public.hospital_signup_catalog hsc
        on hsc.id = eosh.hospital_catalog_id
      left join public.hospitals_private hp
        on hp.codcnh = hsc.codcnh
      where eosh.org_id = eo.id
    $sql$;
  else
    update public.employer_org eo
    set
      ownership_type = case
        when hp.id is not null then 'private'
        else eo.ownership_type
      end,
      hospital_id = eo.hospital_id,
      hospital_private_id = hp.id
    from public.employer_org_signup_hospital eosh
    left join public.hospital_signup_catalog hsc
      on hsc.id = eosh.hospital_catalog_id
    left join public.hospitals_private hp
      on hp.codcnh = hsc.codcnh
    where eosh.org_id = eo.id;
  end if;
end $$;

do $$
begin
  alter table public.employer_org
    add constraint employer_org_ownership_type_check
    check (ownership_type in ('public', 'private'));
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.employer_org
    add constraint employer_org_hospital_source_check
    check (
      (ownership_type is null and hospital_id is null and hospital_private_id is null)
      or
      (ownership_type = 'public' and hospital_id is not null and hospital_private_id is null)
      or
      (ownership_type = 'private' and hospital_private_id is not null and hospital_id is null)
    );
exception
  when duplicate_object then null;
end $$;

create unique index if not exists idx_employer_org_hospital_id_unique
  on public.employer_org (hospital_id)
  where hospital_id is not null;

create unique index if not exists idx_employer_org_hospital_private_id_unique
  on public.employer_org (hospital_private_id)
  where hospital_private_id is not null;

alter table public.hospitals_private enable row level security;

do $$
begin
  create policy hospitals_private_public_read
    on public.hospitals_private
    for select
    using (true);
exception
  when duplicate_object then null;
end $$;

grant select on table public.hospitals_private to anon, authenticated, service_role;
grant all on table public.hospitals_private to service_role;

drop table if exists public.employer_org_signup_hospital;
drop table if exists public.hospital_signup_catalog;
drop function if exists public.set_updated_at_timestamp_hospital_signup_catalog();
