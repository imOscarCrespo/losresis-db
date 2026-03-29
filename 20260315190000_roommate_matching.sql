set check_function_bodies = off;

create table if not exists public.roommate_question (
    id uuid primary key default gen_random_uuid(),
    code text not null unique,
    step_number integer not null check (step_number between 1 and 6),
    display_order integer not null check (display_order > 0),
    title text not null,
    prompt text not null,
    helper_text text,
    input_type text not null check (input_type in ('single_choice', 'multi_choice', 'scale', 'text')),
    options jsonb not null default '[]'::jsonb,
    category text not null check (category in ('profile', 'lifestyle', 'search')),
    is_required boolean not null default true,
    is_active boolean not null default true,
    created_at timestamp with time zone not null default now()
);

create table if not exists public.roommate_profile (
    user_id uuid primary key,
    headline text,
    bio text,
    about_home text,
    ideal_roommate text,
    dealbreakers text,
    occupation_label text,
    age smallint check (age is null or age between 18 and 99),
    city text not null,
    hospital_id uuid,
    speciality_id uuid,
    residency_year smallint check (residency_year is null or residency_year between 1 and 8),
    home_plan text not null default 'open_to_team_up' check (home_plan in ('already_have_flat', 'need_room', 'open_to_team_up')),
    looking_for text not null default 'shared_flat' check (looking_for in ('room', 'shared_flat', 'studio', 'any')),
    budget_min_eur integer check (budget_min_eur is null or budget_min_eur >= 0),
    budget_max_eur integer check (budget_max_eur is null or budget_max_eur >= 0),
    move_in_date date,
    stay_length_months smallint check (stay_length_months is null or stay_length_months between 1 and 60),
    max_roommates smallint check (max_roommates is null or max_roommates between 1 and 10),
    preferred_neighborhoods text[] not null default '{}'::text[],
    languages text[] not null default '{}'::text[],
    avatar_url text,
    is_active boolean not null default true,
    is_visible boolean not null default true,
    is_verified boolean not null default false,
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    constraint roommate_profile_budget_ck check (
        budget_min_eur is null
        or budget_max_eur is null
        or budget_min_eur <= budget_max_eur
    ),
    constraint roommate_profile_user_id_fkey foreign key (user_id) references public.users(id) on delete cascade,
    constraint roommate_profile_hospital_id_fkey foreign key (hospital_id) references public.hospitals(id) on delete set null,
    constraint roommate_profile_speciality_id_fkey foreign key (speciality_id) references public.specialities(id) on delete set null
);

create table if not exists public.roommate_lifestyle_preference (
    user_id uuid primary key,
    cleanliness_level smallint check (cleanliness_level is null or cleanliness_level between 1 and 5),
    sociability_level smallint check (sociability_level is null or sociability_level between 1 and 5),
    sleep_schedule text check (sleep_schedule is null or sleep_schedule in ('early_bird', 'balanced', 'night_owl')),
    work_from_home text check (work_from_home is null or work_from_home in ('never', 'sometimes', 'often')),
    guests_frequency text check (guests_frequency is null or guests_frequency in ('rarely', 'sometimes', 'often')),
    smoking_habit text check (smoking_habit is null or smoking_habit in ('no', 'outside_only', 'yes')),
    pets text check (pets is null or pets in ('none', 'has_pet', 'pet_friendly')),
    cooking_habit text check (cooking_habit is null or cooking_habit in ('rarely', 'weekly', 'daily')),
    noise_level text check (noise_level is null or noise_level in ('quiet', 'balanced', 'lively')),
    party_frequency text check (party_frequency is null or party_frequency in ('never', 'sometimes', 'often')),
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    constraint roommate_lifestyle_preference_user_id_fkey foreign key (user_id) references public.users(id) on delete cascade
);

