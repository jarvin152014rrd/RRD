-- PRUEBA: (0.20.0) vender sin internet, subir (pagos: efectivo y transferencia con referencia; tarjeta solo con internet): registrar el equipo; reservar un bloque de facturas CAI por caja y equipo (ultimo_numero del rango salta al final del bloque SOLO con la marca; la caja ya no numera en línea: BLOQUE_ACTIVO; otro equipo no reserva esa caja); la foto versionada del catálogo (G5: "sin cambios" con la misma versión, versión nueva al cambiar un precio); subir: precio de la foto, precio de hoy y precio manipulado (por resolver, el número igual se gasta), la misma venta dos veces y una que entró por registrar_venta (G2: "ya estaba"), número repetido o fuera del bloque (grave), reloj adelantado, tarjeta sin internet (no), transferencia sin internet (por confirmar; sin referencia: por resolver; referencia repetida: aviso), crédito sin internet (no), tope por venta, existencia negativa (se registra y avisa), fuera del horario (M7) y las ventas de un usuario desactivado (antes: se registran, subidas por el dueño con motivo; después: por resolver); cifras a mano y libros que cuadran
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
  e     uuid := pruebas.empresa('A');
  q     jsonb;
  q2    jsonb;
  eq    uuid;
  b     jsonb;
  bf    jsonb;
  p     jsonb;
  r     jsonb;
  x     jsonb;
  v     public.venta;
  v_g   uuid := gen_random_uuid();
  v_id  uuid := gen_random_uuid();
  v1    integer;
  v2    integer;
  n     bigint;
  caja0 bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  -- El dueño da el permiso nuevo al cajero (por defecto: dueño y admin).
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.rol_permiso WHERE empresa_id = e AND rol = 'cajero' AND permiso = 'ventas.sin_internet'),
    'el cajero no vende sin internet por defecto');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.sin_internet', true, 'El cajero vende sin internet');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.rol_permiso WHERE empresa_id = e AND permiso = 'ventas.subir_ajenas') = 1,
    'subir ajenas: solo el dueño');

  -- G2 (antes del bloque): una venta en línea con el id v_g.
  PERFORM pruebas.como('cajero_a');
  PERFORM public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid());
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'efectivo'), v_g);
  PERFORM pruebas.afirmar(r->>'numero_documento' = '001-001-01-00000001', 'venta en línea antes del bloque: ' || r::text);

  -- 1) Equipo y bloque de 50 números.
  q := public.registrar_equipo(e, '{"nombre": "Caja 1 - computadora"}', v_id);
  PERFORM pruebas.afirmar((public.registrar_equipo(e, '{"nombre": "Caja 1 - computadora"}', v_id)->>'equipo_id') = q->>'equipo_id',
    'registrar el equipo otra vez con el mismo id = el mismo equipo');
  eq := (q->>'equipo_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.preparar_sin_internet(%L, %L)', e, gen_random_uuid()), 'EQUIPO_INVALIDO', 'equipo que no existe');
  -- Tamaño sugerido: 1.5 x las ventas de un día de la caja (1 venta hoy) = 2 -> mínimo 20; aquí se piden 50.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.tamano_bloque(e, pruebas.id('CAJA001')) = 20, 'tamaño sugerido 20');
  PERFORM pruebas.como('cajero_a');
  b := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), '{"tamano": 50}');
  bf := b->'bloques'->0;
  PERFORM pruebas.afirmar(jsonb_array_length(b->'bloques') = 1 AND bf->>'tipo' = 'factura' AND (bf->>'desde')::int = 2
    AND (bf->>'hasta')::int = 51 AND bf->>'desde_texto' = '001-001-01-00000002', 'bloque 2 a 51: ' || b::text);
  -- Reservar otra vez desde el mismo equipo: el mismo bloque.
  PERFORM pruebas.afirmar(public.reservar_bloque_numeros(e, eq, gen_random_uuid())->'bloques'->0->>'bloque_id' = bf->>'bloque_id', 'mismo bloque');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT ultimo_numero FROM public.cai_rango WHERE id = pruebas.id('CAI1')) = 51, 'el rango salta al final del bloque');
  -- El candado del rango: sin la marca no salta.
  PERFORM pruebas.debe_fallar(format('UPDATE public.cai_rango SET ultimo_numero = 80 WHERE id = %L', pruebas.id('CAI1')),
    'de uno en uno', 'salto sin la marca de reserva');
  PERFORM pruebas.como('cajero_a');
  -- La caja con bloque no numera en línea; otro equipo no reserva esa caja.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1, 'efectivo')),
    'BLOQUE_ACTIVO', 'venta en línea en una caja con bloque');
  q2 := public.registrar_equipo(e, '{"nombre": "Celular del cajero"}', gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.reservar_bloque_numeros(%L, %L, gen_random_uuid())', e, q2->>'equipo_id'),
    'BLOQUE_ACTIVO', 'otro equipo en la misma caja');

  -- 2) Foto del catálogo (G5).
  p := public.preparar_sin_internet(e, eq);
  v1 := (p->>'version')::int;
  PERFORM pruebas.afirmar(p->'catalogo'->'productos'->(pruebas.id('P1')::text)->>'precio_venta_centavos' = '1500'
    AND p->'perfil'->'permisos' ? 'ventas.sin_internet' AND p->>'valido_hasta' IS NOT NULL AND (p->'reglas'->>'horas')::int = 24
    AND (p->'reglas'->>'tope_venta_centavos')::bigint = 1000000
    AND jsonb_array_length(p->'bloques') = 1, 'preparar: ' || (p - 'catalogo' - 'clientes' - 'existencias')::text);
  r := public.preparar_sin_internet(e, eq, jsonb_build_object('version', v1));
  PERFORM pruebas.afirmar((r->>'sin_cambios')::boolean AND r->'catalogo' = 'null'::jsonb, 'misma versión: sin cambios');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_precio_producto(e, pruebas.id('P1'), 1600, 'Subió el tornillo');
  PERFORM pruebas.como('cajero_a');
  v2 := (public.preparar_sin_internet(e, eq, jsonb_build_object('version', v1))->>'version')::int;
  PERFORM pruebas.afirmar(v2 = v1 + 1, 'versión nueva al cambiar un precio');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.catalogo_entrega WHERE equipo_id = eq) = 2, 'entregas a nombre del equipo');

  -- 3) Subir. Fuera del horario del cajero (M7): hoy no trabaja.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_horario_acceso(e, 'cajero', jsonb_build_object(
    ((extract(isodow FROM now() AT TIME ZONE 'America/Tegucigalpa')::int % 7) + 1)::text, '{"desde": "07:00", "hasta": "08:00"}'::jsonb), 'Prueba M7: hoy no trabaja');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.preparar_sin_internet(%L, %L)', e, eq), 'FUERA_DE_HORARIO', 'preparar sí respeta el horario');
  PERFORM pruebas.como('cajero_a');
  caja0 := pruebas.dinero('CAJA1');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    -- A: 2 tornillos al precio de la foto v1 (15.00): 3,000
    pruebas.vsi(bf, 2, v1, jsonb_build_array(pruebas.linea('P1', 2, 1500, 3000)), 3000,
                '[{"forma":"efectivo","monto_centavos":3000,"recibido_centavos":5000}]'),
    -- B: 1 tornillo al precio de hoy (16.00) con la foto v1: 1,600
    pruebas.vsi(bf, 3, v1, jsonb_build_array(pruebas.linea('P1', 1, 1600, 1600)), 1600),
    -- C: precio manipulado (12.34): por resolver; el número 4 se gasta
    pruebas.vsi(bf, 4, v1, jsonb_build_array(pruebas.linea('P1', 1, 1234, 1234)), 1234),
    -- D: número 4 otra vez: GRAVE
    pruebas.vsi(bf, 4, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500),
    -- E: número fuera del bloque: GRAVE
    pruebas.vsi(bf, 60, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500),
    -- F: reloj una hora adelantado
    pruebas.vsi(bf, 5, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, NULL, now() + interval '1 hour'),
    -- G: tarjeta sin internet: no (el POS necesita conexión)
    pruebas.vsi(bf, 6, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, '[{"forma":"tarjeta","monto_centavos":1500,"referencia":"V-1"}]'),
    -- H: tarjeta con internet (la cola de una caja con bloque): se registra
    pruebas.vsi(bf, 7, v2, jsonb_build_array(pruebas.linea('P1', 1, 1600, 1600)), 1600, '[{"forma":"tarjeta","monto_centavos":1600}]',
                now(), 'cajero_a', true),
    -- I: G2: el id de una venta que ya entró por registrar_venta
    pruebas.vsi(bf, 8, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, NULL, now(), 'cajero_a', false, v_g),
    -- J: 12 galones de pintura (hay 10): se registra y avisa. 12 x 450.00 = 540,000; pasa el tope de L 10,000? no: 5,400.00
    pruebas.vsi(bf, 8, v1, jsonb_build_array(pruebas.linea('P3', 12, 45000, 540000)), 540000)));
  x := r->'resultados';
  PERFORM pruebas.afirmar(x->0->>'estado' = 'registrada' AND x->0->>'numero_documento' = '001-001-01-00000002', 'A: ' || (x->0)::text);
  PERFORM pruebas.afirmar(x->1->>'estado' = 'registrada', 'B (precio de hoy): ' || (x->1)::text);
  PERFORM pruebas.afirmar(x->2->>'estado' = 'por_resolver' AND x->2->>'problema' = 'precio'
    AND x->2->>'problema_texto' LIKE '%L 12.34%L 15.00%L 16.00%', 'C (manipulado): ' || (x->2)::text);
  PERFORM pruebas.afirmar(x->3->>'problema' = 'numero_repetido' AND (x->3->>'grave')::boolean, 'D: ' || (x->3)::text);
  PERFORM pruebas.afirmar(x->4->>'problema' = 'numero_invalido' AND (x->4->>'grave')::boolean, 'E: ' || (x->4)::text);
  PERFORM pruebas.afirmar(x->5->>'problema' = 'reloj', 'F: ' || (x->5)::text);
  PERFORM pruebas.afirmar(x->6->>'problema' = 'tarjeta', 'G: ' || (x->6)::text);
  PERFORM pruebas.afirmar(x->7->>'estado' = 'registrada', 'H: ' || (x->7)::text);
  PERFORM pruebas.afirmar(x->8->>'estado' = 'ya_estaba' AND x->8->>'numero_documento' = '001-001-01-00000001', 'I (G2): ' || (x->8)::text);
  PERFORM pruebas.afirmar(x->9->>'estado' = 'registrada' AND (x->9->>'inventario_negativo')::boolean, 'J: ' || (x->9)::text);
  PERFORM pruebas.afirmar((r->>'registradas')::int = 4 AND (r->>'por_resolver')::int = 5 AND (r->>'ya_estaban')::int = 1, 'conteo: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P3') = -2, 'pintura en -2');

  PERFORM pruebas.como('superusuario');
  -- Cifras: la venta A en los libros (3,000 con ISV 15 % incluido: 2,609 + 391), número del equipo, nota.
  SELECT * INTO v FROM public.venta WHERE id = (x->0->>'venta_id')::uuid;
  PERFORM pruebas.afirmar(v.total_centavos = 3000 AND v.impuesto_centavos = 391 AND v.numero_documento = '001-001-01-00000002'
    AND v.nota LIKE 'Emitida sin conexión%' AND v.estado = 'emitida' AND v.creado_por = pruebas.usuario('cajero_a')
    AND v.vendedor_id = pruebas.usuario('cajero_a') AND v.equipo = 'Caja 1 - computadora', 'venta A: ' || to_jsonb(v)::text);
  PERFORM pruebas.afirmar((SELECT vuelto_centavos FROM public.venta_pago WHERE venta_id = v.id) = 2000, 'vuelto 2,000');
  -- El efectivo entró al turno del cajero: A 3,000 + B 1,600 + J 540,000 (la tarjeta va al POS).
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') - caja0 = 544600, 'caja: ' || (pruebas.dinero('CAJA1') - caja0));
  -- El bloque: siguiente 9 (8 era el último), números gastados 2..8 (D y E no gastan otro).
  PERFORM pruebas.afirmar((SELECT siguiente FROM public.numero_bloque WHERE id = (bf->>'bloque_id')::uuid) = 9, 'siguiente 9');
  PERFORM pruebas.afirmar(NOT (p->'reglas'->'formas_pago') ? 'tarjeta' AND (p->'reglas'->'formas_pago') ? 'transferencia', 'formas sin internet');
  PERFORM pruebas.afirmar((SELECT string_agg(numero || ':' || estado, ',' ORDER BY numero) FROM public.numero_emitido
                            WHERE bloque_id = (bf->>'bloque_id')::uuid)
    = '2:registrado,3:registrado,4:por_resolver,5:por_resolver,6:por_resolver,7:registrado,8:registrado', 'números emitidos');
  PERFORM pruebas.como('cajero_a');
  -- Una venta mal armada se rechaza sin guardar.
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(x->0->'id_operacion'));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'rechazada', 'una venta mal armada se rechaza sin guardar');
  -- La misma tanda otra vez: "ya estaba" (nada se duplica).
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM public.venta WHERE empresa_id = e;
  PERFORM pruebas.como('cajero_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, 2, v1, jsonb_build_array(pruebas.linea('P1', 2, 1500, 3000)), 3000, NULL, now(), 'cajero_a', false, (x->0->>'id_operacion')::uuid),
    pruebas.vsi(bf, 4, v1, jsonb_build_array(pruebas.linea('P1', 1, 1234, 1234)), 1234, NULL, now(), 'cajero_a', false, (x->2->>'id_operacion')::uuid)));
  PERFORM pruebas.afirmar((r->>'ya_estaban')::int = 2 AND r->'resultados'->1->>'estado_venta' = 'por_resolver', 'otra vez: ' || r::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta WHERE empresa_id = e) = n, 'no se duplicó ninguna venta');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.venta_sin_internet WHERE empresa_id = e) = 9, '9 guardadas (I ya estaba)');

  -- 4) Tope por venta de L 50.00 (solo el dueño) y transferencia sin internet (exige referencia; queda por confirmar).
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_horario_acceso(e, 'cajero', NULL, 'Fin de la prueba M7');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"sin_internet_tope_venta_centavos": 5000}', 'Tope más bajo'),
    'SIN_PERMISO', 'el cajero no cambia la regla');
  PERFORM pruebas.como('dueno_a');
  r := public.configurar_empresa(e, '{"sin_internet_tope_venta_centavos": 5000}', 'Tope de prueba');
  PERFORM pruebas.afirmar((r->>'sin_internet_tope_venta_centavos')::bigint = 5000, 'reglas: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"sin_internet_horas": 0}', 'Horas cero'),
    'DATO_INVALIDO', 'horas fuera de rango');
  PERFORM pruebas.como('cajero_a');
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, 9, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500,
                '[{"forma":"transferencia","monto_centavos":1500,"referencia":"TR-7781","banco":"BAC"}]'),
    pruebas.vsi(bf, 10, v1, jsonb_build_array(pruebas.linea('P1', 4, 1500, 6000)), 6000),
    pruebas.vsi(bf, 11, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, '[{"forma":"credito","monto_centavos":1500}]'),
    pruebas.vsi(bf, 14, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, '[{"forma":"transferencia","monto_centavos":1500}]'),
    pruebas.vsi(bf, 15, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, '[{"forma":"transferencia","monto_centavos":1500,"referencia":"tr-7781"}]')));
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'registrada' AND jsonb_array_length(r->'resultados'->0->'avisos') = 0,
    'transferencia: ' || (r->'resultados'->0)::text);
  PERFORM pruebas.afirmar(r->'resultados'->1->>'problema' = 'tope_venta', 'tope: ' || (r->'resultados'->1)::text);
  PERFORM pruebas.afirmar(r->'resultados'->2->>'problema' = 'forma_pago', 'crédito sin internet: ' || (r->'resultados'->2)::text);
  PERFORM pruebas.afirmar(r->'resultados'->3->>'problema' = 'referencia', 'transferencia sin referencia: ' || (r->'resultados'->3)::text);
  PERFORM pruebas.afirmar(r->'resultados'->4->>'estado' = 'registrada' AND r->'resultados'->4->'avisos'->>0 LIKE '%ya aparece en la venta 001-001-01-00000009%',
    'referencia repetida: se registra con aviso: ' || (r->'resultados'->4)::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT p.estado_transferencia = 'por_confirmar' AND p.referencia = 'TR-7781 · BAC' AND d.tipo = 'transferencia_por_confirmar'
                             FROM public.venta_pago p JOIN public.cuenta_dinero d ON d.id = p.cuenta_dinero_id
                            WHERE p.venta_id = (r->'resultados'->0->>'venta_id')::uuid), 'la transferencia queda por confirmar');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.guardar('EQ', eq);
  PERFORM pruebas.guardar('BLOQUE', (bf->>'bloque_id')::uuid);
  PERFORM pruebas.guardar('FOTO', (SELECT id FROM public.catalogo_foto WHERE empresa_id = e AND version = v1));
