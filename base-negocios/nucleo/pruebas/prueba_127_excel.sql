-- PRUEBA: Excel de ida y vuelta: exportar -> cambiar precios y un campo extra -> vista previa (no guarda) -> aplicar -> exportar coincide; errores por fila y columna; celda vacía conserva; nunca borra; todo o nada; id_operacion repetido; permisos (vendedor sin costos ni importar); clientes con código, saldos iniciales, categorías, existencias iniciales una vez y conteo físico con ajustes pendientes de aprobación
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  x      jsonb;
  r      jsonb;
  filas  jsonb;
  op     uuid := gen_random_uuid();
  n      bigint;
  v_cod  text;
  v_apr  uuid;
  fila   jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);   -- B1, B2, P1 TOR-001 (100 und a L 10.00), P2 ARR-001, P3 PIN-001, CLI1, CLI2, S1
  PERFORM public.crear_campo_extra(e, 'marca', 'Marca', 'texto');

  -- 1) Exportar productos (dueño, ve costos). TOR-001: L 15.00 con ISV 15 % -> sin ISV round(1500/1.15) = 1304
  --    (L 13.04); costo L 10.00; margen = (1304 - 1000) / 1304 = 23.31 %.
  x := public.exportar_plantilla(e, 'productos');
  fila := (SELECT f FROM jsonb_array_elements(x->'filas') f WHERE f->>'codigo' = 'TOR-001');
  PERFORM pruebas.afirmar(fila->'precio_venta' = '15.00' AND fila->'precio_sin_isv' = '13.04' AND fila->'costo_promedio' = '10.00'
    AND fila->'margen_porcentaje' = '23.31' AND fila->'existencia_total' = '100' AND fila->>'precio_incluye_isv' = 'Sí'
    AND fila->>'unidad' = 'UND' AND fila->>'impuesto' = 'ISV15' AND fila ? 'extra.marca' AND fila->>'ultima_compra' = '2026-01-05',
    'fila exportada de TOR-001: ' || fila::text);
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(x->'columnas') c
                                   WHERE c->>'clave' = 'costo_promedio' AND NOT (c->>'editable')::boolean), 'costo en gris');

  -- 2) Cambiar en el "Excel": TOR-001 a L 16.50 y marca Stanley; ARR-001 a L 24.00. Lo demás igual.
  filas := (SELECT jsonb_agg(CASE f->>'codigo'
             WHEN 'TOR-001' THEN f || '{"precio_venta": 16.50, "extra.marca": "Stanley"}'
             WHEN 'ARR-001' THEN f || '{"precio_venta": 24.00}'
             ELSE f END) FROM jsonb_array_elements(x->'filas') f);
  r := public.importar_vista_previa(e, 'productos', filas);
  PERFORM pruebas.afirmar(r->'resumen' = jsonb_build_object('filas', jsonb_array_length(filas), 'crear', 0, 'actualizar', 2,
    'sin_cambios', jsonb_array_length(filas) - 2, 'error', 0), 'vista previa: 2 a actualizar: ' || (r->'resumen')::text);
  PERFORM pruebas.afirmar((SELECT f->'cambios' FROM jsonb_array_elements(r->'filas') f WHERE f->>'llave' = 'TOR-001')
                          = '["extra.marca", "precio_venta"]', 'cambios de TOR-001');
  PERFORM pruebas.afirmar((SELECT precio_venta_centavos FROM public.producto WHERE id = pruebas.id('P1')) = 1500
    AND (SELECT campos_extra FROM public.producto WHERE id = pruebas.id('P1')) = '{}', 'la vista previa no guardó nada');

  r := public.importar_aplicar(e, 'productos', filas, op, 'Precios de octubre');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean AND (r->'resumen'->>'actualizar')::int = 2, 'aplicado: ' || (r - 'filas')::text);
  PERFORM pruebas.afirmar((SELECT precio_venta_centavos FROM public.producto WHERE id = pruebas.id('P1')) = 1650
    AND (SELECT precio_venta_centavos FROM public.producto WHERE id = pruebas.id('P2')) = 2400
    AND (SELECT campos_extra->>'marca' FROM public.producto WHERE id = pruebas.id('P1')) = 'Stanley', 'precios y marca guardados');
  PERFORM pruebas.afirmar((SELECT motivo FROM public.producto_precio WHERE producto_id = pruebas.id('P1') ORDER BY id DESC LIMIT 1)
                          = 'Precios de octubre', 'historial de precios con el motivo');

  -- 3) Exportar otra vez: lo editable coincide con lo que se subió.
  x := public.exportar_plantilla(e, 'productos');
  PERFORM pruebas.afirmar((SELECT bool_and((SELECT jsonb_object_agg(c->>'clave', a->(c->>'clave')) FROM jsonb_array_elements(x->'columnas') c
                                             WHERE (c->>'editable')::boolean)
                                          = (SELECT jsonb_object_agg(c->>'clave', b->(c->>'clave')) FROM jsonb_array_elements(x->'columnas') c
                                             WHERE (c->>'editable')::boolean))
                             FROM jsonb_array_elements(x->'filas') a
                             JOIN jsonb_array_elements(filas) b ON b->>'codigo' = a->>'codigo')
    AND jsonb_array_length(x->'filas') = jsonb_array_length(filas), 'exportar después de aplicar coincide');
  PERFORM pruebas.afirmar((public.importar_vista_previa(e, 'productos', x->'filas')->'resumen'->>'actualizar')::int = 0,
    'subir lo mismo = sin cambios');

  -- 4) Mismo id_operacion: no repite; otro tipo de operación con ese id: ID_OPERACION_USADO.
  n := (SELECT count(*) FROM public.producto_precio);
  r := public.importar_aplicar(e, 'productos', filas, op, 'Precios de octubre');
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean AND (SELECT count(*) FROM public.producto_precio) = n
    AND (SELECT count(*) FROM public.importacion_excel WHERE empresa_id = e) = 1, 'reintento con el mismo id no repite');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, %L)', e, '{"codigo":"Z1","nombre":"Z"}', op),
    'ID_OPERACION_USADO', 'id de una importación usado en otra cosa');

  -- 5) Errores por fila y columna; con UN error no se aplica nada.
  filas := '[
    {"fila": 2, "codigo": "TOR-001", "precio_venta": "15.555"},
    {"fila": 3, "codigo": "NUEVO-1", "nombre": "Nuevo", "categoria": "No existe"},
    {"fila": 4, "codigo": "NUEVO-2"},
    {"fila": 5, "codigo": "PIN-001", "activo": "tal vez"},
    {"fila": 6, "codigo": "ARR-001", "unidad": "XX"},
    {"fila": 7, "codigo": "arr-001", "nombre": "Otro"},
    {"fila": 8, "codigo": "MAL CODIGO"},
    {"fila": 9, "codigo": "P-OK", "nombre": "Producto bueno", "precio_venta": 10},
    {"fila": 10, "codigo": "X", "color": "rojo"},
    {"fila": 11, "codigo": "PIN-001", "precio_venta": "-5"}]';
  r := public.importar_vista_previa(e, 'productos', filas);
  PERFORM pruebas.afirmar((r->'resumen'->>'error')::int = 9 AND (r->'resumen'->>'crear')::int = 1, 'resumen con errores: ' || (r->'resumen')::text);
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er
                                   WHERE (er->>'fila')::int = 2 AND er->>'columna' = 'Precio de venta (L)' AND er->>'mensaje' LIKE '%2 decimales%'),
    'fila 2: precio con 3 decimales');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er
                                   WHERE (er->>'fila')::int = 3 AND er->>'columna' = 'Categoría' AND er->>'mensaje' LIKE '%no existe%'), 'fila 3: categoría');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 4 AND er->>'columna' = 'Nombre'), 'fila 4: falta nombre');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 5 AND er->>'texto' LIKE 'Fila 5, columna "Activo": escriba Sí o No.'), 'fila 5: Sí/No');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 6 AND er->>'columna' = 'Unidad'), 'fila 6: unidad');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 7 AND er->>'mensaje' LIKE '%repetido%fila 6%'), 'fila 7: repetido');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 8 AND er->>'columna' = 'Código'), 'fila 8: código');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 10 AND er->>'columna' = 'color'), 'fila 10: columna desconocida');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 11 AND er->>'mensaje' LIKE '%negativo%'), 'fila 11: negativo');
  r := public.importar_aplicar(e, 'productos', filas, gen_random_uuid(), 'Con errores');
  PERFORM pruebas.afirmar(NOT (r->>'aplicado')::boolean AND NOT EXISTS (SELECT 1 FROM public.producto WHERE empresa_id = e AND codigo = 'P-OK')
    AND (SELECT count(*) FROM public.importacion_excel WHERE empresa_id = e) = 1, 'un error = no se aplica nada');

  -- 6) Celda vacía conserva; nunca borra; "Activo: No" desactiva.
  n := (SELECT count(*) FROM public.producto WHERE empresa_id = e);
  r := public.importar_aplicar(e, 'productos', '[{"codigo": "PIN-001", "nombre": "", "precio_venta": null, "codigo_barras": "  ", "existencia_minima": 3},
                                                  {"codigo": "NUEVO-3", "nombre": "Para desactivar", "precio_venta": "1,250.50", "activo": "No"}]',
                               gen_random_uuid(), 'Ajustes varios');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean, 'aplicado 6: ' || r::text);
  PERFORM pruebas.afirmar((SELECT nombre = 'Pintura galón' AND precio_venta_centavos = 45000 AND stock_minimo = 3
                             FROM public.producto WHERE id = pruebas.id('P3')), 'vacío conserva; solo cambia la existencia mínima');
  PERFORM pruebas.afirmar((SELECT NOT activo AND precio_venta_centavos = 125050 FROM public.producto WHERE empresa_id = e AND codigo = 'NUEVO-3')
    AND (SELECT count(*) FROM public.producto WHERE empresa_id = e) = n + 1, 'nuevo creado inactivo; nada borrado');

  -- 7) Permisos: el vendedor exporta sin costos y no importa.
  PERFORM pruebas.como('vendedor_a');
  x := public.exportar_plantilla(e, 'productos');
  PERFORM pruebas.afirmar((x->>'costos_ocultos')::boolean
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x->'columnas') c WHERE c->>'clave' IN ('costo_promedio', 'valor_inventario', 'margen_porcentaje'))
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x->'filas') f WHERE f ? 'costo_promedio' OR f ? 'margen_porcentaje'), 'vendedor sin costos');
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_vista_previa(%L, %L, %L)', e, 'productos', '[]'), 'SIN_PERMISO', 'vendedor no revisa importaciones');
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_aplicar(%L, %L, %L, gen_random_uuid(), %L)', e, 'clientes_proveedores',
    '[{"nombre":"X"}]', 'Prueba vendedor'), 'SIN_PERMISO', 'vendedor no importa');
  PERFORM pruebas.debe_fallar(format('SELECT public.exportar_plantilla(%L, %L)', e, 'existencias_iniciales'), 'SIN_PERMISO', 'vendedor no exporta cargas iniciales');

  -- 8) Categorías y clientes con código (como admin).
  PERFORM pruebas.como('admin_a');
  r := public.importar_aplicar(e, 'categorias', '[{"nombre": "Ferretería"}, {"nombre": "Tornillería", "categoria_madre": "ferretería"}]',
                               gen_random_uuid(), 'Categorías iniciales');
  PERFORM pruebas.afirmar((r->'resumen'->>'crear')::int = 2, 'categorías creadas: ' || r::text);
  r := public.importar_aplicar(e, 'productos', '[{"codigo": "TOR-001", "categoria": "Ferretería", "subcategoria": "Tornillería"}]',
                               gen_random_uuid(), 'Categoría del tornillo');
  PERFORM pruebas.afirmar((SELECT f->>'categoria' || ' / ' || (f->>'subcategoria') FROM jsonb_array_elements(public.exportar_plantilla(e, 'productos')->'filas') f
                            WHERE f->>'codigo' = 'TOR-001') = 'Ferretería / Tornillería', 'producto con subcategoría');

  x := public.exportar_plantilla(e, 'clientes_proveedores');
  PERFORM pruebas.afirmar((SELECT bool_and(f->>'codigo' ~ '^T[0-9]{5}$') FROM jsonb_array_elements(x->'filas') f)
    AND (SELECT f->>'saldo_por_pagar' FROM jsonb_array_elements(x->'filas') f WHERE f->>'nombre' = 'Distribuidora Lara') = '5440.00',
    'clientes y proveedores con código y saldo (F-INI-1: 475,000 + ISV 15,000 + 54,000 = 544,000)');
  v_cod := (SELECT codigo FROM public.tercero WHERE id = pruebas.id('CLI2'));
  r := public.importar_aplicar(e, 'clientes_proveedores', jsonb_build_array(
         jsonb_build_object('codigo', v_cod, 'telefono', '9999-1111', 'saldo_por_cobrar', '999.00'),
         '{"nombre": "Cliente del Excel", "tipo": "cliente", "rtn": "0801-1990-003333"}'::jsonb), gen_random_uuid(), 'Clientes de la libreta');
  PERFORM pruebas.afirmar((r->'resumen'->>'crear')::int = 1 AND (r->'resumen'->>'actualizar')::int = 1, 'clientes: ' || (r - 'filas')::text);
  PERFORM pruebas.afirmar((SELECT telefono FROM public.tercero WHERE id = pruebas.id('CLI2')) = '99991111', 'teléfono actualizado (gris ignorada)');
  v_cod := (SELECT codigo FROM public.tercero WHERE empresa_id = e AND rtn = '08011990003333');
  PERFORM pruebas.afirmar(v_cod ~ '^T[0-9]{5}$', 'código automático ' || coalesce(v_cod, '-'));
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.tercero SET codigo = %L WHERE id = %L', 'OTRO', pruebas.id('CLI2')), 'NO_PERMITIDO', 'el código no cambia');

  -- 9) Saldos iniciales (solo el dueño): una vez; subirlo otra vez = sin cambios.
  PERFORM pruebas.como('dueno_a');
  filas := jsonb_build_array(jsonb_build_object('tipo', 'cliente', 'codigo', v_cod, 'documento', 'F-100',
             'fecha_documento', '2025-12-15', 'monto', '1,500.00'));
  r := public.importar_aplicar(e, 'saldos_iniciales', filas, gen_random_uuid(), 'Saldos de la libreta');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean AND (SELECT monto_centavos FROM public.cxc_saldo_inicial
    WHERE empresa_id = e AND numero_documento = 'F-100') = 150000, 'saldo inicial de cliente 150,000');
  PERFORM pruebas.afirmar((public.importar_vista_previa(e, 'saldos_iniciales', filas)->'resumen'->>'sin_cambios')::int = 1, 'otra vez = sin cambios');
  PERFORM pruebas.afirmar((SELECT f->>'saldo_pendiente' FROM jsonb_array_elements(public.exportar_plantilla(e, 'saldos_iniciales')->'filas') f
                            WHERE f->>'documento' = 'F-100') = '1500.00', 'exportar saldos iniciales');

  -- 10) Existencias iniciales: una sola vez contra Saldos de apertura (L 250.00 x 10 = 250,000).
  n := pruebas.saldo_libros(e, '3.3.01.03');
  PERFORM public.importar_aplicar(e, 'productos', '[{"codigo": "CEM-1", "nombre": "Cemento"}]', gen_random_uuid(), 'Producto nuevo');
  filas := '[{"codigo": "CEM-1", "bodega": "b1", "cantidad": 10, "costo_unitario": "250.00"}, {"codigo": "TOR-001", "bodega": "B2"}]';
  r := public.importar_aplicar(e, 'existencias_iniciales', filas, gen_random_uuid(), 'Inventario inicial');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean AND (SELECT s.cantidad = 10 AND s.valor_centavos = 250000 FROM public.inventario_saldo s JOIN public.producto p ON p.id = s.producto_id
                                                                  WHERE p.codigo = 'CEM-1' AND s.bodega_id = pruebas.id('B1'))
    AND pruebas.saldo_libros(e, '3.3.01.03') = n + 250000, 'carga inicial: ' || (r - 'filas')::text);
  PERFORM pruebas.como('admin_a');                -- el admin no tiene "repetir carga inicial"
  r := public.importar_vista_previa(e, 'existencias_iniciales', filas);
  PERFORM pruebas.afirmar((SELECT er->>'mensaje' FROM jsonb_array_elements(r->'errores') er WHERE (er->>'fila')::int = 2) LIKE '%una sola vez%',
    'segunda carga = error claro');

  -- 11) Conteo físico (admin): NO cambia existencias; crea ajustes pendientes por bodega.
  x := public.exportar_plantilla(e, 'conteo_fisico');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x->'filas') f WHERE f ? 'existencia'), 'conteo a ciegas');
  filas := '[{"codigo": "TOR-001", "bodega": "B1", "cantidad_contada": 97},
             {"codigo": "ARR-001", "bodega": "B1", "cantidad_contada": 50},
             {"codigo": "PIN-001", "bodega": "B2", "cantidad_contada": 2},
             {"codigo": "CEM-1", "bodega": "B1"}]';
  r := public.importar_aplicar(e, 'conteo_fisico', filas, gen_random_uuid(), 'Conteo de fin de mes');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean AND (r->'resumen'->>'crear')::int = 2 AND (r->'resumen'->>'sin_cambios')::int = 2
    AND jsonb_array_length(r->'documentos') = 2, 'conteo: ' || (r - 'filas')::text);
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 100 AND pruebas.existencia('B2', 'P3') = 0, 'el conteo no toca existencias');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.aprobacion WHERE empresa_id = e AND tipo = 'conteo_fisico' AND estado = 'pendiente') = 2,
    'dos ajustes pendientes de aprobación');
  v_apr := (SELECT c.aprobacion_id FROM public.conteo_fisico c JOIN public.bodega b ON b.id = c.bodega_id WHERE b.codigo = 'B1');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', v_apr, 'ok'), 'PROHIBIDO', 'no aprueba su propio conteo');

  -- Después del conteo salen 5 de B1 a B2; al aprobar se aplica la DIFERENCIA (-3): 95 - 3 = 92.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), public.hoy_local(e),
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5)), gen_random_uuid());
  r := public.resolver_aprobacion(v_apr, true, 'Conteo revisado', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicado' AND pruebas.existencia('B1', 'P1') = 92
    AND (SELECT tipo FROM public.inventario_documento WHERE id = (r->>'documento_id')::uuid) = 'ajuste', 'aprobado: ' || r::text);
  v_apr := (SELECT c.aprobacion_id FROM public.conteo_fisico c JOIN public.bodega b ON b.id = c.bodega_id WHERE b.codigo = 'B2');
  r := public.resolver_aprobacion(v_apr, false, 'Se contó mal la bodega trasera', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'rechazado' AND pruebas.existencia('B2', 'P3') = 0, 'rechazado sin mover nada');

  -- 12) Todas las hojas exportan con columnas y reglas.
  PERFORM pruebas.afirmar((SELECT bool_and(jsonb_array_length(public.exportar_plantilla(e, h)->'columnas') > 2)
                             FROM unnest(ARRAY['productos', 'clientes_proveedores', 'categorias', 'existencias_iniciales',
                                               'saldos_iniciales', 'conteo_fisico']) h), 'todas las hojas exportan');
  PERFORM pruebas.debe_fallar(format('SELECT public.exportar_plantilla(%L, %L)', e, 'ventas'), 'DATO_INVALIDO', 'hoja inexistente');
END $$;
