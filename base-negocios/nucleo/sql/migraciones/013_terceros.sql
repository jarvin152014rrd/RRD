-- =====================================================================
-- 013_terceros.sql  -  Clientes y proveedores en UNA tabla
--
-- Un tercero puede ser cliente, proveedor o los dos (es_cliente /
-- es_proveedor). Todo se liga por id, nunca por nombre.
-- Nunca se borra: se desactiva. Cada cambio queda en bitácora (antes y
-- después), con motivo cuando se da.
--
--   crear_tercero(empresa, datos, id_operacion)       terceros.editar
--   editar_tercero(empresa, tercero, datos, motivo?)   terceros.editar
--        límite de crédito y plazo además piden        terceros.credito
--        (y quien no es dueño no pasa el tope de la empresa)
--   desactivar_tercero(empresa, tercero, motivo)       terceros.desactivar
--
-- Formato de "datos" (solo las claves que se quieren poner o cambiar):
--   {"nombre": "Ferretería Lara", "es_proveedor": true, "es_cliente": false,
--    "tipo_persona": "juridica", "rtn": "0801-1999-000012", "telefono": "9999-8888",
--    "correo": "ventas@lara.hn", "direccion": "...",
--    "limite_credito_centavos": 500000, "plazo_dias": 30}
-- El RTN y el teléfono aceptan guiones y espacios; se guardan solo dígitos.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('RTN_INVALIDO',     'El RTN no tiene el formato correcto.', 'El RTN tiene 14 dígitos (puede escribirlo con o sin guiones).'),
  ('TERCERO_INVALIDO', 'El cliente o proveedor elegido no se puede usar.', 'Revise que exista, esté activo y tenga el rol correcto (cliente o proveedor).');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('terceros.editar',     'Crear y editar clientes y proveedores (datos de contacto)', false, false),
  ('terceros.credito',    'Fijar límite de crédito y plazo de clientes y proveedores', false, false),
  ('terceros.desactivar', 'Desactivar clientes y proveedores',                         false, false);

INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'terceros.editar'), ('dueno', 'terceros.credito'), ('dueno', 'terceros.desactivar'),
  ('admin', 'terceros.editar'), ('admin', 'terceros.credito'), ('admin', 'terceros.desactivar'),
  ('cajero', 'terceros.editar'),
  ('vendedor', 'terceros.editar');

SELECT interno.repartir_permisos(ARRAY['terceros.editar', 'terceros.credito', 'terceros.desactivar'],
  'Núcleo 0.3.0: permisos nuevos de clientes y proveedores');

