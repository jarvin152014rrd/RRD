-- =====================================================================
-- 036_comisiones.sql  -  Núcleo 0.9.0 (etapa 2b-2b): comisiones de
-- vendedores (módulo "comisiones", necesita "ventas").
--
--   Interruptor por empresa (empresa.comisiones_activas, solo el dueño) y
--   base elegida por el dueño (empresa.comision_base):
--     ganancia (recomendado) = precio sin ISV - costo (bienes: costo del
--       kardex; servicios: costo estimado)
--     precio   = precio sin ISV
--   NUNCA sobre el ISV. Porcentaje por empleado con fecha desde
--   (comision_porcentaje, historial; vale el de la fecha de la venta).
--   Se DEVENGAN cuando la venta queda cobrada completa (contado: al emitir;
--   crédito: cuando su saldo llega a 0) y se AJUSTAN solas con devoluciones,
--   cobros anulados y anulaciones (aunque ya se hayan pagado: queda saldo a
--   descontar del próximo pago). Cada cambio es un movimiento con su asiento:
--     Dr 6.1.01.04 Comisiones sobre ventas / Cr 2.1.03.04 Comisiones por pagar
--   Pago por período (liquidación) desde una cuenta de dinero elegida:
--     Dr Comisiones por pagar / Cr cuenta de dinero (con rastro). Se anula con motivo.
--   El vendedor ve SOLO sus comisiones (monto, no costos: v_mis_comisiones).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('NADA_QUE_PAGAR', 'No hay comisiones por pagar en ese período.',
   'Revise el período: puede que todo esté pagado o que haya un saldo a descontar por devoluciones.');

INSERT INTO public.modulo (codigo, nombre) VALUES ('comisiones', 'Comisiones de vendedores');
INSERT INTO public.modulo_dependencia (modulo, requiere, motivo) VALUES
  ('comisiones', 'ventas', 'Las comisiones salen de las ventas cobradas.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('comisiones.configurar', 'Encender o apagar comisiones, elegir la base y fijar el porcentaje de cada empleado', false, false),
  ('comisiones.ver',        'Ver las comisiones de todos los vendedores', false, true),
  ('comisiones.pagar',      'Pagar (liquidar) comisiones y anular esos pagos', true, false);
-- Criterio (REQUISITOS): comisiones = solo el dueño las configura; el admin
-- ve y paga; el contador solo ve. El vendedor ve las suyas sin permiso extra.
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'comisiones.configurar'), ('dueno', 'comisiones.ver'), ('dueno', 'comisiones.pagar'),
  ('admin', 'comisiones.ver'), ('admin', 'comisiones.pagar'),
  ('contador', 'comisiones.ver');
SELECT interno.repartir_permisos(ARRAY['comisiones.configurar', 'comisiones.ver', 'comisiones.pagar'], 'Núcleo 0.9.0: comisiones');

INSERT INTO interno.plantilla_cuenta (codigo, nombre, tipo, naturaleza, es_detalle) VALUES
  ('2.1.03.04', 'Comisiones por pagar',    'pasivo', 'acreedora', true),
  ('6.1.01.04', 'Comisiones sobre ventas', 'gasto',  'deudora',   true);
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('comisiones_por_pagar', '2.1.03.04', 'Comisiones devengadas por pagar a vendedores (negativo = saldo a descontar)', 'comisiones'),
  ('gasto_comisiones',     '6.1.01.04', 'Gasto de comisiones sobre ventas', NULL);
DO $$
DECLARE e record;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.9.0: cuentas de comisiones', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    PERFORM interno.asegurar_cuenta_uso(e.id, 'comisiones_por_pagar', 'Comisiones por pagar');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'gasto_comisiones', 'Comisiones sobre ventas');
  END LOOP;
  PERFORM set_config('app.motivo', '', true);
END $$;

ALTER TABLE public.empresa
  ADD COLUMN comisiones_activas boolean NOT NULL DEFAULT false,
  ADD COLUMN comision_base      text NOT NULL DEFAULT 'ganancia' CHECK (comision_base IN ('ganancia', 'precio'));

