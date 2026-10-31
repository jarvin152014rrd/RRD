-- =====================================================================
-- 019_compras_correcciones.sql  -  Núcleo 0.4.0
--
--   * anular_pago_proveedor(pago, motivo, id_operacion, fecha?): contra-
--     asiento a la MISMA cuenta de dinero, en mes abierto, una sola vez;
--     la factura recupera su saldo. Con todos sus pagos anulados, la
--     compra ya se puede anular. (Patrón para los cobros de la etapa 2b:
--     ver docs/CONVENCIONES.md, "Anular un abono".)
--   * Saldos iniciales de proveedores (facturas pendientes al empezar):
--     registrar_saldo_inicial_cxp / anular_saldo_inicial_cxp. Asiento
--     Dr Saldos de apertura / Cr Proveedores. Salen en las vistas de CxP y
--     antigüedad, y se pagan con pagar_proveedor como una compra.
--   * Activar inventario o compras con saldo previo en 1.1.03.01 o
--     2.1.01.01 que el módulo no explica: se rechaza (MODULO_CON_SALDO) y
--     el mensaje dice cómo hacer la carga inicial.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('MODULO_CON_SALDO', 'No se puede activar el módulo: la cuenta que controla ya tiene saldo en los libros.',
   'Pase ese saldo a "Saldos de apertura" con un asiento, active el módulo y cargue el detalle (existencias o facturas pendientes) con la carga inicial. Ver docs/PROCEDIMIENTOS.md (P-07).');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('compras.saldo_inicial', 'Cargar y anular saldos iniciales de proveedores (facturas pendientes al empezar)', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES ('dueno', 'compras.saldo_inicial');
SELECT interno.repartir_permisos(ARRAY['compras.saldo_inicial'], 'Núcleo 0.4.0: saldos iniciales de proveedores');

-- ---------------------------------------------------------------------
-- 1) Saldos iniciales de proveedores
-- ---------------------------------------------------------------------
CREATE TABLE public.cxp_saldo_inicial (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,                  -- correlativo propio por empresa
  proveedor_id             uuid NOT NULL,
  numero_documento         text NOT NULL CHECK (length(trim(numero_documento)) > 0),
  fecha_documento          date NOT NULL,                    -- fecha de la factura (puede ser antes del inicio)
  fecha_contable           date NOT NULL,                    -- fecha del asiento de apertura
  fecha_vencimiento        date NOT NULL,
  monto_centavos           bigint NOT NULL CHECK (monto_centavos > 0 AND monto_centavos <= 9007199254740991),
  sucursal_id              uuid NOT NULL,
  notas                    text,
  asiento_id               uuid NOT NULL,
  id_operacion             uuid NOT NULL,
  creado_por               uuid,
  registrado_en            timestamptz NOT NULL DEFAULT now(),
  anulada_en               timestamptz,
  anulada_por              uuid,
  motivo_anulacion         text,
  asiento_anulacion_id     uuid,
  anulacion_id_operacion   uuid,
  fecha_anulacion          date,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, proveedor_id)         REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id)          REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK (fecha_vencimiento >= fecha_documento),
  CHECK (fecha_documento <= fecha_contable),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL)),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL))
);
CREATE UNIQUE INDEX cxp_saldo_inicial_factura ON public.cxp_saldo_inicial (empresa_id, proveedor_id, upper(numero_documento))
  WHERE anulada_en IS NULL;
CREATE INDEX cxp_saldo_inicial_proveedor ON public.cxp_saldo_inicial (empresa_id, proveedor_id, fecha_documento);
CREATE INDEX cxp_saldo_inicial_anulacion ON public.cxp_saldo_inicial (empresa_id, anulacion_id_operacion)
  WHERE anulacion_id_operacion IS NOT NULL;

-- No se edita; solo se anula una vez (igual que la compra).
CREATE FUNCTION interno.proteger_saldo_inicial_cxp() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.anulada_en IS NOT NULL
     OR to_jsonb(NEW) - 'anulada_en' - 'anulada_por' - 'motivo_anulacion' - 'asiento_anulacion_id'
                      - 'anulacion_id_operacion' - 'fecha_anulacion'
        IS DISTINCT FROM
        to_jsonb(OLD) - 'anulada_en' - 'anulada_por' - 'motivo_anulacion' - 'asiento_anulacion_id'
                      - 'anulacion_id_operacion' - 'fecha_anulacion' THEN
    RAISE EXCEPTION 'PROHIBIDO: un saldo inicial no se edita; solo se anula una vez.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.cxp_saldo_inicial
  FOR EACH ROW EXECUTE FUNCTION interno.proteger_saldo_inicial_cxp();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.cxp_saldo_inicial
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los saldos iniciales no se borran: se anulan.');
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.cxp_saldo_inicial
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();

