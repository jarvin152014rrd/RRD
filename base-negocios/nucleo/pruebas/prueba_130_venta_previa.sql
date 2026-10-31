-- PRUEBA: (0.13.2) calcular_venta_previa: mismo total que la venta, sugiere la promoción que más descuenta sin sumarlas (la venta sigue pidiendo elegir), avisa el tope de descuento del puesto, no muestra costos al cajero, no guarda nada y otra empresa no la usa
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  catp  uuid;
  cath  uuid;
  pr10  uuid;
  pr2   uuid;
  r     jsonb;
  v     jsonb;
  n0    bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de venta previa');
  catp := (public.crear_categoria(e, 'Ferretería')->>'categoria_id')::uuid;
  cath := (public.crear_categoria(e, 'Tornillería', catp)->>'categoria_id')::uuid;
  PERFORM public.editar_producto(e, pruebas.id('P1'), jsonb_build_object('categoria_id', cath));
  PERFORM pruebas.como('admin_a');
  pr10 := (public.crear_promocion(e, jsonb_build_object('nombre', 'Diez por ciento', 'categoria_id', catp, 'tipo', 'porcentaje',
           'porcentaje', 10, 'fecha_inicio', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'),
           'fecha_fin', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;
  pr2 := (public.crear_promocion(e, jsonb_build_object('nombre', 'Dos lempiras menos', 'categoria_id', cath, 'tipo', 'monto',
          'monto_centavos', 200, 'fecha_inicio', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'),
          'fecha_fin', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;

  -- 1) Cajero, 10 tornillos (L 15.00 con ISV): 10 % = 1,500; L 2.00 x 10 = 2,000. Sugiere la de 2,000.
  --    A mano: 15,000 - 2,000 = 13,000 con ISV -> sin ISV round(13,000 / 1.15) = 11,304; ISV 1,696.
  PERFORM pruebas.como('cajero_a');
  SELECT count(*) INTO n0 FROM public.v_venta;
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10))));
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 13000 AND (r->>'impuesto_centavos')::bigint = 1696,
    'previa con la promoción sugerida: ' || r::text);
  PERFORM pruebas.afirmar((r->'lineas'->0->>'promocion_sugerida_id')::uuid = pr2 AND (r->'lineas'->0->>'promocion_id')::uuid = pr2
    AND jsonb_array_length(r->'lineas'->0->'promociones') = 2
    AND (r->'lineas'->0->'promociones'->0->>'descuento_centavos')::bigint = 2000, 'sugiere la que más descuenta: ' || r::text);
  -- La venta de verdad sigue exigiendo que se elija (nunca se suman ni elige sola).
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('lineas',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10)), 'pagos', '[{"forma":"efectivo"}]'::jsonb)),
    'PROMOCION_A_ELEGIR', 'la venta sin elegir promoción');
  -- Cambiada a la de 10 %: 13,500 (sin sugerida).
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'promocion_id', pr10))));
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 13500 AND r->'lineas'->0->'promocion_sugerida_id' = 'null'::jsonb,
    'previa con la promoción cambiada: ' || r::text);
  -- No guardó nada.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = n0, 'la previa no crea ventas');
  -- La venta con la misma promoción da el mismo total que la previa.
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'promocion_id', pr10)),
         'pagos', '[{"forma":"efectivo","recibido_centavos":20000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 13500 AND (v->>'impuesto_centavos')::bigint = (r->>'impuesto_centavos')::bigint,
    'venta = previa: ' || v::text);

  -- 2) Tope del cajero (5 %): galón L 450.00 con 10 % pide aprobación; con 5 % no. Costos ocultos al cajero.
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 10),
         jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 2))));
  -- A mano: 45,000 - 4,500 = 40,500; mano de obra 2 x 23,000 = 46,000; total 86,500.
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 86500 AND (r->>'descuento_pide_aprobacion')::boolean
    AND (r->>'tope_descuento_porcentaje')::numeric = 5, 'cajero 10 % sobre tope: ' || r::text);
  PERFORM pruebas.afirmar(NOT (r->'lineas'->1 ? 'costo_estimado_centavos'), 'el cajero no ve el costo estimado');
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 5))));
  PERFORM pruebas.afirmar(NOT (r->>'descuento_pide_aprobacion')::boolean AND (r->>'total_centavos')::bigint = 42750,
    'cajero 5 % dentro del tope (45,000 - 2,250 = 42,750): ' || r::text);
  -- Descuento de factura del 10 % también se revisa contra el tope.
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)), 'descuento_factura', '{"porcentaje": 10}'::jsonb));
  PERFORM pruebas.afirmar((r->>'descuento_pide_aprobacion')::boolean AND (r->>'total_centavos')::bigint = 40500, 'factura 10 %: ' || r::text);

  -- 3) El dueño no tiene tope y sí ve el costo estimado (2 x 8,000 = 16,000).
  PERFORM pruebas.como('dueno_a');
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 50),
         jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 2))));
  PERFORM pruebas.afirmar(NOT (r->>'descuento_pide_aprobacion')::boolean AND r->'tope_descuento_porcentaje' = 'null'::jsonb
    AND (r->'lineas'->1->>'costo_estimado_centavos')::bigint = 16000, 'dueño sin tope y con costo: ' || r::text);

  -- 4) Datos malos y otra empresa.
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_venta_previa(%L, %L)', e, '{"lineas": []}'), 'DATO_INVALIDO', 'sin líneas');
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_venta_previa(%L, %L)', e, jsonb_build_object('lineas',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1.5)))), 'CANTIDAD_INVALIDA', 'tornillo con decimales');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.calcular_venta_previa(%L, %L)', e, jsonb_build_object('lineas',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))), 'NO_PERTENECE', 'otra empresa');
END $$;
