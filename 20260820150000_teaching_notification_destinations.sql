-- ---------------------------------------------------------------------------
-- Que las notificaciones de Docencia abran su contenido.
--
-- Las ocho funciones que avisan al residente (tutoría programada, compartida y
-- recordada; evaluación cerrada; autoevaluación pedida y recordada; comunicado
-- enviado) insertan en `notifications` SIN `data.destination_section`. La app
-- navega por ese campo, así que hoy esas notificaciones no llevan a ninguna parte:
-- el residente recibe "tienes una tutoría el día 22", la toca y no pasa nada.
--
-- Se resuelve con un trigger sobre `notifications` en vez de reescribiendo las ocho
-- funciones: el destino se deduce del `type`, que ya es único por caso, y así el
-- próximo aviso de Docencia lo hereda sin que nadie se acuerde de ponerlo.
--
-- Solo rellena cuando falta: si una función pone su destino a mano, manda ella.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_notification_destination()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_destination text;
BEGIN
  -- Lo que ya trae destino no se toca.
  IF NEW.data ? 'destination_section' THEN
    RETURN NEW;
  END IF;

  v_destination := CASE
    WHEN NEW.type LIKE 'tutoring%' THEN 'tutorias'
    WHEN NEW.type LIKE 'evaluation%' THEN 'evaluaciones'
    WHEN NEW.type LIKE 'self_assessment%' THEN 'autoevaluacion'
    -- El comunicado ES su título y su cuerpo: no hay pantalla propia que abrir, y
    -- la lista de notificaciones ya lo enseña entero.
    WHEN NEW.type = 'hospital_announcement' THEN 'notifications'
    WHEN NEW.type LIKE 'libro_%' THEN 'residenceLibrary'
    ELSE NULL
  END;

  IF v_destination IS NULL THEN
    RETURN NEW;
  END IF;

  NEW.data := COALESCE(NEW.data, '{}'::jsonb)
    || jsonb_build_object('destination_section', v_destination);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_set_notification_destination ON public.notifications;

CREATE TRIGGER trigger_set_notification_destination
BEFORE INSERT ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.set_notification_destination();

GRANT ALL ON FUNCTION public.set_notification_destination() TO anon;
GRANT ALL ON FUNCTION public.set_notification_destination() TO authenticated;
GRANT ALL ON FUNCTION public.set_notification_destination() TO service_role;
