-- PRUEBA: cuadre global tras ventas de todo tipo (contado, tarjeta, transferencia confirmada, crédito, mixto, servicios, descuentos, aprobadas, rechazadas, anuladas): ventas = ingresos contables; descuentos = 4.1.01.03; ISV por pagar = ISV de ventas no anuladas; costo = costo de ventas; kardex = inventario; CxC = Clientes; dinero = subcuentas; cada venta cuadra con sus líneas y pagos; números CAI seguidos sin repetir; bitácora intacta
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  i    integer;
  v    jsonb;
  s    jsonb;
  pg   uuid;
  r    record;
BEGIN
  PERFORM pruebas.preparar_ventas();
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  PERFORM pruebas.como('cajero_a');
  FOR i IN 1..12 LOOP
    v := public.registrar_venta(e, jsonb_build_object(
      'cliente_id', CASE WHEN i % 4 = 0 THEN pruebas.id('CLI1') END,
      'lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', i, 'descuento_porcentaje', CASE WHEN i % 3 = 0 THEN 4 END),
         jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', i * 0.25),
         jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', CASE WHEN i % 2 = 0 THEN 1.5 ELSE 0.5 END)),
      'descuento_factura', CASE WHEN i % 5 = 0 THEN jsonb_build_object('monto_centavos', 333) END,
      'pagos', CASE i % 4 WHEN 1 THEN '[{"forma":"efectivo"}]'::jsonb
                          WHEN 2 THEN '[{"forma":"tarjeta"}]'::jsonb
                          WHEN 3 THEN '[{"forma":"transferencia"}]'::jsonb
                          ELSE '[{"forma":"credito"}]'::jsonb END), gen_random_uuid());
    -- Anular la 6 y la 8 (tarjeta y crédito); confirmar la transferencia de la 3.
    IF i IN (6, 8) THEN
      PERFORM pruebas.como('dueno_a');
      s := public.solicitar_anulacion_venta((v->>'venta_id')::uuid, 'Prueba de cuadre global', gen_random_uuid());
      PERFORM public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Prueba de cuadre', gen_random_uuid());
      PERFORM pruebas.como('cajero_a');
    ELSIF i = 3 THEN
      PERFORM pruebas.como('admin_a');
      SELECT id INTO pg FROM public.venta_pago WHERE venta_id = (v->>'venta_id')::uuid;
      PERFORM public.confirmar_transferencia_venta(pg, jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'TRF-3'), gen_random_uuid());
      PERFORM pruebas.como('cajero_a');
    END IF;
  END LOOP;
  -- Mixto, una aprobada y una rechazada.
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
         'pagos', '[{"forma":"efectivo","monto_centavos":10000},{"forma":"tarjeta","monto_centavos":35000}]'::jsonb), gen_random_uuid());
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1,
         'descuento_porcentaje', 15)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM public.resolver_aprobacion((v->>'aprobacion_id')::uuid, true, 'Ok', gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1,
         'descuento_porcentaje', 15)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM public.resolver_aprobacion((v->>'aprobacion_id')::uuid, false, 'No autorizado', gen_random_uuid());

  PERFORM pruebas.como('superusuario');
  -- Ventas vs libros.
  PERFORM pruebas.afirmar((SELECT sum(subtotal_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida') = pruebas.saldo_libros(e, '4.1.01.01'),
    'ventas = 4.1.01.01');
  PERFORM pruebas.afirmar((SELECT sum(descuento_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida') = pruebas.saldo_libros(e, '4.1.01.03'),
    'descuentos = 4.1.01.03');
  PERFORM pruebas.afirmar((SELECT sum(impuesto_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida') = pruebas.saldo_libros(e, '2.1.02.01'),
    'ISV por pagar = ISV de ventas no anuladas');
  PERFORM pruebas.afirmar((SELECT sum(costo_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida') = pruebas.saldo_libros(e, '5.1.01.01'),
    'costo de ventas');
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'), 'kardex = inventario');
  PERFORM pruebas.afirmar((SELECT sum(saldo_centavos) FROM public.v_cxc_documento WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.02.01')
    AND interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01') AND pruebas.saldo_libros(e, '1.1.02.01') > 0, 'CxC = Clientes');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)), 'dinero = subcuentas');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento_linea l JOIN public.cuenta_dinero d ON d.cuenta_id = l.cuenta_id
                                       WHERE (SELECT count(*) FROM public.dinero_movimiento m WHERE m.asiento_linea_id = l.id) <> 1), 'rastro de cada línea');
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea WHERE empresa_id = e), 'debe = haber');
  -- Cada venta con sus líneas, pagos y desglose.
  FOR r IN SELECT v2.* FROM public.venta v2 WHERE v2.empresa_id = e LOOP
    PERFORM pruebas.afirmar((SELECT sum(total_centavos) FROM public.venta_linea WHERE venta_id = r.id) = r.total_centavos
      AND (SELECT sum(impuesto_centavos) FROM public.venta_linea WHERE venta_id = r.id) = r.impuesto_centavos
      AND (SELECT sum(subtotal_centavos) FROM public.venta_linea WHERE venta_id = r.id) = r.subtotal_centavos
      AND (SELECT sum(monto_centavos) FROM public.venta_pago WHERE venta_id = r.id) = r.total_centavos
      AND (SELECT sum((d->>'impuesto_centavos')::bigint) FROM jsonb_array_elements(r.desglose_impuestos) d) = r.impuesto_centavos,
      'venta #' || r.numero || ' cuadra');
    IF r.estado IN ('emitida', 'anulada') THEN
      PERFORM pruebas.afirmar((SELECT sum(costo_centavos) FROM public.venta_linea WHERE venta_id = r.id) = r.costo_centavos, 'costo #' || r.numero);
    END IF;
  END LOOP;
  -- CAI: facturas seguidas, sin huecos ni repetidos; rechazadas sin número.
  PERFORM pruebas.afirmar((SELECT count(*) || '/' || count(DISTINCT numero_documento) || '/' || max(numero_documento)
                             FROM public.venta WHERE empresa_id = e AND numero_documento IS NOT NULL)
    = '14/14/001-001-01-00000014' AND (SELECT ultimo_numero FROM public.cai_rango WHERE id = pruebas.id('CAI1')) = 14, 'numeración CAI');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta WHERE estado = 'anulada') = 2 AND (SELECT count(*) FROM public.venta WHERE estado = 'rechazada') = 1,
    'anuladas y rechazada');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.inventario_movimiento WHERE producto_id = pruebas.id('S1')), 'servicios fuera del kardex');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora intacta');
END $$;
