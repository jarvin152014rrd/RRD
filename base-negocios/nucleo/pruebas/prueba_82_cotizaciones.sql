-- PRUEBA: cotizaciones (cifras a mano): no mueven inventario, dinero ni número CAI; vigencia; el vendedor cotiza y el cajero la cobra (la venta queda a nombre del vendedor); vigente con "respetar" = precios cotizados aunque el precio cambie; vencida o con "recalcular" = precios del día; no se convierte dos veces ni anulada; si su venta se rechaza se puede volver a convertir
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  c1   jsonb;
  c2   jsonb;
  c3   jsonb;
  c4   jsonb;
  v    jsonb;
  r    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas();
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');

  -- 1) El vendedor cotiza: 10 tornillos (L 15.00) + 1 galón (L 450.00) con 5 % en el galón.
  PERFORM pruebas.como('vendedor_a');
  c1 := public.crear_cotizacion(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10),
          jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 5))), gen_random_uuid());
  -- A mano: 15,000 + (45,000 - 2,250) = 57,750; vigente 15 días.
  PERFORM pruebas.afirmar((c1->>'total_centavos')::bigint = 57750 AND c1->>'vigente_hasta' = to_char(public.hoy_local(e) + 15, 'YYYY-MM-DD'),
    'cotización: ' || c1::text);
  c2 := public.crear_cotizacion(e, jsonb_build_object('fecha', '2026-01-10', 'vigente_hasta', '2026-01-20',
          'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10))), gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT estado FROM public.v_cotizacion WHERE cotizacion_id = (c2->>'cotizacion_id')::uuid) = 'vencida', 'vencida');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 100 AND (SELECT ultimo_numero FROM public.cai_rango WHERE id = pruebas.id('CAI1')) = 0
    AND NOT EXISTS (SELECT 1 FROM public.venta), 'no mueve inventario, dinero ni CAI');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.convertir_cotizacion_a_venta(%L, %L, gen_random_uuid())', c1->>'cotizacion_id',
    '{"pagos":[{"forma":"efectivo"}]}'), 'SIN_PERMISO', 'el vendedor no cobra');

  -- 2) Sube el precio del tornillo a L 20.00.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 2000, 'Subió el proveedor');

  -- 3) El cajero convierte la vigente: precios COTIZADOS.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.convertir_cotizacion_a_venta(%L, %L, gen_random_uuid())', c1->>'cotizacion_id',
    '{"pagos":[{"forma":"efectivo"}],"lineas":[]}'), 'DATO_INVALIDO', 'las líneas salen de la cotización');
  v := public.convertir_cotizacion_a_venta((c1->>'cotizacion_id')::uuid, '{"pagos":[{"forma":"efectivo"}]}', gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND (v->>'total_centavos')::bigint = 57750 AND v->>'precios' = 'cotizados'
    AND v->>'numero_documento' = '001-001-01-00000001', 'convertida con precios cotizados: ' || v::text);
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT vendedor_id = pruebas.usuario('vendedor_a') AND creado_por = pruebas.usuario('cajero_a')
                                  AND cotizacion_id = (c1->>'cotizacion_id')::uuid FROM public.venta WHERE id = (v->>'venta_id')::uuid),
    'la venta queda a nombre del vendedor; la cobró el cajero');
  PERFORM pruebas.afirmar((SELECT estado || '/' || (venta_id = (v->>'venta_id')::uuid) FROM public.cotizacion WHERE id = (c1->>'cotizacion_id')::uuid)
    = 'convertida/true', 'cotización convertida');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.convertir_cotizacion_a_venta(%L, %L, gen_random_uuid())', c1->>'cotizacion_id',
    '{"pagos":[{"forma":"efectivo"}]}'), 'NO_PERMITIDO', 'no se convierte dos veces');

  -- 4) La vencida se cobra a precio del día: 10 x 2,000 = 20,000.
  v := public.convertir_cotizacion_a_venta((c2->>'cotizacion_id')::uuid, '{"pagos":[{"forma":"efectivo"}]}', gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 20000 AND v->>'precios' = 'del_dia', 'vencida: precio del día: ' || v::text);

  -- 5) "recalcular": aun vigente, precio del día.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"cotizacion_precios": "recalcular"}', 'Siempre precio del día');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 1500, 'Vuelve el precio');
  PERFORM pruebas.como('vendedor_a');
  c3 := public.crear_cotizacion(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
          'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2))), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 1800, 'Otro aumento');
  -- El vendedor sí convierte una de crédito (no cobra dinero): 2 x 1,800 = 3,600.
  PERFORM pruebas.como('vendedor_a');
  v := public.convertir_cotizacion_a_venta((c3->>'cotizacion_id')::uuid, '{"pagos":[{"forma":"credito"}]}', gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 3600 AND v->>'precios' = 'del_dia' AND v->>'cliente' = 'Constructora Ríos',
    'recalcular: ' || v::text);

  -- 6) Anulada no se convierte; la que tuvo su venta rechazada sí, otra vez.
  c4 := public.crear_cotizacion(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 20))), gen_random_uuid());
  r := public.crear_cotizacion(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))),
       gen_random_uuid());
  PERFORM public.anular_cotizacion((r->>'cotizacion_id')::uuid, 'El cliente no la quiso', gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.convertir_cotizacion_a_venta(%L, %L, gen_random_uuid())', r->>'cotizacion_id',
    '{"pagos":[{"forma":"efectivo"}]}'), 'NO_PERMITIDO', 'anulada');
  v := public.convertir_cotizacion_a_venta((c4->>'cotizacion_id')::uuid, '{"pagos":[{"forma":"efectivo"}]}', gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'pendiente_aprobacion', '20 % pasa el tope del cajero (5 %)');
  PERFORM pruebas.como('admin_a');
  PERFORM public.resolver_aprobacion((v->>'aprobacion_id')::uuid, false, 'Descuento no autorizado', gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  v := public.convertir_cotizacion_a_venta((c4->>'cotizacion_id')::uuid, '{"pagos":[{"forma":"efectivo"}]}', gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'pendiente_aprobacion', 'su venta fue rechazada: se convierte otra vez');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cotizacion SET total_centavos = 1 WHERE id = %L', c4->>'cotizacion_id'), 'PROHIBIDO', 'inmutable');
END $$;
