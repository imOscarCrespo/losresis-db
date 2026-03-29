CREATE TABLE IF NOT EXISTS public.dashboard_advertisement (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text,
  description text,
  image_url text,
  placement_scope text NOT NULL DEFAULT 'dashboard',
  role_scope text NOT NULL DEFAULT 'all',
  target_section text,
  position integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT dashboard_advertisement_placement_scope_ck
    CHECK (placement_scope IN ('all', 'dashboard', 'mir_results')),
  CONSTRAINT dashboard_advertisement_role_scope_ck
    CHECK (role_scope IN ('all', 'student', 'resident', 'doctor')),
  CONSTRAINT dashboard_advertisement_dates_ck
    CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at >= starts_at)
);

CREATE INDEX IF NOT EXISTS dashboard_advertisement_active_idx
  ON public.dashboard_advertisement (is_active, placement_scope, role_scope, position);

CREATE OR REPLACE FUNCTION public.update_dashboard_advertisement_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_dashboard_advertisement_updated_at
  ON public.dashboard_advertisement;

CREATE TRIGGER trigger_update_dashboard_advertisement_updated_at
BEFORE UPDATE ON public.dashboard_advertisement
FOR EACH ROW
EXECUTE FUNCTION public.update_dashboard_advertisement_updated_at();

ALTER TABLE public.dashboard_advertisement ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "dashboard_advertisement_select_authenticated"
  ON public.dashboard_advertisement;

CREATE POLICY "dashboard_advertisement_select_authenticated"
ON public.dashboard_advertisement
FOR SELECT
TO authenticated
USING (true);

GRANT SELECT ON TABLE public.dashboard_advertisement TO authenticated;
GRANT ALL ON TABLE public.dashboard_advertisement TO service_role;
GRANT ALL ON FUNCTION public.update_dashboard_advertisement_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_dashboard_advertisement_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_dashboard_advertisement_updated_at() TO service_role;
