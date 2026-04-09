-- Hospital visibility sponsorship + precomputed ranking snapshots.
-- Snapshot-first design to protect Supabase read latency.

begin;

create table if not exists public.hospital_sponsorship (
  id uuid primary key default extensions.uuid_generate_v4(),
  org_id uuid not null references public.employer_org(id) on delete cascade,
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  speciality_id uuid references public.specialities(id) on delete cascade,
  tier_code text not null check (tier_code in ('free', 'boost', 'featured', 'premium')),
  monthly_budget_eur integer not null default 0 check (monthly_budget_eur >= 0),
  status text not null default 'draft' check (status in ('draft', 'active', 'paused', 'expired')),
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_employer_org_id_hospital_id_unique
  on public.employer_org (id, hospital_id)
  where hospital_id is not null;

create unique index if not exists idx_hospital_sponsorship_org_scope
  on public.hospital_sponsorship (org_id, hospital_id, coalesce(speciality_id, '00000000-0000-0000-0000-000000000000'::uuid));

create index if not exists idx_hospital_sponsorship_active_scope
  on public.hospital_sponsorship (hospital_id, speciality_id, status, starts_at, ends_at);

create table if not exists public.hospital_ranking_config (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.hospital_ranking_signal_daily (
  day date not null,
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  speciality_id uuid references public.specialities(id) on delete cascade,
  approved_review_count integer not null default 0,
  approved_review_answer_count integer not null default 0,
  approved_review_rating_sum numeric(12,2) not null default 0,
  profile_completeness_score numeric(8,2) not null default 0,
  active_sponsorship_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_hospital_ranking_signal_daily_scope
  on public.hospital_ranking_signal_daily (
    day,
    hospital_id,
    coalesce(speciality_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index if not exists idx_hospital_ranking_signal_daily_lookup
  on public.hospital_ranking_signal_daily (hospital_id, speciality_id, day desc);

create table if not exists public.hospital_ranking_score (
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  speciality_id uuid references public.specialities(id) on delete cascade,
  approved_review_count integer not null default 0,
  average_rating numeric(8,2) not null default 0,
  review_volume_score numeric(8,2) not null default 0,
  bayesian_rating_score numeric(8,2) not null default 0,
  profile_completeness_score numeric(8,2) not null default 0,
  organic_score numeric(8,2) not null default 0,
  sponsorship_tier text not null default 'free',
  sponsorship_weight numeric(8,2) not null default 0,
  sponsorship_boost_score numeric(8,2) not null default 0,
  final_score numeric(8,2) not null default 0,
  is_sponsored boolean not null default false,
  sponsorship_label text,
  top_guardrail_applied boolean not null default false,
  organic_rank integer,
  blended_rank integer,
  computed_at timestamptz not null default now()
);

create unique index if not exists idx_hospital_ranking_score_scope
  on public.hospital_ranking_score (
    hospital_id,
    coalesce(speciality_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index if not exists idx_hospital_ranking_score_blended
  on public.hospital_ranking_score (speciality_id, blended_rank, hospital_id);

create index if not exists idx_hospital_ranking_score_organic
  on public.hospital_ranking_score (speciality_id, organic_rank, hospital_id);

create or replace function public.set_updated_at_timestamp_hospital_ranker()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_hospital_sponsorship_updated_at on public.hospital_sponsorship;
create trigger trg_hospital_sponsorship_updated_at
before update on public.hospital_sponsorship
for each row execute function public.set_updated_at_timestamp_hospital_ranker();

drop trigger if exists trg_hospital_ranking_signal_daily_updated_at on public.hospital_ranking_signal_daily;
create trigger trg_hospital_ranking_signal_daily_updated_at
before update on public.hospital_ranking_signal_daily
for each row execute function public.set_updated_at_timestamp_hospital_ranker();

insert into public.hospital_ranking_config (key, value)
values
  ('v1', jsonb_build_object(
    'global_mean_rating', 7.0,
    'bayesian_prior_count', 5,
    'review_volume_log_cap', 25,
    'organic_weights', jsonb_build_object(
      'rating', 0.65,
      'volume', 0.25,
      'profile', 0.10
    ),
    'tier_weights', jsonb_build_object(
      'free', 0,
      'boost', 6,
      'featured', 12,
      'premium', 18
    ),
    'boost_cap_pct', 0.30,
    'minimum_review_count_for_sponsorship', 3,
    'minimum_organic_score_for_top3', 45
  ))
on conflict (key) do update
set value = excluded.value,
    updated_at = now();

create or replace function public.refresh_hospital_ranking_signal_daily(
  p_target_day date default current_date
)
returns void
language plpgsql
as $$
begin
  delete from public.hospital_ranking_signal_daily
  where day = p_target_day;

  insert into public.hospital_ranking_signal_daily (
    day,
    hospital_id,
    speciality_id,
    approved_review_count,
    approved_review_answer_count,
    approved_review_rating_sum,
    profile_completeness_score,
    active_sponsorship_count
  )
  with review_rollup as (
    select
      r.hospital_id,
      r.speciality_id,
      count(*)::integer as approved_review_count,
      count(ra.rating_value)::integer as approved_review_answer_count,
      coalesce(sum(ra.rating_value), 0)::numeric(12,2) as approved_review_rating_sum
    from public.review r
    left join public.review_answer ra
      on ra.review_id = r.id
      and ra.rating_value is not null
    where r.is_approved = true
      and r.created_at < (p_target_day + interval '1 day')
    group by r.hospital_id, r.speciality_id
  ),
  profile_rollup as (
    select
      eo.hospital_id,
      eops.speciality_id,
      least(
        100::numeric,
        (
          case when eop.about is not null and length(trim(eop.about)) >= 80 then 40 else 0 end
          + least(coalesce(image_count, 0), 4) * 10
          + least(coalesce(speciality_count, 0), 4) * 5
          + case when eops.plan_formativo_url is not null then 20 else 0 end
        )::numeric
      ) as profile_completeness_score
    from public.employer_org eo
    left join public.employer_org_profile eop
      on eop.org_id = eo.id
    left join (
      select org_id, count(*)::integer as image_count
      from public.employer_org_profile_image
      group by org_id
    ) img on img.org_id = eo.id
    left join (
      select org_id, count(*)::integer as speciality_count
      from public.employer_org_profile_speciality
      group by org_id
    ) spec_count on spec_count.org_id = eo.id
    left join public.employer_org_profile_speciality eops
      on eops.org_id = eo.id
    where eo.hospital_id is not null
  ),
  sponsorship_rollup as (
    select
      hs.hospital_id,
      hs.speciality_id,
      count(*)::integer as active_sponsorship_count
    from public.hospital_sponsorship hs
    where hs.status = 'active'
      and coalesce(hs.starts_at, '-infinity'::timestamptz) <= (p_target_day + interval '1 day')
      and coalesce(hs.ends_at, 'infinity'::timestamptz) >= p_target_day
    group by hs.hospital_id, hs.speciality_id
  ),
  hospital_speciality_scope as (
    select hospital_id, speciality_id from public.hospital_specialities
    union
    select hospital_id, speciality_id from review_rollup
    union
    select hospital_id, speciality_id from profile_rollup
    union
    select hospital_id, speciality_id from sponsorship_rollup
  )
  select
    p_target_day,
    scope.hospital_id,
    scope.speciality_id,
    coalesce(rr.approved_review_count, 0),
    coalesce(rr.approved_review_answer_count, 0),
    coalesce(rr.approved_review_rating_sum, 0),
    coalesce(pr.profile_completeness_score, 0),
    coalesce(sr.active_sponsorship_count, 0)
  from hospital_speciality_scope scope
  left join review_rollup rr
    on rr.hospital_id = scope.hospital_id
    and rr.speciality_id = scope.speciality_id
  left join profile_rollup pr
    on pr.hospital_id = scope.hospital_id
    and pr.speciality_id = scope.speciality_id
  left join sponsorship_rollup sr
    on sr.hospital_id = scope.hospital_id
    and sr.speciality_id is not distinct from scope.speciality_id;
end;
$$;

create or replace function public.refresh_hospital_ranking_scores()
returns void
language plpgsql
as $$
declare
  v_config jsonb;
begin
  select value
  into v_config
  from public.hospital_ranking_config
  where key = 'v1';

  if v_config is null then
    raise exception 'Missing hospital ranking config';
  end if;

  perform public.refresh_hospital_ranking_signal_daily(current_date);

  truncate table public.hospital_ranking_score;

  insert into public.hospital_ranking_score (
    hospital_id,
    speciality_id,
    approved_review_count,
    average_rating,
    review_volume_score,
    bayesian_rating_score,
    profile_completeness_score,
    organic_score,
    sponsorship_tier,
    sponsorship_weight,
    sponsorship_boost_score,
    final_score,
    is_sponsored,
    sponsorship_label,
    top_guardrail_applied,
    computed_at
  )
  with latest_signals as (
    select
      hsd.hospital_id,
      hsd.speciality_id,
      sum(hsd.approved_review_count)::integer as approved_review_count,
      sum(hsd.approved_review_answer_count)::integer as approved_review_answer_count,
      sum(hsd.approved_review_rating_sum)::numeric(12,2) as approved_review_rating_sum,
      max(hsd.profile_completeness_score)::numeric(8,2) as profile_completeness_score
    from public.hospital_ranking_signal_daily hsd
    where hsd.day >= current_date - interval '365 day'
    group by hsd.hospital_id, hsd.speciality_id
  ),
  sponsorship_scope as (
    select distinct on (hs.hospital_id, hs.speciality_id)
      hs.hospital_id,
      hs.speciality_id,
      hs.tier_code,
      hs.monthly_budget_eur
    from public.hospital_sponsorship hs
    where hs.status = 'active'
      and coalesce(hs.starts_at, '-infinity'::timestamptz) <= now()
      and coalesce(hs.ends_at, 'infinity'::timestamptz) >= now()
    order by hs.hospital_id, hs.speciality_id, hs.monthly_budget_eur desc, hs.updated_at desc
  ),
  scored as (
    select
      ls.hospital_id,
      ls.speciality_id,
      ls.approved_review_count,
      case
        when ls.approved_review_answer_count > 0
          then round((ls.approved_review_rating_sum / ls.approved_review_answer_count)::numeric, 2)
        else 0::numeric
      end as average_rating,
      round(
        least(
          100::numeric,
          (ln(1 + ls.approved_review_count::numeric) / ln((coalesce((v_config->>'review_volume_log_cap')::numeric, 25)) + 1)) * 100
        ),
        2
      ) as review_volume_score,
      round(
        (
          (
            (
              (coalesce((v_config->>'global_mean_rating')::numeric, 7.0)
                * coalesce((v_config->>'bayesian_prior_count')::numeric, 5))
              + ls.approved_review_rating_sum
            )
            /
            greatest(
              coalesce((v_config->>'bayesian_prior_count')::numeric, 5)
              + ls.approved_review_answer_count,
              1
            )
          ) / 10
        ) * 100,
        2
      ) as bayesian_rating_score,
      ls.profile_completeness_score,
      coalesce(ss.tier_code, 'free') as sponsorship_tier,
      coalesce(((v_config->'tier_weights'->>coalesce(ss.tier_code, 'free'))::numeric), 0) as sponsorship_weight
    from latest_signals ls
    left join sponsorship_scope ss
      on ss.hospital_id = ls.hospital_id
      and ss.speciality_id is not distinct from ls.speciality_id
  )
  select
    scored.hospital_id,
    scored.speciality_id,
    scored.approved_review_count,
    scored.average_rating,
    scored.review_volume_score,
    scored.bayesian_rating_score,
    scored.profile_completeness_score,
    round(
      (
        scored.bayesian_rating_score * coalesce((v_config->'organic_weights'->>'rating')::numeric, 0.65)
        + scored.review_volume_score * coalesce((v_config->'organic_weights'->>'volume')::numeric, 0.25)
        + scored.profile_completeness_score * coalesce((v_config->'organic_weights'->>'profile')::numeric, 0.10)
      ),
      2
    ) as organic_score,
    scored.sponsorship_tier,
    scored.sponsorship_weight,
    round(
      least(
        (
          (
            scored.bayesian_rating_score * coalesce((v_config->'organic_weights'->>'rating')::numeric, 0.65)
            + scored.review_volume_score * coalesce((v_config->'organic_weights'->>'volume')::numeric, 0.25)
            + scored.profile_completeness_score * coalesce((v_config->'organic_weights'->>'profile')::numeric, 0.10)
          ) * coalesce((v_config->>'boost_cap_pct')::numeric, 0.30)
        ),
        case
          when scored.approved_review_count >= coalesce((v_config->>'minimum_review_count_for_sponsorship')::integer, 3)
            then scored.sponsorship_weight
          else 0::numeric
        end
      ),
      2
    ) as sponsorship_boost_score,
    round(
      (
        (
          scored.bayesian_rating_score * coalesce((v_config->'organic_weights'->>'rating')::numeric, 0.65)
          + scored.review_volume_score * coalesce((v_config->'organic_weights'->>'volume')::numeric, 0.25)
          + scored.profile_completeness_score * coalesce((v_config->'organic_weights'->>'profile')::numeric, 0.10)
        )
        +
        least(
          (
            (
              scored.bayesian_rating_score * coalesce((v_config->'organic_weights'->>'rating')::numeric, 0.65)
              + scored.review_volume_score * coalesce((v_config->'organic_weights'->>'volume')::numeric, 0.25)
              + scored.profile_completeness_score * coalesce((v_config->'organic_weights'->>'profile')::numeric, 0.10)
            ) * coalesce((v_config->>'boost_cap_pct')::numeric, 0.30)
          ),
          case
            when scored.approved_review_count >= coalesce((v_config->>'minimum_review_count_for_sponsorship')::integer, 3)
              then scored.sponsorship_weight
            else 0::numeric
          end
        )
      ),
      2
    ) as final_score,
    (scored.sponsorship_tier <> 'free' and scored.approved_review_count >= coalesce((v_config->>'minimum_review_count_for_sponsorship')::integer, 3)) as is_sponsored,
    case scored.sponsorship_tier
      when 'premium' then 'Patrocinado'
      when 'featured' then 'Destacado'
      when 'boost' then 'Impulsado'
      else null
    end as sponsorship_label,
    (
      (
        scored.bayesian_rating_score * coalesce((v_config->'organic_weights'->>'rating')::numeric, 0.65)
        + scored.review_volume_score * coalesce((v_config->'organic_weights'->>'volume')::numeric, 0.25)
        + scored.profile_completeness_score * coalesce((v_config->'organic_weights'->>'profile')::numeric, 0.10)
      ) < coalesce((v_config->>'minimum_organic_score_for_top3')::numeric, 45)
    ) as top_guardrail_applied,
    now()
  from scored;

  with ranked as (
    select
      hrs.hospital_id,
      hrs.speciality_id,
      row_number() over (
        partition by hrs.speciality_id
        order by hrs.organic_score desc, hrs.approved_review_count desc, hrs.hospital_id asc
      ) as organic_rank,
      row_number() over (
        partition by hrs.speciality_id
        order by
          case
            when hrs.top_guardrail_applied then hrs.organic_score
            else hrs.final_score
          end desc,
          hrs.organic_score desc,
          hrs.approved_review_count desc,
          hrs.hospital_id asc
      ) as blended_rank
    from public.hospital_ranking_score hrs
  )
  update public.hospital_ranking_score hrs
  set organic_rank = ranked.organic_rank,
      blended_rank = ranked.blended_rank
  from ranked
  where ranked.hospital_id = hrs.hospital_id
    and ranked.speciality_id is not distinct from hrs.speciality_id;
end;
$$;

create or replace view public.v_hospital_discovery_ranked as
select
  hrs.hospital_id,
  h.name as hospital_name,
  h.city,
  h.region,
  hrs.speciality_id,
  s.name as speciality_name,
  hrs.approved_review_count,
  hrs.average_rating,
  hrs.organic_score,
  hrs.final_score,
  hrs.organic_rank,
  hrs.blended_rank,
  hrs.is_sponsored,
  hrs.sponsorship_tier,
  hrs.sponsorship_label,
  hrs.computed_at
from public.hospital_ranking_score hrs
join public.hospitals h on h.id = hrs.hospital_id
left join public.specialities s on s.id = hrs.speciality_id;

create or replace function public.get_org_hospital_visibility_summary(p_org_id uuid)
returns table (
  org_id uuid,
  hospital_id uuid,
  hospital_name text,
  current_tier text,
  monthly_budget_eur integer,
  sponsorship_status text,
  starts_at timestamptz,
  ends_at timestamptz,
  organic_score numeric,
  final_score numeric,
  organic_rank integer,
  blended_rank integer,
  approved_review_count integer,
  is_sponsored boolean,
  sponsorship_label text,
  computed_at timestamptz
)
language sql
stable
as $$
  with org_hospital as (
    select eo.id as org_id, eo.hospital_id
    from public.employer_org eo
    where eo.id = p_org_id
      and eo.hospital_id is not null
  ),
  current_sponsorship as (
    select distinct on (hs.org_id, hs.hospital_id)
      hs.org_id,
      hs.hospital_id,
      hs.tier_code,
      hs.monthly_budget_eur,
      hs.status,
      hs.starts_at,
      hs.ends_at
    from public.hospital_sponsorship hs
    where hs.org_id = p_org_id
    order by hs.org_id, hs.hospital_id, hs.updated_at desc
  ),
  general_rank as (
    select *
    from public.hospital_ranking_score hrs
    where hrs.speciality_id is null
  )
  select
    oh.org_id,
    oh.hospital_id,
    h.name,
    coalesce(cs.tier_code, 'free') as current_tier,
    coalesce(cs.monthly_budget_eur, 0) as monthly_budget_eur,
    coalesce(cs.status, 'draft') as sponsorship_status,
    cs.starts_at,
    cs.ends_at,
    coalesce(gr.organic_score, 0),
    coalesce(gr.final_score, 0),
    gr.organic_rank,
    gr.blended_rank,
    coalesce(gr.approved_review_count, 0),
    coalesce(gr.is_sponsored, false),
    gr.sponsorship_label,
    gr.computed_at
  from org_hospital oh
  join public.hospitals h on h.id = oh.hospital_id
  left join current_sponsorship cs
    on cs.org_id = oh.org_id
    and cs.hospital_id = oh.hospital_id
  left join general_rank gr
    on gr.hospital_id = oh.hospital_id;
$$;

alter table public.hospital_sponsorship enable row level security;
alter table public.hospital_ranking_config enable row level security;
alter table public.hospital_ranking_signal_daily enable row level security;
alter table public.hospital_ranking_score enable row level security;

do $$
begin
  create policy hospital_sponsorship_allow_all
    on public.hospital_sponsorship
    for all
    using (true)
    with check (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy hospital_ranking_config_read
    on public.hospital_ranking_config
    for select
    using (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy hospital_ranking_signal_daily_read
    on public.hospital_ranking_signal_daily
    for select
    using (true);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy hospital_ranking_score_read
    on public.hospital_ranking_score
    for select
    using (true);
exception
  when duplicate_object then null;
end $$;

grant select on public.hospital_ranking_config to anon, authenticated, service_role;
grant select on public.hospital_ranking_signal_daily to anon, authenticated, service_role;
grant select on public.hospital_ranking_score to anon, authenticated, service_role;
grant all on public.hospital_sponsorship to anon, authenticated, service_role;
grant select on public.v_hospital_discovery_ranked to anon, authenticated, service_role;
grant execute on function public.refresh_hospital_ranking_signal_daily(date) to anon, authenticated, service_role;
grant execute on function public.refresh_hospital_ranking_scores() to anon, authenticated, service_role;
grant execute on function public.get_org_hospital_visibility_summary(uuid) to anon, authenticated, service_role;

commit;
