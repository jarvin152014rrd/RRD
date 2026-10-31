-- PRUEBA: ventas todo-o-nada (cifras a mano): factura con CAI, ISV por línea respetando "precio incluye ISV", salida del kardex a costo promedio y asiento completo; efectivo en el turno del cajero con vuelto, tarjeta a POS por liquidar, transferencia por confirmar y su confirmación al banco elegido, crédito a CxC con vencimiento por plazo, mixto que suma exacto; consumidor final; el vendedor no cobra; reintentos; "primera venta" del asistente se marca sola
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   jsonb;
  v2   jsonb;
  v3   jsonb;
  v4   jsonb;
  op   uuid := gen_random_uuid();
  opt  uuid := gen_random_uuid();
  pg   uuid;
  r    jsonb;
  t    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas();
  PERFORM pruebas.afirmar(public.estado_arranque(e)->'pasos'->6->>'estado' = 'pendiente', 'primera venta pendiente');

  -- 1) Efectivo: el cajero abre su turno (fondo 0). 10 tornillos (L 15.00 con ISV15) + 2.5 lb de arroz (L 22.00, exento).
  PERFORM pruebas.como('cajero_a');
  t := public.abrir_turno(e, pruebas.id('CAJA001'), 0, opt);
  v1 := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10),
          jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 2.5)),
          'pagos', jsonb_build_array(jsonb_build_object('forma', 'efectivo', 'recibido_centavos', 50000))), op);
  -- A mano: tornillos 15,000 con ISV -> sin ISV round(15,000/1.15) = 13,043, ISV 1,957; arroz 5,500 exento. Total 20,500; vuelto 29,500.
  PERFORM pruebas.afirmar(v1->>'estado' = 'emitida' AND v1->>'numero_documento' = '001-001-01-00000001' AND v1->>'cliente' = 'Consumidor final',
    'factura: ' || v1::text);
  PERFORM pruebas.afirmar((v1->>'subtotal_centavos')::bigint = 18543 AND (v1->>'impuesto_centavos')::bigint = 1957
                          AND (v1->>'total_centavos')::bigint = 20500 AND (v1->>'vuelto_centavos')::bigint = 29500, 'montos');
  PERFORM pruebas.afirmar(v1->>'costo_centavos' IS NULL AND (v1->>'costos_ocultos')::boolean, 'el cajero no ve el costo');
  PERFORM pruebas.afirmar((public.registrar_venta(e, '{"lineas":[]}', op)->>'duplicado')::boolean, 'reintento = misma venta');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, %L)', e, pruebas.venta('P1', 1), opt),
    'ID_OPERACION_USADO', 'id de otra operación');

  -- 2) Mixto: 1 galón de pintura (L 450.00 con ISV18): tarjeta 200.00 + transferencia 150.00 + efectivo 100.00.
  v2 := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
          'pagos', jsonb_build_array(jsonb_build_object('forma', 'tarjeta', 'monto_centavos', 20000, 'referencia', 'Voucher 7781'),
                                     jsonb_build_object('forma', 'transferencia', 'monto_centavos', 15000, 'referencia', 'App BAC'),
                                     jsonb_build_object('forma', 'efectivo', 'monto_centavos', 10000))), gen_random_uuid());
  -- A mano: sin ISV round(45,000/1.18) = 38,136; ISV 6,864.
  PERFORM pruebas.afirmar(v2->>'numero_documento' = '001-001-01-00000002' AND (v2->>'impuesto_centavos')::bigint = 6864, 'mixto: ' || v2::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'efectivo', 'monto_centavos', 1000),
                               jsonb_build_object('forma', 'tarjeta', 'monto_centavos', 499)))), 'PAGO_NO_CUADRA', 'mixto que no suma');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1, 'credito')), 'CLIENTE_REQUERIDO', 'crédito sin cliente');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'efectivo', 'recibido_centavos', 100)))), 'DATO_INVALIDO', 'recibido menor');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1.5)),
    'CANTIDAD_INVALIDA', 'tornillos enteros');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 500)),
    'EXISTENCIA_INSUFICIENTE', 'sin existencia (cajero sin permiso de negativo)');

  -- 3) Crédito: el vendedor vende a CLI1 (límite L 5,000.00, plazo 30) 2 galones = L 900.00. No cobra dinero: sí puede.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)),
    'SIN_PERMISO', 'el vendedor no cobra (cotiza y el cajero cobra)');
  v3 := public.registrar_venta(e, pruebas.venta('P3', 2, 'credito', 'CLI1') || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid());
  -- A mano: 90,000 con ISV18 -> round(90,000/1.18) = 76,271; ISV 13,729. Vence hoy + 30.
  PERFORM pruebas.afirmar(v3->>'estado' = 'emitida' AND v3->>'numero_documento' = '001-001-01-00000003'
    AND (v3->>'credito_centavos')::bigint = 90000 AND v3->>'vence_el' = to_char(public.hoy_local(e) + 30, 'YYYY-MM-DD')
    AND (v3->>'impuesto_centavos')::bigint = 13729, 'crédito: ' || v3::text);
  -- Crédito a un cliente sin límite: pide aprobación, NO consume número ni mueve nada.
  v4 := public.registrar_venta(e, pruebas.venta('P1', 2, 'credito', 'CLI2') || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid());
  PERFORM pruebas.afirmar(v4->>'estado' = 'pendiente_aprobacion' AND v4->>'numero_documento' IS NULL
    AND v4->'requiere_aprobacion' = '["credito"]' AND v4->>'asiento_id' IS NULL, 'cliente sin límite: ' || v4::text);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = 2, 'el vendedor ve solo sus ventas (2)');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta) = 0, 'la tabla con costos no la lee');

  -- 4) Transferencia por confirmar: el admin la confirma en BAC con su referencia.
  PERFORM pruebas.como('admin_a');
  SELECT id INTO pg FROM public.venta_pago WHERE venta_id = (v2->>'venta_id')::uuid AND forma = 'transferencia';
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_transferencia_venta(%L, %L, gen_random_uuid())', pg,
    jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'TRF-1')), 'SIN_PERMISO', 'cajero no confirma');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_transferencia_venta(%L, %L, gen_random_uuid())', pg,
    jsonb_build_object('banco_id', pruebas.id('CAJA1'), 'referencia', 'TRF-1')), 'CUENTA_DINERO_INVALIDA', 'a una caja no');
  r := public.confirmar_transferencia_venta(pg, jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'TRF-55821'), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'saldo_banco_centavos')::bigint = 1015000, 'BAC 1,000,000 + 15,000: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_transferencia_venta(%L, %L, gen_random_uuid())', pg,
    jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'TRF-55821')), 'YA_RESUELTO', 'una sola vez');

  -- 5) Dinero: cada cuenta y su subcuenta (a mano).
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 30500 AND pruebas.dinero_libros('CAJA1') = 30500, 'caja: 20,500 + 10,000');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE tipo = 'pos_por_liquidar') = 20000, 'POS por liquidar 20,000');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE tipo = 'transferencia_por_confirmar') = 0, 'transferencia confirmada');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.dinero_movimiento WHERE documento_id = (v1->>'venta_id')::uuid
                             AND turno_id = (t->>'turno_id')::uuid AND monto_centavos = 20500) = 1, 'efectivo en el turno del cajero');

  -- 6) Libros (a mano).
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '4.1.01.01') = 18543 + 38136 + 76271, 'ventas sin ISV = 132,950');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.02.01') = 1957 + 6864 + 13729, 'ISV por pagar = 22,550');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') = 90000, 'clientes = 90,000');
  -- Costos: 10 x 1,000 + 2.5 x 1,500 = 13,750; 1 x 30,000; 2 x 30,000.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '5.1.01.01') = 13750 + 30000 + 60000, 'costo de ventas = 103,750');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 475000 - 103750
    AND (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = 475000 - 103750, 'inventario = kardex');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 90 AND pruebas.existencia('B1', 'P2') = 47.5 AND pruebas.existencia('B1', 'P3') = 7, 'existencias');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.inventario_movimiento WHERE origen = 'venta') = 4, 'kardex: 4 salidas');
  PERFORM pruebas.afirmar((SELECT costo_centavos FROM public.venta WHERE id = (v1->>'venta_id')::uuid) = 13750, 'el dueño ve el costo');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, %L, %L, %L, gen_random_uuid())', e, '2026-01-20', 'Manual CxC',
    pruebas.lineas('1.1.02.01', '4.1.01.01', 100)), 'CUENTA_CONTROLADA', 'clientes la controla el módulo');

  -- 7) Arqueo del turno: esperado = 0 + 20,500 + 10,000.
  PERFORM pruebas.como('cajero_a');
  r := public.cerrar_turno((t->>'turno_id')::uuid, 30500, gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'esperado_centavos')::bigint = 30500 AND r->>'diferencia_estado' = 'sin_diferencia', 'arqueo: ' || r::text);
  -- Con el turno cerrado y turnos obligatorios no se cobra en efectivo.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)),
    'SIN_TURNO_ABIERTO', 'sin turno');
  -- Con tarjeta sí (no es efectivo).
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'tarjeta'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'numero_documento' = '001-001-01-00000004', 'tarjeta sin turno: ' || r::text);

  -- 8) La venta no se edita ni se borra; "primera venta" quedó hecha.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.venta SET total_centavos = 1 WHERE id = %L', v1->>'venta_id'), 'PROHIBIDO', 'venta inmutable');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.venta_linea WHERE venta_id = %L', v1->>'venta_id'), 'PROHIBIDO', 'líneas no se borran');
  PERFORM pruebas.debe_fallar(format('UPDATE public.venta_pago SET monto_centavos = 1 WHERE venta_id = %L', v1->>'venta_id'), 'PROHIBIDO', 'pagos inmutables');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(public.estado_arranque(e)->'pasos'->6->>'estado' = 'hecho', 'primera venta hecha sola');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE tabla = 'venta' AND registro_id = v1->>'venta_id') >= 2, 'bitácora de la venta');
END $$;
