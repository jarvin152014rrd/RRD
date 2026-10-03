-- =====================================================================
-- 029_cotizaciones_lecturas.sql  -  Núcleo 0.7.0 (etapa 2b-2a)
--
--   cotizacion   no mueve inventario ni dinero ni consume número fiscal;
--                tiene vigencia (empresa.cotizacion_dias_vigencia, defecto 15
--                días). convertir_cotizacion_a_venta la vuelve venta:
--                  cotizacion_precios = 'respetar' (defecto) y vigente ->
--                  se cobran los precios y descuentos COTIZADOS;
--                  'recalcular', o cotización vencida -> precios, impuestos y
--                  promociones del día de la venta.
--                El vendedor cotiza y el cajero la cobra (la venta queda a
--                nombre del vendedor de la cotización).
--   Lecturas: v_venta, v_venta_linea, v_venta_pago (vistas del sistema: cada
--   quien ve sus ventas; con ventas.ver todas; costos solo con
--   inventario.costos), ventas por día / vendedor / caja, CxC por factura y
--   por cliente con antigüedad, documento_venta() para imprimir y
--   seguir_venta() (venta -> forma de pago -> cuenta de dinero -> depósito).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Cotizaciones
-- ---------------------------------------------------------------------
CREATE TABLE public.cotizacion (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                uuid NOT NULL REFERENCES public.empresa(id),
  numero                    bigint NOT NULL,
  fecha                     date NOT NULL,
  vigente_hasta             date NOT NULL,
  cliente_id                uuid,
  cliente_nombre            text NOT NULL,
  vendedor_id               uuid NOT NULL,
  entrada                   jsonb NOT NULL,        -- {"lineas": [...], "descuento_factura": {...}} tal como se pidió
  calculo                   jsonb NOT NULL,        -- líneas y totales calculados (precios cotizados)
  subtotal_centavos         bigint NOT NULL,
  descuento_centavos        bigint NOT NULL,
  impuesto_centavos         bigint NOT NULL,
  total_centavos            bigint NOT NULL CHECK (total_centavos > 0),
  estado                    text NOT NULL DEFAULT 'vigente' CHECK (estado IN ('vigente', 'convertida', 'anulada')),
  venta_id                  uuid,
  convertida_en             timestamptz,
  conversion_id_operacion   uuid,
  nota                      text,
  id_operacion              uuid NOT NULL,
  creado_por                uuid,
  registrado_en             timestamptz NOT NULL DEFAULT now(),
  anulada_en                timestamptz,
  anulada_por               uuid,
  motivo_anulacion          text,
  anulacion_id_operacion    uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, cliente_id) REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, venta_id)   REFERENCES public.venta(empresa_id, id),
  CHECK (vigente_hasta >= fecha),
  CHECK (total_centavos = subtotal_centavos - descuento_centavos + impuesto_centavos),
  CHECK ((estado = 'convertida') = (venta_id IS NOT NULL)),
  CHECK ((estado = 'anulada') = (anulada_en IS NOT NULL))
);
CREATE INDEX cotizacion_empresa_fecha ON public.cotizacion (empresa_id, fecha);
ALTER TABLE public.venta ADD CONSTRAINT venta_cotizacion_fk FOREIGN KEY (empresa_id, cotizacion_id) REFERENCES public.cotizacion(empresa_id, id);

-- La cotización no se edita: se convierte o se anula una vez. Si su venta
-- quedó rechazada o cancelada, se puede convertir otra vez.
CREATE FUNCTION interno.proteger_cotizacion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_conv constant text[] := ARRAY['estado', 'venta_id', 'convertida_en', 'conversion_id_operacion'];
  c_anul constant text[] := ARRAY['estado', 'anulada_en', 'anulada_por', 'motivo_anulacion', 'anulacion_id_operacion'];
BEGIN
  IF NEW.estado = 'convertida' AND (to_jsonb(NEW) - c_conv) = (to_jsonb(OLD) - c_conv)
     AND (OLD.estado = 'vigente'
          OR (OLD.estado = 'convertida' AND (SELECT v.estado FROM public.venta v WHERE v.id = OLD.venta_id) IN ('rechazada', 'cancelada'))) THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'vigente' AND NEW.estado = 'anulada' AND (to_jsonb(NEW) - c_anul) = (to_jsonb(OLD) - c_anul) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una cotización no se edita; se convierte en venta o se anula una vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.cotizacion FOR EACH ROW EXECUTE FUNCTION interno.proteger_cotizacion();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.cotizacion FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.cotizacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las cotizaciones no se borran: se anulan.');