-- ---------------------------------------------------------------------
-- 2) Pagos: también a saldos iniciales; anulación en tabla aparte
-- ---------------------------------------------------------------------
ALTER TABLE public.pago_proveedor
  ALTER COLUMN compra_id DROP NOT NULL,
  ADD COLUMN saldo_inicial_id uuid,
  ADD CONSTRAINT pago_proveedor_saldo_inicial_fk FOREIGN KEY (empresa_id, saldo_inicial_id)
    REFERENCES public.cxp_saldo_inicial(empresa_id, id),
  ADD CONSTRAINT pago_proveedor_un_documento CHECK ((compra_id IS NULL) <> (saldo_inicial_id IS NULL));
CREATE INDEX pago_proveedor_saldo_inicial ON public.pago_proveedor (saldo_inicial_id) WHERE saldo_inicial_id IS NOT NULL;

CREATE TABLE public.pago_proveedor_anulacion (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  pago_id         uuid NOT NULL UNIQUE,                  -- un pago se anula una sola vez
  fecha_contable  date NOT NULL,
  motivo          text NOT NULL CHECK (length(trim(motivo)) >= 5),
  asiento_id      uuid NOT NULL,
  id_operacion    uuid NOT NULL,
  anulado_por     uuid,
  registrado_en   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (pago_id) REFERENCES public.pago_proveedor(id),
  FOREIGN KEY (empresa_id, asiento_id) REFERENCES public.asiento(empresa_id, id)
);
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.pago_proveedor_anulacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Una anulación no se edita ni se borra.');
CREATE TRIGGER auditar AFTER INSERT ON public.pago_proveedor_anulacion
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();

-- Seguridad de las tablas nuevas (piden compras.ver).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cxp_saldo_inicial', 'pago_proveedor_anulacion'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', t, 'compras.ver');
  END LOOP;
END $$;

-- Lo pagado (sin pagos anulados) de una compra o saldo inicial.
CREATE FUNCTION interno.pagado_documento_cxp(p_documento_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(p.monto_centavos), 0)::bigint
    FROM public.pago_proveedor p
   WHERE (p.compra_id = p_documento_id OR p.saldo_inicial_id = p_documento_id)
     AND NOT EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion a WHERE a.pago_id = p.id)
$$;

-- Total por pagar de la empresa según el módulo (debe = saldo de 2.1.01.01).
CREATE FUNCTION interno.total_cxp(p_empresa_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ( coalesce((SELECT sum(c.total_centavos) FROM public.compra c
                      WHERE c.empresa_id = p_empresa_id AND c.condicion = 'credito' AND c.anulada_en IS NULL), 0)
         + coalesce((SELECT sum(s.monto_centavos) FROM public.cxp_saldo_inicial s
                      WHERE s.empresa_id = p_empresa_id AND s.anulada_en IS NULL), 0)
         - coalesce((SELECT sum(p.monto_centavos) FROM public.pago_proveedor p
                      WHERE p.empresa_id = p_empresa_id
                        AND NOT EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion a WHERE a.pago_id = p.id)), 0)
         )::bigint
$$;

-- Saldo de una cuenta (por código) en los libros, positivo según su naturaleza.
CREATE FUNCTION interno.saldo_libros(p_empresa_id uuid, p_codigo text) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(CASE WHEN c.naturaleza = 'deudora' THEN l.debe_centavos - l.haber_centavos
                           ELSE l.haber_centavos - l.debe_centavos END), 0)::bigint
    FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
   WHERE l.empresa_id = p_empresa_id AND c.codigo = p_codigo
$$;

