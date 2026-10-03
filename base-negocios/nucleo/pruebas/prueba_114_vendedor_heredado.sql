-- PRUEBA: (0.9.2, importante) el vendedor que viene de un documento guardado se respeta: un apartado de un cajero que después se da de baja se completa a su nombre y su comisión se genera igual (el dueño decide al liquidar); una cotización de un vendedor cuyo puesto ya solo cotiza se convierte a su nombre; la regla de vendedor_id sigue valiendo cuando se elige en el momento
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  caj  uuid := pruebas.usuario('cajero_a');
  a    jsonb;
  c    jsonb;
  v    jsonb;
  p    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de vendedor heredado');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'apartados') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'comisiones') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_comisiones(e, '{"activas": true, "base": "precio"}', 'Comisión sobre el precio');
  PERFORM public.fijar_porcentaje_comision(e, caj, 10, NULL, 'Comisión del cajero');

  -- 1) El cajero aparta 2 tornillos (3,000 con ISV) a CLI1 con 1,000 de anticipo. Después lo dan de baja.
  PERFORM pruebas.como('cajero_a');
  a := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
         'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  UPDATE public.usuario_empresa SET activo = false WHERE empresa_id = e AND user_id = caj;

  --    El dueño lo completa (cobra 2,000): antes daba DATO_INVALIDO y el apartado quedaba trabado.
  PERFORM pruebas.como('dueno_a');
  v := public.completar_apartado((a->>'apartado_id')::uuid, '{"pagos":[{"forma":"efectivo","monto_centavos":2000}]}', gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida', 'apartado completado: ' || v::text);
  --    A nombre del cajero; comisión: base sin ISV round(3,000 / 1.15) = 2,609; 10 % = round(260.9) = 261, a su nombre.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT vendedor_id FROM public.venta WHERE id = (v->>'venta_id')::uuid) = caj, 'venta a nombre del cajero');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = (v->>'venta_id')::uuid AND vendedor_id = caj) = 261,
    'comisión de 261 al cajero dado de baja');
  --    El dueño decide al liquidar: se le puede pagar aunque ya no esté activo.
  PERFORM pruebas.como('dueno_a');
  p := public.pagar_comisiones(e, jsonb_build_object('vendedor_id', caj, 'cuenta_dinero_id', pruebas.id('FUERTE')), gen_random_uuid());
  PERFORM pruebas.afirmar((p->>'monto_centavos')::bigint = 261, 'liquidación de 261');

  -- 2) El vendedor cotiza 1 tornillo; el dueño decide que los vendedores solo cotizan; el admin la convierte:
  --    antes DATO_INVALIDO (la cotización quedaba trabada); ahora la venta queda a nombre de quien cotizó.
  PERFORM pruebas.como('vendedor_a');
  c := public.crear_cotizacion(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))),
         gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'vendedor', 'ventas.vender', false, 'Los vendedores solo cotizan');
  PERFORM pruebas.como('admin_a');
  v := public.convertir_cotizacion_a_venta((c->>'cotizacion_id')::uuid, '{"pagos":[{"forma":"efectivo"}]}', gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida', 'cotización convertida: ' || v::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT vendedor_id FROM public.venta WHERE id = (v->>'venta_id')::uuid) = pruebas.usuario('vendedor_a'),
    'venta a nombre de quien cotizó');

  -- 3) Elegido en el momento, la regla sigue: ni el cajero dado de baja ni el vendedor (su puesto ya no vende).
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', caj)), 'DATO_INVALIDO', 'cajero dado de baja');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', pruebas.usuario('vendedor_a'))), 'DATO_INVALIDO', 'puesto que ya no vende');

  -- Cuadre: comisiones por pagar = su cuenta; dinero = libros.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_comisiones_por_pagar(e) = pruebas.saldo_libros(e, '2.1.03.04')
    AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero x JOIN public.cuenta k ON k.id = x.cuenta_id
                     WHERE x.empresa_id = e AND interno.saldo_dinero(x.id) <> pruebas.saldo_libros(e, k.codigo)), 'cuadre');
END $$;
