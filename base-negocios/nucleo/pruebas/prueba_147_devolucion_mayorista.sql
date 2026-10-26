-- PRUEBA: (0.19.0) devolución parcial de una venta con precio mayorista POR CANTIDAD (decisión del dueño A1), cifras a mano: si lo que se queda baja de "desde cantidad", lo que conserva pasa a precio normal y la diferencia se descuenta de lo devuelto ("Ajuste por perder precio mayorista"); si el ajuste se come todo, se rechaza con un mensaje claro y sin guardar nada; varias devoluciones seguidas = una sola (acumulado) y al devolver todo vuelve el ajuste; base e ISV netos (ISV de las notas = ISV de la venta); asiento exacto; cálculo previo (devolución y cambio) igual a lo registrado; nota de crédito con el texto; cliente mayorista (por cliente), la venta que no baja del mínimo y la garantía no llevan ajuste; la línea guarda por qué fue mayorista
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   jsonb;
  v2   jsonb;
  v3   jsonb;
  pv   jsonb;
  d    jsonb;
  doc  jsonb;
  n    bigint;
  isv  text;
  cja  text;
  caja0 bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de devolución mayorista');
  -- Tornillo P1: L 15.00 con ISV 15 % (costo L 10.00); mayorista L 12.00 desde 12 unidades.
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 1200, "cantidad_mayorista": 12}', 'Precio de mayoreo');
  SELECT im.cuenta_por_pagar INTO isv FROM public.impuesto im WHERE im.empresa_id = e AND im.codigo = 'ISV15';
  SELECT c.codigo INTO cja FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = pruebas.id('CAJA1');

  -- ===== 1) Venta de 12 a Juan Pérez (NO es mayorista): precio mayorista por cantidad =====
  -- 12 x 12.00 = 14,400 con ISV -> base round(14,400 / 1.15) = 12,522; ISV 1,878.
  v1 := public.registrar_venta(e, pruebas.venta('P1', 12, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.afirmar((v1->>'total_centavos')::bigint = 14400, 'venta mayorista: ' || v1::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT precio_tipo = 'mayorista' AND mayorista_por = 'cantidad' AND mayorista_desde = 12 AND precio_normal_centavos = 1500
                             AND base_centavos = 12522 AND impuesto_centavos = 1878
                             FROM public.venta_linea WHERE venta_id = (v1->>'venta_id')::uuid), 'la línea guarda por qué fue mayorista');

  -- ===== 2) Devolver 2 (se queda con 10): el ajuste se come todo -> rechazo claro =====
  -- Lo devuelto vale 2 x 12.00 = 2,400. Las 10 que se queda: a precio normal 15,000; pagó por ellas 12,000.
  -- Ajuste 3,000 > 2,400: no queda nada que devolver.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_devolucion_previa(%L, %L)', v1->>'venta_id', '{"lineas":[{"linea":1,"cantidad":2}]}'),
    'DEVOLUCION_INVALIDA', 'el previo también rechaza');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb, 'motivo', 'Le sobraron', 'destino', 'dinero',
                       'cuenta_dinero_id', pruebas.id('CAJA1'))), 'precio mayorista es desde 12', 'devolver 2 de 12: el ajuste se come todo');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.devolucion WHERE venta_id = (v1->>'venta_id')::uuid) = 0, 'el rechazo no guardó nada');

  -- ===== 3) Devolver 6 (se queda con 6): a mano =====
  -- Pagó 14,400 por 12. Se queda 6 a precio normal = 6 x 15.00 = 9,000. Se le devuelve 14,400 - 9,000 = 5,400.
  -- Lo devuelto vale 6 x 12.00 = 7,200; ajuste 7,200 - 5,400 = 1,800.
  -- Base: acumulada round(12,522 x 6/12) = 6,261; lo que se queda a normal sin ISV round(9,000/1.15) = 7,826 y pagó
  -- 12,522 - 6,261 = 6,261 -> ajuste base 1,565. Base de la nota 6,261 - 1,565 = 4,696; ISV 5,400 - 4,696 = 704.
  PERFORM pruebas.como('dueno_a');
  pv := public.calcular_devolucion_previa((v1->>'venta_id')::uuid, '{"lineas":[{"linea":1,"cantidad":6}]}');
  PERFORM pruebas.afirmar((pv->>'valor_centavos')::bigint = 7200 AND (pv->>'ajuste_mayorista_centavos')::bigint = 1800
    AND (pv->>'total_centavos')::bigint = 5400 AND (pv->>'subtotal_centavos')::bigint = 4696 AND (pv->>'impuesto_centavos')::bigint = 704
    AND pv->>'ajuste_mayorista_texto' = 'Ajuste por perder precio mayorista: L 18.00'
    AND (pv->'lineas'->0->>'conserva')::numeric = 6 AND NOT (pv::text LIKE '%costo%'), 'previo de 6: ' || pv::text);
  -- El cálculo del cambio usa la misma cuenta (lo devuelto vale 5,400).
  PERFORM public.configurar_empresa(e, '{"cambio_exacto": false}', 'Prueba: el previo del cambio');
  d := public.calcular_cambio_previo((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":6}]'::jsonb,
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))));
  PERFORM pruebas.afirmar((d->'devuelto'->>'total_centavos')::bigint = 5400 AND (d->>'ajuste_mayorista_centavos')::bigint = 1800
    AND d->'devuelto'->'lineas'->0->>'ajuste_texto' LIKE 'Ajuste por perder precio mayorista: L 18.00%', 'previo del cambio: ' || d::text);
  PERFORM public.configurar_empresa(e, '{"cambio_exacto": true}', 'Prueba: vuelve la regla');
  caja0 := pruebas.dinero('CAJA1');
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":6}]'::jsonb,
         'motivo', 'Le sobraron', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar(d->>'estado' = 'aplicada' AND (d->>'total_centavos')::bigint = 5400 AND (d->>'subtotal_centavos')::bigint = 4696
    AND (d->>'impuesto_centavos')::bigint = 704 AND (d->>'dinero_centavos')::bigint = 5400 AND (d->>'ajuste_mayorista_centavos')::bigint = 1800
    AND (d->>'valor_centavos')::bigint = 7200 AND d->>'ajuste_mayorista_texto' = 'Ajuste por perder precio mayorista: L 18.00', 'devolver 6: ' || d::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = caja0 - 5400, 'salen 5,400 de la caja');
  -- Asiento: Dr 4.1.01.04 4,696 + Dr ISV 704 = Cr caja 5,400; Dr inventario / Cr costo 6 x 1,000 = 6,000.
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ',' ORDER BY c.codigo)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
                            WHERE l.asiento_id = (SELECT asiento_id FROM public.devolucion WHERE id = (d->>'devolucion_id')::uuid))
    = (SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY[cja || ':0/5400', '1.1.03.01:6000/0', isv || ':704/0', '4.1.01.04:4696/0',
                                                              '5.1.01.01:0/6000']) x),
    'asiento exacto: ' || (SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ',' ORDER BY c.codigo)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
                            WHERE l.asiento_id = (SELECT asiento_id FROM public.devolucion WHERE id = (d->>'devolucion_id')::uuid)));
  PERFORM pruebas.afirmar((SELECT ajuste_mayorista_centavos FROM public.devolucion_linea WHERE devolucion_id = (d->>'devolucion_id')::uuid) = 1800
    AND (SELECT ajuste_mayorista_centavos FROM public.v_devolucion WHERE devolucion_id = (d->>'devolucion_id')::uuid) = 1800, 'el ajuste queda guardado');
  PERFORM pruebas.como('dueno_a');
  doc := public.documento_nota_credito((d->>'devolucion_id')::uuid);
  PERFORM pruebas.afirmar(doc->>'ajuste_mayorista_texto' = 'Ajuste por perder precio mayorista: L 18.00'
    AND (doc->>'valor_devuelto_centavos')::bigint = 7200 AND (doc->'totales'->>'total_centavos')::bigint = 5400
    AND (doc->'lineas'->0->>'ajuste_mayorista_centavos')::bigint = 1800, 'nota de crédito: ' || doc::text);

  -- ===== 4) Devolver 3 más (se queda con 3): sobre lo ACUMULADO =====
  -- Se queda 3 a normal = 4,500. En total se le devuelve 14,400 - 4,500 = 9,900; ya recibió 5,400 -> ahora 4,500.
  -- Base: acumulada round(12,522 x 9/12) = 9,392 (9,391.5); lo que se queda: round(4,500/1.15) = 3,913 contra 12,522 - 9,392
  -- = 3,130 -> ajuste base 783; base total 9,392 - 783 = 8,609; ya devuelta 4,696 -> 3,913. ISV 4,500 - 3,913 = 587.
  -- Lo devuelto vale 3 x 12.00 = 3,600 y se devuelven 4,500: vuelve 900 del ajuste anterior.
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":3}]'::jsonb,
         'motivo', 'Le sobraron otros', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'total_centavos')::bigint = 4500 AND (d->>'subtotal_centavos')::bigint = 3913 AND (d->>'impuesto_centavos')::bigint = 587
    AND (d->>'ajuste_mayorista_centavos')::bigint = -900 AND d->>'ajuste_mayorista_texto' = 'Se devuelve el ajuste por precio mayorista: L 9.00',
    'devolver 3 más: ' || d::text);

  -- ===== 5) Devolver las últimas 3 (se queda con 0): vuelve todo el ajuste =====
  -- En total se le devuelve 14,400; ya recibió 9,900 -> 4,500. Base 12,522 - 8,609 = 3,913; ISV 587.
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":3}]'::jsonb,
         'motivo', 'Ya no las ocupa', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'total_centavos')::bigint = 4500 AND (d->>'subtotal_centavos')::bigint = 3913 AND (d->>'impuesto_centavos')::bigint = 587
    AND (d->>'ajuste_mayorista_centavos')::bigint = -900, 'devolver las últimas: ' || d::text);
  PERFORM pruebas.como('superusuario');
  -- Todo devuelto: lo mismo que pagó, la misma base y el mismo ISV que la venta; los ajustes suman cero.
  PERFORM pruebas.afirmar((SELECT sum(total_centavos) = 14400 AND sum(subtotal_centavos) = 12522 AND sum(impuesto_centavos) = 1878
                             AND sum(ajuste_mayorista_centavos) = 0
                             FROM public.devolucion WHERE venta_id = (v1->>'venta_id')::uuid), 'todo devuelto = lo pagado');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = caja0 - 14400, 'salieron 14,400 de la caja en total');

  -- ===== 6) Una sola devolución de 9 = las dos primeras juntas (5,400 + 4,500 = 9,900; base 8,609) =====
  PERFORM pruebas.como('dueno_a');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 12, 'efectivo', 'CLI2'), gen_random_uuid());
  pv := public.calcular_devolucion_previa((v2->>'venta_id')::uuid, '{"lineas":[{"linea":1,"cantidad":9}]}');
  PERFORM pruebas.afirmar((pv->>'total_centavos')::bigint = 9900 AND (pv->>'subtotal_centavos')::bigint = 8609
    AND (pv->>'ajuste_mayorista_centavos')::bigint = 900, 'una de 9: ' || pv::text);

  -- ===== 7) Venta de 15 (desde 12): devolver 3 no baja del mínimo -> sin ajuste =====
  -- 15 x 12.00 = 18,000. Devolver 3 -> se queda 12: proporcional 3,600 sin ajuste.
  -- Después devolver 9 (se queda 3): en total 18,000 - 4,500 = 13,500; ya 3,600 -> 9,900; lo devuelto vale 10,800, ajuste 900.
  v3 := public.registrar_venta(e, pruebas.venta('P1', 15, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.afirmar((v3->>'total_centavos')::bigint = 18000, 'venta de 15');
  d := public.registrar_devolucion((v3->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":3}]'::jsonb,
         'motivo', 'Le sobraron', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'total_centavos')::bigint = 3600 AND (d->>'ajuste_mayorista_centavos')::bigint = 0
    AND d->>'ajuste_mayorista_texto' IS NULL, 'sin bajar del mínimo: ' || d::text);
  -- Devolver 1 más (se queda con 11): ajuste 16,500 - 13,200 = 3,300 contra 1,200 de valor -> rechazo.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v3->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Otra más', 'destino', 'dinero',
                       'cuenta_dinero_id', pruebas.id('CAJA1'))), 'no haga la devolución', 'devolver 1 más: rechazo');
  d := public.registrar_devolucion((v3->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":9}]'::jsonb,
         'motivo', 'Le sobraron más', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'total_centavos')::bigint = 9900 AND (d->>'ajuste_mayorista_centavos')::bigint = 900, 'devolver 9: ' || d::text);

  -- ===== 8) Cliente MAYORISTA (por cliente): nunca hay ajuste =====
  PERFORM public.editar_tercero(e, pruebas.id('CLI1'), '{"es_mayorista": true}', 'Cliente mayorista');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 6, 'efectivo', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar((v2->>'total_centavos')::bigint = 7200, 'mayorista por cliente: ' || v2::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT mayorista_por = 'cliente' FROM public.venta_linea WHERE venta_id = (v2->>'venta_id')::uuid), 'por cliente');
  PERFORM pruebas.como('dueno_a');
  d := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":3}]'::jsonb,
         'motivo', 'Le sobraron', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'total_centavos')::bigint = 3600 AND (d->>'ajuste_mayorista_centavos')::bigint = 0, 'cliente mayorista: ' || d::text);
  PERFORM public.editar_tercero(e, pruebas.id('CLI1'), '{"es_mayorista": false}', 'Ya no es mayorista');

  -- ===== 9) Garantía: el producto vino malo, sin ajuste =====
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"dias_garantia": 30}');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 12, 'efectivo', 'CLI2'), gen_random_uuid());
  d := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v2->'venta_id', 'linea', 1, 'cantidad', 2,
         'motivo', 'Vienen sin rosca'), gen_random_uuid());
  d := public.resolver_reclamo_garantia((d->>'reclamo_id')::uuid, jsonb_build_object('resolucion', 'devuelto', 'destino', 'dinero',
         'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->'devolucion'->>'total_centavos')::bigint = 2400 AND (d->'devolucion'->>'ajuste_mayorista_centavos')::bigint = 0,
    'garantía sin ajuste: ' || d::text);

  -- ===== 10) Cuadre: ISV por pagar y libros =====
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM public.asiento a
   WHERE a.empresa_id = e AND (SELECT sum(debe_centavos) - sum(haber_centavos) FROM public.asiento_linea l WHERE l.asiento_id = a.id) <> 0;
  PERFORM pruebas.afirmar(n = 0, 'todos los asientos cuadran');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora íntegra');
END $$;
