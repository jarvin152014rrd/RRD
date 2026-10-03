-- PRUEBA: descuentos (cifras a mano): promoción por categoría (vale para subcategorías, con fechas), por artículo y por factura prorrateado a las líneas para el ISV; tope de descuento por puesto: encima queda pendiente SIN número ni movimiento hasta aprobar (dentro del tope del aprobador, nunca el propio), rechazar o cancelar; doble aprobación en ventas y gastos (dos personas distintas; el dueño solo); crédito según límite o siempre con aprobación
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  catp uuid;
  cath uuid;
  pr   uuid;
  v    jsonb;
  vc   jsonb;
  vd   jsonb;
  r    jsonb;
  g    jsonb;
  adm2 uuid;
  l1   record;
  l2   record;
BEGIN
  PERFORM pruebas.preparar_ventas();
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  catp := (public.crear_categoria(e, 'Ferretería')->>'categoria_id')::uuid;
  cath := (public.crear_categoria(e, 'Tornillería', catp)->>'categoria_id')::uuid;
  PERFORM public.editar_producto(e, pruebas.id('P1'), jsonb_build_object('categoria_id', cath));

  -- 1) Promoción 10 % en "Ferretería" (la madre) de ayer a mañana; solo el admin o el dueño.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_promocion(%L, %L)', e, '{}'), 'SIN_PERMISO', 'cajero no crea promociones');
  PERFORM pruebas.como('admin_a');
  pr := (public.crear_promocion(e, jsonb_build_object('nombre', 'Semana del tornillo', 'categoria_id', catp, 'tipo', 'porcentaje',
         'porcentaje', 10, 'fecha_inicio', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'),
         'fecha_fin', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;

  -- 2) Venta A (cajero): 10 tornillos con promoción 10 % y 5 % del artículo (su tope: 5 %).
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'descuento_porcentaje', 5)),
         'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  -- A mano: bruto 15,000; promoción 1,500 -> 13,500; artículo round(13,500 x 5 %) = 675 -> 12,825 (con ISV).
  -- Sin ISV: bruto 13,043; con promoción round(13,500/1.15) = 11,739; neto round(12,825/1.15) = 11,152; ISV 1,673.
  -- Descuento manual = (11,739 - 11,152) / 11,739 = 5.00 % (justo el tope: no pide aprobación).
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND (v->>'total_centavos')::bigint = 12825 AND (v->>'impuesto_centavos')::bigint = 1673
    AND (v->>'subtotal_centavos')::bigint = 13043 AND (v->>'descuento_centavos')::bigint = 1891
    AND (v->>'descuento_manual_porcentaje')::numeric = 5.00, 'venta A: ' || v::text);
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT descuento_promocion_centavos || '/' || descuento_manual_centavos FROM public.venta WHERE id = (v->>'venta_id')::uuid)
    = '1304/587', 'promoción 1,304 y manual 587 (sin ISV)');
  PERFORM pruebas.afirmar((SELECT promocion_id FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid) = pr, 'línea con su promoción');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '4.1.01.03') = 1891 AND pruebas.saldo_libros(e, '4.1.01.01') = 13043, 'Dr descuentos / Cr ventas brutas');

  -- 3) Venta B: descuento de factura de L 20.00 (con ISV) entre tornillos (con promoción) y un galón.
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10),
         jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1)),
         'descuento_factura', '{"monto_centavos": 2000}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  -- A mano: totales con ISV antes del descuento 13,500 y 45,000 (suma 58,500). Partes: 2,000 x 13,500/58,500 = 461.54 y
  -- 2,000 x 45,000/58,500 = 1,538.46 -> 461 + 1,538 = 1,999; el centavo que falta va al resto mayor (0.54): 462 y 1,538.
  -- Tornillos 13,038 -> 11,337 + 1,701; galón 43,462 -> round(43,462/1.18) = 36,832 + 6,630. Total 56,500 = 58,500 - 2,000.
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 56500 AND (v->>'impuesto_centavos')::bigint = 1701 + 6630, 'venta B: ' || v::text);
  PERFORM pruebas.como('dueno_a');
  SELECT * INTO l1 FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid AND linea = 1;
  SELECT * INTO l2 FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid AND linea = 2;
  PERFORM pruebas.afirmar(l1.descuento_factura_centavos = 462 AND l2.descuento_factura_centavos = 1538
    AND l1.base_centavos = 11337 AND l2.base_centavos = 36832, 'prorrateo por línea');

  -- 4) Descuento sobre el tope: pendiente SIN número, sin inventario y sin dinero.
  PERFORM pruebas.como('cajero_a');
  vc := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 20)),
          'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  -- A mano: 45,000 - 9,000 = 36,000 -> sin ISV 30,508; con descuento manual (38,136 - 30,508)/38,136 = 20.00 %.
  PERFORM pruebas.afirmar(vc->>'estado' = 'pendiente_aprobacion' AND vc->'requiere_aprobacion' = '["descuento"]'
    AND vc->>'numero_documento' IS NULL AND (vc->>'descuento_manual_porcentaje')::numeric = 20.00, 'pendiente: ' || vc::text);
  vd := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 25)),
          'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P3') = 9 AND pruebas.dinero('CAJA1') = 12825 + 56500, 'pendientes no mueven nada');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', vc->>'aprobacion_id', 'ok'),
    'SIN_PERMISO', 'el cajero no aprueba');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', vd->>'aprobacion_id', 'ok'),
    'TOPE_APROBACION', 'admin aprueba hasta 20 %');
  r := public.resolver_aprobacion((vc->>'aprobacion_id')::uuid, true, 'Cliente frecuente', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida' AND r->>'numero_documento' = '001-001-01-00000003' AND r->>'aprobacion_estado' = 'aprobada',
    'aprobada y emitida: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', vc->>'aprobacion_id', 'otra'),
    'YA_RESUELTO', 'una sola vez');
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((vd->>'aprobacion_id')::uuid, true, NULL, gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'numero_documento' = '001-001-01-00000004', 'el dueño aprueba sin tope');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P3') = 7 AND pruebas.dinero('CAJA1') = 12825 + 56500 + 36000 + 33750,
    'al aprobar sale la mercadería y entra el dinero (36,000 y 33,750)');

  -- 5) Rechazar (con motivo) y cancelar: sin número ni movimiento.
  PERFORM pruebas.como('cajero_a');
  vc := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_centavos', 500)),
          'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  vd := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_centavos', 500)),
          'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, false, %L, gen_random_uuid())', vc->>'aprobacion_id', 'no'),
    'FALTA_MOTIVO', 'rechazo sin motivo');
  r := public.resolver_aprobacion((vc->>'aprobacion_id')::uuid, false, 'Descuento muy alto', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'rechazada' AND r->>'numero_documento' IS NULL, 'rechazada');
  PERFORM pruebas.como('cajero_a');
  r := public.cancelar_venta((vd->>'venta_id')::uuid, 'El cliente se fue', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'cancelada', 'cancelada por quien la registró');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT estado FROM public.aprobacion WHERE id = (vd->>'aprobacion_id')::uuid) = 'cancelada', 'su aprobación cancelada');
  PERFORM pruebas.afirmar((SELECT ultimo_numero FROM public.cai_rango WHERE id = pruebas.id('CAI1')) = 4, 'rechazadas y canceladas no consumen números');

  -- 6) Topes: los cambia solo el dueño (en porcentaje).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_tope_descuento(%L, %L, 50, 0, %L)', e, 'cajero', 'Subir tope'), 'SIN_PERMISO', 'admin no cambia topes');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_tope_descuento(e, 'cajero', 0, 0, 'Sin descuentos sin aprobación');
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_porcentaje', 1)),
         'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'pendiente_aprobacion', 'tope 0 %: cualquier descuento manual pide aprobación');
  r := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida', 'la promoción no cuenta contra el tope');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_tope_descuento(e, 'cajero', 5, 0, 'Vuelve a 5 %');

  -- 7) Doble aprobación (empresa grande): dos personas distintas; el dueño aprueba solo.
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (email) VALUES ('admin2@prueba.hn') RETURNING id INTO adm2;
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('admin2', adm2);
  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol) VALUES (adm2, e, 'admin');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"doble_aprobacion": true}', 'Empresa grande');
  PERFORM pruebas.como('cajero_a');
  vc := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2, 'descuento_porcentaje', 10)),
          'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  r := public.resolver_aprobacion((vc->>'aprobacion_id')::uuid, true, 'Primera', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'pendiente_aprobacion' AND (r->>'falta_segunda_aprobacion')::boolean
    AND r->>'numero_documento' IS NULL, 'primera aprobación: sigue pendiente: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', vc->>'aprobacion_id', 'Otra vez'),
    'PROHIBIDO', 'la segunda la da otra persona');
  PERFORM pruebas.como('admin2');
  r := public.resolver_aprobacion((vc->>'aprobacion_id')::uuid, true, 'Segunda', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida' AND r->>'aprobacion_estado' = 'aprobada', 'segunda: emitida');
  PERFORM pruebas.afirmar((SELECT aprobaciones_requeridas || '/' || (primera_aprobacion_por = pruebas.usuario('admin_a')) || '/' || (resuelto_por = adm2)
                             FROM public.aprobacion WHERE id = (vc->>'aprobacion_id')::uuid) = '2/true/true', 'quién aprobó cada paso');
  PERFORM pruebas.como('cajero_a');
  vc := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2, 'descuento_porcentaje', 10)),
          'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((vc->>'aprobacion_id')::uuid, true, NULL, gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida', 'el dueño aprueba solo');
  -- Gastos también: el admin pide (su tope de registro a 0), admin2 da la primera y el dueño la segunda.
  PERFORM public.configurar_tope_rol(e, 'admin', 'gasto', 0, 500000, 'Todo gasto del admin pide aprobación');
  PERFORM pruebas.como('admin_a');
  g := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
         'monto_centavos', 100000, 'descripcion', 'Resmas'), gen_random_uuid());
  PERFORM pruebas.como('admin2');
  r := public.resolver_aprobacion((g->>'aprobacion_id')::uuid, true, 'Primera', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'pendiente_aprobacion' AND (r->>'falta_segunda_aprobacion')::boolean
    AND pruebas.dinero('BANCO') = 1000000, 'gasto: primera aprobación, el dinero no se movió');
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((g->>'aprobacion_id')::uuid, true, NULL, gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicado' AND pruebas.dinero('BANCO') = 900000, 'gasto aplicado con la segunda');
  PERFORM public.configurar_empresa(e, '{"doble_aprobacion": false}', 'Vuelve a una aprobación');

  -- 8) Crédito según límite: CLI1 con límite L 1,000.00 y plazo 30.
  PERFORM public.editar_tercero(e, pruebas.id('CLI1'), '{"limite_credito_centavos": 100000}', 'Límite de prueba');
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_venta(e, pruebas.venta('P3', 2, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida' AND (r->>'credito_centavos')::bigint = 90000, 'dentro del límite: directo');
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida', '90,000 + 1,350 (tornillo con promoción) = 91,350 <= 100,000');
  vc := public.registrar_venta(e, pruebas.venta('P1', 10, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar(vc->>'estado' = 'pendiente_aprobacion' AND vc->'requiere_aprobacion' = '["credito"]', '91,350 + 13,500 pasa el límite');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_tope_rol(e, 'admin', 'credito', 0, 10000, 'Admin aprueba créditos hasta L 100');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', vc->>'aprobacion_id', 'ok'),
    'TOPE_APROBACION', 'crédito sobre el tope del admin');
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((vc->>'aprobacion_id')::uuid, true, NULL, gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida' AND r->>'vence_el' = to_char(public.hoy_local(e) + 30, 'YYYY-MM-DD'), 'vence a 30 días (fecha local)');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cxc_cliente WHERE cliente_id = pruebas.id('CLI1')) = 104850, 'CxC del cliente: 90,000 + 1,350 + 13,500');
  -- Siempre con aprobación: aun dentro del límite; el dueño no la necesita.
  PERFORM public.configurar_empresa(e, '{"credito_politica": "siempre_aprobacion"}', 'Todo crédito con aprobación');
  PERFORM public.editar_tercero(e, pruebas.id('CLI1'), '{"limite_credito_centavos": 1000000}', 'Límite alto');
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'pendiente_aprobacion', 'siempre con aprobación');
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida', 'el dueño no pide aprobación');
END $$;