-- ---------------------------------------------------------------------
-- 3) RPC: registrar_saldo_inicial_cxp (permiso compras.saldo_inicial)
-- p_datos = {"proveedor_id":"...","numero_documento":"F-889","fecha_documento":"2025-11-20",
--            "fecha_vencimiento":"2026-01-20","monto_centavos":250000,
--            "fecha":"2026-01-01" (del asiento; si falta: inicio de la empresa), "notas":"..."}
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_saldo_inicial_cxp(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_s     public.cxp_saldo_inicial;
  v_prov  public.tercero;
  v_doc   text;
  v_fdoc  date;
  v_venc  date;
  v_fecha date;
  v_monto bigint;
  v_num   bigint;
  v_asto  uuid;
  v_suc   uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.saldo_inicial', 'compras');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'saldo_inicial_cxp');
  SELECT * INTO v_s FROM public.cxp_saldo_inicial WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_s.id IS NOT NULL THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'numero', v_s.numero, 'asiento_id', v_s.asiento_id,
                              'monto_centavos', v_s.monto_centavos, 'duplicado', true);
  END IF;

  PERFORM interno.exigir_claves(p_datos, ARRAY['proveedor_id', 'numero_documento', 'fecha_documento',
                                               'fecha_vencimiento', 'monto_centavos', 'fecha', 'notas']);
  SELECT * INTO v_prov FROM public.tercero t
   WHERE t.empresa_id = p_empresa_id AND t.id = interno.json_uuid(p_datos->'proveedor_id', 'proveedor_id');
  IF v_prov.id IS NULL OR NOT v_prov.es_proveedor OR NOT v_prov.activo THEN
    RAISE EXCEPTION 'TERCERO_INVALIDO: el proveedor no existe, no está marcado como proveedor o está desactivado.';
  END IF;
  v_doc := interno.json_texto(p_datos->'numero_documento', 'numero_documento', 50);
  IF v_doc IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el número de la factura del proveedor.';
  END IF;
  BEGIN
    v_fdoc := (p_datos->>'fecha_documento')::date;
    v_venc := (p_datos->>'fecha_vencimiento')::date;
    v_fecha := (p_datos->>'fecha')::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: las fechas deben ser AAAA-MM-DD.';
  END;
  IF v_fdoc IS NULL OR v_fdoc < '2000-01-01' THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique la fecha de la factura ("fecha_documento", AAAA-MM-DD).';
  END IF;
  v_fecha := coalesce(v_fecha, (SELECT e.fecha_inicio FROM public.empresa e WHERE e.id = p_empresa_id));
  v_venc  := coalesce(v_venc, v_fdoc + v_prov.plazo_dias);
  IF v_venc < v_fdoc THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el vencimiento no puede ser antes de la fecha de la factura.';
  END IF;
  IF v_fdoc > v_fecha THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la factura (%) no puede ser posterior a la fecha de apertura (%); si es nueva, regístrela como compra.',
      to_char(v_fdoc, 'DD/MM/YYYY'), to_char(v_fecha, 'DD/MM/YYYY');
  END IF;
  v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  IF v_monto = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el monto pendiente debe ser mayor que cero.';
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO v_s FROM public.cxp_saldo_inicial WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_s.id IS NOT NULL THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'numero', v_s.numero, 'asiento_id', v_s.asiento_id,
                              'monto_centavos', v_s.monto_centavos, 'duplicado', true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.cxp_saldo_inicial x WHERE x.empresa_id = p_empresa_id AND x.proveedor_id = v_prov.id
              AND upper(x.numero_documento) = upper(v_doc) AND x.anulada_en IS NULL)
     OR EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.proveedor_id = v_prov.id
              AND upper(x.numero_documento) = upper(v_doc) AND x.anulada_en IS NULL) THEN
    RAISE EXCEPTION 'YA_EXISTE: la factura % de este proveedor ya está registrada.', v_doc;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);

  SELECT s.id INTO v_suc FROM public.sucursal s WHERE s.empresa_id = p_empresa_id AND s.activa ORDER BY s.codigo LIMIT 1;
  v_num := interno.siguiente_numero(p_empresa_id, 'cxp_saldo_inicial');
  v_asto := interno.asiento_sistema(p_empresa_id, v_suc, v_fecha,
    'Saldo inicial #' || v_num || ' por pagar a ' || v_prov.nombre || ', factura ' || v_doc
      || ' del ' || to_char(v_fdoc, 'DD/MM/YYYY'),
    'saldo_inicial_cxp', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'apertura_cxp', 'debe', v_monto),
                      jsonb_build_object('uso', 'cxp', 'haber', v_monto)));

  INSERT INTO public.cxp_saldo_inicial (empresa_id, numero, proveedor_id, numero_documento, fecha_documento,
    fecha_contable, fecha_vencimiento, monto_centavos, sucursal_id, notas, asiento_id, id_operacion, creado_por)
  VALUES (p_empresa_id, v_num, v_prov.id, v_doc, v_fdoc, v_fecha, v_venc, v_monto, v_suc,
    interno.json_texto(p_datos->'notas', 'notas', 500), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO v_s;

  RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'numero', v_num, 'asiento_id', v_asto,
                            'monto_centavos', v_monto, 'duplicado', false);
