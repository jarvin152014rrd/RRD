-- PRUEBA: costo promedio en orden de registro (entrada con fecha anterior a la última salida: no, salvo permiso del dueño), existencia 0 = valor 0 con ajuste de costo (negativo a cero) y no quitar fracciones con existencias fraccionarias
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  n   bigint;
  m   public.inventario_movimiento;
  r   jsonb;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');

  -- ===== Entradas con fecha atrasada =====
  -- Carga B1: 10 x 1000 = 10,000. Traslado 4 a B2 el 10/01 (salida de B1 con fecha 10/01).
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'costo_unitario', 1000)), gen_random_uuid());
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-10',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 4)), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM public.compra;
  PERFORM pruebas.como('admin_a');
  -- Compra a B1 fechada el 08/01: no (cambiaría el costo de la salida del 10/01). Nada se guarda.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'ATR-1', '2026-01-08', 'credito', 'P1', 4, 1500)), 'ENTRADA_FECHA_ATRASADA', 'compra con fecha atrasada');
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 7)), 'Conteo atrasado'), 'ENTRADA_FECHA_ATRASADA', 'sobrante con fecha atrasada');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.compra) = n, 'todo o nada: no quedó la compra');
  PERFORM pruebas.como('admin_a');
  -- El mismo día de la salida sí: 4 x 1500 = 6,000 -> B1 10 / 12,000, promedio 1,200.
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'ATR-1', '2026-01-10', 'credito', 'P1', 4, 1500), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 10 AND pruebas.valor('B1', 'P1') = 12000 AND pruebas.promedio('B1', 'P1') = 1200, 'compra del 10/01');
  -- En B2 no hay salidas: una entrada con fecha anterior sí entra.
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B2', 'ATR-2', '2026-01-05', 'credito', 'P1', 1, 1000), gen_random_uuid());
  -- El dueño (inventario.fecha_atrasada) sí puede; el costo sigue el ORDEN DE REGISTRO:
  -- 10 x 1300 = 13,000 -> B1 20 / 25,000, promedio 1,250; la salida del 10/01 NO se recalcula (sigue en 4,000).
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'ATR-3', '2026-01-08', 'credito', 'P1', 10, 1300), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 20 AND pruebas.valor('B1', 'P1') = 25000 AND pruebas.promedio('B1', 'P1') = 1250, 'compra atrasada del dueño');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT valor_centavos FROM public.inventario_movimiento WHERE bodega_id = pruebas.id('B1') AND origen = 'traslado') = -4000,
    'la salida ya hecha no cambia');

  -- ===== Negativo a cero: el valor sobrante va a ajuste de costo =====
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"permite_existencia_negativa": true}', 'Se vende antes de ingresar');
  PERFORM pruebas.como('admin_a');
  -- B2 arroz: carga 5 lb x 2000 = 10,000; salen 8 lb x 2000 = 16,000 -> B2 -3 lb / -6,000.
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B2'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 5, 'costo_unitario', 2000)), gen_random_uuid());
  PERFORM public.trasladar_inventario(e, pruebas.id('B2'), pruebas.id('B1'), '2026-01-03',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 8)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B2', 'P2') = -3 AND pruebas.valor('B2', 'P2') = -6000, 'B2 en -3 / -6,000');
  -- Entran 3 lb x 2500 = 7,500: quedaría 0 lb con 1,500 -> ajuste de costo -1,500 (Dr 5.1.01.02 / Cr 1.1.03.01).
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B2', 'NEG-1', '2026-01-04', 'contado', 'P2', 3, 2500, 'caja'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B2', 'P2') = 0 AND pruebas.valor('B2', 'P2') = 0, 'cero unidades = L 0.00');
  PERFORM pruebas.como('superusuario');
  SELECT * INTO m FROM public.inventario_movimiento WHERE bodega_id = pruebas.id('B2') AND producto_id = pruebas.id('P2') ORDER BY id DESC LIMIT 1;
  PERFORM pruebas.afirmar(m.tipo = 'ajuste_costo' AND m.cantidad = 0 AND m.valor_centavos = -1500 AND m.saldo_cantidad = 0
    AND m.saldo_valor_centavos = 0, 'línea de ajuste de costo en el kardex');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ' ' ORDER BY l.linea)
                             FROM public.asiento a JOIN public.asiento_linea l ON l.asiento_id = a.id JOIN public.cuenta c ON c.id = l.cuenta_id
                            WHERE a.empresa_id = e AND a.origen = 'ajuste_costo_inventario')
                          = '5.1.01.02:1500/0 1.1.03.01:0/1500', 'asiento del ajuste de costo');
  -- Al revés: B2 -2 lb / -5,000 (a 2,500) y entran 2 lb x 2000 = 4,000 -> quedaría -1,000: ajuste +1,000.
  PERFORM pruebas.como('admin_a');
  PERFORM public.trasladar_inventario(e, pruebas.id('B2'), pruebas.id('B1'), '2026-01-05',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 2)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B2', 'P2') = -2 AND pruebas.valor('B2', 'P2') = -5000, 'B2 en -2 / -5,000');
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B2', 'NEG-2', '2026-01-06', 'contado', 'P2', 2, 2000, 'caja'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B2', 'P2') = 0 AND pruebas.valor('B2', 'P2') = 0, 'otra vez 0 = L 0.00');
  -- 5.1.01.02: 1,500 - 1,000 = 500. Inventario en libros a mano:
  --   10,000 + 6,000 + 1,000 + 13,000 (P1) + 10,000 + 7,500 - 1,500 + 4,000 + 1,000 (P2) = 51,000 = kardex.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '5.1.01.02') = 500, 'ajuste neto 500');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 51000, 'inventario 51,000: ' || pruebas.saldo_libros(e, '1.1.03.01'));
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = 51000, 'kardex 51,000');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.inventario_saldo WHERE cantidad = 0 AND valor_centavos <> 0), 'ningún 0 con valor');

  -- ===== Fracciones =====
  -- B1 arroz: 8 + 2 = 10 lb. Salen 0.5 lb a B2: queda 9.5 -> no se puede quitar "se vende con decimales".
  PERFORM pruebas.como('admin_a');
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-07',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 0.5)), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P2'), '{"permite_fracciones": false}'), 'decimales', 'fracciones con existencia 9.5');
  PERFORM pruebas.afirmar((SELECT permite_fracciones FROM public.producto WHERE id = pruebas.id('P2')), 'sigue con fracciones');
  -- Vuelve la media libra: 10 y 0 -> ahora sí; y desde ahí no acepta decimales.
  PERFORM public.trasladar_inventario(e, pruebas.id('B2'), pruebas.id('B1'), '2026-01-07',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 0.5)), gen_random_uuid());
  PERFORM public.editar_producto(e, pruebas.id('P2'), '{"permite_fracciones": false}');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-07',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1.5))), 'CANTIDAD_INVALIDA', 'ya no acepta decimales');
  PERFORM public.editar_producto(e, pruebas.id('P2'), '{"permite_fracciones": true}');   -- volver a permitir: siempre se puede
END $$;
