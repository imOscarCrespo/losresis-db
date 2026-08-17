-- Propagación de la plantilla al libro del residente: el cableado.
--
-- Decisión de producto: el tutor puede editar una plantilla ya publicada y los
-- residentes que ya tienen libro ven las altas (bloques y nodos nuevos) y los
-- cambios (nombre, objetivo, color, orden). Lo que el tutor NO puede hacer es
-- borrar un nodo en el que algún residente ya ha registrado actividad.
--
-- Para eso hacen falta tres cosas que no existían:
--
--   1. Identidad compartida entre el nodo de plantilla y el nodo del residente
--      (libro_node.template_node_id). Sin el vínculo no se puede distinguir "esto
--      es nuevo en la plantilla" de "esto ya lo tiene el residente", ni saber a
--      qué nodo de plantilla pertenece la actividad registrada.
--   2. Un candado sobre el borrado en plantilla cuando hay actividad detrás.
--   3. Una función de reconciliación que aplique las altas y los cambios.
--
-- ESTA MIGRACIÓN ES PURAMENTE ADITIVA: no cambia el comportamiento de nada.
-- Todo lo que añade queda inerte hasta que la siembra empiece a sellar
-- template_id y template_node_id, que es la migración siguiente y va emparejada
-- con la release de la app que trae la UI de solo lectura.
--
-- Requisito previo, ya hecho en el panel: libro_template_node conserva su id
-- entre guardados (antes se borraba y reinsertaba la plantilla entera en cada
-- "Guardar", así que el vínculo del punto 1 habría durado hasta el siguiente
-- guardado del tutor).

-- ---------------------------------------------------------------------------
-- 1. De qué nodo de plantilla viene este nodo del residente.
--
-- ON DELETE SET NULL y no CASCADE a propósito: si un nodo de plantilla
-- desaparece, el nodo del residente y su actividad se quedan. Quitarlo (cuando
-- procede) es trabajo de sync_libro_template_for_user, que sabe mirar si hay
-- actividad registrada. Un CASCADE se llevaría por delante el registro del
-- residente sin preguntar.
-- ---------------------------------------------------------------------------

ALTER TABLE public.libro_node
  ADD COLUMN IF NOT EXISTS template_node_id uuid
  REFERENCES public.libro_template_node(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.libro_node.template_node_id IS
  'Nodo de plantilla del que se clonó. NULL = lo añadió el residente y es suyo.';

CREATE INDEX IF NOT EXISTS libro_node_template_node_idx
ON public.libro_node (template_node_id)
WHERE template_node_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS libro_book_template_idx
ON public.libro_book (template_id)
WHERE template_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. El tutor no puede borrar un nodo con actividad registrada detrás.
--
-- "Actividad" es un libro_event, o un libro_entry con count > 0: un contador a
-- cero no es trabajo del residente, una entrada con cuenta sí.
--
-- El candado cubre también los descendientes sin comprobarlos aquí: borrar una
-- categoría de plantilla cascadea sobre sus actividades (libro_template_node
-- .parent_node_id ON DELETE CASCADE), el borrado en cascada dispara este mismo
-- trigger en cada hija, y la excepción aborta la sentencia entera.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.libro_template_node_block_delete_with_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.libro_node n
    WHERE n.template_node_id = OLD.id
      AND (
        EXISTS (SELECT 1 FROM public.libro_event e WHERE e.node_id = n.id)
        OR EXISTS (
          SELECT 1 FROM public.libro_entry en
          WHERE en.node_id = n.id AND en.count > 0
        )
      )
  ) THEN
    RAISE EXCEPTION
      'No se puede eliminar "%": hay residentes que ya han registrado actividad en este apartado',
      OLD.name
      USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trigger_libro_template_node_activity_guard
  ON public.libro_template_node;

CREATE TRIGGER trigger_libro_template_node_activity_guard
BEFORE DELETE ON public.libro_template_node
FOR EACH ROW
EXECUTE FUNCTION public.libro_template_node_block_delete_with_activity();

