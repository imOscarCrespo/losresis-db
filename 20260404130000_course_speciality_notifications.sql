insert into public.notification_types (code, description)
values (
  'course_published',
  'Notificacion cuando se publica un curso de la especialidad del usuario'
)
on conflict (code) do nothing;

create index if not exists idx_users_speciality_id
  on public.users (speciality_id)
  where speciality_id is not null;

create or replace function public.notify_course_published()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_should_notify boolean := false;
begin
  if new.speciality_id is null then
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
    and u.id <> coalesce(new.created_by_id, '00000000-0000-0000-0000-000000000000'::uuid)
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
