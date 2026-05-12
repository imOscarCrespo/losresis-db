begin;

alter table public.speciality_quiz_question
  add column if not exists quiz_version text;

update public.speciality_quiz_question
set quiz_version = coalesce(quiz_version, 'v2_profiles_abcd')
where quiz_version is null;

alter table public.speciality_quiz_question
  alter column quiz_version set default 'v2_profiles_abcd';

alter table public.speciality_quiz_question
  alter column quiz_version set not null;

create table if not exists public.speciality_profile_vector (
  id uuid primary key default gen_random_uuid(),
  speciality_key text not null,
  quiz_version text not null,
  name text not null,
  category text not null,
  profile_a numeric(5,2) not null,
  profile_b numeric(5,2) not null,
  profile_c numeric(5,2) not null,
  profile_d numeric(5,2) not null,
  created_at timestamptz not null default now(),
  constraint speciality_profile_vector_quiz_key_unique unique (speciality_key, quiz_version),
  constraint speciality_profile_vector_speciality_key_fkey
    foreign key (speciality_key)
    references public.speciality_profile (speciality_key)
    on delete cascade,
  constraint speciality_profile_vector_profiles_nonnegative check (
    profile_a >= 0 and profile_b >= 0 and profile_c >= 0 and profile_d >= 0
  )
);

create index if not exists idx_speciality_profile_vector_quiz_version
  on public.speciality_profile_vector (quiz_version);

