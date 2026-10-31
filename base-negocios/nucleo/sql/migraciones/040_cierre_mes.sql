-- =====================================================================
-- 040_cierre_mes.sql  -  Núcleo 0.10.0 (etapa 3a): cierre de mes completo
--
--   cierre           una FOTO inmutable por cada vez que se cierra un mes
--                    (versión 1, 2, ...). Al reabrir el mes la foto queda
--                    "superada" (nunca se borra); al volver a cerrar se crea
--                    la versión siguiente.
--   cierre_detalle   las secciones de la foto (jsonb): saldos de cuentas,
--                    estado de resultados, balance general, flujo de efectivo
--                    (método directo), CxC con antigüedad, CxP, inventario
--                    valorizado, cuentas de dinero, saldo a favor y anticipos,
--                    comisiones por pagar e ISV del mes.
--
--   cerrar_mes(empresa, año, mes, motivo?)  periodos.cerrar
--     1) descuadre contable (debe <> haber) = NO cierra (DESCUADRE_CONTABLE);
--     2) bloquea el mes con cerrar_periodo (en orden, mes terminado);
--     3) guarda la foto y devuelve las ADVERTENCIAS (no bloquean): depósitos
--        en tránsito, turnos abiertos, aprobaciones pendientes, transferencias
--        por confirmar, cuentas en negativo y alertas de cuadre.
--   Selector de meses (contabilidad.ver): estado_resultados, balance_general,
--   flujo_efectivo, saldos_cuentas_mes, cuentas_por_cobrar_mes,
--   cuentas_por_pagar_mes, inventario_mes, dinero_mes, isv_mes. Mes cerrado =
--   la foto; mes abierto = en vivo y "preliminar". exportar_mes = todo el
--   paquete (JSON listo para que la app arme PDF o Excel, sin emojis, montos
--   en centavos, fechas ISO). historial_cierres / ver_cierre.
--
--   Utilidad COBRADA (decisión, ver nucleo/docs/estados.md):
--     utilidad neta del mes - (utilidad por cobrar al final - al inicio)
--     utilidad por cobrar de una factura = saldo x (base sin ISV - costo) / total
--   (nunca negativa por factura; los saldos iniciales de clientes no son
--   ingreso del sistema y no cuentan).
--
--   Formatos NIIF para PYMES; un contador hondureño debe validar la
--   presentación antes de usarlos ante terceros.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('DESCUADRE_CONTABLE', 'Los libros no cuadran (el debe no es igual al haber); el mes no se puede cerrar.',
   'No se cerró nada. Avise a soporte con el detalle del mensaje para revisar los asientos.');

-- ---------------------------------------------------------------------
-- 1) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.cierre (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id       uuid NOT NULL REFERENCES public.empresa(id),
  anio             integer NOT NULL CHECK (anio BETWEEN 2000 AND 2100),
  mes              integer NOT NULL CHECK (mes BETWEEN 1 AND 12),
  version          integer NOT NULL CHECK (version >= 1),
  estado           text NOT NULL DEFAULT 'vigente' CHECK (estado IN ('vigente', 'superada')),
  motivo           text,                                   -- motivo del cierre (opcional)
  advertencias     jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(advertencias) = 'array'),
  resumen          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(resumen) = 'object'),
  cerrado_por      uuid,
  cerrado_en       timestamptz NOT NULL DEFAULT now(),
  superada_en      timestamptz,
  superada_por     uuid,
  motivo_superada  text,                                   -- el motivo de la reapertura
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, anio, mes, version),
  CHECK ((estado = 'superada') = (superada_en IS NOT NULL))
);
CREATE UNIQUE INDEX cierre_vigente ON public.cierre (empresa_id, anio, mes) WHERE estado = 'vigente';

CREATE TABLE public.cierre_detalle (
  cierre_id   uuid NOT NULL REFERENCES public.cierre(id),
  empresa_id  uuid NOT NULL,
  seccion     text NOT NULL CHECK (seccion ~ '^[a-z_]{3,40}$'),
  datos       jsonb NOT NULL,
  PRIMARY KEY (cierre_id, seccion),
  FOREIGN KEY (empresa_id, cierre_id) REFERENCES public.cierre(empresa_id, id)
);

-- La foto no se edita: solo pasa una vez de vigente a superada.
CREATE FUNCTION interno.proteger_cierre() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c constant text[] := ARRAY['estado', 'superada_en', 'superada_por', 'motivo_superada'];
BEGIN
  IF OLD.estado = 'vigente' AND NEW.estado = 'superada' AND (to_jsonb(NEW) - c) = (to_jsonb(OLD) - c) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: la foto de un cierre no se edita; al reabrir el mes queda superada y al cerrar se crea otra versión.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.cierre FOR EACH ROW EXECUTE FUNCTION interno.proteger_cierre();
CREATE TRIGGER inmutable BEFORE UPDATE ON public.cierre_detalle
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La foto de un cierre no se edita.');
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cierre', 'cierre_detalle'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'Los cierres de mes no se borran (al reabrir quedan superados).');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', t, 'contabilidad.ver');
  END LOOP;
END $$;

-- Al reabrir un mes (cerrado -> abierto, por cualquier camino) su foto vigente queda superada.
CREATE FUNCTION interno.superar_cierre() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.estado = 'cerrado' AND NEW.estado = 'abierto' THEN
    UPDATE public.cierre
       SET estado = 'superada', superada_en = now(), superada_por = auth.uid(),
           motivo_superada = nullif(current_setting('app.motivo', true), '')
     WHERE empresa_id = NEW.empresa_id AND anio = NEW.anio AND mes = NEW.mes AND estado = 'vigente';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER superar_cierre AFTER UPDATE OF estado ON public.periodo
  FOR EACH ROW EXECUTE FUNCTION interno.superar_cierre();

-- ---------------------------------------------------------------------
-- 2) Cálculos (sin permisos: los llaman las RPC después de revisarlos)
-- ---------------------------------------------------------------------
-- saldo_cuentas sin revisar permisos (misma cuenta que 011).
CREATE FUNCTION interno.saldo_cuentas_base(p_empresa_id uuid, p_desde date, p_hasta date)
RETURNS TABLE (cuenta_id uuid, codigo text, nombre text, tipo text, naturaleza text,
               saldo_inicial_centavos bigint, debe_centavos bigint, haber_centavos bigint,
               movimiento_centavos bigint, saldo_final_centavos bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH mov AS (
    SELECT l.cuenta_id,
           sum(CASE WHEN p_desde IS NOT NULL AND a.fecha_contable < p_desde THEN l.debe_centavos - l.haber_centavos ELSE 0 END) AS antes_neto,
           sum(CASE WHEN p_desde IS NULL OR a.fecha_contable >= p_desde THEN l.debe_centavos ELSE 0 END) AS debe,
           sum(CASE WHEN p_desde IS NULL OR a.fecha_contable >= p_desde THEN l.haber_centavos ELSE 0 END) AS haber
      FROM public.asiento_linea l
      JOIN public.asiento a ON a.id = l.asiento_id
     WHERE l.empresa_id = p_empresa_id AND a.fecha_contable <= p_hasta
     GROUP BY l.cuenta_id)
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
   ORDER BY c.codigo
$$;

-- Saldo de una cuenta (por código) a una fecha, positivo según su naturaleza.
CREATE FUNCTION interno.saldo_libros_al(p_empresa_id uuid, p_codigo text, p_fecha date) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(CASE WHEN c.naturaleza = 'deudora' THEN l.debe_centavos - l.haber_centavos
                           ELSE l.haber_centavos - l.debe_centavos END), 0)::bigint
    FROM public.asiento_linea l
    JOIN public.cuenta c ON c.id = l.cuenta_id
    JOIN public.asiento a ON a.id = l.asiento_id
   WHERE l.empresa_id = p_empresa_id AND c.codigo = p_codigo AND a.fecha_contable <= p_fecha
$$;

-- Documentos por cobrar (ventas al crédito y saldos iniciales) TAL COMO ESTABAN a una fecha:
-- cuenta lo emitido hasta esa fecha y lo aplicado hasta esa fecha (una anulación cuenta en
-- su fecha, como en los libros). margen_num / margen_den: para la utilidad por cobrar.
CREATE FUNCTION interno.cxc_al(p_empresa_id uuid, p_fecha date)
RETURNS TABLE (documento_id uuid, origen text, cliente_id uuid, numero_documento text, fecha_documento date,
               vence_el date, monto_centavos bigint, aplicado_centavos bigint, saldo_centavos bigint,
               margen_num bigint, margen_den bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH docs AS (
    SELECT v.id, 'venta'::text AS origen, v.cliente_id, v.numero_documento, v.fecha_contable AS fecha_documento,
           v.vence_el, v.credito_centavos AS monto,
           greatest(v.subtotal_centavos - v.descuento_centavos - coalesce(v.costo_centavos, 0), 0)::bigint AS num,
           v.total_centavos AS den
      FROM public.venta v
     WHERE v.empresa_id = p_empresa_id AND v.credito_centavos > 0 AND v.fecha_contable <= p_fecha
       AND (v.estado = 'emitida' OR (v.estado = 'anulada' AND v.fecha_anulacion > p_fecha))
    UNION ALL
    SELECT s.id, 'saldo_inicial', s.cliente_id, s.numero_documento, s.fecha_documento, s.fecha_vencimiento, s.monto_centavos,
           0::bigint, 1::bigint
      FROM public.cxc_saldo_inicial s
     WHERE s.empresa_id = p_empresa_id AND s.fecha_contable <= p_fecha
       AND (s.anulada_en IS NULL OR s.fecha_anulacion > p_fecha)),
  apl AS (
    SELECT coalesce(a.venta_id, a.saldo_inicial_id) AS documento_id, sum(a.monto_centavos) AS aplicado
      FROM public.cxc_aplicacion a
      LEFT JOIN public.cobro cb ON a.origen = 'cobro' AND cb.id = a.origen_id
      LEFT JOIN public.cxc_condonacion cd ON a.origen = 'condonacion' AND cd.id = a.origen_id
     WHERE a.empresa_id = p_empresa_id AND a.fecha_contable <= p_fecha
       AND (a.anulada_en IS NULL OR coalesce(cb.fecha_anulacion, cd.fecha_anulacion, p_fecha) > p_fecha)
     GROUP BY 1)
  SELECT d.id, d.origen, d.cliente_id, d.numero_documento, d.fecha_documento, d.vence_el, d.monto,
         coalesce(p.aplicado, 0)::bigint, (d.monto - coalesce(p.aplicado, 0))::bigint, d.num, d.den
    FROM docs d LEFT JOIN apl p ON p.documento_id = d.id
$$;

-- Utilidad todavía por cobrar a una fecha (ver encabezado).
CREATE FUNCTION interno.utilidad_por_cobrar_al(p_empresa_id uuid, p_fecha date) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(round(x.saldo_centavos::numeric * x.margen_num / x.margen_den)), 0)::bigint
    FROM interno.cxc_al(p_empresa_id, p_fecha) x
   WHERE x.origen = 'venta' AND x.saldo_centavos > 0 AND x.margen_den > 0
