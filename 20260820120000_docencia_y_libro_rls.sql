-- ---------------------------------------------------------------------------
-- RLS del Libro del Residente y de los módulos de Docencia.
--
-- Punto de partida: TODAS estas tablas estaban con `USING (true)`. Con la app
-- móvil a punto de leerlas, eso deja de ser teórico: la clave anon viaja en el
-- binario, así que cualquier residente podría leer —y en el Libro, ESCRIBIR— el
-- libro, las tutorías, las evaluaciones y las autoevaluaciones de cualquier otro.
--
-- El criterio es el mismo en todas: dos brazos, y ninguno más.
--
--   1. El residente, sobre lo suyo (`auth.uid()`).
--   2. La cuenta de panel con alcance sobre ese hospital y esa especialidad.
--
-- Deliberadamente NO se reutiliza `seguimiento_tiene_alcance`: su segundo brazo
-- da acceso a cualquier residente o médico del hospital+especialidad, que es
-- correcto para Seguimiento de Pacientes (equipo clínico, ADR 0018) y es
-- exactamente la fuga que aquí hay que cerrar. Docencia tiene su propio helper.
--
-- `shared_at` no se puede aplicar con RLS, que es por filas y no por columnas: el
-- residente tiene que ver que existe una tutoría futura (aparece en su Agenda y en
-- su tarjeta de "próxima tutoría") sin ver las notas de trabajo del tutor. Para eso
-- van dos vistas que enmascaran el contenido, y el residente NO lee las tablas.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Quién es "Docencia" para un hospital y una especialidad.
--
-- owner y editor son Docencia y ven todo su hospital; speciality_manager es tutor
-- y solo ve las especialidades que tiene en su alcance.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.has_teaching_scope(
  p_hospital_id uuid,
  p_speciality_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.employer_account ea
    JOIN public.employer_org eo ON eo.id = ea.org_id
    WHERE ea.user_id = auth.uid()
      AND coalesce(ea.is_active, false)
      AND eo.hospital_id = p_hospital_id
      AND (
        ea.role IN ('owner', 'editor')
        OR EXISTS (
          SELECT 1
          FROM public.employer_account_speciality eas
          WHERE eas.account_id = ea.id
            AND eas.speciality_id = p_speciality_id
        )
      )
  );
$$;

-- El mismo alcance, resuelto desde el residente. Las tablas del Libro no llevan
-- hospital ni especialidad: llevan user_id.
CREATE OR REPLACE FUNCTION public.has_teaching_scope_for_user(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND public.has_teaching_scope(u.hospital_id, u.speciality_id)
  );
$$;

