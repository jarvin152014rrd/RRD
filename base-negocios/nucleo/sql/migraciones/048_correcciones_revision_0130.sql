-- =====================================================================
-- 048_correcciones_revision_0130.sql  -  Núcleo 0.13.1: correcciones de la
-- revisión de 0.13.0 (docs/PENDIENTES.md). Las 001-047 no se tocan.
--
--   IMPORTANTE
--   1. Cerrar sesión a distancia ya no se salta al renovar el token: la sesión
--      se reconoce por el claim "session_id" del JWT de Supabase (no cambia al
--      renovar) y se compara la hora en que se INICIÓ esa sesión
--      (auth.sessions.created_at) con la hora del cierre. Si el token no trae
--      session_id (o la base no puede leer auth.sessions) se usa el "iat" como antes.
--   2. Un mes con reparto de utilidades vigente no se reabre (MES_CON_REPARTO):
--      primero se anula el reparto (anular_distribucion). Trigger en periodo,
--      así vale para reabrir_periodo y para cualquier otro camino.
--   3. Usuarios restringidos por sucursal: resumen_hoy, alertas_activas y
--      exportar_plantilla solo cuentan sus sucursales (ventas, cuentas por
--      cobrar de ventas emitidas en sus sucursales, cuentas por pagar de compras
--      de sus sucursales, dinero, existencias, cajas, turnos y bancos). La
--      ganancia (de toda la empresa) no se les muestra. El dueño y quien no
--      tiene restricción ven todo igual que antes.
--   MENORES
--   4. Conciliación tipo "otro": la contrapartida no puede ser una cuenta que
--      controla un módulo (igual que usar_fondo).
--   5. Conciliación: importar el estado de cuenta y emparejar exigen la
--      sucursal de la cuenta de banco (SUCURSAL_NO_PERMITIDA).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('MES_CON_REPARTO', 'Ese mes tiene un reparto de utilidades vigente y no se puede reabrir.',
   'Anule primero el reparto de ese mes (Fondos > Repartos > Anular) y después reabra el mes.');

-- ---------------------------------------------------------------------
-- 1) Sesión cerrada: por session_id (no cambia al renovar el token)
-- ---------------------------------------------------------------------
-- ¿El token de esta llamada es de una sesión anterior al cierre? (true = rechazar)
--   Con session_id y auth.sessions legible: la sesión debe existir, ser del usuario
--   y haberse iniciado DESPUÉS del cierre. Si no existe (salió o se revocó), se rechaza.
--   Sin session_id (o sin poder leer auth.sessions): regla de 0.13.0 con el "iat".
CREATE FUNCTION interno.sesion_anterior_al_cierre(p_cerrada_en timestamptz) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_claims jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_sid    text;
  v_iat    numeric;
  v_inicio timestamptz;
BEGIN
  IF p_cerrada_en IS NULL THEN
    RETURN false;
  END IF;
  v_sid := v_claims->>'session_id';
  IF v_sid ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     AND to_regclass('auth.sessions') IS NOT NULL AND has_table_privilege('auth.sessions', 'SELECT') THEN
    SELECT s.created_at INTO v_inicio FROM auth.sessions s WHERE s.id = v_sid::uuid AND s.user_id = auth.uid();
    RETURN v_inicio IS NULL OR v_inicio <= p_cerrada_en;
  END IF;
  v_iat := (v_claims->>'iat')::numeric;
  RETURN v_iat IS NULL OR to_timestamp(v_iat) <= p_cerrada_en;
END $$;

-- revisar_acceso (reemplaza la de 047; misma firma). Nuevo: usa sesion_anterior_al_cierre.
CREATE OR REPLACE FUNCTION interno.revisar_acceso(p_empresa_id uuid, p_operar boolean) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  ue      public.usuario_empresa;
  v_h     jsonb;
  v_local timestamp;
  v_dia   jsonb;
BEGIN
  SELECT * INTO ue FROM public.usuario_empresa x WHERE x.user_id = auth.uid() AND x.empresa_id = p_empresa_id AND x.activo;
  IF ue.id IS NULL THEN
    RETURN;
  END IF;
  IF ue.sesion_cerrada_en IS NOT NULL THEN
    IF interno.sesion_anterior_al_cierre(ue.sesion_cerrada_en) THEN
      RAISE EXCEPTION 'SESION_CERRADA: su sesión fue cerrada el %; vuelva a entrar.',
        to_char(ue.sesion_cerrada_en AT TIME ZONE (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id), 'DD/MM/YYYY HH24:MI');
    END IF;
  END IF;
  IF p_operar AND ue.rol NOT IN ('dueno', 'proveedor') THEN
    SELECT h.horario INTO v_h FROM public.horario_acceso h WHERE h.empresa_id = p_empresa_id AND h.rol = ue.rol;
    IF v_h IS NOT NULL THEN
      v_local := now() AT TIME ZONE (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id);
      v_dia := v_h->(extract(isodow FROM v_local)::integer::text);
      IF v_dia IS NULL OR v_local::time < (v_dia->>'desde')::time OR v_local::time >= (v_dia->>'hasta')::time THEN
        RAISE EXCEPTION 'FUERA_DE_HORARIO: el puesto "%" no puede operar ahora (%).', ue.rol,
          coalesce('hoy de ' || (v_dia->>'desde') || ' a ' || (v_dia->>'hasta'), 'hoy no es día de trabajo');
      END IF;
    END IF;
  END IF;
END $$;

