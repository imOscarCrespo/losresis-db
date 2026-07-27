-- Refuerza ensure_direct_group para que un residente sin work_email
-- (estados pending_corporate_email_seasonal / locked_missing_corporate_email)
-- no pueda iniciar chats directos. Defensa en profundidad: el cliente ya lo
-- bloquea desde el directorio de residentes, esto cubre llamadas directas a
-- la RPC (cliente desactualizado o uso indebido).
--
-- No tocamos al destinatario para no romper otros flujos (p.ej. chats con
-- usuarios no residentes que pudieran no tener work_email): el directorio
-- de residentes ya filtra por work_email IS NOT NULL en la propia query.

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
  ON CONFLICT (group_id, user_id) DO NOTHING;

  RETURN QUERY
  SELECT
    v_group_id,
    COALESCE(v_other_name, 'Chat directo'),
    p_other_user_id;
END;
$$;
