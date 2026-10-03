-- PRUEBA: datos raros se rechazan con mensajes claros (cuentas, decimales, negativos, sesión)
DO $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01', '4.1.01.01', 100)), 'CUENTA_INVALIDA', 'cuenta de agrupación');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('9.9.99', '4.1.01.01', 100)), 'CUENTA_INVALIDA', 'cuenta inexistente');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":100.5},{"cuenta":"4.1.01.01","haber":100.5}]'), 'LINEA_INVALIDA', 'decimales en centavos');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":-100},{"cuenta":"4.1.01.01","haber":-100}]'), 'LINEA_INVALIDA', 'negativos');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":"100"},{"cuenta":"4.1.01.01","haber":"100"}]'), 'LINEA_INVALIDA', 'montos como texto');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":100,"haber":100},{"cuenta":"4.1.01.01","haber":100,"debe":100}]'), 'LINEA_INVALIDA', 'debe y haber en la misma línea');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":90071992547409910},{"cuenta":"4.1.01.01","haber":90071992547409910}]'), 'LINEA_INVALIDA', 'monto gigante');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid(), '   '),
    'FALTA_DESCRIPCION', 'descripción vacía');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, NULL, %L, %L::jsonb, gen_random_uuid())',
    e, 'x', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'FECHA_INVALIDA', 'sin fecha');

  -- Cuenta desactivada.
  PERFORM pruebas.como('superusuario');
  UPDATE public.cuenta SET activa = false WHERE empresa_id = e AND codigo = '1.1.01.02';
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.02', '4.1.01.01', 100)), 'CUENTA_INVALIDA', 'cuenta desactivada');

  -- Sesión: rol authenticated sin usuario, y anon.
  PERFORM pruebas.como('sin_sesion');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'SIN_SESION', 'sin usuario');
  PERFORM pruebas.como('anon');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), '42501', 'anon');
  PERFORM pruebas.como('sin_empresa');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'NO_PERTENECE', 'usuario sin empresa');

  -- Nada de lo anterior quedó guardado.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento) = 0, 'ningún asiento guardado');
END $$;
