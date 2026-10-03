-- PRUEBA: gastos (cifras a mano): sale de la cuenta de dinero elegida a su categoría con ISV crédito fiscal (solo con factura y RTN); todo o nada; sobre el tope del puesto queda pendiente SIN mover dinero; aprobación genérica con tope del aprobador, nunca la propia, rechazo con motivo; anular y cancelar; mes cerrado; quién ve qué
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  g1   jsonb; g2 jsonb; g3 jsonb; g4 jsonb; g5 jsonb; g6 jsonb;
  r    jsonb;
  op   uuid := gen_random_uuid();
  n    bigint;
BEGIN
  -- Un contador (solo lectura) para ver qué ve.
  INSERT INTO auth.users (email) VALUES ('contador@prueba.hn');
  INSERT INTO pruebas.usuario (apodo, id) SELECT 'contador', id FROM auth.users WHERE email = 'contador@prueba.hn';
  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol) VALUES (pruebas.usuario('contador'), e, 'contador');
  PERFORM pruebas.preparar_dinero();
  -- Inicio: BAC 1,000,000. Tope del admin (plantilla): registra sin aprobación y aprueba hasta 500,000.

  -- 1) Gasto de luz del admin: total 115,000 con ISV 15,000 (factura F-1001).
  --    Asiento: Dr 6.1.02.02 100,000 + Dr 1.1.04.01 15,000 / Cr BAC 115,000. BAC 885,000.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 115000, 'isv_centavos', 15000,
    'descripcion', 'Luz')), 'factura', 'ISV sin factura');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 1000, 'isv_centavos', 1000,
    'descripcion', 'Luz', 'documento', jsonb_build_object('numero', 'X', 'rtn', '08011999000123'))), 'menor que el total', 'ISV igual al total');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 1000)), 'FALTA_DESCRIPCION', 'sin descripción');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', gen_random_uuid(), 'monto_centavos', 1000, 'descripcion', 'X')), 'categoría', 'categoría inventada');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 1000, 'descripcion', 'X',
    'documento', jsonb_build_object('numero', 'X', 'rtn', '0801-123'))), 'RTN_INVALIDO', 'RTN corto');
  g1 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 115000, 'isv_centavos', 15000, 'descripcion', 'Energía de enero', 'fecha', '2026-01-15',
    'documento', jsonb_build_object('numero', 'F-1001', 'fecha', '2026-01-14', 'rtn', '0801-1999-000123'),
    'comprobante', pruebas.comprobante('luz-enero.jpg')), op);
  PERFORM pruebas.afirmar(g1->>'estado' = 'aplicado' AND (g1->>'saldo_cuenta_centavos')::bigint = 885000, 'gasto aplicado: ' || g1::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '6.1.02.02') = 100000 AND pruebas.saldo_libros(e, '1.1.04.01') = 15000
    AND pruebas.dinero('BANCO') = 885000 AND pruebas.dinero_libros('BANCO') = 885000, 'asiento del gasto');
  PERFORM pruebas.afirmar((public.registrar_gasto(e, '{}', op)->>'duplicado')::boolean, 'reintento');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_gasto(%L, %L, %L)', g1->>'gasto_id', 'Otro motivo', op), 'ID_OPERACION_USADO', 'id del gasto para anular');

  -- 2) Alquiler de 600,000 > tope 500,000: queda pendiente y NO mueve dinero.
  g2 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_ALQ'),
    'monto_centavos', 600000, 'descripcion', 'Alquiler de enero', 'fecha', '2026-01-16'), gen_random_uuid());
  PERFORM pruebas.afirmar(g2->>'estado' = 'pendiente_aprobacion' AND g2->>'asiento_id' IS NULL AND pruebas.dinero('BANCO') = 885000,
    'pendiente sin mover dinero');
  PERFORM pruebas.afirmar((SELECT estado || '/' || tipo || '/' || monto_centavos FROM public.aprobacion WHERE id = (g2->>'aprobacion_id')::uuid)
    = 'pendiente/gasto/600000', 'solicitud de aprobación');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, NULL, gen_random_uuid())', g2->>'aprobacion_id'), 'PROHIBIDO', 'aprobar lo propio');
  -- El dueño aprueba: BAC 885,000 - 600,000 = 285,000.
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((g2->>'aprobacion_id')::uuid, true, NULL, gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicado' AND r->>'aprobacion_estado' = 'aprobada' AND pruebas.dinero('BANCO') = 285000, 'aprobado por el dueño');
  PERFORM pruebas.afirmar((SELECT fecha_contable FROM public.asiento WHERE id = (r->>'asiento_id')::uuid) = '2026-01-16', 'con la fecha del gasto');

  -- 3) El dueño da gastos.registrar al cajero (tope 0: todo suyo pide aprobación).
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'gastos.registrar', true, 'El cajero registra gastos');
  PERFORM pruebas.como('cajero_a');
  g3 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 30000, 'descripcion', 'Resmas de papel', 'fecha', '2026-01-17'), gen_random_uuid());
  PERFORM pruebas.afirmar(g3->>'estado' = 'pendiente_aprobacion', 'cajero: pendiente');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, NULL, gen_random_uuid())', g3->>'aprobacion_id'), 'SIN_PERMISO', 'cajero aprueba');
  PERFORM pruebas.como('admin_a');
  PERFORM public.resolver_aprobacion((g3->>'aprobacion_id')::uuid, true, 'Comprado para la oficina', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 255000, 'BAC 255,000');

  -- 4) 550,000 del cajero: el admin no lo aprueba (su tope es 500,000); rechazar pide motivo; el dueño lo rechaza.
  PERFORM pruebas.como('cajero_a');
  g4 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 550000, 'descripcion', 'Impresora', 'fecha', '2026-01-18'), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, NULL, gen_random_uuid())', g4->>'aprobacion_id'), 'TOPE_APROBACION', 'sobre el tope del admin');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, false, NULL, gen_random_uuid())', g4->>'aprobacion_id'), 'FALTA_MOTIVO', 'rechazo sin motivo');
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((g4->>'aprobacion_id')::uuid, false, 'No hay presupuesto este mes', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'rechazado' AND r->>'aprobacion_estado' = 'rechazada' AND pruebas.dinero('BANCO') = 255000, 'rechazado sin mover dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, NULL, gen_random_uuid())', g4->>'aprobacion_id'), 'YA_RESUELTO', 'resolver dos veces');

  -- 5) Todo o nada: 300,000 cuando el BAC tiene 255,000 -> no se guarda nada.
  PERFORM pruebas.como('admin_a');
  n := (SELECT count(*) FROM public.gasto);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 300000, 'descripcion', 'Muebles')),
    'SALDO_INSUFICIENTE', 'sin fondos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.gasto) = n, 'no quedó el gasto');

  -- 6) Anular el gasto de luz: el dinero vuelve al BAC (370,000) y el ISV y el gasto quedan en 0.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_gasto(%L, %L, gen_random_uuid(), %L)', g1->>'gasto_id', 'Factura duplicada', '2026-01-14'),
    'FECHA_INVALIDA', 'anular antes del gasto');
  r := public.anular_gasto((g1->>'gasto_id')::uuid, 'Factura duplicada', gen_random_uuid(), '2026-01-20');
  PERFORM pruebas.afirmar(r->>'estado' = 'anulado' AND pruebas.dinero('BANCO') = 370000
    AND pruebas.saldo_libros(e, '6.1.02.02') = 0 AND pruebas.saldo_libros(e, '1.1.04.01') = 0, 'gasto anulado');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_gasto(%L, %L, gen_random_uuid())', g1->>'gasto_id', 'Otra vez'), 'YA_ANULADO', 'anular dos veces');

  -- 7) El cajero cancela su propia solicitud pendiente.
  PERFORM pruebas.como('cajero_a');
  g5 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 40000, 'descripcion', 'Tinta'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_gasto(%L, %L, gen_random_uuid())', g3->>'gasto_id', 'Ya no lo quiero'), 'SIN_PERMISO', 'cajero anula uno aplicado');
  r := public.anular_gasto((g5->>'gasto_id')::uuid, 'Ya no hace falta', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'anulado' AND (SELECT estado FROM public.aprobacion WHERE id = (g5->>'aprobacion_id')::uuid) = 'cancelada',
    'solicitud cancelada');

  -- 8) Topes: solo el dueño los cambia; el dueño no tiene tope.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_tope_rol(%L, %L, %L, 0, 0, %L)', e, 'admin', 'gasto', 'Bajar el tope'), 'SIN_PERMISO', 'admin cambia topes');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_tope_rol(%L, %L, %L, 0, 0, %L)', e, 'dueno', 'gasto', 'Tope al dueño'), 'DATO_INVALIDO', 'tope al dueño');
  PERFORM public.configurar_tope_rol(e, 'admin', 'gasto', 0, 500000, 'Todo gasto del admin pide aprobación');
  PERFORM pruebas.como('admin_a');
  g6 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 100, 'descripcion', 'Clips', 'fecha', '2026-01-20'), gen_random_uuid());
  PERFORM pruebas.afirmar(g6->>'estado' = 'pendiente_aprobacion', 'con tope 0 queda pendiente');

  -- 9) Quién ve qué: el cajero solo lo suyo; el contador todo; el vendedor nada.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_gasto) = 3 AND (SELECT count(*) FROM public.v_aprobacion) = 3, 'cajero ve lo suyo');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_gasto) = 6 AND (SELECT count(*) FROM public.v_aprobacion) = 5, 'contador ve todo');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 1, 'descripcion', 'X')), 'SIN_PERMISO', 'contador registra');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_gasto) = 0 AND (SELECT count(*) FROM public.aprobacion) = 0, 'vendedor no ve gastos');

  -- 10) Mes cerrado: el dueño cierra enero; la solicitud de enero se aprueba con fecha de febrero.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cerrar_periodo(e, 2026, 1);
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, NULL, gen_random_uuid())', g6->>'aprobacion_id'), 'PERIODO_CERRADO', 'aprobar en mes cerrado');
  r := public.resolver_aprobacion((g6->>'aprobacion_id')::uuid, true, NULL, gen_random_uuid(), '2026-02-02');
  -- BAC 370,000 - 100 = 369,900.
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicado' AND pruebas.dinero('BANCO') = 369900
    AND (SELECT fecha_contable FROM public.gasto WHERE id = (g6->>'gasto_id')::uuid) = '2026-02-02', 'aprobado en febrero');

  -- Defensas de tabla, rastro = libros y bitácora.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.gasto SET monto_centavos = 1 WHERE id = %L', g3->>'gasto_id'), 'PROHIBIDO', 'editar un gasto');
  PERFORM pruebas.debe_fallar(format('UPDATE public.aprobacion SET estado = %L WHERE id = %L', 'pendiente', g4->>'aprobacion_id'), 'PROHIBIDO', 'reabrir una aprobación');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.gasto WHERE id = %L', g4->>'gasto_id'), 'PROHIBIDO', 'borrar un gasto');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.adjunto WHERE documento_tipo = 'gasto' AND documento_id = (g1->>'gasto_id')::uuid) = 1, 'comprobante del gasto');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)), 'rastro = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
