alter table public.employer_org_signup_hospital
  alter column hospital_catalog_id drop not null;

alter table public.employer_org_signup_hospital
  add column if not exists ownership_type text,
  add column if not exists hospital_id uuid references public.hospitals(id);

update public.employer_org_signup_hospital
set ownership_type = 'private'
where ownership_type is null and hospital_catalog_id is not null;

alter table public.employer_org_signup_hospital
  alter column ownership_type set not null;

do $$
begin
  alter table public.employer_org_signup_hospital
    add constraint employer_org_signup_hospital_ownership_type_check
    check (ownership_type in ('public', 'private'));
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.employer_org_signup_hospital
    add constraint employer_org_signup_hospital_source_check
    check (
      (ownership_type = 'private' and hospital_catalog_id is not null and hospital_id is null)
      or
      (ownership_type = 'public' and hospital_id is not null and hospital_catalog_id is null)
    );
exception
  when duplicate_object then null;
end $$;

create unique index if not exists idx_employer_org_signup_hospital_public_hospital
  on public.employer_org_signup_hospital (hospital_id)
  where hospital_id is not null;
