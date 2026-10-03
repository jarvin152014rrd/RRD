-- PRUEBA: caja chica (fondo fijo, gastos con y sin comprobante, cuadre = fondo - gastos, reposición de lo gastado) y comprobantes (ruta de la empresa, sha256, solo agregar); pagos fijos: vencimientos mensuales y semanales, próximos y vencidos, registrar genera un gasto REAL con el monto real, un vencimiento se paga una vez, total mensual
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  g1   jsonb; g2 jsonb;
  r    jsonb;
  a1   jsonb;
  pf   public.pago_fijo;
  alq  uuid; vig uuid; seg uuid;
  hoy  date := public.hoy_local(pruebas.empresa('A'));
  m0   date := date_trunc('month', public.hoy_local(pruebas.empresa('A')))::date;
  m1   date; m2 date;
  x    record;
BEGIN
  m1 := (m0 - interval '1 month')::date;
  m2 := (m0 - interval '2 months')::date;
  PERFORM pruebas.preparar_dinero();
  -- Inicio: BAC 1,000,000; caja chica fondo 200,000 y saldo 0.

  -- 1) Reposición sin monto: 200,000 del BAC (800,000).
  PERFORM pruebas.como('admin_a');
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'reposicion_caja_chica', 'origen_id', pruebas.id('BANCO'),
    'destino_id', pruebas.id('CCHICA'), 'fecha', '2026-01-05'), gen_random_uuid());
  -- 2) Gastos de caja chica: 30,000 con comprobante y 20,000 sin él. Saldo 150,000.
  g1 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CCHICA'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 30000, 'descripcion', 'Folders', 'fecha', '2026-01-06', 'comprobante', pruebas.comprobante('folders.jpg')), gen_random_uuid());
  g2 := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CCHICA'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 20000, 'descripcion', 'Café para clientes', 'fecha', '2026-01-07'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'cuenta_dinero_id', pruebas.id('CCHICA'), 'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 150001, 'descripcion', 'Silla')),
    'SALDO_INSUFICIENTE', 'gasto mayor que la caja chica');
  -- Cuadre: fondo 200,000 - gastos 50,000 = 150,000 = esperado; faltan reponer 50,000.
  --         Con 149,000 contados, diferencia -1,000.
  r := public.cuadre_caja_chica(pruebas.id('CCHICA'), 149000);
  PERFORM pruebas.afirmar((r->>'fondo_fijo_centavos')::bigint = 200000 AND (r->>'efectivo_esperado_centavos')::bigint = 150000
    AND (r->>'por_reponer_centavos')::bigint = 50000 AND (r->'gastos_ciclo'->>'cantidad')::int = 2
    AND (r->'gastos_ciclo'->>'total_centavos')::bigint = 50000 AND (r->'gastos_ciclo'->>'con_comprobante_centavos')::bigint = 30000
    AND (r->'gastos_ciclo'->>'sin_comprobante_centavos')::bigint = 20000 AND (r->'gastos_ciclo'->>'cantidad_sin_comprobante')::int = 1
    AND (r->>'fondo_menos_gastos_centavos')::bigint = 150000 AND (r->>'cuadra_con_fondo')::boolean
    AND (r->>'diferencia_centavos')::bigint = -1000, 'cuadre: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.cuadre_caja_chica(%L)', pruebas.id('BANCO')), 'CUENTA_DINERO_INVALIDA', 'cuadre de un banco');

  -- 3) Comprobante que faltaba, agregado después (validaciones y solo agregar).
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_adjunto(%L, %L, %L, %L)', e, 'gasto', g2->>'gasto_id',
    jsonb_build_object('ruta', 'otra_empresa/cafe.jpg', 'tipo', 'image/jpeg', 'sha256', repeat('a', 64))), 'carpeta de la empresa', 'ruta ajena');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_adjunto(%L, %L, %L, %L)', e, 'gasto', g2->>'gasto_id',
    jsonb_build_object('ruta', e::text || '/../x.jpg', 'tipo', 'image/jpeg', 'sha256', repeat('a', 64))), 'carpeta de la empresa', 'ruta con ..');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_adjunto(%L, %L, %L, %L)', e, 'gasto', g2->>'gasto_id',
    jsonb_build_object('ruta', e::text || '/cafe.txt', 'tipo', 'text/plain', 'sha256', repeat('a', 64))), 'foto', 'tipo no permitido');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_adjunto(%L, %L, %L, %L)', e, 'gasto', g2->>'gasto_id',
    jsonb_build_object('ruta', e::text || '/cafe.jpg', 'tipo', 'image/jpeg', 'sha256', 'abc')), 'sha256', 'huella mala');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_adjunto(%L, %L, %L, %L)', e, 'gasto', gen_random_uuid(),
    pruebas.comprobante('cafe.jpg')), 'NO_EXISTE', 'documento inventado');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_adjunto(%L, %L, %L, %L)', e, 'venta', g2->>'gasto_id',
    pruebas.comprobante('cafe.jpg')), 'NO_EXISTE', 'tipo de documento desconocido');
  a1 := public.agregar_adjunto(e, 'gasto', (g2->>'gasto_id')::uuid, pruebas.comprobante('cafe.jpg') || '{"tamano_bytes": 34567, "nombre": "cafe.jpg"}');
  PERFORM pruebas.afirmar((public.agregar_adjunto(e, 'gasto', (g2->>'gasto_id')::uuid, pruebas.comprobante('cafe.jpg'))->>'adjunto_id') = a1->>'adjunto_id',
    'el mismo comprobante no se repite');
  PERFORM pruebas.afirmar((public.cuadre_caja_chica(pruebas.id('CCHICA'))->'gastos_ciclo'->>'sin_comprobante_centavos')::bigint = 0, 'ya todos con comprobante');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_adjunto(%L, %L, %L, %L)', e, 'gasto', g2->>'gasto_id', pruebas.comprobante('v.jpg')),
    'SIN_PERMISO', 'vendedor adjunta');
  PERFORM pruebas.debe_fallar(format('SELECT public.cuadre_caja_chica(%L)', pruebas.id('CCHICA')), 'SIN_PERMISO', 'vendedor ve el cuadre');
  PERFORM pruebas.como('cajero_a');
  PERFORM public.agregar_adjunto(e, 'gasto', (g1->>'gasto_id')::uuid, pruebas.comprobante('folders-2.jpg'));
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.adjunto) = 1, 'el cajero ve solo lo que él subió');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar('UPDATE public.adjunto SET ruta = ''x''', 'PROHIBIDO', 'editar comprobante');
  PERFORM pruebas.debe_fallar('DELETE FROM public.adjunto', 'PROHIBIDO', 'borrar comprobante');

  -- 4) Reposición de lo gastado: 50,000 (BAC 750,000). Ciclo nuevo sin gastos y cuadra.
  PERFORM pruebas.como('admin_a');
  r := public.trasladar_dinero(e, jsonb_build_object('tipo', 'reposicion_caja_chica', 'origen_id', pruebas.id('BANCO'),
    'destino_id', pruebas.id('CCHICA'), 'fecha', '2026-01-08'), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'monto_centavos')::bigint = 50000 AND pruebas.dinero('CCHICA') = 200000 AND pruebas.dinero('BANCO') = 750000, 'repuesta');
  r := public.cuadre_caja_chica(pruebas.id('CCHICA'));
  PERFORM pruebas.afirmar((r->'gastos_ciclo'->>'cantidad')::int = 0 AND (r->>'por_reponer_centavos')::bigint = 0 AND (r->>'cuadra_con_fondo')::boolean,
    'ciclo nuevo: ' || r::text);

  -- 5) Vencimientos (cálculo puro).
  PERFORM pruebas.como('superusuario');
  pf.frecuencia := 'mensual'; pf.cada := 3; pf.dia := 31; pf.fecha_inicio := '2026-01-01';
  PERFORM pruebas.afirmar((SELECT string_agg(v::text, ',' ORDER BY v) FROM interno.vencimientos_pago_fijo(pf, '2026-12-31') v)
    = '2026-01-31,2026-04-30,2026-07-31,2026-10-31', 'trimestral día 31 (abril: 30)');
  pf.cada := 1; pf.dia := 15; pf.fecha_inicio := '2026-01-20';
  PERFORM pruebas.afirmar((SELECT string_agg(v::text, ',' ORDER BY v) FROM interno.vencimientos_pago_fijo(pf, '2026-04-30') v)
    = '2026-02-15,2026-03-15,2026-04-15', 'mensual día 15 desde el 20/01');
  pf.frecuencia := 'semanal'; pf.cada := 2; pf.dia := 5; pf.fecha_inicio := '2026-09-01';   -- martes; viernes cada 2 semanas
  PERFORM pruebas.afirmar((SELECT string_agg(v::text, ',' ORDER BY v) FROM interno.vencimientos_pago_fijo(pf, '2026-10-31') v)
    = '2026-09-04,2026-09-18,2026-10-02,2026-10-16,2026-10-30', 'quincenal los viernes');

  -- 6) Plantillas: alquiler (500,000 el día 1, desde hace dos meses, del BAC), vigilancia (100,000
  --    viernes cada 2 semanas, desde mañana) y seguro (300,000 cada 3 meses, sin cuenta sugerida).
  PERFORM pruebas.como('admin_a');
  alq := (public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Alquiler del local', 'categoria_id', pruebas.id('CAT_ALQ'),
    'monto_estimado_centavos', 500000, 'frecuencia', 'mensual', 'dia', 1, 'fecha_inicio', m2, 'cuenta_dinero_id', pruebas.id('BANCO')))->>'pago_fijo_id')::uuid;
  vig := (public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Vigilancia', 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_estimado_centavos', 100000, 'frecuencia', 'semanal', 'cada', 2, 'dia', 5, 'fecha_inicio', hoy + 1))->>'pago_fijo_id')::uuid;
  seg := (public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Seguro', 'categoria_id', pruebas.id('CAT_ALQ'),
    'monto_estimado_centavos', 300000, 'frecuencia', 'mensual', 'cada', 3, 'dia', 31, 'fecha_inicio', '2026-01-01'))->>'pago_fijo_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_pago_fijo(%L, %L)', e, jsonb_build_object('nombre', 'X', 'categoria_id', pruebas.id('CAT_ALQ'),
    'frecuencia', 'semanal', 'dia', 8)), 'DATO_INVALIDO', 'día de semana 8');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_pago_fijo(%L, %L)', e, jsonb_build_object('nombre', 'alquiler DEL LOCAL', 'categoria_id', pruebas.id('CAT_ALQ'),
    'frecuencia', 'mensual', 'dia', 1)), 'YA_EXISTE', 'nombre repetido');
  -- Alquiler: el próximo sin pagar es el de hace dos meses (vencido).
  SELECT * INTO x FROM public.pagos_fijos_proximos(e) WHERE pago_fijo_id = alq;
  PERFORM pruebas.afirmar(x.proximo_vence_el = m2 AND x.estado = 'vencido'
    AND x.vencidos = 2 + (CASE WHEN m0 < hoy THEN 1 ELSE 0 END), 'alquiler vencido: ' || row_to_json(x)::text);
  SELECT * INTO x FROM public.pagos_fijos_proximos(e) WHERE pago_fijo_id = vig;
  PERFORM pruebas.afirmar(x.dias BETWEEN 1 AND 7 AND extract(isodow FROM x.proximo_vence_el) = 5 AND x.estado = 'proximo'
    AND x.monto_mensual_estimado_centavos = 216667, 'vigilancia próxima (100,000 x 52 / 12 / 2 = 216,667)');

  -- 7) Pagar el alquiler: nunca solo; con el monto REAL (520,000). El dueño lo registra (sin tope).
  --    Cubre el vencimiento más antiguo (m2). BAC 750,000 - 520,000 = 230,000.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_pago_fijo(%L, %L, gen_random_uuid())', alq, '{}'), 'monto REAL', 'sin monto');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_pago_fijo(%L, %L, gen_random_uuid())', alq, '{"monto_centavos": 520000, "otra": 1}'),
    'no se reconoce', 'clave desconocida');
  r := public.registrar_pago_fijo(alq, '{"monto_centavos": 520000}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicado' AND (r->>'vence_el')::date = m2 AND pruebas.dinero('BANCO') = 230000, 'alquiler pagado: ' || r::text);
  PERFORM pruebas.afirmar((SELECT descripcion || '|' || monto_centavos || '|' || categoria_id::text FROM public.gasto WHERE id = (r->>'gasto_id')::uuid)
    = 'Alquiler del local (vence ' || to_char(m2, 'DD/MM/YYYY') || ')|520000|' || pruebas.id('CAT_ALQ'), 'gasto real del alquiler');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_pago_fijo(%L, %L, gen_random_uuid())', alq,
    jsonb_build_object('monto_centavos', 1, 'vence_el', m2)), 'YA_EXISTE', 'pagar dos veces el mismo vencimiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_pago_fijo(%L, %L, gen_random_uuid())', alq,
    jsonb_build_object('monto_centavos', 1, 'vence_el', m2 + 1)), 'no es un vencimiento', 'fecha que no es vencimiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_pago_fijo(%L, %L, gen_random_uuid())', seg, '{"monto_centavos": 1}'),
    'cuenta de dinero', 'seguro sin cuenta');
  -- El admin registra el de m1 por 520,000 (> su tope 500,000): queda pendiente, pero ese vencimiento ya está tomado.
  PERFORM pruebas.como('admin_a');
  r := public.registrar_pago_fijo(alq, '{"monto_centavos": 520000}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'pendiente_aprobacion' AND (r->>'vence_el')::date = m1 AND pruebas.dinero('BANCO') = 230000, 'm1 pendiente');
  SELECT * INTO x FROM public.pagos_fijos_proximos(e) WHERE pago_fijo_id = alq;
  PERFORM pruebas.afirmar(x.proximo_vence_el = m0, 'el próximo del alquiler es el de este mes');

  -- 8) Total mensual: 500,000 + 216,667 + 300,000 / 3 = 816,667 estimado; pagado este mes 520,000.
  r := public.reporte_pagos_fijos(e, extract(year FROM hoy)::int, extract(month FROM hoy)::int);
  PERFORM pruebas.afirmar((r->>'estimado_mensual_total_centavos')::bigint = 816667 AND (r->>'pagado_mes_total_centavos')::bigint = 520000,
    'reporte: ' || (r - 'pagos_fijos')::text);
  -- Desactivar la vigilancia: sale de próximos y del total (600,000); no se paga.
  PERFORM public.editar_pago_fijo(e, vig, '{"activo": false}', 'Se canceló el servicio');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.pagos_fijos_proximos(e) WHERE pago_fijo_id = vig), 'vigilancia fuera');
  PERFORM pruebas.afirmar((public.reporte_pagos_fijos(e, extract(year FROM hoy)::int, extract(month FROM hoy)::int)->>'estimado_mensual_total_centavos')::bigint = 600000,
    'total sin vigilancia');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_pago_fijo(%L, %L, gen_random_uuid())', vig, '{"monto_centavos": 1, "cuenta_dinero_id": "' || pruebas.id('BANCO') || '"}'),
    'desactivado', 'pagar uno desactivado');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.pagos_fijos_proximos(%L)', e), 'SIN_PERMISO', 'vendedor ve pagos fijos');

  -- Rastro = libros y bitácora.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)), 'rastro = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