with profile_catalog (
  speciality_key,
  name,
  category,
  description,
  profile_a,
  profile_b,
  profile_c,
  profile_d
) as (
  values
    ('medicina_interna', 'Medicina Interna', 'medica', 'Perfil clínico generalista con fuerte orientación diagnóstica y visión integral del paciente.', 45, 10, 30, 15),
    ('cardiologia', 'Cardiología', 'medica', 'Especialidad médica con mezcla de razonamiento clínico, procedimientos y toma de decisiones agudas.', 35, 30, 20, 15),
    ('neumologia', 'Neumología', 'medica', 'Perfil médico analítico con componente técnico moderado y continuidad asistencial.', 40, 20, 25, 15),
    ('aparato_digestivo', 'Aparato Digestivo', 'medica', 'Especialidad médica con equilibrio entre razonamiento clínico y procedimientos diagnósticos o terapéuticos.', 35, 30, 20, 15),
    ('nefrologia', 'Nefrología', 'medica', 'Orientación diagnóstica y fisiopatológica con seguimiento longitudinal de pacientes complejos.', 40, 20, 25, 15),
    ('endocrinologia_nutricion', 'Endocrinología y Nutrición', 'medica', 'Especialidad médica reflexiva con peso en seguimiento longitudinal y componente académico.', 40, 10, 30, 20),
    ('reumatologia', 'Reumatología', 'medica', 'Especialidad de alta incertidumbre diagnóstica y relación longitudinal con el paciente.', 45, 10, 30, 15),
    ('neurologia', 'Neurología', 'medica', 'Perfil fuertemente diagnóstico, centrado en complejidad clínica y razonamiento profundo.', 45, 15, 25, 15),
    ('hematologia_hemoterapia', 'Hematología y Hemoterapia', 'medica', 'Especialidad médica compleja con mezcla de diagnóstico, seguimiento y entorno académico.', 40, 15, 20, 25),
    ('oncologia_medica', 'Oncología Médica', 'medica', 'Especialidad con fuerte componente relacional y continuidad, además de base científica sólida.', 35, 10, 35, 20),
    ('alergologia', 'Alergología', 'medica', 'Perfil médico analítico con consulta longitudinal y manejo ambulatorio frecuente.', 40, 15, 30, 15),
    ('geriatria', 'Geriatría', 'medica', 'Especialidad centrada en complejidad clínica, continuidad y acompañamiento humano.', 30, 10, 45, 15),

    ('cirugia_general_digestivo', 'Cirugía General y del Aparato Digestivo', 'quirurgica', 'Especialidad quirúrgica resolutiva con alto peso procedimental y presión asistencial.', 20, 55, 15, 10),
    ('traumatologia_ortopedia', 'Cirugía Ortopédica y Traumatología', 'quirurgica', 'Orientación técnica, volumen alto y resultados visibles e inmediatos.', 15, 60, 15, 10),
    ('neurocirugia', 'Neurocirugía', 'quirurgica', 'Especialidad de alta exigencia técnica con casos complejos y entrenamiento prolongado.', 25, 55, 10, 10),
    ('cirugia_cardiovascular', 'Cirugía Cardiovascular', 'quirurgica', 'Perfil procedimental de alto riesgo con exigencia técnica y componente académico relevante.', 20, 55, 10, 15),
    ('cirugia_toracica', 'Cirugía Torácica', 'quirurgica', 'Especialidad quirúrgica compleja con fuerte orientación procedimental.', 20, 55, 15, 10),
    ('cirugia_plastica', 'Cirugía Plástica, Estética y Reparadora', 'quirurgica', 'Orientación técnica con creatividad aplicada y resultados visibles.', 15, 60, 15, 10),
    ('cirugia_pediatrica', 'Cirugía Pediátrica', 'quirurgica', 'Cirugía con mayor componente relacional por el trabajo con niños y familias.', 20, 50, 20, 10),
    ('cirugia_vascular', 'Angiología y Cirugía Vascular', 'quirurgica', 'Especialidad médico-quirúrgica con predominio técnico y toma de decisiones agudas.', 25, 50, 15, 10),
    ('urologia', 'Urología', 'quirurgica', 'Práctica mixta con alto peso procedimental y actividad ambulatoria.', 25, 50, 15, 10),
    ('cirugia_oral_maxilofacial', 'Cirugía Oral y Maxilofacial', 'quirurgica', 'Especialidad técnica, reconstructiva y de alta precisión manual.', 20, 55, 15, 10),

    ('ginecologia_obstetricia', 'Obstetricia y Ginecología', 'quirurgica', 'Especialidad médico-quirúrgica con equilibrio entre acción, continuidad y procesos vitales.', 25, 40, 25, 10),
    ('oftalmologia', 'Oftalmología', 'quirurgica', 'Especialidad de precisión técnica con práctica ambulatoria y microprocedimientos.', 25, 50, 15, 10),
    ('otorrinolaringologia', 'Otorrinolaringología', 'quirurgica', 'Especialidad mixta con peso técnico y actividad de consulta y quirófano.', 25, 45, 20, 10),
    ('dermatologia_medico_quirurgica_venereologia', 'Dermatología Médico-Quirúrgica y Venereología', 'medica', 'Especialidad con equilibrio entre razonamiento clínico, técnica menor y longitudinalidad.', 35, 30, 25, 10),

    ('medicina_familiar', 'Medicina Familiar y Comunitaria', 'atencion_primaria', 'Especialidad longitudinal y centrada en las personas, con visión comunitaria.', 25, 10, 50, 15),
    ('pediatria', 'Pediatría y sus Áreas Específicas', 'atencion_primaria', 'Especialidad relacional y clínica con continuidad, prevención y seguimiento.', 30, 15, 40, 15),

    ('psiquiatria', 'Psiquiatría', 'medica', 'Especialidad con fuerte componente relacional, escucha y complejidad humana.', 30, 5, 45, 20),
    ('psiquiatria_infanto_juvenil', 'Psiquiatría Infantil y de la Adolescencia', 'medica', 'Psiquiatría con enfoque relacional y de acompañamiento prolongado.', 30, 5, 45, 20),

    ('medicina_intensiva', 'Medicina Intensiva', 'urgencias_criticos', 'Especialidad de presión alta con mezcla de análisis, técnica y decisión rápida.', 30, 40, 20, 10),
    ('medicina_urgencias', 'Medicina de Urgencias y Emergencias', 'urgencias_criticos', 'Entorno dinámico y resolutivo con predominio procedimental.', 25, 45, 20, 10),
    ('anestesiologia_reanimacion', 'Anestesiología y Reanimación', 'urgencias_criticos', 'Especialidad técnica, aguda y con fuerte componente procedimental.', 25, 45, 15, 15),

    ('radiodiagnostico', 'Radiodiagnóstico', 'diagnostica', 'Especialidad analítica basada en interpretación, tecnología y soporte diagnóstico.', 45, 20, 10, 25),
    ('medicina_nuclear', 'Medicina Nuclear', 'diagnostica', 'Práctica diagnóstica y terapéutica con claro perfil académico e innovador.', 40, 20, 10, 30),
    ('oncologia_radioterapica', 'Oncología Radioterápica', 'diagnostica', 'Especialidad técnica con componente oncológico, planificación y trabajo académico.', 35, 25, 20, 20),
    ('anatomia_patologica', 'Anatomía Patológica', 'diagnostica', 'Perfil fuertemente diagnóstico y de laboratorio con poca longitudinalidad clínica directa.', 50, 15, 5, 30),
    ('analisis_clinicos', 'Análisis Clínicos', 'diagnostica', 'Especialidad de laboratorio con foco analítico y componente científico.', 45, 15, 10, 30),
    ('bioquimica_clinica', 'Bioquímica Clínica', 'diagnostica', 'Entorno de laboratorio con fuerte orientación académica e investigadora.', 45, 10, 10, 35),
    ('microbiologia_parasitologia', 'Microbiología y Parasitología', 'diagnostica', 'Especialidad analítica de laboratorio con trabajo científico y clínico indirecto.', 45, 15, 10, 30),
    ('inmunologia', 'Inmunología', 'diagnostica', 'Práctica de laboratorio y consulta especializada con foco en conocimiento avanzado.', 40, 15, 10, 35),
    ('neurofisiologia_clinica', 'Neurofisiología Clínica', 'diagnostica', 'Especialidad diagnóstica con mezcla de interpretación, tecnología y paciente.', 45, 20, 15, 20),

    ('medicina_fisica_rehabilitacion', 'Medicina Física y Rehabilitación', 'medica', 'Especialidad funcional con equilibrio entre continuidad, técnica y trabajo interdisciplinar.', 25, 25, 35, 15),

    ('medicina_preventiva_salud_publica', 'Medicina Preventiva y Salud Pública', 'salud_publica', 'Orientación sistémica, poblacional y académica con fuerte peso innovador.', 30, 5, 25, 40),
    ('medicina_trabajo', 'Medicina del Trabajo', 'salud_publica', 'Especialidad preventiva con mezcla de clínica, entorno laboral y gestión.', 30, 10, 30, 30),
    ('farmacologia_clinica', 'Farmacología Clínica', 'diagnostica', 'Especialidad académica y científica con base clínica y metodológica.', 35, 10, 15, 40),
    ('medicina_legal_forense', 'Medicina Legal y Forense', 'salud_publica', 'Perfil analítico con componente pericial, sistémico y académico.', 45, 15, 15, 25)
),
upsert_profiles as (
  insert into public.speciality_profile (
    speciality_key,
    name,
    category,
    description
  )
  select
    speciality_key,
    name,
    category,
    description
  from profile_catalog
  on conflict (speciality_key) do update
  set
    name = excluded.name,
    category = excluded.category,
    description = excluded.description
  returning speciality_key
)
insert into public.speciality_profile_vector (
  speciality_key,
  quiz_version,
  name,
  category,
  profile_a,
  profile_b,
  profile_c,
  profile_d
)
select
  speciality_key,
  'v3_profiles_abcd_18',
  name,
  category,
  profile_a,
  profile_b,
  profile_c,
  profile_d
