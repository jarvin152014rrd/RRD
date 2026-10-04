-- PRUEBA: cierre de mes completo (cifras a mano): cerrar_mes guarda una foto inmutable (saldos de cuentas, estado de resultados con utilidad cobrada, balance, flujo directo, CxC con antigüedad, CxP, inventario valorizado, cuentas de dinero, saldo a favor, comisiones e ISV) y lista advertencias sin bloquear (depósito en tránsito, transferencias por confirmar, aprobaciones, cuentas en negativo); en orden; reintento seguro; selector de meses (foto o en vivo "preliminar") con comparativo; reabrir deja la foto superada y al cerrar otra vez se crea la versión 2 (historial); exportar_mes sin emojis y con fechas ISO; permisos (admin cierra, cajero no, contador solo lee); un descuadre contable no deja cerrar
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  r    jsonb;
  er   jsonb;
  bg   jsonb;
  fl   jsonb;
  x    jsonb;
  c1   uuid;
  c2   uuid;
BEGIN
  PERFORM pruebas.crear_contador();
  PERFORM pruebas.preparar_enero();

  -- ===================== Enero abierto: en vivo y preliminar =====================
  -- A mano (enero):
  --   ventas sin ISV 13,043 + 38,136 + 40,000 = 91,179; costo 10,000 + 30,000 = 40,000
  --   utilidad bruta 51,179; margen 51,179 / 91,179 = 56.13 %; gastos 11,500; utilidad neta 39,679
  --   utilidad por cobrar al 31/01: V_ENE_2 saldo 25,000 x (38,136 - 30,000) / 45,000 = 4,520
  --   utilidad cobrada = 39,679 - (4,520 - 0) = 35,159
  er := public.estado_resultados(e, 2026, 1);
  PERFORM pruebas.afirmar(er->>'fuente' = 'en_vivo' AND (er->>'preliminar')::boolean AND er->>'estado_mes' = 'abierto'
    AND er->>'nota' LIKE 'PRELIMINAR%', 'enero abierto: en vivo y preliminar');
  PERFORM pruebas.afirmar((er->>'ventas_brutas_centavos')::bigint = 91179 AND (er->>'devoluciones_descuentos_centavos')::bigint = 0
    AND (er->>'ventas_netas_centavos')::bigint = 91179 AND (er->>'costo_ventas_centavos')::bigint = 40000
    AND (er->>'utilidad_bruta_centavos')::bigint = 51179 AND (er->>'margen_bruto_porcentaje')::numeric = 56.13
    AND (er->>'gastos_operacion_centavos')::bigint = 11500 AND (er->>'utilidad_operativa_centavos')::bigint = 39679
    AND (er->>'utilidad_neta_centavos')::bigint = 39679 AND (er->>'utilidad_facturada_centavos')::bigint = 39679
    AND (er->>'utilidad_por_cobrar_fin_centavos')::bigint = 4520 AND (er->>'utilidad_cobrada_centavos')::bigint = 35159,
    'estado de resultados de enero: ' || er::text);
  PERFORM pruebas.afirmar(er->'gastos_por_categoria' = '[{"codigo": "6.1.02.02", "nombre": "Energía eléctrica", "monto_centavos": 11500}]'::jsonb,
    'gastos por categoría: ' || (er->'gastos_por_categoria')::text);
  PERFORM pruebas.afirmar(er->'comparativo'->'mes_anterior' = 'null'::jsonb AND er->'comparativo'->'mismo_mes_anio_anterior' = 'null'::jsonb,
    'sin meses anteriores al inicio');

  -- ===================== Cerrar enero (el admin) =====================
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, 2026, 1)', e), 'SIN_PERMISO', 'cajero no cierra');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_resultados(%L, 2026, 1)', e), 'SIN_PERMISO', 'cajero no ve estados');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, 2026, 1)', e), 'SIN_PERMISO', 'contador no cierra');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, 2026, 2)', e), 'MES_ANTERIOR_ABIERTO', 'en orden');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, %s, %s)', e, extract(year FROM public.hoy_local(e)), extract(month FROM public.hoy_local(e))),
    'MES_NO_TERMINADO', 'el mes en curso no se cierra');
  r := public.cerrar_mes(e, 2026, 1, 'Cierre de enero');
  c1 := (r->>'cierre_id')::uuid;
  PERFORM pruebas.afirmar(r->>'estado' = 'cerrado' AND (r->>'version')::integer = 1 AND NOT (r->>'ya_estaba')::boolean,
    'enero cerrado, versión 1: ' || r::text);
  -- Advertencias (no bloquean): el depósito de 50,000 sigue en tránsito.
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advertencias') a
    WHERE a->>'tipo' = 'depositos_en_transito' AND (a->>'monto_centavos')::bigint = 50000 AND (a->>'cantidad')::integer = 1)
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advertencias') a WHERE a->>'tipo' IN ('alerta_cuadre', 'cuentas_en_negativo')),
    'advertencias: ' || (r->'advertencias')::text);
  PERFORM pruebas.afirmar((r->'resumen'->>'utilidad_cobrada_centavos')::bigint = 35159 AND (r->'resumen'->>'total_activo_centavos')::bigint = 1798500,
    'resumen: ' || (r->'resumen')::text);
  -- Reintento: lo mismo, sin otra versión.
  r := public.cerrar_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((r->>'ya_estaba')::boolean AND (r->>'cierre_id')::uuid = c1, 'reintento seguro');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, %L, %L, %L, gen_random_uuid())', e, '2026-01-31', 'Tarde',
    pruebas.lineas('1.1.01.01', '4.2.01.02', 100)), 'PERIODO_CERRADO', 'enero bloqueado');

  -- ===================== La foto de enero (cifras a mano) =====================
  PERFORM pruebas.como('contador');
  er := public.estado_resultados(e, 2026, 1);
  PERFORM pruebas.afirmar(er->>'fuente' = 'foto' AND NOT (er->>'preliminar')::boolean AND (er->>'version')::integer = 1
    AND (er->>'utilidad_cobrada_centavos')::bigint = 35159 AND (er->>'utilidad_neta_centavos')::bigint = 39679, 'contador lee la foto de enero');
  -- Estado de resultados = saldo_cuentas (los libros).
  PERFORM pruebas.afirmar((er->>'ventas_brutas_centavos')::bigint = (SELECT movimiento_centavos FROM public.saldo_cuentas(e, '2026-01-01', '2026-01-31') WHERE codigo = '4.1.01.01')
    AND (er->>'costo_ventas_centavos')::bigint = (SELECT sum(movimiento_centavos) FROM public.saldo_cuentas(e, '2026-01-01', '2026-01-31') WHERE tipo = 'costo')
    AND (er->>'utilidad_neta_centavos')::bigint =
        (SELECT sum(CASE WHEN tipo = 'ingreso' THEN 1 ELSE -1 END * CASE WHEN naturaleza = 'acreedora' AND tipo = 'ingreso' OR naturaleza = 'deudora' AND tipo <> 'ingreso' THEN movimiento_centavos ELSE -movimiento_centavos END)
           FROM public.saldo_cuentas(e, '2026-01-01', '2026-01-31') WHERE tipo IN ('ingreso', 'costo', 'gasto')),
    'estado de resultados = saldo_cuentas');
  -- Balance al 31/01: dinero 1,269,500 + clientes 25,000 + inventario 435,000 + ISV crédito 69,000 = 1,798,500
  --   pasivo: proveedores 444,000 + ISV por pagar 14,821 = 458,821
  --   patrimonio: saldos de apertura 1,300,000 + resultado del ejercicio 39,679 = 1,339,679; 458,821 + 1,339,679 = 1,798,500
  bg := public.balance_general(e, 2026, 1);
  PERFORM pruebas.afirmar((bg->>'total_activo_centavos')::bigint = 1798500 AND (bg->>'total_pasivo_centavos')::bigint = 458821
    AND (bg->>'total_patrimonio_centavos')::bigint = 1339679 AND (bg->>'resultado_ejercicio_centavos')::bigint = 39679
    AND (bg->>'cuadra')::boolean AND (bg->>'diferencia_centavos')::bigint = 0, 'balance de enero: ' || bg::text);
  PERFORM pruebas.afirmar((bg->>'total_activo_centavos')::bigint = (SELECT sum(saldo_final_centavos * CASE WHEN naturaleza = 'deudora' THEN 1 ELSE -1 END)
      FROM public.saldo_cuentas(e, NULL, '2026-01-31') WHERE tipo = 'activo')
    AND (bg->>'total_pasivo_centavos')::bigint = (SELECT sum(saldo_final_centavos) FROM public.saldo_cuentas(e, NULL, '2026-01-31') WHERE tipo = 'pasivo'),
    'balance = saldo_cuentas');
  -- Flujo directo de enero: entradas = saldos iniciales 1,300,000 + ventas 61,000 + cobro 20,000 = 1,381,000;
  -- salidas = gasto 11,500 + pago 100,000 = 111,500; traslado interno (depósito) 50,000; final 1,269,500.
  fl := public.flujo_efectivo(e, 2026, 1);
  PERFORM pruebas.afirmar((fl->>'saldo_inicial_centavos')::bigint = 0 AND (fl->>'entradas_centavos')::bigint = 1381000
    AND (fl->>'salidas_centavos')::bigint = 111500 AND (fl->>'traslados_internos_centavos')::bigint = 50000
    AND (fl->>'saldo_final_centavos')::bigint = 1269500 AND (fl->>'cuadra')::boolean, 'flujo de enero: ' || fl::text);
  PERFORM pruebas.afirmar((SELECT (y->>'monto_centavos')::bigint FROM jsonb_array_elements(fl->'entradas') y WHERE y->>'tipo' = 'venta') = 61000
    AND (SELECT (y->>'monto_centavos')::bigint FROM jsonb_array_elements(fl->'salidas') y WHERE y->>'tipo' = 'pago_proveedor') = 100000,
    'entradas y salidas por tipo');
  -- Secciones restantes.
  x := public.cuentas_por_cobrar_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((x->>'total_centavos')::bigint = 25000 AND (x->'clientes'->0->>'saldo_centavos')::bigint = 25000
    AND (x->'clientes'->0->>'de_0_a_30_centavos')::bigint = 25000 AND (x->>'vencido_centavos')::bigint = 0, 'CxC de enero: ' || x::text);
  x := public.cuentas_por_pagar_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((x->>'total_centavos')::bigint = 444000 AND (x->'proveedores'->0->>'nombre') = 'Distribuidora Lara', 'CxP de enero: ' || x::text);
  x := public.inventario_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((x->>'valor_inventario_centavos')::bigint = 435000
    AND (SELECT (y->>'cantidad')::numeric = 90 AND (y->>'valor_inventario_centavos')::bigint = 90000 FROM jsonb_array_elements(x->'productos') y
          WHERE y->>'codigo' = 'TOR-001'), 'inventario de enero (contador ve costos): ' || x::text);
  x := public.dinero_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((x->>'saldo_final_centavos')::bigint = 1269500
    AND (SELECT (y->>'saldo_final_centavos')::bigint FROM jsonb_array_elements(x->'cuentas') y WHERE y->>'nombre' = 'BAC cheques') = 888500
    AND (SELECT (y->>'saldo_final_centavos')::bigint FROM jsonb_array_elements(x->'cuentas') y WHERE y->>'nombre' = 'Caja 1') = 35000,
    'dinero de enero: ' || x::text);
  -- ISV de enero: débito 1,957 + 6,864 + 6,000 = 14,821; crédito (compra) 69,000; a pagar -54,179 (crédito a favor).
  x := public.isv_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((x->>'debito_fiscal_centavos')::bigint = 14821 AND (x->>'credito_fiscal_centavos')::bigint = 69000
    AND (x->>'a_pagar_centavos')::bigint = -54179, 'ISV de enero: ' || x::text);
  x := public.saldos_cuentas_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((x->>'sumas_iguales')::boolean AND (x->>'debe_centavos')::bigint = (x->>'haber_centavos')::bigint, 'sumas iguales');

  -- ===================== Exportar (JSON para PDF / Excel) =====================
  x := public.exportar_mes(e, 2026, 1);
  PERFORM pruebas.afirmar(x->>'fuente' = 'foto' AND x->>'desde' = '2026-01-01' AND x->>'hasta' = '2026-01-31'
    AND x->>'generado_en' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    AND (SELECT count(*) FROM jsonb_object_keys(x->'secciones')) = 11
    AND (x->'secciones'->'comisiones'->>'total_centavos')::bigint = 0
    AND (x->'secciones'->'saldo_favor'->>'saldo_favor_y_vales_centavos')::bigint = 0
    AND jsonb_array_length(x->'advertencias') >= 1 AND x->>'nota' LIKE '%contador hondureño%', 'exportar_mes: ' || left(x::text, 400));
  PERFORM pruebas.afirmar(NOT (x::text ~ '[\U0001F000-\U0001FAFF]|[☀-➿]'), 'sin emojis');

  -- ===================== Febrero y comparativo =====================
  -- 03/02 se confirma el depósito; 05/02 CLI1 paga 25,000; 10/02 venta de 20 tornillos = 30,000 (26,087 + 3,913; costo 20,000);
  -- 14/02 venta al crédito de 10 lb de arroz exento = 22,000 (costo 15,000); 20/02 papelería 5,000.
  -- A mano: ventas 48,087; costo 35,000; bruta 13,087 (27.22 %); gastos 5,000; neta 8,087.
  -- Por cobrar al 28/02: 22,000 x 7,000 / 22,000 = 7,000 -> cobrada = 8,087 - (7,000 - 4,520) = 5,607.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.confirmar_deposito(pruebas.id('DEP_ENE'), gen_random_uuid(), '2026-02-03');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'fecha', '2026-02-05',
    'pagos', '[{"forma":"efectivo","monto_centavos":25000}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 20, 'efectivo') || '{"fecha": "2026-02-10"}', gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P2', 10, 'credito', 'CLI1') || '{"fecha": "2026-02-14"}', gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 5000, 'descripcion', 'Papelería', 'fecha', '2026-02-20'), gen_random_uuid());
  er := public.estado_resultados(e, 2026, 2);
  PERFORM pruebas.afirmar((er->>'preliminar')::boolean AND (er->>'ventas_netas_centavos')::bigint = 48087 AND (er->>'costo_ventas_centavos')::bigint = 35000
    AND (er->>'utilidad_bruta_centavos')::bigint = 13087 AND (er->>'margen_bruto_porcentaje')::numeric = 27.22
    AND (er->>'utilidad_neta_centavos')::bigint = 8087 AND (er->>'utilidad_por_cobrar_inicio_centavos')::bigint = 4520
    AND (er->>'utilidad_por_cobrar_fin_centavos')::bigint = 7000 AND (er->>'utilidad_cobrada_centavos')::bigint = 5607,
    'febrero en vivo: ' || er::text);
  -- Comparativo con enero (foto): ventas -43,092; neta 8,087 - 39,679 = -31,592; (-31,592 / 39,679 = -79.62 %).
  PERFORM pruebas.afirmar(er->'comparativo'->'mes_anterior'->>'fuente' = 'foto'
    AND (er->'comparativo'->'mes_anterior'->>'ventas_netas_centavos')::bigint = 91179
    AND (er->'comparativo'->'mes_anterior'->>'ventas_netas_variacion_centavos')::bigint = -43092
    AND (er->'comparativo'->'mes_anterior'->>'utilidad_neta_variacion_centavos')::bigint = -31592
    AND (er->'comparativo'->'mes_anterior'->>'utilidad_neta_variacion_porcentaje')::numeric = -79.62
    AND er->'comparativo'->'mismo_mes_anio_anterior' = 'null'::jsonb, 'comparativo: ' || (er->'comparativo')::text);
  -- Flujo de febrero: la confirmación del depósito es interna (50,000).
  fl := public.flujo_efectivo(e, 2026, 2);
  PERFORM pruebas.afirmar((fl->>'saldo_inicial_centavos')::bigint = 1269500 AND (fl->>'entradas_centavos')::bigint = 55000
    AND (fl->>'salidas_centavos')::bigint = 5000 AND (fl->>'traslados_internos_centavos')::bigint = 50000
    AND (fl->>'saldo_final_centavos')::bigint = 1319500 AND (fl->>'cuadra')::boolean, 'flujo de febrero: ' || fl::text);

  -- Cerrar febrero; reabrirlo (solo el dueño, con motivo, en orden) deja la foto superada; volver a cerrar = versión 2.
  r := public.cerrar_mes(e, 2026, 2);
  c2 := (r->>'cierre_id')::uuid;
  PERFORM pruebas.afirmar((r->>'version')::integer = 1 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advertencias') a
    WHERE a->>'tipo' = 'depositos_en_transito'), 'febrero cerrado sin depósitos en tránsito');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 1, %L)', e, 'Corregir enero'), 'REABRIR_EN_ORDEN', 'reabrir en orden');
  PERFORM public.reabrir_periodo(e, 2026, 2, 'Falta una factura de febrero');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado = 'superada' AND motivo_superada = 'Falta una factura de febrero' AND superada_por = pruebas.usuario('dueno_a')
    FROM public.cierre WHERE id = c2), 'la foto de febrero queda superada (no se borra)');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cierre_detalle SET datos = %L WHERE cierre_id = %L', '{}', c1), 'PROHIBIDO', 'la foto no se edita');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.cierre WHERE id = %L', c2), 'no se borran', 'la foto no se borra');
  PERFORM pruebas.como('dueno_a');
  er := public.estado_resultados(e, 2026, 2);
  PERFORM pruebas.afirmar(er->>'fuente' = 'en_vivo' AND (er->>'preliminar')::boolean, 'febrero reabierto: en vivo');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 1000, 'descripcion', 'Factura olvidada', 'fecha', '2026-02-27'), gen_random_uuid());
  r := public.cerrar_mes(e, 2026, 2, 'Cierre corregido');
  PERFORM pruebas.afirmar((r->>'version')::integer = 2 AND (r->'resumen'->>'utilidad_neta_centavos')::bigint = 7087, 'versión 2 con el gasto: ' || r::text);
  PERFORM pruebas.afirmar((SELECT string_agg(version || ':' || estado, ',' ORDER BY version) FROM public.historial_cierres(e, 2026, 2)) = '1:superada,2:vigente',
    'historial de versiones');
  x := public.ver_cierre(c2);
  PERFORM pruebas.afirmar(x->>'estado' = 'superada' AND (x->'secciones'->'estado_resultados'->>'utilidad_neta_centavos')::bigint = 8087,
    'la versión 1 se sigue viendo completa');

  -- Un mes abierto en vivo (marzo) y sin permisos el cajero no exporta.
  x := public.exportar_mes(e, 2026, 3);
  PERFORM pruebas.afirmar(x->>'fuente' = 'en_vivo' AND (x->>'preliminar')::boolean AND (x->'secciones'->'balance_general'->>'cuadra')::boolean,
    'marzo en vivo');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.exportar_mes(%L, 2026, 1)', e), 'SIN_PERMISO', 'cajero no exporta');

  -- ===================== Advertencias que no bloquean (marzo) =====================
  -- Transferencia de cliente por confirmar, gasto pendiente de aprobación (del admin, sobre su tope) y una caja en negativo.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_saldo_negativo(e, pruebas.id('CCHICA'), 'permitir_con_alerta', NULL, 'Prueba de alerta');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CCHICA'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 700, 'descripcion', 'Sin fondo', 'fecha', '2026-03-03'), gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 1, 'transferencia') || '{"fecha": "2026-03-04"}', gen_random_uuid());
  PERFORM pruebas.como('admin_a');   -- L 6,000 pasa su tope de L 5,000: queda pendiente
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 600000, 'descripcion', 'Pide aprobación', 'fecha', '2026-03-05'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  r := public.cerrar_mes(e, 2026, 3);
  PERFORM pruebas.afirmar((SELECT string_agg(a->>'tipo', ',' ORDER BY a->>'tipo') FROM jsonb_array_elements(r->'advertencias') a)
    = 'aprobaciones_pendientes,cuentas_en_negativo,transferencias_por_confirmar', 'advertencias de marzo: ' || (r->'advertencias')::text);

  -- ===================== Descuadre contable: no cierra =====================
  PERFORM pruebas.como('superusuario');
  SET LOCAL session_replication_role = replica;   -- salta las defensas solo para fabricar el descuadre
  INSERT INTO public.asiento (empresa_id, sucursal_id, numero, fecha_contable, descripcion, origen, id_operacion, total_centavos)
  SELECT e, s.id, 999999, '2026-04-05', 'Descuadrado a propósito', 'manual', gen_random_uuid(), 100
    FROM public.sucursal s WHERE s.empresa_id = e AND s.codigo = '001';
  INSERT INTO public.asiento_linea (empresa_id, asiento_id, linea, cuenta_id, debe_centavos)
  SELECT e, a.id, 1, c.id, 100 FROM public.asiento a, public.cuenta c
   WHERE a.empresa_id = e AND a.numero = 999999 AND c.empresa_id = e AND c.codigo = '1.1.01.01';
  SET LOCAL session_replication_role = origin;
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, 2026, 4)', e), 'DESCUADRE_CONTABLE', 'descuadre no cierra');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.periodo WHERE empresa_id = e AND anio = 2026 AND mes = 4 AND estado = 'cerrado'),
    'abril sigue abierto');
END $$;