$$;

-- Documentos por pagar a una fecha (compras al crédito y saldos iniciales menos pagos).
CREATE FUNCTION interno.cxp_al(p_empresa_id uuid, p_fecha date)
RETURNS TABLE (documento_id uuid, origen text, proveedor_id uuid, numero_documento text, fecha_documento date,
               vence_el date, monto_centavos bigint, pagado_centavos bigint, saldo_centavos bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH docs AS (
    SELECT c.id, 'compra'::text AS origen, c.proveedor_id, c.numero_documento, c.fecha_contable AS fecha_documento,
           c.fecha_vencimiento AS vence_el, c.total_centavos AS monto
      FROM public.compra c
     WHERE c.empresa_id = p_empresa_id AND c.condicion = 'credito' AND c.fecha_contable <= p_fecha
       AND (c.anulada_en IS NULL OR c.fecha_anulacion > p_fecha)
    UNION ALL
    SELECT s.id, 'saldo_inicial', s.proveedor_id, s.numero_documento, s.fecha_documento, s.fecha_vencimiento, s.monto_centavos
      FROM public.cxp_saldo_inicial s
     WHERE s.empresa_id = p_empresa_id AND s.fecha_contable <= p_fecha
       AND (s.anulada_en IS NULL OR s.fecha_anulacion > p_fecha)),
  pag AS (
    SELECT coalesce(p.compra_id, p.saldo_inicial_id) AS documento_id, sum(p.monto_centavos) AS pagado
      FROM public.pago_proveedor p
     WHERE p.empresa_id = p_empresa_id AND p.fecha_contable <= p_fecha
       AND NOT EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion a WHERE a.pago_id = p.id AND a.fecha_contable <= p_fecha)
     GROUP BY 1)
  SELECT d.id, d.origen, d.proveedor_id, d.numero_documento, d.fecha_documento, d.vence_el, d.monto,
         coalesce(p.pagado, 0)::bigint, (d.monto - coalesce(p.pagado, 0))::bigint
    FROM docs d LEFT JOIN pag p ON p.documento_id = d.id
$$;

-- Fila de presentación (lo que la app imprime tal cual).
CREATE FUNCTION interno.linea_estado(p_concepto text, p_monto bigint, p_tipo text, p_nivel integer DEFAULT 0,
                                     p_codigo text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('codigo', p_codigo, 'concepto', p_concepto, 'monto_centavos', p_monto, 'tipo', p_tipo, 'nivel', p_nivel)
$$;

-- Estado de resultados del período (ventas, devoluciones y descuentos, ventas netas,
-- costo, utilidad bruta y margen, gastos por categoría (cuenta), utilidad operativa,
-- otros ingresos y gastos, utilidad neta) más la utilidad COBRADA.
CREATE FUNCTION interno.calcular_estado_resultados(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_vb   bigint; v_dd bigint; v_vn bigint; v_cv bigint; v_ub bigint; v_go bigint; v_uo bigint;
  v_oi   bigint; v_og bigint; v_un bigint; v_pi bigint; v_pf bigint;
  j_vb   jsonb; j_dd jsonb; j_cv jsonb; j_go jsonb; j_oi jsonb; j_og jsonb;
  v_lin  jsonb := '[]';
BEGIN
  WITH er AS (
    SELECT s.codigo, s.nombre,
           CASE WHEN s.tipo = 'ingreso' AND s.codigo LIKE '4.1.%' AND s.naturaleza = 'acreedora' THEN 'ventas'
                WHEN s.tipo = 'ingreso' AND s.codigo LIKE '4.1.%' THEN 'devoluciones_descuentos'
                WHEN s.tipo = 'ingreso' THEN 'otros_ingresos'
                WHEN s.tipo = 'costo' THEN 'costo'
                WHEN s.tipo = 'gasto' AND s.codigo LIKE '6.1.%' THEN 'gastos_operacion'
                ELSE 'otros_gastos' END AS grupo,
           -- ingresos: positivo = aumenta la utilidad; costos y gastos: positivo = la disminuye;
           -- devoluciones y descuentos: positivo = rebaja de ventas.
           CASE WHEN s.tipo = 'ingreso' AND s.codigo LIKE '4.1.%' THEN s.movimiento_centavos
                WHEN s.tipo = 'ingreso' THEN CASE WHEN s.naturaleza = 'acreedora' THEN s.movimiento_centavos ELSE -s.movimiento_centavos END
                ELSE CASE WHEN s.naturaleza = 'deudora' THEN s.movimiento_centavos ELSE -s.movimiento_centavos END END AS monto
      FROM interno.saldo_cuentas_base(p_empresa_id, p_desde, p_hasta) s
     WHERE s.tipo IN ('ingreso', 'costo', 'gasto') AND s.movimiento_centavos <> 0)
  SELECT coalesce(sum(monto) FILTER (WHERE grupo = 'ventas'), 0), coalesce(sum(monto) FILTER (WHERE grupo = 'devoluciones_descuentos'), 0),
         coalesce(sum(monto) FILTER (WHERE grupo = 'costo'), 0), coalesce(sum(monto) FILTER (WHERE grupo = 'gastos_operacion'), 0),
         coalesce(sum(monto) FILTER (WHERE grupo = 'otros_ingresos'), 0), coalesce(sum(monto) FILTER (WHERE grupo = 'otros_gastos'), 0),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'ventas'), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'devoluciones_descuentos'), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'costo'), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'gastos_operacion'), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'otros_ingresos'), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'otros_gastos'), '[]')
    INTO v_vb, v_dd, v_cv, v_go, v_oi, v_og, j_vb, j_dd, j_cv, j_go, j_oi, j_og
    FROM er;
  v_vn := v_vb - v_dd;  v_ub := v_vn - v_cv;  v_uo := v_ub - v_go;  v_un := v_uo + v_oi - v_og;
  v_pi := interno.utilidad_por_cobrar_al(p_empresa_id, p_desde - 1);
  v_pf := interno.utilidad_por_cobrar_al(p_empresa_id, p_hasta);

  -- Filas de presentación (en orden).
  v_lin := v_lin || interno.linea_estado('Ventas', v_vb, 'titulo')
         || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'codigo')) FROM jsonb_array_elements(j_vb) x), '[]')
         || interno.linea_estado('(-) Devoluciones y descuentos sobre ventas', v_dd, 'titulo')
         || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'codigo')) FROM jsonb_array_elements(j_dd) x), '[]')
         || interno.linea_estado('Ventas netas', v_vn, 'subtotal')
         || interno.linea_estado('(-) Costo de ventas', v_cv, 'titulo')
         || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'codigo')) FROM jsonb_array_elements(j_cv) x), '[]')
         || interno.linea_estado('Utilidad bruta', v_ub, 'subtotal')
         || interno.linea_estado('(-) Gastos de operación', v_go, 'titulo')
         || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'codigo')) FROM jsonb_array_elements(j_go) x), '[]')
         || interno.linea_estado('Utilidad de operación', v_uo, 'subtotal')
         || interno.linea_estado('(+) Otros ingresos', v_oi, 'titulo')
         || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'codigo')) FROM jsonb_array_elements(j_oi) x), '[]')
         || interno.linea_estado('(-) Otros gastos', v_og, 'titulo')
         || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'codigo')) FROM jsonb_array_elements(j_og) x), '[]')
         || interno.linea_estado('Utilidad neta del período (facturada)', v_un, 'total')
         || interno.linea_estado('(-) Aumento de la utilidad por cobrar a clientes', v_pf - v_pi, 'detalle', 1)
         || interno.linea_estado('Utilidad cobrada (dinero que de verdad entró)', v_un - (v_pf - v_pi), 'total');

  RETURN jsonb_build_object(
    'titulo', 'Estado de resultados', 'desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'ventas_brutas_centavos', v_vb, 'devoluciones_descuentos_centavos', v_dd, 'ventas_netas_centavos', v_vn,
    'costo_ventas_centavos', v_cv, 'utilidad_bruta_centavos', v_ub,
    'margen_bruto_porcentaje', CASE WHEN v_vn <> 0 THEN round(v_ub * 100.0 / v_vn, 2) END,
    'gastos_operacion_centavos', v_go, 'utilidad_operativa_centavos', v_uo,
    'otros_ingresos_centavos', v_oi, 'otros_gastos_centavos', v_og,
    'utilidad_neta_centavos', v_un, 'utilidad_facturada_centavos', v_un,
    'utilidad_por_cobrar_inicio_centavos', v_pi, 'utilidad_por_cobrar_fin_centavos', v_pf,
    'utilidad_cobrada_centavos', v_un - (v_pf - v_pi),
    'margen_neto_porcentaje', CASE WHEN v_vn <> 0 THEN round(v_un * 100.0 / v_vn, 2) END,
    'ventas', j_vb, 'devoluciones_descuentos', j_dd, 'costo_ventas', j_cv, 'gastos_por_categoria', j_go,
    'otros_ingresos', j_oi, 'otros_gastos', j_og, 'lineas', v_lin);