CREATE FUNCTION interno.cotizacion_respuesta(c public.cotizacion, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('cotizacion_id', c.id, 'numero', c.numero, 'estado', c.estado,
    'fecha', to_char(c.fecha, 'YYYY-MM-DD'), 'vigente_hasta', to_char(c.vigente_hasta, 'YYYY-MM-DD'),
    'cliente', c.cliente_nombre, 'subtotal_centavos', c.subtotal_centavos, 'descuento_centavos', c.descuento_centavos,
    'impuesto_centavos', c.impuesto_centavos, 'total_centavos', c.total_centavos, 'venta_id', c.venta_id, 'duplicado', p_duplicado)
$$;

-- crear_cotizacion(empresa, datos, id_operacion)   ventas.cotizar
-- datos = {"lineas":[...como en la venta...], "descuento_factura":{...}, "cliente_id":"...",
--          "fecha":"2026-01-15", "vigente_hasta":"2026-01-30" (defecto: fecha + días de la empresa), "nota":"..."}
CREATE FUNCTION public.crear_cotizacion(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c       public.cotizacion;
  e       public.empresa;
  v_cli   public.tercero;
  v_fecha date;
  v_hasta date;
  v_calc  jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.cotizar', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'cotizacion');
  SELECT * INTO c FROM public.cotizacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF c.id IS NOT NULL THEN
    RETURN interno.cotizacion_respuesta(c, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['lineas', 'descuento_factura', 'cliente_id', 'fecha', 'vigente_hasta', 'nota']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  v_hasta := coalesce(interno.json_fecha(p_datos->'vigente_hasta', 'vigente_hasta'), v_fecha + e.cotizacion_dias_vigencia);
  IF v_hasta < v_fecha OR v_hasta > v_fecha + 365 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la vigencia va desde la fecha de la cotización hasta un año después.';
  END IF;
  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    SELECT * INTO v_cli FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_datos->'cliente_id', 'cliente_id') AND t.empresa_id = p_empresa_id;
    IF v_cli.id IS NULL OR NOT v_cli.es_cliente OR NOT v_cli.activo THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente no existe, no está marcado como cliente o está desactivado.';
    END IF;
  END IF;
  v_calc := interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura');
  IF (v_calc->>'total_centavos')::bigint <= 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el total de la cotización debe ser mayor que cero.';
  END IF;
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'cotizacion');
  SELECT * INTO c FROM public.cotizacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF c.id IS NOT NULL THEN
    RETURN interno.cotizacion_respuesta(c, true);
  END IF;
  INSERT INTO public.cotizacion (empresa_id, numero, fecha, vigente_hasta, cliente_id, cliente_nombre, vendedor_id, entrada, calculo,
    subtotal_centavos, descuento_centavos, impuesto_centavos, total_centavos, nota, id_operacion, creado_por)
  VALUES (p_empresa_id, interno.siguiente_numero(p_empresa_id, 'cotizacion'), v_fecha, v_hasta, v_cli.id,
    coalesce(v_cli.nombre, 'Consumidor final'), auth.uid(),
    jsonb_build_object('lineas', p_datos->'lineas', 'descuento_factura', p_datos->'descuento_factura'), v_calc,
    (v_calc->>'subtotal_centavos')::bigint, (v_calc->>'descuento_centavos')::bigint, (v_calc->>'impuesto_centavos')::bigint,
    (v_calc->>'total_centavos')::bigint, interno.json_texto(p_datos->'nota', 'nota', 500), p_id_operacion, auth.uid())
  RETURNING * INTO c;
  RETURN interno.cotizacion_respuesta(c, false);
END $$;

-- anular_cotizacion(cotizacion, motivo, id_operacion)   ventas.cotizar
CREATE FUNCTION public.anular_cotizacion(p_cotizacion_id uuid, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.cotizacion;
BEGIN
  SELECT * INTO c FROM public.cotizacion WHERE id = p_cotizacion_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la cotización no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, 'ventas.cotizar', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(c.empresa_id, p_id_operacion, 'anulacion_cotizacion');
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cotizacion_respuesta(c, true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se anula la cotización (mínimo 5 letras).';
  END IF;
  PERFORM interno.reservar_operacion(c.empresa_id, p_id_operacion, 'anulacion_cotizacion');
  SELECT * INTO c FROM public.cotizacion WHERE id = p_cotizacion_id FOR UPDATE;
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cotizacion_respuesta(c, true);
  END IF;
  IF c.estado <> 'vigente' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la cotización #% ya está %.', c.numero, c.estado;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cotizacion SET estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo),
         anulacion_id_operacion = p_id_operacion
   WHERE id = c.id RETURNING * INTO c;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.cotizacion_respuesta(c, false);
END $$;

-- convertir_cotizacion_a_venta(cotizacion, datos, id_operacion)   ventas.vender (+ ventas.cobrar si entra dinero)
-- datos = como en registrar_venta, SIN "lineas", "descuento_factura" ni "vendedor_id" (salen
-- de la cotización): {"pagos":[...], "caja_id", "bodega_id", "tipo_documento", "fecha",
-- "cliente_id" (solo si la cotización no tenía), "nota", "equipo"}.
CREATE FUNCTION public.convertir_cotizacion_a_venta(p_cotizacion_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c        public.cotizacion;
  v        public.venta;
  e        public.empresa;
  v_datos  jsonb;
  v_calc   jsonb;
  v_resp   boolean;
  r        jsonb;
  l        jsonb;
BEGIN
  SELECT * INTO c FROM public.cotizacion WHERE id = p_cotizacion_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la cotización no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, 'ventas.vender', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(c.empresa_id, p_id_operacion, 'venta');
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = c.empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.ocultar_costos(c.empresa_id, interno.venta_respuesta(v, true), ARRAY['costo_centavos']);
  END IF;
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  IF p_datos ?| ARRAY['lineas', 'descuento_factura', 'vendedor_id'] THEN
    RAISE EXCEPTION 'DATO_INVALIDO: las líneas, el descuento y el vendedor salen de la cotización.';
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = c.empresa_id;

  PERFORM interno.reservar_operacion(c.empresa_id, p_id_operacion, 'venta');
  SELECT * INTO c FROM public.cotizacion WHERE id = p_cotizacion_id FOR UPDATE;
  IF NOT (c.estado = 'vigente' OR (c.estado = 'convertida'
          AND (SELECT x.estado FROM public.venta x WHERE x.id = c.venta_id) IN ('rechazada', 'cancelada'))) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la cotización #% ya está % (no se convierte dos veces).', c.numero, c.estado;
  END IF;
  IF c.cliente_id IS NOT NULL AND coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb
     AND interno.json_uuid(p_datos->'cliente_id', 'cliente_id') <> c.cliente_id THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cotización es de otro cliente; haga una venta nueva.';
  END IF;

  -- ¿Precios cotizados o del día? (decisión documentada en ventas.md)
  v_resp := e.cotizacion_precios = 'respetar' AND public.hoy_local(c.empresa_id) <= c.vigente_hasta;
  IF v_resp THEN
    v_calc := c.calculo;
    FOR l IN SELECT * FROM jsonb_array_elements(c.calculo->'lineas') LOOP
      PERFORM interno.producto_de(c.empresa_id, l->'producto_id', (l->>'linea')::integer, true);
    END LOOP;
  END IF;
  v_datos := p_datos || jsonb_build_object('lineas', c.entrada->'lineas', 'descuento_factura', c.entrada->'descuento_factura',
                                           'vendedor_id', c.vendedor_id)
             || CASE WHEN c.cliente_id IS NOT NULL THEN jsonb_build_object('cliente_id', c.cliente_id) ELSE '{}'::jsonb END;
  r := interno.registrar_venta_base(c.empresa_id, v_datos, p_id_operacion, c.id, v_calc);
  UPDATE public.cotizacion SET estado = 'convertida', venta_id = (r->>'venta_id')::uuid, convertida_en = now(),
         conversion_id_operacion = p_id_operacion
   WHERE id = c.id;
  RETURN interno.ocultar_costos(c.empresa_id, r || jsonb_build_object('cotizacion_id', c.id, 'precios', CASE WHEN v_resp THEN 'cotizados' ELSE 'del_dia' END),
                                ARRAY['costo_centavos']);
END $$;

-- ---------------------------------------------------------------------
-- 2) id_operacion por tipo (reemplaza la de 028) y adjuntos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.tipo_operacion_2b(p_empresa_id uuid, p_id uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  SELECT 'dinero_' || x.tipo INTO v FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN v;
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.confirmacion_id_operacion = p_id) THEN
    RETURN 'confirmacion_deposito';
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_operacion_dinero';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.apertura_id_operacion = p_id) THEN
    RETURN 'abrir_turno';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cierre_id_operacion = p_id) THEN
    RETURN 'cerrar_turno';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.resolucion_id_operacion = p_id) THEN
    RETURN 'resolver_diferencia';
  END IF;
  IF EXISTS (SELECT 1 FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'gasto';
  END IF;
  IF EXISTS (SELECT 1 FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_gasto';
  END IF;
  IF EXISTS (SELECT 1 FROM public.aprobacion x WHERE x.empresa_id = p_empresa_id
               AND ((x.resolucion_id_operacion = p_id AND x.estado IN ('aprobada', 'rechazada')) OR x.primera_id_operacion = p_id)) THEN
    RETURN 'resolver_aprobacion';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.cancelacion_id_operacion = p_id) THEN
    RETURN 'cancelacion_venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta_anulacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'solicitar_anulacion_venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta_pago x WHERE x.empresa_id = p_empresa_id AND x.confirmacion_id_operacion = p_id) THEN
    RETURN 'confirmacion_transferencia';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cotizacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'cotizacion';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cotizacion x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_cotizacion';
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION interno.empresa_de_documento(p_tipo text, p_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN CASE p_tipo
    WHEN 'operacion_dinero' THEN (SELECT x.empresa_id FROM public.operacion_dinero x WHERE x.id = p_id)
    WHEN 'turno_caja'       THEN (SELECT x.empresa_id FROM public.turno_caja x WHERE x.id = p_id)
    WHEN 'gasto'            THEN (SELECT x.empresa_id FROM public.gasto x WHERE x.id = p_id)
    WHEN 'compra'           THEN (SELECT x.empresa_id FROM public.compra x WHERE x.id = p_id)
    WHEN 'pago_proveedor'   THEN (SELECT x.empresa_id FROM public.pago_proveedor x WHERE x.id = p_id)
    WHEN 'cxp_saldo_inicial' THEN (SELECT x.empresa_id FROM public.cxp_saldo_inicial x WHERE x.id = p_id)
    WHEN 'inventario_documento' THEN (SELECT x.empresa_id FROM public.inventario_documento x WHERE x.id = p_id)
    WHEN 'venta'            THEN (SELECT x.empresa_id FROM public.venta x WHERE x.id = p_id)
    WHEN 'venta_pago'       THEN (SELECT x.empresa_id FROM public.venta_pago x WHERE x.id = p_id)
    WHEN 'cotizacion'       THEN (SELECT x.empresa_id FROM public.cotizacion x WHERE x.id = p_id)
  END;
END $$;

-- ---------------------------------------------------------------------
-- 3) Vistas de ventas (del sistema: filtran por permiso UNA vez por consulta)
--    Sin ventas.ver cada quien ve las ventas que registró o que son suyas
--    como vendedor. Costo y utilidad solo con ventas.ver + inventario.costos.
-- ---------------------------------------------------------------------
CREATE VIEW public.v_venta AS
  SELECT v.empresa_id, v.id AS venta_id, v.numero, v.estado, v.tipo_documento, v.numero_documento, v.regimen_fiscal,
         v.datos_fiscales, v.fecha_contable, v.sucursal_id, v.caja_id, c.nombre AS caja, v.bodega_id,
         v.cliente_id, v.cliente_nombre, v.cliente_rtn, v.vendedor_id, public.nombre_usuario(v.empresa_id, v.vendedor_id) AS vendedor,
         v.creado_por, public.nombre_usuario(v.empresa_id, v.creado_por) AS registrado_por, v.cotizacion_id,
         v.condicion, v.credito_centavos, v.vence_el, v.subtotal_centavos, v.descuento_centavos, v.descuento_promocion_centavos,
         v.descuento_manual_centavos, v.descuento_manual_porcentaje, v.gravado_centavos, v.exento_centavos, v.exonerado_centavos,
         v.impuesto_centavos, v.desglose_impuestos, v.total_centavos,
         CASE WHEN x.costos THEN v.costo_centavos END AS costo_centavos,
         CASE WHEN x.costos AND v.costo_centavos IS NOT NULL
              THEN v.subtotal_centavos - v.descuento_centavos - v.costo_centavos
                   - coalesce((SELECT sum(l.costo_estimado_centavos) FROM public.venta_linea l WHERE l.venta_id = v.id), 0) END
           AS utilidad_bruta_centavos,
         v.requiere_aprobacion, v.aprobacion_id, v.asiento_id, v.emitida_en, v.registrado_en,
         v.motivo_cancelacion, v.motivo_anulacion, v.fecha_anulacion
  FROM public.venta v
  JOIN public.caja c ON c.id = v.caja_id
  CROSS JOIN LATERAL (SELECT v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
                             AND v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))) AS costos) x
  WHERE v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
     OR (v.empresa_id IN (SELECT public.mis_empresas()) AND (v.creado_por = (SELECT auth.uid()) OR v.vendedor_id = (SELECT auth.uid())));

