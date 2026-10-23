-- PRUEBA: (0.16.0) anular un reparto de utilidad desde la app (anular_distribucion, núcleo 0.10.0) y reabrir el mes (cifras a mano de la prueba 121): solo el dueño (admin y contador: SIN_PERMISO), motivo obligatorio, no se anula si ya se pagó a un socio (primero se anula ese pago), contra-asientos que dejan reservas, dividendos y el dinero separado como antes (nada se borra), doble envío con el mismo id_operacion, una segunda anulación da YA_ANULADO, MES_CON_REPARTO deja de bloquear y el mes se reabre, se vuelve a cerrar (versión 2) y se puede repartir otra vez; todos los asientos cuadran
CREATE FUNCTION pruebas.f137_saldo(p_fondo uuid) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT interno.saldo_fondo(p_fondo) $$;
CREATE FUNCTION pruebas.f137_dinero(p_cuenta uuid) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT interno.saldo_dinero(p_cuenta) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pruebas TO anon, authenticated, service_role;

DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  r     jsonb;
  reinv uuid;
  emer  uuid;
  bf    uuid;
  sa    uuid;
  sb    uuid;
  dist  uuid;
  pg    uuid;
  op    uuid;
  a1    uuid;
  n     bigint;
BEGIN
  PERFORM pruebas.crear_contador();
  PERFORM pruebas.preparar_enero();
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fondos');
  PERFORM pruebas.como('dueno_a');
  bf := (public.crear_cuenta_dinero(e, '{"tipo": "banco", "nombre": "Banco fondos", "banco": "Ficohsa", "numero_cuenta": "200-111-222", "tipo_cuenta": "ahorro"}')->>'cuenta_dinero_id')::uuid;
  reinv := (public.crear_fondo(e, '{"nombre": "Reinversión", "tipo": "reinversion"}', 'Fondo para crecer')->>'fondo_id')::uuid;
  emer := (public.crear_fondo(e, jsonb_build_object('nombre', 'Emergencias', 'tipo', 'emergencias', 'cuenta_dinero_id', bf), 'Fondo para imprevistos')->>'fondo_id')::uuid;
  sa := (public.guardar_socio(e, jsonb_build_object('user_id', pruebas.usuario('dueno_a'), 'porcentaje', 60), 'Socio fundador')->>'socio_id')::uuid;
  sb := (public.guardar_socio(e, jsonb_build_object('tercero_id', (public.crear_tercero(e, '{"nombre": "Ana Socia", "es_proveedor": true}',
          gen_random_uuid())->>'tercero_id')::uuid, 'porcentaje', 40), 'Socia inversionista')->>'socio_id')::uuid;
  PERFORM public.guardar_regla_distribucion(e, jsonb_build_object('fondos', jsonb_build_array(jsonb_build_object('fondo_id', reinv, 'porcentaje', 40),
    jsonb_build_object('fondo_id', emer, 'porcentaje', 30)), 'socios_porcentaje', 30), 'Regla del dueño');

  -- Enero cerrado y repartido (a mano, prueba 121): base 35,159 -> reinversión 14,063, emergencias 10,548,
  -- Ana 4,219, Dueño 6,329 (dividendos 10,548). Separación física: Banco fondos recibe 10,548 del BANCO
  -- (888,500 -> 877,952).
  PERFORM public.cerrar_mes(e, 2026, 1);
  r := public.distribuir_utilidades(e, 2026, 1, jsonb_build_object('fecha', '2026-02-15', 'separar_desde', pruebas.id('BANCO')), 'Reparto de enero', gen_random_uuid());
  dist := (r->>'distribucion_id')::uuid;
  PERFORM pruebas.afirmar((r->>'base_centavos')::bigint = 35159 AND pruebas.dinero('BANCO') = 877952 AND pruebas.f137_dinero(bf) = 10548, 'reparto de enero');

  -- Con reparto vigente, enero no se reabre.
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 1, %L)', e, 'Falta una factura'), 'MES_CON_REPARTO', 'reabrir con reparto');

  -- Sin permiso: admin y contador (fondos.distribuir es solo del dueño).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, %L, gen_random_uuid())', dist, 'Porcentajes equivocados'), 'SIN_PERMISO', 'admin no anula');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, %L, gen_random_uuid())', dist, 'Porcentajes equivocados'), 'SIN_PERMISO', 'contador no anula');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'fondos.distribuir', 'Darle repartos'),
    'solo del dueño', 'fondos.distribuir no se da a otro puesto');
  -- Sin motivo.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, %L, gen_random_uuid())', dist, ''), 'FALTA_MOTIVO', 'motivo vacío');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, NULL, gen_random_uuid())', dist), 'FALTA_MOTIVO', 'motivo nulo');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, %L, NULL)', dist, 'Porcentajes equivocados'), 'FALTA_ID_OPERACION', 'sin id_operacion');

  -- Con un pago a un socio: no se anula (el mensaje pide anular primero ese pago).
  pg := (public.pagar_dividendos(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 2000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'fecha', '2026-02-16'),
          gen_random_uuid())->>'dividendo_pago_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, %L, gen_random_uuid())', dist, 'Porcentajes equivocados'),
    'anule primero esos pagos', 'reparto con pagos');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 1, %L)', e, 'Falta una factura'), 'MES_CON_REPARTO', 'sigue sin reabrir');
  PERFORM public.anular_pago_dividendos(pg, 'Se pagó por error', gen_random_uuid(), '2026-02-16');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 877952, 'el pago anulado devolvió el dinero');

  -- Anular: contra-asientos (anula_asiento_id) y todo vuelve; nada se borra.
  op := gen_random_uuid();
  r := public.anular_distribucion(dist, 'Porcentajes equivocados', op, '2026-02-17');
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean AND r->>'asiento_separacion_id' IS NOT NULL, 'anulado: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '3.3.01.02') = 0 AND pruebas.saldo_libros(e, '3.2.02.01') = 0 AND pruebas.saldo_libros(e, '3.2.02.02') = 0
    AND pruebas.saldo_libros(e, '2.1.01.03') = 0 AND pruebas.f137_saldo(reinv) = 0 AND pruebas.f137_saldo(emer) = 0
    AND pruebas.dinero('BANCO') = 888500 AND pruebas.f137_dinero(bf) = 0, 'reservas, dividendos y dinero separado como antes');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT anula_asiento_id FROM public.asiento WHERE id = (r->>'asiento_id')::uuid)
                          = (SELECT asiento_id FROM public.distribucion WHERE id = dist), 'contra-asiento enlazado al reparto');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.distribucion WHERE id = dist AND anulada_en IS NOT NULL AND motivo_anulacion = 'Porcentajes equivocados') = 1
    AND (SELECT count(*) FROM public.fondo_movimiento WHERE documento_id = dist) = 4
    AND (SELECT count(*) FROM public.fondo_movimiento WHERE documento_id = dist AND tipo = 'anulacion_aporte') = 2, 'el reparto queda con su anulación (nada borrado)');
  PERFORM pruebas.como('dueno_a');
  -- Doble envío: el mismo id = la misma anulación; otro id: YA_ANULADO.
  r := public.anular_distribucion(dist, 'Porcentajes equivocados', op, '2026-02-17');
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean, 'reintento = la misma anulación');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, %L, gen_random_uuid())', dist, 'Otra vez'), 'YA_ANULADO', 'dos veces no');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE origen = 'anulacion_distribucion' AND empresa_id = e) = 1, 'un solo contra-asiento');

  -- Ya sin reparto vigente: enero se reabre (con id_operacion), se vuelve a cerrar (versión 2) y se reparte otra vez.
  PERFORM pruebas.como('dueno_a');
  a1 := gen_random_uuid();
  r := public.reabrir_periodo(e, 2026, 1, 'Falta una factura de enero', a1);
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean, 'enero reabierto');
  PERFORM pruebas.afirmar((SELECT estado FROM public.periodo WHERE empresa_id = e AND anio = 2026 AND mes = 1) = 'abierto'
    AND (SELECT estado FROM public.cierre WHERE empresa_id = e AND anio = 2026 AND mes = 1 AND version = 1) = 'superada', 'foto superada');
  PERFORM public.cerrar_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((SELECT version FROM public.cierre WHERE empresa_id = e AND anio = 2026 AND mes = 1 AND estado = 'vigente') = 2, 'versión 2');
  r := public.distribuir_utilidades(e, 2026, 1, '{"fecha": "2026-02-18"}', 'Reparto de enero corregido', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'base_centavos')::bigint = 35159 AND pruebas.f137_saldo(emer) = 10548, 'reparto nuevo');

  -- Todo cuadra.
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM (SELECT l.asiento_id FROM public.asiento_linea l WHERE l.empresa_id = e
                                GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)) x;
  PERFORM pruebas.afirmar(n = 0, 'asientos que no cuadran: ' || n);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
