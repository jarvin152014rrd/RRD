-- PRUEBA: un id_operacion solo se reconoce como reintento si es del mismo tipo de operación (si no, ID_OPERACION_USADO); la anulación de un asiento no tiene fecha anterior al original; las RPC no devuelven costos a quien no tiene inventario.costos
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  x   uuid := gen_random_uuid();
  y   uuid := gen_random_uuid();
  z   uuid := gen_random_uuid();
  w   uuid := gen_random_uuid();
  t   uuid := gen_random_uuid();
  c   jsonb; a jsonb; r jsonb; tr jsonb; pg jsonb;
  hoy date;
BEGIN
  PERFORM pruebas.preparar_inventario();
  hoy := public.hoy_local(e);
  PERFORM pruebas.como('dueno_a');

  -- ===== id_operacion por tipo =====
  a  := public.registrar_asiento(e, '2026-01-15', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), x);
  PERFORM pruebas.afirmar((public.registrar_asiento(e, '2026-01-15', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), x)->>'duplicado')::boolean,
    'mismo tipo: reintento');
  c  := public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'OP-1', '2026-01-10', 'credito', 'P1', 10, 1000), y);
  tr := public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-11',
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)), z);
  pg := public.pagar_proveedor(e, (c->>'compra_id')::uuid, 1000, '2026-01-12', 'caja', w);
  PERFORM public.crear_tercero(e, '{"nombre": "Cliente T", "es_cliente": true}', t);

  -- Antes, un asiento manual con el id de una compra devolvía el asiento de la compra como "duplicado".
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-15', pruebas.lineas('1.1.01.01', '4.1.01.01', 1), y), 'ID_OPERACION_USADO', 'asiento con id de compra');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, %L)', e,
    pruebas.compra('PROV1', 'B1', 'OP-2', '2026-01-15', 'credito', 'P1', 1, 1000), x), 'ID_OPERACION_USADO', 'compra con id de asiento');
  -- Antes, un ajuste con el id de un traslado devolvía el traslado como "duplicado".
  PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, %L)', e, pruebas.id('B1'), '2026-01-15',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 1)), 'Conteo', z), 'ID_OPERACION_USADO', 'ajuste con id de traslado');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, %L)', e, pruebas.id('B1'), '2026-01-15',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1, 'costo_unitario', 1)), z), 'ID_OPERACION_USADO', 'carga con id de traslado');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, %L)', e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-15',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)), y), 'ID_OPERACION_USADO', 'traslado con id de compra');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, %L)', e, c->>'compra_id', '2026-01-15', 'caja', y), 'ID_OPERACION_USADO', 'pago con id de compra');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, %L)', pg->>'pago_id', 'Pago equivocado', w), 'ID_OPERACION_USADO', 'anular pago con id del pago');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, %L)', c->>'compra_id', 'Compra equivocada', y), 'ID_OPERACION_USADO', 'anular compra con id de la compra');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L, %L)', a->>'asiento_id', 'Venta equivocada', x), 'ID_OPERACION_USADO', 'anular asiento con id del asiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, %L)', tr->>'documento_id', 'Traslado equivocado', z), 'ID_OPERACION_USADO', 'anular traslado con su id');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, %L)', e, '{"codigo":"N1","nombre":"N"}', t), 'ID_OPERACION_USADO', 'producto con id de tercero');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, %L)', e, '{"nombre":"N","es_cliente":true}', w), 'ID_OPERACION_USADO', 'tercero con id de pago');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, %L)', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'S-1', 'fecha_documento', '2026-01-01', 'monto_centavos', 5, 'fecha', '2026-01-01'), x),
    'ID_OPERACION_USADO', 'saldo inicial con id de asiento');
  -- Los reintentos del mismo tipo siguen igual.
  PERFORM pruebas.afirmar((public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'OP-1', '2026-01-10', 'credito', 'P1', 10, 1000), y)->>'duplicado')::boolean, 'reintento de compra');
  PERFORM pruebas.afirmar((public.pagar_proveedor(e, (c->>'compra_id')::uuid, 1000, '2026-01-12', 'caja', w)->>'duplicado')::boolean, 'reintento de pago');
  PERFORM pruebas.afirmar((public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-11',
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)), z)->>'duplicado')::boolean, 'reintento de traslado');
  -- Cada empresa tiene sus propios id: en B el id de la compra de A es libre.
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar(NOT (public.registrar_asiento(pruebas.empresa('B'), '2026-01-15', 'Venta B', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), y)->>'duplicado')::boolean,
    'en otra empresa el id está libre');

  -- ===== Fecha de la anulación de un asiento =====
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L, NULL, %L)', a->>'asiento_id', 'Venta equivocada', '2026-01-14'), 'FECHA_INVALIDA', 'anulación antes del asiento');
  r := public.anular_asiento((a->>'asiento_id')::uuid, 'Venta equivocada', NULL, '2026-01-15');
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean, 'el mismo día sí');
  -- Asiento con fecha futura (hoy + 2): sin fecha, la anulación toma la del asiento, no la de hoy.
  a := public.registrar_asiento(e, hoy + 2, 'Cheque posfechado', pruebas.lineas('1.1.01.03', '4.1.01.01', 500), gen_random_uuid());
  r := public.anular_asiento((a->>'asiento_id')::uuid, 'Cheque devuelto');
  PERFORM pruebas.afirmar((SELECT fecha_contable FROM public.asiento WHERE id = (r->>'asiento_id')::uuid) = hoy + 2, 'anulación con la fecha del asiento futuro');

  -- ===== Costos ocultos =====
  -- El dueño da al cajero ajustar, carga inicial y anular compras, pero no inventario.costos.
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'inventario.ajustar', true, 'Cajero hace conteos');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'inventario.carga_inicial', true, 'Cajero carga existencias');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'compras.anular', true, 'Cajero devuelve mercadería');
  c := public.registrar_compra(e, pruebas.compra('PROV2', 'B2', 'OC-1', '2026-01-16', 'contado', 'P3', 1, 30000, 'caja'), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  y := gen_random_uuid();
  r := public.ajustar_inventario(e, pruebas.id('B1'), '2026-01-16',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 7)), 'Conteo del cajero', y);
  PERFORM pruebas.afirmar(r->'faltante_centavos' = 'null'::jsonb AND r->'sobrante_centavos' = 'null'::jsonb AND r->'total_centavos' = 'null'::jsonb
    AND (r->>'costos_ocultos')::boolean AND r->>'documento_id' IS NOT NULL, 'ajuste sin montos: ' || r::text);
  r := public.ajustar_inventario(e, pruebas.id('B1'), '2026-01-16',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 7)), 'Conteo del cajero', y);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean AND r->'faltante_centavos' = 'null'::jsonb, 'reintento también sin montos');
  r := public.cargar_saldo_inicial(e, pruebas.id('B2'), '2026-01-16',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 3, 'costo_unitario', 2000)), gen_random_uuid());
  PERFORM pruebas.afirmar(r->'total_centavos' = 'null'::jsonb, 'carga sin total');
  r := public.anular_compra((c->>'compra_id')::uuid, 'Devuelta al proveedor', gen_random_uuid(), '2026-01-16');
  PERFORM pruebas.afirmar(r->'ajuste_costo_centavos' = 'null'::jsonb AND r->>'asiento_id' IS NOT NULL, 'anulación de compra sin ajuste de costo');
  -- El admin (con costos) sí los recibe.
  PERFORM pruebas.como('admin_a');
  r := public.ajustar_inventario(e, pruebas.id('B1'), '2026-01-16',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 6)), 'Conteo del admin', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'faltante_centavos')::bigint = 1000 AND NOT r ? 'costos_ocultos', 'admin ve el faltante (1 x 1000)');
END $$;
