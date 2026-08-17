-- Libro de residente: arquetipos "itinerario" y "formulario configurable".
--
-- Contexto: losresis-panel/docs/rediseno-libro-residente.md y el documento
-- "retoques 2.0" del equipo. Cada apartado del libro es de uno de cuatro
-- arquetipos; esta migración trae lo que necesitan los dos que faltaban.
--
--   * Itinerario (Rotaciones, Competencias, Reflexión anual): el tutor define
--     una LISTA y el residente completa UNA ficha por elemento. Hacen falta la
--     duración de la rotación, el nivel esperado de la competencia y una tabla
--     donde viva la ficha del residente.
--
--   * Formulario configurable (Cursos, Congresos, Sesiones clínicas,
--     Investigación, Tutorías, Evaluaciones): el tutor no define contenido, solo
--     QUÉ CAMPOS pide. Hacen falta un sitio para esa configuración y un sitio
--     para las filas que el residente crea, que no cuelgan de ningún nodo.
--
-- Además vuelven los adjuntos (certificados, pósters, PDFs de evaluación), que
-- se habían descartado y el documento del equipo recupera.
--
-- ADITIVA: no borra ni reescribe ninguna fila existente. Todas las columnas
-- nuevas llevan default, así que los libros que ya usan los residentes siguen
-- exactamente igual.

-- ---------------------------------------------------------------------------
-- 1. Itinerario: duración de la rotación y nivel esperado de la competencia.
--
-- Dos columnas para la duración y no un interval: el tutor dice "2 meses", no
-- "60 días", y la unidad es información suya, no una equivalencia.
-- ---------------------------------------------------------------------------

ALTER TABLE public.libro_template_node
  ADD COLUMN IF NOT EXISTS duration_amount integer,
  ADD COLUMN IF NOT EXISTS duration_unit text,
  ADD COLUMN IF NOT EXISTS center text,
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS expected_level text;

ALTER TABLE public.libro_template_node
  DROP CONSTRAINT IF EXISTS libro_template_node_duration_check;

ALTER TABLE public.libro_template_node
  ADD CONSTRAINT libro_template_node_duration_check
  CHECK (
    (duration_amount IS NULL OR duration_amount > 0)
    AND (duration_unit IS NULL OR duration_unit IN ('weeks', 'months'))
  );

-- La escala de competencias es común a todo LosResis: el tutor no crea la suya,
-- solo dice qué nivel espera para ese año.
ALTER TABLE public.libro_template_node
  DROP CONSTRAINT IF EXISTS libro_template_node_expected_level_check;

ALTER TABLE public.libro_template_node
  ADD CONSTRAINT libro_template_node_expected_level_check
  CHECK (
    expected_level IS NULL
    OR expected_level IN ('pending', 'acquiring', 'acquired', 'autonomous')
  );

COMMENT ON COLUMN public.libro_template_node.duration_amount IS
  'Rotaciones: duración prevista, en la unidad de duration_unit.';
COMMENT ON COLUMN public.libro_template_node.center IS
  'Rotaciones: centro donde se realiza. Opcional (puede ser el propio hospital).';
COMMENT ON COLUMN public.libro_template_node.description IS
  'Competencias: descripción opcional de lo que se espera del residente.';
COMMENT ON COLUMN public.libro_template_node.expected_level IS
  'Competencias: nivel esperado para ese año. pending|acquiring|acquired|autonomous.';

-- Las mismas columnas en el libro del residente, porque la app lee su nodo y no
-- la plantilla.
ALTER TABLE public.libro_node
  ADD COLUMN IF NOT EXISTS duration_amount integer,
  ADD COLUMN IF NOT EXISTS duration_unit text,
  ADD COLUMN IF NOT EXISTS center text,
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS expected_level text;

-- ---------------------------------------------------------------------------
-- 2. Formulario configurable: qué campos pide el tutor.
--
-- Va en el bloque y no clonado al libro: la app ya lee libro_template_block en
-- runtime (getLibroTemplateOutline), así que un cambio del tutor llega solo, sin
-- pasar por la reconciliación y sin duplicar la verdad.
-- ---------------------------------------------------------------------------

ALTER TABLE public.libro_template_block
  ADD COLUMN IF NOT EXISTS config jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.libro_template_block.config IS
  'Configuración del apartado: qué campos pide al residente. Forma según section. {} = los de por defecto.';

