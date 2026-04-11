-- Differential points per speciality plan in employer hospital profiles.
-- Keep this migration in sync with losresis-app/supabase/migrations because both apps share the same database.

begin;

alter table public.employer_org_profile_speciality
  add column if not exists differential_points text[] not null default '{}'::text[];

commit;
