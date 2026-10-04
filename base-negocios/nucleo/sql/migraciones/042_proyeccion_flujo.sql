-- =====================================================================
-- 042_proyeccion_flujo.sql  -  Núcleo 0.10.0 (etapa 3a): proyección de flujo de caja
--
-- proyeccion_flujo(empresa, dias 30|60|90, agrupar 'semana')   contabilidad.ver
--   Dinero disponible HOY = cajas, bancos y caja chica. Lo que todavía no es
--   disponible (depósitos en tránsito, transferencias por confirmar, POS por
--   liquidar) se muestra aparte y NO se suma.
--   + cobros esperados de CxC según su vencimiento (los VENCIDOS se muestran
--     aparte y NO se asumen)
--   - pagos de CxP según su vencimiento (los vencidos se asumen en la semana 1)
--   - pagos fijos próximos (monto estimado; los atrasados en la semana 1)
--   - comisiones por pagar y dividendos por pagar (semana 1)
--   Saldo proyectado por semana (semana 1 = hoy a hoy + 6) y alerta si alguna
--   semana queda en negativo.
-- =====================================================================

CREATE FUNCTION public.proyeccion_flujo(p_empresa_id uuid, p_dias integer DEFAULT 30, p_agrupar text DEFAULT 'semana')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy    date := public.hoy_local(p_empresa_id);
  v_hasta  date;
  v_n      integer;
  v_disp   bigint;
  v_mov    jsonb := '[]';   -- [{semana, tipo, monto (+ entra, - sale), fecha, detalle}]
  v_sem    jsonb := '[]';
  v_saldo  bigint;
  v_ent    bigint;
  v_sal    bigint;
  v_alert  jsonb := '[]';
  i        integer;
  r        record;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  IF p_dias IS NULL OR p_dias NOT IN (30, 60, 90) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la proyección es a 30, 60 o 90 días.';
  END IF;
  IF coalesce(p_agrupar, '') <> 'semana' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: por ahora la proyección se agrupa por "semana".';
  END IF;
  v_hasta := v_hoy + p_dias;
  v_n := ceil((p_dias + 1) / 7.0)::integer;

  SELECT coalesce(sum(interno.saldo_dinero(d.id)), 0) INTO v_disp
    FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('efectivo_caja', 'banco', 'caja_chica');

  -- Cobros esperados (no vencidos, dentro del horizonte).
  SELECT coalesce(jsonb_agg(jsonb_build_object('semana', (x.vence_el - v_hoy) / 7 + 1, 'tipo', 'cobro', 'monto', x.saldo_centavos,
           'fecha', to_char(x.vence_el, 'YYYY-MM-DD'), 'detalle', t.nombre || ' ' || coalesce(x.numero_documento, ''))), '[]')
    INTO v_mov
    FROM interno.cxc_al(p_empresa_id, 'infinity') x JOIN public.tercero t ON t.id = x.cliente_id
   WHERE x.saldo_centavos > 0 AND x.vence_el BETWEEN v_hoy AND v_hasta;
  -- Pagos a proveedores (vencidos: semana 1).
  v_mov := v_mov || coalesce((SELECT jsonb_agg(jsonb_build_object('semana', greatest((x.vence_el - v_hoy) / 7 + 1, 1), 'tipo', 'pago_proveedor',
           'monto', -x.saldo_centavos, 'fecha', to_char(x.vence_el, 'YYYY-MM-DD'), 'detalle', t.nombre || ' ' || x.numero_documento))
    FROM interno.cxp_al(p_empresa_id, 'infinity') x JOIN public.tercero t ON t.id = x.proveedor_id
   WHERE x.saldo_centavos > 0 AND x.vence_el <= v_hasta), '[]');
  -- Pagos fijos sin pagar hasta el horizonte (atrasados: semana 1).
  v_mov := v_mov || coalesce((SELECT jsonb_agg(jsonb_build_object('semana', greatest((v.v - v_hoy) / 7 + 1, 1), 'tipo', 'pago_fijo',
           'monto', -p.monto_estimado_centavos, 'fecha', to_char(v.v, 'YYYY-MM-DD'), 'detalle', p.nombre))
    FROM public.pago_fijo p CROSS JOIN LATERAL interno.vencimientos_pago_fijo(p, v_hasta) AS v(v)
   WHERE p.empresa_id = p_empresa_id AND p.activo AND p.monto_estimado_centavos > 0
     AND NOT EXISTS (SELECT 1 FROM public.gasto g WHERE g.pago_fijo_id = p.id AND g.pago_fijo_vence_el = v.v
                       AND g.estado IN ('pendiente_aprobacion', 'aplicado'))), '[]');
  -- Comisiones por pagar (lo positivo de cada vendedor) y dividendos por pagar: semana 1.
  v_mov := v_mov || coalesce((SELECT jsonb_agg(jsonb_build_object('semana', 1, 'tipo', 'comisiones', 'monto', -x.por_pagar,
           'fecha', to_char(v_hoy, 'YYYY-MM-DD'), 'detalle', coalesce(public.nombre_usuario(p_empresa_id, x.vendedor_id), 'Vendedor')))
    FROM (SELECT j->>'vendedor_id' AS vid, (j->>'vendedor_id')::uuid AS vendedor_id, (j->>'por_pagar_centavos')::bigint AS por_pagar
            FROM jsonb_array_elements(interno.calcular_comisiones(p_empresa_id, 'infinity')->'vendedores') j) x
   WHERE x.por_pagar > 0), '[]');
  IF interno.total_dividendos_por_pagar(p_empresa_id) > 0 THEN
    v_mov := v_mov || jsonb_build_object('semana', 1, 'tipo', 'dividendos', 'monto', -interno.total_dividendos_por_pagar(p_empresa_id),
                                         'fecha', to_char(v_hoy, 'YYYY-MM-DD'), 'detalle', 'Dividendos por pagar a socios');
  END IF;

  v_saldo := v_disp;
  FOR i IN 1..v_n LOOP
    SELECT coalesce(sum((m->>'monto')::bigint) FILTER (WHERE (m->>'monto')::bigint > 0), 0),
           coalesce(-sum((m->>'monto')::bigint) FILTER (WHERE (m->>'monto')::bigint < 0), 0)
      INTO v_ent, v_sal FROM jsonb_array_elements(v_mov) m WHERE (m->>'semana')::integer = i;
    SELECT
      coalesce(sum((m->>'monto')::bigint) FILTER (WHERE m->>'tipo' = 'cobro'), 0) AS cobros,
      coalesce(-sum((m->>'monto')::bigint) FILTER (WHERE m->>'tipo' = 'pago_proveedor'), 0) AS proveedores,
      coalesce(-sum((m->>'monto')::bigint) FILTER (WHERE m->>'tipo' = 'pago_fijo'), 0) AS fijos,
      coalesce(-sum((m->>'monto')::bigint) FILTER (WHERE m->>'tipo' = 'comisiones'), 0) AS comisiones,
      coalesce(-sum((m->>'monto')::bigint) FILTER (WHERE m->>'tipo' = 'dividendos'), 0) AS dividendos
      INTO r FROM jsonb_array_elements(v_mov) m WHERE (m->>'semana')::integer = i;
    v_sem := v_sem || jsonb_build_object('semana', i,
      'desde', to_char(v_hoy + (i - 1) * 7, 'YYYY-MM-DD'), 'hasta', to_char(least(v_hoy + i * 7 - 1, v_hasta), 'YYYY-MM-DD'),
      'saldo_inicial_centavos', v_saldo, 'cobros_centavos', r.cobros, 'pagos_proveedores_centavos', r.proveedores,
      'pagos_fijos_centavos', r.fijos, 'comisiones_centavos', r.comisiones, 'dividendos_centavos', r.dividendos,
      'entradas_centavos', v_ent, 'salidas_centavos', v_sal, 'saldo_final_centavos', v_saldo + v_ent - v_sal,
      'negativo', v_saldo + v_ent - v_sal < 0);
    IF v_saldo + v_ent - v_sal < 0 THEN
      v_alert := v_alert || jsonb_build_object('semana', i, 'saldo_final_centavos', v_saldo + v_ent - v_sal,
        'mensaje', 'En la semana ' || i || ' (desde el ' || to_char(v_hoy + (i - 1) * 7, 'DD/MM/YYYY') || ') el dinero proyectado queda en '
                   || interno.lempiras(v_saldo + v_ent - v_sal) || '. Busque cobrar antes o mover pagos.');
    END IF;
    v_saldo := v_saldo + v_ent - v_sal;
  END LOOP;

  RETURN jsonb_build_object(
    'titulo', 'Proyección de flujo de caja', 'empresa', interno.encabezado_empresa(p_empresa_id),
    'desde', to_char(v_hoy, 'YYYY-MM-DD'), 'hasta', to_char(v_hasta, 'YYYY-MM-DD'), 'dias', p_dias, 'agrupar', 'semana',
    'generado_en', public.iso(now()),
    'disponible_hoy_centavos', v_disp,
    'disponible_por_cuenta', (SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', d.id, 'nombre', d.nombre, 'tipo', d.tipo,
        'saldo_centavos', interno.saldo_dinero(d.id), 'fondo', (SELECT f.nombre FROM public.fondo f WHERE f.cuenta_dinero_id = d.id AND f.activo LIMIT 1))
        ORDER BY d.tipo, d.nombre), '[]')
      FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('efectivo_caja', 'banco', 'caja_chica')
        AND (d.activa OR interno.saldo_dinero(d.id) <> 0)),
    'no_disponible_aun', (SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', d.id, 'nombre', d.nombre, 'tipo', d.tipo,
        'saldo_centavos', interno.saldo_dinero(d.id)) ORDER BY d.tipo, d.nombre), '[]')
      FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('transito', 'transferencia_por_confirmar', 'pos_por_liquidar')
        AND interno.saldo_dinero(d.id) <> 0),
    'no_disponible_aun_centavos', (SELECT coalesce(sum(interno.saldo_dinero(d.id)), 0) FROM public.cuenta_dinero d
      WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('transito', 'transferencia_por_confirmar', 'pos_por_liquidar')),
    'cobros_vencidos_centavos', (SELECT coalesce(sum(x.saldo_centavos), 0) FROM interno.cxc_al(p_empresa_id, 'infinity') x
      WHERE x.saldo_centavos > 0 AND x.vence_el < v_hoy),
    'cobros_vencidos', (SELECT coalesce(jsonb_agg(jsonb_build_object('cliente', t.nombre, 'numero_documento', x.numero_documento,
        'vence_el', to_char(x.vence_el, 'YYYY-MM-DD'), 'saldo_centavos', x.saldo_centavos) ORDER BY x.vence_el), '[]')
      FROM interno.cxc_al(p_empresa_id, 'infinity') x JOIN public.tercero t ON t.id = x.cliente_id
      WHERE x.saldo_centavos > 0 AND x.vence_el < v_hoy),
    'cobros_despues_del_horizonte_centavos', (SELECT coalesce(sum(x.saldo_centavos), 0) FROM interno.cxc_al(p_empresa_id, 'infinity') x
      WHERE x.saldo_centavos > 0 AND x.vence_el > v_hasta),
    'semanas', v_sem, 'saldo_final_proyectado_centavos', v_saldo,
    'alerta', jsonb_array_length(v_alert) > 0, 'alertas', v_alert,
    'detalle', (SELECT coalesce(jsonb_agg(m ORDER BY (m->>'semana')::integer, m->>'fecha', m->>'tipo'), '[]') FROM jsonb_array_elements(v_mov) m),
    'nota', 'Los cobros vencidos no se asumen; las cuentas por pagar vencidas, las comisiones y los dividendos por pagar se asumen en la semana 1. Pagos fijos con su monto estimado.');
END $$;

REVOKE EXECUTE ON FUNCTION public.proyeccion_flujo(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.proyeccion_flujo(uuid, integer, text) TO authenticated, service_role;
