-- =====================================================================
-- 030_modulos_dependencias.sql  -  Núcleo 0.8.0: encender y apagar
-- módulos sin romper los números.
--
--   modulo_dependencia   qué módulo necesita a cuál (DATOS, no código).
--       No se activa un módulo sin los que necesita y no se apaga uno del
--       que dependen otros activos (MODULO_DEPENDENCIA dice cuál).
--       Dependencias mínimas: inventario, dinero y ventas -> contabilidad;
--       compras -> inventario; fiscal_hn -> ventas. Ventas NO necesita
--       inventario (sin él solo vende servicios) ni dinero (sin él solo
--       vende al crédito; el contado necesita una cuenta de dinero).
--   Apagar = solo impide operaciones NUEVAS. Siguen funcionando: lecturas,
--       reportes, contabilidad y las correcciones de lo ya registrado
--       (anular, cerrar un turno abierto, confirmar un depósito o una
--       transferencia, cancelar una venta pendiente). Lista como datos en
--       interno.modulo_apagado_permite. Nunca se borra nada.
--   Cuentas de un módulo apagado: siguen sin aceptar asientos manuales
--       (si no, el kardex, la CxC o la CxP dejarían de cuadrar con los libros).
--   El catálogo de productos y servicios también se edita con "ventas"
--       (un negocio de solo servicios no necesita inventario).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('MODULO_DEPENDENCIA', 'Ese módulo depende de otro.',
   'Para activarlo, active primero el módulo que necesita. Para apagarlo, apague primero los módulos que lo usan. Lo hace su proveedor.');

-- ---------------------------------------------------------------------
-- 1) Dependencias como datos
-- ---------------------------------------------------------------------
CREATE TABLE public.modulo_dependencia (
  modulo    text NOT NULL REFERENCES public.modulo(codigo),
  requiere  text NOT NULL REFERENCES public.modulo(codigo),
  motivo    text NOT NULL,
  PRIMARY KEY (modulo, requiere),
  CHECK (modulo <> requiere)
);
ALTER TABLE public.modulo_dependencia ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.modulo_dependencia FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.modulo_dependencia TO authenticated, service_role;
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.modulo_dependencia
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');

INSERT INTO public.modulo_dependencia (modulo, requiere, motivo) VALUES
  ('inventario', 'contabilidad', 'El kardex lleva su valor a los libros (1.1.03.01).'),
  ('dinero',     'contabilidad', 'Cada cuenta de dinero es una subcuenta de los libros.'),
  ('ventas',     'contabilidad', 'Cada venta hace su asiento.'),
  ('compras',    'inventario',   'Lo comprado entra al kardex.'),
  ('fiscal_hn',  'ventas',       'El CAI numera las facturas de las ventas.');

-- ---------------------------------------------------------------------
-- 2) ¿Estuvo activo alguna vez? (para correcciones y cuentas controladas)
-- ---------------------------------------------------------------------
ALTER TABLE public.modulo_activo ADD COLUMN estuvo_activo boolean NOT NULL DEFAULT false;
-- Conservador: toda fila que ya existe se trata como usada.
UPDATE public.modulo_activo SET estuvo_activo = true;

CREATE FUNCTION interno.marcar_estuvo_activo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.estuvo_activo := NEW.activo;
  ELSE
    NEW.estuvo_activo := OLD.estuvo_activo OR NEW.activo;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER marcar_estuvo_activo BEFORE INSERT OR UPDATE ON public.modulo_activo
  FOR EACH ROW EXECUTE FUNCTION interno.marcar_estuvo_activo();

