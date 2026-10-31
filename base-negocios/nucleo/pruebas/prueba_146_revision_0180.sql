-- PRUEBA: (0.18.0, revisión) cifras a mano: mayorista en apartado, en cotización convertida y en cambio de producto; cambio por garantía del mismo producto con "precio de garantía" (vale lo que pagó el cliente: precio que subió, que bajó y venta con promoción; sin tope ni descuento doble; el cliente no paga ni recibe diferencia; al crédito sigue debiendo lo mismo) y por otro producto pagando la diferencia; un reclamo cuya devolución o gasto de reparación pide aprobación NO se cierra (APROBACION_REQUERIDA); venta pagada con cheque sin confirmar no devuelve dinero ni saldo a favor (sí después de confirmar); el rebote no puede tener fecha anterior al depósito y lo registra quien tiene cobros.anular sin dinero.anular; v_cheque_recibido la ve quien tiene dinero.ver sin ventas.ver; Excel baja precio y mayorista en la misma fila (y avisa bajo costo); DESCUENTO_DOBLE en palabras; usuario limitado a su sucursal en cheques y garantías; asientos cuadran y bitácora íntegra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v    jsonb;
  va   jsonb;
  vb   jsonb;
  vc   jsonb;
  r    jsonb;
  a    jsonb;
  c    jsonb;
  x    jsonb;
  filas jsonb;
  catp uuid;
  pa   uuid;
  ch   uuid;
  dep  jsonb;
  s2   uuid;
  hoy  date;
  n    bigint;
  m    text;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  -- 0.19.0: esta prueba es del cambio con diferencia (0.16.0): se apaga la regla del dueño "cambio exacto".
  PERFORM public.configurar_empresa(e, '{"cambio_exacto": false}', 'Prueba del cambio con diferencia');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'apartados') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('dueno_a');
  hoy := public.hoy_local(e);
  -- Tornillo P1: L 15.00 con ISV 15 %. Mayorista L 12.00 desde 12; CLI1 es mayorista.
  PERFORM pruebas.como('admin_a');
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 1200, "cantidad_mayorista": 12, "dias_garantia": 30}', 'Precio de mayoreo');
  PERFORM public.editar_producto(e, pruebas.id('P3'), '{"dias_garantia": 90}');
  PERFORM public.editar_tercero(e, pruebas.id('CLI1'), '{"es_mayorista": true}', 'Compra para revender');

  -- ===== 1) Mayorista en apartado, cotización convertida y cambio de producto =====
  PERFORM pruebas.como('cajero_a');
  a := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
         'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((a->>'total_centavos')::bigint = 2400, 'apartado mayorista 2 x 12.00: ' || a::text);
  v := public.completar_apartado((a->>'apartado_id')::uuid, '{"pagos":[{"forma":"efectivo","monto_centavos":1400}]}', gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 2400 AND v->>'estado' = 'emitida', 'apartado completado: ' || v::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT precio_tipo FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid) = 'mayorista', 'la venta del apartado dice mayorista');
  PERFORM pruebas.como('cajero_a');
  c := public.crear_cotizacion(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 3))), gen_random_uuid());
  v := public.convertir_cotizacion_a_venta((c->>'cotizacion_id')::uuid, '{"pagos":[{"forma":"efectivo"}]}', gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 3600, 'cotización convertida 3 x 12.00: ' || v::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT precio_tipo FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid) = 'mayorista', 'la venta de la cotización dice mayorista');
  -- CLI1 compra un galón (45,000) y lo cambia por 30 tornillos al mayorista (36,000): 9,000 a su favor.
  PERFORM pruebas.como('dueno_a');
  v := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI1'), gen_random_uuid());
  r := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea": 1, "cantidad": 1}]'::jsonb,
         'motivo', 'Prefiere tornillos', 'destino', 'cambio',
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 30)),
                                      'diferencia', 'saldo_favor')), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT total_centavos = 36000 FROM public.venta WHERE id = (r->>'venta_cambio_id')::uuid)
    AND (SELECT precio_tipo FROM public.venta_linea WHERE venta_id = (r->>'venta_cambio_id')::uuid) = 'mayorista'
    AND (r->>'saldo_favor_centavos')::bigint = 9000, 'cambio de producto al mayorista: ' || r::text);

  -- ===== 2) Cambio por garantía con "precio de garantía" =====
  -- va: galón a 45,000; luego el precio SUBE a 50,000 y vb se vende a 50,000; luego BAJA a 40,000.
  PERFORM pruebas.como('dueno_a');
  va := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P3'), 50000, 'Subió el galón');
  vb := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  -- El precio subió: se entrega otro igual y la venta del cambio vale 45,000 (lo que pagó), sin cobrar nada.
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', va->'venta_id', 'linea', 1, 'motivo', 'Vino seca'), gen_random_uuid());
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, '{"resolucion": "cambiado"}', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT total_centavos = 45000 AND descuento_centavos = 0 FROM public.venta WHERE id = (r->'devolucion'->>'venta_cambio_id')::uuid)
    AND (SELECT precio_tipo = 'garantia' AND precio_normal_centavos = 50000 AND total_centavos = 45000
           FROM public.venta_linea WHERE venta_id = (r->'devolucion'->>'venta_cambio_id')::uuid)
    AND (SELECT dinero_centavos = 0 AND saldo_favor_centavos = 0 AND cambio_centavos = 45000 FROM public.devolucion WHERE id = (r->>'devolucion_id')::uuid),
    'precio subió: el cambio vale 45,000: ' || r::text);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta_pago WHERE venta_id = (r->'devolucion'->>'venta_cambio_id')::uuid AND forma <> 'saldo_favor') = 0,
    'el cliente no paga nada');
  PERFORM pruebas.afirmar((public.documento_venta((r->'devolucion'->>'venta_cambio_id')::uuid))->'lineas'->0->>'precio_texto' = 'Cambio por garantía',
    'el comprobante dice "Cambio por garantía"');
  -- El precio bajó: vb (pagó 50,000) se cambia y vale 50,000: no se le devuelve diferencia.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P3'), 40000, 'Bajó el galón');
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', vb->'venta_id', 'linea', 1, 'motivo', 'Vino seca'), gen_random_uuid());
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, '{"resolucion": "cambiado"}', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT total_centavos FROM public.venta WHERE id = (r->'devolucion'->>'venta_cambio_id')::uuid) = 50000
    AND (SELECT dinero_centavos = 0 AND saldo_favor_centavos = 0 FROM public.devolucion WHERE id = (r->>'devolucion_id')::uuid),
    'precio bajó: el cambio vale 50,000 y no devuelve nada: ' || r::text);
  -- Al crédito sin pagar (galón a 400.00 hoy): el cambio queda al crédito y el cliente sigue debiendo 40,000.
  PERFORM pruebas.como('dueno_a');
  v := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1'), gen_random_uuid());
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v->'venta_id', 'linea', 1, 'motivo', 'Vino seca'), gen_random_uuid());
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, '{"resolucion": "cambiado"}', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_documento_cxc((v->>'venta_id')::uuid) = 0
    AND interno.saldo_documento_cxc((r->'devolucion'->>'venta_cambio_id')::uuid) = 40000, 'al crédito: sigue debiendo 40,000: ' || r::text);
  -- Venta con promoción (10 % al tornillo): 2 x 15.00 - 10 % = 27.00; se reclama 1: vale 13.50. El admin (con tope de
  -- descuento) lo resuelve: no pide aprobación (no es descuento) ni choca con la promoción (no es descuento doble).
  PERFORM pruebas.como('dueno_a');
  catp := (public.crear_categoria(e, 'Ferretería')->>'categoria_id')::uuid;
  PERFORM public.editar_producto(e, pruebas.id('P1'), jsonb_build_object('categoria_id', catp));
  pa := (public.crear_promocion(e, jsonb_build_object('nombre', 'Diez por ciento', 'categoria_id', catp, 'tipo', 'porcentaje', 'porcentaje', 10,
         'fecha_inicio', to_char(hoy - 1, 'YYYY-MM-DD'), 'fecha_fin', to_char(hoy + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;
  vc := public.registrar_venta(e, pruebas.venta('P1', 2, 'efectivo', 'CLI2'), gen_random_uuid());
  PERFORM pruebas.afirmar((vc->>'total_centavos')::bigint = 2700, 'venta con promoción 27.00');
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', vc->'venta_id', 'linea', 1, 'motivo', 'Rosca mala'), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, '{"resolucion": "cambiado"}', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT total_centavos = 1350 AND estado = 'emitida' FROM public.venta WHERE id = (r->'devolucion'->>'venta_cambio_id')::uuid)
    AND (SELECT promocion_id IS NULL AND precio_tipo = 'garantia' FROM public.venta_linea WHERE venta_id = (r->'devolucion'->>'venta_cambio_id')::uuid),
    'con promoción: el cambio vale 13.50, sin promoción encima: ' || r::text);
  -- El otro tornillo se cambia por OTRO producto (arroz 22.00): el cliente paga la diferencia (22.00 - 13.50 = 8.50).
  PERFORM pruebas.como('vendedor_a');
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', vc->'venta_id', 'linea', 1, 'motivo', 'Rosca mala'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, jsonb_build_object('resolucion', 'cambiado',
         'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1)),
                                      'pagos', '[{"forma":"efectivo","monto_centavos":850}]'::jsonb)), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT total_centavos = 2200 FROM public.venta WHERE id = (r->'devolucion'->>'venta_cambio_id')::uuid)
    AND (SELECT precio_tipo = 'normal' FROM public.venta_linea WHERE venta_id = (r->'devolucion'->>'venta_cambio_id')::uuid)
    AND (SELECT sum(monto_centavos) FROM public.venta_pago WHERE venta_id = (r->'devolucion'->>'venta_cambio_id')::uuid AND forma = 'efectivo') = 850,
    'otro producto: paga 8.50 de diferencia: ' || r::text);

  -- ===== 3) Reclamo cuya devolución o gasto pide aprobación: no se cierra =====
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_tope_rol(e, 'admin', 'devolucion', 1000, 0, 'Devoluciones del admin con aprobación');
  PERFORM public.configurar_tope_rol(e, 'admin', 'gasto', 0, 0, 'Todo gasto del admin pide aprobación');
  v := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2'), gen_random_uuid());
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v->'venta_id', 'linea', 1, 'motivo', 'Color equivocado'), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_reclamo_garantia(%L, %L, gen_random_uuid())', r->>'reclamo_id',
    '{"resolucion": "devuelto", "destino": "saldo_favor"}'), 'APROBACION_REQUERIDA', 'devolución sobre el tope: no se cierra');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_reclamo_garantia(%L, %L, gen_random_uuid())', r->>'reclamo_id',
    jsonb_build_object('resolucion', 'reparado', 'costo_reparacion', jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'),
      'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 5000))), 'APROBACION_REQUERIDA', 'gasto de reparación sobre el tope: no se cierra');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado FROM public.garantia_reclamo WHERE id = (r->>'reclamo_id')::uuid) = 'recibido'
    AND NOT EXISTS (SELECT 1 FROM public.devolucion WHERE venta_id = (v->>'venta_id')::uuid)
    AND NOT EXISTS (SELECT 1 FROM public.gasto WHERE descripcion LIKE 'Reparación por garantía%'), 'el reclamo sigue abierto y no quedó nada');
  -- El dueño (quien aprueba) sí lo resuelve.
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, '{"resolucion": "devuelto", "destino": "saldo_favor"}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'resuelto' AND r->'devolucion'->>'estado' = 'aplicada', 'el dueño lo resuelve');

  -- ===== 4) Venta pagada con cheque sin confirmar: no devuelve dinero ni saldo a favor =====
  v := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI2'), gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
    'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v->'venta_id', 'monto_centavos', 40000)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'cheque', 'monto_centavos', 40000, 'numero_cheque', '5501',
      'banco_emisor', 'BAC', 'fecha_cheque', hoy))), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  ch := (SELECT id FROM public.cheque_recibido WHERE numero_cheque = '5501');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v->>'venta_id',
    jsonb_build_object('lineas', '[{"linea": 1, "cantidad": 1}]'::jsonb, 'motivo', 'No le gustó', 'destino', 'dinero',
                       'cuenta_dinero_id', pruebas.id('BANCO'))), 'CHEQUE_POR_CONFIRMAR', 'cheque por depositar: no devuelve dinero');
  dep := public.depositar_cheque(ch, pruebas.id('BANCO'), hoy, NULL, gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v->>'venta_id',
    jsonb_build_object('lineas', '[{"linea": 1, "cantidad": 1}]'::jsonb, 'motivo', 'No le gustó', 'destino', 'saldo_favor')),
    'CHEQUE_POR_CONFIRMAR', 'depositado en tránsito: no deja saldo a favor');
  PERFORM public.confirmar_deposito((dep->>'operacion_deposito_id')::uuid, gen_random_uuid(), hoy);
  r := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea": 1, "cantidad": 1}]'::jsonb,
         'motivo', 'No le gustó', 'destino', 'saldo_favor'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicada' AND (r->>'saldo_favor_centavos')::bigint = 40000, 'confirmado: sí deja saldo a favor: ' || r::text);

  -- ===== 5) Rebote: fecha y permiso =====
  v := public.registrar_venta(e, pruebas.venta('P1', 10, 'credito', 'CLI2'), gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
    'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v->'venta_id', 'monto_centavos', (v->>'total_centavos')::bigint)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'cheque', 'monto_centavos', (v->>'total_centavos')::bigint, 'numero_cheque', '5502',
      'banco_emisor', 'BAC', 'fecha_cheque', hoy))), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  ch := (SELECT id FROM public.cheque_recibido WHERE numero_cheque = '5502');
  PERFORM pruebas.como('dueno_a');
  dep := public.depositar_cheque(ch, pruebas.id('BANCO'), hoy, NULL, gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cheque_rechazado(%L, %L, gen_random_uuid())', ch,
    jsonb_build_object('motivo', 'Fondos insuficientes', 'fecha', hoy - 1)), 'FECHA_INVALIDA', 'rebote antes del depósito');
  -- El cajero con cobros.anular (sin dinero.anular) registra el rebote con el depósito en tránsito.
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'cobros.anular', true, 'El cajero registra cheques rebotados');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('dinero.anular', e), 'el cajero no tiene dinero.anular');
  r := public.registrar_cheque_rechazado(ch, '{"motivo": "Fondos insuficientes"}', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(r->>'estado' = 'rechazado' AND (SELECT anulada_en IS NOT NULL FROM public.operacion_dinero WHERE id = (dep->>'operacion_deposito_id')::uuid)
    AND interno.saldo_documento_cxc((v->>'venta_id')::uuid) = (v->>'total_centavos')::bigint, 'rebote por el cajero: deuda de vuelta');

  -- ===== 6) v_cheque_recibido con dinero.ver y sin ventas.ver =====
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'dinero.ver', true, 'El cajero ve el dinero');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.ver', false, 'Sin ver ventas');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cheque_recibido WHERE empresa_id = e) = 2, 'el cajero ve los 2 cheques');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.ver', true, 'Vuelve a ver ventas');

  -- ===== 7) Excel: bajar el precio y el mayorista en la misma fila =====
  x := public.exportar_plantilla(e, 'productos');
  filas := (SELECT jsonb_agg(CASE f->>'codigo' WHEN 'TOR-001' THEN f || '{"precio_venta": 11.00, "precio_mayorista": 9.00}' ELSE f END)
              FROM jsonb_array_elements(x->'filas') f);
  r := public.importar_aplicar(e, 'productos', filas, gen_random_uuid(), 'Bajan los tornillos');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean, 'Excel aplicado: ' || (r - 'filas')::text);
  PERFORM pruebas.afirmar((SELECT precio_venta_centavos = 1100 AND precio_mayorista_centavos = 900 FROM public.producto WHERE id = pruebas.id('P1')),
    'bajaron los dos');
  -- Costo del tornillo 10.00: el mayorista sin ISV (9.00 / 1.15 = 7.83) queda bajo el costo: aviso en la fila.
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'filas') f, jsonb_array_elements(f->'avisos') w
                                   WHERE w->>'tipo' = 'mayorista_bajo_costo'), 'aviso del mayorista bajo el costo: ' || (r->'filas')::text);
  filas := (SELECT jsonb_agg(CASE f->>'codigo' WHEN 'TOR-001' THEN f || '{"precio_venta": 8.00}' ELSE f END)
              FROM jsonb_array_elements(x->'filas') f);
  r := public.importar_vista_previa(e, 'productos', filas);
  PERFORM pruebas.afirmar((r->'resumen'->>'error')::int = 1, 'Excel: precio bajo el mayorista (sin bajarlo) = error: ' || (r->'resumen')::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_precio_producto(%L, %L, 800, %L)', e, pruebas.id('P1'), 'Más barato'),
    'PRECIO_MAYORISTA_INVALIDO', 'bajar el precio normal por debajo del mayorista');

  -- ===== 8) DESCUENTO_DOBLE en palabras =====
  BEGIN
    PERFORM public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo"}]'::jsonb,
      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_porcentaje', 5))), gen_random_uuid());
    m := 'pasó';
  EXCEPTION WHEN OTHERS THEN m := SQLERRM;
  END;
  PERFORM pruebas.afirmar(m LIKE 'DESCUENTO_DOBLE:%Para dar un descuento, toque "Usar precio normal" en la línea.', 'mensaje: ' || m);

  -- ===== 9) Usuario limitado a su sucursal: cheques y garantías =====
  v := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI2'), gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
    'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v->'venta_id', 'monto_centavos', 40000)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'cheque', 'monto_centavos', 40000, 'numero_cheque', '5503',
      'banco_emisor', 'BAC', 'fecha_cheque', hoy))), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  ch := (SELECT id FROM public.cheque_recibido WHERE numero_cheque = '5503');
  PERFORM pruebas.como('dueno_a');
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  PERFORM public.crear_caja(e, s2, 'Caja Norte', '001');
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('cajero_a'), ARRAY[s2], 'Cajero de la Norte');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cheque_recibido WHERE empresa_id = e) = 0, 'no ve cheques de la principal');
  PERFORM pruebas.afirmar(NOT (public.donde_esta_mi_dinero(e)->'cheques_por_depositar'->'cheques') @> jsonb_build_array(jsonb_build_object('cheque_id', ch)),
    'ni en dónde está mi dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cheque_rechazado(%L, %L, gen_random_uuid())', ch, '{"motivo": "Fondos insuficientes"}'),
    'SUCURSAL_NO_PERMITIDA', 'no rebota un cheque de otra sucursal');
  PERFORM pruebas.afirmar(jsonb_array_length(public.buscar_garantia(e, 'pintura')->'lineas') = 0, 'no encuentra garantías de la principal');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_garantia_reclamo WHERE empresa_id = e) = 0, 'no ve reclamos de la principal');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v->'venta_id', 'linea', 1, 'motivo', 'No cubre')), 'SUCURSAL_NO_PERMITIDA', 'no reclama una venta de otra sucursal');

  -- ===== 10) Todo cuadra =====
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM (SELECT l.asiento_id FROM public.asiento_linea l WHERE l.empresa_id = e
                                GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)) x;
  PERFORM pruebas.afirmar(n = 0, 'asientos que no cuadran: ' || n);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
