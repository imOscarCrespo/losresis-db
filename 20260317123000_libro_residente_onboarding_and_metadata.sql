DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'libro_node_tracking_mode'
  ) THEN
    CREATE TYPE public.libro_node_tracking_mode AS ENUM (
      'counter',
      'note',
      'checklist'
    );
  END IF;
END
$$;

ALTER TABLE public.libro_node
  ADD COLUMN IF NOT EXISTS icon_name text,
  ADD COLUMN IF NOT EXISTS color_token text,
  ADD COLUMN IF NOT EXISTS tracking_mode public.libro_node_tracking_mode NOT NULL DEFAULT 'counter';

ALTER TABLE public.libro_entry
  ADD COLUMN IF NOT EXISTS performed_at date NOT NULL DEFAULT CURRENT_DATE,
  ADD COLUMN IF NOT EXISTS payload jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.libro_user_settings (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  speciality_id uuid REFERENCES public.specialities(id) ON DELETE SET NULL,
  onboarding_completed_at timestamp with time zone,
  onboarding_version integer NOT NULL DEFAULT 1,
  last_used_node_id uuid REFERENCES public.libro_node(id) ON DELETE SET NULL,
  quick_activity_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.update_libro_user_settings_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_libro_user_settings_updated_at ON public.libro_user_settings;

CREATE TRIGGER trigger_update_libro_user_settings_updated_at
BEFORE UPDATE ON public.libro_user_settings
FOR EACH ROW
EXECUTE FUNCTION public.update_libro_user_settings_updated_at();

ALTER TABLE public.libro_user_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_libro_user_settings ON public.libro_user_settings;

CREATE POLICY allow_all_libro_user_settings
ON public.libro_user_settings
USING (true)
WITH CHECK (true);

GRANT ALL ON TABLE public.libro_user_settings TO anon;
GRANT ALL ON TABLE public.libro_user_settings TO authenticated;
GRANT ALL ON TABLE public.libro_user_settings TO service_role;

GRANT ALL ON FUNCTION public.update_libro_user_settings_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_libro_user_settings_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_libro_user_settings_updated_at() TO service_role;
