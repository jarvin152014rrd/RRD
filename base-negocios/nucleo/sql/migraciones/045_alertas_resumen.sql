-- =====================================================================
-- 045_alertas_resumen.sql  -  Núcleo 0.11.0 (etapa 3b-1): alertas en un solo
-- lugar y "¿cuánto gané hoy / este mes?" para el panel del dueño.
--
--   alerta_tipo            los tipos de alerta (datos: nombre y para qué sirve).
--   alerta_preferencia     qué tipos quiere recibir cada usuario (por defecto todos).
--   alertas_activas(empresa)   lista uniforme {tipo, gravedad, titulo, mensaje,
--                          que_hacer, enlace, datos} con las alertas que ya existen,
--                          SOLO las que el usuario puede ver por sus permisos (el
--                          cajero no ve dinero, bancos, costos ni créditos) y las que
--                          no apagó en sus preferencias.
--   resumen_hoy(empresa)   ventas de hoy, ganancia de hoy y del mes, dinero
--                          disponible, te deben (vencido aparte), debes; comparado con
--                          ayer y con el mes pasado. Cada parte solo con su permiso; la
--                          ganancia solo con inventario.costos (si no: null y
--                          "costos_ocultos").
-- =====================================================================

CREATE TABLE public.alerta_tipo (
  codigo       text PRIMARY KEY CHECK (codigo ~ '^[a-z_]{3,40}$'),
  nombre       text NOT NULL,
  descripcion  text NOT NULL,
  orden        integer NOT NULL
);
INSERT INTO public.alerta_tipo (codigo, nombre, descripcion, orden) VALUES
  ('cai',                'Facturación (CAI)',        'CAI vencido, por vencer, rango agotado o por agotarse, caja sin CAI', 1),
  ('cierre_mes',         'Cierre de mes',            'Meses que ya terminaron y siguen sin cerrar', 2),
  ('cuenta_negativa',    'Cuentas en negativo',      'Cajas o bancos con saldo menor que cero', 3),
  ('deposito_transito',  'Depósitos sin confirmar',  'Depósitos al banco que llevan varios días sin confirmarse', 4),
  ('diferencia_arqueo',  'Diferencias de caja',      'Cierres de caja con faltante o sobrante sin resolver', 5),
  ('aprobaciones',       'Aprobaciones pendientes',  'Descuentos, créditos, anulaciones, gastos o devoluciones esperando su decisión', 6),
  ('credito_vencido',    'Clientes con atraso',      'Clientes que debían pagar y no han pagado', 7),
  ('pago_fijo',          'Pagos fijos',              'Alquiler, luz, planilla y otros pagos vencidos o que vencen en 7 días', 8),
  ('stock_minimo',       'Mercadería por acabarse',  'Productos con existencia igual o menor a su mínimo', 9),
  ('conciliacion',       'Conciliación bancaria',    'Cuentas de banco sin conciliar el mes pasado', 10),
  ('licencia',           'Licencia del sistema',     'La licencia vence pronto o ya venció', 11),
  ('limite_contrato',    'Límites del plan',         'Usuarios, cajas, sucursales o bodegas al 80 % o más de su plan', 12);
ALTER TABLE public.alerta_tipo ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.alerta_tipo FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.alerta_tipo TO authenticated, service_role;
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.alerta_tipo FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');

CREATE TABLE public.alerta_preferencia (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  user_id         uuid NOT NULL,
  tipo            text NOT NULL REFERENCES public.alerta_tipo(codigo),
  recibir         boolean NOT NULL,
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, user_id, tipo)
);
ALTER TABLE public.alerta_preferencia ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.alerta_preferencia FOR SELECT TO authenticated USING (user_id = auth.uid());
GRANT SELECT ON public.alerta_preferencia TO authenticated, service_role;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.alerta_preferencia FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.alerta_preferencia
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las preferencias no se borran: se cambian a recibir sí o no.');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.alerta_preferencia
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');

