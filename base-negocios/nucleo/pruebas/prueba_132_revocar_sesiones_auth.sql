-- PRUEBA: (0.15.0) revocar_sesiones_auth para la Edge Function "cerrar-sesion-remota": solo service_role (ni el dueño con su token ni anon); solo después de cerrar_sesion_usuario hecho por alguien con permiso (doble candado); borra TODAS las sesiones de Supabase Auth de ese usuario y ninguna de otro; tras revocar, su token viejo da SESION_CERRADA
DO $$
DECLARE
  e       uuid := pruebas.empresa('A');
  cajero  uuid := pruebas.usuario('cajero_a');
  vend    uuid := pruebas.usuario('vendedor_a');
  n       integer;
BEGIN
  -- El cajero tiene 2 sesiones (celular y computadora); el vendedor 1 (de preparar_datos).
  INSERT INTO auth.sessions (user_id) VALUES (cajero);
  PERFORM pruebas.afirmar((SELECT count(*) FROM auth.sessions WHERE user_id = cajero) = 2, 'cajero con 2 sesiones');

  -- Nadie más que service_role la puede llamar.
  PERFORM pruebas.afirmar(NOT has_function_privilege('authenticated', 'public.revocar_sesiones_auth(uuid)', 'EXECUTE'), 'authenticated no la ejecuta');
  PERFORM pruebas.afirmar(NOT has_function_privilege('anon', 'public.revocar_sesiones_auth(uuid)', 'EXECUTE'), 'anon no la ejecuta');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.revocar_sesiones_auth(%L)', cajero), '42501', 'el dueño con su token no la llama directo');

  -- Sin cierre previo: no revoca (doble candado).
  PERFORM pruebas.como('service_role');
  PERFORM pruebas.debe_fallar(format('SELECT public.revocar_sesiones_auth(%L)', cajero), 'PROHIBIDO', 'sin cerrar_sesion_usuario antes');
  PERFORM pruebas.debe_fallar('SELECT public.revocar_sesiones_auth(NULL)', 'DATO_INVALIDO', 'sin usuario');

  -- Con cierre previo del dueño: borra las 2 sesiones del cajero y ninguna del vendedor.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cerrar_sesion_usuario(e, cajero, 'Celular perdido');
  PERFORM pruebas.como('service_role');
  n := public.revocar_sesiones_auth(cajero);
  PERFORM pruebas.afirmar(n = 2, 'revocó 2 sesiones (salió ' || n || ')');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM auth.sessions WHERE user_id = cajero) = 0, 'el cajero quedó sin sesiones');
  PERFORM pruebas.afirmar((SELECT count(*) FROM auth.sessions WHERE user_id = vend) = 1, 'el vendedor conserva la suya');

  -- Su token viejo (session_id que ya no existe) queda fuera.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resumen_hoy(%L)', e), 'SESION_CERRADA', 'token de la sesión revocada');
  PERFORM pruebas.como('superusuario');
END $$;
