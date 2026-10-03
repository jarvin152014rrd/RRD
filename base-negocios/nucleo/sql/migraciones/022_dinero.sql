-- =====================================================================
-- 022_dinero.sql  -  Núcleo 0.5.0 (etapa 2b-1): rastro del dinero
--
--   cuenta_dinero        cada lugar con dinero (caja de efectivo, banco, caja
--                        chica, POS por liquidar, transferencias por confirmar,
--                        dinero en tránsito). Crear una crea SU subcuenta de
--                        detalle bajo 1.1.01; esa subcuenta no acepta asientos
--                        manuales (como inventario y proveedores).
--   dinero_movimiento    el "kardex del dinero": SOLO AGREGAR, una fila por
--                        cada línea de asiento que toca una cuenta de dinero,
--                        con contrapartida (origen/destino), usuario, equipo,
--                        referencia y turno. Suma por cuenta = saldo contable
--                        de su subcuenta. Un asiento que toca una cuenta de
--                        dinero sin su movimiento NO se confirma (MOVIMIENTO_SIN_RASTRO).
--   operacion_dinero     saldo inicial, depósito (queda EN TRÁNSITO hasta
--                        confirmar_deposito), retiro, reposición de caja chica
--                        y traslado general: sale de una cuenta y entra a otra
--                        en UNA operación. Se anula con motivo (contra-asiento).
--   adjunto              comprobantes (foto o PDF en Supabase Storage): ruta,
--                        tipo, huella sha256; ligado a cualquier documento;
--                        solo agregar, nunca se borra.
-- Compras: registrar_compra, pagar_proveedor, anular_pago_proveedor y
-- anular_compra aceptan la cuenta de dinero (cuenta_dinero_id) y dejan su rastro.
-- Lecturas: v_cuenta_dinero, v_deposito_transito, donde_esta_mi_dinero(),
-- estado_cuenta_dinero().
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('CUENTA_DINERO_INVALIDA', 'La cuenta de dinero elegida no se puede usar para esto.',
   'Elija una cuenta de dinero activa de su empresa y del tipo correcto (por ejemplo, un depósito va de una caja a un banco).'),
  ('SALDO_INSUFICIENTE', 'No hay suficiente dinero en esa cuenta.',
   'Revise el saldo de la cuenta. Registre primero la entrada que falta (depósito, traslado o saldo inicial).'),
  ('TOPE_CAJA_CHICA', 'La caja chica pasaría su fondo fijo.',
   'Reponga solo lo gastado (fondo menos saldo) o pida al dueño subir el fondo.'),
  ('MOVIMIENTO_SIN_RASTRO', 'Un movimiento de dinero quedó sin su rastro.',
   'No se guardó nada. Avise a soporte: toda entrada o salida de dinero debe registrarse desde su módulo.'),
  ('MONEDA_NO_SOPORTADA', 'Por ahora las cuentas de dinero van en la moneda de la empresa.',
   'Registre la cuenta en la moneda de la empresa. Las cuentas en otra moneda vendrán en una versión futura.');

INSERT INTO public.modulo (codigo, nombre) VALUES ('dinero', 'Dinero: cuentas, caja, gastos');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('dinero.ver',           'Ver cuentas de dinero, saldos, movimientos, gastos y turnos', false, true),
  ('dinero.administrar',   'Crear, editar y desactivar cuentas de dinero, categorías de gasto y pagos fijos', false, false),
  ('dinero.trasladar',     'Depósitos, retiros, reposición de caja chica y traslados entre cuentas de dinero', true, false),
  ('dinero.anular',        'Anular depósitos, retiros y traslados de dinero', true, false),
  ('dinero.saldo_inicial', 'Cargar y anular saldos iniciales de cuentas de dinero', true, false),
  ('adjuntos.agregar',     'Agregar comprobantes (foto o PDF) a un documento', false, false);

-- Criterio (REQUISITOS): admin opera dentro de los topes; contador solo
-- ve; cajero agrega comprobantes (su turno va en 023); el vendedor no ve
-- bancos. Saldos iniciales: solo el dueño.
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'dinero.ver'), ('dueno', 'dinero.administrar'), ('dueno', 'dinero.trasladar'), ('dueno', 'dinero.anular'),
  ('dueno', 'dinero.saldo_inicial'), ('dueno', 'adjuntos.agregar'),
  ('admin', 'dinero.ver'), ('admin', 'dinero.administrar'), ('admin', 'dinero.trasladar'), ('admin', 'dinero.anular'),
  ('admin', 'adjuntos.agregar'),
  ('cajero', 'adjuntos.agregar'),
  ('contador', 'dinero.ver');
SELECT interno.repartir_permisos(ARRAY['dinero.ver', 'dinero.administrar', 'dinero.trasladar', 'dinero.anular',
  'dinero.saldo_inicial', 'adjuntos.agregar'], 'Núcleo 0.5.0: permisos de dinero');

-- Días que un depósito puede estar en tránsito antes de la alerta (lo cambia el dueño).
ALTER TABLE public.empresa
  ADD COLUMN dias_alerta_transito integer NOT NULL DEFAULT 3 CHECK (dias_alerta_transito BETWEEN 0 AND 60);

-- ---------------------------------------------------------------------
-- 1) Cuentas contables nuevas (plantilla y empresas ya instaladas)
-- ---------------------------------------------------------------------
INSERT INTO interno.plantilla_cuenta (codigo, nombre, tipo, naturaleza, es_detalle) VALUES
  ('1.1.02.04', 'Diferencias de caja por resolver', 'activo',  'deudora',   true),
  ('1.1.02.05', 'Cuentas por cobrar a empleados',   'activo',  'deudora',   true),
  ('4.2.01.03', 'Sobrantes de caja',                'ingreso', 'acreedora', true),
  ('6.1.02.11', 'Faltantes de caja',                'gasto',   'deudora',   true);

INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('diferencia_caja', '1.1.02.04', 'Diferencias de arqueo pendientes de resolver (faltantes al debe, sobrantes al haber)', 'dinero'),
  ('cxc_empleados',   '1.1.02.05', 'Faltantes de caja cobrados al cajero', NULL),
  ('sobrante_caja',   '4.2.01.03', 'Sobrantes de caja (otros ingresos)', NULL),
  ('faltante_caja',   '6.1.02.11', 'Faltantes de caja enviados a gasto', NULL),
  ('apertura_dinero', '3.3.01.03', 'Saldos de apertura: contrapartida de los saldos iniciales de cuentas de dinero', NULL);

-- Crea en una empresa la cuenta de un uso (código de la plantilla o, si ya
-- era del cliente, el siguiente libre bajo la misma madre) y lo anota.
CREATE FUNCTION interno.asegurar_cuenta_uso(p_empresa_id uuid, p_uso text, p_nombre text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cs     interno.cuenta_sistema;
  v_madre  public.cuenta;
  v_codigo text;
  n        integer;
BEGIN
  SELECT * INTO v_cs FROM interno.cuenta_sistema WHERE uso = p_uso;
  IF EXISTS (SELECT 1 FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.codigo = interno.cuenta_de(p_empresa_id, p_uso)
               AND c.nombre = p_nombre) THEN
    RETURN interno.cuenta_de(p_empresa_id, p_uso);
  END IF;
  SELECT * INTO v_madre FROM public.cuenta c
   WHERE c.empresa_id = p_empresa_id AND c.codigo = regexp_replace(v_cs.codigo, '\.[0-9]+$', '');
  v_codigo := v_cs.codigo;
  n := split_part(v_cs.codigo, '.', 4)::integer;
  WHILE EXISTS (SELECT 1 FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.codigo = v_codigo) LOOP
    n := n + 1;
    v_codigo := v_madre.codigo || '.' || lpad(n::text, 2, '0');
  END LOOP;
  INSERT INTO public.cuenta (empresa_id, codigo, nombre, tipo, naturaleza, padre_id, es_detalle)
  VALUES (p_empresa_id, v_codigo, p_nombre, v_madre.tipo,
          (SELECT p.naturaleza FROM interno.plantilla_cuenta p WHERE p.codigo = v_cs.codigo), v_madre.id, true);
  IF v_codigo <> v_cs.codigo THEN
    INSERT INTO interno.cuenta_sistema_empresa (empresa_id, uso, codigo) VALUES (p_empresa_id, p_uso, v_codigo);
  END IF;
  RETURN v_codigo;
END $$;

DO $$
DECLARE e record;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.5.0: cuentas de caja (diferencias, empleados, faltantes, sobrantes)', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    PERFORM interno.asegurar_cuenta_uso(e.id, 'diferencia_caja', 'Diferencias de caja por resolver');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'cxc_empleados', 'Cuentas por cobrar a empleados');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'sobrante_caja', 'Sobrantes de caja');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'faltante_caja', 'Faltantes de caja');
  END LOOP;
  -- Saldos de apertura del dinero = la misma cuenta que la apertura de inventario.
  INSERT INTO interno.cuenta_sistema_empresa (empresa_id, uso, codigo)
  SELECT x.empresa_id, 'apertura_dinero', x.codigo FROM interno.cuenta_sistema_empresa x WHERE x.uso = 'apertura_inventario';
  PERFORM set_config('app.motivo', '', true);
END $$;

-- ---------------------------------------------------------------------
-- 2) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.cuenta_dinero (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id           uuid NOT NULL REFERENCES public.empresa(id),
  tipo                 text NOT NULL CHECK (tipo IN ('efectivo_caja', 'banco', 'caja_chica', 'pos_por_liquidar',
                                                     'transferencia_por_confirmar', 'transito')),
  nombre               text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 100),
  sucursal_id          uuid,
  caja_id              uuid REFERENCES public.caja(id),      -- efectivo de un punto de emisión (turnos)
  banco                text,
  numero_enmascarado   text CHECK (numero_enmascarado IS NULL OR numero_enmascarado ~ '^\*{4}[0-9]{1,4}$'),
  tipo_cuenta          text CHECK (tipo_cuenta IN ('ahorro', 'cheques', 'otra')),
  moneda               text NOT NULL CHECK (moneda ~ '^[A-Z]{3}$'),           -- ISO 4217
  fondo_fijo_centavos  bigint CHECK (fondo_fijo_centavos BETWEEN 1 AND 9007199254740991),
  cuenta_id            uuid NOT NULL UNIQUE,                 -- su subcuenta contable (1.1.01.NN)
  activa               boolean NOT NULL DEFAULT true,
  creado_por           uuid,
  creado_en            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (caja_id),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_id)   REFERENCES public.cuenta(empresa_id, id),
  CHECK (caja_id IS NULL OR tipo = 'efectivo_caja'),
  CHECK ((tipo = 'caja_chica') = (fondo_fijo_centavos IS NOT NULL)),
  CHECK ((tipo = 'banco') = (banco IS NOT NULL)),
  CHECK (tipo = 'banco' OR (numero_enmascarado IS NULL AND tipo_cuenta IS NULL))
);
CREATE UNIQUE INDEX cuenta_dinero_nombre ON public.cuenta_dinero (empresa_id, lower(nombre));