GRANT ALL ON FUNCTION public.has_teaching_scope(uuid, uuid) TO anon;
GRANT ALL ON FUNCTION public.has_teaching_scope(uuid, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.has_teaching_scope(uuid, uuid) TO service_role;
GRANT ALL ON FUNCTION public.has_teaching_scope_for_user(uuid) TO anon;
GRANT ALL ON FUNCTION public.has_teaching_scope_for_user(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.has_teaching_scope_for_user(uuid) TO service_role;

-- Un comunicado no va a UNA especialidad sino a varias: hospital_announcement
-- guarda speciality_ids uuid[]. Un comunicado sin especialidades es "a todo el
-- hospital", y ahí solo llega Docencia.
CREATE OR REPLACE FUNCTION public.has_teaching_scope_any(
  p_hospital_id uuid,
  p_speciality_ids uuid[]
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.employer_account ea
    JOIN public.employer_org eo ON eo.id = ea.org_id
    WHERE ea.user_id = auth.uid()
      AND coalesce(ea.is_active, false)
      AND eo.hospital_id = p_hospital_id
      AND (
        ea.role IN ('owner', 'editor')
        OR EXISTS (
          SELECT 1
          FROM public.employer_account_speciality eas
          WHERE eas.account_id = ea.id
            AND eas.speciality_id = ANY (coalesce(p_speciality_ids, '{}'::uuid[]))
        )
      )
  );
$$;

GRANT ALL ON FUNCTION public.has_teaching_scope_any(uuid, uuid[]) TO anon;
GRANT ALL ON FUNCTION public.has_teaching_scope_any(uuid, uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.has_teaching_scope_any(uuid, uuid[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. La plantilla del Libro.
--
-- El residente la LEE (la app pinta el plan de su tutor en solo lectura) pero solo
-- la publicada de su hospital y especialidad. Escribirla es cosa del panel.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS allow_all_libro_template ON public.libro_template;

CREATE POLICY libro_template_panel ON public.libro_template
  FOR ALL
  USING (public.has_teaching_scope(hospital_id, speciality_id))
  WITH CHECK (public.has_teaching_scope(hospital_id, speciality_id));

CREATE POLICY libro_template_resident_read ON public.libro_template
  FOR SELECT
  USING (
    is_published
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.hospital_id = libro_template.hospital_id
        AND u.speciality_id = libro_template.speciality_id
    )
  );

DROP POLICY IF EXISTS allow_all_libro_template_block ON public.libro_template_block;

CREATE POLICY libro_template_block_panel ON public.libro_template_block
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.libro_template t
      WHERE t.id = libro_template_block.template_id
        AND public.has_teaching_scope(t.hospital_id, t.speciality_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.libro_template t
      WHERE t.id = libro_template_block.template_id
        AND public.has_teaching_scope(t.hospital_id, t.speciality_id)
    )
  );

-- El bloque lo lee el residente porque `config` es lo que la app necesita para
-- montar el formulario del arquetipo `form`, y se lee EN VIVO de la plantilla: no
-- se clona al libro.
CREATE POLICY libro_template_block_resident_read ON public.libro_template_block
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.libro_template t
      JOIN public.users u ON u.id = auth.uid()
      WHERE t.id = libro_template_block.template_id
        AND t.is_published
        AND u.hospital_id = t.hospital_id
        AND u.speciality_id = t.speciality_id
    )
  );

DROP POLICY IF EXISTS allow_all_libro_template_node ON public.libro_template_node;

CREATE POLICY libro_template_node_panel ON public.libro_template_node
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.libro_template t
      WHERE t.id = libro_template_node.template_id
        AND public.has_teaching_scope(t.hospital_id, t.speciality_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.libro_template t
      WHERE t.id = libro_template_node.template_id
        AND public.has_teaching_scope(t.hospital_id, t.speciality_id)
    )
  );

CREATE POLICY libro_template_node_resident_read ON public.libro_template_node
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.libro_template t
      JOIN public.users u ON u.id = auth.uid()
      WHERE t.id = libro_template_node.template_id
        AND t.is_published
        AND u.hospital_id = t.hospital_id
        AND u.speciality_id = t.speciality_id
    )
  );

-- ---------------------------------------------------------------------------
-- 3. El libro del residente.
--
-- Escribe él y solo él: registrar actividad, montar su Libro propio, archivar. El
-- panel lo LEE (la pantalla de Residentes del tutor) y no lo escribe: sembrar y
-- reconciliar es cosa de apply_/sync_libro_template_for_user, que son
-- SECURITY DEFINER y no pasan por aquí.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS allow_all_libro_book ON public.libro_book;

CREATE POLICY libro_book_owner ON public.libro_book
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY libro_book_panel_read ON public.libro_book
  FOR SELECT
  USING (public.has_teaching_scope_for_user(user_id));

DROP POLICY IF EXISTS allow_all_libro_node ON public.libro_node;

CREATE POLICY libro_node_owner ON public.libro_node
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY libro_node_panel_read ON public.libro_node
  FOR SELECT
  USING (public.has_teaching_scope_for_user(user_id));

-- libro_entry no tiene user_id: cuelga de un nodo (itinerary y tree) o del libro
-- (form, book_id). Hay que mirar las dos vías.
DROP POLICY IF EXISTS allow_all_libro_entry ON public.libro_entry;

