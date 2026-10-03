-- PRUEBA: (0.9.1, importante 2) el cajero (sin inventario.costos) no ve costos en un cambio de producto: tampoco en la venta nueva anidada (venta_cambio.costo_centavos en null, costos_ocultos); el dueño sí los ve; ocultar_costos limpia todos los niveles
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  v  jsonb;
  r  jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de costos en cambios');
  -- El cajero registra devoluciones hasta L 1,000.00 sin aprobación (un cambio no queda pendiente).
  PERFORM public.configurar_tope_rol(e, 'cajero', 'devolucion', 100000, 0, 'Cambios en mostrador');

  -- Venta: 2 tornillos a L 15.00 = 3,000 (costo 2 x 1,000 = 2,000).
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 2), gen_random_uuid());
  -- Cambia 1 tornillo por otro tornillo (1,500 por 1,500; costo de la venta nueva 1,000).
  r := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Salió torcido', 'destino', 'cambio', 'cambio', jsonb_build_object('lineas',
           jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))), gen_random_uuid());
  PERFORM pruebas.afirmar(r->'venta_cambio'->>'estado' = 'emitida', 'cambio emitido');
  PERFORM pruebas.afirmar(r->>'costo_centavos' IS NULL AND (r->>'costos_ocultos')::boolean, 'sin costo arriba');
  PERFORM pruebas.afirmar(r->'venta_cambio' ? 'costo_centavos' AND r->'venta_cambio'->>'costo_centavos' IS NULL,
    'sin costo en la venta nueva: ' || (r->'venta_cambio')::text);

  -- El dueño (con inventario.costos) sí los ve: devolución 1,000 y venta nueva 1,000.
  PERFORM pruebas.como('dueno_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 2), gen_random_uuid());
  r := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Salió torcido', 'destino', 'cambio', 'cambio', jsonb_build_object('lineas',
           jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'costo_centavos')::bigint = 1000 AND (r->'venta_cambio'->>'costo_centavos')::bigint = 1000
    AND NOT r ? 'costos_ocultos', 'el dueño ve los costos');

  -- La regla en general (lo que usa ocultar_costos): cualquier nivel, también dentro de listas.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.quitar_claves('{"a":{"costo_centavos":5,"b":[{"costo_centavos":7,"x":1}]},"costo_centavos":3}', ARRAY['costo_centavos'])
    = '{"a":{"costo_centavos":null,"b":[{"costo_centavos":null,"x":1}]},"costo_centavos":null}'::jsonb, 'todos los niveles');
END $$;
