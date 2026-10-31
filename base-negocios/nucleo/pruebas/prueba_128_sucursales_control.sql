-- PRUEBA: sucursales y centro de control (cifras a mano): usuario restringido a una sucursal (lecturas RLS y vistas, venta, gasto, turno, ajuste y traslado rechazados fuera de su sucursal; el admin restringido no amplía su alcance); traslado de mercadería entre sucursales con rastro de salida y llegada y recepción confirmada por el destino; precio por sucursal (activable, la venta lo respeta, historial); envío de dinero entre sucursales en tránsito hasta que el destino lo recibe (y anulación antes de recibir); reporte por sucursal y total; vigilancia por empleado; bitácora legible; cerrar sesión a distancia; horario por puesto (el dueño nunca se bloquea); desactivar al instante
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  hoy    date;
  s1     uuid;
  s2     uuid;
  c2     uuid;
  doc    uuid;
  v1     jsonb;
  v2     jsonb;
  op     jsonb;
  op2    jsonb;
  r      jsonb;
  f      jsonb;
  n      bigint;
  t      jsonb;
  dia    text;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  hoy := public.hoy_local(e);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de sucursales');
  SELECT id INTO s1 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  c2 := (public.crear_caja(e, s2, 'Caja Norte', '001')->>'caja_id')::uuid;
  PERFORM pruebas.guardar('CAJA2', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja',
    'nombre', 'Caja Norte', 'caja_id', c2))->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('B3', (public.crear_bodega(e, s2, 'B3', 'Bodega Norte')->>'bodega_id')::uuid);

  -- =========== 1) Usuarios por sucursal ===========
  -- El dueño deja al admin solo en la Norte; el admin (restringido) no amplía su alcance.
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('admin_a'), ARRAY[s2], 'Encargado de la Norte');
  PERFORM pruebas.debe_fallar(format('SELECT public.asignar_sucursales_usuario(%L, %L, ARRAY[%L]::uuid[], %L)', e, pruebas.usuario('dueno_a'), s2, 'Prueba'),
    'PROHIBIDO', 'el dueño siempre ve todo');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.asignar_sucursales_usuario(%L, %L, ARRAY[%L]::uuid[], %L)', e, pruebas.usuario('admin_a'), s1, 'Me amplío'),
    'PROHIBIDO', 'nadie cambia sus propias sucursales');
  PERFORM pruebas.debe_fallar(format('SELECT public.asignar_sucursales_usuario(%L, %L, ARRAY[%L]::uuid[], %L)', e, pruebas.usuario('cajero_a'), s1, 'A la principal'),
    'SUCURSAL_NO_PERMITIDA', 'admin restringido no da una sucursal que no tiene');
  PERFORM pruebas.debe_fallar(format('SELECT public.asignar_sucursales_usuario(%L, %L, ARRAY[]::uuid[], %L)', e, pruebas.usuario('cajero_a'), 'Todas las sucursales'),
    'PROHIBIDO', 'admin restringido no da "todas"');
  r := public.asignar_sucursales_usuario(e, pruebas.usuario('cajero_a'), ARRAY[s2], 'Cajero de la Norte');
  PERFORM pruebas.afirmar(NOT (r->>'todas')::boolean AND jsonb_array_length(r->'sucursales') = 1, 'cajero en la Norte');

  -- Traslado de mercadería a la otra sucursal (dueño): 10 tornillos de B1 a B3 a costo 1,000 c/u.
  PERFORM pruebas.como('dueno_a');
  doc := (public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B3'), hoy,
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10)), gen_random_uuid(), 'Surtir la Norte')->>'documento_id')::uuid;
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.inventario_movimiento m WHERE m.documento_id = doc AND m.bodega_id = pruebas.id('B1') AND m.cantidad = -10) = 1
    AND (SELECT count(*) FROM public.inventario_movimiento m WHERE m.documento_id = doc AND m.bodega_id = pruebas.id('B3') AND m.cantidad = 10 AND m.valor_centavos = 10000) = 1,
    'rastro de salida (B1 -10) y llegada (B3 +10, L 100.00)');
  PERFORM pruebas.afirmar(jsonb_array_length(public.pendientes_entre_sucursales(e)->'mercaderia') = 1, 'traslado por recibir');
  -- El admin de la Norte no saca de la principal (ni ajusta ni traslada desde B1).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L::date, %L::jsonb, gen_random_uuid(), NULL)', e, pruebas.id('B1'), pruebas.id('B3'), hoy,
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))), 'SUCURSAL_NO_PERMITIDA', 'traslado desde una sucursal ajena');
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L::date, %L::jsonb, %L, gen_random_uuid())', e, pruebas.id('B1'), hoy,
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 0)), 'Conteo ajeno'), 'SUCURSAL_NO_PERMITIDA', 'ajuste en sucursal ajena');
  -- La Norte confirma la recepción (una sola vez; reintento = lo mismo).
  r := public.confirmar_recepcion_traslado(doc, pruebas.guardar('REC1', gen_random_uuid()), 'Llegó completo');
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean, 'recepción confirmada');
  PERFORM pruebas.afirmar((public.confirmar_recepcion_traslado(doc, pruebas.id('REC1'))->>'duplicado')::boolean, 'reintento = misma recepción');
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_recepcion_traslado(%L, gen_random_uuid())', doc), 'NO_PERMITIDO', 'no se recibe dos veces');
  PERFORM pruebas.afirmar(jsonb_array_length(public.pendientes_entre_sucursales(e)->'mercaderia') = 0, 'ya no está pendiente');

  -- =========== 4) Precio por sucursal ===========
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.fijar_precio_sucursal(%L, %L, %L, 2000, %L)', e, pruebas.id('P1'), s2, 'Precio Norte'),
    'NO_PERMITIDO', 'apagado hasta que el dueño lo activa');
  PERFORM public.activar_precios_sucursal(e, true, 'Precios distintos en la Norte');
  r := public.fijar_precio_sucursal(e, pruebas.id('P1'), s2, 2000, 'Flete hasta la Norte');
  PERFORM pruebas.afirmar(r->>'origen' = 'sucursal' AND (r->>'precio_centavos')::bigint = 2000, 'precio Norte fijado');
  PERFORM pruebas.afirmar((public.precio_en_sucursal(e, pruebas.id('P1'), s2)->>'precio_centavos')::bigint = 2000
    AND (public.precio_en_sucursal(e, pruebas.id('P1'), s1)->>'precio_centavos')::bigint = 1500, 'Norte 2,000; principal usa el general 1,500');

  -- Ventas (a mano; P1 ISV 15 % incluido):
  --   principal (dueño, caja 001): 1 tornillo = 1,500 (1,304 + ISV 196; costo 1,000) -> ganancia bruta 304
  --   Norte (cajero, caja Norte):  2 tornillos a 2,000 = 4,000 (3,478 + ISV 522; costo 2,000) -> ganancia bruta 1,478
  v1 := public.registrar_venta(e, pruebas.venta('P1', 1) || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L::jsonb, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('caja_id', pruebas.id('CAJA001'))), 'SUCURSAL_NO_PERMITIDA', 'cajero no vende en la principal');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 1500, gen_random_uuid())', e, pruebas.id('CAJA001')),
    'SUCURSAL_NO_PERMITIDA', 'ni abre turno en la principal');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 2) || jsonb_build_object('caja_id', c2), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT precio_unitario_centavos FROM public.venta_linea WHERE venta_id = (v2->>'venta_id')::uuid) = 2000
    AND (SELECT precio_unitario_centavos FROM public.venta_linea WHERE venta_id = (v1->>'venta_id')::uuid) = 1500, 'cada venta con el precio de su sucursal');
  PERFORM pruebas.afirmar((SELECT total_centavos FROM public.venta WHERE id = (v2->>'venta_id')::uuid) = 4000
    AND (SELECT impuesto_centavos FROM public.venta WHERE id = (v2->>'venta_id')::uuid) = 522
    AND (SELECT costo_centavos FROM public.venta WHERE id = (v2->>'venta_id')::uuid) = 2000, 'venta Norte 4,000 (ISV 522, costo 2,000)');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.producto_precio WHERE producto_id = pruebas.id('P1') AND sucursal_id = s2 AND precio_nuevo_centavos = 2000) = 1,
    'historial del precio por sucursal');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.fijar_precio_sucursal(e, pruebas.id('P1'), s2, NULL, 'Se quita el flete');
  PERFORM pruebas.afirmar(public.precio_en_sucursal(e, pruebas.id('P1'), s2)->>'origen' = 'general', 'sin precio propio vuelve al general');

  -- Gasto: el admin de la Norte paga 1,000 de papelería desde la caja Norte (no desde la principal).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L::jsonb, gen_random_uuid())', e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'),
    'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 500, 'descripcion', 'Papel')), 'SUCURSAL_NO_PERMITIDA', 'gasto desde la caja ajena');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA2'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 1000, 'descripcion', 'Papel para facturas'), gen_random_uuid());

  -- Lecturas del admin restringido: solo lo de la Norte (tablas con RLS y vistas del sistema).
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta) = 1 AND (SELECT count(*) FROM public.v_venta) = 1
    AND (SELECT count(*) FROM public.venta_linea) = 1, 'admin ve solo la venta de la Norte');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bodega) = 1 AND (SELECT count(*) FROM public.v_existencia WHERE bodega_id <> pruebas.id('B3')) = 0
    AND (SELECT count(*) FROM public.inventario_saldo WHERE bodega_id = pruebas.id('B1')) = 0, 'solo su bodega');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero WHERE id = pruebas.id('CAJA1'))
    AND EXISTS (SELECT 1 FROM public.cuenta_dinero WHERE id = pruebas.id('BANCO'))
    AND NOT EXISTS (SELECT 1 FROM public.dinero_movimiento WHERE cuenta_dinero_id = pruebas.id('CAJA1')), 'no ve la caja de la principal (sí las de toda la empresa)');

  -- =========== 3) Envío de dinero entre sucursales ===========
  -- Norte -> principal 2,000: CAJA2 4,000 - 1,000 - 2,000 = 1,000; en tránsito 2,000; CAJA1 sigue en 1,500.
  op := public.enviar_dinero_sucursal(e, jsonb_build_object('origen_id', pruebas.id('CAJA2'), 'destino_id', pruebas.id('CAJA1'),
          'monto_centavos', 2000, 'referencia', 'Bolsa 7'), pruebas.guardar('ENV1', gen_random_uuid()));
  PERFORM pruebas.afirmar((public.enviar_dinero_sucursal(e, jsonb_build_object('origen_id', pruebas.id('CAJA2'), 'destino_id', pruebas.id('CAJA1'),
          'monto_centavos', 2000), pruebas.id('ENV1'))->>'duplicado')::boolean, 'reintento = mismo envío');
  PERFORM pruebas.debe_fallar(format('SELECT public.enviar_dinero_sucursal(%L, %L::jsonb, gen_random_uuid())', e, jsonb_build_object('origen_id', pruebas.id('CAJA1'),
    'destino_id', pruebas.id('CAJA2'), 'monto_centavos', 100)), 'SUCURSAL_NO_PERMITIDA', 'no envía desde la caja ajena');
  PERFORM pruebas.debe_fallar(format('SELECT public.recibir_dinero_sucursal(%L, gen_random_uuid())', op->>'operacion_id'),
    'SUCURSAL_NO_PERMITIDA', 'la Norte no recibe lo que va a la principal');
  -- Un segundo envío de 500 se anula antes de recibirse (vuelve a la caja Norte).
  op2 := public.enviar_dinero_sucursal(e, jsonb_build_object('origen_id', pruebas.id('CAJA2'), 'destino_id', pruebas.id('CAJA1'),
          'monto_centavos', 500), gen_random_uuid());
  PERFORM public.anular_operacion_dinero((op2->>'operacion_id')::uuid, 'Se equivocó de monto', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA2') = 1000 AND pruebas.dinero('CAJA1') = 1500, 'tras enviar: Norte 1,000, principal 1,500');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(jsonb_array_length(public.pendientes_entre_sucursales(e)->'dinero') = 1, 'un envío por recibir');
  PERFORM public.recibir_dinero_sucursal((op->>'operacion_id')::uuid, gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.recibir_dinero_sucursal(%L, gen_random_uuid())', op->>'operacion_id'), 'NO_PERMITIDO', 'se recibe una sola vez');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 3500 AND pruebas.dinero('CAJA2') = 1000
    AND (SELECT sum(m.monto_centavos) FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
          WHERE d.nombre = 'Envíos entre sucursales') = 0, 'recibido: principal 3,500; tránsito en 0');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = pruebas.dinero_libros('CAJA1') AND pruebas.dinero('CAJA2') = pruebas.dinero_libros('CAJA2'),
    'rastro = libros');

  -- =========== 2) Reporte por sucursal ===========
  -- Principal: ventas 1,500, sin ISV 1,304, costo 1,000, ganancia 304, dinero 3,500.
  -- Norte: ventas 4,000, sin ISV 3,478, costo 2,000, gastos 1,000, ganancia 478, dinero 1,000.
  -- De toda la empresa: dinero FUERTE 300,000 + BANCO 1,000,000. Total: ventas 5,500, ganancia 782, dinero 1,304,500.
  r := public.reporte_sucursales(e, hoy, hoy);
  SELECT x INTO f FROM jsonb_array_elements(r->'sucursales') x WHERE x->>'codigo' = '001';
  PERFORM pruebas.afirmar((f->>'ventas_centavos')::bigint = 1500 AND (f->>'ventas_sin_isv_centavos')::bigint = 1304 AND (f->>'costo_centavos')::bigint = 1000
    AND (f->>'ganancia_centavos')::bigint = 304 AND (f->>'dinero_centavos')::bigint = 3500, 'principal: ' || f::text);
  SELECT x INTO f FROM jsonb_array_elements(r->'sucursales') x WHERE x->>'codigo' = '002';
  PERFORM pruebas.afirmar((f->>'ventas_centavos')::bigint = 4000 AND (f->>'ventas_sin_isv_centavos')::bigint = 3478 AND (f->>'gastos_centavos')::bigint = 1000
    AND (f->>'ganancia_centavos')::bigint = 478 AND (f->>'dinero_centavos')::bigint = 1000, 'Norte: ' || f::text);
  PERFORM pruebas.afirmar((r->'total'->>'ventas_centavos')::bigint = 5500 AND (r->'total'->>'ganancia_centavos')::bigint = 782
    AND (r->'total'->>'dinero_centavos')::bigint = 1304500 AND jsonb_array_length(r->'sucursales') = 3, 'total: ' || (r->'total')::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((r->'total'->>'ventas_centavos')::bigint = (interno.ventas_del(e, hoy, hoy)->>'total_centavos')::bigint, 'total = ventas de la empresa');
  PERFORM pruebas.como('admin_a');
  r := public.reporte_sucursales(e, hoy, hoy);
  PERFORM pruebas.afirmar(jsonb_array_length(r->'sucursales') = 1 AND (r->'total'->>'ventas_centavos')::bigint = 4000 AND (r->>'restringido')::boolean,
    'el admin restringido ve solo la Norte');

  -- =========== 5) Centro de control ===========
  -- Diferencia de caja: el cajero abre turno en la Norte con fondo 1,000 y cuenta 900 (faltan 100).
  PERFORM pruebas.como('cajero_a');
  t := public.abrir_turno(e, c2, 1000, gen_random_uuid());
  PERFORM public.solicitar_anulacion_venta((v2->>'venta_id')::uuid, 'Cliente se arrepintió', gen_random_uuid());
  PERFORM public.cerrar_turno((t->>'turno_id')::uuid, 900, gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  r := public.vigilancia_empleados(e, hoy, hoy);
  SELECT x INTO f FROM jsonb_array_elements(r->'empleados') x WHERE (x->>'usuario_id')::uuid = pruebas.usuario('cajero_a');
  PERFORM pruebas.afirmar((f->'ventas'->>'cantidad')::integer = 1 AND (f->'ventas'->>'total_centavos')::bigint = 4000 AND (f->>'ganancia_centavos')::bigint = 1478
    AND (f->'anulaciones_pedidas'->>'cantidad')::integer = 1 AND (f->'diferencias_caja'->>'faltante_centavos')::bigint = -100
    AND (f->'diferencias_caja'->>'turnos')::integer = 1 AND jsonb_array_length(f->'horario_uso') = 1
    AND (f->'horario_uso'->0->>'acciones')::integer > 0 AND f->'horario_uso'->0->>'primera' IS NOT NULL, 'vigilancia del cajero: ' || f::text);
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.vigilancia_empleados(%L, %L::date, %L::date)', e, hoy, hoy), 'SIN_PERMISO', 'el cajero no vigila');

  -- Bitácora legible con filtros.
  PERFORM pruebas.como('dueno_a');
  r := public.bitacora_legible(e, jsonb_build_object('usuario_id', pruebas.usuario('cajero_a'), 'tipo', 'ventas', 'desde', hoy, 'hasta', hoy));
  PERFORM pruebas.afirmar((r->>'cantidad')::integer >= 2 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'filas') x WHERE x->>'tipo' <> 'ventas'
      OR (x->>'usuario_id')::uuid <> pruebas.usuario('cajero_a'))
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'filas') x WHERE x->>'texto' LIKE '% creó una venta #%'), 'bitácora del cajero: ' || (r->'filas'->0)::text);
  r := public.bitacora_legible(e, '{"limite": 3}');
  PERFORM pruebas.afirmar((r->>'cantidad')::integer = 3 AND (r->>'siguiente_antes_de') IS NOT NULL
    AND ((public.bitacora_legible(e, jsonb_build_object('limite', 3, 'antes_de', (r->>'siguiente_antes_de')::bigint))->'filas'->0->>'secuencia')::bigint
         < (r->>'siguiente_antes_de')::bigint), 'páginas');

  -- Cerrar sesión a distancia: el admin cierra la del cajero; con su sesión vieja no hace nada; al entrar de nuevo, sí.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_sesion_usuario(%L, %L, %L)', e, pruebas.usuario('dueno_a'), 'Probando'), 'PROHIBIDO', 'el admin no cierra al dueño');
  PERFORM public.cerrar_sesion_usuario(e, pruebas.usuario('cajero_a'), 'Celular perdido');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((public.mi_estado_sesion(e)->>'debe_salir')::boolean, 'la app sabe que debe sacarlo');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L::jsonb, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('caja_id', c2)), 'SESION_CERRADA', 'sesión vieja rechazada');
  PERFORM pruebas.debe_fallar(format('SELECT public.resumen_hoy(%L)', e), 'SESION_CERRADA', 'tampoco consulta');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', pruebas.usuario('cajero_a'), 'role', 'authenticated',
    'iat', extract(epoch FROM now())::bigint + 1)::text, true);   -- entró de nuevo (token nuevo)
  PERFORM pruebas.afirmar(NOT (public.mi_estado_sesion(e)->>'debe_salir')::boolean, 'sesión nueva vale');
  PERFORM public.resumen_hoy(e);

  -- Horario por puesto: el cajero solo trabaja otro día; consultar sí puede. El dueño nunca se bloquea.
  PERFORM pruebas.como('dueno_a');
  dia := (extract(isodow FROM now() AT TIME ZONE (SELECT zona_horaria FROM public.empresa WHERE id = e))::integer % 7 + 1)::text;   -- mañana
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_horario_acceso(%L, %L, %L::jsonb, %L)', e, 'dueno', '{"1":{"desde":"08:00","hasta":"17:00"}}', 'Prueba'),
    'DATO_INVALIDO', 'el dueño no tiene horario');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_horario_acceso(%L, %L, %L::jsonb, %L)', e, 'cajero', '{"1":{"desde":"18:00","hasta":"08:00"}}', 'Prueba'),
    'DATO_INVALIDO', 'desde antes que hasta');
  PERFORM public.configurar_horario_acceso(e, 'cajero', jsonb_build_object(dia, jsonb_build_object('desde', '00:00', 'hasta', '24:00')), 'Solo mañana');
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', pruebas.usuario('cajero_a'), 'role', 'authenticated',
    'iat', extract(epoch FROM now())::bigint + 1)::text, true);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L::jsonb, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('caja_id', c2)), 'FUERA_DE_HORARIO', 'fuera de horario no vende');
  PERFORM pruebas.afirmar(NOT (public.mi_estado_sesion(e)->>'dentro_de_horario')::boolean, 'la app lo avisa');
  PERFORM public.resumen_hoy(e);   -- consultar sí
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_horario_acceso(e, 'cajero', NULL, 'Sin límite de horario');
  -- El dueño (nunca bloqueado) vende 1 tornillo con 10 % de descuento: 1,500 - 150 = 1,350.
  v1 := public.registrar_venta(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'pagos', '[{"forma":"efectivo"}]'::jsonb,
          'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_porcentaje', 10))), gen_random_uuid());
  f := (SELECT x FROM jsonb_array_elements(public.vigilancia_empleados(e, hoy, hoy, pruebas.usuario('dueno_a'))->'empleados') x);
  PERFORM pruebas.afirmar((f->'descuentos'->>'ventas_con_descuento')::integer = 1 AND (f->'ventas'->>'total_centavos')::bigint = 1500 + 1350
    AND (f->'descuentos'->>'total_centavos')::bigint = (SELECT descuento_manual_centavos FROM public.venta WHERE id = (v1->>'venta_id')::uuid)
    AND (f->'descuentos'->>'total_centavos')::bigint > 0, 'descuentos del dueño: ' || f::text);

  -- Desactivar al instante: el vendedor desactivado ya no hace nada.
  PERFORM public.desactivar_usuario_empresa(e, pruebas.usuario('vendedor_a'), 'Ya no trabaja aquí');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L::jsonb, gen_random_uuid())', e, pruebas.venta('P1', 1)), 'NO_PERTENECE', 'desactivado al instante');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta) = 0, 'y no ve nada');

  -- Quitar la restricción: el cajero vuelve a ver toda la empresa.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('admin_a'), ARRAY[]::uuid[], 'Vuelve a toda la empresa');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta) = 3, 'sin restricción ve todo');
END $$;
