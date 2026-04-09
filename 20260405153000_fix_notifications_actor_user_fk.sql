alter table public.notifications
  drop constraint if exists notifications_actor_user_id_fkey;

alter table public.notifications
  add constraint notifications_actor_user_id_fkey
  foreign key (actor_user_id)
  references public.users(id)
  on delete set null;