-- mi_estado_sesion (reemplaza la de 047; misma firma y respuesta). Nuevo: debe_salir por session_id.
CREATE OR REPLACE FUNCTION public.mi_estado_sesion(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  ue      public.usuario_empresa;
  v_h     jsonb;
  v_local timestamp;
  v_dia   jsonb;
  v_dentro boolean := true;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  SELECT * INTO ue FROM public.usuario_empresa x WHERE x.user_id = auth.uid() AND x.empresa_id = p_empresa_id;
  IF ue.id IS NULL OR NOT ue.activo THEN
    RETURN jsonb_build_object('activo', false, 'debe_salir', true, 'motivo', 'Su usuario fue desactivado en esta empresa.');
  END IF;
  IF ue.rol NOT IN ('dueno', 'proveedor') THEN
    SELECT h.horario INTO v_h FROM public.horario_acceso h WHERE h.empresa_id = p_empresa_id AND h.rol = ue.rol;
    IF v_h IS NOT NULL THEN
      v_local := now() AT TIME ZONE (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id);
      v_dia := v_h->(extract(isodow FROM v_local)::integer::text);
      v_dentro := v_dia IS NOT NULL AND v_local::time >= (v_dia->>'desde')::time AND v_local::time < (v_dia->>'hasta')::time;
    END IF;
  END IF;
  RETURN jsonb_build_object('activo', true,
    'debe_salir', interno.sesion_anterior_al_cierre(ue.sesion_cerrada_en),
    'sesion_cerrada_en', public.iso(ue.sesion_cerrada_en),
    'horario', v_h, 'horario_hoy', v_dia, 'dentro_de_horario', v_dentro,
    'sucursales', CASE WHEN interno.usuario_restringido(p_empresa_id) THEN
      (SELECT jsonb_agg(jsonb_build_object('sucursal_id', s.id, 'codigo', s.codigo, 'nombre', s.nombre) ORDER BY s.codigo)
         FROM public.usuario_sucursal us JOIN public.sucursal s ON s.id = us.sucursal_id
        WHERE us.empresa_id = p_empresa_id AND us.user_id = auth.uid() AND us.activo) END,
    'todas_las_sucursales', NOT interno.usuario_restringido(p_empresa_id));
END $$;

-- ---------------------------------------------------------------------
-- 2) No reabrir un mes con reparto de utilidades vigente
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.reabrir_sin_reparto() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_num bigint;
BEGIN
  IF OLD.estado = 'cerrado' AND NEW.estado = 'abierto' THEN
    SELECT d.numero INTO v_num FROM public.distribucion d
     WHERE d.empresa_id = NEW.empresa_id AND d.anio = NEW.anio AND d.mes = NEW.mes AND d.anulada_en IS NULL
     ORDER BY d.numero LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'MES_CON_REPARTO: el mes %/% tiene el reparto de utilidades #% vigente; anúlelo primero (anular_distribucion) y después reabra el mes.',
        lpad(NEW.mes::text, 2, '0'), NEW.anio, v_num;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER reabrir_sin_reparto BEFORE UPDATE OF estado ON public.periodo
  FOR EACH ROW EXECUTE FUNCTION interno.reabrir_sin_reparto();

