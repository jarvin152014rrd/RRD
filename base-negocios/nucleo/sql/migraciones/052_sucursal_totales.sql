-- =====================================================================
-- 052_sucursal_totales.sql  -  Núcleo 0.16.0: pendientes del núcleo que anotó
-- la app (app/PENDIENTES.md). Las 001-051 no se tocan.
--
--   1) Usuario limitado a su sucursal: recibe SOLO lo que le toca (antes la app
--      lo escondía en pantalla pero el dato llegaba al navegador). El dueño y
--      quien no tiene restricción reciben lo mismo que antes.
--        - Políticas RLS restrictivas: compra_linea, pago_proveedor,
--          pago_proveedor_anulacion, cxp_saldo_inicial (de toda la empresa),
--          las tablas de la conciliación (por la cuenta de banco) y, del lado de
--          clientes, cxc_saldo_inicial (de toda la empresa), cxc_aplicacion,
--          cxc_condonacion (por la venta), cobro_pago (por su cobro), saldo_favor
--          y saldo_favor_uso (por la sucursal del documento que creó el lote).
--          Así v_cxp_documento / v_cxp_proveedor / v_conciliacion quedan filtradas.
--        - v_comision_vendedor: solo comisiones de ventas de sus sucursales.
--        - donde_esta_mi_dinero, estado_fondos (saldo de la cuenta del fondo),
--          proyeccion_flujo: solo cuentas y documentos de sus sucursales.
--        - ver_conciliacion exige la sucursal del banco.
--        - condonar_saldo_cxc exige la sucursal de la venta (saldo inicial: no).
--        - pagar_proveedor / anular_pago_proveedor exigen la sucursal de la compra;
--          los saldos iniciales de proveedor son de toda la empresa (se guardan
--          con la primera sucursal solo por la contabilidad): el limitado no
--          los ve ni los paga.
--   2) Cobro "a la más vieja" de un usuario limitado: el servidor aplica solo a
--      facturas de SUS sucursales (salta las demás) y rechaza un "aplicar" a una
--      factura de otra sucursal o a un saldo inicial de cliente.
--   3) guardar_preferencias_alertas rechaza los tipos que el puesto no ve.
--   4) Lecturas de TOTALES (solo lectura; respetan empresa, permiso y sucursal):
--        totales_compras, totales_gastos, mas_vendido (resta devoluciones).
--   5) (NO se hace) estado de resultados / saldo de cuentas por sucursal: los
--      libros no asignan cada asiento a una sucursal (ver nucleo/docs/sucursales.md).
--   6) cerrar_mes y reabrir_periodo aceptan un id_operacion opcional al final
--      (las llamadas de antes siguen igual). Tabla periodo_operacion.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Ayudante: empresas donde el usuario conectado ve TODAS las sucursales
--    (dueño, sin restricción o la llave del servidor). Para políticas y vistas
--    (se calcula una vez por consulta con ARRAY(SELECT ...)).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.empresas_sin_restriccion() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT e.id FROM public.empresa e
   WHERE auth.uid() IS NULL AND coalesce(auth.role(), '') NOT IN ('anon', 'authenticated')
  UNION ALL
  SELECT ue.empresa_id FROM public.usuario_empresa ue
   WHERE ue.user_id = auth.uid() AND ue.activo
     AND (ue.rol = 'dueno'
          OR NOT EXISTS (SELECT 1 FROM public.usuario_sucursal us
                          WHERE us.empresa_id = ue.empresa_id AND us.user_id = ue.user_id AND us.activo))
$$;

-- ---------------------------------------------------------------------
-- 1a) Políticas restrictivas nuevas (se suman a "leer": hay que cumplir las dos)
-- ---------------------------------------------------------------------
-- Quien ve toda la empresa entra por el primer "OR" (empresas_sin_restriccion, una vez por
-- consulta) y no pasa por la subconsulta de la sucursal.
-- Saldo a favor (decisión 0.16.0): un lote se ve si su documento de origen (cobro, devolución,
-- apartado o venta anulada) es de una sucursal que el usuario ve; un cobro o apartado sin sucursal
-- (sin caja) es de toda la empresa: solo sin restricción. Sus usos, por el lote.
DO $$
DECLARE
  r     record;
  todo  constant text := 'empresa_id = ANY (ARRAY(SELECT public.empresas_sin_restriccion()))';
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('cxp_saldo_inicial',        NULL),
      ('compra_linea',             'compra_id IN (SELECT c.id FROM public.compra c)'),
      ('pago_proveedor',           'compra_id IN (SELECT c.id FROM public.compra c)'),
      ('pago_proveedor_anulacion', 'pago_id IN (SELECT p.id FROM public.pago_proveedor p)'),
      ('conciliacion',             'cuenta_dinero_id = ANY (ARRAY(SELECT public.cuentas_dinero_permitidas()))'),
      ('banco_movimiento',         'cuenta_dinero_id = ANY (ARRAY(SELECT public.cuentas_dinero_permitidas()))'),
      ('banco_importacion',        'conciliacion_id IN (SELECT c.id FROM public.conciliacion c)'),
      ('conciliacion_pareja',      'conciliacion_id IN (SELECT c.id FROM public.conciliacion c)'),
      ('banco_diferencia',         'banco_movimiento_id IN (SELECT b.id FROM public.banco_movimiento b)'),
      ('cxc_saldo_inicial',        NULL),
      ('cxc_aplicacion',           'venta_id IN (SELECT v.id FROM public.venta v)'),
      ('cxc_condonacion',          'venta_id IN (SELECT v.id FROM public.venta v)'),
      ('cobro_pago',               'cobro_id IN (SELECT c.id FROM public.cobro c)'),
      ('saldo_favor',              'documento_id IN (SELECT c.id FROM public.cobro c WHERE c.sucursal_id IS NOT NULL
                                      UNION ALL SELECT d.id FROM public.devolucion d
                                      UNION ALL SELECT a.id FROM public.apartado a WHERE a.sucursal_id IS NOT NULL
                                      UNION ALL SELECT v.id FROM public.venta v)'),
      ('saldo_favor_uso',          'saldo_favor_id IN (SELECT f.id FROM public.saldo_favor f)')) x(t, filtro) LOOP
    EXECUTE format('CREATE POLICY por_sucursal ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (%s%s)',
                   r.t, todo, CASE WHEN r.filtro IS NULL THEN '' ELSE ' OR ' || r.filtro END);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 1b) v_comision_vendedor (reemplaza la de 036; mismas columnas). Quien ve toda