-- ---------------------------------------------------------------------
-- 1) Tablas
-- ---------------------------------------------------------------------
-- Porcentaje de cada empleado (historial: solo agregar; vale el de la fecha de la venta).
CREATE TABLE public.comision_porcentaje (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id     uuid NOT NULL REFERENCES public.empresa(id),
  user_id        uuid NOT NULL,
  porcentaje     numeric(5,2) NOT NULL CHECK (porcentaje BETWEEN 0 AND 100),
  desde          date NOT NULL,
  motivo         text NOT NULL,
  creado_por     uuid,
  registrado_en  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX comision_porcentaje_usuario ON public.comision_porcentaje (empresa_id, user_id, desde);

CREATE TABLE public.comision_movimiento (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  vendedor_id     uuid NOT NULL,
  venta_id        uuid NOT NULL,
  tipo            text NOT NULL CHECK (tipo IN ('devengo', 'ajuste')),
  base_tipo       text NOT NULL CHECK (base_tipo IN ('ganancia', 'precio')),
  base_centavos   bigint NOT NULL,          -- base total de la venta en este momento (sin ISV)
  porcentaje      numeric(5,2) NOT NULL,
  monto_centavos  bigint NOT NULL CHECK (monto_centavos <> 0),   -- + devenga, - ajuste a la baja
  fecha_contable  date NOT NULL,
  asiento_id      uuid NOT NULL,
  creado_por      uuid,
  registrado_en   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, venta_id)   REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id) REFERENCES public.asiento(empresa_id, id)
);
CREATE INDEX comision_movimiento_venta ON public.comision_movimiento (venta_id);
CREATE INDEX comision_movimiento_vendedor ON public.comision_movimiento (empresa_id, vendedor_id, fecha_contable);

CREATE TABLE public.comision_liquidacion (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  vendedor_id              uuid NOT NULL,
  hasta                    date NOT NULL,               -- movimientos hasta esta fecha
  fecha_contable           date NOT NULL,
  monto_centavos           bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  cuenta_dinero_id         uuid NOT NULL,
  referencia               text,
  equipo                   text,
  asiento_id               uuid NOT NULL,
  id_operacion             uuid NOT NULL,
  creado_por               uuid,
  registrado_en            timestamptz NOT NULL DEFAULT now(),
  anulada_en               timestamptz,
  anulada_por              uuid,
  motivo_anulacion         text,
  fecha_anulacion          date,
  asiento_anulacion_id     uuid,
  anulacion_id_operacion   uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, cuenta_dinero_id)     REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL)),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL))
);

CREATE TABLE public.comision_liquidacion_detalle (
  liquidacion_id  uuid NOT NULL REFERENCES public.comision_liquidacion(id),
  movimiento_id   bigint NOT NULL REFERENCES public.comision_movimiento(id),
  empresa_id      uuid NOT NULL,
  PRIMARY KEY (liquidacion_id, movimiento_id)
);
CREATE INDEX comision_detalle_movimiento ON public.comision_liquidacion_detalle (movimiento_id);

CREATE TRIGGER proteger BEFORE UPDATE ON public.comision_porcentaje
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El historial de porcentajes no se edita: se agrega uno nuevo.');
CREATE TRIGGER proteger BEFORE UPDATE ON public.comision_movimiento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los movimientos de comisión no se editan.');
CREATE TRIGGER proteger BEFORE UPDATE ON public.comision_liquidacion
  FOR EACH ROW EXECUTE FUNCTION interno.proteger_anulable();
CREATE TRIGGER proteger BEFORE UPDATE ON public.comision_liquidacion_detalle
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El detalle de un pago de comisiones no se edita.');
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['comision_porcentaje', 'comision_movimiento', 'comision_liquidacion', 'comision_liquidacion_detalle'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'Las comisiones no se borran.');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', t, 'comisiones.ver');
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 2) Cálculo
-- ---------------------------------------------------------------------
-- Porcentaje de un empleado en una fecha (0 si no tiene).
CREATE FUNCTION interno.porcentaje_comision(p_empresa_id uuid, p_user_id uuid, p_fecha date) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT c.porcentaje FROM public.comision_porcentaje c
                    WHERE c.empresa_id = p_empresa_id AND c.user_id = p_user_id AND c.desde <= p_fecha
                    ORDER BY c.desde DESC, c.id DESC LIMIT 1), 0)
