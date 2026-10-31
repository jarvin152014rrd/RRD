-- PRUEBA: (0.9.1, grave 1) nadie paga con el saldo a favor de OTRO cliente ni de OTRA empresa: la venta no acepta "saldo_favor_id" desde la app (ni del propio cliente), el lote debe ser de la misma empresa y cliente aunque se llame por dentro, el cliente sí usa su propio saldo y el cambio de producto sigue usando su lote
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  eb   uuid := pruebas.empresa('B');
  l1   uuid;
  lb   uuid;
  clib uuid;
  v    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de saldo a favor ajeno');

  -- CLI1 deja un anticipo de 3,000: su lote de saldo a favor.
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'tipo', 'anticipo',
         'pagos', '[{"forma":"efectivo","monto_centavos":3000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  l1 := (SELECT id FROM public.saldo_favor WHERE empresa_id = e AND cliente_id = pruebas.id('CLI1'));
  PERFORM pruebas.afirmar(interno.saldo_favor_lote(l1) = 3000, 'lote de CLI1 con 3,000');

  -- Otra empresa (B) con un cliente y un lote de 50,000 (creados por dentro).
  INSERT INTO public.tercero (empresa_id, nombre, es_cliente, id_operacion) VALUES (eb, 'Cliente de B', true, gen_random_uuid()) RETURNING id INTO clib;
  INSERT INTO public.saldo_favor (empresa_id, numero, cliente_id, origen, documento_tipo, documento_id, monto_centavos, fecha_contable)
  VALUES (eb, 1, clib, 'anticipo', 'cobro', gen_random_uuid(), 50000, public.hoy_local(eb)) RETURNING id INTO lb;

  -- 1) Venta a CLI2 (2 tornillos = 3,000) pagada con el lote de CLI1: NO.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'monto_centavos', 3000, 'saldo_favor_id', l1)))),
    'DATO_INVALIDO', 'saldo a favor de otro cliente');
  -- 2) Ni siquiera el propio CLI1 manda "saldo_favor_id" (solo uso interno del cambio de producto).
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cliente_id', pruebas.id('CLI1'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'monto_centavos', 3000, 'saldo_favor_id', l1)))),
    'DATO_INVALIDO', 'saldo_favor_id desde la app');
  -- 3) El lote de la empresa B: NO (y no se gasta).
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'monto_centavos', 3000, 'saldo_favor_id', lb)))),
    'DATO_INVALIDO', 'saldo a favor de otra empresa');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_lote(l1) = 3000 AND interno.saldo_favor_lote(lb) = 50000, 'ningún lote se gastó');

  -- 4) Defensa por dentro: aunque algo llamara a usar_saldo_favor_lote, el lote debe ser del cliente y la empresa de la venta.
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)), 'pagos', '[{"forma":"efectivo"}]'::jsonb),
         gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('SELECT interno.usar_saldo_favor_lote(%L, 1500, %L, %L, public.hoy_local(%L))', l1, 'venta', v->>'venta_id', e),
    'VALE_INVALIDO', 'lote de otro cliente');
  PERFORM pruebas.debe_fallar(format('SELECT interno.usar_saldo_favor_lote(%L, 1500, %L, %L, public.hoy_local(%L))', lb, 'venta', v->>'venta_id', e),
    'VALE_INVALIDO', 'lote de otra empresa');

  -- 5) Lo correcto sigue igual: CLI1 paga 2 tornillos (3,000) con SU saldo a favor (sin indicar lote).
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
         'pagos', '[{"forma":"saldo_favor","monto_centavos":3000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND interno.saldo_favor_lote(l1) = 0 AND interno.saldo_favor_lote(lb) = 50000,
    'CLI1 usó su propio saldo');

  -- 6) El cambio de producto (usa por dentro el lote de su devolución) sigue funcionando.
  PERFORM pruebas.como('dueno_a');
  v := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Cambia por otro', 'destino', 'cambio', 'cambio', jsonb_build_object('lineas',
           jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))), gen_random_uuid());
  PERFORM pruebas.afirmar(v->'venta_cambio'->>'estado' = 'emitida' AND (v->>'cambio_centavos')::bigint = 1500, 'cambio de producto: ' || v::text);

  -- Cuadre: saldo a favor de A = su pasivo.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_saldo_favor(e) = coalesce(pruebas.saldo_libros(e, '2.1.04.02'), 0), 'saldo a favor = su pasivo');
END $$;