END $$;

-- RPC: anular_saldo_inicial_cxp (solo si no tiene pagos vigentes).
CREATE FUNCTION public.anular_saldo_inicial_cxp(p_saldo_inicial_id uuid, p_motivo text, p_id_operacion uuid,
                                                p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_s     public.cxp_saldo_inicial;
  v_fecha date;
  v_cta   text;
  v_asto  uuid;
BEGIN
  SELECT * INTO v_s FROM public.cxp_saldo_inicial WHERE id = p_saldo_inicial_id;
  IF v_s.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el saldo inicial no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v_s.empresa_id, 'compras.saldo_inicial', 'compras');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v_s.empresa_id, p_id_operacion, 'anulacion_saldo_inicial_cxp');
  IF v_s.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'asiento_id', v_s.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(v_s.empresa_id), v_s.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v_s.empresa_id, v_fecha);
  IF v_fecha < v_s.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al saldo inicial (%).',
      to_char(v_s.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.bloquear_libros(v_s.empresa_id);
  SELECT * INTO v_s FROM public.cxp_saldo_inicial WHERE id = p_saldo_inicial_id FOR UPDATE;
  IF v_s.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'asiento_id', v_s.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF v_s.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el saldo inicial #% ya fue anulado.', v_s.numero;
  END IF;
  IF interno.pagado_documento_cxp(v_s.id) > 0 THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el saldo inicial #% tiene pagos; anule primero esos pagos.', v_s.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(v_s.empresa_id, v_fecha);

  -- Contra la misma cuenta de apertura que usó el original.
  SELECT c.codigo INTO v_cta FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
   WHERE l.asiento_id = v_s.asiento_id AND l.debe_centavos > 0 ORDER BY l.linea LIMIT 1;
  v_asto := interno.asiento_sistema(v_s.empresa_id, v_s.sucursal_id, v_fecha,
    'ANULACIÓN saldo inicial #' || v_s.numero || ' (factura ' || v_s.numero_documento || '): ' || trim(p_motivo),
    'anulacion_saldo_inicial_cxp', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'cxp', 'debe', v_s.monto_centavos),
                      jsonb_build_object('cuenta', v_cta, 'haber', v_s.monto_centavos)),
    v_s.asiento_id, trim(p_motivo));

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cxp_saldo_inicial
     SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo),
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion, fecha_anulacion = v_fecha
   WHERE id = v_s.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'asiento_id', v_asto, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 4) pagar_proveedor (reemplaza la de 016; misma firma). Cambios: paga una
