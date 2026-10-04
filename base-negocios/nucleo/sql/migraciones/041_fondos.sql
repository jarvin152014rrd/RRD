-- =====================================================================
-- 041_fondos.sql  -  Núcleo 0.10.0 (etapa 3a): fondos, socios y reparto de
-- utilidades (módulo "fondos", necesita "dinero" y por ella "contabilidad").
--
--   socio                 tercero o usuario con su % de participación (activo / no).
--   fondo                 reinversión, emergencias y los que cree el dueño; cada uno
--                         con SU subcuenta de reserva 3.2.02.NN (patrimonio), meta
--                         opcional (monto o N meses de pagos fijos) y, si se quiere,
--                         la cuenta de dinero donde se separa físicamente.
--   regla_distribucion    la regla guardada: % por fondo y socios (suman 100 %).
--   distribucion          una por mes cerrado (anulable con motivo). Base = utilidad
--                         COBRADA del mes (de la foto del cierre; negativa = no se
--                         reparte). Asiento de patrimonio:
--                           Dr 3.3.01.02 Resultado del ejercicio (utilidades del ejercicio)
--                           Cr 3.2.02.NN Reserva de cada fondo
--                           Cr 2.1.01.03 Dividendos por pagar a socios
--                         Separación física opcional: traslado a la cuenta de dinero
--                         de cada fondo (otro asiento, con rastro).
--   fondo_uso             usar un fondo: para qué (motivo), cuánto, de qué cuenta de
--                         dinero sale, a qué cuenta va el gasto o el activo y el
--                         comprobante. Lo aprueba el DUEÑO (si lo pide otro queda
--                         pendiente en "aprobacion"). Asiento:
--                           Dr cuenta destino / Cr cuenta de dinero (rastro)
--                           Dr reserva del fondo / Cr 3.3.01.01 Utilidades acumuladas (libera la reserva)
--   dividendo_pago        pago a un socio desde la cuenta de dinero elegida (anulable).
--   fondo_movimiento      el rastro de cada fondo: aportes, anulaciones y usos
--                         (su suma = la subcuenta de reserva).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('MES_ABIERTO', 'Ese mes todavía está abierto.', 'Cierre primero el mes (cerrar_mes) y después reparta sus utilidades.'),
  ('MES_SIN_CIERRE', 'El mes está cerrado pero no tiene la foto del cierre.', 'Ejecute cerrar_mes para ese mes: guarda la foto sin volver a abrirlo.'),
  ('SIN_UTILIDAD_COBRADA', 'No hay utilidad cobrada para repartir en ese mes.',
   'La utilidad cobrada del mes es cero o negativa: no se reparte. Revise los cobros pendientes o espere al mes siguiente.'),
  ('YA_DISTRIBUIDO', 'Las utilidades de ese mes ya se repartieron.', 'Si hubo un error, anule esa distribución con su motivo y vuelva a repartir.'),
  ('PORCENTAJES_INVALIDOS', 'Los porcentajes de la distribución no son válidos.',
   'Los porcentajes de fondos y socios deben sumar exactamente 100 % y la participación de los socios activos también.'),
  ('SIN_REGLA_DISTRIBUCION', 'No hay una regla de distribución guardada.', 'Guarde la regla (porcentajes por fondo y socios) o envíe los porcentajes al repartir.'),
  ('FONDO_INSUFICIENTE', 'El fondo no tiene saldo suficiente.', 'Use un monto menor o igual al saldo del fondo.'),
  ('DISTRIBUCION_USADA', 'Esa distribución ya se usó (se pagaron dividendos o se gastó parte de un fondo).',
   'Anule primero los pagos de dividendos de ese reparto; lo ya gastado de un fondo no se devuelve: corrija con otra distribución.');

INSERT INTO public.modulo (codigo, nombre) VALUES ('fondos', 'Fondos y reparto de utilidades');
INSERT INTO public.modulo_dependencia (modulo, requiere, motivo) VALUES
  ('fondos', 'dinero', 'El fondo se separa y se usa desde cuentas de dinero (y dinero necesita contabilidad).');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('fondos.ver',               'Ver fondos, socios, repartos de utilidades y dividendos', false, true),
  ('fondos.configurar',        'Crear y editar fondos, socios y la regla de distribución', false, false),
  ('fondos.distribuir',        'Repartir las utilidades de un mes cerrado y anular un reparto', true, false),
  ('fondos.usar',              'Usar el dinero de un fondo (lo aprueba el dueño)', true, false),
  ('fondos.aprobar',           'Aprobar el uso de un fondo', true, false),
  ('fondos.pagar_dividendos',  'Pagar dividendos a los socios y anular esos pagos', true, false);
-- Criterio (REQUISITOS): reglas de distribución y fondos = solo el dueño; el admin y el
-- contador ven. Usar y pagar: el dueño (puede dar "usar" a otro puesto; igual lo aprueba él).
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'fondos.ver'), ('dueno', 'fondos.configurar'), ('dueno', 'fondos.distribuir'), ('dueno', 'fondos.usar'),
  ('dueno', 'fondos.aprobar'), ('dueno', 'fondos.pagar_dividendos'),
  ('admin', 'fondos.ver'), ('contador', 'fondos.ver');
SELECT interno.repartir_permisos(ARRAY['fondos.ver', 'fondos.configurar', 'fondos.distribuir', 'fondos.usar', 'fondos.aprobar',
  'fondos.pagar_dividendos'], 'Núcleo 0.10.0: fondos y reparto de utilidades');

-- Permisos que solo puede tener el dueño (reemplaza la de 017; misma regla + fondos).
CREATE OR REPLACE FUNCTION interno.validar_rol_permiso() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_p public.permiso;
BEGIN
  IF NEW.rol = 'proveedor' THEN
    RAISE EXCEPTION 'PROHIBIDO: el rol proveedor no recibe permisos ("%"). Para soporte, el dueño da un acceso temporal.', NEW.permiso;
  END IF;
  IF NEW.permiso IN ('soporte.otorgar', 'permisos.editar', 'periodos.reabrir', 'empresa.configurar',
                     'fondos.configurar', 'fondos.distribuir', 'fondos.aprobar')
     AND NEW.rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: el permiso "%" es solo del dueño.', NEW.permiso;
  END IF;
  IF NEW.rol = 'contador' THEN
    SELECT * INTO v_p FROM public.permiso WHERE codigo = NEW.permiso;
    IF v_p.es_movimiento OR NOT (v_p.es_financiero OR v_p.codigo LIKE '%.ver') THEN
      RAISE EXCEPTION 'PROHIBIDO: el contador es de solo lectura; no recibe el permiso "%".', NEW.permiso;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 1) Cuentas
-- ---------------------------------------------------------------------
INSERT INTO interno.plantilla_cuenta (codigo, nombre, tipo, naturaleza, es_detalle) VALUES
  ('2.1.01.03', 'Dividendos por pagar a socios', 'pasivo', 'acreedora', true);
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('dividendos_por_pagar',  '2.1.01.03', 'Dividendos repartidos a socios y todavía no pagados', 'fondos'),
  ('utilidades_ejercicio',  '3.3.01.02', 'Resultado del ejercicio: de aquí salen las utilidades que se reparten', NULL),
  ('utilidades_acumuladas', '3.3.01.01', 'Utilidades acumuladas: vuelve aquí la reserva de un fondo que se usa', NULL);
DO $$
DECLARE e record;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.10.0: cuentas de fondos y dividendos', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    PERFORM interno.asegurar_cuenta_uso(e.id, 'dividendos_por_pagar', 'Dividendos por pagar a socios');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'utilidades_ejercicio', 'Resultado del ejercicio');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'utilidades_acumuladas', 'Utilidades (pérdidas) acumuladas');
  END LOOP;
  PERFORM set_config('app.motivo', '', true);
END $$;

-- ---------------------------------------------------------------------
-- 2) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.socio (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  nombre          text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 150),
  tercero_id      uuid,
  user_id         uuid,
  porcentaje      numeric(5,2) NOT NULL CHECK (porcentaje > 0 AND porcentaje <= 100),   -- participación
  activo          boolean NOT NULL DEFAULT true,
  creado_por      uuid,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, tercero_id) REFERENCES public.tercero(empresa_id, id),
  CHECK ((tercero_id IS NULL) <> (user_id IS NULL))
);
CREATE UNIQUE INDEX socio_tercero ON public.socio (empresa_id, tercero_id) WHERE tercero_id IS NOT NULL;
CREATE UNIQUE INDEX socio_usuario ON public.socio (empresa_id, user_id) WHERE user_id IS NOT NULL;

CREATE TABLE public.fondo (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id           uuid NOT NULL REFERENCES public.empresa(id),
  nombre               text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 100),
  tipo                 text NOT NULL CHECK (tipo IN ('reinversion', 'emergencias', 'otro')),
  meta_tipo            text NOT NULL DEFAULT 'ninguna' CHECK (meta_tipo IN ('ninguna', 'monto', 'meses_pagos_fijos')),
  meta_monto_centavos  bigint CHECK (meta_monto_centavos BETWEEN 1 AND 9007199254740991),
  meta_meses           numeric(5,2) CHECK (meta_meses > 0 AND meta_meses <= 120),
  cuenta_id            uuid NOT NULL UNIQUE,          -- su subcuenta de reserva (3.2.02.NN)
  cuenta_dinero_id     uuid,                          -- dónde se separa el dinero (opcional)
  notas                text,
  activo               boolean NOT NULL DEFAULT true,
  creado_por           uuid,
  creado_en            timestamptz NOT NULL DEFAULT now(),
  actualizado_en       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_id)        REFERENCES public.cuenta(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id) REFERENCES public.cuenta_dinero(empresa_id, id),
  CHECK ((meta_tipo = 'monto') = (meta_monto_centavos IS NOT NULL)),
  CHECK ((meta_tipo = 'meses_pagos_fijos') = (meta_meses IS NOT NULL))
);
CREATE UNIQUE INDEX fondo_nombre ON public.fondo (empresa_id, lower(nombre));

CREATE TABLE public.regla_distribucion (
  empresa_id      uuid PRIMARY KEY REFERENCES public.empresa(id),
  regla           jsonb NOT NULL CHECK (jsonb_typeof(regla) = 'object'),
  motivo          text NOT NULL,
  actualizado_por uuid,
  actualizado_en  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.distribucion (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                  uuid NOT NULL REFERENCES public.empresa(id),
  numero                      bigint NOT NULL,
  anio                        integer NOT NULL,
  mes                         integer NOT NULL CHECK (mes BETWEEN 1 AND 12),
  cierre_id                   uuid NOT NULL,             -- la foto de donde salió la base
  utilidad_facturada_centavos bigint NOT NULL,
  base_centavos               bigint NOT NULL CHECK (base_centavos BETWEEN 1 AND 9007199254740991),   -- utilidad cobrada
  fecha_contable              date NOT NULL,
  motivo                      text NOT NULL,
  separar_desde_id            uuid,                      -- cuenta de dinero de donde se separó (si se separó)
  equipo                      text,
  asiento_id                  uuid NOT NULL,
  asiento_separacion_id       uuid,
  id_operacion                uuid NOT NULL,
  creado_por                  uuid,
  registrado_en               timestamptz NOT NULL DEFAULT now(),
  anulada_en                  timestamptz,
  anulada_por                 uuid,
  motivo_anulacion            text,
  fecha_anulacion             date,
  asiento_anulacion_id        uuid,
  asiento_anulacion_separacion_id uuid,
  anulacion_id_operacion      uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, cierre_id)             REFERENCES public.cierre(empresa_id, id),
  FOREIGN KEY (empresa_id, separar_desde_id)      REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)            REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_separacion_id) REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id)  REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_separacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL)),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL))
);
CREATE UNIQUE INDEX distribucion_mes ON public.distribucion (empresa_id, anio, mes) WHERE anulada_en IS NULL;

