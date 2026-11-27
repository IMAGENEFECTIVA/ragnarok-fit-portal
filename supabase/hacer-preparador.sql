-- Convierte una cuenta existente en preparador (administrador).
-- Uso: en Supabase → SQL Editor, cambia el correo y ejecuta.
-- La persona debe registrarse primero en la página.
INSERT INTO public.user_roles (user_id, role)
SELECT id, 'trainer'::public.app_role
FROM auth.users
WHERE lower(email) = lower('correo-del-preparador@ejemplo.cl')
ON CONFLICT (user_id, role) DO NOTHING;

-- Para quitarle el rol de preparador:
-- DELETE FROM public.user_roles
-- WHERE role = 'trainer'
--   AND user_id = (SELECT id FROM auth.users WHERE lower(email) = lower('correo-del-preparador@ejemplo.cl'));