--    compra al crédito O un saldo inicial (p_compra_id = documento_id de
--    v_cxp_documento); el saldo descuenta solo pagos NO anulados.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pagar_proveedor(p_empresa_id uuid, p_compra_id uuid, p_monto_centavos bigint,
                                       p_fecha date, p_forma_pago text, p_id_operacion uuid,
                                       p_referencia text DEFAULT NULL, p_cuenta_pago text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_pago   public.pago_proveedor;
  v_c      public.compra;
  v_s      public.cxp_saldo_inicial;
  v_total  bigint;
  v_fdoc   date;
  v_prov   uuid;
  v_texto  text;
  v_suc    uuid;
  v_saldo  bigint;
  v_num    bigint;
  v_asto   uuid;
  v_cta    public.cuenta;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.pagar', 'compras');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'pago_proveedor');
  SELECT * INTO v_pago FROM public.pago_proveedor WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_pago.id IS NOT NULL THEN
    RETURN jsonb_build_object('pago_id', v_pago.id, 'numero', v_pago.numero, 'asiento_id', v_pago.asiento_id, 'duplicado', true);
  END IF;
  IF p_monto_centavos IS NULL OR p_monto_centavos <= 0 OR p_monto_centavos > 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el monto del pago es un entero de centavos mayor que cero.';
  END IF;
  IF p_forma_pago IS NULL OR p_forma_pago NOT IN ('caja', 'banco') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago es "caja" o "banco".';
  END IF;
  v_cta := interno.cuenta_de_pago(p_empresa_id, p_forma_pago, p_cuenta_pago);
  PERFORM interno.exigir_fecha_contable(p_empresa_id, p_fecha);

  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO v_pago FROM public.pago_proveedor WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_pago.id IS NOT NULL THEN
    RETURN jsonb_build_object('pago_id', v_pago.id, 'numero', v_pago.numero, 'asiento_id', v_pago.asiento_id, 'duplicado', true);
  END IF;

  SELECT * INTO v_c FROM public.compra WHERE id = p_compra_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_c.id IS NOT NULL THEN
    IF v_c.condicion <> 'credito' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la compra #% fue de contado; no tiene saldo por pagar.', v_c.numero;
    END IF;
    IF v_c.anulada_en IS NOT NULL THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la compra #% está anulada.', v_c.numero;
    END IF;
    v_total := v_c.total_centavos; v_fdoc := v_c.fecha_contable; v_prov := v_c.proveedor_id;
    v_texto := 'compra #' || v_c.numero || ' (factura ' || v_c.numero_documento || ')';
    SELECT s.id INTO v_suc FROM public.sucursal s WHERE s.id = v_c.sucursal_id AND s.activa;
  ELSE
    SELECT * INTO v_s FROM public.cxp_saldo_inicial WHERE id = p_compra_id AND empresa_id = p_empresa_id FOR UPDATE;
    IF v_s.id IS NULL THEN
      RAISE EXCEPTION 'NO_EXISTE: la compra o factura por pagar no existe en esta empresa.';
    END IF;
    IF v_s.anulada_en IS NOT NULL THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el saldo inicial #% está anulado.', v_s.numero;
    END IF;
    v_total := v_s.monto_centavos; v_fdoc := v_s.fecha_contable; v_prov := v_s.proveedor_id;
    v_texto := 'saldo inicial #' || v_s.numero || ' (factura ' || v_s.numero_documento || ')';
    SELECT s.id INTO v_suc FROM public.sucursal s WHERE s.id = v_s.sucursal_id AND s.activa;
  END IF;
  IF p_fecha < v_fdoc THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el pago no puede tener fecha anterior a la compra o al saldo inicial.';
  END IF;
  v_saldo := v_total - interno.pagado_documento_cxp(p_compra_id);
  IF p_monto_centavos > v_saldo THEN
    RAISE EXCEPTION 'PAGO_EXCEDE_SALDO: el pago (% centavos) es mayor que el saldo de la % (% centavos).',
      p_monto_centavos, v_texto, v_saldo;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, p_fecha);

  v_num := interno.siguiente_numero(p_empresa_id, 'pago_proveedor');
  v_asto := interno.asiento_sistema(p_empresa_id, v_suc, p_fecha,
    'Pago #' || v_num || ' a proveedor, ' || v_texto || coalesce(' ref. ' || nullif(trim(p_referencia), ''), ''),
    'pago_proveedor', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'cxp', 'debe', p_monto_centavos),
                      jsonb_build_object('cuenta', v_cta.codigo, 'haber', p_monto_centavos)));

  INSERT INTO public.pago_proveedor (empresa_id, numero, compra_id, saldo_inicial_id, proveedor_id, fecha_contable,
    forma_pago, cuenta_pago_id, monto_centavos, referencia, asiento_id, id_operacion, creado_por)
  VALUES (p_empresa_id, v_num, v_c.id, v_s.id, v_prov, p_fecha, p_forma_pago, v_cta.id, p_monto_centavos,
    nullif(trim(p_referencia), ''), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO v_pago;

  RETURN jsonb_build_object('pago_id', v_pago.id, 'numero', v_num, 'asiento_id', v_asto,
                            'saldo_restante_centavos', v_saldo - p_monto_centavos, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 5) RPC: anular_pago_proveedor (permiso compras.anular)
--    Contra-asiento: Dr la MISMA cuenta de dinero del pago / Cr Proveedores.
--    Fecha: la indicada o hoy (nunca antes del pago); mes abierto.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.anular_pago_proveedor(p_pago_id uuid, p_motivo text, p_id_operacion uuid,
                                             p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_p     public.pago_proveedor;
  v_an    public.pago_proveedor_anulacion;
  v_fecha date;
  v_doc   uuid;
  v_total bigint;
  v_cta   text;
  v_suc   uuid;
  v_asto  uuid;
BEGIN
  SELECT * INTO v_p FROM public.pago_proveedor WHERE id = p_pago_id;
  IF v_p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el pago no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v_p.empresa_id, 'compras.anular', 'compras');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v_p.empresa_id, p_id_operacion, 'anulacion_pago_proveedor');
  v_doc := coalesce(v_p.compra_id, v_p.saldo_inicial_id);
  v_total := coalesce((SELECT c.total_centavos FROM public.compra c WHERE c.id = v_p.compra_id),
                      (SELECT s.monto_centavos FROM public.cxp_saldo_inicial s WHERE s.id = v_p.saldo_inicial_id));
  SELECT * INTO v_an FROM public.pago_proveedor_anulacion WHERE pago_id = v_p.id;
  IF v_an.id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('pago_id', v_p.id, 'asiento_id', v_an.asiento_id,
                              'saldo_documento_centavos', v_total - interno.pagado_documento_cxp(v_doc), 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(v_p.empresa_id), v_p.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v_p.empresa_id, v_fecha);
  IF v_fecha < v_p.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al pago (%).',
      to_char(v_p.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.bloquear_libros(v_p.empresa_id);
  SELECT * INTO v_an FROM public.pago_proveedor_anulacion WHERE pago_id = v_p.id;
  IF v_an.id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('pago_id', v_p.id, 'asiento_id', v_an.asiento_id,
                              'saldo_documento_centavos', v_total - interno.pagado_documento_cxp(v_doc), 'duplicado', true);
  END IF;
  IF v_an.id IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el pago #% ya fue anulado.', v_p.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(v_p.empresa_id, v_fecha);

  SELECT c.codigo INTO v_cta FROM public.cuenta c WHERE c.id = v_p.cuenta_pago_id;
  SELECT a.sucursal_id INTO v_suc FROM public.asiento a WHERE a.id = v_p.asiento_id;
  v_asto := interno.asiento_sistema(v_p.empresa_id, v_suc, v_fecha,
    'ANULACIÓN pago #' || v_p.numero || ' a proveedor: ' || trim(p_motivo),
    'anulacion_pago_proveedor', p_id_operacion,
    jsonb_build_array(jsonb_build_object('cuenta', v_cta, 'debe', v_p.monto_centavos, 'descripcion', 'Vuelve el dinero del pago'),
                      jsonb_build_object('uso', 'cxp', 'haber', v_p.monto_centavos)),
    v_p.asiento_id, trim(p_motivo));

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.pago_proveedor_anulacion (empresa_id, pago_id, fecha_contable, motivo, asiento_id, id_operacion, anulado_por)
  VALUES (v_p.empresa_id, v_p.id, v_fecha, trim(p_motivo), v_asto, p_id_operacion, auth.uid());
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('pago_id', v_p.id, 'asiento_id', v_asto,
                            'saldo_documento_centavos', v_total - interno.pagado_documento_cxp(v_doc), 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 6) anular_compra (reemplaza la de 016; misma firma). Cambios: los pagos
--    ANULADOS no cuentan; id_operacion por tipo; fecha por defecto nunca
--    antes de la compra; el ajuste de costo se oculta sin inventario.costos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.anular_compra(p_compra_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_c     public.compra;
  v_fecha date;
  r       public.compra_linea;
  m       public.inventario_movimiento;
  v_sale  bigint := 0;
  v_dif   bigint;
  v_asto  uuid;
BEGIN
  SELECT * INTO v_c FROM public.compra WHERE id = p_compra_id;
  IF v_c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la compra no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v_c.empresa_id, 'compras.anular', 'compras');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v_c.empresa_id, p_id_operacion, 'anulacion_compra');
  IF v_c.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('compra_id', v_c.id, 'asiento_id', v_c.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(v_c.empresa_id), v_c.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v_c.empresa_id, v_fecha);
  IF v_fecha < v_c.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior a la compra.';
  END IF;

  PERFORM interno.bloquear_libros(v_c.empresa_id);
  SELECT * INTO v_c FROM public.compra WHERE id = p_compra_id FOR UPDATE;
  IF v_c.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('compra_id', v_c.id, 'asiento_id', v_c.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF v_c.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: la compra #% ya fue anulada.', v_c.numero;
  END IF;
  IF interno.pagado_documento_cxp(v_c.id) > 0 THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la compra #% ya tiene pagos; anule primero esos pagos (anular_pago_proveedor).', v_c.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(v_c.empresa_id, v_fecha);

  FOR r IN SELECT * FROM public.compra_linea WHERE compra_id = v_c.id ORDER BY linea LOOP
    m := interno.mover_inventario(v_c.empresa_id, v_c.bodega_id, r.producto_id, 'salida', 'anulacion_compra',
                                  v_fecha, -r.cantidad, r.subtotal_centavos, 'compra', v_c.id, p_id_operacion,
                                  'Anulación compra #' || v_c.numero || ': ' || trim(p_motivo), false);
    v_sale := v_sale - m.valor_centavos;
  END LOOP;
  v_dif := v_c.subtotal_centavos - v_sale;     -- > 0: sale menos valor que el original

  v_asto := interno.asiento_sistema(v_c.empresa_id, v_c.sucursal_id, v_fecha,
    'ANULACIÓN compra #' || v_c.numero || ' (factura ' || v_c.numero_documento || '): ' || trim(p_motivo),
    'anulacion_compra', p_id_operacion,
    jsonb_build_array(
      CASE WHEN v_c.condicion = 'credito' THEN jsonb_build_object('uso', 'cxp', 'debe', v_c.total_centavos)
           ELSE jsonb_build_object('cuenta', (SELECT x.codigo FROM public.cuenta x WHERE x.id = v_c.cuenta_pago_id),
                                   'debe', v_c.total_centavos) END,
      jsonb_build_object('uso', 'isv_credito', 'haber', v_c.isv_centavos),
      jsonb_build_object('uso', 'inventario',  'haber', v_sale),
      jsonb_build_object('uso', 'perdida_inventario', 'haber', greatest(v_dif, 0), 'descripcion', 'Ajuste de costo'),
      jsonb_build_object('uso', 'perdida_inventario', 'debe',  greatest(-v_dif, 0), 'descripcion', 'Ajuste de costo')),
    v_c.asiento_id, trim(p_motivo));

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.compra
     SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo),
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion, fecha_anulacion = v_fecha
   WHERE id = v_c.id;
  PERFORM set_config('app.motivo', '', true);

  RETURN interno.ocultar_costos(v_c.empresa_id,
    jsonb_build_object('compra_id', v_c.id, 'asiento_id', v_asto, 'ajuste_costo_centavos', v_dif, 'duplicado', false),
    ARRAY['ajuste_costo_centavos']);
