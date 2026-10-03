-- PRUEBA: devoluciones y notas de crédito (cifras a mano): parcial por línea, cantidad <= vendida - ya devuelta (pendientes cuentan); inventario al costo de la venta; revierte ingreso (4.1.01.04) e ISV; nota de crédito con CAI propio (fiscal_hn) o interna; destino dinero (cuenta elegida), saldo a favor o cambio; en crédito primero rebaja la CxC y NUNCA devuelve dinero por esa parte; servicios sin inventario ni cambio; tipos que el dueño permite; tope y aprobación (y rechazo); cambio de producto enlazado (se cobra o devuelve la diferencia); la venta con devoluciones no se anula; ISV por pagar = ventas - notas de crédito
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1 jsonb; v2 jsonb; v3 jsonb; v4 jsonb; v5 jsonb;
  d    jsonb;
  dp   jsonb;
  r    jsonb;
  isv0 bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de devoluciones');
  PERFORM public.registrar_cai(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'tipo_documento', 'nota_credito',
    'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D7', 'rango_desde', '001-001-03-00000001', 'rango_hasta', '001-001-03-00000100',
    'fecha_limite_emision', to_char(public.hoy_local(e) + 180, 'YYYY-MM-DD')));

  -- V1 contado a CLI2: 10 tornillos (15,000 = 13,043 + 1,957; costo 10,000) + 2 h de mano de obra (46,000 = 40,000 + 6,000). Total 61,000.
  PERFORM pruebas.como('cajero_a');
  v1 := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10), jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 2)),
          'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((v1->>'total_centavos')::bigint = 61000 AND (v1->>'impuesto_centavos')::bigint = 7957, 'V1');

  -- 1) El cajero devuelve 4 tornillos en dinero: pasa su tope (siempre pide aprobación); no mueve nada hasta aprobar.
  dp := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":4}]'::jsonb,
          'motivo', 'Venían oxidados', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar(dp->>'estado' = 'pendiente_aprobacion' AND (dp->>'total_centavos')::bigint = 6000 AND dp->>'numero_documento' IS NULL,
    'pendiente: 4/10 de 15,000 = 6,000');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 90 AND pruebas.dinero('CAJA1') = 61000, 'pendiente no mueve nada');
  -- Las pendientes cuentan: quedan 6.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    '{"lineas":[{"linea":1,"cantidad":7}],"motivo":"Otra vez","destino":"dinero","cuenta_dinero_id":"' || pruebas.id('CAJA1') || '"}'),
    'DEVOLUCION_INVALIDA', 'no más de lo vendido menos lo devuelto (o pedido)');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', dp->>'aprobacion_id', 'Ok'),
    'SIN_PERMISO', 'el cajero no aprueba');
  PERFORM pruebas.como('admin_a');
  r := public.resolver_aprobacion((dp->>'aprobacion_id')::uuid, true, 'Producto defectuoso', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicada' AND r->>'numero_documento' = '001-001-03-00000001' AND (r->>'dinero_centavos')::bigint = 6000
    AND (r->>'cxc_centavos')::bigint = 0, 'aprobada: nota de crédito CAI ' || r::text);
  PERFORM pruebas.como('superusuario');
  -- 4/10: total 6,000; base round(13,043 x 0.4) = 5,217; ISV 783; costo 4,000.
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 94 AND pruebas.dinero('CAJA1') = 55000 AND pruebas.saldo_libros(e, '4.1.01.04') = 5217
    AND pruebas.saldo_libros(e, '2.1.02.01') = 7957 - 783 AND pruebas.saldo_libros(e, '5.1.01.01') = 10000 - 4000
    AND (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'),
    'inventario al costo de la venta; ingreso, ISV y dinero revertidos');
  PERFORM pruebas.afirmar((SELECT origen FROM public.inventario_movimiento WHERE documento_id = (dp->>'devolucion_id')::uuid) = 'devolucion_venta'
    AND (SELECT valor_centavos FROM public.inventario_movimiento WHERE documento_id = (dp->>'devolucion_id')::uuid) = 4000, 'kardex: entrada a 4,000');

  -- 2) Un pedido pendiente rechazado no mueve nada.
  PERFORM pruebas.como('cajero_a');
  dp := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":6}]'::jsonb,
          'motivo', 'También oxidados', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, false, %L, gen_random_uuid())', dp->>'aprobacion_id', ''), 'FALTA_MOTIVO', 'rechazo con motivo');
  r := public.resolver_aprobacion((dp->>'aprobacion_id')::uuid, false, 'No están dañados', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'rechazada', 'rechazada');

  -- 3) Servicio: 1 h como nota de crédito a favor de CLI2 (23,000 = 20,000 + 3,000), sin inventario; como cambio, no.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    '{"lineas":[{"linea":2,"cantidad":1}],"motivo":"No se hizo","destino":"cambio","cambio":{"lineas":[{"producto_id":"' || pruebas.id('P1') || '","cantidad":1}]}}'),
    'DEVOLUCION_INVALIDA', 'servicio no se cambia');
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, '{"lineas":[{"linea":2,"cantidad":1}],"motivo":"Solo se hizo una hora","destino":"saldo_favor"}',
         gen_random_uuid());
  PERFORM pruebas.afirmar(d->>'numero_documento' = '001-001-03-00000002' AND (d->>'saldo_favor_centavos')::bigint = 23000
    AND d->'saldo_favor'->>'codigo' IS NULL, 'servicio a saldo a favor del cliente');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_cliente(e, pruebas.id('CLI2')) = 23000 AND pruebas.saldo_libros(e, '4.1.01.04') = 5217 + 20000
    AND NOT EXISTS (SELECT 1 FROM public.inventario_movimiento WHERE documento_id = (d->>'devolucion_id')::uuid), 'servicio: sin kardex');

  -- 4) Venta al crédito: primero rebaja la CxC, nunca devuelve dinero por esa parte.
  --    V2: 2 galones a CLI1 = 90,000 (76,271 + 13,729); cobra 30,000; debe 60,000.
  PERFORM pruebas.como('cajero_a');
  v2 := public.registrar_venta(e, pruebas.venta('P3', 2, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo","monto_centavos":30000}]'::jsonb),
    gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  d := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Color equivocado',
         'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  -- 1/2: total 45,000; base round(76,271 / 2) = 38,136; ISV 6,864. Debe 60,000: todo rebaja la CxC.
  PERFORM pruebas.afirmar((d->>'cxc_centavos')::bigint = 45000 AND (d->>'dinero_centavos')::bigint = 0 AND (d->>'impuesto_centavos')::bigint = 6864,
    'crédito: rebaja CxC 45,000 sin dinero');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_documento_cxc((v2->>'venta_id')::uuid) = 15000 AND pruebas.dinero('CAJA1') = 55000 + 30000,
    'debe 15,000; la caja no se toca');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v2->>'venta_id',
    '{"lineas":[{"linea":1,"cantidad":1}],"motivo":"Color equivocado"}'), 'DATO_INVALIDO', 'lo pagado necesita destino');
  d := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Color equivocado',
         'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  -- Lo último de la línea: base 76,271 - 38,136 = 38,135; ISV 6,865. Rebaja 15,000 y devuelve 30,000 (lo que pagó).
  PERFORM pruebas.afirmar((d->>'cxc_centavos')::bigint = 15000 AND (d->>'dinero_centavos')::bigint = 30000 AND (d->>'impuesto_centavos')::bigint = 6865,
    'rebaja 15,000 + devuelve 30,000');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_documento_cxc((v2->>'venta_id')::uuid) = 0 AND pruebas.dinero('CAJA1') = 55000
    AND (SELECT devuelto_centavos FROM public.v_cxc_documento WHERE venta_id = (v2->>'venta_id')::uuid) = 60000
    AND interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01'), 'CxC en 0; nunca dos veces');

  -- 5) Tipos que permite el dueño.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"devolucion_tipos": ["nota_credito", "cambio_producto"]}', 'Sin devolver dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    '{"lineas":[{"linea":1,"cantidad":1}],"motivo":"Oxidado","destino":"dinero","cuenta_dinero_id":"' || pruebas.id('CAJA1') || '"}'),
    'DEVOLUCION_NO_PERMITIDA', 'el dueño no permite devolver dinero');
  PERFORM public.configurar_empresa(e, '{"devolucion_tipos": ["devolver_dinero", "cambio_producto", "nota_credito"]}', 'Todo otra vez');

  -- 6) Cambio de producto: 2 tornillos (3,000) por 1 galón (45,000): cobra la diferencia 42,000.
  PERFORM pruebas.como('cajero_a');
  v3 := public.registrar_venta(e, pruebas.venta('P1', 2, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  d := public.registrar_devolucion((v3->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb, 'motivo', 'Prefiere pintura',
         'destino', 'cambio', 'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
                                                             'pagos', '[{"forma":"efectivo","monto_centavos":42000}]'::jsonb)), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'cambio_centavos')::bigint = 3000 AND d->'venta_cambio'->>'estado' = 'emitida'
    AND (d->'venta_cambio'->>'total_centavos')::bigint = 45000 AND d->>'venta_cambio_id' IS NOT NULL, 'cambio enlazado: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT string_agg(forma || ':' || monto_centavos, ',' ORDER BY linea) FROM public.venta_pago
                            WHERE venta_id = (d->>'venta_cambio_id')::uuid) = 'saldo_favor:3000,efectivo:42000'
    AND interno.saldo_favor_lote((d->'saldo_favor'->>'saldo_favor_id')::uuid) = 0 AND pruebas.dinero('CAJA1') = 55000 + 3000 + 42000,
    'la venta nueva paga con la devolución + diferencia');
  -- Al revés: 1 galón (45,000) por 2 tornillos (3,000): devuelve 42,000 de la caja.
  PERFORM pruebas.como('cajero_a');
  v4 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v4->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
    'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2))))),
    'DATO_INVALIDO', 'la diferencia a devolver necesita cuenta');
  d := public.registrar_devolucion((v4->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos',
         'destino', 'cambio', 'cuenta_dinero_id', pruebas.id('CAJA1'),
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'cambio_centavos')::bigint = 3000 AND (d->>'dinero_centavos')::bigint = 42000, 'cambio a menos: devuelve 42,000');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 100000 + 45000 - 42000, 'caja: entra 45,000, sale 42,000');

  -- 7) La venta con devoluciones no se anula completa.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v1->>'venta_id', 'Error de captura'),
    'VENTA_CON_DEVOLUCIONES', 'venta con nota de crédito');

  -- 8) Ticket interno: nota de crédito con numeración interna.
  PERFORM public.configurar_empresa(e, '{"documento_venta_modo": "factura_o_ticket"}', 'Permitir tickets');
  PERFORM pruebas.como('cajero_a');
  v5 := public.registrar_venta(e, pruebas.venta('P1', 1, 'efectivo') || '{"tipo_documento":"ticket"}', gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  d := public.registrar_devolucion((v5->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'No le quedó',
         'destino', 'saldo_favor'), gen_random_uuid());
  PERFORM pruebas.afirmar(d->>'numero_documento' = 'NC-001-001-00000001' AND d->>'tipo_documento' = 'nota_credito_interna'
    AND d->'saldo_favor'->>'codigo' ~ '^VALE-', 'interna y vale sin cliente');

  -- 9) Documento impreso de la nota de crédito.
  r := public.documento_nota_credito((SELECT id FROM public.devolucion WHERE numero_documento = '001-001-03-00000001'));
  PERFORM pruebas.afirmar(r->>'tipo' = 'NOTA DE CRÉDITO' AND r->>'documento_que_modifica' = '001-001-01-00000001'
    AND r->'fiscal'->>'cai' = 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D7' AND (r->'totales'->>'total_centavos')::bigint = 6000
    AND NOT r::text LIKE '%costo%', 'documento sin costos');

  -- 10) Cuadre: ISV por pagar = ventas - notas de crédito; devoluciones = 4.1.01.04; costo; kardex; CxC; saldo a favor; dinero.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(impuesto_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida')
                          - (SELECT sum(impuesto_centavos) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada')
                          = pruebas.saldo_libros(e, '2.1.02.01'), 'ISV = ventas - notas de crédito');
  PERFORM pruebas.afirmar((SELECT sum(subtotal_centavos) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada') = pruebas.saldo_libros(e, '4.1.01.04')
    AND (SELECT sum(costo_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida')
        - (SELECT sum(costo_centavos) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada') = pruebas.saldo_libros(e, '5.1.01.01')
    AND (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01')
    AND interno.total_cxc(e) = coalesce(pruebas.saldo_libros(e, '1.1.02.01'), 0)
    AND interno.total_saldo_favor(e) = pruebas.saldo_libros(e, '2.1.04.02')
    AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero x JOIN public.cuenta c ON c.id = x.cuenta_id
                     WHERE interno.saldo_dinero(x.id) <> pruebas.saldo_libros(x.empresa_id, c.codigo))
    AND (SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea WHERE empresa_id = e)
    AND (SELECT count(*) FROM public.verificar_bitacora()) = 0, 'cuadre de devoluciones');
  PERFORM pruebas.afirmar((SELECT ultimo_numero FROM public.cai_rango WHERE tipo_documento = 'nota_credito' AND empresa_id = e) = 6,
    'notas de crédito CAI seguidas (6)');
  PERFORM pruebas.debe_fallar(format('UPDATE public.devolucion SET total_centavos = 1 WHERE id = %L', d->>'devolucion_id'), 'PROHIBIDO', 'no se edita');
  -- El vendedor no devuelve.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    '{"lineas":[{"linea":1,"cantidad":1}],"motivo":"Oxidado","destino":"saldo_favor"}'), 'SIN_PERMISO', 'vendedor');
END $$;
