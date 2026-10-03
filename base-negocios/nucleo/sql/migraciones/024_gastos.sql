-- =====================================================================
-- 024_gastos.sql  -  Núcleo 0.5.0 (etapa 2b-1): gastos, aprobaciones,
-- caja chica y pagos fijos
--
--   categoria_gasto     cada categoría va a una cuenta de gasto (6.x) o costo (5.x)
--   tope_rol            topes por puesto (los fija el dueño): hasta cuánto se
--                       registra sin aprobación y hasta cuánto se aprueba
--   aprobacion          tabla GENÉRICA de aprobaciones (tipo, documento,
--                       solicitante, aprobador, estado, motivo); la usa el
--                       gasto y la usará la etapa 2b-2 (crédito, descuentos, anulaciones)
--   gasto               de qué cuenta de dinero sale, categoría, monto, ISV
--                       crédito fiscal (con datos de la factura), proveedor y
--                       comprobante. Todo o nada. Si pasa el tope del puesto
--                       queda "pendiente_aprobacion" SIN mover dinero.
--   pago_fijo           plantillas (alquiler, luz, planilla...): próximos y
--                       vencidos; registrar_pago_fijo genera un gasto REAL con
--                       el monto real (nunca se descuenta solo).
--   Caja chica: cuadre_caja_chica (fondo, gastos con y sin comprobante,
--   efectivo esperado) y su reposición con trasladar_dinero (022).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('TOPE_APROBACION', 'El monto pasa el tope que usted puede aprobar.', 'Pida que lo apruebe el dueño (o alguien con un tope mayor).');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('gastos.registrar', 'Registrar gastos y pagos fijos (sobre el tope del puesto quedan pendientes de aprobación)', true, false),
  ('gastos.aprobar',   'Aprobar o rechazar gastos pendientes, hasta el tope del puesto', true, false),
  ('gastos.anular',    'Anular gastos (contra-asiento)', true, false),
  ('aprobaciones.ver', 'Ver las solicitudes de aprobación de la empresa', false, true);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'gastos.registrar'), ('dueno', 'gastos.aprobar'), ('dueno', 'gastos.anular'), ('dueno', 'aprobaciones.ver'),
  ('admin', 'gastos.registrar'), ('admin', 'gastos.aprobar'), ('admin', 'gastos.anular'), ('admin', 'aprobaciones.ver'),
  ('contador', 'aprobaciones.ver');
SELECT interno.repartir_permisos(ARRAY['gastos.registrar', 'gastos.aprobar', 'gastos.anular', 'aprobaciones.ver'],
  'Núcleo 0.5.0: gastos y aprobaciones');

-- Topes por defecto (el dueño los cambia con configurar_tope_rol). El dueño
-- no tiene tope. Puesto sin fila = 0: todo gasto suyo pide aprobación y no aprueba.
CREATE TABLE interno.plantilla_tope_rol (
  rol                      text NOT NULL REFERENCES public.rol(codigo),
  tipo                     text NOT NULL,
  sin_aprobacion_centavos  bigint NOT NULL,
  aprueba_hasta_centavos   bigint NOT NULL,
  PRIMARY KEY (rol, tipo)
);
INSERT INTO interno.plantilla_tope_rol VALUES ('admin', 'gasto', 500000, 500000);   -- L 5,000.00

-- ---------------------------------------------------------------------
-- 1) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.categoria_gasto (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  nombre      text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 100),
  cuenta_id   uuid NOT NULL,
  activa      boolean NOT NULL DEFAULT true,
  creado_por  uuid,
  creado_en   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_id) REFERENCES public.cuenta(empresa_id, id)
);
CREATE UNIQUE INDEX categoria_gasto_nombre ON public.categoria_gasto (empresa_id, lower(nombre));

CREATE TABLE public.tope_rol (
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  rol                      text NOT NULL REFERENCES public.rol(codigo),
  tipo                     text NOT NULL CHECK (tipo IN ('gasto')),
  sin_aprobacion_centavos  bigint NOT NULL CHECK (sin_aprobacion_centavos BETWEEN 0 AND 9007199254740991),
  aprueba_hasta_centavos   bigint NOT NULL CHECK (aprueba_hasta_centavos BETWEEN 0 AND 9007199254740991),
  actualizado_por          uuid,
  actualizado_en           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (empresa_id, rol, tipo)
);

CREATE TABLE public.aprobacion (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  tipo                     text NOT NULL CHECK (tipo ~ '^[a-z_]{3,40}$'),       -- gasto (2b-2: credito, descuento, anulacion_venta...)
  documento_tipo           text NOT NULL,
  documento_id             uuid NOT NULL,
  monto_centavos           bigint NOT NULL CHECK (monto_centavos BETWEEN 0 AND 9007199254740991),
  descripcion              text NOT NULL,
  solicitado_por           uuid,
  rol_solicitante          text,
  solicitado_en            timestamptz NOT NULL DEFAULT now(),
  estado                   text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'aprobada', 'rechazada', 'cancelada')),
  resuelto_por             uuid,
  rol_resolutor            text,
  resuelto_en              timestamptz,
  motivo_resolucion        text,
  resolucion_id_operacion  uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (documento_tipo, documento_id),
  CHECK ((estado = 'pendiente') = (resuelto_en IS NULL))
);
CREATE INDEX aprobacion_pendiente ON public.aprobacion (empresa_id, solicitado_en) WHERE estado = 'pendiente';

CREATE TABLE public.pago_fijo (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                uuid NOT NULL REFERENCES public.empresa(id),
  nombre                    text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 100),
  categoria_id              uuid NOT NULL,
  monto_estimado_centavos   bigint NOT NULL CHECK (monto_estimado_centavos BETWEEN 0 AND 9007199254740991),
  frecuencia                text NOT NULL CHECK (frecuencia IN ('mensual', 'semanal')),
  cada                      integer NOT NULL DEFAULT 1,     -- cada N meses (1-12) o N semanas (1-52)
  dia                       integer NOT NULL,               -- día del mes (1-31) o de la semana (1 lunes .. 7 domingo)
  fecha_inicio              date NOT NULL,                  -- desde cuándo cuenta (primer vencimiento en o después)
  cuenta_dinero_id          uuid,                           -- de dónde se suele pagar (sugerida)
  notas                     text,
  activo                    boolean NOT NULL DEFAULT true,
  creado_por                uuid,
  creado_en                 timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, categoria_id)     REFERENCES public.categoria_gasto(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id) REFERENCES public.cuenta_dinero(empresa_id, id),
  CHECK ((frecuencia = 'mensual' AND cada BETWEEN 1 AND 12 AND dia BETWEEN 1 AND 31)
      OR (frecuencia = 'semanal' AND cada BETWEEN 1 AND 52 AND dia BETWEEN 1 AND 7))
);
CREATE UNIQUE INDEX pago_fijo_nombre ON public.pago_fijo (empresa_id, lower(nombre));

