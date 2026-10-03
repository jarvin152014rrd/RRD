-- =====================================================================
-- 011_reportes.sql  -  Saldos entre dos fechas (base de los estados mensuales)
--
-- saldo_cuentas(empresa, desde, hasta) devuelve, por cada cuenta de detalle:
--   saldo_inicial   = todo lo anterior a "desde"
--   debe / haber    = movimientos entre "desde" y "hasta" (ambos incluidos)
--   saldo_final     = saldo_inicial + movimientos
-- Saldos en centavos y "positivos según su naturaleza" (como v_saldo_cuenta).
-- Uso típico:
--   Balance general al 31/01   -> saldo_final de activo, pasivo y patrimonio
--   Resultados de enero        -> movimiento (debe/haber) de ingreso, costo, gasto
-- Cuenta las anulaciones en la fecha del contra-asiento (así son los libros).
-- desde = NULL significa "desde el principio".
-- =====================================================================

CREATE FUNCTION public.saldo_cuentas(p_empresa_id uuid, p_desde date, p_hasta date)
RETURNS TABLE (
  cuenta_id              uuid,
  codigo                 text,
  nombre                 text,
  tipo                   text,
  naturaleza             text,
  saldo_inicial_centavos bigint,
  debe_centavos          bigint,
  haber_centavos         bigint,
  movimiento_centavos    bigint,
  saldo_final_centavos   bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
#variable_conflict use_column
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  IF p_hasta IS NULL OR (p_desde IS NOT NULL AND p_desde > p_hasta) THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique la fecha "hasta" y que "desde" no sea mayor que "hasta".';
  END IF;

  RETURN QUERY
  WITH mov AS (
    SELECT l.cuenta_id,
           sum(CASE WHEN p_desde IS NOT NULL AND a.fecha_contable < p_desde
                    THEN l.debe_centavos - l.haber_centavos ELSE 0 END) AS antes_neto,
           sum(CASE WHEN p_desde IS NULL OR a.fecha_contable >= p_desde
                    THEN l.debe_centavos ELSE 0 END) AS debe,
           sum(CASE WHEN p_desde IS NULL OR a.fecha_contable >= p_desde
                    THEN l.haber_centavos ELSE 0 END) AS haber
    FROM public.asiento_linea l
    JOIN public.asiento a ON a.id = l.asiento_id
    WHERE l.empresa_id = p_empresa_id AND a.fecha_contable <= p_hasta
    GROUP BY l.cuenta_id
  )
  SELECT c.id, c.codigo, c.nombre, c.tipo, c.naturaleza,
         (s.signo * coalesce(m.antes_neto, 0))::bigint,
         coalesce(m.debe, 0)::bigint,
         coalesce(m.haber, 0)::bigint,
         (s.signo * (coalesce(m.debe, 0) - coalesce(m.haber, 0)))::bigint,
         (s.signo * (coalesce(m.antes_neto, 0) + coalesce(m.debe, 0) - coalesce(m.haber, 0)))::bigint
  FROM public.cuenta c
  CROSS JOIN LATERAL (SELECT CASE WHEN c.naturaleza = 'deudora' THEN 1 ELSE -1 END AS signo) s
  LEFT JOIN mov m ON m.cuenta_id = c.id
  WHERE c.empresa_id = p_empresa_id AND c.es_detalle
  ORDER BY c.codigo;
END $$;

REVOKE EXECUTE ON FUNCTION public.saldo_cuentas(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.saldo_cuentas(uuid, date, date) TO authenticated, service_role;