--     la empresa: la misma cuenta de siempre (devengado - pagos vigentes). El
--     limitado: solo los movimientos de ventas de sus sucursales y, de ellos,
--     los que ya están en un pago vigente.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_comision_vendedor AS
  SELECT u.empresa_id, u.vendedor_id, public.nombre_usuario(u.empresa_id, u.vendedor_id) AS vendedor,
         x.devengado::bigint AS devengado_centavos,
         x.pagado::bigint AS pagado_centavos,
         (x.devengado - x.pagado)::bigint AS por_pagar_centavos
  FROM (SELECT DISTINCT m.empresa_id, m.vendedor_id FROM public.comision_movimiento m
          JOIN public.venta v ON v.id = m.venta_id
         WHERE v.sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas()))) u
  CROSS JOIN LATERAL (SELECT u.empresa_id = ANY (ARRAY(SELECT public.empresas_sin_restriccion())) AS todo) t
  CROSS JOIN LATERAL (
    SELECT CASE WHEN t.todo
             THEN coalesce((SELECT sum(m.monto_centavos) FROM public.comision_movimiento m
                             WHERE m.empresa_id = u.empresa_id AND m.vendedor_id = u.vendedor_id), 0)
             ELSE coalesce((SELECT sum(m.monto_centavos) FROM public.comision_movimiento m JOIN public.venta v ON v.id = m.venta_id
                             WHERE m.empresa_id = u.empresa_id AND m.vendedor_id = u.vendedor_id
                               AND v.sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas()))), 0) END AS devengado,
           CASE WHEN t.todo
             THEN coalesce((SELECT sum(l.monto_centavos) FROM public.comision_liquidacion l
                             WHERE l.empresa_id = u.empresa_id AND l.vendedor_id = u.vendedor_id AND l.anulada_en IS NULL), 0)
             ELSE coalesce((SELECT sum(m.monto_centavos) FROM public.comision_movimiento m JOIN public.venta v ON v.id = m.venta_id
                             WHERE m.empresa_id = u.empresa_id AND m.vendedor_id = u.vendedor_id
                               AND v.sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas()))
                               AND EXISTS (SELECT 1 FROM public.comision_liquidacion_detalle dd
                                             JOIN public.comision_liquidacion l ON l.id = dd.liquidacion_id
                                            WHERE dd.movimiento_id = m.id AND l.anulada_en IS NULL)), 0) END AS pagado) x
  WHERE u.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('comisiones.ver')));

-- ---------------------------------------------------------------------
-- 1c) donde_esta_mi_dinero (reemplaza la de 025; misma firma y respuesta).
--     Limitado: cuentas de sus sucursales y las de toda la empresa (sin sucursal),
--     depósitos en tránsito que salen o llegan a ellas; "otras cuentas de
--     efectivo sin rastro" (de los libros, sin sucursal) no se le muestran.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.donde_esta_mi_dinero(p_empresa_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cuentas  jsonb;
  v_tipos    jsonb;
  v_transito jsonb;
  v_otras    jsonb;
  v_alertas  jsonb;
  v_total    bigint;
  v_restr    boolean;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'dinero.ver');
  v_restr := interno.usuario_restringido(p_empresa_id);
  WITH s AS (
    SELECT d AS fila, d.*, interno.saldo_dinero(d.id) AS saldo, c.codigo AS cuenta_codigo
      FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
     WHERE d.empresa_id = p_empresa_id
       AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id)))
  SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', s.id, 'tipo', s.tipo, 'nombre', s.nombre,
           'banco', s.banco, 'numero_enmascarado', s.numero_enmascarado, 'sucursal_id', s.sucursal_id,
           'cuenta_codigo', s.cuenta_codigo, 'activa', s.activa, 'saldo_centavos', s.saldo,
           'fondo_fijo_centavos', s.fondo_fijo_centavos, 'turno_abierto_id', interno.turno_de_cuenta(s.id),
           'politica_saldo_negativo', s.politica_saldo_negativo, 'sobregiro_limite_centavos', s.sobregiro_limite_centavos,
           'alerta', interno.alerta_saldo_negativo(s.fila, s.saldo))
           ORDER BY s.tipo, s.nombre) FILTER (WHERE s.activa OR s.saldo <> 0), '[]'),
         coalesce(sum(s.saldo), 0),
         coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', s.id, 'nombre', s.nombre, 'saldo_centavos', s.saldo,
           'politica_saldo_negativo', s.politica_saldo_negativo, 'mensaje', interno.alerta_saldo_negativo(s.fila, s.saldo))
           ORDER BY s.nombre) FILTER (WHERE s.saldo < 0), '[]')
    INTO v_cuentas, v_total, v_alertas FROM s;
  SELECT coalesce(jsonb_object_agg(t.tipo, t.saldo), '{}') INTO v_tipos
    FROM (SELECT d.tipo, sum(interno.saldo_dinero(d.id))::bigint AS saldo
            FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id
             AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id))
           GROUP BY d.tipo) t;
  SELECT jsonb_build_object('total_centavos', coalesce(sum(o.monto_centavos), 0),
           'con_alerta', count(*) FILTER (WHERE (public.hoy_local(o.empresa_id) - o.fecha_contable) > e.dias_alerta_transito),
           'depositos', coalesce(jsonb_agg(jsonb_build_object('operacion_id', o.id, 'numero', o.numero,
              'fecha', to_char(o.fecha_contable, 'YYYY-MM-DD'), 'monto_centavos', o.monto_centavos,
              'banco', (SELECT CASE WHEN NOT v_restr OR interno.sucursal_permitida(p_empresa_id, x.sucursal_id) THEN x.nombre END
                          FROM public.cuenta_dinero x WHERE x.id = o.destino_id),   -- 0.16.0: de otra sucursal, null
              'dias', public.hoy_local(o.empresa_id) - o.fecha_contable,
              'alerta', (public.hoy_local(o.empresa_id) - o.fecha_contable) > e.dias_alerta_transito) ORDER BY o.fecha_contable), '[]'))
    INTO v_transito
    FROM public.operacion_dinero o JOIN public.empresa e ON e.id = o.empresa_id
   WHERE o.empresa_id = p_empresa_id AND o.tipo = 'deposito' AND o.estado = 'en_transito' AND o.anulada_en IS NULL
     AND (NOT v_restr
          OR interno.sucursal_permitida(p_empresa_id, (SELECT x.sucursal_id FROM public.cuenta_dinero x WHERE x.id = o.origen_id))
          OR interno.sucursal_permitida(p_empresa_id, (SELECT x.sucursal_id FROM public.cuenta_dinero x WHERE x.id = o.destino_id)));
  SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_codigo', x.codigo, 'nombre', x.nombre, 'saldo_centavos', x.saldo)
                            ORDER BY x.codigo), '[]')
    INTO v_otras
    FROM (SELECT c.codigo, c.nombre, interno.saldo_libros(p_empresa_id, c.codigo) AS saldo
            FROM public.cuenta c
           WHERE c.empresa_id = p_empresa_id AND c.es_detalle AND c.codigo LIKE '1.1.01.%' AND NOT v_restr
             AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d WHERE d.cuenta_id = c.id)) x
   WHERE x.saldo <> 0;
  RETURN jsonb_build_object('fecha', to_char(public.hoy_local(p_empresa_id), 'YYYY-MM-DD'), 'hora_servidor', public.iso(now()),
    'total_centavos', v_total, 'por_tipo', v_tipos, 'cuentas', v_cuentas, 'en_transito', v_transito,
    'otras_cuentas_efectivo_sin_rastro', v_otras,
    'total_con_otras_centavos', v_total + coalesce((SELECT sum((x->>'saldo_centavos')::bigint) FROM jsonb_array_elements(v_otras) x), 0),
    'alertas', v_alertas)
    || CASE WHEN v_restr THEN jsonb_build_object('solo_mis_sucursales', true) ELSE '{}'::jsonb END;
