-- PRUEBA: (0.20.0) facturas de emergencia (talonario de imprenta, decisión del dueño): módulo "facturas_emergencia" (depende de ventas y fiscal_hn); registrar el rango solo dueño o admin, con su propio punto de emisión (nunca el de una caja; una caja nueva no puede tomarlo), sin cruces y sin CAI vencido; pasar una factura: venta completa con el número escrito y la fecha de la copia (inventario, caja, ISV, libro de ventas), aunque la caja tenga un bloque sin internet; número fuera del rango, repetido, CAI vencido a la fecha de la copia, mes cerrado (el dueño reabre) y una que pediría aprobación: se rechazan sin dejar nada; anular un número arruinado (sale ANULADA en el libro); la lista con usados, anulados, libres y huecos; cifras a mano y bitácora
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  t1    uuid;
  t2    uuid;
  r     jsonb;
  l     jsonb;
  v     public.venta;
  hoy   date := public.hoy_local(pruebas.empresa('A'));
  caja0 bigint;
  p10   numeric;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  -- Sin el módulo: no.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_talonario(%L, %L, gen_random_uuid())', e,
    '{"cai":"B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6","rango_desde":"001-901-01-00000001","rango_hasta":"001-901-01-00000050","fecha_limite_emision":"2099-01-01"}'),
    'MODULO_INACTIVO', 'sin el módulo');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'facturas_emergencia');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.modulo_dependencia WHERE modulo = 'facturas_emergencia') = 2, 'depende de ventas y fiscal_hn');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'talonario.registrar', true, 'El cajero pasa el talonario');

  -- 1) Registrar el rango.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_talonario(%L, %L, gen_random_uuid())', e,
    '{"cai":"B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6","rango_desde":"001-901-01-00000001","rango_hasta":"001-901-01-00000050","fecha_limite_emision":"2099-01-01"}'),
    'SIN_PERMISO', 'el cajero no registra el rango');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_talonario(%L, %L, gen_random_uuid())', e,
    '{"cai":"B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6","rango_desde":"001-001-01-00002001","rango_hasta":"001-001-01-00002050","fecha_limite_emision":"2099-01-01"}'),
    'punto de emisión 001 es de una caja', 'el punto de emisión de una caja');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_talonario(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cai', 'B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-901-01-00000001', 'rango_hasta', '001-901-01-00000050',
                       'fecha_limite_emision', hoy - 1)), 'CAI_VENCIDO', 'CAI vencido');
  t1 := (public.registrar_talonario(e, jsonb_build_object('cai', 'B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-901-01-00000001',
           'rango_hasta', '001-901-01-00000050', 'fecha_limite_emision', hoy + 200, 'nota', 'Talonario de la imprenta Lara'),
           gen_random_uuid())->>'talonario_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_talonario(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cai', 'B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-901-01-00000040', 'rango_hasta', '001-901-01-00000060',
                       'fecha_limite_emision', hoy + 200)), 'se cruza', 'rangos que se cruzan');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_caja(%L, %L, %L, %L)', e,
    (SELECT id FROM public.sucursal WHERE empresa_id = e AND codigo = '001'), 'Caja 901', '901'), 'talonario', 'una caja no toma el punto del talonario');
  -- Un talonario viejo cuyo CAI venció hace 10 días (cargado como estaba).
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.talonario_rango (empresa_id, sucursal_id, cai, prefijo, rango_desde, rango_hasta, numero_desde, numero_hasta,
                                      fecha_limite_emision, id_operacion)
  VALUES (e, (SELECT id FROM public.sucursal WHERE empresa_id = e AND codigo = '001'), 'C1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', '001-902-01',
          '001-902-01-00000001', '001-902-01-00000010', 1, 10, hoy - 10, gen_random_uuid())
  RETURNING id INTO t2;

  -- 2) Pasar la factura 5 (escrita ayer): 2 tornillos a L 15.00 = L 30.00 en efectivo, en la caja que además tiene un bloque sin internet.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.sin_internet', true, 'Sin internet');
  PERFORM pruebas.como('cajero_a');
  PERFORM public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid());
  PERFORM public.reservar_bloque_numeros(e, (public.registrar_equipo(e, '{"nombre":"Caja 1"}', gen_random_uuid())->>'equipo_id')::uuid,
    gen_random_uuid(), '{"tamano": 10}');
  caja0 := pruebas.dinero('CAJA1');
  p10 := pruebas.existencia('B1', 'P1');
  r := public.registrar_factura_talonario(e, jsonb_build_object('talonario_id', t1, 'numero', 5, 'fecha', hoy - 1,
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
         'pagos', '[{"forma":"efectivo","monto_centavos":3000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'numero_documento' = '001-901-01-00000005' AND r->>'fecha' = to_char(hoy - 1, 'YYYY-MM-DD')
    AND (r->>'total_centavos')::bigint = 3000 AND r->>'estado' = 'emitida', 'factura del talonario: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') - caja0 = 3000 AND p10 - pruebas.existencia('B1', 'P1') = 2, 'caja +3,000 y 2 tornillos menos');
  PERFORM pruebas.como('superusuario');
  SELECT * INTO v FROM public.venta WHERE id = (r->>'venta_id')::uuid;
  PERFORM pruebas.afirmar(v.datos_fiscales->>'cai' = 'B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6' AND (v.datos_fiscales->>'talonario')::boolean
    AND v.impuesto_centavos = 391 AND v.nota LIKE 'Factura de talonario%', 'datos fiscales del talonario: ' || to_jsonb(v)::text);
  -- El rango CAI de la caja no se movió por el talonario.
  PERFORM pruebas.afirmar((SELECT ultimo_numero FROM public.cai_rango WHERE id = pruebas.id('CAI1')) = 10, 'el rango de la caja sigue en su bloque');
  PERFORM pruebas.como('cajero_a');

  -- 3) Rechazos (nada queda guardado).
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_factura_talonario(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('talonario_id', t1, 'numero', 5, 'fecha', hoy, 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
      'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'TALONARIO_REPETIDO', 'número repetido');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_factura_talonario(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('talonario_id', t1, 'numero', 51, 'fecha', hoy, 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
      'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'TALONARIO_INVALIDO', 'fuera del rango');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_factura_talonario(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('talonario_id', t2, 'numero', 1, 'fecha', hoy - 5, 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
      'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'CAI_VENCIDO', 'escrita después de vencer el CAI');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_factura_talonario(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('talonario_id', t1, 'numero', 8, 'fecha', hoy - 1, 'cliente_id', pruebas.id('CLI2'),
      'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
      'pagos', '[{"forma":"credito"}]'::jsonb)), 'APROBACION_REQUERIDA', 'crédito que pide aprobación');
  -- Mes cerrado: la copia es de enero (con el CAI viejo, todavía vigente en enero).
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.periodo (empresa_id, anio, mes, estado) VALUES (e, 2026, 1, 'cerrado') ON CONFLICT (empresa_id, anio, mes) DO UPDATE SET estado = 'cerrado';
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_factura_talonario(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('talonario_id', t2, 'numero', 1, 'fecha', '2026-01-15', 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
      'pagos', '[{"forma":"efectivo"}]'::jsonb)), 'PERIODO_CERRADO', 'mes cerrado');
  PERFORM pruebas.como('superusuario');
  UPDATE public.periodo SET estado = 'abierto' WHERE empresa_id = e AND anio = 2026 AND mes = 1;
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_factura_talonario(e, jsonb_build_object('talonario_id', t2, 'numero', 1, 'fecha', '2026-01-15',
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
         'pagos', '[{"forma":"tarjeta"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'fecha' = '2026-01-15' AND r->>'numero_documento' = '001-902-01-00000001', 'reabierto: con su fecha real: ' || r::text);

  -- 4) Anular el 7 (arruinado).
  r := public.anular_numero_talonario(e, t1, 7, 'Se arruinó al escribirla', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'anulado' AND r->>'numero_documento' = '001-901-01-00000007', 'anulado: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_numero_talonario(%L, %L, 7, %L, gen_random_uuid())', e, t1, 'Otra vez anulada'),
    'TALONARIO_REPETIDO', 'una sola vez');

  -- 5) La lista: usados 1, anulados 1, libres 48, huecos 1, 2, 3, 4 y 6.
  l := public.talonarios(e)->'talonarios';
  SELECT y INTO l FROM jsonb_array_elements(l) y WHERE (y->>'talonario_id')::uuid = t1;
  PERFORM pruebas.afirmar((l->>'usados')::int = 1 AND (l->>'anulados')::int = 1 AND (l->>'libres')::int = 48
    AND l->'huecos' = '[1, 2, 3, 4, 6]'::jsonb, 'lista: ' || l::text);

  -- 6) El libro de ventas del mes: la factura 5 y el 7 ANULADO en cero.
  PERFORM pruebas.como('dueno_a');
  l := public.libro_ventas(e, extract(year FROM hoy)::int, extract(month FROM hoy)::int)->'filas';
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(l) y WHERE y->>'numero_documento' = '001-901-01-00000005'
                                    AND (y->>'total_centavos')::bigint = 3000)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(l) y WHERE y->>'numero_documento' = '001-901-01-00000007' AND y->>'estado' = 'ANULADA'
                  AND (y->>'total_centavos')::bigint = 0), 'libro de ventas: ' || l::text);

  -- 7) Libros y bitácora.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento_linea x JOIN public.asiento s ON s.id = x.asiento_id WHERE s.empresa_id = e
                                      GROUP BY x.asiento_id HAVING sum(x.debe_centavos) <> sum(x.haber_centavos)), 'cada asiento cuadra');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.talonario_numero WHERE empresa_id = e) = 3, 'solo el 5 y el 7 (y el 1 del viejo) quedaron');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
