-- PRUEBA: régimen fiscal de Honduras como módulo (fiscal_hn): sin él la venta sale con ticket interno; registrar CAI por caja (formato, establecimiento y punto de emisión de la caja, sin cruces, no vencido); el servidor numera dentro del rango de ESA caja sin saltos; rango agotado y CAI vencido se rechazan sin consumir número; alertas por vencer y por agotarse configurables; un solo régimen activo; documento con CAI, rango, fecha límite, leyendas y total en letras
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  c2   uuid;
  r    jsonb;
  v    jsonb;
  a    jsonb;
  lim  text;
  rg2  uuid;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  lim := to_char(public.hoy_local(e) + 90, 'YYYY-MM-DD');

  -- 1) Sin el módulo fiscal_hn: no hay CAI y la venta es ticket.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000001', 'rango_hasta', '001-001-01-00000010',
    'fecha_limite_emision', lim)), 'MODULO_INACTIVO', 'CAI sin el módulo fiscal');
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'tipo_documento' = 'ticket' AND v->>'numero_documento' = 'T-001-001-00000001', 'ticket: ' || v::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || '{"tipo_documento":"factura"}'), 'MODULO_INACTIVO', 'factura sin régimen');
  PERFORM pruebas.afirmar((public.documento_venta((v->>'venta_id')::uuid)->'fiscal'->'leyendas'->>0) LIKE 'Documento interno%', 'ticket sin valor fiscal');

  -- 2) Activar el régimen; solo uno a la vez.
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fiscal_hn');
  INSERT INTO public.modulo (codigo, nombre) VALUES ('fiscal_xx', 'Régimen de otro país (prueba)');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', e, 'fiscal_xx'),
    'NO_PERMITIDO', 'un solo régimen fiscal');
  PERFORM pruebas.como('dueno_a');
  -- Sin CAI todavía: factura imposible, sin consumir nada.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)),
    'SIN_CAI', 'sin CAI');

  -- 3) Validaciones del CAI.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, '{}'), 'SIN_PERMISO', 'cajero no registra CAI');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'XYZ', 'rango_desde', '001-001-01-00000001', 'rango_hasta', '001-001-01-00000010', 'fecha_limite_emision', lim)),
    'CAI_INVALIDO', 'CAI mal escrito');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-002-01-00000001', 'rango_hasta', '001-002-01-00000010',
    'fecha_limite_emision', lim)), 'CAI_INVALIDO', 'punto de emisión de otra caja');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000010', 'rango_hasta', '001-001-01-00000001',
    'fecha_limite_emision', lim)), 'CAI_INVALIDO', 'rango al revés');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000001', 'rango_hasta', '001-001-01-00000010',
    'fecha_limite_emision', '2026-01-01')), 'CAI_VENCIDO', 'fecha límite pasada');
  -- Rango chico de 3 números (para agotarlo): 001-001-01-00000001 a 00000003; el CAI en minúsculas se guarda en mayúsculas.
  r := public.registrar_cai(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'a1b2c3-d4e5f6-a7b8c9-d0e1f2-a3b4c5-d6', 'rango_desde', '001-001-01-00000001', 'rango_hasta', '001-001-01-00000003',
    'fecha_limite_emision', lim));
  PERFORM pruebas.afirmar((r->>'disponibles')::int = 3 AND r->>'cai' = 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'CAI registrado: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000003', 'rango_hasta', '001-001-01-00000009',
    'fecha_limite_emision', lim)), 'CAI_INVALIDO', 'rangos que se cruzan');

  -- 4) Numera el servidor, en orden y sin saltos; el ticket sigue con su propio correlativo.
  PERFORM pruebas.como('dueno_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'tipo_documento' = 'factura' AND v->>'numero_documento' = '001-001-01-00000001', 'primera factura');
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'numero_documento' = '001-001-01-00000002', 'segunda factura');
  -- Una venta que falla (sin existencia; el cajero no tiene "inventario.negativo") no consume número.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1000)),
    'EXISTENCIA_INSUFICIENTE', 'sin existencia');
  PERFORM pruebas.como('dueno_a');
  -- Alertas: 2 de 3 usados = 66.7 % (no llega a 80 %); al bajar el umbral a 60 % aparece; vence en 90 días y la alerta es a 30.
  a := public.cai_alertas(e);
  PERFORM pruebas.afirmar(NOT (a->'alertas' @> '[{"tipo":"por_agotarse"}]') AND NOT (a->'alertas' @> '[{"tipo":"por_vencer"}]'), 'sin alertas: ' || a::text);
  PERFORM public.configurar_empresa(e, '{"cai_porcentaje_alerta": 60, "cai_dias_alerta": 120}', 'Umbrales de prueba');
  a := public.cai_alertas(e);
  PERFORM pruebas.afirmar(a->'alertas' @> '[{"tipo":"por_agotarse","disponibles":1}]' AND a->'alertas' @> '[{"tipo":"por_vencer","dias":90}]',
    'alertas configurables: ' || a::text);
  PERFORM pruebas.afirmar((SELECT porcentaje_usado || '/' || numeros_disponibles || '/' || ultimo_emitido || '/' || alerta_agotamiento
                             FROM public.v_cai_rango WHERE cai_rango_id = (r->>'cai_rango_id')::uuid) = '66.7/1/001-001-01-00000002/true', 'vista del rango');
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'numero_documento' = '001-001-01-00000003', 'tercera factura');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)),
    'CAI_AGOTADO', 'rango agotado');
  PERFORM pruebas.afirmar(public.cai_alertas(e)->'alertas' @> '[{"tipo":"agotado"}]' AND public.cai_alertas(e)->'alertas' @> '[{"tipo":"sin_cai"}]',
    'alerta agotado y caja sin CAI vigente');

  -- 5) Rango nuevo (continúa) y CAI vencido.
  rg2 := (public.registrar_cai(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'C1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000004', 'rango_hasta', '001-001-01-00000100',
    'fecha_limite_emision', lim))->>'cai_rango_id')::uuid;
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'numero_documento' = '001-001-01-00000004'
    AND (SELECT datos_fiscales->>'cai' FROM public.venta WHERE id = (v->>'venta_id')::uuid) = 'C1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'sigue con el rango nuevo');
  -- Se simula que el CAI ya venció (la fecha límite no se edita: se cambia con el superusuario).
  PERFORM pruebas.como('superusuario');
  ALTER TABLE public.cai_rango DISABLE TRIGGER proteger;
  UPDATE public.cai_rango SET fecha_limite_emision = public.hoy_local(e) - 1 WHERE id = rg2;
  ALTER TABLE public.cai_rango ENABLE TRIGGER proteger;
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)),
    'CAI_VENCIDO', 'CAI vencido');
  PERFORM pruebas.afirmar((SELECT ultimo_numero FROM public.cai_rango WHERE id = rg2) = 4, 'el vencido no consumió número');

  -- 6) Una factura no lleva fecha futura ni anterior a la última del rango (orden).
  rg2 := (public.registrar_cai(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
    'cai', 'D1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000101', 'rango_hasta', '001-001-01-00000200',
    'fecha_limite_emision', lim))->>'cai_rango_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('fecha', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD'))), 'FECHA_INVALIDA', 'factura futura');
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('fecha', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'))), 'FECHA_INVALIDA', 'factura con fecha atrás');

  -- 7) El rango no se edita; el documento lleva los datos fiscales y el total en letras.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cai_rango SET cai = %L WHERE id = %L', 'X', rg2), 'PROHIBIDO', 'CAI inmutable');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cai_rango SET ultimo_numero = ultimo_numero - 1 WHERE id = %L', rg2), 'PROHIBIDO', 'correlativo no retrocede');
  PERFORM pruebas.como('dueno_a');
  a := public.documento_venta((v->>'venta_id')::uuid);
  PERFORM pruebas.afirmar(a->>'tipo' = 'FACTURA' AND a->>'numero_documento' = '001-001-01-00000101'
    AND a->'fiscal'->>'cai' = 'D1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6'
    AND a->'fiscal'->>'rango_autorizado' = '001-001-01-00000101 al 001-001-01-00000200'
    AND a->'fiscal'->>'fecha_limite_emision' = to_char(public.hoy_local(e) + 90, 'DD/MM/YYYY')
    AND a->'fiscal'->'leyendas' ? 'La factura es beneficio de todos. ¡Exíjala!'
    AND a->'emisor'->>'rtn' = '08011999000001' AND a->'cliente'->>'nombre' = 'Consumidor final'
    AND a->'totales'->>'total_en_letras' = 'QUINCE LEMPIRAS CON 00/100', 'documento: ' || a::text);
  PERFORM public.configurar_empresa(e, '{"leyenda_factura": "Gracias por su compra"}', 'Leyenda propia');
  PERFORM pruebas.afirmar(public.documento_venta((v->>'venta_id')::uuid)->'fiscal'->'leyendas' ? 'Gracias por su compra', 'leyenda propia');

  -- 8) Total en letras (a mano).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.monto_en_letras(123456789, 'HNL') = 'UN MILLÓN DOSCIENTOS TREINTA Y CUATRO MIL QUINIENTOS SESENTA Y SIETE LEMPIRAS CON 89/100',
    interno.monto_en_letras(123456789, 'HNL'));
  PERFORM pruebas.afirmar(interno.monto_en_letras(2110000, 'HNL') = 'VEINTIÚN MIL CIEN LEMPIRAS CON 00/100', interno.monto_en_letras(2110000, 'HNL'));
  PERFORM pruebas.afirmar(interno.monto_en_letras(100, 'HNL') = 'UN LEMPIRA CON 00/100', interno.monto_en_letras(100, 'HNL'));
  PERFORM pruebas.afirmar(interno.monto_en_letras(200000000, 'HNL') = 'DOS MILLONES DE LEMPIRAS CON 00/100', interno.monto_en_letras(200000000, 'HNL'));
  PERFORM pruebas.afirmar(interno.monto_en_letras(31550, 'HNL') = 'TRESCIENTOS QUINCE LEMPIRAS CON 50/100', interno.monto_en_letras(31550, 'HNL'));
END $$;