-- ---------------------------------------------------------------------
-- 3) Lecturas de toda la empresa filtradas para usuarios restringidos
-- ---------------------------------------------------------------------
-- Criterio de cuentas por cobrar (decisión 0.13.1): el restringido ve las ventas al crédito
-- EMITIDAS en sus sucursales (aunque el cliente compre también en otras). Los saldos iniciales
-- de clientes no tienen sucursal: solo los ve quien no tiene restricción. Igual en cuentas por
-- pagar con las compras.
CREATE FUNCTION interno.documento_cxc_permitido(p_empresa_id uuid, p_origen text, p_documento_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NOT interno.usuario_restringido(p_empresa_id)
      OR (p_origen = 'venta' AND EXISTS (SELECT 1 FROM public.venta v WHERE v.id = p_documento_id
                                           AND interno.sucursal_permitida(p_empresa_id, v.sucursal_id)))
$$;

CREATE FUNCTION interno.documento_cxp_permitido(p_empresa_id uuid, p_origen text, p_documento_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NOT interno.usuario_restringido(p_empresa_id)
      OR (p_origen = 'compra' AND EXISTS (SELECT 1 FROM public.compra c WHERE c.id = p_documento_id
                                            AND interno.sucursal_permitida(p_empresa_id, c.sucursal_id)))
$$;

-- ventas_del (reemplaza la de 045; misma firma): solo ventas de las sucursales que uno ve.
CREATE OR REPLACE FUNCTION interno.ventas_del(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('total_centavos', coalesce(sum(v.total_centavos), 0), 'cantidad', count(*))
    FROM public.venta v WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND v.fecha_contable BETWEEN p_desde AND p_hasta
     AND v.sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas()))   -- 0.13.1: solo sus sucursales
$$;

-- resumen_hoy (reemplaza la de 045; misma firma). Restringido: ventas, dinero, te_deben y debes
-- solo de sus sucursales (dinero: también las cuentas sin sucursal, como en las demás lecturas);
-- ganancia_hoy y ganancia_mes ocultas (son de toda la empresa). Nueva clave "solo_mis_sucursales".
CREATE OR REPLACE FUNCTION public.resumen_hoy(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy    date := public.hoy_local(p_empresa_id);
  v_ayer   date := public.hoy_local(p_empresa_id) - 1;
  v_mes    date := date_trunc('month', public.hoy_local(p_empresa_id))::date;
  v_mp_ini date := (date_trunc('month', public.hoy_local(p_empresa_id)) - interval '1 month')::date;
  v_mp_fin date := (date_trunc('month', public.hoy_local(p_empresa_id)) - interval '1 day')::date;
  v_mp_dia date;
  v_ventas boolean := public.puede_leer(p_empresa_id, 'ventas.ver');
  v_costos boolean := public.puede_leer(p_empresa_id, 'inventario.costos');
  v_cont   boolean := public.puede_leer(p_empresa_id, 'contabilidad.ver');
  v_dinero boolean := public.puede_leer(p_empresa_id, 'dinero.ver');
  v_compras boolean := public.puede_leer(p_empresa_id, 'compras.ver');
  v_restr  boolean := interno.usuario_restringido(p_empresa_id);
  v_ocultos text[] := '{}';
  j_vh jsonb; j_va jsonb; j_vm jsonb; j_vmp jsonb;
  e_hoy jsonb; e_ayer jsonb; e_mes jsonb; e_mp jsonb; e_mpd jsonb;
  r        jsonb := '{}';
  v_frase  text;
BEGIN
  PERFORM interno.exigir_miembro(p_empresa_id);
  v_mp_dia := least(v_mp_ini + (v_hoy - v_mes), v_mp_fin);   -- el mes pasado hasta el mismo día

  IF v_ventas THEN
    j_vh := interno.ventas_del(p_empresa_id, v_hoy, v_hoy);
    j_va := interno.ventas_del(p_empresa_id, v_ayer, v_ayer);
    j_vm := interno.ventas_del(p_empresa_id, v_mes, v_hoy);
    j_vmp := interno.ventas_del(p_empresa_id, v_mp_ini, v_mp_fin);
    r := r || jsonb_build_object(
      'ventas_hoy', j_vh || jsonb_build_object('ayer_centavos', (j_va->>'total_centavos')::bigint)
                    || interno.comparar((j_vh->>'total_centavos')::bigint, (j_va->>'total_centavos')::bigint),
      'ventas_mes', j_vm || jsonb_build_object('mes_pasado_centavos', (j_vmp->>'total_centavos')::bigint,
                    'mes_pasado_a_la_fecha_centavos', (interno.ventas_del(p_empresa_id, v_mp_ini, v_mp_dia)->>'total_centavos')::bigint));
  ELSE
    v_ocultos := v_ocultos || ARRAY['ventas_hoy', 'ventas_mes'];
  END IF;

  -- Ganancia bruta de hoy (ventas sin ISV - costo de lo vendido): necesita ver costos.
  -- (0.13.1) Restringido por sucursal: la ganancia es de toda la empresa, no se muestra.
  IF v_ventas AND v_costos AND NOT v_restr THEN
    e_hoy := interno.calcular_estado_resultados(p_empresa_id, v_hoy, v_hoy);
    e_ayer := interno.calcular_estado_resultados(p_empresa_id, v_ayer, v_ayer);
    r := r || jsonb_build_object('ganancia_hoy', jsonb_build_object(
      'ganancia_bruta_centavos', (e_hoy->>'utilidad_bruta_centavos')::bigint,
      'ventas_sin_isv_centavos', (e_hoy->>'ventas_netas_centavos')::bigint,
      'ayer_centavos', (e_ayer->>'utilidad_bruta_centavos')::bigint)
      || interno.comparar((e_hoy->>'utilidad_bruta_centavos')::bigint, (e_ayer->>'utilidad_bruta_centavos')::bigint));
  ELSE
    r := r || jsonb_build_object('ganancia_hoy', NULL);
    v_ocultos := v_ocultos || ARRAY['ganancia_hoy'];
  END IF;

  -- Ganancia del mes (utilidad neta: ventas - costo - gastos), con el mes pasado.
  IF v_cont AND v_costos AND NOT v_restr THEN
    e_mes := interno.calcular_estado_resultados(p_empresa_id, v_mes, v_hoy);
    e_mp := interno.calcular_estado_resultados(p_empresa_id, v_mp_ini, v_mp_fin);
    e_mpd := interno.calcular_estado_resultados(p_empresa_id, v_mp_ini, v_mp_dia);
    r := r || jsonb_build_object('ganancia_mes', jsonb_build_object(
      'ganancia_centavos', (e_mes->>'utilidad_neta_centavos')::bigint,
      'ganancia_bruta_centavos', (e_mes->>'utilidad_bruta_centavos')::bigint,
      'gastos_centavos', (e_mes->>'gastos_operacion_centavos')::bigint,
      'ganancia_cobrada_centavos', (e_mes->>'utilidad_cobrada_centavos')::bigint,
      'mes_pasado_centavos', (e_mp->>'utilidad_neta_centavos')::bigint,
      'mes_pasado_a_la_fecha_centavos', (e_mpd->>'utilidad_neta_centavos')::bigint)
      || interno.comparar((e_mes->>'utilidad_neta_centavos')::bigint, (e_mpd->>'utilidad_neta_centavos')::bigint));
  ELSE
    r := r || jsonb_build_object('ganancia_mes', NULL);
    v_ocultos := v_ocultos || ARRAY['ganancia_mes'];
  END IF;

  IF v_dinero THEN
    r := r || jsonb_build_object('dinero', jsonb_build_object(
      'disponible_centavos', (SELECT coalesce(sum(interno.saldo_dinero(d.id)), 0) FROM public.cuenta_dinero d
                               WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('efectivo_caja', 'banco', 'caja_chica')
                                 AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id))),
      'por_confirmar_centavos', (SELECT coalesce(sum(interno.saldo_dinero(d.id)), 0) FROM public.cuenta_dinero d
                               WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('transito', 'transferencia_por_confirmar', 'pos_por_liquidar')
                                 AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id)))));
  ELSE
    v_ocultos := v_ocultos || ARRAY['dinero'];
  END IF;

  IF v_ventas THEN
    r := r || jsonb_build_object('te_deben', (SELECT jsonb_build_object(
      'total_centavos', coalesce(sum(x.saldo_centavos), 0),
      'vencido_centavos', coalesce(sum(x.saldo_centavos) FILTER (WHERE x.vence_el < v_hoy), 0),
      'clientes', count(DISTINCT x.cliente_id))
      FROM interno.cxc_al(p_empresa_id, 'infinity') x WHERE x.saldo_centavos > 0
        AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, x.origen, x.documento_id))));
  ELSE
    v_ocultos := v_ocultos || ARRAY['te_deben'];
  END IF;

  IF v_compras THEN
    r := r || jsonb_build_object('debes', (SELECT jsonb_build_object(
      'total_centavos', coalesce(sum(x.saldo_centavos), 0),
      'vencido_centavos', coalesce(sum(x.saldo_centavos) FILTER (WHERE x.vence_el < v_hoy), 0),
      'proveedores', count(DISTINCT x.proveedor_id))
      FROM interno.cxp_al(p_empresa_id, 'infinity') x WHERE x.saldo_centavos > 0
        AND (NOT v_restr OR interno.documento_cxp_permitido(p_empresa_id, x.origen, x.documento_id))));
  ELSE
    v_ocultos := v_ocultos || ARRAY['debes'];
  END IF;

  IF v_ventas THEN
    v_frase := 'Hoy vendiste ' || interno.lempiras((j_vh->>'total_centavos')::bigint);
    IF r->'ganancia_hoy' <> 'null'::jsonb THEN
      v_frase := v_frase || ' y ganaste ' || interno.lempiras((r->'ganancia_hoy'->>'ganancia_bruta_centavos')::bigint);
    END IF;
    v_frase := v_frase || '.';
    IF r->'ganancia_mes' <> 'null'::jsonb THEN
      v_frase := v_frase || ' En el mes llevas ' || interno.lempiras((r->'ganancia_mes'->>'ganancia_centavos')::bigint) || ' de ganancia.';
    END IF;
  END IF;

  RETURN r || jsonb_build_object('titulo', 'Mi negocio hoy', 'fecha', to_char(v_hoy, 'YYYY-MM-DD'), 'generado_en', public.iso(now()),
    'frase', v_frase, 'costos_ocultos', NOT v_costos, 'ocultos', to_jsonb(v_ocultos), 'solo_mis_sucursales', v_restr,
    'nota', 'Ventas con ISV (emitidas y no anuladas). Ganancia de hoy = ventas sin ISV - costo de lo vendido. Ganancia del mes = ventas - costo - gastos, desde el día 1 hasta hoy.');
END $$;

