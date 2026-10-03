-- PRUEBA: permisos de inventario y compras por rol: vendedor no ve costos, cajero no ajusta, proveedor no mueve nada (con soporte solo lee), licencia vencida solo lectura
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  c uuid;
  ajuste text;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'costo_unitario', 1000)), gen_random_uuid());
  c := (public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'H-1', '2026-01-05', 'credito', 'P1', 1, 1000), gen_random_uuid())->>'compra_id')::uuid;
  ajuste := format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-06',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 1)), 'Conteo de prueba');

  -- Vendedor: ve productos y cantidades; no costos, compras ni movimientos.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(ajuste, 'SIN_PERMISO', 'vendedor ajusta');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-06',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1))), 'SIN_PERMISO', 'vendedor traslada');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e, pruebas.compra('PROV1', 'B1', 'H-2', '2026-01-05', 'credito', 'P1', 1, 1000)), 'SIN_PERMISO', 'vendedor compra');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.producto WHERE empresa_id = e) = 3, 'vendedor ve productos');
  PERFORM pruebas.afirmar((SELECT cantidad FROM public.v_existencia WHERE producto_id = pruebas.id('P1')) = 11
    AND (SELECT valor_centavos FROM public.v_existencia WHERE producto_id = pruebas.id('P1')) IS NULL, 'cantidad sí, costo no');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.compra) + (SELECT count(*) FROM public.compra_linea)
    + (SELECT count(*) FROM public.inventario_documento) + (SELECT count(*) FROM public.v_kardex) = 0, 'sin compras, documentos ni kardex');

  -- Cajero: igual que el vendedor en inventario; no paga ni carga saldos.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(ajuste, 'SIN_PERMISO', 'cajero ajusta');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, c, '2026-01-06', 'caja'), 'SIN_PERMISO', 'cajero paga');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid())', c, 'no me gusta'), 'SIN_PERMISO', 'cajero anula compra');
  PERFORM pruebas.afirmar((SELECT costo_promedio FROM public.v_existencia WHERE producto_id = pruebas.id('P1')) IS NULL, 'cajero sin costos');

  -- Proveedor: nada. Con soporte, lee costos y compras, pero no mueve.
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.debe_fallar(ajuste, 'SIN_PERMISO', 'proveedor ajusta');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_existencia) = 0 AND (SELECT count(*) FROM public.compra) = 0, 'proveedor no ve existencias ni compras');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.otorgar_acceso_soporte(e, now() + interval '1 day', 'Revisar costos del kardex');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_kardex) = 2 AND (SELECT count(*) FROM public.compra) = 1, 'con soporte lee kardex y compras');
  PERFORM pruebas.debe_fallar(ajuste, 'SIN_PERMISO', 'proveedor con soporte ajusta');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, c, '2026-01-06', 'caja'), 'SIN_PERMISO', 'proveedor con soporte paga');

  -- Admin sí ajusta; pero no deja negativo ni repite carga inicial (solo dueño).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('inventario.negativo', e) AND NOT public.tiene_permiso('inventario.carga_inicial_repetir', e), 'admin sin permisos especiales');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-06',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 12))), 'EXISTENCIA_INSUFICIENTE', 'admin deja negativo');
  -- El dueño sí puede dejar negativo (su permiso), con alerta.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-06',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 12)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = -1 AND (SELECT count(*) FROM public.inventario_alerta) = 1, 'dueño deja negativo con alerta');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.inventario_alerta) = 1, 'cajero ve la alerta (cantidades)');

  -- Licencia vencida: solo lectura.
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local() - 60 WHERE empresa_id = e;
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(ajuste, 'LICENCIA_VENCIDA', 'ajustar en solo lectura');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e, pruebas.compra('PROV1', 'B1', 'H-3', '2026-01-05', 'credito', 'P1', 1, 1000)), 'LICENCIA_VENCIDA', 'comprar en solo lectura');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true}'), 'LICENCIA_VENCIDA', 'crear cliente en solo lectura');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_kardex) = 4 AND (SELECT count(*) FROM public.v_cxp_proveedor) = 1, 'sigue leyendo');
END $$;