END $$;

-- Balance general a una fecha. El resultado de los meses aún sin cierre anual se muestra
-- en patrimonio (del año en curso y de años anteriores).
CREATE FUNCTION interno.calcular_balance(p_empresa_id uuid, p_hasta date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ini_anio date := make_date(extract(year FROM p_hasta)::integer, 1, 1);
  v_act  bigint; v_pas bigint; v_pat bigint; v_res_anio bigint; v_res_ant bigint;
  j_ac jsonb; j_anc jsonb; j_pc jsonb; j_pnc jsonb; j_pat jsonb;
  v_ac bigint; v_anc bigint; v_pc bigint; v_pnc bigint;
  v_lin jsonb := '[]';
BEGIN
  WITH bg AS (
    SELECT s.codigo, s.nombre,
           CASE WHEN s.tipo = 'activo' AND s.codigo LIKE '1.1.%' THEN 'activo_corriente'
                WHEN s.tipo = 'activo' THEN 'activo_no_corriente'
                WHEN s.tipo = 'pasivo' AND s.codigo LIKE '2.1.%' THEN 'pasivo_corriente'
                WHEN s.tipo = 'pasivo' THEN 'pasivo_no_corriente'
                WHEN s.tipo = 'patrimonio' THEN 'patrimonio'
                ELSE 'resultado' END AS grupo,
           -- Activo: deudora suma, acreedora (depreciación, estimaciones) resta. Pasivo y patrimonio al revés.
           CASE WHEN s.tipo = 'activo' THEN CASE WHEN s.naturaleza = 'deudora' THEN s.saldo_final_centavos ELSE -s.saldo_final_centavos END
                ELSE CASE WHEN s.naturaleza = 'acreedora' THEN s.saldo_final_centavos ELSE -s.saldo_final_centavos END END AS monto,
           -- Resultado (ingreso suma; costo y gasto restan): lo de años anteriores y lo del año.
           CASE WHEN s.naturaleza = 'acreedora' THEN s.saldo_inicial_centavos ELSE -s.saldo_inicial_centavos END AS ini,
           CASE WHEN s.naturaleza = 'acreedora' THEN s.movimiento_centavos ELSE -s.movimiento_centavos END AS mov
      FROM interno.saldo_cuentas_base(p_empresa_id, v_ini_anio, p_hasta) s)
  SELECT coalesce(sum(monto) FILTER (WHERE grupo = 'activo_corriente'), 0), coalesce(sum(monto) FILTER (WHERE grupo = 'activo_no_corriente'), 0),
         coalesce(sum(monto) FILTER (WHERE grupo = 'pasivo_corriente'), 0), coalesce(sum(monto) FILTER (WHERE grupo = 'pasivo_no_corriente'), 0),
         coalesce(sum(monto) FILTER (WHERE grupo = 'patrimonio'), 0),
         coalesce(sum(mov) FILTER (WHERE grupo = 'resultado'), 0), coalesce(sum(ini) FILTER (WHERE grupo = 'resultado'), 0),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'activo_corriente' AND monto <> 0), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'activo_no_corriente' AND monto <> 0), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'pasivo_corriente' AND monto <> 0), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'pasivo_no_corriente' AND monto <> 0), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'monto_centavos', monto) ORDER BY codigo)
                  FILTER (WHERE grupo = 'patrimonio' AND monto <> 0), '[]')
    INTO v_ac, v_anc, v_pc, v_pnc, v_pat, v_res_anio, v_res_ant, j_ac, j_anc, j_pc, j_pnc, j_pat
    FROM bg;
  v_act := v_ac + v_anc;  v_pas := v_pc + v_pnc;  v_pat := v_pat + v_res_anio + v_res_ant;

  v_lin := '[]'::jsonb || interno.linea_estado('ACTIVO', NULL, 'titulo')
        || interno.linea_estado('Activo corriente', v_ac, 'titulo', 1)
        || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 2, x->>'codigo')) FROM jsonb_array_elements(j_ac) x), '[]')
        || interno.linea_estado('Activo no corriente', v_anc, 'titulo', 1)
        || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 2, x->>'codigo')) FROM jsonb_array_elements(j_anc) x), '[]')
        || interno.linea_estado('Total activo', v_act, 'total')
        || interno.linea_estado('PASIVO', NULL, 'titulo')
        || interno.linea_estado('Pasivo corriente', v_pc, 'titulo', 1)
        || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 2, x->>'codigo')) FROM jsonb_array_elements(j_pc) x), '[]')
        || interno.linea_estado('Pasivo no corriente', v_pnc, 'titulo', 1)
        || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 2, x->>'codigo')) FROM jsonb_array_elements(j_pnc) x), '[]')
        || interno.linea_estado('Total pasivo', v_pas, 'total')
        || interno.linea_estado('PATRIMONIO', NULL, 'titulo')
        || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 2, x->>'codigo')) FROM jsonb_array_elements(j_pat) x), '[]')
        || interno.linea_estado('Resultados de años anteriores (sin cierre anual)', v_res_ant, 'detalle', 2)
        || interno.linea_estado('Resultado del ejercicio en curso', v_res_anio, 'detalle', 2)
        || interno.linea_estado('Total patrimonio', v_pat, 'total')
        || interno.linea_estado('Total pasivo y patrimonio', v_pas + v_pat, 'total');

  RETURN jsonb_build_object(
    'titulo', 'Balance general', 'al', to_char(p_hasta, 'YYYY-MM-DD'),
    'activo_corriente', j_ac, 'activo_corriente_centavos', v_ac,
    'activo_no_corriente', j_anc, 'activo_no_corriente_centavos', v_anc,
    'pasivo_corriente', j_pc, 'pasivo_corriente_centavos', v_pc,
    'pasivo_no_corriente', j_pnc, 'pasivo_no_corriente_centavos', v_pnc,
    'patrimonio', j_pat,
    'resultado_ejercicio_centavos', v_res_anio, 'resultados_anios_anteriores_centavos', v_res_ant,
    'total_activo_centavos', v_act, 'total_pasivo_centavos', v_pas, 'total_patrimonio_centavos', v_pat,
    'pasivo_mas_patrimonio_centavos', v_pas + v_pat, 'cuadra', v_act = v_pas + v_pat,
    'diferencia_centavos', v_act - (v_pas + v_pat), 'lineas', v_lin);
END $$;

-- Nombre legible de una operación del rastro (codigo_en_minusculas -> "Codigo en minusculas").
CREATE FUNCTION interno.nombre_operacion(p_operacion text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_operacion
    WHEN 'dinero_saldo_inicial' THEN 'Saldos iniciales'
    WHEN 'venta' THEN 'Ventas de contado'
    WHEN 'cobro' THEN 'Cobros a clientes'
    WHEN 'gasto' THEN 'Gastos'
    WHEN 'compra' THEN 'Compras de contado'
    WHEN 'pago_proveedor' THEN 'Pagos a proveedores'
    WHEN 'pago_comisiones' THEN 'Pago de comisiones'
    WHEN 'pago_dividendos' THEN 'Pago de dividendos a socios'
    WHEN 'uso_fondo' THEN 'Uso de fondos'
    WHEN 'devolucion' THEN 'Devoluciones a clientes'
    ELSE upper(left(replace(p_operacion, '_', ' '), 1)) || substr(replace(p_operacion, '_', ' '), 2) END
$$;

-- Flujo de efectivo por el método DIRECTO, desde el rastro del dinero. Un asiento cuyo
-- dinero suma 0 (depósito, traslado, confirmación) es un traslado interno: no es entrada
-- ni salida. saldo inicial + entradas - salidas = saldo final.
CREATE FUNCTION interno.calcular_flujo(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ini bigint; v_fin bigint; v_ent bigint; v_sal bigint; v_int bigint;
  j_ent jsonb; j_sal jsonb; v_lin jsonb;
BEGIN
  SELECT coalesce(sum(m.monto_centavos) FILTER (WHERE m.fecha_contable < p_desde), 0),
         coalesce(sum(m.monto_centavos), 0)
    INTO v_ini, v_fin FROM public.dinero_movimiento m WHERE m.empresa_id = p_empresa_id AND m.fecha_contable <= p_hasta;
  WITH fl AS (
    SELECT m.operacion, m.monto_centavos AS monto, n.neto = 0 AS es_interno
      FROM public.dinero_movimiento m
      JOIN (SELECT x.asiento_id, sum(x.monto_centavos) AS neto FROM public.dinero_movimiento x
             WHERE x.empresa_id = p_empresa_id AND x.fecha_contable BETWEEN p_desde AND p_hasta GROUP BY x.asiento_id) n
        ON n.asiento_id = m.asiento_id
     WHERE m.empresa_id = p_empresa_id AND m.fecha_contable BETWEEN p_desde AND p_hasta)
  SELECT coalesce((SELECT sum(monto) FROM fl WHERE NOT es_interno AND monto > 0), 0),
         coalesce((SELECT -sum(monto) FROM fl WHERE NOT es_interno AND monto < 0), 0),
         coalesce((SELECT sum(monto) FROM fl WHERE es_interno AND monto > 0), 0),
         (SELECT coalesce(jsonb_agg(jsonb_build_object('tipo', t.operacion, 'nombre', interno.nombre_operacion(t.operacion), 'monto_centavos', t.monto)
                                    ORDER BY t.monto DESC, t.operacion), '[]')
            FROM (SELECT operacion, sum(monto)::bigint AS monto FROM fl WHERE NOT es_interno AND monto > 0 GROUP BY operacion) t),
         (SELECT coalesce(jsonb_agg(jsonb_build_object('tipo', t.operacion, 'nombre', interno.nombre_operacion(t.operacion), 'monto_centavos', t.monto)
                                    ORDER BY t.monto DESC, t.operacion), '[]')
            FROM (SELECT operacion, (-sum(monto))::bigint AS monto FROM fl WHERE NOT es_interno AND monto < 0 GROUP BY operacion) t)
    INTO v_ent, v_sal, v_int, j_ent, j_sal;
  v_lin := '[]'::jsonb || interno.linea_estado('Saldo inicial de las cuentas de dinero', v_ini, 'subtotal')
        || interno.linea_estado('(+) Entradas de dinero', v_ent, 'titulo')
        || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'tipo')) FROM jsonb_array_elements(j_ent) x), '[]')
        || interno.linea_estado('(-) Salidas de dinero', v_sal, 'titulo')
        || coalesce((SELECT jsonb_agg(interno.linea_estado(x->>'nombre', (x->>'monto_centavos')::bigint, 'detalle', 1, x->>'tipo')) FROM jsonb_array_elements(j_sal) x), '[]')
        || interno.linea_estado('Flujo neto del período', v_ent - v_sal, 'subtotal')
        || interno.linea_estado('Saldo final de las cuentas de dinero', v_fin, 'total')
        || interno.linea_estado('Traslados entre cuentas propias (no cambian el total)', v_int, 'detalle', 1);
  RETURN jsonb_build_object(
    'titulo', 'Flujo de efectivo (método directo)', 'desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'saldo_inicial_centavos', v_ini, 'entradas_centavos', v_ent, 'salidas_centavos', v_sal, 'flujo_neto_centavos', v_ent - v_sal,
    'saldo_final_centavos', v_fin, 'traslados_internos_centavos', v_int, 'cuadra', v_ini + v_ent - v_sal = v_fin,
    'entradas', j_ent, 'salidas', j_sal,
    'otras_cuentas_efectivo_sin_rastro', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', s.codigo, 'nombre', s.nombre, 'saldo_inicial_centavos', s.saldo_inicial_centavos,
                                                   'saldo_final_centavos', s.saldo_final_centavos) ORDER BY s.codigo), '[]')
        FROM interno.saldo_cuentas_base(p_empresa_id, p_desde, p_hasta) s
       WHERE s.codigo LIKE '1.1.01.%' AND (s.saldo_inicial_centavos <> 0 OR s.saldo_final_centavos <> 0)
         AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d WHERE d.cuenta_id = s.cuenta_id)),
    'lineas', v_lin);
