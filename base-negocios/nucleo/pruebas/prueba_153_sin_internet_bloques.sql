-- PRUEBA: (0.20.0) vender sin internet, bloques (G3, G4, M5): una venta que falta en medio deja un hueco y devolver el bloque da FALTAN_VENTAS_POR_SUBIR; solo el MISMO equipo devuelve; el turno no se cierra con el bloque activo (BLOQUE_SIN_DEVOLVER); devuelto, la numeración en línea usa primero los números devueltos (correlativa: 6, 7) y un bloque nuevo sigue desde ahí; resolver por resolver (registrar con motivo y permiso, anular deja el número ANULADO); equipo desactivado: su bloque queda por conciliar (no se anula), sus ventas se revisan y se concilia (los no usados, uno por uno); mes cerrado (M5): por resolver, el dueño reabre y se registra con su fecha real; tickets cuando la empresa da factura o ticket; un equipo sin noticias 48 h: el turno cierra y el bloque pasa a por conciliar con alerta; cifras a mano, libros y bitácora
CREATE FUNCTION pruebas.vsi(p_bloque jsonb, p_numero bigint, p_foto integer, p_lineas jsonb, p_total bigint,
                            p_pagos jsonb DEFAULT NULL, p_hora timestamptz DEFAULT now(), p_usuario text DEFAULT 'cajero_a',
                            p_en_linea boolean DEFAULT false, p_id uuid DEFAULT gen_random_uuid()) RETURNS jsonb
LANGUAGE sql VOLATILE AS $$
  SELECT jsonb_build_object('id_operacion', p_id, 'usuario_id', pruebas.usuario(p_usuario),
    'caja_id', p_bloque->'caja_id', 'bloque_id', p_bloque->'bloque_id', 'numero', p_numero,
    'numero_documento', (p_bloque->>'prefijo') || '-' || lpad(p_numero::text, 8, '0'),
    'tipo_documento', p_bloque->'tipo', 'foto_version', p_foto, 'hora_equipo', public.iso(p_hora),
    'lineas', p_lineas, 'pagos', coalesce(p_pagos, jsonb_build_array(jsonb_build_object('forma', 'efectivo', 'monto_centavos', p_total))),
    'total_centavos', p_total, 'en_linea', p_en_linea)
