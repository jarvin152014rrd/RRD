-- =====================================================================
-- 034_apartados.sql  -  Núcleo 0.9.0 (etapa 2b-2b): apartados con
-- anticipo y formas de pago nuevas en la venta.
--
--   Ventas: dos formas de pago nuevas
--     saldo_favor  el cliente paga con su saldo a favor ("vale": el código de
--                  un vale sin cliente). Se consume al EMITIR (una venta
--                  pendiente no mueve nada). Dr Saldos a favor.
--     anticipo     solo al completar un apartado: lo que el cliente ya dejó.
--                  Dr Anticipos de clientes (2.1.04.01).
--     Al anular la venta: el saldo a favor usado vuelve a su lote; el
--     anticipo pasa a saldo a favor del cliente (el apartado ya se entregó).
--   Módulo "apartados" (necesita ventas e inventario):
--     crear_apartado: requiere cliente; precios y descuentos del día quedan
--       fijos; RESERVA las existencias (no disponibles para otras ventas ni
--       traslados) SIN salir del kardex ni reconocer ingreso; anticipo inicial
--       obligatorio como pasivo (Dr dinero / Cr Anticipos de clientes) con
--       rastro. Vence en empresa.apartado_dias_vigencia días (defecto 30):
--       vencido ya no reserva.
--     abonar_apartado: más anticipos (es un cobro tipo "apartado").
--     completar_apartado: cobra lo que falta y lo convierte en VENTA (factura
--       CAI si fiscal_hn) aplicando los anticipos; la venta sale de una vez
--       (si necesitara aprobación: APROBACION_REQUERIDA).
--     cancelar_apartado: libera la reserva; el anticipo se devuelve (de la
--       cuenta elegida) o pasa a saldo a favor, según empresa.apartado_cancelacion
--       (saldo_favor por defecto | devolver | elegir). Con motivo.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('EXISTENCIA_RESERVADA', 'Esa mercadería está apartada para otro cliente.',
   'Venda otra unidad o pida que se complete o cancele el apartado.'),
  ('APROBACION_REQUERIDA', 'Esta operación necesita una aprobación que no se puede pedir aquí.',
   'Pida a quien aprueba que la haga, o cámbiela para que quede dentro de su tope.');

INSERT INTO public.modulo (codigo, nombre) VALUES ('apartados', 'Apartados con anticipo (reservan mercadería)');
INSERT INTO public.modulo_dependencia (modulo, requiere, motivo) VALUES
  ('apartados', 'ventas',     'Un apartado termina en una venta.'),
  ('apartados', 'inventario', 'Reserva existencias del kardex.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('apartados.registrar', 'Crear apartados, recibir sus anticipos y completarlos (convertir en venta)', true, false),
  ('apartados.cancelar',  'Cancelar apartados (libera la mercadería; el anticipo se devuelve o queda a favor)', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'apartados.registrar'), ('dueno', 'apartados.cancelar'),
  ('admin', 'apartados.registrar'), ('admin', 'apartados.cancelar'),
  ('cajero', 'apartados.registrar'), ('vendedor', 'apartados.registrar');
SELECT interno.repartir_permisos(ARRAY['apartados.registrar', 'apartados.cancelar'], 'Núcleo 0.9.0: permisos de apartados');

INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('anticipo_clientes', '2.1.04.01', 'Anticipos de clientes por apartados (pasivo hasta entregar)', 'apartados');

ALTER TABLE public.empresa
  ADD COLUMN apartado_dias_vigencia integer NOT NULL DEFAULT 30 CHECK (apartado_dias_vigencia BETWEEN 1 AND 365),
  ADD COLUMN apartado_cancelacion   text NOT NULL DEFAULT 'saldo_favor' CHECK (apartado_cancelacion IN ('saldo_favor', 'devolver', 'elegir'));

-- ---------------------------------------------------------------------
-- 1) Formas de pago nuevas de la venta
-- ---------------------------------------------------------------------
ALTER TABLE public.venta_pago
  DROP CONSTRAINT venta_pago_forma_check,
  ADD CONSTRAINT venta_pago_forma_check CHECK (forma IN ('efectivo', 'tarjeta', 'transferencia', 'credito', 'saldo_favor', 'anticipo')),
  DROP CONSTRAINT venta_pago_check,
  ADD CONSTRAINT venta_pago_cuenta_check CHECK ((forma IN ('credito', 'saldo_favor', 'anticipo')) = (cuenta_dinero_id IS NULL)),
  ADD COLUMN vale            text,     -- saldo_favor: código del vale (sin cliente)
  ADD COLUMN saldo_favor_id  uuid,     -- saldo_favor: un lote en particular (cambio de producto, 035)
  ADD CONSTRAINT venta_pago_vale_check CHECK (forma = 'saldo_favor' OR (vale IS NULL AND saldo_favor_id IS NULL));
ALTER TABLE public.venta ADD COLUMN apartado_id uuid;

-- Usa un lote en particular (bloqueado). Error si no alcanza o venció.
CREATE FUNCTION interno.usar_saldo_favor_lote(p_lote_id uuid, p_monto bigint, p_documento_tipo text, p_documento_id uuid,
                                              p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s      public.saldo_favor;
  v_disp bigint;
BEGIN
  SELECT * INTO s FROM public.saldo_favor WHERE id = p_lote_id FOR UPDATE;
  IF s.id IS NULL OR s.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'VALE_INVALIDO: el saldo a favor no existe o está anulado.';
  END IF;
  IF s.vence_el < public.hoy_local(s.empresa_id) THEN
    RAISE EXCEPTION 'VALE_VENCIDO: el vale % venció el %.', s.codigo, to_char(s.vence_el, 'DD/MM/YYYY');
  END IF;
  v_disp := interno.saldo_favor_lote(s.id);
  IF v_disp < p_monto THEN
    RAISE EXCEPTION 'SALDO_FAVOR_INSUFICIENTE: el saldo a favor #% tiene % y se quieren usar %.', s.numero,
      interno.lempiras(v_disp), interno.lempiras(p_monto);
  END IF;
  INSERT INTO public.saldo_favor_uso (empresa_id, saldo_favor_id, monto_centavos, documento_tipo, documento_id, fecha_contable, creado_por)
  VALUES (s.empresa_id, s.id, p_monto, p_documento_tipo, p_documento_id, p_fecha, auth.uid());
  RETURN jsonb_build_array(jsonb_build_object('saldo_favor_id', s.id, 'codigo', s.codigo, 'monto_centavos', p_monto));
END $$;

-- ---------------------------------------------------------------------
-- 2) Apartados
-- ---------------------------------------------------------------------
CREATE TABLE public.apartado (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                  uuid NOT NULL REFERENCES public.empresa(id),
  numero                      bigint NOT NULL,
  cliente_id                  uuid NOT NULL,
  vendedor_id                 uuid NOT NULL,
  caja_id                     uuid NOT NULL REFERENCES public.caja(id),
  sucursal_id                 uuid NOT NULL,
  bodega_id                   uuid NOT NULL,
  fecha                       date NOT NULL,
  vence_el                    date NOT NULL,
  entrada                     jsonb NOT NULL,     -- {"lineas", "descuento_factura"} tal como se pidió
  calculo                     jsonb NOT NULL,     -- precios y descuentos que quedan fijos
  subtotal_centavos           bigint NOT NULL,
  descuento_centavos          bigint NOT NULL,
  impuesto_centavos           bigint NOT NULL,
  total_centavos              bigint NOT NULL CHECK (total_centavos BETWEEN 1 AND 9007199254740991),
  estado                      text NOT NULL DEFAULT 'vigente' CHECK (estado IN ('vigente', 'completado', 'cancelado')),
  venta_id                    uuid,
  completado_en               timestamptz,
  completado_por              uuid,
  completado_id_operacion     uuid,
  cancelado_en                timestamptz,
  cancelado_por               uuid,
  motivo_cancelacion          text,
  destino_anticipo            text CHECK (destino_anticipo IN ('saldo_favor', 'devolver')),
  anticipo_devuelto_centavos  bigint,
  cuenta_devolucion_id        uuid,
  saldo_favor_id              uuid,
  asiento_cancelacion_id      uuid,
  cancelacion_id_operacion    uuid,
  nota                        text,
  equipo                      text,
  id_operacion                uuid NOT NULL,
  creado_por                  uuid,
  registrado_en               timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, cliente_id)             REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id)            REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, bodega_id)              REFERENCES public.bodega(empresa_id, id),
  FOREIGN KEY (empresa_id, venta_id)               REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_devolucion_id)   REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, saldo_favor_id)         REFERENCES public.saldo_favor(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_cancelacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK (vence_el >= fecha),
  CHECK (total_centavos = subtotal_centavos - descuento_centavos + impuesto_centavos),
  CHECK ((estado = 'completado') = (venta_id IS NOT NULL)),
  CHECK ((estado = 'cancelado') = (cancelado_en IS NOT NULL)),
  CHECK (estado <> 'cancelado' OR (motivo_cancelacion IS NOT NULL AND destino_anticipo IS NOT NULL))
);
CREATE INDEX apartado_vigente ON public.apartado (empresa_id, bodega_id) WHERE estado = 'vigente';
CREATE INDEX apartado_cliente ON public.apartado (empresa_id, cliente_id, fecha);