create table if not exists public.roommate_search_preference (
    user_id uuid primary key,
    preferred_gender text not null default 'any' check (preferred_gender in ('any', 'women', 'men', 'mixed')),
    min_age smallint check (min_age is null or min_age between 18 and 99),
    max_age smallint check (max_age is null or max_age between 18 and 99),
    budget_min_eur integer check (budget_min_eur is null or budget_min_eur >= 0),
    budget_max_eur integer check (budget_max_eur is null or budget_max_eur >= 0),
    preferred_city text,
    preferred_neighborhoods text[] not null default '{}'::text[],
    move_in_from date,
    move_in_to date,
    preferred_sleep_schedule text not null default 'any' check (preferred_sleep_schedule in ('any', 'early_bird', 'balanced', 'night_owl')),
    min_cleanliness_level smallint check (min_cleanliness_level is null or min_cleanliness_level between 1 and 5),
    min_sociability_level smallint check (min_sociability_level is null or min_sociability_level between 1 and 5),
    accepts_smoking boolean,
    accepts_pets boolean,
    notes text,
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    constraint roommate_search_preference_age_ck check (
        min_age is null
        or max_age is null
        or min_age <= max_age
    ),
    constraint roommate_search_preference_budget_ck check (
        budget_min_eur is null
        or budget_max_eur is null
        or budget_min_eur <= budget_max_eur
    ),
    constraint roommate_search_preference_move_in_ck check (
        move_in_from is null
        or move_in_to is null
        or move_in_from <= move_in_to
    ),
    constraint roommate_search_preference_user_id_fkey foreign key (user_id) references public.users(id) on delete cascade
);

create table if not exists public.roommate_question_answer (
    user_id uuid not null,
    question_id uuid not null,
    answer_text text,
    answer_number numeric(10,2),
    answer_options text[] not null default '{}'::text[],
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    primary key (user_id, question_id),
    constraint roommate_question_answer_value_ck check (
        nullif(btrim(coalesce(answer_text, '')), '') is not null
        or answer_number is not null
        or coalesce(array_length(answer_options, 1), 0) > 0
    ),
    constraint roommate_question_answer_user_id_fkey foreign key (user_id) references public.users(id) on delete cascade,
    constraint roommate_question_answer_question_id_fkey foreign key (question_id) references public.roommate_question(id) on delete cascade
);

create table if not exists public.roommate_saved_filter (
    user_id uuid primary key,
    preferred_city text,
    hospital_id uuid,
    speciality_id uuid,
    budget_max_eur integer check (budget_max_eur is null or budget_max_eur >= 0),
    move_in_from date,
    move_in_to date,
    min_cleanliness_level smallint check (min_cleanliness_level is null or min_cleanliness_level between 1 and 5),
    preferred_sleep_schedule text not null default 'any' check (preferred_sleep_schedule in ('any', 'early_bird', 'balanced', 'night_owl')),
    accepts_pets boolean,
    accepts_smoking boolean,
    only_verified boolean not null default false,
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    constraint roommate_saved_filter_move_in_ck check (
        move_in_from is null
        or move_in_to is null
        or move_in_from <= move_in_to
    ),
    constraint roommate_saved_filter_user_id_fkey foreign key (user_id) references public.users(id) on delete cascade,
    constraint roommate_saved_filter_hospital_id_fkey foreign key (hospital_id) references public.hospitals(id) on delete set null,
    constraint roommate_saved_filter_speciality_id_fkey foreign key (speciality_id) references public.specialities(id) on delete set null
);

create table if not exists public.roommate_swipe (
    id uuid primary key default gen_random_uuid(),
    actor_user_id uuid not null,
    target_user_id uuid not null,
    decision text not null check (decision in ('like', 'pass')),
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    constraint roommate_swipe_actor_target_uq unique (actor_user_id, target_user_id),
    constraint roommate_swipe_actor_target_ck check (actor_user_id <> target_user_id),
    constraint roommate_swipe_actor_user_id_fkey foreign key (actor_user_id) references public.users(id) on delete cascade,
    constraint roommate_swipe_target_user_id_fkey foreign key (target_user_id) references public.users(id) on delete cascade
);

