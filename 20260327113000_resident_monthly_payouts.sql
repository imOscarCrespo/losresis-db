CREATE TABLE IF NOT EXISTS public.resident_monthly_payouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  period_year integer NOT NULL,
  period_month integer NOT NULL,
  gross_total_eur numeric(10,2) NOT NULL,
  guard_count integer NOT NULL DEFAULT 0,
  strike_count integer NOT NULL DEFAULT 0,
  has_double_pay boolean NOT NULL DEFAULT false,
  has_pending_payment boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT resident_monthly_payouts_user_period_key UNIQUE (user_id, period_year, period_month),
  CONSTRAINT resident_monthly_payouts_period_month_check CHECK (period_month BETWEEN 1 AND 12),
  CONSTRAINT resident_monthly_payouts_gross_total_eur_check CHECK (gross_total_eur >= 0),
  CONSTRAINT resident_monthly_payouts_guard_count_check CHECK (guard_count >= 0),
  CONSTRAINT resident_monthly_payouts_strike_count_check CHECK (strike_count >= 0)
);

CREATE INDEX IF NOT EXISTS resident_monthly_payouts_user_period_idx
ON public.resident_monthly_payouts (user_id, period_year, period_month DESC);

CREATE OR REPLACE FUNCTION public.update_resident_monthly_payouts_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_resident_monthly_payouts_updated_at
ON public.resident_monthly_payouts;

CREATE TRIGGER trigger_update_resident_monthly_payouts_updated_at
BEFORE UPDATE ON public.resident_monthly_payouts
FOR EACH ROW
EXECUTE FUNCTION public.update_resident_monthly_payouts_updated_at();

ALTER TABLE public.resident_monthly_payouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS resident_monthly_payouts_select_own
ON public.resident_monthly_payouts;
CREATE POLICY resident_monthly_payouts_select_own
ON public.resident_monthly_payouts
FOR SELECT
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS resident_monthly_payouts_insert_own
ON public.resident_monthly_payouts;
CREATE POLICY resident_monthly_payouts_insert_own
ON public.resident_monthly_payouts
FOR INSERT
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS resident_monthly_payouts_update_own
ON public.resident_monthly_payouts;
CREATE POLICY resident_monthly_payouts_update_own
ON public.resident_monthly_payouts
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS resident_monthly_payouts_delete_own
ON public.resident_monthly_payouts;
CREATE POLICY resident_monthly_payouts_delete_own
ON public.resident_monthly_payouts
FOR DELETE
USING (auth.uid() = user_id);

GRANT ALL ON TABLE public.resident_monthly_payouts TO authenticated;
GRANT ALL ON TABLE public.resident_monthly_payouts TO service_role;

GRANT ALL ON FUNCTION public.update_resident_monthly_payouts_updated_at()
TO authenticated;
GRANT ALL ON FUNCTION public.update_resident_monthly_payouts_updated_at()
TO service_role;