CREATE VIEW public.v_venta_linea AS
  SELECT l.empresa_id, l.venta_id, v.numero_documento, v.estado, v.fecha_contable, l.linea, l.producto_id, p.codigo,
         l.descripcion, p.tipo, l.es_servicio, l.cantidad, l.precio_unitario_centavos, l.precio_incluye_isv, l.tipo_impuesto,
         l.impuesto_porcentaje, l.impuesto_clase, l.promocion_id, l.descuento_linea_porcentaje, l.bruto_centavos,
         l.descuento_promocion_precio_centavos, l.descuento_linea_centavos, l.descuento_factura_centavos, l.neto_centavos,
         l.subtotal_centavos, l.descuento_centavos, l.base_centavos, l.impuesto_centavos, l.total_centavos,
         CASE WHEN x.costos THEN l.costo_centavos END AS costo_centavos,
         CASE WHEN x.costos THEN l.costo_estimado_centavos END AS costo_estimado_centavos
  FROM public.venta_linea l
  JOIN public.venta v ON v.id = l.venta_id
  JOIN public.producto p ON p.id = l.producto_id
  CROSS JOIN LATERAL (SELECT l.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
                             AND l.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))) AS costos) x
  WHERE l.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
     OR (l.empresa_id IN (SELECT public.mis_empresas()) AND (v.creado_por = (SELECT auth.uid()) OR v.vendedor_id = (SELECT auth.uid())));

