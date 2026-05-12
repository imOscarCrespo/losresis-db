create or replace function public.can_use_feature(
  p_feature_key text,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when coalesce((
      select u.is_super_admin
      from public.users u
      where u.id = p_user_id
      limit 1
    ), false) then true
    else coalesce((
      select ufa.enabled
      from public.user_feature_access ufa
      where ufa.user_id = p_user_id
        and ufa.feature_key = p_feature_key
      limit 1
    ), false)
  end;
$$;

revoke all on function public.can_use_feature(text, uuid) from public;
grant execute on function public.can_use_feature(text, uuid) to authenticated;
grant execute on function public.can_use_feature(text, uuid) to service_role;
