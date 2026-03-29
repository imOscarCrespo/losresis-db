CREATE OR REPLACE FUNCTION public.register_push_token(
  p_token text,
  p_provider text DEFAULT 'expo',
  p_platform text DEFAULT NULL,
  p_device_name text DEFAULT NULL,
  p_app_version text DEFAULT NULL
)
RETURNS public.push_tokens
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_row public.push_tokens;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RAISE EXCEPTION 'Push token is required';
  END IF;

  IF p_platform IS NULL OR btrim(p_platform) = '' THEN
    RAISE EXCEPTION 'Platform is required';
  END IF;

  INSERT INTO public.push_tokens (
    user_id,
    token,
    provider,
    platform,
    device_name,
    app_version,
    is_valid,
    last_seen_at
  )
  VALUES (
    v_user_id,
    btrim(p_token),
    COALESCE(NULLIF(btrim(p_provider), ''), 'expo'),
    btrim(p_platform),
    NULLIF(btrim(COALESCE(p_device_name, '')), ''),
    NULLIF(btrim(COALESCE(p_app_version, '')), ''),
    true,
    now()
  )
  ON CONFLICT (token) DO UPDATE
  SET
    user_id = EXCLUDED.user_id,
    provider = EXCLUDED.provider,
    platform = EXCLUDED.platform,
    device_name = EXCLUDED.device_name,
    app_version = EXCLUDED.app_version,
    is_valid = true,
    last_seen_at = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_push_token(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_push_token(text, text, text, text, text) TO service_role;
