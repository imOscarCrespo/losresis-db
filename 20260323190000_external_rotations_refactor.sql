do $$
begin
  if not exists (
    select 1
    from pg_type
    where typname = 'external_rotation_contact_method'
      and typnamespace = 'public'::regnamespace
  ) then
    create type public.external_rotation_contact_method as enum (
      'app_chat',
      'whatsapp',
      'email',
      'none'
    );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_type
    where typname = 'external_rotation_difficulty'
      and typnamespace = 'public'::regnamespace
  ) then
    create type public.external_rotation_difficulty as enum (
      'easy',
      'medium',
      'hard'
    );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_type
    where typname = 'external_rotation_kind'
      and typnamespace = 'public'::regnamespace
  ) then
    create type public.external_rotation_kind as enum (
      'observational',
      'hands_on'
    );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'public.forum_scope'::regtype
      and enumlabel = 'external_rotations'
  ) then
    alter type public.forum_scope add value 'external_rotations';
  end if;
end $$;

alter table public.external_rotation
  add column if not exists hospital_name text,
  add column if not exists service_name text,
  add column if not exists speciality_id uuid references public.specialities(id) on delete set null,
  add column if not exists notes text,
  add column if not exists contact_preference public.external_rotation_contact_method default 'app_chat'::public.external_rotation_contact_method not null;

alter table public.external_rotation_review
  alter column rotation_id drop not null;

alter table public.external_rotation_review
  add column if not exists speciality_id uuid references public.specialities(id) on delete set null,
  add column if not exists service_name text,
  add column if not exists difficulty public.external_rotation_difficulty,
  add column if not exists difficulty_notes text,
  add column if not exists rotation_kind public.external_rotation_kind,
  add column if not exists highlight_summary text,
  add column if not exists before_you_go text,
  add column if not exists tutor_name text,
  add column if not exists tutor_email text,
  add column if not exists preferred_contact_method public.external_rotation_contact_method default 'app_chat'::public.external_rotation_contact_method not null,
  add column if not exists allow_app_contact boolean default true not null;

alter table public.external_rotation_review
  drop constraint if exists external_rotation_review_tutor_email_ck;

alter table public.external_rotation_review
  add constraint external_rotation_review_tutor_email_ck
  check (
    tutor_email is null
    or tutor_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
  );

create unique index if not exists external_rotation_review_user_rotation_unique_idx
  on public.external_rotation_review (user_id, rotation_id)
  where rotation_id is not null;

create index if not exists external_rotation_country_city_idx
  on public.external_rotation (country, city);

create index if not exists external_rotation_speciality_idx
  on public.external_rotation (speciality_id);

create index if not exists external_rotation_hospital_name_idx
  on public.external_rotation using gin (to_tsvector('simple', coalesce(hospital_name, '')));

create index if not exists external_rotation_review_country_city_idx
  on public.external_rotation_review (country, city);

create index if not exists external_rotation_review_speciality_idx
  on public.external_rotation_review (speciality_id);

create index if not exists external_rotation_review_hospital_name_idx
  on public.external_rotation_review using gin (to_tsvector('simple', coalesce(external_hospital_name, '')));

create index if not exists external_rotation_review_highlight_idx
  on public.external_rotation_review using gin (
    to_tsvector(
      'simple',
      coalesce(external_hospital_name, '')
      || ' '
      || coalesce(service_name, '')
      || ' '
      || coalesce(highlight_summary, '')
      || ' '
      || coalesce(before_you_go, '')
    )
  );
