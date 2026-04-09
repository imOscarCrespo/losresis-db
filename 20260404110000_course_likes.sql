create table if not exists public.course_like (
  user_id uuid not null references public.users(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  created_at timestamp with time zone not null default timezone('utc'::text, now()),
  constraint course_like_pkey primary key (user_id, course_id)
);

create index if not exists course_like_course_idx
  on public.course_like (course_id, created_at desc);

alter table public.course_like enable row level security;

drop policy if exists course_like_select_own
  on public.course_like;
create policy course_like_select_own
on public.course_like
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists course_like_insert_own
  on public.course_like;
create policy course_like_insert_own
on public.course_like
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists course_like_delete_own
  on public.course_like;
create policy course_like_delete_own
on public.course_like
for delete
to authenticated
using (auth.uid() = user_id);

grant select, insert, delete on public.course_like to authenticated;
grant all on public.course_like to service_role;