END $$;

-- ---------------------------------------------------------------------
-- 1d) estado_fondos (reemplaza la de 041; misma firma y respuesta). Limitado:
--     el saldo de la cuenta de dinero de un fondo que está en otra sucursal va en
--     null (los fondos y socios son de toda la empresa y se ven igual).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.estado_fondos(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_restr boolean;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'fondos.ver');
  v_restr := interno.usuario_restringido(p_empresa_id);
  RETURN jsonb_build_object(
    'empresa', interno.encabezado_empresa(p_empresa_id), 'generado_en', public.iso(now()),
    'fondos', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'fondo_id', f.id, 'nombre', f.nombre, 'tipo', f.tipo, 'activo', f.activo, 'cuenta_codigo', c.codigo,
        'saldo_centavos', interno.saldo_fondo(f.id),
        'aportes_centavos', coalesce((SELECT sum(m.monto_centavos) FROM public.fondo_movimiento m WHERE m.fondo_id = f.id AND m.tipo <> 'uso'), 0),
        'usos_centavos', coalesce((SELECT -sum(m.monto_centavos) FROM public.fondo_movimiento m WHERE m.fondo_id = f.id AND m.tipo = 'uso'), 0),
        'meta_tipo', f.meta_tipo, 'meta_meses', f.meta_meses, 'meta_centavos', interno.meta_fondo(f),
        'meta_porcentaje', CASE WHEN coalesce(interno.meta_fondo(f), 0) > 0
                                THEN round(interno.saldo_fondo(f.id) * 100.0 / interno.meta_fondo(f), 2) END,
        'cuenta_dinero_id', f.cuenta_dinero_id, 'cuenta_dinero', cd.nombre,
        'saldo_cuenta_dinero_centavos', CASE WHEN cd.id IS NOT NULL
                                              AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, cd.sucursal_id))
                                             THEN interno.saldo_dinero(cd.id) END,
        'libros_centavos', interno.saldo_libros(p_empresa_id, c.codigo),
        'usos_pendientes', (SELECT count(*) FROM public.fondo_uso u WHERE u.fondo_id = f.id AND u.estado = 'pendiente_aprobacion'))
        ORDER BY f.nombre)
      FROM public.fondo f JOIN public.cuenta c ON c.id = f.cuenta_id LEFT JOIN public.cuenta_dinero cd ON cd.id = f.cuenta_dinero_id
      WHERE f.empresa_id = p_empresa_id), '[]'),
    'socios', coalesce((SELECT jsonb_agg(jsonb_build_object('socio_id', s.id, 'nombre', s.nombre, 'porcentaje', s.porcentaje, 'activo', s.activo,
        'dividendos_pendientes_centavos', interno.dividendos_pendientes(s.id)) ORDER BY s.nombre)
      FROM public.socio s WHERE s.empresa_id = p_empresa_id), '[]'),
    'total_reservas_centavos', coalesce((SELECT sum(m.monto_centavos) FROM public.fondo_movimiento m WHERE m.empresa_id = p_empresa_id), 0),
    'dividendos_por_pagar_centavos', interno.total_dividendos_por_pagar(p_empresa_id),
    'dividendos_por_pagar_libros_centavos', interno.saldo_libros(p_empresa_id, interno.cuenta_de(p_empresa_id, 'dividendos_por_pagar')),
    'regla', (SELECT r.regla FROM public.regla_distribucion r WHERE r.empresa_id = p_empresa_id))
    || CASE WHEN v_restr THEN jsonb_build_object('solo_mis_sucursales', true) ELSE '{}'::jsonb END;
END $$;

