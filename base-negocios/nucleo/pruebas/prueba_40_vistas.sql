-- PRUEBA: vistas de lectura: existencias por bodega (sin costos para el vendedor), kardex con saldo acumulado y CxP por proveedor con antigüedad 0-30, 31-60, 61-90, +90
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  hoy date;
  r   record;
  cb  uuid;
  ce  uuid;
BEGIN
  PERFORM pruebas.preparar_inventario();
  hoy := public.hoy_local(e);
  PERFORM pruebas.como('admin_a');

  -- ===== Kardex con saldo acumulado (P1) =====
  -- 1) inicial B1 +100 a 1000      -> producto 100 / 100,000
  -- 2) traslado B1 -30 (-30,000)   -> producto  70 /  70,000
  -- 3) traslado B2 +30 (+30,000)   -> producto 100 / 100,000
  -- 4) compra B2 +10 a 1300        -> producto 110 / 113,000 (B2: 40 / 43,000)
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000)), gen_random_uuid());
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-03',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 30)), gen_random_uuid());
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B2', 'K-1', '2026-01-04', 'contado', 'P1', 10, 1300, 'caja'), gen_random_uuid());

  PERFORM pruebas.afirmar((SELECT string_agg(k.bodega_codigo || ':' || k.cantidad::int || '=' || k.saldo_producto_cantidad::int || '/' || k.saldo_producto_valor_centavos, ' ' ORDER BY k.id)
                             FROM public.v_kardex k WHERE k.producto_id = pruebas.id('P1'))
                          = 'B1:100=100/100000 B1:-30=70/70000 B2:30=100/100000 B2:10=110/113000',
                          'kardex acumulado: ' || (SELECT string_agg(k.bodega_codigo || ':' || k.cantidad::int || '=' || k.saldo_producto_cantidad::int || '/' || k.saldo_producto_valor_centavos, ' ' ORDER BY k.id)
                             FROM public.v_kardex k WHERE k.producto_id = pruebas.id('P1')));
  SELECT * INTO r FROM public.v_kardex WHERE producto_id = pruebas.id('P1') ORDER BY id DESC LIMIT 1;
  PERFORM pruebas.afirmar(r.saldo_bodega_cantidad = 40 AND r.saldo_bodega_valor_centavos = 43000 AND r.costo_promedio_bodega = 1075
                          AND r.origen = 'compra' AND r.costo_unitario = 1300, 'saldo por bodega en el kardex (43000/40 = 1075)');

  -- ===== Existencias =====
  SELECT * INTO r FROM public.v_existencia WHERE producto_id = pruebas.id('P1') AND bodega_codigo = 'B1';
  PERFORM pruebas.afirmar(r.cantidad = 70 AND r.valor_centavos = 70000 AND r.costo_promedio = 1000 AND NOT r.bajo_minimo, 'admin ve existencia y costo');
  SELECT * INTO r FROM public.v_existencia WHERE producto_id = pruebas.id('P1') AND bodega_codigo = 'B2';
  PERFORM pruebas.afirmar(r.cantidad = 40 AND r.bajo_minimo AND r.unidad = 'UND', 'B2 bajo el mínimo (40 < 50)');

  PERFORM pruebas.como('vendedor_a');
  SELECT * INTO r FROM public.v_existencia WHERE producto_id = pruebas.id('P1') AND bodega_codigo = 'B1';
  PERFORM pruebas.afirmar(r.cantidad = 70 AND r.costo_promedio IS NULL AND r.valor_centavos IS NULL, 'vendedor ve cantidad, no costos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_kardex) = 0, 'vendedor no ve kardex');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.inventario_saldo) = 0 AND (SELECT count(*) FROM public.inventario_movimiento) = 0, 'vendedor no lee tablas con costos');
  PERFORM pruebas.afirmar((public.buscar_producto_por_codigo(e, '7421000000011')->'existencias'->0->>'costo_promedio') IS NULL
    AND (public.buscar_producto_por_codigo(e, '7421000000011')->'existencias'->0->>'cantidad')::numeric = 70, 'búsqueda sin costo para vendedor');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_existencia) = 0, 'otra empresa no ve existencias');
  PERFORM pruebas.como('sin_sesion');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_existencia) = 0, 'sin sesión no ve existencias');
  PERFORM pruebas.como('service_role');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_existencia WHERE empresa_id = e) = 2, 'service_role sí ve');

  -- ===== CxP con antigüedad (días desde la fecha de la factura) =====
  -- PROV1 (plazo 30):  hace 30 días 11,500 | hace 31 días 23,000 - pago 3,000 = 20,000 | hace 75 días 1,150
  -- PROV2 (plazo 0):   hace 90 días 2,300  | hace 120 días 5,750
  --                    hace 5 días 1,150 pagada completa (no aparece) | una anulada (no aparece)
  PERFORM pruebas.como('admin_a');
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'A-30',  hoy - 30,  'credito', 'P1', 10, 1000), gen_random_uuid());
  cb := (public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'A-31',  hoy - 31,  'credito', 'P1', 20, 1000), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.pagar_proveedor(e, cb, 3000, hoy - 20, 'caja', gen_random_uuid());
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'A-75',  hoy - 75,  'credito', 'P1', 1, 1000), gen_random_uuid());
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'A-90',  hoy - 90,  'credito', 'P1', 2, 1000), gen_random_uuid());
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'A-120', hoy - 120, 'credito', 'P1', 5, 1000), gen_random_uuid());
  ce := (public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'A-5', hoy - 5, 'credito', 'P1', 1, 1000), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.pagar_proveedor(e, ce, 1150, hoy - 1, 'banco', gen_random_uuid());
  ce := (public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'A-X', hoy - 5, 'credito', 'P1', 1, 1000), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.anular_compra(ce, 'Factura duplicada', gen_random_uuid(), hoy - 1);

  SELECT * INTO r FROM public.v_cxp_proveedor WHERE proveedor_id = pruebas.id('PROV1');
  PERFORM pruebas.afirmar(r.facturas = 3 AND r.saldo_centavos = 32650 AND r.de_0_a_30_centavos = 11500 AND r.de_31_a_60_centavos = 20000
    AND r.de_61_a_90_centavos = 1150 AND r.mas_de_90_centavos = 0 AND r.vencido_centavos = 21150, 'PROV1 por antigüedad: ' || to_jsonb(r)::text);
  SELECT * INTO r FROM public.v_cxp_proveedor WHERE proveedor_id = pruebas.id('PROV2');
  PERFORM pruebas.afirmar(r.facturas = 2 AND r.saldo_centavos = 8050 AND r.de_61_a_90_centavos = 2300 AND r.mas_de_90_centavos = 5750
    AND r.de_0_a_30_centavos = 0 AND r.vencido_centavos = 8050, 'PROV2 por antigüedad: ' || to_jsonb(r)::text);
  SELECT * INTO r FROM public.v_cxp_documento WHERE numero_documento = 'A-31';
  PERFORM pruebas.afirmar(r.total_centavos = 23000 AND r.pagado_centavos = 3000 AND r.saldo_centavos = 20000 AND r.dias = 31
    AND r.dias_vencido = 1 AND r.fecha_vencimiento = hoy - 1, 'documento A-31');
  -- Suma de CxP = libros (40,700 = 32,650 + 8,050).
  PERFORM pruebas.afirmar((SELECT sum(saldo_centavos) FROM public.v_cxp_proveedor) = pruebas.saldo_libros(e, '2.1.01.01')
    AND pruebas.saldo_libros(e, '2.1.01.01') = 40700, 'CxP = libros = 40700');

  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cxp_proveedor) = 0 AND (SELECT count(*) FROM public.compra) = 0, 'vendedor no ve compras ni CxP');
END $$;
