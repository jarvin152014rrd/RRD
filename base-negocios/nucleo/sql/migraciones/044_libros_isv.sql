-- =====================================================================
-- 044_libros_isv.sql  -  Núcleo 0.11.0 (etapa 3b-1): libros de ventas y de compras
-- del ISV por mes (régimen fiscal_hn; contabilidad.ver).
--
--   libro_ventas(empresa, año, mes)    facturas y tickets emitidos, notas de crédito
--                                      y anulaciones de ventas de meses anteriores.
--   libro_compras(empresa, año, mes)   compras y gastos CON factura (y sus anulaciones
--                                      de meses anteriores).
--   libros_isv(empresa, año, mes)      los dos juntos y el cuadre.
--
-- Columnas: fecha, tipo, número de documento, CAI, RTN, nombre, base gravada 15 %,
-- base gravada 18 %, base de otra tasa, exento, exonerado, ISV 15 %, ISV 18 %, ISV de
-- otra tasa, ISV total y total. Una fila por documento, con la fecha de su asiento:
--   - emitido y anulado en el mismo mes: una fila en cero marcada "ANULADA";
--   - anulado en un mes posterior: en ese mes una fila "anulacion" en negativo;
--   - nota de crédito: en negativo, con la factura que corrige.
-- Así el total del ISV del libro = débito (ventas) o crédito (compras) fiscal de
-- isv_mes, que sale de los asientos del sistema. Montos en centavos, fechas ISO.
-- El FORMATO lo debe validar un contador hondureño antes de presentarlo a la SAR.
-- =====================================================================

-- Reparte un desglose [{porcentaje, clase, base_centavos, impuesto_centavos}] en las
-- columnas del libro (signo -1 para notas de crédito y anulaciones; 0 = anulada).
CREATE FUNCTION interno.columnas_isv(p_desglose jsonb, p_signo integer) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH d AS (
    SELECT coalesce(x->>'clase', 'gravado') AS clase, coalesce((x->>'porcentaje')::numeric, 0) AS pct,
           coalesce((x->>'base_centavos')::bigint, 0) * p_signo AS base, coalesce((x->>'impuesto_centavos')::bigint, 0) * p_signo AS isv
      FROM jsonb_array_elements(coalesce(p_desglose, '[]')) x)
  SELECT jsonb_build_object(
    'base_15_centavos',        coalesce(sum(base) FILTER (WHERE clase = 'gravado' AND pct = 15), 0),
    'base_18_centavos',        coalesce(sum(base) FILTER (WHERE clase = 'gravado' AND pct = 18), 0),
    'base_otra_tasa_centavos', coalesce(sum(base) FILTER (WHERE clase = 'gravado' AND pct NOT IN (15, 18)), 0),
    'exento_centavos',         coalesce(sum(base) FILTER (WHERE clase = 'exento'), 0),
    'exonerado_centavos',      coalesce(sum(base) FILTER (WHERE clase = 'exonerado'), 0),
    'isv_15_centavos',         coalesce(sum(isv) FILTER (WHERE clase = 'gravado' AND pct = 15), 0),
    'isv_18_centavos',         coalesce(sum(isv) FILTER (WHERE clase = 'gravado' AND pct = 18), 0),
    'isv_otra_tasa_centavos',  coalesce(sum(isv) FILTER (WHERE clase = 'gravado' AND pct NOT IN (15, 18)), 0),
    'isv_centavos',            coalesce(sum(isv), 0),
    'total_centavos',          coalesce(sum(base + isv), 0))
  FROM d
$$;

