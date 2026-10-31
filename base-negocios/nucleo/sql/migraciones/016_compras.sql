-- =====================================================================
-- 016_compras.sql  -  Compras a proveedores, anulación y pagos (CxP)
--
--   compra / compra_linea   documento del proveedor (su número de factura)
--   pago_proveedor          abonos a una compra al crédito
--
-- registrar_compra: TODO o NADA en una transacción:
--   documento + entradas al kardex (a su costo) + asiento
--     Dr Inventario (subtotal)  Dr ISV crédito fiscal (ISV)
--     Cr Caja o Bancos (contado)  ó  Cr Proveedores (crédito)
-- anular_compra (con motivo): contra-movimiento en el kardex (sale a lo
--   que costó) + contra-asiento. Se rechaza si dejaría existencia negativa
--   o si la compra ya tiene pagos.
-- pagar_proveedor: abono a una compra al crédito, nunca más que su saldo.
--   Dr Proveedores / Cr Caja o Bancos.
-- De qué cuenta sale el dinero: "caja" = 1.1.01.01, "banco" = 1.1.01.03, o
--   la subcuenta que se indique (ej. 1.1.01.04 "Banco Atlántida"): cualquier
--   cuenta de detalle activa bajo 1.1.01 (Efectivo y equivalentes).
--
-- Montos: centavos. Costo unitario: centavos por unidad con 6 decimales.
--   subtotal de línea = round(cantidad x costo_unitario)
--   ISV de línea      = round(subtotal x 15% ó 18%) (EXENTO = 0); se puede
--                       mandar "isv_centavos" para cuadrar con la factura.
-- Vistas: v_cxp_documento (saldo por factura) y v_cxp_proveedor
--   (saldo por proveedor con antigüedad 0-30, 31-60, 61-90, +90 días).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('PAGO_EXCEDE_SALDO', 'El pago es mayor que lo que se debe.', 'Revise el saldo de la factura y pague como máximo ese monto.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('compras.ver',       'Ver compras y cuentas por pagar',               false, true),
  ('compras.registrar', 'Registrar compras a proveedores',               true,  false),
  ('compras.anular',    'Anular compras (contra-movimiento y asiento)',  true,  false),
  ('compras.pagar',     'Registrar pagos (abonos) a proveedores',        true,  false);

INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'compras.ver'), ('dueno', 'compras.registrar'), ('dueno', 'compras.anular'), ('dueno', 'compras.pagar'),
  ('admin', 'compras.ver'), ('admin', 'compras.registrar'), ('admin', 'compras.anular'), ('admin', 'compras.pagar');

SELECT interno.repartir_permisos(ARRAY['compras.ver', 'compras.registrar', 'compras.anular', 'compras.pagar'],
  'Núcleo 0.3.0: permisos nuevos de compras');

-- ---------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.compra (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,                 -- correlativo interno por empresa
  proveedor_id             uuid NOT NULL,
  numero_documento         text NOT NULL CHECK (length(trim(numero_documento)) > 0),  -- factura del proveedor
  sucursal_id              uuid NOT NULL,
  bodega_id                uuid NOT NULL,
  fecha_contable           date NOT NULL,
  condicion                text NOT NULL CHECK (condicion IN ('contado', 'credito')),
  forma_pago               text CHECK (forma_pago IN ('caja', 'banco')),
  cuenta_pago_id           uuid,                      -- contado: de qué cuenta salió el dinero
  fecha_vencimiento        date,
  subtotal_centavos        bigint NOT NULL CHECK (subtotal_centavos >= 0),
  isv_centavos             bigint NOT NULL CHECK (isv_centavos >= 0),
  total_centavos           bigint NOT NULL CHECK (total_centavos > 0 AND total_centavos = subtotal_centavos + isv_centavos),
  notas                    text,
  asiento_id               uuid NOT NULL,
  id_operacion             uuid NOT NULL,
  creado_por               uuid,
  registrado_en            timestamptz NOT NULL DEFAULT now(),
  -- Anulación (se llena una sola vez)
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
  FOREIGN KEY (empresa_id, bodega_id)            REFERENCES public.bodega(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((condicion = 'contado') = (forma_pago IS NOT NULL)),
  CHECK ((condicion = 'contado') = (cuenta_pago_id IS NOT NULL)),
  FOREIGN KEY (empresa_id, cuenta_pago_id)       REFERENCES public.cuenta(empresa_id, id),
  CHECK ((condicion = 'credito') = (fecha_vencimiento IS NOT NULL)),
  CHECK (fecha_vencimiento IS NULL OR fecha_vencimiento >= fecha_contable),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL)),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL))
);
-- La misma factura del mismo proveedor no entra dos veces (salvo anulada).
CREATE UNIQUE INDEX compra_factura ON public.compra (empresa_id, proveedor_id, upper(numero_documento))
  WHERE anulada_en IS NULL;
