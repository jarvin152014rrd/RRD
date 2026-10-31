-- PRUEBA: (0.19.0, revisión) cifras a mano: (1) una devolución nueva sobre una línea con otra pendiente de aprobación se rechaza con un mensaje claro; rechazada la pendiente, la nueva da lo correcto (10 a L 90.00, normal L 100.00 desde 10: devolver 3 = L 200.00, no L 300.00); (2) una garantía después de una devolución con ajuste mayorista NO le devuelve el ajuste al cliente (solo el valor proporcional); (3) el cálculo previo del cambio por garantía (con reclamo_id) coincide con lo que se guarda; (4) el crédito "de vuelta" de un cambio exacto de una venta al crédito no pide aprobación aunque la regla sea "siempre_aprobacion" y vence cuando vencía la original; (5) una línea de antes de 0.19.0 vendida con menos que "desde cantidad" es mayorista por cliente (sin ajuste); todo cuadra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   jsonb;
  v2   jsonb;
  d    jsonb;
  pv   jsonb;
  r    jsonb;
  vnue public.venta;
  n    bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de la revisión 0.19.0');
  -- Tornillo P1: normal L 100.00 con ISV, mayorista L 90.00 desde 10; 30 días de garantía.
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 10000, 'Precio de prueba');
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 9000, "cantidad_mayorista": 10, "dias_garantia": 30}', 'Mayoreo');

  -- ===== 1) Pendiente de aprobación primero =====
  -- Venta de 10 a Juan Pérez: 10 x 90.00 = 90,000.
  v1 := public.registrar_venta(e, pruebas.venta('P1', 10, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.afirmar((v1->>'total_centavos')::bigint = 90000, 'venta: ' || v1::text);
  -- A (cajero): 2 a saldo a favor; el cajero siempre pide aprobación -> pendiente (se queda 8: 90,000 - 80,000 = 10,000).
  PERFORM pruebas.como('cajero_a');
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb,
         'motivo', 'Le sobraron', 'destino', 'saldo_favor'), gen_random_uuid());
  PERFORM pruebas.afirmar(d->>'estado' = 'pendiente_aprobacion' AND (d->>'total_centavos')::bigint = 10000, 'A pendiente: ' || d::text);
  -- B (dueño): 3 más mientras A espera -> se rechaza, sin guardar nada.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":3}]'::jsonb, 'motivo', 'Otras más', 'destino', 'saldo_favor')),
    'esperando aprobación', 'B con A pendiente');
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_devolucion_previa(%L, %L)', v1->>'venta_id', '{"lineas":[{"linea":1,"cantidad":3}]}'),
    'esperando aprobación', 'el previo también');
  -- Se rechaza A; ahora B: se queda 7 a 100.00 = 70,000; se le devuelve 90,000 - 70,000 = 20,000 (L 200.00).
  PERFORM public.resolver_aprobacion((d->>'aprobacion_id')::uuid, false, 'No corresponde', gen_random_uuid());
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":3}]'::jsonb,
         'motivo', 'Otras más', 'destino', 'saldo_favor'), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'total_centavos')::bigint = 20000 AND (d->>'ajuste_mayorista_centavos')::bigint = 7000, 'B: ' || d::text);

  -- ===== 2) Garantía después de una devolución con ajuste =====
  -- Venta de 10 (90,000). Devuelve 2: se queda 8 a 100.00 = 80,000 -> recibe 10,000 (L 100.00; ajuste 8,000).
  v2 := public.registrar_venta(e, pruebas.venta('P1', 10, 'efectivo', 'CLI2'), gen_random_uuid());
  d := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb,
         'motivo', 'Le sobraron', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((d->>'total_centavos')::bigint = 10000, 'devolución de 2: ' || d::text);
  -- Garantía "devuelto" de 1: el valor proporcional (round(90,000 x 3/10) - round(90,000 x 2/10) = 9,000), no 17,000.
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v2->'venta_id', 'linea', 1, 'cantidad', 1, 'motivo', 'Sin rosca'), gen_random_uuid());
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, jsonb_build_object('resolucion', 'devuelto', 'destino', 'dinero',
         'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar((r->'devolucion'->>'total_centavos')::bigint = 9000 AND (r->'devolucion'->>'ajuste_mayorista_centavos')::bigint = 0,
    'garantía: ' || r::text);

  -- ===== 3) Cambio por garantía por otro producto: el previo (con reclamo_id) = lo guardado =====
  -- Otro reclamo de 1 de la misma venta; cambio por 1 galón (45,000) pagando la diferencia (regla de cambio exacto apagada).
  PERFORM public.configurar_empresa(e, '{"cambio_exacto": false}', 'Prueba del cambio por garantía con diferencia');
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v2->'venta_id', 'linea', 1, 'cantidad', 1, 'motivo', 'Torcido'), gen_random_uuid());
  pv := public.calcular_cambio_previo((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'reclamo_id', r->'reclamo_id',
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)))));
  -- Sin ajuste: round(90,000 x 4/10) - round(90,000 x 3/10) = 9,000; paga 45,000 - 9,000 = 36,000.
  PERFORM pruebas.afirmar((pv->'devuelto'->>'total_centavos')::bigint = 9000 AND (pv->>'a_cobrar_centavos')::bigint = 36000
    AND (pv->>'garantia')::boolean, 'previo de garantía: ' || pv::text);
  d := public.calcular_cambio_previo((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)))));
  PERFORM pruebas.afirmar((d->'devuelto'->>'total_centavos')::bigint <> 9000, 'sin reclamo_id sí lleva ajuste: ' || d::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_cambio_previo(%L, %L)', v1->>'venta_id',
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'reclamo_id', r->'reclamo_id',
      'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1))))),
    'GARANTIA_INVALIDA', 'reclamo de otra venta');
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, jsonb_build_object('resolucion', 'cambiado',
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
                                      'pagos', '[{"forma":"efectivo","monto_centavos":36000}]'::jsonb)), gen_random_uuid());
  PERFORM pruebas.afirmar((r->'devolucion'->>'total_centavos')::bigint = (pv->'devuelto'->>'total_centavos')::bigint, 'guardado = previo: ' || r::text);
  PERFORM public.configurar_empresa(e, '{"cambio_exacto": true}', 'Vuelve la regla');

  -- ===== 4) Crédito "de vuelta" sin aprobación y con el vencimiento original =====
  PERFORM public.configurar_empresa(e, '{"credito_politica": "siempre_aprobacion"}', 'Todo crédito con aprobación');
  -- El dueño (sin topes) vende 1 galón al crédito a CLI1 el 01/10/2026: 45,000, vence 31/10/2026 (plazo 30).
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1') || '{"fecha": "2026-10-01"}', gen_random_uuid());
  PERFORM pruebas.afirmar(v1->>'estado' = 'emitida' AND v1->>'vence_el' = '2026-10-31', 'venta al crédito: ' || v1::text);
  -- El admin (con esa regla, todo crédito suyo pide aprobación) cambia el galón por otro galón (exacto: 45,000). La
  -- devolución rebaja la deuda (45,000) y esa parte vuelve a deberse en la venta nueva, sin aprobación de crédito.
  PERFORM pruebas.como('admin_a');
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Otro color', 'destino', 'cambio',
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)))), gen_random_uuid());
  PERFORM pruebas.afirmar(d->>'estado' = 'aplicada' AND (d->>'cxc_centavos')::bigint = 45000 AND d->'venta_cambio'->>'estado' = 'emitida',
    'cambio sin pedir aprobación de crédito: ' || d::text);
  PERFORM pruebas.como('superusuario');
  SELECT * INTO vnue FROM public.venta WHERE id = (d->>'venta_cambio_id')::uuid;
  PERFORM pruebas.afirmar(vnue.credito_centavos = 45000 AND vnue.vence_el = '2026-10-31' AND vnue.requiere_aprobacion = '{}',
    'venta nueva: ' || to_jsonb(vnue)::text);
  -- Un crédito normal del admin sigue pidiendo aprobación.
  PERFORM pruebas.como('admin_a');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar(v2->>'estado' = 'pendiente_aprobacion', 'el crédito normal sigue con aprobación: ' || v2::text);
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"credito_politica": "segun_limite"}', 'Vuelve la regla de crédito');

  -- ===== 5) Línea de antes de 0.19.0 vendida con menos que "desde cantidad" = por cliente =====
  PERFORM public.editar_tercero(e, pruebas.id('CLI2'), '{"es_mayorista": true}', 'Mayorista un tiempo');
  v1 := public.registrar_venta(e, pruebas.venta('P1', 5, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.afirmar((v1->>'total_centavos')::bigint = 45000, 'mayorista por cliente: ' || v1::text);
  PERFORM public.editar_tercero(e, pruebas.id('CLI2'), '{"es_mayorista": false}', 'Ya no es mayorista');
  PERFORM pruebas.como('superusuario');
  ALTER TABLE public.venta_linea DISABLE TRIGGER proteger;
  UPDATE public.venta_linea SET mayorista_por = NULL, mayorista_desde = NULL WHERE venta_id = (v1->>'venta_id')::uuid;   -- como antes de 0.19.0
  ALTER TABLE public.venta_linea ENABLE TRIGGER proteger;
  PERFORM pruebas.como('dueno_a');
  pv := public.calcular_devolucion_previa((v1->>'venta_id')::uuid, '{"lineas":[{"linea":1,"cantidad":2}]}');
  PERFORM pruebas.afirmar((pv->>'total_centavos')::bigint = 18000 AND (pv->>'ajuste_mayorista_centavos')::bigint = 0, 'línea vieja: ' || pv::text);

  -- ===== Todo cuadra =====
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM public.asiento a
   WHERE a.empresa_id = e AND (SELECT sum(debe_centavos) - sum(haber_centavos) FROM public.asiento_linea l WHERE l.asiento_id = a.id) <> 0;
  PERFORM pruebas.afirmar(n = 0, 'todos los asientos cuadran');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora íntegra');
END $$;
