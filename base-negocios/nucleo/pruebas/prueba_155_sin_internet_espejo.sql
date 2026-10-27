-- PRUEBA: (0.20.0) G5 y pruebas espejo: con la foto del catálogo de hoy, interno.calcular_venta da EXACTAMENTE lo mismo (o el mismo error) que con los datos de hoy en 200 carritos al azar (promociones de porcentaje y de monto, varias que aplican, mayorista por cantidad y por cliente, precio sin ISV, exento con decimales, servicio); con una foto vieja calcula con los precios de la foto (promoción que ya terminó, precio que subió, impuesto que cambió: M6); y una tanda de 20 ventas sube en menos de 8 segundos
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  catp   uuid;
  cath   uuid;
  p4     uuid;
  foto   jsonb;
  lin    jsonb;
  a      jsonb;
  b      jsonb;
  ea     text;
  eb     text;
  i      integer;
  k      integer;
  n      integer;
  prods  uuid[];
  pid    uuid;
  cli    text;
  promos jsonb;
  iguales integer := 0;
  errores integer := 0;
  hoy    date := public.hoy_local(pruebas.empresa('A'));
BEGIN
  PERFORM setseed(0.42);
  PERFORM pruebas.preparar_ventas(false);
  catp := (public.crear_categoria(e, 'Ferretería')->>'categoria_id')::uuid;
  cath := (public.crear_categoria(e, 'Tornillería', catp)->>'categoria_id')::uuid;
  PERFORM public.editar_producto(e, pruebas.id('P1'), jsonb_build_object('categoria_id', cath));
  PERFORM public.editar_producto(e, pruebas.id('P3'), jsonb_build_object('categoria_id', catp));
  PERFORM public.crear_promocion(e, jsonb_build_object('nombre', 'Diez por ciento', 'categoria_id', catp, 'tipo', 'porcentaje', 'porcentaje', 10,
    'fecha_inicio', to_char(hoy - 1, 'YYYY-MM-DD'), 'fecha_fin', to_char(hoy + 1, 'YYYY-MM-DD')));
  PERFORM public.crear_promocion(e, jsonb_build_object('nombre', 'Dos lempiras menos', 'categoria_id', cath, 'tipo', 'monto', 'monto_centavos', 200,
    'fecha_inicio', to_char(hoy - 1, 'YYYY-MM-DD'), 'fecha_fin', to_char(hoy + 1, 'YYYY-MM-DD')));
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 1200, "cantidad_mayorista": 12}', 'Mayoreo');
  p4 := (public.crear_producto(e, jsonb_build_object('codigo', 'CLA-001', 'nombre', 'Clavo sin ISV incluido', 'precio_venta_centavos', 333,
          'precio_incluye_isv', false), gen_random_uuid())->>'producto_id')::uuid;
  PERFORM public.editar_producto(e, p4, '{"precio_mayorista_centavos": 290, "cantidad_mayorista": 7}', 'Mayoreo');
  PERFORM pruebas.guardar('P4', p4);
  PERFORM public.editar_tercero(e, pruebas.id('CLI1'), '{"es_mayorista": true}', 'Compra para revender');
  prods := ARRAY[pruebas.id('P1'), pruebas.id('P2'), pruebas.id('P3'), pruebas.id('S1'), p4];

  PERFORM pruebas.como('superusuario');
  foto := interno.armar_catalogo(e, (SELECT sucursal_id FROM public.caja WHERE id = pruebas.id('CAJA001')));
  PERFORM set_config('app.sucursal_venta', (SELECT sucursal_id FROM public.caja WHERE id = pruebas.id('CAJA001'))::text, true);
  FOR i IN 1 .. 200 LOOP
    lin := '[]';
    n := 1 + floor(random() * 4)::int;
    FOR k IN 1 .. n LOOP
      pid := prods[1 + floor(random() * 5)::int];
      lin := lin || jsonb_strip_nulls(jsonb_build_object('producto_id', pid,
        'cantidad', CASE WHEN pid IN (pruebas.id('P2'), pruebas.id('S1')) THEN round((0.25 + random() * 10)::numeric, 2)
                         ELSE 1 + floor(random() * 20)::int END,
        'precio_tipo', (ARRAY['normal', 'mayorista', NULL, NULL])[1 + floor(random() * 4)::int]));
    END LOOP;
    -- Si aplican varias promociones, quien vende elige una (como en la app): la primera de la lista de hoy, a veces.
    lin := (SELECT jsonb_agg(CASE WHEN random() < 0.5 AND jsonb_array_length(interno.promociones_de(e, p, hoy, (l->>'cantidad')::numeric)) > 1
                                   AND coalesce(l->>'precio_tipo', '') <> 'mayorista'
                                  THEN l || jsonb_build_object('promocion_id', interno.promociones_de(e, p, hoy, (l->>'cantidad')::numeric)->0->'promocion_id')
                                  ELSE l END ORDER BY y.orden)
              FROM jsonb_array_elements(lin) WITH ORDINALITY y(l, orden) JOIN public.producto p ON p.id = (l->>'producto_id')::uuid);
    cli := CASE WHEN random() < 0.3 THEN pruebas.id('CLI1')::text ELSE '' END;
    PERFORM set_config('app.cliente_venta', cli, true);
    a := NULL; b := NULL; ea := NULL; eb := NULL;
    PERFORM set_config('app.foto_venta', '', true);
    BEGIN a := interno.calcular_venta(e, hoy, lin, NULL); EXCEPTION WHEN OTHERS THEN ea := SQLERRM; END;
    PERFORM set_config('app.foto_venta', interno.foto_de_venta(foto, lin)::text, true);
    BEGIN b := interno.calcular_venta(e, hoy, lin, NULL); EXCEPTION WHEN OTHERS THEN eb := SQLERRM; END;
    PERFORM set_config('app.foto_venta', '', true);
    IF a IS DISTINCT FROM b OR ea IS DISTINCT FROM eb THEN
      RAISE EXCEPTION 'FALLA: espejo %: hoy=% / % ; foto=% / % ; lineas=%', i, a, ea, b, eb, lin;
    END IF;
    IF ea IS NULL THEN iguales := iguales + 1; ELSE errores := errores + 1; END IF;
  END LOOP;
  PERFORM pruebas.afirmar(iguales >= 100 AND errores >= 5, format('200 casos: %s calculados iguales, %s errores iguales', iguales, errores));

  -- Foto vieja (M6): después de bajarla, el tornillo sube a 20.00, el 10 % termina y el ISV de la pintura pasa a 15.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 2000, 'Subió');
  PERFORM pruebas.como('superusuario');
  UPDATE public.promocion SET fecha_fin = hoy - 1, fecha_inicio = hoy - 2 WHERE empresa_id = e AND nombre = 'Diez por ciento';
  UPDATE public.producto SET tipo_impuesto = 'ISV15' WHERE id = pruebas.id('P3');
  lin := jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'precio_tipo', 'normal',
                                              'promocion_id', (SELECT id FROM public.promocion WHERE empresa_id = e AND nombre = 'Diez por ciento')),
                           jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1));
  PERFORM set_config('app.cliente_venta', '', true);
  PERFORM set_config('app.foto_venta', interno.foto_de_venta(foto, lin)::text, true);
  b := interno.calcular_venta(e, hoy, lin, NULL);
  PERFORM set_config('app.foto_venta', '', true);
  -- Con la foto: tornillo 15.00 - 10 % = 13.50; pintura 450.00 - 10 % = 405.00 con ISV 18 % (61.78): total 418.50.
  PERFORM pruebas.afirmar((b->>'total_centavos')::bigint = 41850 AND (b->'lineas'->1->>'impuesto_porcentaje')::numeric = 18,
    'con la foto vieja: ' || b::text);