END $$;

-- 5) Usuario desactivado (M2), en otra transacción (otra hora): la venta 12 es de ANTES; la 13, de después.
DO $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"sin_internet_tope_venta_centavos": 1000000}', 'Tope normal');
  PERFORM public.desactivar_usuario_empresa(e, pruebas.usuario('cajero_a'), 'Ya no trabaja aquí');
END $$;

DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  eq    uuid := pruebas.id('EQ');
  bf    jsonb;
  v1    integer := (SELECT version FROM public.catalogo_foto WHERE id = pruebas.id('FOTO'));
  t1    timestamptz := (SELECT max(hora_equipo) FROM public.venta_sin_internet WHERE bloque_id = pruebas.id('BLOQUE') AND problema IS DISTINCT FROM 'reloj');
  x     jsonb;
  r     jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  bf := public.bloques_del_equipo(e, eq)->'bloques'->0;
  x := jsonb_build_array(
    pruebas.vsi(bf, 13, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, NULL, t1),
    pruebas.vsi(bf, 16, v1, jsonb_build_array(pruebas.linea('P1', 1, 1500, 1500)), 1500, NULL, now() + interval '2 minutes'));
  r := public.subir_ventas_sin_internet(e, eq, x);
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'rechazada' AND r->'resultados'->0->>'clave' = 'FALTA_MOTIVO', 'sin motivo: ' || r::text);
  r := public.subir_ventas_sin_internet(e, eq, x, 'El cajero se fue: las subo yo');
  PERFORM pruebas.afirmar(r->'resultados'->0->>'estado' = 'registrada', 'de antes de desactivarlo: ' || (r->'resultados'->0)::text);
  PERFORM pruebas.afirmar(r->'resultados'->1->>'problema' = 'usuario_desactivado', 'de después: ' || (r->'resultados'->1)::text);
  PERFORM pruebas.afirmar((SELECT subido_por = pruebas.usuario('dueno_a') AND motivo_subida LIKE 'El cajero se fue%' AND usuario_id = pruebas.usuario('cajero_a')
                             FROM public.venta_sin_internet WHERE id_operacion = (x->0->>'id_operacion')::uuid), 'a nombre del cajero, subida por el dueño');
  PERFORM pruebas.afirmar((SELECT creado_por FROM public.venta WHERE id = (r->'resultados'->0->>'venta_id')::uuid) = pruebas.usuario('cajero_a'),
    'la venta queda a nombre del cajero');

END $$;

DO $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  -- 6) Libros: cada asiento cuadra, el dinero tiene su rastro y la bitácora está íntegra.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento_linea l JOIN public.asiento a ON a.id = l.asiento_id WHERE a.empresa_id = e
                                      GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)), 'cada asiento cuadra');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = pruebas.dinero_libros('CAJA1'), 'caja = libros');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e),
    'kardex = inventario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