CREATE TABLE public.distribucion_detalle (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  distribucion_id  uuid NOT NULL REFERENCES public.distribucion(id),
  empresa_id       uuid NOT NULL,
  fondo_id         uuid,
  socio_id         uuid,
  porcentaje       numeric(9,4) NOT NULL CHECK (porcentaje > 0 AND porcentaje <= 100),
  monto_centavos   bigint NOT NULL CHECK (monto_centavos >= 0),
  FOREIGN KEY (empresa_id, fondo_id) REFERENCES public.fondo(empresa_id, id),
  FOREIGN KEY (empresa_id, socio_id) REFERENCES public.socio(empresa_id, id),
  CHECK ((fondo_id IS NULL) <> (socio_id IS NULL))
);
CREATE INDEX distribucion_detalle_dist ON public.distribucion_detalle (distribucion_id);
CREATE INDEX distribucion_detalle_socio ON public.distribucion_detalle (socio_id) WHERE socio_id IS NOT NULL;

CREATE TABLE public.fondo_uso (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id         uuid NOT NULL REFERENCES public.empresa(id),
  numero             bigint NOT NULL,
  fondo_id           uuid NOT NULL,
  monto_centavos     bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  motivo             text NOT NULL CHECK (length(trim(motivo)) >= 5),     -- para qué
  cuenta_dinero_id   uuid NOT NULL,                                       -- de dónde sale el dinero
  cuenta_destino_id  uuid NOT NULL,                                       -- a qué gasto, costo o activo va
  fecha_contable     date NOT NULL,
  referencia         text,
  equipo             text,
  estado             text NOT NULL CHECK (estado IN ('pendiente_aprobacion', 'aplicado', 'rechazado')),
  aprobacion_id      uuid,
  asiento_id         uuid,
  id_operacion       uuid NOT NULL,
  solicitado_por     uuid,
  registrado_en      timestamptz NOT NULL DEFAULT now(),
  aplicado_en        timestamptz,
  aplicado_por       uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, fondo_id)          REFERENCES public.fondo(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id)  REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_destino_id) REFERENCES public.cuenta(empresa_id, id),
  FOREIGN KEY (empresa_id, aprobacion_id)     REFERENCES public.aprobacion(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)        REFERENCES public.asiento(empresa_id, id),
  CHECK ((estado = 'aplicado') = (asiento_id IS NOT NULL))
);

CREATE TABLE public.dividendo_pago (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  socio_id                 uuid NOT NULL,
  monto_centavos           bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  cuenta_dinero_id         uuid NOT NULL,
  fecha_contable           date NOT NULL,
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
  FOREIGN KEY (empresa_id, socio_id)             REFERENCES public.socio(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id)     REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL)),
  CHECK ((anulada_en IS NULL) = (motivo_anulacion IS NULL))
);

CREATE TABLE public.fondo_movimiento (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  fondo_id        uuid NOT NULL,
  tipo            text NOT NULL CHECK (tipo IN ('aporte', 'anulacion_aporte', 'uso')),
  monto_centavos  bigint NOT NULL CHECK (monto_centavos <> 0),        -- + entra a la reserva, - sale
  fecha_contable  date NOT NULL,
  documento_tipo  text NOT NULL,                                      -- distribucion, fondo_uso
  documento_id    uuid NOT NULL,
  asiento_id      uuid NOT NULL,
  descripcion     text,
  creado_por      uuid,
  registrado_en   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, fondo_id)   REFERENCES public.fondo(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id) REFERENCES public.asiento(empresa_id, id)
);
CREATE INDEX fondo_movimiento_fondo ON public.fondo_movimiento (fondo_id, fecha_contable, id);

-- Defensas: nada se edita salvo lo que se llena una vez.
CREATE FUNCTION interno.proteger_fondo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.tipo, NEW.cuenta_id, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.tipo, OLD.cuenta_id, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: de un fondo no se cambia el tipo ni su cuenta de reserva.';
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.fondo FOR EACH ROW EXECUTE FUNCTION interno.proteger_fondo();

CREATE FUNCTION interno.proteger_socio() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.tercero_id, NEW.user_id, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.tercero_id, OLD.user_id, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: de un socio solo se cambia el nombre, el porcentaje o si está activo.';
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.socio FOR EACH ROW EXECUTE FUNCTION interno.proteger_socio();

CREATE FUNCTION interno.proteger_distribucion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c constant text[] := ARRAY['anulada_en', 'anulada_por', 'motivo_anulacion', 'fecha_anulacion', 'asiento_anulacion_id',
                                   'asiento_anulacion_separacion_id', 'anulacion_id_operacion'];
BEGIN
  IF OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL AND (to_jsonb(NEW) - c) = (to_jsonb(OLD) - c) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una distribución de utilidades no se edita; se anula una vez con su motivo.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.distribucion FOR EACH ROW EXECUTE FUNCTION interno.proteger_distribucion();

CREATE FUNCTION interno.proteger_fondo_uso() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c constant text[] := ARRAY['estado', 'asiento_id', 'aplicado_en', 'aplicado_por', 'fecha_contable'];
BEGIN
  IF OLD.estado = 'pendiente_aprobacion' AND NEW.estado IN ('aplicado', 'rechazado') AND (to_jsonb(NEW) - c) = (to_jsonb(OLD) - c) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: el uso de un fondo no se edita; uno pendiente se aprueba o se rechaza una vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.fondo_uso FOR EACH ROW EXECUTE FUNCTION interno.proteger_fondo_uso();
CREATE TRIGGER proteger BEFORE UPDATE ON public.dividendo_pago FOR EACH ROW EXECUTE FUNCTION interno.proteger_anulable();
CREATE TRIGGER inmutable BEFORE UPDATE ON public.distribucion_detalle
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El detalle de una distribución no se edita.');
CREATE TRIGGER inmutable BEFORE UPDATE ON public.fondo_movimiento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los movimientos de un fondo son de solo agregar.');
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['socio', 'fondo', 'regla_distribucion', 'distribucion', 'distribucion_detalle', 'fondo_uso',
                           'dividendo_pago', 'fondo_movimiento'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'Los fondos, socios y repartos no se borran (se desactivan o se anulan).');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', t, 'fondos.ver');
  END LOOP;
END $$;

-- La subcuenta de reserva de un fondo no acepta asientos manuales (aunque el módulo esté apagado).
CREATE FUNCTION interno.revisar_cuenta_fondo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_origen text;
  v_fondo  text;
BEGIN
  SELECT f.nombre INTO v_fondo FROM public.fondo f WHERE f.cuenta_id = NEW.cuenta_id;
  IF v_fondo IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT a.origen INTO v_origen FROM public.asiento a WHERE a.id = NEW.asiento_id;
  IF v_origen = 'manual' THEN
    RAISE EXCEPTION 'CUENTA_CONTROLADA: la cuenta es la reserva del fondo "%"; se mueve repartiendo utilidades o usando el fondo, no con un asiento manual.', v_fondo;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cuenta_fondo BEFORE INSERT ON public.asiento_linea FOR EACH ROW EXECUTE FUNCTION interno.revisar_cuenta_fondo();

-- ---------------------------------------------------------------------
-- 3) Ayudantes
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.saldo_fondo(p_fondo_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(m.monto_centavos), 0)::bigint FROM public.fondo_movimiento m WHERE m.fondo_id = p_fondo_id
$$;

