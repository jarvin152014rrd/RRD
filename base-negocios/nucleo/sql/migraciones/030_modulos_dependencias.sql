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
--   vista_previa_ficha / aplicar_ficha: lo que usa herramientas/aplicar_ficha.sh
--       (solo la llave del proveedor): módulos, perfil y licencia en una
--       transacción, en el orden que piden las dependencias, con bitácora.
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
-- La política de RLS de modulo (catálogo) para que la app lo lea igual.

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
-- 5) Ficha del proveedor: vista previa y aplicar (solo service_role)
--    p_cambios = {"modulos": {"ventas": true, "compras": false, ...},
--                 "perfil": "pequeno" | null, "licencia": {"vence_el": "2026-12-31", "dias_gracia": 5}}
--    Lo que no viene, no cambia.
-- ---------------------------------------------------------------------
-- Profundidad de un módulo en el árbol de dependencias (contabilidad = 0).
CREATE FUNCTION interno.nivel_modulo(p_modulo text) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH RECURSIVE r(m, n) AS (
    SELECT p_modulo, 0
    UNION ALL
    SELECT d.requiere, r.n + 1 FROM public.modulo_dependencia d JOIN r ON d.modulo = r.m WHERE r.n < 20)
  SELECT max(n) FROM r
$$;

CREATE FUNCTION interno.exigir_proveedor_llave() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NOT NULL OR coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'SIN_PERMISO: esto lo hace solo el proveedor con su conexión de instalación (herramientas/aplicar_ficha.sh).';
  END IF;
END $$;

