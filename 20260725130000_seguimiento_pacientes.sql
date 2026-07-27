-- Seguimiento de pacientes por servicio (hospital + especialidad).
--
-- Nueva vertical del panel de organizaciones: un servicio archiva casos en
-- carpetas, los expone en el pase diario de las 08:00 y comparte recordatorios.
--
-- Decisiones de diseño en losresis-panel/docs/adr:
--   0004  el paciente se identifica solo por NHC, nunca por nombre
--   0005  nota estructurada + detector de nombres que avisa, no bloquea
--   0006  autoría declarada por selector, más creado_por para auditoría
--   0007  el pase es una vista, no una carpeta
--   0008  recordatorio como entidad, con arrastre y archivado
--   0010  ventana del pase: ayer 08:00 -> hoy 08:00
--   0011  el caso es la entidad; la nota es un apunte dentro de él
--   0012  notas editables con historial de versiones
--   0014  RLS REAL aquí (excepción deliberada al allow_all del resto)
--   0015  alta manual + archivado por inactividad
--   0017  sin interruptor: el servicio se crea al entrar
--
-- IMPORTANTE: estas tablas NO llevan políticas allow_all ni permisos para el
-- rol anon. Son datos de salud pseudonimizados. No las "normalices" al patrón
-- del resto de la base.

