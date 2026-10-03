-- PRUEBA: decisiones del dueño (0.8.0): nunca descuento sobre descuento (varias promociones: se elige una, sin elegir PROMOCION_A_ELEGIR con la lista; promoción ajena PROMOCION_INVALIDA; promoción + descuento manual DESCUENTO_DOBLE; el descuento de factura solo va a líneas sin otro descuento, cifras a mano); vendedor que cobra configurable (falso por defecto, solo el dueño con motivo y bitácora, respeta turnos; perfil pequeño lo sugiere); topes confirmados (5 %, 10 % / 20 %, L 5,000) y cotización de 15 días
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  catp uuid;
  cath uuid;
  pa   uuid;
  pb   uuid;
  v    jsonb;
  l    record;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  catp := (public.crear_categoria(e, 'Ferretería')->>'categoria_id')::uuid;
  cath := (public.crear_categoria(e, 'Tornillería', catp)->>'categoria_id')::uuid;
  PERFORM public.editar_producto(e, pruebas.id('P1'), jsonb_build_object('categoria_id', cath));
  pa := (public.crear_promocion(e, jsonb_build_object('nombre', 'Diez por ciento', 'categoria_id', catp, 'tipo', 'porcentaje', 'porcentaje', 10,
         'fecha_inicio', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'), 'fecha_fin', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;

  -- 1) Una sola promoción vigente: se aplica sola (10 tornillos a L 15.00: 15,000 - 1,500 = 13,500).
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 10), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 13500, 'una promoción: se aplica sola');

  -- 2) Dos promociones: la venta no elige sola.
  PERFORM pruebas.como('admin_a');
  pb := (public.crear_promocion(e, jsonb_build_object('nombre', 'Dos lempiras menos', 'categoria_id', cath, 'tipo', 'monto', 'monto_centavos', 200,
         'fecha_inicio', to_char(public.hoy_local(e) - 1, 'YYYY-MM-DD'), 'fecha_fin', to_char(public.hoy_local(e) + 1, 'YYYY-MM-DD')))->>'promocion_id')::uuid;
  PERFORM pruebas.como('vendedor_a');
  v := public.promociones_aplicables(e, pruebas.id('P1'), NULL, 10);
  -- A mano: 10 x 2.00 = 2,000 y 10 % de 15,000 = 1,500 (la que más descuenta primero).
  PERFORM pruebas.afirmar(jsonb_array_length(v->'promociones') = 2 AND (v->'promociones'->0->>'promocion_id')::uuid = pb
    AND (v->'promociones'->0->>'descuento_centavos')::bigint = 2000 AND (v->'promociones'->1->>'descuento_centavos')::bigint = 1500,
    'promociones aplicables: ' || v::text);
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 10)),
    'PROMOCION_A_ELEGIR', 'varias sin elegir');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 10)),
    'Dos lempiras menos', 'el error trae la lista');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'promocion_id', pa)),
    'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'PROMOCION_INVALIDA', 'promoción de otra categoría');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'promocion_id', pa, 'descuento_porcentaje', 1)),
    'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'DESCUENTO_DOBLE', 'promoción + descuento manual');
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'promocion_id', pa)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 13500, 'eligió la del 10 % (no la que más descuenta)');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT promocion_id FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid) = pa, 'queda la elegida');

  -- 3) Factura: solo líneas sin otro descuento. Dueño (sin topes):
  --    tornillos con promoción 13,500; galón con 2 % manual 45,000 - 900 = 44,100; servicio sin descuento 23,000.
  --    10 % de factura solo al servicio: round(23,000 x 10 %) = 2,300 -> 20,700. Total 13,500 + 44,100 + 20,700 = 78,300.
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'promocion_id', pa),
         jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 2),
         jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 1)),
         'descuento_factura', '{"porcentaje": 10}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 78300, 'total con factura solo en la línea libre: ' || v::text);
  PERFORM pruebas.afirmar((SELECT string_agg(descuento_factura_centavos::text, ',' ORDER BY linea) FROM public.venta_linea
                            WHERE venta_id = (v->>'venta_id')::uuid) = '0,0,2300', 'factura por línea');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.venta_linea WHERE empresa_id = e
     AND ((promocion_id IS NOT NULL)::int + (descuento_linea_centavos > 0)::int + (descuento_factura_centavos > 0)::int) > 1),
    'ninguna línea con más de un descuento');
  -- Monto de factura (L 10.00) con una línea con promoción y el servicio: todo al servicio.
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'promocion_id', pa),
         jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 1)),
         'descuento_factura', '{"monto_centavos": 1000}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT string_agg(descuento_factura_centavos::text, ',' ORDER BY linea) FROM public.venta_linea
                            WHERE venta_id = (v->>'venta_id')::uuid) = '0,1000' AND (v->>'total_centavos')::bigint = 1350 + 22000, 'monto solo al servicio');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'promocion_id', pa)),
    'descuento_factura', '{"porcentaje": 5}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'DESCUENTO_DOBLE', 'factura sobre líneas ya rebajadas');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'promocion_id', pa),
                                jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 1)),
    'descuento_factura', '{"monto_centavos": 30000}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'sin otro descuento', 'monto mayor que las líneas libres');
  -- La cotización usa la misma regla.
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cotizacion(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))), 'PROMOCION_A_ELEGIR', 'cotización también elige');

  -- 4) Vendedor que cobra: falso por defecto.
  PERFORM pruebas.afirmar(NOT (SELECT vendedor_cobra FROM public.empresa WHERE id = e), 'falso por defecto');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P3', 1)),
    'ventas.cobrar', 'el vendedor no cobra');
  v := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida', 'el vendedor vende al crédito');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"vendedor_cobra": true}', 'Que cobre'),
    'SIN_PERMISO', 'el admin no lo cambia');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"vendedor_cobra": true}', ''), 'FALTA_MOTIVO', 'con motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"vendedor_cobra": "si"}', 'Que cobre'), 'DATO_INVALIDO', 'booleano');
  v := public.configurar_empresa(e, '{"vendedor_cobra": true}', 'El vendedor también cobra');
  PERFORM pruebas.afirmar((v->>'vendedor_cobra')::boolean AND (public.mi_perfil(e)->'empresa'->>'vendedor_cobra')::boolean, 'activado');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora b WHERE b.empresa_id = e AND b.tabla = 'empresa'
    AND b.motivo = 'El vendedor también cobra' AND (b.despues->>'vendedor_cobra')::boolean), 'bitácora con motivo');
  PERFORM pruebas.como('vendedor_a');
  v := public.registrar_venta(e, pruebas.venta('P3', 1), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida', 'ahora el vendedor cobra en efectivo');
  -- Respeta los turnos: si la empresa los exige, el vendedor sin turno no recibe efectivo.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": true}', 'Turnos obligatorios');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P3', 1)),
    'SIN_TURNO_ABIERTO', 'el vendedor respeta los turnos');
  v := public.registrar_venta(e, pruebas.venta('P3', 1, 'tarjeta'), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida', 'tarjeta no necesita turno');

  -- 5) Perfiles: el pequeño sugiere que el vendedor cobre; los demás no.
  PERFORM pruebas.afirmar((SELECT string_agg(x->>'perfil' || '=' || (x->>'vendedor_cobra'), ',' ORDER BY x->>'perfil')
                             FROM jsonb_array_elements(public.perfiles_negocio()) x) = 'grande=false,mediano=false,pequeno=true', 'perfiles');

  -- 6) Valores confirmados por el dueño (no cambian).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sin_aprobacion || '/' || aprueba_hasta FROM interno.tope_descuento(e, 'cajero')) = '5.00/0.00'
    AND (SELECT sin_aprobacion FROM interno.tope_descuento(e, 'vendedor')) = 5
    AND (SELECT sin_aprobacion || '/' || aprueba_hasta FROM interno.tope_descuento(e, 'admin')) = '10.00/20.00', 'topes de descuento');
  PERFORM pruebas.afirmar((SELECT aprueba_hasta FROM interno.tope_rol(e, 'admin', 'credito')) = 500000
    AND (SELECT aprueba_hasta FROM interno.tope_rol(e, 'admin', 'anulacion_venta')) = 500000, 'admin aprueba créditos y anulaciones hasta L 5,000');
  PERFORM pruebas.afirmar((SELECT cotizacion_dias_vigencia FROM public.empresa WHERE id = e) = 15, 'cotización 15 días');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