CREATE INDEX compra_proveedor ON public.compra (empresa_id, proveedor_id, fecha_contable);

CREATE TABLE public.compra_linea (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id         uuid NOT NULL,
  compra_id          uuid NOT NULL,
  linea              smallint NOT NULL CHECK (linea > 0),
  producto_id        uuid NOT NULL,
  cantidad           numeric(18,4) NOT NULL CHECK (cantidad > 0),
  costo_unitario     numeric(18,6) NOT NULL CHECK (costo_unitario >= 0),
  subtotal_centavos  bigint NOT NULL CHECK (subtotal_centavos >= 0),
  tipo_impuesto      text NOT NULL CHECK (tipo_impuesto IN ('ISV15', 'ISV18', 'EXENTO')),
  isv_centavos       bigint NOT NULL CHECK (isv_centavos >= 0),
  movimiento_id      bigint NOT NULL REFERENCES public.inventario_movimiento(id),
  UNIQUE (compra_id, linea),
  FOREIGN KEY (empresa_id, compra_id)   REFERENCES public.compra(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id)
);

CREATE TABLE public.pago_proveedor (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id       uuid NOT NULL REFERENCES public.empresa(id),
  numero           bigint NOT NULL,
  compra_id        uuid NOT NULL,
  proveedor_id     uuid NOT NULL,
  fecha_contable   date NOT NULL,
  forma_pago       text NOT NULL CHECK (forma_pago IN ('caja', 'banco')),
  cuenta_pago_id   uuid NOT NULL,               -- de qué cuenta salió el dinero
  monto_centavos   bigint NOT NULL CHECK (monto_centavos > 0),
  referencia       text,                        -- n.º de cheque, transferencia...
  asiento_id       uuid NOT NULL,
  id_operacion     uuid NOT NULL,
  creado_por       uuid,
  registrado_en    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, compra_id)    REFERENCES public.compra(empresa_id, id),
  FOREIGN KEY (empresa_id, proveedor_id) REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)   REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_pago_id) REFERENCES public.cuenta(empresa_id, id)
);
CREATE INDEX pago_proveedor_compra ON public.pago_proveedor (compra_id);

-- La compra no se edita; solo se anula una vez (se llenan los datos de anulación).
CREATE FUNCTION interno.proteger_compra() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.anulada_en IS NOT NULL
     OR to_jsonb(NEW) - 'anulada_en' - 'anulada_por' - 'motivo_anulacion' - 'asiento_anulacion_id'
                      - 'anulacion_id_operacion' - 'fecha_anulacion'
        IS DISTINCT FROM
        to_jsonb(OLD) - 'anulada_en' - 'anulada_por' - 'motivo_anulacion' - 'asiento_anulacion_id'
                      - 'anulacion_id_operacion' - 'fecha_anulacion' THEN
    RAISE EXCEPTION 'PROHIBIDO: una compra no se edita; solo se anula una vez.';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER proteger BEFORE UPDATE ON public.compra FOR EACH ROW EXECUTE FUNCTION interno.proteger_compra();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.compra
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las compras no se borran: se anulan.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.compra_linea
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las compras no se editan: se anulan.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.pago_proveedor
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los pagos no se editan ni se borran.');
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.compra FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT ON public.pago_proveedor              FOR EACH ROW EXECUTE FUNCTION interno.auditar();

-- Cuenta de la que sale el dinero: la indicada (código) o la de la forma de
-- pago. Debe ser de detalle, activa y de "Efectivo y equivalentes" (1.1.01).
CREATE FUNCTION interno.cuenta_de_pago(p_empresa_id uuid, p_forma text, p_codigo text) RETURNS public.cuenta
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.cuenta;
BEGIN
  SELECT * INTO c FROM public.cuenta x
   WHERE x.empresa_id = p_empresa_id AND x.codigo = coalesce(nullif(trim(p_codigo), ''), interno.cuenta_sistema(p_forma));
  IF c.id IS NULL OR NOT c.es_detalle OR NOT c.activa OR c.codigo NOT LIKE '1.1.01.%' THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta de pago "%" debe ser una cuenta de detalle activa de efectivo o bancos (1.1.01...).',
      coalesce(p_codigo, p_forma);
  END IF;
  RETURN c;