CREATE TABLE public.gasto (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id              uuid NOT NULL REFERENCES public.empresa(id),
  numero                  bigint NOT NULL,
  sucursal_id             uuid,
  fecha_contable          date NOT NULL,
  cuenta_dinero_id        uuid NOT NULL,           -- de dónde sale el dinero
  categoria_id            uuid NOT NULL,
  proveedor_id            uuid,
  descripcion             text NOT NULL CHECK (length(trim(descripcion)) BETWEEN 1 AND 300),
  monto_centavos          bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),   -- total pagado
  isv_centavos            bigint NOT NULL DEFAULT 0 CHECK (isv_centavos >= 0),                    -- crédito fiscal (dentro del total)
  numero_documento        text,                    -- factura del proveedor
  fecha_documento         date,
  rtn_emisor              text CHECK (rtn_emisor IS NULL OR rtn_emisor ~ '^[0-9]{14}$'),
  cai                     text,
  pago_fijo_id            uuid,
  pago_fijo_vence_el      date,
  estado                  text NOT NULL CHECK (estado IN ('pendiente_aprobacion', 'aplicado', 'rechazado', 'anulado')),
  aprobacion_id           uuid,
  asiento_id              uuid,
  aplicado_en             timestamptz,
  aplicado_por            uuid,
  equipo                  text,
  id_operacion            uuid NOT NULL,
  creado_por              uuid,
  registrado_en           timestamptz NOT NULL DEFAULT now(),
  anulado_en              timestamptz,
  anulado_por             uuid,
  motivo_anulacion        text,
  fecha_anulacion         date,
  asiento_anulacion_id    uuid,
  anulacion_id_operacion  uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, sucursal_id)          REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id)     REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, categoria_id)         REFERENCES public.categoria_gasto(empresa_id, id),
  FOREIGN KEY (empresa_id, proveedor_id)         REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, pago_fijo_id)         REFERENCES public.pago_fijo(empresa_id, id),
  FOREIGN KEY (empresa_id, aprobacion_id)        REFERENCES public.aprobacion(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK (isv_centavos < monto_centavos),
  CHECK (isv_centavos = 0 OR numero_documento IS NOT NULL),
  CHECK ((pago_fijo_id IS NULL) = (pago_fijo_vence_el IS NULL)),
  CHECK ((asiento_id IS NULL) = (aplicado_en IS NULL)),
  CHECK (estado NOT IN ('pendiente_aprobacion', 'rechazado') OR asiento_id IS NULL),
  CHECK (estado <> 'aplicado' OR asiento_id IS NOT NULL),
  CHECK ((estado = 'anulado') = (anulado_en IS NOT NULL)),
  CHECK ((asiento_anulacion_id IS NULL) OR (estado = 'anulado' AND asiento_id IS NOT NULL))
);
CREATE INDEX gasto_empresa_fecha ON public.gasto (empresa_id, fecha_contable);
CREATE INDEX gasto_cuenta ON public.gasto (cuenta_dinero_id);
-- Un vencimiento de un pago fijo se paga una sola vez (salvo rechazado o anulado).
CREATE UNIQUE INDEX gasto_pago_fijo_vencimiento ON public.gasto (pago_fijo_id, pago_fijo_vence_el)
  WHERE estado IN ('pendiente_aprobacion', 'aplicado');

-- Defensas de tabla
CREATE FUNCTION interno.proteger_gasto() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_mut constant text[] := ARRAY['estado', 'asiento_id', 'aplicado_en', 'aplicado_por', 'fecha_contable',
    'anulado_en', 'anulado_por', 'motivo_anulacion', 'fecha_anulacion', 'asiento_anulacion_id', 'anulacion_id_operacion'];
BEGIN
  IF (to_jsonb(NEW) - c_mut) IS DISTINCT FROM (to_jsonb(OLD) - c_mut) THEN
    RAISE EXCEPTION 'PROHIBIDO: un gasto no se edita; se aprueba, se rechaza o se anula.';
  END IF;
  IF OLD.estado = 'pendiente_aprobacion' AND NEW.estado IN ('aplicado', 'rechazado', 'anulado') THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'aplicado' AND NEW.estado = 'anulado'
     AND (NEW.asiento_id, NEW.aplicado_en, NEW.aplicado_por, NEW.fecha_contable)
         IS NOT DISTINCT FROM (OLD.asiento_id, OLD.aplicado_en, OLD.aplicado_por, OLD.fecha_contable) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: un gasto no se edita; se aprueba, se rechaza o se anula una sola vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.gasto FOR EACH ROW EXECUTE FUNCTION interno.proteger_gasto();

CREATE FUNCTION interno.proteger_aprobacion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c_mut constant text[] := ARRAY['estado', 'resuelto_por', 'rol_resolutor', 'resuelto_en', 'motivo_resolucion', 'resolucion_id_operacion'];
BEGIN
  IF OLD.estado = 'pendiente' AND NEW.estado <> 'pendiente'
     AND (to_jsonb(NEW) - c_mut) = (to_jsonb(OLD) - c_mut) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una aprobación no se edita; se resuelve una sola vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.aprobacion FOR EACH ROW EXECUTE FUNCTION interno.proteger_aprobacion();

CREATE TRIGGER proteger BEFORE UPDATE ON public.categoria_gasto FOR EACH ROW EXECUTE FUNCTION interno.proteger_catalogo();

CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.categoria_gasto FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.tope_rol        FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.aprobacion      FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.pago_fijo       FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.gasto           FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.categoria_gasto
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la categoría en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.tope_rol
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los topes se cambian, no se borran.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.aprobacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las aprobaciones no se borran.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.pago_fijo
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive el pago fijo en vez de borrarlo.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.gasto
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los gastos no se borran: se anulan.');

