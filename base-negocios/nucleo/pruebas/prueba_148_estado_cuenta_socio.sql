-- PRUEBA: (0.19.0) estado de cuenta de un socio (decisión del dueño A3), cifras a mano: aportes, aporte anulado, reparto de utilidad asignado, pagos recibidos, pago anulado y reparto anulado, cada uno en SU fecha; saldo al empezar, saldo corrido y saldo final; total invertido y saldo por pagar; con rango de fechas; cuadra con la contabilidad (3.1.01.04 y 2.1.01.03, todos los socios) a cualquier fecha; permisos (contador lee, vendedor no, otra empresa no, usuario limitado a su sucursal no); fechas al revés y socio ajeno se rechazan; una sola cuenta contable por concepto (sin cuentas por socio)
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  sa    uuid;
  sb    uuid;
  reinv uuid;
  emer  uuid;
  r     jsonb;
  ap3   uuid;
  pg1   uuid;
  pg2   uuid;
  dist  uuid;
  n     bigint;
  cuentas0 bigint;
BEGIN
  PERFORM pruebas.crear_contador();
  PERFORM pruebas.preparar_enero();
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fondos');
  PERFORM pruebas.como('dueno_a');
  reinv := (public.crear_fondo(e, '{"nombre": "Reinversión", "tipo": "reinversion"}', 'Fondo para crecer')->>'fondo_id')::uuid;
  emer := (public.crear_fondo(e, '{"nombre": "Emergencias", "tipo": "emergencias"}', 'Fondo para imprevistos')->>'fondo_id')::uuid;
  sa := (public.guardar_socio(e, jsonb_build_object('user_id', pruebas.usuario('dueno_a'), 'porcentaje', 60), 'Socio fundador')->>'socio_id')::uuid;
  sb := (public.guardar_socio(e, jsonb_build_object('tercero_id', (public.crear_tercero(e, '{"nombre": "Ana Socia", "es_proveedor": true}',
          gen_random_uuid())->>'tercero_id')::uuid, 'porcentaje', 40), 'Socia inversionista')->>'socio_id')::uuid;
  PERFORM public.guardar_regla_distribucion(e, jsonb_build_object('fondos', jsonb_build_array(jsonb_build_object('fondo_id', reinv, 'porcentaje', 40),
    jsonb_build_object('fondo_id', emer, 'porcentaje', 30)), 'socios_porcentaje', 30), 'Regla del dueño');
  SELECT count(*) INTO cuentas0 FROM public.cuenta WHERE empresa_id = e;

  -- Aportes: Ana 500,000 (10/02, banco) y 100,000 (12/02, anulado el 13/02); el dueño 200,000 (11/02, caja fuerte).
  PERFORM public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 500000, 'cuenta_dinero_id', pruebas.id('BANCO'),
    'fecha', '2026-02-10', 'referencia', 'Depósito 7788'), gen_random_uuid());
  PERFORM public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sa, 'monto_centavos', 200000, 'cuenta_dinero_id', pruebas.id('FUERTE'),
    'fecha', '2026-02-11'), gen_random_uuid());
  ap3 := (public.registrar_aporte_socio(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 100000, 'cuenta_dinero_id', pruebas.id('BANCO'),
    'fecha', '2026-02-12'), gen_random_uuid())->>'aporte_id')::uuid;
  PERFORM public.anular_aporte_socio(ap3, 'Se registró dos veces', gen_random_uuid(), '2026-02-13');
  -- Enero cerrado y repartido el 15/02 (prueba 121): base 35,159; socios 30 % = 10,548 -> Dueño 6,329, Ana 4,219.
  PERFORM public.cerrar_mes(e, 2026, 1);
  r := public.distribuir_utilidades(e, 2026, 1, '{"fecha": "2026-02-15"}', 'Reparto de enero', gen_random_uuid());
  dist := (r->>'distribucion_id')::uuid;
  -- Pagos a Ana: 2,000 (20/02) y 1,000 (21/02, anulado el 22/02).
  pg1 := (public.pagar_dividendos(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 2000, 'cuenta_dinero_id', pruebas.id('BANCO'),
    'fecha', '2026-02-20', 'referencia', 'Transferencia 55'), gen_random_uuid())->>'dividendo_pago_id')::uuid;
  pg2 := (public.pagar_dividendos(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 1000, 'cuenta_dinero_id', pruebas.id('BANCO'),
    'fecha', '2026-02-21'), gen_random_uuid())->>'dividendo_pago_id')::uuid;
  PERFORM public.anular_pago_dividendos(pg2, 'Era de otro socio', gen_random_uuid(), '2026-02-22');

  -- ===== 1) Todo el historial de Ana =====
  -- Invertido: 500,000 + 100,000 - 100,000 = 500,000. Por pagar: 4,219 - 2,000 - 1,000 + 1,000 = 2,219.
  r := public.estado_cuenta_socio(e, sb);
  PERFORM pruebas.afirmar((r->>'total_invertido_centavos')::bigint = 500000 AND (r->>'saldo_por_pagar_centavos')::bigint = 2219
    AND (r->'totales'->>'aportes_centavos')::bigint = 600000 AND (r->'totales'->>'aportes_anulados_centavos')::bigint = 100000
    AND (r->'totales'->>'repartos_centavos')::bigint = 4219 AND (r->'totales'->>'pagos_centavos')::bigint = 3000
    AND (r->'totales'->>'pagos_anulados_centavos')::bigint = 1000 AND (r->'totales'->>'movimientos')::bigint = 7
    AND (r->'saldo_inicial'->>'invertido_centavos')::bigint = 0 AND r->'socio'->>'nombre' = 'Ana Socia', 'historial de Ana: ' || r::text);
  PERFORM pruebas.afirmar((SELECT string_agg(m->>'tipo' || ':' || (m->>'saldo_invertido_centavos') || '/' || (m->>'saldo_por_pagar_centavos'), ','
                                             ORDER BY o) FROM jsonb_array_elements(r->'movimientos') WITH ORDINALITY AS x(m, o))
    = 'aporte:500000/0,aporte:600000/0,aporte_anulado:500000/0,reparto:500000/4219,pago:500000/2219,pago:500000/1219,pago_anulado:500000/2219',
    'movimientos en orden con saldo corrido: ' || (r->'movimientos')::text);
  PERFORM pruebas.afirmar(r->'movimientos'->3->>'texto' = 'Reparto de utilidad de enero de 2026 (#1)'
    AND r->'movimientos'->0->>'detalle' LIKE 'entró a BAC cheques%Depósito 7788', 'textos: ' || (r->'movimientos')::text);
  -- Cuadre a hoy: aportes 500,000 + 200,000 = 700,000 = 3.1.01.04; por pagar 10,548 - 2,000 = 8,548 = 2.1.01.03.
  PERFORM pruebas.afirmar((r->'cuadre'->>'cuadra')::boolean AND (r->'cuadre'->>'aportes_libros_centavos')::bigint = 700000
    AND (r->'cuadre'->>'aportes_todos_los_socios_centavos')::bigint = 700000 AND (r->'cuadre'->>'dividendos_libros_centavos')::bigint = 8548
    AND (r->'cuadre'->>'por_pagar_todos_los_socios_centavos')::bigint = 8548 AND r->'cuadre'->>'cuenta_aportes' = '3.1.01.04'
    AND r->'cuadre'->>'cuenta_dividendos' = '2.1.01.03', 'cuadre a hoy: ' || (r->'cuadre')::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '3.1.01.04') = 700000 AND pruebas.saldo_libros(e, '2.1.01.03') = 8548, 'libros');

  -- ===== 2) Con rango: del 14/02 al 20/02 =====
  -- Al empezar: invertido 500,000 y nada por pagar; en el rango: el reparto y el pago de 2,000.
  r := public.estado_cuenta_socio(e, sb, '2026-02-14', '2026-02-20');
  PERFORM pruebas.afirmar((r->'saldo_inicial'->>'invertido_centavos')::bigint = 500000 AND (r->'saldo_inicial'->>'por_pagar_centavos')::bigint = 0
    AND jsonb_array_length(r->'movimientos') = 2 AND (r->'totales'->>'repartos_centavos')::bigint = 4219
    AND (r->'totales'->>'pagos_centavos')::bigint = 2000 AND (r->'totales'->>'aportes_centavos')::bigint = 0
    AND (r->>'saldo_por_pagar_centavos')::bigint = 2219 AND (r->>'total_invertido_centavos')::bigint = 500000
    AND (r->'movimientos'->1->>'saldo_por_pagar_centavos')::bigint = 2219 AND r->>'desde' = '2026-02-14' AND r->>'hasta' = '2026-02-20',
    'rango: ' || r::text);
  -- Hasta el 12/02 (la anulación del 13 todavía no cuenta): Ana 600,000; todos 800,000 = libros a esa fecha.
  r := public.estado_cuenta_socio(e, sb, NULL, '2026-02-12');
  PERFORM pruebas.afirmar((r->>'total_invertido_centavos')::bigint = 600000 AND (r->>'saldo_por_pagar_centavos')::bigint = 0
    AND (r->'cuadre'->>'aportes_libros_centavos')::bigint = 800000 AND (r->'cuadre'->>'cuadra')::boolean, 'al 12/02: ' || r::text);
  -- El dueño (socio) por su lado: 200,000 invertidos y 6,329 por pagar.
  r := public.estado_cuenta_socio(e, sa);
  PERFORM pruebas.afirmar((r->>'total_invertido_centavos')::bigint = 200000 AND (r->>'saldo_por_pagar_centavos')::bigint = 6329, 'dueño: ' || r::text);

  -- ===== 3) Se anula el pago y el reparto: cada anulación en su fecha =====
  PERFORM public.anular_pago_dividendos(pg1, 'Se devolvió la transferencia', gen_random_uuid(), '2026-02-25');
  PERFORM public.anular_distribucion(dist, 'Porcentajes equivocados', gen_random_uuid(), '2026-02-26');
  r := public.estado_cuenta_socio(e, sb);
  PERFORM pruebas.afirmar((r->>'saldo_por_pagar_centavos')::bigint = 0 AND (r->'totales'->>'repartos_anulados_centavos')::bigint = 4219
    AND (r->'totales'->>'pagos_anulados_centavos')::bigint = 3000 AND (r->'totales'->>'movimientos')::bigint = 9
    AND (r->'cuadre'->>'cuadra')::boolean AND (r->'cuadre'->>'dividendos_libros_centavos')::bigint = 0, 'con anulaciones: ' || r::text);
  -- Al 20/02 se ve como estaba ese día (las anulaciones son después).
  r := public.estado_cuenta_socio(e, sb, NULL, '2026-02-20');
  PERFORM pruebas.afirmar((r->>'saldo_por_pagar_centavos')::bigint = 2219 AND (r->'cuadre'->>'cuadra')::boolean
    AND (r->'cuadre'->>'dividendos_libros_centavos')::bigint = 8548, 'al 20/02 como estaba: ' || r::text);

  -- ===== 4) Una sola cuenta por concepto: no se creó ninguna cuenta por socio =====
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta WHERE empresa_id = e) = cuentas0, 'sin cuentas nuevas por socio');

  -- ===== 5) Permisos y rechazos =====
  PERFORM pruebas.como('contador');
  r := public.estado_cuenta_socio(e, sb);
  PERFORM pruebas.afirmar((r->>'total_invertido_centavos')::bigint = 500000, 'el contador lo lee');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_socio(%L, %L)', e, sb), 'SIN_PERMISO', 'el vendedor no');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_socio(%L, %L)', e, sb), 'NO_PERTENECE', 'otra empresa no');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_socio(%L, %L)', e, gen_random_uuid()), 'NO_EXISTE', 'socio que no existe');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_socio(%L, %L, %L, %L)', e, sb, '2026-03-01', '2026-02-01'),
    'FECHA_INVALIDA', 'fechas al revés');
  -- Usuario limitado a una sucursal: es información de toda la empresa.
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('admin_a'),
    ARRAY[(SELECT s.id FROM public.sucursal s WHERE s.empresa_id = e ORDER BY s.codigo LIMIT 1)], 'Solo la principal');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_socio(%L, %L)', e, sb), 'SUCURSAL_NO_PERMITIDA', 'limitado a su sucursal');

  -- ===== 6) Todo cuadra =====
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM public.asiento a
   WHERE a.empresa_id = e AND (SELECT sum(debe_centavos) - sum(haber_centavos) FROM public.asiento_linea l WHERE l.asiento_id = a.id) <> 0;
  PERFORM pruebas.afirmar(n = 0, 'todos los asientos cuadran');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora íntegra');
END $$;
