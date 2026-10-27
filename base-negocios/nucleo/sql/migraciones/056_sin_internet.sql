-- =====================================================================
-- 056_sin_internet.sql  -  Núcleo 0.20.0: vender sin internet, etapa 1
-- (diseño aprobado: docs/SIN_INTERNET.md v2; códigos G1-G6, M1-M7).
--
-- El equipo (computadora o celular) ANOTA la venta y la SUBE después; el
-- servidor la vuelve a revisar toda y es quien la registra en los libros.
--
--   equipo               equipos registrados para vender sin internet (G3: se
--                        desactivan, nunca se borran).
--   numero_bloque        números (facturas CAI o tickets) reservados para una
--                        caja y un equipo (6.2). Mientras está activo, esa caja
--                        numera SOLO desde el bloque (BLOQUE_ACTIVO).
--   numero_emitido       cada número del bloque que se usó (único: nunca se
--                        repite), con su estado.
--   catalogo_foto        la foto versionada del catálogo que bajó el equipo (G5).
--   venta_sin_internet   todo lo que mandó el equipo; registrada o por resolver.
--
-- Funciones: registrar_equipo, desactivar_equipo, preparar_sin_internet,
-- reservar_bloque_numeros, devolver_bloque, subir_ventas_sin_internet,
-- ventas_sin_internet_por_resolver, resolver_venta_sin_internet,
-- conciliar_bloque, bloques_sin_internet. Detalle: nucleo/docs/sin_internet.md.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('EQUIPO_INVALIDO', 'Este equipo no está registrado para vender sin internet o fue desactivado.',
   'Prepare el equipo otra vez en Ajustes > Sin internet. Si el dueño lo desactivó, use otro equipo.'),
  ('BLOQUE_ACTIVO', 'Esta caja tiene números reservados para vender sin internet.',
   'Mientras la caja tenga números reservados, las ventas de contado se hacen desde el equipo que los tiene. Para lo demás (crédito, cotizaciones, cambios) use otra caja o devuelva los números en ese equipo.'),
  ('BLOQUE_SIN_DEVOLVER', 'El turno no se puede cerrar: su caja todavía tiene números reservados en un equipo.',
   'En ese equipo, conéctese para subir las ventas guardadas y cierre el turno desde ahí (los números se devuelven solos). Si el equipo se perdió, el dueño lo desactiva.'),
  ('BLOQUE_INVALIDO', 'Los números reservados no corresponden a este equipo o a esta caja.',
   'Prepare el equipo otra vez. Si el problema sigue, avise al dueño.'),
  ('FALTAN_VENTAS_POR_SUBIR', 'Todavía hay ventas sin internet de este equipo que no llegaron al servidor.',
   'Conéctese a internet y espere a que suban todas; después intente otra vez.'),
  ('VENTA_SIN_INTERNET_INVALIDA', 'Esa venta sin internet no se puede registrar así.',
   'Lea la razón. Si no se puede registrar, anúlela con motivo (el número queda anulado).');

-- ---------------------------------------------------------------------
-- 1) Permisos
-- ---------------------------------------------------------------------
INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('ventas.sin_internet', 'Vender de contado sin internet en un equipo preparado (lo da el dueño)', true, false),
  ('ventas.resolver_sin_internet', 'Ver y resolver las ventas sin internet por resolver (registrar o anular con motivo)', true, false),
  ('ventas.subir_ajenas', 'Subir las ventas sin internet que otro usuario dejó guardadas en un equipo', true, false),
  ('equipos.administrar', 'Desactivar un equipo perdido o dañado y conciliar sus números', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'ventas.sin_internet'), ('admin', 'ventas.sin_internet'),
  ('dueno', 'ventas.resolver_sin_internet'), ('admin', 'ventas.resolver_sin_internet'),
  ('dueno', 'ventas.subir_ajenas'),
  ('dueno', 'equipos.administrar');
SELECT interno.repartir_permisos(ARRAY['ventas.sin_internet', 'ventas.resolver_sin_internet', 'ventas.subir_ajenas',
                                       'equipos.administrar'], 'Núcleo 0.20.0: vender sin internet');

-- ---------------------------------------------------------------------
-- 2) Reglas de la empresa (las cambia el dueño con configurar_empresa)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa
  -- Horas que sirven los precios bajados al equipo (M4). Pasado ese tiempo no se vende sin internet.
  ADD COLUMN sin_internet_horas integer NOT NULL DEFAULT 24 CHECK (sin_internet_horas BETWEEN 1 AND 168),
  -- Tope de una venta sin internet y de lo vendido sin internet en un turno (o un bloque).
  ADD COLUMN sin_internet_tope_venta_centavos bigint NOT NULL DEFAULT 1000000
    CHECK (sin_internet_tope_venta_centavos BETWEEN 1 AND 9007199254740991),
  ADD COLUMN sin_internet_tope_turno_centavos bigint NOT NULL DEFAULT 5000000
    CHECK (sin_internet_tope_turno_centavos BETWEEN 1 AND 9007199254740991),
  -- Tarjeta sin internet: solo si el POS del banco funciona sin conexión. Apagado por defecto.
  ADD COLUMN sin_internet_tarjeta boolean NOT NULL DEFAULT false,
  -- Tamaño del bloque de números; NULL = el sugerido (1.5 veces las ventas de un día de esa caja).
  ADD COLUMN sin_internet_bloque integer CHECK (sin_internet_bloque BETWEEN 10 AND 5000);

-- ---------------------------------------------------------------------
-- 3) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.equipo (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id            uuid NOT NULL REFERENCES public.empresa(id),
  nombre                text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 60),
  activo                boolean NOT NULL DEFAULT true,
  registrado_por        uuid,
  registrado_en         timestamptz NOT NULL DEFAULT now(),
  desactivado_en        timestamptz,
  desactivado_por       uuid,
  motivo_desactivacion  text,
  id_operacion          uuid NOT NULL,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion),
  CHECK (activo = (desactivado_en IS NULL)),
  CHECK (activo OR length(trim(motivo_desactivacion)) >= 5)
);

-- Última noticia de cada equipo y la versión de la foto que tiene (sin bitácora: cambia cada 15 minutos).
CREATE TABLE interno.equipo_sync (
  equipo_id      uuid PRIMARY KEY REFERENCES public.equipo(id),
  ultima_en      timestamptz NOT NULL DEFAULT now(),
  foto_version   integer
);

CREATE TABLE public.numero_bloque (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                 uuid NOT NULL REFERENCES public.empresa(id),
  sucursal_id                uuid NOT NULL,
  caja_id                    uuid NOT NULL REFERENCES public.caja(id),
  equipo_id                  uuid NOT NULL,
  turno_id                   uuid REFERENCES public.turno_caja(id),
  tipo                       text NOT NULL CHECK (tipo IN ('factura', 'ticket')),
  cai_rango_id               uuid REFERENCES public.cai_rango(id),
  serie                      text NOT NULL,          -- 'cai:<rango>' o 'ticket:<caja>' (los números no se repiten en una serie)
  prefijo                    text NOT NULL,          -- '001-001-01' (factura) o 'T-001-001' (ticket)
  desde                      bigint NOT NULL CHECK (desde BETWEEN 1 AND 99999999),
  hasta                      bigint NOT NULL CHECK (hasta BETWEEN 1 AND 99999999),
  siguiente                  bigint NOT NULL,        -- el siguiente que el servidor todavía no conoce
  ultima_hora_equipo         timestamptz,
  reservado_en               timestamptz NOT NULL DEFAULT now(),
  reservado_por              uuid,
  vence_en                   timestamptz,            -- fecha límite del CAI (el bloque dura hasta cerrar el turno)
  estado                     text NOT NULL DEFAULT 'activo' CHECK (estado IN ('activo', 'devuelto', 'por_conciliar', 'conciliado')),
  devuelto_desde             bigint,                 -- desde ahí el equipo ya no numera (el servidor los usa primero)
  devuelto_en                timestamptz,
  devuelto_por               uuid,
  devolucion_id_operacion    uuid,
  por_conciliar_en           timestamptz,
  motivo_por_conciliar       text,
  conciliado_en              timestamptz,
  conciliado_por             uuid,
  motivo_conciliacion        text,
  conciliacion_id_operacion  uuid,
  id_operacion               uuid NOT NULL,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion, tipo),
  UNIQUE (empresa_id, devolucion_id_operacion),
  UNIQUE (empresa_id, conciliacion_id_operacion),
  FOREIGN KEY (empresa_id, equipo_id) REFERENCES public.equipo(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id),
  CHECK (desde <= hasta),
  CHECK (siguiente BETWEEN desde AND hasta + 1),
  CHECK ((tipo = 'factura') = (cai_rango_id IS NOT NULL))
);
CREATE INDEX numero_bloque_caja ON public.numero_bloque (caja_id, tipo, estado);
CREATE INDEX numero_bloque_equipo ON public.numero_bloque (equipo_id, estado);
-- Un solo bloque activo por caja y tipo de documento.
CREATE UNIQUE INDEX numero_bloque_un_activo ON public.numero_bloque (caja_id, tipo) WHERE estado = 'activo';

CREATE TABLE public.numero_emitido (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  bloque_id                uuid NOT NULL,
  serie                    text NOT NULL,
  numero                   bigint NOT NULL,
  numero_documento         text NOT NULL,
  venta_id                 uuid,
  venta_sin_internet_id    uuid,
  estado                   text NOT NULL CHECK (estado IN ('registrado', 'por_resolver', 'anulado', 'no_usado')),
  creado_en                timestamptz NOT NULL DEFAULT now(),
  actualizado_en           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, serie, numero),
  FOREIGN KEY (empresa_id, bloque_id) REFERENCES public.numero_bloque(empresa_id, id)
);
CREATE INDEX numero_emitido_bloque ON public.numero_emitido (bloque_id, numero);

CREATE TABLE public.catalogo_foto (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id    uuid NOT NULL REFERENCES public.empresa(id),
  sucursal_id   uuid NOT NULL,
  version       integer NOT NULL,
  huella        text NOT NULL,
  contenido     jsonb NOT NULL CHECK (jsonb_typeof(contenido) = 'object'),
  creado_por    uuid,
  creado_en     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, version),
  UNIQUE (empresa_id, sucursal_id, huella),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id)
);

-- G5: qué foto se entregó a qué equipo (a nombre de ese equipo).
CREATE TABLE public.catalogo_entrega (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id    uuid NOT NULL REFERENCES public.empresa(id),
  equipo_id     uuid NOT NULL,
  foto_id       uuid NOT NULL REFERENCES public.catalogo_foto(id),
  entregado_a   uuid,
  entregado_en  timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, equipo_id) REFERENCES public.equipo(empresa_id, id)
);
CREATE INDEX catalogo_entrega_equipo ON public.catalogo_entrega (equipo_id, id);

CREATE TABLE public.venta_sin_internet (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                uuid NOT NULL REFERENCES public.empresa(id),
  sucursal_id               uuid,
  caja_id                   uuid,
  equipo_id                 uuid NOT NULL,
  usuario_id                uuid NOT NULL,
  id_operacion              uuid NOT NULL,
  bloque_id                 uuid,
  numero                    bigint,
  numero_documento          text,
  tipo_documento            text,
  foto_version              integer,
  total_centavos            bigint,
  en_linea                  boolean NOT NULL DEFAULT false,   -- la mandó la cola con internet (G2)
  hora_equipo               timestamptz,
  recibido_en               timestamptz NOT NULL DEFAULT now(),
  payload                   jsonb NOT NULL,                   -- todo lo que mandó el equipo
  estado                    text NOT NULL CHECK (estado IN ('registrada', 'por_resolver', 'resuelta', 'anulada')),
  problema                  text,
  problema_texto            text,
  grave                     boolean NOT NULL DEFAULT false,
  negativo                  boolean NOT NULL DEFAULT false,   -- dejó inventario en negativo
  venta_id                  uuid,
  subido_por                uuid,
  motivo_subida             text,
  resuelto_por              uuid,
  resuelto_en               timestamptz,
  motivo_resolucion         text,
  resolucion_id_operacion   uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion),
  UNIQUE (empresa_id, resolucion_id_operacion),
  FOREIGN KEY (empresa_id, equipo_id) REFERENCES public.equipo(empresa_id, id),
  FOREIGN KEY (empresa_id, venta_id) REFERENCES public.venta(empresa_id, id),
  CHECK ((estado = 'por_resolver') = (problema IS NOT NULL AND resuelto_en IS NULL) OR estado IN ('resuelta', 'anulada')),
  CHECK (estado NOT IN ('registrada', 'resuelta') OR venta_id IS NOT NULL),
  CHECK (estado NOT IN ('resuelta', 'anulada') OR length(trim(motivo_resolucion)) >= 5)
);
CREATE INDEX venta_sin_internet_estado ON public.venta_sin_internet (empresa_id, estado);
CREATE INDEX venta_sin_internet_bloque ON public.venta_sin_internet (bloque_id, numero);

-- Protecciones: nada se borra; solo cambia lo que debe cambiar y hacia adelante.
CREATE FUNCTION interno.proteger_equipo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.registrado_por, NEW.registrado_en, NEW.id_operacion)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.registrado_por, OLD.registrado_en, OLD.id_operacion) THEN
    RAISE EXCEPTION 'PROHIBIDO: el registro de un equipo no se edita.';
  END IF;
  IF NOT OLD.activo AND NEW.activo THEN
    RAISE EXCEPTION 'PROHIBIDO: un equipo desactivado no se vuelve a activar; registre el equipo otra vez.';
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION interno.proteger_numero_bloque() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.caja_id, NEW.equipo_id, NEW.tipo, NEW.cai_rango_id, NEW.serie, NEW.prefijo, NEW.desde,
      NEW.hasta, NEW.reservado_en, NEW.reservado_por, NEW.id_operacion)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.caja_id, OLD.equipo_id, OLD.tipo, OLD.cai_rango_id, OLD.serie, OLD.prefijo,
      OLD.desde, OLD.hasta, OLD.reservado_en, OLD.reservado_por, OLD.id_operacion) THEN
    RAISE EXCEPTION 'PROHIBIDO: un bloque de números no se edita.';
  END IF;
  IF NEW.siguiente < OLD.siguiente THEN
    RAISE EXCEPTION 'PROHIBIDO: el siguiente número de un bloque nunca va hacia atrás.';
  END IF;
  IF OLD.estado <> NEW.estado AND NOT (
       (OLD.estado = 'activo' AND NEW.estado IN ('devuelto', 'por_conciliar'))
    OR (OLD.estado = 'devuelto' AND NEW.estado = 'por_conciliar')
    OR (OLD.estado = 'por_conciliar' AND NEW.estado = 'conciliado')) THEN
    RAISE EXCEPTION 'PROHIBIDO: un bloque no pasa de "%" a "%".', OLD.estado, NEW.estado;
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION interno.proteger_numero_emitido() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.bloque_id, NEW.serie, NEW.numero, NEW.numero_documento, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.bloque_id, OLD.serie, OLD.numero, OLD.numero_documento, OLD.creado_en)
     OR (OLD.venta_id IS NOT NULL AND NEW.venta_id IS DISTINCT FROM OLD.venta_id) THEN
    RAISE EXCEPTION 'PROHIBIDO: un número emitido no se edita.';
  END IF;
  IF OLD.estado <> NEW.estado AND NOT (OLD.estado = 'por_resolver' AND NEW.estado IN ('registrado', 'anulado')) THEN
    RAISE EXCEPTION 'PROHIBIDO: un número "%" no pasa a "%".', OLD.estado, NEW.estado;
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;

CREATE FUNCTION interno.proteger_venta_sin_internet() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.equipo_id, NEW.usuario_id, NEW.id_operacion, NEW.bloque_id, NEW.numero, NEW.numero_documento,
      NEW.total_centavos, NEW.hora_equipo, NEW.recibido_en, NEW.payload, NEW.subido_por)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.equipo_id, OLD.usuario_id, OLD.id_operacion, OLD.bloque_id, OLD.numero,
      OLD.numero_documento, OLD.total_centavos, OLD.hora_equipo, OLD.recibido_en, OLD.payload, OLD.subido_por) THEN
    RAISE EXCEPTION 'PROHIBIDO: lo que mandó el equipo no se edita.';
  END IF;
  IF OLD.estado <> 'por_resolver' OR NEW.estado NOT IN ('resuelta', 'anulada') THEN
    RAISE EXCEPTION 'PROHIBIDO: solo una venta sin internet por resolver se resuelve (registrar o anular), una vez.';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER proteger BEFORE UPDATE ON public.equipo FOR EACH ROW EXECUTE FUNCTION interno.proteger_equipo();