CREATE TABLE public.apartado_linea (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id   uuid NOT NULL,
  apartado_id  uuid NOT NULL,
  linea        smallint NOT NULL CHECK (linea > 0),
  producto_id  uuid NOT NULL,
  cantidad     numeric(18,4) NOT NULL CHECK (cantidad > 0),
  es_servicio  boolean NOT NULL,
  UNIQUE (apartado_id, linea),
  FOREIGN KEY (empresa_id, apartado_id) REFERENCES public.apartado(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id)
);
CREATE INDEX apartado_linea_producto ON public.apartado_linea (producto_id) WHERE NOT es_servicio;

ALTER TABLE public.cobro ADD CONSTRAINT cobro_apartado_fk FOREIGN KEY (empresa_id, apartado_id) REFERENCES public.apartado(empresa_id, id);
ALTER TABLE public.venta ADD CONSTRAINT venta_apartado_fk FOREIGN KEY (empresa_id, apartado_id) REFERENCES public.apartado(empresa_id, id);
CREATE INDEX cobro_apartado ON public.cobro (apartado_id) WHERE apartado_id IS NOT NULL;

-- El apartado no se edita: se completa o se cancela una vez.
CREATE FUNCTION interno.proteger_apartado() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_com constant text[] := ARRAY['estado', 'venta_id', 'completado_en', 'completado_por', 'completado_id_operacion'];
  c_can constant text[] := ARRAY['estado', 'cancelado_en', 'cancelado_por', 'motivo_cancelacion', 'destino_anticipo',
                                 'anticipo_devuelto_centavos', 'cuenta_devolucion_id', 'saldo_favor_id', 'asiento_cancelacion_id',
                                 'cancelacion_id_operacion'];
BEGIN
  IF OLD.estado = 'vigente' AND NEW.estado = 'completado' AND (to_jsonb(NEW) - c_com) = (to_jsonb(OLD) - c_com) THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'vigente' AND NEW.estado = 'cancelado' AND (to_jsonb(NEW) - c_can) = (to_jsonb(OLD) - c_can) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: un apartado no se edita; se completa o se cancela una sola vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.apartado FOR EACH ROW EXECUTE FUNCTION interno.proteger_apartado();
CREATE TRIGGER proteger BEFORE UPDATE ON public.apartado_linea
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las líneas de un apartado no se editan.');
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['apartado', 'apartado_linea'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'Los apartados no se borran: se cancelan.');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L)))
                           OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', t, 'ventas.ver', 'apartados.registrar');
  END LOOP;
END $$;

-- Anticipos vigentes de un apartado.
CREATE FUNCTION interno.anticipos_apartado(p_apartado_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(c.aplicado_centavos), 0)::bigint FROM public.cobro c
   WHERE c.apartado_id = p_apartado_id AND c.anulada_en IS NULL
$$;

-- Cantidad reservada de un producto en una bodega: apartados vigentes y sin
-- vencer (menos el que se está completando en esta transacción).
CREATE FUNCTION interno.reservado(p_bodega_id uuid, p_producto_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(l.cantidad), 0)
    FROM public.apartado_linea l JOIN public.apartado a ON a.id = l.apartado_id
   WHERE l.producto_id = p_producto_id AND NOT l.es_servicio AND a.bodega_id = p_bodega_id AND a.estado = 'vigente'
     AND a.vence_el >= public.hoy_local(a.empresa_id)
     AND a.id::text IS DISTINCT FROM nullif(current_setting('app.apartado_en_curso', true), '')
$$;

-- La reserva se respeta: una venta o un traslado no saca lo apartado. Un
-- ajuste por conteo físico sí (refleja la realidad).
CREATE FUNCTION interno.respetar_reserva() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_res numeric;
  v_cod text;
BEGIN
  IF NEW.cantidad < 0 AND NEW.origen IN ('venta', 'traslado') THEN
    v_res := interno.reservado(NEW.bodega_id, NEW.producto_id);
    IF v_res > 0 AND NEW.saldo_cantidad < v_res THEN
      SELECT p.codigo INTO v_cod FROM public.producto p WHERE p.id = NEW.producto_id;
      RAISE EXCEPTION 'EXISTENCIA_RESERVADA: del producto % hay % apartado(s) en esta bodega; quedarían % disponibles.',
        v_cod, v_res, NEW.saldo_cantidad + (-NEW.cantidad) - v_res;
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER respetar_reserva AFTER INSERT ON public.inventario_movimiento
  FOR EACH ROW EXECUTE FUNCTION interno.respetar_reserva();

-- Un anticipo de apartado solo se anula con el apartado vigente (reemplaza el gancho de 033).
CREATE OR REPLACE FUNCTION interno.validar_anulacion_cobro(c public.cobro) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_est text;
BEGIN
  IF c.tipo = 'apartado' THEN
    SELECT a.estado INTO v_est FROM public.apartado a WHERE a.id = c.apartado_id FOR UPDATE;
    IF v_est <> 'vigente' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el apartado de este anticipo ya está %; el anticipo ya se aplicó.', v_est;
    END IF;
  END IF;
END $$;

-- Gancho para 035: una venta con devoluciones no se anula.
CREATE FUNCTION interno.devoluciones_vigentes_venta(p_venta_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT 0::bigint
$$;

-- ---------------------------------------------------------------------
-- 3) Venta: registrar (reemplaza la de 031 con un parámetro más: el apartado
--    que se completa). Formas nuevas: saldo_favor y anticipo.
-- ---------------------------------------------------------------------
DROP FUNCTION interno.registrar_venta_base(uuid, jsonb, uuid, uuid, jsonb);
CREATE FUNCTION interno.registrar_venta_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_cotizacion_id uuid DEFAULT NULL, p_calculo jsonb DEFAULT NULL,
                                             p_apartado_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e        public.empresa;
  v        public.venta;
  v_caja   public.caja;
  v_bod    public.bodega;
  v_cli    public.tercero;
  v_tdoc   text;
  v_fecha  date;
  v_calc   jsonb;
  v_total  bigint;
  pj       jsonb;
  v_forma  text;
  v_monto  bigint;
  v_rec    bigint;
  v_suma   bigint := 0;
  v_cred   bigint := 0;
  v_din    bigint := 0;
  v_ncred  integer := 0;
  v_nant   integer := 0;
  v_norm   jsonb := '[]';
  v_rol    text := public.mi_rol(p_empresa_id);
  v_vend   uuid;
  v_req    text[] := '{}';
  v_td     record;
  v_saldo  bigint;
  v_apr    uuid;
  v_desc   text := '';
  d        public.cuenta_dinero;
  k        integer := 0;
  v_vale   text;
  v_lote   uuid;
  v_sf     bigint;