from profile_catalog
on conflict (speciality_key, quiz_version) do update
set
  name = excluded.name,
  category = excluded.category,
  profile_a = excluded.profile_a,
  profile_b = excluded.profile_b,
  profile_c = excluded.profile_c,
  profile_d = excluded.profile_d;

with questions (
  order_index,
  text,
  dimension,
  question_type,
  option_a,
  option_b,
  option_c,
  option_d
) as (
  values
    (1, 'Durante una guardia, recibes un paciente con síntomas inespecíficos. Tu impulso inicial es:', 'block_1_orientacion_cognitiva', 'choice', 'Revisar historia y pruebas hasta comprender el mecanismo fisiopatológico', 'Actuar rápidamente para estabilizar y resolver lo urgente', 'Explicar al paciente lo que ocurre y tranquilizarlo', 'Analizar si el protocolo actual es el más adecuado o podría mejorarse'),
    (2, 'Te sientes más satisfecho/a profesionalmente cuando:', 'block_1_orientacion_cognitiva', 'choice', 'Descubres un diagnóstico que otros no habían visto', 'Realizas un procedimiento técnicamente exigente con éxito', 'Un paciente te agradece tu acompañamiento durante su proceso', 'Contribuyes a mejorar un protocolo o publicar un hallazgo relevante'),
    (3, 'Cuando estudias medicina, disfrutas más:', 'block_1_orientacion_cognitiva', 'choice', 'Comprendiendo mecanismos fisiopatológicos complejos', 'Aprendiendo técnicas prácticas y habilidades manuales', 'Analizando historias clínicas reales con contexto humano', 'Revisando literatura científica y estudios recientes'),

    (4, '¿Qué tipo de relación con pacientes te resulta más gratificante?', 'block_2_relacion_medico_paciente', 'choice', 'Episodios clínicos complejos con resolución diagnóstica clara', 'Intervenciones resolutivas con resultado inmediato visible', 'Seguimiento longitudinal durante meses o años', 'Impacto a nivel poblacional o sistémico'),
    (5, 'Si un paciente no mejora con el tratamiento inicial:', 'block_2_relacion_medico_paciente', 'choice', 'Revisas el diagnóstico en profundidad buscando lo que falta', 'Consideras nuevas intervenciones prácticas o técnicas', 'Aumentas la comunicación y el apoyo emocional', 'Analizas si el abordaje global o el sistema debe cambiar'),
    (6, 'Te identificas más con:', 'block_2_relacion_medico_paciente', 'choice', 'El clínico que resuelve enigmas diagnósticos difíciles', 'El médico que interviene con destreza técnica y precisión', 'El profesional que acompaña procesos vitales importantes', 'El médico que impulsa cambios e innovación en la práctica'),

    (7, '¿En qué ambiente trabajas mejor?', 'block_3_tolerancia_estres_entorno', 'choice', 'Entorno estructurado con tiempo para analizar cada caso', 'Ambiente dinámico con decisiones rápidas y acción constante', 'Consultas programadas con tiempo suficiente por paciente', 'Entornos académicos o con componente de investigación'),
    (8, 'Ante situaciones clínicas críticas:', 'block_3_tolerancia_estres_entorno', 'choice', 'Prefieres analizar la información antes de actuar', 'Te activas y rindes mejor bajo presión', 'Te centras en el bienestar emocional del paciente y familia', 'Evalúas cómo el sistema podría prevenir estas situaciones'),
    (9, '¿Qué tipo de guardia toleras mejor?', 'block_3_tolerancia_estres_entorno', 'choice', 'Diagnósticos complejos que requieren debate clínico', 'Politrauma y emergencias constantes con acción directa', 'Seguimiento de pacientes conocidos y sus familias', 'Organización de equipos, protocolos y coordinación'),

    (10, 'Tu prioridad profesional principal es:', 'block_4_estilo_vida_equilibrio', 'choice', 'Excelencia diagnóstica y reconocimiento como clínico experto', 'Impacto inmediato y resultados tangibles en cada intervención', 'Equilibrio razonable con vida personal y familiar', 'Proyección académica, investigadora o de liderazgo'),
    (11, 'Respecto al horario ideal de trabajo:', 'block_4_estilo_vida_equilibrio', 'choice', 'Regular y estructurado, aunque sea intenso intelectualmente', 'Variable e intenso, con adrenalina y variedad de casos', 'Compatible con estabilidad personal y familiar', 'Flexible según proyectos, publicaciones u objetivos'),
    (12, 'Respecto a las guardias:', 'block_4_estilo_vida_equilibrio', 'choice', 'Las acepto si son intelectualmente estimulantes', 'Las disfruto por la acción y variedad de casos', 'Prefiero minimizarlas para equilibrio personal', 'Las veo como oportunidad de aprendizaje e investigación'),

    (13, 'En un equipo de trabajo, sueles ser:', 'block_5_personalidad_profesional', 'choice', 'Analítico/a y reflexivo/a, aportas profundidad', 'Decidido/a y resolutivo/a, aportas acción', 'Empático/a y cohesionador/a, aportas armonía', 'Visionario/a y creativo/a, aportas ideas nuevas'),
    (14, 'Ante la incertidumbre diagnóstica:', 'block_5_personalidad_profesional', 'choice', 'Buscas más datos, pruebas y evidencia antes de decidir', 'Tomas decisiones prácticas con la información disponible', 'Escuchas al paciente y su contexto para orientarte', 'Reformulas el problema desde un ángulo diferente'),
    (15, 'Prefieres trabajar:', 'block_5_personalidad_profesional', 'choice', 'En profundidad sobre pocos casos complejos', 'Con volumen alto y resolución rápida de casos', 'Con continuidad y seguimiento longitudinal de pacientes', 'En entornos mixtos clínico-académicos'),

    (16, 'Lo que más te motiva de la medicina es:', 'block_6_motivaciones_valores', 'choice', 'Comprender profundamente la enfermedad y su mecanismo', 'Intervenir activamente y ver resultados rápidos', 'Acompañar a personas en procesos humanos difíciles', 'Contribuir al avance del conocimiento científico'),
    (17, '¿Qué te atrajo originalmente de la medicina?', 'block_6_motivaciones_valores', 'choice', 'El desafío intelectual y científico de entender el cuerpo', 'La capacidad de intervenir, reparar y curar directamente', 'Ayudar a personas en los momentos más difíciles de su vida', 'Contribuir al conocimiento y mejorar la sociedad'),
    (18, '¿Cómo te ves profesionalmente en 15-20 años?', 'block_6_motivaciones_valores', 'choice', 'Referente clínico experto en mi área o subespecialidad', 'Experto técnico reconocido por mis habilidades procedimentales', 'Médico de confianza con relaciones duraderas con pacientes', 'Investigador, docente o líder con impacto académico o sistémico')
),
existing_questions as (
  select id, order_index
  from public.speciality_quiz_question
  where quiz_version = 'v3_profiles_abcd_18'
),
upserted_questions as (
  insert into public.speciality_quiz_question (
    order_index,
    text,
    dimension,
    question_type,
    quiz_version
  )
  select
    q.order_index,
    q.text,
    q.dimension,
    q.question_type,
    'v3_profiles_abcd_18'
  from questions q
  where not exists (
    select 1
    from existing_questions eq
    where eq.order_index = q.order_index
  )
  returning id, order_index
),
all_questions as (
  select id, order_index
  from existing_questions
  union all
  select id, order_index
  from upserted_questions
),
updated_questions as (
  update public.speciality_quiz_question sq
  set
    text = q.text,
    dimension = q.dimension,
    question_type = q.question_type,
    quiz_version = 'v3_profiles_abcd_18'
  from questions q
  join all_questions aq
    on aq.order_index = q.order_index
  where sq.id = aq.id
  returning sq.id
)
delete from public.speciality_quiz_option o
using updated_questions uq
where o.question_id = uq.id;

