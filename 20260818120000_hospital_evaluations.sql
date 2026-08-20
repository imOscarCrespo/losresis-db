-- Evaluaciones oficiales del residente, como módulo propio de Docencia.
--
-- Sale de la plantilla del Libro del Residente (documento "Modificaciones parte
-- II", puntos 6 y 7). Aquí el tutor crea la evaluación, la completa, la finaliza
-- y consulta el histórico de cada residente.
--
-- Decisiones de modelado:
--
--   * Tres estados persistidos: draft, pending_signature y finished. "Pendiente"
--     (la que ya venció sin cerrar) se deriva de la fecha, igual que en Tutorías:
--     un estado derivado no puede desincronizarse y no necesita job.
--
--   * La rotación evaluada apunta al nodo del Libro del Residente
--     (libro_node.id) en vez de repetir el nombre del servicio a mano. Es lo que
--     pide el documento: "permitir seleccionar entre las rotaciones ya existentes
--     en el Libro del Residente".
--
--   * Las competencias revisadas en la evaluación NO se copian: se escriben en
--     libro_node_progress, que es donde vive el nivel del residente. Así el
--     apartado Competencias de su Libro queda actualizado sin duplicar trabajo.

INSERT INTO public.notification_types (code, description)
VALUES ('evaluation_shared', 'Tu tutor ha compartido una evaluación')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.hospital_evaluation (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  hospital_id uuid NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
  resident_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  tutor_account_id uuid,
  tutor_name text,
  speciality_id uuid REFERENCES public.specialities(id) ON DELETE SET NULL,
  residency_year smallint,
  evaluation_type text NOT NULL DEFAULT 'rotacion',
  /** Etiqueta del periodo evaluado, tal como la escribe el tutor. */
  period_label text,
  period_start date,
  period_end date,
  /** La rotación del Libro del Residente que se evalúa, si aplica. */
  rotation_node_id uuid REFERENCES public.libro_node(id) ON DELETE SET NULL,
  evaluation_date date NOT NULL DEFAULT CURRENT_DATE,
  status text NOT NULL DEFAULT 'draft',
  competencies_reviewed text,
  goals_achieved text,
  improvements text,
  tutor_comments text,
  overall_rating text,
  shared_at timestamp with time zone,
  finished_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT hospital_evaluation_status_check
    CHECK (status IN ('draft', 'pending_signature', 'finished')),
  CONSTRAINT hospital_evaluation_type_check
    CHECK (evaluation_type IN ('rotacion', 'semestral', 'anual', 'extraordinaria', 'otra')),
  CONSTRAINT hospital_evaluation_year_check
    CHECK (residency_year IS NULL OR residency_year BETWEEN 1 AND 8),
  CONSTRAINT hospital_evaluation_finished_needs_date
    CHECK (status <> 'finished' OR finished_at IS NOT NULL),
  CONSTRAINT hospital_evaluation_period_range
    CHECK (period_end IS NULL OR period_start IS NULL OR period_end >= period_start)
);

CREATE INDEX IF NOT EXISTS hospital_evaluation_hospital_idx
  ON public.hospital_evaluation (hospital_id, evaluation_date DESC);
CREATE INDEX IF NOT EXISTS hospital_evaluation_resident_idx
  ON public.hospital_evaluation (resident_user_id, evaluation_date DESC);
CREATE INDEX IF NOT EXISTS hospital_evaluation_open_idx
  ON public.hospital_evaluation (hospital_id, evaluation_date)
  WHERE status <> 'finished';

CREATE OR REPLACE FUNCTION public.update_hospital_evaluation_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_hospital_evaluation_updated_at
  ON public.hospital_evaluation;

CREATE TRIGGER trigger_update_hospital_evaluation_updated_at
BEFORE UPDATE ON public.hospital_evaluation
FOR EACH ROW
EXECUTE FUNCTION public.update_hospital_evaluation_updated_at();

ALTER TABLE public.hospital_evaluation ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_hospital_evaluation ON public.hospital_evaluation;
CREATE POLICY allow_all_hospital_evaluation
  ON public.hospital_evaluation USING (true) WITH CHECK (true);

GRANT ALL ON TABLE public.hospital_evaluation TO anon;
GRANT ALL ON TABLE public.hospital_evaluation TO authenticated;
GRANT ALL ON TABLE public.hospital_evaluation TO service_role;

GRANT ALL ON FUNCTION public.update_hospital_evaluation_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_hospital_evaluation_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_hospital_evaluation_updated_at() TO service_role;

CREATE TABLE IF NOT EXISTS public.hospital_evaluation_attachment (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  evaluation_id uuid NOT NULL
    REFERENCES public.hospital_evaluation(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  file_name text NOT NULL,
  uploaded_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS hospital_evaluation_attachment_idx
  ON public.hospital_evaluation_attachment (evaluation_id);

ALTER TABLE public.hospital_evaluation_attachment ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_hospital_evaluation_attachment
  ON public.hospital_evaluation_attachment;
CREATE POLICY allow_all_hospital_evaluation_attachment
  ON public.hospital_evaluation_attachment USING (true) WITH CHECK (true);

GRANT ALL ON TABLE public.hospital_evaluation_attachment TO anon;
GRANT ALL ON TABLE public.hospital_evaluation_attachment TO authenticated;
GRANT ALL ON TABLE public.hospital_evaluation_attachment TO service_role;

-- ---------------------------------------------------------------------------
-- Competencias revisadas durante la evaluación.
--
-- Guarda el nivel que el tutor pone en esta evaluación (histórico de esa
-- valoración) y además lo escribe en libro_node_progress, que es el estado
-- actual de la competencia en el Libro del Residente.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.hospital_evaluation_competency (
  evaluation_id uuid NOT NULL
    REFERENCES public.hospital_evaluation(id) ON DELETE CASCADE,
  /** El nodo de competencia del Libro del Residente. */
  node_id uuid NOT NULL REFERENCES public.libro_node(id) ON DELETE CASCADE,
  level text NOT NULL,
  comment text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  PRIMARY KEY (evaluation_id, node_id),
  CONSTRAINT hospital_evaluation_competency_level_check
    CHECK (level IN ('pending', 'acquiring', 'acquired', 'autonomous'))
);

ALTER TABLE public.hospital_evaluation_competency ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_hospital_evaluation_competency
  ON public.hospital_evaluation_competency;
CREATE POLICY allow_all_hospital_evaluation_competency
  ON public.hospital_evaluation_competency USING (true) WITH CHECK (true);

GRANT ALL ON TABLE public.hospital_evaluation_competency TO anon;
GRANT ALL ON TABLE public.hospital_evaluation_competency TO authenticated;
GRANT ALL ON TABLE public.hospital_evaluation_competency TO service_role;

-- ---------------------------------------------------------------------------
-- Anotar una competencia desde la evaluación y propagarla al Libro.
--
-- Una sola función para que no puedan quedar desalineados el histórico de la
-- evaluación y el estado del Libro, que es justo lo que el documento pide evitar.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_evaluation_competency(
  p_evaluation_id uuid,
  p_node_id uuid,
  p_level text,
  p_comment text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT user_id INTO v_user_id FROM public.libro_node WHERE id = p_node_id;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'La competencia % no existe', p_node_id;
  END IF;

  INSERT INTO public.hospital_evaluation_competency (
    evaluation_id, node_id, level, comment
  )
  VALUES (p_evaluation_id, p_node_id, p_level, p_comment)
  ON CONFLICT (evaluation_id, node_id) DO UPDATE
    SET level = EXCLUDED.level,
        comment = EXCLUDED.comment;

  -- El estado actual de la competencia en el Libro del Residente.
  INSERT INTO public.libro_node_progress (node_id, user_id, status, payload)
  VALUES (
    p_node_id, v_user_id, p_level,
    jsonb_build_object('comment', p_comment, 'evaluation_id', p_evaluation_id)
  )
  ON CONFLICT (node_id) DO UPDATE
    SET status = EXCLUDED.status,
        payload = public.libro_node_progress.payload || EXCLUDED.payload,
        completed_at = CASE
          WHEN EXCLUDED.status IN ('acquired', 'autonomous') THEN now()
          ELSE public.libro_node_progress.completed_at
        END,
        updated_at = now();
END;
$$;

GRANT ALL ON FUNCTION public.set_evaluation_competency(uuid, uuid, text, text) TO anon;
GRANT ALL ON FUNCTION public.set_evaluation_competency(uuid, uuid, text, text) TO authenticated;
GRANT ALL ON FUNCTION public.set_evaluation_competency(uuid, uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Finalizar: bloquea la evaluación y, si se comparte, avisa al residente.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.finish_hospital_evaluation(
  p_evaluation_id uuid,
  p_share_with_resident boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_evaluation record;
  v_ya_compartida boolean;
BEGIN
  SELECT * INTO v_evaluation
  FROM public.hospital_evaluation WHERE id = p_evaluation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La evaluación % no existe', p_evaluation_id;
  END IF;

  v_ya_compartida := v_evaluation.shared_at IS NOT NULL;

  UPDATE public.hospital_evaluation
  SET status = 'finished',
      finished_at = COALESCE(finished_at, now()),
      shared_at = CASE
        WHEN p_share_with_resident THEN COALESCE(shared_at, now())
        ELSE NULL
      END
  WHERE id = p_evaluation_id;

  IF p_share_with_resident AND NOT v_ya_compartida THEN
    INSERT INTO public.notifications (
      user_id, type, title, body, entity_type, entity_id, data
    )
    VALUES (
      v_evaluation.resident_user_id, 'evaluation_shared',
      'Evaluación disponible',
      'Tu tutor ha finalizado tu evaluación del ' ||
        to_char(v_evaluation.evaluation_date, 'DD/MM/YYYY') ||
        '. Ya puedes consultarla.',
      'hospital_evaluation', p_evaluation_id,
      jsonb_build_object('evaluation_id', p_evaluation_id)
    );
  END IF;
END;
$$;

GRANT ALL ON FUNCTION public.finish_hospital_evaluation(uuid, boolean) TO anon;
GRANT ALL ON FUNCTION public.finish_hospital_evaluation(uuid, boolean) TO authenticated;
GRANT ALL ON FUNCTION public.finish_hospital_evaluation(uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- Lo que esta migración NO hace, a propósito.
--
--   a) No genera el PDF. La descarga se resuelve en el panel con una vista
--      imprimible y el diálogo del navegador: montar un generador de PDF en
--      servidor es un trabajo aparte y no cambia el modelo de datos.
--
--   b) No restringe por rol en base de datos: el gateo por especialidad lo hace
--      el panel, como en el resto de los módulos.
-- ---------------------------------------------------------------------------