CREATE TRIGGER proteger BEFORE UPDATE ON public.numero_bloque FOR EACH ROW EXECUTE FUNCTION interno.proteger_numero_bloque();
CREATE TRIGGER proteger BEFORE UPDATE ON public.numero_emitido FOR EACH ROW EXECUTE FUNCTION interno.proteger_numero_emitido();
CREATE TRIGGER proteger BEFORE UPDATE ON public.catalogo_foto
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Una foto del catálogo no se edita.');
CREATE TRIGGER proteger BEFORE UPDATE ON public.catalogo_entrega
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La entrega de una foto del catálogo no se edita.');
CREATE TRIGGER proteger BEFORE UPDATE ON public.venta_sin_internet
  FOR EACH ROW EXECUTE FUNCTION interno.proteger_venta_sin_internet();
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['equipo', 'numero_bloque', 'numero_emitido', 'catalogo_foto', 'catalogo_entrega', 'venta_sin_internet'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'Lo de vender sin internet no se borra.');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
REVOKE ALL ON interno.equipo_sync FROM PUBLIC, anon, authenticated, service_role;

-- Lectura (las RPC hacen el resto): quien vende sin internet ve los equipos y bloques; quien resuelve ve todo.
CREATE POLICY leer ON public.equipo FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.sin_internet')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.resolver_sin_internet')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('equipos.administrar'))));
CREATE POLICY leer ON public.numero_bloque FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.sin_internet')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.resolver_sin_internet')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('equipos.administrar'))));
CREATE POLICY por_sucursal ON public.numero_bloque AS RESTRICTIVE FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_sin_restriccion()))
         OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())));
CREATE POLICY leer ON public.numero_emitido FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.resolver_sin_internet')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('equipos.administrar'))));
CREATE POLICY leer ON public.catalogo_foto FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.resolver_sin_internet'))));
CREATE POLICY leer ON public.catalogo_entrega FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.resolver_sin_internet'))));
CREATE POLICY leer ON public.venta_sin_internet FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.resolver_sin_internet')))
         OR usuario_id = auth.uid());
CREATE POLICY por_sucursal ON public.venta_sin_internet AS RESTRICTIVE FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_sin_restriccion()))
         OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())));

-- El id_operacion de una venta sin internet es el de la venta (G2: un reintento por registrar_venta o
-- por la cola se reconoce como la misma venta).
INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('equipo',             'id_operacion',              'registro_equipo',               98),
  ('numero_bloque',      'id_operacion',              'reserva_bloque',                99),
  ('numero_bloque',      'devolucion_id_operacion',   'devolucion_bloque',             100),
  ('numero_bloque',      'conciliacion_id_operacion', 'conciliacion_bloque',           101),
  ('venta_sin_internet', 'id_operacion',              'venta',                         102),
  ('venta_sin_internet', 'resolucion_id_operacion',   'resolucion_venta_sin_internet', 103);

-- ---------------------------------------------------------------------
-- 4) G5: la foto del catálogo. Mientras se calcula una venta sin internet,
--    app.foto_venta (local a la transacción) trae los datos de la foto de
--    los productos de esa venta; los ayudantes del cálculo los usan en vez
--    de los de hoy. Así interno.calcular_venta es la MISMA regla siempre.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.foto_venta() RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT nullif(current_setting('app.foto_venta', true), '')::jsonb
$$;