-- Dividendos pendientes de un socio (repartos vigentes - pagos vigentes).
CREATE FUNCTION interno.dividendos_pendientes(p_socio_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ( coalesce((SELECT sum(d.monto_centavos) FROM public.distribucion_detalle d JOIN public.distribucion x ON x.id = d.distribucion_id
                      WHERE d.socio_id = p_socio_id AND x.anulada_en IS NULL), 0)
         - coalesce((SELECT sum(p.monto_centavos) FROM public.dividendo_pago p WHERE p.socio_id = p_socio_id AND p.anulada_en IS NULL), 0)
         )::bigint
$$;

-- Total por pagar a socios (debe = saldo de 2.1.01.03).
CREATE FUNCTION interno.total_dividendos_por_pagar(p_empresa_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ( coalesce((SELECT sum(d.monto_centavos) FROM public.distribucion_detalle d JOIN public.distribucion x ON x.id = d.distribucion_id
                      WHERE x.empresa_id = p_empresa_id AND d.socio_id IS NOT NULL AND x.anulada_en IS NULL), 0)
         - coalesce((SELECT sum(p.monto_centavos) FROM public.dividendo_pago p WHERE p.empresa_id = p_empresa_id AND p.anulada_en IS NULL), 0)
         )::bigint
$$;

-- Meta de un fondo en centavos (monto, o N meses del total mensual estimado de pagos fijos activos).
CREATE FUNCTION interno.meta_fondo(f public.fondo) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE f.meta_tipo
    WHEN 'monto' THEN f.meta_monto_centavos
    WHEN 'meses_pagos_fijos' THEN round(f.meta_meses * coalesce((SELECT sum(interno.mensual_pago_fijo(p)) FROM public.pago_fijo p
                                                                  WHERE p.empresa_id = f.empresa_id AND p.activo), 0))::bigint
  END
$$;

-- Madre de las reservas por fondo: 3.2.02 "Reservas de fondos" (o el siguiente libre bajo 3.2).
CREATE FUNCTION interno.madre_reservas(p_empresa_id uuid) RETURNS public.cuenta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_m  public.cuenta;
  v_r  public.cuenta;
  n    integer := 2;
  v_c  text := '3.2.02';
BEGIN
  SELECT c.* INTO v_m FROM public.cuenta c JOIN public.fondo f ON f.empresa_id = c.empresa_id
   JOIN public.cuenta h ON h.id = f.cuenta_id AND h.padre_id = c.id
   WHERE c.empresa_id = p_empresa_id LIMIT 1;
  IF v_m.id IS NOT NULL THEN
    RETURN v_m;
  END IF;
  SELECT * INTO v_m FROM public.cuenta c
   WHERE c.empresa_id = p_empresa_id AND c.codigo ~ '^3\.2\.[0-9]+$' AND NOT c.es_detalle AND c.nombre = 'Reservas de fondos';
  IF v_m.id IS NOT NULL THEN
    RETURN v_m;
  END IF;
  SELECT * INTO v_r FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.codigo = '3.2';
  IF v_r.id IS NULL OR v_r.es_detalle THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: falta la cuenta 3.2 (Reservas) en el catálogo. Avise a soporte.';
  END IF;
  WHILE EXISTS (SELECT 1 FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.codigo = v_c) LOOP
    n := n + 1;
    v_c := '3.2.' || lpad(n::text, 2, '0');
  END LOOP;
  INSERT INTO public.cuenta (empresa_id, codigo, nombre, tipo, naturaleza, padre_id, es_detalle)
  VALUES (p_empresa_id, v_c, 'Reservas de fondos', 'patrimonio', 'acreedora', v_r.id, false)
  RETURNING * INTO v_m;
  RETURN v_m;
END $$;

-- Porcentaje desde jsonb (más de 0 y hasta 100, 2 decimales).
CREATE FUNCTION interno.json_porcentaje(p_valor jsonb, p_campo text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v numeric;
BEGIN
  IF p_valor IS NULL OR jsonb_typeof(p_valor) <> 'number' THEN
    RAISE EXCEPTION 'PORCENTAJES_INVALIDOS: "%" debe ser un número (porcentaje).', p_campo;
  END IF;
  v := (p_valor #>> '{}')::numeric;
  IF v <= 0 OR v > 100 OR v <> round(v, 2) THEN
    RAISE EXCEPTION 'PORCENTAJES_INVALIDOS: "%" va de más de 0 a 100 (hasta 2 decimales).', p_campo;
  END IF;
  RETURN v;
END $$;

-- Regla -> lista de partes [{"tipo":"fondo"|"socio","id","nombre","porcentaje"}] que suman 100 %.
-- regla = {"fondos":[{"fondo_id","porcentaje"}], "socios":[{"socio_id","porcentaje"}]}
--      o  {"fondos":[...], "socios_porcentaje": 30}   (el 30 % se reparte según la participación de cada socio activo)
CREATE FUNCTION interno.partes_regla(p_empresa_id uuid, p_regla jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_p   jsonb := '[]';
  x     jsonb;
  f     public.fondo;
  s     public.socio;
  v_pct numeric;
  v_sp  numeric;
  v_tot numeric;
BEGIN
  PERFORM interno.exigir_claves(p_regla, ARRAY['fondos', 'socios', 'socios_porcentaje']);
  IF p_regla ? 'socios' AND p_regla ? 'socios_porcentaje' THEN
    RAISE EXCEPTION 'PORCENTAJES_INVALIDOS: indique "socios" (cada uno con su %%) o "socios_porcentaje" (según la participación), no los dos.';
  END IF;
  IF p_regla ? 'fondos' AND jsonb_typeof(p_regla->'fondos') <> 'array' OR p_regla ? 'socios' AND jsonb_typeof(p_regla->'socios') <> 'array' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "fondos" y "socios" son listas.';
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_regla->'fondos', '[]')) LOOP
    PERFORM interno.exigir_claves(x, ARRAY['fondo_id', 'porcentaje']);
    SELECT * INTO f FROM public.fondo y WHERE y.id = interno.json_uuid(x->'fondo_id', 'fondo_id') AND y.empresa_id = p_empresa_id;
    IF f.id IS NULL OR NOT f.activo THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el fondo no existe en esta empresa o está desactivado.';
    END IF;
    IF v_p @> jsonb_build_array(jsonb_build_object('id', f.id)) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el fondo "%" está dos veces.', f.nombre;
    END IF;
    v_p := v_p || jsonb_build_object('tipo', 'fondo', 'id', f.id, 'nombre', f.nombre, 'porcentaje', interno.json_porcentaje(x->'porcentaje', 'porcentaje'));
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_regla->'socios', '[]')) LOOP
    PERFORM interno.exigir_claves(x, ARRAY['socio_id', 'porcentaje']);
    SELECT * INTO s FROM public.socio y WHERE y.id = interno.json_uuid(x->'socio_id', 'socio_id') AND y.empresa_id = p_empresa_id;
    IF s.id IS NULL OR NOT s.activo THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el socio no existe en esta empresa o está desactivado.';
    END IF;
    IF v_p @> jsonb_build_array(jsonb_build_object('id', s.id)) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el socio "%" está dos veces.', s.nombre;
    END IF;
    v_p := v_p || jsonb_build_object('tipo', 'socio', 'id', s.id, 'nombre', s.nombre, 'porcentaje', interno.json_porcentaje(x->'porcentaje', 'porcentaje'));
  END LOOP;
  IF p_regla ? 'socios_porcentaje' THEN
    v_sp := interno.json_porcentaje(p_regla->'socios_porcentaje', 'socios_porcentaje');
    SELECT coalesce(sum(y.porcentaje), 0) INTO v_tot FROM public.socio y WHERE y.empresa_id = p_empresa_id AND y.activo;
    IF v_tot <> 100 THEN
      RAISE EXCEPTION 'PORCENTAJES_INVALIDOS: la participación de los socios activos suma % %%; debe sumar 100 %%.', v_tot;
    END IF;
    FOR s IN SELECT * FROM public.socio y WHERE y.empresa_id = p_empresa_id AND y.activo ORDER BY y.nombre, y.id LOOP
      v_p := v_p || jsonb_build_object('tipo', 'socio', 'id', s.id, 'nombre', s.nombre, 'porcentaje', v_sp * s.porcentaje / 100);
    END LOOP;
  END IF;
  SELECT coalesce(sum((y->>'porcentaje')::numeric), 0) INTO v_pct FROM jsonb_array_elements(v_p) y;
  IF v_pct <> 100 THEN
    RAISE EXCEPTION 'PORCENTAJES_INVALIDOS: los porcentajes de fondos y socios suman % %%; deben sumar 100 %%.', v_pct;
  END IF;
  RETURN v_p;
END $$;

-- Reparte la base entre las partes (resto mayor: la suma da la base exacta).
CREATE FUNCTION interno.repartir_base(p_base bigint, p_partes jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH it AS (SELECT x AS parte, n, (x->>'porcentaje')::numeric AS pct FROM jsonb_array_elements(p_partes) WITH ORDINALITY AS t(x, n)),
  b AS (SELECT it.*, floor(p_base * pct / 100)::bigint AS piso, p_base * pct / 100 - floor(p_base * pct / 100) AS resto FROM it),
  r AS (SELECT b.*, row_number() OVER (ORDER BY resto DESC, n) AS rn, p_base - sum(piso) OVER () AS falta FROM b)
  SELECT coalesce(jsonb_agg(parte || jsonb_build_object('monto_centavos', piso + CASE WHEN rn <= falta THEN 1 ELSE 0 END) ORDER BY n), '[]')
    FROM r
$$;

-- Asiento y rastro de un uso de fondo ya aprobado.
CREATE FUNCTION interno.aplicar_uso_fondo(u public.fondo_uso, p_fecha date, p_id_operacion uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f      public.fondo;
  d      public.cuenta_dinero;
  v_asto uuid;
BEGIN
  SELECT * INTO f FROM public.fondo WHERE id = u.fondo_id;
  IF interno.saldo_fondo(f.id) < u.monto_centavos THEN
    RAISE EXCEPTION 'FONDO_INSUFICIENTE: el fondo "%" tiene % y el uso es de %.', f.nombre,
      interno.lempiras(interno.saldo_fondo(f.id)), interno.lempiras(u.monto_centavos);
  END IF;
  d := interno.cuenta_dinero_para_pagar(u.empresa_id, u.cuenta_dinero_id);
  PERFORM interno.exigir_periodo_abierto(u.empresa_id, p_fecha);
  v_asto := interno.asiento_sistema(u.empresa_id, interno.sucursal_activa(d.sucursal_id), p_fecha,
    'Uso del fondo "' || f.nombre || '" #' || u.numero || ': ' || u.motivo, 'uso_fondo', p_id_operacion,
    jsonb_build_array(
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = u.cuenta_destino_id), 'debe', u.monto_centavos,
                         'descripcion', u.motivo),
      jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'haber', u.monto_centavos, 'descripcion', 'Sale el dinero del fondo'),
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = f.cuenta_id), 'debe', u.monto_centavos,
                         'descripcion', 'Se libera la reserva del fondo'),
      jsonb_build_object('uso', 'utilidades_acumuladas', 'haber', u.monto_centavos, 'descripcion', 'La reserva usada vuelve a utilidades acumuladas')));
  INSERT INTO public.fondo_movimiento (empresa_id, fondo_id, tipo, monto_centavos, fecha_contable, documento_tipo, documento_id, asiento_id,
                                       descripcion, creado_por)
  VALUES (u.empresa_id, f.id, 'uso', -u.monto_centavos, p_fecha, 'fondo_uso', u.id, v_asto, u.motivo, auth.uid());
  PERFORM interno.rastrear_dinero(v_asto, 'uso_fondo', 'fondo_uso', u.id, coalesce(u.referencia, 'Uso de fondo #' || u.numero), u.equipo);
  RETURN v_asto;
END $$;

CREATE FUNCTION interno.fondo_uso_respuesta(u public.fondo_uso, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('fondo_uso_id', u.id, 'numero', u.numero, 'fondo_id', u.fondo_id, 'monto_centavos', u.monto_centavos,
    'estado', u.estado, 'aprobacion_id', u.aprobacion_id, 'asiento_id', u.asiento_id,
    'saldo_fondo_centavos', interno.saldo_fondo(u.fondo_id), 'duplicado', p_duplicado)
$$;

-- ---------------------------------------------------------------------
-- 4) RPC: socios, fondos y regla (solo el dueño: fondos.configurar)
-- ---------------------------------------------------------------------
-- guardar_socio(empresa, {"socio_id"? , "tercero_id" | "user_id", "nombre"?, "porcentaje", "activo"?}, motivo)
CREATE FUNCTION public.guardar_socio(p_empresa_id uuid, p_datos jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s      public.socio;
  v_ter  uuid;
  v_usr  uuid;
  v_nom  text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'fondos.configurar', 'fondos');
  PERFORM interno.exigir_claves(p_datos, ARRAY['socio_id', 'tercero_id', 'user_id', 'nombre', 'porcentaje', 'activo']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  IF p_datos ? 'socio_id' THEN
    SELECT * INTO s FROM public.socio x WHERE x.id = interno.json_uuid(p_datos->'socio_id', 'socio_id') AND x.empresa_id = p_empresa_id FOR UPDATE;
    IF s.id IS NULL THEN
      RAISE EXCEPTION 'NO_EXISTE: el socio no existe en esta empresa.';
    END IF;
    IF p_datos ? 'tercero_id' OR p_datos ? 'user_id' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: de un socio no se cambia la persona; desactívelo y cree otro.';
    END IF;
    UPDATE public.socio SET
      nombre = coalesce(interno.json_texto(p_datos->'nombre', 'nombre', 150), nombre),
      porcentaje = CASE WHEN p_datos ? 'porcentaje' THEN interno.json_porcentaje(p_datos->'porcentaje', 'porcentaje') ELSE porcentaje END,
      activo = CASE WHEN p_datos ? 'activo' THEN interno.json_si_no(p_datos->'activo', 'activo') ELSE activo END
     WHERE id = s.id RETURNING * INTO s;
  ELSE
    v_ter := interno.json_uuid(p_datos->'tercero_id', 'tercero_id');
    v_usr := interno.json_uuid(p_datos->'user_id', 'user_id');
    IF (v_ter IS NULL) = (v_usr IS NULL) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el socio es un tercero ("tercero_id") o un usuario del negocio ("user_id"), uno de los dos.';
    END IF;
    IF v_ter IS NOT NULL THEN
      SELECT t.nombre INTO v_nom FROM public.tercero t WHERE t.id = v_ter AND t.empresa_id = p_empresa_id;
      IF v_nom IS NULL THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el tercero no existe en esta empresa.';
      END IF;
    ELSE
      IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = v_usr
                       AND ue.rol NOT IN ('proveedor')) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el usuario no es de esta empresa.';
      END IF;
      v_nom := public.nombre_usuario(p_empresa_id, v_usr);
    END IF;
    IF EXISTS (SELECT 1 FROM public.socio x WHERE x.empresa_id = p_empresa_id AND (x.tercero_id = v_ter OR x.user_id = v_usr)) THEN
      RAISE EXCEPTION 'YA_EXISTE: esa persona ya es socio; edítelo con su "socio_id".';
    END IF;
    INSERT INTO public.socio (empresa_id, nombre, tercero_id, user_id, porcentaje, activo, creado_por)
    VALUES (p_empresa_id, coalesce(interno.json_texto(p_datos->'nombre', 'nombre', 150), v_nom, 'Socio'), v_ter, v_usr,
            interno.json_porcentaje(p_datos->'porcentaje', 'porcentaje'),
            CASE WHEN p_datos ? 'activo' THEN interno.json_si_no(p_datos->'activo', 'activo') ELSE true END, auth.uid())
    RETURNING * INTO s;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('socio_id', s.id, 'nombre', s.nombre, 'porcentaje', s.porcentaje, 'activo', s.activo,
    'participacion_activos_porcentaje', (SELECT coalesce(sum(x.porcentaje), 0) FROM public.socio x WHERE x.empresa_id = p_empresa_id AND x.activo));
