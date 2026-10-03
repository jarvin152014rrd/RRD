-- =====================================================================
-- 033_cobros_saldo_favor.sql  -  Núcleo 0.9.0 (etapa 2b-2b): cobros a
-- clientes, saldos iniciales de CxC, saldo a favor / vales y condonación.
--
--   cxc_saldo_inicial   facturas que los clientes ya debían al empezar
--                       (Dr Clientes / Cr Saldos de apertura). Se cobran
--                       igual que una venta al crédito; se anulan sin cobros.
--   cxc_aplicacion      TODO lo que rebaja una factura por cobrar (cobro,
--                       condonación y, en 035, devolución). El saldo de una
--                       factura = monto - aplicaciones vigentes (no anuladas).
--   cobro / cobro_pago  un cobro a un cliente: a una factura o consolidado a
--                       varias (la más vieja primero o las elegidas); formas
--                       de pago como en ventas (efectivo con turno según la
--                       empresa, tarjeta, transferencia por confirmar, mixto)
--                       y también su saldo a favor. Nunca se cobra más del
--                       saldo sin decisión: el excedente pasa a SALDO A FAVOR
--                       del cliente solo si se pide ("excedente":"saldo_favor").
--                       Tipo "anticipo": todo el dinero queda como saldo a favor.
--   anular_cobro        patrón "anular un abono" (CONVENCIONES): motivo,
--                       contra-asiento, el dinero sale de la MISMA cuenta,
--                       los saldos se restauran.
--   cxc_condonacion     perdonar un saldo (redondeo) NUNCA en silencio:
--                       operación aparte con permiso cobros.condonar y motivo
--                       (Dr Saldos condonados / Cr Clientes). Se puede anular.
--   saldo_favor         cada saldo a favor es un "lote" (pasivo 2.1.04.02):
--                       del cliente, o VALE sin cliente con código único y
--                       vencimiento opcional (empresa.vale_dias_vigencia).
--                       saldo_favor_uso: cada vez que se usa (venta, cobro).
--                       Saldo del lote = monto - usos vigentes.
-- Asiento de un cobro:
--   Dr caja / POS por liquidar / transferencias por confirmar (lo recibido)
--   Dr Saldos a favor (si paga con su saldo a favor)
--   Cr Clientes (lo aplicado a facturas)  Cr Saldos a favor (el excedente)
-- Ganchos: interno.cobros_vigentes_venta (la venta con cobros o condonaciones
-- no se anula), interno.recalcular_comision (036), apartados (034).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('COBRO_EXCEDE_SALDO', 'El cobro es mayor que lo que el cliente debe.',
   'Cobre solo el saldo o indique que el excedente quede como saldo a favor del cliente ("excedente": "saldo_favor").'),
  ('SALDO_FAVOR_INSUFICIENTE', 'El saldo a favor no alcanza.',
   'Revise el saldo a favor del cliente o del vale y cobre la diferencia con otra forma de pago.'),
  ('VALE_INVALIDO', 'El vale no existe, está anulado o ya se usó completo.',
   'Revise el código del vale (está impreso en la nota de crédito).'),
  ('VALE_VENCIDO', 'El vale ya venció.',
   'Un vale vencido no se puede usar. Si el dueño decide aceptarlo, debe registrarse aparte.'),
  ('SALDO_FAVOR_USADO', 'Ese saldo a favor ya se usó.',
   'Anule primero la venta o el cobro que lo usó y vuelva a intentar.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('cobros.anular',        'Anular cobros a clientes y condonaciones (con motivo)', true, false),
  ('cobros.condonar',      'Condonar (perdonar) el saldo de una factura de cliente, con motivo', true, false),
  ('ventas.saldo_inicial', 'Cargar y anular saldos iniciales de clientes (facturas que ya debían)', true, false);

-- Criterio: anular y condonar = dueño y admin; saldos iniciales = solo dueño
-- (igual que compras.saldo_inicial). Cobrar usa ventas.cobrar (o el vendedor
-- que cobra, 031).
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'cobros.anular'), ('dueno', 'cobros.condonar'), ('dueno', 'ventas.saldo_inicial'),
  ('admin', 'cobros.anular'), ('admin', 'cobros.condonar');
SELECT interno.repartir_permisos(ARRAY['cobros.anular', 'cobros.condonar', 'ventas.saldo_inicial'],
  'Núcleo 0.9.0: permisos de cobros y saldos iniciales de clientes');

-- ---------------------------------------------------------------------
-- 1) Cuentas
-- ---------------------------------------------------------------------
INSERT INTO interno.plantilla_cuenta (codigo, nombre, tipo, naturaleza, es_detalle) VALUES
  ('2.1.04.02', 'Saldos a favor de clientes (vales)', 'pasivo', 'acreedora', true),
  ('6.1.02.12', 'Saldos condonados a clientes',       'gasto',  'deudora',   true);

INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('saldo_favor',     '2.1.04.02', 'Saldos a favor de clientes y vales (excedentes, anticipos, notas de crédito)', 'ventas'),
  ('condonacion_cxc', '6.1.02.12', 'Saldos de clientes condonados con motivo (redondeos)', NULL),
  ('apertura_cxc',    '3.3.01.03', 'Saldos de apertura: contrapartida de las facturas de clientes pendientes al iniciar', NULL);

DO $$
DECLARE e record;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.9.0: cuentas de saldo a favor y condonaciones', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    PERFORM interno.asegurar_cuenta_uso(e.id, 'saldo_favor', 'Saldos a favor de clientes (vales)');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'condonacion_cxc', 'Saldos condonados a clientes');
  END LOOP;
  -- Apertura de clientes = la misma cuenta que la apertura de proveedores.
  INSERT INTO interno.cuenta_sistema_empresa (empresa_id, uso, codigo)
  SELECT x.empresa_id, 'apertura_cxc', x.codigo FROM interno.cuenta_sistema_empresa x WHERE x.uso = 'apertura_cxp';
  PERFORM set_config('app.motivo', '', true);
END $$;

-- Días de vigencia de un VALE sin cliente (NULL = no vence). Lo cambia el dueño.
ALTER TABLE public.empresa
  ADD COLUMN vale_dias_vigencia integer CHECK (vale_dias_vigencia BETWEEN 1 AND 3650);

-- ---------------------------------------------------------------------
-- 2) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.cxc_saldo_inicial (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  cliente_id               uuid NOT NULL,
  numero_documento         text NOT NULL CHECK (length(trim(numero_documento)) > 0),
  fecha_documento          date NOT NULL,                    -- fecha de la factura (puede ser antes del inicio)
  fecha_contable           date NOT NULL,                    -- fecha del asiento de apertura
  fecha_vencimiento        date NOT NULL,
  monto_centavos           bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
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
  FOREIGN KEY (empresa_id, cliente_id)           REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id)          REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK (fecha_vencimiento >= fecha_documento),
  CHECK (fecha_documento <= fecha_contable),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL)),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL))
);
CREATE UNIQUE INDEX cxc_saldo_inicial_factura ON public.cxc_saldo_inicial (empresa_id, cliente_id, upper(numero_documento))
  WHERE anulada_en IS NULL;
CREATE INDEX cxc_saldo_inicial_cliente ON public.cxc_saldo_inicial (empresa_id, cliente_id, fecha_documento);

-- Saldo a favor: un lote por cada vez que se genera.
CREATE TABLE public.saldo_favor (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id        uuid NOT NULL REFERENCES public.empresa(id),
  numero            bigint NOT NULL,
  cliente_id        uuid,                 -- NULL = vale de consumidor final (con código)
  codigo            text,                 -- código del vale (sin cliente); se imprime
  origen            text NOT NULL CHECK (origen IN ('excedente_cobro', 'anticipo', 'devolucion', 'apartado_cancelado', 'anulacion_venta')),
  documento_tipo    text NOT NULL,        -- cobro, devolucion, apartado, venta
  documento_id      uuid NOT NULL,
  monto_centavos    bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  fecha_contable    date NOT NULL,
  vence_el          date,                 -- solo vales sin cliente (empresa.vale_dias_vigencia)
  creado_por        uuid,
  registrado_en     timestamptz NOT NULL DEFAULT now(),
  anulada_en        timestamptz,          -- se anula cuando se anula el documento que lo creó (sin usos)
  anulada_por       uuid,
  motivo_anulacion  text,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  FOREIGN KEY (empresa_id, cliente_id) REFERENCES public.tercero(empresa_id, id),
  CHECK (cliente_id IS NOT NULL OR codigo IS NOT NULL),
  CHECK (codigo IS NULL OR codigo ~ '^VALE-[0-9A-F]{10}$'),
  CHECK (vence_el IS NULL OR vence_el >= fecha_contable),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL))
);
CREATE UNIQUE INDEX saldo_favor_codigo ON public.saldo_favor (empresa_id, codigo) WHERE codigo IS NOT NULL;
CREATE INDEX saldo_favor_cliente ON public.saldo_favor (empresa_id, cliente_id, fecha_contable) WHERE cliente_id IS NOT NULL;
CREATE INDEX saldo_favor_documento ON public.saldo_favor (documento_id);

CREATE TABLE public.saldo_favor_uso (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id        uuid NOT NULL REFERENCES public.empresa(id),
  saldo_favor_id    uuid NOT NULL,
  monto_centavos    bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  documento_tipo    text NOT NULL,        -- venta, cobro, apartado
  documento_id      uuid NOT NULL,
  fecha_contable    date NOT NULL,
  creado_por        uuid,
  registrado_en     timestamptz NOT NULL DEFAULT now(),
  anulado_en        timestamptz,          -- al anular el documento que lo usó: el lote recupera su saldo
  motivo_anulacion  text,
  FOREIGN KEY (empresa_id, saldo_favor_id) REFERENCES public.saldo_favor(empresa_id, id),
  CHECK ((anulado_en IS NULL) = (motivo_anulacion IS NULL))
);
CREATE INDEX saldo_favor_uso_lote ON public.saldo_favor_uso (saldo_favor_id);
CREATE INDEX saldo_favor_uso_documento ON public.saldo_favor_uso (documento_id);

CREATE TABLE public.cobro (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  tipo                     text NOT NULL CHECK (tipo IN ('cxc', 'anticipo', 'apartado')),
  cliente_id               uuid NOT NULL,
  apartado_id              uuid,                -- tipo apartado (034)
  caja_id                  uuid REFERENCES public.caja(id),
  sucursal_id              uuid,
  fecha_contable           date NOT NULL,
  monto_centavos           bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),   -- todo lo recibido
  aplicado_centavos        bigint NOT NULL CHECK (aplicado_centavos >= 0),     -- a facturas o al apartado
  excedente_centavos       bigint NOT NULL CHECK (excedente_centavos >= 0),    -- a saldo a favor
  saldo_favor_id           uuid,                -- el lote del excedente
  referencia               text,
  nota                     text,
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
  FOREIGN KEY (empresa_id, cliente_id)           REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id)          REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, saldo_favor_id)       REFERENCES public.saldo_favor(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK (monto_centavos = aplicado_centavos + excedente_centavos),
  CHECK ((excedente_centavos > 0) = (saldo_favor_id IS NOT NULL)),
  CHECK ((tipo = 'apartado') = (apartado_id IS NOT NULL)),
  CHECK (tipo <> 'anticipo' OR aplicado_centavos = 0),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL)),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL))
);
CREATE INDEX cobro_empresa_fecha ON public.cobro (empresa_id, fecha_contable);
CREATE INDEX cobro_cliente ON public.cobro (empresa_id, cliente_id, fecha_contable);

