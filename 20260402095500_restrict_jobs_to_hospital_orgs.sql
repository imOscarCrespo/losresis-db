begin;

create or replace function public.enforce_job_plan_limits()
returns trigger
language plpgsql
as $$
declare
  v_can_publish boolean;
  v_priority_boost integer;
  v_org_kind text;
begin
  if new.org_id is null then
    raise exception 'No se puede publicar la oferta sin org_id';
  end if;

  select eo.org_kind
  into v_org_kind
  from public.employer_org eo
  where eo.id = new.org_id;

  if coalesce(v_org_kind, '') <> 'hospital' then
    raise exception 'Solo las organizaciones hospitalarias pueden publicar ofertas de trabajo';
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

  select public.get_org_priority_boost(new.org_id)
  into v_priority_boost;

  new.visibility_score = coalesce(v_priority_boost, 0);

  return new;
end;
$$;

grant execute on function public.enforce_job_plan_limits() to anon, authenticated, service_role;

commit;
