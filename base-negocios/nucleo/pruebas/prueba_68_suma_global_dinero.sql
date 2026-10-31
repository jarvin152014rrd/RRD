-- PRUEBA: cuadre global del dinero en dos empresas tras operaciones de todo tipo: cada cuenta de dinero = saldo contable de su subcuenta; cada línea que toca una cuenta de dinero tiene exactamente un movimiento igual a ella; depósitos en tránsito = saldo de tránsito; arqueos coherentes y diferencias pendientes = cuenta de diferencias de caja; debe = haber
DO $$
DECLARE
  a    uuid := pruebas.empresa('A');
  b    uuid := pruebas.empresa('B');
  bb   uuid;
  cb   uuid;
  t    jsonb;
  g    jsonb;
  c    jsonb;
  p    jsonb;
  d    jsonb;
  emp  uuid;
BEGIN
  -- Empresa A: de todo un poco.
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.preparar_dinero();
  PERFORM pruebas.como('admin_a');
  PERFORM public.trasladar_dinero(a, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('CAJA1'),
    'monto_centavos', 80000), gen_random_uuid());
  PERFORM public.trasladar_dinero(a, jsonb_build_object('tipo', 'reposicion_caja_chica', 'origen_id', pruebas.id('BANCO'),
    'destino_id', pruebas.id('CCHICA')), gen_random_uuid());
  d := public.trasladar_dinero(a, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'),
    'monto_centavos', 70000), gen_random_uuid());
  PERFORM public.confirmar_deposito((d->>'operacion_id')::uuid, gen_random_uuid());
  PERFORM public.trasladar_dinero(a, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'),
    'monto_centavos', 33333), gen_random_uuid());                     -- queda en tránsito
  g := public.registrar_gasto(a, jsonb_build_object('cuenta_dinero_id', pruebas.id('CCHICA'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 12345, 'isv_centavos', 1610, 'descripcion', 'Tóner', 'documento', jsonb_build_object('numero', 'T-1', 'rtn', '08011999000999')),
    gen_random_uuid());
  PERFORM public.anular_gasto((g->>'gasto_id')::uuid, 'Tóner devuelto', gen_random_uuid());
  PERFORM public.registrar_gasto(a, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_ALQ'),
    'monto_centavos', 700000, 'descripcion', 'Alquiler'), gen_random_uuid());          -- pendiente (sobre el tope)
  c := public.registrar_compra(a, pruebas.compra('PROV1', 'B1', 'G-1', public.hoy_local(a), 'credito', 'P1', 7, 1333.33), gen_random_uuid());
  p := public.pagar_proveedor(a, (c->>'compra_id')::uuid, 4321, public.hoy_local(a), NULL, gen_random_uuid(), NULL, NULL, pruebas.id('BANCO'));
  PERFORM public.pagar_proveedor(a, (c->>'compra_id')::uuid, 1234, public.hoy_local(a), NULL, gen_random_uuid(), NULL, NULL, pruebas.id('CCHICA'));
  PERFORM public.anular_pago_proveedor((p->>'pago_id')::uuid, 'Pago repetido', gen_random_uuid());
  PERFORM public.registrar_compra(a, pruebas.compra('PROV2', 'B2', 'G-2', public.hoy_local(a), 'contado', 'P3', 2, 4567.891)
    || jsonb_build_object('cuenta_dinero_id', pruebas.id('FUERTE')), gen_random_uuid());
  -- Turnos: uno con faltante pendiente, uno con sobrante resuelto.
  PERFORM pruebas.como('cajero_a');
  t := public.abrir_turno(a, pruebas.id('CAJA001'), 80000, gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM public.registrar_gasto(a, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 999, 'descripcion', 'Foco'), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  PERFORM public.cerrar_turno((t->>'turno_id')::uuid, 78000, gen_random_uuid());      -- esperado 79,001: faltan 1,001
  PERFORM pruebas.como('admin_a');
  t := public.abrir_turno(a, pruebas.id('CAJA001'), 78000, gen_random_uuid());
  PERFORM public.cerrar_turno((t->>'turno_id')::uuid, 78250, gen_random_uuid());      -- sobran 250
  PERFORM pruebas.como('dueno_a');
  PERFORM public.resolver_diferencia((t->>'turno_id')::uuid, 'otros_ingresos', 'Sobrante del día', gen_random_uuid());

  -- Empresa B: su banco y un gasto.
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (b, 'dinero');
  PERFORM pruebas.como('dueno_b');
  bb := (public.crear_cuenta_dinero(b, '{"tipo":"banco","nombre":"Banpaís","banco":"Banpaís","numero_cuenta":"0011223344"}')->>'cuenta_dinero_id')::uuid;
  PERFORM public.registrar_saldo_inicial_dinero(b, jsonb_build_object('cuenta_dinero_id', bb, 'monto_centavos', 50000), gen_random_uuid());
  cb := (public.crear_categoria_gasto(b, 'Varios', '6.1.02.10')->>'categoria_id')::uuid;
  PERFORM public.registrar_gasto(b, jsonb_build_object('cuenta_dinero_id', bb, 'categoria_id', cb, 'monto_centavos', 7777, 'descripcion', 'Bolsas'),
    gen_random_uuid());
  -- B no usa cuentas de A.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', b, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'),
    'categoria_id', cb, 'monto_centavos', 1, 'descripcion', 'X')), 'CUENTA_DINERO_INVALIDA', 'B usa el banco de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', b, jsonb_build_object('tipo', 'traslado',
    'origen_id', bb, 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'CUENTA_DINERO_INVALIDA', 'B manda dinero a A');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_turno(%L, 1, gen_random_uuid())', t->>'turno_id'), 'NO_PERTENECE', 'B cierra turno de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta_dinero) = 1 AND (SELECT count(*) FROM public.turno_caja) = 0
    AND (SELECT count(*) FROM public.gasto) = 1, 'B solo ve lo suyo');

  -- Revisión global (como el administrador de la base).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea), 'debe = haber');
  -- (1) Suma de cada cuenta de dinero = saldo contable de su subcuenta.
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero x JOIN public.cuenta k ON k.id = x.cuenta_id
                                       WHERE interno.saldo_dinero(x.id) <> pruebas.saldo_libros(x.empresa_id, k.codigo)), 'cuentas de dinero = libros');
  -- (2) Cada línea en una subcuenta de dinero tiene UN movimiento igual (cuenta, monto, fecha), y al revés.
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.asiento_linea l JOIN public.cuenta_dinero x ON x.cuenta_id = l.cuenta_id
      JOIN public.asiento s ON s.id = l.asiento_id
      LEFT JOIN public.dinero_movimiento m ON m.asiento_linea_id = l.id
     WHERE m.id IS NULL OR m.cuenta_dinero_id <> x.id OR m.monto_centavos <> l.debe_centavos - l.haber_centavos
        OR m.fecha_contable <> s.fecha_contable OR m.asiento_id <> l.asiento_id), 'cada línea con su movimiento');
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.dinero_movimiento m JOIN public.asiento_linea l ON l.id = m.asiento_linea_id
      JOIN public.cuenta_dinero x ON x.id = m.cuenta_dinero_id WHERE l.cuenta_id <> x.cuenta_id), 'cada movimiento en su subcuenta');
  -- (3) Depósitos en tránsito = saldo de las cuentas de tránsito (33,333 en A).
  FOREACH emp IN ARRAY ARRAY[a, b] LOOP
    PERFORM pruebas.afirmar(coalesce((SELECT sum(o.monto_centavos) FROM public.operacion_dinero o
                                       WHERE o.empresa_id = emp AND o.tipo = 'deposito' AND o.estado = 'en_transito' AND o.anulada_en IS NULL), 0)
                            = coalesce((SELECT sum(interno.saldo_dinero(x.id)) FROM public.cuenta_dinero x WHERE x.empresa_id = emp AND x.tipo = 'transito'), 0),
      'tránsito = depósitos sin confirmar');
    -- (4) Diferencias pendientes = cuenta de diferencias de caja (faltante 1,001 pendiente en A).
    PERFORM pruebas.afirmar(coalesce((SELECT -sum(x.diferencia_centavos) FROM public.turno_caja x
                                       WHERE x.empresa_id = emp AND x.diferencia_estado = 'pendiente'), 0)
                            = pruebas.saldo_libros(emp, interno.cuenta_de(emp, 'diferencia_caja')), 'diferencias pendientes = libros');
    -- (5) Gastos aplicados: su asiento es por el total y sale de su cuenta de dinero.
    PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.gasto x JOIN public.asiento s ON s.id = x.asiento_id
                                         WHERE x.empresa_id = emp AND (s.total_centavos <> x.monto_centavos
                                           OR NOT EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.asiento_id = s.id
                                                           AND m.cuenta_dinero_id = x.cuenta_dinero_id AND m.monto_centavos = -x.monto_centavos))),
      'gastos = su salida de dinero');
  END LOOP;
  PERFORM pruebas.afirmar(pruebas.saldo_libros(a, '1.1.02.04') = 1001 AND pruebas.saldo_libros(a, '4.2.01.03') = 250, 'cifras de los arqueos');
  -- (6) Arqueos coherentes.
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.estado = 'cerrado' AND (
      x.esperado_centavos <> x.fondo_inicial_centavos + x.entradas_centavos - x.salidas_centavos
      OR x.entradas_centavos <> coalesce((SELECT sum(m.monto_centavos) FROM public.dinero_movimiento m WHERE m.turno_id = x.id AND m.monto_centavos > 0), 0)
      OR x.salidas_centavos <> coalesce((SELECT -sum(m.monto_centavos) FROM public.dinero_movimiento m WHERE m.turno_id = x.id AND m.monto_centavos < 0), 0)
      OR x.diferencia_centavos <> x.contado_centavos - x.esperado_centavos
      OR (x.diferencia_centavos <> 0) <> (x.asiento_diferencia_id IS NOT NULL))), 'arqueos coherentes');
  -- Kardex y CxP siguen cuadrando; bitácora intacta.
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = a) = pruebas.saldo_libros(a, '1.1.03.01'), 'kardex = libros');
  PERFORM pruebas.afirmar(interno.total_cxp(a) = pruebas.saldo_libros(a, '2.1.01.01'), 'CxP = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