END $$;

-- registrar_compra (envoltura de 017): además, una factura ya cargada como
-- saldo inicial del mismo proveedor no entra otra vez como compra.
CREATE OR REPLACE FUNCTION public.registrar_compra(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_doc text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.registrar', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'compra');
  IF jsonb_typeof(p_datos) = 'object' AND jsonb_typeof(p_datos->'numero_documento') = 'string'
     AND jsonb_typeof(p_datos->'proveedor_id') = 'string'
     AND NOT EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    v_doc := trim(p_datos->>'numero_documento');
    IF EXISTS (SELECT 1 FROM public.cxp_saldo_inicial s
                WHERE s.empresa_id = p_empresa_id AND s.proveedor_id::text = p_datos->>'proveedor_id'
                  AND upper(s.numero_documento) = upper(v_doc) AND s.anulada_en IS NULL) THEN
      RAISE EXCEPTION 'YA_EXISTE: la factura % de este proveedor ya está registrada como saldo inicial.', v_doc;
    END IF;
  END IF;
  RETURN interno.registrar_compra_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- ---------------------------------------------------------------------
-- 7) Vistas de CxP: compras al crédito + saldos iniciales; pagos anulados
--    no cuentan. Mismas columnas que en 016 y tres nuevas al final:
--    origen ('compra' | 'saldo_inicial'), documento_id (lo que se pasa a
--    pagar_proveedor) y fecha_documento (de ella sale la antigüedad).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_cxp_documento WITH (security_invoker = true) AS
  WITH pagos AS (
    SELECT coalesce(x.compra_id, x.saldo_inicial_id) AS documento_id, sum(x.monto_centavos) AS pagado
      FROM public.pago_proveedor x
     WHERE NOT EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion a WHERE a.pago_id = x.id)
     GROUP BY 1),
  docs AS (
    SELECT c.empresa_id, c.id AS compra_id, c.numero, c.proveedor_id, c.numero_documento, c.fecha_contable,
           c.fecha_vencimiento, c.total_centavos, 'compra'::text AS origen, c.id AS documento_id,
           c.fecha_contable AS fecha_documento
      FROM public.compra c
     WHERE c.condicion = 'credito' AND c.anulada_en IS NULL
    UNION ALL
    SELECT s.empresa_id, NULL::uuid, s.numero, s.proveedor_id, s.numero_documento, s.fecha_contable,
           s.fecha_vencimiento, s.monto_centavos, 'saldo_inicial'::text, s.id, s.fecha_documento
      FROM public.cxp_saldo_inicial s
     WHERE s.anulada_en IS NULL)
  SELECT d.empresa_id, d.compra_id, d.numero, d.proveedor_id, t.nombre AS proveedor_nombre, t.rtn AS proveedor_rtn,
         d.numero_documento, d.fecha_contable, d.fecha_vencimiento, d.total_centavos,
         coalesce(pg.pagado, 0)::bigint AS pagado_centavos,
         (d.total_centavos - coalesce(pg.pagado, 0))::bigint AS saldo_centavos,
         public.hoy_local(d.empresa_id) - d.fecha_documento AS dias,
         greatest(public.hoy_local(d.empresa_id) - d.fecha_vencimiento, 0) AS dias_vencido,
         d.origen, d.documento_id, d.fecha_documento
  FROM docs d
  JOIN public.tercero t ON t.id = d.proveedor_id
  LEFT JOIN pagos pg ON pg.documento_id = d.documento_id
  WHERE d.total_centavos - coalesce(pg.pagado, 0) > 0;