-- Las columnas en el orden del libro (para el encabezado del CSV / Excel).
CREATE FUNCTION interno.columnas_libro(p_tercero text) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_array(
    jsonb_build_object('clave', 'fecha', 'titulo', 'Fecha'),
    jsonb_build_object('clave', 'tipo_documento', 'titulo', 'Tipo'),
    jsonb_build_object('clave', 'numero_documento', 'titulo', 'Número de documento'),
    jsonb_build_object('clave', 'cai', 'titulo', 'CAI'),
    jsonb_build_object('clave', 'rtn', 'titulo', 'RTN del ' || p_tercero),
    jsonb_build_object('clave', 'nombre', 'titulo', 'Nombre del ' || p_tercero),
    jsonb_build_object('clave', 'base_15_centavos', 'titulo', 'Gravado 15 %'),
    jsonb_build_object('clave', 'base_18_centavos', 'titulo', 'Gravado 18 %'),
    jsonb_build_object('clave', 'base_otra_tasa_centavos', 'titulo', 'Gravado otra tasa'),
    jsonb_build_object('clave', 'exento_centavos', 'titulo', 'Exento'),
    jsonb_build_object('clave', 'exonerado_centavos', 'titulo', 'Exonerado'),
    jsonb_build_object('clave', 'isv_15_centavos', 'titulo', 'ISV 15 %'),
    jsonb_build_object('clave', 'isv_18_centavos', 'titulo', 'ISV 18 %'),
    jsonb_build_object('clave', 'isv_otra_tasa_centavos', 'titulo', 'ISV otra tasa'),
    jsonb_build_object('clave', 'isv_centavos', 'titulo', 'ISV total'),
    jsonb_build_object('clave', 'total_centavos', 'titulo', 'Total'),
    jsonb_build_object('clave', 'estado', 'titulo', 'Estado'),
    jsonb_build_object('clave', 'documento_referencia', 'titulo', 'Documento que corrige'))
$$;