-- ---------------------------------------------------------------------
-- 1e) proyeccion_flujo (reemplaza la de 042; misma firma y respuesta). Limitado:
--     dinero de sus cuentas (y las de toda la empresa), cobros de ventas emitidas
--     en sus sucursales, pagos de compras de sus sucursales, pagos fijos que no se
--     pagan desde una cuenta de otra sucursal. Comisiones y dividendos (de toda la
--     empresa) NO entran: van en "ocultos".
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.proyeccion_flujo(p_empresa_id uuid, p_dias integer DEFAULT 30, p_agrupar text DEFAULT 'semana')
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
  v_restr  boolean;
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
  v_restr := interno.usuario_restringido(p_empresa_id);
  v_hasta := v_hoy + p_dias;
  v_n := ceil((p_dias + 1) / 7.0)::integer;

  SELECT coalesce(sum(interno.saldo_dinero(d.id)), 0) INTO v_disp
    FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('efectivo_caja', 'banco', 'caja_chica')
     AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id));

  -- Cobros esperados (no vencidos, dentro del horizonte).
  SELECT coalesce(jsonb_agg(jsonb_build_object('semana', (x.vence_el - v_hoy) / 7 + 1, 'tipo', 'cobro', 'monto', x.saldo_centavos,
           'fecha', to_char(x.vence_el, 'YYYY-MM-DD'), 'detalle', t.nombre || ' ' || coalesce(x.numero_documento, ''))), '[]')
    INTO v_mov
    FROM interno.cxc_al(p_empresa_id, 'infinity') x JOIN public.tercero t ON t.id = x.cliente_id
   WHERE x.saldo_centavos > 0 AND x.vence_el BETWEEN v_hoy AND v_hasta
     AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, x.origen, x.documento_id));
  -- Pagos a proveedores (vencidos: semana 1).
  v_mov := v_mov || coalesce((SELECT jsonb_agg(jsonb_build_object('semana', greatest((x.vence_el - v_hoy) / 7 + 1, 1), 'tipo', 'pago_proveedor',
           'monto', -x.saldo_centavos, 'fecha', to_char(x.vence_el, 'YYYY-MM-DD'), 'detalle', t.nombre || ' ' || x.numero_documento))
    FROM interno.cxp_al(p_empresa_id, 'infinity') x JOIN public.tercero t ON t.id = x.proveedor_id
   WHERE x.saldo_centavos > 0 AND x.vence_el <= v_hasta
     AND (NOT v_restr OR interno.documento_cxp_permitido(p_empresa_id, x.origen, x.documento_id))), '[]');
  -- Pagos fijos sin pagar hasta el horizonte (atrasados: semana 1).
  v_mov := v_mov || coalesce((SELECT jsonb_agg(jsonb_build_object('semana', greatest((v.v - v_hoy) / 7 + 1, 1), 'tipo', 'pago_fijo',
           'monto', -p.monto_estimado_centavos, 'fecha', to_char(v.v, 'YYYY-MM-DD'), 'detalle', p.nombre))
    FROM public.pago_fijo p CROSS JOIN LATERAL interno.vencimientos_pago_fijo(p, v_hasta) AS v(v)
   WHERE p.empresa_id = p_empresa_id AND p.activo AND p.monto_estimado_centavos > 0
     AND (NOT v_restr OR p.cuenta_dinero_id IS NULL
          OR interno.sucursal_permitida(p_empresa_id, (SELECT d.sucursal_id FROM public.cuenta_dinero d WHERE d.id = p.cuenta_dinero_id)))
     AND NOT EXISTS (SELECT 1 FROM public.gasto g WHERE g.pago_fijo_id = p.id AND g.pago_fijo_vence_el = v.v
                       AND g.estado IN ('pendiente_aprobacion', 'aplicado'))), '[]');
  -- Comisiones por pagar (lo positivo de cada vendedor) y dividendos por pagar: semana 1 (de toda la empresa).
  IF NOT v_restr THEN
    v_mov := v_mov || coalesce((SELECT jsonb_agg(jsonb_build_object('semana', 1, 'tipo', 'comisiones', 'monto', -x.por_pagar,
             'fecha', to_char(v_hoy, 'YYYY-MM-DD'), 'detalle', coalesce(public.nombre_usuario(p_empresa_id, x.vendedor_id), 'Vendedor')))
      FROM (SELECT j->>'vendedor_id' AS vid, (j->>'vendedor_id')::uuid AS vendedor_id, (j->>'por_pagar_centavos')::bigint AS por_pagar
              FROM jsonb_array_elements(interno.calcular_comisiones(p_empresa_id, 'infinity')->'vendedores') j) x
     WHERE x.por_pagar > 0), '[]');
    IF interno.total_dividendos_por_pagar(p_empresa_id) > 0 THEN
      v_mov := v_mov || jsonb_build_object('semana', 1, 'tipo', 'dividendos', 'monto', -interno.total_dividendos_por_pagar(p_empresa_id),
                                           'fecha', to_char(v_hoy, 'YYYY-MM-DD'), 'detalle', 'Dividendos por pagar a socios');
    END IF;
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
        AND (d.activa OR interno.saldo_dinero(d.id) <> 0)
        AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id))),
    'no_disponible_aun', (SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', d.id, 'nombre', d.nombre, 'tipo', d.tipo,
        'saldo_centavos', interno.saldo_dinero(d.id)) ORDER BY d.tipo, d.nombre), '[]')
      FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('transito', 'transferencia_por_confirmar', 'pos_por_liquidar')
        AND interno.saldo_dinero(d.id) <> 0
        AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id))),
    'no_disponible_aun_centavos', (SELECT coalesce(sum(interno.saldo_dinero(d.id)), 0) FROM public.cuenta_dinero d
      WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('transito', 'transferencia_por_confirmar', 'pos_por_liquidar')
        AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id))),
    'cobros_vencidos_centavos', (SELECT coalesce(sum(x.saldo_centavos), 0) FROM interno.cxc_al(p_empresa_id, 'infinity') x
      WHERE x.saldo_centavos > 0 AND x.vence_el < v_hoy
        AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, x.origen, x.documento_id))),
    'cobros_vencidos', (SELECT coalesce(jsonb_agg(jsonb_build_object('cliente', t.nombre, 'numero_documento', x.numero_documento,
        'vence_el', to_char(x.vence_el, 'YYYY-MM-DD'), 'saldo_centavos', x.saldo_centavos) ORDER BY x.vence_el), '[]')
      FROM interno.cxc_al(p_empresa_id, 'infinity') x JOIN public.tercero t ON t.id = x.cliente_id
      WHERE x.saldo_centavos > 0 AND x.vence_el < v_hoy
        AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, x.origen, x.documento_id))),
    'cobros_despues_del_horizonte_centavos', (SELECT coalesce(sum(x.saldo_centavos), 0) FROM interno.cxc_al(p_empresa_id, 'infinity') x
      WHERE x.saldo_centavos > 0 AND x.vence_el > v_hasta
        AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, x.origen, x.documento_id))),
    'semanas', v_sem, 'saldo_final_proyectado_centavos', v_saldo,
    'alerta', jsonb_array_length(v_alert) > 0, 'alertas', v_alert,
    'detalle', (SELECT coalesce(jsonb_agg(m ORDER BY (m->>'semana')::integer, m->>'fecha', m->>'tipo'), '[]') FROM jsonb_array_elements(v_mov) m),
    'nota', 'Los cobros vencidos no se asumen; las cuentas por pagar vencidas, las comisiones y los dividendos por pagar se asumen en la semana 1. Pagos fijos con su monto estimado.')
    || CASE WHEN v_restr THEN jsonb_build_object('solo_mis_sucursales', true, 'ocultos', jsonb_build_array('comisiones', 'dividendos'),
         'nota_sucursal', 'Solo sus sucursales (y las cuentas de toda la empresa). Las comisiones y los dividendos son de toda la empresa y no se incluyen.')
            ELSE '{}'::jsonb END;
END $$;