CREATE TABLE public.cobro_pago (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                 uuid NOT NULL,
  cobro_id                   uuid NOT NULL,
  linea                      smallint NOT NULL CHECK (linea > 0),
  forma                      text NOT NULL CHECK (forma IN ('efectivo', 'tarjeta', 'transferencia', 'saldo_favor')),
  monto_centavos             bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  cuenta_dinero_id           uuid,                 -- a dónde entra el dinero (NULL con saldo a favor)
  turno_id                   uuid,
  referencia                 text,
  recibido_centavos          bigint,
  vuelto_centavos            bigint,
  estado_transferencia       text CHECK (estado_transferencia IN ('por_confirmar', 'confirmada')),
  banco_id                   uuid,
  referencia_confirmacion    text,
  fecha_confirmacion         date,
  asiento_confirmacion_id    uuid,
  confirmacion_id_operacion  uuid,
  confirmada_por             uuid,
  confirmada_en              timestamptz,
  UNIQUE (empresa_id, id),
  UNIQUE (cobro_id, linea),
  FOREIGN KEY (empresa_id, cobro_id)                REFERENCES public.cobro(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id)        REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, turno_id)                REFERENCES public.turno_caja(empresa_id, id),
  FOREIGN KEY (empresa_id, banco_id)                REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_confirmacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((forma = 'saldo_favor') = (cuenta_dinero_id IS NULL)),
  CHECK (forma = 'efectivo' OR (recibido_centavos IS NULL AND vuelto_centavos IS NULL AND turno_id IS NULL)),
  CHECK ((recibido_centavos IS NULL) = (vuelto_centavos IS NULL)),
  CHECK (recibido_centavos IS NULL OR (recibido_centavos >= monto_centavos AND vuelto_centavos = recibido_centavos - monto_centavos)),
  CHECK ((forma = 'transferencia') = (estado_transferencia IS NOT NULL)),
  CHECK ((estado_transferencia = 'confirmada') = (asiento_confirmacion_id IS NOT NULL)),
  CHECK ((asiento_confirmacion_id IS NULL) = (banco_id IS NULL))
);
CREATE INDEX cobro_pago_cobro ON public.cobro_pago (cobro_id);
CREATE INDEX cobro_pago_por_confirmar ON public.cobro_pago (empresa_id) WHERE estado_transferencia = 'por_confirmar';

CREATE TABLE public.cxc_condonacion (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  cliente_id               uuid NOT NULL,
  venta_id                 uuid,
  saldo_inicial_id         uuid,
  monto_centavos           bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  motivo                   text NOT NULL CHECK (length(trim(motivo)) >= 5),
  fecha_contable           date NOT NULL,
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
  FOREIGN KEY (empresa_id, cliente_id)           REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, venta_id)             REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, saldo_inicial_id)     REFERENCES public.cxc_saldo_inicial(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((venta_id IS NULL) <> (saldo_inicial_id IS NULL)),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL))
);

-- Todo lo que rebaja una factura por cobrar (venta al crédito o saldo inicial).
CREATE TABLE public.cxc_aplicacion (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id        uuid NOT NULL REFERENCES public.empresa(id),
  cliente_id        uuid NOT NULL,
  venta_id          uuid,
  saldo_inicial_id  uuid,
  origen            text NOT NULL CHECK (origen IN ('cobro', 'condonacion', 'devolucion')),
  origen_id         uuid NOT NULL,
  monto_centavos    bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  fecha_contable    date NOT NULL,
  creado_por        uuid,
  registrado_en     timestamptz NOT NULL DEFAULT now(),
  anulada_en        timestamptz,          -- se anula con su documento (una vez)
  FOREIGN KEY (empresa_id, venta_id)         REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, saldo_inicial_id) REFERENCES public.cxc_saldo_inicial(empresa_id, id),
  CHECK ((venta_id IS NULL) <> (saldo_inicial_id IS NULL))
);
CREATE INDEX cxc_aplicacion_venta ON public.cxc_aplicacion (venta_id) WHERE venta_id IS NOT NULL;
CREATE INDEX cxc_aplicacion_saldo_inicial ON public.cxc_aplicacion (saldo_inicial_id) WHERE saldo_inicial_id IS NOT NULL;
CREATE INDEX cxc_aplicacion_origen ON public.cxc_aplicacion (origen_id);
CREATE INDEX cxc_aplicacion_cliente ON public.cxc_aplicacion (empresa_id, cliente_id);

-- ---------------------------------------------------------------------
-- 3) Defensas: nada se edita; se anula una vez.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.proteger_anulable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c constant text[] := ARRAY['anulada_en', 'anulada_por', 'motivo_anulacion', 'fecha_anulacion', 'asiento_anulacion_id',
                             'anulacion_id_operacion', 'anulado_en'];
BEGIN
  IF (to_jsonb(OLD) ? 'anulada_en' AND to_jsonb(OLD)->>'anulada_en' IS NULL AND to_jsonb(NEW)->>'anulada_en' IS NOT NULL
      OR to_jsonb(OLD) ? 'anulado_en' AND to_jsonb(OLD)->>'anulado_en' IS NULL AND to_jsonb(NEW)->>'anulado_en' IS NOT NULL)
     AND (to_jsonb(NEW) - c) = (to_jsonb(OLD) - c) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: % no se edita; solo se anula una vez.', TG_TABLE_NAME;
END $$;

-- La transferencia de un cobro se confirma una vez.
CREATE FUNCTION interno.proteger_cobro_pago() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c_conf constant text[] := ARRAY['estado_transferencia', 'banco_id', 'referencia_confirmacion', 'fecha_confirmacion',
                                        'asiento_confirmacion_id', 'confirmacion_id_operacion', 'confirmada_por', 'confirmada_en'];
BEGIN
  IF OLD.estado_transferencia = 'por_confirmar' AND NEW.estado_transferencia = 'confirmada'
     AND (to_jsonb(NEW) - c_conf) = (to_jsonb(OLD) - c_conf) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: un pago no se edita; la transferencia se confirma una sola vez.';
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cxc_saldo_inicial', 'saldo_favor', 'saldo_favor_uso', 'cobro', 'cxc_condonacion', 'cxc_aplicacion'] LOOP
    EXECUTE format('CREATE TRIGGER proteger BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.proteger_anulable()', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['cxc_saldo_inicial', 'saldo_favor', 'saldo_favor_uso', 'cobro', 'cobro_pago', 'cxc_condonacion', 'cxc_aplicacion'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'Los cobros, saldos y aplicaciones no se borran: se anulan.');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.cobro_pago FOR EACH ROW EXECUTE FUNCTION interno.proteger_cobro_pago();

CREATE POLICY leer ON public.cxc_saldo_inicial FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
CREATE POLICY leer ON public.saldo_favor FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
CREATE POLICY leer ON public.saldo_favor_uso FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
CREATE POLICY leer ON public.cobro FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         OR (creado_por = (SELECT auth.uid()) AND empresa_id IN (SELECT public.mis_empresas())));
CREATE POLICY leer ON public.cobro_pago FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
CREATE POLICY leer ON public.cxc_condonacion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
CREATE POLICY leer ON public.cxc_aplicacion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));

-- ---------------------------------------------------------------------
-- 4) Saldos de cuentas por cobrar (reemplazan los ganchos de 028)
-- ---------------------------------------------------------------------
-- Rebajas vigentes de un documento (venta o saldo inicial): cobros, condonaciones y devoluciones.
CREATE FUNCTION interno.rebajas_cxc(p_documento_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(a.monto_centavos), 0)::bigint FROM public.cxc_aplicacion a
   WHERE (a.venta_id = p_documento_id OR a.saldo_inicial_id = p_documento_id) AND a.anulada_en IS NULL
$$;

-- Saldo por cobrar de un documento (0 si no es por cobrar o está anulado).
CREATE FUNCTION interno.saldo_documento_cxc(p_documento_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT v.credito_centavos FROM public.venta v WHERE v.id = p_documento_id AND v.estado = 'emitida'),
                  (SELECT s.monto_centavos FROM public.cxc_saldo_inicial s WHERE s.id = p_documento_id AND s.anulada_en IS NULL), 0)
         - interno.rebajas_cxc(p_documento_id)
$$;

-- GANCHO (028): lo que impide anular una venta = cobros y condonaciones vigentes.
CREATE OR REPLACE FUNCTION interno.cobros_vigentes_venta(p_venta_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(a.monto_centavos), 0)::bigint FROM public.cxc_aplicacion a
   WHERE a.venta_id = p_venta_id AND a.anulada_en IS NULL AND a.origen IN ('cobro', 'condonacion')
$$;