-- ---------------------------------------------------------------------
-- 8) Activar inventario o compras: los libros deben coincidir con el módulo
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.lempiras(p_centavos bigint) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT 'L ' || to_char(p_centavos / 100.0, 'FM999,999,999,999,990.00')
$$;

CREATE FUNCTION interno.revisar_activacion_modulo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_libros bigint;
  v_modulo bigint;
  v_cta    text;
BEGIN
  IF NOT NEW.activo OR (TG_OP = 'UPDATE' AND OLD.activo) THEN
    RETURN NEW;
  END IF;
  IF NEW.modulo = 'inventario' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'inventario');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := coalesce((SELECT sum(s.valor_centavos) FROM public.inventario_saldo s WHERE s.empresa_id = NEW.empresa_id), 0);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (inventario) tiene % en los libros y el kardex tiene %. Para activar el módulo: 1) registre un asiento que pase la diferencia a % Saldos de apertura (Dr %, Cr %); 2) active el módulo; 3) cargue las existencias con cargar_saldo_inicial (vuelve a llevar el valor a % contra Saldos de apertura).',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo),
        interno.cuenta_de(NEW.empresa_id, 'apertura_inventario'), interno.cuenta_de(NEW.empresa_id, 'apertura_inventario'), v_cta, v_cta;
    END IF;
  ELSIF NEW.modulo = 'compras' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'cxp');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_cxp(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (proveedores) tiene % en los libros y las facturas por pagar del sistema suman %. Para activar el módulo: 1) registre un asiento que pase la diferencia a % Saldos de apertura (Dr %, Cr %); 2) active el módulo; 3) registre cada factura pendiente con registrar_saldo_inicial_cxp.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo),
        interno.cuenta_de(NEW.empresa_id, 'apertura_cxp'), v_cta, interno.cuenta_de(NEW.empresa_id, 'apertura_cxp');
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER revisar_activacion BEFORE INSERT OR UPDATE ON public.modulo_activo
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_activacion_modulo();