BEGIN
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cliente_id', 'caja_id', 'bodega_id', 'fecha', 'tipo_documento', 'lineas',
                                               'descuento_factura', 'pagos', 'vendedor_id', 'nota', 'equipo']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;

  v_caja := interno.caja_de_venta(p_empresa_id, p_datos->'caja_id');
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  v_tdoc := interno.json_texto(p_datos->'tipo_documento', 'tipo_documento', 20);
  IF v_tdoc IS NOT NULL AND v_tdoc NOT IN ('factura', 'ticket') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el documento es "factura" o "ticket".';
  END IF;
  IF interno.regimen_fiscal(p_empresa_id) IS NULL THEN
    IF v_tdoc = 'factura' THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: la empresa no tiene un régimen fiscal activo; la venta sale con ticket interno.';
    END IF;
    v_tdoc := 'ticket';
  ELSE
    v_tdoc := coalesce(v_tdoc, CASE e.documento_venta_modo WHEN 'solo_ticket' THEN 'ticket' ELSE 'factura' END);
    IF v_tdoc = 'ticket' AND e.documento_venta_modo = 'solo_factura' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la empresa emite factura en todas sus ventas (el dueño puede permitir tickets internos en Ajustes).';
    END IF;
    IF v_tdoc = 'factura' AND e.documento_venta_modo = 'solo_ticket' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la empresa está configurada para emitir solo tickets internos.';
    END IF;
  END IF;

  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    SELECT * INTO v_cli FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_datos->'cliente_id', 'cliente_id') AND t.empresa_id = p_empresa_id;
    IF v_cli.id IS NULL OR NOT v_cli.es_cliente OR NOT v_cli.activo THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente no existe, no está marcado como cliente o está desactivado.';
    END IF;
  END IF;
  v_vend := coalesce(interno.json_uuid(p_datos->'vendedor_id', 'vendedor_id'), auth.uid());
  IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = v_vend
                   AND ue.activo AND ue.rol NOT IN ('proveedor', 'contador')) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el vendedor no es un usuario activo de la empresa.';
  END IF;

  v_calc := coalesce(p_calculo, interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura'));
  v_total := (v_calc->>'total_centavos')::bigint;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el total de la venta debe ser mayor que cero.';
  END IF;
  IF coalesce((v_calc->>'tiene_bienes')::boolean, true) AND NOT public.modulo_esta_activo(p_empresa_id, 'inventario') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo: esta venta solo puede llevar servicios (quite los productos que son bienes).';
  END IF;
  IF coalesce(p_datos->'bodega_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_bod := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  ELSIF coalesce((v_calc->>'tiene_bienes')::boolean, true) THEN
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa; cree una o indique "bodega_id".';
    END IF;
  END IF;

  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia, crédito o saldo a favor).';
  END IF;
  IF jsonb_array_length(p_datos->'pagos') > 10 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 10 formas de pago por venta.';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    k := k + 1;
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    PERFORM interno.exigir_claves(pj, ARRAY['forma', 'monto_centavos', 'cuenta_dinero_id', 'referencia', 'recibido_centavos',
                                            'vale', 'saldo_favor_id']);
    v_forma := interno.json_texto(pj->'forma', 'forma', 20);
    IF coalesce(v_forma, '') NOT IN ('efectivo', 'tarjeta', 'transferencia', 'credito', 'saldo_favor', 'anticipo') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago es efectivo, tarjeta, transferencia, credito o saldo_favor.';
    END IF;
    IF v_forma = 'anticipo' AND p_apartado_id IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma "anticipo" solo se usa al completar un apartado (completar_apartado).';
    END IF;
    IF coalesce(pj->'monto_centavos', 'null'::jsonb) = 'null'::jsonb THEN
      IF jsonb_array_length(p_datos->'pagos') > 1 THEN
        RAISE EXCEPTION 'PAGO_NO_CUADRA: con varias formas de pago cada una lleva su monto.';
      END IF;
      v_monto := v_total;
    ELSE
      v_monto := interno.json_centavos(pj->'monto_centavos', 'monto_centavos');
    END IF;
    IF v_monto = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada forma de pago lleva un monto mayor que cero.';
    END IF;
    v_rec := NULL;
    IF coalesce(pj->'recibido_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      IF v_forma <> 'efectivo' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "recibido_centavos" (para el vuelto) solo va en efectivo.';
      END IF;
      v_rec := interno.json_centavos(pj->'recibido_centavos', 'recibido_centavos');
      IF v_rec < v_monto THEN
        RAISE EXCEPTION 'DATO_INVALIDO: lo recibido (%) es menos que lo que se cobra en efectivo (%).', interno.lempiras(v_rec), interno.lempiras(v_monto);
      END IF;
    END IF;
    IF v_forma IN ('efectivo', 'credito', 'saldo_favor', 'anticipo') AND coalesce(pj->'cuenta_dinero_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: en % no se indica cuenta (el efectivo entra a la caja de la venta).', v_forma;
    END IF;
    IF v_forma <> 'saldo_favor' AND (pj ? 'vale' OR pj ? 'saldo_favor_id') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "vale" y "saldo_favor_id" solo van con la forma saldo_favor.';
    END IF;
    v_vale := NULL; v_lote := NULL;
    IF v_forma = 'saldo_favor' THEN
      v_vale := upper(interno.json_texto(pj->'vale', 'vale', 20));
      v_lote := interno.json_uuid(pj->'saldo_favor_id', 'saldo_favor_id');
      IF v_vale IS NOT NULL AND v_lote IS NOT NULL THEN
        RAISE EXCEPTION 'DATO_INVALIDO: indique "vale" o "saldo_favor_id", no los dos.';
      END IF;
      IF v_vale IS NULL AND v_lote IS NULL AND v_cli.id IS NULL THEN
        RAISE EXCEPTION 'CLIENTE_REQUERIDO: para pagar con saldo a favor indique el cliente o el código del vale ("vale").';
      END IF;
      -- Revisión previa (se consume al emitir, con el lote bloqueado).
      v_sf := CASE WHEN v_lote IS NOT NULL THEN interno.saldo_favor_lote(v_lote)
                   WHEN v_vale IS NOT NULL THEN (SELECT interno.saldo_favor_lote(s.id) FROM public.saldo_favor s
                                                  WHERE s.empresa_id = p_empresa_id AND s.codigo = v_vale)
                   ELSE interno.saldo_favor_cliente(p_empresa_id, v_cli.id) END;
      IF v_vale IS NOT NULL AND v_sf IS NULL THEN
        RAISE EXCEPTION 'VALE_INVALIDO: el vale % no existe.', v_vale;
      END IF;
      IF coalesce(v_sf, 0) < v_monto THEN
        RAISE EXCEPTION 'SALDO_FAVOR_INSUFICIENTE: el saldo a favor disponible es % y se quieren usar %.', interno.lempiras(coalesce(v_sf, 0)), interno.lempiras(v_monto);
      END IF;
    END IF;
    IF v_forma = 'credito' THEN
      v_ncred := v_ncred + 1;
      v_cred := v_cred + v_monto;
    ELSIF v_forma = 'anticipo' THEN
      v_nant := v_nant + 1;
      IF v_monto <> interno.anticipos_apartado(p_apartado_id) THEN
        RAISE EXCEPTION 'PAGO_NO_CUADRA: el anticipo (%) no es lo abonado al apartado (%).', interno.lempiras(v_monto),
          interno.lempiras(interno.anticipos_apartado(p_apartado_id));
      END IF;
    ELSIF v_forma IN ('efectivo', 'tarjeta', 'transferencia') THEN
      v_din := v_din + v_monto;
    END IF;
    v_suma := v_suma + v_monto;
    v_norm := v_norm || jsonb_build_object('linea', k, 'forma', v_forma, 'monto', v_monto, 'recibido', v_rec,
      'cuenta', interno.json_uuid(pj->'cuenta_dinero_id', 'cuenta_dinero_id'), 'referencia', interno.json_texto(pj->'referencia', 'referencia', 100),
      'vale', v_vale, 'saldo_favor_id', v_lote);
  END LOOP;
  IF v_ncred > 1 OR v_nant > 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el crédito (o el anticipo) va en una sola forma de pago.';
  END IF;
  IF v_suma <> v_total THEN
    RAISE EXCEPTION 'PAGO_NO_CUADRA: las formas de pago suman % y el total de la venta es % (diferencia %).',
      interno.lempiras(v_suma), interno.lempiras(v_total), interno.lempiras(v_suma - v_total);
  END IF;
  IF v_cred > 0 AND v_cli.id IS NULL THEN
    RAISE EXCEPTION 'CLIENTE_REQUERIDO: una venta al crédito necesita cliente (no puede ser Consumidor final).';
  END IF;
  IF v_suma > v_cred AND NOT interno.puede_cobrar(p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.cobrar"; haga una cotización y el cajero la cobra (o el dueño permite que el vendedor cobre).';
  END IF;
  IF v_din > 0 AND NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa (el cobro entra a una cuenta de dinero).';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'venta');
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;

  -- ¿Necesita aprobación? (el dueño no tiene topes; el descuento de un apartado ya se revisó al crearlo)
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    IF p_apartado_id IS NULL AND (v_calc->>'descuento_manual_porcentaje')::numeric > v_td.sin_aprobacion THEN
      v_req := v_req || 'descuento'::text;
      v_desc := 'descuento de ' || (v_calc->>'descuento_manual_porcentaje') || ' % (su tope: ' || v_td.sin_aprobacion || ' %)';
    END IF;
    IF v_cred > 0 THEN
      v_saldo := interno.saldo_cxc_cliente(p_empresa_id, v_cli.id);
      IF e.credito_politica = 'siempre_aprobacion' OR v_cli.limite_credito_centavos = 0
         OR v_saldo + v_cred > v_cli.limite_credito_centavos THEN
        v_req := v_req || 'credito'::text;
        v_desc := v_desc || CASE WHEN v_desc <> '' THEN '; ' ELSE '' END || 'crédito de ' || interno.lempiras(v_cred)
          || CASE WHEN e.credito_politica = 'siempre_aprobacion' THEN ' (todo crédito pide aprobación)'
                  WHEN v_cli.limite_credito_centavos = 0 THEN ' (cliente sin límite de crédito)'
                  ELSE ' (debe ' || interno.lempiras(v_saldo) || ', límite ' || interno.lempiras(v_cli.limite_credito_centavos) || ')' END;
      END IF;
    END IF;
  END IF;

  v.id := gen_random_uuid();
  v.numero := interno.siguiente_numero(p_empresa_id, 'venta');
  IF cardinality(v_req) > 0 THEN
    v_apr := gen_random_uuid();
    INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                   solicitado_por, rol_solicitante)
    VALUES (v_apr, p_empresa_id, interno.siguiente_numero(p_empresa_id, 'aprobacion'), 'venta', 'venta', v.id, v_total,
            'Venta #' || v.numero || ' a ' || coalesce(v_cli.nombre, 'Consumidor final') || ' por ' || interno.lempiras(v_total) || ': ' || v_desc,
            auth.uid(), v_rol);
  END IF;

  INSERT INTO public.venta (id, empresa_id, numero, sucursal_id, caja_id, bodega_id, fecha_contable, tipo_documento,
    emisor_nombre, emisor_rtn, cliente_id, cliente_nombre, cliente_rtn, vendedor_id, cotizacion_id,
    condicion, credito_centavos, plazo_dias,
    descuento_factura_porcentaje, descuento_factura_monto_centavos,
    subtotal_centavos, descuento_centavos, descuento_promocion_centavos, descuento_manual_centavos, descuento_manual_porcentaje,
    gravado_centavos, exento_centavos, exonerado_centavos, impuesto_centavos, desglose_impuestos, total_centavos,
    estado, requiere_aprobacion, aprobacion_id, nota, equipo, id_operacion, creado_por, apartado_id)
  VALUES (v.id, p_empresa_id, v.numero, v_caja.sucursal_id, v_caja.id, v_bod.id, v_fecha, v_tdoc,
    e.nombre, e.rtn, v_cli.id, coalesce(v_cli.nombre, 'Consumidor final'), v_cli.rtn, v_vend, p_cotizacion_id,
    CASE WHEN v_cred > 0 THEN 'credito' ELSE 'contado' END, v_cred, CASE WHEN v_cred > 0 THEN v_cli.plazo_dias END,
    (v_calc->>'descuento_factura_porcentaje')::numeric, (v_calc->>'descuento_factura_monto_centavos')::bigint,
    (v_calc->>'subtotal_centavos')::bigint, (v_calc->>'descuento_centavos')::bigint,
    (v_calc->>'descuento_promocion_centavos')::bigint, (v_calc->>'descuento_manual_centavos')::bigint,
    (v_calc->>'descuento_manual_porcentaje')::numeric,
    (v_calc->>'gravado_centavos')::bigint, (v_calc->>'exento_centavos')::bigint, (v_calc->>'exonerado_centavos')::bigint,
    (v_calc->>'impuesto_centavos')::bigint, v_calc->'desglose_impuestos', v_total,
    CASE WHEN cardinality(v_req) > 0 THEN 'pendiente_aprobacion' ELSE 'por_emitir' END, v_req, v_apr,
    interno.json_texto(p_datos->'nota', 'nota', 500), interno.equipo(p_datos), p_id_operacion, auth.uid(), p_apartado_id)
  RETURNING * INTO v;

  INSERT INTO public.venta_linea (empresa_id, venta_id, linea, producto_id, descripcion, cantidad, precio_unitario_centavos,
    precio_incluye_isv, tipo_impuesto, impuesto_porcentaje, impuesto_clase, es_servicio, costo_estimado_centavos,
    promocion_id, descuento_linea_porcentaje, descuento_linea_monto_centavos,
    bruto_centavos, descuento_promocion_precio_centavos, descuento_linea_centavos, descuento_factura_centavos, neto_centavos,
    subtotal_centavos, descuento_promocion_centavos, descuento_centavos, base_centavos, impuesto_centavos, total_centavos)
  SELECT p_empresa_id, v.id, x.linea, x.producto_id, x.descripcion, x.cantidad, x.precio_unitario_centavos,
         x.precio_incluye_isv, x.tipo_impuesto, x.impuesto_porcentaje, x.impuesto_clase, x.es_servicio, x.costo_estimado_centavos,
         x.promocion_id, x.descuento_linea_porcentaje, x.descuento_linea_monto_centavos,
         x.bruto_centavos, x.descuento_promocion_precio_centavos, x.descuento_linea_centavos, x.descuento_factura_centavos,
         x.neto_centavos, x.subtotal_centavos, x.descuento_promocion_centavos, x.descuento_centavos, x.base_centavos,
         x.impuesto_centavos, x.total_centavos
    FROM jsonb_to_recordset(v_calc->'lineas') AS x(linea smallint, producto_id uuid, descripcion text, cantidad numeric,
         precio_unitario_centavos bigint, precio_incluye_isv boolean, tipo_impuesto text, impuesto_porcentaje numeric,
         impuesto_clase text, es_servicio boolean, costo_estimado_centavos bigint, promocion_id uuid,
         descuento_linea_porcentaje numeric, descuento_linea_monto_centavos bigint, bruto_centavos bigint,
         descuento_promocion_precio_centavos bigint, descuento_linea_centavos bigint, descuento_factura_centavos bigint,
         neto_centavos bigint, subtotal_centavos bigint, descuento_promocion_centavos bigint, descuento_centavos bigint,
         base_centavos bigint, impuesto_centavos bigint, total_centavos bigint);

  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    d := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(p_empresa_id, v_caja.id);
    ELSIF pj->>'forma' IN ('tarjeta', 'transferencia') THEN
      d := interno.cuenta_cobro_venta(p_empresa_id, pj->>'forma', (pj->>'cuenta')::uuid);
    END IF;
    INSERT INTO public.venta_pago (empresa_id, venta_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos, estado_transferencia, vale, saldo_favor_id)
    VALUES (p_empresa_id, v.id, (pj->>'linea')::smallint, pj->>'forma', (pj->>'monto')::bigint, d.id,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta(d.id) END, pj->>'referencia',
            (pj->>'recibido')::bigint, (pj->>'recibido')::bigint - (pj->>'monto')::bigint,
            CASE WHEN pj->>'forma' = 'transferencia' THEN 'por_confirmar' END, pj->>'vale', (pj->>'saldo_favor_id')::uuid);
  END LOOP;

  IF v.estado = 'por_emitir' THEN
    v := interno.emitir_venta(v.id, v_fecha, p_id_operacion);
  END IF;
  RETURN interno.venta_respuesta(v, false);
END $$;

-- ---------------------------------------------------------------------
-- 4) Emitir (reemplaza la de 028; misma firma): saldo a favor y anticipo;
--    al final revisa las comisiones (036).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.emitir_venta(p_venta_id uuid, p_fecha date, p_id_operacion uuid) RETURNS public.venta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v      public.venta;
  pg     public.venta_pago;
  ln     public.venta_linea;
  m      public.inventario_movimiento;
  rf     record;
  v_num  text;
  v_reg  text;
  v_fis  jsonb;
  v_cost bigint := 0;
  v_neg  boolean;
  v_lin  jsonb := '[]';
  v_asto uuid;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  PERFORM interno.exigir_periodo_abierto(v.empresa_id, p_fecha);
  IF NOT EXISTS (SELECT 1 FROM public.caja c JOIN public.sucursal s ON s.id = c.sucursal_id
                  WHERE c.id = v.caja_id AND c.activa AND s.activa) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja de la venta está desactivada (ella o su sucursal).';
  END IF;

  FOR pg IN SELECT * FROM public.venta_pago x WHERE x.venta_id = v.id ORDER BY x.linea LOOP
    IF pg.forma = 'credito' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'cxc', 'debe', pg.monto_centavos, 'descripcion', 'Venta al crédito: ' || v.cliente_nombre);
      CONTINUE;
    ELSIF pg.forma = 'saldo_favor' THEN
      IF pg.saldo_favor_id IS NOT NULL THEN
        PERFORM interno.usar_saldo_favor_lote(pg.saldo_favor_id, pg.monto_centavos, 'venta', v.id, p_fecha);
      ELSE
        PERFORM interno.usar_saldo_favor(v.empresa_id, v.cliente_id, pg.vale, pg.monto_centavos, 'venta', v.id, p_fecha);
      END IF;
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'debe', pg.monto_centavos,
                                           'descripcion', 'Pagado con saldo a favor' || coalesce(' (vale ' || pg.vale || ')', ''));
      CONTINUE;
    ELSIF pg.forma = 'anticipo' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'anticipo_clientes', 'debe', pg.monto_centavos, 'descripcion', 'Anticipos del apartado aplicados');
      CONTINUE;
    END IF;
    PERFORM interno.cuenta_dinero_de(v.empresa_id, pg.cuenta_dinero_id);
    IF pg.forma = 'efectivo' THEN
      IF pg.turno_id IS NOT NULL AND interno.turno_de_cuenta(pg.cuenta_dinero_id) IS DISTINCT FROM pg.turno_id THEN
        RAISE EXCEPTION 'TURNO_CERRADO: el turno de caja en que se iba a cobrar la venta #% ya se cerró; regístrela otra vez en un turno abierto.', v.numero;
      ELSIF pg.turno_id IS NULL AND interno.turno_de_cuenta(pg.cuenta_dinero_id) IS NOT NULL THEN
        RAISE EXCEPTION 'CAJA_OCUPADA: la caja de la venta #% tiene ahora abierto el turno de un cajero; regístrela otra vez en ese turno.', v.numero;
      ELSIF pg.turno_id IS NULL AND coalesce((SELECT e.turnos_obligatorios FROM public.empresa e WHERE e.id = v.empresa_id), true) THEN
        RAISE EXCEPTION 'SIN_TURNO_ABIERTO: la empresa exige turno de caja para cobrar en efectivo.';
      END IF;
    END IF;
    v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(pg.cuenta_dinero_id),
                                         'debe', pg.monto_centavos, 'descripcion', 'Cobro de la venta (' || pg.forma || ')');
  END LOOP;

  IF v.tipo_documento = 'factura' THEN
    SELECT * INTO rf FROM interno.numero_fiscal(v.empresa_id, v.caja_id, 'factura', p_fecha);
    v_num := rf.o_numero;
    v_fis := rf.o_datos;
    v_reg := v_fis->>'regimen';
  ELSE
    v_num := interno.siguiente_ticket(v.empresa_id, v.caja_id);
  END IF;

  v_neg := interno.permite_negativo(v.empresa_id);
  FOR ln IN SELECT * FROM public.venta_linea x WHERE x.venta_id = v.id ORDER BY x.linea LOOP
    IF ln.es_servicio THEN
      UPDATE public.venta_linea SET costo_centavos = 0 WHERE id = ln.id;
      CONTINUE;
    END IF;
    m := interno.mover_inventario(v.empresa_id, v.bodega_id, ln.producto_id, 'salida', 'venta', p_fecha, -ln.cantidad, NULL,
                                  'venta', v.id, p_id_operacion, 'Venta ' || v_num, v_neg);
    UPDATE public.venta_linea SET costo_centavos = -m.valor_centavos, movimiento_id = m.id WHERE id = ln.id;
    v_cost := v_cost - m.valor_centavos;
  END LOOP;

  v_lin := v_lin || jsonb_build_array(
    jsonb_build_object('uso', 'descuento_ventas', 'debe',  v.descuento_centavos, 'descripcion', 'Descuentos sobre ventas'),
    jsonb_build_object('uso', 'ventas',           'haber', v.subtotal_centavos,  'descripcion', 'Ventas (precio sin impuesto)'),
    jsonb_build_object('uso', 'costo_ventas',     'debe',  v_cost,               'descripcion', 'Costo de lo vendido'),
    jsonb_build_object('uso', 'inventario',       'haber', v_cost,               'descripcion', 'Salida de inventario por venta'));
  v_lin := v_lin || coalesce((SELECT jsonb_agg(jsonb_build_object('cuenta', d->>'cuenta_por_pagar',
                                 'haber', (d->>'impuesto_centavos')::bigint, 'descripcion', 'Impuesto ' || (d->>'nombre')))
                                FROM jsonb_array_elements(v.desglose_impuestos) d
                               WHERE (d->>'impuesto_centavos')::bigint > 0), '[]');
  v_asto := interno.asiento_sistema(v.empresa_id, interno.sucursal_activa(v.sucursal_id), p_fecha,
    'Venta ' || v.tipo_documento || ' ' || v_num || ' a ' || v.cliente_nombre, 'venta', p_id_operacion, v_lin);

  UPDATE public.venta
     SET estado = 'emitida', fecha_contable = p_fecha, numero_documento = v_num, regimen_fiscal = v_reg, datos_fiscales = v_fis,
         vence_el = CASE WHEN v.credito_centavos > 0 THEN p_fecha + v.plazo_dias END,
         asiento_id = v_asto, costo_centavos = v_cost, emitida_en = now(), emitida_por = auth.uid()
   WHERE id = v.id
  RETURNING * INTO v;
  PERFORM interno.rastrear_dinero(v_asto, 'venta', 'venta', v.id, v_num, v.equipo);
  PERFORM interno.recalcular_comision(v.id, p_id_operacion, p_fecha);
  RETURN v;