-- alertas_de (reemplaza la de 045; misma firma). Restringido: CAI de sus cajas, cuentas y bancos de
-- sus sucursales (o sin sucursal), depósitos que salen o llegan a ellas, arqueos de sus turnos, crédito
-- vencido con el criterio de arriba y stock mínimo con la existencia de SUS bodegas.
CREATE OR REPLACE FUNCTION interno.alertas_de(p_empresa_id uuid, p_tipo text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e       public.empresa;
  v_hoy   date := public.hoy_local(p_empresa_id);
  v_a     jsonb := '[]';
  v_lic   jsonb;
  v_ini   date;
  v_prev  date := (date_trunc('month', public.hoy_local(p_empresa_id)) - interval '1 day')::date;
  v_n     integer;
  v_txt   text;
  v_restr boolean := interno.usuario_restringido(p_empresa_id);
  r       record;
BEGIN
  SELECT * INTO e FROM public.empresa WHERE id = p_empresa_id;
  IF p_tipo = 'cai' THEN
    FOR r IN SELECT x FROM jsonb_array_elements(public.cai_alertas(p_empresa_id)->'alertas') x
              WHERE NOT v_restr OR x->>'caja_id' IS NULL
                 OR interno.sucursal_permitida(p_empresa_id, (SELECT c.sucursal_id FROM public.caja c WHERE c.id = (x->>'caja_id')::uuid)) LOOP
      v_a := v_a || interno.alerta('cai',
        CASE WHEN r.x->>'tipo' IN ('vencido', 'agotado', 'sin_cai') THEN 'alta' ELSE 'media' END,
        CASE r.x->>'tipo' WHEN 'vencido' THEN 'CAI vencido' WHEN 'agotado' THEN 'Se acabaron los números de factura'
             WHEN 'sin_cai' THEN 'Caja sin CAI' WHEN 'por_vencer' THEN 'CAI por vencer' ELSE 'Quedan pocos números de factura' END,
        r.x->>'mensaje',
        CASE WHEN r.x->>'tipo' IN ('vencido', 'agotado', 'sin_cai') THEN 'Esa caja no puede facturar. Pida un CAI nuevo en la SAR y regístrelo en el sistema.'
             ELSE 'Pida a tiempo el CAI nuevo en la SAR para no quedarse sin poder facturar.' END,
        '/ajustes/facturacion', r.x - 'mensaje');
    END LOOP;

  ELSIF p_tipo = 'cierre_mes' THEN
    -- Meses ya terminados sin cerrar (desde el inicio de la empresa hasta el mes pasado).
    SELECT count(*), string_agg(to_char(m, 'MM/YYYY'), ', ' ORDER BY m), min(m) INTO v_n, v_txt, v_ini
      FROM generate_series(date_trunc('month', e.fecha_inicio)::date, date_trunc('month', v_prev)::date, interval '1 month') AS g(m)
     WHERE NOT EXISTS (SELECT 1 FROM public.periodo p WHERE p.empresa_id = p_empresa_id AND p.anio = extract(year FROM g.m)
                         AND p.mes = extract(month FROM g.m) AND p.estado = 'cerrado')
       AND v_prev >= e.fecha_inicio;
    -- El mes pasado se da hasta el día 10 para cerrarlo; un mes más viejo ya está atrasado.
    IF v_n > 1 OR (v_n = 1 AND (v_ini < date_trunc('month', v_prev) OR extract(day FROM v_hoy) > 10)) THEN
      v_a := v_a || interno.alerta('cierre_mes', CASE WHEN v_ini < date_trunc('month', v_prev) THEN 'alta' ELSE 'media' END,
        'Meses sin cerrar', 'Tiene ' || v_n || ' mes(es) sin cerrar: ' || v_txt || '.',
        'Revise y cierre cada mes en orden; así sus números quedan firmes y puede ver sus estados del mes.',
        '/contabilidad/cierres', jsonb_build_object('meses', v_n, 'desde', to_char(v_ini, 'YYYY-MM')));
    END IF;

  ELSIF p_tipo = 'cuenta_negativa' THEN
    FOR r IN SELECT d.id, d.nombre, interno.saldo_dinero(d.id) AS saldo FROM public.cuenta_dinero d
              WHERE d.empresa_id = p_empresa_id AND interno.saldo_dinero(d.id) < 0
                AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id)) ORDER BY d.nombre LOOP
      v_a := v_a || interno.alerta('cuenta_negativa', 'alta', 'Cuenta en negativo',
        'La cuenta "' || r.nombre || '" está en ' || interno.lempiras(r.saldo) || '.',
        'Registre el dinero que entró y falta en el sistema o revise el saldo inicial de esa cuenta.',
        '/dinero/cuentas/' || r.id, jsonb_build_object('cuenta_dinero_id', r.id, 'saldo_centavos', r.saldo));
    END LOOP;

  ELSIF p_tipo = 'deposito_transito' THEN
    FOR r IN SELECT o.id, o.monto_centavos, o.fecha_contable, d.nombre AS banco, v_hoy - o.fecha_contable AS dias
               FROM public.operacion_dinero o JOIN public.cuenta_dinero d ON d.id = o.destino_id
              WHERE o.empresa_id = p_empresa_id AND o.tipo = 'deposito' AND o.estado = 'en_transito' AND o.anulada_en IS NULL
                AND v_hoy - o.fecha_contable > e.dias_alerta_transito
                AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id)
                     OR interno.sucursal_permitida(p_empresa_id, (SELECT x.sucursal_id FROM public.cuenta_dinero x WHERE x.id = o.origen_id)))
              ORDER BY o.fecha_contable LOOP
      v_a := v_a || interno.alerta('deposito_transito', 'media', 'Depósito sin confirmar',
        'El depósito de ' || interno.lempiras(r.monto_centavos) || ' a "' || r.banco || '" del ' || to_char(r.fecha_contable, 'DD/MM/YYYY')
          || ' lleva ' || r.dias || ' días sin confirmarse.',
        'Revise el estado de cuenta del banco. Si ya llegó, confírmelo; si no, averigüe con quien lo llevó.',
        '/dinero/depositos', jsonb_build_object('operacion_id', r.id, 'monto_centavos', r.monto_centavos, 'dias', r.dias));
    END LOOP;

  ELSIF p_tipo = 'diferencia_arqueo' THEN
    SELECT count(*) INTO v_n FROM public.turno_caja t
     WHERE t.empresa_id = p_empresa_id AND t.diferencia_estado = 'pendiente'
       AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, t.sucursal_id));
    IF v_n > 0 THEN
      v_a := v_a || interno.alerta('diferencia_arqueo', 'media', 'Diferencias de caja sin resolver',
        'Hay ' || v_n || ' cierre(s) de caja con faltante o sobrante sin resolver.',
        'Decida en cada uno si se cobra al cajero, se pasa a gasto o queda como sobrante.',
        '/caja/diferencias', jsonb_build_object('cantidad', v_n));
    END IF;

  ELSIF p_tipo = 'aprobaciones' THEN
    SELECT count(*) INTO v_n FROM public.aprobacion a WHERE a.empresa_id = p_empresa_id AND a.estado = 'pendiente';
    IF v_n > 0 THEN
      v_a := v_a || interno.alerta('aprobaciones', 'media', 'Solicitudes esperando su decisión',
        'Tiene ' || v_n || ' solicitud(es) esperando aprobación.',
        'Revíselas y apruebe o rechace cada una con su motivo.', '/aprobaciones',
        jsonb_build_object('cantidad', v_n, 'por_tipo', (SELECT jsonb_object_agg(x.tipo, x.n) FROM (SELECT a.tipo, count(*) AS n
          FROM public.aprobacion a WHERE a.empresa_id = p_empresa_id AND a.estado = 'pendiente' GROUP BY a.tipo) x)));
    END IF;

  ELSIF p_tipo = 'credito_vencido' THEN
    FOR r IN SELECT x.cliente_id, t.nombre, sum(x.saldo_centavos)::bigint AS saldo, min(x.vence_el) AS desde
               FROM interno.cxc_al(p_empresa_id, 'infinity') x JOIN public.tercero t ON t.id = x.cliente_id
              WHERE x.saldo_centavos > 0 AND x.vence_el < v_hoy
                AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, x.origen, x.documento_id)) GROUP BY x.cliente_id, t.nombre ORDER BY min(x.vence_el) LOOP
      v_a := v_a || interno.alerta('credito_vencido', CASE WHEN v_hoy - r.desde > 30 THEN 'alta' ELSE 'media' END, 'Cliente con atraso',
        r.nombre || ' le debe ' || interno.lempiras(r.saldo) || ' que ya venció (desde el ' || to_char(r.desde, 'DD/MM/YYYY')
          || ', ' || (v_hoy - r.desde) || ' días).',
        'Llame o escriba al cliente para cobrarle; no le dé más crédito hasta que se ponga al día.',
        '/clientes/' || r.cliente_id, jsonb_build_object('cliente_id', r.cliente_id, 'saldo_vencido_centavos', r.saldo, 'dias', v_hoy - r.desde));
    END LOOP;

  ELSIF p_tipo = 'pago_fijo' THEN
    FOR r IN SELECT p.id, p.nombre, p.monto_estimado_centavos, x.proximo FROM public.pago_fijo p
               CROSS JOIN LATERAL (SELECT min(v) AS proximo FROM interno.vencimientos_pago_fijo(p, v_hoy + 7) v
                                    WHERE NOT EXISTS (SELECT 1 FROM public.gasto g WHERE g.pago_fijo_id = p.id AND g.pago_fijo_vence_el = v
                                                        AND g.estado IN ('pendiente_aprobacion', 'aplicado'))) x
              WHERE p.empresa_id = p_empresa_id AND p.activo AND x.proximo IS NOT NULL ORDER BY x.proximo LOOP
      v_a := v_a || interno.alerta('pago_fijo', CASE WHEN r.proximo < v_hoy THEN 'alta' ELSE 'media' END,
        CASE WHEN r.proximo < v_hoy THEN 'Pago vencido' ELSE 'Pago por vencer' END,
        CASE WHEN r.proximo < v_hoy THEN 'El pago de "' || r.nombre || '" venció el ' || to_char(r.proximo, 'DD/MM/YYYY') || '.'
             ELSE 'El pago de "' || r.nombre || '" vence en ' || (r.proximo - v_hoy) || ' día(s) (' || to_char(r.proximo, 'DD/MM/YYYY') || ').' END,
        'Páguelo y regístrelo como gasto de ese pago fijo para que no se acumulen recargos.',
        '/dinero/pagos-fijos', jsonb_build_object('pago_fijo_id', r.id, 'vence_el', to_char(r.proximo, 'YYYY-MM-DD'),
                                                  'monto_estimado_centavos', r.monto_estimado_centavos));
    END LOOP;

  ELSIF p_tipo = 'stock_minimo' THEN
    FOR r IN SELECT p.id, p.nombre, p.stock_minimo, coalesce(sum(s.cantidad), 0) AS existencia
               FROM public.producto p
               LEFT JOIN public.inventario_saldo s ON s.producto_id = p.id
                AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, (SELECT b.sucursal_id FROM public.bodega b WHERE b.id = s.bodega_id)))
              WHERE p.empresa_id = p_empresa_id AND p.activo AND p.tipo = 'bien' AND p.stock_minimo > 0
              GROUP BY p.id, p.nombre, p.stock_minimo HAVING coalesce(sum(s.cantidad), 0) <= p.stock_minimo ORDER BY p.nombre LOOP
      v_a := v_a || interno.alerta('stock_minimo', CASE WHEN r.existencia <= 0 THEN 'alta' ELSE 'baja' END,
        CASE WHEN r.existencia <= 0 THEN 'Producto agotado' ELSE 'Producto por acabarse' END,
        CASE WHEN r.existencia <= 0 THEN 'Se acabó "' || r.nombre || '".'
             ELSE 'Quedan ' || trim(to_char(r.existencia, 'FM999999999990.####'), '.') || ' de "' || r.nombre || '" (su mínimo es '
                  || trim(to_char(r.stock_minimo, 'FM999999999990.####'), '.') || ').' END,
        'Pida más a su proveedor.', '/inventario/productos/' || r.id,
        jsonb_build_object('producto_id', r.id, 'existencia', r.existencia, 'stock_minimo', r.stock_minimo));
    END LOOP;

  ELSIF p_tipo = 'conciliacion' THEN
    -- Bancos con movimientos hasta el fin del mes pasado y sin su conciliación cerrada.
    IF v_prev >= e.fecha_inicio THEN
      FOR r IN SELECT d.id, d.nombre FROM public.cuenta_dinero d
                WHERE d.empresa_id = p_empresa_id AND d.tipo = 'banco'
                  AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, d.sucursal_id))
                  AND EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.cuenta_dinero_id = d.id AND m.fecha_contable <= v_prev)
                  AND NOT EXISTS (SELECT 1 FROM public.conciliacion c WHERE c.cuenta_dinero_id = d.id AND c.estado = 'cerrada'
                                    AND c.anio = extract(year FROM v_prev) AND c.mes = extract(month FROM v_prev))
                ORDER BY d.nombre LOOP
        v_a := v_a || interno.alerta('conciliacion', 'media', 'Banco sin conciliar',
          'Falta conciliar "' || r.nombre || '" de ' || to_char(v_prev, 'MM/YYYY') || ' con el estado de cuenta del banco.',
          'Descargue el estado de cuenta del banco, cárguelo y revise las diferencias.',
          '/dinero/conciliacion', jsonb_build_object('cuenta_dinero_id', r.id, 'anio', extract(year FROM v_prev)::integer,
                                                     'mes', extract(month FROM v_prev)::integer));
      END LOOP;
    END IF;

  ELSIF p_tipo = 'licencia' THEN
    v_lic := interno.estado_licencia(p_empresa_id);
    IF v_lic->>'estado' = 'solo_lectura' THEN
      v_a := v_a || interno.alerta('licencia', 'alta', 'Sistema solo para consultar',
        'Su licencia no está vigente: puede consultar y exportar, pero no registrar.',
        'Comuníquese con su proveedor para renovarla.', '/ajustes/licencia', v_lic);
    ELSIF v_lic->>'estado' = 'en_gracia' THEN
      v_a := v_a || interno.alerta('licencia', 'alta', 'Licencia vencida',
        'Su licencia venció. Le quedan ' || (v_lic->>'dias') || ' día(s) antes de que el sistema quede solo para consultar.',
        'Comuníquese con su proveedor para renovarla.', '/ajustes/licencia', v_lic);
    ELSIF (v_lic->>'dias')::integer <= 15 THEN
      v_a := v_a || interno.alerta('licencia', 'media', 'Licencia por vencer',
        'Su licencia vence en ' || (v_lic->>'dias') || ' día(s).', 'Comuníquese con su proveedor para renovarla a tiempo.',
        '/ajustes/licencia', v_lic);
    END IF;

  ELSIF p_tipo = 'limite_contrato' THEN
    FOR r IN SELECT k AS cosa, (x.v->>'limite')::integer AS limite, (x.v->>'uso')::integer AS uso
               FROM jsonb_each(interno.limites_y_uso(p_empresa_id)) AS x(k, v)
              WHERE x.v->>'limite' IS NOT NULL AND (x.v->>'limite')::integer > 0
                AND (x.v->>'uso')::integer * 100 >= (x.v->>'limite')::integer * 80 ORDER BY k LOOP
      v_a := v_a || interno.alerta('limite_contrato', CASE WHEN r.uso >= r.limite THEN 'media' ELSE 'baja' END, 'Límite del plan',
        'Está usando ' || r.uso || ' de ' || r.limite || ' ' || r.cosa || ' de su plan.',
        'Si necesita más, solicite una ampliación a su proveedor.', '/ajustes/plan',
        jsonb_build_object('cosa', r.cosa, 'uso', r.uso, 'limite', r.limite));
    END LOOP;
  END IF;
  RETURN v_a;
