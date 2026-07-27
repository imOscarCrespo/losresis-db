-- Libro de residente: plantillas por hospital + especialidad.
--
-- Un tutor (desde el panel de organizaciones) diseña la estructura del libro
-- de residente para su hospital y especialidad. Cuando un NUEVO residente de
-- ese hospital+especialidad entra en la plataforma, se le crea automáticamente
-- la misma estructura de libro (libro_book + libro_node por sección), sin tocar
-- los residentes que ya tienen un libro creado.

-- 1. Tabla de plantilla (una por hospital + especialidad).
CREATE TABLE IF NOT EXISTS public.libro_template (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  hospital_id uuid NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
  speciality_id uuid NOT NULL REFERENCES public.specialities(id) ON DELETE CASCADE,
  -- uid (auth) del tutor que la creó. Sin FK a public.users porque el autor
  -- puede ser una cuenta de organización que no existe en public.users.
  created_by uuid,
  is_published boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS libro_template_unique_hospital_speciality_idx
ON public.libro_template (hospital_id, speciality_id);

-- 2. Nodos de la plantilla (jerarquía categoría -> actividad, igual que libro_node).
CREATE TABLE IF NOT EXISTS public.libro_template_node (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  template_id uuid NOT NULL REFERENCES public.libro_template(id) ON DELETE CASCADE,
  parent_node_id uuid REFERENCES public.libro_template_node(id) ON DELETE CASCADE,
  section public.libro_section_code NOT NULL,
  name text NOT NULL,
  goal integer,
  icon_name text,
  color_token text,
  tracking_mode public.libro_node_tracking_mode NOT NULL DEFAULT 'counter',
  position integer,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS libro_template_node_template_id_idx
ON public.libro_template_node (template_id);

CREATE INDEX IF NOT EXISTS libro_template_node_parent_idx
ON public.libro_template_node (parent_node_id);

-- 3. updated_at trigger para libro_template.
CREATE OR REPLACE FUNCTION public.update_libro_template_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_libro_template_updated_at ON public.libro_template;

CREATE TRIGGER trigger_update_libro_template_updated_at
BEFORE UPDATE ON public.libro_template
FOR EACH ROW
EXECUTE FUNCTION public.update_libro_template_updated_at();

-- 4. RLS permisiva (mismo patrón que el resto de tablas del libro).
ALTER TABLE public.libro_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.libro_template_node ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_libro_template ON public.libro_template;
CREATE POLICY allow_all_libro_template
ON public.libro_template
USING (true)
WITH CHECK (true);

DROP POLICY IF EXISTS allow_all_libro_template_node ON public.libro_template_node;
CREATE POLICY allow_all_libro_template_node
ON public.libro_template_node
USING (true)
WITH CHECK (true);

GRANT ALL ON TABLE public.libro_template TO anon;
GRANT ALL ON TABLE public.libro_template TO authenticated;
GRANT ALL ON TABLE public.libro_template TO service_role;

GRANT ALL ON TABLE public.libro_template_node TO anon;
GRANT ALL ON TABLE public.libro_template_node TO authenticated;
GRANT ALL ON TABLE public.libro_template_node TO service_role;

GRANT ALL ON FUNCTION public.update_libro_template_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_libro_template_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_libro_template_updated_at() TO service_role;

-- 5. Aplica la plantilla publicada del hospital+especialidad del usuario a su
--    libro. Solo actúa sobre residentes que aún NO tienen ningún libro creado
--    (futuros residentes); nunca sobrescribe estructuras existentes.
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
    FOR v_node IN
      WITH RECURSIVE tree AS (
        SELECT tn.id, tn.parent_node_id, tn.name, tn.goal, tn.icon_name,
               tn.color_token, tn.tracking_mode, tn.position, tn.created_at,
               0 AS depth
        FROM public.libro_template_node tn
        WHERE tn.template_id = v_template_id
          AND tn.section = v_section
          AND tn.parent_node_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_node_id, c.name, c.goal, c.icon_name,
               c.color_token, c.tracking_mode, c.position, c.created_at,
               t.depth + 1
        FROM public.libro_template_node c
        JOIN tree t ON c.parent_node_id = t.id
        WHERE c.template_id = v_template_id
          AND c.section = v_section
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

  -- Marca el onboarding del libro como completado para que la app muestre la
  -- estructura ya creada en vez del asistente de onboarding.
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

-- 6. Trigger sobre users: al crear/actualizar un residente con hospital y
--    especialidad, intenta aplicar la plantilla. Es idempotente (no hace nada
--    si ya tiene libro) y nunca rompe la escritura sobre users.
CREATE OR REPLACE FUNCTION public.trg_apply_libro_template_on_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM public.apply_libro_template_for_user(NEW.id);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'apply_libro_template_for_user failed for user %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_apply_libro_template ON public.users;

CREATE TRIGGER trigger_apply_libro_template
AFTER INSERT OR UPDATE OF hospital_id, speciality_id, is_resident, resident_year
ON public.users
FOR EACH ROW
WHEN (
  NEW.is_resident IS TRUE
  AND NEW.hospital_id IS NOT NULL
  AND NEW.speciality_id IS NOT NULL
)
EXECUTE FUNCTION public.trg_apply_libro_template_on_user();

GRANT ALL ON FUNCTION public.trg_apply_libro_template_on_user() TO anon;
GRANT ALL ON FUNCTION public.trg_apply_libro_template_on_user() TO authenticated;
GRANT ALL ON FUNCTION public.trg_apply_libro_template_on_user() TO service_role;
