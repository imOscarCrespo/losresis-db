CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.users (
    id,
    name,
    surname,
    phone,
    is_doctor,
    is_student,
    hospital_id,
    city,
    work_email,
    speciality_id,
    resident_year,
    is_resident
  )
  VALUES (
    NEW.id,
    '',
    '',
    '',
    false,
    false,
    NULL,
    '',
    '',
    NULL,
    NULL,
    false
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_user();

INSERT INTO public.users (
  id,
  name,
  surname,
  phone,
  is_doctor,
  is_student,
  hospital_id,
  city,
  work_email,
  speciality_id,
  resident_year,
  is_resident
)
SELECT
  au.id,
  '',
  '',
  '',
  false,
  false,
  NULL,
  '',
  '',
  NULL,
  NULL,
  false
FROM auth.users au
LEFT JOIN public.users pu
  ON pu.id = au.id
WHERE pu.id IS NULL;
