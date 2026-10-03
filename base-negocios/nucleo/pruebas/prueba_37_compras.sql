-- PRUEBA: compras al contado y al crédito (todo o nada: documento + kardex + asiento), ISV crédito fiscal, factura repetida, reintentos y anulación con contra-movimiento
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  op  uuid := gen_random_uuid();
  r   jsonb;
  c1  public.compra;
  c2  uuid;
  c3  uuid;
  cli uuid;
  n_c bigint; n_m bigint; n_a bigint;
  lineas jsonb;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');

  -- 1) Compra al crédito de 3 líneas, a mano:
  --   P1 10 x 1250.5  = 12,505   ISV15 round(1875.75) = 1,876
  --   P2 2.5 x 3000   =  7,500   EXENTO               =     0
  --   P3 4 x 25000    = 100,000  ISV18                = 18,000
  --   subtotal 120,005 + ISV 19,876 = total 139,881. Vence 10/01 + 30 días = 09/02.
  lineas := jsonb_build_array(
    jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10,  'costo_unitario', 1250.5),
    jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 2.5, 'costo_unitario', 3000),
    jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 4,   'costo_unitario', 25000));
  r := public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'bodega_id', pruebas.id('B1'),
         'numero_documento', '000-001-01-00000100', 'fecha', '2026-01-10', 'condicion', 'credito', 'lineas', lineas), op);
  PERFORM pruebas.afirmar((r->>'subtotal_centavos')::bigint = 120005 AND (r->>'isv_centavos')::bigint = 19876
    AND (r->>'total_centavos')::bigint = 139881 AND NOT (r->>'duplicado')::boolean, 'totales a mano: ' || r::text);
  SELECT * INTO c1 FROM public.compra WHERE id = (r->>'compra_id')::uuid;
  PERFORM pruebas.afirmar(c1.fecha_vencimiento = '2026-02-09' AND c1.numero = 1 AND c1.forma_pago IS NULL, 'vencimiento por plazo del proveedor');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 10 AND pruebas.valor('B1','P1') = 12505 AND pruebas.promedio('B1','P1') = 1250.5, 'kardex P1');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P2') = 2.5 AND pruebas.valor('B1','P2') = 7500, 'kardex P2 con fracción');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P3') = 4 AND pruebas.valor('B1','P3') = 100000, 'kardex P3');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 120005 AND pruebas.saldo_libros(e, '1.1.04.01') = 19876
    AND pruebas.saldo_libros(e, '2.1.01.01') = 139881, 'asiento: inventario, ISV crédito, proveedores');
  PERFORM pruebas.afirmar((SELECT origen FROM public.asiento WHERE id = c1.asiento_id) = 'compra', 'origen compra');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.compra_linea l JOIN public.inventario_movimiento m ON m.id = l.movimiento_id
                            WHERE l.compra_id = c1.id AND m.documento_id = c1.id) = 3, 'cada línea ligada a su movimiento');

  -- 2) Reintento (sin internet): mismo id_operacion, nada nuevo.
  r := public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'bodega_id', pruebas.id('B1'),
         'numero_documento', 'otra', 'fecha', '2026-01-10', 'condicion', 'credito', 'lineas', lineas), op);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean AND (r->>'compra_id')::uuid = c1.id, 'reintento devuelve la misma');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 10, 'reintento no duplica kardex');

  -- 3) La misma factura del mismo proveedor no entra dos veces; de otro proveedor sí.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', '000-001-01-00000100', '2026-01-11', 'credito', 'P1', 1, 100)), 'YA_EXISTE', 'factura repetida');
  -- Contado por banco, otro proveedor, mismo número: 5 x 1000 = 5,000 + ISV 750 = 5,750.
  c2 := (public.registrar_compra(e, pruebas.compra('PROV2', 'B1', '000-001-01-00000100', '2026-01-11', 'contado', 'P1', 5, 1000, 'banco'),
         gen_random_uuid())->>'compra_id')::uuid;
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.03') = -5750, 'sale del banco 5750');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 15 AND pruebas.valor('B1','P1') = 17505 AND pruebas.promedio('B1','P1') = 1167, 'P1: 17505/15 = 1167');

  -- 4) ISV indicado a mano para cuadrar con la factura del proveedor.
  r := public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV2'), 'bodega_id', pruebas.id('B1'),
         'numero_documento', 'F-ISV', 'fecha', '2026-01-11', 'condicion', 'contado', 'forma_pago', 'caja',
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'costo_unitario', 1250.5, 'isv_centavos', 1875))),
         gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'isv_centavos')::bigint = 1875 AND (r->>'total_centavos')::bigint = 14380, 'ISV de la factura');

  -- 5) Todo o nada: si una línea falla, no queda nada.
  PERFORM pruebas.como('superusuario');
  SELECT (SELECT count(*) FROM public.compra), (SELECT count(*) FROM public.inventario_movimiento), (SELECT count(*) FROM public.asiento)
    INTO n_c, n_m, n_a;
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'proveedor_id', pruebas.id('PROV1'), 'bodega_id', pruebas.id('B1'), 'numero_documento', 'F-MALA', 'fecha', '2026-01-12', 'condicion', 'credito',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'costo_unitario', 100),
                                jsonb_build_object('producto_id', gen_random_uuid(), 'cantidad', 1, 'costo_unitario', 100)))), 'PRODUCTO_INVALIDO', 'línea mala');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.compra) = n_c AND (SELECT count(*) FROM public.inventario_movimiento) = n_m
    AND (SELECT count(*) FROM public.asiento) = n_a, 'nada guardado');

  -- 6) Validaciones.
  PERFORM pruebas.como('admin_a');
  cli := (public.crear_tercero(e, '{"nombre": "Cliente X", "es_cliente": true}', gen_random_uuid())->>'tercero_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, 100) || jsonb_build_object('proveedor_id', cli)), 'TERCERO_INVALIDO', 'cliente como proveedor');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'contado', 'P1', 1, 100)), 'forma de pago', 'contado sin forma de pago');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, 100, 'caja')), 'no lleva forma de pago', 'crédito con forma de pago');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 0, 100)), 'CANTIDAD_INVALIDA', 'cantidad cero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, -5)), 'LINEA_INVALIDA', 'costo negativo');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, 0.0000001)), 'LINEA_INVALIDA', 'costo con 7 decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, 0)), 'L 0.00', 'compra en cero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, 100) || '{"fecha": "2026-31-01"}'), 'FECHA_INVALIDA', 'fecha mala');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2025-12-31', 'credito', 'P1', 1, 100)), 'FECHA_ANTERIOR_AL_INICIO', 'antes del inicio');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, 100) || '{"fecha_vencimiento": "2026-01-01"}'), 'vencimiento', 'vence antes');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'proveedor_id', pruebas.id('PROV1'), 'bodega_id', pruebas.id('B1'), 'numero_documento', 'F-1', 'fecha', '2026-01-12', 'condicion', 'credito',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1, 'costo_unitario', 100, 'isv_centavos', 15)))), 'ISV', 'ISV en exento');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, NULL)', e,
    pruebas.compra('PROV1', 'B1', 'F-1', '2026-01-12', 'credito', 'P1', 1, 100)), 'FALTA_ID_OPERACION', 'sin id_operacion');

  -- 7) Anular la compra de contado (5 x 1000): sale a lo que costó; vuelve al banco.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid(), %L)', c2, 'no', '2026-01-15'), 'FALTA_MOTIVO', 'anular sin motivo');
  op := gen_random_uuid();
  r := public.anular_compra(c2, 'Mercadería devuelta al proveedor', op, '2026-01-15');
  PERFORM pruebas.afirmar((r->>'ajuste_costo_centavos')::bigint = 0, 'sin ajuste de costo');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.03') = 0, 'banco vuelve a 0');
  -- P1 antes: Q 25, V 17505 + 12505 = 30010; sale 5 a 1000: Q 20, V 25010.
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 20 AND pruebas.valor('B1','P1') = 25010, 'contra-movimiento en kardex');
  PERFORM pruebas.afirmar((public.anular_compra(c2, 'Mercadería devuelta al proveedor', op, '2026-01-15')->>'duplicado')::boolean, 'reintento de anulación');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid(), %L)', c2, 'otra vez', '2026-01-15'), 'YA_ANULADO', 'anular dos veces');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado FROM public.v_asiento WHERE id = (SELECT asiento_id FROM public.compra WHERE id = c2)) = 'anulado', 'asiento original anulado');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'compra' AND accion = 'UPDATE' AND registro_id = c2::text
    AND motivo = 'Mercadería devuelta al proveedor'), 'anulación en bitácora');
  -- La factura anulada se puede volver a registrar bien.
  PERFORM pruebas.como('admin_a');
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B1', '000-001-01-00000100', '2026-01-15', 'contado', 'P1', 4, 1000, 'banco'), gen_random_uuid());

  -- 8) No se anula si dejaría existencia negativa (ni con negativo permitido).
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-16',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 3)), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"permite_existencia_negativa": true}', 'Probar que anular no lo usa');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid(), %L)', c1.id, 'Factura equivocada', '2026-01-16'), 'EXISTENCIA_INSUFICIENTE', 'anular deja negativo');
  PERFORM pruebas.afirmar((SELECT anulada_en FROM public.compra WHERE id = c1.id) IS NULL, 'sigue vigente');

  -- 9) Ajuste de costo al anular: B2 arroz: inicial 10 x 1000 = 10,000; compra 10 x 2000 = 20,000
  --    (Q 20, V 30,000, prom. 1500); trasladan 10 a B1 (salen 15,000) -> Q 10, V 15,000.
  --    Anular la compra: salen los 10 que quedan con TODO su valor (15,000);
  --    diferencia 20,000 - 15,000 = 5,000 al haber de 5.1.01.02. Dr Caja 20,000.
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B2'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 10, 'costo_unitario', 1000)), gen_random_uuid());
  c3 := (public.registrar_compra(e, pruebas.compra('PROV2', 'B2', 'F-ARROZ', '2026-01-17', 'contado', 'P2', 10, 2000, 'caja'), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.trasladar_inventario(e, pruebas.id('B2'), pruebas.id('B1'), '2026-01-17',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 10)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B2','P2') = 10 AND pruebas.valor('B2','P2') = 15000, 'antes de anular');
  r := public.anular_compra(c3, 'Precio equivocado en factura', gen_random_uuid(), '2026-01-18');
  PERFORM pruebas.afirmar((r->>'ajuste_costo_centavos')::bigint = 5000, 'ajuste de costo 5000');
  PERFORM pruebas.afirmar(pruebas.existencia('B2','P2') = 0 AND pruebas.valor('B2','P2') = 0, 'B2 vacía sin centavos sueltos');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '5.1.01.02') = -5000, 'ajuste al haber de 5.1.01.02');

  -- 10) Las cuentas que mueve el módulo no aceptan asientos manuales,
  --     y el asiento de una compra no se anula con anular_asiento.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-20', pruebas.lineas('1.1.03.01', '1.1.01.01', 100)), 'CUENTA_CONTROLADA', 'manual a inventario');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-20', pruebas.lineas('1.1.01.01', '2.1.01.01', 100)), 'CUENTA_CONTROLADA', 'manual a proveedores');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', c1.asiento_id, 'anular por fuera'), 'PROHIBIDO', 'anular_asiento de una compra');

  -- 11) Kardex = libros y la compra no se edita ni borra.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'), 'kardex = libros');
  PERFORM pruebas.debe_fallar(format('UPDATE public.compra SET total_centavos = 1 WHERE id = %L', c1.id), 'PROHIBIDO', 'editar compra');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.compra_linea WHERE compra_id = %L', c1.id), 'PROHIBIDO', 'borrar línea');
  PERFORM pruebas.debe_fallar(format('UPDATE public.compra SET anulada_en = NULL, motivo_anulacion = NULL, asiento_anulacion_id = NULL WHERE id = %L', c2), 'PROHIBIDO', 'des-anular');

  -- 12) Sin módulo compras, no se compra.
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'compras';
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-9', '2026-01-12', 'credito', 'P1', 1, 100)), 'MODULO_INACTIVO', 'módulo compras apagado');
END $$;
