-- =====================================================================
-- 046_excel.sql  -  Núcleo 0.12.0 (etapa 3b-2a): Excel de ida y vuelta.
--
-- El servidor NO lee ni escribe archivos Excel: la app convierte xlsx <-> JSON.
--   exportar_plantilla(empresa, hoja)          columnas (con su ayuda para la hoja
--                                              "Instrucciones") y filas actuales.
--   importar_vista_previa(empresa, hoja, filas) revisa fila por fila y NO guarda nada.
--   importar_aplicar(empresa, hoja, filas, id_operacion, motivo)
--                                              todo o nada: con UN error no guarda nada.
--
-- Hojas: productos, clientes_proveedores, categorias, existencias_iniciales,
--        saldos_iniciales, conteo_fisico.
--
-- Reglas: el código es la llave; celda vacía conserva el valor; nunca se borra
-- nada (desactivar = "Activo: No"); las columnas grises (solo información) se
-- ignoran al subir; montos en lempiras con 2 decimales; fechas AAAA-MM-DD;
-- Sí/No. Por dentro se usan las MISMAS funciones de siempre (crear_producto,
-- editar_producto, cambiar_precio_producto, crear_tercero, editar_tercero,
-- crear_categoria, cargar_saldo_inicial, registrar_saldo_inicial_cxc/cxp):
-- permisos, límites, historial de precios y bitácora quedan iguales.
--
-- Cómo funciona por dentro: cada fila se aplica en su propia sub-transacción
-- (si falla, se anota el error con su número de fila y sigue con la próxima);
-- al final, la vista previa (o una importación con errores) DESHACE todo.
-- Así la vista previa revisa con las reglas reales sin guardar nada.
--
-- Clientes y proveedores no tenían código: se agrega tercero.codigo (T00001,
-- T00002... a los que ya existen y a los nuevos que no traen uno). No cambia.
--
-- Conteo físico: no toca la existencia. Por bodega crea un "conteo_fisico" con
-- su solicitud de aprobación (tipo "conteo_fisico"); al aprobarla (admin o
-- dueño, inventario.ajustar) se hace el ajuste con la DIFERENCIA contada (así
-- no se pierde lo vendido entre el conteo y la aprobación).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('EXCEL_CELDA', 'Hay un dato del Excel que no se puede usar.', 'Corrija la celda que indica el mensaje (fila y columna) y vuelva a subir el archivo.'),
  ('EXCEL_DESHACER', 'La revisión del Excel no guardó nada.', 'Es normal en la vista previa. Si fue al aplicar, corrija los errores de la lista y vuelva a subir.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('excel.importar', 'Subir hojas de Excel (productos, clientes, categorías, cargas iniciales y conteo físico)', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'excel.importar'), ('admin', 'excel.importar');
SELECT interno.repartir_permisos(ARRAY['excel.importar'], 'Núcleo 0.12.0: Excel de ida y vuelta');

-- ---------------------------------------------------------------------
-- 1) Código de clientes y proveedores (llave del Excel)
-- ---------------------------------------------------------------------
ALTER TABLE public.tercero ADD COLUMN codigo text CHECK (codigo ~ '^[A-Z0-9._/-]{1,30}$');

-- Los que ya existen: T00001, T00002... por empresa, en el orden en que se crearon.
WITH x AS (
  SELECT t.id, t.empresa_id, row_number() OVER (PARTITION BY t.empresa_id ORDER BY t.creado_en, t.id) AS n
    FROM public.tercero t)
UPDATE public.tercero t SET codigo = 'T' || lpad(x.n::text, 5, '0') FROM x WHERE x.id = t.id;
INSERT INTO interno.contador (empresa_id, clave, ultimo)
SELECT t.empresa_id, 'tercero_codigo', count(*) FROM public.tercero t GROUP BY t.empresa_id
ON CONFLICT (empresa_id, clave) DO UPDATE SET ultimo = greatest(interno.contador.ultimo, excluded.ultimo);

ALTER TABLE public.tercero ALTER COLUMN codigo SET NOT NULL;
CREATE UNIQUE INDEX tercero_codigo ON public.tercero (empresa_id, codigo);

-- Al crear: el código que pidió el Excel (app.tercero_codigo) o el siguiente libre.
CREATE FUNCTION interno.codigo_tercero() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.codigo IS DISTINCT FROM OLD.codigo THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el código del cliente o proveedor no cambia (es la llave del Excel).';
    END IF;
    RETURN NEW;
  END IF;
  NEW.codigo := upper(coalesce(NEW.codigo, nullif(current_setting('app.tercero_codigo', true), '')));
  IF NEW.codigo IS NULL THEN
    LOOP
      v := 'T' || lpad(interno.siguiente_numero(NEW.empresa_id, 'tercero_codigo')::text, 5, '0');
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.tercero t WHERE t.empresa_id = NEW.empresa_id AND t.codigo = v);
    END LOOP;
    NEW.codigo := v;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER codigo BEFORE INSERT OR UPDATE OF codigo ON public.tercero
  FOR EACH ROW EXECUTE FUNCTION interno.codigo_tercero();

-- ---------------------------------------------------------------------
-- 2) Tablas: importaciones aplicadas y conteos físicos
-- ---------------------------------------------------------------------
CREATE TABLE public.importacion_excel (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id    uuid NOT NULL REFERENCES public.empresa(id),
  numero        bigint NOT NULL,
  hoja          text NOT NULL,
  filas         integer NOT NULL CHECK (filas >= 0),
  resumen       jsonb NOT NULL,          -- lo mismo que devolvió importar_aplicar (sin el detalle por fila)
  motivo        text NOT NULL CHECK (length(trim(motivo)) >= 5),
  id_operacion  uuid NOT NULL,
  creado_por    uuid,
  creado_en     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion)
);

CREATE TABLE public.conteo_fisico (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id     uuid NOT NULL REFERENCES public.empresa(id),
  numero         bigint NOT NULL,
  bodega_id      uuid NOT NULL,
  fecha          date NOT NULL,
  -- [{"producto_id","codigo","existencia","contada","diferencia"}] (existencia = la del sistema al subir)
  lineas         jsonb NOT NULL CHECK (jsonb_typeof(lineas) = 'array' AND jsonb_array_length(lineas) > 0),
  motivo         text NOT NULL,
  estado         text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'aplicado', 'rechazado')),
  aprobacion_id  uuid NOT NULL,
  documento_id   uuid,                   -- el ajuste de inventario hecho al aprobar
  importacion_id_operacion uuid,         -- id_operacion de la importación que lo creó
  id_operacion   uuid NOT NULL,
  creado_por     uuid,
  creado_en      timestamptz NOT NULL DEFAULT now(),
  resuelto_en    timestamptz,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, bodega_id) REFERENCES public.bodega(empresa_id, id),
  CHECK ((estado = 'pendiente') = (resuelto_en IS NULL)),
  CHECK (estado <> 'aplicado' OR documento_id IS NOT NULL)
);

CREATE TRIGGER inmutable BEFORE UPDATE ON public.importacion_excel
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Una importación de Excel no se edita.');

CREATE FUNCTION interno.proteger_conteo_fisico() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c_mut constant text[] := ARRAY['estado', 'documento_id', 'resuelto_en'];
BEGIN
  IF OLD.estado = 'pendiente' AND NEW.estado <> 'pendiente' AND (to_jsonb(NEW) - c_mut) = (to_jsonb(OLD) - c_mut) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: un conteo físico no se edita; se aprueba o se rechaza una sola vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.conteo_fisico FOR EACH ROW EXECUTE FUNCTION interno.proteger_conteo_fisico();

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('importacion_excel', 'excel.importar'), ('conteo_fisico', 'inventario.ajustar')) x(t, permiso) LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', r.t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   r.t, 'Las importaciones y los conteos no se borran.');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   r.t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', r.t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', r.t, r.permiso);
  END LOOP;
END $$;

INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('importacion_excel', 'id_operacion', 'importar_excel', 70),
  ('conteo_fisico',     'id_operacion', 'conteo_fisico',  71);

-- ---------------------------------------------------------------------
-- 3) Ayudantes
-- ---------------------------------------------------------------------
-- id_operacion derivado (una importación hace varias operaciones; cada una con
-- su id fijo, así un reintento nunca duplica).
CREATE FUNCTION interno.excel_id(p_base uuid, p_parte text) RETURNS uuid
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT md5(p_base::text || '/excel/' || p_parte)::uuid
$$;

