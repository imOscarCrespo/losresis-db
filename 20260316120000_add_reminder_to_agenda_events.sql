ALTER TABLE "public"."agenda_events"
DROP CONSTRAINT IF EXISTS "agenda_events_event_type_check";

ALTER TABLE "public"."agenda_events"
ADD CONSTRAINT "agenda_events_event_type_check"
CHECK (
  "event_type" = ANY (
    ARRAY[
      'shift'::text,
      'course'::text,
      'research'::text,
      'study'::text,
      'conference'::text,
      'day_off'::text,
      'reminder'::text
    ]
  )
);
