-- ---------------------------------------------------------------------------
-- Eventos del servicio (losresis-panel ADR 0021 y 0022).
--
-- Un Evento del servicio es un acto con fecha y hora (sesión clínica, curso,
-- reunión) que un Responsable de especialidad convoca para residentes de su
-- Servicio. No es un Recordatorio (ADR 0008): no se cierra, no se arrastra,
-- no se archiva y no lleva NHC.
--
-- Se proyecta como COPIA por convocado en agenda_events (event_type =
-- 'service'), que la app ya pinta por user_id sin cambios estructurales. Las
-- copias son de solo lectura en la app; la verdad editable vive aquí.
--
-- Todas las escrituras pasan por RPCs SECURITY DEFINER transaccionales: o
-- entra todo (evento + convocados + copias + notificaciones) o no entra nada.
-- El insert en notifications dispara el push vía el trigger
-- send_push_notifications existente.
--
-- Solo convoca el Responsable de especialidad (role = 'speciality_manager'
-- con la especialidad en su alcance). El Owner NO: convocar nace del alcance,
-- no del rango (losresis-panel ADR 0022).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Tipo 'service' en agenda_events.
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
      'service'::text
    ]
  )
);

-- ---------------------------------------------------------------------------
-- 2. Tipos de notificación. Deben existir antes de cualquier insert en
--    notifications por el FK notifications.type -> notification_types.code.
-- ---------------------------------------------------------------------------

INSERT INTO public.notification_types (code, description)
VALUES
  ('service_event_created', 'El servicio ha convocado un nuevo evento en tu agenda'),
  ('service_event_updated', 'Un evento del servicio en tu agenda ha cambiado'),
  ('service_event_cancelled', 'Un evento del servicio en tu agenda se ha cancelado')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Tablas. El evento es UNA fila del Servicio; los convocados son la lista