GRANT ALL ON FUNCTION public.libro_template_node_block_delete_with_activity() TO anon;
GRANT ALL ON FUNCTION public.libro_template_node_block_delete_with_activity() TO authenticated;
GRANT ALL ON FUNCTION public.libro_template_node_block_delete_with_activity() TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Puerta de salida para la reconciliación servidor.
--
-- trigger_libro_node_structure_locked impide tocar la estructura de un libro de
-- plantilla, y eso incluiría a la propia sincronización, que es justamente quien
-- debe tocarla. El flag es local a la transacción (set_config con is_local =
-- true) y solo lo pone una función SECURITY DEFINER: un cliente de PostgREST no
-- puede fijar GUCs arbitrarios por su cuenta.
--
-- Mismo cuerpo que ya está en producción más el early return del flag.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.libro_node_block_structure_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF COALESCE(current_setting('libro.sync', true), '') = 'on' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.libro_book
    WHERE id = COALESCE(NEW.book_id, OLD.book_id) AND template_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Este libro lo define el hospital: su estructura no se puede modificar';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Reconciliar los libros de un residente con su plantilla.
--
-- Idempotente: se puede llamar en cada apertura de pantalla y cuando el tutor
-- publica. Solo toca nodos que vienen de la plantilla; lo que el residente haya
-- añadido por su cuenta (template_node_id NULL) no se toca nunca.
--
-- Las bajas son conservadoras: un nodo que ya no está en la plantilla se borra
-- solo si no tiene actividad. Si la tiene se queda, aunque el tutor haya
-- conseguido moverlo de año o de sección.
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
    -- El residente puede estar por encima del último año que cubre la plantilla.
    v_template_year := LEAST(v_book.residency_year, 5)::smallint;

    -- Altas y cambios. El recorrido va padres antes que hijos para que el
    -- parent_node_id remapeado ya exista cuando llega la hija.
    FOR v_node IN
      WITH RECURSIVE tree AS (
        SELECT tn.id, tn.parent_node_id, tn.name, tn.goal, tn.icon_name,
               tn.color_token, tn.tracking_mode, tn.position, tn.created_at,
               0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_book.template_id
          AND tn.section = v_book.section
          AND tn.residency_year = v_template_year
          AND tn.parent_node_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.position, c.created_at,
               t.depth + 1
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
          position = v_node.position,
          parent_node_id = v_parent_new
      WHERE book_id = v_book.id
        AND template_node_id = v_node.id;

      IF NOT FOUND THEN
        INSERT INTO public.libro_node (
          user_id, book_id, section, parent_node_id, name, goal,
          icon_name, color_token, tracking_mode, position, template_node_id
        )
        VALUES (
          p_user_id, v_book.id, v_book.section, v_parent_new, v_node.name,
          v_node.goal, v_node.icon_name, v_node.color_token,
          COALESCE(v_node.tracking_mode, 'counter'), v_node.position, v_node.id
        );
      END IF;
    END LOOP;

    -- Bajas sin actividad.
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
-- 5. Lo que NO trae esta migración, a propósito.
--
--   a) La siembra sigue sin sellar template_id ni template_node_id, así que hoy
--      no hay ningún libro marcado: el candado del punto 2 no encuentra
--      actividad que proteger y la sincronización del punto 4 no encuentra
--      libros que reconciliar. Todo queda listo pero inerte.
--
--   b) El índice único libro_book_one_active_per_user_section_idx sigue
--      permitiendo un solo libro activo por (user, section), así que todavía no
--      caben los cinco años a la vez. Relajarlo a (user, section,
--      residency_year) debilita una invariante que hoy sostiene
--      archive_libro_book_and_start_new_year, que elige "el libro activo de esta
--      sección" con un SELECT INTO: si pudiera haber varios, cogería uno
--      cualquiera sin avisar. Las dos cosas van juntas en la migración
--      siguiente, donde esa función pasa a ser consciente del año.
--
--   c) Nadie llama a sync_libro_template_for_user todavía. Los dos disparadores
--      previstos son la publicación desde el panel y la apertura de la pantalla
--      en la app (idempotente, así que arregla libros rezagados sin job).
-- ---------------------------------------------------------------------------
