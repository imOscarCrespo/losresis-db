alter table public.group_messages
  drop constraint if exists group_messages_user_id_fkey;

alter table public.group_messages
  add constraint group_messages_user_id_fkey
  foreign key (user_id)
  references public.users(id)
  on delete cascade;