-- Revisión de dependencias al final de cada sentencia (así un INSERT de
-- varios módulos a la vez se revisa con todos ya puestos). Solo mira el
-- módulo que cambió: un estado viejo de otra fila no bloquea cambios ajenos.
CREATE FUNCTION interno.revisar_dependencias_modulo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_emp   uuid;
  v_mod   text;
  v_lista text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_emp := OLD.empresa_id; v_mod := OLD.modulo;
  ELSE
    v_emp := NEW.empresa_id; v_mod := NEW.modulo;
  END IF;
  IF public.modulo_esta_activo(v_emp, v_mod) THEN
    SELECT string_agg('"' || d.requiere || '"', ', ' ORDER BY d.requiere) INTO v_lista
      FROM public.modulo_dependencia d
     WHERE d.modulo = v_mod AND NOT public.modulo_esta_activo(v_emp, d.requiere);
    IF v_lista IS NOT NULL THEN
      RAISE EXCEPTION 'MODULO_DEPENDENCIA: el módulo "%" necesita %, que no está activo. Active primero %.', v_mod, v_lista, v_lista;
    END IF;
  ELSE
    SELECT string_agg('"' || d.modulo || '"', ', ' ORDER BY d.modulo) INTO v_lista
      FROM public.modulo_dependencia d
     WHERE d.requiere = v_mod AND public.modulo_esta_activo(v_emp, d.modulo);
    IF v_lista IS NOT NULL THEN
      RAISE EXCEPTION 'MODULO_DEPENDENCIA: no se puede apagar "%" porque lo usa %, que está activo. Apague primero %.', v_mod, v_lista, v_lista;
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER revisar_dependencias AFTER INSERT OR UPDATE OR DELETE ON public.modulo_activo
  DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION interno.revisar_dependencias_modulo();

-- ---------------------------------------------------------------------
-- 3) Apagado: qué sigue funcionando (DATOS)
-- ---------------------------------------------------------------------
-- Funciones que corrigen o terminan lo ya registrado y siguen funcionando
-- con su módulo apagado (si el módulo estuvo activo alguna vez). Se
-- reconocen por la pila de llamadas real (PG_CONTEXT): nadie las puede
-- suplantar, porque solo el dueño de la base crea funciones en public/interno.
CREATE TABLE interno.modulo_apagado_permite (
  modulo   text NOT NULL REFERENCES public.modulo(codigo),
  funcion  text NOT NULL CHECK (funcion ~ '^(public|interno)\.[a-z_0-9]+$'),
  motivo   text NOT NULL,
  PRIMARY KEY (modulo, funcion)
);
INSERT INTO interno.modulo_apagado_permite (modulo, funcion, motivo) VALUES
  ('compras',    'public.anular_compra',                 'Corregir una compra mal registrada.'),
  ('compras',    'public.anular_pago_proveedor',         'Corregir un pago mal registrado.'),
  ('compras',    'public.anular_saldo_inicial_cxp',      'Corregir un saldo inicial de proveedor.'),
  ('inventario', 'public.anular_documento_inventario',   'Corregir un ajuste, traslado o carga inicial.'),
  ('dinero',     'public.anular_operacion_dinero',       'Corregir un depósito, retiro o traslado.'),
  ('dinero',     'public.anular_gasto',                  'Corregir un gasto.'),
  ('dinero',     'public.cerrar_turno',                  'Cerrar con arqueo un turno que quedó abierto.'),
  ('dinero',     'public.resolver_diferencia',           'Resolver la diferencia pendiente de un arqueo.'),
  ('dinero',     'public.confirmar_deposito',            'Terminar un depósito que quedó en tránsito.'),
  ('dinero',     'public.confirmar_transferencia_venta', 'Pasar al banco una transferencia ya cobrada.'),
  ('ventas',     'public.solicitar_anulacion_venta',     'Pedir anular una venta mal registrada.'),
  ('ventas',     'interno.resolver_anulacion_venta',     'Aprobar o rechazar la anulación de una venta.'),
  ('ventas',     'public.cancelar_venta',                'Cancelar una venta pendiente (no movió nada).'),
  ('ventas',     'public.anular_cotizacion',             'Anular una cotización (no mueve nada).');

-- Permisos de un módulo que también valen con OTRO módulo activo.
CREATE TABLE interno.modulo_alterno (
  modulo   text NOT NULL REFERENCES public.modulo(codigo),
  permiso  text NOT NULL REFERENCES public.permiso(codigo),
  alterno  text NOT NULL REFERENCES public.modulo(codigo),
  motivo   text NOT NULL,
  PRIMARY KEY (modulo, permiso, alterno)
);
INSERT INTO interno.modulo_alterno (modulo, permiso, alterno, motivo) VALUES
  ('inventario', 'productos.editar',  'ventas', 'Un negocio de solo servicios arma su catálogo sin inventario.'),
  ('inventario', 'productos.precios', 'ventas', 'Un negocio de solo servicios cambia sus precios sin inventario.');