-- ---------------------------------------------------------------------
-- 2) Ayudantes
-- ---------------------------------------------------------------------
-- Topes de un puesto (fila de la empresa, si no la plantilla, si no 0).
CREATE FUNCTION interno.tope_rol(p_empresa_id uuid, p_rol text, p_tipo text,
                                 OUT sin_aprobacion bigint, OUT aprueba_hasta bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(t.sin_aprobacion_centavos, p.sin_aprobacion_centavos, 0),
         coalesce(t.aprueba_hasta_centavos, p.aprueba_hasta_centavos, 0)
    FROM (SELECT 1) x
    LEFT JOIN public.tope_rol t ON t.empresa_id = p_empresa_id AND t.rol = p_rol AND t.tipo = p_tipo
    LEFT JOIN interno.plantilla_tope_rol p ON p.rol = p_rol AND p.tipo = p_tipo
$$;

CREATE FUNCTION interno.gasto_respuesta(g public.gasto, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('gasto_id', g.id, 'numero', g.numero, 'estado', g.estado, 'monto_centavos', g.monto_centavos,
    'isv_centavos', g.isv_centavos, 'asiento_id', g.asiento_id, 'aprobacion_id', g.aprobacion_id,
    'saldo_cuenta_centavos', interno.saldo_dinero(g.cuenta_dinero_id), 'duplicado', p_duplicado)
$$;

-- Mueve el dinero de un gasto: asiento + rastro. Dr gasto (sin ISV), Dr ISV
-- crédito fiscal / Cr la cuenta de dinero (el total).
CREATE FUNCTION interno.aplicar_gasto(g public.gasto, p_fecha date, p_id_operacion uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d      public.cuenta_dinero;
  v_cat  record;
  v_asto uuid;
BEGIN
  d := interno.cuenta_dinero_para_pagar(g.empresa_id, g.cuenta_dinero_id);
  SELECT cg.nombre, c.codigo INTO v_cat FROM public.categoria_gasto cg JOIN public.cuenta c ON c.id = cg.cuenta_id
   WHERE cg.id = g.categoria_id;
  PERFORM interno.exigir_periodo_abierto(g.empresa_id, p_fecha);
  v_asto := interno.asiento_sistema(g.empresa_id, interno.sucursal_activa(g.sucursal_id), p_fecha,
    'Gasto #' || g.numero || ' (' || v_cat.nombre || '): ' || g.descripcion
      || coalesce(', factura ' || g.numero_documento, ''),
    'gasto', p_id_operacion,
    jsonb_build_array(
      jsonb_build_object('cuenta', v_cat.codigo, 'debe', g.monto_centavos - g.isv_centavos, 'descripcion', g.descripcion),
      jsonb_build_object('uso', 'isv_credito', 'debe', g.isv_centavos, 'descripcion', 'ISV crédito fiscal'),
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id), 'haber', g.monto_centavos)));
  PERFORM interno.rastrear_dinero(v_asto, 'gasto', 'gasto', g.id, coalesce(g.numero_documento, g.descripcion), g.equipo);
  RETURN v_asto;
END $$;

-- Registra un gasto (lo usan registrar_gasto y registrar_pago_fijo).
-- datos = {"cuenta_dinero_id","categoria_id","monto_centavos","isv_centavos"?,"descripcion",
--          "fecha"? (hoy),"proveedor_id"?,"sucursal_id"?,
--          "documento"?: {"numero":"000-001-01-00012345","fecha":"2026-01-10","rtn":"0801...","cai":"..."},
--          "comprobante"?: {"ruta","tipo","sha256"}, "equipo"?}
CREATE FUNCTION interno.registrar_gasto_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_pago_fijo_id uuid DEFAULT NULL, p_vence_el date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  g       public.gasto;
  d       public.cuenta_dinero;
  v_cat   public.categoria_gasto;
  v_prov  public.tercero;
  v_doc   jsonb;
  v_rtn   text;
  v_suc   uuid;
  v_rol   text := public.mi_rol(p_empresa_id);
  v_tope  record;
  v_apr   uuid;
  v_prev  uuid;
BEGIN
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'gasto');
  SELECT * INTO g FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF g.id IS NOT NULL THEN
    RETURN interno.gasto_respuesta(g, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cuenta_dinero_id', 'categoria_id', 'monto_centavos', 'isv_centavos',
    'descripcion', 'fecha', 'proveedor_id', 'sucursal_id', 'documento', 'comprobante', 'equipo']);

  g.empresa_id := p_empresa_id;
  d := interno.cuenta_dinero_para_pagar(p_empresa_id, interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id'));
  g.cuenta_dinero_id := d.id;
  SELECT * INTO v_cat FROM public.categoria_gasto x
   WHERE x.id = interno.json_uuid(p_datos->'categoria_id', 'categoria_id') AND x.empresa_id = p_empresa_id AND x.activa;
  IF v_cat.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la categoría de gasto no existe en esta empresa o está desactivada.';
  END IF;
  g.categoria_id := v_cat.id;
  g.monto_centavos := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  IF g.monto_centavos = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el monto del gasto debe ser mayor que cero.';
  END IF;
  g.isv_centavos := CASE WHEN p_datos ? 'isv_centavos' THEN interno.json_centavos(p_datos->'isv_centavos', 'isv_centavos') ELSE 0 END;
  IF g.isv_centavos >= g.monto_centavos THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el ISV debe ser menor que el total del gasto.';
  END IF;
  g.descripcion := interno.json_texto(p_datos->'descripcion', 'descripcion', 300);
  IF g.descripcion IS NULL THEN
    RAISE EXCEPTION 'FALTA_DESCRIPCION: escriba de qué es el gasto.';
  END IF;
  g.fecha_contable := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, g.fecha_contable);
  IF p_datos ? 'proveedor_id' AND p_datos->'proveedor_id' <> 'null'::jsonb THEN
    SELECT * INTO v_prov FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_datos->'proveedor_id', 'proveedor_id') AND t.empresa_id = p_empresa_id;
    IF v_prov.id IS NULL OR NOT v_prov.es_proveedor OR NOT v_prov.activo THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el proveedor no existe, no está marcado como proveedor o está desactivado.';
    END IF;
    g.proveedor_id := v_prov.id;
  END IF;
  v_suc := interno.json_uuid(p_datos->'sucursal_id', 'sucursal_id');
  IF v_suc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = v_suc AND s.empresa_id = p_empresa_id AND s.activa) THEN
    RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal no existe en esta empresa o está desactivada.';
  END IF;
  g.sucursal_id := coalesce(v_suc, interno.sucursal_activa(d.sucursal_id));
  v_doc := p_datos->'documento';
  IF v_doc IS NOT NULL AND v_doc <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(v_doc, ARRAY['numero', 'fecha', 'rtn', 'cai']);
    g.numero_documento := interno.json_texto(v_doc->'numero', 'documento.numero', 50);
    g.fecha_documento := interno.json_fecha(v_doc->'fecha', 'documento.fecha');
    v_rtn := regexp_replace(coalesce(interno.json_texto(v_doc->'rtn', 'documento.rtn', 40), ''), '[[:space:]-]', '', 'g');
    IF v_rtn <> '' AND v_rtn !~ '^[0-9]{14}$' THEN
      RAISE EXCEPTION 'RTN_INVALIDO: el RTN del emisor debe tener 14 dígitos.';
    END IF;
    g.rtn_emisor := nullif(v_rtn, '');
    g.cai := interno.json_texto(v_doc->'cai', 'documento.cai', 60);
  END IF;
  -- ISV crédito fiscal: solo con factura (número) y emisor identificado.
  IF g.isv_centavos > 0 AND (g.numero_documento IS NULL OR coalesce(g.rtn_emisor, v_prov.rtn) IS NULL) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: para tomar ISV crédito fiscal indique el número de la factura y el RTN del emisor (o un proveedor con RTN).';
  END IF;
  g.pago_fijo_id := p_pago_fijo_id;
  g.pago_fijo_vence_el := p_vence_el;
  g.equipo := interno.equipo(p_datos);

  -- Candado, reintento y número.
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'gasto');
  SELECT x.id INTO v_prev FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v_prev IS NOT NULL THEN
    SELECT * INTO g FROM public.gasto WHERE id = v_prev;
    RETURN interno.gasto_respuesta(g, true);
  END IF;
  IF p_pago_fijo_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.gasto x WHERE x.pago_fijo_id = p_pago_fijo_id
       AND x.pago_fijo_vence_el = p_vence_el AND x.estado IN ('pendiente_aprobacion', 'aplicado')) THEN
    RAISE EXCEPTION 'YA_EXISTE: el pago fijo con vencimiento % ya está registrado.', to_char(p_vence_el, 'DD/MM/YYYY');
  END IF;
  g.id := gen_random_uuid();
  g.numero := interno.siguiente_numero(p_empresa_id, 'gasto');
  g.id_operacion := p_id_operacion;
  g.creado_por := auth.uid();
  g.registrado_en := now();

  -- ¿Pasa el tope del puesto? El dueño no tiene tope.
  SELECT * INTO v_tope FROM interno.tope_rol(p_empresa_id, v_rol, 'gasto');
  IF v_rol = 'dueno' OR g.monto_centavos <= v_tope.sin_aprobacion THEN
    -- Dentro del tope: el dinero sale ya (asiento + rastro) y se guarda aplicado.
    g.asiento_id := interno.aplicar_gasto(g, g.fecha_contable, p_id_operacion);
    g.estado := 'aplicado';
    g.aplicado_en := now();
    g.aplicado_por := auth.uid();
    INSERT INTO public.gasto SELECT (g).*;
  ELSE
    -- Pasa el tope: queda pendiente, SIN mover dinero, con su solicitud.
    g.estado := 'pendiente_aprobacion';
    v_apr := gen_random_uuid();
    INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                   solicitado_por, rol_solicitante)
    VALUES (v_apr, p_empresa_id, interno.siguiente_numero(p_empresa_id, 'aprobacion'), 'gasto', 'gasto', g.id, g.monto_centavos,
            'Gasto #' || g.numero || ' (' || v_cat.nombre || '): ' || g.descripcion, auth.uid(), v_rol);
    g.aprobacion_id := v_apr;
    INSERT INTO public.gasto SELECT (g).*;
  END IF;
  PERFORM interno.guardar_adjunto(p_empresa_id, 'gasto', g.id, p_datos->'comprobante');
  SELECT * INTO g FROM public.gasto WHERE id = g.id;
  RETURN interno.gasto_respuesta(g, false);
