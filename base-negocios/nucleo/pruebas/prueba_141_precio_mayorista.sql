-- PRUEBA: (0.18.0) precio mayorista (cifras a mano): por cantidad (desde 12) y por cliente mayorista; la línea guarda qué precio usó y el precio normal; nunca descuento sobre descuento (con una promoción gana lo mejor para el cliente, con varias el mayorista gana solo si es mejor que todas, si no se elige; mayorista + promoción o + descuento manual se rechaza; con "precio_tipo": "normal" sí lleva descuento manual; el descuento de factura no va a líneas mayoristas); precio_tipo mayorista donde no aplica se rechaza; venta previa, cotización y comprobante lo dicen; el mayorista no pasa el precio normal (tampoco al bajar el precio normal) y "desde cantidad" necesita precio; permisos (productos.precios y motivo para cambiarlo; marcar mayorista); aviso de precio por debajo del costo; Excel de productos y clientes ida y vuelta; doble envío; asientos cuadran y bitácora íntegra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v    jsonb;
  v2   jsonb;
  r    jsonb;
  op   uuid := gen_random_uuid();
  catp uuid;
  pa   uuid;
  pb   uuid;
  x    jsonb;
  filas jsonb;
  n    bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  -- Tornillo P1: L 15.00 con ISV 15 % (costo L 10.00). Mayorista L 12.00 desde 12 unidades.

  -- ===== 1) Reglas del producto y permisos =====
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L, %L)', e, pruebas.id('P1'),
    '{"precio_mayorista_centavos": 1200}', 'Precio de mayoreo'), 'SIN_PERMISO', 'el vendedor no pone precio mayorista');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P1'),
    '{"precio_mayorista_centavos": 1200}'), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L, %L)', e, pruebas.id('P1'),
    '{"precio_mayorista_centavos": 1600}', 'Precio de mayoreo'), 'PRECIO_MAYORISTA_INVALIDO', 'mayorista mayor que el normal');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L, %L)', e, pruebas.id('P1'),
    '{"cantidad_mayorista": 12}', 'Precio de mayoreo'), 'PRECIO_MAYORISTA_INVALIDO', 'desde cantidad sin precio');
  r := public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 1200, "cantidad_mayorista": 12}', 'Precio de mayoreo');
  PERFORM pruebas.afirmar(jsonb_array_length(r->'avisos') = 0, 'sin avisos (1,200 con ISV = 1,043 sin ISV > costo 1,000): ' || r::text);
  PERFORM pruebas.afirmar((SELECT precio_mayorista_centavos = 1200 AND cantidad_mayorista = 12 AND precio_mayorista_con_isv_centavos = 1200
                             FROM public.v_producto WHERE producto_id = pruebas.id('P1')), 'v_producto con el mayorista');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_precio_producto(%L, %L, 1100, %L)', e, pruebas.id('P1'), 'Bajar el precio'),
    'PRECIO_MAYORISTA_INVALIDO', 'el normal no baja del mayorista');
  -- Por debajo del costo: aviso (no impide). 1,100 con ISV = round(1,100 / 1.15) = 957 sin ISV < 1,000.
  r := public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 1100}', 'Prueba de aviso');
  PERFORM pruebas.afirmar(r->'avisos'->0->>'tipo' = 'mayorista_bajo_costo', 'aviso de costo: ' || r::text);
  r := public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 1200}', 'Volver al de mayoreo');
  -- Producto nuevo con mayorista (productos.editar basta).
  r := public.crear_producto(e, '{"codigo": "CLAVO-1", "nombre": "Clavo", "precio_venta_centavos": 500, "precio_mayorista_centavos": 400, "cantidad_mayorista": 100}', gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT precio_mayorista_centavos = 400 AND cantidad_mayorista = 100 FROM public.producto WHERE id = (r->>'producto_id')::uuid), 'nuevo con mayorista');

  -- ===== 2) Por cantidad =====
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 10), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 15000, '10 tornillos a precio normal: ' || (v->>'total_centavos'));
  -- 12 x 12.00 = 14,400 (base round(14,400 / 1.15) = 12,522; ISV 1,878).
  v := public.registrar_venta(e, pruebas.venta('P1', 12), op);
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 14400, '12 tornillos al mayorista: ' || (v->>'total_centavos'));
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT precio_tipo = 'mayorista' AND precio_normal_centavos = 1500 AND precio_unitario_centavos = 1200
                             AND base_centavos = 12522 AND impuesto_centavos = 1878
                             FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid), 'la línea guarda el mayorista');
  PERFORM pruebas.como('cajero_a');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 12), op);
  PERFORM pruebas.afirmar((v2->>'duplicado')::boolean AND v2->>'venta_id' = v->>'venta_id', 'doble envío = la misma venta');
  r := public.documento_venta((v->>'venta_id')::uuid);
  PERFORM pruebas.afirmar(r->'lineas'->0->>'precio_texto' = 'Precio mayorista' AND (r->'lineas'->0->>'precio_normal_centavos')::bigint = 1500,
    'comprobante: ' || (r->'lineas')::text);

  -- ===== 3) Por cliente =====
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_tercero(%L, %L, %L)', e, pruebas.id('CLI1'), '{"es_mayorista": true}'),
    'SIN_PERMISO', 'el cajero no marca mayoristas');
  PERFORM pruebas.como('admin_a');
  PERFORM public.editar_tercero(e, pruebas.id('CLI1'), '{"es_mayorista": true}', 'Compra para revender');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'tercero' AND motivo = 'Compra para revender'
    AND (despues->>'es_mayorista')::boolean), 'bitácora del cliente mayorista');
  PERFORM pruebas.como('cajero_a');
  r := public.calcular_venta_previa(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))));
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 1200 AND r->'lineas'->0->>'precio_tipo' = 'mayorista'
    AND (r->>'cliente_mayorista')::boolean, 'previa con cliente mayorista: ' || r::text);
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))));
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 1500 AND r->'lineas'->0->>'precio_tipo' = 'normal'
    AND NOT (r->'lineas'->0->>'precio_mayorista_disponible')::boolean, 'previa sin cliente: normal');
  v := public.registrar_venta(e, pruebas.venta('P1', 1, 'efectivo', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 1200, 'cliente mayorista, 1 tornillo: ' || (v->>'total_centavos'));
  -- Pedir el normal explícito.
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo"}]'::jsonb,
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'precio_tipo', 'normal'))), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 1500, 'precio normal elegido');
  -- Mayorista donde no aplica (arroz sin precio mayorista).
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('pagos', '[{"forma":"efectivo"}]'::jsonb,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1, 'precio_tipo', 'mayorista')))),
    'PRECIO_MAYORISTA_NO_APLICA', 'mayorista en un producto sin él');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('pagos', '[{"forma":"efectivo"}]'::jsonb,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2, 'precio_tipo', 'mayorista')))),
    'PRECIO_MAYORISTA_NO_APLICA', 'mayorista sin cliente mayorista ni cantidad');
  -- Cotización del cliente mayorista.
  PERFORM pruebas.como('dueno_a');
  r := public.crear_cotizacion(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2))), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 2400
    AND (SELECT calculo->'lineas'->0->>'precio_tipo' FROM public.cotizacion WHERE id = (r->>'cotizacion_id')::uuid) = 'mayorista', 'cotización mayorista');

  -- ===== 4) Nunca descuento sobre descuento =====
  -- Galón P3: L 450.00 con ISV 18 %, mayorista L 400.00.
  PERFORM public.editar_producto(e, pruebas.id('P3'), '{"precio_mayorista_centavos": 40000}', 'Precio de mayoreo');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', '[{"forma":"efectivo"}]'::jsonb,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 5)))),
    'DESCUENTO_DOBLE', 'mayorista + descuento manual');
  -- Con precio normal elegido, 5 %: 45,000 - 2,250 = 42,750.
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo"}]'::jsonb,
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'precio_tipo', 'normal', 'descuento_porcentaje', 5))),
         gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 42750, 'normal con 5 %: ' || (v->>'total_centavos'));
  -- Descuento de factura 10 %: el galón mayorista (40,000) queda fuera; el servicio (23,000) baja a 20,700. Total 60,700.
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo"}]'::jsonb,
         'descuento_factura', '{"porcentaje": 10}'::jsonb,
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1),
                                     jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 1))), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 60700, 'descuento de factura solo al servicio: ' || (v->>'total_centavos'));
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', '[{"forma":"efectivo"}]'::jsonb, 'descuento_factura', '{"porcentaje": 10}'::jsonb,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)))),
    'DESCUENTO_DOBLE', 'factura con solo líneas mayoristas');

  -- Promociones en la categoría del tornillo.
  PERFORM pruebas.como('dueno_a');
  catp := (public.crear_categoria(e, 'Ferretería')->>'categoria_id')::uuid;
  PERFORM public.editar_producto(e, pruebas.id('P1'), jsonb_build_object('categoria_id', catp));
  pa := (public.crear_promocion(e, jsonb_build_object('nombre', 'Diez por ciento', 'categoria_id', catp, 'tipo', 'porcentaje', 'porcentaje', 10,
         'fecha_inicio', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'), 'fecha_fin', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;
  PERFORM pruebas.como('cajero_a');
  -- Una promoción: 12 x 15.00 = 18,000 - 10 % = 16,200 contra mayorista 14,400: gana el mayorista (no se suman).
  v := public.registrar_venta(e, pruebas.venta('P1', 12), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 14400, 'mayorista gana a la promoción: ' || (v->>'total_centavos'));
  -- 10 tornillos (no llega a 12): la promoción, 13,500.
  v := public.registrar_venta(e, pruebas.venta('P1', 10), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 13500, 'sin mayorista: la promoción');
  -- Quien vende elige la promoción en vez del mayorista: 16,200.
  v := public.registrar_venta(e, jsonb_build_object('pagos', '[{"forma":"efectivo"}]'::jsonb,
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 12, 'promocion_id', pa))), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 16200, 'promoción elegida: ' || (v->>'total_centavos'));
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('pagos', '[{"forma":"efectivo"}]'::jsonb,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 12, 'promocion_id', pa, 'precio_tipo', 'mayorista')))),
    'DESCUENTO_DOBLE', 'mayorista + promoción');
  -- Dos promociones (10 % y L 1.00 por unidad): el mayorista (14,400) gana a las dos (16,200 y 16,800): sale solo.
  PERFORM pruebas.como('dueno_a');
  pb := (public.crear_promocion(e, jsonb_build_object('nombre', 'Un lempira menos', 'categoria_id', catp, 'tipo', 'monto', 'monto_centavos', 100,
         'fecha_inicio', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'), 'fecha_fin', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 12), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 14400, 'mayorista gana a dos promociones');
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 12))));
  PERFORM pruebas.afirmar(r->'lineas'->0->>'precio_tipo' = 'mayorista' AND r->'lineas'->0->'promocion_sugerida_id' = 'null', 'previa: mayorista sin sugerir promoción');
  -- Pidiendo el precio normal, con dos promociones hay que elegir.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object('pagos', '[{"forma":"efectivo"}]'::jsonb,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 12, 'precio_tipo', 'normal')))),
    'PROMOCION_A_ELEGIR', 'normal con dos promociones');

  -- ===== 5) Excel de ida y vuelta =====
  PERFORM pruebas.como('dueno_a');
  x := public.exportar_plantilla(e, 'productos');
  PERFORM pruebas.afirmar((SELECT f->'precio_mayorista' = '12.00' AND f->'desde_cantidad' = '12' FROM jsonb_array_elements(x->'filas') f
                            WHERE f->>'codigo' = 'TOR-001'), 'exporta el mayorista');
  PERFORM pruebas.afirmar((SELECT string_agg(c->>'clave', ',') FROM jsonb_array_elements(x->'columnas') c) LIKE '%precio_incluye_isv,precio_mayorista,desde_cantidad,%',
    'columnas nuevas después de "precio incluye ISV"');
  filas := (SELECT jsonb_agg(CASE f->>'codigo' WHEN 'TOR-001' THEN f || '{"precio_mayorista": 11.50}'
                                               WHEN 'ARR-001' THEN f || '{"precio_mayorista": 20.00, "desde_cantidad": 25}' ELSE f END)
              FROM jsonb_array_elements(x->'filas') f);
  r := public.importar_aplicar(e, 'productos', filas, gen_random_uuid(), 'Precios de mayoreo');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean AND (r->'resumen'->>'actualizar')::int = 2, 'Excel aplicado: ' || (r - 'filas')::text);
  PERFORM pruebas.afirmar((SELECT precio_mayorista_centavos FROM public.producto WHERE id = pruebas.id('P1')) = 1150
    AND (SELECT precio_mayorista_centavos = 2000 AND cantidad_mayorista = 25 FROM public.producto WHERE id = pruebas.id('P2')), 'mayoristas del Excel');
  filas := (SELECT jsonb_agg(CASE f->>'codigo' WHEN 'TOR-001' THEN f || '{"precio_mayorista": 99.00}' ELSE f END)
              FROM jsonb_array_elements(x->'filas') f);
  r := public.importar_vista_previa(e, 'productos', filas);
  PERFORM pruebas.afirmar((r->'resumen'->>'error')::int = 1, 'Excel: mayorista mayor que el precio = error: ' || (r->'resumen')::text);
  x := public.exportar_plantilla(e, 'clientes_proveedores');
  PERFORM pruebas.afirmar((SELECT f->>'mayorista' FROM jsonb_array_elements(x->'filas') f WHERE f->>'nombre' = 'Constructora Ríos') = 'Sí',
    'exporta cliente mayorista');
  filas := (SELECT jsonb_agg(CASE f->>'nombre' WHEN 'Juan Pérez' THEN f || '{"mayorista": "Sí"}' ELSE f END)
              FROM jsonb_array_elements(x->'filas') f);
  r := public.importar_aplicar(e, 'clientes_proveedores', filas, gen_random_uuid(), 'Mayoristas nuevos');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean AND (SELECT es_mayorista FROM public.tercero WHERE id = pruebas.id('CLI2')), 'cliente mayorista por Excel: ' || (r - 'filas')::text);

  -- ===== 6) Todo cuadra =====
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM (SELECT l.asiento_id FROM public.asiento_linea l WHERE l.empresa_id = e
                                GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)) x;
  PERFORM pruebas.afirmar(n = 0, 'asientos que no cuadran: ' || n);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