CREATE TABLE public.operacion_dinero (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                 uuid NOT NULL REFERENCES public.empresa(id),
  numero                     bigint NOT NULL,
  tipo                       text NOT NULL CHECK (tipo IN ('saldo_inicial', 'deposito', 'retiro', 'reposicion_caja_chica', 'traslado')),
  origen_id                  uuid,            -- de qué cuenta sale (NULL en saldo inicial)
  destino_id                 uuid NOT NULL,   -- a cuál entra (en depósito: el banco)
  transito_id                uuid,            -- depósito: dónde espera hasta confirmarse
  contrapartida_cuenta_id    uuid,            -- saldo inicial: contra qué cuenta contable
  monto_centavos             bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  fecha_contable             date NOT NULL,
  sucursal_id                uuid,
  referencia                 text,
  nota                       text,
  equipo                     text,
  estado                     text NOT NULL CHECK (estado IN ('aplicada', 'en_transito', 'confirmada')),
  asiento_id                 uuid NOT NULL,
  id_operacion               uuid NOT NULL,
  creado_por                 uuid,
  registrado_en              timestamptz NOT NULL DEFAULT now(),
  -- Confirmación del depósito (una vez)
  confirmada_en              timestamptz,
  confirmada_por             uuid,
  fecha_confirmacion         date,
  referencia_confirmacion    text,
  asiento_confirmacion_id    uuid,
  confirmacion_id_operacion  uuid,
  -- Anulación (una vez)
  anulada_en                 timestamptz,
  anulada_por                uuid,
  motivo_anulacion           text,
  fecha_anulacion            date,
  asiento_anulacion_id       uuid,
  anulacion_id_operacion     uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, origen_id)               REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, destino_id)              REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, transito_id)             REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, contrapartida_cuenta_id) REFERENCES public.cuenta(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)              REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_confirmacion_id) REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id)    REFERENCES public.asiento(empresa_id, id),
  CHECK ((tipo = 'saldo_inicial') = (origen_id IS NULL)),
  CHECK ((tipo = 'saldo_inicial') = (contrapartida_cuenta_id IS NOT NULL)),
  CHECK ((tipo = 'deposito') = (transito_id IS NOT NULL)),
  CHECK (origen_id IS DISTINCT FROM destino_id),
  CHECK ((tipo = 'deposito') = (estado <> 'aplicada')),
  CHECK ((estado = 'confirmada') = (asiento_confirmacion_id IS NOT NULL)),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL)),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL)),
  CHECK (anulada_en IS NULL OR estado <> 'confirmada')
);
CREATE INDEX operacion_dinero_empresa_fecha ON public.operacion_dinero (empresa_id, fecha_contable);
CREATE INDEX operacion_dinero_transito ON public.operacion_dinero (empresa_id) WHERE estado = 'en_transito' AND anulada_en IS NULL;

CREATE TABLE public.dinero_movimiento (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id        uuid NOT NULL REFERENCES public.empresa(id),
  cuenta_dinero_id  uuid NOT NULL,
  asiento_id        uuid NOT NULL,
  asiento_linea_id  bigint NOT NULL UNIQUE REFERENCES public.asiento_linea(id),
  fecha_contable    date NOT NULL,
  monto_centavos    bigint NOT NULL CHECK (monto_centavos <> 0),   -- + entra, - sale
  operacion         text NOT NULL,          -- dinero_deposito, gasto, pago_proveedor, compra, diferencia_arqueo...
  documento_tipo    text NOT NULL,          -- operacion_dinero, gasto, compra, pago_proveedor, turno_caja...
  documento_id      uuid NOT NULL,
  contrapartida     text,                   -- de dónde vino o a dónde fue (la otra cara del asiento)
  turno_id          uuid,                   -- turno de caja abierto en esa cuenta (023)
  referencia        text,
  equipo            text,
  creado_por        uuid,
  registrado_en     timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, cuenta_dinero_id) REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)       REFERENCES public.asiento(empresa_id, id)
);
CREATE INDEX dinero_movimiento_cuenta ON public.dinero_movimiento (cuenta_dinero_id, fecha_contable, id);
CREATE INDEX dinero_movimiento_empresa_fecha ON public.dinero_movimiento (empresa_id, fecha_contable);
CREATE INDEX dinero_movimiento_documento ON public.dinero_movimiento (documento_id);

CREATE TABLE public.adjunto (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id       uuid NOT NULL REFERENCES public.empresa(id),
  documento_tipo   text NOT NULL CHECK (documento_tipo ~ '^[a-z_]{3,40}$'),
  documento_id     uuid NOT NULL,
  ruta             text NOT NULL CHECK (length(ruta) BETWEEN 3 AND 500),   -- ruta en Supabase Storage
  tipo_contenido   text NOT NULL CHECK (tipo_contenido IN ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf')),
  huella_sha256    text NOT NULL CHECK (huella_sha256 ~ '^[0-9a-f]{64}$'),
  tamano_bytes     bigint CHECK (tamano_bytes IS NULL OR tamano_bytes BETWEEN 1 AND 52428800),
  nombre_original  text,
  subido_por       uuid,
  subido_en        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, documento_tipo, documento_id, huella_sha256)
);
CREATE INDEX adjunto_documento ON public.adjunto (documento_id);

-- Defensas de tabla
CREATE FUNCTION interno.proteger_cuenta_dinero() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.tipo, NEW.cuenta_id, NEW.caja_id, NEW.moneda, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.tipo, OLD.cuenta_id, OLD.caja_id, OLD.moneda, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: de una cuenta de dinero no se cambia el tipo, la subcuenta, la caja ni la moneda.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.cuenta_dinero FOR EACH ROW EXECUTE FUNCTION interno.proteger_cuenta_dinero();

-- La operación no se edita: el depósito se confirma una vez y cualquier
-- operación se anula una vez.
CREATE FUNCTION interno.proteger_operacion_dinero() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_conf constant text[] := ARRAY['estado', 'confirmada_en', 'confirmada_por', 'fecha_confirmacion',
                                  'referencia_confirmacion', 'asiento_confirmacion_id', 'confirmacion_id_operacion'];
  c_anul constant text[] := ARRAY['anulada_en', 'anulada_por', 'motivo_anulacion', 'fecha_anulacion',
                                  'asiento_anulacion_id', 'anulacion_id_operacion'];
BEGIN
  IF OLD.anulada_en IS NOT NULL OR OLD.estado = 'confirmada'
     OR (to_jsonb(NEW) - c_conf - c_anul) IS DISTINCT FROM (to_jsonb(OLD) - c_conf - c_anul)
     OR ((to_jsonb(NEW) - c_anul) IS DISTINCT FROM (to_jsonb(OLD) - c_anul) AND
         (OLD.estado <> 'en_transito' OR NEW.estado <> 'confirmada' OR NEW.anulada_en IS NOT NULL)) THEN
    RAISE EXCEPTION 'PROHIBIDO: una operación de dinero no se edita; el depósito se confirma una vez y se anula una vez.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.operacion_dinero FOR EACH ROW EXECUTE FUNCTION interno.proteger_operacion_dinero();

CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.cuenta_dinero    FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.operacion_dinero FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT ON public.dinero_movimiento FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT ON public.adjunto           FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.cuenta_dinero
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la cuenta de dinero en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.operacion_dinero
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las operaciones de dinero no se borran: se anulan.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.dinero_movimiento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los movimientos de dinero son de solo agregar; corrija anulando la operación.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.adjunto
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los comprobantes no se editan ni se borran.');

-- ---------------------------------------------------------------------
-- 3) Defensas del rastro sobre los asientos
-- ---------------------------------------------------------------------
-- Cuentas controladas (reemplaza la de 015): usa el código de CADA empresa
-- (cuenta_de) y además la subcuenta de una cuenta de dinero nunca acepta
-- asientos manuales.
CREATE OR REPLACE FUNCTION interno.revisar_cuenta_controlada() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_origen text;
  v_codigo text;
  v_cs     interno.cuenta_sistema;
  v_cd     text;
BEGIN
  SELECT a.origen INTO v_origen FROM public.asiento a WHERE a.id = NEW.asiento_id;
  IF v_origen IS DISTINCT FROM 'manual' THEN
    RETURN NEW;
  END IF;
  SELECT c.codigo INTO v_codigo FROM public.cuenta c WHERE c.id = NEW.cuenta_id;
  SELECT cs.* INTO v_cs FROM interno.cuenta_sistema cs
   WHERE cs.modulo_controla IS NOT NULL AND interno.cuenta_de(NEW.empresa_id, cs.uso) = v_codigo
     AND public.modulo_esta_activo(NEW.empresa_id, cs.modulo_controla)
   LIMIT 1;
  IF v_cs.uso IS NOT NULL THEN
    RAISE EXCEPTION 'CUENTA_CONTROLADA: la cuenta % la mueve el módulo "%"; use ese módulo en vez de un asiento manual.',
      v_codigo, v_cs.modulo_controla;
  END IF;
  SELECT d.nombre INTO v_cd FROM public.cuenta_dinero d WHERE d.cuenta_id = NEW.cuenta_id;
  IF v_cd IS NOT NULL THEN
    RAISE EXCEPTION 'CUENTA_CONTROLADA: la cuenta % es la cuenta de dinero "%"; el dinero se mueve con depósitos, traslados, gastos, pagos o cobros, no con un asiento manual.',
      v_codigo, v_cd;
  END IF;
  RETURN NEW;
END $$;

-- Al confirmar: toda línea que toca una cuenta de dinero tiene su movimiento.
CREATE FUNCTION interno.exigir_rastro_dinero() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_cd text;
BEGIN
  SELECT d.nombre INTO v_cd FROM public.cuenta_dinero d WHERE d.cuenta_id = NEW.cuenta_id;
  IF v_cd IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.asiento_linea_id = NEW.id) THEN
    RAISE EXCEPTION 'MOVIMIENTO_SIN_RASTRO: el asiento % mueve la cuenta de dinero "%" sin registrar su movimiento. No se guardó nada.',
      NEW.asiento_id, v_cd;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rastro_dinero AFTER INSERT ON public.asiento_linea
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION interno.exigir_rastro_dinero();

-- ---------------------------------------------------------------------
-- 4) Ayudantes
-- ---------------------------------------------------------------------
-- Equipo desde donde se opera: "equipo" en los datos, o la cabecera
-- x-equipo (o el navegador) de la llamada a Supabase.
CREATE FUNCTION interno.equipo(p_datos jsonb) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v text;
  h json;
BEGIN
  IF jsonb_typeof(p_datos) = 'object' AND p_datos ? 'equipo' THEN
    v := interno.json_texto(p_datos->'equipo', 'equipo', 200);
  END IF;
  IF v IS NULL THEN
    BEGIN
      h := nullif(current_setting('request.headers', true), '')::json;
      v := left(coalesce(h->>'x-equipo', h->>'user-agent'), 200);
    EXCEPTION WHEN OTHERS THEN
      v := NULL;
    END;
  END IF;
  RETURN v;
END $$;

