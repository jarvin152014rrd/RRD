-- PRUEBA: lecturas de ventas (cifras a mano): ventas por día, por vendedor y por caja; CxC por factura y por cliente con antigüedad 0-30 / 31-60 / 61-90 / +90, vencido y crédito disponible; "seguir una venta" (venta -> forma de pago -> cuenta de dinero -> depósito); cada quien ve lo suyo y el contador todo (solo lectura)
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  hoy  date := public.hoy_local(pruebas.empresa('A'));
  va   jsonb;
  s    jsonb;
  cont uuid;
  x    record;
BEGIN
  PERFORM pruebas.preparar_ventas(false);       -- tickets: se pueden registrar con fechas pasadas
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');

  -- 1) Créditos de CLI1 (límite L 5,000.00, plazo 30) en fechas pasadas: hace 100, 70, 40 y 10 días.
  PERFORM pruebas.como('cajero_a');
  PERFORM public.registrar_venta(e, pruebas.venta('P3', 2, 'credito', 'CLI1') || jsonb_build_object('fecha', hoy - 100), gen_random_uuid()); -- 90,000
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 10, 'credito', 'CLI1') || jsonb_build_object('fecha', hoy - 70), gen_random_uuid()); -- 15,000
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1') || jsonb_build_object('fecha', hoy - 40), gen_random_uuid());  -- 1,500
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 2, 'credito', 'CLI1') || jsonb_build_object('fecha', hoy - 10), gen_random_uuid());  -- 3,000

  -- 2) Ventas de hoy: cajero efectivo 1,500; admin tarjeta 3,000; vendedor crédito 1,500.
  va := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 2, 'tarjeta'), gen_random_uuid());
  PERFORM pruebas.como('vendedor_a');
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = 1 AND (SELECT costo_centavos FROM public.v_venta) IS NULL,
    'el vendedor ve solo su venta y sin costo');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.v_ventas_por_dia) AND NOT EXISTS (SELECT 1 FROM public.v_cxc_documento),
    'sin ventas.ver no ve reportes ni CxC');
  PERFORM pruebas.debe_fallar(format('SELECT public.seguir_venta(%L)', va->>'venta_id'), 'SIN_PERMISO', 'vendedor no sigue ventas');

  -- 3) Reportes del día (dueño).
  PERFORM pruebas.como('dueno_a');
  SELECT * INTO x FROM public.v_ventas_por_dia WHERE empresa_id = e AND fecha = hoy;
  PERFORM pruebas.afirmar(x.ventas = 3 AND x.total_centavos = 6000 AND x.contado_centavos = 4500 AND x.credito_centavos = 1500
    AND x.impuesto_centavos = 196 + 391 + 196, 'por día: ' || row_to_json(x)::text);
  PERFORM pruebas.afirmar((SELECT string_agg(vendedor || '=' || total_centavos, ',' ORDER BY vendedor) FROM public.v_ventas_por_vendedor
                             WHERE empresa_id = e AND fecha = hoy) = 'admin_a@prueba.hn=3000,cajero_a@prueba.hn=1500,vendedor_a@prueba.hn=1500', 'por vendedor');
  SELECT * INTO x FROM public.v_ventas_por_caja WHERE empresa_id = e AND fecha = hoy;
  PERFORM pruebas.afirmar(x.efectivo_centavos = 1500 AND x.tarjeta_centavos = 3000 AND x.credito_centavos = 1500 AND x.ventas = 3, 'por caja');

  -- 4) CxC por cliente con antigüedad (desde la fecha de la factura; vence a los 30 días).
  SELECT * INTO x FROM public.v_cxc_cliente WHERE cliente_id = pruebas.id('CLI1');
  PERFORM pruebas.afirmar(x.saldo_centavos = 111000 AND x.mas_de_90 = 90000 AND x.de_61_a_90 = 15000 AND x.de_31_a_60 = 1500
    AND x.de_0_a_30 = 4500 AND x.vencido_centavos = 106500 AND x.credito_disponible_centavos = 389000 AND x.documentos = 5,
    'antigüedad: ' || row_to_json(x)::text);
  PERFORM pruebas.afirmar((SELECT sum(saldo_centavos) FROM public.v_cxc_documento WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.02.01'),
    'CxC = saldo de Clientes');
  PERFORM pruebas.afirmar((SELECT dias_vencido FROM public.v_cxc_documento WHERE fecha_documento = hoy - 100) = 70, 'vencida hace 70 días');

  -- 5) Seguir la venta en efectivo hasta el depósito.
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('CAJA1'), 'destino_id', pruebas.id('BANCO'),
    'monto_centavos', 1500, 'referencia', 'Boleta 777'), gen_random_uuid());
  s := public.seguir_venta((va->>'venta_id')::uuid);
  PERFORM pruebas.afirmar(s->'pagos'->0->>'forma' = 'efectivo' AND s->'pagos'->0->'cuenta'->>'nombre' = 'Caja 1'
    AND (s->'pagos'->0->'movimientos'->0->>'monto_centavos')::bigint = 1500
    AND s->'pagos'->0->'depositos_de_esa_caja_desde_la_venta'->0->>'estado' = 'en_transito'
    AND s->'pagos'->0->'depositos_de_esa_caja_desde_la_venta'->0->>'banco' = 'BAC cheques', 'seguir: ' || s::text);

  -- 6) Contador: lee todo, no vende.
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (email) VALUES ('contador@prueba.hn') RETURNING id INTO cont;
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('contador', cont);
  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol) VALUES (cont, e, 'contador');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = 7 AND (SELECT count(*) FROM public.venta) = 7, 'contador ve las 7 ventas');
  PERFORM pruebas.afirmar((public.seguir_venta((va->>'venta_id')::uuid)->>'detalle_dinero_visible')::boolean, 'contador sigue la venta');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)),
    'SIN_PERMISO', 'contador no vende');
END $$;