END $$;

-- ---------------------------------------------------------------------
-- 5) Anular una venta (reemplaza la de 028; misma firma): saldo a favor y
--    anticipo; sin devoluciones vigentes; comisiones.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.anular_venta_base(p_venta_id uuid, p_fecha date, p_motivo text, p_id_operacion uuid,
                                                     p_solicitud_id uuid) RETURNS public.venta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v      public.venta;
  ln     public.venta_linea;
  pg     public.venta_pago;
  v_lin  jsonb := '[]';
  v_asto uuid;
  v_cta  uuid;
  v_ant  bigint := 0;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  IF interno.devoluciones_vigentes_venta(v.id) > 0 THEN
    RAISE EXCEPTION 'VENTA_CON_DEVOLUCIONES: la venta % tiene devoluciones (notas de crédito); ya no se anula completa.', v.numero_documento;
  END IF;
  PERFORM interno.exigir_periodo_abierto(v.empresa_id, v.fecha_contable);
  PERFORM interno.exigir_periodo_abierto(v.empresa_id, p_fecha);
  FOR ln IN SELECT * FROM public.venta_linea x WHERE x.venta_id = v.id AND NOT x.es_servicio ORDER BY x.linea LOOP
    PERFORM interno.mover_inventario(v.empresa_id, v.bodega_id, ln.producto_id, 'entrada', 'anulacion_venta', p_fecha,
                                     ln.cantidad, ln.costo_centavos, 'venta', v.id, p_id_operacion,
                                     'Anulación venta ' || v.numero_documento || ': ' || p_motivo, false);
  END LOOP;
  FOR pg IN SELECT * FROM public.venta_pago x WHERE x.venta_id = v.id ORDER BY x.linea LOOP
    IF pg.forma = 'credito' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'cxc', 'haber', pg.monto_centavos, 'descripcion', 'Reversión del crédito');
    ELSIF pg.forma = 'saldo_favor' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos, 'descripcion', 'Vuelve el saldo a favor usado');
    ELSIF pg.forma = 'anticipo' THEN
      v_ant := v_ant + pg.monto_centavos;
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos,
                                           'descripcion', 'El anticipo del apartado queda a favor del cliente');
    ELSE
      v_cta := CASE WHEN pg.estado_transferencia = 'confirmada' THEN pg.banco_id ELSE pg.cuenta_dinero_id END;
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(v_cta),
                                           'haber', pg.monto_centavos, 'descripcion', 'Devolución del cobro (' || pg.forma || ')');
    END IF;
  END LOOP;
  v_lin := v_lin || jsonb_build_array(
    jsonb_build_object('uso', 'ventas',           'debe',  v.subtotal_centavos,  'descripcion', 'Reversión de ventas'),
    jsonb_build_object('uso', 'descuento_ventas', 'haber', v.descuento_centavos, 'descripcion', 'Reversión de descuentos'),
    jsonb_build_object('uso', 'inventario',       'debe',  v.costo_centavos,     'descripcion', 'Mercadería devuelta al inventario'),
    jsonb_build_object('uso', 'costo_ventas',     'haber', v.costo_centavos,     'descripcion', 'Reversión del costo'));
  v_lin := v_lin || coalesce((SELECT jsonb_agg(jsonb_build_object('cuenta', d->>'cuenta_por_pagar',
                                 'debe', (d->>'impuesto_centavos')::bigint, 'descripcion', 'Reversión impuesto ' || (d->>'nombre')))
                                FROM jsonb_array_elements(v.desglose_impuestos) d
                               WHERE (d->>'impuesto_centavos')::bigint > 0), '[]');
  v_asto := interno.asiento_sistema(v.empresa_id, v.sucursal_id, p_fecha,
    'ANULACIÓN venta ' || v.numero_documento || ': ' || p_motivo, 'anulacion_venta', p_id_operacion, v_lin,
    v.asiento_id, p_motivo);
  PERFORM set_config('app.motivo', p_motivo, true);
  PERFORM interno.devolver_usos_saldo_favor(v.id, 'Anulación de la venta ' || v.numero_documento);
  IF v_ant > 0 THEN
    PERFORM interno.crear_saldo_favor(v.empresa_id, v.cliente_id, 'anulacion_venta', 'venta', v.id, v_ant, p_fecha);
  END IF;
  UPDATE public.venta
     SET estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = p_motivo, fecha_anulacion = p_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion, anulacion_solicitud_id = p_solicitud_id
   WHERE id = v.id
  RETURNING * INTO v;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_venta', 'venta', v.id, p_motivo, NULL);
  PERFORM interno.recalcular_comision(v.id, p_id_operacion, p_fecha);
  RETURN v;