-- Catálogo de una sucursal tal como lo usa el cálculo de la venta (sin costos ni existencias).
CREATE FUNCTION interno.armar_catalogo(p_empresa_id uuid, p_sucursal_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH RECURSIVE
  anc(cat, ancestro, nivel) AS (
    SELECT c.id, c.id, 1 FROM public.categoria_producto c WHERE c.empresa_id = p_empresa_id
    UNION ALL
    SELECT anc.cat, c.padre_id, anc.nivel + 1 FROM anc JOIN public.categoria_producto c ON c.id = anc.ancestro
     WHERE c.padre_id IS NOT NULL AND anc.nivel < 5),
  pr AS (
    SELECT x.* FROM public.promocion x
     WHERE x.empresa_id = p_empresa_id AND x.activa AND x.fecha_fin >= public.hoy_local(p_empresa_id)),
  prod AS (
    SELECT p.id, p.codigo, p.codigo_barras, p.nombre, u.codigo AS unidad, p.permite_fracciones, p.tipo, p.categoria_id,
           p.tipo_impuesto,
           coalesce(ps.precio_venta_centavos, p.precio_venta_centavos) AS precio,
           coalesce(ps.precio_incluye_isv, p.precio_incluye_isv) AS incluye,
           p.precio_mayorista_centavos, p.cantidad_mayorista, p.precio_incluye_isv AS may_incluye
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      LEFT JOIN public.producto_precio_sucursal ps ON ps.producto_id = p.id AND ps.sucursal_id = p_sucursal_id AND ps.activo
            AND (SELECT e.precios_por_sucursal FROM public.empresa e WHERE e.id = p_empresa_id)
     WHERE p.empresa_id = p_empresa_id AND p.activo)
  SELECT jsonb_build_object(
    'productos', coalesce((SELECT jsonb_object_agg(prod.id::text, jsonb_build_object(
        'codigo', prod.codigo, 'codigo_barras', prod.codigo_barras, 'nombre', prod.nombre, 'unidad', prod.unidad,
        'permite_fracciones', prod.permite_fracciones, 'tipo', prod.tipo, 'tipo_impuesto', prod.tipo_impuesto,
        'precio_venta_centavos', prod.precio, 'precio_incluye_isv', prod.incluye,
        'precio_mayorista_centavos', prod.precio_mayorista_centavos, 'cantidad_mayorista', prod.cantidad_mayorista,
        'mayorista_incluye', prod.may_incluye,
        'promos', (SELECT coalesce(jsonb_agg(pr.id ORDER BY pr.id), '[]') FROM pr
                    WHERE pr.categoria_id IN (SELECT anc.ancestro FROM anc WHERE anc.cat = prod.categoria_id))))
      FROM prod), '{}'),
    'impuestos', coalesce((SELECT jsonb_object_agg(i.codigo, jsonb_build_object('nombre', i.nombre, 'porcentaje', i.porcentaje,
        'clase', i.clase)) FROM public.impuesto i WHERE i.empresa_id = p_empresa_id), '{}'),
    'promociones', coalesce((SELECT jsonb_object_agg(pr.id::text, jsonb_build_object('nombre', pr.nombre, 'tipo', pr.tipo,
        'porcentaje', pr.porcentaje, 'monto_centavos', pr.monto_centavos,
        'fecha_inicio', to_char(pr.fecha_inicio, 'YYYY-MM-DD'), 'fecha_fin', to_char(pr.fecha_fin, 'YYYY-MM-DD'),
        'creado_en', to_char(pr.creado_en AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'))) FROM pr), '{}'),
    'mayoristas', coalesce((SELECT jsonb_agg(t.id::text ORDER BY t.id) FROM public.tercero t
        WHERE t.empresa_id = p_empresa_id AND t.es_cliente AND t.es_mayorista), '[]'))
$$;

-- Lo de la foto que necesita UNA venta (solo sus productos): para app.foto_venta.
CREATE FUNCTION interno.foto_de_venta(p_contenido jsonb, p_lineas jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'productos', coalesce((SELECT jsonb_object_agg(k, p_contenido->'productos'->k)
                             FROM (SELECT DISTINCT l->>'producto_id' AS k FROM jsonb_array_elements(p_lineas) l) q
                            WHERE p_contenido->'productos' ? k), '{}'),
    'impuestos', coalesce(p_contenido->'impuestos', '{}'),
    'promociones', coalesce(p_contenido->'promociones', '{}'),
    'mayoristas', coalesce(p_contenido->'mayoristas', '[]'))
$$;

-- producto_de (reemplaza la de 047; misma firma): con una foto, el precio, el impuesto y el mayorista son los de la foto
-- (y un producto desactivado después de bajar la foto se acepta: ya se vendió).
CREATE OR REPLACE FUNCTION interno.producto_de(p_empresa_id uuid, p_valor jsonb, p_linea integer, p_activo boolean)
RETURNS public.producto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p     public.producto;
  ps    public.producto_precio_sucursal;
  v_suc uuid := nullif(current_setting('app.sucursal_venta', true), '')::uuid;
  v_f   jsonb := interno.foto_venta();
  v_x   jsonb;
BEGIN
  SELECT * INTO p FROM public.producto x
   WHERE x.empresa_id = p_empresa_id AND x.id = interno.json_uuid(p_valor, 'producto_id');
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'PRODUCTO_INVALIDO: el producto de la línea % no existe en esta empresa.', p_linea;
  END IF;
  IF v_f IS NOT NULL THEN
    v_x := v_f->'productos'->(p.id::text);
    IF v_x IS NULL THEN
      RAISE EXCEPTION 'PRODUCTO_INVALIDO: el producto % (línea %) no estaba en los precios guardados en el equipo.', p.codigo, p_linea;
    END IF;
    p.precio_venta_centavos := (v_x->>'precio_venta_centavos')::bigint;
    p.precio_incluye_isv := (v_x->>'precio_incluye_isv')::boolean;
    p.tipo_impuesto := v_x->>'tipo_impuesto';
    p.precio_mayorista_centavos := (v_x->>'precio_mayorista_centavos')::bigint;
    p.cantidad_mayorista := (v_x->>'cantidad_mayorista')::numeric;
    RETURN p;
  END IF;
  IF p_activo AND NOT p.activo THEN
    RAISE EXCEPTION 'PRODUCTO_INVALIDO: el producto % (línea %) está desactivado.', p.codigo, p_linea;
  END IF;
  IF v_suc IS NOT NULL THEN
    SELECT x.* INTO ps FROM public.producto_precio_sucursal x JOIN public.empresa e ON e.id = x.empresa_id
     WHERE x.producto_id = p.id AND x.sucursal_id = v_suc AND x.activo AND e.precios_por_sucursal;
    IF ps.id IS NOT NULL THEN
      p.precio_venta_centavos := ps.precio_venta_centavos;
      p.precio_incluye_isv := ps.precio_incluye_isv;
    END IF;
  END IF;
  RETURN p;
END $$;

-- impuesto_de (reemplaza la de 026; misma firma): con una foto, la tasa y la clase son las de la foto.
CREATE OR REPLACE FUNCTION interno.impuesto_de(p_empresa_id uuid, p_codigo text, p_activo boolean DEFAULT false) RETURNS public.impuesto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  i   public.impuesto;
  v_x jsonb := interno.foto_venta()->'impuestos'->p_codigo;
BEGIN
  SELECT * INTO i FROM public.impuesto x WHERE x.empresa_id = p_empresa_id AND x.codigo = p_codigo;
  IF v_x IS NOT NULL THEN
    i.empresa_id := p_empresa_id;
    i.codigo := p_codigo;
    i.nombre := coalesce(i.nombre, v_x->>'nombre');
    i.porcentaje := (v_x->>'porcentaje')::numeric;
    i.clase := v_x->>'clase';
    RETURN i;
  END IF;
  IF i.codigo IS NULL OR (p_activo AND NOT i.activo) THEN
    RAISE EXCEPTION 'IMPUESTO_INVALIDO: el impuesto "%" no existe en la empresa o está desactivado.', coalesce(p_codigo, '');
  END IF;
  RETURN i;
END $$;

-- promociones_de (reemplaza la de 031; misma firma y misma cuenta): con una foto, las promociones de la foto.
CREATE OR REPLACE FUNCTION interno.promociones_de(p_empresa_id uuid, p public.producto, p_fecha date, p_cantidad numeric) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_f jsonb := interno.foto_venta();
BEGIN
  IF v_f IS NOT NULL THEN
    RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('promocion_id', x.id, 'nombre', x.nombre, 'tipo', x.tipo,
              'porcentaje', x.porcentaje, 'monto_centavos', x.monto_centavos, 'descuento_centavos', x.d)
              ORDER BY x.d DESC, x.creado, x.id), '[]')
      FROM (SELECT (pid #>> '{}')::uuid AS id, pr->>'nombre' AS nombre, pr->>'tipo' AS tipo,
                   (pr->>'porcentaje')::numeric AS porcentaje, (pr->>'monto_centavos')::bigint AS monto_centavos,
                   pr->>'creado_en' AS creado,
                   CASE pr->>'tipo' WHEN 'porcentaje'
                        THEN round(round(p_cantidad * p.precio_venta_centavos) * (pr->>'porcentaje')::numeric / 100)::bigint
                        ELSE least(round(p_cantidad * p.precio_venta_centavos)::bigint,
                                   round(p_cantidad * (pr->>'monto_centavos')::bigint)::bigint) END AS d
              FROM jsonb_array_elements(coalesce(v_f->'productos'->(p.id::text)->'promos', '[]')) pid
              CROSS JOIN LATERAL (SELECT v_f->'promociones'->(pid #>> '{}') AS pr) z
             WHERE z.pr IS NOT NULL AND p_fecha BETWEEN (z.pr->>'fecha_inicio')::date AND (z.pr->>'fecha_fin')::date) x);
  END IF;
  RETURN (
    WITH RECURSIVE cats(id, padre_id, nivel) AS (
      SELECT c.id, c.padre_id, 1 FROM public.categoria_producto c WHERE c.id = p.categoria_id
      UNION ALL
      SELECT c.id, c.padre_id, cats.nivel + 1 FROM public.categoria_producto c JOIN cats ON c.id = cats.padre_id WHERE cats.nivel < 5),
    x AS (
      SELECT pr.id, pr.nombre, pr.tipo, pr.porcentaje, pr.monto_centavos, pr.creado_en,
             CASE pr.tipo WHEN 'porcentaje' THEN round(round(p_cantidad * p.precio_venta_centavos) * pr.porcentaje / 100)::bigint
                          ELSE least(round(p_cantidad * p.precio_venta_centavos)::bigint, round(p_cantidad * pr.monto_centavos)::bigint) END AS d
        FROM public.promocion pr
       WHERE pr.empresa_id = p_empresa_id AND pr.activa AND p_fecha BETWEEN pr.fecha_inicio AND pr.fecha_fin
         AND pr.categoria_id IN (SELECT cats.id FROM cats))
    SELECT coalesce(jsonb_agg(jsonb_build_object('promocion_id', x.id, 'nombre', x.nombre, 'tipo', x.tipo,
             'porcentaje', x.porcentaje, 'monto_centavos', x.monto_centavos, 'descuento_centavos', x.d)
             ORDER BY x.d DESC, x.creado_en, x.id), '[]')
      FROM x);
END $$;

-- mayorista_de (reemplaza la de 054; misma firma): con una foto, el precio mayorista y "desde cantidad" de la foto.
CREATE OR REPLACE FUNCTION interno.mayorista_de(p public.producto, p_tasa numeric, p_cantidad numeric, p_cliente_mayorista boolean,
                                     OUT o_aplica boolean, OUT o_precio bigint, OUT o_incluye boolean,
                                     OUT o_cantidad numeric, OUT o_mas_barato boolean, OUT o_por text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_f jsonb := interno.foto_venta();
BEGIN
  IF v_f IS NOT NULL THEN
    o_precio := (v_f->'productos'->(p.id::text)->>'precio_mayorista_centavos')::bigint;
    o_incluye := (v_f->'productos'->(p.id::text)->>'mayorista_incluye')::boolean;
    o_cantidad := (v_f->'productos'->(p.id::text)->>'cantidad_mayorista')::numeric;
  ELSE
    SELECT x.precio_mayorista_centavos, x.precio_incluye_isv, x.cantidad_mayorista INTO o_precio, o_incluye, o_cantidad
      FROM public.producto x WHERE x.id = p.id;
  END IF;
  o_aplica := false;
  o_mas_barato := false;
  IF o_precio IS NULL THEN
    RETURN;
  END IF;
  o_mas_barato := (public.precio_con_tasa(o_precio, o_incluye, coalesce(p_tasa, 0), 1)).con_isv_centavos
                < (public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, coalesce(p_tasa, 0), 1)).con_isv_centavos;
  o_por := CASE WHEN p_cliente_mayorista THEN 'cliente'
                WHEN o_cantidad IS NOT NULL AND p_cantidad >= o_cantidad THEN 'cantidad' END;
  o_aplica := o_mas_barato AND o_por IS NOT NULL;
END $$;

-- cliente_venta_mayorista (reemplaza la de 054): con una foto, si el cliente era mayorista en la foto.
CREATE OR REPLACE FUNCTION interno.cliente_venta_mayorista(p_empresa_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN interno.foto_venta() IS NOT NULL
              THEN coalesce(interno.foto_venta()->'mayoristas' ? nullif(current_setting('app.cliente_venta', true), ''), false)
              ELSE coalesce((SELECT t.es_mayorista FROM public.tercero t
                              WHERE t.empresa_id = p_empresa_id AND t.es_cliente
                                AND t.id::text = nullif(current_setting('app.cliente_venta', true), '')), false) END
$$;

-- mayorista_de_linea (reemplaza la de 055): una línea vendida sin internet guarda el "desde cantidad" de la foto.
CREATE OR REPLACE FUNCTION interno.mayorista_de_linea() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_f jsonb := interno.foto_venta();
BEGIN
  IF NEW.precio_tipo = 'mayorista' AND v_f IS NOT NULL THEN
    NEW.mayorista_por := CASE WHEN v_f->'mayoristas' ? (SELECT v.cliente_id::text FROM public.venta v WHERE v.id = NEW.venta_id)
                              THEN 'cliente' ELSE 'cantidad' END;
    NEW.mayorista_desde := (v_f->'productos'->(NEW.producto_id::text)->>'cantidad_mayorista')::numeric;
  ELSIF NEW.precio_tipo = 'mayorista' THEN
    NEW.mayorista_por := CASE WHEN EXISTS (SELECT 1 FROM public.venta v JOIN public.tercero t ON t.id = v.cliente_id
                                            WHERE v.id = NEW.venta_id AND t.es_cliente AND t.es_mayorista)
                              THEN 'cliente' ELSE 'cantidad' END;
    SELECT p.cantidad_mayorista INTO NEW.mayorista_desde FROM public.producto p WHERE p.id = NEW.producto_id;
  ELSE
    NEW.mayorista_por := NULL;
    NEW.mayorista_desde := NULL;
  END IF;
  RETURN NEW;
END $$;

-- Existencia negativa: una venta sin internet se registra igual (la mercadería ya salió) y queda la alerta.
CREATE OR REPLACE FUNCTION interno.permite_negativo(p_empresa_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT e.permite_existencia_negativa FROM public.empresa e WHERE e.id = p_empresa_id), false)
      OR public.tiene_permiso('inventario.negativo', p_empresa_id)
      OR coalesce(current_setting('app.sin_internet', true), '') = '1'
$$;

-- ---------------------------------------------------------------------
-- 5) Numeración (6.3, G4)
-- ---------------------------------------------------------------------
-- El candado de cai_rango acepta que ultimo_numero salte al final de un bloque SOLO si lo marca
-- reservar_bloque_numeros (app.reserva_bloque) y el bloque ya está guardado.
CREATE OR REPLACE FUNCTION interno.proteger_cai_rango() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (to_jsonb(NEW) - 'ultimo_numero' - 'ultima_fecha_emision' - 'activo')
     IS DISTINCT FROM (to_jsonb(OLD) - 'ultimo_numero' - 'ultima_fecha_emision' - 'activo') THEN
    RAISE EXCEPTION 'PROHIBIDO: un rango de CAI no se edita; si está mal, desactívelo y registre el correcto.';
  END IF;
  IF NEW.ultimo_numero NOT IN (OLD.ultimo_numero, OLD.ultimo_numero + 1) THEN
    IF NOT (NEW.ultimo_numero > OLD.ultimo_numero
            AND coalesce(current_setting('app.reserva_bloque', true), '') = OLD.id::text
            AND EXISTS (SELECT 1 FROM public.numero_bloque b
                         WHERE b.cai_rango_id = OLD.id AND b.hasta = NEW.ultimo_numero AND b.estado = 'activo')) THEN
      RAISE EXCEPTION 'PROHIBIDO: el correlativo del CAI avanza de uno en uno y nunca hacia atrás.';
    END IF;
  END IF;
  IF NEW.ultima_fecha_emision < OLD.ultima_fecha_emision THEN
    RAISE EXCEPTION 'PROHIBIDO: los documentos de un rango van en orden de fecha.';
  END IF;
  RETURN NEW;
END $$;

-- Número formateado de un bloque.
CREATE FUNCTION interno.numero_de_bloque(b public.numero_bloque, p_numero bigint) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT b.prefijo || '-' || lpad(p_numero::text, 8, '0')
$$;

ALTER FUNCTION interno.asignar_numero_fiscal(uuid, uuid, text, date) RENAME TO asignar_numero_fiscal_027;
-- asignar_numero_fiscal (misma firma):
--   * número que puso el equipo (app.numero_bloque, lo anota la subida): se usa ese, del rango de su bloque;
--   * la caja tiene un bloque activo: BLOQUE_ACTIVO (esa caja numera solo desde el bloque);
--   * números devueltos por el mismo equipo y nada emitido después: se usan primero, de uno en uno;
--   * si no, como siempre (sigue después del bloque).
CREATE FUNCTION interno.asignar_numero_fiscal(p_empresa_id uuid, p_caja_id uuid, p_tipo text, p_fecha date,
                                              OUT o_rango public.cai_rango, OUT o_numero text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_pre jsonb := nullif(current_setting('app.numero_bloque', true), '')::jsonb;
  v_hoy date := public.hoy_local(p_empresa_id);
  v_n   bigint;
  b     public.numero_bloque;
  rf    record;
BEGIN
  IF p_tipo = 'factura' AND v_pre IS NOT NULL THEN
    v_n := (v_pre->>'numero')::bigint;
    SELECT * INTO b FROM public.numero_bloque x
     WHERE x.id = (v_pre->>'bloque_id')::uuid AND x.empresa_id = p_empresa_id AND x.caja_id = p_caja_id AND x.tipo = 'factura';
    IF b.id IS NULL OR v_n IS NULL OR v_n NOT BETWEEN b.desde AND b.hasta THEN
      RAISE EXCEPTION 'BLOQUE_INVALIDO: el número % no es de un bloque de facturas de esta caja.', coalesce(v_pre->>'numero', '?');
    END IF;
    SELECT * INTO o_rango FROM public.cai_rango r WHERE r.id = b.cai_rango_id FOR UPDATE;
    IF p_fecha > o_rango.fecha_limite_emision THEN
      RAISE EXCEPTION 'CAI_VENCIDO: la venta es del %, después de la fecha límite del CAI (%).',
        to_char(p_fecha, 'DD/MM/YYYY'), to_char(o_rango.fecha_limite_emision, 'DD/MM/YYYY');
    END IF;
    UPDATE public.cai_rango SET ultima_fecha_emision = greatest(coalesce(ultima_fecha_emision, p_fecha), p_fecha)
     WHERE id = o_rango.id
    RETURNING * INTO o_rango;
    o_numero := interno.numero_de_bloque(b, v_n);
    RETURN;
  END IF;
  IF p_tipo = 'factura' THEN
    IF EXISTS (SELECT 1 FROM public.numero_bloque x WHERE x.caja_id = p_caja_id AND x.tipo = 'factura' AND x.estado = 'activo') THEN
      RAISE EXCEPTION 'BLOQUE_ACTIVO: la caja "%" tiene números de factura reservados en el equipo "%"; la venta de contado se hace desde ese equipo.',
        (SELECT c.nombre FROM public.caja c WHERE c.id = p_caja_id),
        (SELECT q.nombre FROM public.numero_bloque x JOIN public.equipo q ON q.id = x.equipo_id
          WHERE x.caja_id = p_caja_id AND x.tipo = 'factura' AND x.estado = 'activo');
    END IF;
    SELECT x.* INTO b FROM public.numero_bloque x JOIN public.cai_rango r ON r.id = x.cai_rango_id
     WHERE x.empresa_id = p_empresa_id AND x.caja_id = p_caja_id AND x.tipo = 'factura' AND x.estado = 'devuelto'
       AND x.siguiente <= x.hasta AND r.ultimo_numero = x.hasta AND r.activo AND r.fecha_limite_emision >= v_hoy
     ORDER BY x.desde LIMIT 1
     FOR UPDATE OF x;
    IF b.id IS NOT NULL THEN
      SELECT * INTO o_rango FROM public.cai_rango r WHERE r.id = b.cai_rango_id FOR UPDATE;
      IF p_fecha > v_hoy THEN
        RAISE EXCEPTION 'FECHA_INVALIDA: un documento fiscal no lleva fecha futura (%).', to_char(p_fecha, 'DD/MM/YYYY');
      END IF;
      IF o_rango.ultima_fecha_emision > p_fecha THEN
        RAISE EXCEPTION 'FECHA_INVALIDA: el último documento de este rango tiene fecha %; uno nuevo no puede tener fecha anterior (%).',
          to_char(o_rango.ultima_fecha_emision, 'DD/MM/YYYY'), to_char(p_fecha, 'DD/MM/YYYY');
      END IF;
      UPDATE public.numero_bloque SET siguiente = siguiente + 1 WHERE id = b.id;
      UPDATE public.cai_rango SET ultima_fecha_emision = greatest(coalesce(ultima_fecha_emision, p_fecha), p_fecha)
       WHERE id = o_rango.id
      RETURNING * INTO o_rango;
      o_numero := interno.numero_de_bloque(b, b.siguiente);
      INSERT INTO public.numero_emitido (empresa_id, bloque_id, serie, numero, numero_documento, estado)
      VALUES (p_empresa_id, b.id, b.serie, b.siguiente, o_numero, 'registrado');
      RETURN;
    END IF;
  END IF;
  SELECT * INTO rf FROM interno.asignar_numero_fiscal_027(p_empresa_id, p_caja_id, p_tipo, p_fecha);
  o_rango := rf.o_rango;
  o_numero := rf.o_numero;
END $$;

ALTER FUNCTION interno.siguiente_ticket(uuid, uuid) RENAME TO siguiente_ticket_028;
-- siguiente_ticket (misma firma): las mismas reglas que la factura, con el contador de tickets de la caja.
CREATE FUNCTION interno.siguiente_ticket(p_empresa_id uuid, p_caja_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_pre jsonb := nullif(current_setting('app.numero_bloque', true), '')::jsonb;
  v_n   bigint;
  b     public.numero_bloque;
  v_num text;
BEGIN
  IF v_pre IS NOT NULL THEN
    v_n := (v_pre->>'numero')::bigint;
    SELECT * INTO b FROM public.numero_bloque x
     WHERE x.id = (v_pre->>'bloque_id')::uuid AND x.empresa_id = p_empresa_id AND x.caja_id = p_caja_id AND x.tipo = 'ticket';
    IF b.id IS NULL OR v_n IS NULL OR v_n NOT BETWEEN b.desde AND b.hasta THEN
      RAISE EXCEPTION 'BLOQUE_INVALIDO: el número % no es de un bloque de tickets de esta caja.', coalesce(v_pre->>'numero', '?');
    END IF;
    RETURN interno.numero_de_bloque(b, v_n);
  END IF;
  IF EXISTS (SELECT 1 FROM public.numero_bloque x WHERE x.caja_id = p_caja_id AND x.tipo = 'ticket' AND x.estado = 'activo') THEN
    RAISE EXCEPTION 'BLOQUE_ACTIVO: la caja "%" tiene números de ticket reservados en el equipo "%"; la venta de contado se hace desde ese equipo.',
      (SELECT c.nombre FROM public.caja c WHERE c.id = p_caja_id),
      (SELECT q.nombre FROM public.numero_bloque x JOIN public.equipo q ON q.id = x.equipo_id
        WHERE x.caja_id = p_caja_id AND x.tipo = 'ticket' AND x.estado = 'activo');
  END IF;
  SELECT x.* INTO b FROM public.numero_bloque x JOIN interno.contador k ON k.empresa_id = x.empresa_id AND k.clave = 'ticket:' || x.caja_id
   WHERE x.empresa_id = p_empresa_id AND x.caja_id = p_caja_id AND x.tipo = 'ticket' AND x.estado = 'devuelto'
     AND x.siguiente <= x.hasta AND k.ultimo = x.hasta
   ORDER BY x.desde LIMIT 1
   FOR UPDATE OF x;
  IF b.id IS NOT NULL THEN
    UPDATE public.numero_bloque SET siguiente = siguiente + 1 WHERE id = b.id;
    v_num := interno.numero_de_bloque(b, b.siguiente);
    INSERT INTO public.numero_emitido (empresa_id, bloque_id, serie, numero, numero_documento, estado)
    VALUES (p_empresa_id, b.id, b.serie, b.siguiente, v_num, 'registrado');
    RETURN v_num;
  END IF;
  RETURN interno.siguiente_ticket_028(p_empresa_id, p_caja_id);
END $$;

-- Un turno no se cierra con un bloque activo de su caja (G4: el mismo equipo lo devuelve después de subir todo).
-- Si el equipo del bloque no da noticias hace 48 horas, el bloque pasa a "por conciliar" y el turno sí cierra.
CREATE FUNCTION interno.turno_con_bloque() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  b       public.numero_bloque;
  v_mot   text := current_setting('app.motivo', true);
BEGIN
  IF NOT (OLD.estado = 'abierto' AND NEW.estado = 'cerrado') THEN
    RETURN NEW;
  END IF;
  FOR b IN SELECT x.* FROM public.numero_bloque x WHERE x.caja_id = NEW.caja_id AND x.estado = 'activo' FOR UPDATE LOOP
    IF coalesce((SELECT s.ultima_en FROM interno.equipo_sync s WHERE s.equipo_id = b.equipo_id), b.reservado_en) < now() - interval '48 hours' THEN
      PERFORM set_config('app.motivo', 'El equipo no dio noticias en 48 horas: números por conciliar', true);
      UPDATE public.numero_bloque SET estado = 'por_conciliar', por_conciliar_en = now(),
             motivo_por_conciliar = 'El equipo no dio noticias en 48 horas; se cerró el turno #' || NEW.numero
       WHERE id = b.id;
      PERFORM set_config('app.motivo', coalesce(v_mot, ''), true);
    ELSE
      RAISE EXCEPTION 'BLOQUE_SIN_DEVOLVER: la caja tiene números reservados en el equipo "%" (% a %); súbalas y cierre el turno desde ese equipo.',
        (SELECT q.nombre FROM public.equipo q WHERE q.id = b.equipo_id),
        interno.numero_de_bloque(b, b.desde), interno.numero_de_bloque(b, b.hasta);
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
CREATE TRIGGER con_bloque BEFORE UPDATE ON public.turno_caja FOR EACH ROW EXECUTE FUNCTION interno.turno_con_bloque();

-- ---------------------------------------------------------------------
-- 6) Ayudantes
-- ---------------------------------------------------------------------
-- El equipo de esta empresa (activo si se pide).
CREATE FUNCTION interno.equipo_de(p_empresa_id uuid, p_equipo_id uuid, p_activo boolean) RETURNS public.equipo
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.equipo;
BEGIN
  SELECT * INTO q FROM public.equipo x WHERE x.id = p_equipo_id AND x.empresa_id = p_empresa_id;
  IF q.id IS NULL THEN
    RAISE EXCEPTION 'EQUIPO_INVALIDO: el equipo no está registrado en esta empresa.';
  END IF;
  IF p_activo AND NOT q.activo THEN
    RAISE EXCEPTION 'EQUIPO_INVALIDO: el equipo "%" fue desactivado el %.', q.nombre,
      to_char(q.desactivado_en AT TIME ZONE (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id), 'DD/MM/YYYY');
  END IF;
  RETURN q;
END $$;

CREATE FUNCTION interno.equipo_noticia(p_equipo_id uuid, p_version integer DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO interno.equipo_sync (equipo_id, ultima_en, foto_version) VALUES (p_equipo_id, now(), p_version)
  ON CONFLICT (equipo_id) DO UPDATE SET ultima_en = now(), foto_version = coalesce(excluded.foto_version, interno.equipo_sync.foto_version)
$$;

-- Entero opcional desde jsonb (null o ausente = NULL).
CREATE FUNCTION interno.json_entero(p_valor jsonb, p_campo text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_valor IS NULL OR p_valor = 'null'::jsonb THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_valor) <> 'number' OR (p_valor #>> '{}') !~ '^-?[0-9]{1,15}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser un número entero.', p_campo;
  END IF;
  RETURN (p_valor #>> '{}')::bigint;
END $$;

-- Hacerse pasar por quien hizo la venta (para que el turno, la bitácora y la sucursal sean los suyos) y volver.
-- Solo lo usan subir y resolver, después de revisar los permisos de quien sube.
CREATE FUNCTION interno.vsi_como(p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_c  text := current_setting('request.jwt.claims', true);
  v_s  text := current_setting('request.jwt.claim.sub', true);
BEGIN
  PERFORM set_config('request.jwt.claims',
    (coalesce(nullif(v_c, '')::jsonb, '{}'::jsonb) || jsonb_build_object('sub', p_user, 'role', 'authenticated'))::text, true);
  IF coalesce(v_s, '') <> '' THEN
    PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
  END IF;
  RETURN jsonb_build_object('claims', coalesce(v_c, ''), 'sub', coalesce(v_s, ''));
END $$;

CREATE FUNCTION interno.vsi_volver(p_antes jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', p_antes->>'claims', true);
  IF p_antes->>'sub' <> '' THEN
    PERFORM set_config('request.jwt.claim.sub', p_antes->>'sub', true);
  END IF;
END $$;

-- Palabras sencillas para cada problema.
CREATE FUNCTION interno.vsi_problema_texto(p_problema text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_problema
    WHEN 'precio'               THEN 'El precio cobrado no es el de los precios guardados en el equipo ni el de hoy.'
    WHEN 'foto'                 THEN 'No se encontró la lista de precios con la que se hizo la venta.'
    WHEN 'numero_invalido'      THEN 'GRAVE: el número de la venta no es de los números reservados para este equipo.'
    WHEN 'numero_repetido'      THEN 'GRAVE: ese número ya se había usado en otra venta.'
    WHEN 'bloque_por_conciliar' THEN 'Los números de este equipo están por conciliar (equipo desactivado o sin noticias).'
    WHEN 'equipo_desactivado'   THEN 'El equipo fue desactivado: sus ventas se revisan una por una.'
    WHEN 'usuario_desactivado'  THEN 'El usuario que la hizo estaba desactivado a esa hora.'
    WHEN 'sin_permiso'          THEN 'El usuario que la hizo no tiene permiso para vender sin internet.'
    WHEN 'reloj'                THEN 'La hora del equipo no cuadra (reloj mal puesto).'
    WHEN 'tope_venta'           THEN 'La venta pasa el tope de una venta sin internet.'
    WHEN 'tope_turno'           THEN 'Lo vendido sin internet en el turno pasa su tope.'
    WHEN 'tarjeta'              THEN 'Se cobró con tarjeta sin internet y la empresa no lo permite.'
    WHEN 'forma_pago'           THEN 'Sin internet solo se cobra en efectivo (o tarjeta, si el dueño lo permite).'
    WHEN 'mes_cerrado'          THEN 'El mes de la venta ya está cerrado: el dueño lo reabre, se registra con su fecha y se cierra otra vez.'
    WHEN 'sucursal'             THEN 'El usuario no trabaja en la sucursal de esa caja.'
    WHEN 'turno'                THEN 'El turno de caja donde se hizo la venta ya no está abierto.'
    WHEN 'cai'                  THEN 'El CAI no permitía facturar en esa fecha.'
    WHEN 'total'                THEN 'Lo cobrado no cuadra con el total de la venta.'
    WHEN 'cliente'              THEN 'El cliente de la venta ya no existe o no es cliente.'
    WHEN 'datos'                THEN 'Los datos de la venta están incompletos.'
    WHEN 'id_operacion_usado'   THEN 'El identificador de la venta ya se usó para otra operación.'
    ELSE 'La venta no se pudo registrar.' END
$$;

CREATE FUNCTION interno.vsi_problema_de_error(p_error text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_error LIKE 'PERIODO_CERRADO%' THEN 'mes_cerrado'
    WHEN p_error LIKE 'SUCURSAL_NO_PERMITIDA%' THEN 'sucursal'
    WHEN p_error LIKE 'SIN_TURNO_ABIERTO%' OR p_error LIKE 'TURNO_CERRADO%' OR p_error LIKE 'CAJA_OCUPADA%'
         OR p_error LIKE 'DATO_INVALIDO: usted tiene abierto el turno%' THEN 'turno'
    WHEN p_error LIKE 'CAI\_%' OR p_error LIKE 'FECHA_INVALIDA%' OR p_error LIKE 'SIN_CAI%' THEN 'cai'
    WHEN p_error LIKE 'PAGO_NO_CUADRA%' THEN 'total'
    WHEN p_error LIKE 'TERCERO_INVALIDO%' THEN 'cliente'
    WHEN p_error LIKE 'ID_OPERACION_USADO%' THEN 'id_operacion_usado'
    ELSE 'otro' END
$$;

-- ¿El cálculo del servidor da lo mismo que cobró el equipo? (total y, por línea, precio y total si los mandó)
CREATE FUNCTION interno.vsi_cuadra(p_calc jsonb, p_payload jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT p_calc IS NOT NULL
     AND (p_calc->>'total_centavos')::bigint = (p_payload->>'total_centavos')::bigint
     AND jsonb_array_length(p_calc->'lineas') = jsonb_array_length(p_payload->'lineas')
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_payload->'lineas') WITH ORDINALITY d(l, k)
        WHERE ((d.l ? 'total_centavos') AND (d.l->>'total_centavos')::bigint IS DISTINCT FROM (p_calc->'lineas'->(d.k::int - 1)->>'total_centavos')::bigint)
           OR ((d.l ? 'precio_unitario_centavos')
               AND (d.l->>'precio_unitario_centavos')::bigint IS DISTINCT FROM (p_calc->'lineas'->(d.k::int - 1)->>'precio_unitario_centavos')::bigint))
$$;

-- Líneas como las pide el cálculo (sin lo que el equipo manda para comparar).
CREATE FUNCTION interno.vsi_lineas(p_payload jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('producto_id', l->'producto_id', 'cantidad', l->'cantidad',
           'precio_tipo', l->'precio_tipo', 'promocion_id', l->'promocion_id')) ORDER BY k), '[]')
    FROM jsonb_array_elements(p_payload->'lineas') WITH ORDINALITY x(l, k)
$$;

-- ---------------------------------------------------------------------
-- 7) Registrar UNA venta sin internet en los libros (como una venta normal: documento + kardex + asiento + rastro),
--    con el número que puso el equipo. Quien llama ya se hizo pasar por el usuario de la venta.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.vsi_registrar(p_vsi public.venta_sin_internet, p_calc jsonb, p_foto jsonb) RETURNS public.venta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e       public.empresa;
  v       public.venta;
  v_caja  public.caja;
  v_bod   public.bodega;
  v_cli   public.tercero;
  v_fecha date;
  v_total bigint := (p_calc->>'total_centavos')::bigint;
  v_suma  bigint := 0;
  pj      jsonb;
  k       integer := 0;
  d       public.cuenta_dinero;
  v_rec   bigint;
  v_mon   bigint;
BEGIN
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_vsi.empresa_id;
  SELECT x.* INTO v_caja FROM public.caja x JOIN public.sucursal s ON s.id = x.sucursal_id
   WHERE x.id = p_vsi.caja_id AND x.empresa_id = e.id AND x.activa AND s.activa;
  IF v_caja.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja de la venta no existe o está desactivada (ella o su sucursal).';
  END IF;
  v_fecha := (p_vsi.hora_equipo AT TIME ZONE e.zona_horaria)::date;
  PERFORM interno.exigir_fecha_contable(e.id, v_fecha);
  IF coalesce(p_vsi.payload->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    SELECT * INTO v_cli FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_vsi.payload->'cliente_id', 'cliente_id') AND t.empresa_id = e.id AND t.es_cliente;
    IF v_cli.id IS NULL THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente de la venta no existe o no es cliente.';
    END IF;
  END IF;
  IF coalesce((p_calc->>'tiene_bienes')::boolean, true) THEN
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = e.id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa.';
    END IF;
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_vsi.payload->'pagos') LOOP
    v_mon := interno.json_centavos(pj->'monto_centavos', 'monto_centavos');
    v_suma := v_suma + coalesce(v_mon, 0);
  END LOOP;
  IF v_suma <> v_total THEN
    RAISE EXCEPTION 'PAGO_NO_CUADRA: las formas de pago suman % y el total de la venta es %.', interno.lempiras(v_suma), interno.lempiras(v_total);
  END IF;

  v.id := gen_random_uuid();
  v.numero := interno.siguiente_numero(e.id, 'venta');
  INSERT INTO public.venta (id, empresa_id, numero, sucursal_id, caja_id, bodega_id, fecha_contable, tipo_documento,
    emisor_nombre, emisor_rtn, cliente_id, cliente_nombre, cliente_rtn, vendedor_id, condicion, credito_centavos,
    subtotal_centavos, descuento_centavos, descuento_promocion_centavos, descuento_manual_centavos, descuento_manual_porcentaje,
    gravado_centavos, exento_centavos, exonerado_centavos, impuesto_centavos, desglose_impuestos, total_centavos,
    estado, nota, equipo, id_operacion, creado_por)
  VALUES (v.id, e.id, v.numero, v_caja.sucursal_id, v_caja.id, v_bod.id, v_fecha, p_vsi.tipo_documento,
    e.nombre, e.rtn, v_cli.id, coalesce(v_cli.nombre, 'Consumidor final'), v_cli.rtn, p_vsi.usuario_id, 'contado', 0,
    (p_calc->>'subtotal_centavos')::bigint, (p_calc->>'descuento_centavos')::bigint,
    (p_calc->>'descuento_promocion_centavos')::bigint, (p_calc->>'descuento_manual_centavos')::bigint,
    (p_calc->>'descuento_manual_porcentaje')::numeric,
    (p_calc->>'gravado_centavos')::bigint, (p_calc->>'exento_centavos')::bigint, (p_calc->>'exonerado_centavos')::bigint,
    (p_calc->>'impuesto_centavos')::bigint, p_calc->'desglose_impuestos', v_total,
    'por_emitir',
    concat_ws(' · ', CASE WHEN NOT p_vsi.en_linea THEN 'Emitida sin conexión' END,
              interno.json_texto(p_vsi.payload->'nota', 'nota', 400)),
    (SELECT q.nombre FROM public.equipo q WHERE q.id = p_vsi.equipo_id), p_vsi.id_operacion, auth.uid())
  RETURNING * INTO v;

  PERFORM set_config('app.foto_venta', coalesce(p_foto::text, ''), true);
  INSERT INTO public.venta_linea (empresa_id, venta_id, linea, producto_id, descripcion, cantidad, precio_unitario_centavos,
    precio_incluye_isv, tipo_impuesto, impuesto_porcentaje, impuesto_clase, es_servicio, costo_estimado_centavos,
    promocion_id, descuento_linea_porcentaje, descuento_linea_monto_centavos,
    bruto_centavos, descuento_promocion_precio_centavos, descuento_linea_centavos, descuento_factura_centavos, neto_centavos,
    subtotal_centavos, descuento_promocion_centavos, descuento_centavos, base_centavos, impuesto_centavos, total_centavos,
    precio_tipo, precio_normal_centavos)
  SELECT e.id, v.id, x.linea, x.producto_id, x.descripcion, x.cantidad, x.precio_unitario_centavos,
         x.precio_incluye_isv, x.tipo_impuesto, x.impuesto_porcentaje, x.impuesto_clase, x.es_servicio, x.costo_estimado_centavos,
         x.promocion_id, x.descuento_linea_porcentaje, x.descuento_linea_monto_centavos,
         x.bruto_centavos, x.descuento_promocion_precio_centavos, x.descuento_linea_centavos, x.descuento_factura_centavos,
         x.neto_centavos, x.subtotal_centavos, x.descuento_promocion_centavos, x.descuento_centavos, x.base_centavos,
         x.impuesto_centavos, x.total_centavos, coalesce(x.precio_tipo, 'normal'), x.precio_normal_centavos
    FROM jsonb_to_recordset(p_calc->'lineas') AS x(linea smallint, producto_id uuid, descripcion text, cantidad numeric,
         precio_unitario_centavos bigint, precio_incluye_isv boolean, tipo_impuesto text, impuesto_porcentaje numeric,
         impuesto_clase text, es_servicio boolean, costo_estimado_centavos bigint, promocion_id uuid,
         descuento_linea_porcentaje numeric, descuento_linea_monto_centavos bigint, bruto_centavos bigint,
         descuento_promocion_precio_centavos bigint, descuento_linea_centavos bigint, descuento_factura_centavos bigint,
         neto_centavos bigint, subtotal_centavos bigint, descuento_promocion_centavos bigint, descuento_centavos bigint,
         base_centavos bigint, impuesto_centavos bigint, total_centavos bigint, precio_tipo text, precio_normal_centavos bigint);
  PERFORM set_config('app.foto_venta', '', true);

  FOR pj IN SELECT * FROM jsonb_array_elements(p_vsi.payload->'pagos') LOOP
    k := k + 1;
    v_mon := interno.json_centavos(pj->'monto_centavos', 'monto_centavos');
    v_rec := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(e.id, v_caja.id);
      v_rec := greatest(CASE WHEN coalesce(pj->'recibido_centavos', 'null'::jsonb) <> 'null'::jsonb
                              THEN interno.json_centavos(pj->'recibido_centavos', 'recibido_centavos') END, v_mon);
    ELSE
      d := interno.cuenta_cobro_venta(e.id, 'tarjeta', NULL);
    END IF;
    INSERT INTO public.venta_pago (empresa_id, venta_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos)
    VALUES (e.id, v.id, k, pj->>'forma', v_mon, d.id,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta(d.id) END,
            interno.json_texto(pj->'referencia', 'referencia', 100), v_rec, v_rec - v_mon);
  END LOOP;

  PERFORM set_config('app.numero_bloque', jsonb_build_object('bloque_id', p_vsi.bloque_id, 'numero', p_vsi.numero)::text, true);
  PERFORM set_config('app.sin_internet', '1', true);
  v := interno.emitir_venta(v.id, v_fecha, p_vsi.id_operacion);
  PERFORM set_config('app.numero_bloque', '', true);
  PERFORM set_config('app.sin_internet', '', true);
  IF v.numero_documento IS DISTINCT FROM p_vsi.numero_documento THEN
    RAISE EXCEPTION 'BLOQUE_INVALIDO: el número impreso (%) no es el que corresponde (%).', p_vsi.numero_documento, v.numero_documento;
  END IF;
  RETURN v;
END $$;

-- Revisa UNA venta sin internet y, si todo está bien, la registra. Devuelve {problema, texto, venta_id, numero_documento, negativo}.
--   p_modo 'subir': todas las revisiones del punto 8.
--   p_modo 'resolver': quien resuelve ya decidió (sin revisar reloj, topes, tarjeta, permiso ni usuario); si el precio no
--      es el de la foto ni el de hoy, se registra con el precio que cobró el equipo (si su cuenta cuadra).
--   p_a_mi_turno: el efectivo entra al turno de quien resuelve (el turno de la venta ya se cerró).
CREATE FUNCTION interno.vsi_revisar(p_vsi public.venta_sin_internet, p_modo text, p_a_mi_turno boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e        public.empresa;
  ue       public.usuario_empresa;
  f        public.catalogo_foto;
  v        public.venta;
  v_antes  jsonb;
  v_prob   text;
  v_txt    text;
  v_hasta  timestamptz;
  v_fecha  date;
  v_lin    jsonb := interno.vsi_lineas(p_vsi.payload);
  v_fv     jsonb;
  v_calc   jsonb;
  v_hoy    jsonb;
  v_suc    uuid;
  v_formas text[];
  v_vend   bigint;
  v_neg    boolean := false;
  v_quien  uuid := CASE WHEN p_a_mi_turno THEN auth.uid() ELSE p_vsi.usuario_id END;
  pj       jsonb;
  l        jsonb;
  k        integer;
BEGIN
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_vsi.empresa_id;
  v_fecha := (p_vsi.hora_equipo AT TIME ZONE e.zona_horaria)::date;
  SELECT c.sucursal_id INTO v_suc FROM public.caja c WHERE c.id = p_vsi.caja_id;
  SELECT * INTO ue FROM public.usuario_empresa x WHERE x.empresa_id = e.id AND x.user_id = p_vsi.usuario_id;
  SELECT array_agg(pg->>'forma') INTO v_formas FROM jsonb_array_elements(p_vsi.payload->'pagos') pg;

  IF ue.id IS NULL THEN
    v_prob := 'usuario_desactivado';
  ELSIF NOT EXISTS (SELECT 1 FROM unnest(v_formas) x WHERE x IS NOT NULL) OR EXISTS (SELECT 1 FROM unnest(v_formas) x WHERE x NOT IN ('efectivo', 'tarjeta') OR x IS NULL) THEN
    v_prob := 'forma_pago';
  END IF;
  IF v_prob IS NULL AND p_modo = 'subir' THEN
    IF NOT ue.activo THEN
      -- ¿Cuándo lo desactivaron? (bitácora). Una venta de ANTES de desactivarlo se registra.
      SELECT max(b.ocurrido_en) INTO v_hasta FROM public.bitacora b
       WHERE b.empresa_id = e.id AND b.tabla = 'usuario_empresa' AND b.registro_id = ue.id::text AND b.accion = 'UPDATE'
         AND (b.despues->>'activo') = 'false';
      IF v_hasta IS NULL OR v_hasta <= p_vsi.hora_equipo THEN
        v_prob := 'usuario_desactivado';
      END IF;
    END IF;
    IF v_prob IS NULL AND NOT p_vsi.en_linea AND 'tarjeta' = ANY (v_formas) AND NOT e.sin_internet_tarjeta THEN
      v_prob := 'tarjeta';
    END IF;
    IF v_prob IS NULL AND NOT p_vsi.en_linea AND p_vsi.total_centavos > e.sin_internet_tope_venta_centavos THEN
      v_prob := 'tope_venta';
    END IF;
    IF v_prob IS NULL AND NOT p_vsi.en_linea THEN
      SELECT coalesce(sum(x.total_centavos), 0) INTO v_vend FROM public.venta_sin_internet x
       WHERE x.bloque_id = p_vsi.bloque_id AND x.usuario_id = p_vsi.usuario_id AND NOT x.en_linea AND x.estado <> 'anulada';
      IF v_vend + p_vsi.total_centavos > e.sin_internet_tope_turno_centavos THEN
        v_prob := 'tope_turno';
      END IF;
    END IF;
  END IF;
  IF v_prob IS NOT NULL THEN
    RETURN jsonb_build_object('problema', v_prob, 'texto', interno.vsi_problema_texto(v_prob));
  END IF;

  v_antes := interno.vsi_como(v_quien);
  BEGIN
    -- Permiso del usuario (activo): sin internet, ventas.sin_internet; con internet (cola de la caja con bloque), vender y cobrar.
    IF p_modo = 'subir' AND ue.activo THEN
      IF NOT p_vsi.en_linea AND NOT public.tiene_permiso('ventas.sin_internet', e.id) THEN
        v_prob := 'sin_permiso';
      ELSIF p_vsi.en_linea AND NOT (public.tiene_permiso('ventas.vender', e.id) AND interno.puede_cobrar(e.id)) THEN
        v_prob := 'sin_permiso';
      END IF;
    END IF;
    -- G5: el precio con la foto; si no, con el de hoy; si no, por resolver.
    IF v_prob IS NULL THEN
      PERFORM set_config('app.sucursal_venta', coalesce(v_suc::text, ''), true);
      PERFORM set_config('app.cliente_venta', coalesce(p_vsi.payload->>'cliente_id', ''), true);
      SELECT * INTO f FROM public.catalogo_foto x WHERE x.empresa_id = e.id AND x.version = p_vsi.foto_version;
      IF f.id IS NOT NULL THEN
        v_fv := interno.foto_de_venta(f.contenido, v_lin);
        PERFORM set_config('app.foto_venta', v_fv::text, true);
        BEGIN
          v_calc := interno.calcular_venta(e.id, v_fecha, v_lin, NULL);
        EXCEPTION WHEN OTHERS THEN
          v_calc := NULL;
        END;
        PERFORM set_config('app.foto_venta', '', true);
      END IF;
      IF NOT interno.vsi_cuadra(v_calc, p_vsi.payload) THEN
        v_fv := NULL;
        BEGIN
          v_hoy := interno.calcular_venta(e.id, v_fecha, v_lin, NULL);
        EXCEPTION WHEN OTHERS THEN
          v_hoy := NULL;
        END;
        IF interno.vsi_cuadra(v_hoy, p_vsi.payload) THEN
          v_calc := v_hoy;
        ELSIF p_modo = 'resolver' THEN
          -- Quien resuelve acepta el precio que cobró el equipo: la foto con ese precio por unidad.
          v_fv := interno.foto_de_venta(coalesce(f.contenido, interno.armar_catalogo(e.id, v_suc)), v_lin);
          k := 0;
          FOR l IN SELECT * FROM jsonb_array_elements(p_vsi.payload->'lineas') LOOP
            k := k + 1;
            IF l ? 'precio_unitario_centavos' AND v_fv->'productos' ? (l->>'producto_id') THEN
              v_fv := jsonb_set(v_fv, ARRAY['productos', l->>'producto_id',
                        CASE WHEN l->>'precio_tipo' = 'mayorista' THEN 'precio_mayorista_centavos' ELSE 'precio_venta_centavos' END],
                        to_jsonb((l->>'precio_unitario_centavos')::bigint));
            END IF;
          END LOOP;
          PERFORM set_config('app.foto_venta', v_fv::text, true);
          BEGIN
            v_calc := interno.calcular_venta(e.id, v_fecha, v_lin, NULL);
          EXCEPTION WHEN OTHERS THEN
            v_calc := NULL;
          END;
          PERFORM set_config('app.foto_venta', '', true);
          IF NOT interno.vsi_cuadra(v_calc, p_vsi.payload) THEN
            RAISE EXCEPTION 'VENTA_SIN_INTERNET_INVALIDA: ni con el precio que cobró el equipo da el total (L %); anúlela con motivo.',
              to_char(p_vsi.total_centavos / 100.0, 'FM999,999,990.00');
          END IF;
        ELSE
          v_prob := CASE WHEN f.id IS NULL THEN 'foto' ELSE 'precio' END;
          v_txt := interno.vsi_problema_texto(v_prob) || ' Cobró ' || interno.lempiras(p_vsi.total_centavos)
            || CASE WHEN v_calc IS NOT NULL THEN '; con los precios guardados da ' || interno.lempiras((v_calc->>'total_centavos')::bigint) ELSE '' END
            || CASE WHEN v_hoy IS NOT NULL THEN '; con los de hoy, ' || interno.lempiras((v_hoy->>'total_centavos')::bigint) ELSE '' END || '.';
        END IF;
      END IF;
    END IF;
    IF v_prob IS NULL THEN
      BEGIN
        v := interno.vsi_registrar(p_vsi, v_calc, v_fv);
        v_neg := EXISTS (SELECT 1 FROM public.venta_linea vl JOIN public.inventario_saldo s
                           ON s.bodega_id = v.bodega_id AND s.producto_id = vl.producto_id
                          WHERE vl.venta_id = v.id AND NOT vl.es_servicio AND s.cantidad < 0);
      EXCEPTION WHEN OTHERS THEN
        IF p_modo = 'resolver' THEN
          RAISE;
        END IF;
        v_prob := interno.vsi_problema_de_error(SQLERRM);
        v_txt := interno.vsi_problema_texto(v_prob) || ' (' || regexp_replace(SQLERRM, '^[A-Z_]+: ', '') || ')';
      END;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM interno.vsi_volver(v_antes);
    RAISE;
  END;
  PERFORM interno.vsi_volver(v_antes);
  PERFORM set_config('app.cliente_venta', '', true);
  IF v_prob IS NOT NULL THEN
    RETURN jsonb_build_object('problema', v_prob, 'texto', coalesce(v_txt, interno.vsi_problema_texto(v_prob)));
  END IF;
  RETURN jsonb_build_object('problema', NULL, 'venta_id', v.id, 'numero_documento', v.numero_documento, 'negativo', v_neg);
END $$;

-- ---------------------------------------------------------------------
-- 8) RPC
-- ---------------------------------------------------------------------
-- registrar_equipo(empresa, {"nombre"}, id_operacion)   ventas.sin_internet o equipos.administrar
CREATE FUNCTION public.registrar_equipo(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  q        public.equipo;
  v_nombre text;
BEGIN
  IF public.tiene_permiso('equipos.administrar', p_empresa_id) THEN
    PERFORM interno.exigir_escritura(p_empresa_id, 'equipos.administrar', 'ventas');
  ELSE
    PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.sin_internet', 'ventas');
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'registro_equipo');
  PERFORM interno.exigir_claves(coalesce(p_datos, '{}'), ARRAY['nombre']);
  v_nombre := trim(coalesce(interno.json_texto(p_datos->'nombre', 'nombre', 60), ''));
  IF length(v_nombre) < 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba un nombre para el equipo (por ejemplo "Caja 1 - computadora").';
  END IF;
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'registro_equipo');
  SELECT * INTO q FROM public.equipo x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF q.id IS NULL THEN
    INSERT INTO public.equipo (empresa_id, nombre, registrado_por, id_operacion)
    VALUES (p_empresa_id, v_nombre, auth.uid(), p_id_operacion)
    RETURNING * INTO q;
    PERFORM interno.equipo_noticia(q.id);
  END IF;
  RETURN jsonb_build_object('equipo_id', q.id, 'nombre', q.nombre, 'activo', q.activo, 'registrado_en', public.iso(q.registrado_en));
END $$;

-- desactivar_equipo(empresa, equipo, motivo)   equipos.administrar (G3: los bloques quedan por conciliar; no se anulan números)
CREATE FUNCTION public.desactivar_equipo(p_empresa_id uuid, p_equipo_id uuid, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  q    public.equipo;
  v_n  integer;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'equipos.administrar', 'ventas');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva el equipo (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  q := interno.equipo_de(p_empresa_id, p_equipo_id, false);
  IF NOT q.activo THEN
    RETURN jsonb_build_object('equipo_id', q.id, 'activo', false, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.equipo SET activo = false, desactivado_en = now(), desactivado_por = auth.uid(), motivo_desactivacion = trim(p_motivo)
   WHERE id = q.id;
  UPDATE public.numero_bloque SET estado = 'por_conciliar', por_conciliar_en = now(),
         motivo_por_conciliar = 'Equipo desactivado: ' || trim(p_motivo)
   WHERE equipo_id = q.id AND estado IN ('activo', 'devuelto') AND siguiente <= hasta;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('equipo_id', q.id, 'activo', false, 'ya_estaba', false, 'bloques_por_conciliar', v_n);
END $$;

-- Tamaño sugerido del bloque: 1.5 veces las ventas de un día de esa caja (últimos 30 días), entre 20 y 500.
CREATE FUNCTION interno.tamano_bloque(p_empresa_id uuid, p_caja_id uuid) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT e.sin_internet_bloque FROM public.empresa e WHERE e.id = p_empresa_id),
    (SELECT least(500, greatest(20, ceil(1.5 * count(*)::numeric / greatest(1, count(DISTINCT v.fecha_contable)))))::integer
       FROM public.venta v
      WHERE v.caja_id = p_caja_id AND v.estado IN ('emitida', 'anulada')
        AND v.fecha_contable >= public.hoy_local(p_empresa_id) - 30
     HAVING count(*) > 0),
    50)
$$;

-- reservar_bloque_numeros(empresa, equipo, id_operacion, {"caja_id"?, "tamano"?})   ventas.sin_internet
-- Reserva los números de la caja (del turno abierto del usuario) para ESTE equipo: facturas CAI y/o tickets según
-- la regla de documento de la empresa. Si el equipo ya tiene un bloque activo de esa caja, lo devuelve (ya_estaba).
CREATE FUNCTION public.reservar_bloque_numeros(p_empresa_id uuid, p_equipo_id uuid, p_id_operacion uuid, p_datos jsonb DEFAULT '{}')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e       public.empresa;
  q       public.equipo;
  t       public.turno_caja;
  c       public.caja;
  v_suc   public.sucursal;
  b       public.numero_bloque;
  ya      public.numero_bloque;
  dv      public.numero_bloque;
  r       public.cai_rango;
  v_datos jsonb := coalesce(p_datos, '{}');
  v_tipos text[];
  v_tipo  text;
  v_n     integer;
  v_desde bigint;
  v_hasta bigint;
  v_ult   bigint;
  v_res   jsonb := '[]';
  v_avis  jsonb := '[]';
  v_hoy   date;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.sin_internet', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'reserva_bloque');
  PERFORM interno.exigir_claves(v_datos, ARRAY['caja_id', 'tamano']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  v_hoy := public.hoy_local(p_empresa_id);
  q := interno.equipo_de(p_empresa_id, p_equipo_id, true);

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'reserva_bloque');
  IF EXISTS (SELECT 1 FROM public.numero_bloque x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    RETURN public.bloques_del_equipo(p_empresa_id, p_equipo_id) || jsonb_build_object('ya_estaba', true);
  END IF;

  SELECT * INTO t FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
  SELECT x.* INTO c FROM public.caja x
   WHERE x.empresa_id = p_empresa_id AND x.activa
     AND x.id = coalesce(interno.json_uuid(v_datos->'caja_id', 'caja_id'), t.caja_id);
  IF c.id IS NULL THEN
    IF e.turnos_obligatorios AND t.id IS NULL THEN
      RAISE EXCEPTION 'SIN_TURNO_ABIERTO: abra su turno de caja para preparar el equipo (los números son de la caja del turno).';
    END IF;
    RAISE EXCEPTION 'DATO_INVALIDO: indique la caja ("caja_id") o abra su turno de caja.';
  END IF;
  IF t.id IS NOT NULL AND t.caja_id <> c.id THEN
    RAISE EXCEPTION 'DATO_INVALIDO: usted tiene abierto el turno #% en otra caja; prepare el equipo para esa caja.', t.numero;
  END IF;
  IF e.turnos_obligatorios AND t.id IS NULL THEN
    RAISE EXCEPTION 'SIN_TURNO_ABIERTO: abra su turno de caja para preparar el equipo.';
  END IF;
  SELECT * INTO v_suc FROM public.sucursal s WHERE s.id = c.sucursal_id AND s.activa;
  IF v_suc.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la sucursal de la caja está desactivada.';
  END IF;
  PERFORM interno.exigir_sucursal(p_empresa_id, c.sucursal_id);

  v_tipos := CASE WHEN interno.regimen_fiscal(p_empresa_id) IS NULL THEN ARRAY['ticket']
                  WHEN e.documento_venta_modo = 'solo_factura' THEN ARRAY['factura']
                  WHEN e.documento_venta_modo = 'solo_ticket' THEN ARRAY['ticket']
                  ELSE ARRAY['factura', 'ticket'] END;
  v_n := coalesce(interno.json_entero(v_datos->'tamano', 'tamano')::integer, interno.tamano_bloque(p_empresa_id, c.id));
  IF v_n NOT BETWEEN 10 AND 5000 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el bloque es de 10 a 5000 números.';
  END IF;

  FOREACH v_tipo IN ARRAY v_tipos LOOP
    SELECT * INTO ya FROM public.numero_bloque x WHERE x.caja_id = c.id AND x.tipo = v_tipo AND x.estado = 'activo' FOR UPDATE;
    IF ya.id IS NOT NULL AND ya.equipo_id <> q.id THEN
      RAISE EXCEPTION 'BLOQUE_ACTIVO: la caja "%" ya tiene números reservados en el equipo "%"; ese equipo los devuelve al cerrar el turno (o el dueño lo desactiva).',
        c.nombre, (SELECT x.nombre FROM public.equipo x WHERE x.id = ya.equipo_id);
    END IF;
    -- Bloque del mismo equipo ya usado completo (y todo subido): se cierra y se reserva otro.
    IF ya.id IS NOT NULL AND ya.siguiente > ya.hasta THEN
      UPDATE public.numero_bloque SET estado = 'devuelto', devuelto_desde = ya.hasta + 1, devuelto_en = now(), devuelto_por = auth.uid()
       WHERE id = ya.id;
      ya := NULL;
    END IF;
    CONTINUE WHEN ya.id IS NOT NULL;

    IF v_tipo = 'factura' THEN
      SELECT * INTO r FROM public.cai_rango x
       WHERE x.empresa_id = p_empresa_id AND x.caja_id = c.id AND x.tipo_documento = 'factura'
         AND x.activo AND x.ultimo_numero < x.numero_hasta AND x.fecha_limite_emision >= v_hoy
       ORDER BY x.numero_desde LIMIT 1 FOR UPDATE;
      -- Números devueltos de ese rango (nada emitido después): el bloque nuevo empieza ahí.
      SELECT x.* INTO dv FROM public.numero_bloque x
       WHERE x.cai_rango_id = r.id AND x.estado = 'devuelto' AND x.siguiente <= x.hasta AND x.hasta = r.ultimo_numero
       ORDER BY x.desde LIMIT 1 FOR UPDATE;
      IF r.id IS NULL THEN
        IF e.documento_venta_modo = 'solo_factura' THEN
          RAISE EXCEPTION 'SIN_CAI: la caja "%" no tiene un rango de CAI vigente con números libres; no se puede facturar sin internet.', c.nombre;
        END IF;
        v_avis := v_avis || to_jsonb('La caja no tiene CAI vigente: sin internet solo saldrán tickets.'::text);
        CONTINUE;
      END IF;
      v_desde := coalesce(dv.siguiente, r.ultimo_numero + 1);
      v_hasta := least(v_desde + v_n - 1, r.numero_hasta);
      IF dv.id IS NOT NULL THEN
        UPDATE public.numero_bloque SET siguiente = dv.hasta + 1 WHERE id = dv.id;
      END IF;
      INSERT INTO public.numero_bloque (empresa_id, sucursal_id, caja_id, equipo_id, turno_id, tipo, cai_rango_id, serie, prefijo,
                                        desde, hasta, siguiente, reservado_por, vence_en, id_operacion)
      VALUES (p_empresa_id, c.sucursal_id, c.id, q.id, t.id, 'factura', r.id, 'cai:' || r.id, r.prefijo,
              v_desde, v_hasta, v_desde, auth.uid(),
              ((r.fecha_limite_emision + 1)::timestamp AT TIME ZONE e.zona_horaria), p_id_operacion)
      RETURNING * INTO b;
      IF v_hasta > r.ultimo_numero THEN
        PERFORM set_config('app.reserva_bloque', r.id::text, true);
        UPDATE public.cai_rango SET ultimo_numero = v_hasta WHERE id = r.id;
        PERFORM set_config('app.reserva_bloque', '', true);
      END IF;
    ELSE
      INSERT INTO interno.contador (empresa_id, clave) VALUES (p_empresa_id, 'ticket:' || c.id) ON CONFLICT DO NOTHING;
      SELECT k.ultimo INTO v_ult FROM interno.contador k WHERE k.empresa_id = p_empresa_id AND k.clave = 'ticket:' || c.id FOR UPDATE;
      SELECT x.* INTO dv FROM public.numero_bloque x
       WHERE x.caja_id = c.id AND x.tipo = 'ticket' AND x.estado = 'devuelto' AND x.siguiente <= x.hasta AND x.hasta = v_ult
       ORDER BY x.desde LIMIT 1 FOR UPDATE;
      v_desde := coalesce(dv.siguiente, v_ult + 1);
      v_hasta := least(v_desde + v_n - 1, 99999999);
      IF dv.id IS NOT NULL THEN
        UPDATE public.numero_bloque SET siguiente = dv.hasta + 1 WHERE id = dv.id;
      END IF;
      INSERT INTO public.numero_bloque (empresa_id, sucursal_id, caja_id, equipo_id, turno_id, tipo, serie, prefijo,
                                        desde, hasta, siguiente, reservado_por, id_operacion)
      VALUES (p_empresa_id, c.sucursal_id, c.id, q.id, t.id, 'ticket', 'ticket:' || c.id,
              'T-' || v_suc.codigo || '-' || c.punto_emision, v_desde, v_hasta, v_desde, auth.uid(), p_id_operacion)
      RETURNING * INTO b;
      UPDATE interno.contador SET ultimo = greatest(ultimo, v_hasta) WHERE empresa_id = p_empresa_id AND clave = 'ticket:' || c.id;
    END IF;
  END LOOP;
  PERFORM interno.equipo_noticia(q.id);
  RETURN public.bloques_del_equipo(p_empresa_id, p_equipo_id) || jsonb_build_object('ya_estaba', false, 'avisos', v_avis);
END $$;

-- Bloques activos de un equipo, con lo necesario para numerar e imprimir sin internet.
CREATE FUNCTION public.bloques_del_equipo(p_empresa_id uuid, p_equipo_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.sin_internet');
  RETURN jsonb_build_object('equipo_id', p_equipo_id, 'bloques', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'bloque_id', b.id, 'tipo', b.tipo, 'caja_id', b.caja_id, 'caja', c.nombre, 'turno_id', b.turno_id,
      'prefijo', b.prefijo, 'desde', b.desde, 'hasta', b.hasta, 'siguiente', b.siguiente,
      'desde_texto', interno.numero_de_bloque(b, b.desde), 'hasta_texto', interno.numero_de_bloque(b, b.hasta),
      'reservado_en', public.iso(b.reservado_en), 'vence_en', public.iso(b.vence_en),
      'cai', CASE WHEN r.id IS NOT NULL THEN jsonb_build_object('regimen', 'fiscal_hn', 'cai_rango_id', r.id, 'cai', r.cai,
               'rango_desde', r.rango_desde, 'rango_hasta', r.rango_hasta,
               'fecha_limite_emision', to_char(r.fecha_limite_emision, 'YYYY-MM-DD')) END)
      ORDER BY b.tipo)
    FROM public.numero_bloque b JOIN public.caja c ON c.id = b.caja_id LEFT JOIN public.cai_rango r ON r.id = b.cai_rango_id
   WHERE b.empresa_id = p_empresa_id AND b.equipo_id = p_equipo_id AND b.estado = 'activo'), '[]'));
END $$;

-- devolver_bloque(empresa, equipo, bloque, siguiente_del_equipo, id_operacion)   ventas.sin_internet
-- G4: SOLO el mismo equipo devuelve, y solo después de subir todo lo que numeró (del inicio hasta su siguiente).
CREATE FUNCTION public.devolver_bloque(p_empresa_id uuid, p_equipo_id uuid, p_bloque_id uuid, p_siguiente bigint, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  b      public.numero_bloque;
  v_falt bigint;
BEGIN
  IF public.tiene_permiso('ventas.subir_ajenas', p_empresa_id) THEN
    PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.subir_ajenas', 'ventas');
  ELSE
    PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.sin_internet', 'ventas');
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'devolucion_bloque');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'devolucion_bloque');
  SELECT * INTO b FROM public.numero_bloque x WHERE x.id = p_bloque_id AND x.empresa_id = p_empresa_id FOR UPDATE;
  IF b.id IS NULL THEN
    RAISE EXCEPTION 'BLOQUE_INVALIDO: ese bloque de números no existe en esta empresa.';
  END IF;
  IF b.devolucion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('bloque_id', b.id, 'estado', b.estado, 'devuelto_desde', b.devuelto_desde, 'ya_estaba', true);
  END IF;
  IF b.equipo_id <> p_equipo_id THEN
    RAISE EXCEPTION 'BLOQUE_INVALIDO: solo el equipo que tiene los números los devuelve.';
  END IF;
  PERFORM interno.equipo_de(p_empresa_id, p_equipo_id, true);
  IF b.estado <> 'activo' THEN
    RAISE EXCEPTION 'BLOQUE_INVALIDO: ese bloque ya no está activo (%).', replace(b.estado, '_', ' ');
  END IF;
  IF p_siguiente IS NULL OR p_siguiente NOT BETWEEN b.desde AND b.hasta + 1 OR p_siguiente < b.siguiente THEN
    RAISE EXCEPTION 'BLOQUE_INVALIDO: el equipo dice que su siguiente número es % y el servidor ya recibió hasta el %.',
      coalesce(p_siguiente::text, '?'), b.siguiente - 1;
  END IF;
  SELECT (p_siguiente - b.desde) - count(*) INTO v_falt FROM public.numero_emitido n
   WHERE n.bloque_id = b.id AND n.numero < p_siguiente;
  IF v_falt > 0 THEN
    RAISE EXCEPTION 'FALTAN_VENTAS_POR_SUBIR: faltan % venta(s) de este equipo por llegar al servidor.', v_falt;
  END IF;
  UPDATE public.numero_bloque SET estado = 'devuelto', siguiente = p_siguiente, devuelto_desde = p_siguiente,
         devuelto_en = now(), devuelto_por = auth.uid(), devolucion_id_operacion = p_id_operacion
   WHERE id = b.id
  RETURNING * INTO b;
  PERFORM interno.equipo_noticia(p_equipo_id);
  RETURN jsonb_build_object('bloque_id', b.id, 'estado', b.estado, 'devuelto_desde', b.devuelto_desde,
    'sin_usar', b.hasta - b.devuelto_desde + 1, 'ya_estaba', false);
END $$;

-- preparar_sin_internet(empresa, equipo, {"version"?, "caja_id"?})   ventas.sin_internet
-- Guarda la foto del catálogo (G5) y devuelve lo necesario para vender sin internet: catálogo (o "sin cambios" si el
-- equipo ya tiene esa versión), existencias para mirar, clientes, reglas, perfil sin internet (G1), bloques y hora.
CREATE FUNCTION public.preparar_sin_internet(p_empresa_id uuid, p_equipo_id uuid, p_datos jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e       public.empresa;
  q       public.equipo;
  t       public.turno_caja;
  c       public.caja;
  f       public.catalogo_foto;
  v_datos jsonb := coalesce(p_datos, '{}');
  v_cat   jsonb;
  v_hu    text;
  v_bod   uuid;
  v_ver   integer;
  v_lic   date;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.sin_internet', 'ventas');
  PERFORM interno.exigir_claves(v_datos, ARRAY['version', 'caja_id']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  q := interno.equipo_de(p_empresa_id, p_equipo_id, true);
  SELECT * INTO t FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
  SELECT x.* INTO c FROM public.caja x
   WHERE x.empresa_id = p_empresa_id AND x.activa
     AND x.id = coalesce(interno.json_uuid(v_datos->'caja_id', 'caja_id'), t.caja_id,
                         (SELECT b.caja_id FROM public.numero_bloque b WHERE b.equipo_id = q.id AND b.estado = 'activo' LIMIT 1));
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique la caja ("caja_id") o abra su turno de caja.';
  END IF;
  PERFORM interno.exigir_sucursal(p_empresa_id, c.sucursal_id);
  v_ver := interno.json_entero(v_datos->'version', 'version')::integer;

  v_cat := interno.armar_catalogo(p_empresa_id, c.sucursal_id);
  v_hu := md5(v_cat::text);
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO f FROM public.catalogo_foto x WHERE x.empresa_id = p_empresa_id AND x.sucursal_id = c.sucursal_id AND x.huella = v_hu;
  IF f.id IS NULL THEN
    INSERT INTO public.catalogo_foto (empresa_id, sucursal_id, version, huella, contenido, creado_por)
    VALUES (p_empresa_id, c.sucursal_id, interno.siguiente_numero(p_empresa_id, 'catalogo_foto')::integer, v_hu, v_cat, auth.uid())
    RETURNING * INTO f;
  END IF;
  IF (SELECT s.foto_version FROM interno.equipo_sync s WHERE s.equipo_id = q.id) IS DISTINCT FROM f.version THEN
    INSERT INTO public.catalogo_entrega (empresa_id, equipo_id, foto_id, entregado_a) VALUES (p_empresa_id, q.id, f.id, auth.uid());
  END IF;
  PERFORM interno.equipo_noticia(q.id, f.version);
  SELECT b.id INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = c.sucursal_id AND b.activa
   ORDER BY b.codigo LIMIT 1;
  SELECT l.vence_el + l.dias_gracia INTO v_lic FROM public.licencia l WHERE l.empresa_id = p_empresa_id;

  RETURN jsonb_build_object(
    'version', f.version,
    'sin_cambios', v_ver IS NOT DISTINCT FROM f.version,
    'catalogo', CASE WHEN v_ver IS DISTINCT FROM f.version THEN f.contenido END,
    'existencias', coalesce((SELECT jsonb_object_agg(s.producto_id::text, s.cantidad) FROM public.inventario_saldo s
                              WHERE s.bodega_id = v_bod), '{}'),
    'existencias_en', public.iso(now()),
    'clientes', coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre, 'rtn', x.rtn, 'es_mayorista', x.es_mayorista)
                             ORDER BY x.nombre) FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.es_cliente AND x.activo), '[]'),
    'reglas', jsonb_build_object('regimen_fiscal', interno.regimen_fiscal(p_empresa_id), 'documento_venta_modo', e.documento_venta_modo,
       'turnos_obligatorios', e.turnos_obligatorios, 'vendedor_cobra', e.vendedor_cobra, 'horas', e.sin_internet_horas,
       'tope_venta_centavos', e.sin_internet_tope_venta_centavos, 'tope_turno_centavos', e.sin_internet_tope_turno_centavos,
       'tarjeta', e.sin_internet_tarjeta, 'moneda', e.moneda, 'zona_horaria', e.zona_horaria),
    'emisor', jsonb_build_object('nombre', e.nombre, 'rtn', e.rtn, 'leyenda_factura', e.leyenda_factura),
    'perfil', jsonb_build_object('usuario_id', auth.uid(), 'empresa_id', p_empresa_id, 'rol', public.mi_rol(p_empresa_id),
       'nombre', public.nombre_usuario(p_empresa_id, auth.uid()),
       'permisos', (SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') FROM unnest(ARRAY['ventas.sin_internet', 'ventas.vender', 'ventas.cobrar',
                     'ventas.subir_ajenas', 'ventas.resolver_sin_internet']) x WHERE public.tiene_permiso(x, p_empresa_id)),
       'puede_cobrar', interno.puede_cobrar(p_empresa_id),
       'licencia_hasta', to_char(v_lic, 'YYYY-MM-DD')),
    'caja', jsonb_build_object('caja_id', c.id, 'nombre', c.nombre, 'sucursal_id', c.sucursal_id, 'bodega_id', v_bod),
    'turno', CASE WHEN t.id IS NOT NULL THEN jsonb_build_object('turno_id', t.id, 'numero', t.numero, 'caja_id', t.caja_id) END,
    'equipo', jsonb_build_object('equipo_id', q.id, 'nombre', q.nombre),
    'bloques', public.bloques_del_equipo(p_empresa_id, q.id)->'bloques',
    'hora_servidor', public.iso(now()),
    'valido_hasta', public.iso(now() + make_interval(hours => e.sin_internet_horas)));
