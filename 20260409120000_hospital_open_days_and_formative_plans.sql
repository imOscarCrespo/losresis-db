-- Hospital profile cleanup: replace MIR recruitment with open days and richer formative plans.
-- Keep this migration in sync with losresis-app/supabase/migrations because both apps share the same database.

begin;

alter table public.employer_org_profile_speciality
  add column if not exists description text;

create table if not exists public.hospital_open_day (
  id uuid primary key default extensions.uuid_generate_v4(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  title text not null,
  description text,
  event_date date not null,
  cta_label text,
  cta_url text,
  image_storage_path text,
  image_public_url text,
  is_published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint hospital_open_day_cta_url_ck
    check (cta_url is null or cta_url ~* '^https?://')
);

create index if not exists idx_hospital_open_day_hospital_date
  on public.hospital_open_day (hospital_id, event_date asc, created_at desc);

create or replace function public.set_updated_at_timestamp_hospital_open_day()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_hospital_open_day_updated_at on public.hospital_open_day;
create trigger trg_hospital_open_day_updated_at
before update on public.hospital_open_day
for each row execute function public.set_updated_at_timestamp_hospital_open_day();

alter table public.hospital_open_day enable row level security;

do $$
begin
  create policy hospital_open_day_allow_all
    on public.hospital_open_day
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

grant all on table public.hospital_open_day to anon, authenticated, service_role;

drop table if exists public.employer_org_mir_recruitment_highlight;
drop table if exists public.employer_org_mir_recruitment_link;
drop table if exists public.employer_org_mir_recruitment_image;
drop table if exists public.employer_org_mir_recruitment_profile;

commit;
