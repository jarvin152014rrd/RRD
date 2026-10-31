-- PRUEBA: carga inicial de inventario: existencia + costo con asiento contra Saldos de apertura (3.3.01.03), una sola vez por producto y bodega (o con permiso especial y motivo)
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  op uuid := gen_random_uuid();
  r  jsonb;
BEGIN
  PERFORM pruebas.preparar_inventario();

  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'costo_unitario', 1))), 'SIN_PERMISO', 'cajero carga');

  -- Admin: P1 100 x 1000 = 100,000; P3 2 x 30000 = 60,000. Total 160,000.
  PERFORM pruebas.como('admin_a');
  r := public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-01', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000),
         jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 2,   'costo_unitario', 30000)), op);
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 160000 AND r->>'tipo' = 'carga_inicial', 'total 160000');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 160000 AND pruebas.saldo_libros(e, '3.3.01.03') = 160000 AND pruebas.saldo_libros(e, '3.1.01.01') = 0, 'asiento de apertura');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT origen FROM public.asiento WHERE id = (r->>'asiento_id')::uuid) = 'carga_inicial_inventario', 'origen');
  PERFORM pruebas.como('admin_a');

  -- Reintento: no duplica.
  r := public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-01', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000)), op);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean AND pruebas.existencia('B1','P1') = 100, 'reintento');

  -- Segunda vez el mismo producto y bodega: no (para corregir: ajuste).
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5, 'costo_unitario', 1000))), 'SALDO_INICIAL_YA_CARGADO', 'repetir sin permiso');
  -- En otra bodega sí.
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B2'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'costo_unitario', 1000)), gen_random_uuid());

  -- El dueño (permiso especial) sí repite, con motivo: 50 x 1300 = 65,000.
  --   B1: Q 150, V 165,000, promedio 1100.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 50, 'costo_unitario', 1300))), 'FALTA_MOTIVO', 'repetir sin motivo');
  PERFORM public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 50, 'costo_unitario', 1300)), gen_random_uuid(),
    'Faltó contar la bodega de arriba');
  PERFORM pruebas.afirmar(pruebas.existencia('B1','P1') = 150 AND pruebas.valor('B1','P1') = 165000 AND pruebas.promedio('B1','P1') = 1100, 'repetida con permiso');
  -- Libros: 160,000 + 10,000 + 65,000 = 235,000.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.03.01') = 235000 AND pruebas.saldo_libros(e, '3.3.01.03') = 235000, 'apertura total 235000');

  -- Costo 0: entra la existencia, sin asiento.
  r := public.cargar_saldo_inicial(e, pruebas.id('B1'), '2026-01-01',
         jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 3, 'costo_unitario', 0)), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'asiento_id' IS NULL AND pruebas.existencia('B1','P2') = 3, 'costo 0 sin asiento');

  -- Datos malos.
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B2'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1))), 'costo_unitario', 'sin costo');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B2'), '2026-01-01',
    '[]'), 'LINEA_INVALIDA', 'sin líneas');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B2'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'costo_unitario', 5, 'precio', 9))), 'LINEA_INVALIDA', 'campo raro');
  PERFORM public.desactivar_producto(e, pruebas.id('P3'), 'Ya no se vende');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B2'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'costo_unitario', 5))), 'PRODUCTO_INVALIDO', 'producto desactivado');
  PERFORM pruebas.debe_fallar(format('SELECT public.cargar_saldo_inicial(%L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B2'), '2026-01-01',
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.empresa('B'), 'cantidad', 1, 'costo_unitario', 5))), 'PRODUCTO_INVALIDO', 'producto inventado');

  -- Kardex = libros.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'), 'kardex = libros');
END $$;
