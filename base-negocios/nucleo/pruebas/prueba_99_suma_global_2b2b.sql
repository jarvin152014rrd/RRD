-- PRUEBA: cuadre global ampliado (2b-2b) tras un mes de operaciones mezcladas (ventas de contado, crédito y servicios, saldos iniciales, cobros consolidados con excedente, condonación, cobros anulados, anticipos, apartados completados y cancelados, devoluciones con dinero, rebaja de CxC, vales y cambio de producto, comisiones devengadas, ajustadas y pagadas): debe = haber; CxC = Clientes; saldo a favor = su pasivo; anticipos = su pasivo; comisiones por pagar = su pasivo; ISV por pagar = ventas - notas de crédito; ventas, descuentos, devoluciones y costo = sus cuentas; kardex = inventario; dinero = subcuentas con rastro; bitácora intacta
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  i    integer;
  v    jsonb;
  c    jsonb;
  ap   jsonb;
  r    jsonb;
  vs   uuid[] := '{}';
  aps  uuid[] := '{}';
  x    record;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba global');
  PERFORM public.registrar_cai(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'tipo_documento', 'nota_credito',
    'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D7', 'rango_desde', '001-001-03-00000001', 'rango_hasta', '001-001-03-00000100',
    'fecha_limite_emision', to_char(public.hoy_local(e) + 180, 'YYYY-MM-DD')));
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'apartados'), (e, 'comisiones');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_comisiones(e, '{"activas": true}', 'Comisiones');
  PERFORM public.fijar_porcentaje_comision(e, pruebas.usuario('vendedor_a'), 10, '2026-01-01', 'Vendedor');
  PERFORM public.fijar_porcentaje_comision(e, pruebas.usuario('cajero_a'), 3, '2026-01-01', 'Cajero');
  PERFORM public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'numero_documento', 'F-OLD-1',
    'fecha_documento', '2025-12-01', 'monto_centavos', 12345), gen_random_uuid());
  PERFORM public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'numero_documento', 'F-OLD-2',
    'fecha_documento', '2025-12-05', 'monto_centavos', 6789), gen_random_uuid());

  FOR i IN 1..8 LOOP
    -- Venta al crédito del vendedor (bien + servicio) y una de contado del cajero.
    PERFORM pruebas.como('vendedor_a');
    v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'lineas', jsonb_build_array(
           jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', i),
           jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 0.5 * (i % 3 + 1))),
           'pagos', '[{"forma":"credito"}]'::jsonb), gen_random_uuid());
    vs := vs || (v->>'venta_id')::uuid;
    PERFORM pruebas.como('cajero_a');
    v := public.registrar_venta(e, jsonb_build_object('cliente_id', CASE WHEN i % 2 = 0 THEN pruebas.id('CLI2') END,
           'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', i * 0.75)),
           'pagos', CASE i % 3 WHEN 0 THEN '[{"forma":"tarjeta"}]'::jsonb WHEN 1 THEN '[{"forma":"efectivo"}]'::jsonb
                                ELSE '[{"forma":"transferencia"}]'::jsonb END), gen_random_uuid());
    -- Cobro consolidado (la más vieja primero); cada 3, con excedente a favor.
    c := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'excedente', CASE WHEN i % 3 = 0 THEN 'saldo_favor' END,
           'pagos', jsonb_build_array(jsonb_build_object('forma', CASE WHEN i % 2 = 0 THEN 'efectivo' ELSE 'tarjeta' END,
                                                         'monto_centavos', 9000 + i * 1111))), gen_random_uuid());
    IF i = 4 THEN
      PERFORM pruebas.como('admin_a');
      PERFORM public.anular_cobro((c->>'cobro_id')::uuid, 'Cobro duplicado', gen_random_uuid());
    END IF;
  END LOOP;

  -- Condonación de un centavo (a la más vieja: F-OLD-2 de CLI2, que queda en 6,788), anticipo y uso del saldo a favor.
  PERFORM pruebas.como('admin_a');
  FOR x IN SELECT d.documento_id, d.origen FROM public.v_cxc_documento d WHERE d.empresa_id = e AND d.saldo_centavos > 0 ORDER BY d.fecha_documento LIMIT 1 LOOP
    PERFORM public.condonar_saldo_cxc(e, jsonb_build_object(CASE WHEN x.origen = 'venta' THEN 'venta_id' ELSE 'saldo_inicial_id' END, x.documento_id,
      'monto_centavos', 1), 'Redondeo', gen_random_uuid());
  END LOOP;
  PERFORM pruebas.como('cajero_a');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'tipo', 'anticipo',
    'pagos', '[{"forma":"efectivo","monto_centavos":20000}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"saldo_favor","monto_centavos":6788}]'::jsonb),
    gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 3)),
    'pagos', '[{"forma":"saldo_favor","monto_centavos":4500}]'::jsonb), gen_random_uuid());

  -- Apartados: uno completado, uno cancelado a favor y uno vigente.
  FOR i IN 1..3 LOOP
    ap := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
            'pagos', jsonb_build_array(jsonb_build_object('forma', 'efectivo', 'monto_centavos', 10000 * i))), gen_random_uuid());
    aps := aps || (ap->>'apartado_id')::uuid;
  END LOOP;
  PERFORM public.abonar_apartado(aps[1], '{"pagos":[{"forma":"tarjeta","monto_centavos":5000}]}', gen_random_uuid());
  PERFORM public.completar_apartado(aps[1], '{"pagos":[{"forma":"efectivo","monto_centavos":30000}]}', gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM public.cancelar_apartado(aps[2], 'No volvió', '{}', gen_random_uuid());

  -- Devoluciones: con dinero (contado), rebaja de CxC (crédito), vale y cambio de producto.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_devolucion(vs[8], jsonb_build_object('lineas', '[{"linea":1,"cantidad":3},{"linea":2,"cantidad":0.5}]'::jsonb,
    'motivo', 'Devolución parcial', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM public.registrar_devolucion(vs[1], jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
    'motivo', 'Devolución total del bien', 'destino', 'saldo_favor'), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 4, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_devolucion((v->>'venta_id')::uuid, '{"lineas":[{"linea":1,"cantidad":1}],"motivo":"Para un vale","destino":"saldo_favor"}', gen_random_uuid());
  PERFORM public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb, 'motivo', 'Cambio de producto',
    'destino', 'cambio', 'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 3)),
                                                      'pagos', '[{"forma":"efectivo","monto_centavos":3600}]'::jsonb)), gen_random_uuid());

  -- Comisiones pagadas al vendedor (lo que tenga hasta hoy).
  PERFORM pruebas.como('admin_a');
  BEGIN
    PERFORM public.pagar_comisiones(e, jsonb_build_object('vendedor_id', pruebas.usuario('vendedor_a'), 'cuenta_dinero_id', pruebas.id('BANCO')), gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'NADA_QUE_PAGAR%' THEN RAISE; END IF;
  END;

  -- ===================== Cuadre global =====================
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea WHERE empresa_id = e)
    AND NOT EXISTS (SELECT 1 FROM public.asiento a WHERE a.empresa_id = e
                     AND (SELECT sum(debe_centavos) - sum(haber_centavos) FROM public.asiento_linea l WHERE l.asiento_id = a.id) <> 0), 'debe = haber');
  PERFORM pruebas.afirmar(interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01')
    AND (SELECT sum(saldo_centavos) FROM public.v_cxc_documento WHERE empresa_id = e) = interno.total_cxc(e) AND interno.total_cxc(e) > 0, 'CxC = Clientes');
  PERFORM pruebas.afirmar(interno.total_saldo_favor(e) = pruebas.saldo_libros(e, '2.1.04.02') AND interno.total_saldo_favor(e) > 0, 'saldo a favor = su pasivo');
  PERFORM pruebas.afirmar((SELECT sum(interno.anticipos_apartado(id)) FROM public.apartado WHERE empresa_id = e AND estado = 'vigente')
    = pruebas.saldo_libros(e, '2.1.04.01') AND pruebas.saldo_libros(e, '2.1.04.01') = 30000, 'anticipos = su pasivo (30,000 del vigente)');
  PERFORM pruebas.afirmar(interno.total_comisiones_por_pagar(e) = coalesce(pruebas.saldo_libros(e, '2.1.03.04'), 0)
    AND (SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE empresa_id = e) = pruebas.saldo_libros(e, '6.1.01.04'), 'comisiones = su pasivo');
  PERFORM pruebas.afirmar((SELECT sum(impuesto_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida')
    - (SELECT sum(impuesto_centavos) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada') = pruebas.saldo_libros(e, '2.1.02.01'),
    'ISV por pagar = ventas - notas de crédito');
  PERFORM pruebas.afirmar((SELECT sum(subtotal_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida') = pruebas.saldo_libros(e, '4.1.01.01')
    AND (SELECT sum(descuento_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida') = coalesce(pruebas.saldo_libros(e, '4.1.01.03'), 0)
    AND (SELECT sum(subtotal_centavos) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada') = pruebas.saldo_libros(e, '4.1.01.04')
    AND (SELECT sum(costo_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida')
        - (SELECT sum(costo_centavos) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada') = pruebas.saldo_libros(e, '5.1.01.01'),
    'ventas, descuentos, devoluciones y costo = sus cuentas');
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'), 'kardex = inventario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c2 ON c2.id = d.cuenta_id
                                       WHERE d.empresa_id = e AND interno.saldo_dinero(d.id) <> pruebas.saldo_libros(e, c2.codigo))
    AND NOT EXISTS (SELECT 1 FROM public.asiento_linea l JOIN public.cuenta_dinero d ON d.cuenta_id = l.cuenta_id
                     WHERE l.empresa_id = e AND (SELECT count(*) FROM public.dinero_movimiento m WHERE m.asiento_linea_id = l.id) <> 1),
    'dinero = subcuentas con rastro de cada línea');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada') = 4
    AND (SELECT count(*) FROM public.cobro WHERE empresa_id = e) >= 11 AND (SELECT count(*) FROM public.comision_movimiento WHERE empresa_id = e) > 0
    AND (SELECT count(*) FROM public.saldo_favor WHERE empresa_id = e AND codigo IS NOT NULL) = 2, 'se operó de todo');
  -- Cada cliente: saldo por documento = saldo del cliente; estado de cuenta = saldo actual.
  FOR x IN SELECT t.id FROM public.tercero t WHERE t.empresa_id = e AND t.es_cliente LOOP
    PERFORM pruebas.afirmar(coalesce((SELECT sum(saldo_centavos) FROM public.v_cxc_documento WHERE cliente_id = x.id), 0) = interno.saldo_cxc_cliente(e, x.id)
      AND (public.estado_cuenta_cliente(e, x.id)->>'saldo_final_centavos')::bigint = interno.saldo_cxc_cliente(e, x.id), 'cliente ' || x.id);
  END LOOP;
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora intacta');
END $$;
