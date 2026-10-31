-- =====================================================================
-- 014_productos.sql  -  Catálogo de productos (módulo "inventario")
--
--   unidad               unidades de medida: comunes (para todos) + propias
--   categoria_producto   categorías con madre opcional (hasta 3 niveles)
--   campo_extra          campos extra que define cada empresa (ej. "talla")
--   producto             código interno y código de barras únicos por
--                        empresa, impuesto, precio de venta en centavos...
--   producto_precio      historial de precios (motivo, usuario, fecha);
--                        lo llena un trigger: ningún cambio se salta.
--
-- RPC (permiso productos.editar, salvo el precio: productos.precios):
--   crear_unidad, crear_categoria, desactivar_categoria,
--   crear_campo_extra, desactivar_campo_extra,
--   crear_producto, editar_producto, desactivar_producto,
--   cambiar_precio_producto
-- Bodegas, existencias y la búsqueda por código de barras: 015.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('PRODUCTO_INVALIDO',    'El producto elegido no se puede usar.', 'Revise que el producto exista y esté activo.'),
  ('CAMPO_EXTRA_INVALIDO', 'Un campo extra tiene un dato incorrecto o falta.', 'Revise los campos extra del producto (tipo de dato y los obligatorios).');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('productos.editar',  'Crear y editar productos, categorías, unidades y campos extra', false, false),
  ('productos.precios', 'Cambiar el precio de venta de los productos',                   false, false);

INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'productos.editar'), ('dueno', 'productos.precios'),
  ('admin', 'productos.editar'), ('admin', 'productos.precios');

SELECT interno.repartir_permisos(ARRAY['productos.editar', 'productos.precios'],
  'Núcleo 0.3.0: permisos nuevos del catálogo de productos');

-- ---------------------------------------------------------------------
-- Unidades. empresa_id NULL = unidad común para todas las empresas.
-- ---------------------------------------------------------------------
CREATE TABLE public.unidad (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id  uuid REFERENCES public.empresa(id),
  codigo      text NOT NULL CHECK (codigo ~ '^[A-Z0-9]{1,10}$'),
  nombre      text NOT NULL CHECK (length(trim(nombre)) > 0),
  activa      boolean NOT NULL DEFAULT true,
  creado_en   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX unidad_codigo ON public.unidad
  ((coalesce(empresa_id, '00000000-0000-0000-0000-000000000000'::uuid)), codigo);

INSERT INTO public.unidad (codigo, nombre) VALUES
  ('UND', 'Unidad'), ('KG', 'Kilogramo'), ('G', 'Gramo'), ('LB', 'Libra'),
  ('LT', 'Litro'), ('ML', 'Mililitro'), ('GAL', 'Galón'), ('M', 'Metro'),
  ('CAJA', 'Caja'), ('PAQ', 'Paquete'), ('DOC', 'Docena'), ('PAR', 'Par');

-- ---------------------------------------------------------------------
-- Categorías (nivel 1 = sin madre; máximo 3 niveles)
-- ---------------------------------------------------------------------
CREATE TABLE public.categoria_producto (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  padre_id    uuid,
  nombre      text NOT NULL CHECK (length(trim(nombre)) > 0),
  nivel       smallint NOT NULL CHECK (nivel BETWEEN 1 AND 3),
  activa      boolean NOT NULL DEFAULT true,
  creado_en   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, padre_id) REFERENCES public.categoria_producto(empresa_id, id)
);
CREATE UNIQUE INDEX categoria_nombre ON public.categoria_producto
  (empresa_id, (coalesce(padre_id, '00000000-0000-0000-0000-000000000000'::uuid)), lower(nombre));