END $$;

-- ---------------------------------------------------------------------
-- 3) RPC: categorías y topes
-- ---------------------------------------------------------------------
-- crear_categoria_gasto(empresa, nombre, cuenta)   dinero.administrar
-- cuenta: código de una cuenta de detalle activa de gasto (6...) o costo (5...).
CREATE FUNCTION public.crear_categoria_gasto(p_empresa_id uuid, p_nombre text, p_cuenta_codigo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c    public.cuenta;
  v_id uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF length(trim(coalesce(p_nombre, ''))) = 0 OR length(trim(p_nombre)) > 100 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la categoría (máximo 100 letras).';
  END IF;
  SELECT * INTO c FROM public.cuenta x WHERE x.empresa_id = p_empresa_id AND x.codigo = trim(coalesce(p_cuenta_codigo, ''));
  IF c.id IS NULL OR NOT c.es_detalle OR NOT c.activa OR c.tipo NOT IN ('gasto', 'costo') THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la categoría va a una cuenta de detalle activa de gasto (6...) o costo (5...).';
  END IF;
  IF EXISTS (SELECT 1 FROM interno.cuenta_sistema cs WHERE interno.cuenta_de(p_empresa_id, cs.uso) = c.codigo AND cs.modulo_controla IS NOT NULL) THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta % la mueve un módulo; elija otra.', c.codigo;
  END IF;
  BEGIN
    INSERT INTO public.categoria_gasto (empresa_id, nombre, cuenta_id, creado_por)
    VALUES (p_empresa_id, trim(p_nombre), c.id, auth.uid()) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay una categoría de gasto llamada "%".', trim(p_nombre);
  END;
  RETURN jsonb_build_object('categoria_id', v_id, 'cuenta_codigo', c.codigo);
END $$;

CREATE FUNCTION public.desactivar_categoria_gasto(p_empresa_id uuid, p_categoria_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.categoria_gasto;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v FROM public.categoria_gasto WHERE id = p_categoria_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la categoría no existe en esta empresa.';
  END IF;
  IF NOT v.activa THEN
    RETURN jsonb_build_object('categoria_id', v.id, 'activa', false, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.categoria_gasto SET activa = false WHERE id = v.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('categoria_id', v.id, 'activa', false, 'ya_estaba', false);
END $$;

CREATE FUNCTION public.reactivar_categoria_gasto(p_empresa_id uuid, p_categoria_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.categoria_gasto;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v FROM public.categoria_gasto WHERE id = p_categoria_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la categoría no existe en esta empresa.';
  END IF;
  IF v.activa THEN
    RETURN jsonb_build_object('categoria_id', v.id, 'activa', true, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.categoria_gasto SET activa = true WHERE id = v.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('categoria_id', v.id, 'activa', true, 'ya_estaba', false);
END $$;

-- configurar_tope_rol(empresa, rol, tipo, sin_aprobacion, aprueba_hasta, motivo)   empresa.configurar (solo dueño)
CREATE FUNCTION public.configurar_tope_rol(p_empresa_id uuid, p_rol text, p_tipo text, p_sin_aprobacion_centavos bigint,
                                           p_aprueba_hasta_centavos bigint, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rol r WHERE r.codigo = p_rol) OR p_rol IN ('dueno', 'proveedor') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el puesto "%" no existe o no lleva topes (el dueño no tiene tope).', p_rol;
  END IF;
  IF coalesce(p_tipo, '') NOT IN ('gasto') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de tope es "gasto".';
  END IF;
  IF p_sin_aprobacion_centavos IS NULL OR p_sin_aprobacion_centavos NOT BETWEEN 0 AND 9007199254740991
     OR p_aprueba_hasta_centavos IS NULL OR p_aprueba_hasta_centavos NOT BETWEEN 0 AND 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los topes son enteros de centavos, 0 o más.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.tope_rol (empresa_id, rol, tipo, sin_aprobacion_centavos, aprueba_hasta_centavos, actualizado_por)
  VALUES (p_empresa_id, p_rol, p_tipo, p_sin_aprobacion_centavos, p_aprueba_hasta_centavos, auth.uid())
  ON CONFLICT (empresa_id, rol, tipo) DO UPDATE
     SET sin_aprobacion_centavos = excluded.sin_aprobacion_centavos, aprueba_hasta_centavos = excluded.aprueba_hasta_centavos,
         actualizado_por = excluded.actualizado_por, actualizado_en = now();
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('rol', p_rol, 'tipo', p_tipo, 'sin_aprobacion_centavos', p_sin_aprobacion_centavos,
                            'aprueba_hasta_centavos', p_aprueba_hasta_centavos);
END $$;

-- ---------------------------------------------------------------------
-- 4) RPC: gastos y aprobaciones
-- ---------------------------------------------------------------------
-- registrar_gasto(empresa, datos, id_operacion)   gastos.registrar
CREATE FUNCTION public.registrar_gasto(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'gastos.registrar', 'dinero');
  RETURN interno.registrar_gasto_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- resolver_aprobacion(aprobacion, aprobar, motivo, id_operacion, fecha?)
-- Gasto: permiso gastos.aprobar y monto dentro del tope del puesto (el dueño
-- sin tope). Nadie aprueba lo que él mismo pidió (salvo el dueño). Al
-- aprobar se mueve el dinero (con la fecha del gasto o la indicada, si su mes
-- ya cerró). Rechazar pide motivo.
CREATE FUNCTION public.resolver_aprobacion(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                           p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.aprobacion;
  g       public.gasto;
  v_rol   text;
  v_tope  record;
  v_fecha date;
  v_asto  uuid;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la solicitud de aprobación no existe.';
  END IF;
  IF a.tipo <> 'gasto' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: este tipo de aprobación (%) todavía no se resuelve aquí.', a.tipo;
  END IF;
  PERFORM interno.exigir_escritura(a.empresa_id, 'gastos.aprobar', 'dinero');
  v_rol := public.mi_rol(a.empresa_id);
  IF p_aprobar IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si aprueba (true) o rechaza (false).';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  IF a.resolucion_id_operacion = p_id_operacion THEN
    SELECT * INTO g FROM public.gasto WHERE id = a.documento_id;
    RETURN interno.gasto_respuesta(g, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado);
  END IF;
  IF NOT p_aprobar AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se rechaza (mínimo 5 letras).';
  END IF;
  IF a.solicitado_por = auth.uid() AND v_rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede aprobar ni rechazar su propia solicitud; lo hace otra persona con permiso o el dueño.';
  END IF;
  SELECT * INTO v_tope FROM interno.tope_rol(a.empresa_id, v_rol, 'gasto');
  IF p_aprobar AND v_rol <> 'dueno' AND a.monto_centavos > v_tope.aprueba_hasta THEN
    RAISE EXCEPTION 'TOPE_APROBACION: el gasto es de % y usted aprueba hasta %; pídale al dueño que lo apruebe.',
      interno.lempiras(a.monto_centavos), interno.lempiras(v_tope.aprueba_hasta);
  END IF;
  SELECT * INTO g FROM public.gasto WHERE id = a.documento_id;
  v_fecha := coalesce(p_fecha, g.fecha_contable);
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_fecha < g.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la fecha del gasto aprobado no puede ser anterior a la de la solicitud (%).', to_char(g.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id FOR UPDATE;
  SELECT * INTO g FROM public.gasto WHERE id = a.documento_id FOR UPDATE;
  IF a.resolucion_id_operacion = p_id_operacion THEN
    RETURN interno.gasto_respuesta(g, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado);
  END IF;
  IF a.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la solicitud #% ya está %.', a.numero, a.estado;
  END IF;

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  UPDATE public.aprobacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_por = auth.uid(),
         rol_resolutor = v_rol, resuelto_en = now(), motivo_resolucion = nullif(trim(p_motivo), ''),
         resolucion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  IF p_aprobar THEN
    g.fecha_contable := v_fecha;
    v_asto := interno.aplicar_gasto(g, v_fecha, p_id_operacion);
    UPDATE public.gasto SET estado = 'aplicado', fecha_contable = v_fecha, asiento_id = v_asto, aplicado_en = now(),
           aplicado_por = auth.uid()
     WHERE id = g.id;
  ELSE
    UPDATE public.gasto SET estado = 'rechazado' WHERE id = g.id;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  SELECT * INTO g FROM public.gasto WHERE id = g.id;
  RETURN interno.gasto_respuesta(g, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado);
END $$;

-- anular_gasto(gasto, motivo, id_operacion, fecha?)   gastos.anular
-- Aplicado: contra-asiento (el dinero vuelve a su cuenta). Pendiente: se
-- cancela (también lo puede cancelar quien lo pidió).
CREATE FUNCTION public.anular_gasto(p_gasto_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  g       public.gasto;
  v_fecha date;
  v_asto  uuid;
BEGIN
  SELECT * INTO g FROM public.gasto WHERE id = p_gasto_id;
  IF g.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el gasto no existe.';
  END IF;
  IF g.estado = 'pendiente_aprobacion' AND g.creado_por = auth.uid() THEN
    PERFORM interno.exigir_escritura(g.empresa_id, 'gastos.registrar', 'dinero');
  ELSE
    PERFORM interno.exigir_escritura(g.empresa_id, 'gastos.anular', 'dinero');
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(g.empresa_id, p_id_operacion, 'anulacion_gasto');
  IF g.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.gasto_respuesta(g, true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(g.empresa_id), g.fecha_contable));
  PERFORM interno.exigir_fecha_contable(g.empresa_id, v_fecha);
  IF v_fecha < g.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al gasto (%).', to_char(g.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(g.empresa_id, p_id_operacion, 'anulacion_gasto');
  SELECT * INTO g FROM public.gasto WHERE id = p_gasto_id FOR UPDATE;
  IF g.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.gasto_respuesta(g, true);
  END IF;
  IF g.estado IN ('anulado', 'rechazado') THEN
    RAISE EXCEPTION 'YA_ANULADO: el gasto #% ya está %.', g.numero, g.estado;
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  IF g.estado = 'aplicado' THEN
    PERFORM interno.exigir_periodo_abierto(g.empresa_id, v_fecha);
    v_asto := interno.asiento_sistema(g.empresa_id, interno.sucursal_activa(g.sucursal_id), v_fecha,
      'ANULACIÓN gasto #' || g.numero || ': ' || trim(p_motivo), 'anulacion_gasto', p_id_operacion,
      (SELECT jsonb_agg(jsonb_build_object('cuenta', c.codigo, 'debe', l.haber_centavos, 'haber', l.debe_centavos,
                                           'descripcion', 'Reversión') ORDER BY l.linea)
         FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = g.asiento_id),
      g.asiento_id, trim(p_motivo));
  ELSE
    UPDATE public.aprobacion SET estado = 'cancelada', resuelto_por = auth.uid(), rol_resolutor = public.mi_rol(g.empresa_id),
           resuelto_en = now(), motivo_resolucion = trim(p_motivo), resolucion_id_operacion = p_id_operacion
     WHERE id = g.aprobacion_id AND estado = 'pendiente';
  END IF;
  UPDATE public.gasto SET estado = 'anulado', anulado_en = now(), anulado_por = auth.uid(), motivo_anulacion = trim(p_motivo),
         fecha_anulacion = v_fecha, asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = g.id
  RETURNING * INTO g;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_gasto', 'gasto', g.id, trim(p_motivo), NULL);
  RETURN interno.gasto_respuesta(g, false);
END $$;

-- ---------------------------------------------------------------------
-- 5) Caja chica: cuadre
-- ---------------------------------------------------------------------
-- cuadre_caja_chica(cuenta, contado?)   dinero.ver
-- Ciclo = desde la última reposición. Devuelve fondo fijo, efectivo
-- esperado (saldo del sistema), gastos del ciclo con y sin comprobante,
-- "fondo - gastos del ciclo" (= esperado si el ciclo empezó con el fondo
-- completo), lo que falta reponer y, si se da lo contado, la diferencia.
CREATE FUNCTION public.cuadre_caja_chica(p_cuenta_dinero_id uuid, p_contado_centavos bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d       public.cuenta_dinero;
  v_desde bigint;
  v_saldo bigint;
  v_g     record;
BEGIN
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = p_cuenta_dinero_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la cuenta de dinero no existe.';
  END IF;
  PERFORM interno.exigir_lectura(d.empresa_id, 'dinero.ver');
  IF d.tipo <> 'caja_chica' THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: "%" no es una caja chica.', d.nombre;
  END IF;
  IF p_contado_centavos IS NOT NULL AND p_contado_centavos NOT BETWEEN 0 AND 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: lo contado es un entero de centavos, 0 o más.';
  END IF;
  SELECT coalesce(max(m.id), 0) INTO v_desde FROM public.dinero_movimiento m
   WHERE m.cuenta_dinero_id = d.id AND m.operacion = 'dinero_reposicion_caja_chica' AND m.monto_centavos > 0;
  v_saldo := interno.saldo_dinero(d.id);
  SELECT count(*) AS n, coalesce(sum(g.monto_centavos), 0) AS total,
         coalesce(sum(g.monto_centavos) FILTER (WHERE x.con), 0) AS con,
         coalesce(sum(g.monto_centavos) FILTER (WHERE NOT x.con), 0) AS sin,
         count(*) FILTER (WHERE NOT x.con) AS n_sin
    INTO v_g
    FROM public.gasto g
    CROSS JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM public.adjunto a WHERE a.documento_tipo = 'gasto' AND a.documento_id = g.id) AS con) x
   WHERE g.cuenta_dinero_id = d.id AND g.estado = 'aplicado'
     AND EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.documento_id = g.id AND m.operacion = 'gasto' AND m.id > v_desde);
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'nombre', d.nombre, 'fondo_fijo_centavos', d.fondo_fijo_centavos,
    'efectivo_esperado_centavos', v_saldo, 'por_reponer_centavos', d.fondo_fijo_centavos - v_saldo,
    'gastos_ciclo', jsonb_build_object('cantidad', v_g.n, 'total_centavos', v_g.total, 'con_comprobante_centavos', v_g.con,
                                       'sin_comprobante_centavos', v_g.sin, 'cantidad_sin_comprobante', v_g.n_sin),
    'fondo_menos_gastos_centavos', d.fondo_fijo_centavos - v_g.total,
    'cuadra_con_fondo', d.fondo_fijo_centavos - v_g.total = v_saldo,
    'contado_centavos', p_contado_centavos,
    'diferencia_centavos', p_contado_centavos - v_saldo);
END $$;

-- ---------------------------------------------------------------------
-- 6) Pagos fijos
-- ---------------------------------------------------------------------
-- Vencimientos de una plantilla hasta una fecha.
--   mensual: el día "dia" (o el último del mes) cada "cada" meses, desde fecha_inicio.
--   semanal: el día "dia" de la semana (1 lunes .. 7 domingo) cada "cada" semanas.
CREATE FUNCTION interno.vencimientos_pago_fijo(p public.pago_fijo, p_hasta date) RETURNS SETOF date
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  k   integer := 0;
  m   date;
  v   date;