END $$;

-- Pedir la anulación de una venta con devoluciones: no (aviso temprano).
CREATE FUNCTION interno.anulacion_sin_devoluciones() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF interno.devoluciones_vigentes_venta(NEW.venta_id) > 0 THEN
    RAISE EXCEPTION 'VENTA_CON_DEVOLUCIONES: la venta tiene devoluciones (notas de crédito); ya no se anula completa.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER sin_devoluciones BEFORE INSERT ON public.venta_anulacion
  FOR EACH ROW EXECUTE FUNCTION interno.anulacion_sin_devoluciones();

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('VENTA_CON_DEVOLUCIONES', 'La venta ya tiene devoluciones.',
   'Una venta con nota de crédito no se anula completa: devuelva lo que falta con otra devolución.');

-- ---------------------------------------------------------------------
-- 6) RPC de apartados
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.apartado_respuesta(a public.apartado, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('apartado_id', a.id, 'numero', a.numero, 'estado', a.estado, 'cliente_id', a.cliente_id,
    'fecha', to_char(a.fecha, 'YYYY-MM-DD'), 'vence_el', to_char(a.vence_el, 'YYYY-MM-DD'),
    'vencido', a.estado = 'vigente' AND a.vence_el < public.hoy_local(a.empresa_id),
    'total_centavos', a.total_centavos, 'anticipos_centavos', interno.anticipos_apartado(a.id),
    'saldo_centavos', CASE WHEN a.estado = 'vigente' THEN a.total_centavos - interno.anticipos_apartado(a.id) ELSE 0 END,
    'venta_id', a.venta_id, 'destino_anticipo', a.destino_anticipo, 'anticipo_devuelto_centavos', a.anticipo_devuelto_centavos,
    'saldo_favor_id', a.saldo_favor_id, 'duplicado', p_duplicado)
$$;

-- crear_apartado(empresa, datos, id_operacion)   apartados.registrar
-- datos = {"cliente_id":"...","lineas":[...como en la venta...],"descuento_factura":{...},
--          "pagos":[...anticipo inicial, como en registrar_cobro...],"caja_id","bodega_id","fecha",
--          "vence_el" (defecto: fecha + empresa.apartado_dias_vigencia),"referencia","nota","equipo"}
CREATE FUNCTION public.crear_apartado(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.apartado;
  e       public.empresa;
  v_cli   public.tercero;
  v_caja  public.caja;
  v_bod   public.bodega;
  v_fecha date;
  v_vence date;
  v_calc  jsonb;
  v_rol   text := public.mi_rol(p_empresa_id);
  v_td    record;
  l       jsonb;
  v_disp  numeric;
  v_cod   text;
  r       jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'apartados.registrar', 'apartados');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'apartado');
  SELECT * INTO a FROM public.apartado x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF a.id IS NOT NULL THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cliente_id', 'lineas', 'descuento_factura', 'pagos', 'caja_id', 'bodega_id',
                                               'fecha', 'vence_el', 'referencia', 'nota', 'equipo']);
  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) = 'null'::jsonb THEN
    RAISE EXCEPTION 'CLIENTE_REQUERIDO: un apartado siempre lleva cliente.';
  END IF;
  v_cli := interno.cliente_de(p_empresa_id, p_datos->'cliente_id', true);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  v_caja := interno.caja_de_venta(p_empresa_id, p_datos->'caja_id');
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  v_vence := coalesce(interno.json_fecha(p_datos->'vence_el', 'vence_el'), v_fecha + e.apartado_dias_vigencia);
  IF v_vence < v_fecha OR v_vence > v_fecha + 365 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el vencimiento del apartado va desde su fecha hasta un año después.';
  END IF;
  IF coalesce(p_datos->'bodega_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_bod := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  ELSE
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa; indique "bodega_id".';
    END IF;
  END IF;
  v_calc := interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura');
  IF NOT coalesce((v_calc->>'tiene_bienes')::boolean, false) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un apartado reserva mercadería; lleva al menos un producto (bien).';
  END IF;
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    IF (v_calc->>'descuento_manual_porcentaje')::numeric > v_td.sin_aprobacion THEN
      RAISE EXCEPTION 'APROBACION_REQUERIDA: el descuento del apartado (% %%) pasa su tope (% %%); que lo haga quien pueda darlo.',
        v_calc->>'descuento_manual_porcentaje', v_td.sin_aprobacion;
    END IF;
  END IF;
  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el apartado necesita un anticipo ("pagos").';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'apartado');
  SELECT * INTO a FROM public.apartado x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF a.id IS NOT NULL THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  -- Disponible = existencia - lo ya apartado (con el candado).
  FOR l IN SELECT * FROM jsonb_array_elements(v_calc->'lineas') LOOP
    CONTINUE WHEN (l->>'es_servicio')::boolean;
    PERFORM interno.bloquear_saldo(p_empresa_id, v_bod.id, (l->>'producto_id')::uuid);
    v_disp := coalesce((SELECT s.cantidad FROM public.inventario_saldo s WHERE s.bodega_id = v_bod.id AND s.producto_id = (l->>'producto_id')::uuid), 0)
              - interno.reservado(v_bod.id, (l->>'producto_id')::uuid)
              - coalesce((SELECT sum((y->>'cantidad')::numeric) FROM jsonb_array_elements(v_calc->'lineas') y
                           WHERE y->>'producto_id' = l->>'producto_id' AND (y->>'linea')::int < (l->>'linea')::int), 0);
    IF v_disp < (l->>'cantidad')::numeric THEN
      SELECT p.codigo INTO v_cod FROM public.producto p WHERE p.id = (l->>'producto_id')::uuid;
      RAISE EXCEPTION 'EXISTENCIA_INSUFICIENTE: del producto % hay % disponibles para apartar y se piden %.', v_cod, greatest(v_disp, 0), l->>'cantidad';
    END IF;
  END LOOP;

  a.id := gen_random_uuid();
  INSERT INTO public.apartado (id, empresa_id, numero, cliente_id, vendedor_id, caja_id, sucursal_id, bodega_id, fecha, vence_el,
    entrada, calculo, subtotal_centavos, descuento_centavos, impuesto_centavos, total_centavos, nota, equipo, id_operacion, creado_por)
  VALUES (a.id, p_empresa_id, interno.siguiente_numero(p_empresa_id, 'apartado'), v_cli.id, auth.uid(), v_caja.id, v_caja.sucursal_id,
    v_bod.id, v_fecha, v_vence, jsonb_build_object('lineas', p_datos->'lineas', 'descuento_factura', p_datos->'descuento_factura'),
    v_calc, (v_calc->>'subtotal_centavos')::bigint, (v_calc->>'descuento_centavos')::bigint, (v_calc->>'impuesto_centavos')::bigint,
    (v_calc->>'total_centavos')::bigint, interno.json_texto(p_datos->'nota', 'nota', 500), interno.equipo(p_datos), p_id_operacion, auth.uid())
  RETURNING * INTO a;
  INSERT INTO public.apartado_linea (empresa_id, apartado_id, linea, producto_id, cantidad, es_servicio)
  SELECT p_empresa_id, a.id, (y->>'linea')::smallint, (y->>'producto_id')::uuid, (y->>'cantidad')::numeric, (y->>'es_servicio')::boolean
    FROM jsonb_array_elements(v_calc->'lineas') y;
  -- Anticipo inicial: un cobro tipo "apartado" (su propio id_operacion, derivado).
  r := interno.registrar_cobro_base(p_empresa_id,
         jsonb_strip_nulls(jsonb_build_object('cliente_id', v_cli.id, 'pagos', p_datos->'pagos', 'caja_id', v_caja.id, 'fecha', v_fecha,
                                              'referencia', coalesce(p_datos->>'referencia', 'Apartado #' || a.numero),
                                              'equipo', p_datos->'equipo')),
         md5(p_id_operacion::text || ':anticipo')::uuid, a.id, a.total_centavos);
  RETURN interno.apartado_respuesta(a, false) || jsonb_build_object('cobro_id', r->'cobro_id', 'vuelto_centavos', r->'vuelto_centavos');
END $$;

-- abonar_apartado(apartado, datos, id_operacion)   apartados.registrar
-- datos = {"pagos":[...],"caja_id","fecha","referencia","equipo"}: un cobro tipo apartado.
CREATE FUNCTION public.abonar_apartado(p_apartado_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a  public.apartado;
  r  jsonb;
BEGIN
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el apartado no existe.';
  END IF;
  PERFORM interno.exigir_escritura(a.empresa_id, 'apartados.registrar', 'apartados');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'cobro');
  PERFORM interno.exigir_claves(p_datos, ARRAY['pagos', 'caja_id', 'fecha', 'referencia', 'equipo']);
  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'cobro');
  IF NOT EXISTS (SELECT 1 FROM public.cobro c WHERE c.empresa_id = a.empresa_id AND c.id_operacion = p_id_operacion) THEN
    SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id FOR UPDATE;
    IF a.estado <> 'vigente' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el apartado #% ya está %.', a.numero, a.estado;
    END IF;
  END IF;
  r := interno.registrar_cobro_base(a.empresa_id, p_datos || jsonb_build_object('cliente_id', a.cliente_id), p_id_operacion,
                                    a.id, a.total_centavos - interno.anticipos_apartado(a.id));
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id;
  RETURN interno.apartado_respuesta(a, (r->>'duplicado')::boolean) || jsonb_build_object('cobro_id', r->'cobro_id', 'vuelto_centavos', r->'vuelto_centavos');