-- ---------------------------------------------------------------------------
-- 3. Itinerario: la ficha única del residente.
--
-- Un elemento de itinerario se completa UNA vez, no N: libro_entry no sirve
-- porque su semántica es "un registro más" y no garantiza unicidad por nodo.
--
-- status sin enum a propósito: el vocabulario depende de la sección.
--   rotations          pending | in_progress | completed
--   competencies       pending | acquiring | acquired | autonomous
--   annual_reflection  pending | completed
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.libro_node_progress (
  node_id uuid PRIMARY KEY REFERENCES public.libro_node(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending',
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  completed_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS libro_node_progress_user_idx
ON public.libro_node_progress (user_id);

CREATE OR REPLACE FUNCTION public.update_libro_node_progress_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_libro_node_progress_updated_at
  ON public.libro_node_progress;

CREATE TRIGGER trigger_update_libro_node_progress_updated_at
BEFORE UPDATE ON public.libro_node_progress
FOR EACH ROW
EXECUTE FUNCTION public.update_libro_node_progress_updated_at();

ALTER TABLE public.libro_node_progress ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_libro_node_progress ON public.libro_node_progress;
CREATE POLICY allow_all_libro_node_progress
ON public.libro_node_progress
USING (true)
WITH CHECK (true);

GRANT ALL ON TABLE public.libro_node_progress TO anon;
GRANT ALL ON TABLE public.libro_node_progress TO authenticated;
GRANT ALL ON TABLE public.libro_node_progress TO service_role;

GRANT ALL ON FUNCTION public.update_libro_node_progress_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_libro_node_progress_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_libro_node_progress_updated_at() TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Formulario configurable: registros que no cuelgan de un nodo.
--
-- El tutor no sabe a qué congresos irá el residente, así que esas filas no
-- corresponden a ningún nodo de plantilla: cuelgan del libro.
-- ---------------------------------------------------------------------------

ALTER TABLE public.libro_entry
  ADD COLUMN IF NOT EXISTS book_id uuid REFERENCES public.libro_book(id) ON DELETE CASCADE;

ALTER TABLE public.libro_entry
  ALTER COLUMN node_id DROP NOT NULL;

ALTER TABLE public.libro_entry
  DROP CONSTRAINT IF EXISTS libro_entry_belongs_to_node_or_book;

ALTER TABLE public.libro_entry
  ADD CONSTRAINT libro_entry_belongs_to_node_or_book
  CHECK (node_id IS NOT NULL OR book_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS libro_entry_book_idx
ON public.libro_entry (book_id)
WHERE book_id IS NOT NULL;

COMMENT ON COLUMN public.libro_entry.book_id IS
  'Registro que pertenece al apartado y no a un nodo (Cursos, Congresos, Sesiones, Investigación, Tutorías, Evaluaciones).';

-- ---------------------------------------------------------------------------
-- 5. Adjuntos.
--
-- Privado y por usuario en la ruta: <user_id>/<resto>. El tutor no lee del
-- bucket directamente; para que pueda ver los documentos de sus residentes hace
-- falta una política adicional que aún no se define aquí (decisión pendiente).
-- ---------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'libro-attachments',
  'libro-attachments',
  false,
  10485760,
  ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
  SET file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS libro_attachments_owner_read ON storage.objects;
CREATE POLICY libro_attachments_owner_read
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'libro-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS libro_attachments_owner_write ON storage.objects;
CREATE POLICY libro_attachments_owner_write
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'libro-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS libro_attachments_owner_delete ON storage.objects;
CREATE POLICY libro_attachments_owner_delete
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'libro-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- ---------------------------------------------------------------------------
-- 6. La siembra y la reconciliación llevan las columnas nuevas.
--
-- Mismo cuerpo que 20260814120000 más duration_*, center, description y
-- expected_level. Sigue sin sellar template_id ni template_node_id.
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

  -- Los apartados de formulario configurable no tienen nodos, así que se crea
  -- libro_book para todo bloque declarado del año, no solo para los que tienen
  -- contenido: si no, el residente no tendría dónde colgar sus registros.
  FOR v_section IN
    SELECT section
    FROM public.libro_template_block
    WHERE template_id = v_template_id
      AND residency_year = v_template_year
    UNION
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
               tn.color_token, tn.tracking_mode, tn.comments_mode,
               tn.duration_amount, tn.duration_unit, tn.center, tn.description,
               tn.expected_level, tn.position, tn.created_at, 0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_template_id
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
        icon_name, color_token, tracking_mode, comments_mode,
        duration_amount, duration_unit, center, description, expected_level,
        position
      )
      VALUES (
        p_user_id, v_book_id, v_section, v_parent_new, v_node.name, v_node.goal,
        v_node.icon_name, v_node.color_token,
        COALESCE(v_node.tracking_mode, 'counter'),
        COALESCE(v_node.comments_mode, 'off'),
        v_node.duration_amount, v_node.duration_unit, v_node.center,
        v_node.description, v_node.expected_level, v_node.position
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
               tn.color_token, tn.tracking_mode, tn.comments_mode,
               tn.duration_amount, tn.duration_unit, tn.center, tn.description,
               tn.expected_level, tn.position, tn.created_at, 0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_book.template_id
          AND tn.section = v_book.section
          AND tn.residency_year = v_template_year
          AND tn.parent_node_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.comments_mode,
               c.duration_amount, c.duration_unit, c.center, c.description,
               c.expected_level, c.position, c.created_at, t.depth + 1
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
          duration_amount = v_node.duration_amount,
          duration_unit = v_node.duration_unit,
          center = v_node.center,
          description = v_node.description,
          expected_level = v_node.expected_level,
          position = v_node.position,
          parent_node_id = v_parent_new
      WHERE book_id = v_book.id
        AND template_node_id = v_node.id;

      IF NOT FOUND THEN
        INSERT INTO public.libro_node (
          user_id, book_id, section, parent_node_id, name, goal,
          icon_name, color_token, tracking_mode, comments_mode,
          duration_amount, duration_unit, center, description, expected_level,
          position, template_node_id
        )
        VALUES (
          p_user_id, v_book.id, v_book.section, v_parent_new, v_node.name,
          v_node.goal, v_node.icon_name, v_node.color_token,
          COALESCE(v_node.tracking_mode, 'counter'),
          COALESCE(v_node.comments_mode, 'off'),
          v_node.duration_amount, v_node.duration_unit, v_node.center,
          v_node.description, v_node.expected_level, v_node.position, v_node.id
        );
      END IF;
    END LOOP;

    -- Bajas sin actividad. libro_node_progress cuenta como actividad: una
    -- competencia que el residente ya ha situado en un nivel no se borra.
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
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.libro_node_progress np
        WHERE np.node_id = n.id AND np.status <> 'pending'
      );
  END LOOP;

  PERFORM set_config('libro.sync', 'off', true);
END;
$$;

GRANT ALL ON FUNCTION public.sync_libro_template_for_user(uuid) TO anon;
GRANT ALL ON FUNCTION public.sync_libro_template_for_user(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.sync_libro_template_for_user(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. El candado de borrado aprende a mirar la ficha del residente.
--
-- "El tutor no puede borrar algo con actividad detrás" tiene que incluir el
-- arquetipo itinerario: una competencia que el residente ya ha movido de
-- "pendiente", o una rotación que ya ha empezado, es trabajo suyo.
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
        OR EXISTS (
          SELECT 1 FROM public.libro_node_progress np
          WHERE np.node_id = n.id AND np.status <> 'pending'
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

GRANT ALL ON FUNCTION public.libro_template_node_block_delete_with_activity() TO anon;
GRANT ALL ON FUNCTION public.libro_template_node_block_delete_with_activity() TO authenticated;
GRANT ALL ON FUNCTION public.libro_template_node_block_delete_with_activity() TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Lo que esta migración NO hace, a propósito.
--
--   a) No sella template_id ni template_node_id en la siembra. Sigue emparejado
--      con la release de la app que trae la UI de solo lectura (20260801120000).
--
--   b) No da al tutor acceso de lectura al bucket de adjuntos. Que Docencia
--      pueda abrir el certificado de un residente es una decisión de producto
--      con su propia política; hasta entonces el adjunto es del residente.
--
--   c) No toca agenda_events para las tutorías. La integración con la Agenda y
--      el registro compartido tutor-residente van en su propia migración.
-- ---------------------------------------------------------------------------