END $$;

-- Datos de la meta y de la cuenta de dinero de un fondo (crear y editar).
CREATE FUNCTION interno.aplicar_datos_fondo(f public.fondo, p_datos jsonb) RETURNS public.fondo
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_datos ? 'nombre' THEN
    f.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 100);
    IF f.nombre IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre del fondo (ej. "Emergencias").';
    END IF;
  END IF;
  IF p_datos ? 'meta_tipo' THEN
    f.meta_tipo := coalesce(interno.json_texto(p_datos->'meta_tipo', 'meta_tipo', 20), 'ninguna');
    IF f.meta_tipo NOT IN ('ninguna', 'monto', 'meses_pagos_fijos') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la meta es "ninguna", "monto" (meta_monto_centavos) o "meses_pagos_fijos" (meta_meses).';
    END IF;
    f.meta_monto_centavos := NULL;
    f.meta_meses := NULL;
  END IF;
  IF f.meta_tipo = 'monto' THEN
    f.meta_monto_centavos := coalesce(CASE WHEN p_datos ? 'meta_monto_centavos'
                                           THEN interno.json_centavos(p_datos->'meta_monto_centavos', 'meta_monto_centavos') END, f.meta_monto_centavos);
    IF coalesce(f.meta_monto_centavos, 0) = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la meta en monto necesita "meta_monto_centavos" mayor que cero.';
    END IF;
  ELSIF f.meta_tipo = 'meses_pagos_fijos' THEN
    IF p_datos ? 'meta_meses' THEN
      IF jsonb_typeof(p_datos->'meta_meses') <> 'number' OR (p_datos->>'meta_meses')::numeric NOT BETWEEN 0.01 AND 120 THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "meta_meses" va de 0.01 a 120 meses.';
      END IF;
      f.meta_meses := round((p_datos->>'meta_meses')::numeric, 2);
    END IF;
    IF f.meta_meses IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la meta en meses de pagos fijos necesita "meta_meses" (ej. 3).';
    END IF;
  ELSIF p_datos ? 'meta_monto_centavos' OR p_datos ? 'meta_meses' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique "meta_tipo" junto con la meta.';
  END IF;
  IF p_datos ? 'cuenta_dinero_id' THEN
    f.cuenta_dinero_id := interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id');
    IF f.cuenta_dinero_id IS NOT NULL THEN
      f.cuenta_dinero_id := (interno.cuenta_dinero_para_pagar(f.empresa_id, f.cuenta_dinero_id)).id;
    END IF;
  END IF;
  IF p_datos ? 'notas' THEN
    f.notas := interno.json_texto(p_datos->'notas', 'notas', 500);
  END IF;
  IF p_datos ? 'activo' THEN
    f.activo := interno.json_si_no(p_datos->'activo', 'activo');
  END IF;
  RETURN f;
END $$;