END $$;

-- exportar_plantilla (reemplaza la de 046; misma firma). Restringido: existencia, valor y costo solo
-- de sus bodegas; última venta/compra/cobro de sus sucursales; saldos de clientes y proveedores con el
-- criterio de arriba; existencias iniciales y conteo físico solo con sus bodegas.
CREATE OR REPLACE FUNCTION public.exportar_plantilla(p_empresa_id uuid, p_hoja text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_costos  boolean;
  v_ventas  boolean;
  v_compras boolean;
  v_hoy     date;
  v_filas   jsonb;
  v_cli     boolean;
  v_prov    boolean;
  v_restr   boolean;
BEGIN
  PERFORM interno.excel_hoja_valida(p_hoja);
  IF p_hoja IN ('productos', 'categorias') THEN
    PERFORM interno.exigir_miembro(p_empresa_id);
  ELSIF p_hoja = 'clientes_proveedores' THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'terceros.ver');
  ELSIF p_hoja = 'existencias_iniciales' THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'inventario.carga_inicial');
  ELSIF p_hoja = 'conteo_fisico' THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'inventario.ver');
  ELSIF p_hoja = 'saldos_iniciales' THEN
    PERFORM interno.exigir_miembro(p_empresa_id);
    v_cli := public.puede_leer(p_empresa_id, 'ventas.saldo_inicial');
    v_prov := public.puede_leer(p_empresa_id, 'compras.saldo_inicial');
    IF NOT (v_cli OR v_prov) THEN
      RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.saldo_inicial" ni "compras.saldo_inicial".';
    END IF;
  END IF;
  v_costos  := public.puede_leer(p_empresa_id, 'inventario.costos');
  v_ventas  := public.puede_leer(p_empresa_id, 'ventas.ver');
  v_compras := public.puede_leer(p_empresa_id, 'compras.ver');
  v_hoy     := public.hoy_local(p_empresa_id);
  v_restr   := interno.usuario_restringido(p_empresa_id);

  IF p_hoja = 'productos' THEN
    SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'codigo', p.codigo, 'codigo_barras', p.codigo_barras, 'nombre', p.nombre, 'tipo', p.tipo,
        'categoria', split_part(interno.excel_ruta_categoria(p.categoria_id), ' > ', 1),
        'subcategoria', nullif(substring(interno.excel_ruta_categoria(p.categoria_id)
                                         FROM length(split_part(interno.excel_ruta_categoria(p.categoria_id), ' > ', 1)) + 4), ''),
        'unidad', u.codigo, 'se_vende_con_decimales', interno.excel_si_no(p.permite_fracciones),
        'impuesto', p.tipo_impuesto, 'precio_venta', interno.excel_lps(p.precio_venta_centavos),
        'precio_incluye_isv', interno.excel_si_no(p.precio_incluye_isv), 'existencia_minima', trim_scale(p.stock_minimo),
        'activo', interno.excel_si_no(p.activo),
        'existencia_total', CASE WHEN p.tipo = 'bien' THEN trim_scale(coalesce(s.cantidad, 0)) END,
        'precio_sin_isv', interno.excel_lps(x.sin_isv_centavos), 'precio_con_isv', interno.excel_lps(x.con_isv_centavos),
        'ultima_venta', (SELECT to_char(max(v.fecha_contable), 'YYYY-MM-DD') FROM public.venta_linea l JOIN public.venta v ON v.id = l.venta_id
                          WHERE l.producto_id = p.id AND v.estado = 'emitida'
                            AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, v.sucursal_id))),
        'ultima_compra', (SELECT to_char(max(cp.fecha_contable), 'YYYY-MM-DD') FROM public.compra_linea l JOIN public.compra cp ON cp.id = l.compra_id
                           WHERE l.producto_id = p.id AND cp.anulada_en IS NULL
                             AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, cp.sucursal_id))))
      || coalesce((SELECT jsonb_object_agg('extra.' || ce.clave,
                      CASE WHEN jsonb_typeof(p.campos_extra->ce.clave) = 'boolean'
                           THEN to_jsonb(interno.excel_si_no((p.campos_extra->>ce.clave)::boolean)) ELSE p.campos_extra->ce.clave END)
                    FROM public.campo_extra ce WHERE ce.empresa_id = p_empresa_id AND ce.entidad = 'producto' AND ce.activo), '{}')
      || CASE WHEN v_costos THEN jsonb_build_object(
           'costo_promedio', interno.excel_lps(k.costo),
           'valor_inventario', CASE WHEN p.tipo = 'bien' THEN interno.excel_lps(coalesce(s.valor, 0)) END,
           'margen_porcentaje', CASE WHEN x.sin_isv_centavos > 0 AND k.costo IS NOT NULL
                                     THEN round((x.sin_isv_centavos - k.costo) * 100.0 / x.sin_isv_centavos, 2) END)
         ELSE '{}' END
      ORDER BY p.codigo), '[]')
      INTO v_filas
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      LEFT JOIN public.impuesto i ON i.empresa_id = p.empresa_id AND i.codigo = p.tipo_impuesto
      CROSS JOIN LATERAL public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, i.porcentaje) x
      LEFT JOIN LATERAL (SELECT sum(z.cantidad) AS cantidad, sum(z.valor_centavos) AS valor
                           FROM public.inventario_saldo z WHERE z.producto_id = p.id
                            AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, (SELECT b.sucursal_id FROM public.bodega b WHERE b.id = z.bodega_id)))) s ON true
      LEFT JOIN LATERAL (SELECT CASE WHEN p.tipo = 'servicio'
                                     THEN (SELECT sc.costo_estimado_centavos::numeric FROM public.servicio_costo sc WHERE sc.producto_id = p.id)
                                     WHEN coalesce(s.cantidad, 0) > 0 THEN s.valor / s.cantidad END AS costo) k ON true
     WHERE p.empresa_id = p_empresa_id;

  ELSIF p_hoja = 'clientes_proveedores' THEN
    -- Cartera calculada UNA vez (no por cada fila).
    WITH cxc AS (
      SELECT a.cliente_id, sum(a.saldo_centavos) AS saldo,
             sum(a.saldo_centavos) FILTER (WHERE a.vence_el < v_hoy AND a.saldo_centavos > 0) AS vencido
        FROM interno.cxc_al(p_empresa_id, 'infinity') a WHERE v_ventas
         AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, a.origen, a.documento_id)) GROUP BY a.cliente_id),
    cxp AS (
      SELECT a.proveedor_id, sum(a.saldo_centavos) AS saldo,
             sum(a.saldo_centavos) FILTER (WHERE a.vence_el < v_hoy AND a.saldo_centavos > 0) AS vencido
        FROM interno.cxp_al(p_empresa_id, 'infinity') a WHERE v_compras
         AND (NOT v_restr OR interno.documento_cxp_permitido(p_empresa_id, a.origen, a.documento_id)) GROUP BY a.proveedor_id)
    SELECT coalesce(jsonb_agg(
      jsonb_build_object('codigo', t.codigo,
        'tipo', CASE WHEN t.es_cliente AND t.es_proveedor THEN 'ambos' WHEN t.es_cliente THEN 'cliente' ELSE 'proveedor' END,
        'tipo_persona', t.tipo_persona, 'nombre', t.nombre, 'rtn', t.rtn, 'telefono', t.telefono, 'correo', t.correo,
        'direccion', t.direccion, 'limite_credito', interno.excel_lps(t.limite_credito_centavos), 'plazo_dias', t.plazo_dias,
        'activo', interno.excel_si_no(t.activo))
      || CASE WHEN v_ventas THEN jsonb_build_object(
           'saldo_por_cobrar', interno.excel_lps(coalesce(cc.saldo, 0)),
           'vencido_por_cobrar', interno.excel_lps(coalesce(cc.vencido, 0)),
           'ultimo_cobro', (SELECT to_char(max(cb.fecha_contable), 'YYYY-MM-DD') FROM public.cobro cb WHERE cb.cliente_id = t.id AND cb.anulada_en IS NULL
                             AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, cb.sucursal_id))))
         ELSE '{}' END
      || CASE WHEN v_compras THEN jsonb_build_object(
           'saldo_por_pagar', interno.excel_lps(coalesce(cp.saldo, 0)),
           'vencido_por_pagar', interno.excel_lps(coalesce(cp.vencido, 0)),
           'ultimo_pago', (SELECT to_char(max(pp.fecha_contable), 'YYYY-MM-DD') FROM public.pago_proveedor pp
                            WHERE pp.proveedor_id = t.id AND NOT EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion an WHERE an.pago_id = pp.id)))
         ELSE '{}' END
      ORDER BY t.codigo), '[]')
      INTO v_filas
      FROM public.tercero t
      LEFT JOIN cxc cc ON cc.cliente_id = t.id
      LEFT JOIN cxp cp ON cp.proveedor_id = t.id
     WHERE t.empresa_id = p_empresa_id;

  ELSIF p_hoja = 'categorias' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('nombre', c.nombre,
             'categoria_madre', interno.excel_ruta_categoria(c.padre_id), 'activo', interno.excel_si_no(c.activa),
             'nivel', c.nivel, 'productos', (SELECT count(*) FROM public.producto p WHERE p.categoria_id = c.id))
           ORDER BY c.nivel, interno.excel_ruta_categoria(c.id)), '[]')
      INTO v_filas
      FROM public.categoria_producto c WHERE c.empresa_id = p_empresa_id;

  ELSIF p_hoja = 'existencias_iniciales' THEN
    -- Productos (bienes activos) x bodegas activas que todavía no tienen carga inicial.
    SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'bodega', b.codigo, 'cantidad', NULL, 'costo_unitario', NULL,
             'fecha', NULL, 'nombre', p.nombre, 'unidad', u.codigo, 'sucursal', su.codigo) ORDER BY b.codigo, p.codigo), '[]')
      INTO v_filas
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      JOIN public.bodega b ON b.empresa_id = p.empresa_id AND b.activa
                             AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, b.sucursal_id))
      JOIN public.sucursal su ON su.id = b.sucursal_id
     WHERE p.empresa_id = p_empresa_id AND p.activo AND p.tipo = 'bien'
       AND NOT EXISTS (SELECT 1 FROM public.inventario_movimiento m
                        WHERE m.bodega_id = b.id AND m.producto_id = p.id AND m.origen = 'carga_inicial'
                          AND NOT EXISTS (SELECT 1 FROM public.inventario_documento_anulacion an WHERE an.documento_id = m.documento_id));

  ELSIF p_hoja = 'saldos_iniciales' THEN
    WITH cxc AS (SELECT a.documento_id, a.saldo_centavos FROM interno.cxc_al(p_empresa_id, 'infinity') a WHERE v_cli AND a.origen = 'saldo_inicial'),
         cxp AS (SELECT a.documento_id, a.saldo_centavos FROM interno.cxp_al(p_empresa_id, 'infinity') a WHERE v_prov AND a.origen = 'saldo_inicial')
    SELECT coalesce(jsonb_agg(z.fila ORDER BY z.orden), '[]') INTO v_filas FROM (
      SELECT jsonb_build_object('tipo', 'cliente', 'codigo', t.codigo, 'documento', s.numero_documento,
               'fecha_documento', to_char(s.fecha_documento, 'YYYY-MM-DD'), 'vencimiento', to_char(s.fecha_vencimiento, 'YYYY-MM-DD'),
               'monto', interno.excel_lps(s.monto_centavos), 'fecha', to_char(s.fecha_contable, 'YYYY-MM-DD'), 'nombre', t.nombre,
               'saldo_pendiente', (SELECT interno.excel_lps(a.saldo_centavos) FROM cxc a WHERE a.documento_id = s.id)) AS fila,
             row_number() OVER (ORDER BY t.codigo, s.numero_documento) AS orden
        FROM public.cxc_saldo_inicial s JOIN public.tercero t ON t.id = s.cliente_id
       WHERE v_cli AND s.empresa_id = p_empresa_id AND s.anulada_en IS NULL
      UNION ALL
      SELECT jsonb_build_object('tipo', 'proveedor', 'codigo', t.codigo, 'documento', s.numero_documento,
               'fecha_documento', to_char(s.fecha_documento, 'YYYY-MM-DD'), 'vencimiento', to_char(s.fecha_vencimiento, 'YYYY-MM-DD'),
               'monto', interno.excel_lps(s.monto_centavos), 'fecha', to_char(s.fecha_contable, 'YYYY-MM-DD'), 'nombre', t.nombre,
               'saldo_pendiente', (SELECT interno.excel_lps(a.saldo_centavos) FROM cxp a WHERE a.documento_id = s.id)),
             100000000 + row_number() OVER (ORDER BY t.codigo, s.numero_documento)
        FROM public.cxp_saldo_inicial s JOIN public.tercero t ON t.id = s.proveedor_id
       WHERE v_prov AND s.empresa_id = p_empresa_id AND s.anulada_en IS NULL) z;

  ELSIF p_hoja = 'conteo_fisico' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'bodega', b.codigo, 'cantidad_contada', NULL,
             'nombre', p.nombre, 'unidad', u.codigo) ORDER BY b.codigo, p.codigo), '[]')
      INTO v_filas
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      JOIN public.bodega b ON b.empresa_id = p.empresa_id AND b.activa
                             AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, b.sucursal_id))
     WHERE p.empresa_id = p_empresa_id AND p.activo AND p.tipo = 'bien';
  END IF;

  RETURN jsonb_build_object(
    'hoja', p_hoja,
    'columnas', interno.excel_columnas(p_empresa_id, p_hoja, false),
    'filas', v_filas,
    'costos_ocultos', NOT v_costos AND p_hoja = 'productos',
    'generado_en', public.iso(now()),
    'reglas', jsonb_build_array(
      'Columnas editables (azules) se suben; columnas de solo información (grises) se ignoran.',
      'El código es la llave: con él se busca la fila. Un código que no existe crea uno nuevo.',
      'Celda vacía = se conserva lo que ya había. Nada se borra: para quitar algo, ponga Activo = No.',
      'Montos en lempiras con 2 decimales (ej. 1250.50). Fechas AAAA-MM-DD (ej. 2026-01-31). Sí o No.',
      'Primero suba el archivo en "vista previa": no guarda nada y muestra los errores por fila y columna.',
      'Al aplicar, todo se guarda junto o nada: si hay un solo error, no se guarda ninguna fila.'));
