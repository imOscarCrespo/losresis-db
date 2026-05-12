-- Schedule the weekly-courses-bot edge function via pg_cron + pg_net.
--
-- Configuration is read from Supabase Vault. Create these three secrets via
-- Studio → Project Settings → Vault → New secret:
--   name = "weekly_courses_bot_url"     value = https://<project>.supabase.co/functions/v1/weekly-courses-bot
--   name = "weekly_courses_bot_secret"  value = <same string as the WEEKLY_COURSES_BOT_SECRET edge function secret>
--   name = "supabase_anon_key"          value = <project anon key, used to pass the gateway>
-- The anon key is public; the bot's authorization is enforced inside the
-- function via WEEKLY_COURSES_BOT_SECRET.

CREATE OR REPLACE FUNCTION public.invoke_weekly_courses_bot()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url      text;
  v_secret   text;
  v_anon_key text;
BEGIN
  SELECT decrypted_secret INTO v_url
  FROM vault.decrypted_secrets
  WHERE name = 'weekly_courses_bot_url';

  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'weekly_courses_bot_secret';

  SELECT decrypted_secret INTO v_anon_key
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_anon_key';

  IF v_url IS NULL OR v_secret IS NULL OR v_anon_key IS NULL THEN
    RAISE WARNING 'invoke_weekly_courses_bot: missing one of weekly_courses_bot_url / weekly_courses_bot_secret / supabase_anon_key in vault; skipping';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_secret,
      'apikey',        v_anon_key,
      'Content-Type',  'application/json'
    ),
    body    := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invoke_weekly_courses_bot() FROM public;
GRANT EXECUTE ON FUNCTION public.invoke_weekly_courses_bot() TO postgres;

-- Replace any prior schedule with the same name (idempotent re-runs).
SELECT cron.unschedule('weekly-courses-bot')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'weekly-courses-bot'
);

SELECT cron.schedule(
  'weekly-courses-bot',
  '0 6 * * 1', -- every Monday at 06:00 UTC
  $$SELECT public.invoke_weekly_courses_bot();$$
);
