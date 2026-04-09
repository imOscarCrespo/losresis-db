-- MIR recruitment profile for hospital organizations.
-- This profile is designed for senior hospital stakeholders focused on attracting top students.

begin;

create table if not exists public.employer_org_mir_recruitment_profile (
  org_id uuid primary key references public.employer_org(id) on delete cascade,
  hero_title text,
  hero_subtitle text,
  hospital_pitch text,
  clinical_exposure_summary text,
  teaching_commitment_summary text,
  technology_and_facilities_summary text,
  research_opportunities_summary text,
  resident_experience_summary text,
  career_projection_summary text,
  hospital_culture_summary text,
  city_context_summary text,
  cta_label text,
  cta_url text,
  contact_email public.citext,
  contact_phone text,
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint employer_org_mir_recruitment_profile_cta_url_ck
    check (cta_url is null or cta_url ~* '^https?://')
);

create table if not exists public.employer_org_mir_recruitment_highlight (
  id uuid primary key default extensions.uuid_generate_v4(),
  org_id uuid not null references public.employer_org(id) on delete cascade,
  title text not null,
  description text,
  position integer not null default 1,
  created_at timestamptz not null default now()
);

create index if not exists idx_employer_org_mir_recruitment_highlight_org
  on public.employer_org_mir_recruitment_highlight (org_id, position);

create table if not exists public.employer_org_mir_recruitment_link (
  id uuid primary key default extensions.uuid_generate_v4(),
  org_id uuid not null references public.employer_org(id) on delete cascade,
  label text not null,
  url text not null,
  kind text not null default 'other'
    check (kind in ('official_site', 'teaching', 'residency_info', 'virtual_tour', 'video', 'contact', 'other')),
  position integer not null default 1,
  created_at timestamptz not null default now(),
  constraint employer_org_mir_recruitment_link_url_ck
    check (url ~* '^https?://')
);

create index if not exists idx_employer_org_mir_recruitment_link_org
  on public.employer_org_mir_recruitment_link (org_id, position);

create table if not exists public.employer_org_mir_recruitment_image (
  id uuid primary key default extensions.uuid_generate_v4(),
  org_id uuid not null references public.employer_org(id) on delete cascade,
  storage_path text not null,
  public_url text not null,
  alt_text text,
  position integer not null default 1,
  created_at timestamptz not null default now()
);

create index if not exists idx_employer_org_mir_recruitment_image_org
  on public.employer_org_mir_recruitment_image (org_id, position);

alter table public.employer_org_profile_image
  add column if not exists alt_text text;

create or replace function public.set_updated_at_timestamp_employer_org_mir_recruitment_profile()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_employer_org_mir_recruitment_profile_updated_at
  on public.employer_org_mir_recruitment_profile;

create trigger trg_employer_org_mir_recruitment_profile_updated_at
before update on public.employer_org_mir_recruitment_profile
for each row
execute function public.set_updated_at_timestamp_employer_org_mir_recruitment_profile();

alter table public.employer_org_mir_recruitment_profile enable row level security;
alter table public.employer_org_mir_recruitment_highlight enable row level security;
alter table public.employer_org_mir_recruitment_link enable row level security;
alter table public.employer_org_mir_recruitment_image enable row level security;

do $$
begin
  create policy employer_org_mir_recruitment_profile_allow_all
    on public.employer_org_mir_recruitment_profile
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy employer_org_mir_recruitment_highlight_allow_all
    on public.employer_org_mir_recruitment_highlight
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy employer_org_mir_recruitment_link_allow_all
    on public.employer_org_mir_recruitment_link
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy employer_org_mir_recruitment_image_allow_all
    on public.employer_org_mir_recruitment_image
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

grant all on table public.employer_org_mir_recruitment_profile to anon, authenticated, service_role;
grant all on table public.employer_org_mir_recruitment_highlight to anon, authenticated, service_role;
grant all on table public.employer_org_mir_recruitment_link to anon, authenticated, service_role;
grant all on table public.employer_org_mir_recruitment_image to anon, authenticated, service_role;

commit;