CREATE VIEW public.v_venta_pago AS
  SELECT g.empresa_id, g.id AS venta_pago_id, g.venta_id, v.numero_documento, v.estado, v.fecha_contable, g.linea, g.forma,
         g.monto_centavos, g.cuenta_dinero_id, d.nombre AS cuenta_dinero, d.tipo AS tipo_cuenta_dinero, g.turno_id, g.referencia,
         g.recibido_centavos, g.vuelto_centavos, g.estado_transferencia, g.banco_id, b.nombre AS banco,
         g.referencia_confirmacion, g.fecha_confirmacion
  FROM public.venta_pago g
  JOIN public.venta v ON v.id = g.venta_id
  LEFT JOIN public.cuenta_dinero d ON d.id = g.cuenta_dinero_id
  LEFT JOIN public.cuenta_dinero b ON b.id = g.banco_id
  WHERE g.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
     OR (g.empresa_id IN (SELECT public.mis_empresas()) AND (v.creado_por = (SELECT auth.uid()) OR v.vendedor_id = (SELECT auth.uid())));

-- Ventas emitidas (las anuladas no cuentan; se cuentan aparte) por día, vendedor y caja.
CREATE VIEW public.v_ventas_por_dia AS
  SELECT v.empresa_id, v.fecha_contable AS fecha,
         count(*) FILTER (WHERE v.estado = 'emitida') AS ventas,
         count(*) FILTER (WHERE v.estado = 'anulada') AS anuladas,
         coalesce(sum(v.subtotal_centavos) FILTER (WHERE v.estado = 'emitida'), 0)::bigint AS subtotal_centavos,
         coalesce(sum(v.descuento_centavos) FILTER (WHERE v.estado = 'emitida'), 0)::bigint AS descuento_centavos,
         coalesce(sum(v.impuesto_centavos) FILTER (WHERE v.estado = 'emitida'), 0)::bigint AS impuesto_centavos,
         coalesce(sum(v.total_centavos) FILTER (WHERE v.estado = 'emitida'), 0)::bigint AS total_centavos,
         coalesce(sum(v.total_centavos - v.credito_centavos) FILTER (WHERE v.estado = 'emitida'), 0)::bigint AS contado_centavos,
         coalesce(sum(v.credito_centavos) FILTER (WHERE v.estado = 'emitida'), 0)::bigint AS credito_centavos,
         CASE WHEN v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos')))
              THEN coalesce(sum(v.costo_centavos) FILTER (WHERE v.estado = 'emitida'), 0)::bigint END AS costo_centavos
  FROM public.venta v
  WHERE v.estado IN ('emitida', 'anulada') AND v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
  GROUP BY v.empresa_id, v.fecha_contable;