CREATE POLICY libro_entry_owner ON public.libro_entry
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.libro_node n
      WHERE n.id = libro_entry.node_id AND n.user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM public.libro_book b
      WHERE b.id = libro_entry.book_id AND b.user_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.libro_node n
      WHERE n.id = libro_entry.node_id AND n.user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM public.libro_book b
      WHERE b.id = libro_entry.book_id AND b.user_id = auth.uid()
    )
  );

CREATE POLICY libro_entry_panel_read ON public.libro_entry
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.libro_node n
      WHERE n.id = libro_entry.node_id
        AND public.has_teaching_scope_for_user(n.user_id)
    )
    OR EXISTS (
      SELECT 1 FROM public.libro_book b
      WHERE b.id = libro_entry.book_id
        AND public.has_teaching_scope_for_user(b.user_id)
    )
  );

-- La ficha del arquetipo itinerary. El residente escribe su parte (payload); el
-- NIVEL de una competencia lo pone el tutor y pasa por set_evaluation_competency,
-- que es SECURITY DEFINER: el tutor no necesita escribir aquí directamente.
DROP POLICY IF EXISTS allow_all_libro_node_progress ON public.libro_node_progress;

CREATE POLICY libro_node_progress_owner ON public.libro_node_progress
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY libro_node_progress_panel_read ON public.libro_node_progress
  FOR SELECT
  USING (public.has_teaching_scope_for_user(user_id));

DROP POLICY IF EXISTS allow_all_libro_user_settings ON public.libro_user_settings;

CREATE POLICY libro_user_settings_owner ON public.libro_user_settings
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- libro_event está muerta (0 filas, ADR 0025 del panel). No se revive, pero
-- tampoco se deja abierta.
DROP POLICY IF EXISTS allow_all_libro_event ON public.libro_event;

CREATE POLICY libro_event_owner ON public.libro_event
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- libro_section es catálogo (5 filas fijas): se lee, no se escribe.
DROP POLICY IF EXISTS allow_all_libro_section ON public.libro_section;

CREATE POLICY libro_section_read ON public.libro_section
  FOR SELECT
  USING (true);

-- ---------------------------------------------------------------------------
-- 4. Los módulos de Docencia.
--
-- Las tablas quedan SOLO para el panel. El residente las lee por las vistas de
-- abajo, que es lo que hace cumplir `shared_at`.
--
-- Todas las acciones del residente (enviar la autoevaluación) van por RPC
-- SECURITY DEFINER, así que no necesita escribir en ninguna.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS allow_all_hospital_tutoring ON public.hospital_tutoring;

CREATE POLICY hospital_tutoring_panel ON public.hospital_tutoring
  FOR ALL
  USING (public.has_teaching_scope(hospital_id, speciality_id))
  WITH CHECK (public.has_teaching_scope(hospital_id, speciality_id));

DROP POLICY IF EXISTS allow_all_hospital_tutoring_attachment
  ON public.hospital_tutoring_attachment;

CREATE POLICY hospital_tutoring_attachment_panel
  ON public.hospital_tutoring_attachment
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_tutoring t
      WHERE t.id = hospital_tutoring_attachment.tutoring_id
        AND public.has_teaching_scope(t.hospital_id, t.speciality_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.hospital_tutoring t
      WHERE t.id = hospital_tutoring_attachment.tutoring_id
        AND public.has_teaching_scope(t.hospital_id, t.speciality_id)
    )
  );

-- El adjunto de una tutoría sí se puede dar por filas: o está compartida o no.
CREATE POLICY hospital_tutoring_attachment_resident_read
  ON public.hospital_tutoring_attachment
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_tutoring t
      WHERE t.id = hospital_tutoring_attachment.tutoring_id
        AND t.resident_user_id = auth.uid()
        AND t.shared_at IS NOT NULL
    )
  );

