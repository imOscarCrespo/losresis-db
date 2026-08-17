-- Course notification audience: speciality is now a filter too.
--
-- 20260727140000_course_notification_audience.sql let the creator narrow the
-- course_published notification by hospital and resident year, but the
-- speciality was always the course's own speciality_id. Hospitals asked for
-- three combinable filters instead:
--   * notify_speciality_ids: specialities whose residents get notified when
--     notify_scope = 'custom'. NULL/empty = every speciality (all of Spain).
--   * notify_hospital_ids:   NULL/empty = every hospital (unchanged).
--   * notify_resident_years: NULL/empty = every year R1-R5 (unchanged).
-- The filters are combined with AND, so 'Hospital de Vic' + R2 reaches only
-- the R2 residents of that hospital, while R2 alone reaches every R2 of the
-- selected specialities.
--
-- notify_scope = 'speciality' keeps its old meaning (all residents of the
-- course's speciality_id, every hospital, every year), so the weekly external
-- courses bot and any legacy insert behave exactly as before.
--
-- This migration is self-contained and idempotent: it also creates the columns
-- introduced by 20260727140000_course_notification_audience.sql, so it applies
-- cleanly whether or not that one already ran. Course notifications go to
-- residents only (is_resident = true), never to doctors or students.

alter table public.courses
  add column if not exists notify_scope text not null default 'speciality',
  add column if not exists notify_speciality_ids uuid[],
  add column if not exists notify_hospital_ids uuid[],
  add column if not exists notify_resident_years integer[];

alter table public.courses
  drop constraint if exists courses_notify_scope_check;
alter table public.courses
  add constraint courses_notify_scope_check
  check (notify_scope in ('speciality', 'custom', 'none'));

alter table public.courses
  drop constraint if exists courses_notify_resident_years_check;
alter table public.courses
  add constraint courses_notify_resident_years_check
  check (
    notify_resident_years is null
    or notify_resident_years <@ array[1, 2, 3, 4, 5]
  );

create or replace function public.notify_course_published()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_should_notify boolean := false;
  v_scope text := coalesce(new.notify_scope, 'speciality');
  v_custom boolean := coalesce(new.notify_scope, 'speciality') = 'custom';
  v_all_specialities boolean :=
    new.notify_speciality_ids is null
    or cardinality(new.notify_speciality_ids) = 0;
begin
  if v_scope = 'none' then
    return new;
  end if;

  -- Outside 'custom' the audience is the course's own speciality, so without
  -- it there is nobody to notify. In 'custom' the speciality filter is
  -- explicit and may even be empty (= every speciality).
  if not v_custom and new.speciality_id is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_should_notify := new.status = 'published';
  elsif tg_op = 'UPDATE' then
    v_should_notify := new.status = 'published'
      and coalesce(old.status, '') <> 'published';
  end if;

  if not v_should_notify then
    return new;
  end if;

  insert into public.notifications (
    user_id,
    type,
    actor_user_id,
    title,
    body,
    entity_type,
    entity_id,
    data
  )
  select
    u.id,
    'course_published',
    new.created_by_id,
    case
      when v_custom and v_all_specialities then 'Nuevo curso disponible'
      else 'Nuevo curso en tu especialidad'
    end,
    case
      when char_length(new.title) > 140 then left(new.title, 137) || '...'
      else new.title
    end,
    'course',
    new.id,
    jsonb_build_object(
      'entity_type', 'course',
      'entity_id', new.id,
      'course_id', new.id,
      'course_title', new.title,
      'speciality_id', new.speciality_id,
      'destination_section', 'cursos'
    )
  from public.users u
  left join public.user_notification_preferences pref
    on pref.user_id = u.id
   and pref.notification_type = 'course_published'
  where u.is_resident = true
    and u.id <> coalesce(new.created_by_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and (
      case
        when not v_custom then u.speciality_id = new.speciality_id
        when v_all_specialities then true
        else u.speciality_id = any(new.notify_speciality_ids)
      end
    )
    and (
      not v_custom
      or new.notify_hospital_ids is null
      or cardinality(new.notify_hospital_ids) = 0
      or u.hospital_id = any(new.notify_hospital_ids)
    )
    and (
      not v_custom
      or new.notify_resident_years is null
      or cardinality(new.notify_resident_years) = 0
      or u.resident_year = any(new.notify_resident_years)
    )
    and (
      pref.user_id is null
      or coalesce(pref.push_enabled, true) = true
      or coalesce(pref.in_app_enabled, true) = true
    );

  return new;
end;
$$;

drop trigger if exists trg_notify_course_published on public.courses;

create trigger trg_notify_course_published
after insert or update on public.courses
for each row
execute function public.notify_course_published();

grant all on function public.notify_course_published() to anon;
grant all on function public.notify_course_published() to authenticated;
grant all on function public.notify_course_published() to service_role;

comment on column public.courses.notify_scope is
  'Audience of the course_published notification: speciality (all residents of the course speciality), custom (narrowed by notify_speciality_ids / notify_hospital_ids / notify_resident_years) or none.';
comment on column public.courses.notify_speciality_ids is
  'When notify_scope = custom, specialities whose residents are notified. NULL or empty = every speciality.';
comment on column public.courses.notify_hospital_ids is
  'When notify_scope = custom, hospitals whose residents are notified. NULL or empty = every hospital.';
comment on column public.courses.notify_resident_years is
  'When notify_scope = custom, resident years (1-5) that are notified. NULL or empty = every year.';
