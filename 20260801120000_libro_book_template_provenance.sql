-- Procedencia del libro: un libro sembrado desde la plantilla del hospital lo
-- define el tutor, no el residente.
--
-- Hasta ahora no había forma de distinguir "este libro lo montó el residente en
-- el onboarding" de "este libro lo sembró la plantilla de su hospital". Ambos
-- casos eran filas idénticas de libro_book, así que la app no podía ofrecer el
-- libro de la plantilla en modo solo lectura.
--
-- libro_book.template_id es esa marca, y es la única fuente de verdad: se guarda
-- en la fila en vez de deducirse de hospital_id + speciality_id del residente,
-- porque un residente cambia de hospital y la deducción bloquearía (o
-- desbloquearía) retroactivamente libros que ya son suyos.
--
-- OJO: esta migración documenta objetos que ya se aplicaron a mano en Supabase.
-- Es idempotente a propósito para que `db push` no divergía del estado real.

-- ---------------------------------------------------------------------------
-- 1. La marca de procedencia.
-- ---------------------------------------------------------------------------

ALTER TABLE public.libro_book
  ADD COLUMN IF NOT EXISTS template_id uuid
  REFERENCES public.libro_template(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.libro_book.template_id IS
  'Plantilla que sembró este libro. NULL = lo montó el residente y es suyo para editar.';

-- ---------------------------------------------------------------------------
-- 2. La estructura de un libro de plantilla es de solo lectura para el residente.
--
-- RLS sobre libro_node es allow_all (USING true / WITH CHECK true), así que
-- esconder botones en la app no es una garantía: el candado tiene que estar aquí.
--
-- El candado cubre solo la ESTRUCTURA (categorías y actividades). Registrar
-- actividad va a libro_entry y libro_event, que siguen abiertos: el residente
-- rellena el libro que le da su hospital, pero no lo reescribe.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.libro_node_block_structure_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.libro_book
    WHERE id = COALESCE(NEW.book_id, OLD.book_id) AND template_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Este libro lo define el hospital: su estructura no se puede modificar';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;

DROP TRIGGER IF EXISTS trigger_libro_node_structure_locked ON public.libro_node;

CREATE TRIGGER trigger_libro_node_structure_locked
BEFORE INSERT OR UPDATE OR DELETE ON public.libro_node
FOR EACH ROW
EXECUTE FUNCTION public.libro_node_block_structure_changes();

GRANT ALL ON FUNCTION public.libro_node_block_structure_changes() TO anon;
GRANT ALL ON FUNCTION public.libro_node_block_structure_changes() TO authenticated;
GRANT ALL ON FUNCTION public.libro_node_block_structure_changes() TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Lo que esta migración NO hace, a propósito.
--
--   a) apply_libro_template_for_user sigue insertando el libro sin template_id,
--      así que hoy el candado no puede saltar nunca: ningún libro está marcado.
--      Es deliberado. El día que la siembra selle template_id, la app tiene que
--      tener ya la UI de solo lectura; si no, el residente vería el botón de
--      "añadir rotación" y recibiría esta excepción en crudo.
--
--      Cuando se selle: el UPDATE de template_id va DESPUÉS de clonar los nodos,
--      o este mismo trigger aborta la siembra (y trg_apply_libro_template_on_user
--      se come el error como RAISE WARNING, así que fallaría en silencio).
--
--   b) No se rellena template_id en los libros que ya existen. La plantilla
--      a53d8062 está publicada desde 2026-07-22, así que entre los libros
--      actuales hay sembrados y montados por el residente sin forma fiable de
--      distinguirlos: marcarlos en bloque bloquearía libros que son del
--      residente. Se quedan en NULL (editables) y entran en la plantilla por el
--      camino explícito de "cambiar al libro oficial".
--
--   c) El trigger no tiene puerta de salida para la sincronización servidor.
--      sync_libro_template_for_user tendrá que insertar y borrar libro_node en
--      libros marcados, así que necesitará un flag de sesión que este trigger
--      respete. Va en la migración que traiga la propagación.
-- ---------------------------------------------------------------------------
