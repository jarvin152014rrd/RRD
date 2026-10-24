-- PRUEBA: (0.17.0) fotos de productos: el interruptor empieza APAGADO y solo el dueño lo cambia (con motivo y bitácora; mi_perfil lo dice; la ficha del proveedor también lo pone); Storage (bucket privado fotos-productos con WEBP/JPEG y 1 MB; políticas): la empresa A sube y lee en su carpeta, B no lee ni sube en la carpeta de A, un rol sin productos.editar (vendedor) lee pero no sube ni borra, una ruta de un producto de otra empresa se rechaza, con fotos apagadas nadie lee ni sube; poner_foto_producto pone, cambia y quita con historial (la foto anterior queda), bitácora con motivo e id_operacion (reintento = misma respuesta, sin duplicar), rechazos (sin permiso, apagadas, ruta ajena o mala, producto de otra empresa); v_producto devuelve las rutas; la bitácora queda íntegra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  eb   uuid := pruebas.empresa('B');
  p1   uuid;
  p2   uuid;
  pb   uuid;
  op   uuid := gen_random_uuid();
  r    jsonb;
  r2   jsonb;
  n    bigint;
  ruta text;
  mini text;
  ruta2 text;
  mini2 text;
  b    record;
BEGIN
  PERFORM pruebas.preparar_inventario();
  p1 := pruebas.id('P1');
  p2 := pruebas.id('P2');
  ruta  := e || '/' || p1 || '/a1b2c3d4e5f6.webp';
  mini  := e || '/' || p1 || '/a1b2c3d4e5f6_mini.webp';
  ruta2 := e || '/' || p1 || '/ffee00112233.jpg';
  mini2 := e || '/' || p1 || '/ffee00112233_mini.jpg';

  -- Producto de la empresa B (para probar rutas ajenas).
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (eb, 'inventario') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('dueno_b');
  pb := (public.crear_producto(eb, '{"codigo": "B-1", "nombre": "Producto de B", "precio_venta_centavos": 100}', gen_random_uuid())->>'producto_id')::uuid;

  -- ---------------- Bucket ----------------
  PERFORM pruebas.como('superusuario');
  SELECT * INTO b FROM storage.buckets WHERE id = 'fotos-productos';
  PERFORM pruebas.afirmar(b.id IS NOT NULL AND b.public = false AND b.file_size_limit = 1048576
    AND b.allowed_mime_types @> ARRAY['image/webp', 'image/jpeg'] AND NOT b.allowed_mime_types @> ARRAY['image/svg+xml'], 'bucket privado, WEBP/JPEG, 1 MB');
  PERFORM pruebas.afirmar((public.estado_fotos_storage()->>'listo')::boolean AND public.estado_fotos_storage()->>'texto' = 'LISTO', 'estado LISTO');
  PERFORM pruebas.afirmar((SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'fotos_productos_%') = 4, '4 políticas');

  -- ---------------- Interruptor ----------------
  PERFORM pruebas.afirmar(NOT (SELECT fotos_productos FROM public.empresa WHERE id = e), 'apagado por defecto');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((public.mi_perfil(e)->'empresa'->>'fotos_productos')::boolean = false, 'mi_perfil dice apagado');
  -- Apagadas: el dueño no sube a Storage ni pone la foto.
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (%L, %L, %L)',
    'fotos-productos', ruta, '{"mimetype":"image/webp","size":100}'), '42501', 'subir con fotos apagadas');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, gen_random_uuid())', e, p1,
    jsonb_build_object('ruta', ruta, 'miniatura', mini)), 'FOTOS_APAGADAS', 'poner con fotos apagadas');
  -- Solo el dueño lo cambia, con motivo.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.activar_fotos_productos(%L, true, %L)', e, 'Quiero fotos'), 'SIN_PERMISO', 'admin no enciende');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.activar_fotos_productos(%L, true, %L)', e, 'no'), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.activar_fotos_productos(%L, true, %L)', eb, 'Encender fotos'), 'NO_PERTENECE', 'empresa ajena');
  r := public.activar_fotos_productos(e, true, 'Encender fotos de productos');
  PERFORM pruebas.afirmar((r->>'fotos_productos')::boolean AND (r->'storage'->>'listo')::boolean, 'encendido: ' || r::text);
  PERFORM pruebas.afirmar((public.mi_perfil(e)->'empresa'->>'fotos_productos')::boolean, 'mi_perfil dice encendido');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'empresa' AND accion = 'UPDATE'
    AND motivo = 'Encender fotos de productos' AND (despues->>'fotos_productos')::boolean AND NOT (antes->>'fotos_productos')::boolean), 'bitácora del interruptor');

  -- ---------------- Políticas de Storage ----------------
  PERFORM pruebas.como('dueno_a');
  INSERT INTO storage.objects (bucket_id, name, metadata) VALUES
    ('fotos-productos', ruta, '{"mimetype":"image/webp","size":40000}'),
    ('fotos-productos', mini, '{"mimetype":"image/webp","size":8000}');
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos') = 2, 'A lee lo suyo');
  -- Ruta de un producto de otra empresa (o un producto que no existe) dentro de su carpeta: no.
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    e || '/' || pb || '/a1b2c3d4e5f6.webp'), '42501', 'producto de B en la carpeta de A');
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    e || '/' || gen_random_uuid() || '/a1b2c3d4e5f6.webp'), '42501', 'producto que no existe');
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    e || '/' || p1 || '/script.svg'), '42501', 'extensión svg');
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    e || '/a1b2c3d4e5f6.webp'), '42501', 'ruta sin producto');
  -- Empresa B: no lee, no sube, no cambia ni borra en la carpeta de A.
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos') = 0, 'B no ve las fotos de A');
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    e || '/' || p1 || '/bbbbbbbbbbbb.webp'), '42501', 'B no sube en la carpeta de A');
  UPDATE storage.objects SET metadata = '{"x":1}' WHERE bucket_id = 'fotos-productos';
  DELETE FROM storage.objects WHERE bucket_id = 'fotos-productos';
  -- B en su propia carpeta, con fotos apagadas en B: tampoco.
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    eb || '/' || pb || '/bbbbbbbbbbbb.webp'), '42501', 'B con fotos apagadas');
  -- Vendedor de A (sin productos.editar): lee, pero no sube, ni cambia, ni borra.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('productos.editar', e), 'el vendedor no tiene productos.editar');
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos') = 2, 'vendedor lee');
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    e || '/' || p2 || '/cccccccccccc.webp'), '42501', 'vendedor no sube');
  UPDATE storage.objects SET metadata = '{"x":1}' WHERE bucket_id = 'fotos-productos';
  DELETE FROM storage.objects WHERE bucket_id = 'fotos-productos';
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, gen_random_uuid())', e, p1,
    jsonb_build_object('ruta', ruta, 'miniatura', mini)), 'SIN_PERMISO', 'vendedor no pone la foto');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos' AND metadata ? 'x') = 0
    AND (SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos') = 2, 'ni B ni el vendedor cambiaron o borraron');
  -- El admin (tiene productos.editar) sí sube.
  PERFORM pruebas.como('admin_a');
  INSERT INTO storage.objects (bucket_id, name) VALUES ('fotos-productos', ruta2), ('fotos-productos', mini2);

  -- ---------------- Poner, cambiar y quitar la foto ----------------
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, gen_random_uuid())', e, p1,
    jsonb_build_object('ruta', ruta, 'miniatura', ruta)), 'FOTO_INVALIDA', 'misma ruta para las dos');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, gen_random_uuid())', e, p1,
    jsonb_build_object('ruta', e || '/' || p2 || '/a1b2c3d4e5f6.webp', 'miniatura', mini)), 'FOTO_INVALIDA', 'ruta de otro producto');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, gen_random_uuid())', e, p1,
    jsonb_build_object('ruta', 'https://otro.sitio/x.webp', 'miniatura', mini)), 'FOTO_INVALIDA', 'ruta externa');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, gen_random_uuid())', e, p1,
    jsonb_build_object('ruta', ruta, 'miniatura', mini, 'otra', 1)), 'DATO_INVALIDO', 'clave desconocida');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, gen_random_uuid())', e, pb,
    jsonb_build_object('ruta', ruta, 'miniatura', mini)), 'NO_EXISTE', 'producto de otra empresa');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, NULL, gen_random_uuid())', e, p1), 'DATO_INVALIDO', 'quitar sin foto');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, %L, NULL)', e, p1,
    jsonb_build_object('ruta', ruta, 'miniatura', mini)), 'FALTA_ID_OPERACION', 'sin id_operacion');

  r := public.poner_foto_producto(e, p1, jsonb_build_object('ruta', ruta, 'miniatura', mini), op);
  PERFORM pruebas.afirmar(r->>'foto_ruta' = ruta AND NOT (r->>'duplicado')::boolean AND r->>'anterior_foto_ruta' IS NULL, 'puesta: ' || r::text);
  r2 := public.poner_foto_producto(e, p1, jsonb_build_object('ruta', ruta, 'miniatura', mini), op);
  PERFORM pruebas.afirmar((r2->>'duplicado')::boolean AND r2->>'historial_id' = r->>'historial_id', 'reintento = misma respuesta');
  PERFORM pruebas.debe_fallar(format('SELECT public.poner_foto_producto(%L, %L, NULL, %L)', e, p1,
    (SELECT id_operacion FROM public.producto WHERE id = p2)), 'ID_OPERACION_USADO', 'id ya usado en otra cosa');
  PERFORM pruebas.afirmar((SELECT foto_ruta = ruta AND foto_miniatura_ruta = mini FROM public.v_producto WHERE producto_id = p1), 'v_producto trae las rutas');
  PERFORM pruebas.afirmar((SELECT foto_ruta IS NULL FROM public.v_producto WHERE producto_id = p2), 'sin foto: null');
  -- Cambiar: la anterior queda en el historial.
  r := public.poner_foto_producto(e, p1, jsonb_build_object('ruta', ruta2, 'miniatura', mini2), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'foto_ruta' = ruta2 AND r->>'anterior_foto_ruta' = ruta, 'cambiada: ' || r::text);
  -- Quitar (se puede aunque las fotos estén apagadas).
  PERFORM public.activar_fotos_productos(e, false, 'Apagar las fotos un rato');
  r := public.poner_foto_producto(e, p1, NULL, gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'quitada')::boolean AND r->>'anterior_foto_ruta' = ruta2, 'quitada');
  PERFORM pruebas.afirmar((SELECT foto_ruta IS NULL AND foto_miniatura_ruta IS NULL FROM public.producto WHERE id = p1), 'producto sin foto');
  -- Apagadas: nadie de A lee (ni el dueño) ni sube; borrar sí (limpieza).
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos') = 0, 'apagadas: no se leen');
  PERFORM pruebas.debe_fallar(format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', 'fotos-productos',
    e || '/' || p2 || '/dddddddddddd.webp'), '42501', 'apagadas: no se sube');
  PERFORM public.activar_fotos_productos(e, true, 'Encender otra vez');
  DELETE FROM storage.objects WHERE bucket_id = 'fotos-productos' AND name = ruta;
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos') = 3, 'el dueño borra');

  -- Historial y bitácora (nada se borra; el producto registra cada cambio con motivo).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.producto_foto WHERE producto_id = p1) = 3, 'historial: 3 cambios');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.producto_foto WHERE producto_id = %L', p1), 'no se borra', 'historial no se borra');
  PERFORM pruebas.debe_fallar(format('UPDATE public.producto_foto SET foto_ruta = NULL WHERE producto_id = %L', p1), 'no se edita', 'historial no se edita');
  SELECT count(*) INTO n FROM public.bitacora WHERE empresa_id = e AND tabla = 'producto' AND accion = 'UPDATE'
     AND registro_id = p1::text AND (antes->>'foto_ruta') IS DISTINCT FROM (despues->>'foto_ruta');
  PERFORM pruebas.afirmar(n = 3, 'bitácora del producto: 3 cambios de foto, hay ' || n);
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'producto' AND registro_id = p1::text
    AND motivo = 'Quitar la foto del producto' AND antes->>'foto_ruta' = ruta2 AND despues->>'foto_ruta' IS NULL), 'bitácora de quitar');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'producto_foto' AND id_operacion = op), 'bitácora con id_operacion');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
  -- La B no ve el historial de A.
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.producto_foto) = 0, 'B no ve el historial de A');
  -- anon: nada.
  PERFORM pruebas.como('anon');
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects) = 0, 'anon no ve nada');
END $$;