END $$;

-- Una venta del equipo: revisar, guardar (siempre) y registrar o dejar por resolver.
CREATE FUNCTION interno.vsi_subir_una(p_empresa_id uuid, p_equipo public.equipo, x jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  vsi     public.venta_sin_internet;
  ya      public.venta_sin_internet;
  vv      public.venta;
  b       public.numero_bloque;
  r       jsonb;
  v_prob  text;
  v_txt   text;
  v_id    uuid;
  v_usu   uuid;
  v_num   bigint;
  v_hora  timestamptz;
  v_doc   text;
  v_ant   timestamptz;
  v_grave boolean := false;
BEGIN
  IF jsonb_typeof(x) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: cada venta es un objeto.';
  END IF;
  PERFORM interno.exigir_claves(x, ARRAY['id_operacion', 'usuario_id', 'caja_id', 'bloque_id', 'numero', 'numero_documento',
    'tipo_documento', 'foto_version', 'hora_equipo', 'cliente_id', 'lineas', 'pagos', 'total_centavos', 'en_linea', 'nota']);
  v_id := interno.json_uuid(x->'id_operacion', 'id_operacion');
  v_usu := interno.json_uuid(x->'usuario_id', 'usuario_id');
  IF v_id IS NULL OR v_usu IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: cada venta lleva "id_operacion" y "usuario_id".';
  END IF;
  -- Idempotente: la misma venta otra vez, o una que ya entró por registrar_venta (G2), es "ya estaba".
  SELECT * INTO ya FROM public.venta_sin_internet z WHERE z.empresa_id = p_empresa_id AND z.id_operacion = v_id;
  IF ya.id IS NOT NULL THEN
    RETURN jsonb_build_object('id_operacion', v_id, 'estado', 'ya_estaba', 'estado_venta', ya.estado, 'venta_id', ya.venta_id,
      'numero_documento', ya.numero_documento, 'problema', ya.problema, 'problema_texto', ya.problema_texto);
  END IF;
  SELECT * INTO vv FROM public.venta z WHERE z.empresa_id = p_empresa_id AND z.id_operacion = v_id;
  IF vv.id IS NOT NULL THEN
    RETURN jsonb_build_object('id_operacion', v_id, 'estado', 'ya_estaba', 'estado_venta', 'registrada', 'venta_id', vv.id,
      'numero_documento', vv.numero_documento);
  END IF;
  -- M2: las ventas de otro usuario las sube quien tiene ventas.subir_ajenas, con motivo.
  IF v_usu <> auth.uid() THEN
    IF NOT public.tiene_permiso('ventas.subir_ajenas', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: esa venta es de otro usuario; la sube él mismo o el dueño (permiso "ventas.subir_ajenas").';
    END IF;
    IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué sube las ventas de otro usuario (mínimo 5 letras).';
    END IF;
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, v_id, 'venta');
  IF jsonb_typeof(x->'lineas') IS DISTINCT FROM 'array' OR jsonb_array_length(x->'lineas') NOT BETWEEN 1 AND 100
     OR jsonb_typeof(x->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(x->'pagos') NOT BETWEEN 1 AND 2 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la venta lleva de 1 a 100 líneas y 1 o 2 formas de pago.';
  END IF;
  BEGIN
    v_hora := (x->>'hora_equipo')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "hora_equipo" va en ISO 8601 (2026-01-31T18:00:00Z).';
  END;
  v_num := interno.json_entero(x->'numero', 'numero');
  v_doc := interno.json_texto(x->'numero_documento', 'numero_documento', 30);

  vsi.id := gen_random_uuid();
  vsi.empresa_id := p_empresa_id;
  vsi.equipo_id := p_equipo.id;
  vsi.usuario_id := v_usu;
  vsi.id_operacion := v_id;
  vsi.caja_id := interno.json_uuid(x->'caja_id', 'caja_id');
  vsi.sucursal_id := (SELECT c.sucursal_id FROM public.caja c WHERE c.id = vsi.caja_id AND c.empresa_id = p_empresa_id);
  vsi.bloque_id := interno.json_uuid(x->'bloque_id', 'bloque_id');
  vsi.numero := v_num;
  vsi.numero_documento := v_doc;
  vsi.tipo_documento := interno.json_texto(x->'tipo_documento', 'tipo_documento', 20);
  vsi.foto_version := interno.json_entero(x->'foto_version', 'foto_version')::integer;
  vsi.total_centavos := interno.json_centavos(x->'total_centavos', 'total_centavos');
  vsi.en_linea := coalesce((x->>'en_linea')::boolean, false);
  vsi.hora_equipo := v_hora;
  vsi.recibido_en := now();
  vsi.payload := x;
  vsi.subido_por := auth.uid();
  vsi.motivo_subida := CASE WHEN v_usu <> auth.uid() THEN trim(p_motivo) END;

  -- El número (6.3): de su bloque, de este equipo y esta caja, sin repetir.
  SELECT * INTO b FROM public.numero_bloque z WHERE z.id = vsi.bloque_id AND z.empresa_id = p_empresa_id FOR UPDATE;
  IF NOT p_equipo.activo THEN
    v_prob := 'equipo_desactivado';
  END IF;
  IF b.id IS NULL OR b.equipo_id <> p_equipo.id OR b.caja_id IS DISTINCT FROM vsi.caja_id OR v_num IS NULL
     OR v_num NOT BETWEEN b.desde AND b.hasta OR b.tipo IS DISTINCT FROM vsi.tipo_documento
     OR v_doc IS DISTINCT FROM interno.numero_de_bloque(b, v_num) THEN
    v_prob := 'numero_invalido';
    b := NULL;
  ELSIF EXISTS (SELECT 1 FROM public.numero_emitido n WHERE n.empresa_id = p_empresa_id AND n.serie = b.serie AND n.numero = v_num) THEN
    v_prob := 'numero_repetido';
    b := NULL;
  ELSIF b.estado = 'conciliado' OR (b.estado = 'devuelto' AND v_num >= b.devuelto_desde) THEN
    v_prob := 'numero_invalido';
    b := NULL;
  ELSIF b.estado = 'por_conciliar' AND v_prob IS NULL THEN
    v_prob := 'bloque_por_conciliar';
  END IF;
  -- 11: la hora (no en el futuro, no antes de la reserva y después de la venta anterior del bloque).
  IF v_prob IS NULL THEN
    SELECT z.hora_equipo INTO v_ant FROM public.venta_sin_internet z
     WHERE z.bloque_id = b.id AND z.numero < v_num AND z.problema IS DISTINCT FROM 'reloj' ORDER BY z.numero DESC LIMIT 1;
    IF v_hora > now() + interval '10 minutes' OR v_hora < b.reservado_en - interval '10 minutes' OR v_hora < v_ant THEN
      v_prob := 'reloj';
    END IF;
  END IF;
  IF v_prob IS NULL THEN
    r := interno.vsi_revisar(vsi, 'subir', false);
    v_prob := r->>'problema';
    v_txt := r->>'texto';
  END IF;
  v_grave := coalesce(v_prob IN ('numero_invalido', 'numero_repetido'), false);
  vsi.estado := CASE WHEN v_prob IS NULL THEN 'registrada' ELSE 'por_resolver' END;
  vsi.problema := v_prob;
  vsi.problema_texto := CASE WHEN v_prob IS NOT NULL THEN coalesce(v_txt, interno.vsi_problema_texto(v_prob)) END;
  vsi.grave := v_grave;
  vsi.negativo := coalesce((r->>'negativo')::boolean, false);
  vsi.venta_id := (r->>'venta_id')::uuid;
  IF v_usu <> auth.uid() THEN
    PERFORM set_config('app.motivo', 'Subida por otro usuario: ' || trim(p_motivo), true);
  END IF;
  INSERT INTO public.venta_sin_internet VALUES (vsi.*);
  -- 6.3: el número queda gastado aunque la venta esté por resolver.
  IF b.id IS NOT NULL THEN
    INSERT INTO public.numero_emitido (empresa_id, bloque_id, serie, numero, numero_documento, venta_id, venta_sin_internet_id, estado)
    VALUES (p_empresa_id, b.id, b.serie, v_num, v_doc, vsi.venta_id, vsi.id, CASE WHEN v_prob IS NULL THEN 'registrado' ELSE 'por_resolver' END);
    UPDATE public.numero_bloque SET siguiente = greatest(siguiente, v_num + 1),
           ultima_hora_equipo = greatest(coalesce(ultima_hora_equipo, v_hora), v_hora)
     WHERE id = b.id;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('id_operacion', v_id, 'estado', vsi.estado, 'venta_id', vsi.venta_id, 'numero_documento', v_doc,
    'problema', v_prob, 'problema_texto', vsi.problema_texto, 'grave', v_grave, 'inventario_negativo', vsi.negativo);
END $$;

-- subir_ventas_sin_internet(empresa, equipo, ventas jsonb (1 a 20), motivo?)
-- ventas.sin_internet (o ventas.subir_ajenas). Funciona fuera del horario del puesto (M7: subir no es operar).
-- Cada venta en su propio paso: una que falla no detiene a las demás; una por resolver igual gasta su número.
CREATE FUNCTION public.subir_ventas_sin_internet(p_empresa_id uuid, p_equipo_id uuid, p_ventas jsonb, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  q      public.equipo;
  x      jsonb;
  r      jsonb;
  v_res  jsonb := '[]';
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  PERFORM interno.revisar_acceso(p_empresa_id, false);     -- sesión cerrada sí; horario no (M7)
  IF NOT (public.tiene_permiso('ventas.sin_internet', p_empresa_id) OR public.tiene_permiso('ventas.subir_ajenas', p_empresa_id)
          OR public.tiene_permiso('ventas.vender', p_empresa_id)) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.sin_internet".';
  END IF;
  IF NOT public.licencia_activa(p_empresa_id) THEN
    RAISE EXCEPTION 'LICENCIA_VENCIDA: el sistema está en modo solo lectura. Puede consultar y exportar.';
  END IF;
  IF NOT public.modulo_esta_activo(p_empresa_id, 'ventas') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "ventas" no está activo para esta empresa.';
  END IF;
  IF jsonb_typeof(p_ventas) IS DISTINCT FROM 'array' OR jsonb_array_length(p_ventas) NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: se suben de 1 a 20 ventas por vez.';
  END IF;
  q := interno.equipo_de(p_empresa_id, p_equipo_id, false);
  PERFORM interno.bloquear_libros(p_empresa_id);
  PERFORM interno.equipo_noticia(q.id);
  FOR x IN SELECT * FROM jsonb_array_elements(p_ventas) LOOP
    BEGIN
      r := interno.vsi_subir_una(p_empresa_id, q, x, p_motivo);
    EXCEPTION WHEN OTHERS THEN
      r := jsonb_build_object('id_operacion', x->'id_operacion', 'estado', 'rechazada',
                              'error', SQLERRM, 'clave', substring(SQLERRM FROM '^([A-Z][A-Z0-9_]+):'));
    END;
    v_res := v_res || r;
  END LOOP;
  RETURN jsonb_build_object('resultados', v_res, 'hora_servidor', public.iso(now()),
    'registradas', (SELECT count(*) FROM jsonb_array_elements(v_res) z WHERE z->>'estado' = 'registrada'),
    'por_resolver', (SELECT count(*) FROM jsonb_array_elements(v_res) z WHERE z->>'estado' = 'por_resolver'),
    'ya_estaban', (SELECT count(*) FROM jsonb_array_elements(v_res) z WHERE z->>'estado' = 'ya_estaba'),
    'rechazadas', (SELECT count(*) FROM jsonb_array_elements(v_res) z WHERE z->>'estado' = 'rechazada'));
END $$;

-- ventas_sin_internet_por_resolver(empresa, todas?)   ventas.resolver_sin_internet
CREATE FUNCTION public.ventas_sin_internet_por_resolver(p_empresa_id uuid, p_todas boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.resolver_sin_internet');
  RETURN jsonb_build_object('ventas', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'venta_sin_internet_id', z.id, 'estado', z.estado, 'problema', z.problema, 'problema_texto', z.problema_texto, 'grave', z.grave,
      'numero_documento', z.numero_documento, 'tipo_documento', z.tipo_documento, 'total_centavos', z.total_centavos,
      'hora_equipo', public.iso(z.hora_equipo), 'recibido_en', public.iso(z.recibido_en),
      'fecha', to_char((z.hora_equipo AT TIME ZONE e.zona_horaria)::date, 'YYYY-MM-DD'),
      'usuario_id', z.usuario_id, 'usuario', public.nombre_usuario(z.empresa_id, z.usuario_id),
      'equipo', q.nombre, 'caja', c.nombre, 'en_linea', z.en_linea, 'venta_id', z.venta_id,
      'subido_por', public.nombre_usuario(z.empresa_id, z.subido_por), 'motivo_resolucion', z.motivo_resolucion,
      'resuelto_por', public.nombre_usuario(z.empresa_id, z.resuelto_por),
      'pagos', z.payload->'pagos',
      'lineas', (SELECT jsonb_agg(jsonb_build_object('producto_id', l->'producto_id', 'nombre', p.nombre, 'cantidad', l->'cantidad',
                   'precio_unitario_centavos', l->'precio_unitario_centavos', 'total_centavos', l->'total_centavos') ORDER BY k)
                   FROM jsonb_array_elements(z.payload->'lineas') WITH ORDINALITY y(l, k)
                   LEFT JOIN public.producto p ON p.id::text = l->>'producto_id' AND p.empresa_id = z.empresa_id))
      ORDER BY z.grave DESC, z.hora_equipo)
    FROM public.venta_sin_internet z
    JOIN public.empresa e ON e.id = z.empresa_id
    JOIN public.equipo q ON q.id = z.equipo_id
    LEFT JOIN public.caja c ON c.id = z.caja_id
   WHERE z.empresa_id = p_empresa_id AND (z.estado = 'por_resolver' OR (p_todas AND z.problema IS NOT NULL))
     AND (z.sucursal_id IS NULL OR interno.sucursal_permitida(p_empresa_id, z.sucursal_id))), '[]'));
