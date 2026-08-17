-- ---------------------------------------------------------------------------
-- Jornada de puertas abiertas: avisos a los inscritos y valoración posterior
-- (losresis-panel ADR 0024).
--
-- Hasta ahora la jornada era un formulario dentro del perfil del hospital: se
-- creaba y ahí moría. El hospital no podía decirle nada a quien se había
-- inscrito ("empieza mañana a las 10:00", "cambiamos de sala") ni saber qué
-- les había parecido.
--
-- Esta migración añade las dos consecuencias que le faltaban a la jornada:
--
--   1. AVISO: un mensaje del hospital a TODOS los inscritos. Se guarda en
--      hospital_open_day_notice (histórico consultable: qué se dijo, cuándo y
--      a cuántos) y se reparte insertando una fila por inscrito en
--      notifications, que es lo que dispara el push por el trigger
--      send_push_notifications existente.
--
--   2. VALORACIÓN: una vez pasada la jornada, el hospital pide opinión con un
--      aviso de tipo 'feedback_request' y cada asistente responde una vez
--      (estrellas + comentario) en hospital_open_day_feedback.
--
-- Ambas escrituras pasan por RPCs SECURITY DEFINER: el reparto del aviso y su
-- registro entran juntos o no entra nada, y nadie inserta notificaciones a
-- mano desde el cliente. Avisa el hospital dueño de la jornada —cualquier
-- cuenta activa de su organización—, no el rango: las jornadas son del
-- hospital entero, no de una especialidad.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Tipos de notificación. Deben existir antes de cualquier insert en
--    notifications por el FK notifications.type -> notification_types.code.
-- ---------------------------------------------------------------------------

INSERT INTO public.notification_types (code, description)
VALUES
  ('hospital_open_day_notice',
   'Aviso del hospital sobre la jornada de puertas abiertas en la que te inscribiste'),
  ('hospital_open_day_feedback_request',
   'El hospital te pide que valores la jornada de puertas abiertas')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Tablas.
-- ---------------------------------------------------------------------------