with questions (
  order_index,
  option_a,
  option_b,
  option_c,
  option_d
) as (
  values
    (1, 'Revisar historia y pruebas hasta comprender el mecanismo fisiopatológico', 'Actuar rápidamente para estabilizar y resolver lo urgente', 'Explicar al paciente lo que ocurre y tranquilizarlo', 'Analizar si el protocolo actual es el más adecuado o podría mejorarse'),
    (2, 'Descubres un diagnóstico que otros no habían visto', 'Realizas un procedimiento técnicamente exigente con éxito', 'Un paciente te agradece tu acompañamiento durante su proceso', 'Contribuyes a mejorar un protocolo o publicar un hallazgo relevante'),
    (3, 'Comprendiendo mecanismos fisiopatológicos complejos', 'Aprendiendo técnicas prácticas y habilidades manuales', 'Analizando historias clínicas reales con contexto humano', 'Revisando literatura científica y estudios recientes'),
    (4, 'Episodios clínicos complejos con resolución diagnóstica clara', 'Intervenciones resolutivas con resultado inmediato visible', 'Seguimiento longitudinal durante meses o años', 'Impacto a nivel poblacional o sistémico'),
    (5, 'Revisas el diagnóstico en profundidad buscando lo que falta', 'Consideras nuevas intervenciones prácticas o técnicas', 'Aumentas la comunicación y el apoyo emocional', 'Analizas si el abordaje global o el sistema debe cambiar'),
    (6, 'El clínico que resuelve enigmas diagnósticos difíciles', 'El médico que interviene con destreza técnica y precisión', 'El profesional que acompaña procesos vitales importantes', 'El médico que impulsa cambios e innovación en la práctica'),
    (7, 'Entorno estructurado con tiempo para analizar cada caso', 'Ambiente dinámico con decisiones rápidas y acción constante', 'Consultas programadas con tiempo suficiente por paciente', 'Entornos académicos o con componente de investigación'),
    (8, 'Prefieres analizar la información antes de actuar', 'Te activas y rindes mejor bajo presión', 'Te centras en el bienestar emocional del paciente y familia', 'Evalúas cómo el sistema podría prevenir estas situaciones'),
    (9, 'Diagnósticos complejos que requieren debate clínico', 'Politrauma y emergencias constantes con acción directa', 'Seguimiento de pacientes conocidos y sus familias', 'Organización de equipos, protocolos y coordinación'),
    (10, 'Excelencia diagnóstica y reconocimiento como clínico experto', 'Impacto inmediato y resultados tangibles en cada intervención', 'Equilibrio razonable con vida personal y familiar', 'Proyección académica, investigadora o de liderazgo'),
    (11, 'Regular y estructurado, aunque sea intenso intelectualmente', 'Variable e intenso, con adrenalina y variedad de casos', 'Compatible con estabilidad personal y familiar', 'Flexible según proyectos, publicaciones u objetivos'),
    (12, 'Las acepto si son intelectualmente estimulantes', 'Las disfruto por la acción y variedad de casos', 'Prefiero minimizarlas para equilibrio personal', 'Las veo como oportunidad de aprendizaje e investigación'),
    (13, 'Analítico/a y reflexivo/a, aportas profundidad', 'Decidido/a y resolutivo/a, aportas acción', 'Empático/a y cohesionador/a, aportas armonía', 'Visionario/a y creativo/a, aportas ideas nuevas'),
    (14, 'Buscas más datos, pruebas y evidencia antes de decidir', 'Tomas decisiones prácticas con la información disponible', 'Escuchas al paciente y su contexto para orientarte', 'Reformulas el problema desde un ángulo diferente'),
    (15, 'En profundidad sobre pocos casos complejos', 'Con volumen alto y resolución rápida de casos', 'Con continuidad y seguimiento longitudinal de pacientes', 'En entornos mixtos clínico-académicos'),
    (16, 'Comprender profundamente la enfermedad y su mecanismo', 'Intervenir activamente y ver resultados rápidos', 'Acompañar a personas en procesos humanos difíciles', 'Contribuir al avance del conocimiento científico'),
    (17, 'El desafío intelectual y científico de entender el cuerpo', 'La capacidad de intervenir, reparar y curar directamente', 'Ayudar a personas en los momentos más difíciles de su vida', 'Contribuir al conocimiento y mejorar la sociedad'),
    (18, 'Referente clínico experto en mi área o subespecialidad', 'Experto técnico reconocido por mis habilidades procedimentales', 'Médico de confianza con relaciones duraderas con pacientes', 'Investigador, docente o líder con impacto académico o sistémico')
),
version_questions as (
  select id, order_index
  from public.speciality_quiz_question
  where quiz_version = 'v3_profiles_abcd_18'
)
insert into public.speciality_quiz_option (
  question_id,
  label,
  value,
  order_index
)
select
  vq.id,
  opt.label,
  opt.value,
  opt.order_index
