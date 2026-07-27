-- ---------------------------------------------------------------------------
-- Push al asignar un Recordatorio (losresis-panel ADR 0008).
--
-- El Recordatorio es el tablón compartido del servicio. Hasta ahora vivía solo
-- en el panel y se creaba por INSERT directo, sin aviso. La app estrena una
-- vista del residente ("Recordatorios del servicio") y con ella el ciclo
-- completo: cuando un recordatorio SEÑALA a alguien (destinatario_user_id al
-- crear, o reasignado después), esa persona recibe un push.
--
-- El aviso nace en un trigger de la tabla, no en las superficies: el panel y
-- la app insertan como siempre y ninguna de las dos puede olvidarse de avisar.
-- Los recordatorios sin asignar ("de quien esté de turno") no notifican a
-- nadie: avisar a 16 residentes de cada nota del tablón sería spam.
-- ---------------------------------------------------------------------------

INSERT INTO public.notification_types (code, description)
VALUES (
  'recordatorio_asignado',
  'Te han asignado un recordatorio del servicio'
)
ON CONFLICT (code) DO NOTHING;

CREATE OR REPLACE FUNCTION public.notify_recordatorio_asignado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo cuando el destinatario APARECE o CAMBIA, y el recordatorio sigue vivo.
  IF NEW.destinatario_user_id IS NULL OR NEW.cerrado_en IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.destinatario_user_id IS NOT DISTINCT FROM OLD.destinatario_user_id THEN
    RETURN NEW;
  END IF;

  -- Asignárselo a uno mismo no avisa: ya lo sabes, tú lo escribiste.
  IF NEW.destinatario_user_id IS NOT DISTINCT FROM auth.uid() THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, entity_type, entity_id, data)
  VALUES (
    NEW.destinatario_user_id,
    'recordatorio_asignado',
    'Recordatorio del servicio',
    '"' || left(NEW.texto, 140) || '" · para el ' || to_char(NEW.fecha, 'DD/MM'),
    'recordatorio',
    NEW.id,
    jsonb_build_object(
      'entity_type', 'recordatorio',
      'entity_id', NEW.id,
      'servicio_id', NEW.servicio_id,
      'fecha', NEW.fecha,
      'destination_section', 'recordatoriosServicio'
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recordatorio_asignado_push ON public.recordatorio;
CREATE TRIGGER trg_recordatorio_asignado_push
AFTER INSERT OR UPDATE ON public.recordatorio
FOR EACH ROW EXECUTE FUNCTION public.notify_recordatorio_asignado();