-- ---------------------------------------------------------------------
-- 1) Ayudantes
-- ---------------------------------------------------------------------
-- Pertenece a la empresa (o es la llave del servidor).
CREATE FUNCTION interno.exigir_miembro(p_empresa_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    IF coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
    END IF;
    RETURN;
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
END $$;

-- ¿Este usuario puede ver este tipo de alerta? (permisos y módulos)
CREATE FUNCTION interno.puede_ver_alerta(p_empresa_id uuid, p_tipo text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE p_tipo
    WHEN 'cai'               THEN public.modulo_esta_activo(p_empresa_id, 'fiscal_hn')
                                  AND (public.puede_leer(p_empresa_id, 'cai.administrar') OR public.puede_leer(p_empresa_id, 'ventas.ver')
                                       OR public.puede_leer(p_empresa_id, 'ventas.vender'))
    WHEN 'cierre_mes'        THEN public.puede_leer(p_empresa_id, 'periodos.cerrar')
    WHEN 'cuenta_negativa'   THEN public.modulo_esta_activo(p_empresa_id, 'dinero') AND public.puede_leer(p_empresa_id, 'dinero.ver')
    WHEN 'deposito_transito' THEN public.modulo_esta_activo(p_empresa_id, 'dinero') AND public.puede_leer(p_empresa_id, 'dinero.ver')
    WHEN 'diferencia_arqueo' THEN public.modulo_esta_activo(p_empresa_id, 'dinero') AND public.puede_leer(p_empresa_id, 'caja.supervisar')
    WHEN 'aprobaciones'      THEN public.puede_leer(p_empresa_id, 'aprobaciones.ver')
    WHEN 'credito_vencido'   THEN public.modulo_esta_activo(p_empresa_id, 'ventas') AND public.puede_leer(p_empresa_id, 'ventas.ver')
    WHEN 'pago_fijo'         THEN public.modulo_esta_activo(p_empresa_id, 'dinero') AND public.puede_leer(p_empresa_id, 'dinero.ver')
    WHEN 'stock_minimo'      THEN public.modulo_esta_activo(p_empresa_id, 'inventario') AND public.puede_leer(p_empresa_id, 'inventario.ver')
    WHEN 'conciliacion'      THEN public.modulo_esta_activo(p_empresa_id, 'conciliacion') AND public.puede_leer(p_empresa_id, 'conciliacion.ver')
    WHEN 'licencia'          THEN public.puede_leer(p_empresa_id, 'proveedor.solicitar')
    WHEN 'limite_contrato'   THEN public.puede_leer(p_empresa_id, 'proveedor.solicitar')
    ELSE false END
$$;

CREATE FUNCTION interno.alerta(p_tipo text, p_gravedad text, p_titulo text, p_mensaje text, p_que_hacer text, p_enlace text,
                               p_datos jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('tipo', p_tipo, 'gravedad', p_gravedad, 'titulo', p_titulo, 'mensaje', p_mensaje,
                            'que_hacer', p_que_hacer, 'enlace', p_enlace, 'datos', coalesce(p_datos, '{}'))
$$;

-- Las alertas de un tipo (sin revisar permisos ni preferencias).
CREATE FUNCTION interno.alertas_de(p_empresa_id uuid, p_tipo text) RETURNS jsonb
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
  r       record;
BEGIN
  SELECT * INTO e FROM public.empresa WHERE id = p_empresa_id;
  IF p_tipo = 'cai' THEN
    FOR r IN SELECT x FROM jsonb_array_elements(public.cai_alertas(p_empresa_id)->'alertas') x LOOP
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
              WHERE d.empresa_id = p_empresa_id AND interno.saldo_dinero(d.id) < 0 ORDER BY d.nombre LOOP
      v_a := v_a || interno.alerta('cuenta_negativa', 'alta', 'Cuenta en negativo',
        'La cuenta "' || r.nombre || '" está en ' || interno.lempiras(r.saldo) || '.',
        'Registre el dinero que entró y falta en el sistema o revise el saldo inicial de esa cuenta.',
        '/dinero/cuentas/' || r.id, jsonb_build_object('cuenta_dinero_id', r.id, 'saldo_centavos', r.saldo));
    END LOOP;

  ELSIF p_tipo = 'deposito_transito' THEN
    FOR r IN SELECT o.id, o.monto_centavos, o.fecha_contable, d.nombre AS banco, v_hoy - o.fecha_contable AS dias
               FROM public.operacion_dinero o JOIN public.cuenta_dinero d ON d.id = o.destino_id
              WHERE o.empresa_id = p_empresa_id AND o.tipo = 'deposito' AND o.estado = 'en_transito' AND o.anulada_en IS NULL
                AND v_hoy - o.fecha_contable > e.dias_alerta_transito ORDER BY o.fecha_contable LOOP
      v_a := v_a || interno.alerta('deposito_transito', 'media', 'Depósito sin confirmar',
        'El depósito de ' || interno.lempiras(r.monto_centavos) || ' a "' || r.banco || '" del ' || to_char(r.fecha_contable, 'DD/MM/YYYY')
          || ' lleva ' || r.dias || ' días sin confirmarse.',
        'Revise el estado de cuenta del banco. Si ya llegó, confírmelo; si no, averigüe con quien lo llevó.',
        '/dinero/depositos', jsonb_build_object('operacion_id', r.id, 'monto_centavos', r.monto_centavos, 'dias', r.dias));
    END LOOP;

  ELSIF p_tipo = 'diferencia_arqueo' THEN
    SELECT count(*) INTO v_n FROM public.turno_caja t
     WHERE t.empresa_id = p_empresa_id AND t.diferencia_estado = 'pendiente';
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
              WHERE x.saldo_centavos > 0 AND x.vence_el < v_hoy GROUP BY x.cliente_id, t.nombre ORDER BY min(x.vence_el) LOOP
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
               FROM public.producto p LEFT JOIN public.inventario_saldo s ON s.producto_id = p.id
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

-- ---------------------------------------------------------------------
-- 2) RPC de alertas
-- ---------------------------------------------------------------------
CREATE FUNCTION public.alertas_activas(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t       public.alerta_tipo;
  v_a     jsonb := '[]';
  v_apag  integer := 0;
  v_quiere boolean;
BEGIN
  PERFORM interno.exigir_miembro(p_empresa_id);
  FOR t IN SELECT * FROM public.alerta_tipo ORDER BY orden LOOP
    CONTINUE WHEN NOT interno.puede_ver_alerta(p_empresa_id, t.codigo);
    SELECT x.recibir INTO v_quiere FROM public.alerta_preferencia x
     WHERE x.empresa_id = p_empresa_id AND x.user_id = auth.uid() AND x.tipo = t.codigo;
    IF v_quiere IS FALSE THEN
      v_apag := v_apag + jsonb_array_length(interno.alertas_de(p_empresa_id, t.codigo));
      CONTINUE;
    END IF;
    v_a := v_a || interno.alertas_de(p_empresa_id, t.codigo);
  END LOOP;
  RETURN jsonb_build_object('fecha', to_char(public.hoy_local(p_empresa_id), 'YYYY-MM-DD'), 'generado_en', public.iso(now()),
    'cantidad', jsonb_array_length(v_a),
    'altas', (SELECT count(*) FROM jsonb_array_elements(v_a) x WHERE x->>'gravedad' = 'alta'),
    'ocultas_por_preferencia', v_apag,
    'alertas', (SELECT coalesce(jsonb_agg(x ORDER BY CASE x->>'gravedad' WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END, n), '[]')
                  FROM jsonb_array_elements(v_a) WITH ORDINALITY AS y(x, n)));
END $$;

-- guardar_preferencias_alertas(empresa, {"stock_minimo": false, "cai": true})   cada usuario las suyas
CREATE FUNCTION public.guardar_preferencias_alertas(p_empresa_id uuid, p_datos jsonb) RETURNS jsonb
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
    INSERT INTO public.alerta_preferencia (empresa_id, user_id, tipo, recibir) VALUES (p_empresa_id, auth.uid(), k, v::boolean)
    ON CONFLICT (empresa_id, user_id, tipo) DO UPDATE SET recibir = EXCLUDED.recibir, actualizado_en = now();
  END LOOP;
  RETURN public.mis_preferencias_alertas(p_empresa_id);
END $$;

-- Los tipos que el usuario puede recibir y si los quiere (por defecto sí).
CREATE FUNCTION public.mis_preferencias_alertas(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_miembro(p_empresa_id);
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('tipo', t.codigo, 'nombre', t.nombre, 'descripcion', t.descripcion,
            'recibir', coalesce(p.recibir, true)) ORDER BY t.orden), '[]')
    FROM public.alerta_tipo t
    LEFT JOIN public.alerta_preferencia p ON p.empresa_id = p_empresa_id AND p.user_id = auth.uid() AND p.tipo = t.codigo
   WHERE interno.puede_ver_alerta(p_empresa_id, t.codigo));
END $$;

-- ---------------------------------------------------------------------
-- 3) "¿Cuánto gané hoy?" (panel del dueño)
-- ---------------------------------------------------------------------
-- Ventas emitidas (no anuladas) de un rango de fechas: total con ISV y cantidad.
CREATE FUNCTION interno.ventas_del(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('total_centavos', coalesce(sum(v.total_centavos), 0), 'cantidad', count(*))
    FROM public.venta v WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND v.fecha_contable BETWEEN p_desde AND p_hasta
$$;

CREATE FUNCTION interno.comparar(p_actual bigint, p_antes bigint) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('diferencia_centavos', p_actual - p_antes,
    'porcentaje', CASE WHEN p_antes <> 0 THEN round((p_actual - p_antes) * 100.0 / abs(p_antes), 1) END)
$$;

CREATE FUNCTION public.resumen_hoy(p_empresa_id uuid) RETURNS jsonb
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
  IF v_ventas AND v_costos THEN
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
  IF v_cont AND v_costos THEN
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
                               WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('efectivo_caja', 'banco', 'caja_chica')),
      'por_confirmar_centavos', (SELECT coalesce(sum(interno.saldo_dinero(d.id)), 0) FROM public.cuenta_dinero d
                               WHERE d.empresa_id = p_empresa_id AND d.tipo IN ('transito', 'transferencia_por_confirmar', 'pos_por_liquidar'))));
  ELSE
    v_ocultos := v_ocultos || ARRAY['dinero'];
  END IF;

  IF v_ventas THEN
    r := r || jsonb_build_object('te_deben', (SELECT jsonb_build_object(
      'total_centavos', coalesce(sum(x.saldo_centavos), 0),
      'vencido_centavos', coalesce(sum(x.saldo_centavos) FILTER (WHERE x.vence_el < v_hoy), 0),
      'clientes', count(DISTINCT x.cliente_id))
      FROM interno.cxc_al(p_empresa_id, 'infinity') x WHERE x.saldo_centavos > 0));
  ELSE
    v_ocultos := v_ocultos || ARRAY['te_deben'];
  END IF;

  IF v_compras THEN
    r := r || jsonb_build_object('debes', (SELECT jsonb_build_object(
      'total_centavos', coalesce(sum(x.saldo_centavos), 0),
      'vencido_centavos', coalesce(sum(x.saldo_centavos) FILTER (WHERE x.vence_el < v_hoy), 0),
      'proveedores', count(DISTINCT x.proveedor_id))
      FROM interno.cxp_al(p_empresa_id, 'infinity') x WHERE x.saldo_centavos > 0));
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
    'frase', v_frase, 'costos_ocultos', NOT v_costos, 'ocultos', to_jsonb(v_ocultos),
    'nota', 'Ventas con ISV (emitidas y no anuladas). Ganancia de hoy = ventas sin ISV - costo de lo vendido. Ganancia del mes = ventas - costo - gastos, desde el día 1 hasta hoy.');
END $$;

REVOKE EXECUTE ON FUNCTION
  interno.exigir_miembro(uuid), interno.puede_ver_alerta(uuid, text), interno.alerta(text, text, text, text, text, text, jsonb),
  interno.alertas_de(uuid, text), interno.ventas_del(uuid, date, date), interno.comparar(bigint, bigint)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.alertas_activas(uuid), public.guardar_preferencias_alertas(uuid, jsonb),
  public.mis_preferencias_alertas(uuid), public.resumen_hoy(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.alertas_activas(uuid), public.mis_preferencias_alertas(uuid), public.resumen_hoy(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_preferencias_alertas(uuid, jsonb) TO authenticated;
