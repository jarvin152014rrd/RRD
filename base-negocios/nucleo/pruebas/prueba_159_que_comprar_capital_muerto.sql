-- PRUEBA: (0.21.0) ¿Qué comprar más? y Capital muerto (solo leen): cifras hechas a mano (vendido neto de devoluciones,
-- por día, para cuántos días alcanza, cuánto pedir para cubrir los días o llegar al mínimo, costo aproximado), los
-- servicios no salen, un producto nuevo no es "capital muerto", días fuera de 7-365 se rechazan, otra empresa no entra,
-- sin inventario.costos los costos llegan en blanco y no se guarda ni cambia nada.
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  r      jsonb;
  f      jsonb;
  antes  bigint;
  despues bigint;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de reportes de inventario');
  -- Compra inicial (preparar_ventas): P1 100 tornillos a L 10.00, P2 50 a L 15.00, P3 10 a L 300.00 (bodega B1). Mínimo de P1: 50.
  -- Hoy: se venden 60 tornillos (dos ventas de 30) y se devuelven 0. Servicio S1: 2 horas (no sale).
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 30, 'efectivo'), gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 30, 'efectivo'), gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('S1', 2, 'efectivo'), gen_random_uuid());
  antes := (SELECT count(*) FROM public.bitacora);

  -- 1) ¿Qué comprar más? en 30 días, para cubrir 30 días.
  --    P1: vendido 60 -> 2 por día; hay 40 -> alcanza 20 días; pedir = max(2*30 - 40, 50 - 40) = 20; bajo el mínimo (40 < 50).
  --    costo aproximado = 40 tornillos valen 40,000 -> 1,000 c/u -> 20 * 1,000 = 20,000.
  r := public.que_comprar(e, 30, 30);
  f := (SELECT x FROM jsonb_array_elements(r->'filas') x WHERE x->>'producto_id' = pruebas.id('P1')::text);
  PERFORM pruebas.afirmar(f IS NOT NULL, 'P1 sale en qué comprar');
  PERFORM pruebas.afirmar((f->>'vendido')::numeric = 60 AND (f->>'ventas')::integer = 2, 'vendido 60 en 2 ventas: ' || f::text);
  PERFORM pruebas.afirmar((f->>'por_dia')::numeric = 2 AND (f->>'hay')::numeric = 40 AND (f->>'dias_alcanza')::integer = 20, 'por día 2, hay 40, alcanza 20 días');
  PERFORM pruebas.afirmar((f->>'pedir')::numeric = 20 AND f->>'estado' = 'bajo_minimo', 'pedir 20 y bajo el mínimo: ' || f::text);
  PERFORM pruebas.afirmar((f->>'costo_aprox_centavos')::bigint = 20000, 'costo aproximado 20,000');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'filas') x WHERE x->>'producto_id' = pruebas.id('S1')::text), 'el servicio no sale');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'filas') x WHERE x->>'producto_id' = pruebas.id('P2')::text), 'P2 (sin ventas y sobre el mínimo) no sale');
  PERFORM pruebas.afirmar((r->'total'->>'por_pedir')::integer >= 1 AND r->>'dias' = '30', 'totales');
  -- Para cubrir 60 días: pedir = 2*60 - 40 = 80.
  f := (SELECT x FROM jsonb_array_elements(public.que_comprar(e, 30, 60)->'filas') x WHERE x->>'producto_id' = pruebas.id('P1')::text);
  PERFORM pruebas.afirmar((f->>'pedir')::numeric = 80, 'para 60 días pedir 80: ' || f::text);
  -- Una devolución de 10 tornillos: vendido neto 50 -> 1.667 por día; hay 50; pedir = max(50 - 50, 50 - 50) = 0.
  PERFORM public.registrar_devolucion(
    (SELECT v.id FROM public.venta v JOIN public.venta_linea l ON l.venta_id = v.id WHERE v.empresa_id = e AND l.producto_id = pruebas.id('P1') ORDER BY v.numero LIMIT 1),
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":10}]'::jsonb, 'motivo', 'Prueba: devolvió 10 tornillos',
      'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  f := (SELECT x FROM jsonb_array_elements(public.que_comprar(e, 30, 30)->'filas') x WHERE x->>'producto_id' = pruebas.id('P1')::text);
  PERFORM pruebas.afirmar((f->>'vendido')::numeric = 50 AND (f->>'hay')::numeric = 50 AND (f->>'pedir')::numeric = 0, 'neto de la devolución: ' || f::text);

  -- 2) Capital muerto: hoy nadie (todo se compró hoy: los productos son nuevos).
  r := public.capital_muerto(e, 90);
  PERFORM pruebas.afirmar((r->'total'->>'productos')::integer = 0, 'productos nuevos no son capital muerto: ' || r::text);
  -- Como si P2 y P3 existieran desde hace 120 días (nunca vendidos) y P1 también (pero se vendió hoy).
  PERFORM pruebas.como('superusuario');
  -- Solo en la prueba: se apagan los triggers un momento (la fecha de creación está protegida) para simular el tiempo.
  PERFORM set_config('session_replication_role', 'replica', true);
  UPDATE public.producto SET creado_en = now() - interval '120 days' WHERE id IN (pruebas.id('P1'), pruebas.id('P2'), pruebas.id('P3'));
  PERFORM set_config('session_replication_role', 'origin', true);
  PERFORM pruebas.como('dueno_a');
  r := public.capital_muerto(e, 90);
  PERFORM pruebas.afirmar((r->'total'->>'productos')::integer = 2, 'P2 y P3 son capital muerto: ' || r::text);
  -- Valor: P2 50 * 1,500 = 75,000; P3 10 * 30,000 = 300,000 -> 375,000; ordenados por valor (P3 primero).
  PERFORM pruebas.afirmar((r->'total'->>'valor_centavos')::bigint = 375000, 'valor parado 375,000');
  PERFORM pruebas.afirmar(r->'filas'->0->>'producto_id' = pruebas.id('P3')::text AND (r->'filas'->0->>'valor_centavos')::bigint = 300000, 'P3 primero');
  PERFORM pruebas.afirmar(r->'filas'->0->>'ultima_venta' IS NULL AND (r->'filas'->0->>'dias_sin_vender')::integer >= 119, 'nunca vendido, 120 días');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'filas') x WHERE x->>'producto_id' = pruebas.id('P1')::text), 'P1 se vendió hoy');

  -- 3) Reglas.
  PERFORM pruebas.debe_fallar(format('SELECT public.que_comprar(%L, 3, 30)', e), 'DIAS_INVALIDOS', 'menos de 7 días');
  PERFORM pruebas.debe_fallar(format('SELECT public.capital_muerto(%L, 400)', e), 'DIAS_INVALIDOS', 'más de 365 días');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.que_comprar(%L)', e), 'NO_PERTENECE', 'otra empresa no entra');
  PERFORM pruebas.debe_fallar(format('SELECT public.capital_muerto(%L)', e), 'NO_PERTENECE', 'otra empresa no entra (capital muerto)');
  -- Sin inventario.costos (el vendedor, si ve inventario): los costos no llegan.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'vendedor', 'inventario.ver', true, 'Prueba: el vendedor ve inventario');
  PERFORM pruebas.como('vendedor_a');
  IF NOT public.puede_leer(e, 'inventario.costos') THEN
    r := public.capital_muerto(e, 90);
    PERFORM pruebas.afirmar(r->>'costos_ocultos' = 'true' AND r->'total'->>'valor_centavos' IS NULL AND r->'filas'->0->>'valor_centavos' IS NULL, 'sin costos: ' || r::text);
    r := public.que_comprar(e);
    PERFORM pruebas.afirmar(r->>'costos_ocultos' = 'true' AND r->'total'->>'costo_aprox_centavos' IS NULL
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'filas') x WHERE x->>'costo_aprox_centavos' IS NOT NULL), 'qué comprar sin costos');
  END IF;

  -- 4) No escribe nada (bitácora igual, salvo la devolución y el cambio de permiso de arriba).
  PERFORM pruebas.como('dueno_a');
  despues := (SELECT count(*) FROM public.bitacora);
  PERFORM public.que_comprar(e); PERFORM public.capital_muerto(e);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora) = despues, 'leer no escribe en la bitácora');
  PERFORM pruebas.afirmar(despues > antes, 'la bitácora sigue viva');
END $$;