-- ---------------------------------------------------------------------------
-- 1. Servicio: unidad de aislamiento (hospital + especialidad)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.servicio (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
  speciality_id uuid NOT NULL REFERENCES public.specialities(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT servicio_hospital_speciality_key UNIQUE (hospital_id, speciality_id)
);

-- Permite que caso lleve hospital_id/speciality_id denormalizados (para que la
-- política de RLS no necesite un join) sin que puedan desalinearse.
CREATE UNIQUE INDEX IF NOT EXISTS servicio_id_hospital_speciality_key
  ON public.servicio (id, hospital_id, speciality_id);

-- ---------------------------------------------------------------------------
-- 2. Carpeta: contenedor editable. Se siembra al crear el servicio.
--    "Pase", "Críticos" y "Recordatorios" NO son carpetas: son vistas.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.carpeta (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  servicio_id uuid NOT NULL REFERENCES public.servicio(id) ON DELETE CASCADE,
  nombre text NOT NULL CHECK (btrim(nombre) <> ''),
  posicion integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS carpeta_servicio_idx
  ON public.carpeta (servicio_id, posicion);

-- ---------------------------------------------------------------------------
-- 3. Caso: el seguimiento de un paciente por un servicio.
--    Clave (hospital, especialidad, NHC): la misma persona seguida por dos
--    servicios son dos casos independientes que no se ven entre sí.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.caso (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  servicio_id uuid NOT NULL,
  hospital_id uuid NOT NULL,
  speciality_id uuid NOT NULL,

  -- Identificación del paciente: SOLO el NHC. Nunca nombre ni apellidos.
  nhc text NOT NULL CHECK (btrim(nhc) <> '' AND length(nhc) <= 64),

  sexo text CHECK (sexo IS NULL OR sexo = ANY (ARRAY['mujer', 'hombre', 'otro'])),
  edad smallint CHECK (edad IS NULL OR (edad >= 0 AND edad <= 120)),
  ubicacion text,
  motivo text,

  -- Cómo está el paciente AHORA. Es del caso, no de la nota: un "crítico"
  -- anotado el martes no debe seguir marcándolo el viernes.
  estado text NOT NULL DEFAULT 'estable'
    CHECK (estado = ANY (ARRAY['estable', 'critico'])),

  -- Ciclo de vida (ADR 0015). Ninguno de los dos es borrado.
  alta_en timestamptz,
  archivado_en timestamptz,

  creado_por_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT caso_nhc_servicio_key UNIQUE (servicio_id, nhc),
  CONSTRAINT caso_servicio_fkey
    FOREIGN KEY (servicio_id, hospital_id, speciality_id)
    REFERENCES public.servicio (id, hospital_id, speciality_id)
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS caso_servicio_idx ON public.caso (servicio_id);
CREATE INDEX IF NOT EXISTS caso_scope_idx ON public.caso (hospital_id, speciality_id);
CREATE INDEX IF NOT EXISTS caso_estado_idx
  ON public.caso (servicio_id, estado)
  WHERE archivado_en IS NULL AND alta_en IS NULL;
CREATE INDEX IF NOT EXISTS caso_nhc_idx ON public.caso (servicio_id, nhc);
-- La expresión tiene que ser EXACTAMENTE la que genera PostgREST para
-- `.textSearch("motivo", …, { config: "spanish" })`, o el índice no se usa y
-- solo sirve para dar una falsa sensación de estar optimizado.
CREATE INDEX IF NOT EXISTS caso_busqueda_idx
  ON public.caso
  USING gin (to_tsvector('spanish', motivo));

-- ---------------------------------------------------------------------------
-- 4. Nota: un apunte dentro de un caso.
--    Solo lleva lo que es realmente del apunte: autor declarado y texto.
--    Sexo, edad, ubicación y motivo viven en el caso (ADR 0011): la fricción
--    se paga una vez por paciente, no una vez por nota.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.nota (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  caso_id uuid NOT NULL REFERENCES public.caso(id) ON DELETE CASCADE,
  carpeta_id uuid REFERENCES public.carpeta(id) ON DELETE SET NULL,

  -- Autor DECLARADO: lo elige un selector, se muestra y se busca por él.
  -- No está verificado contra la sesión (ADR 0006).
  autor_declarado_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,

  -- Autor VERIFICADO: la cuenta que ejecutó la petición. No se muestra;
  -- existe para poder responder "¿quién escribió esto realmente?".
  creado_por_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,

  texto text NOT NULL DEFAULT '',

  -- Borrar es retirar con motivo, y la retirada se ve (ADR 0012).
  retirada_en timestamptz,
  retirada_motivo text,
  retirada_por_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT nota_retirada_con_motivo_chk
    CHECK (retirada_en IS NULL OR btrim(coalesce(retirada_motivo, '')) <> '')
);

CREATE INDEX IF NOT EXISTS nota_caso_idx ON public.nota (caso_id, created_at DESC);
CREATE INDEX IF NOT EXISTS nota_carpeta_idx ON public.nota (carpeta_id);
CREATE INDEX IF NOT EXISTS nota_autor_idx ON public.nota (autor_declarado_user_id);
-- La ventana del pase consulta por created_at dentro del servicio; el servicio
-- se resuelve vía caso, así que el índice por fecha global es el que sirve.
CREATE INDEX IF NOT EXISTS nota_created_at_idx ON public.nota (created_at DESC);
CREATE INDEX IF NOT EXISTS nota_busqueda_idx
  ON public.nota
  USING gin (to_tsvector('spanish', texto));

-- ---------------------------------------------------------------------------
-- 5. Historial de versiones: es lo que compensa la edición libre (ADR 0012).
--    Guarda el estado ANTERIOR de la nota en cada UPDATE.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.nota_version (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nota_id uuid NOT NULL REFERENCES public.nota(id) ON DELETE CASCADE,
  caso_id uuid NOT NULL,
  carpeta_id uuid,
  autor_declarado_user_id uuid,
  texto text NOT NULL DEFAULT '',
  -- Cuándo dejó de ser vigente esta versión.
  reemplazada_en timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS nota_version_nota_idx
  ON public.nota_version (nota_id, reemplazada_en DESC);

-- SECURITY DEFINER es imprescindible: authenticated no tiene INSERT sobre
-- nota_version (solo SELECT), así que sin esto cada edición de nota fallaría.
-- El historial lo escribe el sistema, nunca el cliente.
CREATE OR REPLACE FUNCTION public.nota_guardar_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo versionamos cuando cambia algo sustantivo, no en toques de updated_at.
  IF OLD.texto IS DISTINCT FROM NEW.texto
     OR OLD.carpeta_id IS DISTINCT FROM NEW.carpeta_id
     OR OLD.caso_id IS DISTINCT FROM NEW.caso_id
     OR OLD.autor_declarado_user_id IS DISTINCT FROM NEW.autor_declarado_user_id
     OR OLD.retirada_en IS DISTINCT FROM NEW.retirada_en
  THEN
    INSERT INTO public.nota_version (
      nota_id, caso_id, carpeta_id, autor_declarado_user_id, texto
    ) VALUES (
      OLD.id, OLD.caso_id, OLD.carpeta_id, OLD.autor_declarado_user_id, OLD.texto
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_nota_guardar_version ON public.nota;
CREATE TRIGGER trg_nota_guardar_version
BEFORE UPDATE ON public.nota
FOR EACH ROW EXECUTE FUNCTION public.nota_guardar_version();

-- ---------------------------------------------------------------------------
-- 6. Recordatorio: pendiente compartido del servicio (ADR 0008).
--    caso_id nullable: puede ir vinculado a un caso o existir suelto.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.recordatorio (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  servicio_id uuid NOT NULL REFERENCES public.servicio(id) ON DELETE CASCADE,
  caso_id uuid REFERENCES public.caso(id) ON DELETE CASCADE,

  texto text NOT NULL CHECK (btrim(texto) <> ''),
  fecha date NOT NULL DEFAULT CURRENT_DATE,

  -- Destinatario OPCIONAL: sin asignar = "de quien esté de turno", que es el
  -- caso mayoritario en un equipo que rota. Es etiqueta, no permiso:
  -- cualquiera del servicio puede cerrarlo.
  destinatario_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,

  autor_declarado_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  creado_por_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,

  cerrado_en timestamptz,
  cerrado_por_account_id uuid REFERENCES public.employer_account(id) ON DELETE SET NULL,
  cerrado_por_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS recordatorio_servicio_idx
  ON public.recordatorio (servicio_id, fecha);
CREATE INDEX IF NOT EXISTS recordatorio_abiertos_idx
  ON public.recordatorio (servicio_id, fecha)
  WHERE cerrado_en IS NULL;
CREATE INDEX IF NOT EXISTS recordatorio_caso_idx ON public.recordatorio (caso_id);

-- ---------------------------------------------------------------------------
-- 7. updated_at
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_carpeta_updated_at ON public.carpeta;
CREATE TRIGGER trg_carpeta_updated_at
BEFORE UPDATE ON public.carpeta
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at_timestamp_generic();

DROP TRIGGER IF EXISTS trg_caso_updated_at ON public.caso;
CREATE TRIGGER trg_caso_updated_at
BEFORE UPDATE ON public.caso
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at_timestamp_generic();

DROP TRIGGER IF EXISTS trg_nota_updated_at ON public.nota;
CREATE TRIGGER trg_nota_updated_at
BEFORE UPDATE ON public.nota
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at_timestamp_generic();

DROP TRIGGER IF EXISTS trg_recordatorio_updated_at ON public.recordatorio;
CREATE TRIGGER trg_recordatorio_updated_at
BEFORE UPDATE ON public.recordatorio
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at_timestamp_generic();

-- ---------------------------------------------------------------------------
-- 8. Alcance: el acceso clínico viene del ALCANCE, no del rol (ADR 0014).
--    Un owner sin especialidad asignada administra pero no ve contenido.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.seguimiento_tiene_alcance(
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
    JOIN public.employer_account_speciality eas ON eas.account_id = ea.id
    JOIN public.employer_org eo ON eo.id = ea.org_id
    WHERE ea.user_id = auth.uid()
      AND coalesce(ea.is_active, false)
      AND eo.hospital_id = p_hospital_id
      AND eas.speciality_id = p_speciality_id
  );
$$;

REVOKE ALL ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seguimiento_tiene_alcance(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. RLS real. Nada de allow_all, nada de permisos para anon.
-- ---------------------------------------------------------------------------

ALTER TABLE public.servicio ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpeta ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.caso ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nota ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nota_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recordatorio ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS servicio_scope ON public.servicio;
CREATE POLICY servicio_scope ON public.servicio
  FOR ALL TO authenticated
  USING (public.seguimiento_tiene_alcance(hospital_id, speciality_id))
  WITH CHECK (public.seguimiento_tiene_alcance(hospital_id, speciality_id));

DROP POLICY IF EXISTS carpeta_scope ON public.carpeta;
CREATE POLICY carpeta_scope ON public.carpeta
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.servicio s
    WHERE s.id = carpeta.servicio_id
      AND public.seguimiento_tiene_alcance(s.hospital_id, s.speciality_id)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.servicio s
    WHERE s.id = carpeta.servicio_id
      AND public.seguimiento_tiene_alcance(s.hospital_id, s.speciality_id)
  ));

DROP POLICY IF EXISTS caso_scope ON public.caso;
CREATE POLICY caso_scope ON public.caso
  FOR ALL TO authenticated
  USING (public.seguimiento_tiene_alcance(hospital_id, speciality_id))
  WITH CHECK (public.seguimiento_tiene_alcance(hospital_id, speciality_id));

DROP POLICY IF EXISTS nota_scope ON public.nota;
CREATE POLICY nota_scope ON public.nota
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.caso c
    WHERE c.id = nota.caso_id
      AND public.seguimiento_tiene_alcance(c.hospital_id, c.speciality_id)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.caso c
    WHERE c.id = nota.caso_id
      AND public.seguimiento_tiene_alcance(c.hospital_id, c.speciality_id)
  ));

-- El historial se lee, no se escribe desde el cliente: lo escribe el trigger.
DROP POLICY IF EXISTS nota_version_scope ON public.nota_version;
CREATE POLICY nota_version_scope ON public.nota_version
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.nota n
    JOIN public.caso c ON c.id = n.caso_id
    WHERE n.id = nota_version.nota_id
      AND public.seguimiento_tiene_alcance(c.hospital_id, c.speciality_id)
  ));

DROP POLICY IF EXISTS recordatorio_scope ON public.recordatorio;
CREATE POLICY recordatorio_scope ON public.recordatorio
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.servicio s
    WHERE s.id = recordatorio.servicio_id
      AND public.seguimiento_tiene_alcance(s.hospital_id, s.speciality_id)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.servicio s
    WHERE s.id = recordatorio.servicio_id
      AND public.seguimiento_tiene_alcance(s.hospital_id, s.speciality_id)
  ));

