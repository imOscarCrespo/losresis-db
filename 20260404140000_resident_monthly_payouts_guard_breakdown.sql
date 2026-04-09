ALTER TABLE public.resident_monthly_payouts
ADD COLUMN IF NOT EXISTS weekday_guard_count integer NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS friday_guard_count integer NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS saturday_guard_count integer NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS sunday_guard_count integer NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS holiday_guard_count integer NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS pending_payment_description text;

UPDATE public.resident_monthly_payouts
SET
  weekday_guard_count = guard_count,
  friday_guard_count = 0,
  saturday_guard_count = 0,
  sunday_guard_count = 0,
  holiday_guard_count = 0
WHERE
  weekday_guard_count = 0
  AND friday_guard_count = 0
  AND saturday_guard_count = 0
  AND sunday_guard_count = 0
  AND holiday_guard_count = 0
  AND guard_count > 0;

ALTER TABLE public.resident_monthly_payouts
DROP CONSTRAINT IF EXISTS resident_monthly_payouts_weekday_guard_count_check,
DROP CONSTRAINT IF EXISTS resident_monthly_payouts_friday_guard_count_check,
DROP CONSTRAINT IF EXISTS resident_monthly_payouts_saturday_guard_count_check,
DROP CONSTRAINT IF EXISTS resident_monthly_payouts_sunday_guard_count_check,
DROP CONSTRAINT IF EXISTS resident_monthly_payouts_holiday_guard_count_check;

ALTER TABLE public.resident_monthly_payouts
ADD CONSTRAINT resident_monthly_payouts_weekday_guard_count_check CHECK (weekday_guard_count >= 0),
ADD CONSTRAINT resident_monthly_payouts_friday_guard_count_check CHECK (friday_guard_count >= 0),
ADD CONSTRAINT resident_monthly_payouts_saturday_guard_count_check CHECK (saturday_guard_count >= 0),
ADD CONSTRAINT resident_monthly_payouts_sunday_guard_count_check CHECK (sunday_guard_count >= 0),
ADD CONSTRAINT resident_monthly_payouts_holiday_guard_count_check CHECK (holiday_guard_count >= 0);
