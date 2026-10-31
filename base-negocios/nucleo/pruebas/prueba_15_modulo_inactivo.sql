-- PRUEBA: si el módulo no está activo, el servidor rechaza escribir (pero se puede leer)
DO $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid());

  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'contabilidad';

  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(NOT public.modulo_esta_activo(e, 'contabilidad'), 'módulo inactivo');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-11', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'MODULO_INACTIVO', 'registrar con módulo apagado');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 1, 'sigue pudiendo leer');
END $$;