END $$;

-- completar_apartado(apartado, datos, id_operacion)   apartados.registrar (+ cobrar)
-- datos = {"pagos":[...lo que falta...],"caja_id","tipo_documento","fecha","nota","equipo"}
-- Se convierte en VENTA con los precios del apartado y los anticipos aplicados.
CREATE FUNCTION public.completar_apartado(p_apartado_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.apartado;
  v       public.venta;
  v_ant   bigint;
  v_pagos jsonb;
  r       jsonb;
BEGIN
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el apartado no existe.';
  END IF;
  PERFORM interno.exigir_escritura(a.empresa_id, 'apartados.registrar', 'apartados');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'venta');
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = a.empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.ocultar_costos(a.empresa_id, interno.venta_respuesta(v, true), ARRAY['costo_centavos']) || jsonb_build_object('apartado_id', a.id);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['pagos', 'caja_id', 'tipo_documento', 'fecha', 'nota', 'equipo']);

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'venta');
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id FOR UPDATE;
  IF a.estado <> 'vigente' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el apartado #% ya está %.', a.numero, a.estado;
  END IF;
  v_ant := interno.anticipos_apartado(a.id);
  v_pagos := coalesce(p_datos->'pagos', '[]'::jsonb);
  IF jsonb_typeof(v_pagos) <> 'array' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "pagos" es una lista.';
  END IF;
  IF v_ant > 0 THEN
    v_pagos := jsonb_build_array(jsonb_build_object('forma', 'anticipo', 'monto_centavos', v_ant)) || v_pagos;
  END IF;
  -- Lo de este apartado deja de estar reservado (para poder venderlo).
  PERFORM set_config('app.apartado_en_curso', a.id::text, true);
  r := interno.registrar_venta_base(a.empresa_id,
         jsonb_strip_nulls(jsonb_build_object('cliente_id', a.cliente_id, 'lineas', a.entrada->'lineas',
           'descuento_factura', a.entrada->'descuento_factura', 'vendedor_id', a.vendedor_id, 'bodega_id', a.bodega_id,
           -- Caja: la indicada; si no, la del turno abierto de quien cobra; si no, la del apartado.
           'caja_id', coalesce(p_datos->'caja_id',
                               CASE WHEN NOT EXISTS (SELECT 1 FROM public.turno_caja t WHERE t.empresa_id = a.empresa_id
                                                       AND t.cajero_id = auth.uid() AND t.estado = 'abierto')
                                    THEN to_jsonb(a.caja_id) END),
           'tipo_documento', p_datos->'tipo_documento',
           'fecha', p_datos->'fecha', 'nota', coalesce(p_datos->>'nota', 'Apartado #' || a.numero), 'equipo', p_datos->'equipo',
           'pagos', v_pagos)),
         p_id_operacion, NULL, a.calculo, a.id);
  PERFORM set_config('app.apartado_en_curso', '', true);
  IF r->>'estado' <> 'emitida' THEN
    RAISE EXCEPTION 'APROBACION_REQUERIDA: la venta del apartado necesita aprobación (%); complete el apartado con otra forma de pago o pida que lo complete quien aprueba.',
      r->'requiere_aprobacion';
  END IF;
  UPDATE public.apartado SET estado = 'completado', venta_id = (r->>'venta_id')::uuid, completado_en = now(), completado_por = auth.uid(),
         completado_id_operacion = p_id_operacion
   WHERE id = a.id;
  RETURN interno.ocultar_costos(a.empresa_id, r, ARRAY['costo_centavos']) || jsonb_build_object('apartado_id', a.id, 'anticipo_aplicado_centavos', v_ant);