END $$;

-- resolver_venta_sin_internet(venta_sin_internet, 'registrar' | 'anular', motivo, id_operacion, {"a_mi_turno"?})
-- ventas.resolver_sin_internet. Registrar = como la venta original (con su fecha real; M5: un mes cerrado se reabre
-- primero). Anular = el número queda ANULADO y el dinero se trata como sobrante de caja hasta devolverlo.
CREATE FUNCTION public.resolver_venta_sin_internet(p_id uuid, p_accion text, p_motivo text, p_id_operacion uuid,
                                                   p_datos jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  z      public.venta_sin_internet;
  r      jsonb;
  v_datos jsonb := coalesce(p_datos, '{}');
BEGIN
  SELECT * INTO z FROM public.venta_sin_internet x WHERE x.id = p_id;
  IF z.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: esa venta sin internet no existe.';
  END IF;
  PERFORM interno.exigir_escritura(z.empresa_id, 'ventas.resolver_sin_internet', 'ventas');
  IF z.sucursal_id IS NOT NULL THEN
    PERFORM interno.exigir_sucursal(z.empresa_id, z.sucursal_id);
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(z.empresa_id, p_id_operacion, 'resolucion_venta_sin_internet');
  IF z.resolucion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('venta_sin_internet_id', z.id, 'estado', z.estado, 'venta_id', z.venta_id, 'ya_estaba', true);
  END IF;
  PERFORM interno.exigir_claves(v_datos, ARRAY['a_mi_turno']);
  IF coalesce(p_accion, '') NOT IN ('registrar', 'anular') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la acción es "registrar" o "anular".';
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se resuelve así (mínimo 5 letras).';
  END IF;
  PERFORM interno.reservar_operacion(z.empresa_id, p_id_operacion, 'resolucion_venta_sin_internet');
  SELECT * INTO z FROM public.venta_sin_internet x WHERE x.id = p_id FOR UPDATE;
  IF z.resolucion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('venta_sin_internet_id', z.id, 'estado', z.estado, 'venta_id', z.venta_id, 'ya_estaba', true);
  END IF;
  IF z.estado <> 'por_resolver' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: esa venta ya está %.', replace(z.estado, '_', ' ');
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  IF p_accion = 'anular' THEN
    UPDATE public.venta_sin_internet SET estado = 'anulada', resuelto_por = auth.uid(), resuelto_en = now(),
           motivo_resolucion = trim(p_motivo), resolucion_id_operacion = p_id_operacion
     WHERE id = z.id RETURNING * INTO z;
    UPDATE public.numero_emitido SET estado = 'anulado' WHERE venta_sin_internet_id = z.id AND estado = 'por_resolver';
  ELSE
    IF z.problema IN ('numero_invalido', 'numero_repetido') OR NOT EXISTS (
         SELECT 1 FROM public.numero_emitido n WHERE n.venta_sin_internet_id = z.id AND n.estado = 'por_resolver') THEN
      RAISE EXCEPTION 'VENTA_SIN_INTERNET_INVALIDA: el número % no es válido para registrarla; anúlela y regístrela como una venta normal.',
        coalesce(z.numero_documento, '?');
    END IF;
    r := interno.vsi_revisar(z, 'resolver', coalesce((v_datos->>'a_mi_turno')::boolean, false));
    IF r->>'problema' IS NOT NULL THEN
      RAISE EXCEPTION 'VENTA_SIN_INTERNET_INVALIDA: todavía no se puede registrar: %', r->>'texto';
    END IF;
    UPDATE public.venta_sin_internet SET estado = 'resuelta', venta_id = (r->>'venta_id')::uuid, resuelto_por = auth.uid(),
           resuelto_en = now(), motivo_resolucion = trim(p_motivo), resolucion_id_operacion = p_id_operacion,
           negativo = coalesce((r->>'negativo')::boolean, false)
     WHERE id = z.id RETURNING * INTO z;
    UPDATE public.numero_emitido SET estado = 'registrado', venta_id = z.venta_id WHERE venta_sin_internet_id = z.id;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('venta_sin_internet_id', z.id, 'estado', z.estado, 'venta_id', z.venta_id,
    'numero_documento', z.numero_documento, 'ya_estaba', false);
END $$;

-- conciliar_bloque(empresa, bloque, motivo, id_operacion)   equipos.administrar (G3)
-- Después de registrar desde las copias en papel lo que falta: los números que de verdad no se usaron quedan
-- "no usados" (se reportan a la SAR como diga el contador) y el bloque, conciliado.
CREATE FUNCTION public.conciliar_bloque(p_empresa_id uuid, p_bloque_id uuid, p_motivo text, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  b     public.numero_bloque;
  v_n   integer;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'equipos.administrar', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'conciliacion_bloque');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba cómo se revisaron las copias en papel (mínimo 5 letras).';
  END IF;
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'conciliacion_bloque');
  SELECT * INTO b FROM public.numero_bloque x WHERE x.id = p_bloque_id AND x.empresa_id = p_empresa_id FOR UPDATE;
  IF b.id IS NULL THEN
    RAISE EXCEPTION 'BLOQUE_INVALIDO: ese bloque de números no existe en esta empresa.';
  END IF;
  IF b.conciliacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('bloque_id', b.id, 'estado', b.estado, 'ya_estaba', true);
  END IF;
  IF b.estado <> 'por_conciliar' THEN
    RAISE EXCEPTION 'BLOQUE_INVALIDO: solo se concilia un bloque "por conciliar" (este está %).', replace(b.estado, '_', ' ');
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.numero_emitido (empresa_id, bloque_id, serie, numero, numero_documento, estado)
  SELECT p_empresa_id, b.id, b.serie, g, interno.numero_de_bloque(b, g), 'no_usado'
    FROM generate_series(b.desde, b.hasta) g
   WHERE NOT EXISTS (SELECT 1 FROM public.numero_emitido n WHERE n.empresa_id = p_empresa_id AND n.serie = b.serie AND n.numero = g);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.numero_bloque SET estado = 'conciliado', siguiente = hasta + 1, conciliado_en = now(), conciliado_por = auth.uid(),
         motivo_conciliacion = trim(p_motivo), conciliacion_id_operacion = p_id_operacion
   WHERE id = b.id RETURNING * INTO b;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('bloque_id', b.id, 'estado', b.estado, 'no_usados', v_n,
    'no_usados_lista', (SELECT coalesce(jsonb_agg(n.numero_documento ORDER BY n.numero), '[]') FROM public.numero_emitido n
                         WHERE n.bloque_id = b.id AND n.estado = 'no_usado'),
    'ya_estaba', false);