-- ---------------------------------------------------------------------
-- Campos extra por empresa (hoy solo para "producto")
-- ---------------------------------------------------------------------
CREATE TABLE public.campo_extra (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id   uuid NOT NULL REFERENCES public.empresa(id),
  entidad      text NOT NULL CHECK (entidad IN ('producto')),
  clave        text NOT NULL CHECK (clave ~ '^[a-z][a-z0-9_]{0,39}$'),
  etiqueta     text NOT NULL CHECK (length(trim(etiqueta)) > 0),
  tipo         text NOT NULL CHECK (tipo IN ('texto', 'numero', 'entero', 'fecha', 'si_no', 'lista')),
  opciones     jsonb,                                   -- lista: ["S","M","L"]
  obligatorio  boolean NOT NULL DEFAULT false,
  activo       boolean NOT NULL DEFAULT true,
  creado_en    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, entidad, clave),
  CHECK ((tipo = 'lista') = (opciones IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- Productos
-- ---------------------------------------------------------------------
CREATE TABLE public.producto (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id             uuid NOT NULL REFERENCES public.empresa(id),
  codigo                 text NOT NULL CHECK (codigo ~ '^[A-Z0-9._/-]{1,30}$'),        -- código interno
  codigo_barras          text CHECK (codigo_barras IS NULL OR codigo_barras ~ '^[A-Za-z0-9-]{4,48}$'),
  nombre                 text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 200),
  categoria_id           uuid,
  unidad_id              uuid NOT NULL REFERENCES public.unidad(id),
  tipo_impuesto          text NOT NULL DEFAULT 'ISV15' CHECK (tipo_impuesto IN ('ISV15', 'ISV18', 'EXENTO')),
  -- Precio de venta por unidad, en centavos, SIN ISV (el ISV se suma al facturar).
  precio_venta_centavos  bigint NOT NULL DEFAULT 0 CHECK (precio_venta_centavos BETWEEN 0 AND 9007199254740991),
  stock_minimo           numeric(18,4) NOT NULL DEFAULT 0 CHECK (stock_minimo >= 0),
  permite_fracciones     boolean NOT NULL DEFAULT false,
  activo                 boolean NOT NULL DEFAULT true,
  campos_extra           jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(campos_extra) = 'object'),
  id_operacion           uuid NOT NULL,
  creado_por             uuid,
  creado_en              timestamptz NOT NULL DEFAULT now(),
  actualizado_en         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, categoria_id) REFERENCES public.categoria_producto(empresa_id, id)
);
CREATE UNIQUE INDEX producto_codigo ON public.producto (empresa_id, codigo);
CREATE UNIQUE INDEX producto_codigo_barras ON public.producto (empresa_id, codigo_barras) WHERE codigo_barras IS NOT NULL;
CREATE INDEX producto_nombre ON public.producto (empresa_id, lower(nombre));

-- Historial de precios: solo agregar.
CREATE TABLE public.producto_precio (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id                uuid NOT NULL,
  producto_id               uuid NOT NULL,
  precio_anterior_centavos  bigint,                      -- NULL = precio inicial
  precio_nuevo_centavos     bigint NOT NULL,
  motivo                    text NOT NULL,
  cambiado_por              uuid,
  cambiado_en               timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id)
);
CREATE INDEX producto_precio_producto ON public.producto_precio (producto_id, id);

-- Defensa de tabla: la unidad debe ser común o de la misma empresa; lo
-- que nunca cambia; y todo cambio de precio deja su historial (con motivo).
CREATE FUNCTION interno.proteger_producto() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.unidad u WHERE u.id = NEW.unidad_id
                  AND (u.empresa_id IS NULL OR u.empresa_id = NEW.empresa_id)) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la unidad de medida no existe para esta empresa.';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.id, NEW.empresa_id, NEW.id_operacion, NEW.creado_por, NEW.creado_en)
       IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.id_operacion, OLD.creado_por, OLD.creado_en) THEN
      RAISE EXCEPTION 'PROHIBIDO: no se puede cambiar el id, la empresa ni quién creó el producto.';
    END IF;
    NEW.actualizado_en := now();
    IF NEW.precio_venta_centavos IS DISTINCT FROM OLD.precio_venta_centavos THEN
      IF length(trim(coalesce(current_setting('app.motivo', true), ''))) < 5 THEN
        RAISE EXCEPTION 'FALTA_MOTIVO: todo cambio de precio necesita motivo (mínimo 5 letras).';
      END IF;
      INSERT INTO public.producto_precio (empresa_id, producto_id, precio_anterior_centavos,
                                          precio_nuevo_centavos, motivo, cambiado_por)
      VALUES (NEW.empresa_id, NEW.id, OLD.precio_venta_centavos, NEW.precio_venta_centavos,
              trim(current_setting('app.motivo', true)), auth.uid());
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER proteger BEFORE INSERT OR UPDATE ON public.producto
  FOR EACH ROW EXECUTE FUNCTION interno.proteger_producto();

