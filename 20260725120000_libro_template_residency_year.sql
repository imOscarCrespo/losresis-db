-- Dimensión de año de residencia en la plantilla del libro.
--
-- Solo la sección clinical_practice usa el año (R1–R5): cada nodo (categoría o
-- actividad) pertenece a un año concreto. El resto de secciones mantienen
-- residency_year NULL (sin año). Al sembrar el libro de un residente, se copian
-- los nodos de clinical_practice de SU año.

-- 1. Columna de año en los nodos de plantilla.
ALTER TABLE public.libro_template_node
  ADD COLUMN IF NOT EXISTS residency_year smallint;

ALTER TABLE public.libro_template_node
  DROP CONSTRAINT IF EXISTS libro_template_node_residency_year_check;

ALTER TABLE public.libro_template_node
  ADD CONSTRAINT libro_template_node_residency_year_check
  CHECK (residency_year IS NULL OR (residency_year BETWEEN 1 AND 5));

-- Backfill: los nodos de práctica clínica existentes se asignan a R1.
UPDATE public.libro_template_node
SET residency_year = 1
WHERE section = 'clinical_practice'
  AND residency_year IS NULL;

CREATE INDEX IF NOT EXISTS libro_template_node_year_idx
ON public.libro_template_node (template_id, section, residency_year);

-- 2. apply_libro_template_for_user: al sembrar clinical_practice, copiar solo
--    los nodos del año del residente. Resto de secciones igual (year NULL).
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
  v_section public.libro_section_code;
  v_book_id uuid;
  v_node record;
  v_new_id uuid;
  v_parent_new uuid;
  v_map jsonb := '{}'::jsonb;
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

  FOR v_section IN
    SELECT DISTINCT section
    FROM public.libro_template_node
    WHERE template_id = v_template_id
  LOOP
    INSERT INTO public.libro_book (user_id, section, residency_year, status)
    VALUES (p_user_id, v_section, v_year, 'active')
    RETURNING id INTO v_book_id;

    -- Recorre el árbol de la sección (padres antes que hijos) y clona cada
    -- nodo, remapeando parent_node_id de la plantilla al nodo recién creado.
    -- En clinical_practice solo se copian los nodos del año del residente.
    FOR v_node IN
      WITH RECURSIVE tree AS (
        SELECT tn.id, tn.parent_node_id, tn.name, tn.goal, tn.icon_name,
               tn.color_token, tn.tracking_mode, tn.position, tn.created_at,
               0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_template_id
          AND tn.section = v_section
          AND tn.parent_node_id IS NULL
          AND (tn.section <> 'clinical_practice'::public.libro_section_code
               OR tn.residency_year = v_year)
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.position, c.created_at,
               t.depth + 1
        FROM public.libro_template_node c
        JOIN tree t ON c.parent_node_id = t.id
        WHERE c.template_id = v_template_id
          AND c.section = v_section
          AND (c.section <> 'clinical_practice'::public.libro_section_code
               OR c.residency_year = v_year)
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