CREATE FUNCTION interno.excel_lps(p_centavos numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT round(p_centavos / 100.0, 2)
$$;

CREATE FUNCTION interno.excel_si_no(p boolean) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p THEN 'Sí' WHEN NOT p THEN 'No' END
$$;

-- Descripción de una columna.
CREATE FUNCTION interno.excel_col(p_clave text, p_titulo text, p_editable boolean, p_tipo text, p_descripcion text,
                                  p_valores jsonb DEFAULT NULL, p_obligatorio boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('clave', p_clave, 'titulo', p_titulo, 'editable', p_editable, 'tipo', p_tipo,
                            'obligatorio', p_obligatorio, 'valores', p_valores, 'descripcion', p_descripcion)
$$;

-- Ruta de una categoría: "Ferretería > Tornillería > Acero".
CREATE FUNCTION interno.excel_ruta_categoria(p_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH RECURSIVE r AS (
    SELECT c.id, c.padre_id, c.nombre, 1 AS paso FROM public.categoria_producto c WHERE c.id = p_id
    UNION ALL
    SELECT c.id, c.padre_id, c.nombre, r.paso + 1 FROM public.categoria_producto c JOIN r ON c.id = r.padre_id WHERE r.paso < 5)
  SELECT string_agg(r.nombre, ' > ' ORDER BY r.paso DESC) FROM r
$$;

-- Busca una categoría por su ruta (sin distinguir mayúsculas). NULL si no está.
CREATE FUNCTION interno.excel_buscar_categoria(p_empresa_id uuid, p_ruta text, p_solo_activas boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id    uuid;
  v_parte text;
  v_cero  constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  FOREACH v_parte IN ARRAY string_to_array(coalesce(p_ruta, ''), '>') LOOP
    v_parte := trim(v_parte);
    IF v_parte = '' THEN
      RETURN NULL;
    END IF;
    SELECT c.id INTO v_id FROM public.categoria_producto c
     WHERE c.empresa_id = p_empresa_id AND coalesce(c.padre_id, v_cero) = coalesce(v_id, v_cero)
       AND lower(c.nombre) = lower(v_parte) AND (c.activa OR NOT p_solo_activas);
    IF v_id IS NULL THEN
      RETURN NULL;
    END IF;
  END LOOP;
  RETURN v_id;
END $$;

-- Ruta escrita de forma pareja (para comparar llaves).
CREATE FUNCTION interno.excel_ruta_normal(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT lower(array_to_string(ARRAY(SELECT trim(x) FROM unnest(string_to_array(coalesce(p, ''), '>')) x), ' > '))
$$;

-- Convierte una celda al valor que usan las funciones (sin lanzar error):
--   texto, codigo (mayúsculas), monto (lempiras -> centavos), cantidad (hasta 4
--   decimales, 0 o más), numero, entero, si_no, fecha (AAAA-MM-DD), lista.
-- Celda vacía = NULL (conserva el valor).
CREATE FUNCTION interno.excel_valor(p_tipo text, p_valores jsonb, p_v jsonb, OUT o_valor jsonb, OUT o_error text)
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  t   text;
  x   numeric;
  d   date;
  v   jsonb;
BEGIN
  IF p_v IS NULL OR p_v = 'null'::jsonb THEN
    RETURN;
  END IF;
  IF jsonb_typeof(p_v) IN ('object', 'array') THEN
    o_error := 'la celda trae un dato que no es texto ni número.';
    RETURN;
  END IF;
  t := trim(p_v #>> '{}');
  IF t = '' THEN
    RETURN;
  END IF;

  IF p_tipo = 'texto' THEN
    o_valor := to_jsonb(t);
  ELSIF p_tipo = 'codigo' THEN
    t := upper(t);
    IF t !~ '^[A-Z0-9._/-]{1,30}$' THEN
      o_error := 'use solo letras, números, punto, guion o barra, sin espacios (máximo 30).';
    ELSE
      o_valor := to_jsonb(t);
    END IF;
  ELSIF p_tipo IN ('monto', 'cantidad', 'numero', 'entero') THEN
    IF jsonb_typeof(p_v) = 'number' THEN
      x := t::numeric;
    ELSE
      t := replace(regexp_replace(t, '^L\.?[[:space:]]*', '', 'i'), ',', '');
      IF t !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        o_error := CASE p_tipo WHEN 'monto' THEN 'escriba el monto en lempiras, solo números (ej. 1250.50).'
                               ELSE 'escriba un número (ej. 12.5).' END;
        RETURN;
      END IF;
      x := t::numeric;
    END IF;
    IF p_tipo = 'monto' THEN
      IF x < 0 THEN
        o_error := 'el monto no puede ser negativo.';
      ELSIF abs(x - round(x, 2)) > 0.000001 THEN
        o_error := 'el monto lleva máximo 2 decimales (centavos).';
      ELSIF round(x * 100) > 9007199254740991 THEN
        o_error := 'el monto es demasiado grande.';
      ELSE
        o_valor := to_jsonb(round(x * 100)::bigint);
      END IF;
    ELSIF p_tipo = 'cantidad' THEN
      IF x < 0 THEN
        o_error := 'la cantidad no puede ser negativa.';
      ELSIF abs(x - round(x, 4)) > 0.0000001 OR x >= 100000000000000 THEN
        o_error := 'la cantidad lleva máximo 4 decimales.';
      ELSE
        o_valor := to_jsonb(round(x, 4));
      END IF;
    ELSIF p_tipo = 'entero' THEN
      IF x < 0 OR x <> trunc(x) OR x > 2147483647 THEN
        o_error := 'escriba un número entero, sin decimales (ej. 30).';
      ELSE
        o_valor := to_jsonb(x::bigint);
      END IF;
    ELSE
      o_valor := to_jsonb(x);
    END IF;
  ELSIF p_tipo = 'si_no' THEN
    t := lower(t);
    IF t IN ('sí', 'si', 's', 'true', 'verdadero', '1', 'x') THEN
      o_valor := 'true';
    ELSIF t IN ('no', 'n', 'false', 'falso', '0') THEN
      o_valor := 'false';
    ELSE
      o_error := 'escriba Sí o No.';
    END IF;
  ELSIF p_tipo = 'fecha' THEN
    IF t !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
      o_error := 'la fecha va como AAAA-MM-DD (ej. 2026-01-31).';
      RETURN;
    END IF;
    BEGIN
      d := t::date;
      o_valor := to_jsonb(to_char(d, 'YYYY-MM-DD'));
    EXCEPTION WHEN OTHERS THEN
      o_error := 'esa fecha no existe (revise día y mes).';
    END;
  ELSIF p_tipo = 'lista' THEN
    SELECT e INTO v FROM jsonb_array_elements(coalesce(p_valores, '[]')) e WHERE lower(e #>> '{}') = lower(t) LIMIT 1;
    IF v IS NULL THEN
      o_error := 'debe ser uno de estos valores: ' || (SELECT string_agg(e #>> '{}', ', ') FROM jsonb_array_elements(coalesce(p_valores, '[]')) e) || '.';
    ELSE
      o_valor := v;
    END IF;
  ELSE
    o_error := 'tipo de columna desconocido.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  o_valor := NULL;
  o_error := 'el dato no se pudo leer.';
END $$;

-- Error de una celda (lo que ve el usuario).
CREATE FUNCTION interno.excel_error(p_fila integer, p_clave text, p_titulo text, p_mensaje text) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('fila', p_fila, 'columna', p_titulo, 'clave_columna', p_clave, 'mensaje', p_mensaje,
    'texto', 'Fila ' || p_fila || coalesce(', columna "' || p_titulo || '"', '') || ': ' || p_mensaje)
$$;

-- Error que vino de una función del núcleo ("CLAVE: mensaje"; EXCEL_CELDA trae "Columna|mensaje").
CREATE FUNCTION interno.excel_error_sql(p_fila integer, p_sqlerrm text, p_prefijo text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  v_clave text := substring(p_sqlerrm FROM '^([A-Z_]+):');
  v_msg   text := trim(regexp_replace(p_sqlerrm, '^[A-Z_]+:[[:space:]]*', ''));
  v_col   text;
BEGIN
  IF v_clave = 'EXCEL_CELDA' AND position('|' IN v_msg) > 0 THEN
    v_col := split_part(v_msg, '|', 1);
    v_msg := substring(v_msg FROM position('|' IN v_msg) + 1);
  END IF;
  RETURN interno.excel_error(p_fila, NULL, v_col, p_prefijo || v_msg) || jsonb_build_object('codigo', coalesce(v_clave, 'ERROR'));
END $$;

CREATE FUNCTION interno.excel_hoja_valida(p_hoja text) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_hoja IS NULL OR p_hoja NOT IN ('productos', 'clientes_proveedores', 'categorias', 'existencias_iniciales',
                                      'saldos_iniciales', 'conteo_fisico') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la hoja "%" no existe. Hojas: productos, clientes_proveedores, categorias, existencias_iniciales, saldos_iniciales, conteo_fisico.', coalesce(p_hoja, '');
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 4) Columnas de cada hoja (también son la hoja "Instrucciones")
--    p_todas: al subir se reconocen todas las grises aunque el usuario no
--    pueda verlas (así un archivo de otro usuario no da error).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.excel_columnas(p_empresa_id uuid, p_hoja text, p_todas boolean) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c          jsonb;
  v_costos   boolean := p_todas OR public.puede_leer(p_empresa_id, 'inventario.costos');
  v_ventas   boolean := p_todas OR public.puede_leer(p_empresa_id, 'ventas.ver');
  v_compras  boolean := p_todas OR public.puede_leer(p_empresa_id, 'compras.ver');
  v_si_no    constant jsonb := '["Sí", "No"]';
  v_imp      jsonb := (SELECT jsonb_agg(i.codigo ORDER BY i.orden, i.codigo) FROM public.impuesto i
                        WHERE i.empresa_id = p_empresa_id AND i.activo);
  v_uni      jsonb := (SELECT jsonb_agg(u.codigo ORDER BY u.codigo) FROM public.unidad u
                        WHERE u.activa AND (u.empresa_id IS NULL OR u.empresa_id = p_empresa_id));
  v_bod      jsonb := (SELECT jsonb_agg(b.codigo ORDER BY b.codigo) FROM public.bodega b
                        WHERE b.empresa_id = p_empresa_id AND b.activa);
BEGIN
  IF p_hoja = 'productos' THEN
    c := jsonb_build_array(
      interno.excel_col('codigo', 'Código', true, 'codigo', 'Código interno. Es la LLAVE: no se cambia. Si no existe, se crea un producto nuevo.', NULL, true),
      interno.excel_col('codigo_barras', 'Código de barras', true, 'texto', 'De 4 a 48 letras o números. Vacío = no se cambia.'),
      interno.excel_col('nombre', 'Nombre', true, 'texto', 'Nombre del producto. Obligatorio si el producto es nuevo.'),
      interno.excel_col('tipo', 'Tipo', true, 'lista', '"bien" lleva inventario; "servicio" no. Se fija al crear (por defecto bien).', '["bien", "servicio"]'),
      interno.excel_col('categoria', 'Categoría', true, 'texto', 'Categoría principal. Debe existir (hoja Categorías).'),
      interno.excel_col('subcategoria', 'Subcategoría', true, 'texto', 'Subcategoría dentro de la categoría. Tercer nivel: "Sub > Sub-sub".'),
      interno.excel_col('unidad', 'Unidad', true, 'codigo', 'Código de la unidad de medida (debe existir).', v_uni),
      interno.excel_col('se_vende_con_decimales', 'Se vende con decimales', true, 'si_no', 'Sí = se vende por fracciones (ej. 1.5 lb).', v_si_no),
      interno.excel_col('impuesto', 'Impuesto', true, 'codigo', 'Código del impuesto de la tabla de impuestos de la empresa.', v_imp),
      interno.excel_col('precio_venta', 'Precio de venta (L)', true, 'monto', 'En lempiras con 2 decimales, tal como lo cobra. El cambio queda en el historial de precios.'),
      interno.excel_col('precio_incluye_isv', 'Precio incluye ISV', true, 'si_no', 'Sí = el precio ya trae el impuesto.', v_si_no),
      interno.excel_col('existencia_minima', 'Existencia mínima', true, 'cantidad', 'Avisa cuando la existencia baja de aquí.'),
      interno.excel_col('activo', 'Activo', true, 'si_no', 'No = desactivar (nunca se borra). Sí = volver a activar.', v_si_no));
    c := c || coalesce((SELECT jsonb_agg(interno.excel_col('extra.' || ce.clave, ce.etiqueta, true,
                          ce.tipo, 'Campo extra de la empresa' || CASE WHEN ce.obligatorio THEN ' (obligatorio en productos nuevos)' ELSE '' END || '.',
                          CASE WHEN ce.tipo = 'lista' THEN ce.opciones WHEN ce.tipo = 'si_no' THEN v_si_no END) ORDER BY ce.creado_en, ce.clave)
                          FROM public.campo_extra ce WHERE ce.empresa_id = p_empresa_id AND ce.entidad = 'producto' AND ce.activo), '[]');
    IF v_costos THEN
      c := c || jsonb_build_array(interno.excel_col('costo_promedio', 'Costo promedio (L)', false, 'monto', 'Solo información: costo promedio de todas las bodegas (servicios: costo estimado).'));
    END IF;
    c := c || jsonb_build_array(interno.excel_col('existencia_total', 'Existencia total', false, 'cantidad', 'Solo información: suma de todas las bodegas.'));
    IF v_costos THEN
      c := c || jsonb_build_array(
        interno.excel_col('valor_inventario', 'Valor del inventario (L)', false, 'monto', 'Solo información.'),
        interno.excel_col('margen_porcentaje', 'Margen %', false, 'numero', 'Solo información: (precio sin ISV - costo) / precio sin ISV.'));
    END IF;
    c := c || jsonb_build_array(
      interno.excel_col('precio_sin_isv', 'Precio sin ISV (L)', false, 'monto', 'Solo información.'),
      interno.excel_col('precio_con_isv', 'Precio con ISV (L)', false, 'monto', 'Solo información.'),
      interno.excel_col('ultima_venta', 'Última venta', false, 'fecha', 'Solo información.'),
      interno.excel_col('ultima_compra', 'Última compra', false, 'fecha', 'Solo información.'));

  ELSIF p_hoja = 'clientes_proveedores' THEN
    c := jsonb_build_array(
      interno.excel_col('codigo', 'Código', true, 'codigo', 'LLAVE (no se cambia). Vacío = nuevo: el programa le pone código (T00012); si trae el RTN de uno que ya existe, se actualiza ese.'),
      interno.excel_col('tipo', 'Tipo', true, 'lista', 'cliente, proveedor o ambos. Solo agrega papeles (no quita). Por defecto cliente.', '["cliente", "proveedor", "ambos"]'),
      interno.excel_col('tipo_persona', 'Tipo de persona', true, 'lista', 'natural o juridica.', '["natural", "juridica"]'),
      interno.excel_col('nombre', 'Nombre o razón social', true, 'texto', 'Obligatorio si es nuevo.'),
      interno.excel_col('rtn', 'RTN', true, 'texto', '14 dígitos, con o sin guiones. No se repite en la empresa.'),
      interno.excel_col('telefono', 'Teléfono', true, 'texto', '8 a 15 dígitos.'),
      interno.excel_col('correo', 'Correo', true, 'texto', 'Correo electrónico.'),
      interno.excel_col('direccion', 'Dirección', true, 'texto', 'Dirección.'),
      interno.excel_col('limite_credito', 'Límite de crédito (L)', true, 'monto', 'Pide permiso de crédito; quien no es dueño no pasa el tope que fijó el dueño.'),
      interno.excel_col('plazo_dias', 'Plazo en días', true, 'entero', 'De 0 a 365.'),
      interno.excel_col('activo', 'Activo', true, 'si_no', 'No = desactivar (nunca se borra).', v_si_no));
    IF v_ventas THEN
      c := c || jsonb_build_array(
        interno.excel_col('saldo_por_cobrar', 'Saldo por cobrar (L)', false, 'monto', 'Solo información.'),
        interno.excel_col('vencido_por_cobrar', 'Vencido por cobrar (L)', false, 'monto', 'Solo información.'),
        interno.excel_col('ultimo_cobro', 'Último cobro', false, 'fecha', 'Solo información.'));
    END IF;
    IF v_compras THEN
      c := c || jsonb_build_array(
        interno.excel_col('saldo_por_pagar', 'Saldo por pagar (L)', false, 'monto', 'Solo información.'),
        interno.excel_col('vencido_por_pagar', 'Vencido por pagar (L)', false, 'monto', 'Solo información.'),
        interno.excel_col('ultimo_pago', 'Último pago al proveedor', false, 'fecha', 'Solo información.'));
    END IF;

  ELSIF p_hoja = 'categorias' THEN
    c := jsonb_build_array(
      interno.excel_col('nombre', 'Nombre', true, 'texto', 'Nombre de la categoría (sin el signo >). Llave junto con la madre.', NULL, true),
      interno.excel_col('categoria_madre', 'Categoría madre', true, 'texto', 'Vacío = categoría principal. Si no: la madre ("Ferretería" o "Ferretería > Tornillería"); debe existir o venir en una fila de arriba. Hasta 3 niveles.'),
      interno.excel_col('activo', 'Activo', true, 'si_no', 'No = desactivar (nunca se borra).', v_si_no),
      interno.excel_col('nivel', 'Nivel', false, 'entero', 'Solo información (1, 2 o 3).'),
      interno.excel_col('productos', 'Productos', false, 'entero', 'Solo información: productos en esta categoría.'));

  ELSIF p_hoja = 'existencias_iniciales' THEN
    c := jsonb_build_array(
      interno.excel_col('codigo', 'Código', true, 'codigo', 'Código del producto (debe existir; no servicios).', NULL, true),
      interno.excel_col('bodega', 'Bodega', true, 'codigo', 'Código de la bodega.', v_bod, true),
      interno.excel_col('cantidad', 'Cantidad', true, 'cantidad', 'Existencia al empezar. Vacío = no se carga esta fila.'),
      interno.excel_col('costo_unitario', 'Costo unitario (L)', true, 'monto', 'Costo de cada unidad, en lempiras con 2 decimales.'),
      interno.excel_col('fecha', 'Fecha', true, 'fecha', 'Fecha de la carga (AAAA-MM-DD). Vacío = fecha de inicio de la empresa.'),
      interno.excel_col('nombre', 'Nombre', false, 'texto', 'Solo información.'),
      interno.excel_col('unidad', 'Unidad', false, 'texto', 'Solo información.'),
      interno.excel_col('sucursal', 'Sucursal', false, 'texto', 'Solo información: sucursal de la bodega.'));

  ELSIF p_hoja = 'saldos_iniciales' THEN
    c := jsonb_build_array(
      interno.excel_col('tipo', 'Tipo', true, 'lista', 'cliente (nos debe) o proveedor (le debemos).', '["cliente", "proveedor"]', true),
      interno.excel_col('codigo', 'Código', true, 'codigo', 'Código del cliente o proveedor (hoja Clientes y proveedores).', NULL, true),
      interno.excel_col('documento', 'Documento', true, 'texto', 'Número de la factura pendiente. Una sola vez por cliente o proveedor.', NULL, true),
      interno.excel_col('fecha_documento', 'Fecha del documento', true, 'fecha', 'Fecha de la factura (AAAA-MM-DD).'),
      interno.excel_col('vencimiento', 'Vencimiento', true, 'fecha', 'Vacío = fecha del documento + plazo del cliente o proveedor.'),
      interno.excel_col('monto', 'Monto pendiente (L)', true, 'monto', 'Lo que falta pagar de esa factura, en lempiras.'),
      interno.excel_col('fecha', 'Fecha de apertura', true, 'fecha', 'Fecha del asiento. Vacío = fecha de inicio de la empresa.'),
      interno.excel_col('nombre', 'Nombre', false, 'texto', 'Solo información.'),
      interno.excel_col('saldo_pendiente', 'Saldo pendiente hoy (L)', false, 'monto', 'Solo información.'));

  ELSIF p_hoja = 'conteo_fisico' THEN
    c := jsonb_build_array(
      interno.excel_col('codigo', 'Código', true, 'codigo', 'Código del producto.', NULL, true),
      interno.excel_col('bodega', 'Bodega', true, 'codigo', 'Código de la bodega contada.', v_bod, true),
      interno.excel_col('cantidad_contada', 'Cantidad contada', true, 'cantidad', 'Lo que se contó. Vacío = no se contó (no cambia nada).'),
      interno.excel_col('nombre', 'Nombre', false, 'texto', 'Solo información.'),
      interno.excel_col('unidad', 'Unidad', false, 'texto', 'Solo información.'));
  END IF;
  RETURN c;
END $$;

-- Llave de una fila (para avisar si viene repetida en el mismo archivo).
CREATE FUNCTION interno.excel_llave(p_hoja text, c jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_hoja
    WHEN 'productos' THEN c->>'codigo'
    WHEN 'clientes_proveedores' THEN coalesce(c->>'codigo', 'RTN ' || nullif(regexp_replace(c->>'rtn', '[^0-9]', '', 'g'), ''))
    WHEN 'categorias' THEN interno.excel_ruta_normal(coalesce((c->>'categoria_madre') || ' > ', '') || (c->>'nombre'))
    WHEN 'existencias_iniciales' THEN (c->>'codigo') || ' en ' || (c->>'bodega')
    WHEN 'conteo_fisico' THEN (c->>'codigo') || ' en ' || (c->>'bodega')
    WHEN 'saldos_iniciales' THEN (c->>'tipo') || ' ' || (c->>'codigo') || ' ' || upper(c->>'documento')
  END
$$;

-- Producto y bodega de una fila (inventario).
CREATE FUNCTION interno.excel_producto_bodega(p_empresa_id uuid, c jsonb, OUT p public.producto, OUT b public.bodega)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  SELECT * INTO p FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.codigo = c->>'codigo';
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Código|el producto "%" no existe; súbalo antes en la hoja Productos.', c->>'codigo';
  END IF;
  IF p.tipo = 'servicio' THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Código|"%" es un servicio: no lleva existencias.', c->>'codigo';
  END IF;
  SELECT * INTO b FROM public.bodega x WHERE x.empresa_id = p_empresa_id AND x.codigo = c->>'bodega' AND x.activa;
  IF b.id IS NULL THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Bodega|la bodega "%" no existe o está desactivada.', c->>'bodega';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 5) Una fila de cada hoja (usa las RPC de siempre). Devuelve
--    {accion: crear | actualizar | sin_cambios, llave, cambios: [columnas]}
--    y, en las hojas que se aplican por grupo, "_lote".
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.excel_fila_productos(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p       public.producto;
  d       jsonb := '{}';
  v_extra jsonb := '{}';
  v_camb  text[] := '{}';
  v_id    uuid;
  k       text;
BEGIN
  SELECT * INTO p FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.codigo = c->>'codigo';

  IF c ? 'codigo_barras' AND (c->>'codigo_barras') IS DISTINCT FROM p.codigo_barras THEN
    d := d || jsonb_build_object('codigo_barras', c->'codigo_barras'); v_camb := v_camb || 'codigo_barras'::text;
  END IF;
  IF c ? 'nombre' AND (c->>'nombre') IS DISTINCT FROM p.nombre THEN
    d := d || jsonb_build_object('nombre', c->'nombre'); v_camb := v_camb || 'nombre'::text;
  END IF;
  IF c ? 'tipo' AND (c->>'tipo') IS DISTINCT FROM p.tipo THEN
    d := d || jsonb_build_object('tipo', c->'tipo'); v_camb := v_camb || 'tipo'::text;
  END IF;
  IF c ? 'subcategoria' AND NOT c ? 'categoria' THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Categoría|si escribe la subcategoría, escriba también la categoría.';
  END IF;
  IF c ? 'categoria' THEN
    v_id := interno.excel_buscar_categoria(p_empresa_id, (c->>'categoria') || coalesce(' > ' || (c->>'subcategoria'), ''));
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Categoría|la categoría "%" no existe o está desactivada; créela antes en la hoja Categorías.',
        (c->>'categoria') || coalesce(' > ' || (c->>'subcategoria'), '');
    END IF;
    IF v_id IS DISTINCT FROM p.categoria_id THEN
      d := d || jsonb_build_object('categoria_id', v_id); v_camb := v_camb || 'categoria'::text;
    END IF;
  END IF;
  IF c ? 'unidad' THEN
    SELECT u.id INTO v_id FROM public.unidad u
     WHERE u.codigo = c->>'unidad' AND u.activa AND (u.empresa_id IS NULL OR u.empresa_id = p_empresa_id)
     ORDER BY u.empresa_id NULLS LAST LIMIT 1;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Unidad|la unidad "%" no existe o está desactivada; créela antes en Ajustes.', c->>'unidad';
    END IF;
    IF v_id IS DISTINCT FROM p.unidad_id THEN
      d := d || jsonb_build_object('unidad_id', v_id); v_camb := v_camb || 'unidad'::text;
    END IF;
  END IF;
  IF c ? 'se_vende_con_decimales' AND (c->'se_vende_con_decimales')::boolean IS DISTINCT FROM p.permite_fracciones THEN
    d := d || jsonb_build_object('permite_fracciones', c->'se_vende_con_decimales'); v_camb := v_camb || 'se_vende_con_decimales'::text;
  END IF;
  IF c ? 'impuesto' AND (c->>'impuesto') IS DISTINCT FROM p.tipo_impuesto THEN
    d := d || jsonb_build_object('tipo_impuesto', c->'impuesto'); v_camb := v_camb || 'impuesto'::text;
  END IF;
  IF c ? 'precio_incluye_isv' AND (c->'precio_incluye_isv')::boolean IS DISTINCT FROM p.precio_incluye_isv THEN
    d := d || jsonb_build_object('precio_incluye_isv', c->'precio_incluye_isv'); v_camb := v_camb || 'precio_incluye_isv'::text;
  END IF;
  IF c ? 'existencia_minima' AND (c->>'existencia_minima')::numeric IS DISTINCT FROM p.stock_minimo THEN
    d := d || jsonb_build_object('stock_minimo', c->'existencia_minima'); v_camb := v_camb || 'existencia_minima'::text;
  END IF;
  FOR k IN SELECT x FROM jsonb_object_keys(c) x WHERE x LIKE 'extra.%' LOOP
    IF (c->k) IS DISTINCT FROM (p.campos_extra->substr(k, 7)) THEN
      v_extra := v_extra || jsonb_build_object(substr(k, 7), c->k); v_camb := v_camb || k;
    END IF;
  END LOOP;
  IF c ? 'precio_venta' AND (c->>'precio_venta')::bigint IS DISTINCT FROM p.precio_venta_centavos THEN
    v_camb := v_camb || 'precio_venta'::text;
  END IF;

  IF p.id IS NULL THEN
    IF NOT c ? 'nombre' THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Nombre|el producto "%" es nuevo: escriba su nombre.', c->>'codigo';
    END IF;
    d := d || jsonb_build_object('codigo', c->'codigo');
    IF c ? 'precio_venta' THEN
      d := d || jsonb_build_object('precio_venta_centavos', c->'precio_venta');
    END IF;
    IF v_extra <> '{}' THEN
      d := d || jsonb_build_object('campos_extra', v_extra);
    END IF;
    v_id := (public.crear_producto(p_empresa_id, d, p_id)->>'producto_id')::uuid;
    IF c ? 'activo' AND NOT (c->'activo')::boolean THEN
      PERFORM public.editar_producto(p_empresa_id, v_id, '{"activo": false}', p_motivo);
    END IF;
    RETURN jsonb_build_object('accion', 'crear', 'llave', c->>'codigo', 'cambios', to_jsonb(v_camb));
  END IF;

  IF c ? 'activo' AND (c->'activo')::boolean IS DISTINCT FROM p.activo THEN
    d := d || jsonb_build_object('activo', c->'activo'); v_camb := v_camb || 'activo'::text;
  END IF;
  IF v_extra <> '{}' THEN
    d := d || jsonb_build_object('campos_extra', v_extra);
  END IF;
  IF d <> '{}' THEN
    PERFORM public.editar_producto(p_empresa_id, p.id, d, p_motivo);
  END IF;
  IF 'precio_venta' = ANY (v_camb) THEN
    PERFORM public.cambiar_precio_producto(p_empresa_id, p.id, (c->>'precio_venta')::bigint, p_motivo);
  END IF;
  RETURN jsonb_build_object('accion', CASE WHEN cardinality(v_camb) = 0 THEN 'sin_cambios' ELSE 'actualizar' END,
                            'llave', c->>'codigo', 'cambios', to_jsonb(v_camb));
END $$;

CREATE FUNCTION interno.excel_fila_terceros(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t      public.tercero;
  d      jsonb := '{}';
  v_camb text[] := '{}';
  v_cli  boolean;
  v_prov boolean;
  v_id   uuid;
BEGIN
  IF c ? 'codigo' THEN
    SELECT * INTO t FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.codigo = c->>'codigo';
  ELSIF c ? 'rtn' THEN
    SELECT * INTO t FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.rtn = regexp_replace(c->>'rtn', '[^0-9]', '', 'g');
  END IF;

  v_cli  := coalesce(c->>'tipo', 'cliente') IN ('cliente', 'ambos');
  v_prov := coalesce(c->>'tipo', '') IN ('proveedor', 'ambos');
  IF t.id IS NULL THEN
    d := jsonb_build_object('es_cliente', v_cli, 'es_proveedor', v_prov);
    v_camb := v_camb || 'tipo'::text;
  ELSIF c ? 'tipo' THEN
    -- Solo agrega papeles: quitar "cliente" o "proveedor" se hace en la app.
    IF v_cli AND NOT t.es_cliente THEN d := d || '{"es_cliente": true}'; END IF;
    IF v_prov AND NOT t.es_proveedor THEN d := d || '{"es_proveedor": true}'; END IF;
    IF d <> '{}' THEN v_camb := v_camb || 'tipo'::text; END IF;
  END IF;
  IF c ? 'tipo_persona' AND (c->>'tipo_persona') IS DISTINCT FROM t.tipo_persona THEN
    d := d || jsonb_build_object('tipo_persona', c->'tipo_persona'); v_camb := v_camb || 'tipo_persona'::text;
  END IF;
  IF c ? 'nombre' AND (c->>'nombre') IS DISTINCT FROM t.nombre THEN
    d := d || jsonb_build_object('nombre', c->'nombre'); v_camb := v_camb || 'nombre'::text;
  END IF;
  IF c ? 'rtn' AND regexp_replace(c->>'rtn', '[[:space:]-]', '', 'g') IS DISTINCT FROM t.rtn THEN
    d := d || jsonb_build_object('rtn', c->'rtn'); v_camb := v_camb || 'rtn'::text;
  END IF;
  IF c ? 'telefono' AND regexp_replace(c->>'telefono', '[[:space:]().-]', '', 'g') IS DISTINCT FROM t.telefono THEN
    d := d || jsonb_build_object('telefono', c->'telefono'); v_camb := v_camb || 'telefono'::text;
  END IF;
  IF c ? 'correo' AND lower(c->>'correo') IS DISTINCT FROM t.correo THEN
    d := d || jsonb_build_object('correo', c->'correo'); v_camb := v_camb || 'correo'::text;
  END IF;
  IF c ? 'direccion' AND (c->>'direccion') IS DISTINCT FROM t.direccion THEN
    d := d || jsonb_build_object('direccion', c->'direccion'); v_camb := v_camb || 'direccion'::text;
  END IF;
  IF c ? 'limite_credito' AND (c->>'limite_credito')::bigint IS DISTINCT FROM t.limite_credito_centavos THEN
    d := d || jsonb_build_object('limite_credito_centavos', c->'limite_credito'); v_camb := v_camb || 'limite_credito'::text;
  END IF;
  IF c ? 'plazo_dias' AND (c->>'plazo_dias')::integer IS DISTINCT FROM t.plazo_dias THEN
    d := d || jsonb_build_object('plazo_dias', c->'plazo_dias'); v_camb := v_camb || 'plazo_dias'::text;
  END IF;

  IF t.id IS NULL THEN
    IF NOT c ? 'nombre' THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Nombre o razón social|es nuevo: escriba el nombre.';
    END IF;
    PERFORM set_config('app.tercero_codigo', coalesce(c->>'codigo', ''), true);
    v_id := (public.crear_tercero(p_empresa_id, d, p_id)->>'tercero_id')::uuid;
    PERFORM set_config('app.tercero_codigo', '', true);
    IF c ? 'activo' AND NOT (c->'activo')::boolean THEN
      PERFORM public.editar_tercero(p_empresa_id, v_id, '{"activo": false}', p_motivo);
    END IF;
    RETURN jsonb_build_object('accion', 'crear', 'llave', (SELECT x.codigo FROM public.tercero x WHERE x.id = v_id),
                              'cambios', to_jsonb(v_camb));
  END IF;

  IF c ? 'activo' AND (c->'activo')::boolean IS DISTINCT FROM t.activo THEN
    d := d || jsonb_build_object('activo', c->'activo'); v_camb := v_camb || 'activo'::text;
  END IF;
  IF d <> '{}' THEN
    PERFORM public.editar_tercero(p_empresa_id, t.id, d, p_motivo);
  END IF;
  RETURN jsonb_build_object('accion', CASE WHEN cardinality(v_camb) = 0 THEN 'sin_cambios' ELSE 'actualizar' END,
                            'llave', t.codigo, 'cambios', to_jsonb(v_camb));
END $$;

CREATE FUNCTION interno.excel_fila_categorias(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_madre uuid;
  v       public.categoria_producto;
  v_cero  constant uuid := '00000000-0000-0000-0000-000000000000';
  v_id    uuid;
BEGIN
  IF position('>' IN c->>'nombre') > 0 THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Nombre|no use el signo > en el nombre (la madre va en "Categoría madre").';
  END IF;
  IF c ? 'categoria_madre' THEN
    v_madre := interno.excel_buscar_categoria(p_empresa_id, c->>'categoria_madre');
    IF v_madre IS NULL THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Categoría madre|"%" no existe o está desactivada (póngala en una fila de arriba).', c->>'categoria_madre';
    END IF;
  END IF;
  SELECT * INTO v FROM public.categoria_producto x
   WHERE x.empresa_id = p_empresa_id AND coalesce(x.padre_id, v_cero) = coalesce(v_madre, v_cero) AND lower(x.nombre) = lower(c->>'nombre');
  IF v.id IS NULL THEN
    v_id := (public.crear_categoria(p_empresa_id, c->>'nombre', v_madre)->>'categoria_id')::uuid;
    IF c ? 'activo' AND NOT (c->'activo')::boolean THEN
      PERFORM public.desactivar_categoria(p_empresa_id, v_id, p_motivo);
    END IF;
    RETURN jsonb_build_object('accion', 'crear', 'llave', interno.excel_ruta_categoria(v_id), 'cambios', '["nombre"]'::jsonb);
  END IF;
  IF c ? 'activo' AND (c->'activo')::boolean IS DISTINCT FROM v.activa THEN
    IF (c->'activo')::boolean THEN
      PERFORM public.reactivar_categoria(p_empresa_id, v.id, p_motivo);
    ELSE
      PERFORM public.desactivar_categoria(p_empresa_id, v.id, p_motivo);
    END IF;
    RETURN jsonb_build_object('accion', 'actualizar', 'llave', interno.excel_ruta_categoria(v.id), 'cambios', '["activo"]'::jsonb);
  END IF;
  RETURN jsonb_build_object('accion', 'sin_cambios', 'llave', interno.excel_ruta_categoria(v.id), 'cambios', '[]'::jsonb);
END $$;

CREATE FUNCTION interno.excel_fila_existencias(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  x       record;
  v_q     numeric;
  v_fecha date;
BEGIN
  SELECT * INTO x FROM interno.excel_producto_bodega(p_empresa_id, c);
  IF NOT c ? 'cantidad' THEN
    RETURN jsonb_build_object('accion', 'sin_cambios', 'llave', (x.p).codigo || ' en ' || (x.b).codigo, 'cambios', '[]'::jsonb);
  END IF;
  v_q := (c->>'cantidad')::numeric;
  IF v_q <= 0 THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Cantidad|la cantidad inicial debe ser mayor que cero (o deje la celda vacía).';
  END IF;
  IF NOT (x.p).permite_fracciones AND v_q <> trunc(v_q) THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Cantidad|"%" se maneja por unidades enteras (sin decimales).', (x.p).codigo;
  END IF;
  IF NOT c ? 'costo_unitario' THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Costo unitario (L)|escriba el costo de cada unidad.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventario_movimiento m
              WHERE m.bodega_id = (x.b).id AND m.producto_id = (x.p).id AND m.origen = 'carga_inicial'
                AND NOT EXISTS (SELECT 1 FROM public.inventario_documento_anulacion an WHERE an.documento_id = m.documento_id))
     AND NOT public.tiene_permiso('inventario.carga_inicial_repetir', p_empresa_id) THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Bodega|"%" ya tiene existencia inicial en la bodega % (la carga inicial es una sola vez; si estaba mal, anúlela y vuelva a subirla).',
      (x.p).codigo, (x.b).codigo;
  END IF;
  v_fecha := coalesce((c->>'fecha')::date, (SELECT e.fecha_inicio FROM public.empresa e WHERE e.id = p_empresa_id));
  RETURN jsonb_build_object('accion', 'crear', 'llave', (x.p).codigo || ' en ' || (x.b).codigo,
    'cambios', '["cantidad", "costo_unitario"]'::jsonb,
    '_lote', jsonb_build_object('grupo', (x.b).id::text || '|' || v_fecha::text, 'bodega_id', (x.b).id, 'fecha', v_fecha,
      'linea', jsonb_build_object('producto_id', (x.p).id, 'cantidad', v_q, 'costo_unitario', (c->>'costo_unitario')::bigint)));
END $$;

CREATE FUNCTION interno.excel_fila_saldos(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t       public.tercero;
  v_cli   boolean := c->>'tipo' = 'cliente';
  v_monto bigint;
  d       jsonb;
  v_llave text := interno.excel_llave('saldos_iniciales', c);
BEGIN
  SELECT * INTO t FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.codigo = c->>'codigo';
  IF t.id IS NULL THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Código|el cliente o proveedor "%" no existe; súbalo antes en la hoja Clientes y proveedores.', c->>'codigo';
  END IF;
  IF (v_cli AND NOT t.es_cliente) OR (NOT v_cli AND NOT t.es_proveedor) THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Tipo|"%" no está marcado como %.', c->>'codigo', c->>'tipo';
  END IF;
  IF v_cli THEN
    SELECT s.monto_centavos INTO v_monto FROM public.cxc_saldo_inicial s
     WHERE s.empresa_id = p_empresa_id AND s.cliente_id = t.id AND upper(s.numero_documento) = upper(c->>'documento') AND s.anulada_en IS NULL;
  ELSE
    SELECT s.monto_centavos INTO v_monto FROM public.cxp_saldo_inicial s
     WHERE s.empresa_id = p_empresa_id AND s.proveedor_id = t.id AND upper(s.numero_documento) = upper(c->>'documento') AND s.anulada_en IS NULL;
  END IF;
  IF v_monto IS NOT NULL THEN
    IF NOT c ? 'monto' OR (c->>'monto')::bigint = v_monto THEN
      RETURN jsonb_build_object('accion', 'sin_cambios', 'llave', v_llave, 'cambios', '[]'::jsonb);
    END IF;
    RAISE EXCEPTION 'EXCEL_CELDA: Monto pendiente (L)|el documento % ya está cargado por %; para corregirlo, anúlelo y vuelva a subirlo.',
      c->>'documento', interno.lempiras(v_monto);
  END IF;
  IF NOT c ? 'monto' THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Monto pendiente (L)|escriba lo que falta pagar de esa factura.';
  END IF;
  IF NOT c ? 'fecha_documento' THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Fecha del documento|escriba la fecha de la factura (AAAA-MM-DD).';
  END IF;
  d := jsonb_build_object('numero_documento', c->'documento', 'fecha_documento', c->'fecha_documento', 'monto_centavos', c->'monto')
       || jsonb_strip_nulls(jsonb_build_object('fecha_vencimiento', c->'vencimiento', 'fecha', c->'fecha'));
  IF v_cli THEN
    PERFORM public.registrar_saldo_inicial_cxc(p_empresa_id, d || jsonb_build_object('cliente_id', t.id), p_id);
  ELSE
    PERFORM public.registrar_saldo_inicial_cxp(p_empresa_id, d || jsonb_build_object('proveedor_id', t.id), p_id);
  END IF;
  RETURN jsonb_build_object('accion', 'crear', 'llave', v_llave, 'cambios', '["monto"]'::jsonb);
END $$;

CREATE FUNCTION interno.excel_fila_conteo(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  x      record;
  v_cont numeric;
  v_ex   numeric;
  v_dif  numeric;
  v_ll   text;
BEGIN
  SELECT * INTO x FROM interno.excel_producto_bodega(p_empresa_id, c);
  v_ll := (x.p).codigo || ' en ' || (x.b).codigo;
  IF NOT c ? 'cantidad_contada' THEN
    RETURN jsonb_build_object('accion', 'sin_cambios', 'llave', v_ll, 'cambios', '[]'::jsonb);
  END IF;
  v_cont := (c->>'cantidad_contada')::numeric;
  IF NOT (x.p).permite_fracciones AND v_cont <> trunc(v_cont) THEN
    RAISE EXCEPTION 'EXCEL_CELDA: Cantidad contada|"%" se maneja por unidades enteras (sin decimales).', (x.p).codigo;
  END IF;
  v_ex := coalesce((SELECT s.cantidad FROM public.inventario_saldo s WHERE s.bodega_id = (x.b).id AND s.producto_id = (x.p).id), 0);
  v_dif := v_cont - v_ex;
  IF v_dif = 0 THEN
    RETURN jsonb_build_object('accion', 'sin_cambios', 'llave', v_ll, 'cambios', '[]'::jsonb, 'diferencia', 0);
  END IF;
  RETURN jsonb_build_object('accion', 'crear', 'llave', v_ll, 'cambios', '["cantidad_contada"]'::jsonb, 'diferencia', v_dif,
    '_lote', jsonb_build_object('grupo', (x.b).id::text, 'bodega_id', (x.b).id,
      'linea', jsonb_build_object('producto_id', (x.p).id, 'codigo', (x.p).codigo, 'existencia', v_ex,
                                  'contada', v_cont, 'diferencia', v_dif)));
END $$;

-- Grupos: existencias iniciales = una carga por bodega y fecha (un asiento contra Saldos de apertura).
CREATE FUNCTION interno.excel_lote_existencias(p_empresa_id uuid, l jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  r := public.cargar_saldo_inicial(p_empresa_id, (l->>'bodega_id')::uuid, (l->>'fecha')::date, l->'lineas', p_id, p_motivo);
  RETURN jsonb_build_object('tipo', 'carga_inicial', 'documento_id', r->'documento_id', 'numero', r->'numero',
                            'bodega_id', l->'bodega_id', 'productos', jsonb_array_length(l->'lineas'));
END $$;

-- Grupos: conteo físico = un conteo por bodega con su solicitud de aprobación (no mueve existencias).
CREATE FUNCTION interno.excel_lote_conteo(p_empresa_id uuid, l jsonb, p_motivo text, p_id uuid, p_importacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id   uuid := gen_random_uuid();
  v_apr  uuid := gen_random_uuid();
  v_num  bigint := interno.siguiente_numero(p_empresa_id, 'conteo_fisico');
  v_bod  text := (SELECT b.codigo FROM public.bodega b WHERE b.id = (l->>'bodega_id')::uuid);
  v_n    integer := jsonb_array_length(l->'lineas');
BEGIN
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                 solicitado_por, rol_solicitante)
  VALUES (v_apr, p_empresa_id, interno.siguiente_numero(p_empresa_id, 'aprobacion'), 'conteo_fisico', 'conteo_fisico', v_id, 0,
          'Conteo físico #' || v_num || ', bodega ' || v_bod || ': ' || v_n || ' producto(s) con diferencia (' || trim(p_motivo) || ')',
          auth.uid(), public.mi_rol(p_empresa_id));
  INSERT INTO public.conteo_fisico (id, empresa_id, numero, bodega_id, fecha, lineas, motivo, aprobacion_id,
                                    importacion_id_operacion, id_operacion, creado_por)
  VALUES (v_id, p_empresa_id, v_num, (l->>'bodega_id')::uuid, public.hoy_local(p_empresa_id), l->'lineas', trim(p_motivo), v_apr,
          p_importacion, p_id, auth.uid());
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('tipo', 'conteo_fisico', 'conteo_id', v_id, 'numero', v_num, 'aprobacion_id', v_apr,
                            'bodega', v_bod, 'productos', v_n);
END $$;

-- ---------------------------------------------------------------------
-- 6) El motor: revisa (y aplica) todas las filas. Con p_aplicar = false, o
--    si hubo UN error, deshace todo al final (no queda nada guardado).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.excel_procesar(p_empresa_id uuid, p_hoja text, p_filas jsonb, p_id_operacion uuid,
                                       p_motivo text, p_aplicar boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cols    jsonb := interno.excel_columnas(p_empresa_id, p_hoja, true);
  f         jsonb;
  v_idx     bigint;
  n         integer;
  k         text;
  col       jsonb;
  cv        record;
  v_canon   jsonb;
  v_errs    jsonb;
  v_llave   text;
  v_llaves  jsonb := '{}';
  v_res     jsonb;
  v_det     jsonb := '[]';
  v_errores jsonb := '[]';
  v_lotes   jsonb := '{}';
  v_lote    jsonb;
  v_g       text;
  v_err     jsonb;
  v_docs    jsonb := '[]';
  v_ok      boolean;
BEGIN
  IF jsonb_typeof(p_filas) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "filas" debe ser una lista de filas (la app convierte el Excel en JSON).';
  END IF;
  IF jsonb_array_length(p_filas) > 5000 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 5,000 filas por archivo; divídalo en partes.';
  END IF;

  BEGIN
    FOR f, v_idx IN SELECT x.f, x.i FROM jsonb_array_elements(p_filas) WITH ORDINALITY AS x(f, i) LOOP
      n := v_idx::integer + 1;             -- por defecto: la fila 1 del Excel es el encabezado
      v_errs := '[]';
      v_canon := '{}';
      IF jsonb_typeof(f) <> 'object' THEN
        v_errs := jsonb_build_array(interno.excel_error(n, NULL, NULL, 'la fila no trae columnas.'));
      ELSE
        IF jsonb_typeof(f->'fila') = 'number' AND (f->>'fila') ~ '^[0-9]{1,7}$' THEN
          n := (f->>'fila')::integer;       -- número de fila real del Excel (lo manda la app)
        END IF;
        FOR k IN SELECT jsonb_object_keys(f) LOOP
          CONTINUE WHEN k = 'fila';
          SELECT x INTO col FROM jsonb_array_elements(v_cols) x WHERE x->>'clave' = k;
          IF col IS NULL THEN
            v_errs := v_errs || interno.excel_error(n, k, k, 'esta columna no se reconoce (¿se cambió el encabezado?).');
          ELSIF (col->>'editable')::boolean THEN
            SELECT * INTO cv FROM interno.excel_valor(col->>'tipo', col->'valores', f->k);
            IF cv.o_error IS NOT NULL THEN
              v_errs := v_errs || interno.excel_error(n, k, col->>'titulo', cv.o_error);
            ELSIF cv.o_valor IS NOT NULL THEN
              v_canon := v_canon || jsonb_build_object(k, cv.o_valor);
            END IF;
          END IF;                           -- columna gris: se ignora
        END LOOP;
        IF v_errs = '[]' AND v_canon = '{}' THEN
          v_det := v_det || jsonb_build_object('fila', n, 'accion', 'sin_cambios', 'vacia', true);
          CONTINUE;
        END IF;
        FOR col IN SELECT x FROM jsonb_array_elements(v_cols) x
                    WHERE (x->>'obligatorio')::boolean AND NOT v_canon ? (x->>'clave')
                      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_errs) e WHERE e->>'clave_columna' = x->>'clave') LOOP
          v_errs := v_errs || interno.excel_error(n, col->>'clave', col->>'titulo', 'falta este dato (es obligatorio).');
        END LOOP;
      END IF;

      IF v_errs = '[]' THEN
        v_llave := interno.excel_llave(p_hoja, v_canon);
        IF v_llave IS NOT NULL AND v_llaves ? v_llave THEN
          v_errs := jsonb_build_array(interno.excel_error(n, NULL, NULL,
                      '"' || v_llave || '" está repetido: ya viene en la fila ' || (v_llaves->>v_llave) || '.'));
        ELSIF v_llave IS NOT NULL THEN
          v_llaves := v_llaves || jsonb_build_object(v_llave, n);
        END IF;
      END IF;
      IF v_errs <> '[]' THEN
        v_errores := v_errores || v_errs;
        v_det := v_det || jsonb_build_object('fila', n, 'accion', 'error', 'llave', v_llave, 'errores', v_errs);
        CONTINUE;
      END IF;

      BEGIN
        v_res := CASE p_hoja
          WHEN 'productos' THEN interno.excel_fila_productos(p_empresa_id, v_canon, p_motivo, interno.excel_id(p_id_operacion, 'fila/' || v_idx))
          WHEN 'clientes_proveedores' THEN interno.excel_fila_terceros(p_empresa_id, v_canon, p_motivo, interno.excel_id(p_id_operacion, 'fila/' || v_idx))
          WHEN 'categorias' THEN interno.excel_fila_categorias(p_empresa_id, v_canon, p_motivo, interno.excel_id(p_id_operacion, 'fila/' || v_idx))
          WHEN 'existencias_iniciales' THEN interno.excel_fila_existencias(p_empresa_id, v_canon, p_motivo, interno.excel_id(p_id_operacion, 'fila/' || v_idx))
          WHEN 'saldos_iniciales' THEN interno.excel_fila_saldos(p_empresa_id, v_canon, p_motivo, interno.excel_id(p_id_operacion, 'fila/' || v_idx))
          WHEN 'conteo_fisico' THEN interno.excel_fila_conteo(p_empresa_id, v_canon, p_motivo, interno.excel_id(p_id_operacion, 'fila/' || v_idx))
        END;
      EXCEPTION WHEN OTHERS THEN
        v_err := interno.excel_error_sql(n, SQLERRM);
        v_errores := v_errores || v_err;
        v_det := v_det || jsonb_build_object('fila', n, 'accion', 'error', 'llave', v_llave, 'errores', jsonb_build_array(v_err));
        CONTINUE;
      END;

      IF v_res ? '_lote' THEN
        v_g := v_res->'_lote'->>'grupo';
        v_lote := coalesce(v_lotes->v_g, (v_res->'_lote') - 'linea' || '{"filas": [], "lineas": []}');
        v_lote := jsonb_set(v_lote, '{filas}', (v_lote->'filas') || to_jsonb(n));
        v_lote := jsonb_set(v_lote, '{lineas}', (v_lote->'lineas') || jsonb_build_array(v_res->'_lote'->'linea'));
        v_lotes := v_lotes || jsonb_build_object(v_g, v_lote);
      END IF;
      v_det := v_det || (jsonb_build_object('fila', n) || (v_res - '_lote'));
    END LOOP;

    -- Grupos (una carga o un conteo por bodega).
    FOR v_g, v_lote IN SELECT x.key, x.value FROM jsonb_each(v_lotes) x ORDER BY x.key LOOP
      BEGIN
        v_docs := v_docs || CASE p_hoja
          WHEN 'existencias_iniciales' THEN interno.excel_lote_existencias(p_empresa_id, v_lote, p_motivo, interno.excel_id(p_id_operacion, 'lote/' || v_g))
          WHEN 'conteo_fisico' THEN interno.excel_lote_conteo(p_empresa_id, v_lote, p_motivo, interno.excel_id(p_id_operacion, 'lote/' || v_g), p_id_operacion)
        END;
      EXCEPTION WHEN OTHERS THEN
        v_err := interno.excel_error_sql((v_lote->'filas'->>0)::integer, SQLERRM,
                   'filas ' || (SELECT string_agg(x #>> '{}', ', ') FROM jsonb_array_elements(v_lote->'filas') x) || ': ');
        v_errores := v_errores || v_err;
        v_det := (SELECT jsonb_agg(CASE WHEN (v_lote->'filas') @> jsonb_build_array(d->'fila') AND d->>'accion' <> 'error'
                                        THEN d || jsonb_build_object('accion', 'error', 'errores', jsonb_build_array(v_err)) ELSE d END
                                   ORDER BY o)
                    FROM jsonb_array_elements(v_det) WITH ORDINALITY AS z(d, o));
      END;
    END LOOP;

    IF NOT p_aplicar OR jsonb_array_length(v_errores) > 0 THEN
      RAISE EXCEPTION 'EXCEL_DESHACER: vista previa o importación con errores; no se guarda nada.';
    END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'EXCEL_DESHACER:%' THEN
      RAISE;
    END IF;
  END;

  v_ok := p_aplicar AND jsonb_array_length(v_errores) = 0;
  RETURN jsonb_build_object(
    'hoja', p_hoja,
    'vista_previa', NOT p_aplicar,
    'aplicado', v_ok,
    'resumen', (SELECT jsonb_build_object(
        'filas', count(*),
        'crear', count(*) FILTER (WHERE d->>'accion' = 'crear'),
        'actualizar', count(*) FILTER (WHERE d->>'accion' = 'actualizar'),
        'sin_cambios', count(*) FILTER (WHERE d->>'accion' = 'sin_cambios'),
        'error', count(*) FILTER (WHERE d->>'accion' = 'error'))
      FROM jsonb_array_elements(v_det) d),
    'errores', v_errores,
    'filas', v_det,
    'documentos', CASE WHEN v_ok THEN v_docs ELSE '[]'::jsonb END,
    'mensaje', CASE
      WHEN jsonb_array_length(v_errores) > 0 THEN 'Hay ' || jsonb_array_length(v_errores) || ' error(es). No se guardó nada: corrija y vuelva a subir.'
      WHEN NOT p_aplicar THEN 'Todo está bien. Revise los cambios y confirme para aplicarlos.'
      ELSE 'Importación aplicada.' END);
END $$;

-- ---------------------------------------------------------------------
-- 7) RPC
-- ---------------------------------------------------------------------
-- exportar_plantilla(empresa, hoja): columnas + filas actuales (montos en lempiras
-- con 2 decimales, fechas AAAA-MM-DD, Sí/No). Permisos: productos y categorías
-- cualquier usuario de la empresa (costos solo con inventario.costos); clientes y
-- proveedores terceros.ver (saldos con ventas.ver / compras.ver); existencias
-- iniciales inventario.carga_inicial; saldos iniciales ventas.saldo_inicial o
-- compras.saldo_inicial; conteo físico inventario.ver (sin la existencia: conteo a ciegas).
CREATE FUNCTION public.exportar_plantilla(p_empresa_id uuid, p_hoja text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_costos  boolean;
  v_ventas  boolean;
  v_compras boolean;
  v_hoy     date;
  v_filas   jsonb;
  v_cli     boolean;
  v_prov    boolean;
BEGIN
  PERFORM interno.excel_hoja_valida(p_hoja);
  IF p_hoja IN ('productos', 'categorias') THEN
    PERFORM interno.exigir_miembro(p_empresa_id);
  ELSIF p_hoja = 'clientes_proveedores' THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'terceros.ver');
  ELSIF p_hoja = 'existencias_iniciales' THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'inventario.carga_inicial');
  ELSIF p_hoja = 'conteo_fisico' THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'inventario.ver');
  ELSIF p_hoja = 'saldos_iniciales' THEN
    PERFORM interno.exigir_miembro(p_empresa_id);
    v_cli := public.puede_leer(p_empresa_id, 'ventas.saldo_inicial');
    v_prov := public.puede_leer(p_empresa_id, 'compras.saldo_inicial');
    IF NOT (v_cli OR v_prov) THEN
      RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.saldo_inicial" ni "compras.saldo_inicial".';
    END IF;
  END IF;
  v_costos  := public.puede_leer(p_empresa_id, 'inventario.costos');
  v_ventas  := public.puede_leer(p_empresa_id, 'ventas.ver');
  v_compras := public.puede_leer(p_empresa_id, 'compras.ver');
  v_hoy     := public.hoy_local(p_empresa_id);

  IF p_hoja = 'productos' THEN
    SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'codigo', p.codigo, 'codigo_barras', p.codigo_barras, 'nombre', p.nombre, 'tipo', p.tipo,
        'categoria', split_part(interno.excel_ruta_categoria(p.categoria_id), ' > ', 1),
        'subcategoria', nullif(substring(interno.excel_ruta_categoria(p.categoria_id)
                                         FROM length(split_part(interno.excel_ruta_categoria(p.categoria_id), ' > ', 1)) + 4), ''),
        'unidad', u.codigo, 'se_vende_con_decimales', interno.excel_si_no(p.permite_fracciones),
        'impuesto', p.tipo_impuesto, 'precio_venta', interno.excel_lps(p.precio_venta_centavos),
        'precio_incluye_isv', interno.excel_si_no(p.precio_incluye_isv), 'existencia_minima', trim_scale(p.stock_minimo),
        'activo', interno.excel_si_no(p.activo),
        'existencia_total', CASE WHEN p.tipo = 'bien' THEN trim_scale(coalesce(s.cantidad, 0)) END,
        'precio_sin_isv', interno.excel_lps(x.sin_isv_centavos), 'precio_con_isv', interno.excel_lps(x.con_isv_centavos),
        'ultima_venta', (SELECT to_char(max(v.fecha_contable), 'YYYY-MM-DD') FROM public.venta_linea l JOIN public.venta v ON v.id = l.venta_id
                          WHERE l.producto_id = p.id AND v.estado = 'emitida'),
        'ultima_compra', (SELECT to_char(max(cp.fecha_contable), 'YYYY-MM-DD') FROM public.compra_linea l JOIN public.compra cp ON cp.id = l.compra_id
                           WHERE l.producto_id = p.id AND cp.anulada_en IS NULL))
      || coalesce((SELECT jsonb_object_agg('extra.' || ce.clave,
                      CASE WHEN jsonb_typeof(p.campos_extra->ce.clave) = 'boolean'
                           THEN to_jsonb(interno.excel_si_no((p.campos_extra->>ce.clave)::boolean)) ELSE p.campos_extra->ce.clave END)
                    FROM public.campo_extra ce WHERE ce.empresa_id = p_empresa_id AND ce.entidad = 'producto' AND ce.activo), '{}')
      || CASE WHEN v_costos THEN jsonb_build_object(
           'costo_promedio', interno.excel_lps(k.costo),
           'valor_inventario', CASE WHEN p.tipo = 'bien' THEN interno.excel_lps(coalesce(s.valor, 0)) END,
           'margen_porcentaje', CASE WHEN x.sin_isv_centavos > 0 AND k.costo IS NOT NULL
                                     THEN round((x.sin_isv_centavos - k.costo) * 100.0 / x.sin_isv_centavos, 2) END)
         ELSE '{}' END
      ORDER BY p.codigo), '[]')
      INTO v_filas
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      LEFT JOIN public.impuesto i ON i.empresa_id = p.empresa_id AND i.codigo = p.tipo_impuesto
      CROSS JOIN LATERAL public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, i.porcentaje) x
      LEFT JOIN LATERAL (SELECT sum(z.cantidad) AS cantidad, sum(z.valor_centavos) AS valor
                           FROM public.inventario_saldo z WHERE z.producto_id = p.id) s ON true
      LEFT JOIN LATERAL (SELECT CASE WHEN p.tipo = 'servicio'
                                     THEN (SELECT sc.costo_estimado_centavos::numeric FROM public.servicio_costo sc WHERE sc.producto_id = p.id)
                                     WHEN coalesce(s.cantidad, 0) > 0 THEN s.valor / s.cantidad END AS costo) k ON true
     WHERE p.empresa_id = p_empresa_id;

  ELSIF p_hoja = 'clientes_proveedores' THEN
    -- Cartera calculada UNA vez (no por cada fila).
    WITH cxc AS (
      SELECT a.cliente_id, sum(a.saldo_centavos) AS saldo,
             sum(a.saldo_centavos) FILTER (WHERE a.vence_el < v_hoy AND a.saldo_centavos > 0) AS vencido
        FROM interno.cxc_al(p_empresa_id, 'infinity') a WHERE v_ventas GROUP BY a.cliente_id),
    cxp AS (
      SELECT a.proveedor_id, sum(a.saldo_centavos) AS saldo,
             sum(a.saldo_centavos) FILTER (WHERE a.vence_el < v_hoy AND a.saldo_centavos > 0) AS vencido
        FROM interno.cxp_al(p_empresa_id, 'infinity') a WHERE v_compras GROUP BY a.proveedor_id)
    SELECT coalesce(jsonb_agg(
      jsonb_build_object('codigo', t.codigo,
        'tipo', CASE WHEN t.es_cliente AND t.es_proveedor THEN 'ambos' WHEN t.es_cliente THEN 'cliente' ELSE 'proveedor' END,
        'tipo_persona', t.tipo_persona, 'nombre', t.nombre, 'rtn', t.rtn, 'telefono', t.telefono, 'correo', t.correo,
        'direccion', t.direccion, 'limite_credito', interno.excel_lps(t.limite_credito_centavos), 'plazo_dias', t.plazo_dias,
        'activo', interno.excel_si_no(t.activo))
      || CASE WHEN v_ventas THEN jsonb_build_object(
           'saldo_por_cobrar', interno.excel_lps(coalesce(cc.saldo, 0)),
           'vencido_por_cobrar', interno.excel_lps(coalesce(cc.vencido, 0)),
           'ultimo_cobro', (SELECT to_char(max(cb.fecha_contable), 'YYYY-MM-DD') FROM public.cobro cb WHERE cb.cliente_id = t.id AND cb.anulada_en IS NULL))
         ELSE '{}' END
      || CASE WHEN v_compras THEN jsonb_build_object(
           'saldo_por_pagar', interno.excel_lps(coalesce(cp.saldo, 0)),
           'vencido_por_pagar', interno.excel_lps(coalesce(cp.vencido, 0)),
           'ultimo_pago', (SELECT to_char(max(pp.fecha_contable), 'YYYY-MM-DD') FROM public.pago_proveedor pp
                            WHERE pp.proveedor_id = t.id AND NOT EXISTS (SELECT 1 FROM public.pago_proveedor_anulacion an WHERE an.pago_id = pp.id)))
         ELSE '{}' END
      ORDER BY t.codigo), '[]')
      INTO v_filas
      FROM public.tercero t
      LEFT JOIN cxc cc ON cc.cliente_id = t.id
      LEFT JOIN cxp cp ON cp.proveedor_id = t.id
     WHERE t.empresa_id = p_empresa_id;

  ELSIF p_hoja = 'categorias' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('nombre', c.nombre,
             'categoria_madre', interno.excel_ruta_categoria(c.padre_id), 'activo', interno.excel_si_no(c.activa),
             'nivel', c.nivel, 'productos', (SELECT count(*) FROM public.producto p WHERE p.categoria_id = c.id))
           ORDER BY c.nivel, interno.excel_ruta_categoria(c.id)), '[]')
      INTO v_filas
      FROM public.categoria_producto c WHERE c.empresa_id = p_empresa_id;

  ELSIF p_hoja = 'existencias_iniciales' THEN
    -- Productos (bienes activos) x bodegas activas que todavía no tienen carga inicial.
    SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'bodega', b.codigo, 'cantidad', NULL, 'costo_unitario', NULL,
             'fecha', NULL, 'nombre', p.nombre, 'unidad', u.codigo, 'sucursal', su.codigo) ORDER BY b.codigo, p.codigo), '[]')
      INTO v_filas
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      JOIN public.bodega b ON b.empresa_id = p.empresa_id AND b.activa
      JOIN public.sucursal su ON su.id = b.sucursal_id
     WHERE p.empresa_id = p_empresa_id AND p.activo AND p.tipo = 'bien'
       AND NOT EXISTS (SELECT 1 FROM public.inventario_movimiento m
                        WHERE m.bodega_id = b.id AND m.producto_id = p.id AND m.origen = 'carga_inicial'
                          AND NOT EXISTS (SELECT 1 FROM public.inventario_documento_anulacion an WHERE an.documento_id = m.documento_id));

  ELSIF p_hoja = 'saldos_iniciales' THEN
    WITH cxc AS (SELECT a.documento_id, a.saldo_centavos FROM interno.cxc_al(p_empresa_id, 'infinity') a WHERE v_cli AND a.origen = 'saldo_inicial'),
         cxp AS (SELECT a.documento_id, a.saldo_centavos FROM interno.cxp_al(p_empresa_id, 'infinity') a WHERE v_prov AND a.origen = 'saldo_inicial')
    SELECT coalesce(jsonb_agg(z.fila ORDER BY z.orden), '[]') INTO v_filas FROM (
      SELECT jsonb_build_object('tipo', 'cliente', 'codigo', t.codigo, 'documento', s.numero_documento,
               'fecha_documento', to_char(s.fecha_documento, 'YYYY-MM-DD'), 'vencimiento', to_char(s.fecha_vencimiento, 'YYYY-MM-DD'),
               'monto', interno.excel_lps(s.monto_centavos), 'fecha', to_char(s.fecha_contable, 'YYYY-MM-DD'), 'nombre', t.nombre,
               'saldo_pendiente', (SELECT interno.excel_lps(a.saldo_centavos) FROM cxc a WHERE a.documento_id = s.id)) AS fila,
             row_number() OVER (ORDER BY t.codigo, s.numero_documento) AS orden
        FROM public.cxc_saldo_inicial s JOIN public.tercero t ON t.id = s.cliente_id
       WHERE v_cli AND s.empresa_id = p_empresa_id AND s.anulada_en IS NULL
      UNION ALL
      SELECT jsonb_build_object('tipo', 'proveedor', 'codigo', t.codigo, 'documento', s.numero_documento,
               'fecha_documento', to_char(s.fecha_documento, 'YYYY-MM-DD'), 'vencimiento', to_char(s.fecha_vencimiento, 'YYYY-MM-DD'),
               'monto', interno.excel_lps(s.monto_centavos), 'fecha', to_char(s.fecha_contable, 'YYYY-MM-DD'), 'nombre', t.nombre,
               'saldo_pendiente', (SELECT interno.excel_lps(a.saldo_centavos) FROM cxp a WHERE a.documento_id = s.id)),
             100000000 + row_number() OVER (ORDER BY t.codigo, s.numero_documento)
        FROM public.cxp_saldo_inicial s JOIN public.tercero t ON t.id = s.proveedor_id
       WHERE v_prov AND s.empresa_id = p_empresa_id AND s.anulada_en IS NULL) z;

  ELSIF p_hoja = 'conteo_fisico' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'bodega', b.codigo, 'cantidad_contada', NULL,
             'nombre', p.nombre, 'unidad', u.codigo) ORDER BY b.codigo, p.codigo), '[]')
      INTO v_filas
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      JOIN public.bodega b ON b.empresa_id = p.empresa_id AND b.activa
     WHERE p.empresa_id = p_empresa_id AND p.activo AND p.tipo = 'bien';
  END IF;

  RETURN jsonb_build_object(
    'hoja', p_hoja,
    'columnas', interno.excel_columnas(p_empresa_id, p_hoja, false),
    'filas', v_filas,
    'costos_ocultos', NOT v_costos AND p_hoja = 'productos',
    'generado_en', public.iso(now()),
    'reglas', jsonb_build_array(
      'Columnas editables (azules) se suben; columnas de solo información (grises) se ignoran.',
      'El código es la llave: con él se busca la fila. Un código que no existe crea uno nuevo.',
      'Celda vacía = se conserva lo que ya había. Nada se borra: para quitar algo, ponga Activo = No.',
      'Montos en lempiras con 2 decimales (ej. 1250.50). Fechas AAAA-MM-DD (ej. 2026-01-31). Sí o No.',
      'Primero suba el archivo en "vista previa": no guarda nada y muestra los errores por fila y columna.',
      'Al aplicar, todo se guarda junto o nada: si hay un solo error, no se guarda ninguna fila.'));
END $$;

-- importar_vista_previa(empresa, hoja, filas): NO guarda nada. Pide excel.importar
-- (y cada fila, el permiso de siempre: productos.editar, productos.precios, terceros.editar...).
CREATE FUNCTION public.importar_vista_previa(p_empresa_id uuid, p_hoja text, p_filas jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'excel.importar', NULL);
  PERFORM interno.excel_hoja_valida(p_hoja);
  RETURN interno.excel_procesar(p_empresa_id, p_hoja, p_filas, gen_random_uuid(), 'Vista previa de la importación de Excel', false);
END $$;

-- importar_aplicar(empresa, hoja, filas, id_operacion, motivo): todo o nada.
CREATE FUNCTION public.importar_aplicar(p_empresa_id uuid, p_hoja text, p_filas jsonb, p_id_operacion uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  x  public.importacion_excel;
  r  jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'excel.importar', NULL);
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'importar_excel');
  SELECT * INTO x FROM public.importacion_excel i WHERE i.empresa_id = p_empresa_id AND i.id_operacion = p_id_operacion;
  IF x.id IS NOT NULL THEN
    RETURN x.resumen || jsonb_build_object('importacion_id', x.id, 'duplicado', true);
  END IF;
  PERFORM interno.excel_hoja_valida(p_hoja);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la importación (mínimo 5 letras), ej. "actualización de precios de octubre".';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'importar_excel');
  SELECT * INTO x FROM public.importacion_excel i WHERE i.empresa_id = p_empresa_id AND i.id_operacion = p_id_operacion;
  IF x.id IS NOT NULL THEN
    RETURN x.resumen || jsonb_build_object('importacion_id', x.id, 'duplicado', true);
  END IF;

  r := interno.excel_procesar(p_empresa_id, p_hoja, p_filas, p_id_operacion, trim(p_motivo), true);
  IF NOT (r->>'aplicado')::boolean THEN
    RETURN r || '{"duplicado": false}';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.importacion_excel (empresa_id, numero, hoja, filas, resumen, motivo, id_operacion, creado_por)
  VALUES (p_empresa_id, interno.siguiente_numero(p_empresa_id, 'importacion_excel'), p_hoja, jsonb_array_length(p_filas),
          r - 'filas', trim(p_motivo), p_id_operacion, auth.uid())
  RETURNING * INTO x;
  PERFORM set_config('app.motivo', '', true);
  RETURN r || jsonb_build_object('importacion_id', x.id, 'numero', x.numero, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 8) Aprobar o rechazar un conteo físico (rama nueva de resolver_aprobacion)
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.conteo_respuesta(a public.aprobacion, c public.conteo_fisico, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado, 'conteo_id', c.id, 'numero', c.numero,
                            'estado', c.estado, 'documento_id', c.documento_id, 'duplicado', p_duplicado)
$$;

CREATE FUNCTION interno.resolver_aprobacion_conteo(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                   p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.aprobacion;
  c       public.conteo_fisico;
  v_rol   text;
  v_fecha date;
  v_lin   jsonb;
  r       jsonb;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  PERFORM interno.exigir_escritura(a.empresa_id, 'inventario.ajustar', 'inventario');
  v_rol := public.mi_rol(a.empresa_id);
  IF p_aprobar IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si aprueba (true) o rechaza (false).';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO c FROM public.conteo_fisico WHERE id = a.documento_id;
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.conteo_respuesta(a, c, true);
  END IF;
  IF NOT p_aprobar AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se rechaza (mínimo 5 letras).';
  END IF;
  IF a.solicitado_por = auth.uid() AND v_rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede aprobar ni rechazar su propio conteo; lo hace otro administrador o el dueño.';
  END IF;
  v_fecha := coalesce(p_fecha, public.hoy_local(a.empresa_id));
  IF p_aprobar THEN
    PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
    IF v_fecha < c.fecha THEN
      RAISE EXCEPTION 'FECHA_INVALIDA: el ajuste no puede tener fecha anterior al conteo (%).', to_char(c.fecha, 'DD/MM/YYYY');
    END IF;
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id FOR UPDATE;
  SELECT * INTO c FROM public.conteo_fisico WHERE id = a.documento_id FOR UPDATE;
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.conteo_respuesta(a, c, true);
  END IF;
  IF a.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la solicitud #% ya está %.', a.numero, a.estado;
  END IF;
  IF p_aprobar AND NOT interno.paso_aprobacion(a, v_rol, p_motivo, p_id_operacion) THEN
    SELECT * INTO a FROM public.aprobacion WHERE id = a.id;
    RETURN interno.conteo_respuesta(a, c, false) || '{"falta_segunda_aprobacion": true}';
  END IF;

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  UPDATE public.aprobacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_por = auth.uid(),
         rol_resolutor = v_rol, resuelto_en = now(), motivo_resolucion = nullif(trim(p_motivo), ''), resolucion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  IF p_aprobar THEN
    -- Se aplica la DIFERENCIA contada sobre la existencia de hoy (lo vendido después del conteo no se pierde).
    SELECT jsonb_agg(jsonb_build_object('producto_id', l->>'producto_id',
             'cantidad_contada', coalesce(s.cantidad, 0) + (l->>'diferencia')::numeric))
      INTO v_lin
      FROM jsonb_array_elements(c.lineas) l
      LEFT JOIN public.inventario_saldo s ON s.bodega_id = c.bodega_id AND s.producto_id = (l->>'producto_id')::uuid;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lin) l WHERE (l->>'cantidad_contada')::numeric < 0) THEN
      RAISE EXCEPTION 'CANTIDAD_INVALIDA: con lo que se movió después del conteo, la existencia quedaría negativa; rechace este conteo y cuente otra vez.';
    END IF;
    r := public.ajustar_inventario(a.empresa_id, c.bodega_id, v_fecha, v_lin,
           'Conteo físico #' || c.numero || ': ' || c.motivo, interno.excel_id(p_id_operacion, 'ajuste_conteo'));
    UPDATE public.conteo_fisico SET estado = 'aplicado', documento_id = (r->>'documento_id')::uuid, resuelto_en = now()
     WHERE id = c.id RETURNING * INTO c;
  ELSE
    UPDATE public.conteo_fisico SET estado = 'rechazado', resuelto_en = now() WHERE id = c.id RETURNING * INTO c;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.conteo_respuesta(a, c, false);
