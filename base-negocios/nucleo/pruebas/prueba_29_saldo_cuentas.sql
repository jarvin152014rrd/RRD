-- PRUEBA: saldo_cuentas(desde, hasta) da saldo inicial, movimiento y saldo final correctos (cifras calculadas a mano)
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  r jsonb;
  v record;
BEGIN
  PERFORM pruebas.como('dueno_a');
  -- Enero
  PERFORM public.registrar_asiento(e, '2026-01-05', 'Capital inicial', pruebas.lineas('1.1.01.03', '3.1.01.01', 10000000), gen_random_uuid());  -- L 100,000.00
  PERFORM public.registrar_asiento(e, '2026-01-20', 'Venta con ISV',
    '[{"cuenta":"1.1.01.01","debe":115000},{"cuenta":"4.1.01.01","haber":100000},{"cuenta":"2.1.02.01","haber":15000}]', gen_random_uuid());
  r := public.registrar_asiento(e, '2026-01-25', 'Pago de luz', pruebas.lineas('6.1.02.02', '1.1.01.01', 85000), gen_random_uuid());
  -- Febrero
  PERFORM public.registrar_asiento(e, '2026-02-10', 'Venta con ISV',
    '[{"cuenta":"1.1.01.01","debe":230000},{"cuenta":"4.1.01.01","haber":200000},{"cuenta":"2.1.02.01","haber":30000}]', gen_random_uuid());
  PERFORM public.registrar_asiento(e, '2026-02-15', 'Alquiler', pruebas.lineas('6.1.02.01', '1.1.01.03', 500000), gen_random_uuid());
  PERFORM public.anular_asiento((r->>'asiento_id')::uuid, 'La luz la pagó el dueño', NULL, '2026-02-20');  -- reversa en febrero
  -- Marzo (fuera del rango de febrero)
  PERFORM public.registrar_asiento(e, '2026-03-01', 'Venta marzo',
    '[{"cuenta":"1.1.01.01","debe":11500},{"cuenta":"4.1.01.01","haber":10000},{"cuenta":"2.1.02.01","haber":1500}]', gen_random_uuid());

  -- FEBRERO, a mano:
  --   Caja 1.1.01.01:  inicial 115000-85000 = 30000; debe 230000+85000 = 315000; final 345000
  --   Bancos:          inicial 10000000; haber 500000; final 9500000
  --   Ventas:          inicial 100000; haber 200000; movimiento 200000; final 300000
  --   ISV por pagar:   inicial 15000; movimiento 30000; final 45000
  --   Luz:             inicial 85000; haber 85000 (anulación); movimiento -85000; final 0
  --   Alquiler:        movimiento 500000; final 500000
  FOR v IN SELECT * FROM (VALUES
      ('1.1.01.01',    30000::bigint, 315000::bigint,      0::bigint,  315000::bigint,   345000::bigint),
      ('1.1.01.03', 10000000,              0,         500000,         -500000,          9500000),
      ('4.1.01.01',   100000,              0,         200000,          200000,           300000),
      ('2.1.02.01',    15000,              0,          30000,           30000,            45000),
      ('6.1.02.02',    85000,              0,          85000,          -85000,                0),
      ('6.1.02.01',        0,         500000,              0,          500000,           500000),
      ('3.1.01.01', 10000000,              0,              0,               0,         10000000))
      AS t(codigo, ini, debe, haber, mov, fin)
  LOOP
    PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.saldo_cuentas(e, '2026-02-01', '2026-02-28') s
      WHERE s.codigo = v.codigo AND s.saldo_inicial_centavos = v.ini AND s.debe_centavos = v.debe
        AND s.haber_centavos = v.haber AND s.movimiento_centavos = v.mov AND s.saldo_final_centavos = v.fin),
      'febrero cuenta ' || v.codigo || ': ' || coalesce((SELECT row_to_json(s)::text FROM public.saldo_cuentas(e, '2026-02-01', '2026-02-28') s WHERE s.codigo = v.codigo), 'no está'));
  END LOOP;

  -- Resultado de febrero: ingresos 200000 - gastos (500000 - 85000) = -215000 (pérdida).
  PERFORM pruebas.afirmar((SELECT sum(CASE WHEN tipo = 'ingreso' THEN movimiento_centavos ELSE -movimiento_centavos END)
                           FROM public.saldo_cuentas(e, '2026-02-01', '2026-02-28') WHERE tipo IN ('ingreso','costo','gasto')) = -215000,
                          'resultado de febrero = -215000');
  -- Balance al 28/02: activo 345000 + 9500000 = 9845000 = pasivo 45000 + capital 10000000 + resultado acumulado (300000 - 500000).
  PERFORM pruebas.afirmar((SELECT sum(saldo_final_centavos) FROM public.saldo_cuentas(e, NULL, '2026-02-28') WHERE tipo = 'activo') = 9845000, 'activo = 9845000');
  PERFORM pruebas.afirmar((SELECT sum(CASE WHEN tipo IN ('pasivo','patrimonio','ingreso') THEN saldo_final_centavos ELSE -saldo_final_centavos END)
                           FROM public.saldo_cuentas(e, NULL, '2026-02-28') WHERE tipo <> 'activo') = 9845000, 'activo = pasivo + patrimonio + resultado');
  -- En el rango, debe = haber.
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.saldo_cuentas(e, '2026-02-01', '2026-02-28')), 'febrero cuadra');

  -- ENERO: caja final 30000, luz 85000.
  PERFORM pruebas.afirmar((SELECT saldo_final_centavos FROM public.saldo_cuentas(e, '2026-01-01', '2026-01-31') WHERE codigo = '1.1.01.01') = 30000, 'caja enero');
  PERFORM pruebas.afirmar((SELECT movimiento_centavos FROM public.saldo_cuentas(e, '2026-01-01', '2026-01-31') WHERE codigo = '6.1.02.02') = 85000, 'luz enero');
  -- Desde el principio hasta marzo = la vista de saldos: caja 345000 + 11500 = 356500.
  PERFORM pruebas.afirmar((SELECT saldo_final_centavos FROM public.saldo_cuentas(e, NULL, '2026-03-31') WHERE codigo = '1.1.01.01') = 356500, 'caja a marzo');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.saldo_cuentas(e, NULL, '2026-12-31') s
                                      JOIN public.v_saldo_cuenta vs ON vs.cuenta_id = s.cuenta_id
                                      WHERE vs.saldo_centavos <> s.saldo_final_centavos), 'coincide con v_saldo_cuenta');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.saldo_cuentas(e, '2026-02-01', '2026-02-28'))
                          = (SELECT count(*) FROM public.cuenta WHERE empresa_id = e AND es_detalle), 'todas las cuentas de detalle');

  -- Errores y permisos.
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.saldo_cuentas(%L, %L, %L)', e, '2026-03-01', '2026-02-01'), 'FECHA_INVALIDA', 'desde > hasta');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.saldo_cuentas(%L, %L, NULL)', e, '2026-03-01'), 'FECHA_INVALIDA', 'sin hasta');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.saldo_cuentas(%L, NULL, %L)', e, '2026-12-31'), 'SIN_PERMISO', 'cajero');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.saldo_cuentas(%L, NULL, %L)', e, '2026-12-31'), 'NO_PERTENECE', 'otra empresa');
  PERFORM pruebas.como('sin_sesion');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.saldo_cuentas(%L, NULL, %L)', e, '2026-12-31'), 'SIN_SESION', 'sin sesión');
  PERFORM pruebas.como('service_role');
  PERFORM pruebas.afirmar((SELECT saldo_final_centavos FROM public.saldo_cuentas(e, NULL, '2026-02-28') WHERE codigo = '1.1.01.01') = 345000, 'service_role lee');
END $$;