-- La ficha del proveedor también enciende o apaga las fotos (opciones.fotos_productos).
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  v jsonb;
BEGIN
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT fotos_productos FROM public.empresa WHERE id = e), 'quedó encendido arriba');
  PERFORM pruebas.como('service_role');
  v := public.vista_previa_ficha(e, '{"opciones": {"fotos_productos": false}}');
  PERFORM pruebas.afirmar((v->>'hay_cambios')::boolean AND (v->'opciones'->'fotos_productos'->>'actual')::boolean
    AND NOT (v->'opciones'->'fotos_productos'->>'nuevo')::boolean, 'vista previa: ' || v::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.vista_previa_ficha(%L, %L)', e, '{"opciones": {"fotos": true}}'), 'DATO_INVALIDO', 'opción desconocida');
  PERFORM pruebas.debe_fallar(format('SELECT public.vista_previa_ficha(%L, %L)', e, '{"opciones": {"fotos_productos": "si"}}'), 'DATO_INVALIDO', 'opción no booleana');
  PERFORM public.aplicar_ficha(e, '{"opciones": {"fotos_productos": false}}', 'Ficha del cliente: sin fotos');
  PERFORM pruebas.afirmar(NOT (SELECT fotos_productos FROM public.empresa WHERE id = e), 'la ficha apagó');
  v := public.vista_previa_ficha(e, '{"opciones": {"fotos_productos": false}}');
  PERFORM pruebas.afirmar(NOT (v->>'hay_cambios')::boolean, 'ya está: sin cambios');
  PERFORM public.aplicar_ficha(e, '{"opciones": {"fotos_productos": true}, "perfil": null}', 'Ficha del cliente: con fotos');
  PERFORM pruebas.afirmar((SELECT fotos_productos FROM public.empresa WHERE id = e), 'la ficha encendió');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'empresa' AND motivo = 'Ficha del cliente: sin fotos'), 'bitácora de la ficha');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
