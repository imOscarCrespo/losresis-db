-- Libro de residente: catálogo de bloques, un juego por año y registro por
-- nivel de participación.
--
-- El tutor ya no describe el libro con una frase para que lo genere un modelo:
-- lo monta escogiendo tipos de bloque de un catálogo cerrado. Tres cambios:
--
--   1. El catálogo de bloques crece de 5 a 11 tipos (libro_section_code).
--   2. Cada año de residencia (R1–R5) tiene su propio juego de bloques, así que
--      residency_year pasa a ser obligatorio en los nodos de plantilla y el
--      filtro por año se aplica a TODAS las secciones, no solo a la práctica
--      clínica.
--   3. Un procedimiento puede registrarse desglosado por nivel de
--      participación (Observó / Ayudó / Realizó): nuevo tracking_mode.
--
-- Además se crea libro_template_block: hasta ahora un bloque no era una fila,
-- era solo el valor `section` de sus categorías, así que un bloque vacío no se
-- podía guardar ni se podía ordenar el rail.

-- ---------------------------------------------------------------------------
-- 1. Tipos de bloque nuevos del catálogo.
--
-- Los valores nuevos NO se usan en DML en esta migración (ni en literales
-- casteados): Postgres prohíbe usar un valor de enum recién añadido en la misma
-- transacción que lo crea.
-- ---------------------------------------------------------------------------

ALTER TYPE public.libro_section_code ADD VALUE IF NOT EXISTS 'rotations';
ALTER TYPE public.libro_section_code ADD VALUE IF NOT EXISTS 'on_call_shifts';
ALTER TYPE public.libro_section_code ADD VALUE IF NOT EXISTS 'competencies';
ALTER TYPE public.libro_section_code ADD VALUE IF NOT EXISTS 'tutoring_sessions';
ALTER TYPE public.libro_section_code ADD VALUE IF NOT EXISTS 'evaluations';
ALTER TYPE public.libro_section_code ADD VALUE IF NOT EXISTS 'annual_reflection';

-- ---------------------------------------------------------------------------
-- 2. Registro por nivel de participación (Observó / Ayudó / Realizó).
-- ---------------------------------------------------------------------------

ALTER TYPE public.libro_node_tracking_mode ADD VALUE IF NOT EXISTS 'participation';

-- ---------------------------------------------------------------------------
-- 3. Todos los nodos de plantilla pertenecen a un año.
--
-- Hasta ahora solo clinical_practice usaba el año; el resto de secciones tenían
-- residency_year NULL y se sembraban a cualquier residente. Para no quitarle
-- contenido a nadie, esas secciones se replican en los cinco años en vez de
-- quedarse solo en R1.
-- ---------------------------------------------------------------------------

UPDATE public.libro_template_node
SET residency_year = 1
WHERE residency_year IS NULL;

DO $$
DECLARE
  v_group record;
  v_year smallint;
  v_node record;
  v_map jsonb;
  v_parent uuid;
  v_new_id uuid;
BEGIN
  FOR v_group IN
    SELECT DISTINCT template_id, section
    FROM public.libro_template_node
    WHERE section <> 'clinical_practice'::public.libro_section_code
      AND residency_year = 1
  LOOP
    FOR v_year IN 2..5 LOOP
      -- Si el año ya tiene contenido propio en esa sección, no se toca.
      IF EXISTS (
        SELECT 1
        FROM public.libro_template_node
        WHERE template_id = v_group.template_id
          AND section = v_group.section
          AND residency_year = v_year
      ) THEN
        CONTINUE;
      END IF;

      v_map := '{}'::jsonb;

      FOR v_node IN
        WITH RECURSIVE tree AS (
          SELECT n.*, 0 AS depth
          FROM public.libro_template_node n
          WHERE n.template_id = v_group.template_id
            AND n.section = v_group.section
            AND n.residency_year = 1
            AND n.parent_node_id IS NULL
          UNION ALL
          SELECT c.*, t.depth + 1
          FROM public.libro_template_node c
          JOIN tree t ON c.parent_node_id = t.id
          WHERE c.template_id = v_group.template_id
            AND c.section = v_group.section
            AND c.residency_year = 1
        )
        SELECT * FROM tree
        ORDER BY depth, position NULLS LAST, created_at
      LOOP
        v_parent := NULL;
        IF v_node.parent_node_id IS NOT NULL THEN
          v_parent := (v_map ->> v_node.parent_node_id::text)::uuid;
        END IF;

        INSERT INTO public.libro_template_node (
          template_id, parent_node_id, section, residency_year, name, goal,
          icon_name, color_token, tracking_mode, position
        )
        VALUES (
          v_group.template_id, v_parent, v_group.section, v_year, v_node.name,
          v_node.goal, v_node.icon_name, v_node.color_token,
          v_node.tracking_mode, v_node.position
        )
        RETURNING id INTO v_new_id;

        v_map := v_map || jsonb_build_object(v_node.id::text, v_new_id::text);
      END LOOP;
    END LOOP;
  END LOOP;
