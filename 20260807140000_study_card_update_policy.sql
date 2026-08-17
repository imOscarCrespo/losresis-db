-- Study cards: allow editing classification after creation
--
-- The card detail screen now lets the student change the speciality and
-- topics of a saved card, so the owner needs UPDATE on their own rows.

CREATE POLICY "study photo cards update own"
  ON public.study_photo_cards
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT UPDATE ON public.study_photo_cards TO authenticated;