BEGIN
  IF p.frecuencia = 'mensual' THEN
    LOOP
      m := (date_trunc('month', p.fecha_inicio) + make_interval(months => k * p.cada))::date;
      v := least(m + (p.dia - 1), (m + interval '1 month' - interval '1 day')::date);
      EXIT WHEN v > p_hasta OR k > 1200;
      IF v >= p.fecha_inicio THEN
        RETURN NEXT v;
      END IF;
      k := k + 1;
    END LOOP;
  ELSE
    v := p.fecha_inicio + ((p.dia - extract(isodow FROM p.fecha_inicio)::integer + 7) % 7);
    WHILE v <= p_hasta AND k <= 5200 LOOP
      RETURN NEXT v;
      v := v + 7 * p.cada;
      k := k + 1;
    END LOOP;
  END IF;
END $$;

-- Monto mensual estimado de una plantilla (centavos, redondeado).
CREATE FUNCTION interno.mensual_pago_fijo(p public.pago_fijo) RETURNS bigint
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p.frecuencia WHEN 'mensual' THEN round(p.monto_estimado_centavos::numeric / p.cada)
              ELSE round(p.monto_estimado_centavos::numeric * 52 / 12 / p.cada) END::bigint
$$;

-- Datos de la plantilla (crear y editar).
CREATE FUNCTION interno.aplicar_datos_pago_fijo(p public.pago_fijo, p_datos jsonb) RETURNS public.pago_fijo
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  PERFORM interno.exigir_claves(p_datos, ARRAY['nombre', 'categoria_id', 'monto_estimado_centavos', 'frecuencia', 'cada',
                                               'dia', 'fecha_inicio', 'cuenta_dinero_id', 'notas']);
  IF p_datos ? 'nombre' THEN
    p.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 100);
    IF p.nombre IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre del pago fijo (ej. "Alquiler del local").';
    END IF;
  END IF;
  IF p_datos ? 'categoria_id' THEN
    v := interno.json_uuid(p_datos->'categoria_id', 'categoria_id');
    IF NOT EXISTS (SELECT 1 FROM public.categoria_gasto c WHERE c.id = v AND c.empresa_id = p.empresa_id AND c.activa) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la categoría de gasto no existe en esta empresa o está desactivada.';
    END IF;
    p.categoria_id := v;
  END IF;
  IF p_datos ? 'monto_estimado_centavos' THEN
    p.monto_estimado_centavos := interno.json_centavos(p_datos->'monto_estimado_centavos', 'monto_estimado_centavos');
  END IF;
  IF p_datos ? 'frecuencia' THEN
    p.frecuencia := interno.json_texto(p_datos->'frecuencia', 'frecuencia', 10);
  END IF;
  IF p_datos ? 'cada' THEN
    p.cada := interno.json_centavos(p_datos->'cada', 'cada')::integer;
  END IF;
  IF p_datos ? 'dia' THEN
    p.dia := interno.json_centavos(p_datos->'dia', 'dia')::integer;
  END IF;
  IF p_datos ? 'fecha_inicio' THEN
    p.fecha_inicio := interno.json_fecha(p_datos->'fecha_inicio', 'fecha_inicio');
  END IF;
  IF p_datos ? 'cuenta_dinero_id' THEN
    v := interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id');
    IF v IS NOT NULL THEN
      PERFORM interno.cuenta_dinero_para_pagar(p.empresa_id, v);
    END IF;
    p.cuenta_dinero_id := v;
  END IF;
  IF p_datos ? 'notas' THEN
    p.notas := interno.json_texto(p_datos->'notas', 'notas', 500);
  END IF;
  IF p.frecuencia IS NULL OR p.frecuencia NOT IN ('mensual', 'semanal') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la frecuencia es "mensual" o "semanal".';
  END IF;
  IF p.frecuencia = 'mensual' AND (p.cada NOT BETWEEN 1 AND 12 OR p.dia NOT BETWEEN 1 AND 31) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: mensual: "cada" de 1 a 12 meses y "dia" del mes de 1 a 31.';
  END IF;
  IF p.frecuencia = 'semanal' AND (p.cada NOT BETWEEN 1 AND 52 OR p.dia NOT BETWEEN 1 AND 7) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: semanal: "cada" de 1 a 52 semanas y "dia" de la semana de 1 (lunes) a 7 (domingo).';
  END IF;
  IF p.fecha_inicio IS NULL OR p.fecha_inicio < '2000-01-01' OR p.fecha_inicio > '2100-12-31' THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique desde cuándo cuenta el pago fijo ("fecha_inicio", AAAA-MM-DD).';
  END IF;
  RETURN p;