-- Precio inicial al historial (después de insertar, por la llave foránea).
CREATE FUNCTION interno.precio_inicial() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.producto_precio (empresa_id, producto_id, precio_anterior_centavos,
                                      precio_nuevo_centavos, motivo, cambiado_por)
  VALUES (NEW.empresa_id, NEW.id, NULL, NEW.precio_venta_centavos, 'Precio inicial', auth.uid());
  RETURN NULL;
END $$;

CREATE TRIGGER precio_inicial AFTER INSERT ON public.producto
  FOR EACH ROW EXECUTE FUNCTION interno.precio_inicial();

-- Las categorías y campos extra solo se renombran / desactivan.
CREATE FUNCTION interno.proteger_catalogo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF to_jsonb(NEW) - 'activa' - 'activo' - 'nombre' - 'etiqueta'
     IS DISTINCT FROM to_jsonb(OLD) - 'activa' - 'activo' - 'nombre' - 'etiqueta' THEN
    RAISE EXCEPTION 'PROHIBIDO: de este registro solo se puede cambiar el nombre o desactivarlo.';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER proteger BEFORE UPDATE ON public.unidad             FOR EACH ROW EXECUTE FUNCTION interno.proteger_catalogo();
CREATE TRIGGER proteger BEFORE UPDATE ON public.categoria_producto FOR EACH ROW EXECUTE FUNCTION interno.proteger_catalogo();
CREATE TRIGGER proteger BEFORE UPDATE ON public.campo_extra        FOR EACH ROW EXECUTE FUNCTION interno.proteger_catalogo();

CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.unidad             FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.categoria_producto FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.campo_extra        FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.producto           FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT ON public.producto_precio                        FOR EACH ROW EXECUTE FUNCTION interno.auditar();

CREATE TRIGGER no_borrar BEFORE DELETE ON public.unidad             FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la unidad en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.categoria_producto FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la categoría en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.campo_extra        FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive el campo en vez de borrarlo.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.producto           FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive el producto en vez de borrarlo.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.producto_precio
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El historial de precios es de solo agregar.');

