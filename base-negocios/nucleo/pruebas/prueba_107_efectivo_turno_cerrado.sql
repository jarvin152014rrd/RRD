-- PRUEBA: (0.9.1, importante 6, decisión del dueño) el efectivo de anulaciones y devoluciones sale del turno abierto de quien hace la operación, a su nombre, con referencia al turno original (turno_origen_id); nadie saca dinero del turno de otro cajero (TURNO_AJENO); sin turno propio y turnos obligatorios, SIN_TURNO_ABIERTO; el turno cerrado no se toca; la anulación pedida por el cajero sale de su turno si sigue abierto
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  caj2 uuid;
  t1   jsonb;
  t2   jsonb;
  v1   jsonb; v2 jsonb; v3 jsonb; v4 jsonb;
  c1   jsonb;
  s3   jsonb; s4 jsonb;
  d    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);   -- turnos obligatorios (lo de siempre); Caja 1 en 0, caja fuerte 300,000
  caj2 := (public.crear_caja(e, (SELECT id FROM public.sucursal WHERE empresa_id = e AND codigo = '001'), 'Caja 2', '002')->>'caja_id')::uuid;

  -- Turno T1 del cajero en la caja 001 (fondo 0). Vende V1 (2 tornillos, 3,000), V3 y V4 (1 tornillo, 1,500 c/u)
  -- y cobra en efectivo C1 = 4,500 de V2 (3 tornillos al crédito que vendió el dueño a CLI2). En T1: 10,500.
  PERFORM pruebas.como('cajero_a');
  t1 := public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid());
  v1 := public.registrar_venta(e, pruebas.venta('P1', 2), gen_random_uuid());
  v3 := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  v4 := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 3, 'credito', 'CLI2') || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  c1 := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"efectivo","monto_centavos":4500}]'::jsonb),
          gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 10500, 'T1 con 10,500');

  -- 1) El cajero pide anular V4 y el admin la aprueba con T1 ABIERTO: los 1,500 salen del turno de quien la pidió (T1).
  s4 := public.solicitar_anulacion_venta((v4->>'venta_id')::uuid, 'Cobrada dos veces', gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM public.resolver_aprobacion((s4->>'aprobacion_id')::uuid, true, 'Revisado con el cajero', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 9000 AND (SELECT m.turno_id FROM public.dinero_movimiento m
    WHERE m.documento_id = (v4->>'venta_id')::uuid AND m.operacion = 'anulacion_venta') = (t1->>'turno_id')::uuid, 'V4: sale de T1 (9,000)');

  -- 2) El admin, sin turno, quiere anular C1 mientras T1 está abierto: nadie saca dinero del turno de otro cajero.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c1->>'cobro_id', 'Cobro duplicado'),
    'TURNO_AJENO', 'turno de otro cajero');

  -- 3) El cajero pide anular V3 y cierra T1 contando 9,000.
  PERFORM pruebas.como('cajero_a');
  s3 := public.solicitar_anulacion_venta((v3->>'venta_id')::uuid, 'El cliente se arrepintió', gen_random_uuid());
  PERFORM public.cerrar_turno((t1->>'turno_id')::uuid, 9000, gen_random_uuid());

  -- 4) Con T1 cerrado y sin turno propio (turnos obligatorios): no sale de ninguna parte.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c1->>'cobro_id', 'Cobro duplicado'),
    'SIN_TURNO_ABIERTO', 'sin turno propio');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', s3->>'aprobacion_id', 'Aprobada'),
    'SIN_TURNO_ABIERTO', 'aprobar anulación sin turno propio');

  -- 5) El admin abre SU turno T2 en la Caja 2 con 10,000 traídos de la caja fuerte y anula: sale de T2, a su nombre,
  --    con referencia a T1. Caja 2: 10,000 - 4,500 (C1) - 1,500 (V3) = 4,000. Caja 1 (T1 cerrado) sigue con 9,000.
  t2 := public.abrir_turno(e, caj2, 10000, gen_random_uuid(), jsonb_build_object('cuenta_origen_id', pruebas.id('FUERTE')));
  PERFORM public.anular_cobro((c1->>'cobro_id')::uuid, 'Cobro duplicado', gen_random_uuid());
  PERFORM public.resolver_aprobacion((s3->>'aprobacion_id')::uuid, true, 'Aprobada', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_dinero((t2->>'cuenta_dinero_id')::uuid) = 4000 AND pruebas.dinero('CAJA1') = 9000, 'sale de T2; T1 intacto');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.dinero_movimiento m
    WHERE m.documento_id IN ((c1->>'cobro_id')::uuid, (v3->>'venta_id')::uuid) AND m.monto_centavos < 0
      AND m.cuenta_dinero_id = (t2->>'cuenta_dinero_id')::uuid AND m.turno_id = (t2->>'turno_id')::uuid
      AND m.turno_origen_id = (t1->>'turno_id')::uuid AND m.creado_por = pruebas.usuario('admin_a')) = 2,
    'a nombre del admin, en T2, con referencia a T1');

  -- 6) Devolución de 1 tornillo de V1 (1,500) en dinero: el dueño sin turno, ni de la Caja 1 (sin turno) ni de la Caja 2 (turno del admin).
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Defectuoso', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1'))),
    'SIN_TURNO_ABIERTO', 'devolución de una caja sin turno');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', v1->>'venta_id', jsonb_build_object(
    'lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Defectuoso', 'destino', 'dinero', 'cuenta_dinero_id', t2->>'cuenta_dinero_id')),
    'TURNO_AJENO', 'devolución desde el turno de otro');
  --    El admin sí, desde su T2 (queda 2,500), con referencia a T1 (donde se cobró V1).
  PERFORM pruebas.como('admin_a');
  d := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Defectuoso', 'destino', 'dinero', 'cuenta_dinero_id', t2->>'cuenta_dinero_id'), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(d->>'estado' = 'aplicada' AND interno.saldo_dinero((t2->>'cuenta_dinero_id')::uuid) = 2500
    AND (SELECT m.turno_origen_id FROM public.dinero_movimiento m WHERE m.documento_id = (d->>'devolucion_id')::uuid) = (t1->>'turno_id')::uuid,
    'devolución desde T2 con referencia a T1');

  -- Cuadre: dinero = libros; las salidas de T2 (las que entran a su arqueo) son 4,500 + 1,500 + 1,500 = 7,500.
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero x JOIN public.cuenta c ON c.id = x.cuenta_id
                                       WHERE interno.saldo_dinero(x.id) <> pruebas.saldo_libros(x.empresa_id, c.codigo))
    AND (SELECT sum(m.monto_centavos) FROM public.dinero_movimiento m WHERE m.turno_id = (t2->>'turno_id')::uuid AND m.monto_centavos < 0) = -7500,
    'cuadre');
END $$;