END $$;

-- ---------------------------------------------------------------------
-- 4) y 5) Conciliación
-- ---------------------------------------------------------------------
-- "otro": la contrapartida no puede ser una cuenta controlada por un módulo (como usar_fondo).
CREATE FUNCTION interno.revisar_cuenta_diferencia() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.tipo = 'otro' AND EXISTS (SELECT 1 FROM interno.cuenta_sistema cs JOIN public.cuenta c
                                     ON c.empresa_id = NEW.empresa_id AND c.codigo = interno.cuenta_de(NEW.empresa_id, cs.uso)
                                    WHERE cs.modulo_controla IS NOT NULL AND c.id = NEW.cuenta_id) THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la contrapartida "%" la mueve un módulo; use una cuenta de ingresos, costos o gastos que no sea de un módulo.',
      (SELECT c.codigo FROM public.cuenta c WHERE c.id = NEW.cuenta_id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER revisar_cuenta BEFORE INSERT ON public.banco_diferencia
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_cuenta_diferencia();

-- Importar: la conciliación y cada fila del banco deben ser de una cuenta de sucursal permitida
-- (el mismo trigger de 047 que usa el rastro del dinero).
CREATE TRIGGER revisar_sucursal BEFORE INSERT ON public.conciliacion
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_sucursal_fila('cuenta');
CREATE TRIGGER revisar_sucursal BEFORE INSERT ON public.banco_movimiento
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_sucursal_fila('cuenta');

-- conciliacion_para_escribir (reemplaza la de 043; misma firma): emparejar (automático y a mano),
-- deshacer, marcar anteriores, crear diferencias y cerrar exigen la sucursal de la cuenta de banco.
CREATE OR REPLACE FUNCTION interno.conciliacion_para_escribir(p_conciliacion_id uuid, p_permiso text) RETURNS public.conciliacion
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.conciliacion;
BEGIN
  SELECT * INTO c FROM public.conciliacion WHERE id = p_conciliacion_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la conciliación no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, p_permiso, 'conciliacion');
  PERFORM interno.exigir_sucursal(c.empresa_id, (SELECT d.sucursal_id FROM public.cuenta_dinero d WHERE d.id = c.cuenta_dinero_id));
  PERFORM pg_advisory_xact_lock(hashtext('conciliacion:' || c.cuenta_dinero_id::text));
  SELECT * INTO c FROM public.conciliacion WHERE id = p_conciliacion_id FOR UPDATE;
  IF c.estado = 'cerrada' THEN
    RAISE EXCEPTION 'CONCILIACION_CERRADA: la conciliación de %/% ya está cerrada.', lpad(c.mes::text, 2, '0'), c.anio;
  END IF;
  RETURN c;
END $$;

-- ---------------------------------------------------------------------
-- Permisos de las funciones nuevas (las reemplazadas conservan los suyos)
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.sesion_anterior_al_cierre(timestamptz), interno.reabrir_sin_reparto(),
  interno.documento_cxc_permitido(uuid, text, uuid), interno.documento_cxp_permitido(uuid, text, uuid),
  interno.revisar_cuenta_diferencia()
FROM PUBLIC, anon, authenticated, service_role;
