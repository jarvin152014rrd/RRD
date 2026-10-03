-- PRUEBA: cuentas de dinero: crear una crea su subcuenta 1.1.01.NN; número de banco enmascarado; moneda de la empresa; su subcuenta no acepta asientos manuales ni movimientos sin rastro; editar, desactivar (solo en 0) y reactivar; saldo inicial solo del dueño, una vez, contra Saldos de apertura o una cuenta de efectivo sin rastro
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  r    jsonb;
  ok   boolean;
  bco  uuid;
  si   jsonb;
  v_c  text;
BEGIN
  -- Sin el módulo "dinero" activo no se crea nada.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"banco","nombre":"X","banco":"Y"}'),
    'MODULO_INACTIVO', 'módulo inactivo');

  PERFORM pruebas.preparar_dinero();
  PERFORM pruebas.como('superusuario');
  -- Subcuentas en orden bajo 1.1.01 (01-03 son de la plantilla): Caja 1 = .04, Caja fuerte = .05, BAC = .06, Caja chica = .07.
  PERFORM pruebas.afirmar((SELECT string_agg(d.nombre || '=' || c.codigo, ', ' ORDER BY c.codigo)
                             FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.empresa_id = e)
    = 'Caja 1=1.1.01.04, Caja fuerte=1.1.01.05, BAC cheques=1.1.01.06, Caja chica=1.1.01.07', 'subcuentas en orden');
  PERFORM pruebas.afirmar((SELECT numero_enmascarado || '/' || moneda || '/' || tipo_cuenta FROM public.cuenta_dinero WHERE id = pruebas.id('BANCO'))
    = '****6789/HNL/cheques', 'banco enmascarado, HNL, cheques');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'cuenta_dinero' AND despues::text LIKE '%7301%'),
    'el número completo no queda guardado en ningún lado');
  PERFORM pruebas.afirmar((SELECT caja_id FROM public.cuenta_dinero WHERE id = pruebas.id('CAJA1')) = pruebas.id('CAJA001'), 'caja ligada');
  -- Saldos iniciales: BAC 1,000,000 y caja fuerte 300,000 contra 3.3.01.03.
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 1000000 AND pruebas.dinero_libros('BANCO') = 1000000, 'BAC 1,000,000 = libros');
  PERFORM pruebas.afirmar(pruebas.dinero('FUERTE') = 300000 AND pruebas.saldo_libros(e, '3.3.01.03') = 1300000, 'apertura 1,300,000');
  PERFORM pruebas.afirmar((SELECT contrapartida FROM public.dinero_movimiento WHERE cuenta_dinero_id = pruebas.id('BANCO'))
    = '3.3.01.03 Saldos de apertura', 'contrapartida del saldo inicial');

  -- Validaciones al crear.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"banco","nombre":"Ficohsa"}'), 'banco', 'banco sin nombre de banco');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"banco","nombre":"Ficohsa","banco":"Ficohsa","moneda":"USD"}'),
    'MONEDA_NO_SOPORTADA', 'cuenta en dólares');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"banco","nombre":"Ficohsa","banco":"Ficohsa","numero_cuenta":"12AB"}'),
    'DATO_INVALIDO', 'número con letras');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"caja_chica","nombre":"Chica 2"}'), 'fondo fijo', 'caja chica sin fondo');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"caja_fuerte","nombre":"X"}'), 'DATO_INVALIDO', 'tipo inventado');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"banco","nombre":"bac CHEQUES","banco":"BAC"}'), 'YA_EXISTE', 'nombre repetido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e,
    jsonb_build_object('tipo', 'efectivo_caja', 'nombre', 'Otra', 'caja_id', pruebas.id('CAJA001'))), 'YA_EXISTE', 'caja con dos cuentas');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e,
    jsonb_build_object('tipo', 'banco', 'nombre', 'Otra', 'banco', 'X', 'caja_id', pruebas.id('CAJA001'))), 'DATO_INVALIDO', 'banco ligado a caja');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"pos_por_liquidar","nombre":"POS","fondo_fijo_centavos":5}'),
    'DATO_INVALIDO', 'fondo fijo fuera de caja chica');
  bco := (public.crear_cuenta_dinero(e, '{"tipo":"banco","nombre":"Ficohsa ahorro","banco":"Ficohsa","numero_cuenta":"200-0012345","tipo_cuenta":"ahorro"}')->>'cuenta_dinero_id')::uuid;
  PERFORM pruebas.afirmar((SELECT numero_enmascarado FROM public.cuenta_dinero WHERE id = bco) = '****2345', 'enmascarado ****2345');

  -- Su subcuenta no acepta asientos manuales (ni del dueño). Tampoco se anula por fuera un asiento del módulo.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-05', pruebas.lineas('1.1.01.06', '4.1.01.01', 1000)), 'CUENTA_CONTROLADA', 'asiento manual a BAC');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-05', pruebas.lineas('6.1.02.10', '1.1.01.05', 1000)), 'CUENTA_CONTROLADA', 'asiento manual a caja fuerte');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)',
    (SELECT asiento_id FROM public.operacion_dinero WHERE destino_id = pruebas.id('BANCO') AND tipo = 'saldo_inicial'), 'Por fuera'),
    'PROHIBIDO', 'anular por fuera el saldo inicial');
  -- Las cuentas de efectivo de la plantilla (sin rastro) siguen aceptando asientos manuales.
  PERFORM public.registrar_asiento(e, '2026-01-05', 'Venta en caja general', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid());

  -- Un módulo que mueve una cuenta de dinero SIN su rastro: no se guarda (MOVIMIENTO_SIN_RASTRO).
  PERFORM pruebas.como('superusuario');
  ok := false;
  BEGIN
    PERFORM interno.asiento_sistema(e, NULL, '2026-01-05', 'Sin rastro', 'prueba', gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('cuenta', '1.1.01.06', 'debe', 500), jsonb_build_object('cuenta', '4.1.01.01', 'haber', 500)));
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    ok := SQLERRM LIKE 'MOVIMIENTO_SIN_RASTRO%';
  END;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM pruebas.afirmar(ok, 'asiento a una cuenta de dinero sin movimiento se rechaza');
  PERFORM pruebas.debe_fallar('UPDATE public.dinero_movimiento SET monto_centavos = 1', 'PROHIBIDO', 'editar el rastro');
  PERFORM pruebas.debe_fallar('DELETE FROM public.dinero_movimiento', 'PROHIBIDO', 'borrar el rastro');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.cuenta_dinero WHERE id = %L', bco), 'PROHIBIDO', 'borrar una cuenta de dinero');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cuenta_dinero SET tipo = %L WHERE id = %L', 'caja_chica', bco), 'PROHIBIDO', 'cambiar el tipo');

  -- Editar: nombre (también el de la subcuenta) y fondo fijo (no menor que el saldo).
  PERFORM pruebas.como('admin_a');
  PERFORM public.editar_cuenta_dinero(e, bco, '{"nombre":"Ficohsa ahorro 2","numero_cuenta":"200-0019999"}', 'Cambió el número');
  PERFORM pruebas.afirmar((SELECT d.nombre || '/' || c.nombre || '/' || d.numero_enmascarado FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                            WHERE d.id = bco) = 'Ficohsa ahorro 2/Ficohsa ahorro 2/****9999', 'editada con su subcuenta');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_cuenta_dinero(%L, %L, %L, %L)', e, bco, '{"nombre":"X"}', 'no'), 'FALTA_MOTIVO', 'editar sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_cuenta_dinero(%L, %L, %L, %L)', e, bco, '{"fondo_fijo_centavos":5}', 'Fondo nuevo'), 'caja chica', 'fondo en banco');

  -- Desactivar: con saldo no; en cero sí (y su subcuenta). Reactivar.
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_cuenta_dinero(%L, %L, %L)', e, pruebas.id('BANCO'), 'Se cerró la cuenta'), 'NO_PERMITIDO', 'desactivar con saldo');
  r := public.desactivar_cuenta_dinero(e, bco, 'No se usa todavía');
  PERFORM pruebas.afirmar(NOT (r->>'activa')::boolean AND NOT (SELECT c.activa FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = bco),
    'desactivada con su subcuenta');
  PERFORM pruebas.afirmar((public.desactivar_cuenta_dinero(e, bco, 'No se usa todavía')->>'ya_estaba')::boolean, 'desactivar dos veces');
  PERFORM public.reactivar_cuenta_dinero(e, bco, 'Ya se va a usar');
  PERFORM pruebas.afirmar((SELECT d.activa AND c.activa FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = bco), 'reactivada');

  -- Saldo inicial: solo el dueño; una vez; contrapartida válida.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_dinero(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 100)), 'SIN_PERMISO', 'admin carga saldo inicial');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_dinero(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'monto_centavos', 100)), 'SALDO_INICIAL_YA_CARGADO', 'dos saldos iniciales');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_dinero(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 100, 'contrapartida', '4.1.01.01')), 'CUENTA_INVALIDA', 'contra ventas');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_dinero(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 100, 'contrapartida', '1.1.01.06')), 'CUENTA_INVALIDA', 'contra otra cuenta de dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_dinero(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cuenta_dinero_id', pruebas.id('CCHICA'), 'monto_centavos', 200001)), 'TOPE_CAJA_CHICA', 'caja chica sobre su fondo');
  -- Pasar el saldo de la caja general SIN rastro (1.1.01.01 tiene 1,000) al Ficohsa: Dr 1.1.01.0x / Cr 1.1.01.01.
  si := public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 1000,
          'contrapartida', '1.1.01.01', 'fecha', '2026-01-06'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.01') = 0 AND (si->>'saldo_destino_centavos')::bigint = 1000, 'saldo pasado de la caja general');
  -- Anular el saldo inicial (dueño, con motivo): vuelve a la caja general; luego se puede cargar otra vez.
  r := public.anular_operacion_dinero((si->>'operacion_id')::uuid, 'Era de otra cuenta', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.01') = 1000 AND (r->>'saldo_destino_centavos')::bigint = 0, 'saldo inicial anulado');
  PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 700), gen_random_uuid());

  -- Rastro = libros en cada cuenta; bitácora intacta.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)), 'rastro = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