create table if not exists public.roommate_match (
    id uuid primary key default gen_random_uuid(),
    user_low_id uuid not null,
    user_high_id uuid not null,
    initiator_user_id uuid not null,
    matched_at timestamp with time zone not null default now(),
    last_interaction_at timestamp with time zone not null default now(),
    status text not null default 'active' check (status in ('active', 'archived')),
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    constraint roommate_match_pair_uq unique (user_low_id, user_high_id),
    constraint roommate_match_pair_ck check (user_low_id < user_high_id),
    constraint roommate_match_initiator_ck check (initiator_user_id = user_low_id or initiator_user_id = user_high_id),
    constraint roommate_match_user_low_id_fkey foreign key (user_low_id) references public.users(id) on delete cascade,
    constraint roommate_match_user_high_id_fkey foreign key (user_high_id) references public.users(id) on delete cascade,
    constraint roommate_match_initiator_user_id_fkey foreign key (initiator_user_id) references public.users(id) on delete cascade
);

create index if not exists roommate_question_step_idx
    on public.roommate_question(step_number, display_order)
    where is_active = true;

create index if not exists roommate_profile_visibility_idx
    on public.roommate_profile(is_active, is_visible);

create index if not exists roommate_profile_city_idx
    on public.roommate_profile(lower(city));

create index if not exists roommate_profile_hospital_idx
    on public.roommate_profile(hospital_id);

create index if not exists roommate_profile_speciality_idx
    on public.roommate_profile(speciality_id);

create index if not exists roommate_profile_move_in_idx
    on public.roommate_profile(move_in_date);

create index if not exists roommate_question_answer_user_idx
    on public.roommate_question_answer(user_id);

create index if not exists roommate_swipe_actor_created_idx
    on public.roommate_swipe(actor_user_id, created_at desc);

create index if not exists roommate_swipe_target_decision_idx
    on public.roommate_swipe(target_user_id, decision);

create index if not exists roommate_match_low_idx
    on public.roommate_match(user_low_id, matched_at desc);

create index if not exists roommate_match_high_idx
    on public.roommate_match(user_high_id, matched_at desc);

create or replace function public.set_roommate_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trigger_roommate_profile_updated_at on public.roommate_profile;
create trigger trigger_roommate_profile_updated_at
before update on public.roommate_profile
for each row execute function public.set_roommate_updated_at();

drop trigger if exists trigger_roommate_lifestyle_updated_at on public.roommate_lifestyle_preference;
create trigger trigger_roommate_lifestyle_updated_at
before update on public.roommate_lifestyle_preference
for each row execute function public.set_roommate_updated_at();

drop trigger if exists trigger_roommate_search_updated_at on public.roommate_search_preference;
create trigger trigger_roommate_search_updated_at
before update on public.roommate_search_preference
for each row execute function public.set_roommate_updated_at();

drop trigger if exists trigger_roommate_answer_updated_at on public.roommate_question_answer;
create trigger trigger_roommate_answer_updated_at
before update on public.roommate_question_answer
for each row execute function public.set_roommate_updated_at();

drop trigger if exists trigger_roommate_filter_updated_at on public.roommate_saved_filter;
create trigger trigger_roommate_filter_updated_at
before update on public.roommate_saved_filter
for each row execute function public.set_roommate_updated_at();

drop trigger if exists trigger_roommate_swipe_updated_at on public.roommate_swipe;
create trigger trigger_roommate_swipe_updated_at
before update on public.roommate_swipe
for each row execute function public.set_roommate_updated_at();

drop trigger if exists trigger_roommate_match_updated_at on public.roommate_match;
create trigger trigger_roommate_match_updated_at
before update on public.roommate_match
for each row execute function public.set_roommate_updated_at();

alter table public.roommate_question enable row level security;
alter table public.roommate_profile enable row level security;
alter table public.roommate_lifestyle_preference enable row level security;
alter table public.roommate_search_preference enable row level security;
alter table public.roommate_question_answer enable row level security;
alter table public.roommate_saved_filter enable row level security;
alter table public.roommate_swipe enable row level security;
alter table public.roommate_match enable row level security;

create policy roommate_question_select_authenticated
on public.roommate_question
for select
using (auth.uid() is not null);

create policy roommate_profile_select_visible
on public.roommate_profile
for select
using (
    auth.uid() = user_id
    or (is_active = true and is_visible = true)
    or exists (
        select 1
        from public.roommate_match rm
        where rm.status = 'active'
          and (
              (rm.user_low_id = auth.uid() and rm.user_high_id = roommate_profile.user_id)
              or (rm.user_high_id = auth.uid() and rm.user_low_id = roommate_profile.user_id)
          )
    )
);