-- ---------------------------------------------------------------------
-- Ayudantes para leer datos jsonb (los usan 013-016)
-- ---------------------------------------------------------------------
-- uuid desde jsonb; NULL si no viene; error claro si viene mal.
CREATE FUNCTION interno.json_uuid(p_valor jsonb, p_campo text) RETURNS uuid
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_valor IS NULL OR p_valor = 'null'::jsonb THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_valor) <> 'string'
     OR NOT (p_valor #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser un identificador (uuid).', p_campo;
  END IF;
  RETURN (p_valor #>> '{}')::uuid;
END $$;

-- Texto desde jsonb (recortado); NULL si no viene o viene vacío.
CREATE FUNCTION interno.json_texto(p_valor jsonb, p_campo text, p_max integer DEFAULT 200) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text;
BEGIN
  IF p_valor IS NULL OR p_valor = 'null'::jsonb THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_valor) <> 'string' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser texto.', p_campo;
  END IF;
  v := nullif(trim(p_valor #>> '{}'), '');
  IF length(v) > p_max THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "%" es demasiado largo (máximo % letras).', p_campo, p_max;
  END IF;
  RETURN v;
END $$;

-- Entero de centavos desde jsonb (0 .. tope JavaScript).
CREATE FUNCTION interno.json_centavos(p_valor jsonb, p_campo text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_valor IS NULL OR jsonb_typeof(p_valor) <> 'number'
     OR (p_valor #>> '{}') !~ '^[0-9]{1,16}$'
     OR (p_valor #>> '{}')::numeric > 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser un entero de centavos, 0 o más (L 1.00 = 100).', p_campo;
  END IF;
  RETURN (p_valor #>> '{}')::bigint;
END $$;

-- Sí/no desde jsonb.
CREATE FUNCTION interno.json_si_no(p_valor jsonb, p_campo text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_valor IS NULL OR jsonb_typeof(p_valor) <> 'boolean' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser true o false.', p_campo;
  END IF;
  RETURN (p_valor #>> '{}')::boolean;
END $$;

-- Revisa que un objeto jsonb solo traiga claves conocidas.
CREATE FUNCTION interno.exigir_claves(p_datos jsonb, p_permitidas text[]) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE k text;
BEGIN
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_datos) LOOP
    IF NOT k = ANY (p_permitidas) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce (¿está bien escrito?).', k;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- Tabla
-- ---------------------------------------------------------------------
CREATE TABLE public.tercero (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  es_cliente               boolean NOT NULL DEFAULT false,
  es_proveedor             boolean NOT NULL DEFAULT false,
  tipo_persona             text NOT NULL DEFAULT 'natural' CHECK (tipo_persona IN ('natural', 'juridica')),
  nombre                   text NOT NULL CHECK (length(trim(nombre)) > 0),
  rtn                      text CHECK (rtn IS NULL OR rtn ~ '^[0-9]{14}$'),
  telefono                 text CHECK (telefono IS NULL OR telefono ~ '^\+?[0-9]{8,15}$'),
  correo                   text CHECK (correo IS NULL OR correo ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  direccion                text,
  limite_credito_centavos  bigint  NOT NULL DEFAULT 0 CHECK (limite_credito_centavos BETWEEN 0 AND 9007199254740991),
  plazo_dias               integer NOT NULL DEFAULT 0 CHECK (plazo_dias BETWEEN 0 AND 365),
  activo                   boolean NOT NULL DEFAULT true,
  id_operacion             uuid NOT NULL,
  creado_por               uuid,
  creado_en                timestamptz NOT NULL DEFAULT now(),
  actualizado_en           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion),
  CHECK (es_cliente OR es_proveedor)
);
-- Un RTN no se repite dentro de la empresa.
CREATE UNIQUE INDEX tercero_rtn ON public.tercero (empresa_id, rtn) WHERE rtn IS NOT NULL;
CREATE INDEX tercero_nombre ON public.tercero (empresa_id, lower(nombre));

-- Lo que nunca cambia: id, empresa, id_operacion, quién y cuándo lo creó.
CREATE FUNCTION interno.proteger_tercero() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.id_operacion, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.id_operacion, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: no se puede cambiar el id, la empresa ni quién creó el registro.';
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;

CREATE TRIGGER proteger BEFORE UPDATE ON public.tercero
  FOR EACH ROW EXECUTE FUNCTION interno.proteger_tercero();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.tercero
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.tercero
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive el cliente o proveedor en vez de borrarlo.');

-- ---------------------------------------------------------------------
-- Aplica "datos" sobre un tercero (nuevo o existente) y valida todo.
-- No guarda: devuelve la fila lista para guardar.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.aplicar_datos_tercero(t public.tercero, p_datos jsonb) RETURNS public.tercero
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  PERFORM interno.exigir_claves(p_datos, ARRAY['nombre','es_cliente','es_proveedor','tipo_persona','rtn',
    'telefono','correo','direccion','limite_credito_centavos','plazo_dias']);

  IF p_datos ? 'nombre' THEN
    t.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 200);
    IF t.nombre IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre del cliente o proveedor.';
    END IF;
  END IF;
  IF p_datos ? 'es_cliente'   THEN t.es_cliente   := interno.json_si_no(p_datos->'es_cliente', 'es_cliente'); END IF;
  IF p_datos ? 'es_proveedor' THEN t.es_proveedor := interno.json_si_no(p_datos->'es_proveedor', 'es_proveedor'); END IF;
  IF NOT (t.es_cliente OR t.es_proveedor) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si es cliente, proveedor o los dos.';
  END IF;
  IF p_datos ? 'tipo_persona' THEN
    t.tipo_persona := interno.json_texto(p_datos->'tipo_persona', 'tipo_persona', 20);
    IF t.tipo_persona IS NULL OR t.tipo_persona NOT IN ('natural', 'juridica') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "tipo_persona" es "natural" o "juridica".';
    END IF;
  END IF;
  IF p_datos ? 'rtn' THEN
    v := regexp_replace(coalesce(interno.json_texto(p_datos->'rtn', 'rtn', 40), ''), '[[:space:]-]', '', 'g');
    IF v <> '' AND v !~ '^[0-9]{14}$' THEN
      RAISE EXCEPTION 'RTN_INVALIDO: el RTN "%" debe tener 14 dígitos.', p_datos->>'rtn';
    END IF;
    t.rtn := nullif(v, '');
  END IF;
  IF p_datos ? 'telefono' THEN
    v := regexp_replace(coalesce(interno.json_texto(p_datos->'telefono', 'telefono', 40), ''), '[[:space:]().-]', '', 'g');
    IF v <> '' AND v !~ '^\+?[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el teléfono "%" no es válido (8 a 15 dígitos, ej. 9999-8888).', p_datos->>'telefono';
    END IF;
    t.telefono := nullif(v, '');
  END IF;
  IF p_datos ? 'correo' THEN
    v := lower(interno.json_texto(p_datos->'correo', 'correo', 200));
    IF v IS NOT NULL AND v !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el correo "%" no es válido.', p_datos->>'correo';
    END IF;
    t.correo := v;
  END IF;
  IF p_datos ? 'direccion' THEN
    t.direccion := interno.json_texto(p_datos->'direccion', 'direccion', 500);
  END IF;
  IF p_datos ? 'limite_credito_centavos' THEN
    t.limite_credito_centavos := interno.json_centavos(p_datos->'limite_credito_centavos', 'limite_credito_centavos');
  END IF;
  IF p_datos ? 'plazo_dias' THEN
    IF jsonb_typeof(p_datos->'plazo_dias') <> 'number' OR (p_datos->>'plazo_dias') !~ '^[0-9]{1,3}$'
       OR (p_datos->>'plazo_dias')::integer > 365 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "plazo_dias" debe ser un número entero de 0 a 365.';
    END IF;
    t.plazo_dias := (p_datos->>'plazo_dias')::integer;
  END IF;
  RETURN t;
END $$;

-- Crédito: pide terceros.credito; quien no es dueño no pasa el tope.
CREATE FUNCTION interno.revisar_credito(p_empresa_id uuid, p_nuevo public.tercero, p_antes public.tercero)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_tope bigint;
BEGIN
  IF (p_nuevo.limite_credito_centavos, p_nuevo.plazo_dias)
     IS NOT DISTINCT FROM (coalesce(p_antes.limite_credito_centavos, 0), coalesce(p_antes.plazo_dias, 0)) THEN
    RETURN;
  END IF;
  IF NOT public.tiene_permiso('terceros.credito', p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "terceros.credito" (límite de crédito y plazo).';
  END IF;
  SELECT e.tope_credito_centavos INTO v_tope FROM public.empresa e WHERE e.id = p_empresa_id;
  IF public.mi_rol(p_empresa_id) <> 'dueno'
     AND p_nuevo.limite_credito_centavos > coalesce(p_antes.limite_credito_centavos, 0)
     AND p_nuevo.limite_credito_centavos > v_tope THEN
    RAISE EXCEPTION 'TOPE_CREDITO: el límite (% centavos) pasa el tope que fijó el dueño (% centavos).',
      p_nuevo.limite_credito_centavos, v_tope;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- RPC: crear_tercero. Reintento con el mismo id_operacion = mismo tercero.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.crear_tercero(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t     public.tercero;
  v_id  uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'terceros.editar', NULL);
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  SELECT x.id INTO v_id FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF FOUND THEN
    RETURN jsonb_build_object('tercero_id', v_id, 'duplicado', true);
  END IF;
  IF NOT (coalesce(p_datos, '{}') ? 'nombre') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre del cliente o proveedor.';
  END IF;

  t.empresa_id := p_empresa_id;
  t.es_cliente := false; t.es_proveedor := false; t.tipo_persona := 'natural';
  t.limite_credito_centavos := 0; t.plazo_dias := 0;
  t := interno.aplicar_datos_tercero(t, p_datos);
  PERFORM interno.revisar_credito(p_empresa_id, t, NULL);

  BEGIN
    INSERT INTO public.tercero (empresa_id, es_cliente, es_proveedor, tipo_persona, nombre, rtn, telefono,
                                correo, direccion, limite_credito_centavos, plazo_dias, id_operacion, creado_por)
    VALUES (p_empresa_id, t.es_cliente, t.es_proveedor, t.tipo_persona, t.nombre, t.rtn, t.telefono,
            t.correo, t.direccion, t.limite_credito_centavos, t.plazo_dias, p_id_operacion, auth.uid())
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT x.id INTO v_id FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
    IF FOUND THEN
      RETURN jsonb_build_object('tercero_id', v_id, 'duplicado', true);
    END IF;
    RAISE EXCEPTION 'YA_EXISTE: ya hay un cliente o proveedor con el RTN %.', t.rtn;
  END;
  RETURN jsonb_build_object('tercero_id', v_id, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: editar_tercero. Cambia solo las claves enviadas. El "antes" y
-- "después" quedan en la bitácora (con el motivo si se da).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.editar_tercero(p_empresa_id uuid, p_tercero_id uuid, p_datos jsonb,
                                      p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_antes public.tercero;
  t       public.tercero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'terceros.editar', NULL);
  SELECT * INTO v_antes FROM public.tercero
   WHERE id = p_tercero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_antes.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cliente o proveedor no existe en esta empresa.';
  END IF;
  t := interno.aplicar_datos_tercero(v_antes, p_datos);
  PERFORM interno.revisar_credito(p_empresa_id, t, v_antes);

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  BEGIN
    UPDATE public.tercero SET
      es_cliente = t.es_cliente, es_proveedor = t.es_proveedor, tipo_persona = t.tipo_persona,
      nombre = t.nombre, rtn = t.rtn, telefono = t.telefono, correo = t.correo, direccion = t.direccion,
      limite_credito_centavos = t.limite_credito_centavos, plazo_dias = t.plazo_dias
    WHERE id = p_tercero_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay otro cliente o proveedor con el RTN %.', t.rtn;
  END;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('tercero_id', p_tercero_id, 'editado', true);
END $$;

-- RPC: desactivar_tercero (nunca se borra). Seguro de reintentar.
CREATE FUNCTION public.desactivar_tercero(p_empresa_id uuid, p_tercero_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_t public.tercero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'terceros.desactivar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_t FROM public.tercero WHERE id = p_tercero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_t.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cliente o proveedor no existe en esta empresa.';
  END IF;
  IF NOT v_t.activo THEN
    RETURN jsonb_build_object('tercero_id', p_tercero_id, 'activo', false, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.tercero SET activo = false WHERE id = p_tercero_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('tercero_id', p_tercero_id, 'activo', false, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- Seguridad: lectura para los miembros de la empresa; escritura solo RPC.
-- ---------------------------------------------------------------------
ALTER TABLE public.tercero ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.tercero FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.tercero
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
GRANT SELECT ON public.tercero TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  public.crear_tercero(uuid, jsonb, uuid),
  public.editar_tercero(uuid, uuid, jsonb, text),
  public.desactivar_tercero(uuid, uuid, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_tercero(uuid, jsonb, uuid),
  public.editar_tercero(uuid, uuid, jsonb, text),
  public.desactivar_tercero(uuid, uuid, text)
TO authenticated;
