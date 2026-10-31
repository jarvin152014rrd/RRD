-- PRUEBA: (0.9.2, menor) el ajuste del último centavo del descuento de factura en monto ya no pide aprobación en una línea chica (2 centavos de tolerancia por redondeo en el tope por línea); un descuento de línea que de verdad pasa el tope (3 centavos o más) la sigue pidiendo
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  v  jsonb;
  i  integer;
  p  integer[] := ARRAY[1000, 1234, 18];
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de tolerancia del tope por línea');
  -- Tres servicios con precio SIN ISV (15 %): 10.00, 12.34 y 0.18.
  FOR i IN 1..3 LOOP
    PERFORM pruebas.guardar('Y' || i, (public.crear_producto(e, jsonb_build_object('codigo', 'Y' || i, 'nombre', 'Servicio ' || i, 'tipo', 'servicio',
      'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'SERV'), 'precio_venta_centavos', p[i],
      'precio_incluye_isv', false), gen_random_uuid())->>'producto_id')::uuid);
  END LOOP;

  -- 1) El cajero (tope 5 %) da 0.79 de descuento de factura. Con ISV: 1,150 + 1,419 (1,234 + round(185.1)) + 21 (18 + round(2.7)) = 2,590;
  --    0.79 es 3.06 % del total. Reparto por el total con ISV: 35.08 / 43.28 / 0.64 -> 35, 43, 1 (sin ISV: 30, 37, 1); con el ISV
  --    recalculado: 1,150 - 1,116 = 34; 1,419 - 1,377 = 42; 21 - 20 = 1 -> 77, faltan 2 y el ajuste los pone en la línea de 0.18:
  --    2 centavos sin ISV (16 + round(2.4) = 18, descuento 3). 2 / 18 = 11.11 % de la línea, pero es redondeo: antes pedía
  --    aprobación; ahora no. Total 2,590 - 79 = 2,511.
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('Y1'), 'cantidad', 1), jsonb_build_object('producto_id', pruebas.id('Y2'), 'cantidad', 1),
         jsonb_build_object('producto_id', pruebas.id('Y3'), 'cantidad', 1)),
         'descuento_factura', '{"monto_centavos": 79}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND (v->>'total_centavos')::bigint = 2511, 'sin aprobación por 1 o 2 centavos: ' || v::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT descuento_factura_centavos FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid AND linea = 3) = 2,
    'la línea de 0.18 lleva 2 centavos');

  -- 2) Descuento real sobre el tope en una línea: 10 tornillos (15,000) y 1 tornillo (1,500) con 0.78 de descuento (5.2 %):
  --    pasa el 5 % por 3 centavos -> pide aprobación (el total es 0.47 %); con 0.77 queda dentro de la tolerancia.
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10),
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_centavos', 78)),
         'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'pendiente_aprobacion', '3 centavos sobre el tope pide aprobación: ' || v::text);
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10),
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_centavos', 77)),
         'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida', '2 centavos sobre el tope: tolerancia');
END $$;
