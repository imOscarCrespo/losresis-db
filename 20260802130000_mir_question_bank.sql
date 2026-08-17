-- ---------------------------------------------------------------------------
-- MIR question bank (práctica de preguntas para estudiantes).
--
-- Banco unificado de preguntas MIR (Medicina) importado desde
-- mir_medicina_unificado.json (fuentes MIT/CC0; atribución al Ministerio de
-- Sanidad requerida en la UI). 1.125 preguntas, de las cuales solo son
-- "servibles" las que tienen plantilla oficial y no están anuladas
-- (is_active, columna generada). Las 210 de MIR 2025 llegan sin plantilla:
-- cuando se disponga de ella, un UPDATE de correct_option las activa solo.
--
-- Mecánica del drill: la app sirve primero preguntas nunca respondidas
-- (aleatorio entre ellas) y, agotado el pool del filtro, las menos
-- recientemente respondidas. Los intentos en modo 'review' (repaso de
-- importantes/falladas/anotadas) no cuentan para ese orden.
--
-- Solo estudiantes (users.is_student) leen el banco. Cada usuario solo ve y
-- escribe sus propios intentos y su estado por pregunta. is_correct lo
-- calcula el servidor (trigger), nunca el cliente. Los contadores globales
-- (times_answered / times_failed) viven en la propia pregunta y alimentan el
-- ranking de más difíciles / más fáciles visible para estudiantes.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Helper RLS: ¿el usuario autenticado es estudiante?
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_student_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_student = true
  );
$$;

REVOKE ALL ON FUNCTION public.is_student_user() FROM public;
GRANT EXECUTE ON FUNCTION public.is_student_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_student_user() TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Banco de preguntas. options es JSONB [{position, text}] (contenido
--    inmutable de examen, siempre se lee entero). correct_option puede ser
--    NULL (sin plantilla oficial); is_active se deriva y no se escribe.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.mir_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  source_id text NOT NULL UNIQUE,
  fingerprint text NOT NULL UNIQUE,

  exam_year integer,
  exam_version integer,
  question_number integer,
  is_reserve boolean NOT NULL DEFAULT false,
  is_annulled boolean NOT NULL DEFAULT false,

  specialty text,
  clinical_case text,
  question text NOT NULL CHECK (btrim(question) <> ''),
  options jsonb NOT NULL CHECK (jsonb_typeof(options) = 'array'),
  n_options integer NOT NULL CHECK (n_options BETWEEN 2 AND 6),
  -- Las posiciones pueden tener huecos (p.ej. [1,2,4] si la fuente perdió una
  -- opción), así que el rango real lo valida el trigger contra options; aquí
  -- solo una cota de cordura. El seed garantiza que correct_option, si no es
  -- NULL, existe entre las posiciones de options.
  correct_option integer CHECK (
    correct_option IS NULL OR (correct_option BETWEEN 1 AND 6)
  ),
  answer_key_version text,
  explanation text,

  has_image boolean NOT NULL DEFAULT false,
  image_path text,
  image_url text,

  needs_review boolean NOT NULL DEFAULT false,
  review_reason text,
  provenance text,
  source_url text,

  is_active boolean GENERATED ALWAYS AS (
    correct_option IS NOT NULL AND NOT is_annulled
  ) STORED,

  times_answered bigint NOT NULL DEFAULT 0,
  times_failed bigint NOT NULL DEFAULT 0,

  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mir_questions_active_specialty_idx
ON public.mir_questions (specialty)
WHERE is_active;

CREATE INDEX IF NOT EXISTS mir_questions_active_exam_year_idx
ON public.mir_questions (exam_year)
WHERE is_active;

-- ---------------------------------------------------------------------------
-- 3. Intentos. Una fila por respuesta. mode 'drill' alimenta el orden
--    no-repetición; 'review' (re-práctica desde Repaso) no lo contamina.
--    is_correct lo fija el trigger contra la plantilla oficial.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.mir_question_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  question_id uuid NOT NULL REFERENCES public.mir_questions(id) ON DELETE CASCADE,

  selected_option integer NOT NULL,
  is_correct boolean NOT NULL DEFAULT false,
  mode text NOT NULL DEFAULT 'drill' CHECK (mode IN ('drill', 'review')),

  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mir_question_attempts_user_question_idx
ON public.mir_question_attempts (user_id, question_id);

CREATE INDEX IF NOT EXISTS mir_question_attempts_question_idx
ON public.mir_question_attempts (question_id);

-- ---------------------------------------------------------------------------
-- 4. Estado por (usuario, pregunta): marca de importante, UNA nota editable,
--    contadores personales y última respuesta en drill (para el orden del
--    pool). Los contadores y timestamps los mantiene el trigger de intentos;
--    la app solo escribe is_important y note.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.mir_user_question_state (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  question_id uuid NOT NULL REFERENCES public.mir_questions(id) ON DELETE CASCADE,

  is_important boolean NOT NULL DEFAULT false,
  note text,

  times_correct integer NOT NULL DEFAULT 0,
  times_failed integer NOT NULL DEFAULT 0,
  last_drill_answered_at timestamptz,
  last_answered_at timestamptz,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, question_id)
);