$$;
CREATE FUNCTION pruebas.linea(p_prod text, p_cant numeric, p_precio bigint, p_total bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('producto_id', pruebas.id(p_prod), 'cantidad', p_cant, 'precio_tipo', 'normal',
                            'precio_unitario_centavos', p_precio, 'total_centavos', p_total)
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pruebas TO authenticated;

DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  eq   uuid;
  eq2  uuid;
  b    jsonb;
  bf   jsonb;
  v1   integer;
  r    jsonb;
  x    jsonb;
  t    uuid;
  z    uuid;
  z2   uuid;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.sin_internet', true, 'El cajero vende sin internet');
  PERFORM pruebas.como('cajero_a');
  t := (public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid())->>'turno_id')::uuid;
  eq := (public.registrar_equipo(e, '{"nombre": "Caja 1"}', gen_random_uuid())->>'equipo_id')::uuid;
  eq2 := (public.registrar_equipo(e, '{"nombre": "Celular"}', gen_random_uuid())->>'equipo_id')::uuid;
  bf := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), '{"tamano": 10}')->'bloques'->0;
  PERFORM pruebas.afirmar((bf->>'desde')::int = 1 AND (bf->>'hasta')::int = 10, 'bloque 1 a 10');
  v1 := (public.preparar_sin_internet(e, eq)->>'version')::int;

  -- 1) Subir 1, 2 (precio manipulado), 3 y 5 (el 4 sigue en el equipo).
  x := jsonb_build_array(
    pruebas.vsi(bf, 1, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500),
    pruebas.vsi(bf, 2, v1, jsonb_build_array(pruebas.linea('P1', 1, 1000, 1000)), 1000),
    pruebas.vsi(bf, 3, v1, jsonb_build_array(pruebas.linea('P1', 2, 1500, 3000)), 3000),
    pruebas.vsi(bf, 5, v1, jsonb_build_array(pruebas.linea('P2', 2.5, 2200, 5500)), 5500));
  r := public.subir_ventas_sin_internet(e, eq, x);
  PERFORM pruebas.afirmar((r->>'registradas')::int = 3 AND (r->>'por_resolver')::int = 1, 'tanda: ' || r::text);
  -- Devolver: falta el 4; otro equipo no devuelve; el turno no cierra.
  PERFORM pruebas.debe_fallar(format('SELECT public.devolver_bloque(%L, %L, %L, 6, gen_random_uuid())', e, eq, bf->>'bloque_id'),
    'FALTAN_VENTAS_POR_SUBIR: faltan 1', 'falta el 4');
  PERFORM pruebas.debe_fallar(format('SELECT public.devolver_bloque(%L, %L, %L, 6, gen_random_uuid())', e, eq2, bf->>'bloque_id'),
    'BLOQUE_INVALIDO', 'otro equipo no devuelve (G4)');
  PERFORM pruebas.debe_fallar(format('SELECT public.devolver_bloque(%L, %L, %L, 4, gen_random_uuid())', e, eq, bf->>'bloque_id'),
    'BLOQUE_INVALIDO', 'el equipo no puede decir menos de lo que el servidor ya recibió');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_turno(%L, 0, gen_random_uuid())', t), 'BLOQUE_SIN_DEVOLVER', 'turno con bloque');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, 4, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'registrada', 'el 4 llena el hueco: ' || r::text);
  r := public.devolver_bloque(e, eq, (bf->>'bloque_id')::uuid, 6, gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'devuelto' AND (r->>'sin_usar')::int = 5, 'devuelto, 5 sin usar: ' || r::text);

  -- 2) G4: en línea se usan primero los devueltos (6, 7); el bloque nuevo sigue en el 8.
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'numero_documento' = '001-001-01-00000006', 'en línea: el 6: ' || r::text);
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'numero_documento' = '001-001-01-00000007', 'en línea: el 7: ' || r::text);
  bf := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), '{"tamano": 10}')->'bloques'->0;
  PERFORM pruebas.afirmar((bf->>'desde')::int = 8 AND (bf->>'hasta')::int = 17, 'bloque nuevo 8 a 17: ' || bf::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT ultimo_numero FROM public.cai_rango WHERE id = pruebas.id('CAI1')) = 17, 'rango en 17');
  -- Ningún número se repite en el rango: 1..7 emitidos una sola vez (las facturas del libro).
  PERFORM pruebas.afirmar((SELECT string_agg(right(numero_documento, 2), ',' ORDER BY numero_documento) FROM public.venta
                            WHERE empresa_id = e AND numero_documento IS NOT NULL) = '01,03,04,05,06,07', 'facturas en los libros (el 2 está por resolver)');

  -- 3) Resolver el 2 (precio manipulado): sin permiso no; sin motivo no; con motivo: se registra con lo que cobró el equipo.
  SELECT id INTO z FROM public.venta_sin_internet WHERE empresa_id = e AND numero = 2;
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_venta_sin_internet(%L, %L, %L, gen_random_uuid())', z, 'registrar', 'Precio de oferta'),
    'SIN_PERMISO', 'el cajero no resuelve');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(jsonb_array_length(public.ventas_sin_internet_por_resolver(e)->'ventas') = 1, 'una por resolver');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_venta_sin_internet(%L, %L, %L, gen_random_uuid())', z, 'registrar', 'no'),
    'FALTA_MOTIVO', 'sin motivo');
  r := public.resolver_venta_sin_internet(z, 'registrar', 'El tornillo estaba en oferta de L 10.00 ese día', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'resuelta' AND r->>'numero_documento' = '001-001-01-00000002', 'resuelta: ' || r::text);
  PERFORM pruebas.afirmar((SELECT total_centavos FROM public.venta WHERE id = (r->>'venta_id')::uuid) = 1000, 'con lo que cobró: 1,000');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_venta_sin_internet(%L, %L, %L, gen_random_uuid())', z, 'anular', 'Otra vez'),
    'NO_PERMITIDO', 'una sola vez');

  -- 4) G3: el equipo se pierde. Desactivar: el bloque 8..17 queda por conciliar (ningún número se anula).
  r := public.desactivar_equipo(e, eq, 'Se perdió el equipo de la caja 1');
  PERFORM pruebas.afirmar((r->>'bloques_por_conciliar')::int = 1, 'por conciliar: ' || r::text);
  PERFORM pruebas.afirmar((SELECT estado FROM public.numero_bloque WHERE id = (bf->>'bloque_id')::uuid) = 'por_conciliar', 'bloque por conciliar');
  PERFORM pruebas.debe_fallar(format('SELECT public.preparar_sin_internet(%L, %L)', e, eq), 'EQUIPO_INVALIDO', 'equipo desactivado');
  -- Se registra desde la copia en papel la factura 8 (L 15.00): por resolver y el dueño la registra.
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, 8, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, NULL, now(), 'cajero_a')),
    'Copia en papel de la factura 8');
  PERFORM pruebas.afirmar(r->'resultados'->0->>'problema' = 'equipo_desactivado', 'equipo desactivado: ' || r::text);
  z2 := (SELECT id FROM public.venta_sin_internet WHERE empresa_id = e AND numero = 8);
  r := public.resolver_venta_sin_internet(z2, 'registrar', 'Revisada contra la copia en papel', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'resuelta', 'factura 8 registrada: ' || r::text);
  r := public.conciliar_bloque(e, (bf->>'bloque_id')::uuid, 'Copias en papel revisadas: solo se usó la 8', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'conciliado' AND (r->>'no_usados')::int = 9
    AND r->'no_usados_lista'->>0 = '001-001-01-00000009', 'conciliado, 9 no usados: ' || r::text);
  -- Ya sin bloque activo: el turno cierra (contado = lo que hay en la caja).
  PERFORM pruebas.como('cajero_a');
  r := public.cerrar_turno(t, pruebas.dinero('CAJA1'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'cerrado' AND (r->>'diferencia_centavos')::bigint = 0, 'turno cerrado: ' || r::text);
  -- 1,500 + 3,000 + 5,500 + 1,500 (sin internet) + 1,500 x 2 (en línea) + 1,000 (resuelta) + 1,500 (la 8) = 17,000
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 17000, 'caja 17,000: ' || pruebas.dinero('CAJA1'));
END $$;

