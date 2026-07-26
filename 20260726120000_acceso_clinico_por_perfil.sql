-- ---------------------------------------------------------------------------
-- Acceso clínico por perfil, no solo por cuenta (ADR 0018 de losresis-panel).
--
-- Miembro del servicio = quien tiene acceso clínico a un (hospital,
-- especialidad). Hasta ahora solo lo daba el alcance de una cuenta de
-- organización (employer_account_speciality). A partir de ahora también lo da
-- el PERFIL de public.users: un residente o un médico cuyo perfil apunta a ese
-- hospital y especialidad es miembro pleno (lee y escribe), sin necesidad de
-- employer_account.
--
-- Todas las políticas RLS de la vertical clínica (servicio, carpeta, caso,
-- nota, nota_version, recordatorio) y las RPC seguimiento_ensure_servicio /
-- seguimiento_archivar_inactivos delegan en seguimiento_tiene_alcance, así que
-- basta con redefinir esta función.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.seguimiento_tiene_alcance(
  p_hospital_id uuid,
  p_speciality_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    -- Vía cuenta: especialidad en el alcance de una cuenta activa de una
    -- organización de ese hospital (ADR 0014).
    EXISTS (
      SELECT 1
      FROM public.employer_account ea
      JOIN public.employer_account_speciality eas ON eas.account_id = ea.id
      JOIN public.employer_org eo ON eo.id = ea.org_id
      WHERE ea.user_id = auth.uid()
        AND coalesce(ea.is_active, false)
        AND eo.hospital_id = p_hospital_id
        AND eas.speciality_id = p_speciality_id
    )
    -- Vía perfil: residente o médico de ese hospital y especialidad
    -- (ADR 0018). El acceso clínico nace del perfil, no del rol.
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND (coalesce(u.is_resident, false) OR coalesce(u.is_doctor, false))
        AND u.hospital_id = p_hospital_id
        AND u.speciality_id = p_speciality_id
    );
$$;

REVOKE ALL ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) TO service_role;
