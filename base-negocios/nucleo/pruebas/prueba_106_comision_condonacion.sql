-- PRUEBA: (0.9.1, importante 5, decisión del dueño) la comisión se calcula solo sobre lo realmente cobrado: lo condonado se resta de la base (su parte sin ISV); si se anula la condonación la comisión vuelve a 0 hasta cobrar, y cobrado todo es la comisión completa
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  ven  uuid := pruebas.usuario('vendedor_a');
  v    jsonb;
  c    jsonb;
  vid  uuid;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de comisiones');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'comisiones') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_comisiones(e, '{"activas": true, "base": "precio"}', 'Comisión sobre el precio');
  PERFORM public.fijar_porcentaje_comision(e, ven, 10, NULL, 'Acuerdo con el vendedor');

  -- Venta al crédito a CLI2 por el vendedor: 2 galones = 90,000 (76,271 sin ISV + 13,729 de ISV 18 %).
  v := public.registrar_venta(e, pruebas.venta('P3', 2, 'credito', 'CLI2') || jsonb_build_object('vendedor_id', ven), gen_random_uuid());
  vid := (v->>'venta_id')::uuid;
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND (v->>'total_centavos')::bigint = 90000, 'venta 90,000');

  -- Cobra 89,000 y se condonan 1,000 (redondeo): queda cobrada completa.
  PERFORM pruebas.como('cajero_a');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"efectivo","monto_centavos":89000}]'::jsonb),
    gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  c := public.condonar_saldo_cxc(e, jsonb_build_object('venta_id', vid, 'monto_centavos', 1000), 'Redondeo acordado', gen_random_uuid());

  -- Condonado sin ISV = round(1,000 x 76,271 / 90,000) = round(847.46) = 847. Base = 76,271 - 847 = 75,424.
  -- Comisión = round(75,424 x 10 %) = round(7,542.4) = 7,542 (antes: round(7,627.1) = 7,627 sobre todo el precio).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = vid) = 7542
    AND (SELECT base_centavos FROM public.comision_movimiento WHERE venta_id = vid ORDER BY id DESC LIMIT 1) = 75424,
    'comisión solo sobre lo cobrado: ' || (SELECT string_agg(monto_centavos::text, ',') FROM public.comision_movimiento WHERE venta_id = vid));

  -- Se anula la condonación: la venta ya no está cobrada completa: comisión 0 (ajuste -7,542).
  PERFORM pruebas.como('dueno_a');
  PERFORM public.anular_condonacion((c->>'condonacion_id')::uuid, 'Sí va a pagar', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = vid) = 0, 'sin condonación ni pago: 0');

  -- Paga los 1,000: cobrada completa sin condonar: round(76,271 x 10 %) = 7,627.
  PERFORM pruebas.como('cajero_a');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb),
    gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = vid) = 7627, 'cobrada toda: 7,627');
  PERFORM pruebas.afirmar(interno.total_comisiones_por_pagar(e) = pruebas.saldo_libros(e, '2.1.03.04')
    AND pruebas.saldo_libros(e, '6.1.01.04') = 7627, 'comisiones = su pasivo y su gasto');
END $$;