END $$;

-- cancelar_apartado(apartado, motivo, datos, id_operacion)   apartados.cancelar
-- datos = {"destino":"saldo_favor"|"devolver" (si la empresa deja elegir),
--          "cuenta_dinero_id":"..." (devolver: de dónde sale), "fecha", "referencia", "equipo"}
CREATE FUNCTION public.cancelar_apartado(p_apartado_id uuid, p_motivo text, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.apartado;
  e       public.empresa;
  v_dest  text;
  v_ant   bigint;
  v_fecha date;
  d       public.cuenta_dinero;
  f       public.saldo_favor;
  v_asto  uuid;
BEGIN
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el apartado no existe.';
  END IF;
  PERFORM interno.exigir_escritura(a.empresa_id, 'apartados.cancelar', 'apartados');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'cancelacion_apartado');
  IF a.cancelacion_id_operacion = p_id_operacion THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  p_datos := coalesce(p_datos, '{}'::jsonb);
  PERFORM interno.exigir_claves(p_datos, ARRAY['destino', 'cuenta_dinero_id', 'fecha', 'referencia', 'equipo']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se cancela el apartado (mínimo 5 letras).';
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = a.empresa_id;
  v_dest := interno.json_texto(p_datos->'destino', 'destino', 20);
  IF v_dest IS NOT NULL AND v_dest NOT IN ('saldo_favor', 'devolver') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el destino del anticipo es "saldo_favor" o "devolver".';
  END IF;
  IF e.apartado_cancelacion = 'elegir' THEN
    IF v_dest IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique qué pasa con el anticipo ("destino": "saldo_favor" o "devolver").';
    END IF;
  ELSIF v_dest IS NOT NULL AND v_dest <> e.apartado_cancelacion THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el dueño configuró que al cancelar un apartado el anticipo %.',
      CASE e.apartado_cancelacion WHEN 'saldo_favor' THEN 'queda como saldo a favor del cliente' ELSE 'se devuelve' END;
  ELSE
    v_dest := e.apartado_cancelacion;
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), greatest(public.hoy_local(a.empresa_id), a.fecha));
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_dest = 'devolver' THEN
    IF NOT public.modulo_esta_activo(a.empresa_id, 'dinero') THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo; el anticipo solo puede quedar como saldo a favor.';
    END IF;
    d := interno.cuenta_dinero_para_pagar(a.empresa_id, interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id'));
  ELSIF p_datos ? 'cuenta_dinero_id' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de dinero solo va cuando el anticipo se devuelve.';
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'cancelacion_apartado');
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id FOR UPDATE;
  IF a.cancelacion_id_operacion = p_id_operacion THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  IF a.estado <> 'vigente' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el apartado #% ya está %.', a.numero, a.estado;
  END IF;
  v_ant := interno.anticipos_apartado(a.id);
  IF v_ant > 0 THEN
    PERFORM interno.exigir_periodo_abierto(a.empresa_id, v_fecha);
    IF v_dest = 'saldo_favor' THEN
      f := interno.crear_saldo_favor(a.empresa_id, a.cliente_id, 'apartado_cancelado', 'apartado', a.id, v_ant, v_fecha);
    END IF;
    v_asto := interno.asiento_sistema(a.empresa_id, interno.sucursal_activa(a.sucursal_id), v_fecha,
      'Cancelación del apartado #' || a.numero || ': ' || trim(p_motivo), 'cancelacion_apartado', p_id_operacion,
      jsonb_build_array(
        jsonb_build_object('uso', 'anticipo_clientes', 'debe', v_ant, 'descripcion', 'Se libera el anticipo'),
        CASE WHEN v_dest = 'saldo_favor' THEN jsonb_build_object('uso', 'saldo_favor', 'haber', v_ant, 'descripcion', 'Queda a favor del cliente')
             ELSE jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'haber', v_ant, 'descripcion', 'Devolución del anticipo') END));
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.apartado
     SET estado = 'cancelado', cancelado_en = now(), cancelado_por = auth.uid(), motivo_cancelacion = trim(p_motivo),
         destino_anticipo = v_dest, anticipo_devuelto_centavos = v_ant, cuenta_devolucion_id = d.id, saldo_favor_id = f.id,
         asiento_cancelacion_id = v_asto, cancelacion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'cancelacion_apartado', 'apartado', a.id,
                                  coalesce(interno.json_texto(p_datos->'referencia', 'referencia', 100), 'Apartado #' || a.numero),
                                  interno.equipo(p_datos));
  RETURN interno.apartado_respuesta(a, false);
