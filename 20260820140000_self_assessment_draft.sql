-- ---------------------------------------------------------------------------
-- Guardar borrador de la autoevaluación.
--
-- submit_hospital_self_assessment ya la marca enviada, así que no servía para el
-- "guardar borrador" que la app necesita: el residente responde una autoevaluación
-- anual en varias sentadas, y perder lo escrito por cerrar la app no es una opción.
--
-- Va por RPC y no por UPDATE directo porque la RLS de hospital_self_assessment deja
-- la tabla en solo lectura para el residente: escribir es siempre a través de una
-- función que comprueba que es la suya y que sigue pendiente.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.save_hospital_self_assessment_draft(
  p_id uuid,
  p_answers jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner uuid;
  v_status text;
BEGIN
  SELECT resident_user_id, status
  INTO v_owner, v_status
  FROM public.hospital_self_assessment
  WHERE id = p_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'La autoevaluación % no existe', p_id;
  END IF;

  -- Es SECURITY DEFINER: sin esta comprobación cualquiera podría escribir en la
  -- autoevaluación de otro residente.
  IF auth.uid() IS NOT NULL AND auth.uid() <> v_owner THEN
    RAISE EXCEPTION 'Solo el residente puede escribir en su autoevaluación';
  END IF;

  -- Una ya enviada no se toca. Si el tutor quiere que la corrija, la reabre
  -- (reopen_hospital_self_assessment) y vuelve a estar pendiente.
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'La autoevaluación ya está enviada';
  END IF;

  UPDATE public.hospital_self_assessment
  SET answers = COALESCE(p_answers, '{}'::jsonb)
  WHERE id = p_id;
END;
$$;

GRANT ALL ON FUNCTION public.save_hospital_self_assessment_draft(uuid, jsonb) TO anon;
GRANT ALL ON FUNCTION public.save_hospital_self_assessment_draft(uuid, jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.save_hospital_self_assessment_draft(uuid, jsonb) TO service_role;

-- El envío también comprueba de quién es. Antes solo miraba el estado, y como es
-- SECURITY DEFINER cualquiera con el id podía enviar la autoevaluación de otro.
CREATE OR REPLACE FUNCTION public.submit_hospital_self_assessment(
  p_id uuid,
  p_answers jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner uuid;
BEGIN
  SELECT resident_user_id INTO v_owner
  FROM public.hospital_self_assessment
  WHERE id = p_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'La autoevaluación % no existe', p_id;
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> v_owner THEN
    RAISE EXCEPTION 'Solo el residente puede enviar su autoevaluación';
  END IF;

  UPDATE public.hospital_self_assessment
  SET answers = COALESCE(p_answers, '{}'::jsonb),
      status = 'submitted',
      submitted_at = COALESCE(submitted_at, now())
  WHERE id = p_id
    AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La autoevaluación % ya está enviada o no existe', p_id;
  END IF;
END;
$$;