-- ---------------------------------------------------------------------------
-- 10. Permisos. anon NO recibe nada: los allow_all del resto de la base son
--     USING (true) sin cláusula TO, es decir TO PUBLIC, y la anon key viaja
--     en el bundle del navegador. Aquí eso sería inaceptable.
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.servicio FROM anon;
REVOKE ALL ON TABLE public.carpeta FROM anon;
REVOKE ALL ON TABLE public.caso FROM anon;
REVOKE ALL ON TABLE public.nota FROM anon;
REVOKE ALL ON TABLE public.nota_version FROM anon;
REVOKE ALL ON TABLE public.recordatorio FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.servicio TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.carpeta TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.caso TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.nota TO authenticated;
GRANT SELECT ON TABLE public.nota_version TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.recordatorio TO authenticated;

GRANT ALL ON TABLE public.servicio TO service_role;
GRANT ALL ON TABLE public.carpeta TO service_role;
GRANT ALL ON TABLE public.caso TO service_role;
GRANT ALL ON TABLE public.nota TO service_role;
GRANT ALL ON TABLE public.nota_version TO service_role;
GRANT ALL ON TABLE public.recordatorio TO service_role;

-- ---------------------------------------------------------------------------
-- 11. Alta perezosa del servicio con siembra de carpetas (ADR 0017).
--     "Activar" no es un flag: es que exista la fila.
--     Las carpetas sembradas son ubicaciones (el "dónde") y son editables.
--     Pase, Críticos y Recordatorios NO se siembran: son vistas.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.seguimiento_ensure_servicio(
  p_hospital_id uuid,
  p_speciality_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_servicio_id uuid;
  v_nombre text;
  v_posicion integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF NOT public.seguimiento_tiene_alcance(p_hospital_id, p_speciality_id) THEN
    RAISE EXCEPTION 'sin_alcance_de_especialidad'
      USING ERRCODE = 'P0001',
            HINT = 'La cuenta no tiene esta especialidad en su alcance.';
  END IF;

  SELECT id INTO v_servicio_id
  FROM public.servicio
  WHERE hospital_id = p_hospital_id
    AND speciality_id = p_speciality_id;

  IF v_servicio_id IS NOT NULL THEN
    RETURN v_servicio_id;
  END IF;

  INSERT INTO public.servicio (hospital_id, speciality_id)
  VALUES (p_hospital_id, p_speciality_id)
  ON CONFLICT (hospital_id, speciality_id) DO NOTHING
  RETURNING id INTO v_servicio_id;

  -- Carrera entre dos miembros entrando a la vez.
  IF v_servicio_id IS NULL THEN
    SELECT id INTO v_servicio_id
    FROM public.servicio
    WHERE hospital_id = p_hospital_id
      AND speciality_id = p_speciality_id;
    RETURN v_servicio_id;
  END IF;

  FOREACH v_nombre IN ARRAY ARRAY['Urgencias', 'Guardias', 'Planta', 'Consulta']
  LOOP
    INSERT INTO public.carpeta (servicio_id, nombre, posicion)
    VALUES (v_servicio_id, v_nombre, v_posicion);
    v_posicion := v_posicion + 1;
  END LOOP;

  RETURN v_servicio_id;
END;
$$;

REVOKE ALL ON FUNCTION public.seguimiento_ensure_servicio(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.seguimiento_ensure_servicio(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seguimiento_ensure_servicio(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 12. Archivado por inactividad (ADR 0015).
--     Archivar NO es borrar: el caso sigue buscable y una nota nueva lo
--     reactiva. Un caso CRÍTICO no se archiva solo: 30 días crítico sin notas
--     no es inactividad, es información, y se muestra destacado.
--     Se invoca desde la lectura del servicio; no necesita cron.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.seguimiento_archivar_inactivos(
  p_servicio_id uuid,
  p_dias integer DEFAULT 30
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_hospital_id uuid;
  v_speciality_id uuid;
  v_archivados integer;
BEGIN
  SELECT hospital_id, speciality_id
  INTO v_hospital_id, v_speciality_id
  FROM public.servicio
  WHERE id = p_servicio_id;

  IF v_hospital_id IS NULL THEN
    RETURN 0;
  END IF;

  IF NOT public.seguimiento_tiene_alcance(v_hospital_id, v_speciality_id) THEN
    RAISE EXCEPTION 'sin_alcance_de_especialidad' USING ERRCODE = 'P0001';
  END IF;

  WITH inactivos AS (
    SELECT c.id
    FROM public.caso c
    WHERE c.servicio_id = p_servicio_id
      AND c.archivado_en IS NULL
      AND c.alta_en IS NULL
      AND c.estado <> 'critico'
      AND greatest(
            c.created_at,
            coalesce((SELECT max(n.created_at) FROM public.nota n WHERE n.caso_id = c.id), c.created_at)
          ) < now() - make_interval(days => p_dias)
  )
  UPDATE public.caso c
  SET archivado_en = now()
  FROM inactivos i
  WHERE c.id = i.id;

  GET DIAGNOSTICS v_archivados = ROW_COUNT;
  RETURN v_archivados;
END;
$$;

REVOKE ALL ON FUNCTION public.seguimiento_archivar_inactivos(uuid, integer) FROM public;
GRANT EXECUTE ON FUNCTION public.seguimiento_archivar_inactivos(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seguimiento_archivar_inactivos(uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- PENDIENTE, a propósito (ver docs/adr/0016):
--   * purga de casos archivados con más de N años -> falta decidir N
--   * borrado a los 60 días de la baja de suscripción -> falta el modelo de
--     facturación de esta vertical, aparcado deliberadamente
-- No se implementan aquí para no inventar plazos sobre datos de salud.
-- ---------------------------------------------------------------------------