END $$;

-- bloques_sin_internet(empresa)   ventas.resolver_sin_internet o equipos.administrar
-- Equipos, sus bloques (usados, libres, por conciliar), última noticia, lo que hay por resolver y las reglas.
CREATE FUNCTION public.bloques_sin_internet(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.empresa;
BEGIN
  IF public.tiene_permiso('equipos.administrar', p_empresa_id) THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'equipos.administrar');
  ELSIF public.tiene_permiso('ventas.resolver_sin_internet', p_empresa_id) THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.resolver_sin_internet');
  ELSE
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.sin_internet');
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  RETURN jsonb_build_object(
    'reglas', jsonb_build_object('horas', e.sin_internet_horas, 'tope_venta_centavos', e.sin_internet_tope_venta_centavos,
      'tope_turno_centavos', e.sin_internet_tope_turno_centavos, 'tarjeta', e.sin_internet_tarjeta, 'bloque', e.sin_internet_bloque),
    'equipos', coalesce((SELECT jsonb_agg(jsonb_build_object('equipo_id', q.id, 'nombre', q.nombre, 'activo', q.activo,
        'registrado_en', public.iso(q.registrado_en), 'ultima_noticia', public.iso(s.ultima_en), 'foto_version', s.foto_version,
        'sin_noticias_48h', coalesce(s.ultima_en, q.registrado_en) < now() - interval '48 hours',
        'motivo_desactivacion', q.motivo_desactivacion) ORDER BY q.activo DESC, q.nombre)
      FROM public.equipo q LEFT JOIN interno.equipo_sync s ON s.equipo_id = q.id WHERE q.empresa_id = p_empresa_id), '[]'),
    'bloques', coalesce((SELECT jsonb_agg(jsonb_build_object('bloque_id', b.id, 'equipo_id', b.equipo_id, 'equipo', q.nombre,
        'caja', c.nombre, 'tipo', b.tipo, 'estado', b.estado, 'desde_texto', interno.numero_de_bloque(b, b.desde),
        'hasta_texto', interno.numero_de_bloque(b, b.hasta), 'siguiente', b.siguiente, 'desde', b.desde, 'hasta', b.hasta,
        'usados', (SELECT count(*) FROM public.numero_emitido n WHERE n.bloque_id = b.id AND n.estado <> 'no_usado'),
        'libres', greatest(0, b.hasta - b.siguiente + 1), 'reservado_en', public.iso(b.reservado_en),
        'motivo_por_conciliar', b.motivo_por_conciliar) ORDER BY b.estado = 'activo' DESC, b.reservado_en DESC)
      FROM public.numero_bloque b JOIN public.equipo q ON q.id = b.equipo_id JOIN public.caja c ON c.id = b.caja_id
     WHERE b.empresa_id = p_empresa_id AND (b.estado IN ('activo', 'por_conciliar') OR b.reservado_en > now() - interval '30 days')
       AND interno.sucursal_permitida(p_empresa_id, b.sucursal_id)), '[]'),
    'por_resolver', (SELECT count(*) FROM public.venta_sin_internet z WHERE z.empresa_id = p_empresa_id AND z.estado = 'por_resolver'));
