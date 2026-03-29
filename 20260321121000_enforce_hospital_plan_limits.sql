-- Enforce publication limits for hospital plans
-- Requires previous migration with:
-- - public.get_org_plan_features(uuid)
-- - public.can_org_publish_job(uuid)
-- - public.can_org_publish_course(uuid)
-- - public.get_org_priority_boost(uuid)
-- - public.org_subscription / billing_plan / billing_plan_feature
-- - public.courses.org_id and public.courses.status
-- - public.job.org_id and public.job.status

begin;

create or replace function public.enforce_job_plan_limits()
returns trigger
language plpgsql
as $$
declare
  v_can_publish boolean;
  v_priority_boost integer;
begin
  if new.org_id is null then
    raise exception 'No se puede publicar la oferta sin org_id';
  end if;

  if new.status = 'published' and coalesce(old.status, 'draft') <> 'published' then
    select public.can_org_publish_job(new.org_id)
    into v_can_publish;

    if not coalesce(v_can_publish, false) then
      raise exception 'Tu plan actual no permite publicar mas ofertas activas';
    end if;

    if new.published_at is null then
      new.published_at = now();
    end if;
  end if;

  if new.status <> 'published' and coalesce(old.status, 'draft') = 'published' then
    null;
  end if;

  select public.get_org_priority_boost(new.org_id)
  into v_priority_boost;

  new.visibility_score = coalesce(v_priority_boost, 0);

  return new;
end;
$$;

drop trigger if exists trg_enforce_job_plan_limits on public.job;
create trigger trg_enforce_job_plan_limits
before insert or update on public.job
for each row
execute function public.enforce_job_plan_limits();

create or replace function public.enforce_course_plan_limits()
returns trigger
language plpgsql
as $$
declare
  v_can_publish boolean;
  v_priority_boost integer;
begin
  if new.org_id is null then
    raise exception 'No se puede publicar el curso sin org_id';
  end if;

  if new.status = 'published' and coalesce(old.status, 'draft') <> 'published' then
    select public.can_org_publish_course(new.org_id)
    into v_can_publish;

    if not coalesce(v_can_publish, false) then
      raise exception 'Tu plan actual no permite publicar mas cursos activos';
    end if;

    if new.published_at is null then
      new.published_at = now();
    end if;
  end if;

  if new.status <> 'published' and coalesce(old.status, 'draft') = 'published' then
    null;
  end if;

  select public.get_org_priority_boost(new.org_id)
  into v_priority_boost;

  new.visibility_score = coalesce(v_priority_boost, 0);

  return new;
end;
$$;

drop trigger if exists trg_enforce_course_plan_limits on public.courses;
create trigger trg_enforce_course_plan_limits
before insert or update on public.courses
for each row
execute function public.enforce_course_plan_limits();

create or replace function public.refresh_org_content_visibility_scores(p_org_id uuid)
returns void
language plpgsql
as $$
declare
  v_priority_boost integer;
begin
  v_priority_boost := public.get_org_priority_boost(p_org_id);

  update public.job
  set visibility_score = coalesce(v_priority_boost, 0)
  where org_id = p_org_id;

  update public.courses
  set visibility_score = coalesce(v_priority_boost, 0)
  where org_id = p_org_id;
end;
$$;

create or replace function public.handle_subscription_visibility_refresh()
returns trigger
language plpgsql
as $$
begin
  perform public.refresh_org_content_visibility_scores(new.org_id);
  return new;
end;
$$;

drop trigger if exists trg_subscription_visibility_refresh on public.org_subscription;
create trigger trg_subscription_visibility_refresh
after insert or update of plan_id, status, ends_at, trial_ends_at on public.org_subscription
for each row
execute function public.handle_subscription_visibility_refresh();

update public.job
set
  published_at = coalesce(published_at, now()),
  visibility_score = public.get_org_priority_boost(org_id)
where status = 'published'
  and org_id is not null;

update public.courses
set
  published_at = coalesce(published_at, now()),
  visibility_score = public.get_org_priority_boost(org_id)
where status = 'published'
  and org_id is not null;

grant execute on function public.enforce_job_plan_limits() to anon, authenticated, service_role;
grant execute on function public.enforce_course_plan_limits() to anon, authenticated, service_role;
grant execute on function public.refresh_org_content_visibility_scores(uuid) to anon, authenticated, service_role;
grant execute on function public.handle_subscription_visibility_refresh() to anon, authenticated, service_role;

commit;
