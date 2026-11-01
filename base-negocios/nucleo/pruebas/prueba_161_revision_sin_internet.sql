-- PRUEBA: (0.20.0, revisión) vender sin internet: el tope es del TURNO (todos los usuarios y bloques); "con internet" que
-- llega tarde se revisa como sin internet; una venta con internet por la cola no deja existencia negativa; una foto del
-- catálogo que no se entregó a ESE equipo no vale; los números los devuelve solo quien los reservó, el cajero del turno o
-- el dueño; el bloque se renueva cuando quedan pocos (sin huecos) y el nuevo empieza donde quedó el equipo; una venta con
-- datos dañados gasta su número y queda "por resolver"; "ya estaba" no muestra ventas de otro usuario; resolver con el
-- turno abierto mete el efectivo en ese turno y la deuda de una transferencia que no llegó es de quien hizo la venta.
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
  e      uuid := pruebas.empresa('A');
  eq     uuid;
  eq2    uuid;
  bf     jsonb;
  b2     jsonb;
  d      bigint;
  v1     integer;
  v2     integer;
  r      jsonb;
  x      jsonb;
  id_adm uuid := gen_random_uuid();
  vsi5   uuid;
  vp     uuid;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.sin_internet', true, 'El cajero vende sin internet');
  -- Tope por turno pequeño (L 50.00) para probarlo.
  PERFORM public.configurar_empresa(e, '{"sin_internet_tope_turno_centavos": 5000}', 'Prueba: tope por turno de L 50');

  PERFORM pruebas.como('cajero_a');
  PERFORM public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid());
  eq := (public.registrar_equipo(e, '{"nombre": "Caja 1"}', gen_random_uuid())->>'equipo_id')::uuid;
  bf := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), '{"tamano": 10}')->'bloques'->0;
  d := (bf->>'desde')::bigint;
  v1 := (public.preparar_sin_internet(e, eq)->>'version')::int;
  -- Como si el bloque se hubiera reservado hace 2 horas (para poder mandar ventas con hora de antes).
  PERFORM pruebas.como('superusuario');
  PERFORM set_config('session_replication_role', 'replica', true);
  UPDATE public.numero_bloque SET reservado_en = now() - interval '2 hours' WHERE id = (bf->>'bloque_id')::uuid;
  UPDATE public.catalogo_entrega SET entregado_en = now() - interval '2 hours' WHERE equipo_id = eq;
  PERFORM set_config('session_replication_role', 'origin', true);
  -- Otro equipo (de otra caja) recibe una foto con el tornillo a L 16.00; después el precio sube a L 17.00.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 1600, 'Subió el tornillo');
  PERFORM pruebas.como('admin_a');
  eq2 := (public.registrar_equipo(e, '{"nombre": "Otro equipo"}', gen_random_uuid())->>'equipo_id')::uuid;
  v2 := (public.preparar_sin_internet(e, eq2, jsonb_build_object('caja_id', pruebas.id('CAJA001')))->>'version')::int;
  PERFORM pruebas.afirmar(v2 > v1, 'foto nueva');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 1700, 'Subió otra vez');

  -- 1) Tope del TURNO: el cajero vende L 30.00 y el admin, en el mismo bloque y turno, otros L 30.00: pasa el tope (L 50).
  PERFORM pruebas.como('cajero_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, d, v1, jsonb_build_array(pruebas.linea('P1', 2, 1500, 3000)), 3000, NULL, now() - interval '90 minutes')));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'registrada', 'venta del cajero: ' || r::text);
  PERFORM pruebas.como('admin_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, d + 1, v1, jsonb_build_array(pruebas.linea('P1', 2, 1500, 3000)), 3000, NULL, now() - interval '80 minutes', 'admin_a', false, id_adm)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'problema' = 'tope_turno', 'tope del turno con otro usuario: ' || r::text);

  -- (El tope vuelve a L 50,000 para lo que sigue.)
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"sin_internet_tope_turno_centavos": 5000000}', 'Prueba: tope normal');
  -- 2) "Con internet" que llega una hora tarde se revisa como sin internet (tarjeta no).
  PERFORM pruebas.como('cajero_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, d + 2, v1, jsonb_build_array(pruebas.linea('P1', 1, 1700, 1700)), 1700,
                '[{"forma":"tarjeta","monto_centavos":1700}]', now() - interval '1 hour', 'cajero_a', true)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'problema' = 'tarjeta', 'en_linea tarde = sin internet: ' || r::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT (SELECT en_linea FROM public.venta_sin_internet WHERE numero = d + 2 AND bloque_id = (bf->>'bloque_id')::uuid), 'guardada como sin internet');

  -- 3) Con internet (de verdad) por la cola: 12 galones de pintura (hay 10) NO deja existencia negativa.
  PERFORM pruebas.como('cajero_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, d + 3, v1, jsonb_build_array(pruebas.linea('P3', 12, 45000, 540000)), 540000, NULL, now(), 'cajero_a', true)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'por_resolver', 'con internet no queda en negativo: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P3') = 10, 'existencia intacta');

  -- 4) Foto que no se le entregó a ESTE equipo (la del otro equipo, a L 16.00; hoy L 17.00): no vale -> por resolver.
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, d + 4, v2, jsonb_build_array(pruebas.linea('P1', 1, 1600, 1600)), 1600,
                '[{"forma":"transferencia","monto_centavos":1600,"referencia":"TRF-777"}]')));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'problema' = 'foto', 'foto de otro equipo: ' || r::text);
  PERFORM pruebas.como('superusuario');
  vsi5 := (SELECT id FROM public.venta_sin_internet WHERE numero = d + 4 AND bloque_id = (bf->>'bloque_id')::uuid);

  -- 5) Datos dañados (las líneas no son una lista): gasta su número y queda por resolver ("datos").
  PERFORM pruebas.como('cajero_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, d + 5, v1, '"no es una lista"'::jsonb, 1500)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'por_resolver' AND r->'resultados'->0->>'problema' = 'datos', 'datos dañados: ' || r::text);

  -- 6) "Ya estaba" de otro usuario: no responde nada de esa venta.
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, d + 1, v1, jsonb_build_array(pruebas.linea('P1', 2, 1500, 3000)), 3000, NULL, now(), 'admin_a', false, id_adm)));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'rechazada' AND r->'resultados'->0->>'clave' = 'SIN_PERMISO'
    AND NOT (r->'resultados'->0 ? 'numero_documento'), 'ya estaba ajena: ' || r::text);

  -- 7) Devolver los números: el admin (ni reservó ni es el cajero del turno ni puede subir ajenas) no puede.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.devolver_bloque(%L, %L, %L, %s, gen_random_uuid())', e, eq, bf->>'bloque_id', d + 6),
    'SIN_PERMISO', 'otro usuario devuelve los números');

  -- 8) Renovar el bloque (quedan pocos): con un hueco no; sin huecos sí, y el nuevo empieza en el siguiente del equipo.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reservar_bloque_numeros(%L, %L, gen_random_uuid(), %L)', e, eq,
    jsonb_build_object('tamano', 10, 'siguientes', jsonb_build_object(bf->>'bloque_id', d + 8))), 'FALTAN_VENTAS_POR_SUBIR', 'renovar con un hueco');
  -- Con 7 libres de 10 (más de una quinta parte y más de 5): todavía no se renueva (el mismo bloque).
  PERFORM pruebas.afirmar(public.reservar_bloque_numeros(e, eq, gen_random_uuid(),
    jsonb_build_object('tamano', 10, 'siguientes', jsonb_build_object(bf->>'bloque_id', d + 3)))->'bloques'->0->>'bloque_id' = bf->>'bloque_id',
    'con muchos libres no se renueva');
  b2 := public.reservar_bloque_numeros(e, eq, gen_random_uuid(),
    jsonb_build_object('tamano', 10, 'siguientes', jsonb_build_object(bf->>'bloque_id', d + 6)))->'bloques'->0;
  PERFORM pruebas.afirmar(b2->>'bloque_id' <> bf->>'bloque_id' AND (b2->>'desde')::bigint = d + 6, 'bloque nuevo desde ' || (d + 6) || ': ' || b2::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado || '/' || devuelto_desde FROM public.numero_bloque WHERE id = (bf->>'bloque_id')::uuid) = 'devuelto/' || (d + 6),
    'el viejo quedó devuelto desde ' || (d + 6));
  PERFORM pruebas.afirmar((SELECT ultimo_numero FROM public.cai_rango WHERE id = pruebas.id('CAI1')) = d + 15, 'el rango llega al final del bloque nuevo');

  -- 9) Resolver con el turno abierto: el efectivo entra a ese turno (a la caja del cajero). La venta del admin (tope) la
  --    registra el dueño; el admin no tiene turno, pero el dinero está en la caja del turno abierto.
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_venta_sin_internet((SELECT id FROM public.venta_sin_internet WHERE id_operacion = id_adm), 'registrar',
         'Se pasó el tope, pero la venta es buena', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'resuelta' AND NOT (r->>'a_mi_turno')::boolean, 'resuelta en el turno abierto: ' || r::text);
  PERFORM pruebas.afirmar((SELECT p.turno_id FROM public.venta_pago p WHERE p.venta_id = (r->>'venta_id')::uuid)
    = (SELECT id FROM public.turno_caja WHERE empresa_id = e AND estado = 'abierto' AND caja_id = pruebas.id('CAJA001')), 'el efectivo entró al turno abierto');
  PERFORM pruebas.afirmar((SELECT vendedor_id FROM public.venta WHERE id = (r->>'venta_id')::uuid) = pruebas.usuario('admin_a'), 'el vendedor sigue siendo el admin');

  -- 10) La transferencia de la venta 4 (por foto), registrada por el dueño "a su turno"; si no llega, la debe el cajero.
  r := public.resolver_venta_sin_internet(vsi5, 'registrar', 'El cliente pagó el precio de antes', gen_random_uuid(), '{"a_mi_turno": true}');
  PERFORM pruebas.afirmar(r->>'estado' = 'resuelta', 'transferencia resuelta: ' || r::text);
  vp := (SELECT id FROM public.venta_pago WHERE venta_id = (r->>'venta_id')::uuid AND forma = 'transferencia');
  r := public.marcar_transferencia_no_llego(vp, 'No apareció en el banco', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'deuda_de' = 'cajero' AND (r->>'deudor_id')::uuid = pruebas.usuario('cajero_a'), 'la debe el cajero, no el dueño: ' || r::text);

  -- Todo cuadra.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento_linea x JOIN public.asiento s ON s.id = x.asiento_id WHERE s.empresa_id = e
                                      GROUP BY x.asiento_id HAVING sum(x.debe_centavos) <> sum(x.haber_centavos)), 'cada asiento cuadra');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
