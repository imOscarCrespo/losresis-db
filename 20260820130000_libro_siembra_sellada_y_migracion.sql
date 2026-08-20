-- ---------------------------------------------------------------------------
-- Una sola copia de la lógica plantilla → libro, y sellada.
--
-- Punto de partida: había TRES copias y no coincidían (ver ADR 0006 de
-- losresis-app):
--
--   * apply_libro_template_for_user (trigger de alta) — no sellaba nada
--   * switchLibroYearToTemplate (cliente, en la app) — sellaba template_id pero no
--     template_node_id, y no clonaba comments_mode, duration_amount,
--     duration_unit, center ni description
--   * sync_libro_template_for_user — empareja POR template_node_id
--
-- Con eso, llamar a sync sobre un libro migrado desde la app duplicaba todos sus
-- nodos: el UPDATE no encontraba nada, caía al INSERT, y el DELETE de bajas exige
-- template_node_id IS NOT NULL, así que los viejos no se limpiaban nunca.
--
-- Aquí queda una función de siembra, sellando siempre, y las dos entradas
-- (el alta y la migración) la llaman. El cliente deja de clonar.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 0. El candado de estructura dejaba el Libro oficial en solo lectura de hecho.
--
-- libro_node_block_structure_changes está en BEFORE INSERT/DELETE/UPDATE de
-- libro_node y lanza excepción si el libro tiene template_id. La intención es
-- correcta: la estructura de un Libro oficial la define el tutor.
--
-- Pero libro_node_total_count está en AFTER INSERT de libro_entry y hace
-- `UPDATE libro_node SET total_count = ...`. Registrar una actividad en un libro
-- sembrado desde plantilla disparaba el contador, el contador tocaba libro_node y
-- el candado lo abortaba: el residente NO PODÍA REGISTRAR NADA en su libro oficial.
--
-- Hoy solo lo sufre el usuario de prueba (los libros sellados tienen 0 registros),
-- pero se vuelve universal en cuanto un hospital publique su plantilla, que es
-- justo lo que este trabajo habilita.
--
-- El candado pasa a mirar QUÉ cambia: si lo único que cambia en la fila es
-- total_count, no es un cambio de estructura y pasa. Se compara la fila entera en
-- jsonb para que el día que se añada una columna nueva no haya que acordarse de
-- añadirla a una lista.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.libro_node_block_structure_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- La reconciliación desde plantilla sí puede tocar la estructura.
  IF COALESCE(current_setting('libro.sync', true), '') = 'on' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- El contador de registros no es estructura. Es lo que escribe
  -- libro_node_total_count cuando el residente anota algo.
  IF TG_OP = 'UPDATE'
     AND (to_jsonb(NEW) - 'total_count') = (to_jsonb(OLD) - 'total_count') THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.libro_book
    WHERE id = COALESCE(NEW.book_id, OLD.book_id) AND template_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Este libro lo define el hospital: su estructura no se puede modificar';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. La siembra, en un solo sitio.