-- Fecha AAAA-MM-DD desde jsonb (NULL si no viene).
CREATE FUNCTION interno.json_fecha(p_valor jsonb, p_campo text) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_valor IS NULL OR p_valor = 'null'::jsonb THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_valor) <> 'string' OR (p_valor #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: "%" debe ser una fecha AAAA-MM-DD.', p_campo;
  END IF;
  BEGIN
    RETURN (p_valor #>> '{}')::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: "%" no es una fecha válida.', p_campo;
  END;
END $$;

-- Sucursal activa o NULL (crear_cabecera toma entonces la primera activa).
CREATE FUNCTION interno.sucursal_activa(p_sucursal_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT s.id FROM public.sucursal s WHERE s.id = p_sucursal_id AND s.activa
$$;

-- Saldo de una cuenta de dinero (suma de sus movimientos).
CREATE FUNCTION interno.saldo_dinero(p_cuenta_dinero_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(m.monto_centavos), 0)::bigint FROM public.dinero_movimiento m WHERE m.cuenta_dinero_id = p_cuenta_dinero_id
$$;

-- Turno de caja abierto en una cuenta de dinero (en 023 se completa).
CREATE FUNCTION interno.turno_de_cuenta(p_cuenta_dinero_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NULL::uuid
$$;

-- Cuenta de dinero de la empresa (activa si se pide); error claro si no.
CREATE FUNCTION interno.cuenta_dinero_de(p_empresa_id uuid, p_id uuid, p_activa boolean DEFAULT true)
RETURNS public.cuenta_dinero
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  SELECT * INTO d FROM public.cuenta_dinero x WHERE x.id = p_id AND x.empresa_id = p_empresa_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de dinero no existe en esta empresa.';
  END IF;
  IF p_activa AND NOT d.activa THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de dinero "%" está desactivada.', d.nombre;
  END IF;
  RETURN d;
END $$;

-- La otra cara de una línea de asiento: de dónde vino o a dónde fue.
CREATE FUNCTION interno.contrapartida_linea(p_asiento_id uuid, p_linea_id bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT string_agg(DISTINCT coalesce(d.nombre, c.codigo || ' ' || c.nombre), ', ')
    FROM public.asiento_linea esta
    JOIN public.asiento_linea otra ON otra.asiento_id = esta.asiento_id AND otra.id <> esta.id
                                  AND (otra.debe_centavos > 0) <> (esta.debe_centavos > 0)
    JOIN public.cuenta c ON c.id = otra.cuenta_id
    LEFT JOIN public.cuenta_dinero d ON d.cuenta_id = otra.cuenta_id
   WHERE esta.id = p_linea_id AND esta.asiento_id = p_asiento_id
$$;

-- EL RASTRO: por cada línea del asiento que toca una cuenta de dinero,
-- un movimiento (usuario, equipo, referencia, contrapartida y turno).
-- Después revisa que ninguna cuenta quede en negativo y que la caja chica
-- no pase su fondo. Quien llama tiene tomado bloquear_libros.
CREATE FUNCTION interno.rastrear_dinero(p_asiento_id uuid, p_operacion text, p_documento_tipo text,
                                        p_documento_id uuid, p_referencia text DEFAULT NULL, p_equipo text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r       record;
  v_emp   uuid;
  v_fecha date;
  v_n     integer := 0;
  v_cds   uuid[] := '{}';
  d       public.cuenta_dinero;
  v_saldo bigint;
BEGIN
  IF p_asiento_id IS NULL THEN
    RETURN 0;
  END IF;
  SELECT a.empresa_id, a.fecha_contable INTO v_emp, v_fecha FROM public.asiento a WHERE a.id = p_asiento_id;
  PERFORM interno.bloquear_libros(v_emp);
  FOR r IN SELECT l.id, l.debe_centavos, l.haber_centavos, cd.id AS cd_id
             FROM public.asiento_linea l JOIN public.cuenta_dinero cd ON cd.cuenta_id = l.cuenta_id
            WHERE l.asiento_id = p_asiento_id
              AND NOT EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.asiento_linea_id = l.id)
            ORDER BY l.linea LOOP
    INSERT INTO public.dinero_movimiento (empresa_id, cuenta_dinero_id, asiento_id, asiento_linea_id, fecha_contable,
      monto_centavos, operacion, documento_tipo, documento_id, contrapartida, turno_id, referencia, equipo, creado_por)
    VALUES (v_emp, r.cd_id, p_asiento_id, r.id, v_fecha, r.debe_centavos - r.haber_centavos, p_operacion,
      p_documento_tipo, p_documento_id, interno.contrapartida_linea(p_asiento_id, r.id), interno.turno_de_cuenta(r.cd_id),
      nullif(trim(p_referencia), ''), p_equipo, auth.uid());
    v_n := v_n + 1;
    v_cds := v_cds || r.cd_id;
  END LOOP;

  FOR d IN SELECT * FROM public.cuenta_dinero x WHERE x.id = ANY (v_cds) LOOP
    v_saldo := interno.saldo_dinero(d.id);
    IF v_saldo < 0 THEN
      RAISE EXCEPTION 'SALDO_INSUFICIENTE: la cuenta "%" quedaría en % (no alcanza el dinero).',
        d.nombre, interno.lempiras(v_saldo);
    END IF;
    IF d.tipo = 'caja_chica' AND v_saldo > d.fondo_fijo_centavos THEN
      RAISE EXCEPTION 'TOPE_CAJA_CHICA: la caja chica "%" quedaría con % y su fondo fijo es %.',
        d.nombre, interno.lempiras(v_saldo), interno.lempiras(d.fondo_fijo_centavos);
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- Comprobante: {"ruta":"<empresa_id>/gastos/f123.jpg","tipo":"image/jpeg","sha256":"<64 hex>",
-- "tamano_bytes":123456,"nombre":"factura.jpg"}. La ruta empieza con el id
-- de la empresa (carpeta de la empresa en Storage). Si ya estaba, no se repite.
CREATE FUNCTION interno.guardar_adjunto(p_empresa_id uuid, p_documento_tipo text, p_documento_id uuid, p_comprobante jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ruta text;
  v_tipo text;
  v_sha  text;
  v_tam  bigint;
  v_id   uuid;
BEGIN
  IF p_comprobante IS NULL OR p_comprobante = 'null'::jsonb THEN
    RETURN NULL;
  END IF;
  PERFORM interno.exigir_claves(p_comprobante, ARRAY['ruta', 'tipo', 'sha256', 'tamano_bytes', 'nombre']);
  v_ruta := interno.json_texto(p_comprobante->'ruta', 'comprobante.ruta', 500);
  v_tipo := lower(interno.json_texto(p_comprobante->'tipo', 'comprobante.tipo', 50));
  v_sha  := lower(interno.json_texto(p_comprobante->'sha256', 'comprobante.sha256', 64));
  IF v_ruta IS NULL OR v_ruta NOT LIKE p_empresa_id::text || '/%' OR v_ruta LIKE '%..%' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la ruta del comprobante debe estar en la carpeta de la empresa ("%/...").', p_empresa_id;
  END IF;
  IF v_tipo IS NULL OR v_tipo NOT IN ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el comprobante debe ser una foto (jpeg, png, webp, heic) o un PDF.';
  END IF;
  IF v_sha IS NULL OR v_sha !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: falta la huella sha256 del comprobante (64 letras hexadecimales).';
  END IF;
  IF p_comprobante ? 'tamano_bytes' THEN
    v_tam := interno.json_centavos(p_comprobante->'tamano_bytes', 'comprobante.tamano_bytes');
    IF v_tam = 0 OR v_tam > 52428800 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el comprobante debe pesar entre 1 byte y 50 MB.';
    END IF;
  END IF;
  INSERT INTO public.adjunto (empresa_id, documento_tipo, documento_id, ruta, tipo_contenido, huella_sha256,
                              tamano_bytes, nombre_original, subido_por)
  VALUES (p_empresa_id, p_documento_tipo, p_documento_id, v_ruta, v_tipo, v_sha, v_tam,
          interno.json_texto(p_comprobante->'nombre', 'comprobante.nombre', 200), auth.uid())
  ON CONFLICT (empresa_id, documento_tipo, documento_id, huella_sha256) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT a.id INTO v_id FROM public.adjunto a
     WHERE a.empresa_id = p_empresa_id AND a.documento_tipo = p_documento_tipo
       AND a.documento_id = p_documento_id AND a.huella_sha256 = v_sha;
  END IF;
  RETURN v_id;
END $$;

-- Empresa dueña de un documento (para adjuntar). En 023 y 024 se amplía.
CREATE FUNCTION interno.empresa_de_documento(p_tipo text, p_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN CASE p_tipo
    WHEN 'operacion_dinero' THEN (SELECT x.empresa_id FROM public.operacion_dinero x WHERE x.id = p_id)
    WHEN 'compra'           THEN (SELECT x.empresa_id FROM public.compra x WHERE x.id = p_id)
    WHEN 'pago_proveedor'   THEN (SELECT x.empresa_id FROM public.pago_proveedor x WHERE x.id = p_id)
    WHEN 'cxp_saldo_inicial' THEN (SELECT x.empresa_id FROM public.cxp_saldo_inicial x WHERE x.id = p_id)
    WHEN 'inventario_documento' THEN (SELECT x.empresa_id FROM public.inventario_documento x WHERE x.id = p_id)
  END;
END $$;

-- Crea la cuenta de dinero y su subcuenta (1.1.01.NN, el siguiente libre).
CREATE FUNCTION interno.crear_cuenta_dinero_base(p_empresa_id uuid, p_tipo text, p_nombre text, p_sucursal_id uuid,
                                                 p_caja_id uuid, p_banco text, p_numero text, p_tipo_cuenta text,
                                                 p_moneda text, p_fondo bigint)
RETURNS public.cuenta_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_madre public.cuenta;
  v_n     integer;
  v_cta   uuid;
  v_cod   text;
  d       public.cuenta_dinero;
BEGIN
  PERFORM interno.bloquear_libros(p_empresa_id);
  IF EXISTS (SELECT 1 FROM public.cuenta_dinero x WHERE x.empresa_id = p_empresa_id AND lower(x.nombre) = lower(trim(p_nombre))) THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay una cuenta de dinero llamada "%".', trim(p_nombre);
  END IF;
  SELECT * INTO v_madre FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.codigo = '1.1.01';
  IF v_madre.id IS NULL OR v_madre.es_detalle OR NOT v_madre.activa THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: falta la cuenta 1.1.01 (Efectivo y equivalentes) en el catálogo. Avise a soporte.';
  END IF;
  SELECT coalesce(max(split_part(c.codigo, '.', 4)::integer), 0) + 1 INTO v_n
    FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.codigo ~ '^1\.1\.01\.[0-9]+$';
  IF v_n > 999 THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: ya no caben más subcuentas bajo 1.1.01. Avise a soporte.';
  END IF;
  v_cod := '1.1.01.' || lpad(v_n::text, 2, '0');
  INSERT INTO public.cuenta (empresa_id, codigo, nombre, tipo, naturaleza, padre_id, es_detalle)
  VALUES (p_empresa_id, v_cod, trim(p_nombre), 'activo', 'deudora', v_madre.id, true)
  RETURNING id INTO v_cta;
  INSERT INTO public.cuenta_dinero (empresa_id, tipo, nombre, sucursal_id, caja_id, banco, numero_enmascarado,
                                    tipo_cuenta, moneda, fondo_fijo_centavos, cuenta_id, creado_por)
  VALUES (p_empresa_id, p_tipo, trim(p_nombre), p_sucursal_id, p_caja_id, p_banco, p_numero,
          p_tipo_cuenta, p_moneda, p_fondo, v_cta, auth.uid())
  RETURNING * INTO d;
  RETURN d;
END $$;

-- Número de cuenta bancaria: solo se guardan los 4 últimos dígitos (****1234).
CREATE FUNCTION interno.enmascarar_numero(p_numero text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text := regexp_replace(coalesce(p_numero, ''), '[[:space:]-]', '', 'g');
BEGIN
  IF v = '' THEN
    RETURN NULL;
  END IF;
  IF v !~ '^[0-9]{4,30}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el número de cuenta lleva solo dígitos (4 a 30), con o sin guiones.';
  END IF;
  RETURN '****' || right(v, 4);
END $$;

-- Cuenta de tránsito para depósitos: la indicada, la primera activa, o se crea.
CREATE FUNCTION interno.cuenta_transito(p_empresa_id uuid, p_id uuid) RETURNS public.cuenta_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  IF p_id IS NOT NULL THEN
    d := interno.cuenta_dinero_de(p_empresa_id, p_id);
    IF d.tipo <> 'transito' THEN
      RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: "%" no es una cuenta de dinero en tránsito.', d.nombre;
    END IF;
    RETURN d;
  END IF;
  SELECT * INTO d FROM public.cuenta_dinero x
   WHERE x.empresa_id = p_empresa_id AND x.tipo = 'transito' AND x.activa ORDER BY x.creado_en, x.nombre LIMIT 1;
  IF d.id IS NULL THEN
    d := interno.crear_cuenta_dinero_base(p_empresa_id, 'transito', 'Depósitos en tránsito', NULL, NULL, NULL, NULL, NULL,
           (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id), NULL);
  END IF;
  RETURN d;
END $$;

-- Tipos de cuenta de dinero de los que se puede PAGAR (compras y gastos).
CREATE FUNCTION interno.cuenta_dinero_para_pagar(p_empresa_id uuid, p_id uuid) RETURNS public.cuenta_dinero
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  d := interno.cuenta_dinero_de(p_empresa_id, p_id);
  IF d.tipo NOT IN ('efectivo_caja', 'banco', 'caja_chica') THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: no se paga desde "%" (%); use una caja, la caja chica o un banco.', d.nombre, d.tipo;
  END IF;
  RETURN d;
END $$;

-- ---------------------------------------------------------------------
-- 5) RPC: cuentas de dinero
-- datos = {"tipo":"banco","nombre":"BAC cheques","banco":"BAC Credomatic",
--          "numero_cuenta":"7301-2345-6789","tipo_cuenta":"cheques","moneda":"HNL",
--          "sucursal_id":"..."}
--   efectivo_caja: "caja_id" (opcional: la caja/punto de emisión; sin ella
--                  es una caja general o caja fuerte)
--   caja_chica:    "fondo_fijo_centavos" (obligatorio, el tope)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.crear_cuenta_dinero(p_empresa_id uuid, p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_tipo   text;
  v_nombre text;
  v_suc    uuid;
  v_caja   public.caja;
  v_banco  text;
  v_num    text;
  v_tcta   text;
  v_mon    text;
  v_fondo  bigint;
  d        public.cuenta_dinero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  PERFORM interno.exigir_claves(p_datos, ARRAY['tipo', 'nombre', 'sucursal_id', 'caja_id', 'banco', 'numero_cuenta',
                                               'tipo_cuenta', 'moneda', 'fondo_fijo_centavos']);
  v_tipo := interno.json_texto(p_datos->'tipo', 'tipo', 40);
  IF v_tipo IS NULL OR v_tipo NOT IN ('efectivo_caja', 'banco', 'caja_chica', 'pos_por_liquidar',
                                      'transferencia_por_confirmar', 'transito') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo es efectivo_caja, banco, caja_chica, pos_por_liquidar, transferencia_por_confirmar o transito.';
  END IF;
  v_nombre := interno.json_texto(p_datos->'nombre', 'nombre', 100);
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la cuenta de dinero (ej. "BAC cheques" o "Caja chica oficina").';
  END IF;
  v_suc := interno.json_uuid(p_datos->'sucursal_id', 'sucursal_id');
  IF v_suc IS NOT NULL AND interno.sucursal_activa(v_suc) IS NULL
     OR v_suc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = v_suc AND s.empresa_id = p_empresa_id) THEN
    RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal no existe en esta empresa o está desactivada.';
  END IF;
  IF p_datos ? 'caja_id' AND p_datos->'caja_id' <> 'null'::jsonb THEN
    IF v_tipo <> 'efectivo_caja' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: solo una cuenta de efectivo (efectivo_caja) se liga a una caja.';
    END IF;
    SELECT * INTO v_caja FROM public.caja c
     WHERE c.id = interno.json_uuid(p_datos->'caja_id', 'caja_id') AND c.empresa_id = p_empresa_id AND c.activa;
    IF v_caja.id IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la caja no existe en esta empresa o está desactivada.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cuenta_dinero x WHERE x.caja_id = v_caja.id) THEN
      RAISE EXCEPTION 'YA_EXISTE: la caja "%" ya tiene su cuenta de efectivo.', v_caja.nombre;
    END IF;
    v_suc := v_caja.sucursal_id;
  END IF;
  IF v_tipo = 'banco' THEN
    v_banco := interno.json_texto(p_datos->'banco', 'banco', 100);
    v_num   := interno.enmascarar_numero(interno.json_texto(p_datos->'numero_cuenta', 'numero_cuenta', 40));
    v_tcta  := coalesce(interno.json_texto(p_datos->'tipo_cuenta', 'tipo_cuenta', 20), 'otra');
    IF v_banco IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique el banco (ej. "BAC Credomatic").';
    END IF;
    IF v_tcta NOT IN ('ahorro', 'cheques', 'otra') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el tipo de cuenta bancaria es ahorro, cheques u otra.';
    END IF;
  ELSIF p_datos ? 'banco' OR p_datos ? 'numero_cuenta' OR p_datos ? 'tipo_cuenta' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: banco, número y tipo de cuenta solo van en cuentas de tipo banco.';
  END IF;
  v_mon := coalesce(interno.json_texto(p_datos->'moneda', 'moneda', 3),
                    (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id));
  IF v_mon !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la moneda es un código ISO 4217 de 3 letras mayúsculas (ej. HNL).';
  END IF;
  IF v_mon <> (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id) THEN
    RAISE EXCEPTION 'MONEDA_NO_SOPORTADA: la cuenta es en % y la empresa lleva sus libros en %.',
      v_mon, (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id);
  END IF;
  IF v_tipo = 'caja_chica' THEN
    IF NOT p_datos ? 'fondo_fijo_centavos' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la caja chica necesita su fondo fijo ("fondo_fijo_centavos", el tope).';
    END IF;
    v_fondo := interno.json_centavos(p_datos->'fondo_fijo_centavos', 'fondo_fijo_centavos');
    IF v_fondo = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el fondo fijo de la caja chica debe ser mayor que cero.';
    END IF;
  ELSIF p_datos ? 'fondo_fijo_centavos' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el fondo fijo solo va en la caja chica.';
  END IF;

  d := interno.crear_cuenta_dinero_base(p_empresa_id, v_tipo, v_nombre, v_suc, v_caja.id, v_banco, v_num, v_tcta, v_mon, v_fondo);
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'tipo', d.tipo, 'nombre', d.nombre,
    'cuenta_codigo', (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id), 'numero_enmascarado', d.numero_enmascarado);
END $$;

-- Cambia nombre, banco, número, tipo de cuenta, sucursal o fondo fijo (con motivo).
CREATE FUNCTION public.editar_cuenta_dinero(p_empresa_id uuid, p_cuenta_dinero_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d     public.cuenta_dinero;
  n     public.cuenta_dinero;
  v_suc uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['nombre', 'banco', 'numero_cuenta', 'tipo_cuenta', 'sucursal_id', 'fondo_fijo_centavos']);
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = p_cuenta_dinero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de dinero no existe en esta empresa.';
  END IF;
  n := d;
  IF p_datos ? 'nombre' THEN
    n.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 100);
    IF n.nombre IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el nombre no puede quedar vacío.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cuenta_dinero x WHERE x.empresa_id = p_empresa_id AND x.id <> d.id
                 AND lower(x.nombre) = lower(n.nombre)) THEN
      RAISE EXCEPTION 'YA_EXISTE: ya hay una cuenta de dinero llamada "%".', n.nombre;
    END IF;
  END IF;
  IF (p_datos ? 'banco' OR p_datos ? 'numero_cuenta' OR p_datos ? 'tipo_cuenta') AND d.tipo <> 'banco' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: banco, número y tipo de cuenta solo van en cuentas de tipo banco.';
  END IF;
  IF p_datos ? 'banco' THEN
    n.banco := interno.json_texto(p_datos->'banco', 'banco', 100);
    IF n.banco IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique el banco.';
    END IF;
  END IF;
  IF p_datos ? 'numero_cuenta' THEN
    n.numero_enmascarado := interno.enmascarar_numero(interno.json_texto(p_datos->'numero_cuenta', 'numero_cuenta', 40));
  END IF;
  IF p_datos ? 'tipo_cuenta' THEN
    n.tipo_cuenta := interno.json_texto(p_datos->'tipo_cuenta', 'tipo_cuenta', 20);
    IF n.tipo_cuenta IS NULL OR n.tipo_cuenta NOT IN ('ahorro', 'cheques', 'otra') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el tipo de cuenta bancaria es ahorro, cheques u otra.';
    END IF;
  END IF;
  IF p_datos ? 'sucursal_id' THEN
    IF d.caja_id IS NOT NULL THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la cuenta de una caja va en la sucursal de su caja.';
    END IF;
    v_suc := interno.json_uuid(p_datos->'sucursal_id', 'sucursal_id');
    IF v_suc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = v_suc AND s.empresa_id = p_empresa_id AND s.activa) THEN
      RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal no existe en esta empresa o está desactivada.';
    END IF;
    n.sucursal_id := v_suc;
  END IF;
  IF p_datos ? 'fondo_fijo_centavos' THEN
    IF d.tipo <> 'caja_chica' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el fondo fijo solo va en la caja chica.';
    END IF;
    n.fondo_fijo_centavos := interno.json_centavos(p_datos->'fondo_fijo_centavos', 'fondo_fijo_centavos');
    IF n.fondo_fijo_centavos = 0 OR n.fondo_fijo_centavos < interno.saldo_dinero(d.id) THEN
      RAISE EXCEPTION 'TOPE_CAJA_CHICA: el fondo fijo no puede ser 0 ni menor que lo que hay hoy en la caja chica (%).',
        interno.lempiras(interno.saldo_dinero(d.id));
    END IF;
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cuenta_dinero SET nombre = n.nombre, banco = n.banco, numero_enmascarado = n.numero_enmascarado,
         tipo_cuenta = n.tipo_cuenta, sucursal_id = n.sucursal_id, fondo_fijo_centavos = n.fondo_fijo_centavos
   WHERE id = d.id;
  IF n.nombre IS DISTINCT FROM d.nombre THEN
    UPDATE public.cuenta SET nombre = n.nombre WHERE id = d.cuenta_id;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'editada', true);
END $$;

-- Solo con saldo 0, sin turno abierto y sin depósitos en tránsito hacia ella.
CREATE FUNCTION public.desactivar_cuenta_dinero(p_empresa_id uuid, p_cuenta_dinero_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva la cuenta (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = p_cuenta_dinero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de dinero no existe en esta empresa.';
  END IF;
  IF NOT d.activa THEN
    RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'activa', false, 'ya_estaba', true);
  END IF;
  IF interno.saldo_dinero(d.id) <> 0 THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la cuenta "%" todavía tiene % ; trasládelo antes de desactivarla.',
      d.nombre, interno.lempiras(interno.saldo_dinero(d.id));
  END IF;
  IF interno.turno_de_cuenta(d.id) IS NOT NULL THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la caja "%" tiene un turno abierto; ciérrelo primero.', d.nombre;
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero o WHERE o.destino_id = d.id AND o.estado = 'en_transito' AND o.anulada_en IS NULL) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: hay depósitos en tránsito hacia "%"; confírmelos o anúlelos primero.', d.nombre;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cuenta_dinero SET activa = false WHERE id = d.id;
  UPDATE public.cuenta SET activa = false WHERE id = d.cuenta_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'activa', false, 'ya_estaba', false);
