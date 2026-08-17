-- Audience targeting for course_published notifications.
--
-- Until now trg_notify_course_published notified EVERY user of the course's
-- speciality (residents, doctors and students alike). From now on:
--   * Course notifications go to residents only (is_resident = true), always.
--   * The creator can choose the audience at creation time via three new
--     columns on public.courses:
--       - notify_scope: 'speciality' (default, whole speciality),
--         'custom' (narrowed by hospitals and/or resident years) or
--         'none' (no notification at all).
--       - notify_hospital_ids: hospitals whose residents get notified when
--         notify_scope = 'custom'. NULL/empty = no hospital restriction.
--       - notify_resident_years: resident years (1-5) notified when
--         notify_scope = 'custom'. NULL/empty = all years.
-- Inserts that do not set these columns (weekly external courses bot, legacy
-- paths) keep today's behaviour: whole speciality, residents only.

alter table public.courses
  add column if not exists notify_scope text not null default 'speciality',
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
begin
  if new.speciality_id is null then
    return new;
  end if;

  if v_scope = 'none' then
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
    'Nuevo curso en tu especialidad',
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
  where u.speciality_id = new.speciality_id
    and u.is_resident = true
    and u.id <> coalesce(new.created_by_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and (
      v_scope <> 'custom'
      or new.notify_hospital_ids is null
      or cardinality(new.notify_hospital_ids) = 0
      or u.hospital_id = any(new.notify_hospital_ids)
    )
    and (
      v_scope <> 'custom'
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

comment on column public.courses.notify_scope is
  'Audience of the course_published notification: speciality (all residents of the speciality), custom (narrowed by notify_hospital_ids / notify_resident_years) or none.';
comment on column public.courses.notify_hospital_ids is
  'When notify_scope = custom, hospitals whose residents are notified. NULL or empty = no hospital restriction.';
comment on column public.courses.notify_resident_years is
  'When notify_scope = custom, resident years (1-5) that are notified. NULL or empty = all years.';