$$;

-- Base de la comisión de una venta HOY (sin ISV, menos lo devuelto).
-- ganancia = base sin ISV - costo (bienes) - costo estimado (servicios); precio = base sin ISV.
CREATE FUNCTION interno.base_comision(p_venta_id uuid, p_base_tipo text) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT (coalesce(sum(l.base_centavos - coalesce(dv.base, 0)
                       - CASE WHEN p_base_tipo = 'ganancia'
                              THEN coalesce(l.costo_centavos, 0) - coalesce(dv.costo, 0)
                                   + coalesce(l.costo_estimado_centavos, 0) - coalesce(dv.est, 0)
                              ELSE 0 END), 0))::bigint
    FROM public.venta_linea l
    LEFT JOIN LATERAL (SELECT sum(x.base_centavos) AS base, sum(x.costo_centavos) AS costo, sum(x.costo_estimado_centavos) AS est
                         FROM public.devolucion_linea x JOIN public.devolucion d ON d.id = x.devolucion_id
                        WHERE x.venta_linea_id = l.id AND d.estado = 'aplicada') dv ON true
   WHERE l.venta_id = p_venta_id
$$;

-- Revisa la comisión de una venta y registra la diferencia (devengo o ajuste)
-- con su asiento. Lo llaman la venta, los cobros, las condonaciones, las
-- devoluciones y las anulaciones (reemplaza el gancho de 033).
--   Objetivo = round(base x % / 100) si la venta está emitida y cobrada completa; si no, 0.
--   Con el módulo o el interruptor apagado no se devengan comisiones NUEVAS,
--   pero las ya devengadas sí se ajustan (devoluciones, anulaciones).
CREATE OR REPLACE FUNCTION interno.recalcular_comision(p_venta_id uuid, p_id_operacion uuid, p_fecha date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v        public.venta;
  e        public.empresa;
  m0       public.comision_movimiento;
  v_hay    integer;
  v_actual bigint;
  v_pct    numeric;
  v_btipo  text;
  v_base   bigint := 0;
  v_obj    bigint := 0;
  v_dif    bigint;
  v_asto   uuid;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RETURN;
  END IF;
  SELECT * INTO e FROM public.empresa WHERE id = v.empresa_id;
  SELECT count(*), coalesce(sum(x.monto_centavos), 0) INTO v_hay, v_actual FROM public.comision_movimiento x WHERE x.venta_id = v.id;
  SELECT * INTO m0 FROM public.comision_movimiento x WHERE x.venta_id = v.id ORDER BY x.id LIMIT 1;
  IF m0.id IS NOT NULL THEN
    v_pct := m0.porcentaje;  v_btipo := m0.base_tipo;   -- se respetan el % y la base con que se devengó
  ELSE
    IF NOT (e.comisiones_activas AND public.modulo_esta_activo(v.empresa_id, 'comisiones')) THEN
      RETURN;
    END IF;
    v_pct := interno.porcentaje_comision(v.empresa_id, v.vendedor_id, v.fecha_contable);
    v_btipo := e.comision_base;
    IF v_pct = 0 THEN
      RETURN;
    END IF;
  END IF;
  IF v.estado = 'emitida' AND interno.saldo_documento_cxc(v.id) <= 0 THEN
    v_base := interno.base_comision(v.id, v_btipo);
    v_obj := greatest(round(v_base * v_pct / 100), 0)::bigint;
  END IF;
  v_dif := v_obj - v_actual;
  IF v_dif = 0 THEN
    RETURN;
  END IF;
  v_asto := interno.asiento_sistema(v.empresa_id, interno.sucursal_activa(v.sucursal_id), p_fecha,
    CASE WHEN v_dif > 0 THEN 'Comisión de ' ELSE 'Ajuste de comisión de ' END || coalesce(public.nombre_usuario(v.empresa_id, v.vendedor_id), 'vendedor')
      || ' por la venta ' || v.numero_documento,
    'comision', md5(p_id_operacion::text || ':comision:' || v.id::text || ':' || v_hay)::uuid,
    jsonb_build_array(
      jsonb_build_object('uso', 'gasto_comisiones',     'debe',  greatest(v_dif, 0),  'descripcion', 'Comisión devengada'),
      jsonb_build_object('uso', 'comisiones_por_pagar', 'haber', greatest(v_dif, 0),  'descripcion', 'Comisión por pagar'),
      jsonb_build_object('uso', 'comisiones_por_pagar', 'debe',  greatest(-v_dif, 0), 'descripcion', 'Ajuste de comisión'),
      jsonb_build_object('uso', 'gasto_comisiones',     'haber', greatest(-v_dif, 0), 'descripcion', 'Ajuste de comisión')));
  INSERT INTO public.comision_movimiento (empresa_id, vendedor_id, venta_id, tipo, base_tipo, base_centavos, porcentaje, monto_centavos,
                                          fecha_contable, asiento_id, creado_por)
  VALUES (v.empresa_id, v.vendedor_id, v.id, CASE WHEN v_hay = 0 THEN 'devengo' ELSE 'ajuste' END, v_btipo, v_base, v_pct, v_dif,
          p_fecha, v_asto, auth.uid());
END $$;

-- Movimientos de un vendedor que todavía no se pagaron (sin liquidación vigente).
CREATE FUNCTION interno.comision_sin_pagar(p_empresa_id uuid, p_vendedor_id uuid, p_hasta date) RETURNS TABLE (id bigint, monto bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT m.id, m.monto_centavos FROM public.comision_movimiento m
   WHERE m.empresa_id = p_empresa_id AND m.vendedor_id = p_vendedor_id AND m.fecha_contable <= p_hasta
     AND NOT EXISTS (SELECT 1 FROM public.comision_liquidacion_detalle dd JOIN public.comision_liquidacion l ON l.id = dd.liquidacion_id
                      WHERE dd.movimiento_id = m.id AND l.anulada_en IS NULL)
$$;

-- Total por pagar de comisiones de la empresa (debe = saldo de 2.1.03.04).
CREATE FUNCTION interno.total_comisiones_por_pagar(p_empresa_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ( coalesce((SELECT sum(m.monto_centavos) FROM public.comision_movimiento m WHERE m.empresa_id = p_empresa_id), 0)
         - coalesce((SELECT sum(l.monto_centavos) FROM public.comision_liquidacion l WHERE l.empresa_id = p_empresa_id AND l.anulada_en IS NULL), 0)
         )::bigint
$$;

-- ---------------------------------------------------------------------
-- 3) RPC
-- ---------------------------------------------------------------------
-- configurar_comisiones(empresa, {"activas": true|false, "base": "ganancia"|"precio"}, motivo)   solo el dueño
CREATE FUNCTION public.configurar_comisiones(p_empresa_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.empresa;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'comisiones.configurar', 'comisiones');
  PERFORM interno.exigir_claves(p_datos, ARRAY['activas', 'base']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF p_datos ? 'activas' THEN
    PERFORM interno.json_si_no(p_datos->'activas', 'activas');
  END IF;
  IF p_datos ? 'base' AND coalesce(p_datos->>'base', '') NOT IN ('ganancia', 'precio') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la base de la comisión es "ganancia" (precio sin ISV menos costo) o "precio" (sin ISV).';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET comisiones_activas = coalesce((p_datos->>'activas')::boolean, comisiones_activas),
         comision_base = coalesce(p_datos->>'base', comision_base)
   WHERE id = p_empresa_id
  RETURNING * INTO e;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('comisiones_activas', e.comisiones_activas, 'comision_base', e.comision_base);
END $$;

-- fijar_porcentaje_comision(empresa, usuario, porcentaje, desde, motivo)   solo el dueño
CREATE FUNCTION public.fijar_porcentaje_comision(p_empresa_id uuid, p_user_id uuid, p_porcentaje numeric, p_desde date, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_desde date;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'comisiones.configurar', 'comisiones');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = p_user_id
                   AND ue.rol NOT IN ('proveedor', 'contador')) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el empleado no es usuario de esta empresa (o es contador o proveedor).';
  END IF;
  IF p_porcentaje IS NULL OR p_porcentaje NOT BETWEEN 0 AND 100 OR p_porcentaje <> round(p_porcentaje, 2) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el porcentaje va de 0 a 100 (hasta 2 decimales).';
  END IF;
  v_desde := coalesce(p_desde, public.hoy_local(p_empresa_id));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.comision_porcentaje (empresa_id, user_id, porcentaje, desde, motivo, creado_por)
  VALUES (p_empresa_id, p_user_id, p_porcentaje, v_desde, trim(p_motivo), auth.uid());
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('user_id', p_user_id, 'porcentaje', p_porcentaje, 'desde', to_char(v_desde, 'YYYY-MM-DD'));
END $$;

-- pagar_comisiones(empresa, datos, id_operacion)   comisiones.pagar
-- datos = {"vendedor_id":"...","hasta":"2026-01-31","cuenta_dinero_id":"...","fecha":"...","referencia":"...","equipo":"..."}
-- Paga todo lo pendiente hasta "hasta" (los ajustes negativos se descuentan).
CREATE FUNCTION public.pagar_comisiones(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l       public.comision_liquidacion;
  v_vend  uuid;
  v_hasta date;
  v_fecha date;
  d       public.cuenta_dinero;
  v_total bigint;
  v_asto  uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'comisiones.pagar', 'comisiones');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'pago_comisiones');
  SELECT * INTO l FROM public.comision_liquidacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF l.id IS NOT NULL THEN
    RETURN jsonb_build_object('liquidacion_id', l.id, 'numero', l.numero, 'monto_centavos', l.monto_centavos, 'asiento_id', l.asiento_id, 'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['vendedor_id', 'hasta', 'cuenta_dinero_id', 'fecha', 'referencia', 'equipo']);
  v_vend := interno.json_uuid(p_datos->'vendedor_id', 'vendedor_id');
  IF v_vend IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el vendedor ("vendedor_id").';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  v_hasta := coalesce(interno.json_fecha(p_datos->'hasta', 'hasta'), v_fecha);
  IF v_hasta > v_fecha THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el período pagado ("hasta") no puede pasar la fecha del pago.';
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  IF NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo (el pago sale de una cuenta de dinero).';
  END IF;
  d := interno.cuenta_dinero_para_pagar(p_empresa_id, interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id'));

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'pago_comisiones');
  SELECT * INTO l FROM public.comision_liquidacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF l.id IS NOT NULL THEN
    RETURN jsonb_build_object('liquidacion_id', l.id, 'numero', l.numero, 'monto_centavos', l.monto_centavos, 'asiento_id', l.asiento_id, 'duplicado', true);
  END IF;
  SELECT coalesce(sum(x.monto), 0) INTO v_total FROM interno.comision_sin_pagar(p_empresa_id, v_vend, v_hasta) x;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'NADA_QUE_PAGAR: el vendedor tiene % por pagar hasta el % (si es negativo, se descuenta del próximo pago).',
      interno.lempiras(v_total), to_char(v_hasta, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  l.id := gen_random_uuid();
  l.numero := interno.siguiente_numero(p_empresa_id, 'comision_liquidacion');
  v_asto := interno.asiento_sistema(p_empresa_id, interno.sucursal_activa(d.sucursal_id), v_fecha,
    'Pago de comisiones #' || l.numero || ' a ' || coalesce(public.nombre_usuario(p_empresa_id, v_vend), 'vendedor')
      || ' hasta el ' || to_char(v_hasta, 'DD/MM/YYYY'), 'pago_comisiones', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'comisiones_por_pagar', 'debe', v_total, 'descripcion', 'Pago de comisiones'),
                      jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'haber', v_total, 'descripcion', 'Pago de comisiones')));
  INSERT INTO public.comision_liquidacion (id, empresa_id, numero, vendedor_id, hasta, fecha_contable, monto_centavos, cuenta_dinero_id,
    referencia, equipo, asiento_id, id_operacion, creado_por)
  VALUES (l.id, p_empresa_id, l.numero, v_vend, v_hasta, v_fecha, v_total, d.id, interno.json_texto(p_datos->'referencia', 'referencia', 100),
    interno.equipo(p_datos), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO l;
  INSERT INTO public.comision_liquidacion_detalle (liquidacion_id, movimiento_id, empresa_id)
  SELECT l.id, x.id, p_empresa_id FROM interno.comision_sin_pagar(p_empresa_id, v_vend, v_hasta) x;
  PERFORM interno.rastrear_dinero(v_asto, 'pago_comisiones', 'comision_liquidacion', l.id,
                                  coalesce(l.referencia, 'Comisiones #' || l.numero), l.equipo);
  RETURN jsonb_build_object('liquidacion_id', l.id, 'numero', l.numero, 'monto_centavos', v_total, 'asiento_id', v_asto,
    'movimientos', (SELECT count(*) FROM public.comision_liquidacion_detalle x WHERE x.liquidacion_id = l.id), 'duplicado', false);
END $$;

-- anular_pago_comisiones(liquidacion, motivo, id_operacion, fecha?)   comisiones.pagar
-- Contra-asiento: el dinero vuelve a la MISMA cuenta; los movimientos vuelven a quedar por pagar.
CREATE FUNCTION public.anular_pago_comisiones(p_liquidacion_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l       public.comision_liquidacion;
  v_fecha date;
  v_asto  uuid;
  v_suc   uuid;
BEGIN
  SELECT * INTO l FROM public.comision_liquidacion WHERE id = p_liquidacion_id;
  IF l.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el pago de comisiones no existe.';
  END IF;
  PERFORM interno.exigir_escritura(l.empresa_id, 'comisiones.pagar', 'comisiones');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(l.empresa_id, p_id_operacion, 'anulacion_pago_comisiones');
  IF l.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('liquidacion_id', l.id, 'asiento_id', l.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(l.empresa_id), l.fecha_contable));
  PERFORM interno.exigir_fecha_contable(l.empresa_id, v_fecha);
  IF v_fecha < l.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al pago (%).', to_char(l.fecha_contable, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.reservar_operacion(l.empresa_id, p_id_operacion, 'anulacion_pago_comisiones');
  SELECT * INTO l FROM public.comision_liquidacion WHERE id = p_liquidacion_id FOR UPDATE;
  IF l.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('liquidacion_id', l.id, 'asiento_id', l.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF l.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el pago de comisiones #% ya fue anulado.', l.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(l.empresa_id, v_fecha);
  SELECT a.sucursal_id INTO v_suc FROM public.asiento a WHERE a.id = l.asiento_id;
  v_asto := interno.asiento_sistema(l.empresa_id, interno.sucursal_activa(v_suc), v_fecha,
    'ANULACIÓN pago de comisiones #' || l.numero || ': ' || trim(p_motivo), 'anulacion_pago_comisiones', p_id_operacion,
    jsonb_build_array(jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(l.cuenta_dinero_id), 'debe', l.monto_centavos,
                                         'descripcion', 'Vuelve el dinero del pago'),
                      jsonb_build_object('uso', 'comisiones_por_pagar', 'haber', l.monto_centavos, 'descripcion', 'Vuelven a quedar por pagar')),
    l.asiento_id, trim(p_motivo));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.comision_liquidacion SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo),
         fecha_anulacion = v_fecha, asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = l.id;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_pago_comisiones', 'comision_liquidacion', l.id, trim(p_motivo), NULL);
  RETURN jsonb_build_object('liquidacion_id', l.id, 'asiento_id', v_asto, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 4) Lecturas