END $$;

CREATE FUNCTION public.reactivar_cuenta_dinero(p_empresa_id uuid, p_cuenta_dinero_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.administrar', 'dinero');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva la cuenta (mínimo 5 letras).';
  END IF;
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = p_cuenta_dinero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de dinero no existe en esta empresa.';
  END IF;
  IF d.activa THEN
    RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'activa', true, 'ya_estaba', true);
  END IF;
  IF d.caja_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.caja c WHERE c.id = d.caja_id AND c.activa) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la caja de esta cuenta está desactivada; reactívela primero.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cuenta_dinero SET activa = true WHERE id = d.id;
  UPDATE public.cuenta SET activa = true WHERE id = d.cuenta_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'activa', true, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- 6) Operaciones de dinero
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.operacion_dinero_respuesta(o public.operacion_dinero, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('operacion_id', o.id, 'tipo', o.tipo, 'numero', o.numero, 'estado', o.estado,
                            'monto_centavos', o.monto_centavos, 'asiento_id', o.asiento_id,
                            'saldo_origen_centavos', CASE WHEN o.origen_id IS NOT NULL THEN interno.saldo_dinero(o.origen_id) END,
                            'saldo_destino_centavos', interno.saldo_dinero(o.destino_id),
                            'duplicado', p_duplicado)
$$;

-- Guarda la operación con su asiento y su rastro (quien llama ya validó
-- todo y tiene el candado). p_lineas como en asiento_sistema.
CREATE FUNCTION interno.guardar_operacion_dinero(p_empresa_id uuid, p_tipo text, p_origen public.cuenta_dinero,
                                                 p_destino public.cuenta_dinero, p_transito public.cuenta_dinero,
                                                 p_contrapartida_id uuid, p_monto bigint, p_fecha date,
                                                 p_referencia text, p_nota text, p_equipo text, p_comprobante jsonb,
                                                 p_descripcion text, p_lineas jsonb, p_id_operacion uuid)
RETURNS public.operacion_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id   uuid := gen_random_uuid();
  v_num  bigint := interno.siguiente_numero(p_empresa_id, 'operacion_dinero');
  v_suc  uuid := coalesce(interno.sucursal_activa(p_origen.sucursal_id), interno.sucursal_activa(p_destino.sucursal_id));
  v_asto uuid;
  o      public.operacion_dinero;
BEGIN
  v_asto := interno.asiento_sistema(p_empresa_id, v_suc, p_fecha,
    replace(p_descripcion, '#N', '#' || v_num) || coalesce(' ref. ' || nullif(trim(p_referencia), ''), ''),
    'dinero_' || p_tipo, p_id_operacion, p_lineas);
  INSERT INTO public.operacion_dinero (id, empresa_id, numero, tipo, origen_id, destino_id, transito_id,
    contrapartida_cuenta_id, monto_centavos, fecha_contable, sucursal_id, referencia, nota, equipo, estado,
    asiento_id, id_operacion, creado_por)
  VALUES (v_id, p_empresa_id, v_num, p_tipo, p_origen.id, p_destino.id, p_transito.id, p_contrapartida_id, p_monto,
    p_fecha, v_suc, nullif(trim(p_referencia), ''), nullif(trim(p_nota), ''), p_equipo,
    CASE WHEN p_tipo = 'deposito' THEN 'en_transito' ELSE 'aplicada' END, v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO o;
  PERFORM interno.rastrear_dinero(v_asto, 'dinero_' || p_tipo, 'operacion_dinero', v_id, p_referencia, p_equipo);
  PERFORM interno.guardar_adjunto(p_empresa_id, 'operacion_dinero', v_id, p_comprobante);
  RETURN o;
END $$;

-- RPC: trasladar_dinero(empresa, datos, id_operacion)   permiso dinero.trasladar
-- datos = {"tipo":"deposito"|"retiro"|"reposicion_caja_chica"|"traslado",
--          "origen_id":"...","destino_id":"...","monto_centavos":250000,
--          "fecha":"2026-01-15" (defecto hoy),"referencia":"Boleta 99881",
--          "nota":"...","equipo":"Caja 1","transito_id":"..." (depósito, opcional),
--          "comprobante":{"ruta":"...","tipo":"image/jpeg","sha256":"..."}}
--   deposito:   de una caja de efectivo o caja chica a un banco. Queda EN
--               TRÁNSITO (Dr Depósitos en tránsito / Cr caja) hasta confirmar_deposito.
--   retiro:     de un banco a una caja de efectivo o caja chica.
--   reposicion_caja_chica: de un banco o caja de efectivo a la caja chica;
--               sin monto repone lo gastado (fondo fijo - saldo).
--   traslado:   entre dos cuentas cualesquiera (no de tránsito).
CREATE FUNCTION public.trasladar_dinero(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_tipo  text;
  o       public.cuenta_dinero;
  d       public.cuenta_dinero;
  t       public.cuenta_dinero;
  v_monto bigint;
  v_fecha date;
  v_op    public.operacion_dinero;
  v_desc  text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.trasladar', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['tipo', 'origen_id', 'destino_id', 'transito_id', 'monto_centavos',
                                               'fecha', 'referencia', 'nota', 'equipo', 'comprobante']);
  v_tipo := interno.json_texto(p_datos->'tipo', 'tipo', 30);
  IF v_tipo IS NULL OR v_tipo NOT IN ('deposito', 'retiro', 'reposicion_caja_chica', 'traslado') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo es deposito, retiro, reposicion_caja_chica o traslado.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'dinero_' || v_tipo);
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    RETURN interno.operacion_dinero_respuesta(v_op, true);
  END IF;

  o := interno.cuenta_dinero_de(p_empresa_id, interno.json_uuid(p_datos->'origen_id', 'origen_id'));
  d := interno.cuenta_dinero_de(p_empresa_id, interno.json_uuid(p_datos->'destino_id', 'destino_id'));
  IF o.id = d.id THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: el origen y el destino deben ser cuentas distintas.';
  END IF;
  IF o.tipo = 'transito' OR d.tipo = 'transito' THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: el dinero en tránsito solo se mueve con depósitos (y se confirma con confirmar_deposito).';
  END IF;
  IF v_tipo = 'deposito' AND (o.tipo NOT IN ('efectivo_caja', 'caja_chica') OR d.tipo <> 'banco') THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: un depósito va de una caja de efectivo (o caja chica) a un banco.';
  END IF;
  IF v_tipo = 'retiro' AND (o.tipo <> 'banco' OR d.tipo NOT IN ('efectivo_caja', 'caja_chica')) THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: un retiro va de un banco a una caja de efectivo (o caja chica).';
  END IF;
  IF v_tipo = 'reposicion_caja_chica' AND (d.tipo <> 'caja_chica' OR o.tipo NOT IN ('banco', 'efectivo_caja')) THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la reposición va de un banco o una caja de efectivo a la caja chica.';
  END IF;
  IF p_datos ? 'monto_centavos' THEN
    v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
    IF v_monto = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el monto debe ser mayor que cero.';
    END IF;
  ELSIF v_tipo <> 'reposicion_caja_chica' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el monto en centavos ("monto_centavos").';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  -- Candado, reintento y mes abierto.
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'dinero_' || v_tipo);
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    RETURN interno.operacion_dinero_respuesta(v_op, true);
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  IF v_monto IS NULL THEN
    v_monto := d.fondo_fijo_centavos - interno.saldo_dinero(d.id);
    IF v_monto <= 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la caja chica "%" ya tiene su fondo completo (%).', d.nombre, interno.lempiras(d.fondo_fijo_centavos);
    END IF;
  END IF;

  IF v_tipo = 'deposito' THEN
    t := interno.cuenta_transito(p_empresa_id, interno.json_uuid(p_datos->'transito_id', 'transito_id'));
    v_desc := 'Depósito #N de ' || o.nombre || ' a ' || d.nombre || ' (en tránsito)';
    v_op := interno.guardar_operacion_dinero(p_empresa_id, v_tipo, o, d, t, NULL, v_monto, v_fecha,
      interno.json_texto(p_datos->'referencia', 'referencia', 100), interno.json_texto(p_datos->'nota', 'nota', 500),
      interno.equipo(p_datos), p_datos->'comprobante', v_desc,
      jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = t.cuenta_id), 'debe', v_monto),
                        jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = o.cuenta_id), 'haber', v_monto)),
      p_id_operacion);
  ELSE
    v_desc := CASE v_tipo WHEN 'retiro' THEN 'Retiro #N' WHEN 'reposicion_caja_chica' THEN 'Reposición de caja chica #N'
                          ELSE 'Traslado #N' END || ' de ' || o.nombre || ' a ' || d.nombre;
    v_op := interno.guardar_operacion_dinero(p_empresa_id, v_tipo, o, d, NULL, NULL, v_monto, v_fecha,
      interno.json_texto(p_datos->'referencia', 'referencia', 100), interno.json_texto(p_datos->'nota', 'nota', 500),
      interno.equipo(p_datos), p_datos->'comprobante', v_desc,
      jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id), 'debe', v_monto),
                        jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = o.cuenta_id), 'haber', v_monto)),
      p_id_operacion);
  END IF;
  RETURN interno.operacion_dinero_respuesta(v_op, false);
