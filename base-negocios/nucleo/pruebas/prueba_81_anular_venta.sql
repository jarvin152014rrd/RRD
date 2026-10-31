-- PRUEBA: anular venta (cifras a mano): el vendedor solo SOLICITA; aprueba admin (dentro de su tope) o dueño con motivo; la factura conserva su número y queda ANULADA; contra-asiento enlazado; la mercadería vuelve a lo que costó; el dinero vuelve a SALIR de la misma cuenta a la que entró (una transferencia confirmada, del banco donde quedó; sin dinero en esa cuenta no se anula); la CxC se revierte; rechazo; mes cerrado; gancho de cobros
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v0   jsonb;
  v1   jsonb;
  v2   jsonb;
  v3   jsonb;
  v4   jsonb;
  v5   jsonb;
  s    jsonb;
  r    jsonb;
  pg   uuid;
BEGIN
  PERFORM pruebas.preparar_ventas();
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');

  -- 0) Una venta de enero (luego se cierra enero).
  v0 := public.registrar_venta(e, pruebas.venta('P1', 1) || '{"fecha": "2026-01-20"}', gen_random_uuid());
  PERFORM public.cerrar_periodo(e, 2026, 1);

  -- 1) Ventas de hoy.
  PERFORM pruebas.como('cajero_a');
  v1 := public.registrar_venta(e, pruebas.venta('P1', 10), gen_random_uuid());                 -- efectivo 15,000; costo 10,000
  v2 := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
          'pagos', jsonb_build_array(jsonb_build_object('forma', 'tarjeta', 'monto_centavos', 20000),
                                     jsonb_build_object('forma', 'transferencia', 'monto_centavos', 25000))), gen_random_uuid());
  v3 := public.registrar_venta(e, pruebas.venta('P3', 2, 'credito', 'CLI1'), gen_random_uuid());   -- crédito 90,000
  v4 := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());                  -- efectivo 1,500
  PERFORM pruebas.como('admin_a');
  SELECT id INTO pg FROM public.venta_pago WHERE venta_id = (v2->>'venta_id')::uuid AND forma = 'transferencia';
  PERFORM public.confirmar_transferencia_venta(pg, jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'TRF-9'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 1500 + 15000 + 1500 AND pruebas.dinero('BANCO') = 1025000, 'antes: caja 18,000; BAC 1,025,000');

  -- 2) El vendedor solicita; no aprueba.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v1->>'venta_id', 'mal'),
    'FALTA_MOTIVO', 'motivo corto');
  s := public.solicitar_anulacion_venta((v1->>'venta_id')::uuid, 'El cliente devolvió todo en el momento', gen_random_uuid());
  PERFORM pruebas.afirmar(s->>'estado' = 'pendiente', 'solicitud: ' || s::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v1->>'venta_id', 'Otra vez lo mismo'),
    'YA_EXISTE', 'una solicitud pendiente por venta');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', s->>'aprobacion_id', 'Me la apruebo'),
    'SIN_PERMISO', 'el vendedor no aprueba');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta_anulacion) = 1, 'el vendedor ve su solicitud');

  -- 3) El admin aprueba con motivo: anulada, conserva el número; todo vuelve.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, NULL, gen_random_uuid())', s->>'aprobacion_id'),
    'FALTA_MOTIVO', 'aprobar una anulación pide motivo');
  r := public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Revisado con el cajero', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'anulada' AND r->>'numero_documento' = v1->>'numero_documento', 'anulada con su número: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 3000 AND pruebas.dinero_libros('CAJA1') = 3000, 'salen 15,000 de la MISMA caja');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 100 - 1 - 1 AND pruebas.valor('B1', 'P1') = 98000, 'tornillos vuelven a L 10.00');
  PERFORM pruebas.afirmar((SELECT anula_asiento_id = (SELECT asiento_id FROM public.venta WHERE id = (v1->>'venta_id')::uuid)
                             FROM public.asiento WHERE id = (SELECT asiento_anulacion_id FROM public.venta WHERE id = (v1->>'venta_id')::uuid)),
    'contra-asiento enlazado');
  PERFORM pruebas.afirmar((public.documento_venta((v1->>'venta_id')::uuid)->>'marca') = 'ANULADA', 'el documento sale ANULADA');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v1->>'venta_id', 'De nuevo por si acaso'),
    'YA_ANULADO', 'no se anula dos veces');

  -- 4) El dueño solicita y aprueba la de tarjeta + transferencia confirmada.
  PERFORM pruebas.como('dueno_a');
  s := public.solicitar_anulacion_venta((v2->>'venta_id')::uuid, 'Pintura con defecto de fábrica', gen_random_uuid());
  r := public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Aprobado por el dueño', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'anulada', 'el dueño aprueba su propia solicitud');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE tipo = 'pos_por_liquidar') = 0
    AND pruebas.dinero('BANCO') = 1000000 AND (SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE tipo = 'transferencia_por_confirmar') = 0,
    'tarjeta sale del POS y la transferencia confirmada sale del banco donde quedó');

  -- 5) Crédito: la CxC se revierte.
  s := public.solicitar_anulacion_venta((v3->>'venta_id')::uuid, 'Factura a nombre equivocado', gen_random_uuid());
  PERFORM public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Se refactura', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') = 0 AND NOT EXISTS (SELECT 1 FROM public.v_cxc_documento), 'CxC en 0');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P3') = 10 AND pruebas.valor('B1', 'P3') = 300000, 'pintura completa otra vez');

  -- 6) Rechazo: la venta sigue emitida y se puede volver a pedir.
  PERFORM pruebas.como('cajero_a');
  s := public.solicitar_anulacion_venta((v4->>'venta_id')::uuid, 'Me equivoqué de producto', gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, false, %L, gen_random_uuid())', s->>'aprobacion_id', 'no'),
    'FALTA_MOTIVO', 'rechazo con motivo');
  r := public.resolver_aprobacion((s->>'aprobacion_id')::uuid, false, 'El producto sí salió', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida' AND r->>'aprobacion_estado' = 'rechazada', 'rechazada: la venta sigue');
  -- Tope del admin para anular: L 10.00 (la venta es de L 15.00).
  PERFORM pruebas.como('cajero_a');
  s := public.solicitar_anulacion_venta((v4->>'venta_id')::uuid, 'Ahora sí, devolución', gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_tope_rol(e, 'admin', 'anulacion_venta', 0, 1000, 'Admin anula hasta L 10');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', s->>'aprobacion_id', 'Revisado'),
    'TOPE_APROBACION', 'sobre el tope del admin');

  -- 7) El dinero sale de la misma caja: si ya no está (se llevó a la caja fuerte), no se anula.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('CAJA1'), 'destino_id', pruebas.id('FUERTE'),
    'monto_centavos', pruebas.dinero('CAJA1')), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', s->>'aprobacion_id', 'Devolver'),
    'SALDO_INSUFICIENTE', 'sin efectivo en esa caja');

  -- 8) Mes cerrado: la venta de enero ya no se anula.
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v0->>'venta_id', 'Venta vieja equivocada'),
    'PERIODO_CERRADO', 'mes cerrado');

  -- 9) Gancho de cobros (2b-2b): con cobros vigentes no se anula.
  v5 := public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  EXECUTE 'CREATE OR REPLACE FUNCTION interno.cobros_vigentes_venta(p_venta_id uuid) RETURNS bigint '
       || 'LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '''' AS '
       || quote_literal('SELECT CASE WHEN p_venta_id = ' || quote_literal(v5->>'venta_id') || '::uuid THEN 100 ELSE 0 END::bigint');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v5->>'venta_id', 'Tiene un abono'),
    'VENTA_CON_COBROS', 'con cobros no se anula');

  -- 10) Libros = ventas vigentes (a mano): quedan v0 (1,304 + 196), v4 (1,304 + 196) y v5 (1,304 + 196).
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '4.1.01.01') = 3 * 1304 AND pruebas.saldo_libros(e, '2.1.02.01') = 3 * 196,
    'ventas e ISV de lo vigente: ' || pruebas.saldo_libros(e, '4.1.01.01'));
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '5.1.01.01') = 3 * 1000, 'costo de lo vigente');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e), 'kardex = libros');
END $$;