-- ---------------------------------------------------------------------
-- 1f) ver_conciliacion (reemplaza la de 043; misma firma): exige la sucursal del banco.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ver_conciliacion(p_conciliacion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.conciliacion;
BEGIN
  SELECT * INTO c FROM public.conciliacion WHERE id = p_conciliacion_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la conciliación no existe.';
  END IF;
  PERFORM interno.exigir_lectura(c.empresa_id, 'conciliacion.ver');
  PERFORM interno.exigir_sucursal(c.empresa_id, (SELECT d.sucursal_id FROM public.cuenta_dinero d WHERE d.id = c.cuenta_dinero_id));
  IF c.estado = 'cerrada' THEN
    RETURN c.resumen_cierre || jsonb_build_object('generado_en', public.iso(c.cerrada_en), 'foto', true);
  END IF;
  RETURN interno.calcular_conciliacion(c) || jsonb_build_object('generado_en', public.iso(now()), 'foto', false);
END $$;

-- ---------------------------------------------------------------------
-- 1g) Pagos a proveedores: la sucursal del documento.
--     Compra: la de la compra. Saldo inicial: de toda la empresa (solo sin restricción).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.exigir_documento_cxp(p_empresa_id uuid, p_documento_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_suc uuid;
BEGIN
  SELECT c.sucursal_id INTO v_suc FROM public.compra c WHERE c.id = p_documento_id AND c.empresa_id = p_empresa_id;
  IF FOUND THEN
    PERFORM interno.exigir_sucursal(p_empresa_id, v_suc);
    RETURN;
  END IF;
  IF interno.usuario_restringido(p_empresa_id)
     AND EXISTS (SELECT 1 FROM public.cxp_saldo_inicial s WHERE s.id = p_documento_id AND s.empresa_id = p_empresa_id) THEN
    RAISE EXCEPTION 'SUCURSAL_NO_PERMITIDA: los saldos iniciales de proveedores son de toda la empresa; los paga alguien que trabaja con todas las sucursales.';
  END IF;
END $$;

-- pagar_proveedor (reemplaza la de 022; misma firma y respuesta). Nuevo: la sucursal del documento.
CREATE OR REPLACE FUNCTION public.pagar_proveedor(p_empresa_id uuid, p_compra_id uuid, p_monto_centavos bigint,
                                       p_fecha date, p_forma_pago text, p_id_operacion uuid,
                                       p_referencia text DEFAULT NULL, p_cuenta_pago text DEFAULT NULL,
                                       p_cuenta_dinero_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cod   text;
  v_forma text := p_forma_pago;
  r       jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.pagar', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'pago_proveedor');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'pago_proveedor');
  v_cod := p_cuenta_pago;
  IF p_id_operacion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.pago_proveedor x
                                                 WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    PERFORM interno.exigir_documento_cxp(p_empresa_id, p_compra_id);   -- 0.16.0
    v_cod := interno.codigo_cuenta_pago(p_empresa_id, p_cuenta_dinero_id, p_cuenta_pago);
    IF p_cuenta_dinero_id IS NOT NULL AND v_forma IS NULL THEN
      v_forma := CASE WHEN (SELECT x.tipo FROM public.cuenta_dinero x WHERE x.id = p_cuenta_dinero_id) = 'banco'
                      THEN 'banco' ELSE 'caja' END;
    END IF;
  END IF;
  r := interno.pagar_proveedor_base(p_empresa_id, p_compra_id, p_monto_centavos, p_fecha, v_forma,
                                    p_id_operacion, p_referencia, v_cod);
  IF NOT (r->>'duplicado')::boolean THEN
    PERFORM interno.rastrear_dinero((r->>'asiento_id')::uuid, 'pago_proveedor', 'pago_proveedor', (r->>'pago_id')::uuid,
                                    p_referencia, interno.equipo(NULL));
  END IF;
  RETURN r;
END $$;

-- anular_pago_proveedor (reemplaza la de 022; misma firma y respuesta). Nuevo: la sucursal del documento.
CREATE OR REPLACE FUNCTION public.anular_pago_proveedor(p_pago_id uuid, p_motivo text, p_id_operacion uuid,
                                                        p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_p public.pago_proveedor;
  r   jsonb;
BEGIN
  SELECT * INTO v_p FROM public.pago_proveedor p WHERE p.id = p_pago_id;
  IF v_p.id IS NOT NULL AND p_id_operacion IS NOT NULL THEN
    PERFORM interno.exigir_escritura(v_p.empresa_id, 'compras.anular', 'compras');
    PERFORM interno.exigir_tipo_operacion(v_p.empresa_id, p_id_operacion, 'anulacion_pago_proveedor');
    PERFORM interno.reservar_operacion(v_p.empresa_id, p_id_operacion, 'anulacion_pago_proveedor');
    IF NOT EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion a WHERE a.pago_id = v_p.id AND a.id_operacion = p_id_operacion) THEN
      PERFORM interno.exigir_documento_cxp(v_p.empresa_id, coalesce(v_p.compra_id, v_p.saldo_inicial_id));   -- 0.16.0
    END IF;
  END IF;
  r := interno.anular_pago_proveedor_base(p_pago_id, p_motivo, p_id_operacion, p_fecha);
  IF NOT (r->>'duplicado')::boolean THEN
    PERFORM interno.rastrear_dinero((r->>'asiento_id')::uuid, 'anulacion_pago_proveedor', 'pago_proveedor', p_pago_id,
                                    trim(p_motivo), NULL);
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 2) Cobro de un usuario limitado a su sucursal
-- ---------------------------------------------------------------------
-- Devuelve los datos del cobro listos para registrar_cobro_base:
--   * con "aplicar": cada factura debe ser una venta de SUS sucursales (un saldo
--     inicial de cliente es de toda la empresa: no);
--   * sin "aplicar" ("a la más vieja"): arma "aplicar" con las ventas al crédito de
--     sus sucursales, de la más vieja a la más nueva, hasta cubrir lo recibido (las
--     de otras sucursales y los saldos iniciales se saltan). Se calcula con el
--     candado de la empresa tomado (los saldos no cambian por debajo).
CREATE FUNCTION interno.cobro_solo_mis_sucursales(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       jsonb;
  pj      jsonb;
  v_cli   uuid;
  v_doc   uuid;
  v_total bigint := 0;
  v_resto bigint;
  v_saldo bigint;
  v_monto bigint;
  v_apl   jsonb := '[]';
  r       record;
BEGIN
  IF EXISTS (SELECT 1 FROM public.cobro x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    RETURN p_datos;   -- reintento: registrar_cobro_base devuelve el mismo cobro
  END IF;
  IF coalesce(p_datos->'aplicar', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_datos->'aplicar') = 'array' THEN
      FOR a IN SELECT * FROM jsonb_array_elements(p_datos->'aplicar') LOOP
        CONTINUE WHEN jsonb_typeof(a) <> 'object';
        IF coalesce(a->'saldo_inicial_id', 'null'::jsonb) <> 'null'::jsonb THEN
          RAISE EXCEPTION 'SUCURSAL_NO_PERMITIDA: los saldos iniciales de clientes son de toda la empresa; los cobra alguien que trabaja con todas las sucursales.';
        END IF;
        v_doc := interno.json_uuid(a->'venta_id', 'venta_id');
        IF v_doc IS NOT NULL THEN
          PERFORM interno.exigir_sucursal(p_empresa_id,
            (SELECT v.sucursal_id FROM public.venta v WHERE v.id = v_doc AND v.empresa_id = p_empresa_id));
        END IF;
      END LOOP;
    END IF;
    RETURN p_datos;   -- el resto lo valida registrar_cobro_base
  END IF;

  -- "A la más vieja": lo recibido (mismas reglas que registrar_cobro_base).
  v_cli := interno.json_uuid(p_datos->'cliente_id', 'cliente_id');
  IF v_cli IS NULL THEN
    RETURN p_datos;   -- registrar_cobro_base explica que falta el cliente
  END IF;
  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia o saldo a favor).';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    v_total := v_total + interno.json_centavos(pj->'monto_centavos', 'monto_centavos');
  END LOOP;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'cobro');
  IF EXISTS (SELECT 1 FROM public.cobro x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    RETURN p_datos;
  END IF;
  v_resto := v_total;
  FOR r IN SELECT v.id FROM public.venta v
            WHERE v.empresa_id = p_empresa_id AND v.cliente_id = v_cli AND v.estado = 'emitida' AND v.credito_centavos > 0
              AND interno.sucursal_permitida(p_empresa_id, v.sucursal_id)
            ORDER BY v.fecha_contable, v.vence_el, v.numero LOOP
    EXIT WHEN v_resto <= 0;
    PERFORM 1 FROM public.venta x WHERE x.id = r.id FOR UPDATE;
    v_saldo := interno.saldo_documento_cxc(r.id);
    CONTINUE WHEN v_saldo <= 0;
    v_monto := least(v_saldo, v_resto);
    v_apl := v_apl || jsonb_build_object('venta_id', r.id, 'monto_centavos', v_monto);
    v_resto := v_resto - v_monto;
  END LOOP;
  IF jsonb_array_length(v_apl) = 0 THEN
    RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: en sus sucursales este cliente no tiene facturas por cobrar (lo de otras sucursales lo cobra quien trabaja allá). Si deja dinero a favor, regístrelo como anticipo.';
  END IF;
  RETURN p_datos || jsonb_build_object('aplicar', v_apl);
END $$;

-- registrar_cobro (reemplaza la de 033; misma firma y respuesta). Nuevo: usuario limitado.
CREATE OR REPLACE FUNCTION public.registrar_cobro(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_datos jsonb := p_datos;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.vender', 'ventas');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'cobro');
  IF p_id_operacion IS NOT NULL AND jsonb_typeof(p_datos) = 'object' AND interno.usuario_restringido(p_empresa_id)
     AND coalesce(p_datos->>'tipo', 'cxc') = 'cxc' THEN
    v_datos := interno.cobro_solo_mis_sucursales(p_empresa_id, p_datos, p_id_operacion);
  END IF;
  RETURN interno.registrar_cobro_base(p_empresa_id, v_datos, p_id_operacion);
END $$;

-- condonar_saldo_cxc (misma firma y respuesta): la de 033 pasa a interno sin cambios y la pública
-- revisa antes la sucursal de la venta; un saldo inicial de cliente (de toda la empresa), solo sin restricción.
ALTER FUNCTION public.condonar_saldo_cxc(uuid, jsonb, text, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.condonar_saldo_cxc(uuid, jsonb, text, uuid) RENAME TO condonar_saldo_cxc_base;

CREATE FUNCTION public.condonar_saldo_cxc(p_empresa_id uuid, p_datos jsonb, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_doc uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'cobros.condonar', 'ventas');
  IF p_id_operacion IS NOT NULL AND jsonb_typeof(p_datos) = 'object' AND interno.usuario_restringido(p_empresa_id)
     AND NOT EXISTS (SELECT 1 FROM public.cxc_condonacion c WHERE c.empresa_id = p_empresa_id AND c.id_operacion = p_id_operacion) THEN
    IF coalesce(p_datos->'saldo_inicial_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'SUCURSAL_NO_PERMITIDA: los saldos iniciales de clientes son de toda la empresa; los condona alguien que trabaja con todas las sucursales.';
    END IF;
    v_doc := interno.json_uuid(p_datos->'venta_id', 'venta_id');
    IF v_doc IS NOT NULL THEN
      PERFORM interno.exigir_sucursal(p_empresa_id, (SELECT v.sucursal_id FROM public.venta v WHERE v.id = v_doc AND v.empresa_id = p_empresa_id));
    END IF;
  END IF;
  RETURN interno.condonar_saldo_cxc_base(p_empresa_id, p_datos, p_motivo, p_id_operacion);
END $$;

-- ---------------------------------------------------------------------
-- 3) Preferencias de alertas: solo de los tipos que el puesto ve
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_preferencias_alertas(p_empresa_id uuid, p_datos jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text;
        v jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  PERFORM interno.exigir_miembro(p_empresa_id);
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: las preferencias van como {"tipo": true/false}.';
  END IF;
  FOR k, v IN SELECT * FROM jsonb_each(p_datos) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.alerta_tipo t WHERE t.codigo = k) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: no existe el tipo de alerta "%".', k;
    END IF;
    IF jsonb_typeof(v) <> 'boolean' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "%" va con true o false.', k;
    END IF;
    IF NOT interno.puede_ver_alerta(p_empresa_id, k) THEN   -- 0.16.0
      RAISE EXCEPTION 'SIN_PERMISO: su puesto no recibe las alertas de tipo "%"; no puede guardar esa preferencia.', k;
    END IF;
    INSERT INTO public.alerta_preferencia (empresa_id, user_id, tipo, recibir) VALUES (p_empresa_id, auth.uid(), k, v::boolean)
    ON CONFLICT (empresa_id, user_id, tipo) DO UPDATE SET recibir = EXCLUDED.recibir, actualizado_en = now();
  END LOOP;
  RETURN public.mis_preferencias_alertas(p_empresa_id);
END $$;

-- ---------------------------------------------------------------------
-- 4) Lecturas de totales (la app ya no suma en el navegador)
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.exigir_rango(p_desde date, p_hasta date, p_max_dias integer) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique desde y hasta (desde antes que hasta).';
  END IF;
  IF p_max_dias IS NOT NULL AND p_hasta - p_desde > p_max_dias THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el rango es de % días como máximo.', p_max_dias;
  END IF;
END $$;

-- totales_compras(empresa, desde, hasta, proveedor?)   compras.ver
-- Compras con fecha en el rango (de sus sucursales si es limitado):
--   cantidad (todas), anuladas, vigentes; total, contado y crédito de las vigentes;
--   por_pagar = lo que falta pagar de las vigentes al crédito (pagos anulados no
--   cuentan); vencido = la parte de eso ya vencida hoy.
CREATE FUNCTION public.totales_compras(p_empresa_id uuid, p_desde date, p_hasta date, p_proveedor_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy date;
  r     jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'compras.ver');
  PERFORM interno.exigir_rango(p_desde, p_hasta, NULL);
  v_hoy := public.hoy_local(p_empresa_id);
  WITH c AS (
    SELECT x.*, x.anulada_en IS NULL AS vigente,
           CASE WHEN x.anulada_en IS NULL AND x.condicion = 'credito'
                THEN x.total_centavos - interno.pagado_documento_cxp(x.id) ELSE 0 END AS saldo
      FROM public.compra x
     WHERE x.empresa_id = p_empresa_id AND x.fecha_contable BETWEEN p_desde AND p_hasta
       AND (p_proveedor_id IS NULL OR x.proveedor_id = p_proveedor_id)
       AND interno.sucursal_permitida(p_empresa_id, x.sucursal_id))
  SELECT jsonb_build_object(
    'cantidad', count(*),
    'anuladas', count(*) FILTER (WHERE NOT c.vigente),
    'vigentes', count(*) FILTER (WHERE c.vigente),
    'total_centavos', coalesce(sum(c.total_centavos) FILTER (WHERE c.vigente), 0),
    'subtotal_centavos', coalesce(sum(c.subtotal_centavos) FILTER (WHERE c.vigente), 0),
    'isv_centavos', coalesce(sum(c.isv_centavos) FILTER (WHERE c.vigente), 0),
    'contado_centavos', coalesce(sum(c.total_centavos) FILTER (WHERE c.vigente AND c.condicion = 'contado'), 0),
    'credito_centavos', coalesce(sum(c.total_centavos) FILTER (WHERE c.vigente AND c.condicion = 'credito'), 0),
    'por_pagar_centavos', coalesce(sum(c.saldo), 0),
    'vencido_centavos', coalesce(sum(c.saldo) FILTER (WHERE c.fecha_vencimiento < v_hoy), 0),
    'por_pagar_cantidad', count(*) FILTER (WHERE c.saldo > 0))
    INTO r FROM c;
  RETURN r || jsonb_build_object('desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'proveedor_id', p_proveedor_id, 'solo_mis_sucursales', interno.usuario_restringido(p_empresa_id), 'generado_en', public.iso(now()),
    'nota', 'Compras con fecha en el rango. Total, contado y crédito: solo las no anuladas. Por pagar: lo que falta pagar de esas compras al crédito.');
END $$;

-- totales_gastos(empresa, desde, hasta, categoria?, cuenta_dinero?)   dinero.ver
-- Gastos con fecha en el rango (de sus sucursales si es limitado; los de toda la empresa
-- sin sucursal se ven igual que en v_gasto): gastado = aplicados (con ISV) y su parte sin
-- ISV; en espera = pendientes de aprobación; cantidades por estado.
CREATE FUNCTION public.totales_gastos(p_empresa_id uuid, p_desde date, p_hasta date,
                                      p_categoria_id uuid DEFAULT NULL, p_cuenta_dinero_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'dinero.ver');
  PERFORM interno.exigir_rango(p_desde, p_hasta, NULL);
  SELECT jsonb_build_object(
    'cantidad', count(*),
    'gastado_centavos', coalesce(sum(g.monto_centavos) FILTER (WHERE g.estado = 'aplicado'), 0),
    'gastado_sin_isv_centavos', coalesce(sum(g.monto_centavos - g.isv_centavos) FILTER (WHERE g.estado = 'aplicado'), 0),
    'gastado_isv_centavos', coalesce(sum(g.isv_centavos) FILTER (WHERE g.estado = 'aplicado'), 0),
    'aplicados', count(*) FILTER (WHERE g.estado = 'aplicado'),
    'en_espera_centavos', coalesce(sum(g.monto_centavos) FILTER (WHERE g.estado = 'pendiente_aprobacion'), 0),
    'en_espera', count(*) FILTER (WHERE g.estado = 'pendiente_aprobacion'),
    'rechazados', count(*) FILTER (WHERE g.estado = 'rechazado'),
    'anulados', count(*) FILTER (WHERE g.estado = 'anulado'))
    INTO r
    FROM public.gasto g
   WHERE g.empresa_id = p_empresa_id AND g.fecha_contable BETWEEN p_desde AND p_hasta
     AND (p_categoria_id IS NULL OR g.categoria_id = p_categoria_id)
     AND (p_cuenta_dinero_id IS NULL OR g.cuenta_dinero_id = p_cuenta_dinero_id)
     AND interno.sucursal_permitida(p_empresa_id, g.sucursal_id);
  RETURN r || jsonb_build_object('desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'categoria_id', p_categoria_id, 'cuenta_dinero_id', p_cuenta_dinero_id,
    'solo_mis_sucursales', interno.usuario_restringido(p_empresa_id), 'generado_en', public.iso(now()),
    'nota', 'Gastado = gastos aplicados (con ISV). En espera = pendientes de aprobación (todavía no sale dinero).');
END $$;

-- mas_vendido(empresa, desde, hasta, limite 10)   ventas.ver   (máximo un año)
-- Por producto: lo vendido (ventas emitidas con fecha en el rango; anuladas no) y lo
-- devuelto (devoluciones aplicadas con fecha en el rango); neto = vendido - devuelto.
-- Cantidades y totales con ISV. Ordenado por total neto. Los totales de arriba son de
-- TODOS los productos (no solo los del límite). Limitado: solo sus sucursales.
CREATE FUNCTION public.mas_vendido(p_empresa_id uuid, p_desde date, p_hasta date, p_limite integer DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_lim   integer := coalesce(p_limite, 10);
  v_filas jsonb;
  v_tot   jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.ver');
  PERFORM interno.exigir_rango(p_desde, p_hasta, 366);
  IF v_lim NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el límite de productos va de 1 a 1000.';
  END IF;
  WITH ven AS (
    SELECT l.producto_id, sum(l.cantidad) AS cant, sum(l.total_centavos) AS tot, count(DISTINCT l.venta_id) AS ventas
      FROM public.venta_linea l JOIN public.venta v ON v.id = l.venta_id
     WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND v.fecha_contable BETWEEN p_desde AND p_hasta
       AND interno.sucursal_permitida(p_empresa_id, v.sucursal_id)
     GROUP BY l.producto_id
  ), dev AS (
    SELECT l.producto_id, sum(l.cantidad) AS cant, sum(l.total_centavos) AS tot
      FROM public.devolucion_linea l JOIN public.devolucion d ON d.id = l.devolucion_id
     WHERE d.empresa_id = p_empresa_id AND d.estado = 'aplicada' AND d.fecha_contable BETWEEN p_desde AND p_hasta
       AND interno.sucursal_permitida(p_empresa_id, d.sucursal_id)
     GROUP BY l.producto_id
  ), x AS (
    SELECT p.id, p.codigo, p.nombre, p.tipo,
           coalesce(ven.cant, 0) AS cant_v, coalesce(ven.tot, 0) AS tot_v, coalesce(ven.ventas, 0) AS ventas,
           coalesce(dev.cant, 0) AS cant_d, coalesce(dev.tot, 0) AS tot_d
      FROM public.producto p
      LEFT JOIN ven ON ven.producto_id = p.id
      LEFT JOIN dev ON dev.producto_id = p.id
     WHERE p.empresa_id = p_empresa_id AND (ven.producto_id IS NOT NULL OR dev.producto_id IS NOT NULL)
  ), o AS (
    SELECT x.*, row_number() OVER (ORDER BY x.tot_v - x.tot_d DESC, x.cant_v - x.cant_d DESC, x.nombre, x.id) AS n FROM x
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('producto_id', o.id, 'codigo', o.codigo, 'nombre', o.nombre, 'tipo', o.tipo,
           'ventas', o.ventas, 'cantidad_vendida', o.cant_v, 'total_vendido_centavos', o.tot_v,
           'cantidad_devuelta', o.cant_d, 'total_devuelto_centavos', o.tot_d,
           'cantidad_neta', o.cant_v - o.cant_d, 'total_neto_centavos', o.tot_v - o.tot_d) ORDER BY o.n) FILTER (WHERE o.n <= v_lim), '[]'),
         jsonb_build_object('productos', count(*),
           'total_vendido_centavos', coalesce(sum(o.tot_v), 0), 'total_devuelto_centavos', coalesce(sum(o.tot_d), 0),
           'total_neto_centavos', coalesce(sum(o.tot_v - o.tot_d), 0),
           'cantidad_vendida', coalesce(sum(o.cant_v), 0), 'cantidad_devuelta', coalesce(sum(o.cant_d), 0))
    INTO v_filas, v_tot FROM o;
  RETURN jsonb_build_object('desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'), 'limite', v_lim,
    'filas', v_filas, 'total', v_tot, 'hay_mas', (v_tot->>'productos')::integer > v_lim,
    'solo_mis_sucursales', interno.usuario_restringido(p_empresa_id), 'generado_en', public.iso(now()),
    'nota', 'Con ISV. Vendido = ventas emitidas (las anuladas no cuentan); devuelto = devoluciones aplicadas en el rango; neto = vendido - devuelto.');
END $$;

-- ---------------------------------------------------------------------
-- 6) cerrar_mes y reabrir_periodo con id_operacion opcional
-- ---------------------------------------------------------------------
CREATE TABLE public.periodo_operacion (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  tipo                     text NOT NULL CHECK (tipo IN ('cierre_mes', 'reapertura_mes')),
  anio                     integer NOT NULL CHECK (anio BETWEEN 2000 AND 2100),
  mes                      integer NOT NULL CHECK (mes BETWEEN 1 AND 12),
  cierre_id_operacion      uuid,
  reapertura_id_operacion  uuid,
  resultado                jsonb NOT NULL,
  creado_por               uuid,
  registrado_en            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, cierre_id_operacion),
  UNIQUE (empresa_id, reapertura_id_operacion),
  CHECK ((tipo = 'cierre_mes') = (cierre_id_operacion IS NOT NULL)),
  CHECK ((tipo = 'reapertura_mes') = (reapertura_id_operacion IS NOT NULL))
);
CREATE TRIGGER inmutable BEFORE UPDATE ON public.periodo_operacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El registro de un cierre o una reapertura no se edita.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.periodo_operacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El registro de un cierre o una reapertura no se borra.');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.periodo_operacion
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.periodo_operacion
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
ALTER TABLE public.periodo_operacion ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.periodo_operacion FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.periodo_operacion TO authenticated, service_role;
CREATE POLICY leer ON public.periodo_operacion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('contabilidad.ver'))));

INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('periodo_operacion', 'cierre_id_operacion',     'cierre_mes',     90),
  ('periodo_operacion', 'reapertura_id_operacion', 'reapertura_mes', 91);

-- Las de siempre pasan a interno (mismo código) y la pública las envuelve.
ALTER FUNCTION public.cerrar_mes(uuid, integer, integer, text) SET SCHEMA interno;
ALTER FUNCTION interno.cerrar_mes(uuid, integer, integer, text) RENAME TO cerrar_mes_base;
ALTER FUNCTION public.reabrir_periodo(uuid, integer, integer, text) SET SCHEMA interno;
ALTER FUNCTION interno.reabrir_periodo(uuid, integer, integer, text) RENAME TO reabrir_periodo_base;

-- cerrar_mes(empresa, año, mes, motivo?, id_operacion?)   periodos.cerrar
-- Sin id_operacion: igual que antes. Con id_operacion: un reintento con el mismo id devuelve
-- lo mismo ("duplicado": true); el mismo id para otro mes u otra operación: ID_OPERACION_USADO.
CREATE FUNCTION public.cerrar_mes(p_empresa_id uuid, p_anio integer, p_mes integer, p_motivo text DEFAULT NULL,
                                  p_id_operacion uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.periodo_operacion;
  r jsonb;
BEGIN
  IF p_id_operacion IS NULL THEN
    RETURN interno.cerrar_mes_base(p_empresa_id, p_anio, p_mes, p_motivo);
  END IF;
  PERFORM interno.exigir_escritura(p_empresa_id, 'periodos.cerrar');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'cierre_mes');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'cierre_mes');
  SELECT * INTO o FROM public.periodo_operacion x WHERE x.empresa_id = p_empresa_id AND x.cierre_id_operacion = p_id_operacion;
  IF o.id IS NOT NULL THEN
    IF o.anio <> p_anio OR o.mes <> p_mes THEN
      RAISE EXCEPTION 'ID_OPERACION_USADO: el id_operacion % ya se usó para cerrar %/%; use uno nuevo.', p_id_operacion, lpad(o.mes::text, 2, '0'), o.anio;
    END IF;
    RETURN o.resultado || jsonb_build_object('duplicado', true);
  END IF;
  r := interno.cerrar_mes_base(p_empresa_id, p_anio, p_mes, p_motivo);
  INSERT INTO public.periodo_operacion (empresa_id, tipo, anio, mes, cierre_id_operacion, resultado, creado_por)
  VALUES (p_empresa_id, 'cierre_mes', p_anio, p_mes, p_id_operacion, r, auth.uid());
  RETURN r || jsonb_build_object('duplicado', false);