CREATE INDEX IF NOT EXISTS mir_user_question_state_important_idx
ON public.mir_user_question_state (user_id)
WHERE is_important;

CREATE INDEX IF NOT EXISTS mir_user_question_state_failed_idx
ON public.mir_user_question_state (user_id)
WHERE times_failed > 0;

-- ---------------------------------------------------------------------------
-- 5. Trigger de intentos: valida la pregunta, fija is_correct en servidor y
--    mantiene contadores globales y estado personal. SECURITY DEFINER porque
--    el estudiante no tiene UPDATE sobre mir_questions.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.handle_mir_question_attempt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  q public.mir_questions%ROWTYPE;
BEGIN
  SELECT * INTO q FROM public.mir_questions WHERE id = NEW.question_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'mir question % not found', NEW.question_id;
  END IF;

  IF NOT q.is_active THEN
    RAISE EXCEPTION 'mir question % is not active', NEW.question_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(q.options) AS o
    WHERE (o ->> 'position')::integer = NEW.selected_option
  ) THEN
    RAISE EXCEPTION 'selected_option % is not an option of question %',
      NEW.selected_option, NEW.question_id;
  END IF;

  NEW.is_correct := (NEW.selected_option = q.correct_option);

  UPDATE public.mir_questions
  SET times_answered = times_answered + 1,
      times_failed = times_failed + (CASE WHEN NEW.is_correct THEN 0 ELSE 1 END)
  WHERE id = NEW.question_id;

  INSERT INTO public.mir_user_question_state AS s (
    user_id,
    question_id,
    times_correct,
    times_failed,
    last_drill_answered_at,
    last_answered_at
  )
  VALUES (
    NEW.user_id,
    NEW.question_id,
    CASE WHEN NEW.is_correct THEN 1 ELSE 0 END,
    CASE WHEN NEW.is_correct THEN 0 ELSE 1 END,
    CASE WHEN NEW.mode = 'drill' THEN now() ELSE NULL END,
    now()
  )
  ON CONFLICT (user_id, question_id) DO UPDATE
  SET times_correct = s.times_correct + (CASE WHEN NEW.is_correct THEN 1 ELSE 0 END),
      times_failed = s.times_failed + (CASE WHEN NEW.is_correct THEN 0 ELSE 1 END),
      last_drill_answered_at = CASE
        WHEN NEW.mode = 'drill' THEN now()
        ELSE s.last_drill_answered_at
      END,
      last_answered_at = now(),
      updated_at = now();

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_mir_question_attempt() FROM public;

DROP TRIGGER IF EXISTS mir_question_attempt_before_insert ON public.mir_question_attempts;
CREATE TRIGGER mir_question_attempt_before_insert
BEFORE INSERT ON public.mir_question_attempts
FOR EACH ROW
EXECUTE FUNCTION public.handle_mir_question_attempt();

-- ---------------------------------------------------------------------------
-- 6. RLS. Banco: solo lectura para estudiantes. Intentos: insertar y leer
--    los propios (inmutables). Estado: leer/insertar/actualizar el propio.
--    Escrituras de contenido solo por service_role (sin políticas).
-- ---------------------------------------------------------------------------

ALTER TABLE public.mir_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mir_question_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mir_user_question_state ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mir questions student read"
ON public.mir_questions
FOR SELECT
TO authenticated
USING (public.is_student_user());

CREATE POLICY "mir attempts insert own"
ON public.mir_question_attempts
FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid() AND public.is_student_user());

CREATE POLICY "mir attempts read own"
ON public.mir_question_attempts
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "mir state read own"
ON public.mir_user_question_state
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "mir state insert own"
ON public.mir_user_question_state
FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid() AND public.is_student_user());

CREATE POLICY "mir state update own"
ON public.mir_user_question_state
FOR UPDATE
TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

GRANT SELECT ON public.mir_questions TO authenticated;
GRANT SELECT, INSERT ON public.mir_question_attempts TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.mir_user_question_state TO authenticated;

GRANT ALL ON public.mir_questions TO service_role;
GRANT ALL ON public.mir_question_attempts TO service_role;
GRANT ALL ON public.mir_user_question_state TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Bucket público para las ~75 imágenes de preguntas. Solo service_role
--    escribe (el script de carga); lectura pública como roommate-avatar.
-- ---------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'mir-question-images',
  'mir-question-images',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

CREATE POLICY "mir question images public read"
ON storage.objects
FOR SELECT
TO public
USING (bucket_id = 'mir-question-images');