-- Saldo por cobrar de un cliente (ventas al crédito + saldos iniciales - rebajas).
CREATE OR REPLACE FUNCTION interno.saldo_cxc_cliente(p_empresa_id uuid, p_cliente_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ( coalesce((SELECT sum(v.credito_centavos) FROM public.venta v
                      WHERE v.empresa_id = p_empresa_id AND v.cliente_id = p_cliente_id AND v.estado = 'emitida' AND v.credito_centavos > 0), 0)
         + coalesce((SELECT sum(s.monto_centavos) FROM public.cxc_saldo_inicial s
                      WHERE s.empresa_id = p_empresa_id AND s.cliente_id = p_cliente_id AND s.anulada_en IS NULL), 0)
         - coalesce((SELECT sum(a.monto_centavos) FROM public.cxc_aplicacion a
                      WHERE a.empresa_id = p_empresa_id AND a.cliente_id = p_cliente_id AND a.anulada_en IS NULL), 0)
         )::bigint
$$;

-- Total por cobrar de la empresa según el módulo (debe = saldo de Clientes 1.1.02.01).
CREATE OR REPLACE FUNCTION interno.total_cxc(p_empresa_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ( coalesce((SELECT sum(v.credito_centavos) FROM public.venta v
                      WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND v.credito_centavos > 0), 0)
         + coalesce((SELECT sum(s.monto_centavos) FROM public.cxc_saldo_inicial s
                      WHERE s.empresa_id = p_empresa_id AND s.anulada_en IS NULL), 0)
         - coalesce((SELECT sum(a.monto_centavos) FROM public.cxc_aplicacion a
                      WHERE a.empresa_id = p_empresa_id AND a.anulada_en IS NULL), 0)
         )::bigint
$$;

-- ---------------------------------------------------------------------
-- 5) Saldo a favor y vales
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.saldo_favor_lote(p_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN s.anulada_en IS NOT NULL THEN 0
              ELSE s.monto_centavos - coalesce((SELECT sum(u.monto_centavos) FROM public.saldo_favor_uso u
                                                 WHERE u.saldo_favor_id = s.id AND u.anulado_en IS NULL), 0) END::bigint
    FROM public.saldo_favor s WHERE s.id = p_id
$$;

-- Saldo a favor de un cliente (lotes vigentes, sin vencer).
CREATE FUNCTION interno.saldo_favor_cliente(p_empresa_id uuid, p_cliente_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(interno.saldo_favor_lote(s.id)), 0)::bigint FROM public.saldo_favor s
   WHERE s.empresa_id = p_empresa_id AND s.cliente_id = p_cliente_id AND s.anulada_en IS NULL
     AND (s.vence_el IS NULL OR s.vence_el >= public.hoy_local(p_empresa_id))
$$;

-- Total de saldos a favor de la empresa (debe = saldo de 2.1.04.02), vencidos incluidos.
CREATE FUNCTION interno.total_saldo_favor(p_empresa_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ( coalesce((SELECT sum(s.monto_centavos) FROM public.saldo_favor s WHERE s.empresa_id = p_empresa_id AND s.anulada_en IS NULL), 0)
         - coalesce((SELECT sum(u.monto_centavos) FROM public.saldo_favor_uso u JOIN public.saldo_favor s ON s.id = u.saldo_favor_id
                      WHERE u.empresa_id = p_empresa_id AND u.anulado_en IS NULL AND s.anulada_en IS NULL), 0))::bigint
$$;

-- Crea un lote de saldo a favor. Sin cliente = VALE con código único y,
-- si la empresa lo configuró, fecha de vencimiento. Quien llama tiene el candado.
CREATE FUNCTION interno.crear_saldo_favor(p_empresa_id uuid, p_cliente_id uuid, p_origen text, p_documento_tipo text,
                                          p_documento_id uuid, p_monto bigint, p_fecha date) RETURNS public.saldo_favor
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s       public.saldo_favor;
  v_cod   text;
  v_dias  integer;
BEGIN
  IF p_cliente_id IS NULL THEN
    LOOP
      v_cod := 'VALE-' || upper(left(replace(gen_random_uuid()::text, '-', ''), 10));
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.saldo_favor x WHERE x.empresa_id = p_empresa_id AND x.codigo = v_cod);
    END LOOP;
    SELECT e.vale_dias_vigencia INTO v_dias FROM public.empresa e WHERE e.id = p_empresa_id;
  END IF;
  INSERT INTO public.saldo_favor (empresa_id, numero, cliente_id, codigo, origen, documento_tipo, documento_id, monto_centavos,
                                  fecha_contable, vence_el, creado_por)
  VALUES (p_empresa_id, interno.siguiente_numero(p_empresa_id, 'saldo_favor'), p_cliente_id, v_cod, p_origen, p_documento_tipo,
          p_documento_id, p_monto, p_fecha, CASE WHEN v_dias IS NOT NULL THEN p_fecha + v_dias END, auth.uid())
  RETURNING * INTO s;
  RETURN s;
END $$;

-- Usa saldo a favor: del VALE indicado (código) o del cliente (lotes más
-- viejos primero). Bloquea los lotes (dos usos a la vez esperan en fila) y
-- registra el uso. Error si no alcanza, el vale no existe o venció.
-- Devuelve la lista [{saldo_favor_id, monto_centavos}].
CREATE FUNCTION interno.usar_saldo_favor(p_empresa_id uuid, p_cliente_id uuid, p_vale text, p_monto bigint,
                                         p_documento_tipo text, p_documento_id uuid, p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s       public.saldo_favor;
  v_falta bigint := p_monto;
  v_disp  bigint;
  v_toma  bigint;
  v_hoy   date := public.hoy_local(p_empresa_id);
  v_out   jsonb := '[]';
BEGIN
  IF p_monto <= 0 THEN
    RETURN v_out;
  END IF;
  IF p_vale IS NOT NULL THEN
    SELECT * INTO s FROM public.saldo_favor x WHERE x.empresa_id = p_empresa_id AND x.codigo = upper(trim(p_vale)) FOR UPDATE;
    IF s.id IS NULL OR s.anulada_en IS NOT NULL THEN
      RAISE EXCEPTION 'VALE_INVALIDO: el vale % no existe o está anulado.', upper(trim(p_vale));
    END IF;
    IF s.vence_el < v_hoy THEN
      RAISE EXCEPTION 'VALE_VENCIDO: el vale % venció el %.', s.codigo, to_char(s.vence_el, 'DD/MM/YYYY');
    END IF;
    v_disp := interno.saldo_favor_lote(s.id);
    IF v_disp < p_monto THEN
      RAISE EXCEPTION 'SALDO_FAVOR_INSUFICIENTE: el vale % tiene % y se quieren usar %.', s.codigo,
        interno.lempiras(v_disp), interno.lempiras(p_monto);
    END IF;
    INSERT INTO public.saldo_favor_uso (empresa_id, saldo_favor_id, monto_centavos, documento_tipo, documento_id, fecha_contable, creado_por)
    VALUES (p_empresa_id, s.id, p_monto, p_documento_tipo, p_documento_id, p_fecha, auth.uid());
    RETURN jsonb_build_array(jsonb_build_object('saldo_favor_id', s.id, 'codigo', s.codigo, 'monto_centavos', p_monto));
  END IF;
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'CLIENTE_REQUERIDO: para pagar con saldo a favor indique el cliente o el código del vale ("vale").';
  END IF;
  FOR s IN SELECT * FROM public.saldo_favor x
            WHERE x.empresa_id = p_empresa_id AND x.cliente_id = p_cliente_id AND x.anulada_en IS NULL
              AND (x.vence_el IS NULL OR x.vence_el >= v_hoy)
            ORDER BY x.fecha_contable, x.numero
            FOR UPDATE LOOP
    EXIT WHEN v_falta = 0;
    v_disp := interno.saldo_favor_lote(s.id);
    CONTINUE WHEN v_disp <= 0;
    v_toma := least(v_disp, v_falta);
    INSERT INTO public.saldo_favor_uso (empresa_id, saldo_favor_id, monto_centavos, documento_tipo, documento_id, fecha_contable, creado_por)
    VALUES (p_empresa_id, s.id, v_toma, p_documento_tipo, p_documento_id, p_fecha, auth.uid());
    v_out := v_out || jsonb_build_object('saldo_favor_id', s.id, 'codigo', s.codigo, 'monto_centavos', v_toma);
    v_falta := v_falta - v_toma;
  END LOOP;
  IF v_falta > 0 THEN
    RAISE EXCEPTION 'SALDO_FAVOR_INSUFICIENTE: el cliente tiene % a favor y se quieren usar %.',
      interno.lempiras(p_monto - v_falta + interno.saldo_favor_cliente(p_empresa_id, p_cliente_id)), interno.lempiras(p_monto);
  END IF;
  RETURN v_out;
END $$;

-- Anula los usos de saldo a favor de un documento (el saldo vuelve a sus lotes). Devuelve el total.
CREATE FUNCTION interno.devolver_usos_saldo_favor(p_documento_id uuid, p_motivo text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v bigint;
BEGIN
  SELECT coalesce(sum(u.monto_centavos), 0) INTO v FROM public.saldo_favor_uso u WHERE u.documento_id = p_documento_id AND u.anulado_en IS NULL;
  UPDATE public.saldo_favor_uso SET anulado_en = now(), motivo_anulacion = p_motivo
   WHERE documento_id = p_documento_id AND anulado_en IS NULL;
  RETURN v;
END $$;

-- Anula un lote (su documento se anula). Solo si nadie lo usó.
CREATE FUNCTION interno.anular_saldo_favor(p_id uuid, p_motivo text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.saldo_favor;
BEGIN
  SELECT * INTO s FROM public.saldo_favor WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL OR s.anulada_en IS NOT NULL THEN
    RETURN 0;
  END IF;
  IF EXISTS (SELECT 1 FROM public.saldo_favor_uso u WHERE u.saldo_favor_id = s.id AND u.anulado_en IS NULL) THEN
    RAISE EXCEPTION 'SALDO_FAVOR_USADO: el saldo a favor #% (%) ya se usó; anule primero la venta o el cobro que lo usó.',
      s.numero, coalesce(s.codigo, 'del cliente');
  END IF;
  UPDATE public.saldo_favor SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = p_motivo WHERE id = s.id;
  RETURN s.monto_centavos;
END $$;

-- ---------------------------------------------------------------------
-- 6) Ganchos que completan las etapas siguientes (aquí no hacen nada)
-- ---------------------------------------------------------------------
-- 036: comisiones (se devengan cuando la venta queda cobrada completa).
CREATE FUNCTION interno.recalcular_comision(p_venta_id uuid, p_id_operacion uuid, p_fecha date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN;
END $$;
-- 034: un anticipo de apartado solo se anula con el apartado vigente.
CREATE FUNCTION interno.validar_anulacion_cobro(c public.cobro) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN;
END $$;

-- Código contable de una cuenta de dinero.
CREATE FUNCTION interno.codigo_cuenta_dinero(p_cuenta_dinero_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT c.codigo FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = p_cuenta_dinero_id
$$;

-- Cliente de la empresa para cobrar (puede estar desactivado: igual paga lo que debe).
CREATE FUNCTION interno.cliente_de(p_empresa_id uuid, p_valor jsonb, p_activo boolean DEFAULT false) RETURNS public.tercero
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.tercero;
BEGIN
  SELECT * INTO t FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.id = interno.json_uuid(p_valor, 'cliente_id');
  IF t.id IS NULL OR NOT t.es_cliente OR (p_activo AND NOT t.activo) THEN
    RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente no existe, no está marcado como cliente%.',
      CASE WHEN p_activo THEN ' o está desactivado' ELSE '' END;
  END IF;
  RETURN t;
END $$;

-- ---------------------------------------------------------------------
-- 7) Cobros
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.cobro_respuesta(c public.cobro, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('cobro_id', c.id, 'numero', c.numero, 'tipo', c.tipo, 'cliente_id', c.cliente_id,
    'fecha', to_char(c.fecha_contable, 'YYYY-MM-DD'), 'monto_centavos', c.monto_centavos,
    'aplicado_centavos', c.aplicado_centavos, 'excedente_centavos', c.excedente_centavos,
    'aplicaciones', (SELECT coalesce(jsonb_agg(jsonb_build_object('venta_id', a.venta_id, 'saldo_inicial_id', a.saldo_inicial_id,
                       'documento', coalesce(v.numero_documento, s.numero_documento), 'monto_centavos', a.monto_centavos,
                       'saldo_restante_centavos', interno.saldo_documento_cxc(coalesce(a.venta_id, a.saldo_inicial_id))) ORDER BY a.id), '[]')
                       FROM public.cxc_aplicacion a
                       LEFT JOIN public.venta v ON v.id = a.venta_id
                       LEFT JOIN public.cxc_saldo_inicial s ON s.id = a.saldo_inicial_id
                      WHERE a.origen = 'cobro' AND a.origen_id = c.id),
    'saldo_favor', (SELECT jsonb_build_object('saldo_favor_id', f.id, 'codigo', f.codigo, 'monto_centavos', f.monto_centavos)
                      FROM public.saldo_favor f WHERE f.id = c.saldo_favor_id),
    'vuelto_centavos', (SELECT sum(p.vuelto_centavos) FROM public.cobro_pago p WHERE p.cobro_id = c.id),
    'saldo_cliente_centavos', interno.saldo_cxc_cliente(c.empresa_id, c.cliente_id),
    'saldo_favor_cliente_centavos', interno.saldo_favor_cliente(c.empresa_id, c.cliente_id),
    'asiento_id', c.asiento_id, 'anulado', c.anulada_en IS NOT NULL, 'duplicado', p_duplicado)
$$;

-- REGISTRAR un cobro (lo usan registrar_cobro y, en 034, abonar_apartado).
-- datos = {"cliente_id":"...", "tipo":"cxc"|"anticipo",
--          "pagos":[{"forma":"efectivo","monto_centavos":10000,"recibido_centavos":20000},
--                   {"forma":"tarjeta","monto_centavos":5000,"referencia":"Voucher 9"},
--                   {"forma":"transferencia","monto_centavos":5000,"referencia":"..."},
--                   {"forma":"saldo_favor","monto_centavos":2000,"vale":"VALE-..."(opcional)}],
--          "aplicar":[{"venta_id":"..."|"saldo_inicial_id":"...","monto_centavos":5000}] (sin "aplicar": la más vieja primero),
--          "excedente":"saldo_favor" (lo que pase del saldo; sin esto, COBRO_EXCEDE_SALDO),
--          "caja_id":"...", "fecha":"2026-01-20", "referencia":"Recibo 15", "nota":"...", "equipo":"Caja 1"}
-- p_apartado_id / p_apartado_saldo: abono a un apartado (lo valida y bloquea 034).
CREATE FUNCTION interno.registrar_cobro_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_apartado_id uuid DEFAULT NULL, p_apartado_saldo bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c        public.cobro;
  v_cli    public.tercero;
  v_tipo   text;
  v_fecha  date;
  v_caja   uuid;
  pj       jsonb;
  k        integer := 0;
  v_forma  text;
  v_monto  bigint;
  v_rec    bigint;
  v_total  bigint := 0;
  v_dinero bigint := 0;
  v_sfav   bigint := 0;
  v_norm   jsonb := '[]';
  v_apl    jsonb := '[]';
  v_aplic  bigint := 0;
  v_exc    bigint;
  v_doc    uuid;
  v_esvta  boolean;
  v_saldo  bigint;
  v_resto  bigint;
  r        record;
  d        public.cuenta_dinero;
  f        public.saldo_favor;
  v_lin    jsonb := '[]';
  v_usos   jsonb;
  v_vale   text;
  v_suc    uuid;
  v_asto   uuid;
  v_pid    uuid;
  a        jsonb;
BEGIN
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  SELECT * INTO c FROM public.cobro x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF c.id IS NOT NULL THEN
    RETURN interno.cobro_respuesta(c, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cliente_id', 'tipo', 'pagos', 'aplicar', 'excedente', 'caja_id', 'fecha',
                                               'referencia', 'nota', 'equipo']);
  IF NOT interno.puede_cobrar(p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.cobrar" (recibir dinero de clientes).';
  END IF;
  v_cli := interno.cliente_de(p_empresa_id, p_datos->'cliente_id');
  v_tipo := CASE WHEN p_apartado_id IS NOT NULL THEN 'apartado'
                 ELSE coalesce(interno.json_texto(p_datos->'tipo', 'tipo', 20), 'cxc') END;
  IF p_apartado_id IS NULL AND v_tipo NOT IN ('cxc', 'anticipo') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de cobro es "cxc" (a facturas) o "anticipo" (queda como saldo a favor).';
  END IF;
  IF coalesce(p_datos->'excedente', 'null'::jsonb) <> 'null'::jsonb AND interno.json_texto(p_datos->'excedente', 'excedente', 20) <> 'saldo_favor' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "excedente" solo puede ser "saldo_favor" (lo que pase del saldo queda a favor del cliente).';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  v_caja := interno.json_uuid(p_datos->'caja_id', 'caja_id');

  -- Formas de pago.
  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia o saldo a favor).';
  END IF;
  IF jsonb_array_length(p_datos->'pagos') > 10 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 10 formas de pago por cobro.';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    k := k + 1;
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    PERFORM interno.exigir_claves(pj, ARRAY['forma', 'monto_centavos', 'cuenta_dinero_id', 'referencia', 'recibido_centavos', 'vale']);
    v_forma := interno.json_texto(pj->'forma', 'forma', 20);
    IF coalesce(v_forma, '') NOT IN ('efectivo', 'tarjeta', 'transferencia', 'saldo_favor') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago de un cobro es efectivo, tarjeta, transferencia o saldo_favor.';
    END IF;
    v_monto := interno.json_centavos(pj->'monto_centavos', 'monto_centavos');
    IF v_monto = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada forma de pago lleva un monto mayor que cero ("monto_centavos").';
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
    IF v_forma IN ('efectivo', 'saldo_favor') AND coalesce(pj->'cuenta_dinero_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: en % no se indica cuenta de dinero.', v_forma;
    END IF;
    IF v_forma <> 'saldo_favor' AND pj ? 'vale' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "vale" solo va con la forma saldo_favor.';
    END IF;
    IF v_forma = 'saldo_favor' THEN
      v_sfav := v_sfav + v_monto;
    ELSE
      v_dinero := v_dinero + v_monto;
    END IF;
    v_total := v_total + v_monto;
    v_norm := v_norm || jsonb_build_object('linea', k, 'forma', v_forma, 'monto', v_monto, 'recibido', v_rec,
      'cuenta', interno.json_uuid(pj->'cuenta_dinero_id', 'cuenta_dinero_id'),
      'referencia', interno.json_texto(pj->'referencia', 'referencia', 100), 'vale', interno.json_texto(pj->'vale', 'vale', 20));
  END LOOP;
  IF v_dinero > 0 AND NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa (el cobro entra a una cuenta de dinero).';
  END IF;
  IF v_tipo = 'anticipo' AND v_sfav > 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un anticipo no se paga con saldo a favor (ya es saldo a favor).';
  END IF;
  IF v_tipo = 'anticipo' AND p_datos ? 'aplicar' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un anticipo no se aplica a facturas; todo queda como saldo a favor del cliente.';
  END IF;

  -- Candado, reintento.
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'cobro');
  SELECT * INTO c FROM public.cobro x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF c.id IS NOT NULL THEN
    RETURN interno.cobro_respuesta(c, true);
  END IF;

  -- A qué se aplica (con el candado: los saldos no cambian por debajo).
  IF v_tipo = 'apartado' THEN
    IF v_total > p_apartado_saldo THEN
      RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: el abono (%) pasa lo que falta pagar del apartado (%).', interno.lempiras(v_total), interno.lempiras(p_apartado_saldo);
    END IF;
    v_aplic := v_total;
  ELSIF v_tipo = 'cxc' THEN
    IF coalesce(p_datos->'aplicar', 'null'::jsonb) <> 'null'::jsonb THEN
      IF jsonb_typeof(p_datos->'aplicar') <> 'array' OR jsonb_array_length(p_datos->'aplicar') = 0 THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "aplicar" es una lista [{"venta_id" o "saldo_inicial_id", "monto_centavos"}].';
      END IF;
      FOR a IN SELECT * FROM jsonb_array_elements(p_datos->'aplicar') LOOP
        PERFORM interno.exigir_claves(a, ARRAY['venta_id', 'saldo_inicial_id', 'monto_centavos']);
        v_doc := coalesce(interno.json_uuid(a->'venta_id', 'venta_id'), interno.json_uuid(a->'saldo_inicial_id', 'saldo_inicial_id'));
        IF v_doc IS NULL OR (a ? 'venta_id' AND a ? 'saldo_inicial_id') THEN
          RAISE EXCEPTION 'DATO_INVALIDO: cada aplicación lleva "venta_id" o "saldo_inicial_id" (uno solo).';
        END IF;
        IF v_apl @> jsonb_build_array(jsonb_build_object('doc', v_doc)) THEN
          RAISE EXCEPTION 'DATO_INVALIDO: la misma factura viene dos veces en "aplicar".';
        END IF;
        v_monto := interno.json_centavos(a->'monto_centavos', 'monto_centavos');
        IF v_monto = 0 THEN
          RAISE EXCEPTION 'DATO_INVALIDO: cada aplicación lleva un monto mayor que cero.';
        END IF;
        v_esvta := a ? 'venta_id';
        IF v_esvta THEN
          PERFORM 1 FROM public.venta x WHERE x.id = v_doc AND x.empresa_id = p_empresa_id AND x.cliente_id = v_cli.id
             AND x.estado = 'emitida' AND x.credito_centavos > 0 FOR UPDATE;
        ELSE
          PERFORM 1 FROM public.cxc_saldo_inicial x WHERE x.id = v_doc AND x.empresa_id = p_empresa_id AND x.cliente_id = v_cli.id
             AND x.anulada_en IS NULL FOR UPDATE;
        END IF;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'DATO_INVALIDO: la factura indicada no es una cuenta por cobrar vigente de este cliente.';
        END IF;
        v_saldo := interno.saldo_documento_cxc(v_doc);
        IF v_monto > v_saldo THEN
          RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: a esa factura se le quieren aplicar % y su saldo es %.', interno.lempiras(v_monto), interno.lempiras(v_saldo);
        END IF;
        v_apl := v_apl || jsonb_build_object('doc', v_doc, 'es_venta', v_esvta, 'monto', v_monto);
        v_aplic := v_aplic + v_monto;
      END LOOP;
      IF v_aplic > v_total THEN
        RAISE EXCEPTION 'DATO_INVALIDO: lo aplicado a facturas (%) pasa lo recibido (%).', interno.lempiras(v_aplic), interno.lempiras(v_total);
      END IF;
    ELSE
      -- La más vieja primero (fecha de la factura, vencimiento, número).
      v_resto := v_total;
      FOR r IN SELECT x.doc, x.es_venta FROM (
                 SELECT v.id AS doc, true AS es_venta, v.fecha_contable AS f, v.vence_el AS ve, v.numero AS n
                   FROM public.venta v
                  WHERE v.empresa_id = p_empresa_id AND v.cliente_id = v_cli.id AND v.estado = 'emitida' AND v.credito_centavos > 0
                 UNION ALL
                 SELECT s.id, false, s.fecha_documento, s.fecha_vencimiento, s.numero
                   FROM public.cxc_saldo_inicial s
                  WHERE s.empresa_id = p_empresa_id AND s.cliente_id = v_cli.id AND s.anulada_en IS NULL) x
               ORDER BY x.f, x.ve, NOT x.es_venta, x.n LOOP
        EXIT WHEN v_resto = 0;
        IF r.es_venta THEN
          PERFORM 1 FROM public.venta x WHERE x.id = r.doc FOR UPDATE;
        ELSE
          PERFORM 1 FROM public.cxc_saldo_inicial x WHERE x.id = r.doc FOR UPDATE;
        END IF;
        v_saldo := interno.saldo_documento_cxc(r.doc);
        CONTINUE WHEN v_saldo <= 0;
        v_monto := least(v_saldo, v_resto);
        v_apl := v_apl || jsonb_build_object('doc', r.doc, 'es_venta', r.es_venta, 'monto', v_monto);
        v_aplic := v_aplic + v_monto;
        v_resto := v_resto - v_monto;
      END LOOP;
    END IF;
  END IF;
  v_exc := v_total - v_aplic;
  IF v_exc > 0 THEN
    IF coalesce(p_datos->>'excedente', '') <> 'saldo_favor' AND v_tipo <> 'anticipo' THEN
      RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: se reciben % y el cliente debe % en lo indicado (excedente %). Cobre solo el saldo o indique "excedente": "saldo_favor" para dejarlo a favor del cliente.',
        interno.lempiras(v_total), interno.lempiras(v_aplic), interno.lempiras(v_exc);
    END IF;
    IF v_sfav > 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el excedente no puede venir de un saldo a favor; use menos saldo a favor.';
    END IF;
  END IF;

  -- Guardar.
  c.id := gen_random_uuid();
  -- Caja: la indicada o la del turno abierto del usuario.
  IF v_caja IS NULL THEN
    SELECT t.caja_id INTO v_caja FROM public.turno_caja t
     WHERE t.empresa_id = p_empresa_id AND t.cajero_id = auth.uid() AND t.estado = 'abierto';
  END IF;
  IF v_caja IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.caja x WHERE x.id = v_caja AND x.empresa_id = p_empresa_id) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja no existe en esta empresa.';
  END IF;
  SELECT x.sucursal_id INTO v_suc FROM public.caja x WHERE x.id = v_caja;

  -- Pagos (las cuentas de dinero se pueden crear la primera vez, con el candado).
  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    d := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(p_empresa_id, v_caja);
      IF v_caja IS NULL THEN
        v_caja := d.caja_id;
        SELECT x.sucursal_id INTO v_suc FROM public.caja x WHERE x.id = v_caja;
      END IF;
    ELSIF pj->>'forma' IN ('tarjeta', 'transferencia') THEN
      d := interno.cuenta_cobro_venta(p_empresa_id, pj->>'forma', (pj->>'cuenta')::uuid);
    END IF;
    IF d.id IS NOT NULL THEN
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'debe', (pj->>'monto')::bigint,
                                           'descripcion', 'Cobro a ' || v_cli.nombre || ' (' || (pj->>'forma') || ')');
    ELSE
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'debe', (pj->>'monto')::bigint,
                                           'descripcion', 'Cobro con saldo a favor de ' || v_cli.nombre);
    END IF;
    pj := pj || jsonb_build_object('cuenta_id', d.id);
    v_norm := jsonb_set(v_norm, ARRAY[((pj->>'linea')::integer - 1)::text], pj);
  END LOOP;

  v_lin := v_lin || jsonb_build_object('uso', CASE v_tipo WHEN 'apartado' THEN 'anticipo_clientes' ELSE 'cxc' END,
                                       'haber', v_aplic,
                                       'descripcion', CASE v_tipo WHEN 'apartado' THEN 'Anticipo de apartado de ' ELSE 'Cobro a ' END || v_cli.nombre)
                 || jsonb_build_object('uso', 'saldo_favor', 'haber', v_exc,
                                       'descripcion', 'Saldo a favor de ' || v_cli.nombre);
  c.numero := interno.siguiente_numero(p_empresa_id, 'cobro');
  v_asto := interno.asiento_sistema(p_empresa_id, interno.sucursal_activa(v_suc), v_fecha,
    CASE v_tipo WHEN 'cxc' THEN 'Cobro #' || c.numero || ' a ' || v_cli.nombre
                WHEN 'anticipo' THEN 'Anticipo #' || c.numero || ' de ' || v_cli.nombre || ' (saldo a favor)'
                ELSE 'Abono #' || c.numero || ' a apartado de ' || v_cli.nombre END
      || coalesce(' ref. ' || interno.json_texto(p_datos->'referencia', 'referencia', 100), ''),
    'cobro', p_id_operacion, v_lin);

  -- El excedente es un lote de saldo a favor del cliente (documento = este cobro).
  IF v_exc > 0 THEN
    f := interno.crear_saldo_favor(p_empresa_id, v_cli.id, CASE WHEN v_tipo = 'anticipo' THEN 'anticipo' ELSE 'excedente_cobro' END,
                                   'cobro', c.id, v_exc, v_fecha);
  END IF;
  INSERT INTO public.cobro (id, empresa_id, numero, tipo, cliente_id, apartado_id, caja_id, sucursal_id, fecha_contable,
    monto_centavos, aplicado_centavos, excedente_centavos, saldo_favor_id, referencia, nota, equipo, asiento_id, id_operacion, creado_por)
  VALUES (c.id, p_empresa_id, c.numero, v_tipo, v_cli.id, p_apartado_id, v_caja, v_suc, v_fecha, v_total, v_aplic, v_exc, f.id,
    interno.json_texto(p_datos->'referencia', 'referencia', 100), interno.json_texto(p_datos->'nota', 'nota', 500),
    interno.equipo(p_datos), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO c;

  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    INSERT INTO public.cobro_pago (empresa_id, cobro_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos, estado_transferencia)
    VALUES (p_empresa_id, c.id, (pj->>'linea')::smallint, pj->>'forma', (pj->>'monto')::bigint, (pj->>'cuenta_id')::uuid,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta((pj->>'cuenta_id')::uuid) END, pj->>'referencia',
            (pj->>'recibido')::bigint, (pj->>'recibido')::bigint - (pj->>'monto')::bigint,
            CASE WHEN pj->>'forma' = 'transferencia' THEN 'por_confirmar' END);
    IF pj->>'forma' = 'saldo_favor' THEN
      v_usos := interno.usar_saldo_favor(p_empresa_id, v_cli.id, pj->>'vale', (pj->>'monto')::bigint, 'cobro', c.id, v_fecha);
    END IF;
  END LOOP;

  FOR a IN SELECT * FROM jsonb_array_elements(v_apl) LOOP
    INSERT INTO public.cxc_aplicacion (empresa_id, cliente_id, venta_id, saldo_inicial_id, origen, origen_id, monto_centavos,
                                       fecha_contable, creado_por)
    VALUES (p_empresa_id, v_cli.id, CASE WHEN (a->>'es_venta')::boolean THEN (a->>'doc')::uuid END,
            CASE WHEN NOT (a->>'es_venta')::boolean THEN (a->>'doc')::uuid END, 'cobro', c.id, (a->>'monto')::bigint, v_fecha, auth.uid());
  END LOOP;

  PERFORM interno.rastrear_dinero(v_asto, 'cobro', 'cobro', c.id,
    coalesce(interno.json_texto(p_datos->'referencia', 'referencia', 100), 'Cobro #' || c.numero), interno.equipo(p_datos));
  FOR a IN SELECT * FROM jsonb_array_elements(v_apl) LOOP
    IF (a->>'es_venta')::boolean THEN
      PERFORM interno.recalcular_comision((a->>'doc')::uuid, p_id_operacion, v_fecha);
    END IF;
  END LOOP;
  RETURN interno.cobro_respuesta(c, false);
END $$;

-- RPC: registrar_cobro(empresa, datos, id_operacion)   ventas.cobrar (o el vendedor que cobra)
CREATE FUNCTION public.registrar_cobro(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.vender', 'ventas');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'cobro');
  RETURN interno.registrar_cobro_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- RPC: anular_cobro(cobro, motivo, id_operacion, fecha?)   cobros.anular
-- Patrón "anular un abono": contra-asiento enlazado; el dinero SALE de la
-- misma cuenta a la que entró (una transferencia confirmada, del banco donde
-- quedó); el saldo a favor usado vuelve a su lote; el excedente que quedó a
-- favor se anula (si ya se usó: SALDO_FAVOR_USADO); las facturas recuperan su saldo.
CREATE FUNCTION public.anular_cobro(p_cobro_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c       public.cobro;
  pg      public.cobro_pago;
  v_fecha date;
  v_lin   jsonb := '[]';
  v_asto  uuid;
  v_cta   uuid;
  v_vtas  uuid[];
  v       uuid;
BEGIN
  SELECT * INTO c FROM public.cobro WHERE id = p_cobro_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cobro no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, 'cobros.anular', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(c.empresa_id, p_id_operacion, 'anulacion_cobro');
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cobro_respuesta(c, true) || jsonb_build_object('asiento_anulacion_id', c.asiento_anulacion_id);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(c.empresa_id), c.fecha_contable));
  PERFORM interno.exigir_fecha_contable(c.empresa_id, v_fecha);
  IF v_fecha < c.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al cobro (%).', to_char(c.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(c.empresa_id, p_id_operacion, 'anulacion_cobro');
  SELECT * INTO c FROM public.cobro WHERE id = p_cobro_id FOR UPDATE;
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cobro_respuesta(c, true) || jsonb_build_object('asiento_anulacion_id', c.asiento_anulacion_id);
  END IF;
  IF c.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el cobro #% ya fue anulado.', c.numero;
  END IF;
  PERFORM interno.validar_anulacion_cobro(c);
  PERFORM interno.exigir_periodo_abierto(c.empresa_id, v_fecha);

  -- El excedente que quedó a favor del cliente se anula (si nadie lo usó).
  IF c.saldo_favor_id IS NOT NULL THEN
    PERFORM interno.anular_saldo_favor(c.saldo_favor_id, 'Anulación del cobro #' || c.numero || ': ' || trim(p_motivo));
  END IF;
  FOR pg IN SELECT * FROM public.cobro_pago x WHERE x.cobro_id = c.id ORDER BY x.linea LOOP
    IF pg.forma = 'saldo_favor' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos, 'descripcion', 'Vuelve el saldo a favor usado');
    ELSE
      v_cta := CASE WHEN pg.estado_transferencia = 'confirmada' THEN pg.banco_id ELSE pg.cuenta_dinero_id END;
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(v_cta), 'haber', pg.monto_centavos,
                                           'descripcion', 'Devolución del cobro (' || pg.forma || ')');
    END IF;
  END LOOP;
  v_lin := v_lin || jsonb_build_object('uso', CASE c.tipo WHEN 'apartado' THEN 'anticipo_clientes' ELSE 'cxc' END,
                                       'debe', c.aplicado_centavos, 'descripcion', 'Vuelve el saldo por cobrar')
                 || jsonb_build_object('uso', 'saldo_favor', 'debe', c.excedente_centavos, 'descripcion', 'Se anula el saldo a favor del excedente');
  v_asto := interno.asiento_sistema(c.empresa_id, interno.sucursal_activa(c.sucursal_id), v_fecha,
    'ANULACIÓN cobro #' || c.numero || ': ' || trim(p_motivo), 'anulacion_cobro', p_id_operacion, v_lin, c.asiento_id, trim(p_motivo));

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  PERFORM interno.devolver_usos_saldo_favor(c.id, 'Anulación del cobro #' || c.numero);
  SELECT array_agg(DISTINCT a.venta_id) INTO v_vtas FROM public.cxc_aplicacion a
   WHERE a.origen = 'cobro' AND a.origen_id = c.id AND a.anulada_en IS NULL AND a.venta_id IS NOT NULL;
  UPDATE public.cxc_aplicacion SET anulada_en = now() WHERE origen = 'cobro' AND origen_id = c.id AND anulada_en IS NULL;
  UPDATE public.cobro SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo), fecha_anulacion = v_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = c.id
  RETURNING * INTO c;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_cobro', 'cobro', c.id, trim(p_motivo), NULL);
  FOREACH v IN ARRAY coalesce(v_vtas, '{}') LOOP
    PERFORM interno.recalcular_comision(v, p_id_operacion, v_fecha);
  END LOOP;
  RETURN interno.cobro_respuesta(c, false) || jsonb_build_object('asiento_anulacion_id', v_asto);
