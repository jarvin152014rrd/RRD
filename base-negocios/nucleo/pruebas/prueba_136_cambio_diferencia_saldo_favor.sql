-- PRUEBA: (0.16.0) cambio de producto desde la app (cifras a mano; asiento con ISV, inventario y costo exactos; mismo precio; venta al crédito con deuda): calcular_cambio_previo no guarda nada y dice lo devuelto, lo que rebaja la deuda, el total nuevo y la diferencia (a cobrar o a favor) con las opciones que permite el dueño; si el producto nuevo vale menos la diferencia queda como saldo a favor del cliente, como VALE sin cliente o se devuelve en dinero; si vale más se cobra; doble envío con el mismo id_operacion; rechazos (diferencia inválida, saldo a favor con cuenta, tipo no permitido, sin permiso, sucursal ajena); todos los asientos cuadran
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  s2   uuid;
  v1 jsonb; v2 jsonb; v3 jsonb; v4 jsonb;
  pv   jsonb;
  d    jsonb;
  d2   jsonb;
  op   uuid;
  n    bigint;
  caja0 bigint;
  p1   numeric;
  p3   numeric;
  isv  text;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  -- 0.19.0: esta prueba es del cambio con diferencia (0.16.0): se apaga la regla del dueño "cambio exacto".
  PERFORM public.configurar_empresa(e, '{"cambio_exacto": false}', 'Prueba del cambio con diferencia');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de cambio de producto');
  -- Precios: tornillo P1 L 15.00 con ISV (1,500); galón P3 L 450.00 (45,000).

  -- ===== 1) Vale menos: la diferencia queda como SALDO A FAVOR de Juan Pérez (CLI2) =====
  -- V1 contado a CLI2: 1 galón = 45,000. Cambio por 2 tornillos = 3,000. A favor: 45,000 - 3,000 = 42,000.
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))));
  PERFORM pruebas.afirmar((pv->'devuelto'->>'total_centavos')::bigint = 45000 AND (pv->>'rebaja_deuda_centavos')::bigint = 0
    AND (pv->>'para_el_cambio_centavos')::bigint = 45000 AND (pv->>'total_nuevo_centavos')::bigint = 3000
    AND (pv->>'a_cobrar_centavos')::bigint = 0 AND (pv->>'a_favor_cliente_centavos')::bigint = 42000
    AND (SELECT string_agg(o->>'diferencia', ',') FROM jsonb_array_elements(pv->'opciones_diferencia') o) = 'dinero,saldo_favor'
    AND NOT (pv->>'pasa_tope')::boolean, 'previo a menos: ' || pv::text);
  -- El cajero (sin inventario.costos) calcula el mismo previo sin costos; su tope pide aprobación (un cambio no queda pendiente).
  PERFORM pruebas.como('cajero_a');
  d := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))));
  PERFORM pruebas.afirmar(NOT (d::text LIKE '%costo%') AND (d->>'pasa_tope')::boolean
    AND (d->>'a_favor_cliente_centavos')::bigint = 42000, 'previo del cajero: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.devolucion WHERE venta_id = (v1->>'venta_id')::uuid) = 0, 'el previo no guardó nada');
  caja0 := pruebas.dinero('CAJA1');
  PERFORM pruebas.como('dueno_a');
  op := gen_random_uuid();
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Prefiere tornillos', 'destino', 'cambio',
         'cambio', jsonb_build_object('diferencia', 'saldo_favor',
                                      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))), op);
  PERFORM pruebas.afirmar(d->>'estado' = 'aplicada' AND (d->>'cambio_centavos')::bigint = 3000 AND (d->>'saldo_favor_centavos')::bigint = 42000
    AND (d->>'dinero_centavos')::bigint = 0 AND d->'venta_cambio'->>'estado' = 'emitida'
    AND (d->'venta_cambio'->>'total_centavos')::bigint = 3000 AND d->'saldo_favor'->>'codigo' IS NULL, 'cambio a saldo a favor: ' || d::text);
  -- Doble envío: el mismo id_operacion devuelve la misma devolución y no crea otra venta ni otro saldo.
  d2 := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Prefiere tornillos', 'destino', 'cambio',
         'cambio', jsonb_build_object('diferencia', 'saldo_favor',
                                      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))), op);
  PERFORM pruebas.afirmar((d2->>'duplicado')::boolean AND d2->>'devolucion_id' = d->>'devolucion_id', 'reintento = la misma devolución');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.devolucion WHERE venta_id = (v1->>'venta_id')::uuid) = 1
    AND (SELECT count(*) FROM public.venta WHERE nota LIKE 'Cambio de producto%') = 1
    AND (SELECT count(*) FROM public.saldo_favor WHERE documento_id = (d->>'devolucion_id')::uuid) = 1, 'una sola devolución, venta y saldo');
  -- El lote es de 45,000 y la venta nueva usó 3,000: le quedan 42,000 a favor de CLI2. No salió dinero de la caja.
  PERFORM pruebas.afirmar(interno.saldo_favor_lote((d->'saldo_favor'->>'saldo_favor_id')::uuid) = 42000
    AND (SELECT cliente_id FROM public.saldo_favor WHERE id = (d->'saldo_favor'->>'saldo_favor_id')::uuid) = pruebas.id('CLI2')
    AND (SELECT string_agg(forma || ':' || monto_centavos, ',' ORDER BY linea) FROM public.venta_pago
          WHERE venta_id = (d->>'venta_cambio_id')::uuid) = 'saldo_favor:3000'
    AND pruebas.dinero('CAJA1') = caja0, 'saldo a favor de 42,000 y la caja igual');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.02') = 42000, 'pasivo de saldos a favor = 42,000');
  -- Asiento de la nota de crédito, a mano: galón 45,000 con ISV 18 % -> base round(45,000 / 1.18) = 38,136 e ISV 6,864;
  -- costo de la venta 30,000 (compra a L 300.00). Dr 4.1.01.04 38,136 + Dr ISV 6,864 = Cr 2.1.04.02 45,000; Dr 1.1.03.01 / Cr 5.1.01.01 30,000.
  SELECT im.cuenta_por_pagar INTO isv FROM public.impuesto im WHERE im.empresa_id = e AND im.codigo = 'ISV18';
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ',' ORDER BY c.codigo)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
                            WHERE l.asiento_id = (SELECT asiento_id FROM public.devolucion WHERE id = (d->>'devolucion_id')::uuid))
    = (SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY['1.1.03.01:30000/0', isv || ':6864/0', '2.1.04.02:0/45000', '4.1.01.04:38136/0', '5.1.01.01:0/30000']) x),
    'asiento exacto de la nota de crédito');
  -- Inventario: vuelve el galón y salen 2 tornillos de la venta nueva.
  SELECT pruebas.existencia('B1', 'P1'), pruebas.existencia('B1', 'P3') INTO p1, p3;

  PERFORM pruebas.afirmar(p3 = 10 AND p1 = 98, 'inventario: galones ' || p3 || ', tornillos ' || p1);

  -- ===== 1b) Mismo precio: un galón por otro galón (diferencia 0) =====
  PERFORM pruebas.como('dueno_a');
  v2 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)))));
  PERFORM pruebas.afirmar((pv->>'a_cobrar_centavos')::bigint = 0 AND (pv->>'a_favor_cliente_centavos')::bigint = 0
    AND jsonb_array_length(pv->'opciones_diferencia') = 0, 'previo parejo: ' || pv::text);
  d := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Venía golpeado', 'destino', 'cambio',
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)))), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((d->>'cambio_centavos')::bigint = 45000 AND (d->>'saldo_favor_centavos')::bigint = 0 AND (d->>'dinero_centavos')::bigint = 0
    AND interno.saldo_favor_lote((d->'saldo_favor'->>'saldo_favor_id')::uuid) = 0, 'parejo: ' || d::text);

  -- ===== 1c) Venta al crédito con deuda: primero rebaja lo que debe =====
  PERFORM pruebas.como('dueno_a');
  -- V crédito a CLI1: 1 galón = 45,000 (debe todo). Cambio por 2 tornillos (3,000): rebaja 45,000 de la deuda,
  -- no queda nada para el cambio y el cliente paga los 3,000 del producto nuevo.
  v2 := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))));
  PERFORM pruebas.afirmar((pv->>'rebaja_deuda_centavos')::bigint = 45000 AND (pv->>'para_el_cambio_centavos')::bigint = 0
    AND (pv->>'a_cobrar_centavos')::bigint = 3000, 'previo con deuda: ' || pv::text);
  d := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Prefiere tornillos', 'destino', 'cambio',
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
                                      'pagos', '[{"forma":"efectivo","monto_centavos":3000}]'::jsonb)), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'cxc_centavos')::bigint = 45000 AND (d->>'cambio_centavos')::bigint = 0 AND (d->'venta_cambio'->>'total_centavos')::bigint = 3000,
    'con deuda: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_documento_cxc((v2->>'venta_id')::uuid) = 0, 'la deuda quedó en cero');

  -- ===== 2) Consumidor final: la diferencia queda en un VALE con código =====
  -- V2 contado sin cliente: 1 galón = 45,000. Cambio por 1 tornillo = 1,500. Vale: 43,500.
  PERFORM pruebas.como('dueno_a');
  v2 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))));
  PERFORM pruebas.afirmar((pv->>'a_favor_cliente_centavos')::bigint = 43500 AND pv->'opciones_diferencia'->1->>'texto' LIKE '%vale%', 'previo con vale: ' || pv::text);
  d := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Se equivocó de producto', 'destino', 'cambio',
         'cambio', jsonb_build_object('diferencia', 'saldo_favor',
                                      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'saldo_favor_centavos')::bigint = 43500 AND d->'saldo_favor'->>'codigo' LIKE 'VALE-%', 'vale: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_lote((d->'saldo_favor'->>'saldo_favor_id')::uuid) = 43500
    AND pruebas.saldo_libros(e, '2.1.04.02') = 42000 + 43500, 'el vale guarda 43,500');

  -- ===== 3) Vale menos y se devuelve en DINERO (elegido) =====
  PERFORM pruebas.como('dueno_a');
  v3 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  caja0 := pruebas.dinero('CAJA1');
  PERFORM pruebas.como('dueno_a');
  d := public.registrar_devolucion((v3->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Prefiere tornillos', 'destino', 'cambio', 'cuenta_dinero_id', pruebas.id('CAJA1'),
         'cambio', jsonb_build_object('diferencia', 'dinero',
                                      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)))), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'dinero_centavos')::bigint = 42000 AND (d->>'saldo_favor_centavos')::bigint = 0, 'diferencia en dinero: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = caja0 - 42000, 'salen 42,000 de la caja');

  -- ===== 4) Vale MÁS: se cobra la diferencia =====
  -- V4 contado a CLI2: 2 tornillos = 3,000. Cambio por 1 galón = 45,000. Cobra 42,000.
  PERFORM pruebas.como('dueno_a');
  v4 := public.registrar_venta(e, pruebas.venta('P1', 2, 'efectivo', 'CLI2'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v4->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)))));
  PERFORM pruebas.afirmar((pv->>'a_cobrar_centavos')::bigint = 42000 AND (pv->>'a_favor_cliente_centavos')::bigint = 0
    AND jsonb_array_length(pv->'opciones_diferencia') = 0, 'previo a más: ' || pv::text);
  d := public.registrar_devolucion((v4->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb,
         'motivo', 'Prefiere pintura', 'destino', 'cambio',
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
                                      'pagos', '[{"forma":"efectivo","monto_centavos":42000}]'::jsonb)), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'cambio_centavos')::bigint = 3000 AND (d->'venta_cambio'->>'total_centavos')::bigint = 45000, 'cobra la diferencia');

  -- ===== 5) Rechazos =====
  PERFORM pruebas.como('dueno_a');
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
    'cambio', jsonb_build_object('diferencia', 'regalo', 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'DATO_INVALIDO', 'diferencia que no existe');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio', 'cuenta_dinero_id', pruebas.id('CAJA1'),
    'cambio', jsonb_build_object('diferencia', 'saldo_favor', 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'DATO_INVALIDO', 'saldo a favor con cuenta de dinero');
  PERFORM public.configurar_empresa(e, '{"devolucion_tipos": ["devolver_dinero", "cambio_producto"]}', 'Sin notas de crédito');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
    'cambio', jsonb_build_object('diferencia', 'saldo_favor', 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'DEVOLUCION_NO_PERMITIDA', 'el dueño no permite saldo a favor');
  pv := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))));
  PERFORM pruebas.afirmar((SELECT string_agg(o->>'diferencia', ',') FROM jsonb_array_elements(pv->'opciones_diferencia') o) = 'dinero',
    'solo la opción que el dueño permite');
  PERFORM public.configurar_empresa(e, '{"devolucion_tipos": ["nota_credito", "cambio_producto"]}', 'Sin devolver dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio', 'cuenta_dinero_id', pruebas.id('CAJA1'),
    'cambio', jsonb_build_object('diferencia', 'dinero', 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'DEVOLUCION_NO_PERMITIDA', 'el dueño no permite devolver dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio', 'cuenta_dinero_id', pruebas.id('CAJA1'),
    'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'DEVOLUCION_NO_PERMITIDA', 'con cuenta y sin "diferencia" = dinero: no permitido');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
    'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'DEVOLUCION_NO_PERMITIDA', 'sin cuenta ni "diferencia": la diferencia saldría en dinero y no está permitido');
  PERFORM public.configurar_empresa(e, '{"devolucion_tipos": ["devolver_dinero", "nota_credito"]}', 'Sin cambio de producto');
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_cambio_previo(%L, %L)', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'DEVOLUCION_NO_PERMITIDA', 'previo sin cambio de producto permitido');
  PERFORM public.configurar_empresa(e, '{"devolucion_tipos": ["devolver_dinero", "cambio_producto", "nota_credito"]}', 'Todo otra vez');
  -- Sin permiso: el vendedor no devuelve (ni calcula el cambio).
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_cambio_previo(%L, %L)', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'SIN_PERMISO', 'vendedor no calcula cambios');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
    'cambio', jsonb_build_object('diferencia', 'saldo_favor', 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'SIN_PERMISO', 'vendedor no devuelve');
  -- Sucursal ajena: el admin limitado a la Norte no cambia una venta de la principal.
  PERFORM pruebas.como('dueno_a');
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('admin_a'), ARRAY[s2], 'Encargado de la Norte');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_cambio_previo(%L, %L)', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'SUCURSAL_NO_PERMITIDA', 'previo de una venta de otra sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
    'cambio', jsonb_build_object('diferencia', 'saldo_favor', 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))))),
    'SUCURSAL_NO_PERMITIDA', 'cambio en otra sucursal');

  -- ===== 6) Todo cuadra =====
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM (SELECT l.asiento_id FROM public.asiento_linea l WHERE l.empresa_id = e
                                GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)) x;
  PERFORM pruebas.afirmar(n = 0, 'asientos que no cuadran: ' || n);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.02') = interno.total_saldo_favor(e), 'saldos a favor: libros = módulo');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