END $$;

-- RPC: registrar_saldo_inicial_dinero(empresa, datos, id_operacion)   dinero.saldo_inicial (dueño)
-- datos = {"cuenta_dinero_id":"...","monto_centavos":1500000,"fecha":"2026-01-01" (defecto: inicio
--          de la empresa),"contrapartida":"1.1.01.03" (opcional: pasar el saldo de una cuenta
--          de efectivo SIN rastro; sin ella va contra Saldos de apertura),"referencia","nota","comprobante"}
-- Una sola vez por cuenta (anulada no cuenta).
CREATE FUNCTION public.registrar_saldo_inicial_dinero(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d       public.cuenta_dinero;
  v_monto bigint;
  v_fecha date;
  v_cta   public.cuenta;
  v_cod   text;
  v_op    public.operacion_dinero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.saldo_inicial', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'dinero_saldo_inicial');
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    RETURN interno.operacion_dinero_respuesta(v_op, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cuenta_dinero_id', 'monto_centavos', 'fecha', 'contrapartida',
                                               'referencia', 'nota', 'equipo', 'comprobante']);
  d := interno.cuenta_dinero_de(p_empresa_id, interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id'));
  IF d.tipo = 'transito' THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: el dinero en tránsito no lleva saldo inicial; registre cada depósito.';
  END IF;
  v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  IF v_monto = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el saldo inicial debe ser mayor que cero.';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), (SELECT e.fecha_inicio FROM public.empresa e WHERE e.id = p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  v_cod := coalesce(interno.json_texto(p_datos->'contrapartida', 'contrapartida', 30), interno.cuenta_de(p_empresa_id, 'apertura_dinero'));
  SELECT * INTO v_cta FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.codigo = v_cod;
  IF v_cta.id IS NULL OR NOT v_cta.es_detalle OR NOT v_cta.activa
     OR (v_cod <> interno.cuenta_de(p_empresa_id, 'apertura_dinero') AND v_cod NOT LIKE '1.1.01.%')
     OR EXISTS (SELECT 1 FROM public.cuenta_dinero x WHERE x.cuenta_id = v_cta.id) THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la contrapartida es Saldos de apertura o una cuenta de efectivo 1.1.01 que NO sea cuenta de dinero (para pasar su saldo).';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'dinero_saldo_inicial');
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    RETURN interno.operacion_dinero_respuesta(v_op, true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.destino_id = d.id AND x.tipo = 'saldo_inicial' AND x.anulada_en IS NULL) THEN
    RAISE EXCEPTION 'SALDO_INICIAL_YA_CARGADO: la cuenta "%" ya tiene saldo inicial; anúlelo si estaba mal.', d.nombre;
  END IF;
  IF interno.turno_de_cuenta(d.id) IS NOT NULL THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la caja "%" tiene un turno abierto; el saldo inicial se carga sin turno.', d.nombre;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);

  v_op := interno.guardar_operacion_dinero(p_empresa_id, 'saldo_inicial', NULL, d, NULL, v_cta.id, v_monto, v_fecha,
    interno.json_texto(p_datos->'referencia', 'referencia', 100), interno.json_texto(p_datos->'nota', 'nota', 500),
    interno.equipo(p_datos), p_datos->'comprobante', 'Saldo inicial #N de ' || d.nombre || ' contra ' || v_cta.codigo || ' ' || v_cta.nombre,
    jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id), 'debe', v_monto),
                      jsonb_build_object('cuenta', v_cta.codigo, 'haber', v_monto)),
    p_id_operacion);
  RETURN interno.operacion_dinero_respuesta(v_op, false);