-- crear_fondo(empresa, {"nombre","tipo":"reinversion"|"emergencias"|"otro","meta_tipo"?,"meta_monto_centavos"?,"meta_meses"?,
--                       "cuenta_dinero_id"?,"notas"?}, motivo)
CREATE FUNCTION public.crear_fondo(p_empresa_id uuid, p_datos jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f      public.fondo;
  v_m    public.cuenta;
  v_n    integer;
  v_cod  text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'fondos.configurar', 'fondos');
  PERFORM interno.exigir_claves(p_datos, ARRAY['nombre', 'tipo', 'meta_tipo', 'meta_monto_centavos', 'meta_meses', 'cuenta_dinero_id', 'notas']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo (mínimo 5 letras).';
  END IF;
  f.empresa_id := p_empresa_id;
  f.tipo := coalesce(interno.json_texto(p_datos->'tipo', 'tipo', 20), 'otro');
  IF f.tipo NOT IN ('reinversion', 'emergencias', 'otro') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de fondo es reinversion, emergencias u otro.';
  END IF;
  f.meta_tipo := 'ninguna';
  f.activo := true;
  f := interno.aplicar_datos_fondo(f, p_datos || CASE WHEN p_datos ? 'nombre' THEN '{}'::jsonb ELSE '{"nombre": null}'::jsonb END);
  PERFORM interno.bloquear_libros(p_empresa_id);
  IF EXISTS (SELECT 1 FROM public.fondo x WHERE x.empresa_id = p_empresa_id AND lower(x.nombre) = lower(f.nombre)) THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay un fondo llamado "%".', f.nombre;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  v_m := interno.madre_reservas(p_empresa_id);
  SELECT coalesce(max(split_part(c.codigo, '.', 4)::integer), 0) + 1 INTO v_n
    FROM public.cuenta c WHERE c.empresa_id = p_empresa_id AND c.padre_id = v_m.id AND split_part(c.codigo, '.', 4) ~ '^[0-9]+$';
  v_cod := v_m.codigo || '.' || lpad(v_n::text, 2, '0');
  INSERT INTO public.cuenta (empresa_id, codigo, nombre, tipo, naturaleza, padre_id, es_detalle)
  VALUES (p_empresa_id, v_cod, 'Reserva ' || f.nombre, 'patrimonio', 'acreedora', v_m.id, true)
  RETURNING id INTO f.cuenta_id;
  INSERT INTO public.fondo (empresa_id, nombre, tipo, meta_tipo, meta_monto_centavos, meta_meses, cuenta_id, cuenta_dinero_id, notas, activo, creado_por)
  VALUES (p_empresa_id, f.nombre, f.tipo, f.meta_tipo, f.meta_monto_centavos, f.meta_meses, f.cuenta_id, f.cuenta_dinero_id, f.notas, true, auth.uid())
  RETURNING * INTO f;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('fondo_id', f.id, 'nombre', f.nombre, 'tipo', f.tipo, 'cuenta_codigo', v_cod,
    'meta_centavos', interno.meta_fondo(f), 'cuenta_dinero_id', f.cuenta_dinero_id);
END $$;

-- editar_fondo(empresa, fondo, {"nombre","meta_tipo","meta_monto_centavos","meta_meses","cuenta_dinero_id","notas","activo"}, motivo)
-- Desactivado: no recibe repartos nuevos; lo que tenga se puede seguir usando.
CREATE FUNCTION public.editar_fondo(p_empresa_id uuid, p_fondo_id uuid, p_datos jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE f public.fondo;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'fondos.configurar', 'fondos');
  PERFORM interno.exigir_claves(p_datos, ARRAY['nombre', 'meta_tipo', 'meta_monto_centavos', 'meta_meses', 'cuenta_dinero_id', 'notas', 'activo']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO f FROM public.fondo x WHERE x.id = p_fondo_id AND x.empresa_id = p_empresa_id FOR UPDATE;
  IF f.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el fondo no existe en esta empresa.';
  END IF;
  f := interno.aplicar_datos_fondo(f, p_datos);
  IF EXISTS (SELECT 1 FROM public.fondo x WHERE x.empresa_id = p_empresa_id AND x.id <> f.id AND lower(x.nombre) = lower(f.nombre)) THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay un fondo llamado "%".', f.nombre;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.fondo SET nombre = f.nombre, meta_tipo = f.meta_tipo, meta_monto_centavos = f.meta_monto_centavos, meta_meses = f.meta_meses,
         cuenta_dinero_id = f.cuenta_dinero_id, notas = f.notas, activo = f.activo
   WHERE id = f.id RETURNING * INTO f;
  UPDATE public.cuenta SET nombre = 'Reserva ' || f.nombre WHERE id = f.cuenta_id AND nombre <> 'Reserva ' || f.nombre;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('fondo_id', f.id, 'nombre', f.nombre, 'activo', f.activo, 'meta_centavos', interno.meta_fondo(f),
    'saldo_centavos', interno.saldo_fondo(f.id), 'cuenta_dinero_id', f.cuenta_dinero_id);
END $$;

-- guardar_regla_distribucion(empresa, regla, motivo): la valida (suma 100 %) y la guarda.
CREATE FUNCTION public.guardar_regla_distribucion(p_empresa_id uuid, p_regla jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_p jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'fondos.configurar', 'fondos');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  v_p := interno.partes_regla(p_empresa_id, p_regla);
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.regla_distribucion AS r (empresa_id, regla, motivo, actualizado_por)
  VALUES (p_empresa_id, p_regla, trim(p_motivo), auth.uid())
  ON CONFLICT (empresa_id) DO UPDATE SET regla = excluded.regla, motivo = excluded.motivo, actualizado_por = excluded.actualizado_por,
                                         actualizado_en = now();
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('regla', p_regla, 'partes', v_p);
END $$;

-- ---------------------------------------------------------------------
-- 5) RPC: repartir utilidades de un mes CERRADO (solo el dueño)
-- distribuir_utilidades(empresa, año, mes, datos, motivo, id_operacion)
--   datos = {} (regla guardada) | {"fondos":[...], "socios":[...] | "socios_porcentaje": n}
--           + "fecha"? (hoy por defecto; después del mes), "separar_desde"? (cuenta de dinero de donde
--             se separa el dinero hacia la cuenta de cada fondo que tenga una), "equipo"?
-- ---------------------------------------------------------------------
CREATE FUNCTION public.distribuir_utilidades(p_empresa_id uuid, p_anio integer, p_mes integer, p_datos jsonb, p_motivo text,
                                             p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_desde date;
  v_hasta date;
  c       public.cierre;
  d       public.distribucion;
  v_regla jsonb;
  v_part  jsonb;
  v_rep   jsonb;
  v_base  bigint;
  v_fact  bigint;
  v_fecha date;
  v_sep   public.cuenta_dinero;
  v_lin   jsonb;
  v_lsep  jsonb := '[]';
  x       jsonb;
  f       public.fondo;
  v_asto  uuid;
  v_asep  uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'fondos.distribuir', 'fondos');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'distribucion_utilidades');
  SELECT * INTO d FROM public.distribucion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF d.id IS NOT NULL THEN
    RETURN jsonb_build_object('distribucion_id', d.id, 'numero', d.numero, 'base_centavos', d.base_centavos, 'asiento_id', d.asiento_id, 'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(coalesce(p_datos, '{}'), ARRAY['fondos', 'socios', 'socios_porcentaje', 'fecha', 'separar_desde', 'equipo']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del reparto (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_desde, v_hasta FROM interno.rango_mes(p_empresa_id, p_anio, p_mes);
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  IF v_fecha <= v_hasta THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el reparto del mes % va con fecha posterior al mes (desde el %).', interno.mes_texto(v_desde),
      to_char(v_hasta + 1, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  -- Regla: la enviada o la guardada.
  v_regla := coalesce(p_datos, '{}') - ARRAY['fecha', 'separar_desde', 'equipo'];
  IF v_regla = '{}'::jsonb THEN
    SELECT r.regla INTO v_regla FROM public.regla_distribucion r WHERE r.empresa_id = p_empresa_id;
    IF v_regla IS NULL THEN
      RAISE EXCEPTION 'SIN_REGLA_DISTRIBUCION: guarde la regla con guardar_regla_distribucion o envíe los porcentajes.';
    END IF;
  END IF;
  v_part := interno.partes_regla(p_empresa_id, v_regla);
  IF p_datos ? 'separar_desde' AND p_datos->'separar_desde' <> 'null'::jsonb THEN
    IF NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo (separar el dinero es un traslado).';
    END IF;
    v_sep := interno.cuenta_dinero_para_pagar(p_empresa_id, interno.json_uuid(p_datos->'separar_desde', 'separar_desde'));
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'distribucion_utilidades');
  SELECT * INTO d FROM public.distribucion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF d.id IS NOT NULL THEN
    RETURN jsonb_build_object('distribucion_id', d.id, 'numero', d.numero, 'base_centavos', d.base_centavos, 'asiento_id', d.asiento_id, 'duplicado', true);
  END IF;
  -- El mes debe estar cerrado y con su foto (de ahí sale la utilidad cobrada).
  IF NOT EXISTS (SELECT 1 FROM public.periodo p WHERE p.empresa_id = p_empresa_id AND p.anio = p_anio AND p.mes = p_mes AND p.estado = 'cerrado') THEN
    RAISE EXCEPTION 'MES_ABIERTO: el mes % está abierto; ciérrelo con cerrar_mes antes de repartir.', interno.mes_texto(v_desde);
  END IF;
  SELECT * INTO c FROM public.cierre x WHERE x.empresa_id = p_empresa_id AND x.anio = p_anio AND x.mes = p_mes AND x.estado = 'vigente';
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'MES_SIN_CIERRE: el mes % está cerrado sin su foto; ejecute cerrar_mes.', interno.mes_texto(v_desde);
  END IF;
  IF EXISTS (SELECT 1 FROM public.distribucion x WHERE x.empresa_id = p_empresa_id AND x.anio = p_anio AND x.mes = p_mes AND x.anulada_en IS NULL) THEN
    RAISE EXCEPTION 'YA_DISTRIBUIDO: las utilidades de % ya se repartieron.', interno.mes_texto(v_desde);
  END IF;
  SELECT (dd.datos->>'utilidad_cobrada_centavos')::bigint, (dd.datos->>'utilidad_neta_centavos')::bigint INTO v_base, v_fact
    FROM public.cierre_detalle dd WHERE dd.cierre_id = c.id AND dd.seccion = 'estado_resultados';
  IF coalesce(v_base, 0) <= 0 THEN
    RAISE EXCEPTION 'SIN_UTILIDAD_COBRADA: la utilidad cobrada de % es % (facturada %); no se reparte.', interno.mes_texto(v_desde),
      interno.lempiras(coalesce(v_base, 0)), interno.lempiras(coalesce(v_fact, 0));
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  v_rep := interno.repartir_base(v_base, v_part);

  d.id := gen_random_uuid();
  d.numero := interno.siguiente_numero(p_empresa_id, 'distribucion');
  v_lin := jsonb_build_array(jsonb_build_object('uso', 'utilidades_ejercicio', 'debe', v_base,
                                                'descripcion', 'Utilidad cobrada de ' || interno.mes_texto(v_desde)));
  FOR x IN SELECT * FROM jsonb_array_elements(v_rep) LOOP
    IF x->>'tipo' = 'fondo' THEN
      SELECT * INTO f FROM public.fondo WHERE id = (x->>'id')::uuid;
      v_lin := v_lin || jsonb_build_object('cuenta', (SELECT cu.codigo FROM public.cuenta cu WHERE cu.id = f.cuenta_id),
                                           'haber', (x->>'monto_centavos')::bigint, 'descripcion', 'Reserva ' || f.nombre);
      IF v_sep.id IS NOT NULL AND f.cuenta_dinero_id IS NOT NULL AND f.cuenta_dinero_id <> v_sep.id AND (x->>'monto_centavos')::bigint > 0 THEN
        v_lsep := v_lsep
          || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero((interno.cuenta_dinero_de(p_empresa_id, f.cuenta_dinero_id)).id),
                                'debe', (x->>'monto_centavos')::bigint, 'descripcion', 'Separación del fondo ' || f.nombre)
          || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(v_sep.id), 'haber', (x->>'monto_centavos')::bigint,
                                'descripcion', 'Separación del fondo ' || f.nombre);
      END IF;
    END IF;
  END LOOP;
  v_lin := v_lin || jsonb_build_object('uso', 'dividendos_por_pagar',
    'haber', coalesce((SELECT sum((y->>'monto_centavos')::bigint) FROM jsonb_array_elements(v_rep) y WHERE y->>'tipo' = 'socio'), 0),
    'descripcion', 'Dividendos por pagar a socios');
  v_asto := interno.asiento_sistema(p_empresa_id, NULL, v_fecha,
    'Reparto de utilidades #' || d.numero || ' de ' || interno.mes_texto(v_desde) || ': ' || trim(p_motivo),
    'distribucion_utilidades', p_id_operacion, v_lin);
  IF jsonb_array_length(v_lsep) > 0 THEN
    v_asep := interno.asiento_sistema(p_empresa_id, interno.sucursal_activa(v_sep.sucursal_id), v_fecha,
      'Separación física de fondos, reparto #' || d.numero, 'separacion_fondos', md5(p_id_operacion::text || ':separacion')::uuid, v_lsep);
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.distribucion (id, empresa_id, numero, anio, mes, cierre_id, utilidad_facturada_centavos, base_centavos, fecha_contable,
                                   motivo, separar_desde_id, equipo, asiento_id, asiento_separacion_id, id_operacion, creado_por)
  VALUES (d.id, p_empresa_id, d.numero, p_anio, p_mes, c.id, coalesce(v_fact, 0), v_base, v_fecha, trim(p_motivo),
          CASE WHEN v_asep IS NOT NULL THEN v_sep.id END, interno.equipo(p_datos), v_asto, v_asep, p_id_operacion, auth.uid())
  RETURNING * INTO d;
  INSERT INTO public.distribucion_detalle (distribucion_id, empresa_id, fondo_id, socio_id, porcentaje, monto_centavos)
  SELECT d.id, p_empresa_id, CASE WHEN y->>'tipo' = 'fondo' THEN (y->>'id')::uuid END, CASE WHEN y->>'tipo' = 'socio' THEN (y->>'id')::uuid END,
         round((y->>'porcentaje')::numeric, 4), (y->>'monto_centavos')::bigint
    FROM jsonb_array_elements(v_rep) y;
  INSERT INTO public.fondo_movimiento (empresa_id, fondo_id, tipo, monto_centavos, fecha_contable, documento_tipo, documento_id, asiento_id,
                                       descripcion, creado_por)
  SELECT p_empresa_id, (y->>'id')::uuid, 'aporte', (y->>'monto_centavos')::bigint, v_fecha, 'distribucion', d.id, v_asto,
         'Reparto de utilidades de ' || interno.mes_texto(v_desde), auth.uid()
    FROM jsonb_array_elements(v_rep) y WHERE y->>'tipo' = 'fondo' AND (y->>'monto_centavos')::bigint > 0;
  PERFORM set_config('app.motivo', '', true);
  IF v_asep IS NOT NULL THEN
    PERFORM interno.rastrear_dinero(v_asep, 'separacion_fondos', 'distribucion', d.id, 'Reparto #' || d.numero, d.equipo);
  END IF;
  RETURN jsonb_build_object('distribucion_id', d.id, 'numero', d.numero, 'anio', p_anio, 'mes', p_mes,
    'utilidad_facturada_centavos', d.utilidad_facturada_centavos, 'base_centavos', v_base, 'partes', v_rep,
    'asiento_id', v_asto, 'asiento_separacion_id', v_asep, 'duplicado', false);
END $$;

-- anular_distribucion(distribucion, motivo, id_operacion, fecha?)   fondos.distribuir
-- Contra-asientos (y el dinero separado vuelve a su cuenta). No se anula si ya se pagaron
-- dividendos de ese reparto o si un fondo ya gastó parte de lo que recibió (DISTRIBUCION_USADA).
CREATE FUNCTION public.anular_distribucion(p_distribucion_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d       public.distribucion;
  v_fecha date;
  v_lin   jsonb;
  v_asto  uuid;
  v_asep  uuid;
  r       record;
BEGIN
  SELECT * INTO d FROM public.distribucion WHERE id = p_distribucion_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la distribución no existe.';
  END IF;
  PERFORM interno.exigir_escritura(d.empresa_id, 'fondos.distribuir', 'fondos');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(d.empresa_id, p_id_operacion, 'anulacion_distribucion');
  IF d.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('distribucion_id', d.id, 'asiento_id', d.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(d.empresa_id), d.fecha_contable));
  PERFORM interno.exigir_fecha_contable(d.empresa_id, v_fecha);
  IF v_fecha < d.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al reparto (%).', to_char(d.fecha_contable, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.reservar_operacion(d.empresa_id, p_id_operacion, 'anulacion_distribucion');
  SELECT * INTO d FROM public.distribucion WHERE id = p_distribucion_id FOR UPDATE;
  IF d.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('distribucion_id', d.id, 'asiento_id', d.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF d.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el reparto #% ya fue anulado.', d.numero;
  END IF;
  FOR r IN SELECT f.nombre, dd.monto_centavos, interno.saldo_fondo(f.id) AS saldo FROM public.distribucion_detalle dd
             JOIN public.fondo f ON f.id = dd.fondo_id WHERE dd.distribucion_id = d.id LOOP
    IF r.saldo < r.monto_centavos THEN
      RAISE EXCEPTION 'DISTRIBUCION_USADA: el fondo "%" recibió % de este reparto y hoy tiene %.', r.nombre,
        interno.lempiras(r.monto_centavos), interno.lempiras(r.saldo);
    END IF;
  END LOOP;
  FOR r IN SELECT s.nombre, interno.dividendos_pendientes(s.id) - dd.monto_centavos AS queda FROM public.distribucion_detalle dd
             JOIN public.socio s ON s.id = dd.socio_id WHERE dd.distribucion_id = d.id LOOP
    IF r.queda < 0 THEN
      RAISE EXCEPTION 'DISTRIBUCION_USADA: al socio "%" ya se le pagaron dividendos de este reparto; anule primero esos pagos.', r.nombre;
    END IF;
  END LOOP;
  PERFORM interno.exigir_periodo_abierto(d.empresa_id, v_fecha);
  SELECT jsonb_agg(jsonb_build_object('cuenta', c.codigo, 'debe', l.haber_centavos, 'haber', l.debe_centavos, 'descripcion', 'Anulación: ' || l.descripcion)
                   ORDER BY l.linea) INTO v_lin
    FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = d.asiento_id;
  v_asto := interno.asiento_sistema(d.empresa_id, NULL, v_fecha, 'ANULACIÓN reparto de utilidades #' || d.numero || ': ' || trim(p_motivo),
    'anulacion_distribucion', p_id_operacion, v_lin, d.asiento_id, trim(p_motivo));
  IF d.asiento_separacion_id IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('cuenta', c.codigo, 'debe', l.haber_centavos, 'haber', l.debe_centavos, 'descripcion', 'Anulación: ' || l.descripcion)
                     ORDER BY l.linea) INTO v_lin
      FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = d.asiento_separacion_id;
    v_asep := interno.asiento_sistema(d.empresa_id, NULL, v_fecha, 'ANULACIÓN separación de fondos, reparto #' || d.numero,
      'anulacion_separacion_fondos', md5(p_id_operacion::text || ':separacion')::uuid, v_lin, d.asiento_separacion_id, trim(p_motivo));
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.fondo_movimiento (empresa_id, fondo_id, tipo, monto_centavos, fecha_contable, documento_tipo, documento_id, asiento_id,
                                       descripcion, creado_por)
  SELECT d.empresa_id, dd.fondo_id, 'anulacion_aporte', -dd.monto_centavos, v_fecha, 'distribucion', d.id, v_asto, 'Anulación: ' || trim(p_motivo), auth.uid()
    FROM public.distribucion_detalle dd WHERE dd.distribucion_id = d.id AND dd.fondo_id IS NOT NULL AND dd.monto_centavos > 0;
  UPDATE public.distribucion SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo), fecha_anulacion = v_fecha,
         asiento_anulacion_id = v_asto, asiento_anulacion_separacion_id = v_asep, anulacion_id_operacion = p_id_operacion
   WHERE id = d.id;
  PERFORM set_config('app.motivo', '', true);
  IF v_asep IS NOT NULL THEN
    PERFORM interno.rastrear_dinero(v_asep, 'anulacion_separacion_fondos', 'distribucion', d.id, trim(p_motivo), NULL);
  END IF;
  RETURN jsonb_build_object('distribucion_id', d.id, 'asiento_id', v_asto, 'asiento_separacion_id', v_asep, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 6) RPC: usar un fondo (lo aprueba el dueño)
