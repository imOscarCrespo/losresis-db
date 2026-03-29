ALTER TABLE public.groups
ALTER COLUMN speciality_id DROP NOT NULL;

ALTER TABLE public.groups
ALTER COLUMN city DROP NOT NULL;

ALTER TABLE public.groups
DROP CONSTRAINT IF EXISTS groups_user_type_speciality_id_city_key;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_speciality_city_unique_idx
ON public.groups (user_type, speciality_id, city)
WHERE speciality_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_speciality_no_city_unique_idx
ON public.groups (user_type, speciality_id)
WHERE speciality_id IS NOT NULL
  AND city IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS groups_user_type_city_no_speciality_unique_idx
ON public.groups (user_type, city)
WHERE speciality_id IS NULL;