CREATE VIEW public.v_ventas_por_vendedor AS
  SELECT v.empresa_id, v.fecha_contable AS fecha, v.vendedor_id, public.nombre_usuario(v.empresa_id, v.vendedor_id) AS vendedor,
         count(*) AS ventas, sum(v.subtotal_centavos - v.descuento_centavos)::bigint AS venta_sin_impuesto_centavos,
         sum(v.impuesto_centavos)::bigint AS impuesto_centavos, sum(v.total_centavos)::bigint AS total_centavos,
         sum(v.credito_centavos)::bigint AS credito_centavos
  FROM public.venta v
  WHERE v.estado = 'emitida' AND v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
  GROUP BY v.empresa_id, v.fecha_contable, v.vendedor_id;

CREATE VIEW public.v_ventas_por_caja AS
  SELECT v.empresa_id, v.fecha_contable AS fecha, v.caja_id, c.nombre AS caja,
         count(*) AS ventas, sum(v.total_centavos)::bigint AS total_centavos,
         coalesce(sum(g.efectivo), 0)::bigint AS efectivo_centavos, coalesce(sum(g.tarjeta), 0)::bigint AS tarjeta_centavos,
         coalesce(sum(g.transferencia), 0)::bigint AS transferencia_centavos, sum(v.credito_centavos)::bigint AS credito_centavos
  FROM public.venta v
  JOIN public.caja c ON c.id = v.caja_id
  LEFT JOIN LATERAL (SELECT sum(x.monto_centavos) FILTER (WHERE x.forma = 'efectivo') AS efectivo,
                            sum(x.monto_centavos) FILTER (WHERE x.forma = 'tarjeta') AS tarjeta,
                            sum(x.monto_centavos) FILTER (WHERE x.forma = 'transferencia') AS transferencia
                       FROM public.venta_pago x WHERE x.venta_id = v.id) g ON true
  WHERE v.estado = 'emitida' AND v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
  GROUP BY v.empresa_id, v.fecha_contable, v.caja_id, c.nombre;

-- Cuentas por cobrar. GANCHO 2b-2b: "cobrado_centavos" será la suma de
-- cobros vigentes (hoy 0); los saldos iniciales de clientes entrarán aquí
-- con origen 'saldo_inicial'. La antigüedad se cuenta desde la fecha de la factura.
CREATE VIEW public.v_cxc_documento AS
  SELECT v.empresa_id, v.id AS venta_id, v.numero_documento, v.cliente_id, v.cliente_nombre, v.cliente_rtn,
         v.fecha_contable AS fecha_documento, v.vence_el, v.total_centavos, v.credito_centavos,
         0::bigint AS cobrado_centavos, v.credito_centavos AS saldo_centavos,
         public.hoy_local(v.empresa_id) - v.fecha_contable AS dias,
         greatest(public.hoy_local(v.empresa_id) - v.vence_el, 0) AS dias_vencido,
         'venta'::text AS origen, v.id AS documento_id
  FROM public.venta v
  WHERE v.estado = 'emitida' AND v.credito_centavos > 0
    AND v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')));

CREATE VIEW public.v_cxc_cliente AS
  SELECT d.empresa_id, d.cliente_id, t.nombre AS cliente, t.rtn, t.limite_credito_centavos, t.plazo_dias,
         count(*) AS documentos, sum(d.saldo_centavos)::bigint AS saldo_centavos,
         coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias <= 30), 0)::bigint AS de_0_a_30,
         coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 31 AND 60), 0)::bigint AS de_31_a_60,
         coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 61 AND 90), 0)::bigint AS de_61_a_90,
         coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias > 90), 0)::bigint AS mas_de_90,
         coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias_vencido > 0), 0)::bigint AS vencido_centavos,
         greatest(t.limite_credito_centavos - sum(d.saldo_centavos), 0)::bigint AS credito_disponible_centavos
  FROM public.v_cxc_documento d
  JOIN public.tercero t ON t.id = d.cliente_id
  WHERE d.saldo_centavos > 0
  GROUP BY d.empresa_id, d.cliente_id, t.nombre, t.rtn, t.limite_credito_centavos, t.plazo_dias;

CREATE VIEW public.v_cotizacion WITH (security_invoker = true) AS
  SELECT c.empresa_id, c.id AS cotizacion_id, c.numero, c.fecha, c.vigente_hasta,
         CASE WHEN c.estado = 'vigente' AND public.hoy_local(c.empresa_id) > c.vigente_hasta THEN 'vencida' ELSE c.estado END AS estado,
         c.cliente_id, c.cliente_nombre, c.vendedor_id, public.nombre_usuario(c.empresa_id, c.vendedor_id) AS vendedor,
         c.subtotal_centavos, c.descuento_centavos, c.impuesto_centavos, c.total_centavos, c.calculo->'lineas' AS lineas,
         c.venta_id, c.nota, c.registrado_en
  FROM public.cotizacion c;

-- ---------------------------------------------------------------------
-- 4) Documento para imprimir
-- ---------------------------------------------------------------------
-- Número en letras (español, mayúsculas), para el "total en letras".
CREATE FUNCTION interno.letras_centenas(n integer) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  u text[] := ARRAY['UNO','DOS','TRES','CUATRO','CINCO','SEIS','SIETE','OCHO','NUEVE','DIEZ','ONCE','DOCE','TRECE','CATORCE',
                    'QUINCE','DIECISÉIS','DIECISIETE','DIECIOCHO','DIECINUEVE','VEINTE','VEINTIUNO','VEINTIDÓS','VEINTITRÉS',
                    'VEINTICUATRO','VEINTICINCO','VEINTISÉIS','VEINTISIETE','VEINTIOCHO','VEINTINUEVE'];
  d text[] := ARRAY['','','TREINTA','CUARENTA','CINCUENTA','SESENTA','SETENTA','OCHENTA','NOVENTA'];
  c text[] := ARRAY['CIENTO','DOSCIENTOS','TRESCIENTOS','CUATROCIENTOS','QUINIENTOS','SEISCIENTOS','SETECIENTOS','OCHOCIENTOS','NOVECIENTOS'];
  v_c integer := n / 100;
  v_r integer := n % 100;
  t   text := '';
