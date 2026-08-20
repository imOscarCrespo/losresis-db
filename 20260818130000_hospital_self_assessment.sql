-- Autoevaluación anual: el tutor la solicita, el residente la responde.
--
-- Sale de la plantilla del Libro del Residente (documento "Modificaciones parte
-- II", puntos 6 y 7) y pasa a ser un módulo propio de Docencia.
--
-- Decisiones de modelado:
--
--   * Es una SOLICITUD con fecha límite, no un formulario suelto. El tutor pide,
--     el residente responde y el tutor lee: tres momentos sobre la misma fila.
--
--   * Las respuestas van en un jsonb y no en columnas fijas. Las preguntas de la
--     autoevaluación son las de la plantilla de Reflexión anual, que el tutor
--     puede cambiar: columnas fijas obligarían a migrar cada vez que edite una
--     pregunta.
--
--   * "En curso" no se guarda: es una solicitud abierta cuyo residente ya ha
--     empezado a escribir. Lo que se persiste es pending, submitted y closed.

INSERT INTO public.notification_types (code, description)
VALUES
  ('self_assessment_requested', 'Tu tutor te pide la autoevaluación anual'),
  ('self_assessment_reminder', 'Recordatorio: autoevaluación anual pendiente')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.hospital_self_assessment (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  hospital_id uuid NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
  resident_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  tutor_account_id uuid,
  tutor_name text,
  speciality_id uuid REFERENCES public.specialities(id) ON DELETE SET NULL,
  residency_year smallint,
  /** El periodo que se autoevalúa, tal como lo escribe el tutor. */
  period_label text NOT NULL,
  due_date date,
  status text NOT NULL DEFAULT 'pending',
  /** Las preguntas tal como estaban al solicitarla, para que el histórico no cambie. */
  questions jsonb NOT NULL DEFAULT '[]'::jsonb,
  /** Las respuestas del residente, indexadas por pregunta. */
  answers jsonb NOT NULL DEFAULT '{}'::jsonb,
  submitted_at timestamp with time zone,
  /** Comentario privado del tutor: el residente no lo ve. */
  tutor_comment text,
  closed_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT hospital_self_assessment_status_check
    CHECK (status IN ('pending', 'submitted', 'closed')),
  CONSTRAINT hospital_self_assessment_year_check
    CHECK (residency_year IS NULL OR residency_year BETWEEN 1 AND 8),
  CONSTRAINT hospital_self_assessment_submitted_needs_date
    CHECK (status = 'pending' OR submitted_at IS NOT NULL)
);

-- Una sola solicitud por residente y periodo: pedirla dos veces es un error.
CREATE UNIQUE INDEX IF NOT EXISTS hospital_self_assessment_unique_idx
  ON public.hospital_self_assessment (resident_user_id, period_label);

CREATE INDEX IF NOT EXISTS hospital_self_assessment_hospital_idx
  ON public.hospital_self_assessment (hospital_id, due_date);

CREATE INDEX IF NOT EXISTS hospital_self_assessment_open_idx
  ON public.hospital_self_assessment (hospital_id, due_date)
  WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.update_hospital_self_assessment_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_hospital_self_assessment_updated_at
  ON public.hospital_self_assessment;

CREATE TRIGGER trigger_update_hospital_self_assessment_updated_at
BEFORE UPDATE ON public.hospital_self_assessment
FOR EACH ROW
EXECUTE FUNCTION public.update_hospital_self_assessment_updated_at();

ALTER TABLE public.hospital_self_assessment ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_hospital_self_assessment
  ON public.hospital_self_assessment;
CREATE POLICY allow_all_hospital_self_assessment
  ON public.hospital_self_assessment USING (true) WITH CHECK (true);

GRANT ALL ON TABLE public.hospital_self_assessment TO anon;
GRANT ALL ON TABLE public.hospital_self_assessment TO authenticated;
GRANT ALL ON TABLE public.hospital_self_assessment TO service_role;

GRANT ALL ON FUNCTION public.update_hospital_self_assessment_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_hospital_self_assessment_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_hospital_self_assessment_updated_at() TO service_role;

-- ---------------------------------------------------------------------------
-- Solicitar: crea la solicitud con las preguntas del momento y avisa.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_hospital_self_assessment(
  p_hospital_id uuid,
  p_resident_user_id uuid,
  p_period_label text,
  p_due_date date DEFAULT NULL,
  p_questions jsonb DEFAULT '[]'::jsonb,
  p_tutor_account_id uuid DEFAULT NULL,
  p_tutor_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_resident record;
  v_id uuid;
BEGIN
  SELECT speciality_id, resident_year INTO v_resident
  FROM public.users WHERE id = p_resident_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El residente % no existe', p_resident_user_id;
  END IF;

  INSERT INTO public.hospital_self_assessment (
    hospital_id, resident_user_id, tutor_account_id, tutor_name,
    speciality_id, residency_year, period_label, due_date, questions
  )
  VALUES (
    p_hospital_id, p_resident_user_id, p_tutor_account_id, p_tutor_name,
    v_resident.speciality_id, v_resident.resident_year::smallint,
    p_period_label, p_due_date, COALESCE(p_questions, '[]'::jsonb)
  )
  RETURNING id INTO v_id;

  INSERT INTO public.notifications (
    user_id, type, title, body, entity_type, entity_id, data
  )
  VALUES (
    p_resident_user_id, 'self_assessment_requested',
    'Autoevaluación anual ' || p_period_label,
    CASE
      WHEN p_due_date IS NULL THEN
        'Tu tutor te pide que completes tu autoevaluación anual.'
      ELSE
        'Tu tutor te pide que completes tu autoevaluación anual antes del ' ||
        to_char(p_due_date, 'DD/MM/YYYY') || '.'
    END,
    'hospital_self_assessment', v_id,
    jsonb_build_object('self_assessment_id', v_id)
  );

  RETURN v_id;
END;
$$;

GRANT ALL ON FUNCTION public.request_hospital_self_assessment(
  uuid, uuid, text, date, jsonb, uuid, text
) TO anon;
GRANT ALL ON FUNCTION public.request_hospital_self_assessment(
  uuid, uuid, text, date, jsonb, uuid, text
) TO authenticated;
GRANT ALL ON FUNCTION public.request_hospital_self_assessment(
  uuid, uuid, text, date, jsonb, uuid, text
) TO service_role;

-- ---------------------------------------------------------------------------
-- Recordar: vuelve a avisar al residente de una solicitud abierta.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.remind_hospital_self_assessment(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT * INTO v_row FROM public.hospital_self_assessment WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud % no existe', p_id;
  END IF;

  IF v_row.status <> 'pending' THEN
    RETURN;
  END IF;

  INSERT INTO public.notifications (
    user_id, type, title, body, entity_type, entity_id, data
  )
  VALUES (
    v_row.resident_user_id, 'self_assessment_reminder',
    'Autoevaluación pendiente',
    'Tu autoevaluación de ' || v_row.period_label || ' sigue pendiente.',
    'hospital_self_assessment', p_id,
    jsonb_build_object('self_assessment_id', p_id)
  );
END;
$$;

GRANT ALL ON FUNCTION public.remind_hospital_self_assessment(uuid) TO anon;
GRANT ALL ON FUNCTION public.remind_hospital_self_assessment(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.remind_hospital_self_assessment(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Enviar (lo llama la app del residente): bloquea la respuesta.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.submit_hospital_self_assessment(
  p_id uuid,
  p_answers jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
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

GRANT ALL ON FUNCTION public.submit_hospital_self_assessment(uuid, jsonb) TO anon;
GRANT ALL ON FUNCTION public.submit_hospital_self_assessment(uuid, jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.submit_hospital_self_assessment(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- Reabrir: el tutor devuelve la autoevaluación al residente.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reopen_hospital_self_assessment(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.hospital_self_assessment
  SET status = 'pending',
      submitted_at = NULL,
      closed_at = NULL
  WHERE id = p_id;
END;
$$;

GRANT ALL ON FUNCTION public.reopen_hospital_self_assessment(uuid) TO anon;
GRANT ALL ON FUNCTION public.reopen_hospital_self_assessment(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.reopen_hospital_self_assessment(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Lo que esta migración NO hace, a propósito.
--
--   a) No borra el apartado de Reflexión anual de las plantillas que ya lo
--      tengan. Las preguntas siguen ahí y son la fuente de las que se copian a
--      cada solicitud; retirar el apartado del catálogo es cosa del panel.
--
--   b) No programa recordatorios automáticos por fecha límite: hay una función
--      para recordar a mano desde la pantalla. El barrido automático necesita
--      cron, igual que en Comunicados y Tutorías.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Barrido de autoevaluaciones que vencen (añadido después).
--
-- Avisa dos veces y solo dos: una semana antes y el mismo día. La deduplicación
-- es por "ya se avisó hoy", así que el cron puede correr varias veces al día sin
-- llenarle las notificaciones al residente.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.send_due_self_assessment_reminders()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row record;
  v_sent integer := 0;
BEGIN
  FOR v_row IN
    SELECT s.id, s.resident_user_id, s.period_label, s.due_date
    FROM public.hospital_self_assessment s
    WHERE s.status = 'pending'
      AND s.due_date IS NOT NULL
      AND s.due_date IN (CURRENT_DATE + 7, CURRENT_DATE)
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.type = 'self_assessment_reminder'
          AND n.entity_id = s.id
          AND n.created_at::date = CURRENT_DATE
      )
  LOOP
    INSERT INTO public.notifications (
      user_id, type, title, body, entity_type, entity_id, data
    )
    VALUES (
      v_row.resident_user_id,
      'self_assessment_reminder',
      CASE
        WHEN v_row.due_date = CURRENT_DATE THEN 'Tu autoevaluación vence hoy'
        ELSE 'Tu autoevaluación vence en una semana'
      END,
      'La autoevaluación de ' || v_row.period_label ||
        ' sigue pendiente. Fecha límite: ' ||
        to_char(v_row.due_date, 'DD/MM/YYYY') || '.',
      'hospital_self_assessment',
      v_row.id,
      jsonb_build_object('self_assessment_id', v_row.id)
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$$;

GRANT ALL ON FUNCTION public.send_due_self_assessment_reminders() TO anon;
GRANT ALL ON FUNCTION public.send_due_self_assessment_reminders() TO authenticated;
GRANT ALL ON FUNCTION public.send_due_self_assessment_reminders() TO service_role;

-- Los tres cron quedan registrados en el proyecto (pg_cron), no aquí:
--   hospital-announcements-due-5min           */5 * * * *
--   hospital-tutoring-reminders-daily         30 8 * * *
--   hospital-self-assessment-reminders-daily  35 8 * * *
