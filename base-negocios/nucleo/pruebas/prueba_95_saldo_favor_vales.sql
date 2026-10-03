-- PRUEBA: saldo a favor y vales (cifras a mano): anticipo del cliente como pasivo (2.1.04.02) con rastro; se usa como forma de pago en ventas (al emitir, también al aprobar una pendiente) y en cobros; no alcanza = SALDO_FAVOR_INSUFICIENTE; la venta anulada devuelve el saldo a su lote; un anticipo usado no se anula (SALDO_FAVOR_USADO); vale sin cliente con código único y vencimiento configurable (VALE_VENCIDO); consultar_vale; el pasivo siempre = suma de los lotes
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  a    jsonb;
  v    jsonb;
  vp   jsonb;
  r    jsonb;
  d    jsonb;
  cod  text;
  cod2 text;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de saldo a favor');

  -- 1) Anticipo de CLI2: 10,000 en efectivo queda como saldo a favor (pasivo).
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'anticipo',
    'pagos', '[{"forma":"efectivo","monto_centavos":10000}]'::jsonb)), 'TERCERO_INVALIDO', 'el saldo a favor requiere cliente');
  a := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'tipo', 'anticipo',
         'pagos', '[{"forma":"efectivo","monto_centavos":10000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((a->>'excedente_centavos')::bigint = 10000 AND (a->>'saldo_favor_cliente_centavos')::bigint = 10000, 'anticipo a favor');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.02') = 10000 AND pruebas.dinero('CAJA1') = 10000
    AND (SELECT origen FROM public.saldo_favor WHERE id = (a->'saldo_favor'->>'saldo_favor_id')::uuid) = 'anticipo', 'Dr caja / Cr saldos a favor');

  -- 2) Venta de 1 tornillo (1,500) pagada con su saldo a favor: queda 8,500.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1, 'saldo_favor')), 'CLIENTE_REQUERIDO', 'saldo a favor sin cliente ni vale');
  v := public.registrar_venta(e, pruebas.venta('P1', 1, 'saldo_favor', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND (v->>'total_centavos')::bigint = 1500, 'venta con saldo a favor');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P3', 1, 'saldo_favor', 'CLI2')), 'SALDO_FAVOR_INSUFICIENTE', '45,000 con 8,500 a favor');
  -- Mixto: galón de 45,000 = 8,500 a favor + 36,500 efectivo.
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
         'pagos', '[{"forma":"saldo_favor","monto_centavos":8500},{"forma":"efectivo","monto_centavos":36500}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.02') = 0 AND interno.saldo_favor_cliente(e, pruebas.id('CLI2')) = 0
    AND (SELECT count(*) FROM public.saldo_favor_uso WHERE documento_id = (v->>'venta_id')::uuid) = 1, 'saldo a favor usado completo');

  -- 3) Anular esa venta: el saldo a favor vuelve a su lote (8,500) y el efectivo sale de la caja.
  PERFORM pruebas.como('dueno_a');
  r := public.solicitar_anulacion_venta((v->>'venta_id')::uuid, 'Cliente se arrepintió', gen_random_uuid());
  PERFORM public.resolver_aprobacion((r->>'aprobacion_id')::uuid, true, 'Anulada', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_cliente(e, pruebas.id('CLI2')) = 8500 AND pruebas.saldo_libros(e, '2.1.04.02') = 8500
    AND pruebas.dinero('CAJA1') = 10000, 'anulada: vuelve el saldo a favor');

  -- 4) Venta pendiente de aprobación con saldo a favor: no consume nada hasta aprobarla.
  PERFORM pruebas.como('cajero_a');
  vp := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'),
          'cantidad', 2, 'descuento_porcentaje', 10)), 'pagos', '[{"forma":"saldo_favor"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(vp->>'estado' = 'pendiente_aprobacion' AND (vp->>'total_centavos')::bigint = 2700, 'pendiente: 3,000 - 10 %');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_cliente(e, pruebas.id('CLI2')) = 8500, 'pendiente no consume');
  PERFORM pruebas.como('admin_a');
  r := public.resolver_aprobacion((vp->>'aprobacion_id')::uuid, true, 'Cliente frecuente', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida' AND interno.saldo_favor_cliente(e, pruebas.id('CLI2')) = 5800, 'al aprobar consume: 8,500 - 2,700');

  -- 5) Un anticipo ya usado no se anula.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', a->>'cobro_id', 'Anticipo duplicado'),
    'SALDO_FAVOR_USADO', 'anticipo usado');

  -- 6) Cobrar una factura con saldo a favor: venta al crédito de 3,000 (el dueño no tiene topes) pagada con su saldo.
  PERFORM pruebas.como('dueno_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 2, 'credito', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"saldo_favor","monto_centavos":3000}]'::jsonb),
         gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'saldo_cliente_centavos')::bigint = 0 AND (r->>'saldo_favor_cliente_centavos')::bigint = 2800, 'cobro con saldo a favor');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
    'excedente', 'saldo_favor', 'pagos', '[{"forma":"saldo_favor","monto_centavos":100}]'::jsonb)), 'DATO_INVALIDO', 'saldo a favor a saldo a favor');

  -- 7) Vale sin cliente: devolución de una venta a consumidor final como nota de crédito. Vence a los 30 días.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"vale_dias_vigencia": 30}', 'Vales vencen en 30 días');
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 4, 'efectivo') || '{"fecha":"2026-01-10"}', gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  d := public.registrar_devolucion((v->>'venta_id')::uuid, '{"lineas":[{"linea":1,"cantidad":2}],"motivo":"No le sirvió","destino":"saldo_favor","fecha":"2026-01-11"}',
         gen_random_uuid());
  cod := d->'saldo_favor'->>'codigo';
  PERFORM pruebas.afirmar(cod ~ '^VALE-[0-9A-F]{10}$' AND d->'saldo_favor'->>'vence_el' = '2026-02-10' AND (d->>'saldo_favor_centavos')::bigint = 3000,
    'vale con código y vencimiento: ' || d::text);
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar(public.consultar_vale(e, lower(cod))->>'estado' = 'vencido', 'consultar vale (vencido)');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('lineas',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)), 'pagos', jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'vale', cod)))),
    'VALE_VENCIDO', 'vale vencido');
  -- Sin vencimiento: el siguiente vale se usa.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"vale_dias_vigencia": null}', 'Vales sin vencimiento');
  d := public.registrar_devolucion((v->>'venta_id')::uuid, '{"lineas":[{"linea":1,"cantidad":2}],"motivo":"Tampoco le sirvió","destino":"saldo_favor"}',
         gen_random_uuid());
  cod2 := d->'saldo_favor'->>'codigo';
  PERFORM pruebas.afirmar(cod2 IS NOT NULL AND cod2 <> cod AND d->'saldo_favor'->>'vence_el' IS NULL, 'otro vale, sin vencimiento');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((public.consultar_vale(e, cod2)->>'saldo_centavos')::bigint = 3000, 'vale de 3,000');
  PERFORM pruebas.debe_fallar(format('SELECT public.consultar_vale(%L, %L)', e, 'VALE-0000000000'), 'VALE_INVALIDO', 'vale que no existe');
  r := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
         'pagos', jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'vale', cod2))), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'cliente' = 'Consumidor final' AND (public.consultar_vale(e, cod2)->>'saldo_centavos')::bigint = 1500, 'vale usado: 1,500 de 3,000');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('lineas',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)), 'pagos', jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'vale', cod2)))),
    'SALDO_FAVOR_INSUFICIENTE', 'el vale no alcanza');

  -- 8) Lecturas y cuadre: el pasivo 2.1.04.02 = suma de los lotes (vencidos incluidos).
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT estado FROM public.v_saldo_favor WHERE codigo = cod) = 'vencido'
    AND (SELECT saldo_centavos FROM public.v_saldo_favor WHERE codigo = cod2) = 1500
    AND (SELECT saldo_centavos FROM public.v_saldo_favor WHERE saldo_favor_id = (a->'saldo_favor'->>'saldo_favor_id')::uuid) = 2800
    AND (SELECT estado FROM public.v_saldo_favor WHERE saldo_favor_id = (a->'saldo_favor'->>'saldo_favor_id')::uuid) = 'vigente', 'v_saldo_favor');
  PERFORM pruebas.como('superusuario');
  -- Lotes: anticipo 10,000 (usado 1,500 + 2,700 + 3,000 = 7,200) 2,800 + vale vencido 3,000 + vale 3,000 (usado 1,500) 1,500 = 7,300.
  PERFORM pruebas.afirmar(interno.total_saldo_favor(e) = 7300 AND pruebas.saldo_libros(e, '2.1.04.02') = 7300, 'pasivo = lotes: 7,300');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d2 JOIN public.cuenta x ON x.id = d2.cuenta_id
                                       WHERE interno.saldo_dinero(d2.id) <> pruebas.saldo_libros(d2.empresa_id, x.codigo))
    AND (SELECT count(*) FROM public.verificar_bitacora()) = 0, 'dinero = subcuentas; bitácora');
  PERFORM pruebas.debe_fallar(format('UPDATE public.saldo_favor SET monto_centavos = 1 WHERE codigo = %L', cod2), 'PROHIBIDO', 'el lote no se edita');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.saldo_favor_uso WHERE documento_id = %L', r->>'venta_id'), 'PROHIBIDO', 'el uso no se borra');
END $$;
