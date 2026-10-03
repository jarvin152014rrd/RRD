-- =====================================================================
-- 001_base.sql  -  Esquema base del núcleo
-- empresa, sucursal, caja, roles y permisos, usuarios por empresa,
-- módulos activos, licencia, contadores y control de migraciones.
--
-- Reglas que aplican a TODO el núcleo:
--   * Dinero en centavos (bigint). Nunca decimales para dinero.
--   * Nada se borra: se desactiva o se corrige con contra-asiento.
--   * El navegador solo lee (con RLS) y llama funciones (RPC).
--   * Funciones SECURITY DEFINER con search_path vacío ('') y nombres
--     completos (esquema.tabla) para que nadie pueda "colar" objetos.
-- =====================================================================

-- Esquema privado: no lo expone la API de Supabase.
CREATE SCHEMA IF NOT EXISTS interno;
REVOKE ALL ON SCHEMA interno FROM PUBLIC;

-- Nadie fuera del dueño de la base crea objetos en public.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Quitar los permisos "generosos" que Supabase da por defecto a lo que
-- se cree de aquí en adelante. Cada permiso se da a mano en 006.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- ---------------------------------------------------------------------
-- Control de migraciones (solo hacia adelante). Lo llena migrar.sh.
-- ---------------------------------------------------------------------
CREATE TABLE interno._migraciones (
  numero          integer PRIMARY KEY,
  nombre          text        NOT NULL,
  checksum        text        NOT NULL,          -- sha256 del archivo
  version_nucleo  text        NOT NULL,
  aplicada_en     timestamptz NOT NULL DEFAULT now(),
  aplicada_por    text        NOT NULL DEFAULT current_user
);

-- Vista pública con la versión actual (la app la puede mostrar).
CREATE VIEW public.version_esquema AS
  SELECT numero AS ultima_migracion, nombre, version_nucleo, aplicada_en
  FROM interno._migraciones
  ORDER BY numero DESC
  LIMIT 1;

-- ---------------------------------------------------------------------
-- Empresa, sucursal (establecimiento SAR) y caja (punto de emisión)
-- ---------------------------------------------------------------------
CREATE TABLE public.empresa (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre        text NOT NULL CHECK (length(trim(nombre)) > 0),
  rtn           text CHECK (rtn IS NULL OR rtn ~ '^[0-9]{14}$'),
  moneda        char(3) NOT NULL DEFAULT 'HNL',
  zona_horaria  text NOT NULL DEFAULT 'America/Tegucigalpa',
  creado_en     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.sucursal (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  codigo      text NOT NULL CHECK (codigo ~ '^[0-9]{3}$'),  -- establecimiento SAR: 001
  nombre      text NOT NULL,
  activa      boolean NOT NULL DEFAULT true,
  creado_en   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, codigo),
  UNIQUE (empresa_id, id)
);

CREATE TABLE public.caja (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id     uuid NOT NULL,
  sucursal_id    uuid NOT NULL,
  nombre         text NOT NULL,
  punto_emision  text NOT NULL CHECK (punto_emision ~ '^[0-9]{3}$'), -- para rangos CAI por caja
  activa         boolean NOT NULL DEFAULT true,
  creado_en      timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id),
  UNIQUE (sucursal_id, punto_emision)
);

-- ---------------------------------------------------------------------
-- Roles, permisos y la tabla editable rol x permiso (por empresa)
-- ---------------------------------------------------------------------
CREATE TABLE public.rol (
  codigo       text PRIMARY KEY,
  nombre       text NOT NULL,
  descripcion  text
);

INSERT INTO public.rol (codigo, nombre, descripcion) VALUES
  ('proveedor', 'Proveedor del sistema', 'Instala y actualiza. NO registra movimientos.'),
  ('dueno',     'Dueño',                 'Control total del negocio.'),
  ('admin',     'Administrador',         'Administra el día a día.'),
  ('cajero',    'Cajero',                'Cobra y maneja caja.'),
  ('vendedor',  'Vendedor',              'Vende.');

