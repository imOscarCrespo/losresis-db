create table if not exists public.user_feature_access (
  user_id uuid not null,
  feature_key text not null,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_feature_access_pkey primary key (user_id, feature_key),
  constraint user_feature_access_user_id_fkey
    foreign key (user_id)
    references public.users (id)
    on delete cascade
);

create index if not exists idx_user_feature_access_feature_key
  on public.user_feature_access (feature_key);

drop trigger if exists trg_user_feature_access_updated_at
  on public.user_feature_access;
create trigger trg_user_feature_access_updated_at
before update on public.user_feature_access
for each row execute function public.set_updated_at_timestamp_generic();

alter table public.user_feature_access enable row level security;

drop policy if exists user_feature_access_select_own
  on public.user_feature_access;
create policy user_feature_access_select_own
  on public.user_feature_access
  for select
  to authenticated
  using (auth.uid() = user_id);

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
  select coalesce((
    select ufa.enabled
    from public.user_feature_access ufa
    where ufa.user_id = p_user_id
      and ufa.feature_key = p_feature_key
    limit 1
  ), false);
$$;

revoke all on public.user_feature_access from anon;
revoke all on public.user_feature_access from authenticated;
grant select on public.user_feature_access to authenticated;

revoke all on function public.can_use_feature(text, uuid) from public;
grant execute on function public.can_use_feature(text, uuid) to authenticated;
grant execute on function public.can_use_feature(text, uuid) to service_role;