END $$;

-- resolver_aprobacion (misma firma): la de 041 pasa a interno y la pública
-- despacha "conteo_fisico" aquí; todo lo demás sigue igual que antes.
ALTER FUNCTION public.resolver_aprobacion(uuid, boolean, text, uuid, date, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.resolver_aprobacion(uuid, boolean, text, uuid, date, uuid) RENAME TO resolver_aprobacion_041;

CREATE FUNCTION public.resolver_aprobacion(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                           p_fecha date DEFAULT NULL, p_cuenta_salida_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (SELECT a.tipo FROM public.aprobacion a WHERE a.id = p_aprobacion_id) = 'conteo_fisico' THEN
    IF p_cuenta_salida_id IS NOT NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de salida solo se indica al aprobar la anulación de una venta.';
    END IF;
    RETURN interno.resolver_aprobacion_conteo(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha);
  END IF;
  RETURN interno.resolver_aprobacion_041(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha, p_cuenta_salida_id);
END $$;

-- ---------------------------------------------------------------------
-- 9) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.codigo_tercero(), interno.proteger_conteo_fisico(),
  interno.excel_id(uuid, text), interno.excel_lps(numeric), interno.excel_si_no(boolean),
  interno.excel_col(text, text, boolean, text, text, jsonb, boolean), interno.excel_ruta_categoria(uuid),
  interno.excel_buscar_categoria(uuid, text, boolean), interno.excel_ruta_normal(text),
  interno.excel_valor(text, jsonb, jsonb), interno.excel_error(integer, text, text, text),
  interno.excel_error_sql(integer, text, text), interno.excel_hoja_valida(text),
  interno.excel_columnas(uuid, text, boolean), interno.excel_llave(text, jsonb),
  interno.excel_producto_bodega(uuid, jsonb),
  interno.excel_fila_productos(uuid, jsonb, text, uuid), interno.excel_fila_terceros(uuid, jsonb, text, uuid),
  interno.excel_fila_categorias(uuid, jsonb, text, uuid), interno.excel_fila_existencias(uuid, jsonb, text, uuid),
  interno.excel_fila_saldos(uuid, jsonb, text, uuid), interno.excel_fila_conteo(uuid, jsonb, text, uuid),
  interno.excel_lote_existencias(uuid, jsonb, text, uuid), interno.excel_lote_conteo(uuid, jsonb, text, uuid, uuid),
  interno.excel_procesar(uuid, text, jsonb, uuid, text, boolean),
  interno.conteo_respuesta(public.aprobacion, public.conteo_fisico, boolean),
  interno.resolver_aprobacion_conteo(uuid, boolean, text, uuid, date),
  interno.resolver_aprobacion_041(uuid, boolean, text, uuid, date, uuid)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.exportar_plantilla(uuid, text), public.importar_vista_previa(uuid, text, jsonb),
  public.importar_aplicar(uuid, text, jsonb, uuid, text), public.resolver_aprobacion(uuid, boolean, text, uuid, date, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.exportar_plantilla(uuid, text), public.importar_vista_previa(uuid, text, jsonb),
  public.importar_aplicar(uuid, text, jsonb, uuid, text), public.resolver_aprobacion(uuid, boolean, text, uuid, date, uuid)
TO authenticated;
