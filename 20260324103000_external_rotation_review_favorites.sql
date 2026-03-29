create table if not exists public.external_rotation_review_favorite (
  user_id uuid not null references public.users(id) on delete cascade,
  review_id uuid not null references public.external_rotation_review(id) on delete cascade,
  created_at timestamp with time zone not null default timezone('utc'::text, now()),
  constraint external_rotation_review_favorite_pkey primary key (user_id, review_id)
);

create index if not exists external_rotation_review_favorite_review_idx
  on public.external_rotation_review_favorite (review_id, created_at desc);

alter table public.external_rotation_review_favorite enable row level security;

drop policy if exists external_rotation_review_favorite_select_own
  on public.external_rotation_review_favorite;
create policy external_rotation_review_favorite_select_own
on public.external_rotation_review_favorite
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists external_rotation_review_favorite_insert_own
  on public.external_rotation_review_favorite;
create policy external_rotation_review_favorite_insert_own
on public.external_rotation_review_favorite
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists external_rotation_review_favorite_delete_own
  on public.external_rotation_review_favorite;
create policy external_rotation_review_favorite_delete_own
on public.external_rotation_review_favorite
for delete
to authenticated
using (auth.uid() = user_id);

grant select, insert, delete on public.external_rotation_review_favorite to authenticated;
grant all on public.external_rotation_review_favorite to service_role;
