-- PRUEBA: rendimiento de RLS: ninguna política llama tiene_permiso() por fila; el filtro por permiso se calcula una vez por consulta (InitPlan) y existen los índices de empresa, fechas y producto/bodega
DO $$
DECLARE
  r     record;
  plan  text := '';
  linea text;
BEGIN
  -- Ninguna política de public usa tiene_permiso() (se evaluaría por cada fila).
  FOR r IN SELECT tablename, qual FROM pg_policies WHERE schemaname = 'public' AND qual LIKE '%tiene_permiso%' LOOP
    RAISE EXCEPTION 'FALLA: la política de % llama tiene_permiso por fila: %', r.tablename, r.qual;
  END LOOP;
  -- Las tablas con cifras filtran con empresas_con_permiso dentro de ARRAY(SELECT ...).
  FOR r IN SELECT t FROM unnest(ARRAY['asiento', 'asiento_linea', 'bitacora', 'tercero', 'inventario_alerta', 'inventario_saldo',
             'inventario_movimiento', 'inventario_documento', 'inventario_documento_linea', 'inventario_documento_anulacion',
             'compra', 'compra_linea', 'pago_proveedor', 'pago_proveedor_anulacion', 'cxp_saldo_inicial']) AS t LOOP
    PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = r.t
      AND p.qual LIKE '%ANY (ARRAY( SELECT empresas_con_permiso(%'), 'política de ' || r.t);
  END LOOP;
  PERFORM pruebas.afirmar(pg_get_viewdef('public.v_existencia'::regclass) NOT LIKE '%puede_leer%', 'v_existencia sin llamadas por fila');

  -- El plan como usuario: InitPlan (una vez) y sin SubPlan por fila.
  PERFORM pruebas.como('dueno_a');
  FOR linea IN EXECUTE 'EXPLAIN SELECT count(*) FROM public.asiento_linea' LOOP
    plan := plan || linea || E'\n';
  END LOOP;
  PERFORM pruebas.afirmar(plan LIKE '%InitPlan%' AND plan NOT LIKE '%SubPlan%', 'asiento_linea: ' || plan);
  plan := '';
  FOR linea IN EXECUTE 'EXPLAIN SELECT costo_promedio, valor_centavos FROM public.v_existencia' LOOP
    plan := plan || linea || E'\n';
  END LOOP;
  PERFORM pruebas.afirmar(plan LIKE '%InitPlan%' AND plan NOT LIKE '%SubPlan%', 'v_existencia: ' || plan);
  PERFORM pruebas.como('superusuario');

  -- Índices nuevos.
  FOR r IN SELECT i FROM unnest(ARRAY['inventario_mov_bodega_producto', 'inventario_mov_salidas_fecha', 'inventario_mov_empresa_fecha',
             'inventario_doc_empresa_fecha', 'inventario_alerta_empresa', 'compra_empresa_fecha', 'compra_anulacion_operacion',
             'pago_proveedor_empresa_fecha', 'pago_proveedor_proveedor', 'pago_proveedor_saldo_inicial', 'asiento_empresa_origen',
             'cxp_saldo_inicial_proveedor', 'cxp_saldo_inicial_factura']) AS i LOOP
    PERFORM pruebas.afirmar(to_regclass('public.' || r.i) IS NOT NULL, 'índice ' || r.i);
  END LOOP;
END $$;
