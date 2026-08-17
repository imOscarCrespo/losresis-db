-- Study card classification
--
-- When saving a study photo card the student can now tag it with a speciality
-- (name from the specialities catalog) and free-form topics, so the "Mis
-- tarjetas" list can be filtered and reviewed by subject.

ALTER TABLE public.study_photo_cards
  ADD COLUMN speciality text,
  ADD COLUMN topics text[] NOT NULL DEFAULT '{}';