-- usar_fondo(fondo, {"monto_centavos","cuenta_dinero_id","cuenta_destino","fecha"?,"referencia"?,"equipo"?,"comprobante"}, motivo, id_operacion)
--   cuenta_destino: código de una cuenta de detalle de gasto, costo o activo (no efectivo ni cuentas de un módulo).
--   Si lo pide el dueño se aplica; si lo pide otro puesto (con fondos.usar) queda pendiente de su aprobación.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.usar_fondo(p_fondo_id uuid, p_datos jsonb, p_motivo text, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f       public.fondo;
  u       public.fondo_uso;
  d       public.cuenta_dinero;
  v_dest  public.cuenta;
  v_monto bigint;
  v_fecha date;
  v_rol   text;
  v_apr   uuid;
BEGIN
  SELECT * INTO f FROM public.fondo WHERE id = p_fondo_id;
  IF f.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el fondo no existe.';
  END IF;
  PERFORM interno.exigir_escritura(f.empresa_id, 'fondos.usar', 'fondos');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(f.empresa_id, p_id_operacion, 'uso_fondo');
  SELECT * INTO u FROM public.fondo_uso x WHERE x.empresa_id = f.empresa_id AND x.id_operacion = p_id_operacion;
  IF u.id IS NOT NULL THEN
    RETURN interno.fondo_uso_respuesta(u, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['monto_centavos', 'cuenta_dinero_id', 'cuenta_destino', 'fecha', 'referencia', 'equipo', 'comprobante']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba para qué se usa el fondo (mínimo 5 letras).';
  END IF;
  v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  IF v_monto = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el monto debe ser mayor que cero.';
  END IF;
  IF p_datos->'comprobante' IS NULL OR p_datos->'comprobante' = 'null'::jsonb THEN
    RAISE EXCEPTION 'DATO_INVALIDO: usar un fondo necesita el comprobante (foto o PDF de la factura o recibo).';
  END IF;
  d := interno.cuenta_dinero_para_pagar(f.empresa_id, interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id'));
  SELECT * INTO v_dest FROM public.cuenta c WHERE c.empresa_id = f.empresa_id AND c.codigo = interno.json_texto(p_datos->'cuenta_destino', 'cuenta_destino', 30);
  IF v_dest.id IS NULL OR NOT v_dest.es_detalle OR NOT v_dest.activa OR v_dest.tipo NOT IN ('gasto', 'costo', 'activo')
     OR v_dest.codigo LIKE '1.1.01.%'
     OR EXISTS (SELECT 1 FROM interno.cuenta_sistema cs WHERE cs.modulo_controla IS NOT NULL AND interno.cuenta_de(f.empresa_id, cs.uso) = v_dest.codigo) THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: "cuenta_destino" es el código de una cuenta de detalle activa de gasto, costo o activo (no efectivo ni una cuenta que mueve un módulo).';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(f.empresa_id));
  PERFORM interno.exigir_fecha_contable(f.empresa_id, v_fecha);
  v_rol := public.mi_rol(f.empresa_id);

  PERFORM interno.reservar_operacion(f.empresa_id, p_id_operacion, 'uso_fondo');
  SELECT * INTO u FROM public.fondo_uso x WHERE x.empresa_id = f.empresa_id AND x.id_operacion = p_id_operacion;
  IF u.id IS NOT NULL THEN
    RETURN interno.fondo_uso_respuesta(u, true);
  END IF;
  IF interno.saldo_fondo(f.id) < v_monto THEN
    RAISE EXCEPTION 'FONDO_INSUFICIENTE: el fondo "%" tiene % y se pide %.', f.nombre, interno.lempiras(interno.saldo_fondo(f.id)), interno.lempiras(v_monto);
  END IF;
  u.id := gen_random_uuid();
  u.empresa_id := f.empresa_id;
  u.numero := interno.siguiente_numero(f.empresa_id, 'fondo_uso');
  u.fondo_id := f.id;
  u.monto_centavos := v_monto;
  u.motivo := trim(p_motivo);
  u.cuenta_dinero_id := d.id;
  u.cuenta_destino_id := v_dest.id;
  u.fecha_contable := v_fecha;
  u.referencia := interno.json_texto(p_datos->'referencia', 'referencia', 100);
  u.equipo := interno.equipo(p_datos);
  u.id_operacion := p_id_operacion;
  u.solicitado_por := auth.uid();
  u.registrado_en := now();
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  IF v_rol = 'dueno' THEN
    -- El dueño lo pide = el dueño lo aprueba.
    u.asiento_id := interno.aplicar_uso_fondo(u, v_fecha, p_id_operacion);
    u.estado := 'aplicado';
    u.aplicado_en := now();
    u.aplicado_por := auth.uid();
    INSERT INTO public.fondo_uso SELECT (u).*;
  ELSE
    u.estado := 'pendiente_aprobacion';
    v_apr := gen_random_uuid();
    INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                   solicitado_por, rol_solicitante)
    VALUES (v_apr, f.empresa_id, interno.siguiente_numero(f.empresa_id, 'aprobacion'), 'uso_fondo', 'fondo_uso', u.id, v_monto,
            'Uso del fondo "' || f.nombre || '" #' || u.numero || ': ' || u.motivo || ' (' || interno.lempiras(v_monto) || ' de ' || d.nombre || ')',
            auth.uid(), v_rol);
    u.aprobacion_id := v_apr;
    INSERT INTO public.fondo_uso SELECT (u).*;
  END IF;
  PERFORM interno.guardar_adjunto(f.empresa_id, 'fondo_uso', u.id, p_datos->'comprobante');
  PERFORM set_config('app.motivo', '', true);
  SELECT * INTO u FROM public.fondo_uso WHERE id = u.id;
  RETURN interno.fondo_uso_respuesta(u, false);
END $$;

-- Aprobar o rechazar el uso de un fondo (lo llama resolver_aprobacion). Solo quien tiene fondos.aprobar (el dueño).
CREATE FUNCTION interno.resolver_aprobacion_uso_fondo(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                      p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.aprobacion;
  u       public.fondo_uso;
  v_rol   text;
  v_fecha date;
  v_asto  uuid;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  PERFORM interno.exigir_escritura(a.empresa_id, 'fondos.aprobar', 'fondos');
  v_rol := public.mi_rol(a.empresa_id);
  IF p_aprobar IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si aprueba (true) o rechaza (false).';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    SELECT * INTO u FROM public.fondo_uso WHERE id = a.documento_id;
    RETURN interno.fondo_uso_respuesta(u, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado);
  END IF;
  IF NOT p_aprobar AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se rechaza (mínimo 5 letras).';
  END IF;
  IF a.solicitado_por = auth.uid() AND v_rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede aprobar ni rechazar su propia solicitud; lo hace el dueño.';
  END IF;
  SELECT * INTO u FROM public.fondo_uso WHERE id = a.documento_id;
  v_fecha := coalesce(p_fecha, u.fecha_contable);
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_fecha < u.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la fecha del uso aprobado no puede ser anterior a la de la solicitud (%).', to_char(u.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id FOR UPDATE;
  SELECT * INTO u FROM public.fondo_uso WHERE id = a.documento_id FOR UPDATE;
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.fondo_uso_respuesta(u, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado);
  END IF;
  IF a.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la solicitud #% ya está %.', a.numero, a.estado;
  END IF;
  IF p_aprobar AND NOT interno.paso_aprobacion(a, v_rol, p_motivo, p_id_operacion) THEN
    SELECT * INTO a FROM public.aprobacion WHERE id = a.id;
    RETURN interno.fondo_uso_respuesta(u, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', true);
  END IF;
  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  UPDATE public.aprobacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_por = auth.uid(),
         rol_resolutor = v_rol, resuelto_en = now(), motivo_resolucion = nullif(trim(p_motivo), ''), resolucion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  IF p_aprobar THEN
    u.fecha_contable := v_fecha;
    v_asto := interno.aplicar_uso_fondo(u, v_fecha, p_id_operacion);
    UPDATE public.fondo_uso SET estado = 'aplicado', fecha_contable = v_fecha, asiento_id = v_asto, aplicado_en = now(), aplicado_por = auth.uid()
     WHERE id = u.id;
  ELSE
    UPDATE public.fondo_uso SET estado = 'rechazado' WHERE id = u.id;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  SELECT * INTO u FROM public.fondo_uso WHERE id = u.id;
  RETURN interno.fondo_uso_respuesta(u, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
    'falta_segunda_aprobacion', false);
END $$;

-- resolver_aprobacion (reemplaza la de 039; misma firma): rama nueva "uso_fondo".
CREATE OR REPLACE FUNCTION public.resolver_aprobacion(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                      p_fecha date DEFAULT NULL, p_cuenta_salida_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a      public.aprobacion;
  v_td   record;
  v_pct  numeric;
  r      jsonb;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la solicitud de aprobación no existe.';
  END IF;
  IF p_cuenta_salida_id IS NOT NULL AND a.tipo <> 'anulacion_venta' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de salida solo se indica al aprobar la anulación de una venta (en una devolución, use definir_destino_devolucion).';
  END IF;
  IF a.tipo = 'gasto' THEN
    RETURN interno.resolver_aprobacion_gasto(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha);
  ELSIF a.tipo = 'uso_fondo' THEN
    RETURN interno.resolver_aprobacion_uso_fondo(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha);
  ELSIF a.tipo = 'venta' THEN
    -- 0.9.1: quien aprueba tampoco pasa su tope en una sola línea (salvo el dueño).
    IF p_aprobar AND a.estado = 'pendiente' AND public.mi_rol(a.empresa_id) <> 'dueno'
       AND public.tiene_permiso('ventas.aprobar', a.empresa_id)
       AND EXISTS (SELECT 1 FROM public.venta v WHERE v.id = a.documento_id AND 'descuento' = ANY (v.requiere_aprobacion)) THEN
      SELECT * INTO v_td FROM interno.tope_descuento(a.empresa_id, public.mi_rol(a.empresa_id));
      v_pct := interno.descuento_linea_sobre_tope((SELECT jsonb_agg(to_jsonb(l)) FROM public.venta_linea l WHERE l.venta_id = a.documento_id),
                                                 v_td.aprueba_hasta);
      IF v_pct IS NOT NULL THEN
        RAISE EXCEPTION 'TOPE_APROBACION: una línea lleva % %% de descuento y usted aprueba hasta % %%; pídale al dueño que lo apruebe.',
          v_pct, v_td.aprueba_hasta;
      END IF;
    END IF;
    IF p_aprobar AND NOT public.modulo_esta_activo(a.empresa_id, 'inventario')
       AND EXISTS (SELECT 1 FROM public.venta_linea l WHERE l.venta_id = a.documento_id AND NOT l.es_servicio) THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo: esta venta lleva bienes y no se puede emitir; recházela o cancélela.';
    END IF;
    IF p_aprobar AND NOT public.modulo_esta_activo(a.empresa_id, 'dinero')
       AND EXISTS (SELECT 1 FROM public.venta_pago g WHERE g.venta_id = a.documento_id AND g.forma IN ('efectivo', 'tarjeta', 'transferencia')) THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo: esta venta se cobra al contado y no se puede emitir; recházela o cancélela.';
    END IF;
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_aprobacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  ELSIF a.tipo = 'anulacion_venta' THEN
    -- 0.9.2: el efectivo puede salir de la cuenta que elige quien aprueba (caja fuerte, banco o su
    -- propio turno), por ejemplo cuando la única caja tiene abierto el turno de otro cajero.
    IF p_cuenta_salida_id IS NOT NULL AND p_aprobar THEN
      PERFORM interno.exigir_escritura(a.empresa_id, 'ventas.anular', 'ventas');
      PERFORM interno.cuenta_salida_elegida(a.empresa_id, p_cuenta_salida_id);
      PERFORM set_config('app.cuenta_salida', p_cuenta_salida_id::text, true);
    END IF;
    r := interno.ocultar_costos(a.empresa_id,
      interno.resolver_anulacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
    PERFORM set_config('app.cuenta_salida', '', true);
    RETURN r;
  ELSIF a.tipo = 'devolucion' THEN
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_aprobacion_devolucion(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  END IF;
  RAISE EXCEPTION 'NO_PERMITIDO: este tipo de aprobación (%) todavía no se resuelve aquí.', a.tipo;
END $$;

-- ---------------------------------------------------------------------
-- 7) RPC: dividendos a socios
-- pagar_dividendos(empresa, {"socio_id","monto_centavos"? (todo lo pendiente),"cuenta_dinero_id","fecha"?,"referencia"?,"equipo"?,
--                            "comprobante"?}, id_operacion)   fondos.pagar_dividendos
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pagar_dividendos(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p       public.dividendo_pago;
  s       public.socio;
  d       public.cuenta_dinero;
  v_fecha date;
  v_monto bigint;
  v_pend  bigint;
  v_asto  uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'fondos.pagar_dividendos', 'fondos');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'pago_dividendos');
  SELECT * INTO p FROM public.dividendo_pago x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF p.id IS NOT NULL THEN
    RETURN jsonb_build_object('dividendo_pago_id', p.id, 'numero', p.numero, 'monto_centavos', p.monto_centavos, 'asiento_id', p.asiento_id, 'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['socio_id', 'monto_centavos', 'cuenta_dinero_id', 'fecha', 'referencia', 'equipo', 'comprobante']);
  SELECT * INTO s FROM public.socio x WHERE x.id = interno.json_uuid(p_datos->'socio_id', 'socio_id') AND x.empresa_id = p_empresa_id;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el socio ("socio_id") de esta empresa.';
  END IF;
  d := interno.cuenta_dinero_para_pagar(p_empresa_id, interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id'));
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  IF p_datos ? 'monto_centavos' THEN
    v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'pago_dividendos');
  SELECT * INTO p FROM public.dividendo_pago x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF p.id IS NOT NULL THEN
    RETURN jsonb_build_object('dividendo_pago_id', p.id, 'numero', p.numero, 'monto_centavos', p.monto_centavos, 'asiento_id', p.asiento_id, 'duplicado', true);
  END IF;
  v_pend := interno.dividendos_pendientes(s.id);
  IF v_pend <= 0 THEN
    RAISE EXCEPTION 'NADA_QUE_PAGAR: el socio "%" no tiene dividendos pendientes.', s.nombre;
  END IF;
  v_monto := coalesce(v_monto, v_pend);
  IF v_monto = 0 OR v_monto > v_pend THEN
    RAISE EXCEPTION 'PAGO_EXCEDE_SALDO: al socio "%" se le deben %; el pago debe ser mayor que cero y no pasar eso.', s.nombre, interno.lempiras(v_pend);
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  p.id := gen_random_uuid();
  p.numero := interno.siguiente_numero(p_empresa_id, 'dividendo_pago');
  v_asto := interno.asiento_sistema(p_empresa_id, interno.sucursal_activa(d.sucursal_id), v_fecha,
    'Pago de dividendos #' || p.numero || ' a ' || s.nombre, 'pago_dividendos', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'dividendos_por_pagar', 'debe', v_monto, 'descripcion', 'Dividendos pagados a ' || s.nombre),
                      jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'haber', v_monto, 'descripcion', 'Pago de dividendos')));
  INSERT INTO public.dividendo_pago (id, empresa_id, numero, socio_id, monto_centavos, cuenta_dinero_id, fecha_contable, referencia, equipo,
                                     asiento_id, id_operacion, creado_por)
  VALUES (p.id, p_empresa_id, p.numero, s.id, v_monto, d.id, v_fecha, interno.json_texto(p_datos->'referencia', 'referencia', 100),
          interno.equipo(p_datos), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO p;
  PERFORM interno.guardar_adjunto(p_empresa_id, 'dividendo_pago', p.id, p_datos->'comprobante');
  PERFORM interno.rastrear_dinero(v_asto, 'pago_dividendos', 'dividendo_pago', p.id, coalesce(p.referencia, 'Dividendos #' || p.numero), p.equipo);
  RETURN jsonb_build_object('dividendo_pago_id', p.id, 'numero', p.numero, 'monto_centavos', v_monto, 'asiento_id', v_asto,
    'pendiente_centavos', interno.dividendos_pendientes(s.id), 'duplicado', false);
END $$;

-- anular_pago_dividendos(pago, motivo, id_operacion, fecha?): el dinero vuelve a la misma cuenta; vuelve a quedar por pagar.
CREATE FUNCTION public.anular_pago_dividendos(p_pago_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p       public.dividendo_pago;
  v_fecha date;
  v_asto  uuid;
  v_suc   uuid;
BEGIN
  SELECT * INTO p FROM public.dividendo_pago WHERE id = p_pago_id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el pago de dividendos no existe.';
  END IF;
  PERFORM interno.exigir_escritura(p.empresa_id, 'fondos.pagar_dividendos', 'fondos');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p.empresa_id, p_id_operacion, 'anulacion_pago_dividendos');
  IF p.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('dividendo_pago_id', p.id, 'asiento_id', p.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(p.empresa_id), p.fecha_contable));
  PERFORM interno.exigir_fecha_contable(p.empresa_id, v_fecha);
  IF v_fecha < p.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al pago (%).', to_char(p.fecha_contable, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.reservar_operacion(p.empresa_id, p_id_operacion, 'anulacion_pago_dividendos');
  SELECT * INTO p FROM public.dividendo_pago WHERE id = p_pago_id FOR UPDATE;
  IF p.anulacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('dividendo_pago_id', p.id, 'asiento_id', p.asiento_anulacion_id, 'duplicado', true);
  END IF;
  IF p.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el pago de dividendos #% ya fue anulado.', p.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p.empresa_id, v_fecha);
  SELECT a.sucursal_id INTO v_suc FROM public.asiento a WHERE a.id = p.asiento_id;
  v_asto := interno.asiento_sistema(p.empresa_id, interno.sucursal_activa(v_suc), v_fecha,
    'ANULACIÓN pago de dividendos #' || p.numero || ': ' || trim(p_motivo), 'anulacion_pago_dividendos', p_id_operacion,
    jsonb_build_array(jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(p.cuenta_dinero_id), 'debe', p.monto_centavos,
                                         'descripcion', 'Vuelve el dinero del pago'),
                      jsonb_build_object('uso', 'dividendos_por_pagar', 'haber', p.monto_centavos, 'descripcion', 'Vuelve a quedar por pagar')),
    p.asiento_id, trim(p_motivo));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.dividendo_pago SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo), fecha_anulacion = v_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = p.id;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_pago_dividendos', 'dividendo_pago', p.id, trim(p_motivo), NULL);
  RETURN jsonb_build_object('dividendo_pago_id', p.id, 'asiento_id', v_asto, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 8) Lecturas (fondos.ver)
-- ---------------------------------------------------------------------
-- Estado de cada fondo (saldo, aportes, usos, meta y % de meta), socios con dividendos
-- pendientes y el cuadre con los libros.
CREATE FUNCTION public.estado_fondos(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'fondos.ver');
  RETURN jsonb_build_object(
    'empresa', interno.encabezado_empresa(p_empresa_id), 'generado_en', public.iso(now()),
    'fondos', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'fondo_id', f.id, 'nombre', f.nombre, 'tipo', f.tipo, 'activo', f.activo, 'cuenta_codigo', c.codigo,
        'saldo_centavos', interno.saldo_fondo(f.id),
        'aportes_centavos', coalesce((SELECT sum(m.monto_centavos) FROM public.fondo_movimiento m WHERE m.fondo_id = f.id AND m.tipo <> 'uso'), 0),
        'usos_centavos', coalesce((SELECT -sum(m.monto_centavos) FROM public.fondo_movimiento m WHERE m.fondo_id = f.id AND m.tipo = 'uso'), 0),
        'meta_tipo', f.meta_tipo, 'meta_meses', f.meta_meses, 'meta_centavos', interno.meta_fondo(f),
        'meta_porcentaje', CASE WHEN coalesce(interno.meta_fondo(f), 0) > 0
                                THEN round(interno.saldo_fondo(f.id) * 100.0 / interno.meta_fondo(f), 2) END,
        'cuenta_dinero_id', f.cuenta_dinero_id, 'cuenta_dinero', cd.nombre,
        'saldo_cuenta_dinero_centavos', CASE WHEN cd.id IS NOT NULL THEN interno.saldo_dinero(cd.id) END,
        'libros_centavos', interno.saldo_libros(p_empresa_id, c.codigo),
        'usos_pendientes', (SELECT count(*) FROM public.fondo_uso u WHERE u.fondo_id = f.id AND u.estado = 'pendiente_aprobacion'))
        ORDER BY f.nombre)
      FROM public.fondo f JOIN public.cuenta c ON c.id = f.cuenta_id LEFT JOIN public.cuenta_dinero cd ON cd.id = f.cuenta_dinero_id
      WHERE f.empresa_id = p_empresa_id), '[]'),
    'socios', coalesce((SELECT jsonb_agg(jsonb_build_object('socio_id', s.id, 'nombre', s.nombre, 'porcentaje', s.porcentaje, 'activo', s.activo,
        'dividendos_pendientes_centavos', interno.dividendos_pendientes(s.id)) ORDER BY s.nombre)
      FROM public.socio s WHERE s.empresa_id = p_empresa_id), '[]'),
    'total_reservas_centavos', coalesce((SELECT sum(m.monto_centavos) FROM public.fondo_movimiento m WHERE m.empresa_id = p_empresa_id), 0),
    'dividendos_por_pagar_centavos', interno.total_dividendos_por_pagar(p_empresa_id),
    'dividendos_por_pagar_libros_centavos', interno.saldo_libros(p_empresa_id, interno.cuenta_de(p_empresa_id, 'dividendos_por_pagar')),
    'regla', (SELECT r.regla FROM public.regla_distribucion r WHERE r.empresa_id = p_empresa_id));
