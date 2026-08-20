-- ---------------------------------------------------------------------------
-- La tutoría deja de ser un monólogo del tutor.
--
-- El §13 pide que el residente aporte su parte: acuerdos alcanzados, objetivos,
-- comentarios y observaciones. Las seis columnas de contenido que ya existían
-- (topics, competencies_reviewed, goals_achieved, improvements, next_goals, notes)
-- son TODAS del tutor, así que no había dónde ponerlo.
--
-- No se reutilizan esas columnas a propósito: la tutoría es un único registro
-- compartido (ADR 0021 del panel), y si los dos escribieran encima, el tutor
-- pisaría al residente sin dejar rastro. Es el mismo criterio que ya se aplicó al
-- nivel de las competencias: UN escritor por columna.
--
-- Va en jsonb y no en columnas sueltas para no fijar el vocabulario en el esquema:
-- es el mismo patrón que el arquetipo `form` del Libro, donde la configuración dice
-- qué campos hay y el payload los guarda.
--
-- Asimetría deliberada: lo del tutor espera a `shared_at`; lo del residente el tutor
-- lo ve en cuanto lo escribe. Es su preparación para la reunión: esconderla no tiene
-- ningún sentido.
-- ---------------------------------------------------------------------------

ALTER TABLE public.hospital_tutoring
  ADD COLUMN IF NOT EXISTS resident_answers jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.hospital_tutoring.resident_answers IS
  'La parte del residente: agreements, goals, comments, notes. Solo la escribe el, por RPC.';

-- ---------------------------------------------------------------------------
-- Su escritura, con comprobación de dueño.
--
-- La tabla es de solo lectura para el residente (la RLS la dejó para el panel), así
-- que escribir pasa siempre por aquí. Y como es SECURITY DEFINER, sin la
-- comprobación cualquiera con el id podría escribir en la tutoría de otro.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.save_hospital_tutoring_resident_answers(
  p_id uuid,
  p_answers jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner uuid;
  v_status text;
BEGIN
  SELECT resident_user_id, status
  INTO v_owner, v_status
  FROM public.hospital_tutoring
  WHERE id = p_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'La tutoria % no existe', p_id;
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> v_owner THEN
    RAISE EXCEPTION 'Solo el residente puede escribir en su tutoria';
  END IF;

  -- Una cancelada no se rellena. Una cerrada sí: el residente puede añadir lo que
  -- se le ocurra después de la reunión, que es cuando suele acordarse.
  IF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'Esta tutoria esta cancelada';
  END IF;

  UPDATE public.hospital_tutoring
  SET resident_answers = COALESCE(p_answers, '{}'::jsonb)
  WHERE id = p_id;
END;
$$;

GRANT ALL ON FUNCTION public.save_hospital_tutoring_resident_answers(uuid, jsonb) TO anon;
GRANT ALL ON FUNCTION public.save_hospital_tutoring_resident_answers(uuid, jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.save_hospital_tutoring_resident_answers(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- La vista del residente lleva su parte SIN enmascarar: es suya.
--
-- Se recrea en vez de reemplazarse porque CREATE OR REPLACE VIEW no admite insertar
-- una columna en medio: renombraría las de después. El DROP se lleva los GRANT, así
-- que se vuelven a dar abajo.
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.hospital_tutoring_for_resident;

CREATE VIEW public.hospital_tutoring_for_resident AS
SELECT
  t.id,
  t.hospital_id,
  t.resident_user_id,
  t.tutor_name,
  t.speciality_id,
  t.residency_year,
  t.tutoring_type,
  t.scheduled_at,
  t.place,
  t.status,
  t.shared_at,
  t.finished_at,
  t.cancelled_at,
  t.agenda_event_id,
  t.created_at,
  (t.shared_at IS NOT NULL) AS is_shared,
  t.resident_answers,
  CASE WHEN t.shared_at IS NOT NULL THEN t.topics END AS topics,
  CASE WHEN t.shared_at IS NOT NULL THEN t.competencies_reviewed END
    AS competencies_reviewed,
  CASE WHEN t.shared_at IS NOT NULL THEN t.goals_achieved END AS goals_achieved,
  CASE WHEN t.shared_at IS NOT NULL THEN t.improvements END AS improvements,
  CASE WHEN t.shared_at IS NOT NULL THEN t.next_goals END AS next_goals,
  CASE WHEN t.shared_at IS NOT NULL THEN t.notes END AS notes
FROM public.hospital_tutoring t
WHERE t.resident_user_id = auth.uid();

GRANT SELECT ON public.hospital_tutoring_for_resident TO anon;
GRANT SELECT ON public.hospital_tutoring_for_resident TO authenticated;
GRANT SELECT ON public.hospital_tutoring_for_resident TO service_role;

COMMENT ON VIEW public.hospital_tutoring_for_resident IS
  'La tutoria como la ve el residente: siempre la cita y su propia parte, el contenido del tutor solo desde shared_at.';
