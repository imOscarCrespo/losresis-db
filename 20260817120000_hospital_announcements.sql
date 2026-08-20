-- Comunicados de la Unidad Docente.
--
-- Canal oficial para que Docencia y los tutores escriban a los residentes de su
-- hospital desde el panel, sin depender del correo ni de grupos de mensajería.
-- Documento "Modificaciones parte II", punto 1.
--
-- Decisiones de modelado:
--
--   * La segmentación reutiliza la misma forma que ya usan los cursos: listas de
--     especialidades y de años de residencia, combinadas con AND, y cada lista
--     vacía significa "todos". Se guardan como arrays en la propia fila porque
--     son criterios, no entidades: no hay nada que consultar por separado.
--
--   * El destinatario NO se materializa como filas al crear. Se resuelve al
--     enviar, contra los residentes que en ese momento cumplen el filtro. Un
--     comunicado programado para dentro de una semana debe llegar a quien sea
--     residente ese día, no a quien lo era al redactarlo.
--
--   * El historial es permanente: los comunicados no se borran, se archivan.

-- ---------------------------------------------------------------------------
-- 1. El comunicado.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.hospital_announcement (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  hospital_id uuid NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
  -- Quién lo escribió. Sin FK a public.users: el autor es una cuenta de
  -- organización que puede no existir en esa tabla (mismo criterio que
  -- libro_template.created_by).
  created_by uuid,
  created_by_name text,
  title text NOT NULL,
  body text NOT NULL,
  -- Segmentación. Vacío = todos los residentes del hospital.
  speciality_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  resident_years smallint[] NOT NULL DEFAULT '{}'::smallint[],
  status text NOT NULL DEFAULT 'draft',
  -- Cuándo debe salir, si está programado.
  scheduled_for timestamp with time zone,
  sent_at timestamp with time zone,
  -- Cuántos residentes lo recibieron de verdad. Se sella al enviar, para que el
  -- historial diga a cuánta gente llegó y no a cuánta llegaría hoy.
  recipient_count integer,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT hospital_announcement_status_check
    CHECK (status IN ('draft', 'scheduled', 'sent')),
  CONSTRAINT hospital_announcement_scheduled_needs_date
    CHECK (status <> 'scheduled' OR scheduled_for IS NOT NULL),
  CONSTRAINT hospital_announcement_sent_needs_date
    CHECK (status <> 'sent' OR sent_at IS NOT NULL),
  CONSTRAINT hospital_announcement_years_range
    CHECK (resident_years <@ ARRAY[1,2,3,4,5]::smallint[])
);

CREATE INDEX IF NOT EXISTS hospital_announcement_hospital_idx
  ON public.hospital_announcement (hospital_id, created_at DESC);

CREATE INDEX IF NOT EXISTS hospital_announcement_status_idx
  ON public.hospital_announcement (hospital_id, status);

-- Cola de envíos programados: el índice parcial mantiene barata la búsqueda del
-- job, que solo mira los que ya han vencido.
CREATE INDEX IF NOT EXISTS hospital_announcement_due_idx
  ON public.hospital_announcement (scheduled_for)
  WHERE status = 'scheduled';

CREATE OR REPLACE FUNCTION public.update_hospital_announcement_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_hospital_announcement_updated_at
  ON public.hospital_announcement;

CREATE TRIGGER trigger_update_hospital_announcement_updated_at
BEFORE UPDATE ON public.hospital_announcement
FOR EACH ROW
EXECUTE FUNCTION public.update_hospital_announcement_updated_at();