-- 5) M5: mes cerrado, en otra transacción. Un equipo nuevo, un turno nuevo; enero a este mes se cierran (en orden) y la
--    venta queda por resolver; el dueño reabre el mes y se registra con su fecha real (nunca con otra fecha).
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  eq   uuid;
  bf   jsonb;
  v1   integer;
  r    jsonb;
  z    uuid;
  m    integer;
  hoy  date := public.hoy_local(pruebas.empresa('A'));
BEGIN
  PERFORM pruebas.como('cajero_a');
  PERFORM public.abrir_turno(e, pruebas.id('CAJA001'), pruebas.dinero('CAJA1'), gen_random_uuid());
  eq := (public.registrar_equipo(e, '{"nombre": "Caja 1 nueva"}', gen_random_uuid())->>'equipo_id')::uuid;
  bf := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), '{"tamano": 10}')->'bloques'->0;
  PERFORM pruebas.afirmar((bf->>'desde')::int = 18, 'después del bloque conciliado: 18');
  v1 := (public.preparar_sin_internet(e, eq)->>'version')::int;
  PERFORM pruebas.como('superusuario');
  FOR m IN 1 .. extract(month FROM hoy)::int LOOP
    INSERT INTO public.periodo (empresa_id, anio, mes, estado) VALUES (e, extract(year FROM hoy)::int, m, 'cerrado')
    ON CONFLICT (empresa_id, anio, mes) DO UPDATE SET estado = 'cerrado';
  END LOOP;
  PERFORM pruebas.como('cajero_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, 18, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'problema' = 'mes_cerrado', 'mes cerrado: ' || r::text);
  z := (SELECT id FROM public.venta_sin_internet WHERE empresa_id = e AND numero = 18);
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_venta_sin_internet(%L, %L, %L, gen_random_uuid())', z, 'registrar', 'Con el mes cerrado'),
    'PERIODO_CERRADO', 'sin reabrir no se registra');
  PERFORM pruebas.como('superusuario');
  UPDATE public.periodo SET estado = 'abierto' WHERE empresa_id = e AND anio = extract(year FROM hoy)::int AND mes = extract(month FROM hoy)::int;
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_venta_sin_internet(z, 'registrar', 'Reabrí el mes; el contador lo confirmó', gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT fecha_contable FROM public.venta WHERE id = (r->>'venta_id')::uuid) = hoy, 'con su fecha real');
  PERFORM pruebas.guardar('EQ3', eq);