-- El aviso enviado. Se guarda aunque no hubiera inscritos (recipient_count 0):
-- el panel enseña el histórico y "no llegó a nadie" también es información.
CREATE TABLE IF NOT EXISTS public.hospital_open_day_notice (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  open_day_id uuid NOT NULL REFERENCES public.hospital_open_day(id) ON DELETE CASCADE,

  -- 'notice' = mensaje libre antes o durante la jornada.
  -- 'feedback_request' = petición de valoración, ya pasada la jornada.
  kind text NOT NULL DEFAULT 'notice'
    CHECK (kind IN ('notice', 'feedback_request')),

  body text NOT NULL CHECK (btrim(body) <> ''),

  sent_by_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,
  recipient_count integer NOT NULL DEFAULT 0 CHECK (recipient_count >= 0),

  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS hospital_open_day_notice_open_day_idx
  ON public.hospital_open_day_notice (open_day_id, created_at DESC);

-- La valoración del asistente. Una por persona y jornada: volver a enviarla
-- corrige la anterior en vez de acumular opiniones duplicadas.
CREATE TABLE IF NOT EXISTS public.hospital_open_day_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  open_day_id uuid NOT NULL REFERENCES public.hospital_open_day(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT hospital_open_day_feedback_unique UNIQUE (open_day_id, user_id)
);

CREATE INDEX IF NOT EXISTS hospital_open_day_feedback_open_day_idx
  ON public.hospital_open_day_feedback (open_day_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_hospital_open_day_feedback_updated_at
  ON public.hospital_open_day_feedback;
CREATE TRIGGER trg_hospital_open_day_feedback_updated_at
BEFORE UPDATE ON public.hospital_open_day_feedback
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at_timestamp_generic();

-- ---------------------------------------------------------------------------
-- 3. Quién avisa: cuenta activa de la organización dueña del hospital de la
--    jornada. Devuelve el account_id para firmar el aviso, o NULL si no puede.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.hospital_open_day_managing_account(
  p_open_day_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ea.id
  FROM public.hospital_open_day od
  JOIN public.employer_org eo ON eo.hospital_id = od.hospital_id
  JOIN public.employer_account ea ON ea.org_id = eo.id
  WHERE od.id = p_open_day_id
    AND ea.user_id = auth.uid()
    AND coalesce(ea.is_active, false)
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.hospital_open_day_managing_account(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.hospital_open_day_managing_account(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hospital_open_day_managing_account(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Enviar aviso: registro + una notificación por inscrito, transaccional.
--    Devuelve a cuántas personas ha llegado.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.send_hospital_open_day_notice(
  p_open_day_id uuid,
  p_body text,
  p_kind text DEFAULT 'notice'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_open_day public.hospital_open_day%ROWTYPE;
  v_account_id uuid;
  v_hospital_name text;
  v_body text;
  v_kind text;
  v_notice_id uuid;
  v_recipients integer := 0;
  v_type text;
  v_title text;
BEGIN
  SELECT * INTO v_open_day
  FROM public.hospital_open_day
  WHERE id = p_open_day_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada no existe';
  END IF;

  v_account_id := public.hospital_open_day_managing_account(p_open_day_id);
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Solo el hospital que organiza la jornada puede avisar a los inscritos';
  END IF;

  v_body := btrim(coalesce(p_body, ''));
  IF v_body = '' THEN
    RAISE EXCEPTION 'El aviso necesita un mensaje';
  END IF;
  IF char_length(v_body) > 500 THEN
    RAISE EXCEPTION 'El aviso no puede pasar de 500 caracteres';
  END IF;

  v_kind := coalesce(NULLIF(btrim(p_kind), ''), 'notice');
  IF v_kind NOT IN ('notice', 'feedback_request') THEN
    RAISE EXCEPTION 'Tipo de aviso desconocido: %', v_kind;
  END IF;

  -- La valoración solo se pide una vez celebrada la jornada: preguntar antes
  -- por algo que no ha pasado no tiene respuesta posible.
  IF v_kind = 'feedback_request' AND v_open_day.event_date > current_date THEN
    RAISE EXCEPTION 'La valoración solo se puede pedir cuando la jornada ya se ha celebrado';
  END IF;

  SELECT h.name INTO v_hospital_name
  FROM public.hospitals h
  WHERE h.id = v_open_day.hospital_id;

  IF v_kind = 'feedback_request' THEN
    v_type := 'hospital_open_day_feedback_request';
    v_title := '¿Qué te pareció la jornada?';
  ELSE
    v_type := 'hospital_open_day_notice';
    v_title := coalesce(v_hospital_name, 'Jornada de puertas abiertas');
  END IF;

  INSERT INTO public.hospital_open_day_notice (
    open_day_id, kind, body, sent_by_account_id
  ) VALUES (
    p_open_day_id, v_kind, v_body, v_account_id
  )
  RETURNING id INTO v_notice_id;

  INSERT INTO public.notifications (
    user_id, type, title, body, entity_type, entity_id, data
  )
  SELECT
    r.user_id,
    v_type,
    v_title,
    v_body,
    'hospital_open_day',
    p_open_day_id,
    jsonb_build_object(
      'entity_type', 'hospital_open_day',
      'entity_id', p_open_day_id,
      'open_day_id', p_open_day_id,
      'notice_id', v_notice_id,
      'hospital_id', v_open_day.hospital_id,
      'hospital_name', v_hospital_name,
      'event_date', v_open_day.event_date,
      'destination_section',
        CASE WHEN v_kind = 'feedback_request'
          THEN 'valoracionJornada'
          ELSE 'notifications'
        END
    )
  FROM public.hospital_open_day_registration r
  LEFT JOIN public.user_notification_preferences pref
    ON pref.user_id = r.user_id
   AND pref.notification_type = v_type
  WHERE r.open_day_id = p_open_day_id
    AND (
      pref.user_id IS NULL
      OR coalesce(pref.push_enabled, true) = true
      OR coalesce(pref.in_app_enabled, true) = true
    );

  GET DIAGNOSTICS v_recipients = ROW_COUNT;

  UPDATE public.hospital_open_day_notice
  SET recipient_count = v_recipients
  WHERE id = v_notice_id;

  RETURN v_recipients;
END;
$$;

REVOKE ALL ON FUNCTION public.send_hospital_open_day_notice(uuid, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.send_hospital_open_day_notice(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_hospital_open_day_notice(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Valorar la jornada. La escribe el asistente desde la app; solo valora
--    quien se inscribió y solo cuando la jornada ya ha pasado.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.submit_hospital_open_day_feedback(
  p_open_day_id uuid,
  p_rating smallint,
  p_comment text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_open_day public.hospital_open_day%ROWTYPE;
  v_user_id uuid := auth.uid();
  v_feedback_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Hay que identificarse para valorar la jornada';
  END IF;

  SELECT * INTO v_open_day
  FROM public.hospital_open_day
  WHERE id = p_open_day_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada no existe';
  END IF;

  IF v_open_day.event_date > current_date THEN
    RAISE EXCEPTION 'La jornada todavía no se ha celebrado';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.hospital_open_day_registration r
    WHERE r.open_day_id = p_open_day_id
      AND r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'Solo valora la jornada quien se inscribió en ella';
  END IF;

  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'La valoración va de 1 a 5';
  END IF;

  INSERT INTO public.hospital_open_day_feedback (
    open_day_id, user_id, rating, comment
  ) VALUES (
    p_open_day_id, v_user_id, p_rating,
    NULLIF(btrim(coalesce(p_comment, '')), '')
  )
  ON CONFLICT (open_day_id, user_id) DO UPDATE SET
    rating = excluded.rating,
    comment = excluded.comment
  RETURNING id INTO v_feedback_id;

  RETURN v_feedback_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_hospital_open_day_feedback(uuid, smallint, text) FROM public;
GRANT EXECUTE ON FUNCTION public.submit_hospital_open_day_feedback(uuid, smallint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_hospital_open_day_feedback(uuid, smallint, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. RLS. Lectura para el hospital organizador (el panel enseña histórico y
--    valoraciones) y, en las valoraciones, también para su autor (la app le
--    muestra lo que ya respondió). Escritura solo por los RPCs de arriba.
-- ---------------------------------------------------------------------------

ALTER TABLE public.hospital_open_day_notice ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospital_open_day_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hospital_open_day_notice_scope ON public.hospital_open_day_notice;
CREATE POLICY hospital_open_day_notice_scope ON public.hospital_open_day_notice
  FOR SELECT TO authenticated
  USING (
    public.hospital_open_day_managing_account(hospital_open_day_notice.open_day_id) IS NOT NULL
  );

DROP POLICY IF EXISTS hospital_open_day_feedback_scope ON public.hospital_open_day_feedback;
CREATE POLICY hospital_open_day_feedback_scope ON public.hospital_open_day_feedback
  FOR SELECT TO authenticated
  USING (
    hospital_open_day_feedback.user_id = auth.uid()
    OR public.hospital_open_day_managing_account(hospital_open_day_feedback.open_day_id) IS NOT NULL
  );

REVOKE ALL ON TABLE public.hospital_open_day_notice FROM anon;
REVOKE ALL ON TABLE public.hospital_open_day_feedback FROM anon;

GRANT SELECT ON TABLE public.hospital_open_day_notice TO authenticated;
GRANT SELECT ON TABLE public.hospital_open_day_feedback TO authenticated;

GRANT ALL ON TABLE public.hospital_open_day_notice TO service_role;
GRANT ALL ON TABLE public.hospital_open_day_feedback TO service_role;
