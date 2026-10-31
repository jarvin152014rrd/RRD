-- PRUEBA: (0.9.1, importante 4) el tope de descuento también vale por línea: 100 % en una línea de L 500 dentro de una factura de L 20,000 (2.5 % del total) pide aprobación al cajero (tope 5 %), el admin (aprueba hasta 20 %) no la aprueba y el dueño sí; un 5 % de factura parejo no pide nada; en apartados igual
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  v  jsonb;
  r  jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de tope por línea');
  -- Dos servicios con ISV incluido: instalación L 19,500 y flete L 500.
  PERFORM pruebas.guardar('INST', (public.crear_producto(e, jsonb_build_object('codigo', 'INST', 'nombre', 'Instalación', 'tipo', 'servicio',
    'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'SERV'), 'precio_venta_centavos', 1950000), gen_random_uuid())->>'producto_id')::uuid);
  PERFORM pruebas.guardar('FLETE', (public.crear_producto(e, jsonb_build_object('codigo', 'FLETE', 'nombre', 'Flete', 'tipo', 'servicio',
    'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'SERV'), 'precio_venta_centavos', 50000), gen_random_uuid())->>'producto_id')::uuid);

  -- 1) Cajero: flete al 100 %. Sin ISV: instalación round(1,950,000 / 1.15) = 1,695,652; flete round(50,000 / 1.15) = 43,478.
  --    Descuento de toda la factura = 43,478 / 1,739,130 = 2.50 % (bajo su tope de 5 %), pero en la línea es 100 %.
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('INST'), 'cantidad', 1),
         jsonb_build_object('producto_id', pruebas.id('FLETE'), 'cantidad', 1, 'descuento_porcentaje', 100)),
         'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 1950000 AND (v->>'descuento_manual_porcentaje')::numeric = 2.50,
    'total 19,500 con 2.50 % de descuento total: ' || v::text);
  PERFORM pruebas.afirmar(v->>'estado' = 'pendiente_aprobacion' AND v->'requiere_aprobacion' = '["descuento"]'::jsonb,
    '100 % en una línea pide aprobación: ' || v::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT descripcion FROM public.aprobacion WHERE id = (v->>'aprobacion_id')::uuid) LIKE '%100.00 % en una línea%',
    'la solicitud dice por qué');

  -- 2) El admin aprueba descuentos hasta 20 %: esta línea (100 %) no; el dueño sí.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', v->>'aprobacion_id', 'Cliente frecuente'),
    'TOPE_APROBACION', 'el admin no pasa su tope en una línea');
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((v->>'aprobacion_id')::uuid, true, 'Flete de cortesía', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida', 'el dueño la aprueba');

  -- 3) Un 5 % de factura parejo (tope exacto del cajero) no pide aprobación: 1,852,500 + 47,500 = 1,900,000.
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('INST'), 'cantidad', 1), jsonb_build_object('producto_id', pruebas.id('FLETE'), 'cantidad', 1)),
         'descuento_factura', '{"porcentaje": 5}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND (v->>'total_centavos')::bigint = 1900000, '5 % parejo sin aprobación: ' || v::text);

  -- 4) Apartado: 1 tornillo al 100 % + 2 galones (90,000). Total: 1,304 / (1,304 + 76,271) = 1.68 %; en la línea, 100 %.
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'apartados') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_apartado(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_porcentaje', 100),
                                jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 2)),
    'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb)), 'APROBACION_REQUERIDA', 'apartado: tope por línea');
END $$;