END
$$;

ALTER TABLE public.libro_template_node
  DROP CONSTRAINT IF EXISTS libro_template_node_residency_year_check;

ALTER TABLE public.libro_template_node
  ALTER COLUMN residency_year SET NOT NULL;

ALTER TABLE public.libro_template_node
  ADD CONSTRAINT libro_template_node_residency_year_check
  CHECK (residency_year BETWEEN 1 AND 5);

-- ---------------------------------------------------------------------------
-- 4. El bloque es una fila, no solo el `section` de sus categorías.
--
-- Permite guardar un bloque que el tutor ha añadido pero todavía no ha rellenado
-- y ordenar el rail (position).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.libro_template_block (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  template_id uuid NOT NULL REFERENCES public.libro_template(id) ON DELETE CASCADE,
  section public.libro_section_code NOT NULL,
  residency_year smallint NOT NULL CHECK (residency_year BETWEEN 1 AND 5),
  position integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Un tipo de bloque aparece una sola vez por plantilla y año.
CREATE UNIQUE INDEX IF NOT EXISTS libro_template_block_unique_idx
ON public.libro_template_block (template_id, section, residency_year);

CREATE INDEX IF NOT EXISTS libro_template_block_template_year_idx
ON public.libro_template_block (template_id, residency_year, position);

-- Backfill: cada combinación sección+año que ya tenga nodos se convierte en un
-- bloque, respetando el orden del catálogo original.
INSERT INTO public.libro_template_block (template_id, section, residency_year, position)
SELECT DISTINCT n.template_id, n.section, n.residency_year,
       CASE n.section
         WHEN 'clinical_practice'::public.libro_section_code THEN 0
         WHEN 'clinical_sessions'::public.libro_section_code THEN 1
         WHEN 'research_work'::public.libro_section_code THEN 2
         WHEN 'congress_attendance'::public.libro_section_code THEN 3
         WHEN 'workshop_attendance'::public.libro_section_code THEN 4
         ELSE 5
       END
FROM public.libro_template_node n
ON CONFLICT (template_id, section, residency_year) DO NOTHING;

ALTER TABLE public.libro_template_block ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_libro_template_block ON public.libro_template_block;
CREATE POLICY allow_all_libro_template_block
ON public.libro_template_block
USING (true)
WITH CHECK (true);

GRANT ALL ON TABLE public.libro_template_block TO anon;
GRANT ALL ON TABLE public.libro_template_block TO authenticated;
GRANT ALL ON TABLE public.libro_template_block TO service_role;

-- ---------------------------------------------------------------------------
-- 5. apply_libro_template_for_user: el filtro por año vale para todas las
--    secciones, y solo se crea libro para las secciones que tienen contenido en
--    el año del residente.
--
--    El residente puede estar en un año por encima del último que la plantilla
--    cubre (libro_book admite hasta R8): en ese caso el libro se crea con SU año
--    pero se siembra con la estructura del último año de plantilla (R5), para no
--    dejarle un libro vacío.
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

    -- Recorre el árbol de la sección en ese año (padres antes que hijos) y clona
    -- cada nodo, remapeando parent_node_id de la plantilla al nodo recién creado.
    v_map := '{}'::jsonb;

    FOR v_node IN
      WITH RECURSIVE tree AS (
        SELECT tn.id, tn.parent_node_id, tn.name, tn.goal, tn.icon_name,
               tn.color_token, tn.tracking_mode, tn.position, tn.created_at,
               0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_template_id
          AND tn.section = v_section
          AND tn.residency_year = v_template_year
          AND tn.parent_node_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.position, c.created_at,
               t.depth + 1
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
        icon_name, color_token, tracking_mode, position
      )
      VALUES (
        p_user_id, v_book_id, v_section, v_parent_new, v_node.name, v_node.goal,
        v_node.icon_name, v_node.color_token,
        COALESCE(v_node.tracking_mode, 'counter'), v_node.position
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