END $$;

-- crear_pago_fijo(empresa, datos)   dinero.administrar
-- datos = {"nombre":"Alquiler","categoria_id":"...","monto_estimado_centavos":1500000,
--          "frecuencia":"mensual","cada":1,"dia":5,"fecha_inicio":"2026-01-01",
--          "cuenta_dinero_id":"..." (sugerida),"notas":"..."}
CREATE FUNCTION public.crear_pago_fijo(p_empresa_id uuid, p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p public.pago_fijo;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF NOT (coalesce(p_datos, '{}') ? 'nombre' AND p_datos ? 'categoria_id' AND p_datos ? 'frecuencia' AND p_datos ? 'dia') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el pago fijo necesita nombre, categoria_id, frecuencia y dia.';
  END IF;
  p.empresa_id := p_empresa_id;
  p.cada := 1;
  p.monto_estimado_centavos := 0;
  p.fecha_inicio := public.hoy_local(p_empresa_id);
  p := interno.aplicar_datos_pago_fijo(p, p_datos);
  BEGIN
    INSERT INTO public.pago_fijo (empresa_id, nombre, categoria_id, monto_estimado_centavos, frecuencia, cada, dia,
                                  fecha_inicio, cuenta_dinero_id, notas, creado_por)
    VALUES (p_empresa_id, p.nombre, p.categoria_id, p.monto_estimado_centavos, p.frecuencia, p.cada, p.dia,
            p.fecha_inicio, p.cuenta_dinero_id, p.notas, auth.uid())
    RETURNING * INTO p;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay un pago fijo llamado "%".', p.nombre;
  END;
  RETURN jsonb_build_object('pago_fijo_id', p.id, 'monto_mensual_estimado_centavos', interno.mensual_pago_fijo(p));
END $$;

CREATE FUNCTION public.editar_pago_fijo(p_empresa_id uuid, p_pago_fijo_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p     public.pago_fijo;
  v_act boolean;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  SELECT * INTO p FROM public.pago_fijo WHERE id = p_pago_fijo_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el pago fijo no existe en esta empresa.';
  END IF;
  v_act := p.activo;
  IF jsonb_typeof(p_datos) = 'object' AND p_datos ? 'activo' THEN
    v_act := interno.json_si_no(p_datos->'activo', 'activo');
  END IF;
  p := interno.aplicar_datos_pago_fijo(p, coalesce(p_datos, '{}') - 'activo');
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  BEGIN
    UPDATE public.pago_fijo SET nombre = p.nombre, categoria_id = p.categoria_id, monto_estimado_centavos = p.monto_estimado_centavos,
           frecuencia = p.frecuencia, cada = p.cada, dia = p.dia, fecha_inicio = p.fecha_inicio,
           cuenta_dinero_id = p.cuenta_dinero_id, notas = p.notas, activo = v_act
     WHERE id = p.id
    RETURNING * INTO p;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay un pago fijo llamado "%".', p.nombre;
  END;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('pago_fijo_id', p.id, 'activo', p.activo, 'monto_mensual_estimado_centavos', interno.mensual_pago_fijo(p));
END $$;

-- registrar_pago_fijo(pago_fijo, datos, id_operacion)   gastos.registrar
-- Genera un GASTO real con el monto real (nunca se descuenta solo).
-- datos = {"monto_centavos":1520000 (obligatorio),"vence_el":"2026-02-05" (defecto: el
--          vencimiento más antiguo sin pagar),"cuenta_dinero_id" (defecto: la sugerida),
--          "fecha","isv_centavos","documento","proveedor_id","comprobante","descripcion","equipo"}
CREATE FUNCTION public.registrar_pago_fijo(p_pago_fijo_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p       public.pago_fijo;
  v_datos jsonb := coalesce(p_datos, '{}');
  v_vence date;
  r       jsonb;
BEGIN
  SELECT * INTO p FROM public.pago_fijo WHERE id = p_pago_fijo_id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el pago fijo no existe.';
  END IF;
  PERFORM interno.exigir_escritura(p.empresa_id, 'gastos.registrar', 'dinero');
  IF jsonb_typeof(v_datos) <> 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  -- Reintento: devolver lo ya hecho antes de revisar lo demás.
  IF EXISTS (SELECT 1 FROM public.gasto g WHERE g.empresa_id = p.empresa_id AND g.id_operacion = p_id_operacion) THEN
    RETURN interno.registrar_gasto_base(p.empresa_id, '{}', p_id_operacion);
  END IF;
  IF NOT p.activo THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el pago fijo "%" está desactivado.', p.nombre;
  END IF;
  IF NOT v_datos ? 'monto_centavos' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el monto REAL que se paga ("monto_centavos").';
  END IF;
  v_vence := interno.json_fecha(v_datos->'vence_el', 'vence_el');
  IF v_vence IS NULL THEN
    SELECT min(v) INTO v_vence FROM interno.vencimientos_pago_fijo(p, public.hoy_local(p.empresa_id) + 400) v
     WHERE NOT EXISTS (SELECT 1 FROM public.gasto g WHERE g.pago_fijo_id = p.id AND g.pago_fijo_vence_el = v
                         AND g.estado IN ('pendiente_aprobacion', 'aplicado'));
  ELSIF NOT EXISTS (SELECT 1 FROM interno.vencimientos_pago_fijo(p, v_vence) v WHERE v = v_vence) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: % no es un vencimiento del pago fijo "%".', to_char(v_vence, 'DD/MM/YYYY'), p.nombre;
  END IF;
  IF v_vence IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el pago fijo "%" no tiene vencimientos pendientes en el próximo año.', p.nombre;
  END IF;
  v_datos := (v_datos - 'vence_el')
          || jsonb_build_object('categoria_id', p.categoria_id)
          || CASE WHEN v_datos ? 'cuenta_dinero_id' OR p.cuenta_dinero_id IS NULL THEN '{}'::jsonb
                  ELSE jsonb_build_object('cuenta_dinero_id', p.cuenta_dinero_id) END
          || CASE WHEN v_datos ? 'descripcion' THEN '{}'::jsonb
                  ELSE jsonb_build_object('descripcion', p.nombre || ' (vence ' || to_char(v_vence, 'DD/MM/YYYY') || ')') END;
  IF NOT v_datos ? 'cuenta_dinero_id' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique de qué cuenta de dinero sale el pago ("cuenta_dinero_id").';
  END IF;
  r := interno.registrar_gasto_base(p.empresa_id, v_datos, p_id_operacion, p.id, v_vence);
  RETURN r || jsonb_build_object('pago_fijo_id', p.id, 'vence_el', to_char(v_vence, 'YYYY-MM-DD'));
END $$;

-- pagos_fijos_proximos(empresa)   dinero.ver
-- Por cada pago fijo activo: el próximo vencimiento sin pagar, días que
-- faltan (negativo = vencido), cuántos vencimientos hay atrasados y estado
-- ('vencido', 'proximo' (7 días o menos) o 'al_dia').
CREATE FUNCTION public.pagos_fijos_proximos(p_empresa_id uuid)
RETURNS TABLE (pago_fijo_id uuid, nombre text, categoria text, frecuencia text, cada integer, dia integer,
               monto_estimado_centavos bigint, monto_mensual_estimado_centavos bigint, cuenta_dinero_id uuid,
               proximo_vence_el date, dias integer, vencidos integer, estado text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
#variable_conflict use_column
DECLARE v_hoy date := public.hoy_local(p_empresa_id);
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'dinero.ver');
  RETURN QUERY
  SELECT p.id, p.nombre, c.nombre, p.frecuencia, p.cada, p.dia, p.monto_estimado_centavos, interno.mensual_pago_fijo(p),
         p.cuenta_dinero_id, x.proximo, (x.proximo - v_hoy)::integer, x.vencidos::integer,
         CASE WHEN x.proximo < v_hoy THEN 'vencido' WHEN x.proximo - v_hoy <= 7 THEN 'proximo' ELSE 'al_dia' END
    FROM public.pago_fijo p
    JOIN public.categoria_gasto c ON c.id = p.categoria_id
    CROSS JOIN LATERAL (
      SELECT min(v) AS proximo, count(*) FILTER (WHERE v < v_hoy) AS vencidos
        FROM interno.vencimientos_pago_fijo(p, v_hoy + 400) v
       WHERE NOT EXISTS (SELECT 1 FROM public.gasto g WHERE g.pago_fijo_id = p.id AND g.pago_fijo_vence_el = v
                           AND g.estado IN ('pendiente_aprobacion', 'aplicado'))) x
   WHERE p.empresa_id = p_empresa_id AND p.activo
   ORDER BY x.proximo NULLS LAST, p.nombre;
END $$;

-- reporte_pagos_fijos(empresa, anio, mes)   dinero.ver
-- Total mensual estimado de los pagos fijos activos y lo pagado (gastos
-- aplicados de pagos fijos con fecha en ese mes), por plantilla.
CREATE FUNCTION public.reporte_pagos_fijos(p_empresa_id uuid, p_anio integer, p_mes integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ini   date;
  v_fin   date;
  v_lista jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'dinero.ver');
  IF p_anio IS NULL OR p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 OR p_anio NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'PERIODO_INVALIDO: el mes o el año no son válidos.';
  END IF;
  v_ini := make_date(p_anio, p_mes, 1);
  v_fin := (v_ini + interval '1 month' - interval '1 day')::date;
  SELECT coalesce(jsonb_agg(jsonb_build_object('pago_fijo_id', p.id, 'nombre', p.nombre, 'activo', p.activo,
           'frecuencia', p.frecuencia, 'monto_estimado_centavos', p.monto_estimado_centavos,
           'monto_mensual_estimado_centavos', interno.mensual_pago_fijo(p),
           'vencimientos_del_mes', (SELECT coalesce(jsonb_agg(to_char(v, 'YYYY-MM-DD') ORDER BY v), '[]')
                                      FROM interno.vencimientos_pago_fijo(p, v_fin) v WHERE v >= v_ini),
           'pagado_centavos', coalesce(g.pagado, 0), 'pagos', coalesce(g.pagos, 0)) ORDER BY p.nombre), '[]')
    INTO v_lista
    FROM public.pago_fijo p
    LEFT JOIN (SELECT x.pago_fijo_id, sum(x.monto_centavos) AS pagado, count(*) AS pagos FROM public.gasto x
                WHERE x.empresa_id = p_empresa_id AND x.estado = 'aplicado' AND x.fecha_contable BETWEEN v_ini AND v_fin
                  AND x.pago_fijo_id IS NOT NULL GROUP BY x.pago_fijo_id) g ON g.pago_fijo_id = p.id
   WHERE p.empresa_id = p_empresa_id AND (p.activo OR g.pagado IS NOT NULL);
  RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes,
    'estimado_mensual_total_centavos', coalesce((SELECT sum((x->>'monto_mensual_estimado_centavos')::bigint)
                                                   FROM jsonb_array_elements(v_lista) x WHERE (x->>'activo')::boolean), 0),
    'pagado_mes_total_centavos', coalesce((SELECT sum((x->>'pagado_centavos')::bigint) FROM jsonb_array_elements(v_lista) x), 0),
    'pagos_fijos', v_lista);
END $$;

-- ---------------------------------------------------------------------
-- 7) id_operacion por tipo (reemplaza la de 023) y adjuntos a gastos
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
  IF EXISTS (SELECT 1 FROM public.aprobacion x WHERE x.empresa_id = p_empresa_id AND x.resolucion_id_operacion = p_id
               AND x.estado IN ('aprobada', 'rechazada')) THEN
    RETURN 'resolver_aprobacion';
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
  END;
END $$;

-- ---------------------------------------------------------------------
-- 8) Vistas
-- ---------------------------------------------------------------------
CREATE VIEW public.v_gasto WITH (security_invoker = true) AS
  SELECT g.empresa_id, g.id AS gasto_id, g.numero, g.fecha_contable, g.estado, g.descripcion,
         g.categoria_id, cg.nombre AS categoria, g.cuenta_dinero_id, d.nombre AS cuenta_dinero, d.tipo AS tipo_cuenta_dinero,
         g.monto_centavos, g.isv_centavos, (g.monto_centavos - g.isv_centavos) AS sin_isv_centavos,
         g.proveedor_id, g.numero_documento, g.fecha_documento, g.rtn_emisor,
         g.pago_fijo_id, g.pago_fijo_vence_el, g.aprobacion_id,
         EXISTS (SELECT 1 FROM public.adjunto a WHERE a.documento_tipo = 'gasto' AND a.documento_id = g.id) AS tiene_comprobante,
         g.creado_por, public.nombre_usuario(g.empresa_id, g.creado_por) AS registrado_por, g.registrado_en,
         g.motivo_anulacion, g.fecha_anulacion
  FROM public.gasto g
  JOIN public.categoria_gasto cg ON cg.id = g.categoria_id
  LEFT JOIN public.cuenta_dinero d ON d.id = g.cuenta_dinero_id;   -- sin dinero.ver: nombre de la cuenta vacío

