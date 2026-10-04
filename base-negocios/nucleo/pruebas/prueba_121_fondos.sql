-- PRUEBA: fondos y reparto de utilidades (cifras a mano): módulo "fondos" (necesita dinero); socios y fondos con meta (monto o meses de pagos fijos) solo del dueño; regla guardada que suma 100 %; se reparte la utilidad COBRADA de un mes cerrado (abierto: MES_ABIERTO; dos veces: YA_DISTRIBUIDO; negativa: SIN_UTILIDAD_COBRADA) con asiento de patrimonio (reservas y dividendos por pagar) y separación física opcional; se anula con contra-asiento (no si ya se pagó o se usó); dividendos pagados y anulados; usar un fondo pide comprobante y la aprobación del dueño y libera la reserva con rastro; reservas y dividendos sin asientos manuales; estado de cada fondo; el balance del cierre sigue cuadrando; apagado solo corrige

-- Ayudantes de esta prueba (leen sin RLS, como superusuario).
CREATE FUNCTION pruebas.f_saldo(p_fondo uuid) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT interno.saldo_fondo(p_fondo) $$;
CREATE FUNCTION pruebas.f_dividendos(p_empresa uuid) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT interno.total_dividendos_por_pagar(p_empresa) $$;
CREATE FUNCTION pruebas.f_dinero(p_cuenta uuid) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT interno.saldo_dinero(p_cuenta) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pruebas TO anon, authenticated, service_role;

DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  r    jsonb;
  x    jsonb;
  d1   uuid;
  d2   uuid;
  reinv uuid;
  emer uuid;
  bf   uuid;
  sa   uuid;
  sb   uuid;
  u    jsonb;
  pg   uuid;
  apr  uuid;
