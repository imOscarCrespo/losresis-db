create or replace function public.handle_user_deleted_delete_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform net.http_post(
      url := 'https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-user-deleted',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
      ),
      body := jsonb_build_object('user_id', old.id)
    );
  exception
    when others then
      raise warning 'handle_user_deleted_delete_auth failed for user %: %', old.id, sqlerrm;
  end;

  return old;
end;
$$;

alter function public.handle_user_deleted_delete_auth() owner to postgres;

drop trigger if exists on_user_deleted_delete_auth on public.users;

create trigger on_user_deleted_delete_auth
after delete on public.users
for each row
execute function public.handle_user_deleted_delete_auth();