CREATE VIEW public.v_aprobacion WITH (security_invoker = true) AS
  SELECT a.empresa_id, a.id AS aprobacion_id, a.numero, a.tipo, a.documento_tipo, a.documento_id, a.monto_centavos,
         a.descripcion, a.estado, a.solicitado_por, public.nombre_usuario(a.empresa_id, a.solicitado_por) AS solicitante,
         a.rol_solicitante, a.solicitado_en, a.resuelto_por, public.nombre_usuario(a.empresa_id, a.resuelto_por) AS resolutor,
         a.rol_resolutor, a.resuelto_en, a.motivo_resolucion
  FROM public.aprobacion a;

-- ---------------------------------------------------------------------
-- 9) Seguridad
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['categoria_gasto', 'tope_rol', 'aprobacion', 'pago_fijo', 'gasto'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
CREATE POLICY leer ON public.categoria_gasto FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.tope_rol        FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.pago_fijo FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver'))));
CREATE POLICY leer ON public.gasto FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver')))
         OR (creado_por = (SELECT auth.uid()) AND empresa_id IN (SELECT public.mis_empresas())));
CREATE POLICY leer ON public.aprobacion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('aprobaciones.ver')))
         OR (solicitado_por = (SELECT auth.uid()) AND empresa_id IN (SELECT public.mis_empresas())));