--    NOMINAL resuelta al crear (marcar "R1" expande a las personas que son R1
--    en ese momento). anios_convocados guarda qué grupos se marcaron solo
--    para presentación ("R1, R2 · 31 convocados"), no es una regla viva.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.evento_servicio (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  servicio_id uuid NOT NULL REFERENCES public.servicio(id) ON DELETE CASCADE,

  titulo text NOT NULL CHECK (btrim(titulo) <> ''),
  fecha date NOT NULL,
  hora_inicio time without time zone,
  hora_fin time without time zone,
  lugar text,
  notas text,

  anios_convocados smallint[] NOT NULL DEFAULT '{}',

  creado_por_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,

  -- Cancelar marca (quién y cuándo) y retira las copias de agenda: histórico
  -- consultable en el panel, agenda limpia en la app.
  cancelado_en timestamptz,
  cancelado_por_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT evento_servicio_horas_check
    CHECK (hora_fin IS NULL OR hora_inicio IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS evento_servicio_servicio_idx
  ON public.evento_servicio (servicio_id, fecha);

CREATE TABLE IF NOT EXISTS public.evento_servicio_convocado (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evento_id uuid NOT NULL REFERENCES public.evento_servicio(id) ON DELETE CASCADE,
  -- Borrar al usuario borra su convocatoria; su copia de agenda ya cae en
  -- cascada por agenda_events.user_id.
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  -- SET NULL y no CASCADE: al cancelar borramos la copia pero la fila del
  -- convocado se queda, para poder responder "a quién se convocó".
  agenda_event_id uuid REFERENCES public.agenda_events(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT evento_servicio_convocado_unico UNIQUE (evento_id, user_id)
);

CREATE INDEX IF NOT EXISTS evento_servicio_convocado_user_idx
  ON public.evento_servicio_convocado (user_id);

DROP TRIGGER IF EXISTS trg_evento_servicio_updated_at ON public.evento_servicio;
CREATE TRIGGER trg_evento_servicio_updated_at
BEFORE UPDATE ON public.evento_servicio
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at_timestamp_generic();

-- ---------------------------------------------------------------------------
-- 4. Quién convoca: la cuenta activa con role = 'speciality_manager' y la
--    especialidad del servicio en su alcance. Devuelve el account_id para
--    firmar creado_por/cancelado_por, o NULL si no puede.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.evento_servicio_cuenta_convocante(
  p_servicio_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ea.id
  FROM public.servicio s
  JOIN public.employer_org eo ON eo.hospital_id = s.hospital_id
  JOIN public.employer_account ea ON ea.org_id = eo.id
  JOIN public.employer_account_speciality eas ON eas.account_id = ea.id
  WHERE s.id = p_servicio_id
    AND ea.user_id = auth.uid()
    AND coalesce(ea.is_active, false)
    AND ea.role = 'speciality_manager'
    AND eas.speciality_id = s.speciality_id
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.evento_servicio_cuenta_convocante(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.evento_servicio_cuenta_convocante(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.evento_servicio_cuenta_convocante(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Helpers privados de proyección (sin GRANT: solo los usan los RPCs).
-- ---------------------------------------------------------------------------

-- Notas de la copia: el lugar viaja dentro de las notas porque agenda_events
-- no tiene columna de lugar y la app ya muestra notes en el detalle.
CREATE OR REPLACE FUNCTION public.evento_servicio_notas_copia(
  p_lugar text,
  p_notas text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(btrim(concat_ws(
    E'\n',
    CASE WHEN NULLIF(btrim(coalesce(p_lugar, '')), '') IS NOT NULL
      THEN 'Lugar: ' || btrim(p_lugar) END,
    NULLIF(btrim(coalesce(p_notas, '')), '')
  )), '');
$$;

CREATE OR REPLACE FUNCTION public.evento_servicio_texto_cuando(
  p_fecha date,
  p_hora_inicio time
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT to_char(p_fecha, 'DD/MM/YYYY')
    || CASE WHEN p_hora_inicio IS NULL THEN ''
       ELSE ' · ' || to_char(p_hora_inicio, 'HH24:MI') END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Crear: evento + N convocados + N copias + N notificaciones, transaccional.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.crear_evento_servicio(
  p_servicio_id uuid,
  p_titulo text,
  p_fecha date,
  p_user_ids uuid[],
  p_hora_inicio time DEFAULT NULL,
  p_hora_fin time DEFAULT NULL,
  p_lugar text DEFAULT NULL,
  p_notas text DEFAULT NULL,
  p_anios smallint[] DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_servicio public.servicio%ROWTYPE;
  v_account_id uuid;
  v_service_name text;
  v_evento_id uuid;
  v_user_id uuid;
  v_user_ids uuid[];
  v_copy_id uuid;
  v_notas_copia text;
BEGIN
  SELECT * INTO v_servicio FROM public.servicio WHERE id = p_servicio_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El servicio no existe';
  END IF;

  v_account_id := public.evento_servicio_cuenta_convocante(p_servicio_id);
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Solo el responsable de la especialidad puede convocar eventos del servicio';
  END IF;

  IF btrim(coalesce(p_titulo, '')) = '' THEN
    RAISE EXCEPTION 'El evento necesita un título';
  END IF;

  SELECT array_agg(DISTINCT u) INTO v_user_ids FROM unnest(p_user_ids) AS u;
  IF v_user_ids IS NULL OR array_length(v_user_ids, 1) = 0 THEN
    RAISE EXCEPTION 'El evento necesita al menos un convocado';
  END IF;

  -- Solo residentes del propio servicio son convocables (v1).
  IF EXISTS (
    SELECT 1 FROM unnest(v_user_ids) AS uid
    WHERE NOT EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = uid
        AND coalesce(u.is_resident, false)
        AND u.hospital_id = v_servicio.hospital_id
        AND u.speciality_id = v_servicio.speciality_id
    )
  ) THEN
    RAISE EXCEPTION 'Solo se puede convocar a residentes del servicio';
  END IF;

  SELECT sp.name INTO v_service_name
  FROM public.specialities sp
  WHERE sp.id = v_servicio.speciality_id;

  INSERT INTO public.evento_servicio (
    servicio_id, titulo, fecha, hora_inicio, hora_fin, lugar, notas,
    anios_convocados, creado_por_account_id
  ) VALUES (
    p_servicio_id, btrim(p_titulo), p_fecha, p_hora_inicio, p_hora_fin,
    NULLIF(btrim(coalesce(p_lugar, '')), ''),
    NULLIF(btrim(coalesce(p_notas, '')), ''),
    coalesce(p_anios, '{}'), v_account_id
  )
  RETURNING id INTO v_evento_id;

  v_notas_copia := public.evento_servicio_notas_copia(p_lugar, p_notas);

  FOREACH v_user_id IN ARRAY v_user_ids LOOP
    INSERT INTO public.agenda_events (
      user_id, event_type, title, event_date, start_time, end_time,
      all_day, notes, metadata
    ) VALUES (
      v_user_id, 'service', btrim(p_titulo), p_fecha, p_hora_inicio, p_hora_fin,
      p_hora_inicio IS NULL, v_notas_copia,
      jsonb_build_object(
        'evento_servicio_id', v_evento_id,
        'servicio_id', p_servicio_id,
        'service_name', v_service_name
      )
    )
    RETURNING id INTO v_copy_id;

    INSERT INTO public.evento_servicio_convocado (evento_id, user_id, agenda_event_id)
    VALUES (v_evento_id, v_user_id, v_copy_id);

    INSERT INTO public.notifications (user_id, type, title, body, entity_type, entity_id, data)
    VALUES (
      v_user_id,
      'service_event_created',
      'Nuevo evento en tu agenda',
      '"' || btrim(p_titulo) || '" · '
        || public.evento_servicio_texto_cuando(p_fecha, p_hora_inicio),
      'agenda_event',
      v_copy_id,
      jsonb_build_object(
        'entity_type', 'agenda_event',
        'entity_id', v_copy_id,
        'evento_servicio_id', v_evento_id,
        'event_type', 'service',
        'event_title', btrim(p_titulo),
        'event_date', p_fecha,
        'service_name', v_service_name,
        'destination_section', 'agenda',
        'destination_tab', 'agenda'
      )
    );
  END LOOP;

  RETURN v_evento_id;
END;
$$;

REVOKE ALL ON FUNCTION public.crear_evento_servicio(uuid, text, date, uuid[], time, time, text, text, smallint[]) FROM public;
GRANT EXECUTE ON FUNCTION public.crear_evento_servicio(uuid, text, date, uuid[], time, time, text, text, smallint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_evento_servicio(uuid, text, date, uuid[], time, time, text, text, smallint[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Actualizar: los datos propagan a las copias y avisan; añadir convocado
--    crea su copia y le llega el push de creación; quitarlo borra su copia en
--    silencio (avisar "ya no estás convocado" a quien quizá ni lo vio mete
--    ruido).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.actualizar_evento_servicio(
  p_evento_id uuid,
  p_titulo text,
  p_fecha date,
  p_user_ids uuid[],
  p_hora_inicio time DEFAULT NULL,
  p_hora_fin time DEFAULT NULL,
  p_lugar text DEFAULT NULL,
  p_notas text DEFAULT NULL,
  p_anios smallint[] DEFAULT '{}'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_evento public.evento_servicio%ROWTYPE;
  v_servicio public.servicio%ROWTYPE;
  v_account_id uuid;
  v_service_name text;
  v_user_ids uuid[];
  v_user_id uuid;
  v_copy_id uuid;
  v_notas_copia text;
  v_datos_cambian boolean;
  v_convocado record;
BEGIN
  SELECT * INTO v_evento FROM public.evento_servicio WHERE id = p_evento_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El evento no existe';
  END IF;
  IF v_evento.cancelado_en IS NOT NULL THEN
    RAISE EXCEPTION 'Un evento cancelado no se edita';
  END IF;

  SELECT * INTO v_servicio FROM public.servicio WHERE id = v_evento.servicio_id;

  v_account_id := public.evento_servicio_cuenta_convocante(v_evento.servicio_id);
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Solo el responsable de la especialidad puede editar eventos del servicio';
  END IF;

  IF btrim(coalesce(p_titulo, '')) = '' THEN
    RAISE EXCEPTION 'El evento necesita un título';
  END IF;

  SELECT array_agg(DISTINCT u) INTO v_user_ids FROM unnest(p_user_ids) AS u;
  IF v_user_ids IS NULL OR array_length(v_user_ids, 1) = 0 THEN
    RAISE EXCEPTION 'El evento necesita al menos un convocado';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(v_user_ids) AS uid
    WHERE NOT EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = uid
        AND coalesce(u.is_resident, false)
        AND u.hospital_id = v_servicio.hospital_id
        AND u.speciality_id = v_servicio.speciality_id
    )
  ) THEN
    RAISE EXCEPTION 'Solo se puede convocar a residentes del servicio';
  END IF;

  SELECT sp.name INTO v_service_name
  FROM public.specialities sp
  WHERE sp.id = v_servicio.speciality_id;

  v_datos_cambian :=
    v_evento.titulo IS DISTINCT FROM btrim(p_titulo)
    OR v_evento.fecha IS DISTINCT FROM p_fecha
    OR v_evento.hora_inicio IS DISTINCT FROM p_hora_inicio
    OR v_evento.hora_fin IS DISTINCT FROM p_hora_fin
    OR v_evento.lugar IS DISTINCT FROM NULLIF(btrim(coalesce(p_lugar, '')), '')
    OR v_evento.notas IS DISTINCT FROM NULLIF(btrim(coalesce(p_notas, '')), '');

  UPDATE public.evento_servicio SET
    titulo = btrim(p_titulo),
    fecha = p_fecha,
    hora_inicio = p_hora_inicio,
    hora_fin = p_hora_fin,
    lugar = NULLIF(btrim(coalesce(p_lugar, '')), ''),
    notas = NULLIF(btrim(coalesce(p_notas, '')), ''),
    anios_convocados = coalesce(p_anios, '{}')
  WHERE id = p_evento_id;

  v_notas_copia := public.evento_servicio_notas_copia(p_lugar, p_notas);

  -- Bajas: fuera su copia, sin push.
  FOR v_convocado IN
    SELECT * FROM public.evento_servicio_convocado
    WHERE evento_id = p_evento_id AND user_id <> ALL (v_user_ids)
  LOOP
    DELETE FROM public.agenda_events WHERE id = v_convocado.agenda_event_id;
    DELETE FROM public.evento_servicio_convocado WHERE id = v_convocado.id;
  END LOOP;

  -- Los que siguen: propagar datos y, si cambiaron, avisar.
  UPDATE public.agenda_events ae SET
    title = btrim(p_titulo),
    event_date = p_fecha,
    start_time = p_hora_inicio,
    end_time = p_hora_fin,
    all_day = p_hora_inicio IS NULL,
    notes = v_notas_copia,
    updated_at = now()
  FROM public.evento_servicio_convocado c
  WHERE c.evento_id = p_evento_id AND ae.id = c.agenda_event_id;

  IF v_datos_cambian THEN
    INSERT INTO public.notifications (user_id, type, title, body, entity_type, entity_id, data)
    SELECT
      c.user_id,
      'service_event_updated',
      'Evento actualizado',
      '"' || btrim(p_titulo) || '" pasa a '
        || public.evento_servicio_texto_cuando(p_fecha, p_hora_inicio),
      'agenda_event',
      c.agenda_event_id,
      jsonb_build_object(
        'entity_type', 'agenda_event',
        'entity_id', c.agenda_event_id,
        'evento_servicio_id', p_evento_id,
        'event_type', 'service',
        'event_title', btrim(p_titulo),
        'event_date', p_fecha,
        'service_name', v_service_name,
        'destination_section', 'agenda',
        'destination_tab', 'agenda'
      )
    FROM public.evento_servicio_convocado c
    WHERE c.evento_id = p_evento_id;
  END IF;

  -- Altas: copia nueva y push de creación, como si acabara de convocarse.
  FOREACH v_user_id IN ARRAY v_user_ids LOOP
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.evento_servicio_convocado
      WHERE evento_id = p_evento_id AND user_id = v_user_id
    );

    INSERT INTO public.agenda_events (
      user_id, event_type, title, event_date, start_time, end_time,
      all_day, notes, metadata
    ) VALUES (
      v_user_id, 'service', btrim(p_titulo), p_fecha, p_hora_inicio, p_hora_fin,
      p_hora_inicio IS NULL, v_notas_copia,
      jsonb_build_object(
        'evento_servicio_id', p_evento_id,
        'servicio_id', v_evento.servicio_id,
        'service_name', v_service_name
      )
    )
    RETURNING id INTO v_copy_id;

    INSERT INTO public.evento_servicio_convocado (evento_id, user_id, agenda_event_id)
    VALUES (p_evento_id, v_user_id, v_copy_id);

    INSERT INTO public.notifications (user_id, type, title, body, entity_type, entity_id, data)
    VALUES (
      v_user_id,
      'service_event_created',
      'Nuevo evento en tu agenda',
      '"' || btrim(p_titulo) || '" · '
        || public.evento_servicio_texto_cuando(p_fecha, p_hora_inicio),
      'agenda_event',
      v_copy_id,
      jsonb_build_object(
        'entity_type', 'agenda_event',
        'entity_id', v_copy_id,
        'evento_servicio_id', p_evento_id,
        'event_type', 'service',
        'event_title', btrim(p_titulo),
        'event_date', p_fecha,
        'service_name', v_service_name,
        'destination_section', 'agenda',
        'destination_tab', 'agenda'
      )
    );
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.actualizar_evento_servicio(uuid, text, date, uuid[], time, time, text, text, smallint[]) FROM public;
GRANT EXECUTE ON FUNCTION public.actualizar_evento_servicio(uuid, text, date, uuid[], time, time, text, text, smallint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_evento_servicio(uuid, text, date, uuid[], time, time, text, text, smallint[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Cancelar: marca quién y cuándo, avisa y retira las copias. La fila del
--    panel y sus convocados se quedan (agenda_event_id pasa a NULL): el
--    histórico puede responder "esto se convocó y se canceló".
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancelar_evento_servicio(
  p_evento_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_evento public.evento_servicio%ROWTYPE;
  v_account_id uuid;
  v_service_name text;
BEGIN
  SELECT * INTO v_evento FROM public.evento_servicio WHERE id = p_evento_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El evento no existe';
  END IF;
  IF v_evento.cancelado_en IS NOT NULL THEN
    RAISE EXCEPTION 'El evento ya está cancelado';
  END IF;

  v_account_id := public.evento_servicio_cuenta_convocante(v_evento.servicio_id);
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Solo el responsable de la especialidad puede cancelar eventos del servicio';
  END IF;

  SELECT sp.name INTO v_service_name
  FROM public.servicio s
  JOIN public.specialities sp ON sp.id = s.speciality_id
  WHERE s.id = v_evento.servicio_id;

  INSERT INTO public.notifications (user_id, type, title, body, entity_type, entity_id, data)
  SELECT
    c.user_id,
    'service_event_cancelled',
    'Evento cancelado',
    'Cancelado: "' || v_evento.titulo || '" del '
      || public.evento_servicio_texto_cuando(v_evento.fecha, v_evento.hora_inicio),
    'evento_servicio',
    p_evento_id,
    jsonb_build_object(
      'entity_type', 'evento_servicio',
      'entity_id', p_evento_id,
      'event_type', 'service',
      'event_title', v_evento.titulo,
      'event_date', v_evento.fecha,
      'service_name', v_service_name,
      'destination_section', 'agenda',
      'destination_tab', 'agenda'
    )
  FROM public.evento_servicio_convocado c
  WHERE c.evento_id = p_evento_id;

  DELETE FROM public.agenda_events ae
  USING public.evento_servicio_convocado c
  WHERE c.evento_id = p_evento_id AND ae.id = c.agenda_event_id;

  UPDATE public.evento_servicio SET
    cancelado_en = now(),
    cancelado_por_account_id = v_account_id
  WHERE id = p_evento_id;
END;
$$;

REVOKE ALL ON FUNCTION public.cancelar_evento_servicio(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.cancelar_evento_servicio(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancelar_evento_servicio(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. RLS. Lectura para los miembros del servicio (todo el equipo VE los
--    eventos en la pantalla de recordatorios); escritura solo vía RPCs
--    SECURITY DEFINER — sin INSERT/UPDATE/DELETE directos ni para
--    authenticated. anon no recibe nada (mismo criterio que la vertical
--    clínica: la anon key viaja en el bundle).
-- ---------------------------------------------------------------------------

ALTER TABLE public.evento_servicio ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evento_servicio_convocado ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS evento_servicio_scope ON public.evento_servicio;
CREATE POLICY evento_servicio_scope ON public.evento_servicio
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.servicio s
    WHERE s.id = evento_servicio.servicio_id
      AND public.seguimiento_tiene_alcance(s.hospital_id, s.speciality_id)
  ));

DROP POLICY IF EXISTS evento_servicio_convocado_scope ON public.evento_servicio_convocado;
CREATE POLICY evento_servicio_convocado_scope ON public.evento_servicio_convocado
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.evento_servicio e
    JOIN public.servicio s ON s.id = e.servicio_id
    WHERE e.id = evento_servicio_convocado.evento_id
      AND public.seguimiento_tiene_alcance(s.hospital_id, s.speciality_id)
  ));

REVOKE ALL ON TABLE public.evento_servicio FROM anon;
REVOKE ALL ON TABLE public.evento_servicio_convocado FROM anon;

GRANT SELECT ON TABLE public.evento_servicio TO authenticated;
GRANT SELECT ON TABLE public.evento_servicio_convocado TO authenticated;

GRANT ALL ON TABLE public.evento_servicio TO service_role;
GRANT ALL ON TABLE public.evento_servicio_convocado TO service_role;
