CREATE EXTENSION IF NOT EXISTS pg_cron;

INSERT INTO public.notification_types (code, description)
VALUES (
  'agenda_event_reminder',
  'Recordatorio programado para un evento de agenda'
)
ON CONFLICT (code) DO NOTHING;

CREATE OR REPLACE FUNCTION public.enqueue_agenda_event_reminder(p_event_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event public.agenda_events%ROWTYPE;
  v_offset_days integer;
  v_reminder_date date;
  v_spain_now timestamp without time zone := timezone('Europe/Madrid', now());
  v_inserted_count integer := 0;
BEGIN
  SELECT *
  INTO v_event
  FROM public.agenda_events
  WHERE id = p_event_id;

  IF NOT FOUND OR v_event.event_date IS NULL THEN
    RETURN 0;
  END IF;

  BEGIN
    v_offset_days := NULLIF(v_event.metadata->>'reminder_offset_days', '')::integer;
  EXCEPTION
    WHEN invalid_text_representation THEN
      RETURN 0;
  END;

  IF v_offset_days NOT IN (1, 3, 5) THEN
    RETURN 0;
  END IF;

  v_reminder_date := v_event.event_date - v_offset_days;

  IF EXTRACT(HOUR FROM v_spain_now) <> 21 THEN
    RETURN 0;
  END IF;

  IF v_reminder_date <> DATE(v_spain_now) THEN
    RETURN 0;
  END IF;

  INSERT INTO public.notifications (
    user_id,
    type,
    title,
    body,
    entity_type,
    entity_id,
    data
  )
  SELECT
    v_event.user_id,
    'agenda_event_reminder',
    'Recordatorio de agenda',
    CASE
      WHEN v_offset_days = 1 THEN
        'Manana tienes "' || v_event.title || '".'
      ELSE
        'En ' || v_offset_days || ' dias tienes "' || v_event.title || '".'
    END,
    'agenda_event',
    v_event.id,
    jsonb_build_object(
      'entity_type', 'agenda_event',
      'entity_id', v_event.id,
      'event_type', v_event.event_type,
      'event_title', v_event.title,
      'event_date', v_event.event_date,
      'end_date', v_event.end_date,
      'reminder_offset_days', v_offset_days,
      'reminder_date', v_reminder_date,
      'destination_section', 'agenda',
      'destination_tab', 'agenda'
    )
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.notifications n
    WHERE n.type = 'agenda_event_reminder'
      AND n.entity_type = 'agenda_event'
      AND n.entity_id = v_event.id
      AND COALESCE(NULLIF(n.data->>'reminder_offset_days', '')::integer, -1) = v_offset_days
      AND COALESCE(NULLIF(n.data->>'reminder_date', '')::date, CURRENT_DATE) = v_reminder_date
  );

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;
  RETURN v_inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_due_agenda_event_reminders()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event record;
  v_total integer := 0;
  v_spain_now timestamp without time zone := timezone('Europe/Madrid', now());
BEGIN
  IF EXTRACT(HOUR FROM v_spain_now) <> 21 THEN
    RETURN 0;
  END IF;

  FOR v_event IN
    SELECT ae.id
    FROM public.agenda_events ae
    WHERE ae.event_date IS NOT NULL
      AND (ae.metadata->>'reminder_offset_days') IN ('1', '3', '5')
      AND (ae.event_date - ((ae.metadata->>'reminder_offset_days')::integer)) = DATE(v_spain_now)
  LOOP
    v_total := v_total + public.enqueue_agenda_event_reminder(v_event.id);
  END LOOP;

  RETURN v_total;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_agenda_event_reminder_notifications(p_event_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted_count integer := 0;
BEGIN
  DELETE FROM public.notifications
  WHERE type = 'agenda_event_reminder'
    AND entity_type = 'agenda_event'
    AND entity_id = p_event_id
    AND is_read = false;

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  RETURN v_deleted_count;
END;
$$;

GRANT ALL ON FUNCTION public.enqueue_agenda_event_reminder(uuid) TO anon;
GRANT ALL ON FUNCTION public.enqueue_agenda_event_reminder(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.enqueue_agenda_event_reminder(uuid) TO service_role;

GRANT ALL ON FUNCTION public.enqueue_due_agenda_event_reminders() TO anon;
GRANT ALL ON FUNCTION public.enqueue_due_agenda_event_reminders() TO authenticated;
GRANT ALL ON FUNCTION public.enqueue_due_agenda_event_reminders() TO service_role;

GRANT ALL ON FUNCTION public.delete_agenda_event_reminder_notifications(uuid) TO anon;
GRANT ALL ON FUNCTION public.delete_agenda_event_reminder_notifications(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_agenda_event_reminder_notifications(uuid) TO service_role;

SELECT cron.schedule(
  'agenda-event-reminders-hourly',
  '0 * * * *',
  $$SELECT public.enqueue_due_agenda_event_reminders();$$
);
