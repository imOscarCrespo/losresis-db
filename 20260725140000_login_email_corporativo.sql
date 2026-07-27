-- Login con email corporativo verificado del hospital.
--
-- Hasta ahora el panel creaba cuentas con un login SINTÉTICO no entregable
-- (`laia@losresis.saludcastillayleon.es`) más una contraseña temporal que había
-- que hacer llegar por fuera del sistema. A partir de ahora la cuenta se crea
-- contra el email corporativo real y se verifica por invitación.
--
-- Ver losresis-panel/docs/adr/0009.

-- Dominio de correo del hospital declarado por el owner, para los hospitales en
-- los que `hospitals.email_domain` falta o viene sucio.
--
-- IMPORTANTE: vive en employer_org y NO en hospitals. `hospitals.email_domain`
-- es catálogo COMPARTIDO y es lo que usa la app móvil para verificar el correo
-- corporativo de los residentes: un owner con prisa que escribiera ahí una
-- errata cambiaría las reglas de verificación de todos los residentes de su
-- hospital, desde otro repo y sin que nadie se enterara.
ALTER TABLE public.employer_org
  ADD COLUMN IF NOT EXISTS login_email_domain text;

COMMENT ON COLUMN public.employer_org.login_email_domain IS
  'Dominio de correo del hospital declarado por el owner cuando falta en el catálogo. Se usa solo para validar los emails de las cuentas del panel; nunca se copia a hospitals.email_domain.';

-- Buscar una identidad existente por email para NO duplicar personas.
--
-- Si el email corporativo que introduce el owner ya tiene cuenta en LosResis
-- (porque ese médico se registró en la app), se reutiliza su user_id y solo se
-- crea el employer_account. Sin esto, `createUser` falla con "email already
-- registered" y no hay forma de resolverlo desde el cliente.
--
-- Solo service_role: es una consulta al esquema auth y no debe estar al alcance
-- de nadie más.
CREATE OR REPLACE FUNCTION public.buscar_auth_user_por_email(p_email text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT u.id
  FROM auth.users u
  WHERE lower(u.email) = lower(btrim(p_email))
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.buscar_auth_user_por_email(text) FROM public;
REVOKE ALL ON FUNCTION public.buscar_auth_user_por_email(text) FROM anon;
REVOKE ALL ON FUNCTION public.buscar_auth_user_por_email(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_auth_user_por_email(text) TO service_role;