END $$;

-- Tanda de 20 ventas en una llamada: menos de 8 segundos (Supabase corta a unos 8 s).
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  eq   uuid;
  bf   jsonb;
  v1   integer;
  x    jsonb := '[]';
  r    jsonb;
  i    integer;
  t0   timestamptz;
  seg  numeric;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Sin turnos para la tanda');
  eq := (public.registrar_equipo(e, '{"nombre": "Caja rápida"}', gen_random_uuid())->>'equipo_id')::uuid;
  bf := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'tamano', 30))->'bloques'->0;
  v1 := (public.preparar_sin_internet(e, eq, jsonb_build_object('caja_id', pruebas.id('CAJA001')))->>'version')::int;
  FOR i IN 1 .. 20 LOOP
    x := x || jsonb_build_object('id_operacion', gen_random_uuid(), 'usuario_id', pruebas.usuario('dueno_a'), 'caja_id', bf->'caja_id',
      'bloque_id', bf->'bloque_id', 'numero', (bf->>'desde')::int + i - 1,
      'numero_documento', (bf->>'prefijo') || '-' || lpad(((bf->>'desde')::int + i - 1)::text, 8, '0'), 'tipo_documento', bf->'tipo',
      'foto_version', v1, 'hora_equipo', public.iso(now()),
      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1.5, 'precio_tipo', 'normal', 'total_centavos', 3300),
                                  jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 1, 'precio_tipo', 'normal', 'total_centavos', 23000)),
      'pagos', '[{"forma":"efectivo","monto_centavos":26300}]'::jsonb, 'total_centavos', 26300);
  END LOOP;
  t0 := clock_timestamp();
  r := public.subir_ventas_sin_internet(e, eq, x);
  seg := extract(epoch FROM clock_timestamp() - t0);
  PERFORM pruebas.afirmar((r->>'registradas')::int = 20, 'tanda de 20: ' || r::text);
  PERFORM pruebas.afirmar(seg < 8, 'tanda de 20 en ' || seg || ' s');
  RAISE NOTICE 'tanda de 20 ventas en % s', round(seg, 2);
  PERFORM pruebas.debe_fallar(format('SELECT public.subir_ventas_sin_internet(%L, %L, %L)', e, eq, x || x->0), 'de 1 a 20', 'más de 20');
END $$;