CREATE TABLE public.permiso (
  codigo         text PRIMARY KEY,
  descripcion    text NOT NULL,
  -- Si es true, el permiso mueve los libros. El rol proveedor NUNCA lo tiene.
  es_movimiento  boolean NOT NULL DEFAULT false
);

INSERT INTO public.permiso (codigo, descripcion, es_movimiento) VALUES
  ('asientos.registrar', 'Registrar asientos contables',          true),
  ('asientos.anular',    'Anular asientos (contra-asiento)',      true),
  ('periodos.cerrar',    'Cerrar un mes contable',                true),
  ('periodos.reabrir',   'Reabrir un mes contable cerrado',       true),
  ('contabilidad.ver',   'Ver asientos, saldos y reportes',       false),
  ('bitacora.ver',       'Ver la bitácora de auditoría',          false),
  ('permisos.editar',    'Cambiar los permisos de cada rol',      false);

-- Plantilla de permisos que recibe cada empresa nueva.
CREATE TABLE interno.plantilla_rol_permiso (
  rol      text NOT NULL REFERENCES public.rol(codigo),
  permiso  text NOT NULL REFERENCES public.permiso(codigo),
  PRIMARY KEY (rol, permiso)
);

INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'asientos.registrar'), ('dueno', 'asientos.anular'),
  ('dueno', 'periodos.cerrar'),    ('dueno', 'periodos.reabrir'),
  ('dueno', 'contabilidad.ver'),   ('dueno', 'bitacora.ver'),
  ('dueno', 'permisos.editar'),
  ('admin', 'asientos.registrar'), ('admin', 'asientos.anular'),
  ('admin', 'periodos.cerrar'),    ('admin', 'contabilidad.ver'),
  ('admin', 'bitacora.ver'),
  ('proveedor', 'bitacora.ver'),   ('proveedor', 'contabilidad.ver');

CREATE TABLE public.rol_permiso (
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  rol         text NOT NULL REFERENCES public.rol(codigo),
  permiso     text NOT NULL REFERENCES public.permiso(codigo),
  PRIMARY KEY (empresa_id, rol, permiso)
);

-- Usuario (de Supabase Auth) dentro de una empresa, con un rol.
CREATE TABLE public.usuario_empresa (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id),
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  rol         text NOT NULL REFERENCES public.rol(codigo),
  activo      boolean NOT NULL DEFAULT true,
  creado_en   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, empresa_id)
);

-- ---------------------------------------------------------------------
-- Módulos activos por empresa (revisados en el servidor)
-- ---------------------------------------------------------------------
CREATE TABLE public.modulo (
  codigo  text PRIMARY KEY,
  nombre  text NOT NULL
);

INSERT INTO public.modulo (codigo, nombre) VALUES
  ('contabilidad', 'Contabilidad (núcleo)'),
  ('ventas',       'Ventas y facturación'),
  ('inventario',   'Inventario'),
  ('compras',      'Compras');

CREATE TABLE public.modulo_activo (
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  modulo      text NOT NULL REFERENCES public.modulo(codigo),
  activo      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (empresa_id, modulo)
);

-- ---------------------------------------------------------------------
-- Licencia mensual. Solo service_role la escribe (ver 006).
-- ---------------------------------------------------------------------
CREATE TABLE public.licencia (
  empresa_id      uuid PRIMARY KEY REFERENCES public.empresa(id),
  vence_el        date    NOT NULL,
  dias_gracia     integer NOT NULL DEFAULT 5 CHECK (dias_gracia BETWEEN 0 AND 60),
  suspendida      boolean NOT NULL DEFAULT false,
  nota            text,
  actualizado_en  timestamptz NOT NULL DEFAULT now()
);

-- Contadores por empresa (número de asiento sin huecos, etc.).
-- El bloqueo de la fila ordena los registros simultáneos.
CREATE TABLE interno.contador (
  empresa_id  uuid   NOT NULL REFERENCES public.empresa(id),
  clave       text   NOT NULL,
  ultimo      bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (empresa_id, clave)
);