-- ---------------------------------------------------------------------
-- Validación de campos extra. Devuelve el objeto final:
--   actual + nuevos (un valor null quita la clave).
-- Solo se aceptan claves de campos ACTIVOS; los obligatorios activos
-- deben quedar con valor.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.validar_campos_extra(p_empresa_id uuid, p_entidad text,
                                             p_actual jsonb, p_nuevos jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      record;
  d      public.campo_extra;
  v_res  jsonb := coalesce(p_actual, '{}');
  v_tipo text;
  v_f    date;
BEGIN
  IF p_nuevos IS NULL THEN
    p_nuevos := '{}';
  END IF;
  IF jsonb_typeof(p_nuevos) <> 'object' THEN
    RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: "campos_extra" debe ser un objeto, ej. {"talla": "M"}.';
  END IF;
  FOR r IN SELECT * FROM jsonb_each(p_nuevos) LOOP
    SELECT * INTO d FROM public.campo_extra c
     WHERE c.empresa_id = p_empresa_id AND c.entidad = p_entidad AND c.clave = r.key AND c.activo;
    IF d.id IS NULL THEN
      RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: el campo extra "%" no existe o está desactivado.', r.key;
    END IF;
    IF r.value = 'null'::jsonb THEN
      v_res := v_res - r.key;
      CONTINUE;
    END IF;
    v_tipo := jsonb_typeof(r.value);
    IF d.tipo = 'texto' AND (v_tipo <> 'string' OR length(r.value #>> '{}') > 500) THEN
      RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: "%" debe ser texto (máximo 500 letras).', d.etiqueta;
    ELSIF d.tipo = 'numero' AND v_tipo <> 'number' THEN
      RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: "%" debe ser un número.', d.etiqueta;
    ELSIF d.tipo = 'entero' AND (v_tipo <> 'number' OR (r.value #>> '{}') !~ '^-?[0-9]+$') THEN
      RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: "%" debe ser un número entero.', d.etiqueta;
    ELSIF d.tipo = 'si_no' AND v_tipo <> 'boolean' THEN
      RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: "%" debe ser sí o no (true/false).', d.etiqueta;
    ELSIF d.tipo = 'lista' AND (v_tipo <> 'string' OR NOT d.opciones ? (r.value #>> '{}')) THEN
      RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: "%" debe ser una de estas opciones: %.', d.etiqueta, d.opciones;
    ELSIF d.tipo = 'fecha' THEN
      v_f := NULL;
      IF v_tipo = 'string' AND (r.value #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        BEGIN
          v_f := (r.value #>> '{}')::date;
        EXCEPTION WHEN OTHERS THEN
          v_f := NULL;
        END;
      END IF;
      IF v_f IS NULL THEN
        RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: "%" debe ser una fecha AAAA-MM-DD.', d.etiqueta;
      END IF;
    END IF;
    v_res := v_res || jsonb_build_object(r.key, r.value);
  END LOOP;

  FOR d IN SELECT * FROM public.campo_extra c
            WHERE c.empresa_id = p_empresa_id AND c.entidad = p_entidad AND c.activo AND c.obligatorio LOOP
    IF NOT v_res ? d.clave THEN
      RAISE EXCEPTION 'CAMPO_EXTRA_INVALIDO: falta el campo obligatorio "%".', d.etiqueta;
    END IF;
  END LOOP;
  RETURN v_res;
END $$;

-- ---------------------------------------------------------------------
-- Aplica "datos" sobre un producto y valida (no guarda).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.aplicar_datos_producto(p public.producto, p_datos jsonb) RETURNS public.producto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_claves(p_datos, ARRAY['codigo','codigo_barras','nombre','categoria_id','unidad_id',
    'tipo_impuesto','precio_venta_centavos','stock_minimo','permite_fracciones','campos_extra']);

  IF p_datos ? 'codigo' THEN
    p.codigo := upper(interno.json_texto(p_datos->'codigo', 'codigo', 30));
    IF p.codigo IS NULL OR p.codigo !~ '^[A-Z0-9._/-]{1,30}$' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el código interno lleva letras, números, punto, guion o barra (máx. 30), ej. TOR-001.';
    END IF;
  END IF;
  IF p_datos ? 'codigo_barras' THEN
    p.codigo_barras := interno.json_texto(p_datos->'codigo_barras', 'codigo_barras', 48);
    IF p.codigo_barras IS NOT NULL AND p.codigo_barras !~ '^[A-Za-z0-9-]{4,48}$' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el código de barras lleva de 4 a 48 letras o números.';
    END IF;
  END IF;
  IF p_datos ? 'nombre' THEN
    p.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 200);
    IF p.nombre IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre del producto.';
    END IF;
  END IF;
  IF p_datos ? 'categoria_id' THEN
    v_id := interno.json_uuid(p_datos->'categoria_id', 'categoria_id');
    IF v_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.categoria_producto c
                                         WHERE c.id = v_id AND c.empresa_id = p.empresa_id AND c.activa) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la categoría no existe en esta empresa o está desactivada.';
    END IF;
    p.categoria_id := v_id;
  END IF;
  IF p_datos ? 'unidad_id' THEN
    v_id := interno.json_uuid(p_datos->'unidad_id', 'unidad_id');
    IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.unidad u WHERE u.id = v_id AND u.activa
                                     AND (u.empresa_id IS NULL OR u.empresa_id = p.empresa_id)) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la unidad de medida no existe o está desactivada.';
    END IF;
    p.unidad_id := v_id;
  END IF;
  IF p_datos ? 'tipo_impuesto' THEN
    p.tipo_impuesto := upper(interno.json_texto(p_datos->'tipo_impuesto', 'tipo_impuesto', 10));
    IF p.tipo_impuesto IS NULL OR p.tipo_impuesto NOT IN ('ISV15', 'ISV18', 'EXENTO') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el impuesto es ISV15, ISV18 o EXENTO.';
    END IF;
  END IF;
  IF p_datos ? 'precio_venta_centavos' THEN
    p.precio_venta_centavos := interno.json_centavos(p_datos->'precio_venta_centavos', 'precio_venta_centavos');
  END IF;
  IF p_datos ? 'stock_minimo' THEN
    IF jsonb_typeof(p_datos->'stock_minimo') <> 'number' OR (p_datos->>'stock_minimo')::numeric < 0
       OR (p_datos->>'stock_minimo')::numeric >= 100000000000000
       OR (p_datos->>'stock_minimo')::numeric <> round((p_datos->>'stock_minimo')::numeric, 4) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el stock mínimo es un número de 0 o más (hasta 4 decimales).';
    END IF;
    p.stock_minimo := (p_datos->>'stock_minimo')::numeric;
  END IF;
  IF p_datos ? 'permite_fracciones' THEN
    p.permite_fracciones := interno.json_si_no(p_datos->'permite_fracciones', 'permite_fracciones');
  END IF;
  p.campos_extra := interno.validar_campos_extra(p.empresa_id, 'producto', p.campos_extra, p_datos->'campos_extra');
  RETURN p;
END $$;

-- ---------------------------------------------------------------------
-- RPC: unidades, categorías y campos extra
-- ---------------------------------------------------------------------
CREATE FUNCTION public.crear_unidad(p_empresa_id uuid, p_codigo text, p_nombre text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF v_codigo !~ '^[A-Z0-9]{1,10}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el código de la unidad lleva de 1 a 10 letras o números, ej. QQ.';
  END IF;
  IF length(trim(coalesce(p_nombre, ''))) = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la unidad.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.unidad u WHERE u.codigo = v_codigo
              AND (u.empresa_id IS NULL OR u.empresa_id = p_empresa_id)) THEN
    RAISE EXCEPTION 'YA_EXISTE: ya existe la unidad %.', v_codigo;
  END IF;
  BEGIN
    INSERT INTO public.unidad (empresa_id, codigo, nombre) VALUES (p_empresa_id, v_codigo, trim(p_nombre))
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya existe la unidad %.', v_codigo;
  END;
  RETURN jsonb_build_object('unidad_id', v_id, 'codigo', v_codigo);
END $$;

CREATE FUNCTION public.crear_categoria(p_empresa_id uuid, p_nombre text, p_padre_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_padre public.categoria_producto;
  v_id    uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF length(trim(coalesce(p_nombre, ''))) = 0 OR length(trim(p_nombre)) > 100 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la categoría (máximo 100 letras).';
  END IF;
  IF p_padre_id IS NOT NULL THEN
    SELECT * INTO v_padre FROM public.categoria_producto
     WHERE id = p_padre_id AND empresa_id = p_empresa_id AND activa;
    IF v_padre.id IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la categoría madre no existe o está desactivada.';
    END IF;
    IF v_padre.nivel >= 3 THEN
      RAISE EXCEPTION 'NO_PERMITIDO: las categorías llegan hasta 3 niveles.';
    END IF;
  END IF;
  BEGIN
    INSERT INTO public.categoria_producto (empresa_id, padre_id, nombre, nivel)
    VALUES (p_empresa_id, p_padre_id, trim(p_nombre), coalesce(v_padre.nivel, 0) + 1)
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay una categoría "%" en ese nivel.', trim(p_nombre);
  END;
  RETURN jsonb_build_object('categoria_id', v_id);
END $$;

CREATE FUNCTION public.desactivar_categoria(p_empresa_id uuid, p_categoria_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_c public.categoria_producto;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_c FROM public.categoria_producto WHERE id = p_categoria_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la categoría no existe en esta empresa.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.categoria_producto SET activa = false WHERE id = p_categoria_id AND activa;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('categoria_id', p_categoria_id, 'activa', false, 'ya_estaba', NOT v_c.activa);
END $$;

CREATE FUNCTION public.crear_campo_extra(p_empresa_id uuid, p_clave text, p_etiqueta text, p_tipo text,
                                         p_opciones jsonb DEFAULT NULL, p_obligatorio boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid;
  v_o  jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF NOT coalesce(p_clave ~ '^[a-z][a-z0-9_]{0,39}$', false) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la clave va en minúsculas, sin espacios ni tildes, ej. talla o fecha_vence.';
  END IF;
  IF length(trim(coalesce(p_etiqueta, ''))) = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba la etiqueta que verá el usuario.';
  END IF;
  IF p_tipo IS NULL OR p_tipo NOT IN ('texto', 'numero', 'entero', 'fecha', 'si_no', 'lista') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo es texto, numero, entero, fecha, si_no o lista.';
  END IF;
  IF p_tipo = 'lista' THEN
    IF jsonb_typeof(p_opciones) IS DISTINCT FROM 'array' OR jsonb_array_length(p_opciones) = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: una lista necesita sus opciones, ej. ["S","M","L"].';
    END IF;
    FOR v_o IN SELECT * FROM jsonb_array_elements(p_opciones) LOOP
      IF jsonb_typeof(v_o) <> 'string' OR length(trim(v_o #>> '{}')) = 0 THEN
        RAISE EXCEPTION 'DATO_INVALIDO: cada opción de la lista debe ser un texto.';
      END IF;
    END LOOP;
  ELSE
    p_opciones := NULL;
  END IF;
  BEGIN
    INSERT INTO public.campo_extra (empresa_id, entidad, clave, etiqueta, tipo, opciones, obligatorio)
    VALUES (p_empresa_id, 'producto', p_clave, trim(p_etiqueta), p_tipo, p_opciones, coalesce(p_obligatorio, false))
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya existe el campo extra "%".', p_clave;
  END;
  RETURN jsonb_build_object('campo_extra_id', v_id, 'clave', p_clave);
END $$;

CREATE FUNCTION public.desactivar_campo_extra(p_empresa_id uuid, p_campo_extra_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_c public.campo_extra;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_c FROM public.campo_extra WHERE id = p_campo_extra_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el campo extra no existe en esta empresa.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.campo_extra SET activo = false WHERE id = p_campo_extra_id AND activo;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('campo_extra_id', p_campo_extra_id, 'activo', false, 'ya_estaba', NOT v_c.activo);
END $$;

-- ---------------------------------------------------------------------
-- RPC: productos
-- datos = {"codigo":"TOR-001","codigo_barras":"7421234567890","nombre":"Tornillo 1/2",
--          "categoria_id":"...","unidad_id":"...","tipo_impuesto":"ISV15",
--          "precio_venta_centavos":550,"stock_minimo":100,"permite_fracciones":false,
--          "campos_extra":{"marca":"Truper"}}
-- Sin unidad: UND. Sin impuesto: ISV15.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.crear_producto(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p    public.producto;
  v_id uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  SELECT x.id INTO v_id FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF FOUND THEN
    RETURN jsonb_build_object('producto_id', v_id, 'duplicado', true);
  END IF;
  IF NOT (coalesce(p_datos, '{}') ? 'codigo') OR NOT (p_datos ? 'nombre') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el producto necesita "codigo" (código interno) y "nombre".';
  END IF;

  p.empresa_id := p_empresa_id;
  p.tipo_impuesto := 'ISV15'; p.precio_venta_centavos := 0; p.stock_minimo := 0;
  p.permite_fracciones := false; p.campos_extra := '{}';
  SELECT u.id INTO p.unidad_id FROM public.unidad u WHERE u.empresa_id IS NULL AND u.codigo = 'UND';
  p := interno.aplicar_datos_producto(p, p_datos);

  IF EXISTS (SELECT 1 FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.codigo = p.codigo) THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay un producto con el código %.', p.codigo;
  END IF;
  IF p.codigo_barras IS NOT NULL AND EXISTS (SELECT 1 FROM public.producto x
       WHERE x.empresa_id = p_empresa_id AND x.codigo_barras = p.codigo_barras) THEN
    RAISE EXCEPTION 'YA_EXISTE: el código de barras % ya es de otro producto.', p.codigo_barras;
  END IF;

  BEGIN
    INSERT INTO public.producto (empresa_id, codigo, codigo_barras, nombre, categoria_id, unidad_id, tipo_impuesto,
                                 precio_venta_centavos, stock_minimo, permite_fracciones, campos_extra,
                                 id_operacion, creado_por)
    VALUES (p_empresa_id, p.codigo, p.codigo_barras, p.nombre, p.categoria_id, p.unidad_id, p.tipo_impuesto,
            p.precio_venta_centavos, p.stock_minimo, p.permite_fracciones, p.campos_extra,
            p_id_operacion, auth.uid())
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT x.id INTO v_id FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
    IF FOUND THEN
      RETURN jsonb_build_object('producto_id', v_id, 'duplicado', true);
    END IF;
    RAISE EXCEPTION 'YA_EXISTE: ya hay un producto con ese código o código de barras.';
  END;
  RETURN jsonb_build_object('producto_id', v_id, 'codigo', p.codigo, 'duplicado', false);
END $$;

-- Edita los datos enviados. El precio NO: use cambiar_precio_producto.
-- "activo": true/false para reactivar/desactivar (pide motivo).
CREATE FUNCTION public.editar_producto(p_empresa_id uuid, p_producto_id uuid, p_datos jsonb,
                                       p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_antes public.producto;
  p       public.producto;
  v_datos jsonb := p_datos;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  IF p_datos ? 'precio_venta_centavos' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el precio se cambia con "cambiar precio" (queda en el historial con motivo).';
  END IF;
  SELECT * INTO v_antes FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_antes.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
  END IF;
  p := v_antes;
  IF p_datos ? 'activo' THEN
    p.activo := interno.json_si_no(p_datos->'activo', 'activo');
    IF p.activo IS DISTINCT FROM v_antes.activo AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se activa o desactiva el producto (mínimo 5 letras).';
    END IF;
    v_datos := v_datos - 'activo';
  END IF;
  p := interno.aplicar_datos_producto(p, v_datos);

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  BEGIN
    UPDATE public.producto SET
      codigo = p.codigo, codigo_barras = p.codigo_barras, nombre = p.nombre, categoria_id = p.categoria_id,
      unidad_id = p.unidad_id, tipo_impuesto = p.tipo_impuesto, stock_minimo = p.stock_minimo,
      permite_fracciones = p.permite_fracciones, campos_extra = p.campos_extra, activo = p.activo
    WHERE id = p_producto_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ese código o código de barras ya es de otro producto.';
  END;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('producto_id', p_producto_id, 'editado', true);
END $$;

CREATE FUNCTION public.desactivar_producto(p_empresa_id uuid, p_producto_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_p public.producto;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_p FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
  END IF;
  IF NOT v_p.activo THEN
    RETURN jsonb_build_object('producto_id', p_producto_id, 'activo', false, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.producto SET activo = false WHERE id = p_producto_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('producto_id', p_producto_id, 'activo', false, 'ya_estaba', false);
END $$;

-- Cambia el precio de venta (centavos, sin ISV). Queda en producto_precio.
CREATE FUNCTION public.cambiar_precio_producto(p_empresa_id uuid, p_producto_id uuid,
                                               p_precio_centavos bigint, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_p public.producto;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.precios', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio de precio (mínimo 5 letras).';
  END IF;
  IF p_precio_centavos IS NULL OR p_precio_centavos < 0 OR p_precio_centavos > 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el precio es un entero de centavos, 0 o más (L 5.50 = 550).';
  END IF;
  SELECT * INTO v_p FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
  END IF;
  IF v_p.precio_venta_centavos = p_precio_centavos THEN
    RETURN jsonb_build_object('producto_id', p_producto_id, 'precio_centavos', p_precio_centavos, 'cambio', false);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.producto SET precio_venta_centavos = p_precio_centavos WHERE id = p_producto_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('producto_id', p_producto_id, 'precio_anterior_centavos', v_p.precio_venta_centavos,
                            'precio_centavos', p_precio_centavos, 'cambio', true);
END $$;

-- ---------------------------------------------------------------------
-- Seguridad
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['unidad', 'categoria_producto', 'campo_extra', 'producto', 'producto_precio'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;

CREATE POLICY leer ON public.unidad FOR SELECT TO authenticated
  USING (empresa_id IS NULL OR empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.categoria_producto FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.campo_extra        FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.producto           FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.producto_precio    FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));

REVOKE EXECUTE ON FUNCTION
  public.crear_unidad(uuid, text, text),
  public.crear_categoria(uuid, text, uuid),
  public.desactivar_categoria(uuid, uuid, text),
  public.crear_campo_extra(uuid, text, text, text, jsonb, boolean),
  public.desactivar_campo_extra(uuid, uuid, text),
  public.crear_producto(uuid, jsonb, uuid),
  public.editar_producto(uuid, uuid, jsonb, text),
  public.desactivar_producto(uuid, uuid, text),
  public.cambiar_precio_producto(uuid, uuid, bigint, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_unidad(uuid, text, text),
  public.crear_categoria(uuid, text, uuid),
  public.desactivar_categoria(uuid, uuid, text),
  public.crear_campo_extra(uuid, text, text, text, jsonb, boolean),
  public.desactivar_campo_extra(uuid, uuid, text),
  public.crear_producto(uuid, jsonb, uuid),
  public.editar_producto(uuid, uuid, jsonb, text),
  public.desactivar_producto(uuid, uuid, text),
  public.cambiar_precio_producto(uuid, uuid, bigint, text)
TO authenticated;
