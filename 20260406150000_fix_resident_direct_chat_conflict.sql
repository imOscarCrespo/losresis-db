CREATE UNIQUE INDEX IF NOT EXISTS idx_groups_direct_pair_unique
ON public.groups (direct_pair_key)
WHERE kind = 'resident_rotation_direct' AND direct_pair_key IS NOT NULL;

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

  SELECT g.id
  INTO v_group_id
  FROM public.groups g
  WHERE g.kind = 'resident_rotation_direct'
    AND g.direct_pair_key = v_pair_key
  LIMIT 1;

  IF v_group_id IS NULL THEN
    BEGIN
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
      RETURNING id INTO v_group_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT g.id
        INTO v_group_id
        FROM public.groups g
        WHERE g.kind = 'resident_rotation_direct'
          AND g.direct_pair_key = v_pair_key
        LIMIT 1;
    END;
  END IF;

  INSERT INTO public.group_members (group_id, user_id)
  VALUES
    (v_group_id, v_current_user_id),
    (v_group_id, p_other_user_id)
  ON CONFLICT ON CONSTRAINT group_members_group_id_user_id_key DO NOTHING;

  RETURN QUERY
  SELECT
    v_group_id,
    COALESCE(v_other_name, 'Residente'),
    p_other_user_id;
END;
$$;
