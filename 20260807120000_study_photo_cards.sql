-- Study photo cards
--
-- Students photograph an exam question (or study note) they don't understand,
-- the app sends it to the LLM (losresis-llm edge function, mode "estudio") and
-- the resulting explanation can be saved as a review card.
--
-- Access is gated per user with the existing can_use_feature RPC using the
-- feature key 'photo_study_analysis' (rows in public.user_feature_access are
-- granted manually, same operational model as 'clinical_assistant_chat').

-- =============================================================================
-- 1. Table: saved cards
-- =============================================================================

CREATE TABLE public.study_photo_cards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  -- Path inside the 'study-photo-uploads' bucket (public URL derived at render).
  image_path text NOT NULL,
  -- Question/topic transcribed by the model from the image (card preview).
  extracted_question text,
  -- Full markdown explanation returned by the model.
  explanation text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX study_photo_cards_user_created_idx
  ON public.study_photo_cards (user_id, created_at DESC);

-- =============================================================================
-- 2. RLS: students manage only their own cards
-- =============================================================================

ALTER TABLE public.study_photo_cards ENABLE ROW LEVEL SECURITY;

CREATE POLICY "study photo cards select own"
  ON public.study_photo_cards
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "study photo cards insert own"
  ON public.study_photo_cards
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid() AND public.is_student_user());

CREATE POLICY "study photo cards delete own"
  ON public.study_photo_cards
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.study_photo_cards TO authenticated;
GRANT ALL ON public.study_photo_cards TO service_role;

-- =============================================================================
-- 3. Storage bucket: user-uploaded study photos
--    Unlike 'mir-question-images' (service-role writes only), here the student
--    uploads directly, so INSERT is allowed restricted to their own folder.
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'study-photo-uploads',
  'study-photo-uploads',
  true,
  5242880, -- 5 MB
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic']
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE POLICY "study photo uploads public read"
  ON storage.objects
  FOR SELECT
  TO public
  USING (bucket_id = 'study-photo-uploads');

CREATE POLICY "study photo uploads insert own folder"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'study-photo-uploads'
    AND (storage.foldername(name))[1] = auth.uid()::text
    AND public.is_student_user()
  );

CREATE POLICY "study photo uploads delete own folder"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'study-photo-uploads'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