BEGIN
  IF n = 0 THEN RETURN ''; END IF;
  IF n = 100 THEN RETURN 'CIEN'; END IF;
  IF v_c > 0 THEN t := c[v_c]; END IF;
  IF v_r > 0 THEN
    t := t || CASE WHEN t <> '' THEN ' ' ELSE '' END
           || CASE WHEN v_r < 30 THEN u[v_r]
                   ELSE d[v_r / 10] || CASE WHEN v_r % 10 > 0 THEN ' Y ' || u[v_r % 10] ELSE '' END END;
  END IF;
  RETURN t;
END $$;

-- "UNO" -> "UN" (y "VEINTIUNO" -> "VEINTIÚN") delante de MIL, MILLONES y la moneda.
CREATE FUNCTION interno.apocope(t text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN t ~ 'VEINTIUNO$' THEN regexp_replace(t, 'VEINTIUNO$', 'VEINTIÚN')
              WHEN t ~ '(^| )UNO$' THEN regexp_replace(t, 'UNO$', 'UN') ELSE t END
$$;

CREATE FUNCTION interno.monto_en_letras(p_centavos bigint, p_moneda text DEFAULT 'HNL') RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  v_ent  bigint := abs(p_centavos) / 100;
  v_cen  integer := (abs(p_centavos) % 100)::integer;
  v_mm   integer := (v_ent / 1000000000)::integer;      -- miles de millones
  v_m    integer := ((v_ent / 1000000) % 1000)::integer;
  v_k    integer := ((v_ent / 1000) % 1000)::integer;
  v_u    integer := (v_ent % 1000)::integer;
  t      text := '';
  v_sing text;
  v_plur text;
  v_mill integer := (v_mm * 1000 + v_m);
BEGIN
  IF v_mill > 0 THEN
    t := CASE WHEN v_mill = 1 THEN 'UN MILLÓN'
              ELSE trim(CASE WHEN v_mm > 0 THEN CASE WHEN v_mm = 1 THEN 'MIL' ELSE interno.apocope(interno.letras_centenas(v_mm)) || ' MIL' END ELSE '' END
                        || ' ' || interno.apocope(interno.letras_centenas(v_m))) || ' MILLONES' END;
  END IF;
  IF v_k > 0 THEN
    t := t || ' ' || CASE WHEN v_k = 1 THEN 'MIL' ELSE interno.apocope(interno.letras_centenas(v_k)) || ' MIL' END;
  END IF;
  IF v_u > 0 THEN
    t := t || ' ' || interno.apocope(interno.letras_centenas(v_u));
  END IF;
  t := trim(t);
  IF t = '' THEN t := 'CERO'; END IF;
  IF v_k = 0 AND v_u = 0 AND v_mill > 0 THEN t := t || ' DE'; END IF;
  SELECT x.s, x.p INTO v_sing, v_plur FROM (VALUES ('HNL', 'LEMPIRA', 'LEMPIRAS'), ('USD', 'DÓLAR', 'DÓLARES'),
                                                   ('GTQ', 'QUETZAL', 'QUETZALES'), ('NIO', 'CÓRDOBA', 'CÓRDOBAS'),
                                                   ('CRC', 'COLÓN', 'COLONES'), ('MXN', 'PESO', 'PESOS')) x(m, s, p)
   WHERE x.m = p_moneda;
  RETURN t || ' ' || CASE WHEN v_ent = 1 THEN coalesce(v_sing, p_moneda) ELSE coalesce(v_plur, p_moneda) END
           || ' CON ' || lpad(v_cen::text, 2, '0') || '/100';
END $$;

-- Bloque fiscal del documento según el régimen (un régimen nuevo agrega su rama).
-- NOTA: las leyendas de la SAR (Acuerdo 481-2017) las debe validar un contador.
CREATE FUNCTION interno.bloque_fiscal(v public.venta) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ley text := (SELECT e.leyenda_factura FROM public.empresa e WHERE e.id = v.empresa_id);
BEGIN
  IF v.regimen_fiscal = 'fiscal_hn' THEN
    RETURN jsonb_build_object('regimen', 'fiscal_hn', 'pais', 'HN',
      'cai', v.datos_fiscales->>'cai',
      'rango_autorizado', (v.datos_fiscales->>'rango_desde') || ' al ' || (v.datos_fiscales->>'rango_hasta'),
      'rango_desde', v.datos_fiscales->>'rango_desde', 'rango_hasta', v.datos_fiscales->>'rango_hasta',
      'fecha_limite_emision', to_char((v.datos_fiscales->>'fecha_limite_emision')::date, 'DD/MM/YYYY'),
      'leyendas', to_jsonb(array_remove(ARRAY[
        'La factura es beneficio de todos. ¡Exíjala!',
        'Original: Cliente. Copia: Obligado tributario emisor.',
        CASE WHEN v.cliente_rtn IS NULL THEN 'Consumidor final' END,
        v_ley], NULL)));
  END IF;
  RETURN jsonb_build_object('regimen', NULL,
    'leyendas', to_jsonb(array_remove(ARRAY['Documento interno (ticket), sin valor fiscal.', v_ley], NULL)));
END $$;

-- documento_venta(venta): todo lo que lleva el documento impreso (factura o
-- ticket). Lo ve quien registró la venta, su vendedor o quien tiene
-- ventas.ver. Sin costos. Una venta anulada sale marcada "ANULADA".
CREATE FUNCTION public.documento_venta(p_venta_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v   public.venta;
  e   public.empresa;
  s   public.sucursal;
  cj  public.caja;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la venta no existe.';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT (public.tiene_permiso('ventas.ver', v.empresa_id)
       OR (public.mi_rol(v.empresa_id) IS NOT NULL AND auth.uid() IN (v.creado_por, v.vendedor_id))) THEN
    PERFORM interno.exigir_lectura(v.empresa_id, 'ventas.ver');
  ELSIF auth.uid() IS NULL THEN
    PERFORM interno.exigir_lectura(v.empresa_id, 'ventas.ver');
  END IF;
  IF v.numero_documento IS NULL THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la venta #% todavía no está emitida (está %); no tiene documento.', v.numero, v.estado;
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = v.empresa_id;
  SELECT * INTO s FROM public.sucursal x WHERE x.id = v.sucursal_id;
  SELECT * INTO cj FROM public.caja x WHERE x.id = v.caja_id;
  RETURN jsonb_build_object(
    'tipo', upper(v.tipo_documento), 'numero_documento', v.numero_documento, 'estado', v.estado,
    'anulada', v.estado = 'anulada', 'marca', CASE WHEN v.estado = 'anulada' THEN 'ANULADA' END,
    'fecha', to_char(v.fecha_contable, 'DD/MM/YYYY'), 'fecha_iso', to_char(v.fecha_contable, 'YYYY-MM-DD'),
    'emitida_en', public.iso(v.emitida_en),
    'emisor', jsonb_build_object('nombre', v.emisor_nombre, 'rtn', v.emisor_rtn, 'sucursal', s.codigo || ' ' || s.nombre,
                                 'caja', cj.nombre, 'punto_emision', s.codigo || '-' || cj.punto_emision),
    'cliente', jsonb_build_object('nombre', v.cliente_nombre, 'rtn', v.cliente_rtn),
    'vendedor', public.nombre_usuario(v.empresa_id, v.vendedor_id),
    'cajero', public.nombre_usuario(v.empresa_id, v.creado_por),
    'lineas', (SELECT jsonb_agg(jsonb_build_object('linea', l.linea, 'cantidad', l.cantidad, 'descripcion', l.descripcion,
                 'precio_unitario_centavos', l.precio_unitario_centavos, 'precio_incluye_impuesto', l.precio_incluye_isv,
                 'descuento_centavos', l.descuento_promocion_precio_centavos + l.descuento_linea_centavos + l.descuento_factura_centavos,
                 'impuesto', l.tipo_impuesto, 'base_centavos', l.base_centavos, 'impuesto_centavos', l.impuesto_centavos,
                 'total_centavos', l.total_centavos) ORDER BY l.linea)
                 FROM public.venta_linea l WHERE l.venta_id = v.id),
    'totales', jsonb_build_object('subtotal_centavos', v.subtotal_centavos, 'descuento_centavos', v.descuento_centavos,
                 'gravado_centavos', v.gravado_centavos, 'exento_centavos', v.exento_centavos, 'exonerado_centavos', v.exonerado_centavos,
                 'impuestos', v.desglose_impuestos, 'impuesto_centavos', v.impuesto_centavos, 'total_centavos', v.total_centavos,
                 'total_en_letras', interno.monto_en_letras(v.total_centavos, e.moneda), 'moneda', e.moneda),
    'pagos', (SELECT jsonb_agg(jsonb_build_object('forma', g.forma, 'monto_centavos', g.monto_centavos,
                 'recibido_centavos', g.recibido_centavos, 'vuelto_centavos', g.vuelto_centavos, 'referencia', g.referencia) ORDER BY g.linea)
                FROM public.venta_pago g WHERE g.venta_id = v.id),
    'condicion', v.condicion, 'credito_centavos', v.credito_centavos, 'vence_el', to_char(v.vence_el, 'DD/MM/YYYY'),
    'fiscal', interno.bloque_fiscal(v));
END $$;

-- ---------------------------------------------------------------------
-- 5) "Seguir una venta": venta -> forma de pago -> cuenta de dinero ->
--    turno / confirmación / depósito. Pide ventas.ver; el detalle de las
--    cuentas de dinero, además dinero.ver.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.seguir_venta(p_venta_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v       public.venta;
  g       public.venta_pago;
  v_din   boolean;
  v_pagos jsonb := '[]';
  v_p     jsonb;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la venta no existe.';
  END IF;
  PERFORM interno.exigir_lectura(v.empresa_id, 'ventas.ver');
  v_din := public.puede_leer(v.empresa_id, 'dinero.ver');
  FOR g IN SELECT * FROM public.venta_pago x WHERE x.venta_id = v.id ORDER BY x.linea LOOP
    v_p := jsonb_build_object('linea', g.linea, 'forma', g.forma, 'monto_centavos', g.monto_centavos, 'referencia', g.referencia);
    IF g.forma = 'credito' THEN
      v_p := v_p || jsonb_build_object('cuenta', 'Clientes (cuentas por cobrar)', 'vence_el', to_char(v.vence_el, 'YYYY-MM-DD'),
        'cobrado_centavos', interno.cobros_vigentes_venta(v.id),
        'saldo_centavos', CASE WHEN v.estado = 'emitida' THEN v.credito_centavos - interno.cobros_vigentes_venta(v.id) ELSE 0 END);
    ELSIF v_din THEN
      v_p := v_p || jsonb_build_object(
        'cuenta', (SELECT jsonb_build_object('cuenta_dinero_id', d.id, 'nombre', d.nombre, 'tipo', d.tipo)
                     FROM public.cuenta_dinero d WHERE d.id = g.cuenta_dinero_id),
        'movimientos', (SELECT coalesce(jsonb_agg(jsonb_build_object('fecha', to_char(m.fecha_contable, 'YYYY-MM-DD'),
                           'operacion', m.operacion, 'cuenta', d.nombre, 'monto_centavos', m.monto_centavos, 'turno_id', m.turno_id,
                           'turno_numero', t.numero, 'referencia', m.referencia) ORDER BY m.id), '[]')
                          FROM public.dinero_movimiento m JOIN public.cuenta_dinero d ON d.id = m.cuenta_dinero_id
                          LEFT JOIN public.turno_caja t ON t.id = m.turno_id
                         WHERE m.documento_id = v.id AND m.cuenta_dinero_id IN (g.cuenta_dinero_id, g.banco_id)));
      IF g.forma = 'efectivo' THEN
        v_p := v_p || jsonb_build_object(
          'turno', (SELECT jsonb_build_object('turno_id', t.id, 'numero', t.numero, 'estado', t.estado,
                       'cierre', to_char(t.fecha_cierre, 'YYYY-MM-DD'), 'diferencia_centavos', t.diferencia_centavos)
                      FROM public.turno_caja t WHERE t.id = g.turno_id),
          -- El efectivo se mezcla en la caja: estos son los depósitos que salieron de ESA caja desde la venta.
          'depositos_de_esa_caja_desde_la_venta', (SELECT coalesce(jsonb_agg(jsonb_build_object('operacion_id', o.id, 'numero', o.numero,
               'fecha', to_char(o.fecha_contable, 'YYYY-MM-DD'), 'monto_centavos', o.monto_centavos, 'estado', o.estado,
               'banco', (SELECT b.nombre FROM public.cuenta_dinero b WHERE b.id = o.destino_id), 'referencia', o.referencia)
               ORDER BY o.fecha_contable, o.numero), '[]')
             FROM public.operacion_dinero o
            WHERE o.origen_id = g.cuenta_dinero_id AND o.tipo = 'deposito' AND o.anulada_en IS NULL AND o.fecha_contable >= v.fecha_contable));
      ELSIF g.forma = 'transferencia' THEN
        v_p := v_p || jsonb_build_object('estado_transferencia', g.estado_transferencia,
          'confirmacion', CASE WHEN g.estado_transferencia = 'confirmada' THEN jsonb_build_object(
              'banco', (SELECT b.nombre FROM public.cuenta_dinero b WHERE b.id = g.banco_id),
              'referencia', g.referencia_confirmacion, 'fecha', to_char(g.fecha_confirmacion, 'YYYY-MM-DD')) END);
      ELSIF g.forma = 'tarjeta' THEN
        v_p := v_p || jsonb_build_object('liquidaciones_de_ese_pos_desde_la_venta', (SELECT coalesce(jsonb_agg(jsonb_build_object(
               'operacion_id', o.id, 'numero', o.numero, 'fecha', to_char(o.fecha_contable, 'YYYY-MM-DD'), 'monto_centavos', o.monto_centavos,
               'a', (SELECT b.nombre FROM public.cuenta_dinero b WHERE b.id = o.destino_id)) ORDER BY o.fecha_contable, o.numero), '[]')
             FROM public.operacion_dinero o
            WHERE o.origen_id = g.cuenta_dinero_id AND o.anulada_en IS NULL AND o.fecha_contable >= v.fecha_contable));
      END IF;
    END IF;
    v_pagos := v_pagos || v_p;
  END LOOP;
  RETURN jsonb_build_object('venta_id', v.id, 'numero', v.numero, 'numero_documento', v.numero_documento, 'estado', v.estado,
    'fecha', to_char(v.fecha_contable, 'YYYY-MM-DD'), 'cliente', v.cliente_nombre, 'total_centavos', v.total_centavos,
    'asiento_id', v.asiento_id, 'asiento_anulacion_id', v.asiento_anulacion_id, 'motivo_anulacion', v.motivo_anulacion,
    'pagos', v_pagos, 'detalle_dinero_visible', v_din);
END $$;

-- ---------------------------------------------------------------------
-- 6) Seguridad
-- ---------------------------------------------------------------------
ALTER TABLE public.cotizacion ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.cotizacion
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
GRANT SELECT ON public.cotizacion TO authenticated, service_role;
CREATE POLICY leer ON public.cotizacion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.cotizar'))));
GRANT SELECT ON public.v_venta, public.v_venta_linea, public.v_venta_pago, public.v_ventas_por_dia, public.v_ventas_por_vendedor,
  public.v_ventas_por_caja, public.v_cxc_documento, public.v_cxc_cliente, public.v_cotizacion TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  interno.proteger_cotizacion(),
  interno.cotizacion_respuesta(public.cotizacion, boolean),
  interno.letras_centenas(integer),
  interno.apocope(text),
  interno.monto_en_letras(bigint, text),
  interno.bloque_fiscal(public.venta)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.crear_cotizacion(uuid, jsonb, uuid),
  public.anular_cotizacion(uuid, text, uuid),
  public.convertir_cotizacion_a_venta(uuid, jsonb, uuid),
  public.documento_venta(uuid),
  public.seguir_venta(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_cotizacion(uuid, jsonb, uuid),
  public.anular_cotizacion(uuid, text, uuid),
  public.convertir_cotizacion_a_venta(uuid, jsonb, uuid)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.documento_venta(uuid), public.seguir_venta(uuid) TO authenticated, service_role;
