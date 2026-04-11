-- Registrations for hospital open days created from losresis-app and visible in losresis-panel.
-- Keep this migration in sync with losresis-app/supabase/migrations because both apps share the same database.

begin;

create table if not exists public.hospital_open_day_registration (
  id uuid primary key default extensions.uuid_generate_v4(),
  open_day_id uuid not null references public.hospital_open_day(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (open_day_id, user_id)
);

create index if not exists idx_hospital_open_day_registration_open_day
  on public.hospital_open_day_registration (open_day_id, created_at desc);

create index if not exists idx_hospital_open_day_registration_user
  on public.hospital_open_day_registration (user_id, created_at desc);

alter table public.hospital_open_day_registration enable row level security;

do $$
begin
  create policy hospital_open_day_registration_allow_all
    on public.hospital_open_day_registration
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

grant all on table public.hospital_open_day_registration to anon, authenticated, service_role;

commit;