END $$;

-- ---------------------------------------------------------------------
-- 9) Reglas de la empresa (configurar_empresa; solo el dueño)
-- ---------------------------------------------------------------------
ALTER FUNCTION public.configurar_empresa(uuid, jsonb, text) SET SCHEMA interno;
ALTER FUNCTION interno.configurar_empresa(uuid, jsonb, text) RENAME TO configurar_empresa_055;
CREATE FUNCTION public.configurar_empresa(p_empresa_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r       jsonb;
  v_nue   jsonb;
  v_claves text[] := ARRAY['sin_internet_horas', 'sin_internet_tope_venta_centavos', 'sin_internet_tope_turno_centavos',
                           'sin_internet_tarjeta', 'sin_internet_bloque'];
  e       public.empresa;
BEGIN
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' OR NOT (p_datos ?| v_claves) THEN
    RETURN interno.configurar_empresa_055(p_empresa_id, p_datos, p_motivo);
  END IF;
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  v_nue := (SELECT coalesce(jsonb_object_agg(k, p_datos->k), '{}') FROM unnest(v_claves) k WHERE p_datos ? k);
  IF (p_datos - v_claves) <> '{}'::jsonb THEN
    r := interno.configurar_empresa_055(p_empresa_id, p_datos - v_claves, p_motivo);
  END IF;
  IF v_nue ? 'sin_internet_tarjeta' AND jsonb_typeof(v_nue->'sin_internet_tarjeta') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "sin_internet_tarjeta" debe ser true o false.';
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id FOR UPDATE;
  IF v_nue ? 'sin_internet_horas' THEN
    e.sin_internet_horas := interno.json_entero(v_nue->'sin_internet_horas', 'sin_internet_horas')::integer;
  END IF;
  IF v_nue ? 'sin_internet_tope_venta_centavos' THEN
    e.sin_internet_tope_venta_centavos := interno.json_centavos(v_nue->'sin_internet_tope_venta_centavos', 'sin_internet_tope_venta_centavos');
  END IF;
  IF v_nue ? 'sin_internet_tope_turno_centavos' THEN
    e.sin_internet_tope_turno_centavos := interno.json_centavos(v_nue->'sin_internet_tope_turno_centavos', 'sin_internet_tope_turno_centavos');
  END IF;
  IF v_nue ? 'sin_internet_tarjeta' THEN
    e.sin_internet_tarjeta := (v_nue->>'sin_internet_tarjeta')::boolean;
  END IF;
  IF v_nue ? 'sin_internet_bloque' THEN
    e.sin_internet_bloque := CASE WHEN v_nue->'sin_internet_bloque' = 'null'::jsonb THEN NULL
                                  ELSE interno.json_entero(v_nue->'sin_internet_bloque', 'sin_internet_bloque')::integer END;
  END IF;
  IF e.sin_internet_horas IS NULL OR e.sin_internet_horas NOT BETWEEN 1 AND 168 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: las horas sin internet van de 1 a 168.';
  END IF;
  IF coalesce(e.sin_internet_tope_venta_centavos, 0) < 1 OR coalesce(e.sin_internet_tope_turno_centavos, 0) < 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los topes sin internet deben ser mayores que cero.';
  END IF;
  IF e.sin_internet_bloque IS NOT NULL AND e.sin_internet_bloque NOT BETWEEN 10 AND 5000 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el bloque de números es de 10 a 5000 (o null = el sugerido).';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET sin_internet_horas = e.sin_internet_horas, sin_internet_tope_venta_centavos = e.sin_internet_tope_venta_centavos,
         sin_internet_tope_turno_centavos = e.sin_internet_tope_turno_centavos, sin_internet_tarjeta = e.sin_internet_tarjeta,
         sin_internet_bloque = e.sin_internet_bloque
   WHERE id = p_empresa_id
     AND (sin_internet_horas, sin_internet_tope_venta_centavos, sin_internet_tope_turno_centavos, sin_internet_tarjeta, sin_internet_bloque)
         IS DISTINCT FROM (e.sin_internet_horas, e.sin_internet_tope_venta_centavos, e.sin_internet_tope_turno_centavos,
                           e.sin_internet_tarjeta, e.sin_internet_bloque);
  PERFORM set_config('app.motivo', '', true);
  RETURN coalesce(r, '{}'::jsonb) || jsonb_build_object('sin_internet_horas', e.sin_internet_horas,
    'sin_internet_tope_venta_centavos', e.sin_internet_tope_venta_centavos, 'sin_internet_tope_turno_centavos', e.sin_internet_tope_turno_centavos,
    'sin_internet_tarjeta', e.sin_internet_tarjeta, 'sin_internet_bloque', e.sin_internet_bloque);
END $$;

-- ---------------------------------------------------------------------
-- 10) Alertas: "Ventas sin internet" (solo se ve si la empresa tiene equipos registrados)
-- ---------------------------------------------------------------------
INSERT INTO public.alerta_tipo (codigo, nombre, descripcion, orden) VALUES
  ('sin_internet', 'Ventas sin internet', 'Ventas sin internet por resolver, números por conciliar o por agotarse, equipos sin noticias e inventario negativo por ventas sin internet', 13);

