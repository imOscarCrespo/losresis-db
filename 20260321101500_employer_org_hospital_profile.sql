-- Hospital profile data for employer organizations (panel hospitals)
-- Keep this migration in sync with losresis-app/supabase/migrations because both apps share the same database.

create table if not exists public.employer_org_profile (
  org_id uuid primary key references public.employer_org(id) on delete cascade,
  about text,
  exchange_program_available boolean not null default false,
  exchange_program_details text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.employer_org_profile_speciality (
  org_id uuid not null references public.employer_org(id) on delete cascade,
  speciality_id uuid not null references public.specialities(id) on delete cascade,
  plan_formativo_storage_path text,
  plan_formativo_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (org_id, speciality_id)
);

create table if not exists public.employer_org_profile_image (
  id uuid primary key default extensions.uuid_generate_v4(),
  org_id uuid not null references public.employer_org(id) on delete cascade,
  storage_path text not null,
  public_url text not null,
  position integer not null default 1,
  created_at timestamptz not null default now()
);

create index if not exists idx_employer_org_profile_image_org
  on public.employer_org_profile_image(org_id, position);

create or replace function public.set_updated_at_timestamp_employer_org_profile()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_employer_org_profile_updated_at on public.employer_org_profile;
create trigger trg_employer_org_profile_updated_at
before update on public.employer_org_profile
for each row execute function public.set_updated_at_timestamp_employer_org_profile();

drop trigger if exists trg_employer_org_profile_speciality_updated_at on public.employer_org_profile_speciality;
create trigger trg_employer_org_profile_speciality_updated_at
before update on public.employer_org_profile_speciality
for each row execute function public.set_updated_at_timestamp_employer_org_profile();

alter table public.employer_org_profile enable row level security;
alter table public.employer_org_profile_speciality enable row level security;
alter table public.employer_org_profile_image enable row level security;

do $$
begin
  create policy employer_org_profile_allow_all
    on public.employer_org_profile
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy employer_org_profile_speciality_allow_all
    on public.employer_org_profile_speciality
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy employer_org_profile_image_allow_all
    on public.employer_org_profile_image
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

grant all on table public.employer_org_profile to anon, authenticated, service_role;
grant all on table public.employer_org_profile_speciality to anon, authenticated, service_role;
grant all on table public.employer_org_profile_image to anon, authenticated, service_role;

insert into storage.buckets (id, name, public)
values ('hospital-assets', 'hospital-assets', true)
on conflict (id) do nothing;

do $$
begin
  create policy hospital_assets_public_read
    on storage.objects
    for select
    using (bucket_id = 'hospital-assets');
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy hospital_assets_authenticated_insert
    on storage.objects
    for insert
    to authenticated
    with check (bucket_id = 'hospital-assets');
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy hospital_assets_authenticated_update
    on storage.objects
    for update
    to authenticated
    using (bucket_id = 'hospital-assets')
    with check (bucket_id = 'hospital-assets');
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy hospital_assets_authenticated_delete
    on storage.objects
    for delete
    to authenticated
    using (bucket_id = 'hospital-assets');
exception
  when duplicate_object then null;
end $$;