END $$;

-- 6) Factura o ticket: el mismo equipo recibe además un bloque de tickets; la venta sin internet con ticket.
--    Después, 48 horas sin noticias: el turno cierra y el bloque pasa a por conciliar, con alerta para el dueño.
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  eq   uuid := pruebas.id('EQ3');
  b    jsonb;
  bt   jsonb;
  v1   integer;
  r    jsonb;
  t    uuid;
  a    jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"documento_venta_modo": "factura_o_ticket"}', 'Ahora también tickets');
  PERFORM pruebas.como('cajero_a');
  b := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), '{"tamano": 20}');
  PERFORM pruebas.afirmar(jsonb_array_length(b->'bloques') = 2, 'factura y ticket: ' || b::text);
  SELECT y INTO bt FROM jsonb_array_elements(b->'bloques') y WHERE y->>'tipo' = 'ticket';
  PERFORM pruebas.afirmar(bt->>'desde_texto' = 'T-001-001-00000001' AND (bt->>'hasta')::int = 20, 'tickets 1 a 20: ' || bt::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1, 'efectivo') || '{"tipo_documento": "ticket"}'), 'BLOQUE_ACTIVO', 'ticket en línea con bloque');
  v1 := (public.preparar_sin_internet(e, eq)->>'version')::int;
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bt, 1, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'registrada' AND r->'resultados'->0->>'numero_documento' = 'T-001-001-00000001',
    'ticket sin internet: ' || r::text);
  -- 48 horas sin noticias del equipo.
  PERFORM pruebas.como('superusuario');
  UPDATE interno.equipo_sync SET ultima_en = now() - interval '49 hours' WHERE equipo_id = eq;
  t := (SELECT id FROM public.turno_caja WHERE empresa_id = e AND estado = 'abierto');
  PERFORM pruebas.como('dueno_a');
  a := public.alertas_activas(e);
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(a->'alertas') y WHERE y->>'titulo' = 'Equipo sin noticias'), 'alerta sin noticias: ' || a::text);
  PERFORM pruebas.como('cajero_a');
  r := public.cerrar_turno(t, pruebas.dinero('CAJA1'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'cerrado', 'cierra con el equipo sin noticias');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.numero_bloque WHERE equipo_id = eq AND estado = 'por_conciliar') = 2, 'dos bloques por conciliar');
  a := public.alertas_activas(e);
  PERFORM pruebas.afirmar((SELECT count(*) FROM jsonb_array_elements(a->'alertas') y WHERE y->>'titulo' = 'Números por conciliar') = 2,
    'alertas por conciliar: ' || a::text);
  PERFORM pruebas.afirmar((SELECT count(*) FROM jsonb_array_elements(public.bloques_sin_internet(e)->'bloques')) >= 4, 'lectura de bloques');
  -- Libros y bitácora.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento_linea l JOIN public.asiento s ON s.id = l.asiento_id WHERE s.empresa_id = e
                                      GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)), 'cada asiento cuadra');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = pruebas.dinero_libros('CAJA1'), 'caja = libros');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