END $$;

-- reabrir_periodo(empresa, año, mes, motivo, id_operacion?)   periodos.reabrir (solo el dueño)
CREATE FUNCTION public.reabrir_periodo(p_empresa_id uuid, p_anio integer, p_mes integer, p_motivo text,
                                       p_id_operacion uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.periodo_operacion;
  r jsonb;
BEGIN
  IF p_id_operacion IS NULL THEN
    RETURN interno.reabrir_periodo_base(p_empresa_id, p_anio, p_mes, p_motivo);
  END IF;
  PERFORM interno.exigir_escritura(p_empresa_id, 'periodos.reabrir');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'reapertura_mes');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'reapertura_mes');
  SELECT * INTO o FROM public.periodo_operacion x WHERE x.empresa_id = p_empresa_id AND x.reapertura_id_operacion = p_id_operacion;
  IF o.id IS NOT NULL THEN
    IF o.anio <> p_anio OR o.mes <> p_mes THEN
      RAISE EXCEPTION 'ID_OPERACION_USADO: el id_operacion % ya se usó para reabrir %/%; use uno nuevo.', p_id_operacion, lpad(o.mes::text, 2, '0'), o.anio;
    END IF;
    RETURN o.resultado || jsonb_build_object('duplicado', true);
  END IF;
  r := interno.reabrir_periodo_base(p_empresa_id, p_anio, p_mes, p_motivo);
  INSERT INTO public.periodo_operacion (empresa_id, tipo, anio, mes, reapertura_id_operacion, resultado, creado_por)
  VALUES (p_empresa_id, 'reapertura_mes', p_anio, p_mes, p_id_operacion, r, auth.uid());
  RETURN r || jsonb_build_object('duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 7) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.exigir_documento_cxp(uuid, uuid), interno.cobro_solo_mis_sucursales(uuid, jsonb, uuid),
  interno.exigir_rango(date, date, integer),
  interno.cerrar_mes_base(uuid, integer, integer, text), interno.reabrir_periodo_base(uuid, integer, integer, text),
  interno.condonar_saldo_cxc_base(uuid, jsonb, text, uuid)
FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.empresas_sin_restriccion() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.empresas_sin_restriccion() TO authenticated, service_role;

-- Lecturas (las reemplazadas conservan sus permisos; se repiten por claridad).
REVOKE EXECUTE ON FUNCTION
  public.donde_esta_mi_dinero(uuid), public.estado_fondos(uuid), public.proyeccion_flujo(uuid, integer, text),
  public.ver_conciliacion(uuid), public.totales_compras(uuid, date, date, uuid),
  public.totales_gastos(uuid, date, date, uuid, uuid), public.mas_vendido(uuid, date, date, integer)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.donde_esta_mi_dinero(uuid), public.estado_fondos(uuid), public.proyeccion_flujo(uuid, integer, text),
  public.ver_conciliacion(uuid), public.totales_compras(uuid, date, date, uuid),
  public.totales_gastos(uuid, date, date, uuid, uuid), public.mas_vendido(uuid, date, date, integer)
TO authenticated, service_role;

-- Escrituras (solo con sesión de usuario).
REVOKE EXECUTE ON FUNCTION
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text, uuid),
  public.anular_pago_proveedor(uuid, text, uuid, date),
  public.registrar_cobro(uuid, jsonb, uuid), public.guardar_preferencias_alertas(uuid, jsonb),
  public.cerrar_mes(uuid, integer, integer, text, uuid), public.reabrir_periodo(uuid, integer, integer, text, uuid),
  public.condonar_saldo_cxc(uuid, jsonb, text, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text, uuid),
  public.anular_pago_proveedor(uuid, text, uuid, date),
  public.registrar_cobro(uuid, jsonb, uuid), public.guardar_preferencias_alertas(uuid, jsonb),
  public.cerrar_mes(uuid, integer, integer, text, uuid), public.reabrir_periodo(uuid, integer, integer, text, uuid),
  public.condonar_saldo_cxc(uuid, jsonb, text, uuid)
TO authenticated;
