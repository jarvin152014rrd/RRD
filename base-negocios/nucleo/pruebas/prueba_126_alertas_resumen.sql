-- PRUEBA: alertas centralizadas y "ganancia de hoy / del mes" (cifras a mano): alertas_activas junta CAI, cierre atrasado, cuenta en negativo, depósito sin confirmar, aprobaciones, crédito vencido, pago fijo, mercadería por acabarse, conciliación, licencia y límite del plan en una lista uniforme con palabras sencillas; el cajero no ve dinero, bancos ni créditos; preferencias por usuario; resumen_hoy con ventas, ganancia, dinero, te deben y debes comparados con ayer y el mes pasado, sin costos para quien no los ve
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  hoy   date;
  a     jsonb;
  t     text[];
  r     jsonb;
  v     jsonb;
  dp    jsonb;
  mes   bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  hoy := public.hoy_local(e);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false, "cai_dias_alerta": 200}', 'Prueba de alertas');
  PERFORM public.configurar_saldo_negativo(e, pruebas.id('CAJA1'), 'permitir_con_alerta', NULL, 'Prueba de alertas');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'conciliacion');
  UPDATE public.licencia SET vence_el = hoy + 10 WHERE empresa_id = e;
  INSERT INTO public.limite_contrato (empresa_id, usuarios) VALUES (e, 5)
  ON CONFLICT (empresa_id) DO UPDATE SET usuarios = 5;
  PERFORM pruebas.como('dueno_a');

  -- Datos (a mano):
  --   hoy-40: 52 tornillos al crédito a CLI1 (plazo 30, vence hoy-10) = 78,000 (67,826 + ISV 10,174). Tornillos: 100 - 52 = 48.
  --   hoy-1:  1 galón con tarjeta = 45,000 (38,136 + 6,864; costo 30,000): ganancia de ayer 8,136.
  --   hoy:    el cajero vende 2 tornillos en efectivo = 3,000 (2,609 + 391; costo 2,000): ganancia de hoy 609. Quedan 46 (mínimo 50).
  --           el cajero pide devolver 1 tornillo (queda pendiente de aprobación).
  --           gasto de energía de 5,000 desde CAJA1: CAJA1 = 3,000 - 5,000 = -2,000 (en negativo, permitido con alerta).
  --   hoy-5:  depósito de 100,000 de FUERTE al banco, sin confirmar (5 días > 3).
  --   pago fijo semanal de 50,000 que venció hoy-3.
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 52, 'credito', 'CLI1') || jsonb_build_object('fecha', to_char(hoy - 40, 'YYYY-MM-DD')), gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P3', 1, 'tarjeta') || jsonb_build_object('fecha', to_char(hoy - 1, 'YYYY-MM-DD')), gen_random_uuid());
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'),
    'monto_centavos', 100000, 'fecha', to_char(hoy - 5, 'YYYY-MM-DD'), 'referencia', 'Boleta 9'), gen_random_uuid());
  PERFORM public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Vigilancia', 'categoria_id', pruebas.id('CAT_ALQ'), 'monto_estimado_centavos', 50000,
    'frecuencia', 'semanal', 'dia', extract(isodow FROM hoy - 3)::integer, 'fecha_inicio', to_char(hoy - 3, 'YYYY-MM-DD')));
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 2), gen_random_uuid());
  dp := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'motivo', 'Tornillo torcido', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar(dp->>'estado' = 'pendiente_aprobacion', 'devolución pendiente');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 5000, 'descripcion', 'Energía'), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = -2000, 'CAJA1 en -2,000');

  -- 1) El dueño ve todas, en una lista uniforme, primero las graves.
  a := public.alertas_activas(e);
  SELECT array_agg(DISTINCT x->>'tipo' ORDER BY x->>'tipo') INTO t FROM jsonb_array_elements(a->'alertas') x;
  PERFORM pruebas.afirmar(t = ARRAY['aprobaciones', 'cai', 'cierre_mes', 'conciliacion', 'credito_vencido', 'cuenta_negativa',
    'deposito_transito', 'licencia', 'limite_contrato', 'pago_fijo', 'stock_minimo'], 'tipos del dueño: ' || t::text);
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x
                                       WHERE NOT (x ?& ARRAY['tipo', 'gravedad', 'titulo', 'mensaje', 'que_hacer', 'enlace', 'datos'])),
    'todas con la misma forma');
  PERFORM pruebas.afirmar(a->'alertas'->0->>'gravedad' = 'alta' AND a->'alertas'->(jsonb_array_length(a->'alertas') - 1)->>'gravedad' = 'baja',
    'ordenadas de grave a leve');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'cuenta_negativa'
    AND x->>'mensaje' = 'La cuenta "' || (SELECT nombre FROM public.cuenta_dinero WHERE id = pruebas.id('CAJA1')) || '" está en L -20.00.'),
    'mensaje sencillo de cuenta en negativo');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'deposito_transito'
    AND (x->'datos'->>'dias')::integer = 5 AND x->>'mensaje' LIKE 'El depósito de L 1,000.00 a %lleva 5 días sin confirmarse.'), 'depósito sin confirmar');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'credito_vencido'
    AND x->>'mensaje' LIKE 'Constructora Ríos le debe L 780.00 que ya venció%' AND x->>'gravedad' = 'media'), 'crédito vencido');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'stock_minimo'
    AND x->>'mensaje' = 'Quedan 46 de "Tornillo 1/2" (su mínimo es 50).'), 'mercadería por acabarse');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'pago_fijo' AND x->>'gravedad' = 'alta'
    AND x->>'mensaje' = 'El pago de "Vigilancia" venció el ' || to_char(hoy - 3, 'DD/MM/YYYY') || '.'), 'pago fijo vencido');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'limite_contrato'
    AND x->>'mensaje' = 'Está usando 4 de 5 usuarios de su plan.'), 'límite al 80 %');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'licencia'
    AND x->>'mensaje' = 'Su licencia vence en 10 día(s).'), 'licencia por vencer');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'aprobaciones'
    AND (x->'datos'->>'cantidad')::integer = 1), 'una aprobación pendiente');

  -- 2) Preferencias: el dueño apaga "mercadería por acabarse".
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_preferencias_alertas(%L, %L)', e, '{"inventado": false}'), 'DATO_INVALIDO', 'tipo inventado');
  r := public.guardar_preferencias_alertas(e, '{"stock_minimo": false}');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'tipo' = 'stock_minimo' AND NOT (x->>'recibir')::boolean), 'preferencia guardada');
  a := public.alertas_activas(e);
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') x WHERE x->>'tipo' = 'stock_minimo')
    AND (a->>'ocultas_por_preferencia')::integer = 1, 'apagada para el dueño');

  -- 3) El cajero: solo CAI y mercadería (ni dinero, ni bancos, ni créditos, ni costos); sus preferencias son suyas.
  PERFORM pruebas.como('cajero_a');
  a := public.alertas_activas(e);
  SELECT array_agg(DISTINCT x->>'tipo' ORDER BY x->>'tipo') INTO t FROM jsonb_array_elements(a->'alertas') x;
  PERFORM pruebas.afirmar(t = ARRAY['cai', 'stock_minimo'], 'tipos del cajero: ' || t::text);
  PERFORM pruebas.afirmar(jsonb_array_length(public.mis_preferencias_alertas(e)) = 2, 'el cajero elige solo entre lo que ve');

  -- 4) resumen_hoy del dueño (a mano):
  --   ventas de hoy 3,000 (1 venta); ayer 45,000.
  --   ganancia de hoy 2,609 - 2,000 = 609; ayer 38,136 - 30,000 = 8,136.
  --   ganancia del mes = 609 - 5,000 de gasto (+ 8,136 si ayer es de este mes).
  --   dinero disponible: BANCO 1,000,000 + FUERTE 300,000 - 100,000 + CAJA1 -2,000 = 1,198,000; por confirmar 100,000 + 45,000 (POS).
  --   te deben 78,000, todo vencido; debes F-INI-1 544,000, vencida (04/02/2026).
  PERFORM pruebas.como('dueno_a');
  r := public.resumen_hoy(e);
  mes := 609 - 5000 + CASE WHEN date_trunc('month', hoy - 1) = date_trunc('month', hoy) THEN 8136 ELSE 0 END;
  PERFORM pruebas.afirmar((r->'ventas_hoy'->>'total_centavos')::bigint = 3000 AND (r->'ventas_hoy'->>'cantidad')::integer = 1
    AND (r->'ventas_hoy'->>'ayer_centavos')::bigint = 45000 AND (r->'ventas_hoy'->>'diferencia_centavos')::bigint = -42000, 'ventas de hoy: ' || (r->'ventas_hoy')::text);
  PERFORM pruebas.afirmar((r->'ganancia_hoy'->>'ganancia_bruta_centavos')::bigint = 609 AND (r->'ganancia_hoy'->>'ayer_centavos')::bigint = 8136,
    'ganancia de hoy: ' || (r->'ganancia_hoy')::text);
  PERFORM pruebas.afirmar((r->'ganancia_mes'->>'ganancia_centavos')::bigint = mes, 'ganancia del mes ' || mes || ': ' || (r->'ganancia_mes')::text);
  PERFORM pruebas.afirmar((r->'dinero'->>'disponible_centavos')::bigint = 1198000 AND (r->'dinero'->>'por_confirmar_centavos')::bigint = 145000, 'dinero: ' || (r->'dinero')::text);
  PERFORM pruebas.afirmar((r->'te_deben'->>'total_centavos')::bigint = 78000 AND (r->'te_deben'->>'vencido_centavos')::bigint = 78000
    AND (r->'debes'->>'total_centavos')::bigint = 544000 AND (r->'debes'->>'vencido_centavos')::bigint = 544000, 'te deben y debes');
  PERFORM pruebas.afirmar(r->>'frase' LIKE 'Hoy vendiste L 30.00 y ganaste L 6.09.%' AND NOT (r->>'costos_ocultos')::boolean, 'frase: ' || (r->>'frase'));
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((r->'ganancia_mes'->>'mes_pasado_centavos')::bigint = (interno.calcular_estado_resultados(e,
    (date_trunc('month', hoy) - interval '1 month')::date, (date_trunc('month', hoy) - interval '1 day')::date)->>'utilidad_neta_centavos')::bigint,
    'mes pasado = estado de resultados del mes pasado');

  -- 5) Cajero sin ventas.ver: nada de cifras. Con ventas.ver (dado por el dueño) ve ventas pero no la ganancia (costos).
  PERFORM pruebas.como('cajero_a');
  r := public.resumen_hoy(e);
  PERFORM pruebas.afirmar(NOT (r ? 'ventas_hoy') AND NOT (r ? 'dinero') AND r->'ganancia_hoy' = 'null'::jsonb AND (r->>'costos_ocultos')::boolean
    AND r->'ocultos' ? 'te_deben', 'cajero sin cifras: ' || r::text);
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.rol_permiso (empresa_id, rol, permiso) VALUES (e, 'cajero', 'ventas.ver');
  PERFORM pruebas.como('cajero_a');
  r := public.resumen_hoy(e);
  PERFORM pruebas.afirmar((r->'ventas_hoy'->>'total_centavos')::bigint = 3000 AND r->'ganancia_hoy' = 'null'::jsonb AND (r->>'costos_ocultos')::boolean
    AND r->>'frase' = 'Hoy vendiste L 30.00.', 'ventas sí, costos no: ' || r::text);
  -- Otra empresa no.
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.alertas_activas(%L)', e), 'NO_PERTENECE', 'otra empresa');
  PERFORM pruebas.debe_fallar(format('SELECT public.resumen_hoy(%L)', e), 'NO_PERTENECE', 'otra empresa');
END $$;