END $$;

-- RPC: confirmar_transferencia_cobro(pago, {"banco_id","referencia","fecha"?,"equipo"?}, id_operacion)   dinero.trasladar
CREATE FUNCTION public.confirmar_transferencia_cobro(p_cobro_pago_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  pg      public.cobro_pago;
  c       public.cobro;
  b       public.cuenta_dinero;
  v_ref   text;
  v_fecha date;
  v_asto  uuid;
BEGIN
  SELECT * INTO pg FROM public.cobro_pago WHERE id = p_cobro_pago_id;
  IF pg.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el pago no existe.';
  END IF;
  SELECT * INTO c FROM public.cobro WHERE id = pg.cobro_id;
  PERFORM interno.exigir_escritura(c.empresa_id, 'dinero.trasladar', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(c.empresa_id, p_id_operacion, 'confirmacion_transferencia_cobro');
  IF pg.confirmacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('cobro_pago_id', pg.id, 'estado_transferencia', pg.estado_transferencia,
                              'asiento_id', pg.asiento_confirmacion_id, 'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['banco_id', 'referencia', 'fecha', 'equipo']);
  IF pg.forma <> 'transferencia' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: solo se confirman pagos por transferencia.';
  END IF;
  b := interno.cuenta_dinero_de(c.empresa_id, interno.json_uuid(p_datos->'banco_id', 'banco_id'));
  IF b.tipo <> 'banco' THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la transferencia se confirma en una cuenta de banco ("%" es %).', b.nombre, b.tipo;
  END IF;
  v_ref := interno.json_texto(p_datos->'referencia', 'referencia', 100);
  IF length(coalesce(v_ref, '')) < 3 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba la referencia de la transferencia que aparece en el banco (mínimo 3 letras o números).';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), greatest(public.hoy_local(c.empresa_id), c.fecha_contable));
  PERFORM interno.exigir_fecha_contable(c.empresa_id, v_fecha);
  IF v_fecha < c.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la confirmación no puede tener fecha anterior al cobro (%).', to_char(c.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(c.empresa_id, p_id_operacion, 'confirmacion_transferencia_cobro');
  SELECT * INTO pg FROM public.cobro_pago WHERE id = p_cobro_pago_id FOR UPDATE;
  SELECT * INTO c FROM public.cobro WHERE id = pg.cobro_id FOR UPDATE;
  IF pg.confirmacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('cobro_pago_id', pg.id, 'estado_transferencia', pg.estado_transferencia,
                              'asiento_id', pg.asiento_confirmacion_id, 'duplicado', true);
  END IF;
  IF c.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el cobro #% está anulado.', c.numero;
  END IF;
  IF pg.estado_transferencia = 'confirmada' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la transferencia ya fue confirmada (%).', pg.referencia_confirmacion;
  END IF;
  PERFORM interno.exigir_periodo_abierto(c.empresa_id, v_fecha);
  v_asto := interno.asiento_sistema(c.empresa_id, interno.sucursal_activa(c.sucursal_id), v_fecha,
    'Confirmación de transferencia del cobro #' || c.numero || ' en ' || b.nombre || ' ref. ' || v_ref,
    'confirmacion_transferencia_cobro', p_id_operacion,
    jsonb_build_array(
      jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(b.id), 'debe', pg.monto_centavos),
      jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(pg.cuenta_dinero_id), 'haber', pg.monto_centavos)));
  UPDATE public.cobro_pago
     SET estado_transferencia = 'confirmada', banco_id = b.id, referencia_confirmacion = v_ref, fecha_confirmacion = v_fecha,
         asiento_confirmacion_id = v_asto, confirmacion_id_operacion = p_id_operacion, confirmada_por = auth.uid(), confirmada_en = now()
   WHERE id = pg.id
  RETURNING * INTO pg;
  PERFORM interno.rastrear_dinero(v_asto, 'confirmacion_transferencia_cobro', 'cobro', c.id, v_ref, interno.equipo(p_datos));
  RETURN jsonb_build_object('cobro_pago_id', pg.id, 'estado_transferencia', pg.estado_transferencia, 'asiento_id', v_asto,
                            'banco', b.nombre, 'saldo_banco_centavos', interno.saldo_dinero(b.id), 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 8) Condonación (redondeo) explícita
-- ---------------------------------------------------------------------
-- RPC: condonar_saldo_cxc(empresa, {"venta_id"|"saldo_inicial_id","monto_centavos","fecha"?}, motivo, id_operacion)   cobros.condonar
-- Nunca en silencio: permiso propio, motivo y asiento (Dr Saldos condonados / Cr Clientes).
CREATE FUNCTION public.condonar_saldo_cxc(p_empresa_id uuid, p_datos jsonb, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  x       public.cxc_condonacion;
  v_doc   uuid;
  v_esvta boolean;
  v_cli   uuid;
  v_nom   text;
  v_ndoc  text;
  v_suc   uuid;
  v_monto bigint;
  v_saldo bigint;
  v_fecha date;
  v_asto  uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'cobros.condonar', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'condonacion_cxc');
  SELECT * INTO x FROM public.cxc_condonacion c WHERE c.empresa_id = p_empresa_id AND c.id_operacion = p_id_operacion;
  IF x.id IS NOT NULL THEN
    RETURN jsonb_build_object('condonacion_id', x.id, 'numero', x.numero, 'monto_centavos', x.monto_centavos, 'asiento_id', x.asiento_id,
                              'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['venta_id', 'saldo_inicial_id', 'monto_centavos', 'fecha']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se condona el saldo (mínimo 5 letras).';
  END IF;
  v_esvta := p_datos ? 'venta_id';
  v_doc := coalesce(interno.json_uuid(p_datos->'venta_id', 'venta_id'), interno.json_uuid(p_datos->'saldo_inicial_id', 'saldo_inicial_id'));
  IF v_doc IS NULL OR (p_datos ? 'venta_id' AND p_datos ? 'saldo_inicial_id') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique "venta_id" o "saldo_inicial_id" (uno solo).';
  END IF;
  v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  IF v_monto = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el monto a condonar debe ser mayor que cero.';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'condonacion_cxc');
  SELECT * INTO x FROM public.cxc_condonacion c WHERE c.empresa_id = p_empresa_id AND c.id_operacion = p_id_operacion;
  IF x.id IS NOT NULL THEN
    RETURN jsonb_build_object('condonacion_id', x.id, 'numero', x.numero, 'monto_centavos', x.monto_centavos, 'asiento_id', x.asiento_id,
                              'duplicado', true);
  END IF;
  IF v_esvta THEN
    SELECT v.cliente_id, v.cliente_nombre, v.numero_documento, v.sucursal_id INTO v_cli, v_nom, v_ndoc, v_suc FROM public.venta v
     WHERE v.id = v_doc AND v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND v.credito_centavos > 0 FOR UPDATE;
  ELSE
    SELECT s.cliente_id, t.nombre, s.numero_documento, s.sucursal_id INTO v_cli, v_nom, v_ndoc, v_suc
      FROM public.cxc_saldo_inicial s JOIN public.tercero t ON t.id = s.cliente_id
     WHERE s.id = v_doc AND s.empresa_id = p_empresa_id AND s.anulada_en IS NULL FOR UPDATE OF s;
  END IF;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la factura indicada no es una cuenta por cobrar vigente de esta empresa.';
  END IF;
  v_saldo := interno.saldo_documento_cxc(v_doc);
  IF v_monto > v_saldo THEN
    RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: se quieren condonar % y el saldo de la factura % es %.', interno.lempiras(v_monto), v_ndoc, interno.lempiras(v_saldo);
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  x.id := gen_random_uuid();
  x.numero := interno.siguiente_numero(p_empresa_id, 'cxc_condonacion');
  v_asto := interno.asiento_sistema(p_empresa_id, interno.sucursal_activa(v_suc), v_fecha,
    'Condonación #' || x.numero || ' a ' || v_nom || ', factura ' || v_ndoc || ': ' || trim(p_motivo), 'condonacion_cxc', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'condonacion_cxc', 'debe', v_monto, 'descripcion', 'Saldo condonado'),
                      jsonb_build_object('uso', 'cxc', 'haber', v_monto, 'descripcion', 'Rebaja de la factura ' || v_ndoc)));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.cxc_condonacion (id, empresa_id, numero, cliente_id, venta_id, saldo_inicial_id, monto_centavos, motivo,
                                      fecha_contable, asiento_id, id_operacion, creado_por)
  VALUES (x.id, p_empresa_id, x.numero, v_cli, CASE WHEN v_esvta THEN v_doc END, CASE WHEN NOT v_esvta THEN v_doc END, v_monto,
          trim(p_motivo), v_fecha, v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO x;
  INSERT INTO public.cxc_aplicacion (empresa_id, cliente_id, venta_id, saldo_inicial_id, origen, origen_id, monto_centavos, fecha_contable, creado_por)
  VALUES (p_empresa_id, v_cli, x.venta_id, x.saldo_inicial_id, 'condonacion', x.id, v_monto, v_fecha, auth.uid());
  PERFORM set_config('app.motivo', '', true);
  IF v_esvta THEN
    PERFORM interno.recalcular_comision(v_doc, p_id_operacion, v_fecha);
  END IF;
  RETURN jsonb_build_object('condonacion_id', x.id, 'numero', x.numero, 'monto_centavos', v_monto, 'asiento_id', v_asto,
                            'saldo_documento_centavos', interno.saldo_documento_cxc(v_doc), 'duplicado', false);
END $$;

-- RPC: anular_condonacion(condonacion, motivo, id_operacion, fecha?)   cobros.anular
CREATE FUNCTION public.anular_condonacion(p_condonacion_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  x       public.cxc_condonacion;
  v_fecha date;
  v_asto  uuid;
  v_suc   uuid;
BEGIN
  SELECT * INTO x FROM public.cxc_condonacion WHERE id = p_condonacion_id;
  IF x.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la condonación no existe.';
  END IF;
  PERFORM interno.exigir_escritura(x.empresa_id, 'cobros.anular', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(x.empresa_id, p_id_operacion, 'anulacion_condonacion');
  IF x.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('condonacion_id', x.id, 'asiento_id', x.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(x.empresa_id), x.fecha_contable));
  PERFORM interno.exigir_fecha_contable(x.empresa_id, v_fecha);
  IF v_fecha < x.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior a la condonación (%).', to_char(x.fecha_contable, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.reservar_operacion(x.empresa_id, p_id_operacion, 'anulacion_condonacion');
  SELECT * INTO x FROM public.cxc_condonacion WHERE id = p_condonacion_id FOR UPDATE;
  IF x.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('condonacion_id', x.id, 'asiento_id', x.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF x.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: la condonación #% ya fue anulada.', x.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(x.empresa_id, v_fecha);
  SELECT a.sucursal_id INTO v_suc FROM public.asiento a WHERE a.id = x.asiento_id;
  v_asto := interno.asiento_sistema(x.empresa_id, interno.sucursal_activa(v_suc), v_fecha,
    'ANULACIÓN condonación #' || x.numero || ': ' || trim(p_motivo), 'anulacion_condonacion', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'cxc', 'debe', x.monto_centavos, 'descripcion', 'Vuelve el saldo por cobrar'),
                      jsonb_build_object('uso', 'condonacion_cxc', 'haber', x.monto_centavos, 'descripcion', 'Reversión de la condonación')),
    x.asiento_id, trim(p_motivo));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cxc_aplicacion SET anulada_en = now() WHERE origen = 'condonacion' AND origen_id = x.id AND anulada_en IS NULL;
  UPDATE public.cxc_condonacion SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo),
         fecha_anulacion = v_fecha, asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = x.id;
  PERFORM set_config('app.motivo', '', true);
  IF x.venta_id IS NOT NULL THEN
    PERFORM interno.recalcular_comision(x.venta_id, p_id_operacion, v_fecha);
  END IF;
  RETURN jsonb_build_object('condonacion_id', x.id, 'asiento_id', v_asto,
                            'saldo_documento_centavos', interno.saldo_documento_cxc(coalesce(x.venta_id, x.saldo_inicial_id)), 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 9) Saldos iniciales de clientes (contra Saldos de apertura)