BEGIN
  PERFORM pruebas.crear_contador();
  PERFORM pruebas.preparar_enero();
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_fondo(%L, %L, %L)', e, '{"nombre":"Reinversión"}', 'Fondo nuevo'),
    'MODULO_INACTIVO', 'sin el módulo fondos');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fondos');
  PERFORM pruebas.debe_fallar(format('UPDATE public.modulo_activo SET activo = false WHERE empresa_id = %L AND modulo = %L', e, 'dinero'),
    'lo usa "fondos"', 'no se apaga dinero con fondos activo');

  -- ===================== Configuración (solo el dueño) =====================
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_fondo(%L, %L, %L)', e, '{"nombre":"Reinversión"}', 'Fondo nuevo'), 'SIN_PERMISO', 'admin no crea fondos');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'fondos.configurar', 'Darle fondos'),
    'solo del dueño', 'fondos.configurar es solo del dueño');
  bf := (public.crear_cuenta_dinero(e, '{"tipo": "banco", "nombre": "Banco fondos", "banco": "Ficohsa", "numero_cuenta": "200-111-222", "tipo_cuenta": "ahorro"}')->>'cuenta_dinero_id')::uuid;
  PERFORM public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Alquiler', 'categoria_id', pruebas.id('CAT_ALQ'), 'monto_estimado_centavos', 500000,
    'frecuencia', 'mensual', 'dia', 5, 'fecha_inicio', '2026-01-01'));
  r := public.crear_fondo(e, '{"nombre": "Reinversión", "tipo": "reinversion", "meta_tipo": "monto", "meta_monto_centavos": 100000}', 'Fondo para crecer');
  reinv := (r->>'fondo_id')::uuid;
  PERFORM pruebas.afirmar(r->>'cuenta_codigo' = '3.2.02.01' AND (r->>'meta_centavos')::bigint = 100000, 'reinversión con su reserva 3.2.02.01: ' || r::text);
  -- Meta de emergencias: 3 meses de pagos fijos = 3 x 500,000 = 1,500,000.
  r := public.crear_fondo(e, jsonb_build_object('nombre', 'Emergencias', 'tipo', 'emergencias', 'meta_tipo', 'meses_pagos_fijos', 'meta_meses', 3,
    'cuenta_dinero_id', bf), 'Fondo para imprevistos');
  emer := (r->>'fondo_id')::uuid;
  PERFORM pruebas.afirmar(r->>'cuenta_codigo' = '3.2.02.02' AND (r->>'meta_centavos')::bigint = 1500000, 'emergencias: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_fondo(%L, %L, %L)', e, '{"nombre":"emergencias"}', 'Repetido'), 'YA_EXISTE', 'nombre repetido');
  sa := (public.guardar_socio(e, jsonb_build_object('user_id', pruebas.usuario('dueno_a'), 'porcentaje', 60), 'Socio fundador')->>'socio_id')::uuid;
  sb := (public.guardar_socio(e, jsonb_build_object('tercero_id', (public.crear_tercero(e, '{"nombre": "Ana Socia", "es_proveedor": true}',
          gen_random_uuid())->>'tercero_id')::uuid, 'porcentaje', 40), 'Socia inversionista')->>'socio_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_regla_distribucion(%L, %L, %L)', e,
    jsonb_build_object('fondos', jsonb_build_array(jsonb_build_object('fondo_id', reinv, 'porcentaje', 40), jsonb_build_object('fondo_id', emer, 'porcentaje', 20)),
                       'socios_porcentaje', 30), 'Regla mala'), 'PORCENTAJES_INVALIDOS', 'regla que suma 90 %');
  PERFORM public.guardar_regla_distribucion(e, jsonb_build_object('fondos', jsonb_build_array(jsonb_build_object('fondo_id', reinv, 'porcentaje', 40),
    jsonb_build_object('fondo_id', emer, 'porcentaje', 30)), 'socios_porcentaje', 30), 'Regla del dueño');

  -- ===================== Reparto de enero =====================
  PERFORM pruebas.debe_fallar(format('SELECT public.distribuir_utilidades(%L, 2026, 1, %L, %L, gen_random_uuid())', e, '{"fecha":"2026-02-15"}',
    'Reparto de enero'), 'MES_ABIERTO', 'enero abierto no se reparte');
  PERFORM public.cerrar_mes(e, 2026, 1);
  PERFORM pruebas.debe_fallar(format('SELECT public.distribuir_utilidades(%L, 2026, 1, %L, %L, gen_random_uuid())', e, '{"fecha":"2026-01-31"}',
    'Reparto de enero'), 'FECHA_INVALIDA', 'el reparto va después del mes');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.debe_fallar(format('SELECT public.distribuir_utilidades(%L, 2026, 1, %L, %L, gen_random_uuid())', e, '{}', 'Reparto'),
    'SIN_PERMISO', 'contador no reparte');
  PERFORM pruebas.como('dueno_a');
  -- A mano: base = utilidad cobrada de enero 35,159 (facturada 39,679).
  --   reinversión 40 % = 14,063.60; emergencias 30 % = 10,547.70; socios 30 % por participación:
  --   Ana 12 % = 4,219.08 y Dueño 18 % = 6,328.62. Pisos 35,157; faltan 2 -> restos mayores .70 y .62:
  --   reinversión 14,063, emergencias 10,548, Ana 4,219, Dueño 6,329 (dividendos 10,548). Suma 35,159.
  d1 := gen_random_uuid();
  r := public.distribuir_utilidades(e, 2026, 1, jsonb_build_object('fecha', '2026-02-15', 'separar_desde', pruebas.id('BANCO')), 'Reparto de enero', d1);
  PERFORM pruebas.afirmar((r->>'base_centavos')::bigint = 35159 AND (r->>'utilidad_facturada_centavos')::bigint = 39679
    AND (SELECT string_agg((y->>'nombre') || '=' || (y->>'monto_centavos'), ',' ORDER BY y->>'nombre') FROM jsonb_array_elements(r->'partes') y)
        = 'Ana Socia=4219,Dueño A=6329,Emergencias=10548,Reinversión=14063', 'reparto de enero: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '3.3.01.02') = -35159 AND pruebas.saldo_libros(e, '3.2.02.01') = 14063
    AND pruebas.saldo_libros(e, '3.2.02.02') = 10548 AND pruebas.saldo_libros(e, '2.1.01.03') = 10548, 'asiento de patrimonio');
  -- Separación física: solo emergencias tiene cuenta: BANCO 888,500 - 10,548 = 877,952; Banco fondos 10,548.
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 877952 AND pruebas.f_dinero(bf) = 10548, 'separación física con rastro');
  r := public.distribuir_utilidades(e, 2026, 1, jsonb_build_object('fecha', '2026-02-15', 'separar_desde', pruebas.id('BANCO')), 'Reparto de enero', d1);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean, 'reintento = el mismo reparto');
  PERFORM pruebas.debe_fallar(format('SELECT public.distribuir_utilidades(%L, 2026, 1, %L, %L, gen_random_uuid())', e, '{"fecha":"2026-02-15"}',
    'Otra vez'), 'YA_DISTRIBUIDO', 'no dos veces el mismo mes');
  -- Anular: contra-asientos y el dinero vuelve al BANCO.
  r := public.anular_distribucion((SELECT id FROM public.distribucion WHERE id_operacion = d1), 'Porcentajes equivocados', gen_random_uuid(), '2026-02-15');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '3.3.01.02') = 0 AND pruebas.saldo_libros(e, '3.2.02.01') = 0 AND pruebas.saldo_libros(e, '2.1.01.03') = 0
    AND pruebas.dinero('BANCO') = 888500 AND pruebas.f_dinero(bf) = 0, 'anulación del reparto');
  -- Otra vez con la regla guardada y sin separar.
  d2 := gen_random_uuid();
  r := public.distribuir_utilidades(e, 2026, 1, '{"fecha": "2026-02-15"}', 'Reparto de enero corregido', d2);
  PERFORM pruebas.afirmar((r->>'base_centavos')::bigint = 35159 AND r->>'asiento_separacion_id' IS NULL AND pruebas.f_saldo(emer) = 10548,
    'segundo reparto con la regla guardada');

  -- ===================== Dividendos =====================
  PERFORM public.pagar_dividendos(e, jsonb_build_object('socio_id', sa, 'cuenta_dinero_id', pruebas.id('BANCO'), 'fecha', '2026-02-16'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_dividendos(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'monto_centavos', 5000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'fecha', '2026-02-16')), 'PAGO_EXCEDE_SALDO', 'no más de lo pendiente');
  pg := (public.pagar_dividendos(e, jsonb_build_object('socio_id', sb, 'monto_centavos', 2000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'fecha', '2026-02-16'),
          gen_random_uuid())->>'dividendo_pago_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_dividendos(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sa, 'cuenta_dinero_id', pruebas.id('BANCO'), 'fecha', '2026-02-16')), 'NADA_QUE_PAGAR', 'al dueño ya se le pagó');
  -- 10,548 - 6,329 - 2,000 = 2,219 por pagar; BANCO 888,500 - 8,329 = 880,171.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.03') = 2219 AND pruebas.f_dividendos(e) = 2219
    AND pruebas.dinero('BANCO') = 880171, 'dividendos pagados');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_distribucion(%L, %L, gen_random_uuid())', (SELECT id FROM public.distribucion WHERE id_operacion = d2),
    'Ya no sirve'), 'DISTRIBUCION_USADA', 'no se anula con dividendos pagados');

  -- ===================== Usar un fondo =====================
  PERFORM pruebas.debe_fallar(format('SELECT public.usar_fondo(%L, %L, %L, gen_random_uuid())', emer,
    jsonb_build_object('monto_centavos', 3000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'cuenta_destino', '6.1.02.06', 'fecha', '2026-02-17'),
    'Reparar el techo'), 'comprobante', 'sin comprobante no');
  PERFORM pruebas.debe_fallar(format('SELECT public.usar_fondo(%L, %L, %L, gen_random_uuid())', emer,
    jsonb_build_object('monto_centavos', 3000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'cuenta_destino', '1.1.01.01', 'fecha', '2026-02-17',
                       'comprobante', pruebas.comprobante('techo.jpg')), 'Reparar el techo'), 'CUENTA_INVALIDA', 'destino efectivo no');
  -- El dueño lo usa: se aplica. Dr 6.1.02.06 3,000 / Cr BANCO; Dr reserva 3,000 / Cr 3.3.01.01.
  u := public.usar_fondo(emer, jsonb_build_object('monto_centavos', 3000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'cuenta_destino', '6.1.02.06',
         'fecha', '2026-02-17', 'referencia', 'Recibo 55', 'comprobante', pruebas.comprobante('techo.jpg')), 'Reparar el techo', gen_random_uuid());
  PERFORM pruebas.afirmar(u->>'estado' = 'aplicado' AND (u->>'saldo_fondo_centavos')::bigint = 7548 AND pruebas.saldo_libros(e, '3.3.01.01') = 3000
    AND pruebas.saldo_libros(e, '6.1.02.06') = 3000 AND pruebas.dinero('BANCO') = 877171, 'uso del fondo por el dueño: ' || u::text);
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.dinero_movimiento WHERE documento_id = (u->>'fondo_uso_id')::uuid AND operacion = 'uso_fondo'
    AND monto_centavos = -3000) AND EXISTS (SELECT 1 FROM public.adjunto WHERE documento_tipo = 'fondo_uso' AND documento_id = (u->>'fondo_uso_id')::uuid),
    'rastro y comprobante del uso');
  PERFORM pruebas.debe_fallar(format('SELECT public.usar_fondo(%L, %L, %L, gen_random_uuid())', emer,
    jsonb_build_object('monto_centavos', 8000, 'cuenta_dinero_id', pruebas.id('BANCO'), 'cuenta_destino', '6.1.02.06', 'fecha', '2026-02-17',
                       'comprobante', pruebas.comprobante('otro.jpg')), 'Más de lo que hay'), 'FONDO_INSUFICIENTE', 'no más que el saldo');
  -- El admin (con permiso de usar) lo pide: queda pendiente sin mover nada hasta que el dueño apruebe.
  PERFORM public.cambiar_permiso_rol(e, 'admin', 'fondos.usar', true, 'El admin puede pedir usar fondos');
  PERFORM pruebas.como('admin_a');
  u := public.usar_fondo(emer, jsonb_build_object('monto_centavos', 1000, 'cuenta_dinero_id', bf, 'cuenta_destino', '6.1.02.06', 'fecha', '2026-02-18',
         'comprobante', pruebas.comprobante('pintura.jpg')), 'Pintura de la bodega', gen_random_uuid());
  PERFORM pruebas.afirmar(u->>'estado' = 'pendiente_aprobacion' AND (u->>'saldo_fondo_centavos')::bigint = 7548, 'pedido del admin pendiente');
  apr := (u->>'aprobacion_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', apr, 'Aprobado'), 'SIN_PERMISO', 'el admin no aprueba');
  PERFORM pruebas.como('dueno_a');
  -- Banco fondos no tiene dinero (se anuló la separación): con la cuenta elegida no alcanza.
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', apr, 'Aprobado'), 'SALDO_INSUFICIENTE', 'sin dinero en la cuenta');
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('BANCO'), 'destino_id', bf, 'monto_centavos', 7548,
    'fecha', '2026-02-18', 'referencia', 'Separar emergencias'), gen_random_uuid());
  u := public.resolver_aprobacion(apr, true, 'Aprobado', gen_random_uuid());
  PERFORM pruebas.afirmar(u->>'estado' = 'aplicado' AND (u->>'saldo_fondo_centavos')::bigint = 6548 AND pruebas.f_dinero(bf) = 6548,
    'aprobado por el dueño: ' || u::text);
  -- Nadie mueve la reserva ni los dividendos con un asiento manual.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-02-20', pruebas.lineas('3.2.02.02', '3.3.01.01', 100)), 'CUENTA_CONTROLADA', 'reserva sin asiento manual');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-02-20', pruebas.lineas('2.1.01.03', '3.3.01.01', 100)), 'CUENTA_CONTROLADA', 'dividendos sin asiento manual');

  -- ===================== Estado de cada fondo (lo ve el contador) =====================
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_fondos(%L)', e), 'SIN_PERMISO', 'cajero no ve fondos');
  PERFORM pruebas.como('contador');
  x := public.estado_fondos(e);
  -- Reinversión 14,063 de 100,000 = 14.06 %; emergencias: aportes 10,548 (aporte, anulación y aporte), usos 4,000, saldo 6,548
  -- de 1,500,000 = 0.44 %.
  PERFORM pruebas.afirmar((SELECT (f->>'saldo_centavos')::bigint = 14063 AND (f->>'meta_porcentaje')::numeric = 14.06 AND (f->>'libros_centavos')::bigint = 14063
      FROM jsonb_array_elements(x->'fondos') f WHERE f->>'nombre' = 'Reinversión')
    AND (SELECT (f->>'saldo_centavos')::bigint = 6548 AND (f->>'aportes_centavos')::bigint = 10548 AND (f->>'usos_centavos')::bigint = 4000
      AND (f->>'meta_porcentaje')::numeric = 0.44 AND (f->>'saldo_cuenta_dinero_centavos')::bigint = 6548 AND (f->>'libros_centavos')::bigint = 6548
      FROM jsonb_array_elements(x->'fondos') f WHERE f->>'nombre' = 'Emergencias')
    AND (x->>'dividendos_por_pagar_centavos')::bigint = 2219 AND (x->>'dividendos_por_pagar_libros_centavos')::bigint = 2219,
    'estado de los fondos: ' || x::text);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_fondo_movimiento WHERE fondo_id = emer) = 5
    AND (SELECT saldo_centavos FROM public.v_fondo_movimiento WHERE fondo_id = emer ORDER BY fecha_contable DESC, movimiento_id DESC LIMIT 1) = 6548,
    'rastro del fondo');

  -- ===================== Cierre de febrero: el balance cuadra con el reparto =====================
  -- Febrero: gastos de fondos 4,000 -> neta -4,000; por cobrar sigue 4,520 -> cobrada -4,000 (no se reparte).
  -- Patrimonio: 1,339,679 - 10,548 (dividendos declarados) - 4,000 = 1,325,131; pasivo 458,821 + 2,219 = 461,040;
  -- activo 1,798,500 - 8,329 (dividendos) - 4,000 (usos) = 1,786,171 = 461,040 + 1,325,131.
  PERFORM pruebas.como('dueno_a');
  r := public.cerrar_mes(e, 2026, 2);
  x := public.balance_general(e, 2026, 2);
  PERFORM pruebas.afirmar((x->>'total_activo_centavos')::bigint = 1786171 AND (x->>'total_pasivo_centavos')::bigint = 461040
    AND (x->>'total_patrimonio_centavos')::bigint = 1325131 AND (x->>'cuadra')::boolean
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(x->'patrimonio') p WHERE p->>'codigo' = '3.2.02.01' AND (p->>'monto_centavos')::bigint = 14063),
    'balance de febrero: ' || x::text);
  PERFORM pruebas.afirmar((public.estado_resultados(e, 2026, 2)->>'utilidad_cobrada_centavos')::bigint = -4000, 'cobrada de febrero');
  PERFORM pruebas.debe_fallar(format('SELECT public.distribuir_utilidades(%L, 2026, 2, %L, %L, gen_random_uuid())', e, '{}', 'Reparto de febrero'),
    'SIN_UTILIDAD_COBRADA', 'cobrada negativa no se reparte');
  -- Reabrir y volver a cerrar enero: avisa que su reparto salió de la versión anterior.
  PERFORM public.reabrir_periodo(e, 2026, 2, 'Revisar el reparto');
  PERFORM public.reabrir_periodo(e, 2026, 1, 'Revisar el reparto');
  r := public.cerrar_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((r->>'version')::integer = 2 AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advertencias') a
    WHERE a->>'tipo' = 'reparto_version_anterior' AND (a->>'monto_centavos')::bigint = 35159), 'aviso del reparto anterior: ' || (r->'advertencias')::text);

  -- ===================== Apagar fondos: solo corregir =====================
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'fondos';
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_dividendos(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('socio_id', sb, 'cuenta_dinero_id', pruebas.id('BANCO'))), 'MODULO_INACTIVO', 'apagado no paga');
  PERFORM pruebas.debe_fallar(format('SELECT public.usar_fondo(%L, %L, %L, gen_random_uuid())', reinv,
    jsonb_build_object('monto_centavos', 100, 'cuenta_dinero_id', pruebas.id('BANCO'), 'cuenta_destino', '6.1.02.06',
                       'comprobante', pruebas.comprobante('x.jpg')), 'Apagado'), 'MODULO_INACTIVO', 'apagado no usa');
  PERFORM public.anular_pago_dividendos(pg, 'Pago duplicado', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.03') = 4219 AND pruebas.f_dividendos(e) = 4219, 'anular pago con el módulo apagado');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-03-02', pruebas.lineas('2.1.01.03', '3.3.01.01', 100)), 'CUENTA_CONTROLADA', 'apagado sigue controlada');
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = true WHERE empresa_id = e AND modulo = 'fondos';   -- dividendos = libros: no pide nada

  -- ===================== Cuadre =====================
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.fondo f JOIN public.cuenta c ON c.id = f.cuenta_id
    WHERE f.empresa_id = e AND interno.saldo_fondo(f.id) <> pruebas.saldo_libros(e, c.codigo)), 'cada fondo = su reserva');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
    WHERE d.empresa_id = e AND interno.saldo_dinero(d.id) <> coalesce(pruebas.saldo_libros(e, c.codigo), 0)), 'dinero = subcuentas');
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea WHERE empresa_id = e), 'debe = haber');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora intacta');
END $$;
