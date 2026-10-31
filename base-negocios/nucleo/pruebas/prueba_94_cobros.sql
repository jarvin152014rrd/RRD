-- PRUEBA: cobros a clientes (cifras a mano): saldo inicial de CxC contra Saldos de apertura (registrar, cobrar, anular); cobro a una factura o consolidado (la más vieja primero o la elegida); efectivo, tarjeta, transferencia por confirmar y mixto; nunca más del saldo sin decisión (el excedente pasa a saldo a favor); condonación explícita con permiso y motivo; anular cobro (motivo, el dinero sale de la misma cuenta, saldos restaurados); la venta con cobros no se anula; turno obligatorio; estado de cuenta, antigüedad y cobros por caja/cajero; reintento
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   uuid; v2 uuid;
  si1  uuid;
  c    jsonb;
  c1   jsonb; c3 jsonb;
  pg   uuid;
  r    jsonb;
  op   uuid := gen_random_uuid();
  t    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de cobros');

  -- 1) Saldo inicial (solo el dueño): CLI1 debía la factura F-OLD-1 del 15/12/2025 por 20,000.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxc(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'numero_documento', 'F-OLD-1', 'fecha_documento', '2025-12-15', 'monto_centavos', 20000)),
    'SIN_PERMISO', 'saldo inicial: solo el dueño');
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'numero_documento', 'F-OLD-1',
         'fecha_documento', '2025-12-15', 'monto_centavos', 20000), gen_random_uuid());
  si1 := (r->>'saldo_inicial_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxc(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'numero_documento', 'f-old-1', 'fecha_documento', '2025-12-15', 'monto_centavos', 100)),
    'YA_EXISTE', 'misma factura dos veces');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') = 20000 AND pruebas.saldo_libros(e, '3.3.01.03') >= 20000
    AND (SELECT fecha_vencimiento FROM public.cxc_saldo_inicial WHERE id = si1) = '2026-01-14', 'apertura: Dr Clientes / Cr Saldos de apertura; vence +30');

  -- 2) Ventas al crédito: V1 10 tornillos = 15,000; V2 1 galón = 45,000. CxC = 80,000.
  PERFORM pruebas.como('cajero_a');
  v1 := (public.registrar_venta(e, pruebas.venta('P1', 10, 'credito', 'CLI1') || '{"fecha":"2026-01-10"}', gen_random_uuid())->>'venta_id')::uuid;
  v2 := (public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1') || '{"fecha":"2026-01-12"}', gen_random_uuid())->>'venta_id')::uuid;
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_cxc(e) = 80000 AND pruebas.saldo_libros(e, '1.1.02.01') = 80000, 'CxC 80,000');

  -- 3) Cobro de 30,000 en efectivo sin elegir: la más vieja primero (F-OLD-1 20,000 y V1 10,000).
  PERFORM pruebas.como('cajero_a');
  c1 := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'fecha', '2026-01-20', 'referencia', 'Recibo 1',
          'pagos', '[{"forma":"efectivo","monto_centavos":30000,"recibido_centavos":31000}]'::jsonb), op);
  PERFORM pruebas.afirmar((c1->>'aplicado_centavos')::bigint = 30000 AND (c1->>'excedente_centavos')::bigint = 0
    AND (c1->>'vuelto_centavos')::bigint = 1000 AND jsonb_array_length(c1->'aplicaciones') = 2
    AND c1->'aplicaciones'->0->>'documento' = 'F-OLD-1' AND (c1->'aplicaciones'->0->>'monto_centavos')::bigint = 20000
    AND (c1->'aplicaciones'->1->>'monto_centavos')::bigint = 10000 AND (c1->'aplicaciones'->1->>'saldo_restante_centavos')::bigint = 5000
    AND (c1->>'saldo_cliente_centavos')::bigint = 50000, 'más vieja primero: ' || c1::text);
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
          'pagos', '[{"forma":"efectivo","monto_centavos":30000}]'::jsonb), op);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean AND r->>'cobro_id' = c1->>'cobro_id', 'reintento = el mismo cobro');

  -- 4) Cobro elegido: 5,000 con tarjeta a V2 (V2 queda en 40,000).
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'fecha', '2026-01-21',
         'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v2, 'monto_centavos', 5000)),
         'pagos', '[{"forma":"tarjeta","monto_centavos":5000,"referencia":"Voucher 77"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((r->'aplicaciones'->0->>'saldo_restante_centavos')::bigint = 40000, 'elegida: V2 en 40,000');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v1, 'monto_centavos', 5001)),
    'pagos', '[{"forma":"efectivo","monto_centavos":5001}]'::jsonb)), 'COBRO_EXCEDE_SALDO', 'no más que el saldo de la factura');

  -- 5) Nunca más del saldo sin decisión: debe 45,000 y paga 55,000.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', '[{"forma":"efectivo","monto_centavos":55000}]'::jsonb)), 'COBRO_EXCEDE_SALDO', 'excedente sin decisión');
  -- Mixto: 30,000 efectivo + 25,000 transferencia, excedente a saldo a favor: V1 5,000 + V2 40,000 + 10,000 a favor.
  c3 := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'fecha', '2026-01-25', 'excedente', 'saldo_favor',
          'pagos', '[{"forma":"efectivo","monto_centavos":30000},{"forma":"transferencia","monto_centavos":25000,"referencia":"TRF-1"}]'::jsonb),
          gen_random_uuid());
  PERFORM pruebas.afirmar((c3->>'aplicado_centavos')::bigint = 45000 AND (c3->>'excedente_centavos')::bigint = 10000
    AND (c3->'saldo_favor'->>'monto_centavos')::bigint = 10000 AND c3->'saldo_favor'->>'codigo' IS NULL
    AND (c3->>'saldo_cliente_centavos')::bigint = 0 AND (c3->>'saldo_favor_cliente_centavos')::bigint = 10000, 'mixto con excedente: ' || c3::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') = 0 AND interno.total_cxc(e) = 0
    AND pruebas.saldo_libros(e, '2.1.04.02') = 10000 AND interno.total_saldo_favor(e) = 10000, 'CxC 0; saldo a favor 10,000 (pasivo)');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 60000, 'caja 1: 30,000 + 30,000');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
                            WHERE d.empresa_id = e AND d.tipo = 'pos_por_liquidar') = 5000
    AND (SELECT sum(monto_centavos) FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
          WHERE d.empresa_id = e AND d.tipo = 'transferencia_por_confirmar') = 25000, 'POS 5,000; transferencias por confirmar 25,000');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.dinero_movimiento WHERE documento_id = (c3->>'cobro_id')::uuid AND operacion = 'cobro') = 2,
    'rastro de cada entrada');

  -- 6) La transferencia se confirma al banco.
  PERFORM pruebas.como('admin_a');
  SELECT id INTO pg FROM public.cobro_pago WHERE cobro_id = (c3->>'cobro_id')::uuid AND forma = 'transferencia';
  r := public.confirmar_transferencia_cobro(pg, jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'BAC-889'), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'saldo_banco_centavos')::bigint = 1025000, 'banco 1,000,000 + 25,000');

  -- 7) La venta con cobros no se anula (gancho de 2b-2a).
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v1, 'Error de captura'),
    'VENTA_CON_COBROS', 'venta con cobros');

  -- 8) Anular el cobro mixto: el dinero sale de la caja (30,000) y del BANCO (25,000, ya confirmada);
  --    el saldo a favor del excedente se anula; V1 vuelve a 5,000 y V2 a 40,000.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c3->>'cobro_id', 'Error de captura'),
    'SIN_PERMISO', 'el cajero no anula cobros');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c3->>'cobro_id', 'mal'), 'FALTA_MOTIVO', 'sin motivo');
  r := public.anular_cobro((c3->>'cobro_id')::uuid, 'Se registró dos veces', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'anulado')::boolean AND (r->>'saldo_cliente_centavos')::bigint = 45000
    AND (r->>'saldo_favor_cliente_centavos')::bigint = 0, 'anulado: saldos restaurados');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c3->>'cobro_id', 'Otra vez'), 'YA_ANULADO', 'una vez');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 30000 AND pruebas.dinero('BANCO') = 1000000 AND pruebas.saldo_libros(e, '1.1.02.01') = 45000
    AND pruebas.saldo_libros(e, '2.1.04.02') = 0, 'el dinero salió de la misma cuenta');
  PERFORM pruebas.afirmar((SELECT a.anula_asiento_id FROM public.asiento a JOIN public.cobro c ON c.asiento_anulacion_id = a.id
                            WHERE c.id = (c3->>'cobro_id')::uuid) = (SELECT asiento_id FROM public.cobro WHERE id = (c3->>'cobro_id')::uuid),
    'contra-asiento enlazado');

  -- 9) Condonación explícita (redondeo): V1 debe 5,000; paga 4,999 y se condona 1 centavo con permiso y motivo.
  PERFORM pruebas.como('cajero_a');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v1, 'monto_centavos', 4999)),
    'pagos', '[{"forma":"efectivo","monto_centavos":4999}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.condonar_saldo_cxc(%L, %L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v1, 'monto_centavos', 1), 'Redondeo de centavos'), 'SIN_PERMISO', 'el cajero no condona');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.condonar_saldo_cxc(%L, %L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v1, 'monto_centavos', 1), ''), 'FALTA_MOTIVO', 'condonar sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.condonar_saldo_cxc(%L, %L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v1, 'monto_centavos', 2), 'Redondeo de centavos'), 'COBRO_EXCEDE_SALDO', 'no más que el saldo');
  r := public.condonar_saldo_cxc(e, jsonb_build_object('venta_id', v1, 'monto_centavos', 1), 'Redondeo de centavos', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'saldo_documento_centavos')::bigint = 0, 'V1 en 0');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '6.1.02.12') = 1 AND pruebas.saldo_libros(e, '1.1.02.01') = 40000, 'condonado 1 centavo al gasto');
  PERFORM pruebas.como('admin_a');
  r := public.anular_condonacion((r->>'condonacion_id')::uuid, 'Se cobrará el centavo', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'saldo_documento_centavos')::bigint = 1, 'anular condonación: vuelve 1 centavo');

  -- 10) El saldo inicial con cobros no se anula; uno nuevo sin cobros sí.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_saldo_inicial_cxc(%L, %L, gen_random_uuid())', si1, 'Estaba mal'),
    'NO_PERMITIDO', 'saldo inicial con cobros');
  r := public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'numero_documento', 'F-OLD-9',
         'fecha_documento', '2025-11-30', 'fecha_vencimiento', '2025-12-30', 'monto_centavos', 7000), gen_random_uuid());
  PERFORM public.anular_saldo_inicial_cxc((r->>'saldo_inicial_id')::uuid, 'Ya estaba pagada', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') = 40001 AND interno.total_cxc(e) = 40001, 'CxC 40,001 tras anular el saldo inicial');

  -- 11) Turno obligatorio: sin turno no entra efectivo; con turno sí (y queda en el rastro).
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": true}', 'Ahora con turnos');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb)), 'SIN_TURNO_ABIERTO', 'sin turno');
  PERFORM public.abrir_turno(e, pruebas.id('CAJA001'), 34999, gen_random_uuid());   -- 30,000 + 4,999 que tiene la caja
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb),
         gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT turno_id IS NOT NULL FROM public.cobro_pago WHERE cobro_id = (r->>'cobro_id')::uuid)
    AND (SELECT turno_id IS NOT NULL FROM public.dinero_movimiento WHERE documento_id = (r->>'cobro_id')::uuid),
    'cobro en el turno del cajero');

  -- 12) Lecturas: estado de cuenta, antigüedad, cobros por caja y cajero.
  PERFORM pruebas.como('dueno_a');
  t := public.estado_cuenta_cliente(e, pruebas.id('CLI1'), '2026-01-01', NULL);
  -- Antes del 01/01: F-OLD-1 20,000. Cargos: V1 15,000 + V2 45,000 + cobro mixto anulado 45,000 + condonación anulada 1 = 105,001.
  -- Abonos: 30,000 + 5,000 + 45,000 + 4,999 + 1 + 1,000 (1 a V1 y 999 a V2) = 86,000. Saldo: 20,000 + 105,001 - 86,000 = 39,001.
  PERFORM pruebas.afirmar((t->>'saldo_final_centavos')::bigint = 39001 AND (t->>'saldo_actual_centavos')::bigint = 39001
    AND (t->>'saldo_anterior_centavos')::bigint = 20000 AND jsonb_array_length(t->'pendientes') = 1
    AND (t->'pendientes'->0->>'saldo_centavos')::bigint = 39001, 'estado de cuenta: ' || t::text);
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cxc_cliente WHERE cliente_id = pruebas.id('CLI1')) = 39001
    AND (SELECT sum(saldo_centavos) FROM public.v_cxc_documento WHERE cliente_id = pruebas.id('CLI1')) = 39001
    AND (SELECT saldo_centavos FROM public.v_cxc_documento WHERE documento_id = si1) = 0
    AND (SELECT cobrado_centavos FROM public.v_cxc_documento WHERE documento_id = si1) = 20000, 'antigüedad y CxC por documento');
  PERFORM pruebas.afirmar((SELECT sum(total_centavos) FROM public.v_cobros_por_caja WHERE empresa_id = e) = 30000 + 5000 + 4999 + 1000
    AND (SELECT efectivo_centavos FROM public.v_cobros_por_caja WHERE fecha = '2026-01-20') = 30000
    AND (SELECT tarjeta_centavos FROM public.v_cobros_por_caja WHERE fecha = '2026-01-21') = 5000
    AND (SELECT cajero FROM public.v_cobros_por_caja WHERE fecha = '2026-01-20') IS NOT NULL, 'cobros por caja y cajero (sin anulados)');

  -- 13) Cuadre: CxC = Clientes; saldo a favor = su pasivo; dinero = subcuentas; bitácora intacta.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01')
    AND interno.total_saldo_favor(e) = coalesce(pruebas.saldo_libros(e, '2.1.04.02'), 0)
    AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta x ON x.id = d.cuenta_id
                     WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, x.codigo))
    AND (SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea WHERE empresa_id = e)
    AND (SELECT count(*) FROM public.verificar_bitacora()) = 0, 'cuadre');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cobro SET monto_centavos = 1 WHERE id = %L', c1->>'cobro_id'), 'PROHIBIDO', 'el cobro no se edita');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.cxc_aplicacion WHERE origen_id = %L', c1->>'cobro_id'), 'PROHIBIDO', 'no se borra');

  -- 14) Anular el primer cobro: F-OLD-1 y V1 recuperan saldo; con otros cobros vigentes las ventas siguen sin anularse.
  --     0.9.1 (decisión del dueño): el efectivo de c1 (30,000) está en la caja donde el cajero tiene su
  --     turno abierto: el admin, sin turno propio, no lo saca (TURNO_AJENO). El cajero cierra (esperado
  --     34,999 + 1,000 = 35,999, cuenta lo mismo); el admin abre su turno con esos 35,999 y anula: los
  --     30,000 salen de SU turno (queda 5,999).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c1->>'cobro_id', 'Cobro mal aplicado'),
    'TURNO_AJENO', 'nadie saca dinero del turno de otro cajero');
  PERFORM pruebas.como('cajero_a');
  PERFORM public.cerrar_turno((SELECT id FROM public.turno_caja WHERE empresa_id = e AND estado = 'abierto'), 35999, gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM public.abrir_turno(e, pruebas.id('CAJA001'), 35999, gen_random_uuid());
  PERFORM public.anular_cobro((c1->>'cobro_id')::uuid, 'Cobro mal aplicado', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 5999 AND (SELECT t.cajero_id FROM public.dinero_movimiento m JOIN public.turno_caja t ON t.id = m.turno_id
    WHERE m.documento_id = (c1->>'cobro_id')::uuid AND m.operacion = 'anulacion_cobro') = pruebas.usuario('admin_a'), 'sale del turno del admin');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v1, 'Error de captura'),
    'VENTA_CON_COBROS', 'V1 aún tiene el cobro de 4,999');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', v2, 'Venta duplicada'),
    'VENTA_CON_COBROS', 'V2 tiene el cobro con tarjeta');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01') AND interno.total_cxc(e) = 69001, 'CxC 39,001 + 30,000 del cobro anulado');
END $$;
