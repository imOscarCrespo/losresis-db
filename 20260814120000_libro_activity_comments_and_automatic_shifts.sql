-- Libro de residente: la actividad asistencial se configura con opciones, no con
-- un desplegable de "tipo", y las guardias dejan de configurarse.
--
-- Contexto (rediseño de agosto 2026, losresis-panel/docs/rediseno-libro-residente.md):
-- cada apartado del libro declara uno de cuatro arquetipos. Esta migración trae
-- lo que necesitan los dos primeros que se implementan:
--
--   * Actividad asistencial (arquetipo "árbol contable"): el tutor ya no elige
--     entre Contador / Participación / Nota / Checklist. Escribe el nombre de la
--     actividad y, si quiere, activa objetivo, nivel de participación y
--     comentarios. El objetivo ya existe (`goal`) y el nivel de participación ya
--     existe (`tracking_mode = 'participation'`); lo que falta es el estado de
--     los comentarios, que son tres y no dos: apagados, opcionales u
--     obligatorios.
--
--   * Guardias (arquetipo "automático"): no necesita nada en base de datos. Las
--     guardias ya viven en agenda_events con event_type = 'shift', y el
--     comentario del residente cabe en agenda_events.notes. Se documenta aquí
--     para que quede constancia de que la ausencia de cambios es deliberada.
--
-- ESTA MIGRACIÓN NO BORRA NADA. Los nodos de plantilla que algún tutor haya
-- creado bajo Guardias se quedan donde están: quitarlos es una acción explícita
-- del tutor desde el panel, no un efecto colateral de desplegar.
--
-- Tampoco se toca `tracking_mode`: los valores 'note' y 'checklist' siguen en el
-- enum y siguen válidos en las filas que ya los usan. El panel deja de
-- ofrecerlos, pero los conserva al guardar en vez de reescribirlos a 'counter',
-- porque reescribir en silencio lo que un tutor configuró es peor que arrastrar
-- dos valores en desuso.

-- ---------------------------------------------------------------------------
-- 1. Estado de los comentarios de una actividad.
--
-- En la plantilla (lo que configura el tutor) y en el libro del residente (lo
-- que se clona al sembrar), porque la app lee el nodo del residente y no la
-- plantilla para decidir qué formulario pinta.
-- ---------------------------------------------------------------------------

ALTER TABLE public.libro_template_node
  ADD COLUMN IF NOT EXISTS comments_mode text NOT NULL DEFAULT 'off';

ALTER TABLE public.libro_template_node
  DROP CONSTRAINT IF EXISTS libro_template_node_comments_mode_check;

ALTER TABLE public.libro_template_node
  ADD CONSTRAINT libro_template_node_comments_mode_check
  CHECK (comments_mode IN ('off', 'optional', 'required'));

COMMENT ON COLUMN public.libro_template_node.comments_mode IS
  'Comentarios del residente al registrar: off | optional | required.';

ALTER TABLE public.libro_node
  ADD COLUMN IF NOT EXISTS comments_mode text NOT NULL DEFAULT 'off';

ALTER TABLE public.libro_node
  DROP CONSTRAINT IF EXISTS libro_node_comments_mode_check;

ALTER TABLE public.libro_node
  ADD CONSTRAINT libro_node_comments_mode_check
  CHECK (comments_mode IN ('off', 'optional', 'required'));

COMMENT ON COLUMN public.libro_node.comments_mode IS
  'Heredado de libro_template_node.comments_mode al sembrar, o del residente si el libro es suyo.';

-- El default 'off' es el comportamiento de hoy: ninguna actividad existente pide
-- comentarios, así que ningún libro cambia de forma al aplicar esta migración.

-- ---------------------------------------------------------------------------
-- 2. La siembra clona comments_mode.
--
-- Mismo cuerpo que 20260729120000 más la columna nueva. Sigue sin sellar
-- template_id ni template_node_id: eso va emparejado con la release de la app
-- que trae la UI de solo lectura (ver 20260801120000 y 20260802120000).
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
  v_template_year smallint;
  v_section public.libro_section_code;
  v_book_id uuid;
  v_node record;
  v_new_id uuid;
  v_parent_new uuid;
  v_map jsonb;
  v_created_any boolean := false;
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

  -- "Solo futuros residentes": si ya existe cualquier libro, no tocar nada.
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
  v_template_year := LEAST(v_year, 5)::smallint;

  FOR v_section IN
    SELECT DISTINCT section
    FROM public.libro_template_node
    WHERE template_id = v_template_id
      AND residency_year = v_template_year
  LOOP
    INSERT INTO public.libro_book (user_id, section, residency_year, status)
    VALUES (p_user_id, v_section, v_year, 'active')
    RETURNING id INTO v_book_id;

    v_map := '{}'::jsonb;

    FOR v_node IN
      WITH RECURSIVE tree AS (
        SELECT tn.id, tn.parent_node_id, tn.name, tn.goal, tn.icon_name,
               tn.color_token, tn.tracking_mode, tn.comments_mode, tn.position,
               tn.created_at, 0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_template_id
          AND tn.section = v_section
          AND tn.residency_year = v_template_year
          AND tn.parent_node_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.comments_mode, c.position,
               c.created_at, t.depth + 1
        FROM public.libro_template_node c
        JOIN tree t ON c.parent_node_id = t.id
        WHERE c.template_id = v_template_id
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
        icon_name, color_token, tracking_mode, comments_mode, position
      )
      VALUES (
        p_user_id, v_book_id, v_section, v_parent_new, v_node.name, v_node.goal,
        v_node.icon_name, v_node.color_token,
        COALESCE(v_node.tracking_mode, 'counter'),
        COALESCE(v_node.comments_mode, 'off'), v_node.position
      )
      RETURNING id INTO v_new_id;

      v_map := v_map || jsonb_build_object(v_node.id::text, v_new_id::text);
      v_created_any := true;
    END LOOP;
  END LOOP;

  IF v_created_any THEN
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