END $$;

-- RPC: confirmar_deposito(operacion, id_operacion, fecha?, referencia?)   dinero.trasladar
-- El banco ya tiene el dinero: Dr banco / Cr Depósitos en tránsito.
CREATE FUNCTION public.confirmar_deposito(p_operacion_id uuid, p_id_operacion uuid, p_fecha date DEFAULT NULL,
                                          p_referencia text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o       public.operacion_dinero;
  v_fecha date;
  v_asto  uuid;
  v_ref   text := nullif(trim(p_referencia), '');
BEGIN
  SELECT * INTO o FROM public.operacion_dinero WHERE id = p_operacion_id;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la operación de dinero no existe.';
  END IF;
  PERFORM interno.exigir_escritura(o.empresa_id, 'dinero.trasladar', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(o.empresa_id, p_id_operacion, 'confirmacion_deposito');
  IF o.confirmacion_id_operacion = p_id_operacion THEN
    RETURN interno.operacion_dinero_respuesta(o, true);
  END IF;
  IF o.tipo <> 'deposito' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: solo los depósitos se confirman.';
  END IF;
  IF length(v_ref) > 100 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la referencia es demasiado larga (máximo 100 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(o.empresa_id), o.fecha_contable));
  PERFORM interno.exigir_fecha_contable(o.empresa_id, v_fecha);
  IF v_fecha < o.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la confirmación no puede tener fecha anterior al depósito (%).', to_char(o.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(o.empresa_id, p_id_operacion, 'confirmacion_deposito');
  SELECT * INTO o FROM public.operacion_dinero WHERE id = p_operacion_id FOR UPDATE;
  IF o.confirmacion_id_operacion = p_id_operacion THEN
    RETURN interno.operacion_dinero_respuesta(o, true);
  END IF;
  IF o.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el depósito #% está anulado.', o.numero;
  END IF;
  IF o.estado = 'confirmada' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el depósito #% ya fue confirmado.', o.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(o.empresa_id, v_fecha);

  v_asto := interno.asiento_sistema(o.empresa_id, interno.sucursal_activa(o.sucursal_id), v_fecha,
    'Confirmación del depósito #' || o.numero || ' en ' || (SELECT x.nombre FROM public.cuenta_dinero x WHERE x.id = o.destino_id)
      || coalesce(' ref. ' || v_ref, ''),
    'confirmacion_deposito', p_id_operacion,
    jsonb_build_array(
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta_dinero x JOIN public.cuenta c ON c.id = x.cuenta_id WHERE x.id = o.destino_id), 'debe', o.monto_centavos),
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta_dinero x JOIN public.cuenta c ON c.id = x.cuenta_id WHERE x.id = o.transito_id), 'haber', o.monto_centavos)));
  UPDATE public.operacion_dinero
     SET estado = 'confirmada', confirmada_en = now(), confirmada_por = auth.uid(), fecha_confirmacion = v_fecha,
         referencia_confirmacion = v_ref, asiento_confirmacion_id = v_asto, confirmacion_id_operacion = p_id_operacion
   WHERE id = o.id
  RETURNING * INTO o;
  PERFORM interno.rastrear_dinero(v_asto, 'confirmacion_deposito', 'operacion_dinero', o.id, coalesce(v_ref, o.referencia), NULL);
  RETURN interno.operacion_dinero_respuesta(o, false);
END $$;

-- RPC: anular_operacion_dinero(operacion, motivo, id_operacion, fecha?)   dinero.anular
-- (el saldo inicial además pide dinero.saldo_inicial). Contra-asiento del
-- original. Un depósito ya confirmado no se anula: el dinero ya está en el
-- banco (corrija con un retiro o traslado).
CREATE FUNCTION public.anular_operacion_dinero(p_operacion_id uuid, p_motivo text, p_id_operacion uuid,
                                               p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o       public.operacion_dinero;
  v_fecha date;
  v_asto  uuid;
BEGIN
  SELECT * INTO o FROM public.operacion_dinero WHERE id = p_operacion_id;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la operación de dinero no existe.';
  END IF;
  PERFORM interno.exigir_escritura(o.empresa_id, 'dinero.anular', 'dinero');
  IF o.tipo = 'saldo_inicial' AND NOT public.tiene_permiso('dinero.saldo_inicial', o.empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "dinero.saldo_inicial".';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(o.empresa_id, p_id_operacion, 'anulacion_operacion_dinero');
  IF o.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.operacion_dinero_respuesta(o, true) || jsonb_build_object('asiento_anulacion_id', o.asiento_anulacion_id);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(o.empresa_id), o.fecha_contable));
  PERFORM interno.exigir_fecha_contable(o.empresa_id, v_fecha);
  IF v_fecha < o.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior a la operación (%).', to_char(o.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(o.empresa_id, p_id_operacion, 'anulacion_operacion_dinero');
  SELECT * INTO o FROM public.operacion_dinero WHERE id = p_operacion_id FOR UPDATE;
  IF o.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.operacion_dinero_respuesta(o, true) || jsonb_build_object('asiento_anulacion_id', o.asiento_anulacion_id);
  END IF;
  IF o.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: la operación #% ya fue anulada.', o.numero;
  END IF;
  IF o.estado = 'confirmada' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el depósito #% ya está confirmado en el banco; corríjalo con un retiro o un traslado.', o.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(o.empresa_id, v_fecha);

  v_asto := interno.asiento_sistema(o.empresa_id, o.sucursal_id, v_fecha,
    'ANULACIÓN ' || replace(o.tipo, '_', ' ') || ' #' || o.numero || ': ' || trim(p_motivo),
    'anulacion_operacion_dinero', p_id_operacion,
    (SELECT jsonb_agg(jsonb_build_object('cuenta', c.codigo, 'debe', l.haber_centavos, 'haber', l.debe_centavos,
                                         'descripcion', 'Reversión') ORDER BY l.linea)
       FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = o.asiento_id),
    o.asiento_id, trim(p_motivo));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.operacion_dinero
     SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo), fecha_anulacion = v_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = o.id
  RETURNING * INTO o;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_operacion_dinero', 'operacion_dinero', o.id, trim(p_motivo), NULL);
  RETURN interno.operacion_dinero_respuesta(o, false) || jsonb_build_object('asiento_anulacion_id', v_asto);
END $$;

-- RPC: agregar_adjunto(empresa, documento_tipo, documento_id, comprobante)   adjuntos.agregar
-- documento_tipo: operacion_dinero, gasto, turno_caja, compra, pago_proveedor,
-- cxp_saldo_inicial, inventario_documento. Nunca se borra; repetido = el mismo.
CREATE FUNCTION public.agregar_adjunto(p_empresa_id uuid, p_documento_tipo text, p_documento_id uuid, p_comprobante jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'adjuntos.agregar', NULL);
  IF interno.empresa_de_documento(p_documento_tipo, p_documento_id) IS DISTINCT FROM p_empresa_id THEN
    RAISE EXCEPTION 'NO_EXISTE: el documento (% %) no existe en esta empresa.', p_documento_tipo, p_documento_id;
  END IF;
  IF p_comprobante IS NULL OR p_comprobante = 'null'::jsonb THEN
    RAISE EXCEPTION 'DATO_INVALIDO: falta el comprobante (ruta, tipo y sha256).';
  END IF;
  v_id := interno.guardar_adjunto(p_empresa_id, p_documento_tipo, p_documento_id, p_comprobante);
  RETURN jsonb_build_object('adjunto_id', v_id);
END $$;