-- ---------------------------------------------------------------------
-- RPC: registrar_saldo_inicial_cxc(empresa, datos, id_operacion)   ventas.saldo_inicial (solo el dueño)
-- datos = {"cliente_id":"...","numero_documento":"F-120","fecha_documento":"2025-12-10",
--          "fecha_vencimiento":"2026-01-09" (defecto: + plazo del cliente),"monto_centavos":250000,
--          "fecha":"2026-01-01" (del asiento; defecto: inicio de la empresa),"notas":"..."}
CREATE FUNCTION public.registrar_saldo_inicial_cxc(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_s     public.cxc_saldo_inicial;
  v_cli   public.tercero;
  v_doc   text;
  v_fdoc  date;
  v_venc  date;
  v_fecha date;
  v_monto bigint;
  v_num   bigint;
  v_asto  uuid;
  v_suc   uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.saldo_inicial', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'saldo_inicial_cxc');
  SELECT * INTO v_s FROM public.cxc_saldo_inicial WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_s.id IS NOT NULL THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'numero', v_s.numero, 'asiento_id', v_s.asiento_id,
                              'monto_centavos', v_s.monto_centavos, 'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cliente_id', 'numero_documento', 'fecha_documento', 'fecha_vencimiento',
                                               'monto_centavos', 'fecha', 'notas']);
  v_cli := interno.cliente_de(p_empresa_id, p_datos->'cliente_id', true);
  v_doc := interno.json_texto(p_datos->'numero_documento', 'numero_documento', 50);
  IF v_doc IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el número de la factura que el cliente debe.';
  END IF;
  v_fdoc := interno.json_fecha(p_datos->'fecha_documento', 'fecha_documento');
  IF v_fdoc IS NULL OR v_fdoc < '2000-01-01' THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique la fecha de la factura ("fecha_documento", AAAA-MM-DD).';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), (SELECT e.fecha_inicio FROM public.empresa e WHERE e.id = p_empresa_id));
  v_venc := coalesce(interno.json_fecha(p_datos->'fecha_vencimiento', 'fecha_vencimiento'), v_fdoc + v_cli.plazo_dias);
  IF v_venc < v_fdoc THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el vencimiento no puede ser antes de la fecha de la factura.';
  END IF;
  IF v_fdoc > v_fecha THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la factura (%) no puede ser posterior a la fecha de apertura (%); si es nueva, regístrela como venta al crédito.',
      to_char(v_fdoc, 'DD/MM/YYYY'), to_char(v_fecha, 'DD/MM/YYYY');
  END IF;
  v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  IF v_monto = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el monto pendiente debe ser mayor que cero.';
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'saldo_inicial_cxc');
  SELECT * INTO v_s FROM public.cxc_saldo_inicial WHERE empresa_id = p_empresa_id AND id_operacion = p_id_operacion;
  IF v_s.id IS NOT NULL THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'numero', v_s.numero, 'asiento_id', v_s.asiento_id,
                              'monto_centavos', v_s.monto_centavos, 'duplicado', true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.cxc_saldo_inicial x WHERE x.empresa_id = p_empresa_id AND x.cliente_id = v_cli.id
              AND upper(x.numero_documento) = upper(v_doc) AND x.anulada_en IS NULL) THEN
    RAISE EXCEPTION 'YA_EXISTE: la factura % de este cliente ya está registrada como saldo inicial.', v_doc;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  SELECT s.id INTO v_suc FROM public.sucursal s WHERE s.empresa_id = p_empresa_id AND s.activa ORDER BY s.codigo LIMIT 1;
  v_num := interno.siguiente_numero(p_empresa_id, 'cxc_saldo_inicial');
  v_asto := interno.asiento_sistema(p_empresa_id, v_suc, v_fecha,
    'Saldo inicial #' || v_num || ' por cobrar a ' || v_cli.nombre || ', factura ' || v_doc || ' del ' || to_char(v_fdoc, 'DD/MM/YYYY'),
    'saldo_inicial_cxc', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'cxc', 'debe', v_monto),
                      jsonb_build_object('uso', 'apertura_cxc', 'haber', v_monto)));
  INSERT INTO public.cxc_saldo_inicial (empresa_id, numero, cliente_id, numero_documento, fecha_documento, fecha_contable,
    fecha_vencimiento, monto_centavos, sucursal_id, notas, asiento_id, id_operacion, creado_por)
  VALUES (p_empresa_id, v_num, v_cli.id, v_doc, v_fdoc, v_fecha, v_venc, v_monto, v_suc,
    interno.json_texto(p_datos->'notas', 'notas', 500), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO v_s;
  RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'numero', v_num, 'asiento_id', v_asto, 'monto_centavos', v_monto,
                            'saldo_cliente_centavos', interno.saldo_cxc_cliente(p_empresa_id, v_cli.id), 'duplicado', false);
