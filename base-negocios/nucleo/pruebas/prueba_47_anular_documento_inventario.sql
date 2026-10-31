-- PRUEBA: anular carga inicial, ajuste y traslado (cifras a mano): contra-movimientos en el kardex y contra-asiento (la carga vuelve contra apertura), solo sin movimientos posteriores, una vez, con motivo, mes abierto y costos ocultos a quien no los ve
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  c1  jsonb; c2 jsonb; a1 jsonb; t1 jsonb; t2 jsonb; t3 jsonb; t4 jsonb;
  op  uuid := gen_random_uuid();
  r   jsonb;
  x   public.asiento;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');

  -- 1) Carga inicial C1 en B1: P1 100 x 1000 = 100,000; P3 2 x 30,000 = 60,000. Total 160,000.
  c1 := public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-02', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000),
          jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 2, 'costo_unitario', 30000)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 160000 AND pruebas.saldo_libros(e, '3.3.01.03') = 160000, 'C1 en libros');

  -- Validaciones.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', c1->>'documento_id', 'Costos mal puestos'), 'SIN_PERMISO', 'cajero anula');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', c1->>'documento_id', 'no'), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid(), %L)', c1->>'documento_id', 'Costos mal puestos', '2026-01-01'), 'FECHA_INVALIDA', 'antes del documento');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, NULL)', c1->>'documento_id', 'Costos mal puestos'), 'FALTA_ID_OPERACION', 'sin id_operacion');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', gen_random_uuid(), 'Costos mal puestos'), 'NO_EXISTE', 'documento inventado');

  -- 2) Anular C1: salen 100 (100,000) y 2 (60,000). Dr 3.3.01.03 160,000 / Cr 1.1.03.01 160,000.
  r := public.anular_documento_inventario((c1->>'documento_id')::uuid, 'Costos mal puestos', op, '2026-01-03');
  PERFORM pruebas.afirmar((r->>'valor_revertido_centavos')::bigint = -160000 AND (r->>'ajuste_costo_centavos')::bigint = 0, 'C1 anulada: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 0 AND pruebas.valor('B1', 'P1') = 0
    AND pruebas.existencia('B1', 'P3') = 0 AND pruebas.valor('B1', 'P3') = 0, 'kardex vuelve a cero');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 0 AND pruebas.saldo_libros(e, '3.3.01.03') = 0
    AND pruebas.saldo_libros(e, '5.1.01.02') = 0, 'vuelve contra apertura, no contra gasto');
  PERFORM pruebas.como('superusuario');
  SELECT * INTO x FROM public.asiento WHERE id = (r->>'asiento_id')::uuid;
  PERFORM pruebas.afirmar(x.origen = 'anulacion_carga_inicial_inventario' AND x.anula_asiento_id = (c1->>'asiento_id')::uuid, 'contra-asiento enlazado');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ' ' ORDER BY l.linea)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = x.id)
                          = '3.3.01.03:160000/0 1.1.03.01:0/160000', 'líneas: ' || (SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ' ' ORDER BY l.linea)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = x.id));
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'inventario_documento_anulacion' AND motivo = 'Costos mal puestos'), 'en bitácora');
  PERFORM pruebas.debe_fallar('UPDATE public.inventario_documento_anulacion SET motivo = ''x''', 'PROHIBIDO', 'editar anulación');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar((public.anular_documento_inventario((c1->>'documento_id')::uuid, 'Costos mal puestos', op, '2026-01-03')->>'duplicado')::boolean, 'reintento');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', c1->>'documento_id', 'Otra vez'), 'YA_ANULADO', 'anular dos veces');

  -- 3) Anulada la carga, se vuelve a cargar sin el permiso de repetir (el admin no lo tiene).
  --    C2: P1 100 x 1100 = 110,000; P3 2 x 30,000 = 60,000.
  c2 := public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-03', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1100),
          jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 2, 'costo_unitario', 30000)), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 170000, 'C2 = 170,000');

  -- 4) Ajuste A1 en B1: P1 contada 97 (faltan 3 x 1100 = 3,300); P3 contada 3 a 31,000 (sobra 1 = 31,000).
  a1 := public.ajustar_inventario(e, pruebas.id('B1'), '2026-01-05', jsonb_build_array(
          jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 97),
          jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad_contada', 3, 'costo_unitario', 31000)), 'Conteo de enero', gen_random_uuid());
  PERFORM pruebas.afirmar((a1->>'faltante_centavos')::bigint = 3300 AND (a1->>'sobrante_centavos')::bigint = 31000, 'A1: ' || a1::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 197700 AND pruebas.saldo_libros(e, '5.1.01.02') = 3300
    AND pruebas.saldo_libros(e, '4.2.01.02') = 31000, 'A1 en libros: 170,000 - 3,300 + 31,000 = 197,700');
  -- Anular A1: P3 sale 1 a 31,000 (queda 2 / 60,000); P1 entra 3 a 3,300 (queda 100 / 110,000).
  --   Dr 4.2.01.02 31,000 / Cr 1.1.03.01 31,000; Dr 1.1.03.01 3,300 / Cr 5.1.01.02 3,300.
  r := public.anular_documento_inventario((a1->>'documento_id')::uuid, 'Se contó mal la bodega', gen_random_uuid(), '2026-01-06');
  PERFORM pruebas.afirmar((r->>'valor_revertido_centavos')::bigint = -27700, 'neto 3,300 - 31,000 = -27,700');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 100 AND pruebas.valor('B1', 'P1') = 110000 AND pruebas.promedio('B1', 'P1') = 1100
    AND pruebas.existencia('B1', 'P3') = 2 AND pruebas.valor('B1', 'P3') = 60000 AND pruebas.promedio('B1', 'P3') = 30000, 'kardex como antes del ajuste');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 170000 AND pruebas.saldo_libros(e, '5.1.01.02') = 0
    AND pruebas.saldo_libros(e, '4.2.01.02') = 0, 'libros como antes del ajuste');

  -- 5) Traslado T1 B1 -> B2: 30 x 1100 = 33,000. Anularlo: vuelve sin asiento.
  t1 := public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-07',
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 30)), gen_random_uuid());
  r := public.anular_documento_inventario((t1->>'documento_id')::uuid, 'Era para la otra sucursal', gen_random_uuid(), '2026-01-07');
  PERFORM pruebas.afirmar(r->>'asiento_id' IS NULL AND (r->>'valor_revertido_centavos')::bigint = 0, 'traslado sin asiento');
  PERFORM pruebas.afirmar(pruebas.existencia('B2', 'P1') = 0 AND pruebas.valor('B2', 'P1') = 0
    AND pruebas.existencia('B1', 'P1') = 100 AND pruebas.valor('B1', 'P1') = 110000, 'traslado deshecho');

  -- 6) Con movimientos posteriores, no: T2 y luego un ajuste en B2.
  t2 := public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-08',
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10)), gen_random_uuid());
  PERFORM public.ajustar_inventario(e, pruebas.id('B2'), '2026-01-08',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad_contada', 9)), 'Se rompió uno', gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', t2->>'documento_id', 'Traslado equivocado'),
    'MOVIMIENTOS_POSTERIORES', 'traslado con movimientos posteriores');
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-50', '2026-01-09', 'credito', 'P3', 1, 30000), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', c2->>'documento_id', 'Carga equivocada'),
    'MOVIMIENTOS_POSTERIORES', 'carga con compras posteriores');

  -- 7) Quien no ve costos: la respuesta llega sin montos.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'inventario.trasladar', true, 'Cajero mueve mercadería');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'inventario.anular', true, 'Cajero corrige traslados');
  PERFORM pruebas.como('cajero_a');
  t3 := public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-10',
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)), gen_random_uuid());
  PERFORM pruebas.afirmar(t3 ? 'total_centavos' AND t3->'total_centavos' = 'null'::jsonb AND (t3->>'costos_ocultos')::boolean, 'traslado sin costo: ' || t3::text);
  r := public.anular_documento_inventario((t3->>'documento_id')::uuid, 'Me equivoqué de bodega', gen_random_uuid(), '2026-01-10');
  PERFORM pruebas.afirmar(r->'valor_revertido_centavos' = 'null'::jsonb AND (r->>'costos_ocultos')::boolean, 'anulación sin costo');

  -- 8) Mes cerrado: con fecha de enero no; con la de hoy sí.
  PERFORM pruebas.como('admin_a');
  t4 := public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B2'), '2026-01-20',
          jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5)), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cerrar_periodo(e, 2026, 1);
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid(), %L)', t4->>'documento_id', 'Traslado repetido', '2026-01-21'),
    'PERIODO_CERRADO', 'anular en mes cerrado');
  r := public.anular_documento_inventario((t4->>'documento_id')::uuid, 'Traslado repetido', gen_random_uuid());
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean, 'anulado con fecha de hoy');

  -- Cuadre: kardex = libros; saldo = suma del kardex; bitácora intacta.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'), 'kardex = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.inventario_saldo s
     LEFT JOIN (SELECT m.bodega_id, m.producto_id, sum(m.cantidad) AS q, sum(m.valor_centavos) AS v
                  FROM public.inventario_movimiento m GROUP BY 1, 2) k
            ON k.bodega_id = s.bodega_id AND k.producto_id = s.producto_id
     WHERE (s.cantidad, s.valor_centavos) IS DISTINCT FROM (coalesce(k.q, 0), coalesce(k.v, 0))), 'saldo = suma del kardex');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
