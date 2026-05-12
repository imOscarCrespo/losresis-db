-- Add columns to track courses ingested from external sources (e.g. Kimi/Moonshot)
-- so the weekly bot can deduplicate across runs and avoid firing duplicate
-- speciality notifications via trg_notify_course_published.

ALTER TABLE public.courses
  ADD COLUMN IF NOT EXISTS source text,
  ADD COLUMN IF NOT EXISTS external_id text;

CREATE UNIQUE INDEX IF NOT EXISTS courses_source_external_id_key
  ON public.courses (source, external_id)
  WHERE source IS NOT NULL AND external_id IS NOT NULL;