END $$;

-- RPC: anular_saldo_inicial_cxc(saldo_inicial, motivo, id_operacion, fecha?)   ventas.saldo_inicial
-- Solo sin cobros ni condonaciones vigentes (anúlelos primero).
CREATE FUNCTION public.anular_saldo_inicial_cxc(p_saldo_inicial_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_s     public.cxc_saldo_inicial;
  v_fecha date;
  v_cta   text;
  v_asto  uuid;
BEGIN
  SELECT * INTO v_s FROM public.cxc_saldo_inicial WHERE id = p_saldo_inicial_id;
  IF v_s.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el saldo inicial no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v_s.empresa_id, 'ventas.saldo_inicial', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v_s.empresa_id, p_id_operacion, 'anulacion_saldo_inicial_cxc');
  IF v_s.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'asiento_id', v_s.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(v_s.empresa_id), v_s.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v_s.empresa_id, v_fecha);
  IF v_fecha < v_s.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al saldo inicial (%).', to_char(v_s.fecha_contable, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.reservar_operacion(v_s.empresa_id, p_id_operacion, 'anulacion_saldo_inicial_cxc');
  SELECT * INTO v_s FROM public.cxc_saldo_inicial WHERE id = p_saldo_inicial_id FOR UPDATE;
  IF v_s.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'asiento_id', v_s.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF v_s.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el saldo inicial #% ya fue anulado.', v_s.numero;
  END IF;
  IF interno.rebajas_cxc(v_s.id) > 0 THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el saldo inicial #% tiene cobros o condonaciones; anúlelos primero.', v_s.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(v_s.empresa_id, v_fecha);
  SELECT c.codigo INTO v_cta FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
   WHERE l.asiento_id = v_s.asiento_id AND l.haber_centavos > 0 ORDER BY l.linea LIMIT 1;
  v_asto := interno.asiento_sistema(v_s.empresa_id, v_s.sucursal_id, v_fecha,
    'ANULACIÓN saldo inicial de cliente #' || v_s.numero || ' (factura ' || v_s.numero_documento || '): ' || trim(p_motivo),
    'anulacion_saldo_inicial_cxc', p_id_operacion,
    jsonb_build_array(jsonb_build_object('cuenta', v_cta, 'debe', v_s.monto_centavos),
                      jsonb_build_object('uso', 'cxc', 'haber', v_s.monto_centavos)),
    v_s.asiento_id, trim(p_motivo));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cxc_saldo_inicial
     SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo),
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion, fecha_anulacion = v_fecha
   WHERE id = v_s.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('saldo_inicial_id', v_s.id, 'asiento_id', v_asto, 'duplicado', false);
