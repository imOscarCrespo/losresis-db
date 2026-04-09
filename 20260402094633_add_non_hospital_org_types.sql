begin;

alter table public.employer_org
  add column if not exists org_kind text,
  add column if not exists non_hospital_type text;

update public.employer_org
set
  org_kind = case
    when hospital_id is not null or hospital_private_id is not null or ownership_type in ('public', 'private')
      then 'hospital'
    else 'non_hospital'
  end,
  non_hospital_type = case
    when hospital_id is null
      and hospital_private_id is null
      and coalesce(ownership_type, '') not in ('public', 'private')
      then coalesce(non_hospital_type, 'other')
    else null
  end
where org_kind is null;

alter table public.employer_org
  alter column org_kind set not null;

alter table public.employer_org
  alter column ownership_type drop not null;

alter table public.employer_org
  drop constraint if exists employer_org_ownership_type_check;

alter table public.employer_org
  drop constraint if exists employer_org_hospital_source_check;

do $$
begin
  alter table public.employer_org
    add constraint employer_org_kind_check
    check (org_kind in ('hospital', 'non_hospital'));
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.employer_org
    add constraint employer_org_ownership_type_check
    check (
      ownership_type is null
      or ownership_type in ('public', 'private')
    );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.employer_org
    add constraint employer_org_non_hospital_type_check
    check (
      non_hospital_type is null
      or non_hospital_type in ('pharma', 'online_platform', 'other')
    );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.employer_org
    add constraint employer_org_source_by_kind_check
    check (
      (
        org_kind = 'hospital'
        and ownership_type in ('public', 'private')
        and non_hospital_type is null
        and (
          (ownership_type = 'public' and hospital_id is not null and hospital_private_id is null)
          or
          (ownership_type = 'private' and hospital_private_id is not null and hospital_id is null)
        )
      )
      or
      (
        org_kind = 'non_hospital'
        and non_hospital_type in ('pharma', 'online_platform', 'other')
        and ownership_type is null
        and hospital_id is null
        and hospital_private_id is null
      )
    );
exception
  when duplicate_object then null;
end $$;

commit;
