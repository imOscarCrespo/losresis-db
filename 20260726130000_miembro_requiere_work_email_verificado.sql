-- ---------------------------------------------------------------------------
-- Endurece la vía por perfil del ADR 0018: ser miembro del servicio exige
-- ademas el email corporativo en regla.
--
-- Un residente en gracia estacional (resident_state =
-- 'pending_corporate_email_seasonal') o bloqueado
-- ('locked_missing_corporate_email') todavia no ha demostrado pertenecer al
-- hospital: no accede al contenido clinico del panel. Regla: work_email
-- presente Y (resident_state = 'active' O NULL — los medicos del panel y los
-- residentes anteriores al flujo estacional no tienen estado).
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
    -- Vía perfil: residente o médico de ese hospital y especialidad con el
    -- email corporativo en regla (ADR 0018).
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND (coalesce(u.is_resident, false) OR coalesce(u.is_doctor, false))
        AND u.hospital_id = p_hospital_id
        AND u.speciality_id = p_speciality_id
        AND nullif(trim(u.work_email), '') IS NOT NULL
        AND (u.resident_state IS NULL OR u.resident_state = 'active')
    );
$$;

REVOKE ALL ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) TO service_role;
