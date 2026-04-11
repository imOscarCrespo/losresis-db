ALTER TABLE public.app_versions
ADD COLUMN IF NOT EXISTS is_force_update boolean NOT NULL DEFAULT false;