DROP POLICY IF EXISTS allow_all_hospital_evaluation ON public.hospital_evaluation;

CREATE POLICY hospital_evaluation_panel ON public.hospital_evaluation
  FOR ALL
  USING (public.has_teaching_scope(hospital_id, speciality_id))
  WITH CHECK (public.has_teaching_scope(hospital_id, speciality_id));

DROP POLICY IF EXISTS allow_all_hospital_evaluation_attachment
  ON public.hospital_evaluation_attachment;

CREATE POLICY hospital_evaluation_attachment_panel
  ON public.hospital_evaluation_attachment
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_evaluation e
      WHERE e.id = hospital_evaluation_attachment.evaluation_id
        AND public.has_teaching_scope(e.hospital_id, e.speciality_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.hospital_evaluation e
      WHERE e.id = hospital_evaluation_attachment.evaluation_id
        AND public.has_teaching_scope(e.hospital_id, e.speciality_id)
    )
  );

CREATE POLICY hospital_evaluation_attachment_resident_read
  ON public.hospital_evaluation_attachment
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_evaluation e
      WHERE e.id = hospital_evaluation_attachment.evaluation_id
        AND e.resident_user_id = auth.uid()
        AND e.shared_at IS NOT NULL
    )
  );

DROP POLICY IF EXISTS allow_all_hospital_evaluation_competency
  ON public.hospital_evaluation_competency;

CREATE POLICY hospital_evaluation_competency_panel
  ON public.hospital_evaluation_competency
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_evaluation e
      WHERE e.id = hospital_evaluation_competency.evaluation_id
        AND public.has_teaching_scope(e.hospital_id, e.speciality_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.hospital_evaluation e
      WHERE e.id = hospital_evaluation_competency.evaluation_id
        AND public.has_teaching_scope(e.hospital_id, e.speciality_id)
    )
  );

CREATE POLICY hospital_evaluation_competency_resident_read
  ON public.hospital_evaluation_competency
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_evaluation e
      WHERE e.id = hospital_evaluation_competency.evaluation_id
        AND e.resident_user_id = auth.uid()
        AND e.shared_at IS NOT NULL
    )
  );

-- La autoevaluación no se enmascara: la rellena el residente, es suya de principio
-- a fin. Solo lectura, porque enviarla va por submit_hospital_self_assessment.
DROP POLICY IF EXISTS allow_all_hospital_self_assessment
  ON public.hospital_self_assessment;

CREATE POLICY hospital_self_assessment_panel ON public.hospital_self_assessment
  FOR ALL
  USING (public.has_teaching_scope(hospital_id, speciality_id))
  WITH CHECK (public.has_teaching_scope(hospital_id, speciality_id));

CREATE POLICY hospital_self_assessment_resident_read
  ON public.hospital_self_assessment
  FOR SELECT
  USING (resident_user_id = auth.uid());

-- Comunicados: el residente ve los que le han llegado, nunca el borrador ni la
-- lista de destinatarios de los demás.
DROP POLICY IF EXISTS allow_all_hospital_announcement ON public.hospital_announcement;

CREATE POLICY hospital_announcement_panel ON public.hospital_announcement
  FOR ALL
  USING (public.has_teaching_scope_any(hospital_id, speciality_ids))
  WITH CHECK (public.has_teaching_scope_any(hospital_id, speciality_ids));

CREATE POLICY hospital_announcement_resident_read ON public.hospital_announcement
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_announcement_recipient r
      WHERE r.announcement_id = hospital_announcement.id
        AND r.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS allow_all_hospital_announcement_recipient
  ON public.hospital_announcement_recipient;

CREATE POLICY hospital_announcement_recipient_panel
  ON public.hospital_announcement_recipient
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.hospital_announcement a
      WHERE a.id = hospital_announcement_recipient.announcement_id
        AND public.has_teaching_scope_any(a.hospital_id, a.speciality_ids)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.hospital_announcement a
      WHERE a.id = hospital_announcement_recipient.announcement_id
        AND public.has_teaching_scope_any(a.hospital_id, a.speciality_ids)
    )
  );

