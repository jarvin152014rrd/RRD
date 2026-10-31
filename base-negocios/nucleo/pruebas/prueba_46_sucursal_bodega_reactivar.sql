-- PRUEBA: no se desactiva una sucursal ni una bodega con existencias o valor; reactivar sucursal, caja, bodega, categoría y campo extra (con motivo, permisos y bitácora)
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  s2   uuid;
  cj   uuid;
  b3   uuid;
  c1   uuid; c2 uuid;
  ce   uuid;
  r    jsonb;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  cj := (public.crear_caja(e, s2, 'Caja Norte', '001')->>'caja_id')::uuid;
  b3 := (public.crear_bodega(e, s2, 'B3', 'Bodega Norte')->>'bodega_id')::uuid;
  PERFORM pruebas.guardar('B3', b3);
  PERFORM public.cargar_saldo_inicial(e, b3, '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5, 'costo_unitario', 100)), gen_random_uuid());

  -- Con existencias: ni la sucursal ni la bodega.
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_sucursal(%L, %L, %L)', e, s2, 'Se cierra el local'), 'existencias en la bodega B3', 'sucursal con existencias');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_bodega(%L, %L, %L)', e, b3, 'Se cierra la bodega'), 'NO_PERMITIDO', 'bodega con existencias');
  PERFORM pruebas.afirmar((SELECT activa FROM public.sucursal WHERE id = s2), 'la sucursal sigue activa');

  -- Se traslada todo (5 x 100 = 500) y entonces sí.
  PERFORM public.trasladar_inventario(e, b3, pruebas.id('B1'), '2026-01-03',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.existencia('B3', 'P1') = 0 AND pruebas.valor('B3', 'P1') = 0, 'B3 vacía');
  r := public.desactivar_sucursal(e, s2, 'Se cierra el local');
  PERFORM pruebas.afirmar(NOT (r->>'activa')::boolean AND (r->>'cajas_desactivadas')::int = 1, 'sucursal y su caja desactivadas');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, b3, '2026-01-04',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1, 'costo_unitario', 1))), 'BODEGA_INVALIDA', 'bodega de sucursal cerrada');

  -- Valor sin cantidad (dato viejo, a la fuerza): tampoco se desactiva.
  PERFORM pruebas.como('superusuario');
  UPDATE public.inventario_saldo SET valor_centavos = 7 WHERE bodega_id = pruebas.id('B2') AND producto_id = pruebas.id('P1');
  INSERT INTO public.inventario_saldo (empresa_id, bodega_id, producto_id, cantidad, valor_centavos)
  VALUES (e, pruebas.id('B2'), pruebas.id('P3'), 0, 7) ON CONFLICT (bodega_id, producto_id) DO UPDATE SET valor_centavos = 7;
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_bodega(%L, %L, %L)', e, pruebas.id('B2'), 'Bodega sin uso'), 'NO_PERMITIDO', 'bodega con valor sin cantidad');

  -- Reactivar: motivo, permisos y orden (primero la sucursal).
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_sucursal(%L, %L, %L)', e, s2, 'Se reabre el local'), 'SIN_PERMISO', 'cajero reactiva sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_bodega(%L, %L, %L)', e, b3, 'Se reabre la bodega'), 'SIN_PERMISO', 'cajero reactiva bodega');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_sucursal(%L, %L, %L)', e, s2, 'no'), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM public.desactivar_bodega(e, b3, 'Bodega vacía por ahora');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_caja(%L, %L, %L)', e, cj, 'Se reabre la caja'), 'SUCURSAL_INVALIDA', 'caja antes que la sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_bodega(%L, %L, %L)', e, b3, 'Se reabre la bodega'), 'SUCURSAL_INVALIDA', 'bodega antes que la sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_sucursal(%L, %L, %L)', e, gen_random_uuid(), 'Se reabre el local'), 'NO_EXISTE', 'sucursal inventada');
  r := public.reactivar_sucursal(e, s2, 'Se reabre el local');
  PERFORM pruebas.afirmar((r->>'activa')::boolean AND NOT (r->>'ya_estaba')::boolean, 'sucursal reactivada');
  PERFORM pruebas.afirmar((public.reactivar_sucursal(e, s2, 'Se reabre el local')->>'ya_estaba')::boolean, 'reactivar dos veces no hace nada');
  PERFORM public.reactivar_caja(e, cj, 'Se reabre la caja');
  r := public.reactivar_bodega(e, b3, 'Llegó mercadería al norte');
  PERFORM pruebas.afirmar((r->>'activa')::boolean, 'bodega reactivada');
  PERFORM public.cargar_saldo_inicial(e, b3, '2026-01-04',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1, 'costo_unitario', 1)), gen_random_uuid());

  -- Categorías: la hija no se reactiva si la madre está desactivada.
  c1 := (public.crear_categoria(e, 'Herramientas')->>'categoria_id')::uuid;
  c2 := (public.crear_categoria(e, 'Martillos', c1)->>'categoria_id')::uuid;
  PERFORM public.desactivar_categoria(e, c2, 'Reorganizar el catálogo');
  PERFORM public.desactivar_categoria(e, c1, 'Reorganizar el catálogo');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_categoria(%L, %L, %L)', e, c2, 'Vuelve la categoría'), 'madre', 'hija antes que la madre');
  PERFORM public.reactivar_categoria(e, c1, 'Vuelve la categoría');
  PERFORM public.reactivar_categoria(e, c2, 'Vuelve la categoría');
  PERFORM public.editar_producto(e, pruebas.id('P1'), jsonb_build_object('categoria_id', c2));

  -- Campo extra: desactivado no se acepta; reactivado sí.
  ce := (public.crear_campo_extra(e, 'marca', 'Marca', 'texto')->>'campo_extra_id')::uuid;
  PERFORM public.desactivar_campo_extra(e, ce, 'Ya no se usa');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P1'), '{"campos_extra":{"marca":"Truper"}}'), 'CAMPO_EXTRA_INVALIDO', 'campo desactivado');
  PERFORM public.reactivar_campo_extra(e, ce, 'Se vuelve a usar');
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"campos_extra":{"marca":"Truper"}}');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reactivar_campo_extra(%L, %L, %L)', e, ce, 'Se vuelve a usar'), 'SIN_PERMISO', 'vendedor reactiva campo');

  -- Bitácora con motivo.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'sucursal' AND motivo = 'Se reabre el local'
    AND despues->>'activa' = 'true'), 'reactivar sucursal en bitácora');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'bodega' AND motivo = 'Llegó mercadería al norte'), 'reactivar bodega en bitácora');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'campo_extra' AND motivo = 'Se vuelve a usar'), 'reactivar campo en bitácora');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'categoria_producto' AND motivo = 'Vuelve la categoría'), 'reactivar categoría en bitácora');
END $$;
