INSERT INTO public.notification_types (code, description)
VALUES ('group_message', 'Nuevo mensaje en un grupo')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE public.group_members
ADD COLUMN IF NOT EXISTS last_read_at timestamptz,
ADD COLUMN IF NOT EXISTS notifications_muted boolean NOT NULL DEFAULT false;

UPDATE public.group_members
SET last_read_at = COALESCE(last_read_at, joined_at, now())
WHERE last_read_at IS NULL;

ALTER TABLE public.group_members
ALTER COLUMN last_read_at SET DEFAULT now(),
ALTER COLUMN last_read_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_group_members_user_last_read
ON public.group_members (user_id, last_read_at DESC);

CREATE OR REPLACE FUNCTION public.get_group_unread_counts(p_group_ids uuid[] DEFAULT NULL)
RETURNS TABLE (
  group_id uuid,
  unread_count bigint,
  last_message_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    gm.group_id,
    COUNT(msg.id) FILTER (
      WHERE
        msg.user_id <> auth.uid()
        AND msg.created_at > COALESCE(gm.last_read_at, gm.joined_at, '-infinity'::timestamptz)
    ) AS unread_count,
    MAX(msg.created_at) AS last_message_at
  FROM public.group_members gm
  LEFT JOIN public.group_messages msg
    ON msg.group_id = gm.group_id
   AND COALESCE(msg.is_deleted, false) = false
  WHERE gm.user_id = auth.uid()
    AND (p_group_ids IS NULL OR gm.group_id = ANY(p_group_ids))
  GROUP BY gm.group_id;
$$;

CREATE OR REPLACE FUNCTION public.notify_group_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.notifications (
    user_id,
    type,
    actor_user_id,
    title,
    body,
    entity_type,
    entity_id,
    data
  )
  SELECT
    gm.user_id,
    'group_message',
    NEW.user_id,
    COALESCE(g.name, 'Grupo'),
    CASE
      WHEN char_length(NEW.content) > 140 THEN left(NEW.content, 137) || '...'
      ELSE NEW.content
    END,
    'group',
    g.id,
    jsonb_build_object(
      'entity_type', 'group',
      'entity_id', g.id,
      'group_id', g.id,
      'group_name', g.name,
      'message_id', NEW.id,
      'destination_section', 'groupChat'
    )
  FROM public.group_members gm
  JOIN public.groups g
    ON g.id = gm.group_id
  LEFT JOIN public.user_notification_preferences pref
    ON pref.user_id = gm.user_id
   AND pref.notification_type = 'group_message'
  WHERE gm.group_id = NEW.group_id
    AND gm.user_id <> NEW.user_id
    AND COALESCE(gm.notifications_muted, false) = false
    AND (
      pref.user_id IS NULL
      OR COALESCE(pref.push_enabled, true) = true
      OR COALESCE(pref.in_app_enabled, true) = true
    );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_group_message ON public.group_messages;

CREATE TRIGGER trg_notify_group_message
AFTER INSERT ON public.group_messages
FOR EACH ROW
EXECUTE FUNCTION public.notify_group_message();

DROP POLICY IF EXISTS members_update ON public.group_members;

CREATE POLICY members_update
ON public.group_members
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

GRANT EXECUTE ON FUNCTION public.get_group_unread_counts(uuid[]) TO anon;
GRANT EXECUTE ON FUNCTION public.get_group_unread_counts(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_unread_counts(uuid[]) TO service_role;