-- ---------------------------------------------------------------------
-- Para el dueño y el admin (comisiones.ver). La base "ganancia" deja ver el
-- costo: solo con inventario.costos.
CREATE VIEW public.v_comision AS
  SELECT m.empresa_id, m.id AS movimiento_id, m.vendedor_id, public.nombre_usuario(m.empresa_id, m.vendedor_id) AS vendedor,
         m.venta_id, v.numero_documento, m.tipo, m.fecha_contable, m.base_tipo,
         CASE WHEN m.base_tipo = 'precio' OR x.costos THEN m.base_centavos END AS base_centavos,
         m.porcentaje, m.monto_centavos,
         (SELECT l.id FROM public.comision_liquidacion_detalle dd JOIN public.comision_liquidacion l ON l.id = dd.liquidacion_id
           WHERE dd.movimiento_id = m.id AND l.anulada_en IS NULL) AS liquidacion_id
  FROM public.comision_movimiento m
  JOIN public.venta v ON v.id = m.venta_id
  CROSS JOIN LATERAL (SELECT m.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))) AS costos) x
  WHERE m.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('comisiones.ver')));

-- Resumen por vendedor: devengado, pagado y por pagar (negativo = a descontar).
CREATE VIEW public.v_comision_vendedor AS
  SELECT u.empresa_id, u.vendedor_id, public.nombre_usuario(u.empresa_id, u.vendedor_id) AS vendedor,
         coalesce((SELECT sum(m.monto_centavos) FROM public.comision_movimiento m WHERE m.empresa_id = u.empresa_id AND m.vendedor_id = u.vendedor_id), 0)::bigint AS devengado_centavos,
         coalesce((SELECT sum(l.monto_centavos) FROM public.comision_liquidacion l WHERE l.empresa_id = u.empresa_id AND l.vendedor_id = u.vendedor_id
                    AND l.anulada_en IS NULL), 0)::bigint AS pagado_centavos,
         (coalesce((SELECT sum(m.monto_centavos) FROM public.comision_movimiento m WHERE m.empresa_id = u.empresa_id AND m.vendedor_id = u.vendedor_id), 0)
          - coalesce((SELECT sum(l.monto_centavos) FROM public.comision_liquidacion l WHERE l.empresa_id = u.empresa_id AND l.vendedor_id = u.vendedor_id
                       AND l.anulada_en IS NULL), 0))::bigint AS por_pagar_centavos
  FROM (SELECT DISTINCT m.empresa_id, m.vendedor_id FROM public.comision_movimiento m) u
  WHERE u.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('comisiones.ver')));