END $$;

-- Saldos de todas las cuentas de detalle con movimiento o saldo (sumas iguales).
CREATE FUNCTION interno.calcular_saldos_cuentas(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('titulo', 'Saldos de las cuentas', 'desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'debe_centavos', coalesce(sum(s.debe_centavos), 0), 'haber_centavos', coalesce(sum(s.haber_centavos), 0),
    'sumas_iguales', coalesce(sum(s.debe_centavos), 0) = coalesce(sum(s.haber_centavos), 0),
    'cuentas', coalesce(jsonb_agg(jsonb_build_object('codigo', s.codigo, 'nombre', s.nombre, 'tipo', s.tipo, 'naturaleza', s.naturaleza,
      'saldo_inicial_centavos', s.saldo_inicial_centavos, 'debe_centavos', s.debe_centavos, 'haber_centavos', s.haber_centavos,
      'saldo_final_centavos', s.saldo_final_centavos) ORDER BY s.codigo), '[]'))
    FROM interno.saldo_cuentas_base(p_empresa_id, p_desde, p_hasta) s
   WHERE s.saldo_inicial_centavos <> 0 OR s.debe_centavos <> 0 OR s.haber_centavos <> 0
$$;

-- Saldos por cliente al cierre, con antigüedad (días desde la factura) y vencido.
CREATE FUNCTION interno.calcular_cxc(p_empresa_id uuid, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH d AS (SELECT x.*, p_hasta - x.fecha_documento AS dias FROM interno.cxc_al(p_empresa_id, p_hasta) x WHERE x.saldo_centavos <> 0),
  c AS (
    SELECT d.cliente_id, t.nombre, t.rtn, count(*) AS documentos, sum(d.saldo_centavos)::bigint AS saldo,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias <= 30), 0)::bigint AS a30,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 31 AND 60), 0)::bigint AS a60,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 61 AND 90), 0)::bigint AS a90,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias > 90), 0)::bigint AS m90,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.vence_el < p_hasta), 0)::bigint AS vencido
      FROM d JOIN public.tercero t ON t.id = d.cliente_id
     GROUP BY d.cliente_id, t.nombre, t.rtn)
  SELECT jsonb_build_object('titulo', 'Cuentas por cobrar por cliente', 'al', to_char(p_hasta, 'YYYY-MM-DD'),
    'total_centavos', coalesce((SELECT sum(saldo) FROM c), 0),
    'de_0_a_30_centavos', coalesce((SELECT sum(a30) FROM c), 0), 'de_31_a_60_centavos', coalesce((SELECT sum(a60) FROM c), 0),
    'de_61_a_90_centavos', coalesce((SELECT sum(a90) FROM c), 0), 'mas_de_90_centavos', coalesce((SELECT sum(m90) FROM c), 0),
    'vencido_centavos', coalesce((SELECT sum(vencido) FROM c), 0),
    'clientes', coalesce((SELECT jsonb_agg(jsonb_build_object('cliente_id', c.cliente_id, 'nombre', c.nombre, 'rtn', c.rtn,
        'documentos', c.documentos, 'saldo_centavos', c.saldo, 'de_0_a_30_centavos', c.a30, 'de_31_a_60_centavos', c.a60,
        'de_61_a_90_centavos', c.a90, 'mas_de_90_centavos', c.m90, 'vencido_centavos', c.vencido) ORDER BY c.nombre, c.cliente_id) FROM c), '[]'),
    'documentos', coalesce((SELECT jsonb_agg(jsonb_build_object('documento_id', d.documento_id, 'origen', d.origen, 'cliente_id', d.cliente_id,
        'numero_documento', d.numero_documento, 'fecha_documento', to_char(d.fecha_documento, 'YYYY-MM-DD'),
        'vence_el', to_char(d.vence_el, 'YYYY-MM-DD'), 'monto_centavos', d.monto_centavos, 'saldo_centavos', d.saldo_centavos, 'dias', d.dias)
        ORDER BY d.fecha_documento, d.numero_documento) FROM d), '[]'))
$$;

-- Saldos por proveedor al cierre, con antigüedad y vencido.
CREATE FUNCTION interno.calcular_cxp(p_empresa_id uuid, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH d AS (SELECT x.*, p_hasta - x.fecha_documento AS dias FROM interno.cxp_al(p_empresa_id, p_hasta) x WHERE x.saldo_centavos <> 0),
  c AS (
    SELECT d.proveedor_id, t.nombre, t.rtn, count(*) AS documentos, sum(d.saldo_centavos)::bigint AS saldo,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias <= 30), 0)::bigint AS a30,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 31 AND 60), 0)::bigint AS a60,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 61 AND 90), 0)::bigint AS a90,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias > 90), 0)::bigint AS m90,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.vence_el < p_hasta), 0)::bigint AS vencido
      FROM d JOIN public.tercero t ON t.id = d.proveedor_id
     GROUP BY d.proveedor_id, t.nombre, t.rtn)
  SELECT jsonb_build_object('titulo', 'Cuentas por pagar por proveedor', 'al', to_char(p_hasta, 'YYYY-MM-DD'),
    'total_centavos', coalesce((SELECT sum(saldo) FROM c), 0), 'vencido_centavos', coalesce((SELECT sum(vencido) FROM c), 0),
    'proveedores', coalesce((SELECT jsonb_agg(jsonb_build_object('proveedor_id', c.proveedor_id, 'nombre', c.nombre, 'rtn', c.rtn,
        'documentos', c.documentos, 'saldo_centavos', c.saldo, 'de_0_a_30_centavos', c.a30, 'de_31_a_60_centavos', c.a60,
        'de_61_a_90_centavos', c.a90, 'mas_de_90_centavos', c.m90, 'vencido_centavos', c.vencido) ORDER BY c.nombre, c.proveedor_id) FROM c), '[]'),
    'documentos', coalesce((SELECT jsonb_agg(jsonb_build_object('documento_id', d.documento_id, 'origen', d.origen, 'proveedor_id', d.proveedor_id,
        'numero_documento', d.numero_documento, 'fecha_documento', to_char(d.fecha_documento, 'YYYY-MM-DD'),
        'vence_el', to_char(d.vence_el, 'YYYY-MM-DD'), 'monto_centavos', d.monto_centavos, 'saldo_centavos', d.saldo_centavos, 'dias', d.dias)
        ORDER BY d.fecha_documento, d.numero_documento) FROM d), '[]'))
$$;

