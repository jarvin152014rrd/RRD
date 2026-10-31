-- PRUEBA: (0.20.0) transferencias por confirmar (decisión del dueño): una venta sin internet pagada con transferencia (referencia y banco) queda en "Transferencias por confirmar" (no es dinero disponible); la lista la muestra con la referencia repetida marcada; confirmarla la pasa al banco y la conciliación bancaria la empareja con la fila del estado de cuenta; "no llegó" con cliente: la venta queda como deuda del cliente (cuenta por cobrar que se cobra como cualquier otra); "no llegó" sin cliente: deuda del cajero (Cuentas por cobrar a empleados); con motivo, una sola vez, permisos, bitácora; esa venta ya no se anula completa; cifras a mano y libros que cuadran
CREATE FUNCTION pruebas.vsi(p_bloque jsonb, p_numero bigint, p_foto integer, p_lineas jsonb, p_total bigint,
                            p_pagos jsonb DEFAULT NULL, p_cliente text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql VOLATILE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('id_operacion', gen_random_uuid(), 'usuario_id', pruebas.usuario('cajero_a'),
    'caja_id', p_bloque->'caja_id', 'bloque_id', p_bloque->'bloque_id', 'numero', p_numero,
    'numero_documento', (p_bloque->>'prefijo') || '-' || lpad(p_numero::text, 8, '0'),
    'tipo_documento', p_bloque->'tipo', 'foto_version', p_foto, 'hora_equipo', public.iso(now()), 'cliente_id', pruebas.id(p_cliente),
    'lineas', p_lineas, 'pagos', p_pagos, 'total_centavos', p_total, 'en_linea', false))
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pruebas TO authenticated;

DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  eq    uuid;
  bf    jsonb;
  v1    integer;
  r     jsonb;
  l     jsonb;
  pa    uuid;
  pb    uuid;
  pc    uuid;
  va    uuid;
  vb    uuid;
  vc    uuid;
  pxc   bigint;
  cxc0  bigint;
  emp0  bigint;
  ban0  bigint;
  hoy   date := public.hoy_local(pruebas.empresa('A'));
  lin   jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  lin := jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'precio_tipo', 'normal',
                 'precio_unitario_centavos', 45000, 'total_centavos', 45000));
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.sin_internet', true, 'El cajero vende sin internet');
  PERFORM pruebas.como('cajero_a');
  PERFORM public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid());
  eq := (public.registrar_equipo(e, '{"nombre": "Caja 1"}', gen_random_uuid())->>'equipo_id')::uuid;
  bf := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), '{"tamano": 10}')->'bloques'->0;
  v1 := (public.preparar_sin_internet(e, eq)->>'version')::int;
  PERFORM pruebas.como('superusuario');
  pxc := coalesce((SELECT sum(monto_centavos) FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
                    WHERE d.empresa_id = e AND d.tipo = 'transferencia_por_confirmar'), 0);
  PERFORM pruebas.como('cajero_a');
  -- Tres ventas de un galón (L 450.00) con transferencia: A y B con cliente (B repite la referencia de A), C a Consumidor final.
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(
    pruebas.vsi(bf, 1, v1, lin, 45000, '[{"forma":"transferencia","monto_centavos":45000,"referencia":"BAC-5501","banco":"BAC"}]', 'CLI1'),
    pruebas.vsi(bf, 2, v1, lin, 45000, '[{"forma":"transferencia","monto_centavos":45000,"referencia":"bac-5501"}]', 'CLI2'),
    pruebas.vsi(bf, 3, v1, lin, 45000, '[{"forma":"transferencia","monto_centavos":45000,"referencia":"FIC-9","banco":"Ficohsa"}]')));
  PERFORM pruebas.afirmar((r->>'registradas')::int = 3 AND jsonb_array_length(r->'resultados'->1->'avisos') = 1, 'tanda: ' || r::text);
  va := (r->'resultados'->0->>'venta_id')::uuid;  vb := (r->'resultados'->1->>'venta_id')::uuid;  vc := (r->'resultados'->2->>'venta_id')::uuid;
  -- No es dinero disponible: no entra a la caja; va a "Transferencias por confirmar" (+135,000).
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 0, 'nada en la caja');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
                            WHERE d.empresa_id = e AND d.tipo = 'transferencia_por_confirmar') - pxc = 135000, 'por confirmar +135,000');
  SELECT id INTO pa FROM public.venta_pago WHERE venta_id = va;
  SELECT id INTO pb FROM public.venta_pago WHERE venta_id = vb;
  SELECT id INTO pc FROM public.venta_pago WHERE venta_id = vc;

  -- La lista (el cajero no la ve: sin dinero.ver).
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.transferencias_por_confirmar(%L)', e), 'SIN_PERMISO', 'el cajero no ve la lista');
  PERFORM pruebas.como('dueno_a');
  l := public.transferencias_por_confirmar(e)->'transferencias';
  PERFORM pruebas.afirmar(jsonb_array_length(l) = 3 AND (SELECT count(*) FROM jsonb_array_elements(l) y WHERE (y->>'referencia_repetida')::boolean) = 2
    AND (SELECT bool_and((y->>'sin_internet')::boolean) FROM jsonb_array_elements(l) y), 'lista: ' || l::text);

  -- 1) Confirmar A en el banco y emparejarla en la conciliación.
  ban0 := pruebas.dinero('BANCO');
  r := public.confirmar_transferencia_venta(pa, jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'BAC-5501', 'fecha', hoy), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado_transferencia' = 'confirmada' AND pruebas.dinero('BANCO') - ban0 = 45000, 'confirmada: ' || r::text);
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'conciliacion') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('dueno_a');
  r := public.importar_estado_cuenta(e, pruebas.id('BANCO'), extract(year FROM hoy)::int, extract(month FROM hoy)::int,
         jsonb_build_object('archivo', 'bac.csv', 'dias_tolerancia', 1,
           'filas', jsonb_build_array(jsonb_build_object('fecha', hoy, 'descripcion', 'TRANSF BAC-5501', 'monto_centavos', 45000, 'referencia', 'BAC-5501'))),
         gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'emparejadas_automaticamente')::int = 1, 'la conciliación la empareja: ' || r::text);

  -- 2) B no llegó (cliente Juan Pérez): queda como deuda del cliente; se cobra como cualquier cuenta por cobrar.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.marcar_transferencia_no_llego(%L, %L, gen_random_uuid())', pb, 'No aparece en el banco'),
    'SIN_PERMISO', 'el cajero no la marca');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.marcar_transferencia_no_llego(%L, %L, gen_random_uuid())', pb, 'no'), 'FALTA_MOTIVO', 'sin motivo');
  cxc0 := pruebas.saldo_libros(e, '1.1.02.01');
  r := public.marcar_transferencia_no_llego(pb, 'No aparece en el banco después de 3 días', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado_transferencia' = 'no_llego' AND r->>'deuda_de' = 'cliente', 'B no llegó: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') - cxc0 = 45000, 'Clientes +45,000');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.v_cxc_documento x WHERE x.empresa_id = e AND x.cliente_id = pruebas.id('CLI2')
                                    AND x.saldo_centavos = 45000), 'el cliente la debe');
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
         'pagos', '[{"forma":"efectivo","monto_centavos":45000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') = cxc0, 'cobrada: Clientes vuelve a lo de antes');
  PERFORM pruebas.debe_fallar(format('SELECT public.confirmar_transferencia_venta(%L, %L, gen_random_uuid())', pb,
    jsonb_build_object('banco_id', pruebas.id('BANCO'), 'referencia', 'BAC-5501')), 'PROHIBIDO', 'ya no se confirma');
  PERFORM pruebas.debe_fallar(format('SELECT public.marcar_transferencia_no_llego(%L, %L, gen_random_uuid())', pb, 'Otra vez no llegó'),
    'YA_RESUELTO', 'una sola vez');
  PERFORM pruebas.debe_fallar(format('SELECT public.marcar_transferencia_no_llego(%L, %L, gen_random_uuid())', pa, 'Ya estaba confirmada'),
    'YA_RESUELTO', 'una confirmada no se marca');

  -- 3) C no llegó (Consumidor final): deuda del cajero que la registró.
  emp0 := coalesce(pruebas.saldo_libros(e, '1.1.02.05'), 0);
  r := public.marcar_transferencia_no_llego(pc, 'El comprobante que mostró el cliente era falso', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'deuda_de' = 'cajero' AND (r->>'deudor_id')::uuid = pruebas.usuario('cajero_a'), 'C: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.05') - emp0 = 45000, 'Cuentas por cobrar a empleados +45,000');
  -- Esa venta no se anula completa.
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_anulacion_venta(%L, %L, gen_random_uuid())', vc, 'Anular la venta'),
    'no llegó', 'no se anula');

  -- 4) Libros y bitácora: "por confirmar" quedó en lo de antes (+135,000 - 45,000 confirmada - 90,000 no llegaron).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
                            WHERE d.empresa_id = e AND d.tipo = 'transferencia_por_confirmar') = pxc, 'por confirmar vuelve a lo de antes');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento_linea x JOIN public.asiento s ON s.id = x.asiento_id WHERE s.empresa_id = e
                                      GROUP BY x.asiento_id HAVING sum(x.debe_centavos) <> sum(x.haber_centavos)), 'cada asiento cuadra');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e AND tabla = 'venta_pago' AND accion = 'UPDATE'
                             AND motivo LIKE 'El comprobante%') = 1, 'bitácora con motivo');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
