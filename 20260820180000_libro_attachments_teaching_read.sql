-- ---------------------------------------------------------------------------
-- Docencia puede abrir los adjuntos del Libro de los residentes de su alcance.
--
-- El bucket `libro-attachments` solo tenía políticas de dueño
-- (`(storage.foldername(name))[1] = auth.uid()`), así que el residente subía un
-- certificado y el tutor —que había activado la casilla «Documento adjunto» desde el
-- panel precisamente para verlo— no podía abrirlo nunca. El campo existía sin
-- cumplir su función, y por eso la app lo tenía como un simple texto.
--
-- El alcance es el mismo que el del Libro: `has_teaching_scope_for_user` sobre el
-- dueño de la carpeta, así que un tutor solo abre los de sus especialidades.
--
-- La ruta pasa a ser `{user_id}/{apartado}/{fichero}`. El segundo segmento no lo usa
-- esta política: está ahí a propósito, para poder estrechar el acceso por apartado
-- más adelante sin tener que mover ficheros ya subidos.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS libro_attachments_teaching_read ON storage.objects;

CREATE POLICY libro_attachments_teaching_read
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'libro-attachments'
  -- El guard del formato evita que una carpeta que no sea un uuid reviente el cast.
  AND (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  AND public.has_teaching_scope_for_user(((storage.foldername(name))[1])::uuid)
);