GRANT ALL ON FUNCTION public.apply_libro_template_for_user(uuid) TO anon;
GRANT ALL ON FUNCTION public.apply_libro_template_for_user(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.apply_libro_template_for_user(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. La reconciliación también propaga comments_mode.
--
-- Mismo cuerpo que 20260802120000 más la columna nueva. Sigue sin llamarla
-- nadie; queda lista para cuando se cablee (publicación en el panel y apertura
-- de pantalla en la app).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sync_libro_template_for_user(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_book record;
  v_node record;
  v_parent_new uuid;
  v_template_year smallint;
BEGIN
  PERFORM set_config('libro.sync', 'on', true);

  FOR v_book IN
    SELECT id, section, residency_year, template_id
    FROM public.libro_book
    WHERE user_id = p_user_id
      AND template_id IS NOT NULL
      AND status = 'active'
  LOOP
    v_template_year := LEAST(v_book.residency_year, 5)::smallint;

    FOR v_node IN
      WITH RECURSIVE tree AS (
        SELECT tn.id, tn.parent_node_id, tn.name, tn.goal, tn.icon_name,
               tn.color_token, tn.tracking_mode, tn.comments_mode, tn.position,
               tn.created_at, 0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_book.template_id
          AND tn.section = v_book.section
          AND tn.residency_year = v_template_year
          AND tn.parent_node_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.comments_mode, c.position,
               c.created_at, t.depth + 1
        FROM public.libro_template_node c
        JOIN tree t ON c.parent_node_id = t.id
        WHERE c.template_id = v_book.template_id
          AND c.section = v_book.section
          AND c.residency_year = v_template_year
      )
      SELECT * FROM tree
      ORDER BY depth, position NULLS LAST, created_at
    LOOP
      v_parent_new := NULL;
      IF v_node.parent_node_id IS NOT NULL THEN
        SELECT id INTO v_parent_new
        FROM public.libro_node
        WHERE book_id = v_book.id
          AND template_node_id = v_node.parent_node_id;
      END IF;

      UPDATE public.libro_node
      SET name = v_node.name,
          goal = v_node.goal,
          icon_name = v_node.icon_name,
          color_token = v_node.color_token,
          tracking_mode = COALESCE(v_node.tracking_mode, 'counter'),
          comments_mode = COALESCE(v_node.comments_mode, 'off'),
          position = v_node.position,
          parent_node_id = v_parent_new
      WHERE book_id = v_book.id
        AND template_node_id = v_node.id;

      IF NOT FOUND THEN
        INSERT INTO public.libro_node (
          user_id, book_id, section, parent_node_id, name, goal,
          icon_name, color_token, tracking_mode, comments_mode, position,
          template_node_id
        )
        VALUES (
          p_user_id, v_book.id, v_book.section, v_parent_new, v_node.name,
          v_node.goal, v_node.icon_name, v_node.color_token,
          COALESCE(v_node.tracking_mode, 'counter'),
          COALESCE(v_node.comments_mode, 'off'), v_node.position, v_node.id
        );
      END IF;
    END LOOP;

    DELETE FROM public.libro_node n
    WHERE n.book_id = v_book.id
      AND n.template_node_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.libro_template_node tn
        WHERE tn.id = n.template_node_id
          AND tn.template_id = v_book.template_id
          AND tn.section = v_book.section
          AND tn.residency_year = v_template_year
      )
      AND NOT EXISTS (SELECT 1 FROM public.libro_event e WHERE e.node_id = n.id)
      AND NOT EXISTS (
        SELECT 1 FROM public.libro_entry en
        WHERE en.node_id = n.id AND en.count > 0
      );
  END LOOP;

  PERFORM set_config('libro.sync', 'off', true);
END;
$$;

GRANT ALL ON FUNCTION public.sync_libro_template_for_user(uuid) TO anon;
GRANT ALL ON FUNCTION public.sync_libro_template_for_user(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.sync_libro_template_for_user(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Lo que esta migración NO hace, a propósito.
--
--   a) No borra ni migra los nodos de plantilla de la sección on_call_shifts.
--      El panel deja de ofrecer su edición (el apartado pasa a ser explicativo),
--      pero las filas se quedan y el tutor tiene en el panel un botón explícito
--      para retirarlas. Borrarlas aquí cambiaría lo que reciben los residentes
--      futuros sin que nadie lo haya pedido.
--
--   b) No reescribe tracking_mode 'note' ni 'checklist'. Ver la cabecera.
--
--   c) No añade nada para agenda_events: las guardias del libro se leen de las
--      que ya hay, y el comentario del residente va a agenda_events.notes.
-- ---------------------------------------------------------------------------