END $$;

-- RPC: consultar_vale(empresa, codigo)   ventas.vender: saldo y vencimiento de un vale (para cobrar con él).
CREATE FUNCTION public.consultar_vale(p_empresa_id uuid, p_codigo text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.saldo_favor;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.vender');
  SELECT * INTO s FROM public.saldo_favor x WHERE x.empresa_id = p_empresa_id AND x.codigo = upper(trim(coalesce(p_codigo, '')));
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'VALE_INVALIDO: el vale % no existe.', upper(trim(coalesce(p_codigo, '')));
  END IF;
  RETURN jsonb_build_object('saldo_favor_id', s.id, 'codigo', s.codigo, 'monto_centavos', s.monto_centavos,
    'saldo_centavos', interno.saldo_favor_lote(s.id), 'vence_el', to_char(s.vence_el, 'YYYY-MM-DD'),
    'estado', CASE WHEN s.anulada_en IS NOT NULL THEN 'anulado' WHEN s.vence_el < public.hoy_local(p_empresa_id) THEN 'vencido'
                   WHEN interno.saldo_favor_lote(s.id) = 0 THEN 'usado' ELSE 'vigente' END);
END $$;

-- ---------------------------------------------------------------------
-- 10) Lecturas
-- ---------------------------------------------------------------------
-- CxC por factura (reemplaza la de 029: mismas columnas; ahora con cobros y
-- saldos iniciales; al final condonado y devuelto).
CREATE OR REPLACE VIEW public.v_cxc_documento AS
  SELECT v.empresa_id, v.id AS venta_id, v.numero_documento, v.cliente_id, v.cliente_nombre, v.cliente_rtn,
         v.fecha_contable AS fecha_documento, v.vence_el, v.total_centavos, v.credito_centavos,
         coalesce(r.cobrado, 0)::bigint AS cobrado_centavos,
         (v.credito_centavos - coalesce(r.cobrado, 0) - coalesce(r.condonado, 0) - coalesce(r.devuelto, 0))::bigint AS saldo_centavos,
         public.hoy_local(v.empresa_id) - v.fecha_contable AS dias,
         greatest(public.hoy_local(v.empresa_id) - v.vence_el, 0) AS dias_vencido,
         'venta'::text AS origen, v.id AS documento_id,
         coalesce(r.condonado, 0)::bigint AS condonado_centavos, coalesce(r.devuelto, 0)::bigint AS devuelto_centavos
  FROM public.venta v
  LEFT JOIN LATERAL (SELECT sum(a.monto_centavos) FILTER (WHERE a.origen = 'cobro') AS cobrado,
                            sum(a.monto_centavos) FILTER (WHERE a.origen = 'condonacion') AS condonado,
                            sum(a.monto_centavos) FILTER (WHERE a.origen = 'devolucion') AS devuelto
                       FROM public.cxc_aplicacion a WHERE a.venta_id = v.id AND a.anulada_en IS NULL) r ON true
  WHERE v.estado = 'emitida' AND v.credito_centavos > 0
    AND v.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
  UNION ALL
  SELECT s.empresa_id, NULL::uuid, s.numero_documento, s.cliente_id, t.nombre, t.rtn,
         s.fecha_documento, s.fecha_vencimiento, s.monto_centavos, s.monto_centavos,
         coalesce(r.cobrado, 0)::bigint,
         (s.monto_centavos - coalesce(r.cobrado, 0) - coalesce(r.condonado, 0) - coalesce(r.devuelto, 0))::bigint,
         public.hoy_local(s.empresa_id) - s.fecha_documento,
         greatest(public.hoy_local(s.empresa_id) - s.fecha_vencimiento, 0),
         'saldo_inicial'::text, s.id,
         coalesce(r.condonado, 0)::bigint, coalesce(r.devuelto, 0)::bigint
  FROM public.cxc_saldo_inicial s
  JOIN public.tercero t ON t.id = s.cliente_id
  LEFT JOIN LATERAL (SELECT sum(a.monto_centavos) FILTER (WHERE a.origen = 'cobro') AS cobrado,
                            sum(a.monto_centavos) FILTER (WHERE a.origen = 'condonacion') AS condonado,
                            sum(a.monto_centavos) FILTER (WHERE a.origen = 'devolucion') AS devuelto
                       FROM public.cxc_aplicacion a WHERE a.saldo_inicial_id = s.id AND a.anulada_en IS NULL) r ON true
  WHERE s.anulada_en IS NULL
    AND s.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')));

