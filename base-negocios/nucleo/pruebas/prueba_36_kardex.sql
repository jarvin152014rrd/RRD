-- PRUEBA: kardex con costo promedio ponderado (cifras a mano): entradas, traslados, ajustes con su asiento, negativo solo si se permite (con alerta), fracciones
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  r  jsonb;
  n  bigint;
  a  public.asiento;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');

  -- 1) Saldo inicial B1: 100 tornillos a L 10.00 (1000 centavos) = 100,000.
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 100 AND pruebas.valor('B1','P1') = 100000 AND pruebas.promedio('B1','P1') = 1000, 'paso 1');

  -- 2) Compra al crédito: 50 a 1300 = 65,000.  Q 150, V 165,000, promedio 1100.
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-001', '2026-01-05', 'credito', 'P1', 50, 1300), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 150 AND pruebas.valor('B1','P1') = 165000 AND pruebas.promedio('B1','P1') = 1100, 'paso 2');

  -- 3) Traslado B1 -> B2 de 30: salen 30 x 1100 = 33,000.
  r := public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-06',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 30)), gen_random_uuid(), 'Para mostrador');
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 33000 AND r->>'asiento_id' IS NULL, 'traslado sin asiento');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 120 AND pruebas.valor('B1','P1') = 132000 AND pruebas.promedio('B1','P1') = 1100, 'paso 3 B1');
  PERFORM pruebas.afirmar(pruebas.existencia('B2','P1') = 30 AND pruebas.valor('B2','P1') = 33000 AND pruebas.promedio('B2','P1') = 1100, 'paso 3 B2');

  -- 4) Compra de contado: 20 a 1234.5678 -> subtotal round(24,691.356) = 24,691.
  --    B1: Q 140, V 156,691, promedio 156691/140 = 1119.221428571 -> 1119.221429
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'F-777', '2026-01-07', 'contado', 'P1', 20, 1234.5678, 'caja'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 140 AND pruebas.valor('B1','P1') = 156691 AND pruebas.promedio('B1','P1') = 1119.221429, 'paso 4');

  -- 5) Conteo físico B1: hay 137 (faltan 3). Salen round(3 x 1119.221429) = round(3357.664287) = 3,358.
  --    B1: Q 137, V 153,333, promedio 153333/137 = 1119.218978
  --    Asiento: Dr Faltantes 5.1.01.02 3,358 / Cr Inventario 3,358.
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 137)), 'no'), 'FALTA_MOTIVO', 'ajuste sin motivo');
  r := public.ajustar_inventario(e, pruebas.id('B1'), '2026-01-08',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 137)), 'Conteo físico de enero', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'faltante_centavos')::bigint = 3358 AND (r->>'sobrante_centavos')::bigint = 0, 'faltante 3358: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 137 AND pruebas.valor('B1','P1') = 153333 AND pruebas.promedio('B1','P1') = 1119.218978, 'paso 5');
  PERFORM pruebas.como('superusuario');
  SELECT * INTO a FROM public.asiento WHERE id = (r->>'asiento_id')::uuid;
  PERFORM pruebas.afirmar(a.origen = 'ajuste_inventario' AND a.total_centavos = 3358, 'asiento del ajuste');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ' ' ORDER BY l.linea)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = a.id)
                          = '5.1.01.02:3358/0 1.1.03.01:0/3358', 'líneas del ajuste');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.inventario_documento_linea l JOIN public.inventario_documento d ON d.id = l.documento_id
                            WHERE d.id = (r->>'documento_id')::uuid AND l.existencia_sistema = 140 AND l.cantidad_contada = 137 AND l.cantidad = -3) = 1,
                          'el documento guarda sistema, contado y diferencia');

  -- 6) Conteo B2: hay 32 (sobran 2) a promedio 1100 = 2,200. Dr Inventario / Cr Sobrantes 4.2.01.02.
  PERFORM pruebas.como('admin_a');
  r := public.ajustar_inventario(e, pruebas.id('B2'), '2026-01-08',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 32)), 'Conteo físico de enero', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'sobrante_centavos')::bigint = 2200, 'sobrante 2200');
  PERFORM pruebas.afirmar(pruebas.existencia('B2','P1') = 32 AND pruebas.valor('B2','P1') = 35200, 'paso 6');
  -- Conteo sin diferencias: documento sin asiento.
  r := public.ajustar_inventario(e, pruebas.id('B2'), '2026-01-08',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 32)), 'Reconteo sin diferencias', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'asiento_id' IS NULL AND (r->>'total_centavos')::bigint = 0, 'sin diferencia, sin asiento');

  -- Libros a mano: inventario 100000 + 65000 + 24691 - 3358 + 2200 = 188,533 = kardex 153,333 + 35,200.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 188533, 'inventario en libros = 188533');
  PERFORM pruebas.afirmar(pruebas.valor('B1','P1') + pruebas.valor('B2','P1') = 188533, 'kardex = 188533');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '5.1.01.02') = 3358 AND pruebas.saldo_libros(e, '4.2.01.02') = 2200, 'faltantes y sobrantes');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '3.3.01.03') = 100000, 'Saldos de apertura por saldo inicial (0.4.0)');

  -- 7) Sin permiso ni configuración no queda en negativo; no se guarda nada.
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM public.inventario_movimiento;
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B2'), pruebas.id('B1'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 40))), 'EXISTENCIA_INSUFICIENTE', 'traslado deja negativo');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.inventario_movimiento) = n, 'todo o nada: ningún movimiento');

  -- 8) El dueño permite negativo: B2 queda en -8 con alerta.
  --    Salen 40 x 1100 = 44,000: B2 Q -8, V 35200 - 44000 = -8,800.
  --    B1: Q 177, V 197,333, promedio 197333/177 = 1114.875706
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"permite_existencia_negativa": true}', 'Se vende antes de ingresar');
  PERFORM pruebas.como('admin_a');
  PERFORM public.trasladar_inventario(e, pruebas.id('B2'), pruebas.id('B1'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 40)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B2','P1') = -8 AND pruebas.valor('B2','P1') = -8800, 'B2 en negativo');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 177 AND pruebas.valor('B1','P1') = 197333 AND pruebas.promedio('B1','P1') = 1114.875706, 'paso 8 B1');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.inventario_alerta WHERE producto_id = pruebas.id('P1')
                            AND bodega_id = pruebas.id('B2') AND cantidad_resultante = -8 AND tipo = 'existencia_negativa') = 1, 'alerta registrada');
  PERFORM pruebas.afirmar(pruebas.valor('B1','P1') + pruebas.valor('B2','P1') = pruebas.saldo_libros(e, '1.1.03.01'), 'kardex sigue = libros');

  -- 9) Fracciones: el arroz sí (10.5 lb a 2000 = 21,000); el tornillo no.
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 10.5, 'costo_unitario', 2000)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P2') = 10.5 AND pruebas.valor('B1','P2') = 21000, 'arroz con fracción');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1.5))), 'CANTIDAD_INVALIDA', 'tornillo con fracción');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 0.00001))), 'CANTIDAD_INVALIDA', 'más de 4 decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', -1))), 'CANTIDAD_INVALIDA', 'cantidad negativa');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B1'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1))), 'BODEGA_INVALIDA', 'misma bodega');
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-09',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 1), jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 2)),
    'Conteo repetido'), 'repetido', 'producto repetido en el conteo');

  -- 10) Mover el kardex de una venta a costo promedio: arroz, sale todo (10.5): sale TODO el valor (21,000).
  PERFORM pruebas.como('superusuario');
  PERFORM interno.mover_inventario(e, pruebas.id('B1'), pruebas.id('P2'), 'salida', 'prueba', '2026-01-10', -10.5, NULL,
                                   'prueba', gen_random_uuid(), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P2') = 0 AND pruebas.valor('B1','P2') = 0, 'vaciar deja valor 0');

  -- 11) El kardex es de solo agregar; el saldo coincide con la suma de movimientos.
  PERFORM pruebas.debe_fallar('UPDATE public.inventario_movimiento SET cantidad = 1', 'PROHIBIDO', 'editar kardex');
  PERFORM pruebas.debe_fallar('DELETE FROM public.inventario_movimiento', 'PROHIBIDO', 'borrar kardex');
  PERFORM pruebas.debe_fallar('TRUNCATE public.inventario_movimiento CASCADE', 'PROHIBIDO', 'vaciar kardex');
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.inventario_saldo s
     LEFT JOIN (SELECT m.bodega_id, m.producto_id, sum(m.cantidad) AS q, sum(m.valor_centavos) AS v
                  FROM public.inventario_movimiento m GROUP BY 1, 2) k
            ON k.bodega_id = s.bodega_id AND k.producto_id = s.producto_id
     WHERE (s.cantidad, s.valor_centavos) IS DISTINCT FROM (coalesce(k.q, 0), coalesce(k.v, 0))), 'saldo = suma del kardex');

  -- 12) Mes cerrado: no se ajusta ni traslada con esa fecha.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(e, '2026-02-01', 'Mov. febrero', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
  PERFORM public.cerrar_periodo(e, 2026, 1);
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-20',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))), 'PERIODO_CERRADO', 'traslado en mes cerrado');
END $$;
