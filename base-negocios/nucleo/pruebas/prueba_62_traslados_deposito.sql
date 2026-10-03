-- PRUEBA: depósito (queda en tránsito con alerta hasta confirmar), retiro, reposición de caja chica y traslado en UNA operación (cifras a mano): sale de una cuenta y entra a otra con referencia, comprobante, usuario y equipo; ninguna cuenta queda en negativo, la caja chica no pasa su fondo; anular con motivo; reintentos
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  dep  jsonb;
  dep2 jsonb;
  tr   jsonb;
  r    jsonb;
  op   uuid := gen_random_uuid();
  t    uuid;
  m    public.dinero_movimiento;
BEGIN
  PERFORM pruebas.preparar_dinero();
  -- Inicio: BAC 1,000,000; caja fuerte 300,000; caja chica 0 (fondo 200,000); Caja 1 0.
  PERFORM pruebas.como('admin_a');

  -- 1) Depósito de la caja fuerte al BAC: 250,000. Caja fuerte 300,000 - 250,000 = 50,000;
  --    en tránsito 250,000; el BAC sigue en 1,000,000 hasta confirmar.
  dep := public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('BANCO'), 'monto_centavos', 250000, 'fecha', '2026-01-10', 'referencia', 'Boleta 99881',
    'equipo', 'PC oficina', 'comprobante', pruebas.comprobante('boleta99881.jpg')), op);
  PERFORM pruebas.afirmar(dep->>'estado' = 'en_transito' AND (dep->>'saldo_origen_centavos')::bigint = 50000
    AND (dep->>'saldo_destino_centavos')::bigint = 1000000, 'depósito en tránsito: ' || dep::text);
  t := (SELECT transito_id FROM public.operacion_dinero WHERE id = (dep->>'operacion_id')::uuid);
  PERFORM pruebas.guardar('TRANSITO', t);
  PERFORM pruebas.afirmar(pruebas.dinero('TRANSITO') = 250000 AND pruebas.dinero('FUERTE') = 50000 AND pruebas.dinero('BANCO') = 1000000,
    'tránsito 250,000');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT nombre || '/' || tipo FROM public.cuenta_dinero WHERE id = t) = 'Depósitos en tránsito/transito', 'tránsito creado solo');
  SELECT * INTO m FROM public.dinero_movimiento WHERE cuenta_dinero_id = pruebas.id('FUERTE') AND documento_id = (dep->>'operacion_id')::uuid;
  PERFORM pruebas.afirmar(m.monto_centavos = -250000 AND m.contrapartida = 'Depósitos en tránsito' AND m.referencia = 'Boleta 99881'
    AND m.equipo = 'PC oficina' AND m.creado_por = pruebas.usuario('admin_a') AND m.operacion = 'dinero_deposito', 'rastro del depósito');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.adjunto WHERE documento_tipo = 'operacion_dinero'
                            AND documento_id = (dep->>'operacion_id')::uuid AND tipo_contenido = 'image/jpeg') = 1, 'comprobante guardado');
  -- Más de 3 días sin confirmar (defecto): alerta.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar((SELECT alerta FROM public.v_deposito_transito WHERE operacion_id = (dep->>'operacion_id')::uuid), 'alerta de tránsito');
  -- Reintento con el mismo id: lo mismo, sin moverlo otra vez. Ese id en otra cosa: no.
  r := public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('BANCO'), 'monto_centavos', 250000), op);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean AND r->>'operacion_id' = dep->>'operacion_id' AND pruebas.dinero('FUERTE') = 50000, 'reintento');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, %L)', e, jsonb_build_object('tipo', 'retiro',
    'origen_id', pruebas.id('BANCO'), 'destino_id', pruebas.id('FUERTE'), 'monto_centavos', 1), op), 'ID_OPERACION_USADO', 'id de otro tipo');

  -- 2) Confirmar: el BAC recibe 250,000 (1,250,000) y el tránsito queda en 0.
  r := public.confirmar_deposito((dep->>'operacion_id')::uuid, gen_random_uuid(), '2026-01-11', 'Conf 555');
  PERFORM pruebas.afirmar(r->>'estado' = 'confirmada' AND pruebas.dinero('BANCO') = 1250000 AND pruebas.dinero('TRANSITO') = 0, 'confirmado');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.v_deposito_transito), 'sin depósitos en tránsito');
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_deposito(%L, gen_random_uuid())', dep->>'operacion_id'), 'ya fue confirmado', 'confirmar dos veces');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_operacion_dinero(%L, %L, gen_random_uuid())', dep->>'operacion_id', 'Depósito equivocado'),
    'NO_PERMITIDO', 'anular un depósito confirmado');

  -- 3) Retiro del BAC a la caja fuerte: 100,000. BAC 1,150,000; caja fuerte 150,000.
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'retiro', 'origen_id', pruebas.id('BANCO'),
    'destino_id', pruebas.id('FUERTE'), 'monto_centavos', 100000, 'fecha', '2026-01-12', 'referencia', 'Cheque 1001'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 1150000 AND pruebas.dinero('FUERTE') = 150000, 'retiro');

  -- 4) Reposición de la caja chica sin monto: fondo 200,000 - saldo 0 = 200,000 desde el BAC (950,000).
  r := public.trasladar_dinero(e, jsonb_build_object('tipo', 'reposicion_caja_chica', 'origen_id', pruebas.id('BANCO'),
    'destino_id', pruebas.id('CCHICA'), 'fecha', '2026-01-12'), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'monto_centavos')::bigint = 200000 AND pruebas.dinero('CCHICA') = 200000 AND pruebas.dinero('BANCO') = 950000, 'reposición');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'reposicion_caja_chica',
    'origen_id', pruebas.id('BANCO'), 'destino_id', pruebas.id('CCHICA'))), 'fondo completo', 'reponer una caja chica llena');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('CCHICA'), 'monto_centavos', 1)), 'TOPE_CAJA_CHICA', 'pasar el fondo de la caja chica');

  -- 5) No alcanza: caja fuerte tiene 150,000.
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'deposito',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 150001)), 'SALDO_INSUFICIENTE', 'depósito sin fondos');

  -- 6) Depósito 2 de 50,000 y se anula antes de confirmar: vuelve a la caja fuerte.
  dep2 := public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('BANCO'), 'monto_centavos', 50000, 'fecha', '2026-01-13'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('FUERTE') = 100000 AND pruebas.dinero('TRANSITO') = 50000, 'depósito 2 en tránsito');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_operacion_dinero(%L, %L, gen_random_uuid())', dep2->>'operacion_id', 'no'), 'FALTA_MOTIVO', 'anular sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_operacion_dinero(%L, %L, gen_random_uuid(), %L)', dep2->>'operacion_id', 'El banco lo rechazó', '2026-01-12'),
    'FECHA_INVALIDA', 'anular con fecha anterior');
  r := public.anular_operacion_dinero((dep2->>'operacion_id')::uuid, 'El banco lo rechazó', gen_random_uuid(), '2026-01-14');
  PERFORM pruebas.afirmar(pruebas.dinero('FUERTE') = 150000 AND pruebas.dinero('TRANSITO') = 0, 'depósito 2 anulado');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_operacion_dinero(%L, %L, gen_random_uuid())', dep2->>'operacion_id', 'Otra vez'), 'YA_ANULADO', 'anular dos veces');
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_deposito(%L, gen_random_uuid())', dep2->>'operacion_id'), 'YA_ANULADO', 'confirmar un anulado');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT a.anula_asiento_id FROM public.asiento a WHERE a.id = (r->>'asiento_anulacion_id')::uuid)
                          = (SELECT asiento_id FROM public.operacion_dinero WHERE id = (dep2->>'operacion_id')::uuid), 'contra-asiento enlazado');
  PERFORM pruebas.debe_fallar(format('UPDATE public.operacion_dinero SET monto_centavos = 1 WHERE id = %L', dep2->>'operacion_id'), 'PROHIBIDO', 'editar una operación');

  -- 7) Traslado caja fuerte -> Caja 1 (30,000) y Caja 1 -> BAC (30,000). El primero ya no se
  --    anula: Caja 1 quedaría en -30,000.
  PERFORM pruebas.como('admin_a');
  tr := public.trasladar_dinero(e, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('CAJA1'), 'monto_centavos', 30000, 'fecha', '2026-01-15'), gen_random_uuid());
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('CAJA1'),
    'destino_id', pruebas.id('BANCO'), 'monto_centavos', 30000, 'fecha', '2026-01-15'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_operacion_dinero(%L, %L, gen_random_uuid())', tr->>'operacion_id', 'Traslado repetido'),
    'SALDO_INSUFICIENTE', 'anular dejaría la caja en negativo');
  -- Final: BAC 950,000 + 30,000 = 980,000; caja fuerte 150,000 - 30,000 = 120,000; Caja 1 0;
  -- caja chica 200,000; tránsito 0. Total 1,300,000 = lo que había al inicio.
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 980000 AND pruebas.dinero('FUERTE') = 120000 AND pruebas.dinero('CAJA1') = 0
    AND pruebas.dinero('CCHICA') = 200000 AND pruebas.dinero('TRANSITO') = 0, 'saldos finales');

  -- 8) Validaciones de tipos y datos.
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'deposito',
    'origen_id', pruebas.id('BANCO'), 'destino_id', pruebas.id('FUERTE'), 'monto_centavos', 1)), 'CUENTA_DINERO_INVALIDA', 'depósito al revés');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'retiro',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'CUENTA_DINERO_INVALIDA', 'retiro al revés');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'reposicion_caja_chica',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'CUENTA_DINERO_INVALIDA', 'reponer un banco');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('FUERTE'), 'monto_centavos', 1)), 'distintas', 'misma cuenta');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('TRANSITO'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'tránsito', 'sacar del tránsito');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 0)), 'mayor que cero', 'monto 0');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 10.5)), 'DATO_INVALIDO', 'monto con decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'))), 'monto', 'sin monto');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1, 'fecha', '2025-12-31')), 'FECHA_ANTERIOR_AL_INICIO', 'antes del inicio');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1, 'banco', 'x')), 'no se reconoce', 'clave desconocida');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, NULL)', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'FALTA_ID_OPERACION', 'sin id_operacion');

  -- 9) Quién puede: cajero, vendedor y contador no mueven dinero.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'SIN_PERMISO', 'cajero traslada');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_deposito(%L, gen_random_uuid())', dep->>'operacion_id'), 'SIN_PERMISO', 'vendedor confirma');

  -- 10) Alerta configurable (solo el dueño): con 365 días ya no hay alerta.
  PERFORM pruebas.como('admin_a');
  dep2 := public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('BANCO'), 'monto_centavos', 20000, 'fecha', '2026-01-20'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"dias_alerta_transito": 365}', 'Más días'), 'SIN_PERMISO', 'admin configura');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"dias_alerta_transito": 61}', 'Más días'), 'DATO_INVALIDO', '61 días');
  PERFORM public.configurar_empresa(e, '{"dias_alerta_transito": 60}', 'El banco tarda');
  PERFORM pruebas.afirmar((SELECT dias_en_transito FROM public.v_deposito_transito WHERE operacion_id = (dep2->>'operacion_id')::uuid)
                          = public.hoy_local(e) - '2026-01-20'::date, 'días en tránsito');
  PERFORM pruebas.afirmar((SELECT alerta FROM public.v_deposito_transito WHERE operacion_id = (dep2->>'operacion_id')::uuid)
                          = (public.hoy_local(e) - '2026-01-20'::date > 60), 'alerta con 60 días');

  -- Rastro = libros en cada cuenta; debe = haber; bitácora intacta.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)), 'rastro = libros');
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea), 'debe = haber');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