-- Para el vendedor: SOLO sus comisiones (monto y %, sin base ni costos).
CREATE VIEW public.v_mis_comisiones AS
  SELECT m.empresa_id, m.id AS movimiento_id, m.venta_id, v.numero_documento, v.cliente_nombre, m.tipo, m.fecha_contable,
         m.porcentaje, m.monto_centavos,
         EXISTS (SELECT 1 FROM public.comision_liquidacion_detalle dd JOIN public.comision_liquidacion l ON l.id = dd.liquidacion_id
                  WHERE dd.movimiento_id = m.id AND l.anulada_en IS NULL) AS pagada
  FROM public.comision_movimiento m
  JOIN public.venta v ON v.id = m.venta_id
  WHERE m.vendedor_id = (SELECT auth.uid()) AND m.empresa_id IN (SELECT public.mis_empresas());

GRANT SELECT ON public.v_comision, public.v_comision_vendedor, public.v_mis_comisiones TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5) id_operacion, módulo apagado y seguridad
-- ---------------------------------------------------------------------
INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('comision_liquidacion', 'id_operacion',           'pago_comisiones',           40),
  ('comision_liquidacion', 'anulacion_id_operacion', 'anulacion_pago_comisiones', 41);
INSERT INTO interno.modulo_apagado_permite (modulo, funcion, motivo) VALUES
  ('comisiones', 'public.anular_pago_comisiones', 'Corregir un pago de comisiones mal registrado.');

REVOKE EXECUTE ON FUNCTION
  interno.porcentaje_comision(uuid, uuid, date),
  interno.base_comision(uuid, text),
  interno.comision_sin_pagar(uuid, uuid, date),
  interno.total_comisiones_por_pagar(uuid)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.configurar_comisiones(uuid, jsonb, text),
  public.fijar_porcentaje_comision(uuid, uuid, numeric, date, text),
  public.pagar_comisiones(uuid, jsonb, uuid),
  public.anular_pago_comisiones(uuid, text, uuid, date)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.configurar_comisiones(uuid, jsonb, text),
  public.fijar_porcentaje_comision(uuid, uuid, numeric, date, text),
  public.pagar_comisiones(uuid, jsonb, uuid),
  public.anular_pago_comisiones(uuid, text, uuid, date)
TO authenticated;
