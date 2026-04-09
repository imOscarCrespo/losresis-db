-- Fallback to the free plan for newly created orgs that do not yet have a persisted subscription row.

begin;

create or replace function public.get_org_current_subscription(p_org_id uuid)
returns table (
  subscription_id uuid,
  org_id uuid,
  plan_id uuid,
  plan_code text,
  plan_name text,
  subscription_status text,
  starts_at timestamptz,
  ends_at timestamptz,
  trial_ends_at timestamptz,
  cancel_at_period_end boolean
)
language sql
stable
as $$
  with ranked_subscriptions as (
    select
      os.id as subscription_id,
      os.org_id,
      os.plan_id,
      bp.code as plan_code,
      bp.name as plan_name,
      os.status as subscription_status,
      os.starts_at,
      os.ends_at,
      os.trial_ends_at,
      os.cancel_at_period_end,
      row_number() over (
        partition by os.org_id
        order by
          case
            when os.status in ('active', 'trialing', 'past_due') then 0
            when os.status in ('canceled', 'expired') then 1
            else 2
          end,
          coalesce(os.starts_at, os.created_at) desc,
          os.created_at desc
      ) as rn
    from public.org_subscription os
    join public.billing_plan bp on bp.id = os.plan_id
    where os.org_id = p_org_id
  ),
  current_subscription as (
    select
      rs.subscription_id,
      rs.org_id,
      rs.plan_id,
      rs.plan_code,
      rs.plan_name,
      rs.subscription_status,
      rs.starts_at,
      rs.ends_at,
      rs.trial_ends_at,
      rs.cancel_at_period_end
    from ranked_subscriptions rs
    where rs.rn = 1
  )
  select
    cs.subscription_id,
    cs.org_id,
    cs.plan_id,
    cs.plan_code,
    cs.plan_name,
    cs.subscription_status,
    cs.starts_at,
    cs.ends_at,
    cs.trial_ends_at,
    cs.cancel_at_period_end
  from current_subscription cs

  union all

  select
    null::uuid as subscription_id,
    p_org_id as org_id,
    bp.id as plan_id,
    bp.code as plan_code,
    bp.name as plan_name,
    'active'::text as subscription_status,
    null::timestamptz as starts_at,
    null::timestamptz as ends_at,
    null::timestamptz as trial_ends_at,
    false as cancel_at_period_end
  from public.billing_plan bp
  where bp.code = 'free'
    and bp.is_active = true
    and not exists (
      select 1
      from current_subscription
    );
$$;

grant execute on function public.get_org_current_subscription(uuid) to anon, authenticated, service_role;

commit;