GRANT SELECT ON public.v_gasto, public.v_aprobacion TO authenticated, service_role;

REVOKE ALL ON interno.plantilla_tope_rol FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  interno.proteger_gasto(),
  interno.proteger_aprobacion(),
  interno.tope_rol(uuid, text, text),
  interno.gasto_respuesta(public.gasto, boolean),
  interno.aplicar_gasto(public.gasto, date, uuid),
  interno.registrar_gasto_base(uuid, jsonb, uuid, uuid, date),
  interno.vencimientos_pago_fijo(public.pago_fijo, date),
  interno.mensual_pago_fijo(public.pago_fijo),
  interno.aplicar_datos_pago_fijo(public.pago_fijo, jsonb)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.crear_categoria_gasto(uuid, text, text),
  public.desactivar_categoria_gasto(uuid, uuid, text),
  public.reactivar_categoria_gasto(uuid, uuid, text),
  public.configurar_tope_rol(uuid, text, text, bigint, bigint, text),
  public.registrar_gasto(uuid, jsonb, uuid),
  public.resolver_aprobacion(uuid, boolean, text, uuid, date),
  public.anular_gasto(uuid, text, uuid, date),
  public.cuadre_caja_chica(uuid, bigint),
  public.crear_pago_fijo(uuid, jsonb),
  public.editar_pago_fijo(uuid, uuid, jsonb, text),
  public.registrar_pago_fijo(uuid, jsonb, uuid),
  public.pagos_fijos_proximos(uuid),
  public.reporte_pagos_fijos(uuid, integer, integer)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_categoria_gasto(uuid, text, text),
  public.desactivar_categoria_gasto(uuid, uuid, text),
  public.reactivar_categoria_gasto(uuid, uuid, text),
  public.configurar_tope_rol(uuid, text, text, bigint, bigint, text),
  public.registrar_gasto(uuid, jsonb, uuid),
  public.resolver_aprobacion(uuid, boolean, text, uuid, date),
  public.anular_gasto(uuid, text, uuid, date),
  public.crear_pago_fijo(uuid, jsonb),
  public.editar_pago_fijo(uuid, uuid, jsonb, text),
  public.registrar_pago_fijo(uuid, jsonb, uuid)
TO authenticated;
GRANT EXECUTE ON FUNCTION
  public.cuadre_caja_chica(uuid, bigint),
  public.pagos_fijos_proximos(uuid),
  public.reporte_pagos_fijos(uuid, integer, integer)
TO authenticated, service_role;