create policy roommate_profile_insert_own
on public.roommate_profile
for insert
with check (auth.uid() = user_id);

create policy roommate_profile_update_own
on public.roommate_profile
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy roommate_profile_delete_own
on public.roommate_profile
for delete
using (auth.uid() = user_id);

create policy roommate_lifestyle_select_visible
on public.roommate_lifestyle_preference
for select
using (
    auth.uid() = user_id
    or exists (
        select 1
        from public.roommate_profile rp
        where rp.user_id = roommate_lifestyle_preference.user_id
          and rp.is_active = true
          and rp.is_visible = true
    )
    or exists (
        select 1
        from public.roommate_match rm
        where rm.status = 'active'
          and (
              (rm.user_low_id = auth.uid() and rm.user_high_id = roommate_lifestyle_preference.user_id)
              or (rm.user_high_id = auth.uid() and rm.user_low_id = roommate_lifestyle_preference.user_id)
          )
    )
);

create policy roommate_lifestyle_insert_own
on public.roommate_lifestyle_preference
for insert
with check (auth.uid() = user_id);

create policy roommate_lifestyle_update_own
on public.roommate_lifestyle_preference
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy roommate_lifestyle_delete_own
on public.roommate_lifestyle_preference
for delete
using (auth.uid() = user_id);

create policy roommate_search_select_own
on public.roommate_search_preference
for select
using (auth.uid() = user_id);

create policy roommate_search_insert_own
on public.roommate_search_preference
for insert
with check (auth.uid() = user_id);

create policy roommate_search_update_own
on public.roommate_search_preference
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy roommate_search_delete_own
on public.roommate_search_preference
for delete
using (auth.uid() = user_id);

create policy roommate_answer_select_visible
on public.roommate_question_answer
for select
using (
    auth.uid() = user_id
    or exists (
        select 1
        from public.roommate_profile rp
        where rp.user_id = roommate_question_answer.user_id
          and rp.is_active = true
          and rp.is_visible = true
    )
    or exists (
        select 1
        from public.roommate_match rm
        where rm.status = 'active'
          and (
              (rm.user_low_id = auth.uid() and rm.user_high_id = roommate_question_answer.user_id)
              or (rm.user_high_id = auth.uid() and rm.user_low_id = roommate_question_answer.user_id)
          )
    )
);

create policy roommate_answer_insert_own
on public.roommate_question_answer
for insert
with check (auth.uid() = user_id);

create policy roommate_answer_update_own
on public.roommate_question_answer
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy roommate_answer_delete_own
on public.roommate_question_answer
for delete
using (auth.uid() = user_id);

create policy roommate_saved_filter_select_own
on public.roommate_saved_filter
for select
using (auth.uid() = user_id);

create policy roommate_saved_filter_insert_own
on public.roommate_saved_filter
for insert
with check (auth.uid() = user_id);

create policy roommate_saved_filter_update_own
on public.roommate_saved_filter
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy roommate_saved_filter_delete_own
on public.roommate_saved_filter
for delete
using (auth.uid() = user_id);

create policy roommate_swipe_select_own
on public.roommate_swipe
for select
using (auth.uid() = actor_user_id);

create policy roommate_swipe_insert_own
on public.roommate_swipe
for insert
with check (auth.uid() = actor_user_id);

create policy roommate_swipe_update_own
on public.roommate_swipe
for update
using (auth.uid() = actor_user_id)
with check (auth.uid() = actor_user_id);

create policy roommate_swipe_delete_own
on public.roommate_swipe
for delete
using (auth.uid() = actor_user_id);

create policy roommate_match_select_own
on public.roommate_match
for select
using (auth.uid() = user_low_id or auth.uid() = user_high_id);

create policy roommate_match_insert_own_pair
on public.roommate_match
for insert
with check (
    (auth.uid() = user_low_id or auth.uid() = user_high_id)
    and (initiator_user_id = auth.uid())
);

