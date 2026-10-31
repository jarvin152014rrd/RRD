-- PRUEBA: saldo negativo por cuenta de dinero (cifras a mano): por defecto no se permite; "permitir con alerta" deja salir dinero y avisa "revise el saldo inicial" mientras esté en negativo; "sobregiro hasta" respeta su límite exacto; solo el dueño la cambia, con motivo y bitácora; no se pasa a una política más estricta si la cuenta ya está por debajo; el rastro sigue obligatorio y cuadra con los libros
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  r    jsonb;
  d    jsonb;
  trn  uuid;
  g    jsonb;
BEGIN
  PERFORM pruebas.preparar_dinero();
  -- Inicio: BAC 1,000,000; caja fuerte 300,000; Caja 1 = 0; caja chica 0.

  -- 1) Por defecto (no_permitir): un gasto de 10,000 desde Caja 1 (saldo 0) se rechaza.
  PERFORM pruebas.afirmar((SELECT politica_saldo_negativo FROM public.cuenta_dinero WHERE id = pruebas.id('CAJA1')) = 'no_permitir',
    'política por defecto: no_permitir');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 10000,
    'descripcion', 'Resmas', 'fecha', '2026-01-10')), 'SALDO_INSUFICIENTE', 'sin saldo y sin permiso de negativo');

  -- 2) Solo el dueño cambia la política, con motivo y valores válidos.
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, NULL, %L)', e, pruebas.id('CAJA1'),
    'permitir_con_alerta', 'Arranque sin saldo'), 'SIN_PERMISO', 'el admin no cambia la política');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, NULL, %L)', e, pruebas.id('CAJA1'),
    'permitir_con_alerta', 'no'), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, NULL, %L)', e, pruebas.id('CAJA1'),
    'libre', 'Arranque sin saldo'), 'DATO_INVALIDO', 'política inventada');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, NULL, %L)', e, pruebas.id('CAJA1'),
    'sobregiro_hasta', 'Arranque sin saldo'), 'DATO_INVALIDO', 'sobregiro sin límite');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, 0, %L)', e, pruebas.id('CAJA1'),
    'sobregiro_hasta', 'Arranque sin saldo'), 'DATO_INVALIDO', 'sobregiro con límite 0');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, 500, %L)', e, pruebas.id('CAJA1'),
    'permitir_con_alerta', 'Arranque sin saldo'), 'DATO_INVALIDO', 'límite sin sobregiro');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, NULL, %L)', pruebas.empresa('B'), pruebas.id('CAJA1'),
    'permitir_con_alerta', 'Arranque sin saldo'), 'NO_PERTENECE', 'otra empresa');
  r := public.configurar_saldo_negativo(e, pruebas.id('CAJA1'), 'permitir_con_alerta', NULL, 'Arranque sin contar la caja');
  PERFORM pruebas.afirmar(r->>'politica' = 'permitir_con_alerta' AND NOT (r->>'ya_estaba')::boolean AND r->>'alerta' IS NULL, 'política cambiada: ' || r::text);
  PERFORM pruebas.afirmar((public.configurar_saldo_negativo(e, pruebas.id('CAJA1'), 'permitir_con_alerta', NULL, 'Otra vez lo mismo')->>'ya_estaba')::boolean,
    'repetir no cambia nada');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE tabla = 'cuenta_dinero' AND accion = 'UPDATE'
                             AND motivo = 'Arranque sin contar la caja' AND despues->>'politica_saldo_negativo' = 'permitir_con_alerta') = 1,
    'queda en la bitácora con el motivo (una sola vez)');

  -- 3) Con alerta: gasto de 10,000 desde Caja 1 -> Caja 1 = -10,000 (libros igual) y alerta.
  PERFORM pruebas.como('admin_a');
  g := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 10000, 'descripcion', 'Resmas', 'fecha', '2026-01-10'), gen_random_uuid());
  PERFORM pruebas.afirmar(g->>'estado' = 'aplicado' AND (g->>'saldo_cuenta_centavos')::bigint = -10000, 'gasto aplicado en negativo: ' || g::text);
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = -10000 AND pruebas.dinero_libros('CAJA1') = -10000, 'Caja 1 = -10,000 en rastro y libros');
  PERFORM pruebas.afirmar((SELECT contrapartida FROM public.dinero_movimiento WHERE documento_id = (g->>'gasto_id')::uuid)
    LIKE '6.1.02.05%', 'el rastro dice a dónde fue el dinero');
  PERFORM pruebas.como('dueno_a');
  d := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.afirmar(jsonb_array_length(d->'alertas') = 1 AND d->'alertas'->0->>'nombre' = 'Caja 1'
    AND (d->'alertas'->0->>'saldo_centavos')::bigint = -10000
    AND d->'alertas'->0->>'mensaje' = 'Revise el saldo inicial: la cuenta "Caja 1" está en negativo (L -100.00).', 'alerta visible: ' || (d->'alertas')::text);
  PERFORM pruebas.afirmar((SELECT alerta_saldo_negativo FROM public.v_cuenta_dinero WHERE cuenta_dinero_id = pruebas.id('CAJA1')), 'alerta en la vista');
  PERFORM pruebas.afirmar((public.estado_arranque(e)->>'cuentas_en_negativo')::int = 1, 'el asistente cuenta la cuenta en negativo');

  -- 4) Una ENTRADA nunca se rechaza aunque siga en negativo: caja fuerte -> Caja 1 4,000: Caja 1 = -6,000, caja fuerte 296,000.
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('CAJA1'),
    'monto_centavos', 4000, 'fecha', '2026-01-11'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = -6000 AND pruebas.dinero('FUERTE') = 296000, 'entrada en negativo: -6,000 y 296,000');

  -- 5) No se vuelve a "no_permitir" mientras está en negativo.
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, NULL, %L)', e, pruebas.id('CAJA1'),
    'no_permitir', 'Ya se contó la caja'), 'NO_PERMITIDO', 'más estricto estando en negativo');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, 5000, %L)', e, pruebas.id('CAJA1'),
    'sobregiro_hasta', 'Ya se contó la caja'), 'NO_PERMITIDO', 'sobregiro menor que lo que ya debe');

  -- 6) El saldo inicial (contado: 20,000 al 02/01) lo corrige: -6,000 + 20,000 = 14,000 y la alerta se va.
  PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'),
    'monto_centavos', 20000, 'fecha', '2026-01-02'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 14000 AND pruebas.dinero_libros('CAJA1') = 14000, 'Caja 1 = 14,000');
  PERFORM pruebas.afirmar(jsonb_array_length(public.donde_esta_mi_dinero(e)->'alertas') = 0, 'sin alertas');
  r := public.configurar_saldo_negativo(e, pruebas.id('CAJA1'), 'no_permitir', NULL, 'Ya se contó la caja');
  PERFORM pruebas.afirmar(r->>'politica' = 'no_permitir', 'vuelve a no_permitir');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 14001,
    'descripcion', 'Resmas', 'fecha', '2026-01-12')), 'SALDO_INSUFICIENTE', 'otra vez sin negativo (14,001 > 14,000)');

  -- 7) Sobregiro autorizado de 50,000 en BAC (1,000,000):
  --    gasto 1,030,000 -> -30,000 (pasa); gasto 30,000 -> -60,000 (no pasa); gasto 20,000 -> -50,000 (justo el límite, pasa).
  r := public.configurar_saldo_negativo(e, pruebas.id('BANCO'), 'sobregiro_hasta', 50000, 'Sobregiro autorizado por BAC');
  PERFORM pruebas.afirmar(r->>'politica' = 'sobregiro_hasta' AND (r->>'sobregiro_limite_centavos')::bigint = 50000, 'sobregiro 50,000');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_ALQ'),
    'monto_centavos', 1030000, 'descripcion', 'Alquiler del año', 'fecha', '2026-01-15'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = -30000 AND pruebas.dinero_libros('BANCO') = -30000, 'BAC -30,000');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 30000,
    'descripcion', 'Luz', 'fecha', '2026-01-16')), 'sobregiro autorizado es hasta L -500.00', 'pasa el sobregiro (-60,000)');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = -30000, 'el rechazo no movió nada');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 20000, 'descripcion', 'Luz', 'fecha', '2026-01-16'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = -50000, 'justo en el límite: -50,000');
  d := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.afirmar(d->'alertas'->0->>'mensaje' = 'La cuenta "BAC cheques" está en sobregiro: L -500.00 (autorizado hasta L -500.00).',
    'alerta de sobregiro: ' || (d->'alertas')::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, 40000, %L)', e, pruebas.id('BANCO'),
    'sobregiro_hasta', 'Bajar el sobregiro'), 'NO_PERMITIDO', 'bajar el límite por debajo de lo que ya debe');
  PERFORM public.configurar_saldo_negativo(e, pruebas.id('BANCO'), 'permitir_con_alerta', NULL, 'Pasar a solo alerta');

  -- 8) El dinero en tránsito nunca queda en negativo.
  trn := (public.crear_cuenta_dinero(e, '{"tipo":"transito","nombre":"Tránsito BAC"}')->>'cuenta_dinero_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_saldo_negativo(%L, %L, %L, NULL, %L)', e, trn,
    'permitir_con_alerta', 'Probar el tránsito'), 'CUENTA_DINERO_INVALIDA', 'tránsito sin negativo');

  -- 9) Todo cuadra: rastro = libros en cada cuenta; bitácora intacta.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.cuenta_dinero x JOIN public.cuenta c ON c.id = x.cuenta_id
     WHERE x.empresa_id = e
       AND (SELECT coalesce(sum(m.monto_centavos), 0) FROM public.dinero_movimiento m WHERE m.cuenta_dinero_id = x.id)
           <> pruebas.saldo_libros(e, c.codigo)), 'rastro = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
