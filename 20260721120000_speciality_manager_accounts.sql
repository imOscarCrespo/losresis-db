-- Responsables de especialidad en el panel de organizaciones.
--
-- Un responsable es un employer_account más de la misma organización que el
-- owner, con role = 'speciality_manager', cuyo alcance (qué especialidades
-- gestiona) se guarda en la tabla de enlace employer_account_speciality.
-- Ver ADR 0002 en losresis-panel/docs/adr.

-- 1. Ampliar el rol permitido en employer_account.
ALTER TABLE public.employer_account
  DROP CONSTRAINT IF EXISTS employer_account_role_check;

ALTER TABLE public.employer_account
  ADD CONSTRAINT employer_account_role_check
  CHECK (role = ANY (ARRAY['owner'::text, 'editor'::text, 'speciality_manager'::text]));

-- 2. Tabla de enlace cuenta -> especialidad (alcance del responsable).
CREATE TABLE IF NOT EXISTS public.employer_account_speciality (
  account_id uuid NOT NULL REFERENCES public.employer_account(id) ON DELETE CASCADE,
  speciality_id uuid NOT NULL REFERENCES public.specialities(id) ON DELETE CASCADE,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, speciality_id)
);

CREATE INDEX IF NOT EXISTS employer_account_speciality_account_idx
  ON public.employer_account_speciality (account_id);

CREATE INDEX IF NOT EXISTS employer_account_speciality_speciality_idx
  ON public.employer_account_speciality (speciality_id);

ALTER TABLE public.employer_account_speciality ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_employer_account_speciality ON public.employer_account_speciality;
CREATE POLICY allow_all_employer_account_speciality
  ON public.employer_account_speciality
  USING (true)
  WITH CHECK (true);

GRANT ALL ON TABLE public.employer_account_speciality TO anon;
GRANT ALL ON TABLE public.employer_account_speciality TO authenticated;
GRANT ALL ON TABLE public.employer_account_speciality TO service_role;
