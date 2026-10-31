-- PRUEBA: impuestos como datos y servicios (cifras a mano): cada empresa recibe los impuestos de su país (HN: ISV15, ISV18, EXENTO, EXONERADO); productos, compras, gastos y ventas calculan con la tabla (cambiar la tasa cambia el cálculo); solo el dueño los configura; un servicio no lleva kardex ni existencia, su costo estimado no lo ve quien no ve costos y no va a los libros; bien y servicio en la misma venta
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  r    jsonb;
  x    record;
  srv  uuid;
  v    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);

  -- 1) Impuestos sembrados (empresa A y B: país HN).
  PERFORM pruebas.afirmar((SELECT string_agg(codigo || '=' || porcentaje::numeric(5,0) || '/' || clase, ',' ORDER BY orden)
                             FROM public.impuesto WHERE empresa_id = e)
    = 'ISV15=15/gravado,ISV18=18/gravado,EXENTO=0/exento,EXONERADO=0/exonerado', 'impuestos de Honduras');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.impuesto WHERE empresa_id = pruebas.empresa('B')) = 0, 'RLS: no ve los de B');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.impuesto WHERE empresa_id = pruebas.empresa('B')) = 4, 'B también');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT codigo FROM public.impuesto WHERE empresa_id = e AND predeterminado) = 'ISV15', 'predeterminado ISV15');

  -- 2) Regla con la tasa como dato (mismos resultados que la de 0.4.0).
  SELECT * INTO x FROM public.precio_impuesto(e, 1500, true, 'ISV15');
  PERFORM pruebas.afirmar(x.sin_isv_centavos = 1304 AND x.isv_centavos = 196, 'L 15.00 con ISV15: 13.04 + 1.96');
  SELECT * INTO x FROM public.precio_impuesto(e, 333, true, 'ISV15', 3);
  PERFORM pruebas.afirmar(x.sin_isv_centavos = 869 AND x.con_isv_centavos = 999, 'por línea: 3 x 3.33 = 9.99 -> 8.69');
  SELECT * INTO x FROM public.precio_con_tasa(10000, false, 13, 1);
  PERFORM pruebas.afirmar(x.isv_centavos = 1300 AND x.con_isv_centavos = 11300, 'otro país: 13 % sobre L 100.00');

  -- 3) Solo el dueño configura impuestos; un país nuevo solo cambia datos.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_impuesto(%L, %L, %L)', e, '{"codigo":"IVA13"}', 'Prueba admin'),
    'SIN_PERMISO', 'admin no configura impuestos');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_impuesto(%L, %L, %L)', e,
    '{"codigo":"IVA13","nombre":"IVA 13","porcentaje":13,"clase":"exento"}', 'Impuesto nuevo'), 'DATO_INVALIDO', 'gravado con tasa');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_impuesto(%L, %L, %L)', e,
    '{"codigo":"IVA13","nombre":"IVA 13","porcentaje":13,"clase":"gravado","cuenta_por_pagar":"9.9.9","cuenta_credito_fiscal":"1.1.04.01"}',
    'Impuesto nuevo'), 'CUENTA_INVALIDA', 'cuenta inexistente');
  r := public.configurar_impuesto(e, '{"codigo":"iva13","nombre":"IVA 13 %","porcentaje":13,"clase":"gravado",
    "cuenta_por_pagar":"2.1.02.01","cuenta_credito_fiscal":"1.1.04.01"}', 'Impuesto de prueba');
  PERFORM pruebas.afirmar(r->>'codigo' = 'IVA13', 'código en mayúsculas');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'impuesto' AND motivo = 'Impuesto de prueba'), 'bitácora');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e,
    '{"codigo":"X1","nombre":"X","tipo_impuesto":"IVA99"}'), 'IMPUESTO_INVALIDO', 'impuesto inexistente');

  -- 4) Compras calculan con la tabla: ISV15 al 16 % -> 10 x L 10.00 = 1,000 + ISV 160.
  PERFORM public.configurar_impuesto(e, '{"codigo":"ISV15","porcentaje":16}', 'Prueba de tasa');
  r := public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-T16', '2026-01-06', 'credito', 'P1', 10, 100), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'isv_centavos')::bigint = 160 AND (r->>'total_centavos')::bigint = 1160, 'compra con la tasa de la tabla: ' || r::text);
  PERFORM public.configurar_impuesto(e, '{"codigo":"ISV15","porcentaje":15}', 'Vuelve la tasa');
  r := public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-T15', '2026-01-06', 'credito', 'P1', 10, 100), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'isv_centavos')::bigint = 150, 'compra 15 %');

  -- 5) Gasto con "impuesto": total 115,000 con ISV15 -> crédito fiscal 15,000 (solo con factura).
  r := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 115000, 'impuesto', 'ISV15', 'descripcion', 'Energía', 'fecha', '2026-01-15',
    'documento', jsonb_build_object('numero', 'F-ENEE-1', 'rtn', '08019999000011')), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'isv_centavos')::bigint = 15000, 'gasto con impuesto de la tabla: ' || r::text);

  -- 6) Servicios.
  srv := pruebas.id('S1');
  PERFORM pruebas.afirmar((SELECT tipo FROM public.producto WHERE id = srv) = 'servicio', 'S1 es servicio');
  PERFORM pruebas.afirmar((SELECT costo_estimado_centavos FROM public.servicio_costo WHERE producto_id = srv) = 8000, 'costo estimado');
  PERFORM pruebas.afirmar((SELECT tipo || '/' || precio_sin_isv_centavos || '/' || isv_centavos FROM public.v_producto WHERE producto_id = srv)
    = 'servicio/20000/3000', 'v_producto: L 230.00 con ISV = 200.00 + 30.00');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-SRV', '2026-01-06', 'credito', 'S1', 1, 100)), 'PRODUCTO_INVALIDO', 'servicio no se compra al kardex');
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'),
    '2026-01-06', jsonb_build_array(jsonb_build_object('producto_id', srv, 'cantidad_contada', 5)), 'Conteo'), 'PRODUCTO_INVALIDO', 'servicio sin ajuste');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P1'), '{"costo_estimado_centavos": 5}'),
    'DATO_INVALIDO', 'costo estimado solo en servicios');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P1'), '{"tipo": "servicio"}'),
    'NO_PERMITIDO', 'un bien con kardex no pasa a servicio');
  -- Vendedor: ve el servicio, no su costo.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar((SELECT costo_estimado_centavos FROM public.v_producto WHERE producto_id = srv) IS NULL
                          AND (SELECT count(*) FROM public.servicio_costo) = 0, 'vendedor no ve costos de servicios');
  PERFORM pruebas.afirmar(public.buscar_producto_por_codigo(e, 'MO-HORA')->'producto'->>'tipo' = 'servicio'
                          AND public.buscar_producto_por_codigo(e, 'MO-HORA')->'existencias' = 'null', 'búsqueda: servicio sin existencias');
  -- Sin servicios activados no se crean.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"permite_servicios": false}', 'Sin servicios');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"S9","nombre":"Lavado","tipo":"servicio"}'),
    'NO_PERMITIDO', 'servicios apagados');
  PERFORM public.configurar_empresa(e, '{"permite_servicios": true}', 'Con servicios');

  -- 7) Bien + servicio en la misma venta (taller): 2 h de mano de obra + 4 tornillos, ticket (sin régimen fiscal).
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', srv, 'cantidad', 2),
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 4)),
         'pagos', jsonb_build_array(jsonb_build_object('forma', 'efectivo'))), gen_random_uuid());
  -- A mano: servicio 2 x 23,000 = 46,000 con ISV -> 40,000 + 6,000; tornillos 4 x 1,500 = 6,000 -> 5,217 + 783.
  PERFORM pruebas.afirmar(v->>'tipo_documento' = 'ticket' AND v->>'numero_documento' = 'T-001-001-00000001', 'ticket sin régimen: ' || (v->>'numero_documento'));
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 52000 AND (v->>'impuesto_centavos')::bigint = 6783
                          AND (v->>'subtotal_centavos')::bigint = 45217, 'totales: ' || v::text);
  -- Promedio de P1: (100 x 1,000 + 10 x 100 + 10 x 100) / 120 = 850 -> 4 x 850 = 3,400.
  PERFORM pruebas.afirmar((SELECT costo_centavos FROM public.venta WHERE id = (v->>'venta_id')::uuid) = 3400,
    'costo en libros solo de los bienes: 4 x 850');
  PERFORM pruebas.afirmar((SELECT costo_centavos || '/' || coalesce(movimiento_id::text, 'sin kardex') || '/' || costo_estimado_centavos
                             FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid AND es_servicio) = '0/sin kardex/16000',
    'servicio: sin kardex, costo estimado 2 x 8,000 que no va a los libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.inventario_movimiento WHERE producto_id = srv), 'servicio nunca en el kardex');
  PERFORM pruebas.afirmar((SELECT utilidad_bruta_centavos FROM public.v_venta WHERE venta_id = (v->>'venta_id')::uuid) = 45217 - 3400 - 16000,
    'utilidad bruta = venta sin ISV - costo - costo estimado');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, srv, '{"tipo": "bien"}'),
    'NO_PERMITIDO', 'servicio vendido no pasa a bien');
END $$;
