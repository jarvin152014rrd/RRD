-- PRUEBA: rol contador de solo lectura (contabilidad, reportes, bitácora, terceros, compras, existencias con costos) que solo crea el dueño y no recibe permisos de movimiento; el proveedor no ve clientes ni proveedores sin soporte vigente
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  cont uuid;
  p    jsonb;
  c    uuid;
  a    jsonb;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (email) VALUES ('contador@prueba.hn') RETURNING id INTO cont;
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('contador', cont);
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');
  PERFORM public.crear_tercero(e, '{"nombre": "Cliente Fiel", "es_cliente": true}', gen_random_uuid());
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-02',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'costo_unitario', 1000)), gen_random_uuid());
  c := (public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'K-1', '2026-01-05', 'credito', 'P1', 5, 1000), gen_random_uuid())->>'compra_id')::uuid;
  a := public.registrar_asiento(e, '2026-01-06', 'Venta del día', pruebas.lineas('1.1.01.01', '4.1.01.01', 5000), gen_random_uuid());

  -- Solo el dueño crea (o toca) al contador.
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'contador@prueba.hn', 'contador'), 'PROHIBIDO', 'admin crea contador');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.agregar_usuario_empresa(e, 'contador@prueba.hn', 'contador', 'Lic. Contador');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_usuario_empresa(%L, %L, %L)', e, cont, 'Ya no trabaja'), 'PROHIBIDO', 'admin desactiva contador');

  -- Lo que ve: lectura de cifras, también costos y valor del inventario.
  PERFORM pruebas.como('contador');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'rol'->>'codigo' = 'contador'
    AND p->'permisos' = '["aprobaciones.ver", "bitacora.ver", "compras.ver", "contabilidad.ver", "dinero.ver", "inventario.costos", "inventario.ver", "terceros.ver"]',
    'permisos del contador: ' || (p->'permisos')::text);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 3, 've asientos');
  PERFORM pruebas.afirmar((SELECT saldo_final_centavos FROM public.saldo_cuentas(e, NULL, '2026-12-31') WHERE codigo = '1.1.03.01') = 15000, 've saldos: inventario 15,000');
  PERFORM pruebas.afirmar((SELECT valor_centavos FROM public.v_existencia WHERE producto_id = pruebas.id('P1')) = 15000
    AND (SELECT costo_promedio FROM public.v_existencia WHERE producto_id = pruebas.id('P1')) = 1000, 've costos y valor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_kardex) = 2, 've el kardex');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cxp_proveedor WHERE proveedor_id = pruebas.id('PROV1')) = 5750, 've CxP: 5,000 + ISV 750');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero WHERE empresa_id = e) = 3, 've clientes y proveedores');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e) > 0, 've la bitácora');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora(e)), 'verifica la bitácora');

  -- Lo que NO hace: nada que mueva los libros ni administre.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-06', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'SIN_PERMISO', 'contador registra');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', a->>'asiento_id', 'Corregir venta'), 'SIN_PERMISO', 'contador anula');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 1)', e), 'SIN_PERMISO', 'contador cierra mes');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e, pruebas.compra('PROV1', 'B1', 'K-2', '2026-01-05', 'credito', 'P1', 1, 1000)), 'SIN_PERMISO', 'contador compra');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, c, '2026-01-06', 'caja'), 'SIN_PERMISO', 'contador paga');
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-06',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 1)), 'Conteo'), 'SIN_PERMISO', 'contador ajusta');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true}'), 'SIN_PERMISO', 'contador crea cliente');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_precio_producto(%L, %L, 1, %L)', e, pruebas.id('P1'), 'precio de amigo'), 'SIN_PERMISO', 'contador cambia precio');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'sin_empresa@prueba.hn', 'cajero'), 'SIN_PERMISO', 'contador agrega usuarios');

  -- Ni el dueño le da permisos de movimiento o de administrar.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'contador', 'asientos.registrar', 'Que ayude a registrar'), 'PROHIBIDO', 'contador con movimiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'contador', 'usuarios.administrar', 'Que agregue usuarios'), 'PROHIBIDO', 'contador administra');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'contador', 'periodos.cerrar', 'Que cierre el mes'), 'PROHIBIDO', 'contador cierra');
  PERFORM public.cambiar_permiso_rol(e, 'contador', 'compras.ver', false, 'No necesita compras');
  PERFORM public.cambiar_permiso_rol(e, 'contador', 'compras.ver', true, 'Sí necesita compras');
  PERFORM public.desactivar_usuario_empresa(e, cont, 'Terminó el contrato');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento) = 0, 'desactivado no ve nada');

  -- Proveedor: sin soporte no ve clientes ni proveedores (ni límites de crédito).
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero) = 0, 'proveedor no ve terceros');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('terceros.ver', e), 'proveedor sin terceros.ver');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.otorgar_acceso_soporte(e, now() + interval '2 hours', 'Revisar proveedores duplicados');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero) = 3, 'con soporte sí los ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true}'), 'SIN_PERMISO', 'con soporte no crea');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.revocar_acceso_soporte(e, 'Ya terminó la revisión');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero) = 0, 'revocado: ya no los ve');

  -- Cajero y vendedor sí ven clientes; si el dueño les quita terceros.ver, no.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero) = 3, 'vendedor ve terceros');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'vendedor', 'terceros.ver', false, 'Solo el cajero ve clientes');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero) = 0, 'sin el permiso no los ve');
END $$;