END $$;

CREATE VIEW public.v_fondo_movimiento WITH (security_invoker = true) AS
  SELECT m.empresa_id, m.fondo_id, f.nombre AS fondo, m.id AS movimiento_id, m.tipo, m.monto_centavos, m.fecha_contable,
         m.documento_tipo, m.documento_id, m.asiento_id, m.descripcion, public.nombre_usuario(m.empresa_id, m.creado_por) AS usuario,
         m.registrado_en,
         sum(m.monto_centavos) OVER (PARTITION BY m.fondo_id ORDER BY m.fecha_contable, m.id)::bigint AS saldo_centavos
  FROM public.fondo_movimiento m
  JOIN public.fondo f ON f.id = m.fondo_id;

CREATE VIEW public.v_distribucion WITH (security_invoker = true) AS
  SELECT d.empresa_id, d.id AS distribucion_id, d.numero, d.anio, d.mes, d.fecha_contable, d.utilidad_facturada_centavos, d.base_centavos,
         d.motivo, d.separar_desde_id, d.asiento_id, d.anulada_en IS NOT NULL AS anulada, d.motivo_anulacion, d.fecha_anulacion,
         (SELECT c.version FROM public.cierre c WHERE c.id = d.cierre_id) AS version_cierre,
         (SELECT jsonb_agg(jsonb_build_object('fondo_id', dd.fondo_id, 'socio_id', dd.socio_id,
                   'nombre', coalesce((SELECT f.nombre FROM public.fondo f WHERE f.id = dd.fondo_id), (SELECT s.nombre FROM public.socio s WHERE s.id = dd.socio_id)),
                   'porcentaje', dd.porcentaje, 'monto_centavos', dd.monto_centavos) ORDER BY dd.id)
            FROM public.distribucion_detalle dd WHERE dd.distribucion_id = d.id) AS partes,
         public.nombre_usuario(d.empresa_id, d.creado_por) AS registrado_por, d.registrado_en
  FROM public.distribucion d;

