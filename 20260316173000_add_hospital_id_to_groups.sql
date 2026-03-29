ALTER TABLE public.groups
ADD COLUMN IF NOT EXISTS hospital_id uuid;

ALTER TABLE public.groups
DROP CONSTRAINT IF EXISTS groups_hospital_id_fkey;

ALTER TABLE public.groups
ADD CONSTRAINT groups_hospital_id_fkey
FOREIGN KEY (hospital_id) REFERENCES public.hospitals(id) ON DELETE SET NULL;

DROP INDEX IF EXISTS public.groups_user_type_speciality_city_unique_idx;
DROP INDEX IF EXISTS public.groups_user_type_speciality_no_city_unique_idx;
DROP INDEX IF EXISTS public.groups_user_type_city_no_speciality_unique_idx;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_speciality_city_unique_idx
ON public.groups (user_type, speciality_id, city)
WHERE speciality_id IS NOT NULL
  AND hospital_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_speciality_no_city_unique_idx
ON public.groups (user_type, speciality_id)
WHERE speciality_id IS NOT NULL
  AND city IS NULL
  AND hospital_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_city_no_speciality_unique_idx
ON public.groups (user_type, city)
WHERE speciality_id IS NULL
  AND hospital_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_hospital_unique_idx
ON public.groups (user_type, hospital_id)
WHERE hospital_id IS NOT NULL
  AND speciality_id IS NULL;