END $$;

-- Tasa de ISV por tipo de impuesto.
CREATE FUNCTION interno.tasa_isv(p_tipo text) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_tipo WHEN 'ISV15' THEN 0.15 WHEN 'ISV18' THEN 0.18 ELSE 0 END::numeric
$$;

-- Respuesta de una compra ya registrada (reintentos).
CREATE FUNCTION interno.compra_respuesta(c public.compra, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('compra_id', c.id, 'numero', c.numero, 'asiento_id', c.asiento_id,
                            'subtotal_centavos', c.subtotal_centavos, 'isv_centavos', c.isv_centavos,
                            'total_centavos', c.total_centavos, 'duplicado', p_duplicado)
$$;

-- ---------------------------------------------------------------------
-- RPC: registrar_compra
-- p_datos = {
--   "proveedor_id": "...", "bodega_id": "...", "numero_documento": "000-001-01-00001234",
--   "fecha": "2026-01-15", "condicion": "credito" | "contado",
--   "forma_pago": "caja" | "banco"            (solo contado),
--   "cuenta_pago": "1.1.01.04"                (contado, opcional: qué banco o caja),
--   "fecha_vencimiento": "2026-02-14"         (crédito; si no, fecha + plazo del proveedor),
--   "notas": "...",
--   "lineas": [{"producto_id":"...","cantidad":10,"costo_unitario":1250.5,"isv_centavos":1876}, ...]
-- }
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_compra(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_max    constant numeric := 9007199254740991;
  v_c      public.compra;
  v_prov   public.tercero;
  v_b      public.bodega;
  v_fecha  date;
  v_venc   date;
  v_cond   text;
  v_forma  text;
  v_cta    public.cuenta;
  v_doc    text;
  l        jsonb;
  i        integer := 0;
  p        public.producto;
  v_q      numeric;
  v_costo  numeric;
  v_sub    bigint;
  v_isv    bigint;
  v_tsub   numeric := 0;
  v_tisv   numeric := 0;
  v_id     uuid := gen_random_uuid();
  v_num    bigint;
  v_asto   uuid;
  m        public.inventario_movimiento;
  v_lin    jsonb := '[]';
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.registrar', 'compras');
  IF NOT public.modulo_esta_activo(p_empresa_id, 'inventario') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: las compras necesitan el módulo "inventario" activo.';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  SELECT * INTO v_c FROM public.compra WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_c.id IS NOT NULL THEN
    RETURN interno.compra_respuesta(v_c, true);
  END IF;

  -- Cabecera
  PERFORM interno.exigir_claves(p_datos, ARRAY['proveedor_id','bodega_id','numero_documento','fecha','condicion',
                                               'forma_pago','cuenta_pago','fecha_vencimiento','notas','lineas']);
  SELECT * INTO v_prov FROM public.tercero t
   WHERE t.empresa_id = p_empresa_id AND t.id = interno.json_uuid(p_datos->'proveedor_id', 'proveedor_id');
  IF v_prov.id IS NULL OR NOT v_prov.es_proveedor OR NOT v_prov.activo THEN
    RAISE EXCEPTION 'TERCERO_INVALIDO: el proveedor no existe, no está marcado como proveedor o está desactivado.';
  END IF;
  v_b := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  v_doc := interno.json_texto(p_datos->'numero_documento', 'numero_documento', 50);
  IF v_doc IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el número de la factura del proveedor.';
  END IF;
  BEGIN
    v_fecha := (p_datos->>'fecha')::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la fecha de la compra debe ser AAAA-MM-DD.';
  END;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  v_cond := interno.json_texto(p_datos->'condicion', 'condicion', 10);
  IF v_cond IS NULL OR v_cond NOT IN ('contado', 'credito') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la condición es "contado" o "credito".';
  END IF;
  v_forma := interno.json_texto(p_datos->'forma_pago', 'forma_pago', 10);
  IF v_cond = 'contado' AND (v_forma IS NULL OR v_forma NOT IN ('caja', 'banco')) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: en una compra de contado indique la forma de pago: "caja" o "banco".';
  END IF;
  IF v_cond = 'contado' THEN
    v_cta := interno.cuenta_de_pago(p_empresa_id, v_forma, interno.json_texto(p_datos->'cuenta_pago', 'cuenta_pago', 30));
  ELSIF p_datos ? 'cuenta_pago' AND p_datos->'cuenta_pago' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'DATO_INVALIDO: una compra al crédito no lleva cuenta de pago.';
  END IF;
  IF v_cond = 'credito' THEN
    IF v_forma IS NOT NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: una compra al crédito no lleva forma de pago (se paga después con un abono).';
    END IF;
    IF p_datos ? 'fecha_vencimiento' AND p_datos->'fecha_vencimiento' <> 'null'::jsonb THEN
      BEGIN
        v_venc := (p_datos->>'fecha_vencimiento')::date;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FECHA_INVALIDA: la fecha de vencimiento debe ser AAAA-MM-DD.';
      END;
    ELSE
      v_venc := v_fecha + v_prov.plazo_dias;
    END IF;
    IF v_venc < v_fecha THEN
      RAISE EXCEPTION 'FECHA_INVALIDA: el vencimiento no puede ser antes de la fecha de la compra.';
    END IF;
  END IF;
  PERFORM interno.exigir_lineas(p_datos->'lineas', ARRAY['producto_id', 'cantidad', 'costo_unitario', 'isv_centavos']);

  -- Líneas (se validan y calculan antes de tocar nada)
  FOR l IN SELECT * FROM jsonb_array_elements(p_datos->'lineas') LOOP
    i := i + 1;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, true);
    v_q := interno.json_numero(l->'cantidad', 'cantidad', i);
    PERFORM interno.validar_cantidad(p, v_q, i);
    v_costo := interno.json_numero(l->'costo_unitario', 'costo_unitario', i);
    PERFORM interno.validar_costo(v_costo, i);
    IF round(v_q * v_costo) > c_max THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: el monto de la línea % es demasiado grande.', i;
    END IF;
    v_sub := round(v_q * v_costo)::bigint;
    IF l ? 'isv_centavos' THEN
      v_isv := interno.json_centavos(l->'isv_centavos', 'isv_centavos');
      IF v_isv > v_sub OR (p.tipo_impuesto = 'EXENTO' AND v_isv <> 0) THEN
        RAISE EXCEPTION 'LINEA_INVALIDA: el ISV de la línea % no es válido para ese producto y subtotal.', i;
      END IF;
    ELSE
      v_isv := round(v_sub * interno.tasa_isv(p.tipo_impuesto))::bigint;
    END IF;
    v_tsub := v_tsub + v_sub;
    v_tisv := v_tisv + v_isv;
    v_lin := v_lin || jsonb_build_object('producto_id', p.id, 'cantidad', v_q, 'costo', v_costo,
                                         'subtotal', v_sub, 'impuesto', p.tipo_impuesto, 'isv', v_isv);
  END LOOP;
  IF v_tsub + v_tisv = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la compra no puede ser de L 0.00.';
  END IF;
  IF v_tsub + v_tisv > c_max THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el total de la compra es demasiado grande.';
  END IF;

  -- Candado de la empresa, reintento y factura repetida
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO v_c FROM public.compra WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_c.id IS NOT NULL THEN
    RETURN interno.compra_respuesta(v_c, true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.proveedor_id = v_prov.id
              AND upper(x.numero_documento) = upper(v_doc) AND x.anulada_en IS NULL) THEN
    RAISE EXCEPTION 'YA_EXISTE: la factura % de este proveedor ya está registrada.', v_doc;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);

  v_num := interno.siguiente_numero(p_empresa_id, 'compra');
  v_asto := interno.asiento_sistema(p_empresa_id, v_b.sucursal_id, v_fecha,
    'Compra #' || v_num || ' a ' || v_prov.nombre || ', factura ' || v_doc, 'compra', p_id_operacion,
    jsonb_build_array(
      jsonb_build_object('uso', 'inventario',  'debe', v_tsub::bigint),
      jsonb_build_object('uso', 'isv_credito', 'debe', v_tisv::bigint),
      CASE WHEN v_cond = 'credito' THEN jsonb_build_object('uso', 'cxp', 'haber', (v_tsub + v_tisv)::bigint)
           ELSE jsonb_build_object('cuenta', v_cta.codigo, 'haber', (v_tsub + v_tisv)::bigint) END));

  INSERT INTO public.compra (id, empresa_id, numero, proveedor_id, numero_documento, sucursal_id, bodega_id,
    fecha_contable, condicion, forma_pago, cuenta_pago_id, fecha_vencimiento, subtotal_centavos, isv_centavos, total_centavos,
    notas, asiento_id, id_operacion, creado_por)
  VALUES (v_id, p_empresa_id, v_num, v_prov.id, v_doc, v_b.sucursal_id, v_b.id,
    v_fecha, v_cond, v_forma, v_cta.id, v_venc, v_tsub::bigint, v_tisv::bigint, (v_tsub + v_tisv)::bigint,
    interno.json_texto(p_datos->'notas', 'notas', 500), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO v_c;

  i := 0;
  FOR l IN SELECT * FROM jsonb_array_elements(v_lin) LOOP
    i := i + 1;
    m := interno.mover_inventario(p_empresa_id, v_b.id, (l->>'producto_id')::uuid, 'entrada', 'compra', v_fecha,
                                  (l->>'cantidad')::numeric, (l->>'subtotal')::bigint, 'compra', v_id,
                                  p_id_operacion, 'Compra #' || v_num || ', factura ' || v_doc);
    INSERT INTO public.compra_linea (empresa_id, compra_id, linea, producto_id, cantidad, costo_unitario,
      subtotal_centavos, tipo_impuesto, isv_centavos, movimiento_id)
    VALUES (p_empresa_id, v_id, i, (l->>'producto_id')::uuid, (l->>'cantidad')::numeric, (l->>'costo')::numeric,
      (l->>'subtotal')::bigint, l->>'impuesto', (l->>'isv')::bigint, m.id);
  END LOOP;

  RETURN interno.compra_respuesta(v_c, false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: anular_compra
-- Cada línea sale del kardex a lo que costó en la compra. Si ya no hay
-- con qué (se vendió o trasladó), se rechaza. Si la bodega se vacía, sale
-- todo su valor y la diferencia contra el costo original va a
-- "ajuste de costo" (5.1.01.02), para que el kardex siga = contabilidad.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.anular_compra(p_compra_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
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
  IF v_c.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('compra_id', v_c.id, 'asiento_id', v_c.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, public.hoy_local(v_c.empresa_id));
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
  IF EXISTS (SELECT 1 FROM public.pago_proveedor x WHERE x.compra_id = v_c.id) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la compra #% ya tiene pagos; no se puede anular.', v_c.numero;
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

  RETURN jsonb_build_object('compra_id', v_c.id, 'asiento_id', v_asto, 'ajuste_costo_centavos', v_dif,
                            'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: pagar_proveedor (abono a una compra al crédito)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pagar_proveedor(p_empresa_id uuid, p_compra_id uuid, p_monto_centavos bigint,
                                       p_fecha date, p_forma_pago text, p_id_operacion uuid,
                                       p_referencia text DEFAULT NULL, p_cuenta_pago text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_pago  public.pago_proveedor;
  v_c     public.compra;
  v_saldo bigint;
  v_num   bigint;
  v_asto  uuid;
  v_suc   uuid;
  v_cta   public.cuenta;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.pagar', 'compras');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
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
  IF v_c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la compra no existe en esta empresa.';
  END IF;
  IF v_c.condicion <> 'credito' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la compra #% fue de contado; no tiene saldo por pagar.', v_c.numero;
  END IF;
  IF v_c.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la compra #% está anulada.', v_c.numero;
  END IF;
  IF p_fecha < v_c.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el pago no puede tener fecha anterior a la compra.';
  END IF;
  v_saldo := v_c.total_centavos - coalesce((SELECT sum(x.monto_centavos) FROM public.pago_proveedor x
                                             WHERE x.compra_id = v_c.id), 0);
  IF p_monto_centavos > v_saldo THEN
    RAISE EXCEPTION 'PAGO_EXCEDE_SALDO: el pago (% centavos) es mayor que el saldo de la compra #% (% centavos).',
      p_monto_centavos, v_c.numero, v_saldo;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, p_fecha);

  -- Sucursal de la compra (si ya no está activa, la primera activa).
  SELECT s.id INTO v_suc FROM public.sucursal s WHERE s.id = v_c.sucursal_id AND s.activa;
  v_num := interno.siguiente_numero(p_empresa_id, 'pago_proveedor');
  v_asto := interno.asiento_sistema(p_empresa_id, v_suc, p_fecha,
    'Pago #' || v_num || ' a proveedor, compra #' || v_c.numero || ' (factura ' || v_c.numero_documento || ')'
      || coalesce(' ref. ' || nullif(trim(p_referencia), ''), ''),
    'pago_proveedor', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'cxp', 'debe', p_monto_centavos),
                      jsonb_build_object('cuenta', v_cta.codigo, 'haber', p_monto_centavos)));

  INSERT INTO public.pago_proveedor (empresa_id, numero, compra_id, proveedor_id, fecha_contable, forma_pago,
    cuenta_pago_id, monto_centavos, referencia, asiento_id, id_operacion, creado_por)
  VALUES (p_empresa_id, v_num, v_c.id, v_c.proveedor_id, p_fecha, p_forma_pago, v_cta.id, p_monto_centavos,
    nullif(trim(p_referencia), ''), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO v_pago;

  RETURN jsonb_build_object('pago_id', v_pago.id, 'numero', v_num, 'asiento_id', v_asto,
                            'saldo_restante_centavos', v_saldo - p_monto_centavos, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- Vistas (respetan RLS: piden compras.ver)
-- ---------------------------------------------------------------------
-- Facturas al crédito con saldo pendiente. "dias" = días desde la fecha
-- de la factura (antigüedad); "dias_vencido" = días pasados del vencimiento.
CREATE VIEW public.v_cxp_documento WITH (security_invoker = true) AS
  SELECT c.empresa_id, c.id AS compra_id, c.numero, c.proveedor_id, t.nombre AS proveedor_nombre, t.rtn AS proveedor_rtn,
         c.numero_documento, c.fecha_contable, c.fecha_vencimiento, c.total_centavos,
         coalesce(pg.pagado, 0)::bigint AS pagado_centavos,
         (c.total_centavos - coalesce(pg.pagado, 0))::bigint AS saldo_centavos,
         public.hoy_local(c.empresa_id) - c.fecha_contable AS dias,
         greatest(public.hoy_local(c.empresa_id) - c.fecha_vencimiento, 0) AS dias_vencido
  FROM public.compra c
  JOIN public.tercero t ON t.id = c.proveedor_id
  LEFT JOIN (SELECT x.compra_id, sum(x.monto_centavos) AS pagado
               FROM public.pago_proveedor x GROUP BY x.compra_id) pg ON pg.compra_id = c.id
  WHERE c.condicion = 'credito' AND c.anulada_en IS NULL
    AND c.total_centavos - coalesce(pg.pagado, 0) > 0;

-- CxP por proveedor con antigüedad (por días desde la fecha de la factura).
CREATE VIEW public.v_cxp_proveedor WITH (security_invoker = true) AS
  SELECT d.empresa_id, d.proveedor_id, d.proveedor_nombre, d.proveedor_rtn,
         count(*) AS facturas,
         sum(d.saldo_centavos)::bigint AS saldo_centavos,
         sum(CASE WHEN d.dias <= 30 THEN d.saldo_centavos ELSE 0 END)::bigint AS de_0_a_30_centavos,
         sum(CASE WHEN d.dias BETWEEN 31 AND 60 THEN d.saldo_centavos ELSE 0 END)::bigint AS de_31_a_60_centavos,
         sum(CASE WHEN d.dias BETWEEN 61 AND 90 THEN d.saldo_centavos ELSE 0 END)::bigint AS de_61_a_90_centavos,
         sum(CASE WHEN d.dias > 90 THEN d.saldo_centavos ELSE 0 END)::bigint AS mas_de_90_centavos,
         sum(CASE WHEN d.dias_vencido > 0 THEN d.saldo_centavos ELSE 0 END)::bigint AS vencido_centavos
  FROM public.v_cxp_documento d
  GROUP BY d.empresa_id, d.proveedor_id, d.proveedor_nombre, d.proveedor_rtn;

-- ---------------------------------------------------------------------
-- Seguridad
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['compra', 'compra_linea', 'pago_proveedor'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso(%L, empresa_id))',
                   t, 'compras.ver');
  END LOOP;
END $$;
GRANT SELECT ON public.v_cxp_documento, public.v_cxp_proveedor TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  public.registrar_compra(uuid, jsonb, uuid),
  public.anular_compra(uuid, text, uuid, date),
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.registrar_compra(uuid, jsonb, uuid),
  public.anular_compra(uuid, text, uuid, date),
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text)
TO authenticated;