from version_questions vq
join questions q
  on q.order_index = vq.order_index
cross join lateral (
  values
    (q.option_a, 1, 1),
    (q.option_b, 2, 2),
    (q.option_c, 3, 3),
    (q.option_d, 4, 4)
) as opt(label, value, order_index)
order by vq.order_index, opt.order_index;

create or replace function public.calculate_top_specialities_v3(session_uuid uuid)
returns table (
  speciality_key text,
  speciality_name text,
  score numeric,
  rank integer
)
language plpgsql
stable
as $$
declare
  session_version text;
begin
  select coalesce(meta->>'version', 'v2_profiles_abcd')
  into session_version
  from public.speciality_quiz_session
  where id = session_uuid;

  if session_version is distinct from 'v3_profiles_abcd_18' then
    raise exception 'Session % is not a v3 speciality quiz session', session_uuid;
  end if;

  return query
  with answer_scores as (
    select
      a.value as answer_value,
      coalesce(dw.weight, 1.0) as dimension_weight
    from public.speciality_quiz_answer a
    join public.speciality_quiz_question q
      on q.id = a.question_id
    left join public.dimension_weights dw
      on dw.dimension = q.dimension
    where a.session_id = session_uuid
      and q.quiz_version = 'v3_profiles_abcd_18'
  ),
  user_profile as (
    select
      coalesce(sum(case when answer_value = 1 then dimension_weight else 0 end), 0) as score_a,
      coalesce(sum(case when answer_value = 2 then dimension_weight else 0 end), 0) as score_b,
      coalesce(sum(case when answer_value = 3 then dimension_weight else 0 end), 0) as score_c,
      coalesce(sum(case when answer_value = 4 then dimension_weight else 0 end), 0) as score_d,
      coalesce(sum(dimension_weight), 0) as total_weight
    from answer_scores
  ),
  normalized_user as (
    select
      case when total_weight > 0 then (score_a / total_weight) * 100 else 0 end as profile_a,
      case when total_weight > 0 then (score_b / total_weight) * 100 else 0 end as profile_b,
      case when total_weight > 0 then (score_c / total_weight) * 100 else 0 end as profile_c,
      case when total_weight > 0 then (score_d / total_weight) * 100 else 0 end as profile_d,
      case
        when greatest(score_a, score_b, score_c, score_d) = score_a then 'A'
        when greatest(score_a, score_b, score_c, score_d) = score_b then 'B'
        when greatest(score_a, score_b, score_c, score_d) = score_c then 'C'
        else 'D'
      end as dominant_profile
    from user_profile
  ),
  scored_specialities as (
    select
      spv.speciality_key,
      spv.name as speciality_name,
      least(
        (
          case
            when (
              sqrt(
                power(nu.profile_a, 2) + power(nu.profile_b, 2) + power(nu.profile_c, 2) + power(nu.profile_d, 2)
              ) = 0
              or sqrt(
                power(spv.profile_a, 2) + power(spv.profile_b, 2) + power(spv.profile_c, 2) + power(spv.profile_d, 2)
              ) = 0
            ) then 0
            else (
              (
                (nu.profile_a * spv.profile_a) +
                (nu.profile_b * spv.profile_b) +
                (nu.profile_c * spv.profile_c) +
                (nu.profile_d * spv.profile_d)
              ) /
              (
                sqrt(
                  power(nu.profile_a, 2) + power(nu.profile_b, 2) + power(nu.profile_c, 2) + power(nu.profile_d, 2)
                ) *
                sqrt(
                  power(spv.profile_a, 2) + power(spv.profile_b, 2) + power(spv.profile_c, 2) + power(spv.profile_d, 2)
                )
              )
            )
          end
        ) * 100 *
        case
          when nu.dominant_profile = (
            case
              when greatest(spv.profile_a, spv.profile_b, spv.profile_c, spv.profile_d) = spv.profile_a then 'A'
              when greatest(spv.profile_a, spv.profile_b, spv.profile_c, spv.profile_d) = spv.profile_b then 'B'
              when greatest(spv.profile_a, spv.profile_b, spv.profile_c, spv.profile_d) = spv.profile_c then 'C'
              else 'D'
            end
          ) then 1.10
          else 1.00
        end,
        100
      ) as score
    from public.speciality_profile_vector spv
    cross join normalized_user nu
    where spv.quiz_version = 'v3_profiles_abcd_18'
  )
  select
    ss.speciality_key,
    ss.speciality_name,
    round(ss.score, 1) as score,
    row_number() over (order by ss.score desc, ss.speciality_name asc)::int as rank
  from scored_specialities ss
  order by ss.score desc, ss.speciality_name asc
  limit 3;
end;
$$;

grant all on table public.speciality_profile_vector to anon;
grant all on table public.speciality_profile_vector to authenticated;
grant all on table public.speciality_profile_vector to service_role;

grant all on function public.calculate_top_specialities_v3(uuid) to anon;
grant all on function public.calculate_top_specialities_v3(uuid) to authenticated;
grant all on function public.calculate_top_specialities_v3(uuid) to service_role;

commit;
