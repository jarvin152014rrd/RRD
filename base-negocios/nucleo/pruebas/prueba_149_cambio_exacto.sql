-- PRUEBA: (0.19.0) regla del dueño "cambio_exacto" (A4), cifras a mano: encendida por defecto (empresas que ya existían y nuevas); el cambio se hace por UNO O VARIOS productos que sumen EXACTAMENTE lo devuelto (el previo dice falta / sobra y exacto); si no, CAMBIO_NO_EXACTO sin guardar nada; nunca lleva pagos, diferencia ni cuenta de dinero; la devolución completa del dinero sigue; venta al crédito: lo que rebajó la deuda se vuelve a deber en la venta nueva (debe lo mismo); garantía con precio de garantía sigue igual y la de otro producto también debe ser exacta; con la regla apagada vuelve el cambio con diferencia (0.16.0); solo el dueño la cambia, con motivo y bitácora; asientos cuadran
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   jsonb;
  pv   jsonb;
  d    jsonb;
  r    jsonb;
  cxc0 bigint;
  n    bigint;
  exacto jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de cambio exacto');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT cambio_exacto FROM public.empresa WHERE id = e) AND (SELECT cambio_exacto FROM public.empresa WHERE id = pruebas.empresa('B')),
    'la regla viene encendida');
  PERFORM pruebas.como('dueno_a');
  -- Precios: galón P3 L 450.00 (45,000); tornillo P1 L 15.00 (1,500); arroz P2 L 22.00 la libra, exento (2,200).
  -- Exacto: 8 tornillos (12,000) + 15 lb de arroz (33,000) = 45,000.
  exacto := jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 8),
                              jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 15));

  -- ===== 1) Vale menos: falta =====
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))));
  PERFORM pruebas.afirmar((pv->>'cambio_exacto')::boolean AND NOT (pv->>'exacto')::boolean AND (pv->>'falta_centavos')::bigint = 42000
    AND (pv->>'sobra_centavos')::bigint = 0 AND jsonb_array_length(pv->'opciones_diferencia') = 0 AND (pv->>'puede_devolver_dinero')::boolean,
    'previo con falta: ' || pv::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
      'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2))))),
    'falta L 420.00', 'vale menos: no se hace');
  -- ===== 2) Vale más: sobra =====
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
      'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 31))))),
    'sobra L 15.00', 'vale más: no se hace (no se cobra diferencia)');
  -- ===== 3) Nunca pagos, diferencia ni cuenta de dinero en un cambio =====
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
      'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 31)),
                                   'pagos', '[{"forma":"efectivo","monto_centavos":1500}]'::jsonb))), 'CAMBIO_NO_EXACTO', 'con pagos');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
      'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
                                   'diferencia', 'saldo_favor'))), 'CAMBIO_NO_EXACTO', 'con diferencia a saldo a favor');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
      'cuenta_dinero_id', pruebas.id('CAJA1'),
      'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2))))),
    'CAMBIO_NO_EXACTO', 'con cuenta de dinero');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.devolucion WHERE venta_id = (v1->>'venta_id')::uuid) = 0, 'los rechazos no guardaron nada');

  -- ===== 4) Exacto con VARIOS productos: 8 tornillos + 15 lb de arroz = 45,000 =====
  PERFORM pruebas.como('dueno_a');
  pv := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', exacto)));
  PERFORM pruebas.afirmar((pv->>'exacto')::boolean AND (pv->>'falta_centavos')::bigint = 0 AND (pv->>'sobra_centavos')::bigint = 0
    AND (pv->>'total_nuevo_centavos')::bigint = 45000, 'previo exacto: ' || pv::text);
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Prefiere tornillos y arroz', 'destino', 'cambio', 'cambio', jsonb_build_object('lineas', exacto)), gen_random_uuid());
  PERFORM pruebas.afirmar(d->>'estado' = 'aplicada' AND (d->>'cambio_centavos')::bigint = 45000 AND (d->>'dinero_centavos')::bigint = 0
    AND (d->>'saldo_favor_centavos')::bigint = 0 AND (d->'venta_cambio'->>'total_centavos')::bigint = 45000, 'cambio exacto: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT string_agg(forma || ':' || monto_centavos, ',' ORDER BY linea) FROM public.venta_pago
                            WHERE venta_id = (d->>'venta_cambio_id')::uuid) = 'saldo_favor:45000'
    AND interno.saldo_favor_lote((d->'saldo_favor'->>'saldo_favor_id')::uuid) = 0
    AND (SELECT count(*) FROM public.venta_linea WHERE venta_id = (d->>'venta_cambio_id')::uuid) = 2, 'pagado con lo devuelto; no queda saldo');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.02') = 0, 'sin saldo a favor en los libros');

  -- ===== 5) La devolución completa del dinero sigue igual =====
  PERFORM pruebas.como('dueno_a');
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'No le gustó el color', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'dinero_centavos')::bigint = 45000, 'devolver todo el dinero: ' || d::text);

  -- ===== 6) Venta al crédito sin pagar: debe lo mismo antes y después =====
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  SELECT coalesce(sum(saldo_centavos), 0) INTO cxc0 FROM public.v_cxc_documento WHERE cliente_id = pruebas.id('CLI1');
  PERFORM pruebas.como('dueno_a');
  pv := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', exacto)));
  PERFORM pruebas.afirmar((pv->>'exacto')::boolean AND (pv->>'a_credito_centavos')::bigint = 45000 AND (pv->>'rebaja_deuda_centavos')::bigint = 45000,
    'previo al crédito: ' || pv::text);
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Cambia de pedido', 'destino', 'cambio', 'cambio', jsonb_build_object('lineas', exacto)), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'cxc_centavos')::bigint = 45000 AND (d->>'cambio_centavos')::bigint = 0, 'rebaja la deuda: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT string_agg(forma || ':' || monto_centavos, ',' ORDER BY linea) FROM public.venta_pago
                            WHERE venta_id = (d->>'venta_cambio_id')::uuid) = 'credito:45000', 'la venta nueva al crédito');
  PERFORM pruebas.afirmar((SELECT coalesce(sum(saldo_centavos), 0) FROM public.v_cxc_documento WHERE cliente_id = pruebas.id('CLI1')) = cxc0,
    'el cliente debe lo mismo que antes');

  -- ===== 7) Garantía: "precio de garantía" sigue igual; otro producto también exacto =====
  PERFORM pruebas.como('dueno_a');
  PERFORM public.editar_producto(e, pruebas.id('P3'), '{"dias_garantia": 90}');
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v1->'venta_id', 'linea', 1, 'motivo', 'Vino seca'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_reclamo_garantia(%L, %L, gen_random_uuid())', r->>'reclamo_id',
    jsonb_build_object('resolucion', 'cambiado', 'cambio', jsonb_build_object('lineas',
      jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)), 'diferencia', 'saldo_favor'))),
    'CAMBIO_NO_EXACTO', 'garantía por otro producto que no da exacto');
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, '{"resolucion": "cambiado"}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'resuelto' AND (r->'devolucion'->'venta_cambio'->>'total_centavos')::bigint = 45000,
    'garantía con precio de garantía: ' || r::text);

  -- ===== 8) Solo el dueño cambia la regla, con motivo y bitácora =====
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"cambio_exacto": false}', 'Quiero diferencias'),
    'SIN_PERMISO', 'el admin no cambia la regla');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"cambio_exacto": false}', 'no'), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"cambio_exacto": "no"}', 'Probar texto'),
    'DATO_INVALIDO', 'no es true/false');
  r := public.configurar_empresa(e, '{"cambio_exacto": false, "vale_dias_vigencia": 90}', 'Cambio con diferencia para clientes de años');
  PERFORM pruebas.afirmar(NOT (r->>'cambio_exacto')::boolean AND (r->>'vale_dias_vigencia')::integer = 90, 'se apagó: ' || r::text);
  r := public.configurar_empresa(e, '{"cotizacion_dias_vigencia": 20}', 'Otra regla');
  PERFORM pruebas.afirmar(NOT (r->>'cambio_exacto')::boolean, 'las otras reglas dicen cómo está: ' || r::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'empresa' AND accion = 'UPDATE'
    AND motivo = 'Cambio con diferencia para clientes de años'), 'bitácora con el motivo');

  -- ===== 9) Con la regla apagada: el cambio con diferencia de 0.16.0 =====
  PERFORM pruebas.como('dueno_a');
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))));
  PERFORM pruebas.afirmar(NOT (pv->>'cambio_exacto')::boolean AND jsonb_array_length(pv->'opciones_diferencia') = 2, 'previo flexible: ' || pv::text);
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Prefiere tornillos', 'destino', 'cambio',
         'cambio', jsonb_build_object('diferencia', 'saldo_favor',
                                      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'cambio_centavos')::bigint = 3000 AND (d->>'saldo_favor_centavos')::bigint = 42000, 'cambio con diferencia: ' || d::text);
  PERFORM public.configurar_empresa(e, '{"cambio_exacto": true}', 'Vuelve la regla del dueño');

  -- ===== 10) Todo cuadra =====
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM public.asiento a
   WHERE a.empresa_id = e AND (SELECT sum(debe_centavos) - sum(haber_centavos) FROM public.asiento_linea l WHERE l.asiento_id = a.id) <> 0;
  PERFORM pruebas.afirmar(n = 0, 'todos los asientos cuadran');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora íntegra');
END $$;
