-- Tutorías como módulo propio de Docencia.
--
-- Sale de la plantilla del Libro del Residente (documento "Modificaciones parte
-- II", puntos 6 y 7) y pasa a ser el sitio donde se planifican, se realizan, se
-- documentan y se consultan las tutorías de toda la residencia.
--
-- Decisiones de modelado:
--
--   * Un único registro compartido entre tutor y residente. No hay dos filas ni
--     copias: la tutoría es la misma entidad para los dos, y `shared_at` marca
--     desde cuándo el residente puede leer el contenido.
--
--   * El estado "pendiente de completar" NO se guarda: es "programada cuya fecha
--     ya pasó". Guardarlo obligaría a un job que moviese filas cada noche, y un
--     estado derivado no puede desincronizarse. Los estados persistidos son
--     scheduled, finished y cancelled.
--
--   * La proyección en la Agenda del residente es una fila de agenda_events
--     enlazada por agenda_event_id, igual que hace el Evento del servicio
--     (ADR 0021): la agenda de la app ya lee esa tabla y no hay que tocarla.

-- ---------------------------------------------------------------------------
-- 1. La tutoría cabe en la Agenda.
-- ---------------------------------------------------------------------------

ALTER TABLE public.agenda_events
DROP CONSTRAINT IF EXISTS agenda_events_event_type_check;

ALTER TABLE public.agenda_events
ADD CONSTRAINT agenda_events_event_type_check
CHECK (
  event_type = ANY (
    ARRAY[
      'shift'::text,
      'course'::text,
      'research'::text,
      'study'::text,
      'conference'::text,
      'day_off'::text,
      'reminder'::text,
      'service'::text,
      'tutoring'::text
    ]
  )
);

-- ---------------------------------------------------------------------------
-- 2. Tipos de notificación. Antes de cualquier insert en notifications, por el
--    FK notifications.type -> notification_types.code.
-- ---------------------------------------------------------------------------

INSERT INTO public.notification_types (code, description)
VALUES
  ('tutoring_scheduled', 'Tutoría programada con tu tutor'),
  ('tutoring_reminder', 'Recordatorio de tutoría próxima'),
  ('tutoring_shared', 'Tu tutor ha compartido el contenido de una tutoría')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. La tutoría.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.hospital_tutoring (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  hospital_id uuid NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
  resident_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  -- Quién la lleva. Sin FK a users: el tutor es una cuenta de organización.
  tutor_account_id uuid,
  tutor_name text,
  -- Se copian del residente al crear para poder filtrar y ordenar sin joins, y
  -- para que el histórico conserve el año en que ocurrió la tutoría.
  speciality_id uuid REFERENCES public.specialities(id) ON DELETE SET NULL,
  residency_year smallint,
  tutoring_type text NOT NULL DEFAULT 'seguimiento',
  scheduled_at timestamp with time zone NOT NULL,
  place text,
  status text NOT NULL DEFAULT 'scheduled',
  -- Contenido de la reunión. Se rellena cuando se realiza.
  topics text,
  competencies_reviewed text,
  goals_achieved text,
  improvements text,
  next_goals text,
  notes text,
  /** Desde cuándo el residente ve el contenido. NULL = solo lo ve el tutor. */
  shared_at timestamp with time zone,
  finished_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  /** La copia en la Agenda del residente. */
  agenda_event_id uuid REFERENCES public.agenda_events(id) ON DELETE SET NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT hospital_tutoring_status_check
    CHECK (status IN ('scheduled', 'finished', 'cancelled')),
  CONSTRAINT hospital_tutoring_type_check
    CHECK (tutoring_type IN ('inicial', 'seguimiento', 'anual', 'extraordinaria')),
  CONSTRAINT hospital_tutoring_year_check
    CHECK (residency_year IS NULL OR residency_year BETWEEN 1 AND 8),
  CONSTRAINT hospital_tutoring_finished_needs_date
    CHECK (status <> 'finished' OR finished_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS hospital_tutoring_hospital_idx
  ON public.hospital_tutoring (hospital_id, scheduled_at DESC);

CREATE INDEX IF NOT EXISTS hospital_tutoring_resident_idx
  ON public.hospital_tutoring (resident_user_id, scheduled_at DESC);

CREATE INDEX IF NOT EXISTS hospital_tutoring_speciality_idx
  ON public.hospital_tutoring (hospital_id, speciality_id);

-- Las próximas y las vencidas sin cerrar, que es lo que abre la pantalla.
CREATE INDEX IF NOT EXISTS hospital_tutoring_open_idx
  ON public.hospital_tutoring (hospital_id, scheduled_at)
  WHERE status = 'scheduled';

CREATE OR REPLACE FUNCTION public.update_hospital_tutoring_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_hospital_tutoring_updated_at
  ON public.hospital_tutoring;

CREATE TRIGGER trigger_update_hospital_tutoring_updated_at
BEFORE UPDATE ON public.hospital_tutoring
FOR EACH ROW
EXECUTE FUNCTION public.update_hospital_tutoring_updated_at();

ALTER TABLE public.hospital_tutoring ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_hospital_tutoring ON public.hospital_tutoring;
CREATE POLICY allow_all_hospital_tutoring
  ON public.hospital_tutoring
  USING (true)
  WITH CHECK (true);

GRANT ALL ON TABLE public.hospital_tutoring TO anon;
GRANT ALL ON TABLE public.hospital_tutoring TO authenticated;
GRANT ALL ON TABLE public.hospital_tutoring TO service_role;

GRANT ALL ON FUNCTION public.update_hospital_tutoring_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_hospital_tutoring_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_hospital_tutoring_updated_at() TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Documentos adjuntos de la tutoría.
--
-- Tabla propia y no un array en la fila: un adjunto tiene nombre, tamaño y quién
-- lo subió, y se borra uno sin reescribir la tutoría.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.hospital_tutoring_attachment (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  tutoring_id uuid NOT NULL
    REFERENCES public.hospital_tutoring(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  file_name text NOT NULL,
  uploaded_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS hospital_tutoring_attachment_tutoring_idx
  ON public.hospital_tutoring_attachment (tutoring_id);

ALTER TABLE public.hospital_tutoring_attachment ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_hospital_tutoring_attachment
  ON public.hospital_tutoring_attachment;
CREATE POLICY allow_all_hospital_tutoring_attachment
  ON public.hospital_tutoring_attachment
  USING (true)
  WITH CHECK (true);

GRANT ALL ON TABLE public.hospital_tutoring_attachment TO anon;
GRANT ALL ON TABLE public.hospital_tutoring_attachment TO authenticated;
GRANT ALL ON TABLE public.hospital_tutoring_attachment TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Programar: crea la tutoría, la proyecta en la Agenda del residente y le
--    avisa.
--
-- Todo en una función para que no puedan quedar a medias: una tutoría sin evento
-- de agenda sería una reunión que el residente no ve venir.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.schedule_hospital_tutoring(
  p_hospital_id uuid,
  p_resident_user_id uuid,
  p_scheduled_at timestamp with time zone,
  p_tutoring_type text DEFAULT 'seguimiento',
  p_place text DEFAULT NULL,
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
  v_tutoring_id uuid;
  v_event_id uuid;
  v_titulo text;
BEGIN
  SELECT id, speciality_id, resident_year
  INTO v_resident
  FROM public.users
  WHERE id = p_resident_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El residente % no existe', p_resident_user_id;
  END IF;

  INSERT INTO public.hospital_tutoring (
    hospital_id, resident_user_id, tutor_account_id, tutor_name,
    speciality_id, residency_year, tutoring_type, scheduled_at, place
  )
  VALUES (
    p_hospital_id, p_resident_user_id, p_tutor_account_id, p_tutor_name,
    v_resident.speciality_id, v_resident.resident_year::smallint,
    COALESCE(p_tutoring_type, 'seguimiento'), p_scheduled_at, p_place
  )
  RETURNING id INTO v_tutoring_id;

  v_titulo := CASE COALESCE(p_tutoring_type, 'seguimiento')
    WHEN 'inicial' THEN 'Tutoría inicial'
    WHEN 'anual' THEN 'Tutoría anual'
    WHEN 'extraordinaria' THEN 'Tutoría extraordinaria'
    ELSE 'Tutoría de seguimiento'
  END;

  INSERT INTO public.agenda_events (
    user_id, event_type, title, event_date, start_time, all_day, notes, metadata
  )
  VALUES (
    p_resident_user_id,
    'tutoring',
    v_titulo,
    p_scheduled_at::date,
    p_scheduled_at::time,
    false,
    p_place,
    jsonb_build_object('tutoring_id', v_tutoring_id)
  )
  RETURNING id INTO v_event_id;

  UPDATE public.hospital_tutoring
  SET agenda_event_id = v_event_id
  WHERE id = v_tutoring_id;

  INSERT INTO public.notifications (
    user_id, type, title, body, entity_type, entity_id, data
  )
  VALUES (
    p_resident_user_id,
    'tutoring_scheduled',
    v_titulo,
    'Tu tutor ha programado una tutoría para el ' ||
      to_char(p_scheduled_at, 'DD/MM/YYYY') || ' a las ' ||
      to_char(p_scheduled_at, 'HH24:MI') || '.',
    'hospital_tutoring',
    v_tutoring_id,
    jsonb_build_object('tutoring_id', v_tutoring_id)
  );

  RETURN v_tutoring_id;
END;
$$;

GRANT ALL ON FUNCTION public.schedule_hospital_tutoring(
  uuid, uuid, timestamp with time zone, text, text, uuid, text
) TO anon;
GRANT ALL ON FUNCTION public.schedule_hospital_tutoring(
  uuid, uuid, timestamp with time zone, text, text, uuid, text
) TO authenticated;
GRANT ALL ON FUNCTION public.schedule_hospital_tutoring(
  uuid, uuid, timestamp with time zone, text, text, uuid, text
) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Cambiar la fecha arrastra el evento de agenda.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reschedule_hospital_tutoring(
  p_tutoring_id uuid,
  p_scheduled_at timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tutoring record;
BEGIN
  SELECT * INTO v_tutoring
  FROM public.hospital_tutoring
  WHERE id = p_tutoring_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La tutoría % no existe', p_tutoring_id;
  END IF;

  UPDATE public.hospital_tutoring
  SET scheduled_at = p_scheduled_at
  WHERE id = p_tutoring_id;

  IF v_tutoring.agenda_event_id IS NOT NULL THEN
    UPDATE public.agenda_events
    SET event_date = p_scheduled_at::date,
        start_time = p_scheduled_at::time
    WHERE id = v_tutoring.agenda_event_id;
  END IF;
END;
$$;

GRANT ALL ON FUNCTION public.reschedule_hospital_tutoring(uuid, timestamp with time zone) TO anon;
GRANT ALL ON FUNCTION public.reschedule_hospital_tutoring(uuid, timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.reschedule_hospital_tutoring(uuid, timestamp with time zone) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Finalizar y compartir.
--
-- Finalizar bloquea el registro como histórico; se puede reabrir. Compartir es
-- lo que hace visible el contenido al residente, y avisa una sola vez.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.finish_hospital_tutoring(
  p_tutoring_id uuid,
  p_share_with_resident boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tutoring record;
  v_ya_compartida boolean;
BEGIN
  SELECT * INTO v_tutoring
  FROM public.hospital_tutoring
  WHERE id = p_tutoring_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La tutoría % no existe', p_tutoring_id;
  END IF;

  v_ya_compartida := v_tutoring.shared_at IS NOT NULL;

  UPDATE public.hospital_tutoring
  SET status = 'finished',
      finished_at = COALESCE(finished_at, now()),
      shared_at = CASE
        WHEN p_share_with_resident THEN COALESCE(shared_at, now())
        ELSE NULL
      END
  WHERE id = p_tutoring_id;

  IF p_share_with_resident AND NOT v_ya_compartida THEN
    INSERT INTO public.notifications (
      user_id, type, title, body, entity_type, entity_id, data
    )
    VALUES (
      v_tutoring.resident_user_id,
      'tutoring_shared',
      'Tutoría disponible',
      'Tu tutor ha completado la tutoría del ' ||
        to_char(v_tutoring.scheduled_at, 'DD/MM/YYYY') ||
        '. Ya puedes consultarla en tu Libro del Residente.',
      'hospital_tutoring',
      p_tutoring_id,
      jsonb_build_object('tutoring_id', p_tutoring_id)
    );
  END IF;
END;
$$;

GRANT ALL ON FUNCTION public.finish_hospital_tutoring(uuid, boolean) TO anon;
GRANT ALL ON FUNCTION public.finish_hospital_tutoring(uuid, boolean) TO authenticated;
GRANT ALL ON FUNCTION public.finish_hospital_tutoring(uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Cancelar: retira también la reunión de la agenda del residente.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancel_hospital_tutoring(p_tutoring_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id uuid;
BEGIN
  SELECT agenda_event_id INTO v_event_id
  FROM public.hospital_tutoring
  WHERE id = p_tutoring_id;

  UPDATE public.hospital_tutoring
  SET status = 'cancelled',
      cancelled_at = now()
  WHERE id = p_tutoring_id;

  IF v_event_id IS NOT NULL THEN
    DELETE FROM public.agenda_events WHERE id = v_event_id;
  END IF;
END;
$$;

GRANT ALL ON FUNCTION public.cancel_hospital_tutoring(uuid) TO anon;
GRANT ALL ON FUNCTION public.cancel_hospital_tutoring(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.cancel_hospital_tutoring(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Recordatorios: avisa al residente y al tutor unos días antes.
--
-- Idempotente por notificación: no repite el aviso de la misma tutoría.
-- Pensada para un cron diario.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.send_hospital_tutoring_reminders(
  p_days_before integer DEFAULT 2
)
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
    SELECT t.id, t.resident_user_id, t.scheduled_at
    FROM public.hospital_tutoring t
    WHERE t.status = 'scheduled'
      AND t.scheduled_at::date = (CURRENT_DATE + p_days_before)
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.type = 'tutoring_reminder'
          AND n.entity_id = t.id
      )
  LOOP
    INSERT INTO public.notifications (
      user_id, type, title, body, entity_type, entity_id, data
    )
    VALUES (
      v_row.resident_user_id,
      'tutoring_reminder',
      'Tutoría en ' || p_days_before || ' días',
      'Tienes una tutoría el ' || to_char(v_row.scheduled_at, 'DD/MM/YYYY') ||
        ' a las ' || to_char(v_row.scheduled_at, 'HH24:MI') || '.',
      'hospital_tutoring',
      v_row.id,
      jsonb_build_object('tutoring_id', v_row.id)
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$$;

GRANT ALL ON FUNCTION public.send_hospital_tutoring_reminders(integer) TO anon;
GRANT ALL ON FUNCTION public.send_hospital_tutoring_reminders(integer) TO authenticated;
GRANT ALL ON FUNCTION public.send_hospital_tutoring_reminders(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 10. Lo que esta migración NO hace, a propósito.
--
--   a) No guarda el estado "pendiente de completar": es scheduled con la fecha
--      pasada, y se deriva al leer. Ver la cabecera.
--
--   b) No programa el cron de send_hospital_tutoring_reminders(). Hay que
--      registrarlo (pg_cron o equivalente) para que los recordatorios salgan.
--
--   c) No restringe por rol en base de datos: que un tutor solo vea sus
--      especialidades lo hace el panel, como en el resto del módulo.
-- ---------------------------------------------------------------------------
