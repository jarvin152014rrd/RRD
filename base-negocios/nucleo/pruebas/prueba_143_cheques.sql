-- PRUEBA: (0.18.0) abonos con cheque (cifras a mano): el cobro con cheque rebaja lo que debe el cliente y el valor entra a "Cheques por depositar" (no es efectivo disponible; se crea sola la cuenta); reglas (va solo, sin excedente, sin anticipo, con número, banco y fecha); ¿dónde está mi dinero? y la proyección (posfechado en la semana de su fecha); depositar (posfechado no; doble envío) con el flujo de siempre en tránsito y confirmar (el banco recibe un movimiento que se puede cuadrar); el cheque rebota ya confirmado (el banco lo devuelve, cobro anulado con contrapartida, el cliente vuelve a deber y el cargo del banco como gasto) o con el depósito en tránsito (se anula el depósito); anular el cobro solo mientras el cheque está por depositar; la cuenta no se mueve con traslados; permisos; rastro = libros, CxC = Clientes, asientos cuadran y bitácora íntegra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   jsonb;
  v2   jsonb;
  v3   jsonb;
  c1   jsonb;
  c2   jsonb;
  c    jsonb;
  r    jsonb;
  r2   jsonb;
  ch1  uuid;
  ch2  uuid;
  ch3  uuid;
  cta  uuid;
  op   uuid := gen_random_uuid();
  hoy  date;
  n    bigint;
  banco0 bigint;
  cheque jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  hoy := public.hoy_local(e);
  -- Debe: V1 galón 45,000 al crédito; V2 10 tornillos 15,000 al crédito; V3 otro galón 45,000.
  v1 := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1'), gen_random_uuid());
  v2 := public.registrar_venta(e, pruebas.venta('P1', 10, 'credito', 'CLI1'), gen_random_uuid());
  cheque := jsonb_build_object('forma', 'cheque', 'monto_centavos', 45000, 'numero_cheque', '000123',
                               'banco_emisor', 'Banco Atlántida', 'fecha_cheque', hoy);

  -- ===== 1) Reglas del cobro con cheque =====
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', jsonb_build_array(cheque, '{"forma":"efectivo","monto_centavos":100}'::jsonb))), 'CHEQUE_INVALIDO', 'cheque con otra forma');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'excedente', 'saldo_favor', 'pagos', jsonb_build_array(cheque || '{"monto_centavos": 70000}'))), 'CHEQUE_INVALIDO', 'cheque con excedente');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'tipo', 'anticipo', 'pagos', jsonb_build_array(cheque))), 'CHEQUE_INVALIDO', 'anticipo con cheque');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', jsonb_build_array(cheque - 'numero_cheque'))), 'CHEQUE_INVALIDO', 'sin número');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', jsonb_build_array(cheque || jsonb_build_object('fecha_cheque', hoy + 400)))), 'CHEQUE_INVALIDO', 'fecha muy lejana');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', '[{"forma":"efectivo","monto_centavos":100,"numero_cheque":"1"}]'::jsonb)), 'DATO_INVALIDO', 'datos de cheque en efectivo');

  -- ===== 2) Cobro con cheque: a la factura más vieja (V1) =====
  c1 := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', jsonb_build_array(cheque)), op);
  c := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', jsonb_build_array(cheque)), op);
  PERFORM pruebas.afirmar((c->>'duplicado')::boolean AND c->>'cobro_id' = c1->>'cobro_id', 'doble envío = el mismo cobro');
  PERFORM pruebas.como('superusuario');
  SELECT id, cuenta_dinero_id INTO ch1, cta FROM public.cheque_recibido WHERE cobro_id = (c1->>'cobro_id')::uuid;
  PERFORM pruebas.guardar('CHEQUES', cta);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cheque_recibido WHERE empresa_id = e) = 1, 'un solo cheque');
  PERFORM pruebas.afirmar((SELECT tipo = 'cheques_por_depositar' AND nombre = 'Cheques por depositar' FROM public.cuenta_dinero WHERE id = cta)
    AND (SELECT c.codigo LIKE '1.1.01.%' FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = cta), 'cuenta creada sola bajo 1.1.01');
  PERFORM pruebas.afirmar(interno.saldo_documento_cxc((v1->>'venta_id')::uuid) = 0 AND interno.saldo_documento_cxc((v2->>'venta_id')::uuid) = 15000,
    'V1 pagada con el cheque, V2 sigue');
  PERFORM pruebas.afirmar(pruebas.dinero('CHEQUES') = 45000 AND pruebas.dinero_libros('CHEQUES') = 45000, 'cheques por depositar 45,000');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ',' ORDER BY l.debe_centavos DESC)
      FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
     WHERE l.asiento_id = (SELECT asiento_id FROM public.cobro WHERE id = (c1->>'cobro_id')::uuid))
    = (SELECT c.codigo FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = cta) || ':45000/0,1.1.02.01:0/45000',
    'asiento: Dr Cheques por depositar / Cr Clientes');
  -- Posfechado (dentro de 10 días) para V2.
  PERFORM pruebas.como('cajero_a');
  c2 := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', jsonb_build_array(
          cheque || jsonb_build_object('monto_centavos', 15000, 'numero_cheque', '7788', 'fecha_cheque', hoy + 10))), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  ch2 := (SELECT id FROM public.cheque_recibido WHERE cobro_id = (c2->>'cobro_id')::uuid);

  -- ===== 3) ¿Dónde está mi dinero? y proyección =====
  PERFORM pruebas.como('dueno_a');
  r := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.afirmar((r->'cheques_por_depositar'->>'total_centavos')::bigint = 60000 AND (r->'cheques_por_depositar'->>'posfechados_centavos')::bigint = 15000
    AND (r->'por_tipo'->>'cheques_por_depositar')::bigint = 60000, 'dónde está mi dinero: ' || (r->'cheques_por_depositar')::text);
  r := public.proyeccion_flujo(e, 30);
  PERFORM pruebas.afirmar((r->'semanas'->0->>'cheques_centavos')::bigint = 45000 AND (r->'semanas'->1->>'cheques_centavos')::bigint = 15000
    AND (r->>'cheques_por_depositar_centavos')::bigint = 60000
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'disponible_por_cuenta') x WHERE x->>'tipo' = 'cheques_por_depositar'),
    'proyección: semana 1 = 45,000, semana 2 = 15,000; no cuenta como disponible: ' || (r->'semanas')::text);
  PERFORM pruebas.afirmar((r->'semanas'->1->>'saldo_inicial_centavos')::bigint = (r->'semanas'->0->>'saldo_final_centavos')::bigint
    AND (r->>'saldo_final_proyectado_centavos')::bigint = (r->'semanas'->-1->>'saldo_final_centavos')::bigint, 'saldos encadenados');

  -- ===== 4) Depositar =====
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.depositar_cheque(%L, %L, NULL, NULL, gen_random_uuid())', ch1, pruebas.id('BANCO')),
    'SIN_PERMISO', 'el cajero no deposita');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cheque_rechazado(%L, %L, gen_random_uuid())', ch1, '{"motivo":"Sin fondos"}'),
    'SIN_PERMISO', 'el cajero no registra rebotes');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.depositar_cheque(%L, %L, NULL, NULL, gen_random_uuid())', ch2, pruebas.id('BANCO')),
    'CHEQUE_POSFECHADO', 'posfechado');
  PERFORM pruebas.debe_fallar(format('SELECT public.depositar_cheque(%L, %L, NULL, NULL, gen_random_uuid())', ch1, pruebas.id('FUERTE')),
    'CUENTA_DINERO_INVALIDA', 'a una caja');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('CHEQUES'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 100)), 'CUENTA_DINERO_INVALIDA', 'traslado desde cheques');
  op := gen_random_uuid();
  r := public.depositar_cheque(ch1, pruebas.id('BANCO'), NULL, 'Boleta 5544', op);
  r2 := public.depositar_cheque(ch1, pruebas.id('BANCO'), NULL, 'Boleta 5544', op);
  PERFORM pruebas.afirmar(r->>'estado' = 'depositado' AND r->'deposito'->>'estado' = 'en_transito' AND (r2->>'duplicado')::boolean
    AND (SELECT count(*) FROM public.operacion_dinero WHERE empresa_id = e AND tipo = 'deposito') = 1, 'depositado en tránsito, sin duplicar');
  PERFORM pruebas.afirmar(pruebas.dinero('CHEQUES') = 15000, 'quedan 15,000 por depositar');
  banco0 := pruebas.dinero('BANCO');
  PERFORM public.confirmar_deposito((r->>'operacion_deposito_id')::uuid, gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = banco0 + 45000, 'el banco recibe 45,000');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.cuenta_dinero_id = pruebas.id('BANCO') AND m.monto_centavos = 45000
    AND m.operacion = 'confirmacion_deposito' AND interno.mov_conciliable(m)), 'movimiento del banco que se puede cuadrar con el estado de cuenta');

  -- ===== 5) Rebota ya confirmado: el banco lo devuelve, cobro anulado, el cliente vuelve a deber, cargo de L 25.00 =====
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c1->>'cobro_id', 'Me equivoqué'),
    'CHEQUE_DEPOSITADO', 'cobro con cheque depositado no se anula así');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cheque_rechazado(%L, %L, gen_random_uuid())', ch1, '{"motivo":"no"}'),
    'FALTA_MOTIVO', 'rebote sin motivo');
  op := gen_random_uuid();
  r := public.registrar_cheque_rechazado(ch1, jsonb_build_object('motivo', 'Fondos insuficientes',
         'cargo_banco', jsonb_build_object('categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 2500)), op);
  r2 := public.registrar_cheque_rechazado(ch1, '{"motivo":"Fondos insuficientes"}', op);
  PERFORM pruebas.afirmar(r->>'estado' = 'rechazado' AND (r2->>'duplicado')::boolean AND r->'gasto'->>'gasto_id' IS NOT NULL, 'rechazado: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = banco0 + 45000 - 45000 - 2500, 'el banco: devuelve 45,000 y cobra 2,500');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_documento_cxc((v1->>'venta_id')::uuid) = 45000, 'el cliente vuelve a deber V1');
  PERFORM pruebas.afirmar((SELECT anulada_en IS NOT NULL AND motivo_anulacion LIKE 'Cheque 000123 rechazado%' FROM public.cobro WHERE id = (c1->>'cobro_id')::uuid)
    AND (SELECT asiento_anulacion_id IS NOT NULL FROM public.cobro WHERE id = (c1->>'cobro_id')::uuid), 'cobro anulado con contrapartida');
  PERFORM pruebas.afirmar(pruebas.dinero('CHEQUES') = 15000, 'en cheques solo queda el posfechado');

  -- ===== 6) Rebota con el depósito en tránsito: se anula el depósito =====
  PERFORM pruebas.como('cajero_a');
  c := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v1->'venta_id', 'monto_centavos', 45000)),
         'pagos', jsonb_build_array(cheque || '{"numero_cheque": "000124"}')), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  ch3 := (SELECT id FROM public.cheque_recibido WHERE cobro_id = (c->>'cobro_id')::uuid);
  PERFORM pruebas.como('admin_a');
  r := public.depositar_cheque(ch3, pruebas.id('BANCO'), NULL, NULL, gen_random_uuid());
  r := public.registrar_cheque_rechazado(ch3, '{"motivo":"Firma no coincide"}', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(r->>'estado' = 'rechazado' AND (SELECT anulada_en IS NOT NULL FROM public.operacion_dinero WHERE id = (SELECT x.id FROM public.operacion_dinero x
      WHERE x.empresa_id = e AND x.tipo = 'deposito' ORDER BY x.numero DESC LIMIT 1))
    AND interno.saldo_documento_cxc((v1->>'venta_id')::uuid) = 45000 AND pruebas.dinero('CHEQUES') = 15000
    AND (SELECT coalesce(sum(monto_centavos), 0) FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
          WHERE d.empresa_id = e AND d.tipo = 'transito') = 0, 'rebote en tránsito: depósito anulado, el cliente debe otra vez');

  -- ===== 7) Anular un cobro con cheque por depositar; anular el depósito devuelve el cheque =====
  PERFORM pruebas.como('admin_a');
  r := public.anular_cobro((c2->>'cobro_id')::uuid, 'Se registró al cliente equivocado', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado FROM public.cheque_recibido WHERE id = ch2) = 'anulado' AND pruebas.dinero('CHEQUES') = 0
    AND interno.saldo_documento_cxc((v2->>'venta_id')::uuid) = 15000, 'cobro anulado: cheque anulado');
  PERFORM pruebas.como('cajero_a');
  c := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', jsonb_build_array(
         cheque || jsonb_build_object('monto_centavos', 15000, 'numero_cheque', '9001'))), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  r := public.depositar_cheque((SELECT id FROM public.cheque_recibido WHERE cobro_id = (c->>'cobro_id')::uuid), pruebas.id('BANCO'), NULL, NULL, gen_random_uuid());
  PERFORM public.anular_operacion_dinero((r->>'operacion_deposito_id')::uuid, 'Boleta equivocada', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado = 'por_depositar' AND operacion_deposito_id IS NULL FROM public.cheque_recibido WHERE cobro_id = (c->>'cobro_id')::uuid)
    AND pruebas.dinero('CHEQUES') = 15000, 'depósito anulado: el cheque vuelve a por depositar');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cheque_recibido WHERE empresa_id = e) = 4, 'vista de cheques');

  -- ===== 8) Todo cuadra =====
  PERFORM pruebas.afirmar(pruebas.dinero('CHEQUES') = pruebas.dinero_libros('CHEQUES')
    AND pruebas.dinero('BANCO') = pruebas.dinero_libros('BANCO')
    AND pruebas.dinero_libros('CHEQUES') = (SELECT sum(monto_centavos) FROM public.cheque_recibido WHERE empresa_id = e AND estado = 'por_depositar'),
    'rastro = libros y cheques por depositar = cheques en ese estado');
  PERFORM pruebas.afirmar(interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01'), 'CxC = Clientes');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cheque_recibido) = 0, 'B no ve cheques de A');
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM (SELECT l.asiento_id FROM public.asiento_linea l WHERE l.empresa_id = e
                                GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)) x;
  PERFORM pruebas.afirmar(n = 0, 'asientos que no cuadran: ' || n);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
