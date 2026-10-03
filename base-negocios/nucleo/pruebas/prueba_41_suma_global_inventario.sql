-- PRUEBA: en cada empresa el valor del kardex = saldo contable de inventario y las CxP por proveedor = saldo contable de proveedores; saldos = suma del kardex; debe = haber
DO $$
DECLARE
  a   uuid := pruebas.empresa('A');
  b   uuid := pruebas.empresa('B');
  c   uuid;
  bb  uuid;
  pb  uuid;
  prb uuid;
  emp uuid;
BEGIN
  -- Empresa A: de todo un poco.
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');
  PERFORM public.cargar_saldo_inicial(a, pruebas.id('B1'), '2026-01-02', jsonb_build_array(
    jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000),
    jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 50.25, 'costo_unitario', 1777.777777)), gen_random_uuid());
  c := (public.registrar_compra(a, pruebas.compra('PROV1', 'B1', 'G-1', '2026-01-05', 'credito', 'P1', 33, 1234.567891), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.pagar_proveedor(a, c, 12345, '2026-01-06', 'banco', gen_random_uuid());
  PERFORM public.registrar_compra(a, pruebas.compra('PROV2', 'B1', 'G-2', '2026-01-05', 'credito', 'P3', 3, 33333.333333), gen_random_uuid());
  c := (public.registrar_compra(a, pruebas.compra('PROV2', 'B2', 'G-3', '2026-01-05', 'credito', 'P2', 7.5, 1999.99), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.trasladar_inventario(a, pruebas.id('B1'), pruebas.id('B2'), '2026-01-07', jsonb_build_array(
    jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 47),
    jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 13.3333)), gen_random_uuid());
  PERFORM public.ajustar_inventario(a, pruebas.id('B1'), '2026-01-08', jsonb_build_array(
    jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 81),
    jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad_contada', 40),
    jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad_contada', 4, 'costo_unitario', 30000)), 'Conteo general', gen_random_uuid());
  PERFORM public.anular_compra(c, 'Se devolvió todo', gen_random_uuid(), '2026-01-09');
  PERFORM public.registrar_compra(a, pruebas.compra('PROV1', 'B2', 'G-4', '2026-01-10', 'contado', 'P3', 1, 41000, 'caja'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(a, '2026-01-10', 'Venta manual', pruebas.lineas('1.1.01.01', '4.1.01.01', 50000), gen_random_uuid());

  -- Empresa B: su propio inventario y proveedor.
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (b, 'inventario'), (b, 'compras');
  PERFORM pruebas.como('dueno_b');
  bb  := (public.crear_bodega(b, (SELECT id FROM public.sucursal WHERE empresa_id = b AND codigo = '001'), 'PRI', 'Principal')->>'bodega_id')::uuid;
  pb  := (public.crear_producto(b, '{"codigo": "COCA-600", "nombre": "Refresco 600 ml", "precio_venta_centavos": 2500}', gen_random_uuid())->>'producto_id')::uuid;
  prb := (public.crear_tercero(b, '{"nombre": "Embotelladora", "es_proveedor": true, "plazo_dias": 15}', gen_random_uuid())->>'tercero_id')::uuid;
  PERFORM public.registrar_compra(b, jsonb_build_object('proveedor_id', prb, 'bodega_id', bb, 'numero_documento', 'E-1',
    'fecha', '2026-01-05', 'condicion', 'credito', 'lineas', jsonb_build_array(
      jsonb_build_object('producto_id', pb, 'cantidad', 48, 'costo_unitario', 1650))), gen_random_uuid());
  PERFORM public.ajustar_inventario(b, bb, '2026-01-06',
    jsonb_build_array(jsonb_build_object('producto_id', pb, 'cantidad_contada', 45)), 'Se rompieron 3', gen_random_uuid());

  -- Revisión global (como el administrador de la base).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea), 'debe = haber global');
  FOREACH emp IN ARRAY ARRAY[a, b] LOOP
    PERFORM pruebas.afirmar((SELECT coalesce(sum(valor_centavos), 0) FROM public.inventario_saldo WHERE empresa_id = emp)
                            = pruebas.saldo_libros(emp, '1.1.03.01'), 'valor del kardex = inventario en libros');
    PERFORM pruebas.afirmar((SELECT coalesce(sum(valor_centavos), 0) FROM public.inventario_movimiento WHERE empresa_id = emp)
                            = pruebas.saldo_libros(emp, '1.1.03.01'), 'suma de movimientos = inventario en libros');
    PERFORM pruebas.afirmar((SELECT coalesce(sum(saldo_centavos), 0) FROM public.v_cxp_proveedor WHERE empresa_id = emp)
                            = pruebas.saldo_libros(emp, '2.1.01.01'), 'CxP por proveedor = proveedores en libros');
  END LOOP;
  -- CxP por proveedor: compras al crédito vigentes - pagos (cálculo independiente de la vista).
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.tercero t
    LEFT JOIN public.v_cxp_proveedor v ON v.proveedor_id = t.id
    WHERE t.es_proveedor
      AND coalesce(v.saldo_centavos, 0) <>
          coalesce((SELECT sum(x.total_centavos) FROM public.compra x WHERE x.proveedor_id = t.id AND x.condicion = 'credito' AND x.anulada_en IS NULL), 0)
        - coalesce((SELECT sum(p.monto_centavos) FROM public.pago_proveedor p JOIN public.compra x ON x.id = p.compra_id
                     WHERE p.proveedor_id = t.id AND x.anulada_en IS NULL), 0)), 'CxP por proveedor cuadra con compras - pagos');
  -- Saldo de cada bodega/producto = suma de su kardex, y = último saldo guardado en el kardex.
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.inventario_saldo s
     LEFT JOIN (SELECT m.bodega_id, m.producto_id, sum(m.cantidad) AS q, sum(m.valor_centavos) AS v, max(m.id) AS ultimo
                  FROM public.inventario_movimiento m GROUP BY 1, 2) k
            ON k.bodega_id = s.bodega_id AND k.producto_id = s.producto_id
     LEFT JOIN public.inventario_movimiento u ON u.id = k.ultimo
     WHERE (s.cantidad, s.valor_centavos) IS DISTINCT FROM (k.q, k.v)
        OR (s.cantidad, s.valor_centavos, s.costo_promedio) IS DISTINCT FROM (u.saldo_cantidad, u.saldo_valor_centavos, u.saldo_costo_promedio)), 'saldos = kardex');
  -- Cada compra cuadra: total = subtotal + ISV = suma de sus líneas.
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.compra x JOIN public.compra_linea l ON l.compra_id = x.id
    GROUP BY x.id, x.subtotal_centavos, x.isv_centavos
    HAVING sum(l.subtotal_centavos) <> x.subtotal_centavos OR sum(l.isv_centavos) <> x.isv_centavos), 'compras = suma de líneas');
  -- La bitácora sigue intacta.
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