-- ---------------------------------------------------------------------
-- 7) Compras: pagar desde una cuenta de dinero y dejar el rastro
-- ---------------------------------------------------------------------
-- Cuenta de pago (código) a partir de cuenta_dinero_id o del código; si el
-- código es de una cuenta de dinero, se valida como tal.
CREATE FUNCTION interno.codigo_cuenta_pago(p_empresa_id uuid, p_cuenta_dinero_id uuid, p_codigo text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d     public.cuenta_dinero;
  v_cod text;
BEGIN
  IF p_cuenta_dinero_id IS NOT NULL THEN
    IF NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa.';
    END IF;
    d := interno.cuenta_dinero_para_pagar(p_empresa_id, p_cuenta_dinero_id);
    v_cod := (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id);
    IF nullif(trim(p_codigo), '') IS NOT NULL AND trim(p_codigo) <> v_cod THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de pago (%) no es la de la cuenta de dinero "%" (%).', p_codigo, d.nombre, v_cod;
    END IF;
    RETURN v_cod;
  END IF;
  SELECT x.id INTO d.id FROM public.cuenta_dinero x JOIN public.cuenta c ON c.id = x.cuenta_id
   WHERE x.empresa_id = p_empresa_id AND c.codigo = trim(p_codigo);
  IF d.id IS NOT NULL THEN
    PERFORM interno.cuenta_dinero_para_pagar(p_empresa_id, d.id);
  END IF;
  RETURN nullif(trim(p_codigo), '');
END $$;

-- registrar_compra (reemplaza la envoltura de 021; misma firma). Nuevo:
-- "cuenta_dinero_id" en una compra de contado (la forma de pago sale del
-- tipo de cuenta si no se manda) y rastro del dinero.
CREATE OR REPLACE FUNCTION public.registrar_compra(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_doc   text;
  v_prov  uuid;
  v_datos jsonb := p_datos;
  v_cd    uuid;
  v_cod   text;
  r       jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.registrar', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'compra');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'compra');
  IF jsonb_typeof(p_datos) = 'object' AND NOT EXISTS (SELECT 1 FROM public.compra x
                                                       WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    IF jsonb_typeof(p_datos->'numero_documento') = 'string' AND jsonb_typeof(p_datos->'proveedor_id') = 'string' THEN
      v_doc  := trim(p_datos->>'numero_documento');
      v_prov := interno.json_uuid(p_datos->'proveedor_id', 'proveedor_id');
      IF EXISTS (SELECT 1 FROM public.cxp_saldo_inicial s
                  WHERE s.empresa_id = p_empresa_id AND s.proveedor_id = v_prov
                    AND upper(s.numero_documento) = upper(v_doc) AND s.anulada_en IS NULL) THEN
        RAISE EXCEPTION 'YA_EXISTE: la factura % de este proveedor ya está registrada como saldo inicial.', v_doc;
      END IF;
    END IF;
    IF p_datos ? 'cuenta_dinero_id' OR (p_datos ? 'cuenta_pago' AND jsonb_typeof(p_datos->'cuenta_pago') = 'string') THEN
      v_cd  := interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id');
      v_cod := interno.codigo_cuenta_pago(p_empresa_id, v_cd, p_datos->>'cuenta_pago');
      v_datos := v_datos - 'cuenta_dinero_id';
      IF v_cd IS NOT NULL THEN
        v_datos := v_datos || jsonb_build_object('cuenta_pago', v_cod);
        IF NOT v_datos ? 'forma_pago' AND coalesce(v_datos->>'condicion', '') = 'contado' THEN
          v_datos := v_datos || jsonb_build_object('forma_pago',
            CASE WHEN (SELECT x.tipo FROM public.cuenta_dinero x WHERE x.id = v_cd) = 'banco' THEN 'banco' ELSE 'caja' END);
        END IF;
      END IF;
    END IF;
  END IF;
  r := interno.registrar_compra_base(p_empresa_id, v_datos, p_id_operacion);
  IF NOT (r->>'duplicado')::boolean THEN
    PERFORM interno.rastrear_dinero((r->>'asiento_id')::uuid, 'compra', 'compra', (r->>'compra_id')::uuid,
                                    'Factura ' || (p_datos->>'numero_documento'), interno.equipo(p_datos));
  END IF;
  RETURN r;
END $$;

-- pagar_proveedor: nuevo parámetro final p_cuenta_dinero_id (opcional; las
-- llamadas de antes siguen igual). La forma de pago puede ir en NULL si se
-- da la cuenta de dinero.
DROP FUNCTION public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text);
CREATE FUNCTION public.pagar_proveedor(p_empresa_id uuid, p_compra_id uuid, p_monto_centavos bigint,
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

CREATE OR REPLACE FUNCTION public.anular_pago_proveedor(p_pago_id uuid, p_motivo text, p_id_operacion uuid,
                                                        p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_emp uuid;
  r     jsonb;
BEGIN
  SELECT p.empresa_id INTO v_emp FROM public.pago_proveedor p WHERE p.id = p_pago_id;
  IF v_emp IS NOT NULL AND p_id_operacion IS NOT NULL THEN
    PERFORM interno.exigir_escritura(v_emp, 'compras.anular', 'compras');
    PERFORM interno.exigir_tipo_operacion(v_emp, p_id_operacion, 'anulacion_pago_proveedor');
    PERFORM interno.reservar_operacion(v_emp, p_id_operacion, 'anulacion_pago_proveedor');
  END IF;
  r := interno.anular_pago_proveedor_base(p_pago_id, p_motivo, p_id_operacion, p_fecha);
  IF NOT (r->>'duplicado')::boolean THEN
    PERFORM interno.rastrear_dinero((r->>'asiento_id')::uuid, 'anulacion_pago_proveedor', 'pago_proveedor', p_pago_id,
                                    trim(p_motivo), NULL);
  END IF;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.anular_compra(p_compra_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_emp uuid;
  r     jsonb;
BEGIN
  SELECT c.empresa_id INTO v_emp FROM public.compra c WHERE c.id = p_compra_id;
  IF v_emp IS NOT NULL AND p_id_operacion IS NOT NULL THEN
    PERFORM interno.exigir_escritura(v_emp, 'compras.anular', 'compras');
    PERFORM interno.exigir_tipo_operacion(v_emp, p_id_operacion, 'anulacion_compra');
    PERFORM interno.reservar_operacion(v_emp, p_id_operacion, 'anulacion_compra');
  END IF;
  r := interno.anular_compra_base(p_compra_id, p_motivo, p_id_operacion, p_fecha);
  IF NOT (r->>'duplicado')::boolean THEN
    PERFORM interno.rastrear_dinero((r->>'asiento_id')::uuid, 'anulacion_compra', 'compra', p_compra_id, trim(p_motivo), NULL);
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 8) configurar_empresa (reemplaza la de 020; misma firma). Clave nueva:
--    "dias_alerta_transito" (0 a 60): días de un depósito sin confirmar
--    antes de la alerta.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.configurar_empresa(p_empresa_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k     text;
  v_emp public.empresa;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_datos) LOOP
    IF k NOT IN ('tope_credito_centavos', 'permite_existencia_negativa', 'precio_incluye_isv_defecto', 'dias_alerta_transito') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'tope_credito_centavos' AND NOT (jsonb_typeof(p_datos->'tope_credito_centavos') = 'number'
       AND (p_datos->>'tope_credito_centavos') ~ '^[0-9]{1,16}$'
       AND (p_datos->>'tope_credito_centavos')::numeric <= 9007199254740991) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "tope_credito_centavos" debe ser un entero de centavos, 0 o más.';
  END IF;
  IF p_datos ? 'permite_existencia_negativa' AND jsonb_typeof(p_datos->'permite_existencia_negativa') <> 'boolean' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "permite_existencia_negativa" debe ser true o false.';
  END IF;
  IF p_datos ? 'precio_incluye_isv_defecto' AND jsonb_typeof(p_datos->'precio_incluye_isv_defecto') <> 'boolean' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "precio_incluye_isv_defecto" debe ser true o false.';
  END IF;
  IF p_datos ? 'dias_alerta_transito' AND NOT (jsonb_typeof(p_datos->'dias_alerta_transito') = 'number'
       AND (p_datos->>'dias_alerta_transito') ~ '^[0-9]{1,2}$' AND (p_datos->>'dias_alerta_transito')::integer <= 60) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "dias_alerta_transito" debe ser un número entero de 0 a 60.';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET
    tope_credito_centavos = coalesce((p_datos->>'tope_credito_centavos')::bigint, tope_credito_centavos),
    permite_existencia_negativa = coalesce((p_datos->>'permite_existencia_negativa')::boolean, permite_existencia_negativa),
    precio_incluye_isv_defecto = coalesce((p_datos->>'precio_incluye_isv_defecto')::boolean, precio_incluye_isv_defecto),
    dias_alerta_transito = coalesce((p_datos->>'dias_alerta_transito')::integer, dias_alerta_transito)
  WHERE id = p_empresa_id
  RETURNING * INTO v_emp;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('tope_credito_centavos', v_emp.tope_credito_centavos,
                            'permite_existencia_negativa', v_emp.permite_existencia_negativa,
                            'precio_incluye_isv_defecto', v_emp.precio_incluye_isv_defecto,
                            'dias_alerta_transito', v_emp.dias_alerta_transito);
END $$;

-- ---------------------------------------------------------------------
-- 9) id_operacion por tipo: las tablas de la etapa 2b se revisan en
--    interno.tipo_operacion_2b (se amplía en 023 y 024).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.tipo_operacion_2b(p_empresa_id uuid, p_id uuid) RETURNS text
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
  RETURN NULL;
END $$;

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
  v := interno.tipo_operacion_2b(p_empresa_id, p_id);
  IF v IS NOT NULL THEN
    RETURN v;
  END IF;
  SELECT a.origen INTO v FROM public.asiento a WHERE a.empresa_id = p_empresa_id AND a.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN CASE v WHEN 'manual' THEN 'asiento' WHEN 'anulacion' THEN 'anulacion_asiento' ELSE 'asiento_' || v END;
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- 10) Lecturas (piden dinero.ver)
-- ---------------------------------------------------------------------
CREATE VIEW public.v_cuenta_dinero WITH (security_invoker = true) AS
  SELECT d.empresa_id, d.id AS cuenta_dinero_id, d.tipo, d.nombre, d.sucursal_id, s.nombre AS sucursal,
         d.caja_id, cj.nombre AS caja, d.banco, d.numero_enmascarado, d.tipo_cuenta, d.moneda,
         d.fondo_fijo_centavos, d.activa, c.codigo AS cuenta_codigo,
         coalesce(m.saldo, 0)::bigint AS saldo_centavos, m.ultimo_movimiento_en
  FROM public.cuenta_dinero d
  JOIN public.cuenta c ON c.id = d.cuenta_id
  LEFT JOIN public.sucursal s ON s.id = d.sucursal_id
  LEFT JOIN public.caja cj ON cj.id = d.caja_id
  LEFT JOIN (SELECT x.cuenta_dinero_id, sum(x.monto_centavos) AS saldo, max(x.registrado_en) AS ultimo_movimiento_en
               FROM public.dinero_movimiento x GROUP BY x.cuenta_dinero_id) m ON m.cuenta_dinero_id = d.id;

-- Depósitos sin confirmar: días en tránsito y alerta (más de N días de la empresa).
CREATE VIEW public.v_deposito_transito WITH (security_invoker = true) AS
  SELECT o.empresa_id, o.id AS operacion_id, o.numero, o.fecha_contable, o.monto_centavos,
         o.origen_id, co.nombre AS origen, o.destino_id, cd.nombre AS banco, o.referencia,
         public.hoy_local(o.empresa_id) - o.fecha_contable AS dias_en_transito,
         (public.hoy_local(o.empresa_id) - o.fecha_contable) > e.dias_alerta_transito AS alerta,
         o.creado_por, o.registrado_en
  FROM public.operacion_dinero o
  JOIN public.empresa e ON e.id = o.empresa_id
  JOIN public.cuenta_dinero co ON co.id = o.origen_id
  JOIN public.cuenta_dinero cd ON cd.id = o.destino_id
  WHERE o.tipo = 'deposito' AND o.estado = 'en_transito' AND o.anulada_en IS NULL;

-- "¿Dónde está mi dinero hoy?": saldo de cada cuenta de dinero (activas, y
-- las desactivadas que aún tengan saldo), totales por tipo, depósitos en
-- tránsito con alerta y las cuentas de efectivo 1.1.01 SIN rastro que
-- tengan saldo en los libros (para que nada quede escondido).
CREATE FUNCTION public.donde_esta_mi_dinero(p_empresa_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cuentas jsonb;
  v_tipos   jsonb;
  v_transito jsonb;
  v_otras   jsonb;
  v_total   bigint;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'dinero.ver');
  WITH s AS (
    SELECT d.*, interno.saldo_dinero(d.id) AS saldo, c.codigo AS cuenta_codigo
      FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
     WHERE d.empresa_id = p_empresa_id)
  SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', s.id, 'tipo', s.tipo, 'nombre', s.nombre,
           'banco', s.banco, 'numero_enmascarado', s.numero_enmascarado, 'sucursal_id', s.sucursal_id,
           'cuenta_codigo', s.cuenta_codigo, 'activa', s.activa, 'saldo_centavos', s.saldo,
           'fondo_fijo_centavos', s.fondo_fijo_centavos, 'turno_abierto_id', interno.turno_de_cuenta(s.id))
           ORDER BY s.tipo, s.nombre) FILTER (WHERE s.activa OR s.saldo <> 0), '[]'),
         coalesce(sum(s.saldo), 0)
    INTO v_cuentas, v_total FROM s;
  SELECT coalesce(jsonb_object_agg(t.tipo, t.saldo), '{}') INTO v_tipos
    FROM (SELECT d.tipo, sum(interno.saldo_dinero(d.id))::bigint AS saldo
            FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id GROUP BY d.tipo) t;
  SELECT jsonb_build_object('total_centavos', coalesce(sum(o.monto_centavos), 0),
           'con_alerta', count(*) FILTER (WHERE (public.hoy_local(o.empresa_id) - o.fecha_contable) > e.dias_alerta_transito),
           'depositos', coalesce(jsonb_agg(jsonb_build_object('operacion_id', o.id, 'numero', o.numero,
              'fecha', to_char(o.fecha_contable, 'YYYY-MM-DD'), 'monto_centavos', o.monto_centavos,
              'banco', (SELECT x.nombre FROM public.cuenta_dinero x WHERE x.id = o.destino_id),
              'dias', public.hoy_local(o.empresa_id) - o.fecha_contable,
              'alerta', (public.hoy_local(o.empresa_id) - o.fecha_contable) > e.dias_alerta_transito) ORDER BY o.fecha_contable), '[]'))
    INTO v_transito
    FROM public.operacion_dinero o JOIN public.empresa e ON e.id = o.empresa_id
   WHERE o.empresa_id = p_empresa_id AND o.tipo = 'deposito' AND o.estado = 'en_transito' AND o.anulada_en IS NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_codigo', x.codigo, 'nombre', x.nombre, 'saldo_centavos', x.saldo)
                            ORDER BY x.codigo), '[]')
    INTO v_otras
    FROM (SELECT c.codigo, c.nombre, interno.saldo_libros(p_empresa_id, c.codigo) AS saldo
            FROM public.cuenta c
           WHERE c.empresa_id = p_empresa_id AND c.es_detalle AND c.codigo LIKE '1.1.01.%'
             AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d WHERE d.cuenta_id = c.id)) x
   WHERE x.saldo <> 0;
  RETURN jsonb_build_object('fecha', to_char(public.hoy_local(p_empresa_id), 'YYYY-MM-DD'), 'hora_servidor', public.iso(now()),
    'total_centavos', v_total, 'por_tipo', v_tipos, 'cuentas', v_cuentas, 'en_transito', v_transito,
    'otras_cuentas_efectivo_sin_rastro', v_otras,
    'total_con_otras_centavos', v_total + coalesce((SELECT sum((x->>'saldo_centavos')::bigint) FROM jsonb_array_elements(v_otras) x), 0));
