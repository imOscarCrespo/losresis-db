DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'libro_book_status'
  ) THEN
    CREATE TYPE public.libro_book_status AS ENUM ('active', 'archived');
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.libro_book (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  section public.libro_section_code NOT NULL,
  residency_year smallint NOT NULL CHECK (residency_year BETWEEN 1 AND 8),
  status public.libro_book_status NOT NULL DEFAULT 'active',
  archived_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE public.libro_book ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_all_libro_book ON public.libro_book;

CREATE POLICY allow_all_libro_book
ON public.libro_book
USING (true)
WITH CHECK (true);

GRANT ALL ON TABLE public.libro_book TO anon;
GRANT ALL ON TABLE public.libro_book TO authenticated;
GRANT ALL ON TABLE public.libro_book TO service_role;

CREATE OR REPLACE FUNCTION public.update_libro_book_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_libro_book_updated_at ON public.libro_book;

CREATE TRIGGER trigger_update_libro_book_updated_at
BEFORE UPDATE ON public.libro_book
FOR EACH ROW
EXECUTE FUNCTION public.update_libro_book_updated_at();

GRANT ALL ON FUNCTION public.update_libro_book_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_libro_book_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_libro_book_updated_at() TO service_role;

CREATE UNIQUE INDEX IF NOT EXISTS libro_book_one_active_per_user_section_idx
ON public.libro_book (user_id, section)
WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS libro_book_unique_year_per_user_section_idx
ON public.libro_book (user_id, section, residency_year);

ALTER TABLE public.libro_node
  ADD COLUMN IF NOT EXISTS book_id uuid REFERENCES public.libro_book(id) ON DELETE CASCADE;

UPDATE public.libro_node
SET section = 'clinical_practice'::public.libro_section_code
WHERE section IS NULL;

INSERT INTO public.libro_book (user_id, section, residency_year, status)
SELECT DISTINCT
  node.user_id,
  node.section,
  GREATEST(COALESCE(user_profile.resident_year, 1), 1)::smallint,
  'active'::public.libro_book_status
FROM public.libro_node AS node
LEFT JOIN public.users AS user_profile
  ON user_profile.id = node.user_id
WHERE node.book_id IS NULL
  AND node.section IS NOT NULL
ON CONFLICT (user_id, section, residency_year) DO NOTHING;

UPDATE public.libro_node AS node
SET book_id = (
  SELECT book.id
  FROM public.libro_book AS book
  WHERE book.user_id = node.user_id
    AND book.section = node.section
  ORDER BY
    CASE WHEN book.status = 'active' THEN 0 ELSE 1 END,
    book.created_at DESC,
    book.id DESC
  LIMIT 1
)
WHERE node.book_id IS NULL
  AND node.section IS NOT NULL;

INSERT INTO public.libro_book (user_id, section, residency_year, status)
SELECT DISTINCT
  node.user_id,
  node.section,
  1,
  'active'::public.libro_book_status
FROM public.libro_node AS node
WHERE node.book_id IS NULL
  AND node.section IS NOT NULL
ON CONFLICT (user_id, section)
WHERE status = 'active'
DO NOTHING;

UPDATE public.libro_node AS node
SET book_id = (
  SELECT book.id
  FROM public.libro_book AS book
  WHERE book.user_id = node.user_id
    AND book.section = node.section
  ORDER BY
    CASE WHEN book.status = 'active' THEN 0 ELSE 1 END,
    book.created_at DESC,
    book.id DESC
  LIMIT 1
)
WHERE node.book_id IS NULL
  AND node.section IS NOT NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.libro_node
    WHERE book_id IS NULL
  ) THEN
    RAISE EXCEPTION 'libro_node backfill did not assign book_id for every row';
  END IF;
END
$$;

ALTER TABLE public.libro_node
  ALTER COLUMN book_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS libro_node_book_id_idx
ON public.libro_node (book_id);

CREATE OR REPLACE FUNCTION public.archive_libro_book_and_start_new_year(
  p_user_id uuid,
  p_section public.libro_section_code,
  p_next_residency_year integer
)
RETURNS public.libro_book
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_book public.libro_book;
  next_book public.libro_book;
BEGIN
  IF p_user_id IS NULL OR p_section IS NULL OR p_next_residency_year IS NULL THEN
    RAISE EXCEPTION 'user_id, section and next_residency_year are required';
  END IF;

  SELECT *
  INTO current_book
  FROM public.libro_book
  WHERE user_id = p_user_id
    AND section = p_section
    AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active libro book not found';
  END IF;

  IF p_next_residency_year <= current_book.residency_year THEN
    RAISE EXCEPTION 'next_residency_year must be greater than the active book year';
  END IF;

  UPDATE public.libro_book
  SET status = 'archived',
      archived_at = now()
  WHERE id = current_book.id;

  INSERT INTO public.libro_book (
    user_id,
    section,
    residency_year,
    status,
    archived_at
  )
  VALUES (
    p_user_id,
    p_section,
    p_next_residency_year::smallint,
    'active',
    NULL
  )
  RETURNING * INTO next_book;

  RETURN next_book;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'A libro already exists for year %', p_next_residency_year;
END;
$$;

GRANT ALL ON FUNCTION public.archive_libro_book_and_start_new_year(uuid, public.libro_section_code, integer) TO anon;
GRANT ALL ON FUNCTION public.archive_libro_book_and_start_new_year(uuid, public.libro_section_code, integer) TO authenticated;
GRANT ALL ON FUNCTION public.archive_libro_book_and_start_new_year(uuid, public.libro_section_code, integer) TO service_role;