CREATE VIEW public.v_dividendo_socio WITH (security_invoker = true) AS
  SELECT s.empresa_id, s.id AS socio_id, s.nombre, s.porcentaje, s.activo,
         coalesce((SELECT sum(dd.monto_centavos) FROM public.distribucion_detalle dd JOIN public.distribucion d ON d.id = dd.distribucion_id
                    WHERE dd.socio_id = s.id AND d.anulada_en IS NULL), 0)::bigint AS repartido_centavos,
         coalesce((SELECT sum(p.monto_centavos) FROM public.dividendo_pago p WHERE p.socio_id = s.id AND p.anulada_en IS NULL), 0)::bigint AS pagado_centavos,
         (coalesce((SELECT sum(dd.monto_centavos) FROM public.distribucion_detalle dd JOIN public.distribucion d ON d.id = dd.distribucion_id
                     WHERE dd.socio_id = s.id AND d.anulada_en IS NULL), 0)
          - coalesce((SELECT sum(p.monto_centavos) FROM public.dividendo_pago p WHERE p.socio_id = s.id AND p.anulada_en IS NULL), 0))::bigint AS pendiente_centavos
  FROM public.socio s;

GRANT SELECT ON public.v_fondo_movimiento, public.v_distribucion, public.v_dividendo_socio TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 9) Integración: id_operacion, apagado, activación, advertencias del cierre, adjuntos
-- ---------------------------------------------------------------------
INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('distribucion',   'id_operacion',           'distribucion_utilidades',   50),
  ('distribucion',   'anulacion_id_operacion', 'anulacion_distribucion',    51),
  ('fondo_uso',      'id_operacion',           'uso_fondo',                 52),
  ('dividendo_pago', 'id_operacion',           'pago_dividendos',           53),
  ('dividendo_pago', 'anulacion_id_operacion', 'anulacion_pago_dividendos', 54);
INSERT INTO interno.modulo_apagado_permite (modulo, funcion, motivo) VALUES
  ('fondos', 'public.anular_distribucion',    'Corregir un reparto de utilidades mal hecho.'),
  ('fondos', 'public.anular_pago_dividendos', 'Corregir un pago de dividendos mal registrado.');

-- Activar "fondos" con saldo en Dividendos por pagar que el módulo no explica (reemplaza la de 037; mismas ramas + fondos).
CREATE OR REPLACE FUNCTION interno.revisar_activacion_modulo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_libros bigint;
  v_modulo bigint;
  v_cta    text;
BEGIN
  PERFORM interno.bloquear_libros(NEW.empresa_id);
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
  ELSIF NEW.modulo = 'dinero' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'diferencia_caja');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := coalesce((SELECT -sum(t.diferencia_centavos) FROM public.turno_caja t
                           WHERE t.empresa_id = NEW.empresa_id AND t.diferencia_estado = 'pendiente'), 0);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (diferencias de caja) tiene % en los libros y los turnos pendientes suman %. Pase la diferencia con un asiento a la cuenta que corresponda y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  ELSIF NEW.modulo = 'ventas' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'cxc');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_cxc(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (clientes) tiene % en los libros y las facturas por cobrar del sistema suman %. Para activar el módulo: 1) registre un asiento que pase la diferencia a % Saldos de apertura (Dr %, Cr %); 2) active el módulo; 3) cargue cada factura pendiente con registrar_saldo_inicial_cxc.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo),
        interno.cuenta_de(NEW.empresa_id, 'apertura_cxc'), interno.cuenta_de(NEW.empresa_id, 'apertura_cxc'), v_cta;
    END IF;
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'saldo_favor');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_saldo_favor(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (saldos a favor de clientes) tiene % en los libros y los saldos a favor del sistema suman %. Pase la diferencia con un asiento a la cuenta que corresponda y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  ELSIF NEW.modulo = 'apartados' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'anticipo_clientes');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := coalesce((SELECT sum(interno.anticipos_apartado(a.id)) FROM public.apartado a
                           WHERE a.empresa_id = NEW.empresa_id AND a.estado = 'vigente'), 0);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (anticipos de clientes) tiene % en los libros y los apartados vigentes suman %. Pase la diferencia con un asiento (por ejemplo a saldos a favor) y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  ELSIF NEW.modulo = 'comisiones' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'comisiones_por_pagar');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_comisiones_por_pagar(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (comisiones por pagar) tiene % en los libros y las comisiones del sistema suman %. Pague o pase la diferencia con un asiento y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  ELSIF NEW.modulo = 'fondos' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'dividendos_por_pagar');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_dividendos_por_pagar(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (dividendos por pagar) tiene % en los libros y los repartos del sistema suman %. Pase la diferencia con un asiento y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- Al cerrar otra vez un mes que ya tenía reparto: avisa que el reparto salió de la versión anterior.
CREATE OR REPLACE FUNCTION interno.advertencias_extra(p_empresa_id uuid, p_anio integer, p_mes integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('tipo', 'reparto_version_anterior', 'cantidad', 1, 'monto_centavos', d.base_centavos,
    'mensaje', 'Este mes ya tiene el reparto de utilidades #' || d.numero || ' hecho con la versión ' || c.version
               || ' del cierre (utilidad cobrada ' || interno.lempiras(d.base_centavos)
               || '). Si la utilidad cobrada cambió, anule ese reparto y reparta otra vez.')), '[]')
    FROM public.distribucion d JOIN public.cierre c ON c.id = d.cierre_id
   WHERE d.empresa_id = p_empresa_id AND d.anio = p_anio AND d.mes = p_mes AND d.anulada_en IS NULL AND c.estado = 'superada'
$$;

-- Comprobantes también al uso de un fondo y al pago de dividendos (reemplaza la de 033).
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
    WHEN 'fondo_uso'        THEN (SELECT x.empresa_id FROM public.fondo_uso x WHERE x.id = p_id)
    WHEN 'dividendo_pago'   THEN (SELECT x.empresa_id FROM public.dividendo_pago x WHERE x.id = p_id)
  END;
END $$;

-- ---------------------------------------------------------------------
-- 10) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.proteger_fondo(), interno.proteger_socio(), interno.proteger_distribucion(), interno.proteger_fondo_uso(),
  interno.revisar_cuenta_fondo(), interno.saldo_fondo(uuid), interno.dividendos_pendientes(uuid), interno.total_dividendos_por_pagar(uuid),
  interno.meta_fondo(public.fondo), interno.madre_reservas(uuid), interno.json_porcentaje(jsonb, text), interno.partes_regla(uuid, jsonb),
  interno.repartir_base(bigint, jsonb), interno.aplicar_uso_fondo(public.fondo_uso, date, uuid),
  interno.fondo_uso_respuesta(public.fondo_uso, boolean), interno.aplicar_datos_fondo(public.fondo, jsonb),
  interno.resolver_aprobacion_uso_fondo(uuid, boolean, text, uuid, date)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.guardar_socio(uuid, jsonb, text), public.crear_fondo(uuid, jsonb, text), public.editar_fondo(uuid, uuid, jsonb, text),
  public.guardar_regla_distribucion(uuid, jsonb, text), public.distribuir_utilidades(uuid, integer, integer, jsonb, text, uuid),
  public.anular_distribucion(uuid, text, uuid, date), public.usar_fondo(uuid, jsonb, text, uuid),
  public.pagar_dividendos(uuid, jsonb, uuid), public.anular_pago_dividendos(uuid, text, uuid, date), public.estado_fondos(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.guardar_socio(uuid, jsonb, text), public.crear_fondo(uuid, jsonb, text), public.editar_fondo(uuid, uuid, jsonb, text),
  public.guardar_regla_distribucion(uuid, jsonb, text), public.distribuir_utilidades(uuid, integer, integer, jsonb, text, uuid),
  public.anular_distribucion(uuid, text, uuid, date), public.usar_fondo(uuid, jsonb, text, uuid),
  public.pagar_dividendos(uuid, jsonb, uuid), public.anular_pago_dividendos(uuid, text, uuid, date)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.estado_fondos(uuid) TO authenticated, service_role;
