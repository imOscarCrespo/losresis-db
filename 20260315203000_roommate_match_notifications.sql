insert into public.notification_types (code, description)
values (
  'roommate_match',
  'Notificacion cuando dos usuarios hacen match en roomies'
)
on conflict (code) do nothing;

create or replace function public.notify_roommate_match()
returns trigger
language plpgsql
security definer
as $$
begin
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
  values
    (
      new.user_low_id,
      'roommate_match',
      new.user_high_id,
      'Nuevo match de roomies',
      'Has hecho match con un futuro companero de piso.',
      'roommate_match',
      new.id,
      jsonb_build_object(
        'entity_type', 'roommate_match',
        'entity_id', new.id,
        'destination_section', 'roomies',
        'destination_tab', 'matches'
      )
    ),
    (
      new.user_high_id,
      'roommate_match',
      new.user_low_id,
      'Nuevo match de roomies',
      'Has hecho match con un futuro companero de piso.',
      'roommate_match',
      new.id,
      jsonb_build_object(
        'entity_type', 'roommate_match',
        'entity_id', new.id,
        'destination_section', 'roomies',
        'destination_tab', 'matches'
      )
    );

  return new;
end;
$$;

drop trigger if exists trigger_notify_roommate_match on public.roommate_match;

create trigger trigger_notify_roommate_match
after insert on public.roommate_match
for each row
when (new.status = 'active')
execute function public.notify_roommate_match();

grant all on function public.notify_roommate_match() to anon;
grant all on function public.notify_roommate_match() to authenticated;
grant all on function public.notify_roommate_match() to service_role;