-- Totales de una lista de filas.
CREATE FUNCTION interno.totales_libro(p_filas jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_object_agg(k, (SELECT coalesce(sum((f->>k)::bigint), 0) FROM jsonb_array_elements(p_filas) f))
    FROM unnest(ARRAY['base_15_centavos', 'base_18_centavos', 'base_otra_tasa_centavos', 'exento_centavos', 'exonerado_centavos',
                      'isv_15_centavos', 'isv_18_centavos', 'isv_otra_tasa_centavos', 'isv_centavos', 'total_centavos']) k
$$;

-- Filas del libro de ventas del período.
CREATE FUNCTION interno.filas_libro_ventas(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH f AS (
    -- Ventas emitidas en el período (anuladas en el mismo período: fila en cero).
    SELECT a.fecha_contable AS fecha, v.tipo_documento AS tipo, v.numero_documento AS numero, v.datos_fiscales->>'cai' AS cai,
           v.cliente_rtn AS rtn, v.cliente_nombre AS nombre,
           interno.columnas_isv(v.desglose_impuestos, CASE WHEN aa.fecha_contable BETWEEN p_desde AND p_hasta THEN 0 ELSE 1 END) AS col,
           CASE WHEN aa.fecha_contable BETWEEN p_desde AND p_hasta THEN 'ANULADA' ELSE 'vigente' END AS estado,
           NULL::text AS referencia, v.id AS documento_id
      FROM public.venta v JOIN public.asiento a ON a.id = v.asiento_id
      LEFT JOIN public.asiento aa ON aa.id = v.asiento_anulacion_id
     WHERE v.empresa_id = p_empresa_id AND a.fecha_contable BETWEEN p_desde AND p_hasta
    UNION ALL
    -- Ventas de meses anteriores anuladas en este período: en negativo.
    SELECT aa.fecha_contable, 'anulacion', v.numero_documento, v.datos_fiscales->>'cai', v.cliente_rtn, v.cliente_nombre,
           interno.columnas_isv(v.desglose_impuestos, -1), 'anulacion', v.numero_documento, v.id
      FROM public.venta v JOIN public.asiento a ON a.id = v.asiento_id JOIN public.asiento aa ON aa.id = v.asiento_anulacion_id
     WHERE v.empresa_id = p_empresa_id AND aa.fecha_contable BETWEEN p_desde AND p_hasta AND a.fecha_contable < p_desde
    UNION ALL
    -- Notas de crédito (devoluciones aplicadas): en negativo.
    SELECT a.fecha_contable, coalesce(d.tipo_documento, 'nota_credito'), d.numero_documento, d.datos_fiscales->>'cai',
           v.cliente_rtn, d.cliente_nombre,
           interno.columnas_isv((SELECT jsonb_agg(x || jsonb_build_object('clase', coalesce(i.clase, 'gravado')))
                                   FROM jsonb_array_elements(d.desglose_impuestos) x
                                   LEFT JOIN public.impuesto i ON i.empresa_id = d.empresa_id AND i.codigo = x->>'codigo'), -1),
           'vigente', v.numero_documento, d.id
      FROM public.devolucion d JOIN public.asiento a ON a.id = d.asiento_id JOIN public.venta v ON v.id = d.venta_id
     WHERE d.empresa_id = p_empresa_id AND d.estado = 'aplicada' AND a.fecha_contable BETWEEN p_desde AND p_hasta)
  SELECT coalesce(jsonb_agg(jsonb_build_object('fecha', to_char(f.fecha, 'YYYY-MM-DD'), 'tipo_documento', f.tipo,
           'numero_documento', f.numero, 'cai', f.cai, 'rtn', f.rtn, 'nombre', f.nombre, 'estado', f.estado,
           'documento_referencia', f.referencia, 'documento_id', f.documento_id) || f.col
           ORDER BY f.fecha, f.numero, f.tipo), '[]')
    FROM f
$$;

-- Filas del libro de compras del período (compras y gastos con factura).
CREATE FUNCTION interno.filas_libro_compras(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH dc AS (   -- desglose de cada compra por impuesto
    SELECT l.compra_id, jsonb_agg(jsonb_build_object('porcentaje', i.porcentaje, 'clase', i.clase, 'base_centavos', l.base,
             'impuesto_centavos', l.isv)) AS desglose
      FROM (SELECT cl.compra_id, cl.tipo_impuesto, cl.empresa_id, sum(cl.subtotal_centavos) AS base, sum(cl.isv_centavos) AS isv
              FROM public.compra_linea cl WHERE cl.empresa_id = p_empresa_id GROUP BY 1, 2, 3) l
      JOIN public.impuesto i ON i.empresa_id = l.empresa_id AND i.codigo = l.tipo_impuesto
     GROUP BY l.compra_id),
  dg AS (        -- desglose de cada gasto con factura (la tasa se reconoce por el ISV de la factura)
    SELECT g.id, jsonb_build_array(CASE WHEN g.isv_centavos = 0
             THEN jsonb_build_object('porcentaje', 0, 'clase', 'exento', 'base_centavos', g.monto_centavos, 'impuesto_centavos', 0)
             ELSE jsonb_build_object('clase', 'gravado', 'base_centavos', g.monto_centavos - g.isv_centavos, 'impuesto_centavos', g.isv_centavos,
                    'porcentaje', coalesce((SELECT i.porcentaje FROM public.impuesto i
                                             WHERE i.empresa_id = g.empresa_id AND i.clase = 'gravado'
                                               AND round((g.monto_centavos - g.isv_centavos) * i.porcentaje / 100) = g.isv_centavos
                                             ORDER BY i.predeterminado DESC, i.orden, i.codigo LIMIT 1),
                                           round(g.isv_centavos * 100.0 / (g.monto_centavos - g.isv_centavos), 3))) END) AS desglose
      FROM public.gasto g WHERE g.empresa_id = p_empresa_id AND g.numero_documento IS NOT NULL AND g.asiento_id IS NOT NULL),
  f AS (
    SELECT a.fecha_contable AS fecha, 'compra'::text AS tipo, c.numero_documento AS numero, NULL::text AS cai, t.rtn, t.nombre,
           interno.columnas_isv(dc.desglose, CASE WHEN aa.fecha_contable BETWEEN p_desde AND p_hasta THEN 0 ELSE 1 END) AS col,
           CASE WHEN aa.fecha_contable BETWEEN p_desde AND p_hasta THEN 'ANULADA' ELSE 'vigente' END AS estado,
           NULL::text AS referencia, c.id AS documento_id
      FROM public.compra c JOIN public.asiento a ON a.id = c.asiento_id JOIN dc ON dc.compra_id = c.id
      JOIN public.tercero t ON t.id = c.proveedor_id
      LEFT JOIN public.asiento aa ON aa.id = c.asiento_anulacion_id
     WHERE c.empresa_id = p_empresa_id AND a.fecha_contable BETWEEN p_desde AND p_hasta
    UNION ALL
    SELECT aa.fecha_contable, 'anulacion_compra', c.numero_documento, NULL, t.rtn, t.nombre, interno.columnas_isv(dc.desglose, -1),
           'anulacion', c.numero_documento, c.id
      FROM public.compra c JOIN public.asiento a ON a.id = c.asiento_id JOIN public.asiento aa ON aa.id = c.asiento_anulacion_id
      JOIN dc ON dc.compra_id = c.id JOIN public.tercero t ON t.id = c.proveedor_id
     WHERE c.empresa_id = p_empresa_id AND aa.fecha_contable BETWEEN p_desde AND p_hasta AND a.fecha_contable < p_desde
    UNION ALL
    SELECT a.fecha_contable, 'gasto', g.numero_documento, g.cai, coalesce(g.rtn_emisor, t.rtn), coalesce(t.nombre, g.descripcion),
           interno.columnas_isv(dg.desglose, CASE WHEN aa.fecha_contable BETWEEN p_desde AND p_hasta THEN 0 ELSE 1 END),
           CASE WHEN aa.fecha_contable BETWEEN p_desde AND p_hasta THEN 'ANULADA' ELSE 'vigente' END, NULL, g.id
      FROM public.gasto g JOIN dg ON dg.id = g.id JOIN public.asiento a ON a.id = g.asiento_id
      LEFT JOIN public.tercero t ON t.id = g.proveedor_id
      LEFT JOIN public.asiento aa ON aa.id = g.asiento_anulacion_id
     WHERE a.fecha_contable BETWEEN p_desde AND p_hasta
    UNION ALL
    SELECT aa.fecha_contable, 'anulacion_gasto', g.numero_documento, g.cai, coalesce(g.rtn_emisor, t.rtn), coalesce(t.nombre, g.descripcion),
           interno.columnas_isv(dg.desglose, -1), 'anulacion', g.numero_documento, g.id
      FROM public.gasto g JOIN dg ON dg.id = g.id JOIN public.asiento a ON a.id = g.asiento_id
      JOIN public.asiento aa ON aa.id = g.asiento_anulacion_id
      LEFT JOIN public.tercero t ON t.id = g.proveedor_id
     WHERE aa.fecha_contable BETWEEN p_desde AND p_hasta AND a.fecha_contable < p_desde)
  SELECT coalesce(jsonb_agg(jsonb_build_object('fecha', to_char(f.fecha, 'YYYY-MM-DD'), 'tipo_documento', f.tipo,
           'numero_documento', f.numero, 'cai', f.cai, 'rtn', f.rtn, 'nombre', f.nombre, 'estado', f.estado,
           'documento_referencia', f.referencia, 'documento_id', f.documento_id) || f.col
           ORDER BY f.fecha, f.numero, f.tipo), '[]')
    FROM f
$$;

-- Un libro completo con su cuadre contra isv_mes (asientos del sistema) y, en ventas,
-- contra los ingresos por ventas netos de los libros (4.1).
CREATE FUNCTION interno.libro_isv(p_empresa_id uuid, p_anio integer, p_mes integer, p_libro text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_desde date;
  v_hasta date;
  v_filas jsonb;
  v_tot   jsonb;
  v_isv   jsonb;
  v_cont  bigint;
  v_base  bigint;
  v_cuad  jsonb;
BEGIN
  SELECT * INTO v_desde, v_hasta FROM interno.rango_mes(p_empresa_id, p_anio, p_mes);
  v_isv := interno.calcular_isv(p_empresa_id, v_desde, v_hasta);
  IF p_libro = 'ventas' THEN
    v_filas := interno.filas_libro_ventas(p_empresa_id, v_desde, v_hasta);
    v_tot := interno.totales_libro(v_filas);
    v_cont := (v_isv->>'debito_fiscal_centavos')::bigint;
    SELECT coalesce(sum(l.haber_centavos - l.debe_centavos), 0) INTO v_base
      FROM public.asiento_linea l JOIN public.asiento a ON a.id = l.asiento_id JOIN public.cuenta c ON c.id = l.cuenta_id
     WHERE l.empresa_id = p_empresa_id AND a.fecha_contable BETWEEN v_desde AND v_hasta AND a.origen <> 'manual'
       AND c.tipo = 'ingreso' AND c.codigo LIKE '4.1.%';
    v_cuad := jsonb_build_object(
      'isv_libro_centavos', (v_tot->>'isv_centavos')::bigint, 'debito_fiscal_contabilidad_centavos', v_cont,
      'diferencia_isv_centavos', (v_tot->>'isv_centavos')::bigint - v_cont,
      'base_libro_centavos', (v_tot->>'total_centavos')::bigint - (v_tot->>'isv_centavos')::bigint,
      'ventas_netas_contabilidad_centavos', v_base,
      'cuadra', (v_tot->>'isv_centavos')::bigint = v_cont AND (v_tot->>'total_centavos')::bigint - (v_tot->>'isv_centavos')::bigint = v_base);
  ELSE
    v_filas := interno.filas_libro_compras(p_empresa_id, v_desde, v_hasta);
    v_tot := interno.totales_libro(v_filas);
    v_cont := (v_isv->>'credito_fiscal_centavos')::bigint;
    v_cuad := jsonb_build_object(
      'isv_libro_centavos', (v_tot->>'isv_centavos')::bigint, 'credito_fiscal_contabilidad_centavos', v_cont,
      'diferencia_isv_centavos', (v_tot->>'isv_centavos')::bigint - v_cont,
      'cuadra', (v_tot->>'isv_centavos')::bigint = v_cont);
  END IF;
  RETURN jsonb_build_object(
    'titulo', CASE WHEN p_libro = 'ventas' THEN 'Libro de ventas' ELSE 'Libro de compras' END,
    'empresa', interno.encabezado_empresa(p_empresa_id), 'anio', p_anio, 'mes', p_mes,
    'desde', to_char(v_desde, 'YYYY-MM-DD'), 'hasta', to_char(v_hasta, 'YYYY-MM-DD'), 'generado_en', public.iso(now()),
    'regimen_fiscal_activo', public.modulo_esta_activo(p_empresa_id, 'fiscal_hn'),
    'columnas', interno.columnas_libro(CASE WHEN p_libro = 'ventas' THEN 'cliente' ELSE 'proveedor' END),
    'filas', v_filas, 'cantidad_filas', jsonb_array_length(v_filas), 'totales', v_tot, 'cuadre', v_cuad,
    'ajustes_manuales_centavos', (v_isv->>CASE WHEN p_libro = 'ventas' THEN 'ajustes_manuales_debito_centavos'
                                               ELSE 'ajustes_manuales_credito_centavos' END)::bigint,
    'nota', CASE WHEN p_libro = 'ventas'
      THEN 'Montos en centavos. Notas de crédito y anulaciones de meses anteriores van en negativo; una factura emitida y anulada en el mismo mes va en cero como ANULADA. Los tickets (sin CAI) también se listan. Validar el formato con un contador antes de presentarlo a la SAR.'
      ELSE 'Montos en centavos. Compras y gastos con factura; los gastos sin factura no van al libro. La tasa de un gasto se reconoce por el ISV de su factura. Las compras todavía no guardan el CAI del proveedor (columna vacía). Validar el formato con un contador antes de presentarlo a la SAR.' END);
END $$;

CREATE FUNCTION public.libro_ventas(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.libro_isv(p_empresa_id, p_anio, p_mes, 'ventas');
END $$;

CREATE FUNCTION public.libro_compras(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.libro_isv(p_empresa_id, p_anio, p_mes, 'compras');
END $$;

-- Los dos libros y el ISV del mes (débito - crédito = a pagar) para exportar juntos.
CREATE FUNCTION public.libros_isv(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v jsonb;
  c jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  v := interno.libro_isv(p_empresa_id, p_anio, p_mes, 'ventas');
  c := interno.libro_isv(p_empresa_id, p_anio, p_mes, 'compras');
  RETURN jsonb_build_object('titulo', 'Libros de ISV', 'empresa', v->'empresa', 'anio', p_anio, 'mes', p_mes,
    'generado_en', public.iso(now()), 'libro_ventas', v - 'empresa', 'libro_compras', c - 'empresa',
    'isv_a_pagar_centavos', (v->'totales'->>'isv_centavos')::bigint - (c->'totales'->>'isv_centavos')::bigint,
    'cuadra', (v->'cuadre'->>'cuadra')::boolean AND (c->'cuadre'->>'cuadra')::boolean,
    'nota', 'ISV a pagar = ISV de ventas - ISV de compras (negativo = crédito a favor para el mes siguiente). Los ajustes manuales del contador van aparte.');
END $$;

REVOKE EXECUTE ON FUNCTION
  interno.columnas_isv(jsonb, integer), interno.columnas_libro(text), interno.totales_libro(jsonb),
  interno.filas_libro_ventas(uuid, date, date), interno.filas_libro_compras(uuid, date, date), interno.libro_isv(uuid, integer, integer, text)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.libro_ventas(uuid, integer, integer), public.libro_compras(uuid, integer, integer),
  public.libros_isv(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.libro_ventas(uuid, integer, integer), public.libro_compras(uuid, integer, integer),
  public.libros_isv(uuid, integer, integer) TO authenticated, service_role;