-- Cobros (con ventas.ver todos; si no, los que uno registró).
CREATE VIEW public.v_cobro AS
  SELECT c.empresa_id, c.id AS cobro_id, c.numero, c.tipo, c.fecha_contable, c.cliente_id, t.nombre AS cliente,
         c.caja_id, cj.nombre AS caja, c.creado_por, public.nombre_usuario(c.empresa_id, c.creado_por) AS cajero,
         c.monto_centavos, c.aplicado_centavos, c.excedente_centavos, c.apartado_id, c.referencia,
         (SELECT string_agg(p.forma, '+' ORDER BY p.linea) FROM public.cobro_pago p WHERE p.cobro_id = c.id) AS formas,
         c.anulada_en IS NOT NULL AS anulado, c.motivo_anulacion, c.fecha_anulacion, c.asiento_id, c.registrado_en
  FROM public.cobro c
  JOIN public.tercero t ON t.id = c.cliente_id
  LEFT JOIN public.caja cj ON cj.id = c.caja_id
  WHERE c.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
     OR (c.empresa_id IN (SELECT public.mis_empresas()) AND c.creado_por = (SELECT auth.uid()));

-- Cobros del día por caja y cajero (sin anulados), por forma de pago.
CREATE VIEW public.v_cobros_por_caja AS
  SELECT c.empresa_id, c.fecha_contable AS fecha, c.caja_id, cj.nombre AS caja, c.creado_por AS cajero_id,
         public.nombre_usuario(c.empresa_id, c.creado_por) AS cajero,
         count(DISTINCT c.id) AS cobros,
         sum(p.monto_centavos)::bigint AS total_centavos,
         coalesce(sum(p.monto_centavos) FILTER (WHERE p.forma = 'efectivo'), 0)::bigint AS efectivo_centavos,
         coalesce(sum(p.monto_centavos) FILTER (WHERE p.forma = 'tarjeta'), 0)::bigint AS tarjeta_centavos,
         coalesce(sum(p.monto_centavos) FILTER (WHERE p.forma = 'transferencia'), 0)::bigint AS transferencia_centavos,
         coalesce(sum(p.monto_centavos) FILTER (WHERE p.forma = 'saldo_favor'), 0)::bigint AS saldo_favor_centavos
  FROM public.cobro c
  JOIN public.cobro_pago p ON p.cobro_id = c.id
  LEFT JOIN public.caja cj ON cj.id = c.caja_id
  WHERE c.anulada_en IS NULL AND c.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
  GROUP BY c.empresa_id, c.fecha_contable, c.caja_id, cj.nombre, c.creado_por;

-- Saldos a favor y vales (lote por lote).
CREATE VIEW public.v_saldo_favor AS
  SELECT s.empresa_id, s.id AS saldo_favor_id, s.numero, s.cliente_id, t.nombre AS cliente, s.codigo, s.origen,
         s.documento_tipo, s.documento_id, s.fecha_contable, s.vence_el, s.monto_centavos,
         (s.monto_centavos - coalesce((SELECT sum(u.monto_centavos) FROM public.saldo_favor_uso u
                                        WHERE u.saldo_favor_id = s.id AND u.anulado_en IS NULL), 0))::bigint AS saldo_centavos,
         CASE WHEN s.anulada_en IS NOT NULL THEN 'anulado'
              WHEN s.vence_el < public.hoy_local(s.empresa_id) THEN 'vencido'
              WHEN s.monto_centavos = coalesce((SELECT sum(u.monto_centavos) FROM public.saldo_favor_uso u
                                                 WHERE u.saldo_favor_id = s.id AND u.anulado_en IS NULL), 0) THEN 'usado'
              ELSE 'vigente' END AS estado
  FROM public.saldo_favor s
  LEFT JOIN public.tercero t ON t.id = s.cliente_id
  WHERE s.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')));

GRANT SELECT ON public.v_cobro, public.v_cobros_por_caja, public.v_saldo_favor TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 11) id_operacion por tipo: registro como DATOS (las etapas siguientes
--     solo agregan filas). tipo_operacion_2b (reemplaza la de 032; mismo
--     resultado) pregunta al final a interno.tipo_operacion_2b2.
-- ---------------------------------------------------------------------
CREATE TABLE interno.id_operacion_uso (
  tabla    text NOT NULL CHECK (tabla ~ '^[a-z_0-9]+$'),
  columna  text NOT NULL CHECK (columna ~ '^[a-z_0-9]+$'),
  tipo     text NOT NULL,
  orden    integer NOT NULL,
  PRIMARY KEY (tabla, columna)
);
INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('cobro',             'id_operacion',              'cobro',                            10),
  ('cobro',             'anulacion_id_operacion',    'anulacion_cobro',                  11),
  ('cobro_pago',        'confirmacion_id_operacion', 'confirmacion_transferencia_cobro', 12),
  ('cxc_condonacion',   'id_operacion',              'condonacion_cxc',                  13),
  ('cxc_condonacion',   'anulacion_id_operacion',    'anulacion_condonacion',            14),
  ('cxc_saldo_inicial', 'id_operacion',              'saldo_inicial_cxc',                15),
  ('cxc_saldo_inicial', 'anulacion_id_operacion',    'anulacion_saldo_inicial_cxc',      16);

CREATE FUNCTION interno.tipo_operacion_2b2(p_empresa_id uuid, p_id uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r     record;
  v_hay boolean;
BEGIN
  FOR r IN SELECT * FROM interno.id_operacion_uso ORDER BY orden LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I x WHERE x.empresa_id = $1 AND x.%I = $2)', r.tabla, r.columna)
      INTO v_hay USING p_empresa_id, p_id;
    IF v_hay THEN
      RETURN r.tipo;
    END IF;
  END LOOP;
  RETURN NULL;
END $$;

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
  IF EXISTS (SELECT 1 FROM public.solicitud_proveedor x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'solicitud_proveedor';
  END IF;
  RETURN interno.tipo_operacion_2b2(p_empresa_id, p_id);
END $$;

-- Adjuntos también a cobros y saldos iniciales de clientes (reemplaza la de 029).
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
    WHEN 'cobro'            THEN (SELECT x.empresa_id FROM public.cobro x WHERE x.id = p_id)
    WHEN 'cxc_saldo_inicial' THEN (SELECT x.empresa_id FROM public.cxc_saldo_inicial x WHERE x.id = p_id)
  END;
END $$;

-- ---------------------------------------------------------------------
-- 12) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.proteger_anulable(),
  interno.proteger_cobro_pago(),
  interno.rebajas_cxc(uuid),
  interno.saldo_documento_cxc(uuid),
  interno.saldo_favor_lote(uuid),
  interno.saldo_favor_cliente(uuid, uuid),
  interno.total_saldo_favor(uuid),
  interno.crear_saldo_favor(uuid, uuid, text, text, uuid, bigint, date),
  interno.usar_saldo_favor(uuid, uuid, text, bigint, text, uuid, date),
  interno.devolver_usos_saldo_favor(uuid, text),
  interno.anular_saldo_favor(uuid, text),
  interno.tipo_operacion_2b2(uuid, uuid),
  interno.recalcular_comision(uuid, uuid, date),
  interno.validar_anulacion_cobro(public.cobro),
  interno.codigo_cuenta_dinero(uuid),
  interno.cliente_de(uuid, jsonb, boolean),
  interno.cobro_respuesta(public.cobro, boolean),
  interno.registrar_cobro_base(uuid, jsonb, uuid, uuid, bigint)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.registrar_cobro(uuid, jsonb, uuid),
  public.anular_cobro(uuid, text, uuid, date),
  public.confirmar_transferencia_cobro(uuid, jsonb, uuid),
  public.condonar_saldo_cxc(uuid, jsonb, text, uuid),
  public.anular_condonacion(uuid, text, uuid, date),
  public.registrar_saldo_inicial_cxc(uuid, jsonb, uuid),
  public.anular_saldo_inicial_cxc(uuid, text, uuid, date),
  public.consultar_vale(uuid, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.registrar_cobro(uuid, jsonb, uuid),
  public.anular_cobro(uuid, text, uuid, date),
  public.confirmar_transferencia_cobro(uuid, jsonb, uuid),
  public.condonar_saldo_cxc(uuid, jsonb, text, uuid),
  public.anular_condonacion(uuid, text, uuid, date),
  public.registrar_saldo_inicial_cxc(uuid, jsonb, uuid),
  public.anular_saldo_inicial_cxc(uuid, text, uuid, date),
  public.consultar_vale(uuid, text)
TO authenticated;
