-- PRUEBA: un asiento que no cuadra se rechaza y no guarda nada
DO $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.como('dueno_a');

  -- Venta mal digitada: L 115.00 al debe, L 100.00 al haber.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":11500},{"cuenta":"4.1.01.01","haber":10000}]'),
    'NO_CUADRA', 'debe distinto del haber');

  -- Una sola línea.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":100}]'), 'NO_CUADRA', 'una sola línea');

  -- Montos en cero.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10',
    '[{"cuenta":"1.1.01.01","debe":0},{"cuenta":"4.1.01.01","haber":0}]'),
    'LINEA_INVALIDA', 'montos en cero');

  -- Lista vacía o que no es lista.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', '[]'), 'NO_CUADRA', 'sin líneas');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', '{"a":1}'), 'NO_CUADRA', 'no es lista');

  -- Nada quedó guardado (todo-o-nada).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 0, 'no debe quedar ningún asiento');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento_linea WHERE empresa_id = e) = 0, 'no debe quedar ninguna línea');
END $$;
