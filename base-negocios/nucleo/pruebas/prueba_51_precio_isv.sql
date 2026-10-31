-- PRUEBA: precio con o sin ISV: marca por producto (defecto de la empresa, lo cambia solo el dueño), precio guardado tal cual, sin/con ISV calculados por línea con redondeo a centavo (cifras a mano) e historial de precios con la marca
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  p   uuid;
  r   record;
  j   jsonb;
BEGIN
  PERFORM pruebas.preparar_inventario();

  -- Regla (a mano). Incluye ISV: sin = round(precio / 1.15); no incluye: isv = round(precio x 0.15).
  SELECT * INTO r FROM public.precio_isv(1500, true, 'ISV15');      -- 1500 / 1.15 = 1304.35 -> 1304; ISV 196
  PERFORM pruebas.afirmar((r.sin_isv_centavos, r.isv_centavos, r.con_isv_centavos) = (1304, 196, 1500), '1500 con ISV15');
  SELECT * INTO r FROM public.precio_isv(45000, true, 'ISV18');     -- 45000 / 1.18 = 38135.59 -> 38136; ISV 6864
  PERFORM pruebas.afirmar((r.sin_isv_centavos, r.isv_centavos, r.con_isv_centavos) = (38136, 6864, 45000), '45000 con ISV18');
  SELECT * INTO r FROM public.precio_isv(10000, false, 'ISV15');    -- 10000 + 1500 = 11500
  PERFORM pruebas.afirmar((r.sin_isv_centavos, r.isv_centavos, r.con_isv_centavos) = (10000, 1500, 11500), '10000 sin ISV15');
  SELECT * INTO r FROM public.precio_isv(10, false, 'ISV15');       -- 1.5 -> 2 (mitad hacia arriba)
  PERFORM pruebas.afirmar((r.sin_isv_centavos, r.isv_centavos, r.con_isv_centavos) = (10, 2, 12), 'mitad hacia arriba');
  SELECT * INTO r FROM public.precio_isv(23, false, 'ISV15');       -- 3.45 -> 3
  PERFORM pruebas.afirmar((r.sin_isv_centavos, r.isv_centavos, r.con_isv_centavos) = (23, 3, 26), '3.45 baja a 3');
  SELECT * INTO r FROM public.precio_isv(2200, true, 'EXENTO');
  PERFORM pruebas.afirmar((r.sin_isv_centavos, r.isv_centavos, r.con_isv_centavos) = (2200, 0, 2200), 'exento');
  -- Por LÍNEA, no por unidad: 3 x 333 = 999 -> 999 / 1.15 = 868.70 -> 869; ISV 130.
  -- (Por unidad daría 3 x 290 = 870: un centavo distinto. La regla es por línea.)
  SELECT * INTO r FROM public.precio_isv(333, true, 'ISV15', 3);
  PERFORM pruebas.afirmar((r.sin_isv_centavos, r.isv_centavos, r.con_isv_centavos) = (869, 130, 999), 'ISV por línea');
  SELECT * INTO r FROM public.precio_isv(2200, false, 'EXENTO', 2.5);
  PERFORM pruebas.afirmar(r.con_isv_centavos = 5500, '2.5 lb x 2200 = 5500');

  -- Defecto de la empresa: true. Los productos de preparar_inventario lo tomaron.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar((SELECT precio_incluye_isv_defecto FROM public.empresa WHERE id = e), 'empresa: defecto true');
  SELECT * INTO r FROM public.v_producto WHERE producto_id = pruebas.id('P1');
  PERFORM pruebas.afirmar(r.precio_incluye_isv AND r.precio_venta_centavos = 1500 AND r.precio_sin_isv_centavos = 1304
    AND r.isv_centavos = 196 AND r.precio_con_isv_centavos = 1500, 'v_producto P1');
  SELECT * INTO r FROM public.v_producto WHERE producto_id = pruebas.id('P3');
  PERFORM pruebas.afirmar(r.precio_sin_isv_centavos = 38136 AND r.precio_con_isv_centavos = 45000, 'v_producto P3');
  -- Producto que se escribe SIN ISV: se guarda tal cual (10000) y se calcula el con ISV.
  p := (public.crear_producto(e, '{"codigo":"MART","nombre":"Martillo","precio_venta_centavos":10000,"precio_incluye_isv":false}', gen_random_uuid())->>'producto_id')::uuid;
  SELECT * INTO r FROM public.v_producto WHERE producto_id = p;
  PERFORM pruebas.afirmar(NOT r.precio_incluye_isv AND r.precio_venta_centavos = 10000 AND r.precio_con_isv_centavos = 11500, 'guardado tal cual');
  j := public.buscar_producto_por_codigo(e, 'MART');
  PERFORM pruebas.afirmar((j->'producto'->>'precio_sin_isv_centavos')::bigint = 10000 AND (j->'producto'->>'isv_centavos')::bigint = 1500
    AND (j->'producto'->>'precio_con_isv_centavos')::bigint = 11500 AND NOT (j->'producto'->>'precio_incluye_isv')::boolean, 'búsqueda con precios');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, gen_random_uuid())', e, '{"codigo":"X9","nombre":"X","precio_incluye_isv":"si"}'), 'true o false', 'marca mal escrita');

  -- Solo el dueño cambia el defecto.
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"precio_incluye_isv_defecto": false}', 'Cambiar defecto'), 'SIN_PERMISO', 'admin cambia el defecto');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"precio_incluye_isv_defecto": "no"}', 'Cambiar defecto'), 'DATO_INVALIDO', 'defecto mal escrito');
  j := public.configurar_empresa(e, '{"precio_incluye_isv_defecto": false}', 'Mis listas de precios son sin ISV');
  PERFORM pruebas.afirmar(NOT (j->>'precio_incluye_isv_defecto')::boolean, 'defecto cambiado');
  PERFORM pruebas.como('admin_a');
  p := (public.crear_producto(e, '{"codigo":"CLAV","nombre":"Clavo","precio_venta_centavos":100}', gen_random_uuid())->>'producto_id')::uuid;
  PERFORM pruebas.afirmar(NOT (SELECT precio_incluye_isv FROM public.producto WHERE id = p), 'producto nuevo toma el defecto nuevo');
  PERFORM pruebas.afirmar((SELECT precio_incluye_isv FROM public.producto WHERE id = pruebas.id('P1')), 'los productos de antes no cambian');

  -- Cambiar la marca de un producto: permiso de precios y motivo; queda en el historial.
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P1'), '{"precio_incluye_isv": false}'), 'FALTA_MOTIVO', 'marca sin motivo');
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"precio_incluye_isv": false}', 'El precio de lista es sin ISV');
  SELECT * INTO r FROM public.v_producto WHERE producto_id = pruebas.id('P1');
  PERFORM pruebas.afirmar(r.precio_venta_centavos = 1500 AND r.precio_con_isv_centavos = 1725, 'ahora 1500 + 225 = 1725');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.producto_precio WHERE producto_id = pruebas.id('P1')
    AND precio_anterior_centavos = 1500 AND precio_nuevo_centavos = 1500 AND incluye_isv_anterior AND NOT incluye_isv_nuevo
    AND motivo = 'El precio de lista es sin ISV' AND cambiado_por = pruebas.usuario('admin_a')), 'historial con la marca');
  PERFORM pruebas.afirmar((SELECT incluye_isv_nuevo FROM public.producto_precio WHERE producto_id = pruebas.id('P1') AND precio_anterior_centavos IS NULL),
    'precio inicial guarda la marca');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 1600, 'Subió el proveedor');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.producto_precio WHERE producto_id = pruebas.id('P1') AND precio_nuevo_centavos = 1600
    AND NOT incluye_isv_anterior AND NOT incluye_isv_nuevo), 'cambio de precio guarda la marca');
  -- Sin productos.precios no se cambia la marca (aunque pueda editar el producto).
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'admin', 'productos.precios', false, 'Precios solo el dueño');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L, %L)', e, pruebas.id('P1'), '{"precio_incluye_isv": true}', 'Vuelve a con ISV'),
    'SIN_PERMISO', 'marca sin permiso de precios');
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"nombre": "Tornillo de 1/2"}');   -- lo demás sí
  -- Ni a la fuerza sin motivo.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.producto SET precio_incluye_isv = true WHERE id = %L', pruebas.id('P1')), 'FALTA_MOTIVO', 'marca a la fuerza');
END $$;
