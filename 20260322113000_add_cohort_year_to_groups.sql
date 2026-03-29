ALTER TABLE public.groups
ADD COLUMN IF NOT EXISTS cohort_year integer;

ALTER TABLE public.groups
DROP CONSTRAINT IF EXISTS groups_cohort_year_check;

ALTER TABLE public.groups
ADD CONSTRAINT groups_cohort_year_check
CHECK (
  cohort_year IS NULL
  OR (cohort_year >= 2000 AND cohort_year <= 2100)
);

DROP INDEX IF EXISTS public.groups_user_type_speciality_no_city_unique_idx;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_speciality_cohort_unique_idx
ON public.groups (user_type, speciality_id, cohort_year)
WHERE speciality_id IS NOT NULL
  AND city IS NULL
  AND hospital_id IS NULL
  AND cohort_year IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_speciality_no_city_unique_idx
ON public.groups (user_type, speciality_id)
WHERE speciality_id IS NOT NULL
  AND city IS NULL
  AND hospital_id IS NULL
  AND cohort_year IS NULL;