CREATE FUNCTION interno.modulo_permite_apagado(p_empresa_id uuid, p_modulo text, p_permiso text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_pila text;
  v_f    text;
BEGIN
  IF EXISTS (SELECT 1 FROM interno.modulo_alterno a
              WHERE a.modulo = p_modulo AND a.permiso = p_permiso AND public.modulo_esta_activo(p_empresa_id, a.alterno)) THEN
    RETURN true;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.modulo_activo m
                  WHERE m.empresa_id = p_empresa_id AND m.modulo = p_modulo AND m.estuvo_activo) THEN
    RETURN false;
  END IF;
  GET DIAGNOSTICS v_pila = PG_CONTEXT;
  FOR v_f IN SELECT (regexp_matches(v_pila, 'function ((?:public|interno)\.[a-z_0-9]+)\(', 'g'))[1] LOOP
    IF EXISTS (SELECT 1 FROM interno.modulo_apagado_permite x WHERE x.modulo = p_modulo AND x.funcion = v_f) THEN
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END $$;

-- exigir_escritura (reemplaza la de 001; misma firma y mismo orden de
-- revisiones). Nuevo: con el módulo apagado deja pasar las correcciones de
-- interno.modulo_apagado_permite y los permisos de interno.modulo_alterno.
CREATE OR REPLACE FUNCTION interno.exigir_escritura(p_empresa_id uuid, p_permiso text,
                                                    p_modulo text DEFAULT 'contabilidad',
                                                    p_exigir_licencia boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  IF NOT public.tiene_permiso(p_permiso, p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "%".', p_permiso;
  END IF;
  IF p_exigir_licencia AND NOT public.licencia_activa(p_empresa_id) THEN
    RAISE EXCEPTION 'LICENCIA_VENCIDA: el sistema está en modo solo lectura. Puede consultar y exportar.';
  END IF;
  IF p_modulo IS NOT NULL AND NOT public.modulo_esta_activo(p_empresa_id, p_modulo)
     AND NOT interno.modulo_permite_apagado(p_empresa_id, p_modulo, p_permiso) THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "%" no está activo para esta empresa.', p_modulo;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 4) Cuentas controladas: también con el módulo apagado (reemplaza la de 022)
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.modulo_controla_cuenta(p_empresa_id uuid, p_modulo text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.modulo_activo m
                  WHERE m.empresa_id = p_empresa_id AND m.modulo = p_modulo AND (m.activo OR m.estuvo_activo))
$$;

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
     AND interno.modulo_controla_cuenta(NEW.empresa_id, cs.modulo_controla)
   LIMIT 1;
  IF v_cs.uso IS NOT NULL THEN
    IF public.modulo_esta_activo(NEW.empresa_id, v_cs.modulo_controla) THEN
      RAISE EXCEPTION 'CUENTA_CONTROLADA: la cuenta % la mueve el módulo "%"; use ese módulo en vez de un asiento manual.',
        v_codigo, v_cs.modulo_controla;
    END IF;
    RAISE EXCEPTION 'CUENTA_CONTROLADA: la cuenta % la movía el módulo "%" (ahora apagado); sigue sin asientos manuales para que cuadre con lo que el módulo registró. Corrija anulando desde el documento.',
      v_codigo, v_cs.modulo_controla;
  END IF;
  SELECT d.nombre INTO v_cd FROM public.cuenta_dinero d WHERE d.cuenta_id = NEW.cuenta_id;
  IF v_cd IS NOT NULL THEN
    RAISE EXCEPTION 'CUENTA_CONTROLADA: la cuenta % es la cuenta de dinero "%"; el dinero se mueve con depósitos, traslados, gastos, pagos o cobros, no con un asiento manual.',
      v_codigo, v_cd;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 5) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.marcar_estuvo_activo(),
  interno.revisar_dependencias_modulo(),
  interno.modulo_permite_apagado(uuid, text, text),
  interno.modulo_controla_cuenta(uuid, text)
FROM PUBLIC, anon, authenticated, service_role;