-- ---------------------------------------------------------------------------
-- 2. A quién llegó cada comunicado.
--
-- Se rellena al enviar. Sirve para el historial ("qué grupo lo recibió") y para
-- que la app pueda listar los comunicados de un residente sin recalcular el
-- filtro en cada apertura.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.hospital_announcement_recipient (
  announcement_id uuid NOT NULL
    REFERENCES public.hospital_announcement(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  read_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  PRIMARY KEY (announcement_id, user_id)
);

CREATE INDEX IF NOT EXISTS hospital_announcement_recipient_user_idx
  ON public.hospital_announcement_recipient (user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 3. RLS y permisos, con el patrón permisivo del resto del panel.
-- ---------------------------------------------------------------------------

ALTER TABLE public.hospital_announcement ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospital_announcement_recipient ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_hospital_announcement ON public.hospital_announcement;
CREATE POLICY allow_all_hospital_announcement
  ON public.hospital_announcement
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS allow_all_hospital_announcement_recipient
  ON public.hospital_announcement_recipient;
CREATE POLICY allow_all_hospital_announcement_recipient
  ON public.hospital_announcement_recipient
  USING (true)
  WITH CHECK (true);

GRANT ALL ON TABLE public.hospital_announcement TO anon;
GRANT ALL ON TABLE public.hospital_announcement TO authenticated;
GRANT ALL ON TABLE public.hospital_announcement TO service_role;

GRANT ALL ON TABLE public.hospital_announcement_recipient TO anon;
GRANT ALL ON TABLE public.hospital_announcement_recipient TO authenticated;
GRANT ALL ON TABLE public.hospital_announcement_recipient TO service_role;

GRANT ALL ON FUNCTION public.update_hospital_announcement_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_hospital_announcement_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_hospital_announcement_updated_at() TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Quién cumple el filtro.
--
-- La usa el panel para el contador en vivo mientras el usuario elige
-- destinatarios, y el envío para materializar los destinatarios. Una sola
-- definición para las dos cosas: si el contador y el envío difirieran, el número
-- que ve el usuario sería mentira.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.hospital_announcement_audience(
  p_hospital_id uuid,
  p_speciality_ids uuid[] DEFAULT '{}'::uuid[],
  p_resident_years smallint[] DEFAULT '{}'::smallint[]
)
RETURNS TABLE (user_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT u.id
  FROM public.users u
  WHERE u.is_resident IS TRUE
    AND u.hospital_id = p_hospital_id
    AND (
      p_speciality_ids IS NULL
      OR cardinality(p_speciality_ids) = 0
      OR u.speciality_id = ANY (p_speciality_ids)
    )
    AND (
      p_resident_years IS NULL
      OR cardinality(p_resident_years) = 0
      OR COALESCE(u.resident_year, 0)::smallint = ANY (p_resident_years)
    );
$$;

GRANT ALL ON FUNCTION public.hospital_announcement_audience(uuid, uuid[], smallint[]) TO anon;
GRANT ALL ON FUNCTION public.hospital_announcement_audience(uuid, uuid[], smallint[]) TO authenticated;
GRANT ALL ON FUNCTION public.hospital_announcement_audience(uuid, uuid[], smallint[]) TO service_role;

CREATE OR REPLACE FUNCTION public.count_hospital_announcement_audience(
  p_hospital_id uuid,
  p_speciality_ids uuid[] DEFAULT '{}'::uuid[],
  p_resident_years smallint[] DEFAULT '{}'::smallint[]
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.hospital_announcement_audience(
    p_hospital_id, p_speciality_ids, p_resident_years
  );
$$;

GRANT ALL ON FUNCTION public.count_hospital_announcement_audience(uuid, uuid[], smallint[]) TO anon;
GRANT ALL ON FUNCTION public.count_hospital_announcement_audience(uuid, uuid[], smallint[]) TO authenticated;
GRANT ALL ON FUNCTION public.count_hospital_announcement_audience(uuid, uuid[], smallint[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Tipo de notificación.
--
-- Debe existir antes de cualquier insert en notifications por el FK
-- notifications.type -> notification_types.code.
-- ---------------------------------------------------------------------------

INSERT INTO public.notification_types (code, description)
VALUES ('hospital_announcement', 'Comunicado de la Unidad Docente')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Enviar.
--
-- Idempotente por diseño: un comunicado ya enviado no se reenvía, así que el job
-- de los programados puede reintentar sin duplicar notificaciones.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.send_hospital_announcement(p_announcement_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_announcement record;
  v_count integer := 0;
BEGIN
  SELECT * INTO v_announcement
  FROM public.hospital_announcement
  WHERE id = p_announcement_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El comunicado % no existe', p_announcement_id;
  END IF;

  IF v_announcement.status = 'sent' THEN
    RETURN COALESCE(v_announcement.recipient_count, 0);
  END IF;

  INSERT INTO public.hospital_announcement_recipient (announcement_id, user_id)
  SELECT p_announcement_id, a.user_id
  FROM public.hospital_announcement_audience(
    v_announcement.hospital_id,
    v_announcement.speciality_ids,
    v_announcement.resident_years
  ) a
  ON CONFLICT (announcement_id, user_id) DO NOTHING;

  SELECT count(*)::integer INTO v_count
  FROM public.hospital_announcement_recipient
  WHERE announcement_id = p_announcement_id;

  INSERT INTO public.notifications (
    user_id, type, title, body, entity_type, entity_id, data
  )
  SELECT r.user_id,
         'hospital_announcement',
         v_announcement.title,
         v_announcement.body,
         'hospital_announcement',
         p_announcement_id,
         jsonb_build_object('announcement_id', p_announcement_id)
  FROM public.hospital_announcement_recipient r
  WHERE r.announcement_id = p_announcement_id;

  UPDATE public.hospital_announcement
  SET status = 'sent',
      sent_at = now(),
      recipient_count = v_count
  WHERE id = p_announcement_id;

  RETURN v_count;
END;
$$;

GRANT ALL ON FUNCTION public.send_hospital_announcement(uuid) TO anon;
GRANT ALL ON FUNCTION public.send_hospital_announcement(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.send_hospital_announcement(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Los programados que ya han vencido.
--
-- Pensada para un cron (pg_cron o un job externo). Devuelve cuántos envió.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.send_due_hospital_announcements()
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
    SELECT id
    FROM public.hospital_announcement
    WHERE status = 'scheduled'
      AND scheduled_for <= now()
    ORDER BY scheduled_for
  LOOP
    BEGIN
      PERFORM public.send_hospital_announcement(v_row.id);
      v_sent := v_sent + 1;
    EXCEPTION
      WHEN OTHERS THEN
        -- Un comunicado que falla no puede parar a los demás.
        RAISE WARNING 'No se pudo enviar el comunicado %: %', v_row.id, SQLERRM;
    END;
  END LOOP;

  RETURN v_sent;
END;
$$;

GRANT ALL ON FUNCTION public.send_due_hospital_announcements() TO anon;
GRANT ALL ON FUNCTION public.send_due_hospital_announcements() TO authenticated;
GRANT ALL ON FUNCTION public.send_due_hospital_announcements() TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Lo que esta migración NO hace, a propósito.
--
--   a) No programa el cron. Hay que registrar send_due_hospital_announcements()
--      en pg_cron (o equivalente) con la periodicidad que se quiera; mientras no
--      se haga, los comunicados programados se quedan en 'scheduled'.
--
--   b) No manda push. Inserta en notifications, que es lo que la app lee; el
--      push va por el webhook que ya existe sobre esa tabla.
--
--   c) No restringe por rol en base de datos. El gateo de "un tutor solo escribe
--      a sus especialidades" lo hace el panel, igual que el resto del módulo. La
--      RLS de estas tablas es permisiva como en todo el panel.
-- ---------------------------------------------------------------------------