ALTER FUNCTION interno.puede_ver_alerta(uuid, text) RENAME TO puede_ver_alerta_055;
CREATE FUNCTION interno.puede_ver_alerta(p_empresa_id uuid, p_tipo text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN p_tipo = 'sin_internet'
              THEN EXISTS (SELECT 1 FROM public.equipo q WHERE q.empresa_id = p_empresa_id)
                   AND (public.puede_leer(p_empresa_id, 'ventas.resolver_sin_internet') OR public.puede_leer(p_empresa_id, 'equipos.administrar'))
              ELSE interno.puede_ver_alerta_055(p_empresa_id, p_tipo) END
$$;

ALTER FUNCTION interno.alertas_de(uuid, text) RENAME TO alertas_de_055;
CREATE FUNCTION interno.alertas_de(p_empresa_id uuid, p_tipo text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_a  jsonb := '[]';
  v_n  bigint;
  v_g  bigint;
  r    record;
BEGIN
  IF p_tipo <> 'sin_internet' THEN
    RETURN interno.alertas_de_055(p_empresa_id, p_tipo);
  END IF;
  SELECT count(*), count(*) FILTER (WHERE z.grave) INTO v_n, v_g FROM public.venta_sin_internet z
   WHERE z.empresa_id = p_empresa_id AND z.estado = 'por_resolver'
     AND (z.sucursal_id IS NULL OR interno.sucursal_permitida(p_empresa_id, z.sucursal_id));
  IF v_n > 0 THEN
    v_a := v_a || interno.alerta('sin_internet', CASE WHEN v_g > 0 THEN 'alta' ELSE 'media' END,
      'Ventas sin internet por resolver',
      v_n || ' venta(s) hecha(s) sin internet no se pudieron registrar solas' || CASE WHEN v_g > 0 THEN ' (' || v_g || ' grave(s): número repetido o fuera de su bloque)' ELSE '' END || '.',
      'Revíselas una por una: registrar o anular, con motivo.', '#/vender/por_resolver', jsonb_build_object('cantidad', v_n, 'graves', v_g));
  END IF;
  FOR r IN SELECT b.*, q.nombre AS equipo, c.nombre AS caja FROM public.numero_bloque b JOIN public.equipo q ON q.id = b.equipo_id
             JOIN public.caja c ON c.id = b.caja_id
            WHERE b.empresa_id = p_empresa_id AND b.estado = 'por_conciliar' AND interno.sucursal_permitida(p_empresa_id, b.sucursal_id) LOOP
    v_a := v_a || interno.alerta('sin_internet', 'alta', 'Números por conciliar',
      'Los números ' || r.prefijo || '-' || lpad(r.desde::text, 8, '0') || ' a ' || r.prefijo || '-' || lpad(r.hasta::text, 8, '0')
        || ' del equipo "' || r.equipo || '" (caja "' || r.caja || '") están por conciliar.',
      'Registre las ventas que falten a partir de las copias en papel y concilie el bloque: los números no usados se reportan como diga el contador.',
      '#/ajustes/sin_internet', jsonb_build_object('bloque_id', r.id));
  END LOOP;
  FOR r IN SELECT b.*, q.nombre AS equipo, c.nombre AS caja, s.ultima_en FROM public.numero_bloque b JOIN public.equipo q ON q.id = b.equipo_id
             JOIN public.caja c ON c.id = b.caja_id LEFT JOIN interno.equipo_sync s ON s.equipo_id = b.equipo_id
            WHERE b.empresa_id = p_empresa_id AND b.estado = 'activo' AND interno.sucursal_permitida(p_empresa_id, b.sucursal_id) LOOP
    IF coalesce(r.ultima_en, r.reservado_en) < now() - interval '48 hours' THEN
      v_a := v_a || interno.alerta('sin_internet', 'alta', 'Equipo sin noticias',
        'El equipo "' || r.equipo || '" (caja "' || r.caja || '") no se conecta hace más de 48 horas y tiene números reservados.',
        'Si el equipo se perdió o se dañó, desactívelo: sus números quedan por conciliar.', '#/ajustes/sin_internet', jsonb_build_object('bloque_id', r.id));
    ELSIF (r.hasta - r.siguiente + 1) <= greatest(5, (r.hasta - r.desde + 1) / 5) THEN
      v_a := v_a || interno.alerta('sin_internet', 'media', 'Quedan pocos números sin internet',
        'Al equipo "' || r.equipo || '" le quedan ' || greatest(0, r.hasta - r.siguiente + 1) || ' número(s) reservados.',
        'Con internet, prepare el equipo otra vez para reservar más números.', '#/ajustes/sin_internet', jsonb_build_object('bloque_id', r.id));
    END IF;
  END LOOP;
  SELECT count(*) INTO v_n FROM public.venta_sin_internet z
   WHERE z.empresa_id = p_empresa_id AND z.negativo AND z.recibido_en > now() - interval '30 days'
     AND (z.sucursal_id IS NULL OR interno.sucursal_permitida(p_empresa_id, z.sucursal_id));
  IF v_n > 0 THEN
    v_a := v_a || interno.alerta('sin_internet', 'media', 'Inventario negativo por ventas sin internet',
      v_n || ' venta(s) sin internet dejaron existencia negativa (dos equipos vendieron lo último).',
      'Corrija con un conteo antes de registrar compras con fecha atrasada (ENTRADA_FECHA_ATRASADA).', '#/inventario/existencias',
      jsonb_build_object('cantidad', v_n));
  END IF;
  RETURN v_a;
END $$;

-- ---------------------------------------------------------------------
-- 11) Seguridad de las funciones
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.proteger_equipo(), interno.proteger_numero_bloque(), interno.proteger_numero_emitido(),
  interno.proteger_venta_sin_internet(), interno.foto_venta(), interno.armar_catalogo(uuid, uuid),
  interno.foto_de_venta(jsonb, jsonb), interno.numero_de_bloque(public.numero_bloque, bigint),
  interno.asignar_numero_fiscal(uuid, uuid, text, date), interno.siguiente_ticket(uuid, uuid), interno.turno_con_bloque(),
  interno.equipo_de(uuid, uuid, boolean), interno.equipo_noticia(uuid, integer), interno.vsi_como(uuid), interno.vsi_volver(jsonb),
  interno.vsi_problema_texto(text), interno.vsi_problema_de_error(text), interno.json_entero(jsonb, text), interno.vsi_cuadra(jsonb, jsonb), interno.vsi_lineas(jsonb),
  interno.vsi_registrar(public.venta_sin_internet, jsonb, jsonb), interno.vsi_revisar(public.venta_sin_internet, text, boolean),
  interno.tamano_bloque(uuid, uuid), interno.vsi_subir_una(uuid, public.equipo, jsonb, text),
  interno.configurar_empresa_055(uuid, jsonb, text), interno.puede_ver_alerta(uuid, text), interno.alertas_de(uuid, text)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.registrar_equipo(uuid, jsonb, uuid), public.desactivar_equipo(uuid, uuid, text),
  public.reservar_bloque_numeros(uuid, uuid, uuid, jsonb), public.bloques_del_equipo(uuid, uuid),
  public.devolver_bloque(uuid, uuid, uuid, bigint, uuid), public.preparar_sin_internet(uuid, uuid, jsonb),
  public.subir_ventas_sin_internet(uuid, uuid, jsonb, text), public.ventas_sin_internet_por_resolver(uuid, boolean),
  public.resolver_venta_sin_internet(uuid, text, text, uuid, jsonb), public.conciliar_bloque(uuid, uuid, text, uuid),
  public.bloques_sin_internet(uuid), public.configurar_empresa(uuid, jsonb, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.registrar_equipo(uuid, jsonb, uuid), public.desactivar_equipo(uuid, uuid, text),
  public.reservar_bloque_numeros(uuid, uuid, uuid, jsonb), public.bloques_del_equipo(uuid, uuid),
  public.devolver_bloque(uuid, uuid, uuid, bigint, uuid), public.preparar_sin_internet(uuid, uuid, jsonb),
  public.subir_ventas_sin_internet(uuid, uuid, jsonb, text), public.ventas_sin_internet_por_resolver(uuid, boolean),
  public.resolver_venta_sin_internet(uuid, text, text, uuid, jsonb), public.conciliar_bloque(uuid, uuid, text, uuid),
  public.bloques_sin_internet(uuid), public.configurar_empresa(uuid, jsonb, text)
TO authenticated;