-- =====================================================================
-- Funciones de apoyo
-- =====================================================================

-- Fecha de hoy en Honduras (la base trabaja en UTC por dentro).
CREATE FUNCTION public.hoy_local() RETURNS date
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT (now() AT TIME ZONE 'America/Tegucigalpa')::date
$$;

-- Empresas del usuario que está conectado.
CREATE FUNCTION public.mis_empresas() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ue.empresa_id
  FROM public.usuario_empresa ue
  WHERE ue.user_id = auth.uid() AND ue.activo
$$;

-- Si el usuario tiene una sola empresa, esa es la "actual".
CREATE FUNCTION public.empresa_actual() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN count(*) = 1 THEN min(ue.empresa_id::text)::uuid END
  FROM public.usuario_empresa ue
  WHERE ue.user_id = auth.uid() AND ue.activo
$$;

-- Rol del usuario conectado en una empresa (NULL si no pertenece).
CREATE FUNCTION public.mi_rol(p_empresa_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ue.rol
  FROM public.usuario_empresa ue
  WHERE ue.user_id = auth.uid() AND ue.empresa_id = p_empresa_id AND ue.activo
$$;

-- ¿El usuario conectado tiene este permiso? Si no se da empresa,
-- usa la única empresa del usuario. El proveedor nunca tiene permisos
-- que muevan los libros, aunque alguien se los asigne.
CREATE FUNCTION public.tiene_permiso(p_codigo text, p_empresa_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuario_empresa ue
    JOIN public.rol_permiso rp ON rp.empresa_id = ue.empresa_id AND rp.rol = ue.rol
    JOIN public.permiso p      ON p.codigo = rp.permiso
    WHERE ue.user_id = auth.uid()
      AND ue.activo
      AND ue.empresa_id = coalesce(p_empresa_id, public.empresa_actual())
      AND rp.permiso = p_codigo
      AND NOT (ue.rol = 'proveedor' AND p.es_movimiento)
  )
$$;

-- ¿La licencia permite escribir? (vigente o dentro de los días de gracia)
CREATE FUNCTION public.licencia_activa(p_empresa_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.licencia l
    WHERE l.empresa_id = p_empresa_id
      AND NOT l.suspendida
      AND public.hoy_local() <= l.vence_el + l.dias_gracia
  )
$$;

CREATE FUNCTION public.modulo_esta_activo(p_empresa_id uuid, p_modulo text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.modulo_activo m
    WHERE m.empresa_id = p_empresa_id AND m.modulo = p_modulo AND m.activo
  )
$$;

-- Revisión común de TODA función que escribe. Lanza error si algo falla.
-- Orden: sesión -> pertenece a la empresa -> permiso -> licencia -> módulo.
CREATE FUNCTION interno.exigir_escritura(p_empresa_id uuid, p_permiso text, p_modulo text DEFAULT 'contabilidad')
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
  IF NOT public.licencia_activa(p_empresa_id) THEN
    RAISE EXCEPTION 'LICENCIA_VENCIDA: el sistema está en modo solo lectura. Puede consultar y exportar.';
  END IF;
  IF p_modulo IS NOT NULL AND NOT public.modulo_esta_activo(p_empresa_id, p_modulo) THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "%" no está activo para esta empresa.', p_modulo;
  END IF;
END $$;

-- Siguiente número de un contador (bloquea la fila hasta el fin de la transacción).
CREATE FUNCTION interno.siguiente_numero(p_empresa_id uuid, p_clave text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO interno.contador (empresa_id, clave) VALUES (p_empresa_id, p_clave)
  ON CONFLICT (empresa_id, clave) DO NOTHING;
  UPDATE interno.contador SET ultimo = ultimo + 1
   WHERE empresa_id = p_empresa_id AND clave = p_clave
  RETURNING ultimo INTO v;
  RETURN v;
END $$;
