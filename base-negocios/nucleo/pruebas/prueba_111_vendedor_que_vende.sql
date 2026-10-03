-- PRUEBA: (0.9.1, menor) "vendedor_id" de una venta: solo un usuario activo de la misma empresa cuyo puesto vende (permiso ventas.vender); no uno sin ese permiso, ni desactivado, ni de otra empresa, ni el contador
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  v  jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de vendedor');
  -- El dueño decide que los cajeros solo cobran: les quita "ventas.vender".
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'ventas.vender', false, 'Los cajeros solo cobran');

  -- Una venta a nombre del cajero (para que cobre comisión): NO.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', pruebas.usuario('cajero_a'))), 'DATO_INVALIDO', 'puesto que no vende');
  -- A nombre del dueño de otra empresa: NO.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', pruebas.usuario('dueno_b'))), 'DATO_INVALIDO', 'otra empresa');
  -- A nombre del vendedor (su puesto vende): sí.
  v := public.registrar_venta(e, pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', pruebas.usuario('vendedor_a')), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida', 'vendedor válido');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT vendedor_id FROM public.venta WHERE id = (v->>'venta_id')::uuid) = pruebas.usuario('vendedor_a'), 'a su nombre');
  -- El vendedor desactivado: NO.
  UPDATE public.usuario_empresa SET activo = false WHERE empresa_id = e AND user_id = pruebas.usuario('vendedor_a');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', pruebas.usuario('vendedor_a'))), 'DATO_INVALIDO', 'desactivado');
END $$;