-- Inventario valorizado por producto y bodega al cierre (desde el kardex, por fecha).
CREATE FUNCTION interno.calcular_inventario(p_empresa_id uuid, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH s AS (
    SELECT m.bodega_id, m.producto_id, sum(m.cantidad) AS cantidad, sum(m.valor_centavos)::bigint AS valor
      FROM public.inventario_movimiento m
     WHERE m.empresa_id = p_empresa_id AND m.fecha_contable <= p_hasta
     GROUP BY m.bodega_id, m.producto_id
    HAVING sum(m.cantidad) <> 0 OR sum(m.valor_centavos) <> 0)
  SELECT jsonb_build_object('titulo', 'Inventario valorizado', 'al', to_char(p_hasta, 'YYYY-MM-DD'),
    'valor_inventario_centavos', coalesce((SELECT sum(valor) FROM s), 0),
    'productos', coalesce((SELECT jsonb_agg(jsonb_build_object('producto_id', s.producto_id, 'codigo', p.codigo, 'producto', p.nombre,
        'bodega_id', s.bodega_id, 'bodega', b.codigo || ' ' || b.nombre, 'cantidad', s.cantidad, 'valor_inventario_centavos', s.valor,
        'costo_promedio_centavos', CASE WHEN s.cantidad <> 0 THEN round(s.valor / s.cantidad, 6) END) ORDER BY p.codigo, b.codigo)
      FROM s JOIN public.producto p ON p.id = s.producto_id JOIN public.bodega b ON b.id = s.bodega_id), '[]'))
$$;

-- Cuentas de dinero: saldo inicial, entradas, salidas y saldo final del período.
CREATE FUNCTION interno.calcular_dinero(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH s AS (
    SELECT d.id, d.tipo, d.nombre, d.banco, d.numero_enmascarado, d.activa,
           coalesce(sum(m.monto_centavos) FILTER (WHERE m.fecha_contable < p_desde), 0)::bigint AS ini,
           coalesce(sum(m.monto_centavos) FILTER (WHERE m.fecha_contable >= p_desde AND m.monto_centavos > 0), 0)::bigint AS ent,
           coalesce(-sum(m.monto_centavos) FILTER (WHERE m.fecha_contable >= p_desde AND m.monto_centavos < 0), 0)::bigint AS sal,
           coalesce(sum(m.monto_centavos), 0)::bigint AS fin
      FROM public.cuenta_dinero d
      LEFT JOIN public.dinero_movimiento m ON m.cuenta_dinero_id = d.id AND m.fecha_contable <= p_hasta
     WHERE d.empresa_id = p_empresa_id
     GROUP BY d.id)
  SELECT jsonb_build_object('titulo', 'Cuentas de dinero', 'desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'saldo_inicial_centavos', coalesce((SELECT sum(ini) FROM s), 0), 'saldo_final_centavos', coalesce((SELECT sum(fin) FROM s), 0),
    'cuentas', coalesce((SELECT jsonb_agg(jsonb_build_object('cuenta_dinero_id', s.id, 'tipo', s.tipo, 'nombre', s.nombre, 'banco', s.banco,
        'numero_enmascarado', s.numero_enmascarado, 'saldo_inicial_centavos', s.ini, 'entradas_centavos', s.ent, 'salidas_centavos', s.sal,
        'saldo_final_centavos', s.fin, 'en_negativo', s.fin < 0) ORDER BY s.tipo, s.nombre)
      FROM s WHERE s.activa OR s.ini <> 0 OR s.ent <> 0 OR s.sal <> 0 OR s.fin <> 0), '[]'))
$$;

-- Saldo a favor de clientes / vales y anticipos de apartados (los pasivos, al cierre).
CREATE FUNCTION interno.calcular_saldo_favor(p_empresa_id uuid, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('titulo', 'Saldos a favor, vales y anticipos de clientes', 'al', to_char(p_hasta, 'YYYY-MM-DD'),
    'saldo_favor_y_vales_centavos', interno.saldo_libros_al(p_empresa_id, interno.cuenta_de(p_empresa_id, 'saldo_favor'), p_hasta),
    'anticipos_apartados_centavos', interno.saldo_libros_al(p_empresa_id, interno.cuenta_de(p_empresa_id, 'anticipo_clientes'), p_hasta))
$$;

-- Comisiones por pagar al cierre, por vendedor.
CREATE FUNCTION interno.calcular_comisiones(p_empresa_id uuid, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH v AS (
    SELECT x.vendedor_id, sum(x.monto)::bigint AS por_pagar FROM (
      SELECT m.vendedor_id, m.monto_centavos AS monto FROM public.comision_movimiento m
       WHERE m.empresa_id = p_empresa_id AND m.fecha_contable <= p_hasta
      UNION ALL
      SELECT l.vendedor_id, -l.monto_centavos FROM public.comision_liquidacion l
       WHERE l.empresa_id = p_empresa_id AND l.fecha_contable <= p_hasta
         AND (l.anulada_en IS NULL OR l.fecha_anulacion > p_hasta)) x
     GROUP BY x.vendedor_id HAVING sum(x.monto) <> 0)
  SELECT jsonb_build_object('titulo', 'Comisiones por pagar', 'al', to_char(p_hasta, 'YYYY-MM-DD'),
    'total_centavos', coalesce((SELECT sum(por_pagar) FROM v), 0),
    'libros_centavos', interno.saldo_libros_al(p_empresa_id, interno.cuenta_de(p_empresa_id, 'comisiones_por_pagar'), p_hasta),
    'vendedores', coalesce((SELECT jsonb_agg(jsonb_build_object('vendedor_id', v.vendedor_id,
        'vendedor', public.nombre_usuario(p_empresa_id, v.vendedor_id), 'por_pagar_centavos', v.por_pagar) ORDER BY v.vendedor_id) FROM v), '[]'))
$$;

-- ISV (impuestos) del mes: débito fiscal (ventas menos notas de crédito), crédito fiscal
-- (compras y gastos) y a pagar. Los asientos manuales sobre esas cuentas (por ejemplo el pago
-- a la SAR) van aparte.
CREATE FUNCTION interno.calcular_isv(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH ctas AS (
    SELECT DISTINCT i.cuenta_por_pagar AS codigo, 'debito'::text AS clase FROM public.impuesto i
     WHERE i.empresa_id = p_empresa_id AND i.cuenta_por_pagar IS NOT NULL
    UNION
    SELECT DISTINCT i.cuenta_credito_fiscal, 'credito' FROM public.impuesto i
     WHERE i.empresa_id = p_empresa_id AND i.cuenta_credito_fiscal IS NOT NULL
    UNION
    SELECT interno.cuenta_de(p_empresa_id, 'isv_credito'), 'credito'),
  mov AS (
    SELECT k.clase, a.origen = 'manual' AS manual,
           sum(CASE WHEN k.clase = 'debito' THEN l.haber_centavos - l.debe_centavos ELSE l.debe_centavos - l.haber_centavos END)::bigint AS monto
      FROM public.asiento_linea l
      JOIN public.asiento a ON a.id = l.asiento_id
      JOIN public.cuenta c ON c.id = l.cuenta_id
      JOIN ctas k ON k.codigo = c.codigo
     WHERE l.empresa_id = p_empresa_id AND a.fecha_contable BETWEEN p_desde AND p_hasta
     GROUP BY k.clase, a.origen = 'manual')
  SELECT jsonb_build_object('titulo', 'Impuesto sobre ventas del mes', 'desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'debito_fiscal_centavos', coalesce((SELECT sum(monto) FROM mov WHERE clase = 'debito' AND NOT manual), 0),
    'credito_fiscal_centavos', coalesce((SELECT sum(monto) FROM mov WHERE clase = 'credito' AND NOT manual), 0),
    'a_pagar_centavos', coalesce((SELECT sum(monto) FROM mov WHERE clase = 'debito' AND NOT manual), 0)
                        - coalesce((SELECT sum(monto) FROM mov WHERE clase = 'credito' AND NOT manual), 0),
    'ajustes_manuales_debito_centavos', coalesce((SELECT sum(monto) FROM mov WHERE clase = 'debito' AND manual), 0),
    'ajustes_manuales_credito_centavos', coalesce((SELECT sum(monto) FROM mov WHERE clase = 'credito' AND manual), 0),
    'cuentas', (SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', k.codigo, 'clase', k.clase,
                  'saldo_final_centavos', interno.saldo_libros_al(p_empresa_id, k.codigo, p_hasta)) ORDER BY k.clase, k.codigo), '[]') FROM ctas k),
    'nota', 'Débito: impuesto de ventas menos notas de crédito. Crédito: impuesto de compras y gastos con factura. A pagar negativo = crédito a favor para el mes siguiente.')
$$;

-- Una sección calculada en vivo.
CREATE FUNCTION interno.calcular_seccion(p_empresa_id uuid, p_desde date, p_hasta date, p_seccion text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN CASE p_seccion
    WHEN 'estado_resultados' THEN interno.calcular_estado_resultados(p_empresa_id, p_desde, p_hasta)
    WHEN 'balance_general'   THEN interno.calcular_balance(p_empresa_id, p_hasta)
    WHEN 'flujo_efectivo'    THEN interno.calcular_flujo(p_empresa_id, p_desde, p_hasta)
    WHEN 'saldos_cuentas'    THEN interno.calcular_saldos_cuentas(p_empresa_id, p_desde, p_hasta)
    WHEN 'cuentas_por_cobrar' THEN interno.calcular_cxc(p_empresa_id, p_hasta)
    WHEN 'cuentas_por_pagar' THEN interno.calcular_cxp(p_empresa_id, p_hasta)
    WHEN 'inventario'        THEN interno.calcular_inventario(p_empresa_id, p_hasta)
    WHEN 'dinero'            THEN interno.calcular_dinero(p_empresa_id, p_desde, p_hasta)
    WHEN 'saldo_favor'       THEN interno.calcular_saldo_favor(p_empresa_id, p_hasta)
    WHEN 'comisiones'        THEN interno.calcular_comisiones(p_empresa_id, p_hasta)
    WHEN 'isv'               THEN interno.calcular_isv(p_empresa_id, p_desde, p_hasta)
  END;
END $$;

-- Las secciones de la foto, en el orden en que se imprimen.
CREATE FUNCTION interno.secciones_mes() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['estado_resultados', 'balance_general', 'flujo_efectivo', 'saldos_cuentas', 'cuentas_por_cobrar',
               'cuentas_por_pagar', 'inventario', 'dinero', 'saldo_favor', 'comisiones', 'isv']
$$;

-- Descuadre contable hasta una fecha (lo único que impide cerrar).
CREATE FUNCTION interno.descuadres_mes(p_empresa_id uuid, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH t AS (
    SELECT coalesce(sum(l.debe_centavos), 0) AS debe, coalesce(sum(l.haber_centavos), 0) AS haber
      FROM public.asiento_linea l JOIN public.asiento a ON a.id = l.asiento_id
     WHERE l.empresa_id = p_empresa_id AND a.fecha_contable <= p_hasta),
  malos AS (
    SELECT a.numero FROM public.asiento a
      LEFT JOIN public.asiento_linea l ON l.asiento_id = a.id
     WHERE a.empresa_id = p_empresa_id AND a.fecha_contable <= p_hasta
     GROUP BY a.id, a.numero, a.total_centavos
    HAVING coalesce(sum(l.debe_centavos), 0) <> coalesce(sum(l.haber_centavos), 0)
        OR coalesce(sum(l.debe_centavos), 0) <> a.total_centavos)
  SELECT coalesce(
    (SELECT jsonb_agg(x) FROM (
       SELECT jsonb_build_object('tipo', 'debe_haber', 'mensaje', 'El total del debe (' || interno.lempiras(t.debe::bigint)
              || ') no es igual al del haber (' || interno.lempiras(t.haber::bigint) || ').') AS x
         FROM t WHERE t.debe <> t.haber
       UNION ALL
       SELECT jsonb_build_object('tipo', 'asientos_descuadrados', 'mensaje', 'Asientos que no cuadran: '
              || (SELECT string_agg('#' || m.numero, ', ' ORDER BY m.numero) FROM malos m))
        WHERE EXISTS (SELECT 1 FROM malos)) y), '[]')
$$;

-- Lo que NO bloquea el cierre, pero el dueño debe ver (advertencias).
CREATE FUNCTION interno.advertencias_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_fin date := (make_date(p_anio, p_mes, 1) + interval '1 month' - interval '1 day')::date;
  v_adv jsonb := '[]';
  r     record;
BEGIN
  -- Depósitos en tránsito (sin confirmar) hechos hasta el fin del mes.
  SELECT count(*) AS n, coalesce(sum(o.monto_centavos), 0)::bigint AS monto INTO r
    FROM public.operacion_dinero o
   WHERE o.empresa_id = p_empresa_id AND o.tipo = 'deposito' AND o.anulada_en IS NULL AND o.fecha_contable <= v_fin
     AND (o.estado = 'en_transito' OR o.fecha_confirmacion > v_fin);
  IF r.n > 0 THEN
    v_adv := v_adv || jsonb_build_object('tipo', 'depositos_en_transito', 'cantidad', r.n, 'monto_centavos', r.monto,
      'mensaje', r.n || ' depósito(s) en tránsito al cierre por ' || interno.lempiras(r.monto) || '. Confírmelos cuando el banco los acredite.');
  END IF;
  -- Turnos de caja abiertos (abiertos en o antes del fin del mes).
  SELECT count(*) AS n INTO r FROM public.turno_caja t
   WHERE t.empresa_id = p_empresa_id AND t.fecha_apertura <= v_fin AND (t.estado = 'abierto' OR t.fecha_cierre > v_fin);
  IF r.n > 0 THEN
    v_adv := v_adv || jsonb_build_object('tipo', 'turnos_abiertos', 'cantidad', r.n, 'monto_centavos', NULL,
      'mensaje', r.n || ' turno(s) de caja seguían abiertos al fin del mes. Ciérrelos con su arqueo.');
  END IF;
  -- Aprobaciones pendientes.
  SELECT count(*) AS n, coalesce(sum(a.monto_centavos), 0)::bigint AS monto INTO r
    FROM public.aprobacion a WHERE a.empresa_id = p_empresa_id AND a.estado = 'pendiente';
  IF r.n > 0 THEN
    v_adv := v_adv || jsonb_build_object('tipo', 'aprobaciones_pendientes', 'cantidad', r.n, 'monto_centavos', r.monto,
      'mensaje', r.n || ' solicitud(es) de aprobación pendientes. Lo pendiente no movió dinero ni inventario.');
  END IF;
  -- Transferencias de clientes por confirmar (ventas y cobros hasta el fin del mes).
  SELECT count(*) AS n, coalesce(sum(x.monto), 0)::bigint AS monto INTO r FROM (
    SELECT g.monto_centavos AS monto FROM public.venta_pago g JOIN public.venta v ON v.id = g.venta_id
     WHERE g.empresa_id = p_empresa_id AND g.estado_transferencia = 'por_confirmar' AND v.estado = 'emitida' AND v.fecha_contable <= v_fin
    UNION ALL
    SELECT g.monto_centavos FROM public.cobro_pago g JOIN public.cobro c ON c.id = g.cobro_id
     WHERE g.empresa_id = p_empresa_id AND g.estado_transferencia = 'por_confirmar' AND c.anulada_en IS NULL AND c.fecha_contable <= v_fin) x;
  IF r.n > 0 THEN
    v_adv := v_adv || jsonb_build_object('tipo', 'transferencias_por_confirmar', 'cantidad', r.n, 'monto_centavos', r.monto,
      'mensaje', r.n || ' transferencia(s) de clientes por confirmar (' || interno.lempiras(r.monto) || '). Revise el banco y confírmelas.');
  END IF;
  -- Cuentas de dinero en negativo al fin del mes.
  SELECT count(*) AS n, coalesce(string_agg(x.nombre || ' (' || interno.lempiras(x.saldo) || ')', ', '), '') AS lista INTO r FROM (
    SELECT d.nombre, sum(m.monto_centavos)::bigint AS saldo FROM public.cuenta_dinero d
      JOIN public.dinero_movimiento m ON m.cuenta_dinero_id = d.id AND m.fecha_contable <= v_fin
     WHERE d.empresa_id = p_empresa_id GROUP BY d.id, d.nombre HAVING sum(m.monto_centavos) < 0) x;
  IF r.n > 0 THEN
    v_adv := v_adv || jsonb_build_object('tipo', 'cuentas_en_negativo', 'cantidad', r.n, 'monto_centavos', NULL,
      'mensaje', 'Cuentas de dinero en negativo al fin del mes: ' || r.lista || '. Revise el saldo inicial o la entrada que falta.');
  END IF;
  -- Alertas de cuadre: diferencias de arqueo sin resolver y módulos que no cuadran con su cuenta.
  SELECT count(*) AS n, coalesce(sum(t.diferencia_centavos), 0)::bigint AS monto INTO r FROM public.turno_caja t
   WHERE t.empresa_id = p_empresa_id AND t.diferencia_estado = 'pendiente' AND t.fecha_cierre <= v_fin;
  IF r.n > 0 THEN
    v_adv := v_adv || jsonb_build_object('tipo', 'alerta_cuadre', 'cantidad', r.n, 'monto_centavos', r.monto,
      'mensaje', r.n || ' diferencia(s) de arqueo sin resolver (' || interno.lempiras(r.monto) || '). Decida si se cobra al cajero o va a gasto.');
  END IF;
  FOR r IN
    SELECT 'dinero'::text AS que, d.nombre AS nombre, coalesce(sum(m.monto_centavos), 0)::bigint AS modulo,
           interno.saldo_libros_al(p_empresa_id, c.codigo, v_fin) AS libros
      FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
      LEFT JOIN public.dinero_movimiento m ON m.cuenta_dinero_id = d.id AND m.fecha_contable <= v_fin
     WHERE d.empresa_id = p_empresa_id GROUP BY d.id, d.nombre, c.codigo
    UNION ALL
    SELECT 'inventario', 'Inventario (kardex)', coalesce((SELECT sum(m.valor_centavos) FROM public.inventario_movimiento m
             WHERE m.empresa_id = p_empresa_id AND m.fecha_contable <= v_fin), 0)::bigint,
           interno.saldo_libros_al(p_empresa_id, interno.cuenta_de(p_empresa_id, 'inventario'), v_fin)
     WHERE interno.modulo_controla_cuenta(p_empresa_id, 'inventario')
    UNION ALL
    SELECT 'clientes', 'Cuentas por cobrar', coalesce((SELECT sum(x.saldo_centavos) FROM interno.cxc_al(p_empresa_id, v_fin) x), 0)::bigint,
           interno.saldo_libros_al(p_empresa_id, interno.cuenta_de(p_empresa_id, 'cxc'), v_fin)
     WHERE interno.modulo_controla_cuenta(p_empresa_id, 'ventas')
    UNION ALL
    SELECT 'proveedores', 'Cuentas por pagar', coalesce((SELECT sum(x.saldo_centavos) FROM interno.cxp_al(p_empresa_id, v_fin) x), 0)::bigint,
           interno.saldo_libros_al(p_empresa_id, interno.cuenta_de(p_empresa_id, 'cxp'), v_fin)
     WHERE interno.modulo_controla_cuenta(p_empresa_id, 'compras')
    UNION ALL
    SELECT 'comisiones', 'Comisiones por pagar', (interno.calcular_comisiones(p_empresa_id, v_fin)->>'total_centavos')::bigint,
           interno.saldo_libros_al(p_empresa_id, interno.cuenta_de(p_empresa_id, 'comisiones_por_pagar'), v_fin)
     WHERE interno.modulo_controla_cuenta(p_empresa_id, 'comisiones')
  LOOP
    IF r.modulo <> r.libros THEN
      v_adv := v_adv || jsonb_build_object('tipo', 'alerta_cuadre', 'cantidad', 1, 'monto_centavos', r.modulo - r.libros,
        'mensaje', r.nombre || ': el módulo suma ' || interno.lempiras(r.modulo) || ' y los libros ' || interno.lempiras(r.libros)
                   || ' al fin del mes. Avise a soporte.');
    END IF;
  END LOOP;
  RETURN v_adv || interno.advertencias_extra(p_empresa_id, p_anio, p_mes);
END $$;

-- Gancho para advertencias de otros módulos (fondos la reemplaza en 041).
CREATE FUNCTION interno.advertencias_extra(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT '[]'::jsonb
$$;

-- Rango del mes; valida año, mes e inicio de la empresa.
CREATE FUNCTION interno.rango_mes(p_empresa_id uuid, p_anio integer, p_mes integer, OUT o_desde date, OUT o_hasta date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_anio IS NULL OR p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 OR p_anio NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'PERIODO_INVALIDO: el mes o el año no son válidos.';
  END IF;
  o_desde := make_date(p_anio, p_mes, 1);
  o_hasta := (o_desde + interval '1 month' - interval '1 day')::date;
  IF o_hasta < (SELECT e.fecha_inicio FROM public.empresa e WHERE e.id = p_empresa_id) THEN
    RAISE EXCEPTION 'FECHA_ANTERIOR_AL_INICIO: el mes % es anterior al inicio de la empresa.', interno.mes_texto(o_desde);
  END IF;
END $$;

-- Resumen corto de una foto (lo que muestra el historial).
CREATE FUNCTION interno.resumen_mes(p_secciones jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'ventas_netas_centavos', (p_secciones->'estado_resultados'->>'ventas_netas_centavos')::bigint,
    'utilidad_neta_centavos', (p_secciones->'estado_resultados'->>'utilidad_neta_centavos')::bigint,
    'utilidad_cobrada_centavos', (p_secciones->'estado_resultados'->>'utilidad_cobrada_centavos')::bigint,
    'total_activo_centavos', (p_secciones->'balance_general'->>'total_activo_centavos')::bigint,
    'total_pasivo_centavos', (p_secciones->'balance_general'->>'total_pasivo_centavos')::bigint,
    'total_patrimonio_centavos', (p_secciones->'balance_general'->>'total_patrimonio_centavos')::bigint,
    'dinero_final_centavos', (p_secciones->'flujo_efectivo'->>'saldo_final_centavos')::bigint,
    'isv_a_pagar_centavos', (p_secciones->'isv'->>'a_pagar_centavos')::bigint)
$$;

-- Datos de la empresa para el encabezado de cada estado.
CREATE FUNCTION interno.encabezado_empresa(p_empresa_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('empresa_id', e.id, 'nombre', e.nombre, 'rtn', e.rtn, 'moneda', e.moneda, 'pais', e.pais)
    FROM public.empresa e WHERE e.id = p_empresa_id
$$;

-- ---------------------------------------------------------------------
-- 3) RPC: cerrar el mes con su foto
-- ---------------------------------------------------------------------
CREATE FUNCTION public.cerrar_mes(p_empresa_id uuid, p_anio integer, p_mes integer, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_desde date;
  v_hasta date;
  c       public.cierre;
  v_desc  jsonb;
  v_per   jsonb;
  v_adv   jsonb;
  v_sec   jsonb := '{}';
  s       text;
  v_ver   integer;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'periodos.cerrar');
  SELECT * INTO v_desde, v_hasta FROM interno.rango_mes(p_empresa_id, p_anio, p_mes);
  IF p_motivo IS NOT NULL AND length(trim(p_motivo)) > 500 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el motivo del cierre es de 500 letras o menos.';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);

  -- Ya cerrado con su foto: seguro reintentar.
  SELECT * INTO c FROM public.cierre x WHERE x.empresa_id = p_empresa_id AND x.anio = p_anio AND x.mes = p_mes AND x.estado = 'vigente';
  IF c.id IS NOT NULL AND EXISTS (SELECT 1 FROM public.periodo p WHERE p.empresa_id = p_empresa_id AND p.anio = p_anio
                                    AND p.mes = p_mes AND p.estado = 'cerrado') THEN
    RETURN jsonb_build_object('cierre_id', c.id, 'anio', p_anio, 'mes', p_mes, 'estado', 'cerrado', 'version', c.version,
      'advertencias', c.advertencias, 'resumen', c.resumen, 'ya_estaba', true);
  END IF;

  -- Descuadre contable: NO se cierra.
  v_desc := interno.descuadres_mes(p_empresa_id, v_hasta);
  IF jsonb_array_length(v_desc) > 0 THEN
    RAISE EXCEPTION 'DESCUADRE_CONTABLE: el mes % no se cierra: %', interno.mes_texto(v_desde),
      (SELECT string_agg(x->>'mensaje', ' ') FROM jsonb_array_elements(v_desc) x);
  END IF;

  -- El bloqueo de siempre (en orden, mes terminado; los meses vacíos de antes se cierran solos).
  v_per := public.cerrar_periodo(p_empresa_id, p_anio, p_mes);

  -- La foto.
  v_adv := interno.advertencias_mes(p_empresa_id, p_anio, p_mes);
  FOREACH s IN ARRAY interno.secciones_mes() LOOP
    v_sec := v_sec || jsonb_build_object(s, interno.calcular_seccion(p_empresa_id, v_desde, v_hasta, s));
  END LOOP;
  IF NOT (v_sec->'balance_general'->>'cuadra')::boolean THEN
    RAISE EXCEPTION 'DESCUADRE_CONTABLE: el balance del mes % no cuadra (activo % y pasivo más patrimonio %).', interno.mes_texto(v_desde),
      interno.lempiras((v_sec->'balance_general'->>'total_activo_centavos')::bigint),
      interno.lempiras((v_sec->'balance_general'->>'pasivo_mas_patrimonio_centavos')::bigint);
  END IF;
  SELECT coalesce(max(x.version), 0) + 1 INTO v_ver FROM public.cierre x WHERE x.empresa_id = p_empresa_id AND x.anio = p_anio AND x.mes = p_mes;

  PERFORM set_config('app.motivo', coalesce(nullif(trim(p_motivo), ''), 'Cierre del mes ' || interno.mes_texto(v_desde)), true);
  INSERT INTO public.cierre (empresa_id, anio, mes, version, motivo, advertencias, resumen, cerrado_por)
  VALUES (p_empresa_id, p_anio, p_mes, v_ver, nullif(trim(p_motivo), ''), v_adv, interno.resumen_mes(v_sec), auth.uid())
  RETURNING * INTO c;
  INSERT INTO public.cierre_detalle (cierre_id, empresa_id, seccion, datos)
  SELECT c.id, p_empresa_id, k, v_sec->k FROM unnest(interno.secciones_mes()) k;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('cierre_id', c.id, 'anio', p_anio, 'mes', p_mes, 'estado', 'cerrado', 'version', c.version,
    'advertencias', c.advertencias, 'resumen', c.resumen, 'ya_estaba', false,
    'meses_vacios_cerrados', (v_per->>'meses_vacios_cerrados')::integer);
END $$;

-- ---------------------------------------------------------------------
-- 4) Selector de meses (contabilidad.ver)
-- ---------------------------------------------------------------------
-- Una sección de un mes: la foto si el mes está cerrado con foto; si no, en vivo.
CREATE FUNCTION interno.seccion_mes(p_empresa_id uuid, p_anio integer, p_mes integer, p_seccion text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_desde date;
  v_hasta date;
  v_cerr  boolean;
  c       public.cierre;
  v_datos jsonb;
BEGIN
  SELECT * INTO v_desde, v_hasta FROM interno.rango_mes(p_empresa_id, p_anio, p_mes);
  v_cerr := EXISTS (SELECT 1 FROM public.periodo p WHERE p.empresa_id = p_empresa_id AND p.anio = p_anio AND p.mes = p_mes AND p.estado = 'cerrado');
  IF v_cerr THEN
    SELECT * INTO c FROM public.cierre x WHERE x.empresa_id = p_empresa_id AND x.anio = p_anio AND x.mes = p_mes AND x.estado = 'vigente';
    IF c.id IS NOT NULL THEN
      SELECT d.datos INTO v_datos FROM public.cierre_detalle d WHERE d.cierre_id = c.id AND d.seccion = p_seccion;
    END IF;
  END IF;
  IF v_datos IS NULL THEN
    v_datos := interno.calcular_seccion(p_empresa_id, v_desde, v_hasta, p_seccion);
  END IF;
  RETURN v_datos || jsonb_build_object(
    'empresa', interno.encabezado_empresa(p_empresa_id), 'anio', p_anio, 'mes', p_mes,
    'estado_mes', CASE WHEN v_cerr THEN 'cerrado' ELSE 'abierto' END,
    'fuente', CASE WHEN c.id IS NOT NULL AND v_cerr THEN 'foto' ELSE 'en_vivo' END,
    'preliminar', NOT v_cerr, 'cierre_id', c.id, 'version', c.version, 'cerrado_en', public.iso(c.cerrado_en),
    'generado_en', public.iso(now()),
    'nota', CASE WHEN v_cerr THEN 'Mes cerrado.' ELSE 'PRELIMINAR: el mes está abierto y las cifras pueden cambiar.' END
            || ' Formato según NIIF para PYMES, pendiente de validación por un contador hondureño.');
END $$;

-- Comparativo de un estado con el mes anterior y el mismo mes del año anterior (los campos dados).
CREATE FUNCTION interno.comparativo_mes(p_empresa_id uuid, p_anio integer, p_mes integer, p_seccion text, p_actual jsonb, p_campos text[])
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_res  jsonb := '{}';
  v_ant  date := make_date(p_anio, p_mes, 1) - interval '1 month';
  v_per  record;
  v_dat  jsonb;
  v_comp jsonb;
  k      text;
  v_inicio date := (SELECT date_trunc('month', e.fecha_inicio)::date FROM public.empresa e WHERE e.id = p_empresa_id);
BEGIN
  FOR v_per IN SELECT 'mes_anterior' AS clave, extract(year FROM v_ant)::integer AS anio, extract(month FROM v_ant)::integer AS mes
               UNION ALL SELECT 'mismo_mes_anio_anterior', p_anio - 1, p_mes LOOP
    IF make_date(v_per.anio, v_per.mes, 1) < v_inicio THEN
      v_res := v_res || jsonb_build_object(v_per.clave, NULL);
      CONTINUE;
    END IF;
    v_dat := interno.seccion_mes(p_empresa_id, v_per.anio, v_per.mes, p_seccion);
    v_comp := jsonb_build_object('anio', v_per.anio, 'mes', v_per.mes, 'fuente', v_dat->'fuente', 'preliminar', v_dat->'preliminar');
    FOREACH k IN ARRAY p_campos LOOP
      v_comp := v_comp || jsonb_build_object(k, v_dat->k,
        regexp_replace(k, '_centavos$', '') || '_variacion_centavos',
          CASE WHEN k LIKE '%\_centavos' THEN (p_actual->>k)::bigint - (v_dat->>k)::bigint END,
        regexp_replace(k, '_centavos$', '') || '_variacion_porcentaje',
          CASE WHEN k LIKE '%\_centavos' AND coalesce((v_dat->>k)::bigint, 0) <> 0
               THEN round(((p_actual->>k)::bigint - (v_dat->>k)::bigint) * 100.0 / abs((v_dat->>k)::bigint), 2) END);
    END LOOP;
    v_res := v_res || jsonb_build_object(v_per.clave, v_comp);
  END LOOP;
  RETURN v_res;
END $$;

CREATE FUNCTION public.estado_resultados(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  r := interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'estado_resultados');
  RETURN r || jsonb_build_object('comparativo', interno.comparativo_mes(p_empresa_id, p_anio, p_mes, 'estado_resultados', r,
    ARRAY['ventas_netas_centavos', 'costo_ventas_centavos', 'utilidad_bruta_centavos', 'margen_bruto_porcentaje',
          'gastos_operacion_centavos', 'utilidad_operativa_centavos', 'utilidad_neta_centavos', 'utilidad_cobrada_centavos']));
END $$;

CREATE FUNCTION public.balance_general(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  r := interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'balance_general');
  RETURN r || jsonb_build_object('comparativo', interno.comparativo_mes(p_empresa_id, p_anio, p_mes, 'balance_general', r,
    ARRAY['total_activo_centavos', 'total_pasivo_centavos', 'total_patrimonio_centavos']));
END $$;

CREATE FUNCTION public.flujo_efectivo(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  r := interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'flujo_efectivo');
  RETURN r || jsonb_build_object('comparativo', interno.comparativo_mes(p_empresa_id, p_anio, p_mes, 'flujo_efectivo', r,
    ARRAY['entradas_centavos', 'salidas_centavos', 'flujo_neto_centavos', 'saldo_final_centavos']));
END $$;

CREATE FUNCTION public.saldos_cuentas_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'saldos_cuentas');
END $$;

CREATE FUNCTION public.cuentas_por_cobrar_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'cuentas_por_cobrar');
END $$;

CREATE FUNCTION public.cuentas_por_pagar_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'cuentas_por_pagar');
END $$;

-- Valores del inventario: solo con inventario.costos (si no, en null y "costos_ocultos").
CREATE FUNCTION public.inventario_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.ocultar_costos(p_empresa_id, interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'inventario'),
                                ARRAY['valor_inventario_centavos', 'costo_promedio_centavos']);
END $$;

CREATE FUNCTION public.dinero_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'dinero');
END $$;

CREATE FUNCTION public.isv_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN interno.seccion_mes(p_empresa_id, p_anio, p_mes, 'isv');
END $$;

-- Todo el paquete del mes (para PDF y Excel en la app).
CREATE FUNCTION public.exportar_mes(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_desde date;
  v_hasta date;
  v_cerr  boolean;
  c       public.cierre;
  v_sec   jsonb := '{}';
  s       text;
  v_dat   jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  SELECT * INTO v_desde, v_hasta FROM interno.rango_mes(p_empresa_id, p_anio, p_mes);
  v_cerr := EXISTS (SELECT 1 FROM public.periodo p WHERE p.empresa_id = p_empresa_id AND p.anio = p_anio AND p.mes = p_mes AND p.estado = 'cerrado');
  IF v_cerr THEN
    SELECT * INTO c FROM public.cierre x WHERE x.empresa_id = p_empresa_id AND x.anio = p_anio AND x.mes = p_mes AND x.estado = 'vigente';
  END IF;
  FOREACH s IN ARRAY interno.secciones_mes() LOOP
    v_dat := NULL;
    IF c.id IS NOT NULL THEN
      SELECT d.datos INTO v_dat FROM public.cierre_detalle d WHERE d.cierre_id = c.id AND d.seccion = s;
    END IF;
    v_sec := v_sec || jsonb_build_object(s, coalesce(v_dat, interno.calcular_seccion(p_empresa_id, v_desde, v_hasta, s)));
  END LOOP;
  RETURN interno.ocultar_costos(p_empresa_id, jsonb_build_object(
    'formato', 'exportacion_mes_v1', 'empresa', interno.encabezado_empresa(p_empresa_id),
    'anio', p_anio, 'mes', p_mes, 'desde', to_char(v_desde, 'YYYY-MM-DD'), 'hasta', to_char(v_hasta, 'YYYY-MM-DD'),
    'estado_mes', CASE WHEN v_cerr THEN 'cerrado' ELSE 'abierto' END,
    'fuente', CASE WHEN c.id IS NOT NULL THEN 'foto' ELSE 'en_vivo' END, 'preliminar', NOT v_cerr,
    'cierre_id', c.id, 'version', c.version, 'cerrado_en', public.iso(c.cerrado_en),
    'cerrado_por', public.nombre_usuario(p_empresa_id, c.cerrado_por),
    'advertencias', CASE WHEN c.id IS NOT NULL THEN c.advertencias ELSE interno.advertencias_mes(p_empresa_id, p_anio, p_mes) END,
    'generado_en', public.iso(now()),
    'nota', CASE WHEN v_cerr THEN 'Mes cerrado.' ELSE 'PRELIMINAR: el mes está abierto y las cifras pueden cambiar.' END
            || ' Montos en centavos de la moneda de la empresa; fechas ISO 8601. Formato según NIIF para PYMES, pendiente de validación por un contador hondureño.',
    'secciones', v_sec), ARRAY['valor_inventario_centavos', 'costo_promedio_centavos']);
END $$;

-- Historial de versiones de los cierres (vigentes y superadas).
CREATE FUNCTION public.historial_cierres(p_empresa_id uuid, p_anio integer DEFAULT NULL, p_mes integer DEFAULT NULL)
RETURNS TABLE (cierre_id uuid, anio integer, mes integer, version integer, estado text, motivo text,
               cerrado_por text, cerrado_en text, superada_por text, superada_en text, motivo_superada text,
               advertencias jsonb, resumen jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'contabilidad.ver');
  RETURN QUERY
  SELECT c.id, c.anio, c.mes, c.version, c.estado, c.motivo, public.nombre_usuario(c.empresa_id, c.cerrado_por), public.iso(c.cerrado_en),
         public.nombre_usuario(c.empresa_id, c.superada_por), public.iso(c.superada_en), c.motivo_superada, c.advertencias, c.resumen
    FROM public.cierre c
   WHERE c.empresa_id = p_empresa_id AND (p_anio IS NULL OR c.anio = p_anio) AND (p_mes IS NULL OR c.mes = p_mes)
   ORDER BY c.anio DESC, c.mes DESC, c.version DESC;
END $$;

-- Una versión completa (también una superada).
CREATE FUNCTION public.ver_cierre(p_cierre_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.cierre;
BEGIN
  SELECT * INTO c FROM public.cierre WHERE id = p_cierre_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cierre no existe.';
  END IF;
  PERFORM interno.exigir_lectura(c.empresa_id, 'contabilidad.ver');
  RETURN interno.ocultar_costos(c.empresa_id, jsonb_build_object(
    'cierre_id', c.id, 'empresa', interno.encabezado_empresa(c.empresa_id), 'anio', c.anio, 'mes', c.mes, 'version', c.version,
    'estado', c.estado, 'motivo', c.motivo, 'cerrado_en', public.iso(c.cerrado_en), 'superada_en', public.iso(c.superada_en),
    'motivo_superada', c.motivo_superada, 'advertencias', c.advertencias, 'resumen', c.resumen,
    'secciones', (SELECT jsonb_object_agg(d.seccion, d.datos) FROM public.cierre_detalle d WHERE d.cierre_id = c.id)),
    ARRAY['valor_inventario_centavos', 'costo_promedio_centavos']);
END $$;

-- ---------------------------------------------------------------------
-- 5) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.proteger_cierre(), interno.superar_cierre(),
  interno.saldo_cuentas_base(uuid, date, date), interno.saldo_libros_al(uuid, text, date),
  interno.cxc_al(uuid, date), interno.utilidad_por_cobrar_al(uuid, date), interno.cxp_al(uuid, date),
  interno.linea_estado(text, bigint, text, integer, text),
  interno.calcular_estado_resultados(uuid, date, date), interno.calcular_balance(uuid, date),
  interno.nombre_operacion(text), interno.calcular_flujo(uuid, date, date), interno.calcular_saldos_cuentas(uuid, date, date),
  interno.calcular_cxc(uuid, date), interno.calcular_cxp(uuid, date), interno.calcular_inventario(uuid, date),
  interno.calcular_dinero(uuid, date, date), interno.calcular_saldo_favor(uuid, date), interno.calcular_comisiones(uuid, date),
  interno.calcular_isv(uuid, date, date), interno.calcular_seccion(uuid, date, date, text), interno.secciones_mes(),
  interno.descuadres_mes(uuid, date), interno.advertencias_mes(uuid, integer, integer), interno.advertencias_extra(uuid, integer, integer),
  interno.rango_mes(uuid, integer, integer), interno.resumen_mes(jsonb), interno.encabezado_empresa(uuid),
  interno.seccion_mes(uuid, integer, integer, text), interno.comparativo_mes(uuid, integer, integer, text, jsonb, text[])
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.cerrar_mes(uuid, integer, integer, text),
  public.estado_resultados(uuid, integer, integer), public.balance_general(uuid, integer, integer),
  public.flujo_efectivo(uuid, integer, integer), public.saldos_cuentas_mes(uuid, integer, integer),
  public.cuentas_por_cobrar_mes(uuid, integer, integer), public.cuentas_por_pagar_mes(uuid, integer, integer),
  public.inventario_mes(uuid, integer, integer), public.dinero_mes(uuid, integer, integer), public.isv_mes(uuid, integer, integer),
  public.exportar_mes(uuid, integer, integer), public.historial_cierres(uuid, integer, integer), public.ver_cierre(uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerrar_mes(uuid, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION
  public.estado_resultados(uuid, integer, integer), public.balance_general(uuid, integer, integer),
  public.flujo_efectivo(uuid, integer, integer), public.saldos_cuentas_mes(uuid, integer, integer),
  public.cuentas_por_cobrar_mes(uuid, integer, integer), public.cuentas_por_pagar_mes(uuid, integer, integer),
  public.inventario_mes(uuid, integer, integer), public.dinero_mes(uuid, integer, integer), public.isv_mes(uuid, integer, integer),
  public.exportar_mes(uuid, integer, integer), public.historial_cierres(uuid, integer, integer), public.ver_cierre(uuid)
TO authenticated, service_role;