CREATE POLICY hospital_announcement_recipient_owner
  ON public.hospital_announcement_recipient
  FOR SELECT
  USING (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 5. Las vistas del residente, que es donde se aplica `shared_at`.
--
-- Son SECURITY DEFINER (el comportamiento por defecto de una vista: NO se les pone
-- security_invoker) justamente para que el residente no necesite —ni tenga—
-- permiso sobre la tabla. Filtran por auth.uid() y anulan el contenido mientras el
-- tutor no lo haya compartido, de forma que la app pueda enseñar que existe una
-- tutoría futura sin enseñar las notas de trabajo del tutor.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.hospital_tutoring_for_resident AS
SELECT
  t.id,
  t.hospital_id,
  t.resident_user_id,
  t.tutor_name,
  t.speciality_id,
  t.residency_year,
  t.tutoring_type,
  t.scheduled_at,
  t.place,
  t.status,
  t.shared_at,
  t.finished_at,
  t.cancelled_at,
  t.agenda_event_id,
  t.created_at,
  (t.shared_at IS NOT NULL) AS is_shared,
  CASE WHEN t.shared_at IS NOT NULL THEN t.topics END AS topics,
  CASE WHEN t.shared_at IS NOT NULL THEN t.competencies_reviewed END
    AS competencies_reviewed,
  CASE WHEN t.shared_at IS NOT NULL THEN t.goals_achieved END AS goals_achieved,
  CASE WHEN t.shared_at IS NOT NULL THEN t.improvements END AS improvements,
  CASE WHEN t.shared_at IS NOT NULL THEN t.next_goals END AS next_goals,
  CASE WHEN t.shared_at IS NOT NULL THEN t.notes END AS notes
FROM public.hospital_tutoring t
WHERE t.resident_user_id = auth.uid();

CREATE OR REPLACE VIEW public.hospital_evaluation_for_resident AS
SELECT
  e.id,
  e.hospital_id,
  e.resident_user_id,
  e.tutor_name,
  e.speciality_id,
  e.residency_year,
  e.evaluation_type,
  e.period_label,
  e.period_start,
  e.period_end,
  e.rotation_node_id,
  e.evaluation_date,
  e.status,
  e.shared_at,
  e.finished_at,
  e.created_at,
  CASE WHEN e.shared_at IS NOT NULL THEN e.competencies_reviewed END
    AS competencies_reviewed,
  CASE WHEN e.shared_at IS NOT NULL THEN e.goals_achieved END AS goals_achieved,
  CASE WHEN e.shared_at IS NOT NULL THEN e.improvements END AS improvements,
  CASE WHEN e.shared_at IS NOT NULL THEN e.tutor_comments END AS tutor_comments,
  CASE WHEN e.shared_at IS NOT NULL THEN e.overall_rating END AS overall_rating
FROM public.hospital_evaluation e
WHERE e.resident_user_id = auth.uid()
  AND e.shared_at IS NOT NULL;

GRANT SELECT ON public.hospital_tutoring_for_resident TO anon;
GRANT SELECT ON public.hospital_tutoring_for_resident TO authenticated;
GRANT SELECT ON public.hospital_tutoring_for_resident TO service_role;
GRANT SELECT ON public.hospital_evaluation_for_resident TO anon;
GRANT SELECT ON public.hospital_evaluation_for_resident TO authenticated;
GRANT SELECT ON public.hospital_evaluation_for_resident TO service_role;

COMMENT ON VIEW public.hospital_tutoring_for_resident IS
  'La tutoría como la ve el residente: siempre la cita, el contenido solo desde shared_at.';
COMMENT ON VIEW public.hospital_evaluation_for_resident IS
  'Las evaluaciones compartidas con el residente. Las escribe el tutor; él solo lee.';
