-- Fix: "column reference group_id is ambiguous" al abrir un chat directo
-- desde el listado de residentes.
--
-- Causa: ensure_direct_group declara RETURNS TABLE (group_id uuid, ...), lo
-- que crea una variable plpgsql llamada `group_id`. El INSERT sobre
-- group_members usa `ON CONFLICT (group_id, user_id)`, y el inferencer del
-- ON CONFLICT no puede resolver `group_id` entre la variable y la columna.
--
-- Solución: volver a referenciar la constraint por nombre, como en la versión
-- previa a 20260525150000_direct_chat_require_work_email.sql. Se preserva la
-- validación de work_email del residente que llama.

CREATE OR REPLACE FUNCTION public.ensure_direct_group(p_other_user_id uuid)
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
  v_other_exists boolean;
  v_other_name text;
  v_current_is_resident boolean;
  v_current_work_email text;
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

  SELECT
    COALESCE(is_resident, false),
    NULLIF(TRIM(COALESCE(work_email, '')), '')
  INTO v_current_is_resident, v_current_work_email
  FROM public.users
  WHERE id = v_current_user_id;

  IF COALESCE(v_current_is_resident, false) = true
     AND v_current_work_email IS NULL THEN
    RAISE EXCEPTION 'caller_missing_work_email'
      USING ERRCODE = 'P0001',
            HINT = 'Residents must have a verified corporate email to start a chat.';
  END IF;

  SELECT
    true,
    NULLIF(TRIM(CONCAT(COALESCE(name, ''), ' ', COALESCE(surname, ''))), '')
  INTO v_other_exists, v_other_name
  FROM public.users
  WHERE id = p_other_user_id;

  IF COALESCE(v_other_exists, false) = false THEN
    RAISE EXCEPTION 'Recipient not found';
  END IF;

  v_pair_key := CASE
    WHEN v_current_user_id::text < p_other_user_id::text
      THEN v_current_user_id::text || ':' || p_other_user_id::text
    ELSE p_other_user_id::text || ':' || v_current_user_id::text
  END;

  SELECT g.id
  INTO v_group_id
  FROM public.groups g
  WHERE g.kind = 'direct'
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
        'Chat directo',
        'Conversación privada entre dos usuarios',
        0,
        true,
        'direct',
        v_current_user_id,
        v_pair_key
      )
      RETURNING id INTO v_group_id;
    EXCEPTION WHEN unique_violation THEN
      SELECT g.id
      INTO v_group_id
      FROM public.groups g
      WHERE g.kind = 'direct'
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
    COALESCE(v_other_name, 'Chat directo'),
    p_other_user_id;
END;
$$;
