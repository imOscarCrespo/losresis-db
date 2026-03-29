INSERT INTO public.notification_types (code, description)
VALUES ('group_message', 'Nuevo mensaje en un chat')
ON CONFLICT (code) DO UPDATE
SET description = EXCLUDED.description;

ALTER TABLE public.groups
ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'community',
ADD COLUMN IF NOT EXISTS created_by_user_id uuid,
ADD COLUMN IF NOT EXISTS direct_pair_key text;

ALTER TABLE public.groups
ALTER COLUMN speciality_id DROP NOT NULL,
ALTER COLUMN city DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'groups_kind_check'
      AND conrelid = 'public.groups'::regclass
  ) THEN
    ALTER TABLE public.groups
    ADD CONSTRAINT groups_kind_check
    CHECK (kind = ANY (ARRAY['community'::text, 'resident_rotation_direct'::text]));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'groups_created_by_user_id_fkey'
      AND conrelid = 'public.groups'::regclass
  ) THEN
    ALTER TABLE public.groups
    ADD CONSTRAINT groups_created_by_user_id_fkey
    FOREIGN KEY (created_by_user_id)
    REFERENCES public.users(id)
    ON DELETE SET NULL;
  END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_groups_direct_pair_unique
ON public.groups (direct_pair_key)
WHERE kind = 'resident_rotation_direct' AND direct_pair_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_groups_kind_created_at
ON public.groups (kind, created_at DESC);

DROP POLICY IF EXISTS groups_select ON public.groups;

CREATE POLICY groups_select
ON public.groups
FOR SELECT
USING (
  is_active = true
  AND (
    kind <> 'resident_rotation_direct'
    OR EXISTS (
      SELECT 1
      FROM public.group_members gm
      WHERE gm.group_id = groups.id
        AND gm.user_id = auth.uid()
    )
  )
);

CREATE OR REPLACE FUNCTION public.ensure_resident_rotation_direct_group(p_other_user_id uuid)
RETURNS TABLE (
  group_id uuid,
  group_name text,
  other_user_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_user_id uuid := auth.uid();
  v_pair_key text;
  v_group_id uuid;
  v_current_is_resident boolean;
  v_other_is_resident boolean;
  v_other_name text;
BEGIN
  IF v_current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_other_user_id IS NULL THEN
    RAISE EXCEPTION 'Other user is required';
  END IF;

  IF p_other_user_id = v_current_user_id THEN
    RAISE EXCEPTION 'Cannot create a direct chat with yourself';
  END IF;

  SELECT COALESCE(is_resident, false)
  INTO v_current_is_resident
  FROM public.users
  WHERE id = v_current_user_id;

  IF COALESCE(v_current_is_resident, false) = false THEN
    RAISE EXCEPTION 'Only residents can use this chat';
  END IF;

  SELECT
    COALESCE(is_resident, false),
    NULLIF(TRIM(CONCAT(COALESCE(name, ''), ' ', COALESCE(surname, ''))), '')
  INTO v_other_is_resident, v_other_name
  FROM public.users
  WHERE id = p_other_user_id;

  IF v_other_is_resident IS NULL THEN
    RAISE EXCEPTION 'Recipient not found';
  END IF;

  IF COALESCE(v_other_is_resident, false) = false THEN
    RAISE EXCEPTION 'The recipient is not a resident';
  END IF;

  v_pair_key := CASE
    WHEN v_current_user_id::text < p_other_user_id::text
      THEN v_current_user_id::text || ':' || p_other_user_id::text
    ELSE p_other_user_id::text || ':' || v_current_user_id::text
  END;

  INSERT INTO public.groups (
    user_type,
    speciality_id,
    city,
    name,
    description,
    member_count,
    is_active,
    kind,
    created_by_user_id,
    direct_pair_key
  )
  VALUES (
    'resident',
    NULL,
    NULL,
    'Chat privado',
    'Conversación privada entre residentes sobre rotaciones externas',
    0,
    true,
    'resident_rotation_direct',
    v_current_user_id,
    v_pair_key
  )
  ON CONFLICT (direct_pair_key)
  WHERE kind = 'resident_rotation_direct'
  DO UPDATE
  SET direct_pair_key = EXCLUDED.direct_pair_key
  RETURNING id INTO v_group_id;

  INSERT INTO public.group_members (group_id, user_id)
  VALUES
    (v_group_id, v_current_user_id),
    (v_group_id, p_other_user_id)
  ON CONFLICT (group_id, user_id) DO NOTHING;

  RETURN QUERY
  SELECT
    v_group_id,
    COALESCE(v_other_name, 'Residente'),
    p_other_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_resident_rotation_direct_groups()
RETURNS TABLE (
  group_id uuid,
  other_user_id uuid,
  other_user_name text,
  other_user_surname text,
  other_user_city text,
  other_user_speciality_name text,
  last_message_preview text,
  last_message_at timestamptz,
  unread_count bigint,
  notifications_muted boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    g.id AS group_id,
    other_user.id AS other_user_id,
    other_user.name AS other_user_name,
    other_user.surname AS other_user_surname,
    other_user.city AS other_user_city,
    sp.name AS other_user_speciality_name,
    last_message.content AS last_message_preview,
    last_message.created_at AS last_message_at,
    COALESCE(unread.unread_count, 0) AS unread_count,
    COALESCE(self_member.notifications_muted, false) AS notifications_muted
  FROM public.groups g
  JOIN public.group_members self_member
    ON self_member.group_id = g.id
   AND self_member.user_id = auth.uid()
  JOIN public.group_members other_member
    ON other_member.group_id = g.id
   AND other_member.user_id <> auth.uid()
  JOIN public.users other_user
    ON other_user.id = other_member.user_id
  LEFT JOIN public.specialities sp
    ON sp.id = other_user.speciality_id
  LEFT JOIN LATERAL (
    SELECT
      gm.content,
      gm.created_at
    FROM public.group_messages gm
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, false) = false
    ORDER BY gm.created_at DESC
    LIMIT 1
  ) last_message ON true
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS unread_count
    FROM public.group_messages gm
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, false) = false
      AND gm.user_id <> auth.uid()
      AND gm.created_at > COALESCE(self_member.last_read_at, self_member.joined_at, '-infinity'::timestamptz)
  ) unread ON true
  WHERE g.kind = 'resident_rotation_direct'
    AND COALESCE(g.is_active, true) = true
  ORDER BY COALESCE(last_message.created_at, g.created_at) DESC;
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
    CASE
      WHEN g.kind = 'resident_rotation_direct'
        THEN COALESCE(NULLIF(TRIM(CONCAT(COALESCE(sender.name, ''), ' ', COALESCE(sender.surname, ''))), ''), 'Nuevo mensaje')
      ELSE COALESCE(g.name, 'Grupo')
    END,
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
      'group_kind', g.kind,
      'group_name',
      CASE
        WHEN g.kind = 'resident_rotation_direct'
          THEN COALESCE(NULLIF(TRIM(CONCAT(COALESCE(sender.name, ''), ' ', COALESCE(sender.surname, ''))), ''), 'Chat privado')
        ELSE g.name
      END,
      'message_id', NEW.id,
      'destination_section', 'groupChat'
    )
  FROM public.group_members gm
  JOIN public.groups g
    ON g.id = gm.group_id
  LEFT JOIN public.users sender
    ON sender.id = NEW.user_id
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

GRANT EXECUTE ON FUNCTION public.ensure_resident_rotation_direct_group(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_resident_rotation_direct_groups() TO authenticated;