--
-- Crea un libro por BLOQUE declarado, no solo por los que tienen nodos: los
-- apartados del arquetipo `form` no tienen nodos y el residente necesita un libro
-- del que colgar sus registros (libro_entry.book_id).
--
-- Devuelve cuántos libros ha creado.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.seed_libro_year_from_template(
  p_user_id uuid,
  p_template_id uuid,
  p_residency_year smallint
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template_year smallint;
  v_section public.libro_section_code;
  v_book_id uuid;
  v_node record;
  v_new_id uuid;
  v_parent_new uuid;
  v_map jsonb;
  v_created integer := 0;
BEGIN
  IF p_user_id IS NULL OR p_template_id IS NULL OR p_residency_year IS NULL THEN
    RETURN 0;
  END IF;

  -- La plantilla llega hasta R5; un R6 o R7 hereda la de R5.
  v_template_year := LEAST(GREATEST(p_residency_year, 1), 5)::smallint;

  FOR v_section IN
    SELECT section
    FROM public.libro_template_block
    WHERE template_id = p_template_id
      AND residency_year = v_template_year
    UNION
    SELECT DISTINCT section
    FROM public.libro_template_node
    WHERE template_id = p_template_id
      AND residency_year = v_template_year
  LOOP
    INSERT INTO public.libro_book (user_id, section, residency_year, status)
    VALUES (p_user_id, v_section, p_residency_year, 'active')
    RETURNING id INTO v_book_id;

    v_created := v_created + 1;
    v_map := '{}'::jsonb;

    FOR v_node IN
      WITH RECURSIVE tree AS (
        SELECT tn.id, tn.parent_node_id, tn.name, tn.goal, tn.icon_name,
               tn.color_token, tn.tracking_mode, tn.comments_mode,
               tn.duration_amount, tn.duration_unit, tn.center, tn.description,
               tn.expected_level, tn.position, tn.created_at, 0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = p_template_id
          AND tn.section = v_section
          AND tn.residency_year = v_template_year
          AND tn.parent_node_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.comments_mode,
               c.duration_amount, c.duration_unit, c.center, c.description,
               c.expected_level, c.position, c.created_at, t.depth + 1
        FROM public.libro_template_node c
        JOIN tree t ON c.parent_node_id = t.id
        WHERE c.template_id = p_template_id
          AND c.section = v_section
          AND c.residency_year = v_template_year
      )
      SELECT * FROM tree
      ORDER BY depth, position NULLS LAST, created_at
    LOOP
      v_parent_new := NULL;
      IF v_node.parent_node_id IS NOT NULL THEN
        v_parent_new := (v_map ->> v_node.parent_node_id::text)::uuid;
      END IF;

      INSERT INTO public.libro_node (
        user_id, book_id, section, parent_node_id, name, goal,
        icon_name, color_token, tracking_mode, comments_mode,
        duration_amount, duration_unit, center, description, expected_level,
        position, template_node_id
      )
      VALUES (
        p_user_id, v_book_id, v_section, v_parent_new, v_node.name, v_node.goal,
        v_node.icon_name, v_node.color_token,
        COALESCE(v_node.tracking_mode, 'counter'),
        COALESCE(v_node.comments_mode, 'off'),
        v_node.duration_amount, v_node.duration_unit, v_node.center,
        v_node.description, v_node.expected_level, v_node.position,
        v_node.id
      )
      RETURNING id INTO v_new_id;

      v_map := v_map || jsonb_build_object(v_node.id::text, v_new_id::text);
    END LOOP;

    -- El sello del libro va DESPUÉS de clonar: trigger_libro_node_structure_locked
    -- rechaza escribir nodos en un libro que ya tenga template_id, así que sellarlo
    -- antes abortaría su propia siembra.
    UPDATE public.libro_book
    SET template_id = p_template_id
    WHERE id = v_book_id;
  END LOOP;

  RETURN v_created;
END;
$$;

GRANT ALL ON FUNCTION public.seed_libro_year_from_template(uuid, uuid, smallint) TO anon;
GRANT ALL ON FUNCTION public.seed_libro_year_from_template(uuid, uuid, smallint) TO authenticated;
GRANT ALL ON FUNCTION public.seed_libro_year_from_template(uuid, uuid, smallint) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. El alta: igual que antes, pero delegando la siembra.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_libro_template_for_user(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user record;
  v_template_id uuid;
  v_year smallint;
  v_created integer;
BEGIN
  SELECT id, hospital_id, speciality_id, resident_year, is_resident
  INTO v_user
  FROM public.users
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_user.is_resident IS NOT TRUE
     OR v_user.hospital_id IS NULL
     OR v_user.speciality_id IS NULL THEN
    RETURN;
  END IF;

  -- "Solo futuros residentes": si ya existe cualquier libro, no tocar nada. Quien
  -- ya tiene Libro propio se cambia cuando quiera, desde la app (ADR 0007).
  IF EXISTS (SELECT 1 FROM public.libro_book WHERE user_id = p_user_id) THEN
    RETURN;
  END IF;

  SELECT id
  INTO v_template_id
  FROM public.libro_template
  WHERE hospital_id = v_user.hospital_id
    AND speciality_id = v_user.speciality_id
    AND is_published = true
  LIMIT 1;

  IF v_template_id IS NULL THEN
    RETURN;
  END IF;

  v_year := GREATEST(COALESCE(v_user.resident_year, 1), 1)::smallint;

  v_created := public.seed_libro_year_from_template(
    p_user_id, v_template_id, v_year
  );

  -- Antes esto miraba si se había creado algún NODO, así que una plantilla de solo
  -- apartados `form` (que no tienen nodos) dejaba el onboarding sin marcar y el
  -- residente volvía a ver la pantalla de montarse el libro.
  IF v_created > 0 THEN
    INSERT INTO public.libro_user_settings (
      user_id, speciality_id, onboarding_completed_at, onboarding_version
    )
    VALUES (p_user_id, v_user.speciality_id, now(), 1)
    ON CONFLICT (user_id) DO UPDATE
      SET onboarding_completed_at = COALESCE(
            public.libro_user_settings.onboarding_completed_at,
            EXCLUDED.onboarding_completed_at
          ),
          speciality_id = COALESCE(
            public.libro_user_settings.speciality_id,
            EXCLUDED.speciality_id
          ),
          updated_at = now();
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Migrar a la plantilla, sustituyendo al clonado del cliente.
--
-- DESTRUCTIVO: borra el libro que el residente tenga de ese año y con él lo
-- registrado dentro (libro_node cae por el ON DELETE CASCADE de book_id, y con los
-- nodos caen sus entradas y sus fichas). Quien llama tiene que haberlo confirmado,
-- y la app ofrece descargar el libro completo en PDF antes.
--
-- Los años que el residente ya cerró no se tocan.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.migrate_libro_year_to_template(
  p_user_id uuid,
  p_residency_year smallint
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user record;
  v_template_id uuid;
BEGIN
  IF p_user_id IS NULL OR p_residency_year IS NULL THEN
    RAISE EXCEPTION 'p_user_id y p_residency_year son obligatorios';
  END IF;

  -- Solo el propio residente, o el service_role. Es SECURITY DEFINER y borra: sin
  -- esta comprobación cualquiera podría vaciarle el libro a otro.
  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'Solo el residente puede migrar su propio libro';
  END IF;

  SELECT id, hospital_id, speciality_id
  INTO v_user
  FROM public.users
  WHERE id = p_user_id;

  IF NOT FOUND OR v_user.hospital_id IS NULL OR v_user.speciality_id IS NULL THEN
    RAISE EXCEPTION 'El residente % no tiene hospital y especialidad', p_user_id;
  END IF;

  SELECT id
  INTO v_template_id
  FROM public.libro_template
  WHERE hospital_id = v_user.hospital_id
    AND speciality_id = v_user.speciality_id
    AND is_published = true
  LIMIT 1;

  IF v_template_id IS NULL THEN
    RAISE EXCEPTION 'Tu hospital no tiene plantilla publicada para tu especialidad';
  END IF;

  -- Los años anteriores que sigan activos pasan a archivados. Es obligatorio:
  -- libro_book_one_active_per_user_section_idx no admite dos libros activos de la
  -- misma sección, así que sin archivar R1 no cabe el R2.
  UPDATE public.libro_book
  SET status = 'archived', archived_at = now()
  WHERE user_id = p_user_id
    AND status = 'active'
    AND residency_year < p_residency_year;

  -- El borrado cascadea a libro_node, y el BEFORE DELETE del candado de estructura
  -- se dispara TAMBIÉN en cascada: sin esto, migrar un año que ya tuviera un libro
  -- oficial (una segunda migración, o un año medio sembrado) abortaría con "este
  -- libro lo define el hospital". Es la misma escapatoria que usa
  -- sync_libro_template_for_user, y es local a la transacción.
  PERFORM set_config('libro.sync', 'on', true);

  DELETE FROM public.libro_book
  WHERE user_id = p_user_id
    AND residency_year = p_residency_year;

  PERFORM set_config('libro.sync', 'off', true);

  RETURN public.seed_libro_year_from_template(
    p_user_id, v_template_id, p_residency_year
  );
END;
$$;

GRANT ALL ON FUNCTION public.migrate_libro_year_to_template(uuid, smallint) TO anon;
GRANT ALL ON FUNCTION public.migrate_libro_year_to_template(uuid, smallint) TO authenticated;
GRANT ALL ON FUNCTION public.migrate_libro_year_to_template(uuid, smallint) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Backfill del sello que faltaba.
--
-- Solo se sellan los libros que YA tienen template_id, o sea los migrados desde la
-- app: son los únicos de los que se sabe con certeza que vienen de una plantilla.
--
-- Los libros con template_id NULL se dejan en paz a propósito. Hoy son todos Libro
-- propio: no existe ningún libro sembrado por el trigger, porque ningún residente
-- con libro propio está en un hospital con plantilla publicada. Sellar por
-- coincidencia de nombres podría convertir el libro de alguien en "estructura del
-- tutor" y quitarle el permiso de editarlo.
--
-- El emparejamiento exige que el nombre sea ÚNICO en ese ámbito de la plantilla:
-- con dos nodos del mismo nombre no hay forma de saber cuál es cuál, y sellar el
-- que no toca es peor que no sellar.
-- ---------------------------------------------------------------------------

-- El backfill escribe template_node_id, y para el candado de estructura eso ES
-- un cambio de estructura: sin la escapatoria, sellar un libro ya sellado aborta
-- con "este libro lo define el hospital". Va en un DO para que el ajuste sea
-- local y no se escape del backfill.
DO $backfill$
BEGIN
  PERFORM set_config('libro.sync', 'on', true);

  -- Raíces.
  UPDATE public.libro_node n
  SET template_node_id = tn.id
  FROM public.libro_book b, public.libro_template_node tn
  WHERE n.book_id = b.id
    AND n.template_node_id IS NULL
    AND n.parent_node_id IS NULL
    AND b.template_id IS NOT NULL
    AND tn.template_id = b.template_id
    AND tn.section = b.section
    AND tn.residency_year = LEAST(GREATEST(b.residency_year, 1), 5)::smallint
    AND tn.parent_node_id IS NULL
    AND tn.name = n.name
    AND (
      SELECT count(*)
      FROM public.libro_template_node x
      WHERE x.template_id = b.template_id
        AND x.section = b.section
        AND x.residency_year = LEAST(GREATEST(b.residency_year, 1), 5)::smallint
        AND x.parent_node_id IS NULL
        AND x.name = n.name
    ) = 1;

  -- Hijos, colgando del padre ya sellado.
  UPDATE public.libro_node n
  SET template_node_id = tn.id
  FROM public.libro_node parent, public.libro_template_node tn
  WHERE n.parent_node_id = parent.id
    AND n.template_node_id IS NULL
    AND parent.template_node_id IS NOT NULL
    AND tn.parent_node_id = parent.template_node_id
    AND tn.name = n.name
    AND (
      SELECT count(*)
      FROM public.libro_template_node x
      WHERE x.parent_node_id = parent.template_node_id
        AND x.name = n.name
    ) = 1;

  PERFORM set_config('libro.sync', 'off', true);
END;
$backfill$;

-- ---------------------------------------------------------------------------
-- 5. Un aviso al publicar, no uno por cambio.
--
-- Un tutor que monta la plantilla de R1 mete 6 rotaciones, 30 competencias y 40
-- actividades en una sesión. Una notificación por nodo son 76 pushes, así que el
-- aviso va aquí: cuando la plantilla se publica o se vuelve a guardar publicada.
--
-- El anti-tormenta es la ventana de una hora: guardar cinco veces seguidas mientras
-- se afina la plantilla avisa una vez.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notify_libro_template_published()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_published IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  -- Un UPDATE que no cambia nada (o que solo apaga y enciende el mismo estado) no
  -- es una publicación.
  IF TG_OP = 'UPDATE'
     AND OLD.is_published IS TRUE
     AND OLD.updated_at = NEW.updated_at THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (
    user_id, type, title, body, entity_type, entity_id, data
  )
  SELECT
    u.id,
    'libro_template_updated',
    'Tu tutor ha actualizado tu libro',
    'Echa un vistazo a lo que te pide este año en el Libro del Residente.',
    'libro_template',
    NEW.id,
    jsonb_build_object(
      'destination_section', 'residenceLibrary',
      'residency_year', GREATEST(COALESCE(u.resident_year, 1), 1)
    )
  FROM public.users u
  WHERE coalesce(u.is_resident, false)
    AND u.hospital_id = NEW.hospital_id
    AND u.speciality_id = NEW.speciality_id
    -- Solo si la plantilla cubre SU año: al R4 no le interesa que se haya
    -- publicado el R1.
    AND EXISTS (
      SELECT 1
      FROM public.libro_template_block bl
      WHERE bl.template_id = NEW.id
        AND bl.residency_year =
          LEAST(GREATEST(COALESCE(u.resident_year, 1), 1), 5)::smallint
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.notifications n
      WHERE n.user_id = u.id
        AND n.type = 'libro_template_updated'
        AND n.created_at > now() - interval '1 hour'
    );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_libro_template_published
  ON public.libro_template;

CREATE TRIGGER trigger_notify_libro_template_published
AFTER INSERT OR UPDATE ON public.libro_template
FOR EACH ROW
EXECUTE FUNCTION public.notify_libro_template_published();

GRANT ALL ON FUNCTION public.notify_libro_template_published() TO anon;
GRANT ALL ON FUNCTION public.notify_libro_template_published() TO authenticated;
GRANT ALL ON FUNCTION public.notify_libro_template_published() TO service_role;
