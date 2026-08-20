-- ---------------------------------------------------------------------------
-- La siembra deja de crear libros de apartados retirados.
--
-- Tutorías, Evaluaciones y Reflexión anual salieron de la plantilla (ADR 0025 del
-- panel) y la app ya no los pinta. Pero 15 de los 66 bloques de plantilla que
-- existen los siguen declarando —no se borró nada al desplegar, a propósito—, así
-- que sembrar de esas plantillas creaba libros que:
--
--   * el residente no ve nunca, porque la app filtra los apartados retirados; y
--   * el tutor SÍ ve en su pantalla de Residentes, que no los filtra.
--
-- O sea, tutor y residente viendo libros distintos. Se corta en la siembra, que es
-- el único sitio donde se decide qué libros nacen.
--
-- Lo ya sembrado no se toca: quitarle un libro a alguien que lo tenga es peor que
-- dejarlo, y la app lo esconde igual.
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
  -- Fuera de la plantilla desde el rediseño de agosto 2026. Son módulos propios de
  -- Docencia, no apartados del Libro.
  v_retired text[] := ARRAY['tutoring_sessions', 'evaluations', 'annual_reflection'];
BEGIN
  IF p_user_id IS NULL OR p_template_id IS NULL OR p_residency_year IS NULL THEN
    RETURN 0;
  END IF;

  v_template_year := LEAST(GREATEST(p_residency_year, 1), 5)::smallint;

  FOR v_section IN
    SELECT section
    FROM public.libro_template_block
    WHERE template_id = p_template_id
      AND residency_year = v_template_year
      AND section::text <> ALL (v_retired)
    UNION
    SELECT DISTINCT section
    FROM public.libro_template_node
    WHERE template_id = p_template_id
      AND residency_year = v_template_year
      AND section::text <> ALL (v_retired)
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

    -- El sello va DESPUÉS de clonar: el candado de estructura rechaza escribir nodos
    -- en un libro que ya tenga template_id.
    UPDATE public.libro_book
    SET template_id = p_template_id
    WHERE id = v_book_id;
  END LOOP;

  RETURN v_created;
END;
$$;
