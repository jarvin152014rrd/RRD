-- PRUEBA: turnos de caja por cajero (cifras a mano): un turno abierto por cajero y por caja; el fondo contado debe cuadrar (o se trae la diferencia); esperado = fondo + entradas - salidas del turno; la diferencia queda pendiente y la resuelve otro (admin/dueño) cobrándola al cajero, a gasto o a otros ingresos; el cajero no ve el esperado hasta cerrar; historial por cajero
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  t1  jsonb; t2 jsonb; t3 jsonb; t4 jsonb; t6 jsonb;
  r   jsonb;
  op  uuid := gen_random_uuid();
  v   record;
BEGIN
  PERFORM pruebas.preparar_dinero();
  -- Inicio: caja fuerte 300,000; Caja 1 (caja 001) 0.

  -- 1) El cajero cuenta 50,000 pero la caja tiene 0 en el sistema: no abre.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 50000, gen_random_uuid())', e, pruebas.id('CAJA001')),
    'FONDO_NO_CUADRA', 'fondo sin respaldo');
  -- Traer la diferencia pide dinero.trasladar (el cajero no lo tiene).
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 50000, gen_random_uuid(), %L)', e, pruebas.id('CAJA001'),
    jsonb_build_object('cuenta_origen_id', pruebas.id('FUERTE'))), 'SIN_PERMISO', 'cajero trae el fondo');

  -- 2) El admin pasa 50,000 de la caja fuerte a la Caja 1 (fuera de turno). Caja fuerte 250,000.
  PERFORM pruebas.como('admin_a');
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('CAJA1'), 'monto_centavos', 50000, 'referencia', 'Fondo de caja'), gen_random_uuid());

  -- 3) Turno 1 del cajero: fondo por conteo, 5 billetes de L 100 = 50,000.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 40000, gen_random_uuid(), %L)', e, pruebas.id('CAJA001'),
    '{"conteo":[{"denominacion_centavos":10000,"cantidad":5}]}'), 'suma del conteo', 'monto distinto del conteo');
  t1 := public.abrir_turno(e, pruebas.id('CAJA001'), NULL, op, '{"conteo":[{"denominacion_centavos":10000,"cantidad":5}], "equipo":"Caja 1"}');
  PERFORM pruebas.afirmar(t1->>'estado' = 'abierto' AND (t1->>'fondo_inicial_centavos')::bigint = 50000
    AND (t1->>'cuenta_dinero_id')::uuid = pruebas.id('CAJA1'), 'turno 1 abierto: ' || t1::text);
  PERFORM pruebas.afirmar((public.abrir_turno(e, pruebas.id('CAJA001'), NULL, op, '{"conteo":[{"denominacion_centavos":10000,"cantidad":5}]}')->>'duplicado')::boolean,
    'reintento de apertura');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 50000, gen_random_uuid())', e, pruebas.id('CAJA001')), 'TURNO_YA_ABIERTO', 'dos turnos del cajero');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 50000, gen_random_uuid())', e, pruebas.id('CAJA001')), 'CAJA_OCUPADA', 'caja ocupada');

  -- 4) Durante el turno (las hace el admin): entra 10,000 de la caja fuerte; sale un depósito
  --    de 20,000 al BAC y un gasto de luz de 5,000.
  --    Esperado = 50,000 + 10,000 - 20,000 - 5,000 = 35,000.
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('CAJA1'), 'monto_centavos', 10000, 'referencia', 'Cambio'), gen_random_uuid());
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('CAJA1'),
    'destino_id', pruebas.id('BANCO'), 'monto_centavos', 20000), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 5000, 'descripcion', 'Recibo de luz'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 35000, 'Caja 1 en 35,000');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.dinero_movimiento WHERE turno_id = (t1->>'turno_id')::uuid) = 3,
    'tres movimientos marcados con el turno');

  -- 5) El cajero ve SU turno, sin esperado (conteo a ciegas); no ve cuentas de dinero.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_turno_caja) = 1
    AND (SELECT esperado_centavos FROM public.v_turno_caja) IS NULL, 'cajero ve su turno sin esperado');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta_dinero) = 0 AND (SELECT count(*) FROM public.dinero_movimiento) = 0,
    'cajero no ve cuentas ni movimientos');
  r := public.mi_turno(e);
  PERFORM pruebas.afirmar(r->'turno'->>'turno_id' = t1->>'turno_id' AND NOT (r->'turno' ? 'esperado_centavos'), 'mi_turno');

  -- 6) Cierre: cuenta 3 x L 100 + 2 x L 20 = 34,000. Diferencia 34,000 - 35,000 = -1,000 (falta).
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_turno(%L, 34000, gen_random_uuid(), %L)', t1->>'turno_id',
    '{"conteo":[{"denominacion_centavos":10000,"cantidad":3},{"denominacion_centavos":10000,"cantidad":1}]}'), 'repetida', 'denominación repetida');
  -- El id de la apertura no sirve para cerrar (otro tipo de operación).
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_turno(%L, 34000, %L)', t1->>'turno_id', op), 'ID_OPERACION_USADO', 'id de la apertura');
END $$;

DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  t1  uuid;
  t2  jsonb; t3 jsonb; t4 jsonb; t5 jsonb; t6 jsonb;
  r   jsonb;
  op  uuid := gen_random_uuid();
  v   record;
BEGIN
  SELECT id INTO t1 FROM public.turno_caja WHERE empresa_id = e AND numero = 1;
  PERFORM pruebas.como('cajero_a');
  r := public.cerrar_turno(t1, NULL, op,
         '{"conteo":[{"denominacion_centavos":10000,"cantidad":3},{"denominacion_centavos":2000,"cantidad":2}], "nota":"Cierre de la tarde"}');
  PERFORM pruebas.afirmar((r->>'entradas_centavos')::bigint = 10000 AND (r->>'salidas_centavos')::bigint = 25000
    AND (r->>'esperado_centavos')::bigint = 35000 AND (r->>'contado_centavos')::bigint = 34000
    AND (r->>'diferencia_centavos')::bigint = -1000 AND r->>'diferencia_estado' = 'pendiente', 'arqueo: ' || r::text);
  -- La caja queda con lo contado; el faltante espera en 1.1.02.04.
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 34000 AND pruebas.dinero_libros('CAJA1') = 34000
    AND pruebas.saldo_libros(e, '1.1.02.04') = 1000, 'caja 34,000 y 1,000 por resolver');
  PERFORM pruebas.afirmar((public.cerrar_turno(t1, 34000, op)->>'duplicado')::boolean, 'reintento del cierre');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_turno(%L, 34000, gen_random_uuid())', t1), 'TURNO_CERRADO', 'cerrar dos veces');
  PERFORM pruebas.afirmar((SELECT esperado_centavos FROM public.v_turno_caja WHERE turno_id = t1) = 35000, 'ya cerrado, ve el esperado');
  -- La diferencia no se puede pasar por fuera con un asiento manual (cuenta del módulo).
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, public.hoy_local(e), pruebas.lineas('6.1.02.10', '1.1.02.04', 1000)),
    'CUENTA_CONTROLADA', 'asiento manual a diferencias de caja');

  -- 7) Resolver: el cajero no; un faltante no va a otros ingresos; el admin lo cobra al cajero.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_diferencia(%L, %L, %L, gen_random_uuid())', t1, 'gasto', 'Se perdió'), 'SIN_PERMISO', 'cajero resuelve');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_diferencia(%L, %L, %L, gen_random_uuid())', t1, 'otros_ingresos', 'Error de cálculo'),
    'DATO_INVALIDO', 'faltante a ingresos');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_diferencia(%L, %L, %L, gen_random_uuid())', t1, 'gasto', 'no'), 'FALTA_MOTIVO', 'sin motivo');
  r := public.resolver_diferencia(t1, 'cobrar_al_cajero', 'Faltante reconocido por el cajero', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'diferencia_estado' = 'resuelta' AND pruebas.saldo_libros(e, '1.1.02.05') = 1000
    AND pruebas.saldo_libros(e, '1.1.02.04') = 0, 'cobrado al cajero: CxC empleados 1,000');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_diferencia(%L, %L, %L, gen_random_uuid())', t1, 'gasto', 'Otra vez'), 'YA_RESUELTO', 'resolver dos veces');

  -- 8) Turno 2 del admin: fondo 34,000, cuenta 34,500 (sobran 500). Él no resuelve su propio turno; el dueño sí.
  t2 := public.abrir_turno(e, pruebas.id('CAJA001'), 34000, gen_random_uuid());
  r := public.cerrar_turno((t2->>'turno_id')::uuid, 34500, gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'diferencia_centavos')::bigint = 500 AND pruebas.saldo_libros(e, '1.1.02.04') = -500, 'sobrante 500');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_diferencia(%L, %L, %L, gen_random_uuid())', t2->>'turno_id', 'otros_ingresos', 'Sobró'),
    'PROHIBIDO', 'resolver su propio turno');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_diferencia(%L, %L, %L, gen_random_uuid())', t2->>'turno_id', 'gasto', 'Sobró'),
    'DATO_INVALIDO', 'sobrante a gasto');
  PERFORM public.resolver_diferencia((t2->>'turno_id')::uuid, 'otros_ingresos', 'Sobrante sin explicación', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '4.2.01.03') = 500 AND pruebas.saldo_libros(e, '1.1.02.04') = 0, 'sobrante a otros ingresos');

  -- 9) Turno 3 del cajero: fondo 34,500, cuenta 34,000 (faltan 500): el dueño lo manda a gasto.
  PERFORM pruebas.como('cajero_a');
  t3 := public.abrir_turno(e, pruebas.id('CAJA001'), 34500, gen_random_uuid());
  r := public.cerrar_turno((t3->>'turno_id')::uuid, 34000, gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.resolver_diferencia((t3->>'turno_id')::uuid, 'gasto', 'Billete falso', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '6.1.02.11') = 500, 'faltante a gasto 500');

  -- 10) Un supervisor cierra el turno de otro; el cajero no cierra el de otro; sin diferencia no hay nada que resolver.
  PERFORM pruebas.como('cajero_a');
  t4 := public.abrir_turno(e, pruebas.id('CAJA001'), 34000, gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_caja(%L, %L, %L)', e, pruebas.id('CAJA001'), 'Caja dañada'), 'NO_PERMITIDO', 'desactivar caja con turno abierto');
  r := public.cerrar_turno((t4->>'turno_id')::uuid, 34000, gen_random_uuid(), '{"nota":"El cajero se fue sin cerrar"}');
  PERFORM pruebas.afirmar(r->>'diferencia_estado' = 'sin_diferencia', 'cerrado por el supervisor, sin diferencia');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_diferencia(%L, %L, %L, gen_random_uuid())', t4->>'turno_id', 'gasto', 'Nada que resolver'), 'NO_PERMITIDO', 'sin diferencia');
  t5 := public.abrir_turno(e, pruebas.id('CAJA001'), 34000, gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_turno(%L, 34000, gen_random_uuid())', t5->>'turno_id'), 'SIN_PERMISO', 'cajero cierra turno ajeno');
  PERFORM pruebas.como('admin_a');
  PERFORM public.cerrar_turno((t5->>'turno_id')::uuid, 34000, gen_random_uuid());

  -- 11) Fondo con diferencia traída de la caja fuerte: Caja 1 tiene 34,000 y el turno abre con 40,000:
  --     la apertura trae 6,000 (traslado aparte, NO cuenta como entrada del turno).
  t6 := public.abrir_turno(e, pruebas.id('CAJA001'), 40000, gen_random_uuid(), jsonb_build_object('cuenta_origen_id', pruebas.id('FUERTE')));
  r := public.cerrar_turno((t6->>'turno_id')::uuid, 40000, gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'entradas_centavos')::bigint = 0 AND (r->>'esperado_centavos')::bigint = 40000
    AND r->>'diferencia_estado' = 'sin_diferencia', 'fondo traído: ' || r::text);
  -- Caja fuerte: 300,000 - 50,000 - 10,000 - 6,000 = 234,000. Caja 1: 40,000.
  PERFORM pruebas.afirmar(pruebas.dinero('FUERTE') = 234000 AND pruebas.dinero('CAJA1') = 40000, 'saldos después del turno 6');
  -- Al revés: el turno 7 abre con 30,000 y sobran 10,000, que vuelven a la caja fuerte (244,000).
  t6 := public.abrir_turno(e, pruebas.id('CAJA001'), 30000, gen_random_uuid(), jsonb_build_object('cuenta_origen_id', pruebas.id('FUERTE')));
  r := public.cerrar_turno((t6->>'turno_id')::uuid, 30000, gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'salidas_centavos')::bigint = 0 AND pruebas.dinero('FUERTE') = 244000 AND pruebas.dinero('CAJA1') = 30000,
    'sobraba para el fondo: vuelve a la caja fuerte');

  -- 12) Historial por cajero (cifras): cajero 3 turnos (t1, t3, t4), faltantes 1,500, cobrado 1,000, a gasto 500;
  --     admin 4 turnos (t2, t5, t6, t7), sobrante 500 a otros ingresos.
  SELECT * INTO v FROM public.v_diferencia_cajero WHERE cajero_id = pruebas.usuario('cajero_a');
  PERFORM pruebas.afirmar(v.turnos = 3 AND v.turnos_con_diferencia = 2 AND v.faltantes_centavos = 1500 AND v.sobrantes_centavos = 0
    AND v.cobrado_al_cajero_centavos = 1000 AND v.enviado_a_gasto_centavos = 500 AND v.pendiente_neto_centavos = 0, 'historial cajero');
  SELECT * INTO v FROM public.v_diferencia_cajero WHERE cajero_id = pruebas.usuario('admin_a');
  PERFORM pruebas.afirmar(v.turnos = 4 AND v.sobrantes_centavos = 500 AND v.a_otros_ingresos_centavos = 500, 'historial admin');
  PERFORM pruebas.afirmar((SELECT cajero FROM public.v_turno_caja WHERE turno_id = t1) = 'cajero_a@prueba.hn', 'nombre del cajero');

  -- Arqueos coherentes y rastro = libros.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.turno_caja SET contado_centavos = 1 WHERE id = %L', t1), 'PROHIBIDO', 'editar un turno');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.turno_caja t WHERE t.estado = 'cerrado' AND (
      t.esperado_centavos <> t.fondo_inicial_centavos + t.entradas_centavos - t.salidas_centavos
      OR t.entradas_centavos <> coalesce((SELECT sum(m.monto_centavos) FROM public.dinero_movimiento m WHERE m.turno_id = t.id AND m.monto_centavos > 0), 0)
      OR t.salidas_centavos <> coalesce((SELECT -sum(m.monto_centavos) FROM public.dinero_movimiento m WHERE m.turno_id = t.id AND m.monto_centavos < 0), 0)
      OR t.diferencia_centavos <> t.contado_centavos - t.esperado_centavos)), 'arqueos coherentes');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)), 'rastro = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