CREATE FUNCTION interno.cambios_ficha(p_empresa_id uuid, p_cambios jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e         public.empresa;
  l         public.licencia;
  k         text;
  v_final   text[];
  v_act     jsonb := '[]';
  v_des     jsonb := '[]';
  v_err     jsonb := '[]';
  v_otros   jsonb := '[]';
  v_lic     jsonb;
  v_perfil  jsonb;
  v_vence   date;
  v_gracia  integer;
  r         record;
BEGIN
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la empresa no existe en esta base.';
  END IF;
  IF jsonb_typeof(p_cambios) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los cambios deben ser un objeto JSON.';
  END IF;
  PERFORM interno.exigir_claves(p_cambios, ARRAY['modulos', 'perfil', 'licencia']);

  -- Módulos: estado final = lo de hoy + lo que dice la ficha.
  SELECT coalesce(array_agg(m.modulo), '{}') INTO v_final FROM public.modulo_activo m WHERE m.empresa_id = p_empresa_id AND m.activo;
  IF coalesce(p_cambios->'modulos', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_cambios->'modulos') <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "modulos" es un objeto {"ventas": true, ...}.';
    END IF;
    FOR k IN SELECT jsonb_object_keys(p_cambios->'modulos') LOOP
      IF NOT EXISTS (SELECT 1 FROM public.modulo x WHERE x.codigo = k) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el módulo "%" no existe.', k;
      END IF;
      IF jsonb_typeof(p_cambios->'modulos'->k) <> 'boolean' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el módulo "%" va con true o false.', k;
      END IF;
      IF (p_cambios->'modulos'->>k)::boolean AND NOT k = ANY (v_final) THEN
        v_final := v_final || k;
      ELSIF NOT (p_cambios->'modulos'->>k)::boolean AND k = ANY (v_final) THEN
        v_final := array_remove(v_final, k);
      END IF;
    END LOOP;
    SELECT coalesce(jsonb_agg(m.codigo ORDER BY interno.nivel_modulo(m.codigo), m.codigo), '[]') INTO v_act
      FROM public.modulo m
     WHERE m.codigo = ANY (v_final) AND NOT public.modulo_esta_activo(p_empresa_id, m.codigo);
    SELECT coalesce(jsonb_agg(m.codigo ORDER BY interno.nivel_modulo(m.codigo) DESC, m.codigo), '[]') INTO v_des
      FROM public.modulo m
     WHERE NOT m.codigo = ANY (v_final) AND public.modulo_esta_activo(p_empresa_id, m.codigo);
    FOR r IN SELECT d.modulo, d.requiere FROM public.modulo_dependencia d
              WHERE d.modulo = ANY (v_final) AND NOT d.requiere = ANY (v_final) ORDER BY 1, 2 LOOP
      v_err := v_err || to_jsonb(format('El módulo "%s" necesita "%s": actívelo también o apague "%s".', r.modulo, r.requiere, r.modulo));
    END LOOP;
    IF (SELECT count(*) FROM unnest(v_final) x WHERE x LIKE 'fiscal\_%') > 1 THEN
      v_err := v_err || to_jsonb('Solo un régimen fiscal activo a la vez.'::text);
    END IF;
  END IF;

  -- Perfil.
  IF coalesce(p_cambios->'perfil', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_cambios->'perfil') <> 'string' THEN
      RAISE EXCEPTION 'PERFIL_INVALIDO: el perfil es pequeno, mediano o grande.';
    END IF;
    PERFORM interno.perfil_de(p_cambios->>'perfil');
    IF e.perfil IS DISTINCT FROM p_cambios->>'perfil' THEN
      v_perfil := jsonb_build_object('actual', e.perfil, 'nuevo', p_cambios->>'perfil',
        'detalle', interno.cambios_perfil(p_empresa_id, p_cambios->>'perfil'));
    END IF;
  END IF;

  -- Licencia.
  IF coalesce(p_cambios->'licencia', 'null'::jsonb) <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(p_cambios->'licencia', ARRAY['vence_el', 'dias_gracia']);
    v_vence := interno.json_fecha(p_cambios->'licencia'->'vence_el', 'vence_el');
    IF v_vence IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la licencia necesita "vence_el" (AAAA-MM-DD).';
    END IF;
    IF coalesce(p_cambios->'licencia'->'dias_gracia', 'null'::jsonb) <> 'null'::jsonb THEN
      IF jsonb_typeof(p_cambios->'licencia'->'dias_gracia') <> 'number'
         OR (p_cambios->'licencia'->>'dias_gracia') !~ '^[0-9]{1,2}$' OR (p_cambios->'licencia'->>'dias_gracia')::integer > 60 THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "dias_gracia" es un número entero de 0 a 60.';
      END IF;
      v_gracia := (p_cambios->'licencia'->>'dias_gracia')::integer;
    END IF;
    SELECT * INTO l FROM public.licencia x WHERE x.empresa_id = p_empresa_id;
    v_gracia := coalesce(v_gracia, l.dias_gracia, 5);
    IF (l.vence_el, l.dias_gracia) IS DISTINCT FROM (v_vence, v_gracia) THEN
      v_lic := jsonb_build_object('actual', CASE WHEN l.empresa_id IS NOT NULL THEN jsonb_build_object('vence_el', to_char(l.vence_el, 'YYYY-MM-DD'), 'dias_gracia', l.dias_gracia) END,
                                  'nuevo', jsonb_build_object('vence_el', to_char(v_vence, 'YYYY-MM-DD'), 'dias_gracia', v_gracia));
    END IF;
  END IF;

  RETURN jsonb_build_object('empresa_id', e.id, 'empresa', e.nombre,
    'modulos', jsonb_build_object('activar', v_act, 'desactivar', v_des,
                                  'quedan_activos', (SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') FROM unnest(v_final) x)),
    'perfil', v_perfil, 'licencia', v_lic, 'errores', v_err,
    'hay_cambios', jsonb_array_length(v_act) > 0 OR jsonb_array_length(v_des) > 0 OR v_perfil IS NOT NULL OR v_lic IS NOT NULL);
END $$;

-- RPC: vista_previa_ficha(empresa, cambios)   solo la llave del proveedor
CREATE FUNCTION public.vista_previa_ficha(p_empresa_id uuid, p_cambios jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_proveedor_llave();
  RETURN interno.cambios_ficha(p_empresa_id, p_cambios);
END $$;

-- RPC: aplicar_ficha(empresa, cambios, motivo)   solo la llave del proveedor
-- Todo o nada: apaga (los que dependen primero), activa (los necesarios
-- primero), perfil y licencia. Nunca borra datos. Bitácora con el motivo.
CREATE FUNCTION public.aplicar_ficha(p_empresa_id uuid, p_cambios jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v  jsonb;
  m  text;
BEGIN
  PERFORM interno.exigir_proveedor_llave();
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM 1 FROM public.empresa e WHERE e.id = p_empresa_id FOR UPDATE;
  v := interno.cambios_ficha(p_empresa_id, p_cambios);
  IF jsonb_array_length(v->'errores') > 0 THEN
    RAISE EXCEPTION 'MODULO_DEPENDENCIA: %', (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(v->'errores') x);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  FOR m IN SELECT jsonb_array_elements_text(v->'modulos'->'desactivar') LOOP
    UPDATE public.modulo_activo SET activo = false WHERE empresa_id = p_empresa_id AND modulo = m;
  END LOOP;
  FOR m IN SELECT jsonb_array_elements_text(v->'modulos'->'activar') LOOP
    INSERT INTO public.modulo_activo (empresa_id, modulo, activo) VALUES (p_empresa_id, m, true)
    ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  END LOOP;
  IF v->'perfil' <> 'null'::jsonb THEN
    PERFORM interno.guardar_perfil(p_empresa_id, v->'perfil'->>'nuevo');
  END IF;
  IF v->'licencia' <> 'null'::jsonb THEN
    INSERT INTO public.licencia (empresa_id, vence_el, dias_gracia)
    VALUES (p_empresa_id, (v->'licencia'->'nuevo'->>'vence_el')::date, (v->'licencia'->'nuevo'->>'dias_gracia')::integer)
    ON CONFLICT (empresa_id) DO UPDATE SET vence_el = excluded.vence_el, dias_gracia = excluded.dias_gracia, actualizado_en = now();
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN v || jsonb_build_object('aplicado', true);
END $$;

-- ---------------------------------------------------------------------
-- 6) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.marcar_estuvo_activo(),
  interno.revisar_dependencias_modulo(),
  interno.modulo_permite_apagado(uuid, text, text),
  interno.modulo_controla_cuenta(uuid, text),
  interno.nivel_modulo(text),
  interno.exigir_proveedor_llave(),
  interno.cambios_ficha(uuid, jsonb)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.vista_previa_ficha(uuid, jsonb),
  public.aplicar_ficha(uuid, jsonb, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.vista_previa_ficha(uuid, jsonb),
  public.aplicar_ficha(uuid, jsonb, text)
TO service_role;
