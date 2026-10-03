-- PRUEBA: aislamiento entre empresas en compras, pagos, saldos iniciales, ajustes, traslados, anulaciones y vistas: la empresa B pasando ids de la empresa A no ve ni toca nada
DO $$
DECLARE
  a    uuid := pruebas.empresa('A');
  b    uuid := pruebas.empresa('B');
  ca   jsonb; pa jsonb; da jsonb; sa jsonb;
  bb   uuid; pb uuid; prb uuid; sb uuid;
  inv_a bigint; cxp_a bigint;
BEGIN
  -- Empresa A con movimientos de todo tipo.
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('dueno_a');
  da := public.cargar_saldo_inicial(a, pruebas.id('B1'), '2026-01-02',
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 50, 'costo_unitario', 1000)), gen_random_uuid());
  ca := public.registrar_compra(a, pruebas.compra('PROV1', 'B1', 'AIS-1', '2026-01-05', 'credito', 'P1', 10, 1000), gen_random_uuid());
  pa := public.pagar_proveedor(a, (ca->>'compra_id')::uuid, 5000, '2026-01-06', 'caja', gen_random_uuid());
  sa := public.registrar_saldo_inicial_cxp(a, jsonb_build_object('proveedor_id', pruebas.id('PROV2'), 'numero_documento', 'AIS-S',
          'fecha_documento', '2026-01-01', 'monto_centavos', 7000, 'fecha', '2026-01-02'), gen_random_uuid());
  PERFORM public.trasladar_inventario(a, pruebas.id('B1'), pruebas.id('B2'), '2026-01-07',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5)), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  inv_a := pruebas.saldo_libros(a, '1.1.03.01');
  cxp_a := pruebas.saldo_libros(a, '2.1.01.01');

  -- Empresa B con sus módulos, bodega, producto y proveedor propios.
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (b, 'inventario'), (b, 'compras');
  PERFORM pruebas.como('dueno_b');
  sb  := (SELECT id FROM public.sucursal WHERE empresa_id = b AND codigo = '001');
  bb  := (public.crear_bodega(b, sb, 'PRI', 'Principal')->>'bodega_id')::uuid;
  pb  := (public.crear_producto(b, '{"codigo": "JUGO", "nombre": "Jugo"}', gen_random_uuid())->>'producto_id')::uuid;
  prb := (public.crear_tercero(b, '{"nombre": "Proveedor B", "es_proveedor": true}', gen_random_uuid())->>'tercero_id')::uuid;

  -- Compras: en B con ids de A; o directo en A.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', b, jsonb_build_object(
    'proveedor_id', pruebas.id('PROV1'), 'bodega_id', bb, 'numero_documento', 'X1', 'fecha', '2026-01-05', 'condicion', 'credito',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pb, 'cantidad', 1, 'costo_unitario', 100)))), 'TERCERO_INVALIDO', 'proveedor de A en B');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', b, jsonb_build_object(
    'proveedor_id', prb, 'bodega_id', pruebas.id('B1'), 'numero_documento', 'X1', 'fecha', '2026-01-05', 'condicion', 'credito',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pb, 'cantidad', 1, 'costo_unitario', 100)))), 'BODEGA_INVALIDA', 'bodega de A en B');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', b, jsonb_build_object(
    'proveedor_id', prb, 'bodega_id', bb, 'numero_documento', 'X1', 'fecha', '2026-01-05', 'condicion', 'credito',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'costo_unitario', 100)))), 'PRODUCTO_INVALIDO', 'producto de A en B');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', a,
    pruebas.compra('PROV1', 'B1', 'X2', '2026-01-05', 'credito', 'P1', 1, 100)), 'NO_PERTENECE', 'B compra en A');

  -- Pagos, saldos iniciales y anulaciones.
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', b, ca->>'compra_id', '2026-01-06', 'caja'), 'NO_EXISTE', 'B paga compra de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', b, sa->>'saldo_inicial_id', '2026-01-06', 'caja'), 'NO_EXISTE', 'B paga saldo inicial de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', a, ca->>'compra_id', '2026-01-06', 'caja'), 'NO_PERTENECE', 'B paga en A');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', b, jsonb_build_object('proveedor_id', pruebas.id('PROV1'),
    'numero_documento', 'X3', 'fecha_documento', '2026-01-01', 'monto_centavos', 100, 'fecha', '2026-01-02')), 'TERCERO_INVALIDO', 'saldo inicial con proveedor de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid())', ca->>'compra_id', 'Sabotaje de B'), 'NO_PERTENECE', 'B anula compra de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid())', pa->>'pago_id', 'Sabotaje de B'), 'NO_PERTENECE', 'B anula pago de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_saldo_inicial_cxp(%L, %L, gen_random_uuid())', sa->>'saldo_inicial_id', 'Sabotaje de B'), 'NO_PERTENECE', 'B anula saldo inicial de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', da->>'documento_id', 'Sabotaje de B'), 'NO_PERTENECE', 'B anula carga de A');

  -- Inventario: ajustes, traslados y cargas con bodegas o productos de A.
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', b, pruebas.id('B1'), '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pb, 'cantidad_contada', 1)), 'Conteo'), 'BODEGA_INVALIDA', 'B ajusta bodega de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', b, bb, '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 1)), 'Conteo'), 'PRODUCTO_INVALIDO', 'B ajusta producto de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', b, pruebas.id('B1'), bb, '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))), 'BODEGA_INVALIDA', 'B se lleva de una bodega de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', b, bb, pruebas.id('B2'), '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pb, 'cantidad', 1))), 'BODEGA_INVALIDA', 'B manda a una bodega de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', a, pruebas.id('B1'), pruebas.id('B2'), '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))), 'NO_PERTENECE', 'B traslada en A');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', b, bb, '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'costo_unitario', 1))), 'PRODUCTO_INVALIDO', 'B carga producto de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_bodega(%L, %L, %L)', b, pruebas.id('B1'), 'Bodega ajena'), 'NO_EXISTE', 'B reactiva bodega de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_sucursal(%L, %L, %L)', b, (SELECT id FROM public.sucursal WHERE empresa_id = a LIMIT 1), 'Sucursal ajena'),
    'NO_EXISTE', 'B desactiva sucursal de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L, %L)', b, pruebas.id('P1'), '{"precio_incluye_isv": false}', 'Producto ajeno'), 'NO_EXISTE', 'B edita producto de A');

  -- Vistas y tablas: nada de A.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_existencia WHERE empresa_id = a) = 0, 'v_existencia');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_kardex WHERE empresa_id = a) = 0, 'v_kardex');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cxp_documento WHERE empresa_id = a) = 0, 'v_cxp_documento');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cxp_proveedor WHERE empresa_id = a) = 0, 'v_cxp_proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_producto WHERE empresa_id = a) = 0, 'v_producto');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.compra) + (SELECT count(*) FROM public.pago_proveedor)
    + (SELECT count(*) FROM public.cxp_saldo_inicial) + (SELECT count(*) FROM public.inventario_documento)
    + (SELECT count(*) FROM public.inventario_movimiento) + (SELECT count(*) FROM public.tercero WHERE empresa_id = a) = 0, 'tablas de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_existencia) = 0 AND (SELECT count(*) FROM public.v_producto) = 1, 'B solo ve lo suyo');

  -- Y A quedó igual.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(a, '1.1.03.01') = inv_a AND pruebas.saldo_libros(a, '2.1.01.01') = cxp_a, 'A intacta');
  PERFORM pruebas.afirmar(inv_a = 60000 AND cxp_a = 11500 - 5000 + 7000, 'A a mano: inventario 60,000; CxP 13,500');
END $$;
