-- Fix current org subscription selection to prefer live paid subscriptions over old fallback rows.

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
  )
  select
    subscription_id,
    org_id,
    plan_id,
    plan_code,
    plan_name,
    subscription_status,
    starts_at,
    ends_at,
    trial_ends_at,
    cancel_at_period_end
  from ranked_subscriptions
  where rn = 1;
$$;

grant execute on function public.get_org_current_subscription(uuid) to anon, authenticated, service_role;

commit;