create policy roommate_match_update_own_pair
on public.roommate_match
for update
using (auth.uid() = user_low_id or auth.uid() = user_high_id)
with check (auth.uid() = user_low_id or auth.uid() = user_high_id);

grant select on public.roommate_question to authenticated;
grant select, insert, update, delete on public.roommate_profile to authenticated;
grant select, insert, update, delete on public.roommate_lifestyle_preference to authenticated;
grant select, insert, update, delete on public.roommate_search_preference to authenticated;
grant select, insert, update, delete on public.roommate_question_answer to authenticated;
grant select, insert, update, delete on public.roommate_saved_filter to authenticated;
grant select, insert, update, delete on public.roommate_swipe to authenticated;
grant select, insert, update, delete on public.roommate_match to authenticated;

grant all on public.roommate_question to service_role;
grant all on public.roommate_profile to service_role;
grant all on public.roommate_lifestyle_preference to service_role;
grant all on public.roommate_search_preference to service_role;
grant all on public.roommate_question_answer to service_role;
grant all on public.roommate_saved_filter to service_role;
grant all on public.roommate_swipe to service_role;
grant all on public.roommate_match to service_role;

insert into public.roommate_question (
    code,
    step_number,
    display_order,
    title,
    prompt,
    helper_text,
    input_type,
    options,
    category
)
values
    (
        'cleanliness_priority',
        1,
        1,
        'Orden y limpieza',
        '¿Qué nivel de orden necesitas para estar a gusto en casa?',
        'Nos ayuda a encontrar ritmos de convivencia compatibles.',
        'scale',
        '[{"value":1,"label":"Flexible"},{"value":3,"label":"Equilibrado"},{"value":5,"label":"Muy ordenado"}]'::jsonb,
        'lifestyle'
    ),
    (
        'sleep_schedule',
        2,
        2,
        'Horario habitual',
        '¿Cómo suele ser tu ritmo entre semana?',
        'Piensa en tus guardias, estudio y descanso.',
        'single_choice',
        '[{"value":"early_bird","label":"Madrugador/a"},{"value":"balanced","label":"Bastante equilibrado"},{"value":"night_owl","label":"Nocturno/a"}]'::jsonb,
        'lifestyle'
    ),
    (
        'weekday_vibe',
        3,
        3,
        'Plan entre semana',
        'Después del hospital o la facultad, ¿qué ambiente prefieres en casa?',
        null,
        'single_choice',
        '[{"value":"quiet","label":"Tranquilo y silencioso"},{"value":"balanced","label":"Algo de charla pero con calma"},{"value":"social","label":"Con vida y planes"}]'::jsonb,
        'lifestyle'
    ),
    (
        'shared_spaces',
        4,
        4,
        'Espacios compartidos',
        '¿Qué cosas te importan más en una convivencia?',
        'Puedes marcar varias.',
        'multi_choice',
        '[{"value":"clean_kitchen","label":"Cocina cuidada"},{"value":"shared_meals","label":"Compartir alguna comida"},{"value":"quiet_nights","label":"Noches tranquilas"},{"value":"guest_rules","label":"Normas claras con visitas"},{"value":"study_respect","label":"Respeto a tiempos de estudio o descanso"}]'::jsonb,
        'lifestyle'
    ),
    (
        'weekend_plan',
        5,
        5,
        'Fin de semana',
        '¿Qué plan encaja más contigo cuando libras?',
        null,
        'single_choice',
        '[{"value":"stay_in","label":"Casa, descanso y recados"},{"value":"mixed","label":"Un poco de todo"},{"value":"go_out","label":"Salir y hacer planes"}]'::jsonb,
        'profile'
    ),
    (
        'roommate_goal',
        6,
        6,
        'Lo que buscas',
        '¿Qué te gustaría encontrar en tu próximo compi de piso?',
        null,
        'text',
        '[]'::jsonb,
        'search'
    )
on conflict (code) do update
set
    step_number = excluded.step_number,
    display_order = excluded.display_order,
    title = excluded.title,
    prompt = excluded.prompt,
    helper_text = excluded.helper_text,
    input_type = excluded.input_type,
    options = excluded.options,
    category = excluded.category,
    is_required = true,
    is_active = true;