-- ---------------------------------------------------------------------
-- 9) id_operacion por tipo: versión final (todas las tablas de 0.4.0)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.tipo_operacion(p_empresa_id uuid, p_id uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  IF p_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'compra';
  END IF;
  IF EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_compra';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pago_proveedor x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'pago_proveedor';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'anulacion_pago_proveedor';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cxp_saldo_inicial x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'saldo_inicial_cxp';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cxp_saldo_inicial x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_saldo_inicial_cxp';
  END IF;
  SELECT 'inventario_' || d.tipo INTO v FROM public.inventario_documento d
   WHERE d.empresa_id = p_empresa_id AND d.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN v;
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventario_documento_anulacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'anulacion_inventario';
  END IF;
  IF EXISTS (SELECT 1 FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'tercero';
  END IF;
  IF EXISTS (SELECT 1 FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'producto';
  END IF;
  SELECT a.origen INTO v FROM public.asiento a WHERE a.empresa_id = p_empresa_id AND a.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN CASE v WHEN 'manual' THEN 'asiento' WHEN 'anulacion' THEN 'anulacion_asiento' ELSE 'asiento_' || v END;
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- 10) Permisos de ejecución
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.proteger_saldo_inicial_cxp(),
  interno.pagado_documento_cxp(uuid),
  interno.total_cxp(uuid),
  interno.saldo_libros(uuid, text),
  interno.lempiras(bigint),
  interno.revisar_activacion_modulo()
FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  public.registrar_saldo_inicial_cxp(uuid, jsonb, uuid),
  public.anular_saldo_inicial_cxp(uuid, text, uuid, date),
  public.anular_pago_proveedor(uuid, text, uuid, date)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.registrar_saldo_inicial_cxp(uuid, jsonb, uuid),
  public.anular_saldo_inicial_cxp(uuid, text, uuid, date),
  public.anular_pago_proveedor(uuid, text, uuid, date)
TO authenticated;
