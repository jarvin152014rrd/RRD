-- PRUEBA: catálogo de productos: códigos únicos, categorías, unidades, campos extra validados, historial de precios, bodegas y búsqueda por código de barras
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  op   uuid := gen_random_uuid();
  cat1 uuid; cat2 uuid; cat3 uuid;
  qq   uuid;
  p    uuid;
  r    jsonb;
  v    public.producto;
  s001 uuid;
BEGIN
  -- Sin el módulo inventario no se crean productos.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X1","nombre":"X"}'), 'MODULO_INACTIVO', 'sin módulo');
  PERFORM pruebas.preparar_inventario();     -- activa módulos; crea B1, B2, P1, P2, P3

  -- Categorías: hasta 3 niveles, nombre único por nivel.
  PERFORM pruebas.como('admin_a');
  cat1 := (public.crear_categoria(e, 'Ferretería')->>'categoria_id')::uuid;
  cat2 := (public.crear_categoria(e, 'Tornillería', cat1)->>'categoria_id')::uuid;
  cat3 := (public.crear_categoria(e, 'Tornillos de acero', cat2)->>'categoria_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_categoria(%L, %L, %L)', e, 'Nivel 4', cat3), 'NO_PERMITIDO', 'cuarto nivel');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_categoria(%L, %L)', e, 'ferretería'), 'YA_EXISTE', 'nombre repetido');
  PERFORM public.crear_categoria(e, 'Ferretería', cat2);   -- mismo nombre en otro nivel: sí

  -- Unidades: comunes + propias; no repite una común.
  qq := (public.crear_unidad(e, 'qq', 'Quintal')->>'unidad_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_unidad(%L, %L, %L)', e, 'KG', 'Kilo'), 'YA_EXISTE', 'unidad común repetida');

  -- Campos extra: tipos y obligatorios.
  PERFORM public.crear_campo_extra(e, 'marca', 'Marca', 'texto');
  PERFORM public.crear_campo_extra(e, 'talla', 'Talla', 'lista', '["S","M","L"]');
  PERFORM public.crear_campo_extra(e, 'vence', 'Fecha de vencimiento', 'fecha');
  PERFORM public.crear_campo_extra(e, 'piezas', 'Piezas por caja', 'entero');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_campo_extra(%L, %L, %L, %L)', e, 'Mal Clave', 'X', 'texto'), 'DATO_INVALIDO', 'clave con espacio');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_campo_extra(%L, %L, %L, %L)', e, 'color', 'Color', 'lista'), 'opciones', 'lista sin opciones');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_campo_extra(%L, %L, %L, %L)', e, 'marca', 'Marca', 'texto'), 'YA_EXISTE', 'campo repetido');

  -- Crear producto completo.
  r := public.crear_producto(e, jsonb_build_object('codigo', ' cem-50 ', 'codigo_barras', '7420000000505',
         'nombre', 'Cemento 50 kg', 'categoria_id', cat1, 'unidad_id', qq, 'tipo_impuesto', 'isv15',
         'precio_venta_centavos', 26500, 'stock_minimo', 10,
         'campos_extra', jsonb_build_object('marca', 'Bijao', 'piezas', 1, 'vence', '2027-01-31')), op);
  p := (r->>'producto_id')::uuid;
  SELECT * INTO v FROM public.producto WHERE id = p;
  PERFORM pruebas.afirmar(v.codigo = 'CEM-50' AND v.tipo_impuesto = 'ISV15' AND v.unidad_id = qq AND v.categoria_id = cat1
    AND v.precio_venta_centavos = 26500 AND v.stock_minimo = 10 AND NOT v.permite_fracciones
    AND v.campos_extra = '{"marca": "Bijao", "piezas": 1, "vence": "2027-01-31"}', 'producto guardado');
  -- Reintento: mismo id_operacion, mismo producto.
  PERFORM pruebas.afirmar((public.crear_producto(e, '{"codigo":"OTRO","nombre":"Otro"}', op)->>'duplicado')::boolean, 'reintento no duplica');
  -- Defectos: unidad UND, impuesto ISV15.
  PERFORM pruebas.afirmar((SELECT u.codigo FROM public.producto x JOIN public.unidad u ON u.id = x.unidad_id
                            WHERE x.id = pruebas.id('P1')) = 'UND', 'unidad por defecto UND');

  -- Únicos por empresa y datos malos.
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"CEM-50","nombre":"X"}'), 'YA_EXISTE', 'código repetido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"cem-50","nombre":"X"}'), 'YA_EXISTE', 'código repetido (minúsculas)');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","codigo_barras":"7420000000505"}'), 'YA_EXISTE', 'código de barras repetido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X 2","nombre":"X"}'), 'DATO_INVALIDO', 'código con espacio');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","tipo_impuesto":"ISV12"}'), 'IMPUESTO_INVALIDO', 'impuesto inventado');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","precio_venta_centavos":10.5}'), 'centavos', 'precio con decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","precio_venta_centavos":-1}'), 'centavos', 'precio negativo');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","campos_extra":{"color":"rojo"}}'), 'CAMPO_EXTRA_INVALIDO', 'campo extra inexistente');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","campos_extra":{"talla":"XL"}}'), 'CAMPO_EXTRA_INVALIDO', 'opción fuera de lista');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","campos_extra":{"piezas":2.5}}'), 'entero', 'entero con decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","campos_extra":{"vence":"2027-02-30"}}'), 'fecha', 'fecha imposible');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X","campos_extra":{"marca":5}}'), 'texto', 'texto que es número');

  -- Campo obligatorio: desde ahí todo producto nuevo o editado lo necesita.
  PERFORM public.crear_campo_extra(e, 'origen', 'País de origen', 'texto', NULL, true);
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X2","nombre":"X"}'), 'obligatorio', 'falta obligatorio');
  PERFORM public.editar_producto(e, p, '{"campos_extra": {"origen": "Honduras", "piezas": null}}');
  PERFORM pruebas.afirmar((SELECT campos_extra FROM public.producto WHERE id = p) = '{"marca": "Bijao", "vence": "2027-01-31", "origen": "Honduras"}', 'null quita la clave; se combina');
  -- Desactivar el campo: ya no se exige ni se acepta.
  PERFORM public.desactivar_campo_extra(e, (SELECT id FROM public.campo_extra WHERE empresa_id = e AND clave = 'origen'), 'Ya no se usa');
  PERFORM public.crear_producto(e, '{"codigo":"X2","nombre":"Sin origen"}', gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, p, '{"campos_extra":{"origen":"HN"}}'), 'CAMPO_EXTRA_INVALIDO', 'campo desactivado');

  -- Editar: el precio no se cambia por aquí.
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, p, '{"precio_venta_centavos": 1}'), 'NO_PERMITIDO', 'precio por editar');
  PERFORM public.editar_producto(e, p, '{"nombre": "Cemento gris 50 kg", "codigo_barras": null}', 'Nombre del empaque');
  PERFORM pruebas.afirmar((SELECT nombre = 'Cemento gris 50 kg' AND codigo_barras IS NULL FROM public.producto WHERE id = p), 'editado');

  -- Precios: historial con motivo, usuario y fecha.
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_precio_producto(%L, %L, 27000, %L)', e, p, 'no'), 'FALTA_MOTIVO', 'precio sin motivo');
  r := public.cambiar_precio_producto(e, p, 27000, 'Subió el proveedor');
  PERFORM pruebas.afirmar((r->>'precio_anterior_centavos')::bigint = 26500 AND (r->>'cambio')::boolean, 'precio cambiado');
  r := public.cambiar_precio_producto(e, p, 27000, 'Mismo precio');
  PERFORM pruebas.afirmar(NOT (r->>'cambio')::boolean, 'mismo precio: sin cambio');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.producto_precio WHERE producto_id = p) = 2, 'historial: inicial + 1');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.producto_precio WHERE producto_id = p AND precio_anterior_centavos = 26500
    AND precio_nuevo_centavos = 27000 AND motivo = 'Subió el proveedor' AND cambiado_por = pruebas.usuario('admin_a')
    AND cambiado_en IS NOT NULL), 'historial completo');
  -- Ni a la fuerza se cambia un precio sin dejar historial con motivo.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.producto SET precio_venta_centavos = 1 WHERE id = %L', p), 'FALTA_MOTIVO', 'precio a la fuerza sin motivo');
  PERFORM pruebas.debe_fallar(format('UPDATE public.producto_precio SET motivo = %L WHERE producto_id = %L', 'x', p), 'PROHIBIDO', 'editar historial');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.producto WHERE id = %L', p), 'PROHIBIDO', 'borrar producto');

  -- Vendedor y cajero: no editan catálogo ni precios.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_precio_producto(%L, %L, 1, %L)', e, p, 'descuento mío'), 'SIN_PERMISO', 'vendedor cambia precio');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"V1","nombre":"V"}'), 'SIN_PERMISO', 'vendedor crea producto');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.producto WHERE empresa_id = e) = 5, 'vendedor ve el catálogo');

  -- Búsqueda por código de barras (escáner) y por código interno.
  r := public.buscar_producto_por_codigo(e, ' 7421000000011 ');
  PERFORM pruebas.afirmar((r->>'encontrado')::boolean AND r->>'por' = 'codigo_barras' AND r->'producto'->>'codigo' = 'TOR-001'
    AND (r->'producto'->>'precio_venta_centavos')::bigint = 1500 AND r->'producto'->>'unidad' = 'UND', 'por código de barras');
  r := public.buscar_producto_por_codigo(e, 'tor-001');
  PERFORM pruebas.afirmar((r->>'encontrado')::boolean AND r->>'por' = 'codigo', 'por código interno');
  r := public.buscar_producto_por_codigo(e, '0000000000000');
  PERFORM pruebas.afirmar(NOT (r->>'encontrado')::boolean, 'no encontrado sin error');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.buscar_producto_por_codigo(%L, %L)', e, '7421000000011'), 'NO_PERTENECE', 'otra empresa busca');
  PERFORM pruebas.afirmar(NOT (public.buscar_producto_por_codigo(pruebas.empresa('B'), '7421000000011')->>'encontrado')::boolean, 'B no encuentra los de A');

  -- Bodegas: código único, sucursal activa; desactivar solo vacía.
  PERFORM pruebas.como('admin_a');
  SELECT id INTO s001 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_bodega(%L, %L, %L, %L)', e, s001, 'b1', 'Otra'), 'YA_EXISTE', 'bodega repetida');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_bodega(%L, %L, %L, %L)', e, gen_random_uuid(), 'B9', 'X'), 'SUCURSAL_INVALIDA', 'sucursal inventada');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_bodega(%L, %L, %L, %L)', e, s001, 'B9', 'X'), 'SIN_PERMISO', 'cajero crea bodega');
  PERFORM pruebas.como('admin_a');
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B2'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5, 'costo_unitario', 100)), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_bodega(%L, %L, %L)', e, pruebas.id('B2'), 'Cierre de bodega'), 'NO_PERMITIDO', 'bodega con existencias');
  r := public.desactivar_bodega(e, pruebas.id('B1'), 'Bodega vacía, se cierra');
  PERFORM pruebas.afirmar(NOT (r->>'activa')::boolean, 'bodega vacía desactivada');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'costo_unitario', 1))), 'BODEGA_INVALIDA', 'bodega desactivada');

  -- Con kardex, la unidad del producto ya no cambia.
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P1'), jsonb_build_object('unidad_id', qq)), 'NO_PERMITIDO', 'unidad fija con kardex');

  -- Bitácora del catálogo.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'producto' AND accion = 'UPDATE'
    AND registro_id = p::text AND motivo = 'Nombre del empaque'), 'edición en bitácora');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'bodega' AND accion = 'UPDATE'
    AND motivo = 'Bodega vacía, se cierra'), 'bodega desactivada en bitácora');
END $$;
