-- PRUEBA: (0.16.0) aporte de capital de un socio (cifras a mano): registrar con socio, monto, cuenta que recibe, fecha y nota; asiento NIIF Dr cuenta de dinero / Cr 3.1.01.04 Aportes de socios con rastro del dinero; el estado de resultados NO cambia (no es ganancia) y el flujo de efectivo lo muestra como entrada; ¿dónde está mi dinero? sube; lectura por socio con cuadre; doble envío con el mismo id_operacion; anular con motivo (contra-asiento, nada se borra) y sin dinero suficiente no; rechazos (sin permiso, sin motivo, socio inactivo, monto cero, sucursal ajena, sin el módulo); la cuenta no acepta asientos manuales; todos los asientos cuadran
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  sa    uuid;
  sb    uuid;
  sc    uuid;
  s1    uuid;
  s2    uuid;
  bn    uuid;
  bp    uuid;
  r     jsonb;
  r2    jsonb;
  op    uuid;
  ap1   uuid;
  ap2   uuid;
  er0   jsonb;
  er1   jsonb;
  dd0   jsonb;
  n     bigint;
BEGIN
  PERFORM pruebas.crear_contador();
  PERFORM pruebas.preparar_enero();
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', gen_random_uuid(), 'monto_centavos', 100, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'MODULO_INACTIVO', 'sin el módulo fondos');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fondos');
  PERFORM pruebas.como('dueno_a');
  sa := (public.guardar_socio(e, jsonb_build_object('user_id', pruebas.usuario('dueno_a'), 'porcentaje', 60), 'Socio fundador')->>'socio_id')::uuid;
  sb := (public.guardar_socio(e, jsonb_build_object('tercero_id', (public.crear_tercero(e, '{"nombre": "Ana Socia", "es_proveedor": true}',
          gen_random_uuid())->>'tercero_id')::uuid, 'porcentaje', 40), 'Socia inversionista')->>'socio_id')::uuid;
  sc := (public.guardar_socio(e, jsonb_build_object('tercero_id', (public.crear_tercero(e, '{"nombre": "Pedro Retirado", "es_proveedor": true}',
          gen_random_uuid())->>'tercero_id')::uuid, 'porcentaje', 10, 'activo', false), 'Socio que ya salió')->>'socio_id')::uuid;
  PERFORM pruebas.afirmar((SELECT nombre FROM public.cuenta WHERE empresa_id = e AND codigo = '3.1.01.04') = 'Aportes de socios', 'cuenta 3.1.01.04');

  -- Foto de febrero antes del aporte.
  er0 := public.estado_resultados(e, 2026, 2) - 'generado_en';
  dd0 := public.donde_esta_mi_dinero(e);

  -- ===== Registrar: Ana mete L 5,000.00 al BANCO el 10/02 =====
  -- Asiento: Dr BANCO 500,000 / Cr 3.1.01.04 500,000. BANCO 888,500 + 500,000 = 1,388,500.
  op := gen_random_uuid();
  r := public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 500000, 'cuenta_dinero_id', pruebas.id('BANCO'),
         'fecha', '2026-02-10', 'nota', 'Capital para mercadería', 'referencia', 'Depósito 7788'), op);
  ap1 := (r->>'aporte_id')::uuid;
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean AND (r->>'monto_centavos')::bigint = 500000 AND r->>'socio' = 'Ana Socia'
    AND r->>'cuenta_capital' = '3.1.01.04' AND (r->>'aportado_socio_centavos')::bigint = 500000 AND r->>'fecha' = '2026-02-10', 'aporte: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 1388500 AND pruebas.dinero_libros('BANCO') = 1388500
    AND pruebas.saldo_libros(e, '3.1.01.04') = 500000, 'libros y rastro del banco');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.dinero_movimiento WHERE documento_id = ap1 AND operacion = 'aporte_socio' AND monto_centavos = 500000) = 1,
    'rastro del dinero: entrada por aporte');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ',' ORDER BY l.linea)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = (r->>'asiento_id')::uuid)
    = (SELECT c.codigo FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = pruebas.id('BANCO')) || ':500000/0,3.1.01.04:0/500000',
    'asiento Dr banco / Cr aportes de socios');
  PERFORM pruebas.como('dueno_a');
  -- Doble envío: el mismo id = el mismo aporte.
  r2 := public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 500000, 'cuenta_dinero_id', pruebas.id('BANCO'),
         'fecha', '2026-02-10', 'nota', 'Capital para mercadería'), op);
  PERFORM pruebas.afirmar((r2->>'duplicado')::boolean AND r2->>'aporte_id' = ap1::text AND pruebas.dinero('BANCO') = 1388500, 'reintento = el mismo aporte');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, %L)', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 100, 'cuenta_dinero_id', pruebas.id('BANCO')), (SELECT id_operacion FROM public.gasto LIMIT 1)),
    'ID_OPERACION_USADO', 'el id de otra operación (un gasto) no sirve');

  -- ===== No es ganancia: el estado de resultados de febrero no cambia; el flujo sí lo muestra =====
  er1 := public.estado_resultados(e, 2026, 2) - 'generado_en';
  PERFORM pruebas.afirmar(er1 = er0, 'el estado de resultados no cambió con el aporte');
  r2 := public.flujo_efectivo(e, 2026, 2);
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r2->'entradas') x WHERE x->>'tipo' = 'aporte_socio'
    AND x->>'nombre' = 'Aportes de capital de socios' AND (x->>'monto_centavos')::bigint = 500000) AND (r2->>'cuadra')::boolean, 'flujo: ' || (r2->'entradas')::text);
  r2 := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.afirmar((r2->>'total_centavos')::bigint = (dd0->>'total_centavos')::bigint + 500000, '¿dónde está mi dinero? sube 500,000');

  -- ===== Segundo aporte (del dueño, a la caja fuerte) y lectura por socio =====
  ap2 := (public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sa, 'monto_centavos', 150000, 'cuenta_dinero_id', pruebas.id('FUERTE'),
           'fecha', '2026-02-11'), gen_random_uuid())->>'aporte_id')::uuid;
  r := public.aportes_socios(e);
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 650000 AND (r->>'libros_centavos')::bigint = 650000 AND (r->>'cuadra')::boolean
    AND (SELECT string_agg((x->>'nombre') || '=' || (x->>'aportado_centavos'), ',' ORDER BY x->>'nombre') FROM jsonb_array_elements(r->'socios') x)
        = 'Ana Socia=500000,Dueño A=150000,Pedro Retirado=0'
    AND jsonb_array_length(r->'aportes') = 2 AND (r->'aportes'->0->>'aporte_id')::uuid = ap2, 'lectura por socio: ' || r::text);
  PERFORM pruebas.afirmar((public.aportes_socios(e, sb)->>'total_centavos')::bigint = 500000, 'lectura de un socio');
  r := public.aportes_socios(e, NULL, '2026-02-11', '2026-02-28');
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 150000 AND jsonb_array_length(r->'aportes') = 1 AND r->>'libros_centavos' IS NULL
    AND r->>'desde' = '2026-02-11', 'lectura por fechas: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.aportes_socios(%L, NULL, %L, %L)', e, '2026-03-01', '2026-02-01'), 'FECHA_INVALIDA', 'fechas al revés');

  -- ===== Rechazos =====
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sc, 'monto_centavos', 1000, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'DATO_INVALIDO', 'socio desactivado');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 0, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'DATO_INVALIDO', 'monto cero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', -5, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'DATO_INVALIDO', 'monto negativo');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, NULL)', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 1000, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'FALTA_ID_OPERACION', 'sin id_operacion');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 1000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'otra', 1)), 'DATO_INVALIDO', 'clave desconocida');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-02-20', pruebas.lineas('3.3.01.01', '3.1.01.04', 100)), 'CUENTA_CONTROLADA', 'aportes sin asiento manual');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 1000, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'SIN_PERMISO', 'admin sin el permiso');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, %L, gen_random_uuid())', ap1, 'No era aporte'), 'SIN_PERMISO', 'admin no anula');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 1000, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'SIN_PERMISO', 'contador no registra');
  PERFORM pruebas.afirmar((public.aportes_socios(e)->>'total_centavos')::bigint = 650000, 'el contador lee los aportes');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.aportes_socios(%L)', e), 'SIN_PERMISO', 'vendedor no lee aportes');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.socio_aporte) = 0, 'vendedor no ve la tabla');

  -- ===== Sucursal: el admin (con el permiso que le da el dueño) limitado a la Norte =====
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'contador', 'fondos.aportes', 'Darle aportes'),
    'PROHIBIDO', 'el contador no recibe permisos de movimiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'cajero', 'fondos.aportes', 'Darle aportes'),
    'solo del dueño y del administrador', 'el cajero no recibe fondos.aportes');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'vendedor', 'fondos.aportes', 'Darle aportes'),
    'PROHIBIDO', 'el vendedor tampoco');
  PERFORM public.cambiar_permiso_rol(e, 'admin', 'fondos.aportes', true, 'El admin registra aportes de la Norte');
  SELECT id INTO s1 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  bn := (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'banco', 'nombre', 'Banco Norte', 'banco', 'Atlántida',
    'numero_cuenta', '4444-5555-6666', 'tipo_cuenta', 'cheques', 'sucursal_id', s2))->>'cuenta_dinero_id')::uuid;
  bp := (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'banco', 'nombre', 'Banco principal', 'banco', 'BAC',
    'numero_cuenta', '1111-2222-3333', 'tipo_cuenta', 'cheques', 'sucursal_id', s1))->>'cuenta_dinero_id')::uuid;
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('admin_a'), ARRAY[s2], 'Encargado de la Norte');
  PERFORM public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 20000, 'cuenta_dinero_id', bp, 'fecha', '2026-02-12'), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 1000, 'cuenta_dinero_id', bp)), 'SUCURSAL_NO_PERMITIDA', 'banco de otra sucursal');
  r := public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 30000, 'cuenta_dinero_id', bn, 'fecha', '2026-02-12'), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'monto_centavos')::bigint = 30000, 'aporte en su sucursal');
  PERFORM pruebas.afirmar((SELECT sucursal_id FROM public.asiento WHERE id = (r->>'asiento_id')::uuid) = s2, 'el asiento es de la Norte');
  -- Lee solo lo de su sucursal (y lo de toda la empresa: BANCO y FUERTE no tienen sucursal), sin el cuadre de libros.
  r := public.aportes_socios(e);
  PERFORM pruebas.afirmar((r->>'solo_mis_sucursales')::boolean AND r->>'libros_centavos' IS NULL
    AND (r->>'total_centavos')::bigint = 500000 + 150000 + 30000 AND jsonb_array_length(r->'aportes') = 3, 'limitado: ' || r::text);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.socio_aporte) = 3, 'RLS: no ve el aporte del banco principal');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, %L, gen_random_uuid())',
    (SELECT id FROM public.socio_aporte x WHERE x.cuenta_dinero_id = bp LIMIT 1), 'No era aporte'), 'NO_EXISTE', 'no ve (ni anula) el de otra sucursal');
  PERFORM pruebas.como('superusuario');
  ap2 := (SELECT id FROM public.socio_aporte x WHERE x.cuenta_dinero_id = bp);
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, %L, gen_random_uuid())', ap2, 'No era aporte'),
    'SUCURSAL_NO_PERMITIDA', 'anular en otra sucursal');

  -- ===== Anular =====
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, %L, gen_random_uuid())', ap1, 'no'), 'FALTA_MOTIVO', 'motivo corto');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, NULL, gen_random_uuid())', ap1), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, %L, gen_random_uuid(), %L)', ap1, 'Era un préstamo', '2026-02-09'),
    'FECHA_INVALIDA', 'antes del aporte');
  op := gen_random_uuid();
  r := public.anular_aporte_socio(ap1, 'Era un préstamo, no un aporte', op, '2026-02-15');
  PERFORM pruebas.afirmar((r->>'anulada')::boolean AND NOT (r->>'duplicado')::boolean AND (r->>'aportado_socio_centavos')::bigint = 20000 + 30000,
    'anulado: ' || r::text);
  -- BANCO 1,388,500 - 500,000 = 888,500. Aportes en libros: 650,000 + 20,000 + 30,000 - 500,000 = 200,000.
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 888500 AND pruebas.saldo_libros(e, '3.1.01.04') = 200000, 'contra-asiento');
  PERFORM pruebas.afirmar((public.anular_aporte_socio(ap1, 'Era un préstamo, no un aporte', op, '2026-02-15')->>'duplicado')::boolean, 'reintento = la misma anulación');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, %L, gen_random_uuid())', ap1, 'Otra vez'), 'YA_ANULADO', 'dos veces no');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT anula_asiento_id FROM public.asiento WHERE id = (r->>'asiento_anulacion_id')::uuid) = (r->>'asiento_id')::uuid
    AND (SELECT count(*) FROM public.socio_aporte WHERE id = ap1 AND motivo_anulacion = 'Era un préstamo, no un aporte') = 1
    AND (SELECT count(*) FROM public.dinero_movimiento WHERE documento_id = ap1) = 2, 'el aporte queda con su anulación (nada borrado)');
  PERFORM pruebas.como('dueno_a');
  r := public.aportes_socios(e, sb);
  PERFORM pruebas.afirmar((r->'socios'->0->>'anulado_centavos')::bigint = 500000 AND (r->'socios'->0->>'aportado_centavos')::bigint = 50000, 'anulado en la lectura');
  PERFORM pruebas.afirmar((public.aportes_socios(e)->>'cuadra')::boolean, 'cuadra con los libros después de anular');

  -- Sin el dinero en la cuenta no se anula: L 1,000.00 a la caja chica, se gastan L 800.00.
  ap2 := (public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sa, 'monto_centavos', 100000, 'cuenta_dinero_id', pruebas.id('CCHICA'),
           'fecha', '2026-02-16'), gen_random_uuid())->>'aporte_id')::uuid;
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CCHICA'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 80000, 'descripcion', 'Papelería', 'fecha', '2026-02-16'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_aporte_socio(%L, %L, gen_random_uuid())', ap2, 'Se registró dos veces'),
    'SALDO_INSUFICIENTE', 'el dinero ya no está');

  -- Módulo apagado: se anula, no se registra.
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'fondos';
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_aporte_socio(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sa, 'monto_centavos', 1000, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'MODULO_INACTIVO', 'apagado no registra');
  r := public.anular_aporte_socio((SELECT id FROM public.socio_aporte WHERE cuenta_dinero_id = pruebas.id('FUERTE')), 'Se cargó a la caja equivocada', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'anulada')::boolean, 'apagado sí anula');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-02-20', pruebas.lineas('3.3.01.01', '3.1.01.04', 100)), 'CUENTA_CONTROLADA', 'apagado sigue controlada');

  -- Todo cuadra.
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM (SELECT l.asiento_id FROM public.asiento_linea l WHERE l.empresa_id = e
                                GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)) x;
  PERFORM pruebas.afirmar(n = 0, 'asientos que no cuadran: ' || n);
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.socio_aporte WHERE empresa_id = e AND anulada_en IS NULL) = pruebas.saldo_libros(e, '3.1.01.04'),
    'aportes vigentes = libros');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
