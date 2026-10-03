-- PRUEBA: mes cerrado rechaza asientos y mes abierto los acepta
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  r jsonb;
  x uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_asiento(e, '2026-02-05', 'Venta febrero', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid());
  x := (r->>'asiento_id')::uuid;

  r := public.cerrar_periodo(e, 2026, 2);
  PERFORM pruebas.afirmar(r->>'estado' = 'cerrado' AND (r->>'ya_estaba')::boolean = false, 'febrero cerrado');
  PERFORM pruebas.afirmar((public.cerrar_periodo(e, 2026, 2)->>'ya_estaba')::boolean, 'cerrar de nuevo no hace daño');

  -- Febrero rechaza; marzo acepta.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-02-15', pruebas.lineas('1.1.01.01', '4.1.01.01', 500)),
    'PERIODO_CERRADO', 'febrero cerrado');
  r := public.registrar_asiento(e, '2026-03-01', 'Venta marzo', pruebas.lineas('1.1.01.01', '4.1.01.01', 500), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean = false, 'marzo abierto acepta');

  -- Una anulación con fecha en mes cerrado tampoco entra; con fecha de hoy sí.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L, NULL, %L)', x, 'Error de fecha', '2026-02-20'),
    'PERIODO_CERRADO', 'anular dentro de mes cerrado');
  PERFORM public.anular_asiento(x, 'Error de fecha');

  -- Ni el superusuario puede meter un asiento en mes cerrado.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format(
    'INSERT INTO public.asiento (empresa_id, sucursal_id, numero, fecha_contable, descripcion, id_operacion, total_centavos)
     SELECT %L, id, 999, %L, %L, gen_random_uuid(), 1 FROM public.sucursal WHERE empresa_id = %L',
     e, '2026-02-10', 'trampa', e), 'PERIODO_CERRADO', 'superusuario en mes cerrado');

  -- Reabrir con motivo: vuelve a aceptar.
  PERFORM pruebas.como('dueno_a');
  r := public.reabrir_periodo(e, 2026, 2, 'Falta registrar una factura de proveedor');
  PERFORM pruebas.afirmar(r->>'estado' = 'abierto', 'febrero reabierto');
  r := public.registrar_asiento(e, '2026-02-15', 'Compra tardía', pruebas.lineas('5.1.01.01', '2.1.01.01', 800), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean = false, 'febrero reabierto acepta');
END $$;