END $$;

-- Estado de cuenta de una cuenta de dinero entre dos fechas (ambas
-- incluidas): saldo inicial, cada movimiento (fecha, operación, de dónde o
-- a dónde, referencia, usuario, equipo, turno) con su saldo, y saldo final.
CREATE FUNCTION public.estado_cuenta_dinero(p_cuenta_dinero_id uuid, p_desde date, p_hasta date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d        public.cuenta_dinero;
  v_inicio bigint;
  v_movs   jsonb;
  v_ent    bigint;
  v_sal    bigint;
BEGIN
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = p_cuenta_dinero_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la cuenta de dinero no existe.';
  END IF;
  PERFORM interno.exigir_lectura(d.empresa_id, 'dinero.ver');
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique "desde" y "hasta" (desde no mayor que hasta).';
  END IF;
  SELECT coalesce(sum(m.monto_centavos), 0) INTO v_inicio FROM public.dinero_movimiento m
   WHERE m.cuenta_dinero_id = d.id AND m.fecha_contable < p_desde;
  SELECT coalesce(jsonb_agg(x.fila ORDER BY x.fecha_contable, x.id), '[]'),
         coalesce(sum(x.monto_centavos) FILTER (WHERE x.monto_centavos > 0), 0),
         coalesce(-sum(x.monto_centavos) FILTER (WHERE x.monto_centavos < 0), 0)
    INTO v_movs, v_ent, v_sal
    FROM (SELECT m.id, m.fecha_contable, m.monto_centavos,
                 jsonb_build_object('fecha', to_char(m.fecha_contable, 'YYYY-MM-DD'), 'registrado_en', public.iso(m.registrado_en),
                   'operacion', m.operacion, 'documento_tipo', m.documento_tipo, 'documento_id', m.documento_id,
                   'asiento_numero', a.numero, 'descripcion', a.descripcion,
                   'entrada_centavos', greatest(m.monto_centavos, 0), 'salida_centavos', greatest(-m.monto_centavos, 0),
                   'origen_o_destino', m.contrapartida, 'referencia', m.referencia, 'equipo', m.equipo, 'turno_id', m.turno_id,
                   'usuario', coalesce(ue.nombre, u.email), 'usuario_id', m.creado_por,
                   'saldo_centavos', v_inicio + sum(m.monto_centavos) OVER (ORDER BY m.fecha_contable, m.id)) AS fila
            FROM public.dinero_movimiento m
            JOIN public.asiento a ON a.id = m.asiento_id
            LEFT JOIN public.usuario_empresa ue ON ue.empresa_id = m.empresa_id AND ue.user_id = m.creado_por
            LEFT JOIN auth.users u ON u.id = m.creado_por
           WHERE m.cuenta_dinero_id = d.id AND m.fecha_contable BETWEEN p_desde AND p_hasta) x;
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'nombre', d.nombre, 'tipo', d.tipo, 'banco', d.banco,
    'numero_enmascarado', d.numero_enmascarado, 'moneda', d.moneda,
    'desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'saldo_inicial_centavos', v_inicio, 'entradas_centavos', v_ent, 'salidas_centavos', v_sal,
    'saldo_final_centavos', v_inicio + v_ent - v_sal, 'movimientos', v_movs);
END $$;

-- ---------------------------------------------------------------------
-- 11) Seguridad
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cuenta_dinero', 'operacion_dinero', 'dinero_movimiento', 'adjunto'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
CREATE POLICY leer ON public.cuenta_dinero FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver'))));
CREATE POLICY leer ON public.operacion_dinero FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver'))));
CREATE POLICY leer ON public.dinero_movimiento FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver'))));
-- Comprobantes: los ve quien ve el dinero, y cada quien los que subió.
CREATE POLICY leer ON public.adjunto FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver')))
         OR (subido_por = (SELECT auth.uid()) AND empresa_id IN (SELECT public.mis_empresas())));
GRANT SELECT ON public.v_cuenta_dinero, public.v_deposito_transito TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  interno.asegurar_cuenta_uso(uuid, text, text),
  interno.proteger_cuenta_dinero(),
  interno.proteger_operacion_dinero(),
  interno.exigir_rastro_dinero(),
  interno.equipo(jsonb),
  interno.json_fecha(jsonb, text),
  interno.sucursal_activa(uuid),
  interno.saldo_dinero(uuid),
  interno.turno_de_cuenta(uuid),
  interno.cuenta_dinero_de(uuid, uuid, boolean),
  interno.contrapartida_linea(uuid, bigint),
  interno.rastrear_dinero(uuid, text, text, uuid, text, text),
  interno.guardar_adjunto(uuid, text, uuid, jsonb),
  interno.empresa_de_documento(text, uuid),
  interno.crear_cuenta_dinero_base(uuid, text, text, uuid, uuid, text, text, text, text, bigint),
  interno.enmascarar_numero(text),
  interno.cuenta_transito(uuid, uuid),
  interno.cuenta_dinero_para_pagar(uuid, uuid),
  interno.operacion_dinero_respuesta(public.operacion_dinero, boolean),
  interno.guardar_operacion_dinero(uuid, text, public.cuenta_dinero, public.cuenta_dinero, public.cuenta_dinero, uuid, bigint,
                                   date, text, text, text, jsonb, text, jsonb, uuid),
  interno.codigo_cuenta_pago(uuid, uuid, text),
  interno.tipo_operacion_2b(uuid, uuid)
FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  public.crear_cuenta_dinero(uuid, jsonb),
  public.editar_cuenta_dinero(uuid, uuid, jsonb, text),
  public.desactivar_cuenta_dinero(uuid, uuid, text),
  public.reactivar_cuenta_dinero(uuid, uuid, text),
  public.trasladar_dinero(uuid, jsonb, uuid),
  public.registrar_saldo_inicial_dinero(uuid, jsonb, uuid),
  public.confirmar_deposito(uuid, uuid, date, text),
  public.anular_operacion_dinero(uuid, text, uuid, date),
  public.agregar_adjunto(uuid, text, uuid, jsonb),
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text, uuid),
  public.donde_esta_mi_dinero(uuid),
  public.estado_cuenta_dinero(uuid, date, date)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_cuenta_dinero(uuid, jsonb),
  public.editar_cuenta_dinero(uuid, uuid, jsonb, text),
  public.desactivar_cuenta_dinero(uuid, uuid, text),
  public.reactivar_cuenta_dinero(uuid, uuid, text),
  public.trasladar_dinero(uuid, jsonb, uuid),
  public.registrar_saldo_inicial_dinero(uuid, jsonb, uuid),
  public.confirmar_deposito(uuid, uuid, date, text),
  public.anular_operacion_dinero(uuid, text, uuid, date),
  public.agregar_adjunto(uuid, text, uuid, jsonb),
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text, uuid)
TO authenticated;
GRANT EXECUTE ON FUNCTION
  public.donde_esta_mi_dinero(uuid),
  public.estado_cuenta_dinero(uuid, date, date)
TO authenticated, service_role;