END $$;

-- Lecturas: apartados con su estado (vencido calculado), anticipos y saldo.
CREATE VIEW public.v_apartado AS
  SELECT a.empresa_id, a.id AS apartado_id, a.numero, a.cliente_id, t.nombre AS cliente, a.vendedor_id,
         public.nombre_usuario(a.empresa_id, a.vendedor_id) AS vendedor, a.bodega_id, a.fecha, a.vence_el,
         CASE WHEN a.estado = 'vigente' AND a.vence_el < public.hoy_local(a.empresa_id) THEN 'vencido' ELSE a.estado END AS estado,
         a.total_centavos, x.anticipos AS anticipos_centavos,
         CASE WHEN a.estado = 'vigente' THEN a.total_centavos - x.anticipos ELSE 0 END AS saldo_centavos,
         a.calculo->'lineas' AS lineas, a.venta_id, a.destino_anticipo, a.anticipo_devuelto_centavos, a.motivo_cancelacion,
         a.registrado_en
  FROM public.apartado a
  JOIN public.tercero t ON t.id = a.cliente_id
  CROSS JOIN LATERAL (SELECT coalesce(sum(c.aplicado_centavos), 0)::bigint AS anticipos FROM public.cobro c
                       WHERE c.apartado_id = a.id AND c.anulada_en IS NULL) x
  WHERE a.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
     OR a.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('apartados.registrar')));
GRANT SELECT ON public.v_apartado TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 7) id_operacion, módulo apagado y seguridad
-- ---------------------------------------------------------------------
INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('apartado', 'id_operacion',             'apartado',             20),
  ('apartado', 'cancelacion_id_operacion', 'cancelacion_apartado', 21);
INSERT INTO interno.modulo_apagado_permite (modulo, funcion, motivo) VALUES
  ('apartados', 'public.cancelar_apartado', 'Cancelar un apartado (libera la mercadería y resuelve el anticipo).');

REVOKE EXECUTE ON FUNCTION
  interno.usar_saldo_favor_lote(uuid, bigint, text, uuid, date),
  interno.proteger_apartado(),
  interno.anticipos_apartado(uuid),
  interno.reservado(uuid, uuid),
  interno.respetar_reserva(),
  interno.devoluciones_vigentes_venta(uuid),
  interno.registrar_venta_base(uuid, jsonb, uuid, uuid, jsonb, uuid),
  interno.anulacion_sin_devoluciones(),
  interno.apartado_respuesta(public.apartado, boolean)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.crear_apartado(uuid, jsonb, uuid),
  public.abonar_apartado(uuid, jsonb, uuid),
  public.completar_apartado(uuid, jsonb, uuid),
  public.cancelar_apartado(uuid, text, jsonb, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_apartado(uuid, jsonb, uuid),
  public.abonar_apartado(uuid, jsonb, uuid),
  public.completar_apartado(uuid, jsonb, uuid),
  public.cancelar_apartado(uuid, text, jsonb, uuid)
TO authenticated;
