-- =====================================================================
-- 020_precios_isv.sql  -  Núcleo 0.4.0 (decisión del dueño)
--
--   * empresa.precio_incluye_isv_defecto (por defecto true): lo que la app
--     propone al crear un producto. Lo cambia solo el dueño con
--     configurar_empresa.
--   * producto.precio_incluye_isv: el precio se guarda TAL COMO lo escribe
--     el usuario; esta marca dice si ya trae el ISV adentro.
--     Productos creados antes de 0.4.0: false (su precio era SIN ISV).
--   * public.precio_isv(precio, incluye, impuesto, cantidad): la regla de
--     redondeo, en un solo lugar (la usará también la venta en 2b):
--       total = round(cantidad x precio)                     (centavos)
--       si incluye ISV: con = total; sin = round(total / (1 + tasa)); isv = con - sin
--       si no lo incluye: sin = total; isv = round(sin x tasa);      con = sin + isv
--     round() = a centavo, mitades hacia arriba (0.5 -> 1). El ISV se
--     calcula POR LÍNEA (sobre el total de la línea), nunca por unidad.
--   * v_producto: precio_sin_isv_centavos, isv_centavos, precio_con_isv_centavos.
--   * Historial de precios: guarda también si el precio incluía ISV, y
--     cambiar la marca exige permiso de precios y motivo.
-- =====================================================================

ALTER TABLE public.empresa
  ADD COLUMN precio_incluye_isv_defecto boolean NOT NULL DEFAULT true;

-- Los productos que ya existen quedan "sin ISV" (lo que decían en 0.3.0).
ALTER TABLE public.producto ADD COLUMN precio_incluye_isv boolean NOT NULL DEFAULT false;
ALTER TABLE public.producto ALTER COLUMN precio_incluye_isv DROP DEFAULT;   -- desde ahora lo pone el trigger

ALTER TABLE public.producto_precio
  ADD COLUMN incluye_isv_anterior boolean,      -- NULL en filas de antes de 0.4.0 (eran sin ISV)
  ADD COLUMN incluye_isv_nuevo    boolean;

-- ---------------------------------------------------------------------
-- 1) Regla de cálculo (sin acceso a tablas: la puede usar cualquiera)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.precio_isv(p_precio_centavos bigint, p_incluye_isv boolean, p_tipo_impuesto text,
                                  p_cantidad numeric DEFAULT 1,
                                  OUT sin_isv_centavos bigint, OUT isv_centavos bigint, OUT con_isv_centavos bigint)
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH x AS (
    SELECT round(coalesce(p_cantidad, 1) * p_precio_centavos)::bigint AS total,
           CASE p_tipo_impuesto WHEN 'ISV15' THEN 0.15 WHEN 'ISV18' THEN 0.18 ELSE 0 END::numeric AS tasa)
  SELECT s.sin, c.con - s.sin, c.con
    FROM x
    CROSS JOIN LATERAL (SELECT CASE WHEN p_incluye_isv THEN round(x.total / (1 + x.tasa))::bigint ELSE x.total END AS sin) s
    CROSS JOIN LATERAL (SELECT CASE WHEN p_incluye_isv THEN x.total ELSE s.sin + round(s.sin * x.tasa)::bigint END AS con) c
$$;
REVOKE EXECUTE ON FUNCTION public.precio_isv(bigint, boolean, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.precio_isv(bigint, boolean, text, numeric) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2) Defensa de tabla (reemplaza la de 014): la marca sale de la empresa
--    si no se indica; cambiar precio o marca exige motivo y deja historial.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.proteger_producto() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.unidad u WHERE u.id = NEW.unidad_id
                  AND (u.empresa_id IS NULL OR u.empresa_id = NEW.empresa_id)) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la unidad de medida no existe para esta empresa.';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.precio_incluye_isv IS NULL THEN
      SELECT e.precio_incluye_isv_defecto INTO NEW.precio_incluye_isv FROM public.empresa e WHERE e.id = NEW.empresa_id;
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.id, NEW.empresa_id, NEW.id_operacion, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.id_operacion, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: no se puede cambiar el id, la empresa ni quién creó el producto.';
  END IF;
  NEW.actualizado_en := now();
  IF (NEW.precio_venta_centavos, NEW.precio_incluye_isv) IS DISTINCT FROM (OLD.precio_venta_centavos, OLD.precio_incluye_isv) THEN
    IF length(trim(coalesce(current_setting('app.motivo', true), ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: todo cambio de precio (o de "precio incluye ISV") necesita motivo (mínimo 5 letras).';
    END IF;
    INSERT INTO public.producto_precio (empresa_id, producto_id, precio_anterior_centavos, precio_nuevo_centavos,
                                        incluye_isv_anterior, incluye_isv_nuevo, motivo, cambiado_por)
    VALUES (NEW.empresa_id, NEW.id, OLD.precio_venta_centavos, NEW.precio_venta_centavos,
            OLD.precio_incluye_isv, NEW.precio_incluye_isv, trim(current_setting('app.motivo', true)), auth.uid());
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION interno.precio_inicial() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.producto_precio (empresa_id, producto_id, precio_anterior_centavos, precio_nuevo_centavos,
                                      incluye_isv_nuevo, motivo, cambiado_por)
  VALUES (NEW.empresa_id, NEW.id, NULL, NEW.precio_venta_centavos, NEW.precio_incluye_isv, 'Precio inicial', auth.uid());
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- 3) Datos del producto (reemplaza la de 014): acepta "precio_incluye_isv".
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.aplicar_datos_producto(p public.producto, p_datos jsonb) RETURNS public.producto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_claves(p_datos, ARRAY['codigo','codigo_barras','nombre','categoria_id','unidad_id',
    'tipo_impuesto','precio_venta_centavos','precio_incluye_isv','stock_minimo','permite_fracciones','campos_extra']);

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
  IF p_datos ? 'precio_incluye_isv' THEN
    p.precio_incluye_isv := interno.json_si_no(p_datos->'precio_incluye_isv', 'precio_incluye_isv');
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
-- 4) crear_producto y editar_producto (reemplazan las de 014; misma firma)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_producto(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
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
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'producto');
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
  SELECT e.precio_incluye_isv_defecto INTO p.precio_incluye_isv FROM public.empresa e WHERE e.id = p_empresa_id;
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
                                 precio_venta_centavos, precio_incluye_isv, stock_minimo, permite_fracciones, campos_extra,
                                 id_operacion, creado_por)
    VALUES (p_empresa_id, p.codigo, p.codigo_barras, p.nombre, p.categoria_id, p.unidad_id, p.tipo_impuesto,
            p.precio_venta_centavos, p.precio_incluye_isv, p.stock_minimo, p.permite_fracciones, p.campos_extra,
            p_id_operacion, auth.uid())
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT x.id INTO v_id FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
    IF FOUND THEN
      RETURN jsonb_build_object('producto_id', v_id, 'duplicado', true);
    END IF;
    RAISE EXCEPTION 'YA_EXISTE: ya hay un producto con ese código o código de barras.';
  END;
  RETURN jsonb_build_object('producto_id', v_id, 'codigo', p.codigo, 'precio_incluye_isv', p.precio_incluye_isv,
                            'duplicado', false);
END $$;

-- Edita los datos enviados. El precio NO (use cambiar_precio_producto).
-- "precio_incluye_isv" sí, pero pide productos.precios y motivo (cambia
-- lo que paga el cliente). "activo": true/false pide motivo.
CREATE OR REPLACE FUNCTION public.editar_producto(p_empresa_id uuid, p_producto_id uuid, p_datos jsonb,
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
  IF p.precio_incluye_isv IS DISTINCT FROM v_antes.precio_incluye_isv THEN
    IF NOT public.tiene_permiso('productos.precios', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: cambiar si el precio incluye ISV pide el permiso "productos.precios".';
    END IF;
    IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué cambia "precio incluye ISV" (mínimo 5 letras); queda en el historial de precios.';
    END IF;
  END IF;

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  BEGIN
    UPDATE public.producto SET
      codigo = p.codigo, codigo_barras = p.codigo_barras, nombre = p.nombre, categoria_id = p.categoria_id,
      unidad_id = p.unidad_id, tipo_impuesto = p.tipo_impuesto, stock_minimo = p.stock_minimo,
      permite_fracciones = p.permite_fracciones, campos_extra = p.campos_extra, activo = p.activo,
      precio_incluye_isv = p.precio_incluye_isv
    WHERE id = p_producto_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ese código o código de barras ya es de otro producto.';
  END;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('producto_id', p_producto_id, 'editado', true);
END $$;

-- ---------------------------------------------------------------------
-- 5) configurar_empresa (reemplaza la de 012; misma firma). Clave nueva:
--    "precio_incluye_isv_defecto": true/false.
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
    IF k NOT IN ('tope_credito_centavos', 'permite_existencia_negativa', 'precio_incluye_isv_defecto') THEN
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

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET
    tope_credito_centavos = coalesce((p_datos->>'tope_credito_centavos')::bigint, tope_credito_centavos),
    permite_existencia_negativa = coalesce((p_datos->>'permite_existencia_negativa')::boolean, permite_existencia_negativa),
    precio_incluye_isv_defecto = coalesce((p_datos->>'precio_incluye_isv_defecto')::boolean, precio_incluye_isv_defecto)
  WHERE id = p_empresa_id
  RETURNING * INTO v_emp;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('tope_credito_centavos', v_emp.tope_credito_centavos,
                            'permite_existencia_negativa', v_emp.permite_existencia_negativa,
                            'precio_incluye_isv_defecto', v_emp.precio_incluye_isv_defecto);
END $$;

-- ---------------------------------------------------------------------
-- 6) Vista de productos con precio sin y con ISV (respeta RLS)
-- ---------------------------------------------------------------------
CREATE VIEW public.v_producto WITH (security_invoker = true) AS
  SELECT p.empresa_id, p.id AS producto_id, p.codigo, p.codigo_barras, p.nombre,
         p.categoria_id, c.nombre AS categoria, p.unidad_id, u.codigo AS unidad,
         p.tipo_impuesto, p.precio_venta_centavos, p.precio_incluye_isv,
         x.sin_isv_centavos AS precio_sin_isv_centavos, x.isv_centavos, x.con_isv_centavos AS precio_con_isv_centavos,
         p.stock_minimo, p.permite_fracciones, p.activo, p.campos_extra, p.actualizado_en
  FROM public.producto p
  JOIN public.unidad u ON u.id = p.unidad_id
  LEFT JOIN public.categoria_producto c ON c.id = p.categoria_id
  CROSS JOIN LATERAL public.precio_isv(p.precio_venta_centavos, p.precio_incluye_isv, p.tipo_impuesto) x;
GRANT SELECT ON public.v_producto TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 7) buscar_producto_por_codigo (reemplaza la de 015; misma firma).
--    Agrega precio_incluye_isv y el precio sin y con ISV.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.buscar_producto_por_codigo(p_empresa_id uuid, p_codigo text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cod    text := trim(coalesce(p_codigo, ''));
  p        public.producto;
  v_por    text;
  v_exist  jsonb;
  v_costos boolean;
  x        record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  IF v_cod = '' THEN
    RETURN jsonb_build_object('encontrado', false, 'codigo', v_cod);
  END IF;

  SELECT * INTO p FROM public.producto z WHERE z.empresa_id = p_empresa_id AND z.codigo_barras = v_cod;
  v_por := 'codigo_barras';
  IF p.id IS NULL THEN
    SELECT * INTO p FROM public.producto z WHERE z.empresa_id = p_empresa_id AND z.codigo = upper(v_cod);
    v_por := 'codigo';
  END IF;
  IF p.id IS NULL THEN
    RETURN jsonb_build_object('encontrado', false, 'codigo', v_cod);
  END IF;

  v_costos := public.tiene_permiso('inventario.costos', p_empresa_id);
  IF public.tiene_permiso('inventario.ver', p_empresa_id) THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'bodega_id', b.id, 'bodega', b.codigo, 'cantidad', s.cantidad,
             'costo_promedio', CASE WHEN v_costos THEN s.costo_promedio END)
             ORDER BY b.codigo), '[]')
      INTO v_exist
      FROM public.inventario_saldo s JOIN public.bodega b ON b.id = s.bodega_id
     WHERE s.producto_id = p.id AND b.activa;
  END IF;
  SELECT * INTO x FROM public.precio_isv(p.precio_venta_centavos, p.precio_incluye_isv, p.tipo_impuesto);

  RETURN jsonb_build_object(
    'encontrado', true, 'por', v_por,
    'producto', jsonb_build_object(
      'id', p.id, 'codigo', p.codigo, 'codigo_barras', p.codigo_barras, 'nombre', p.nombre,
      'unidad', (SELECT u.codigo FROM public.unidad u WHERE u.id = p.unidad_id),
      'tipo_impuesto', p.tipo_impuesto, 'precio_venta_centavos', p.precio_venta_centavos,
      'precio_incluye_isv', p.precio_incluye_isv, 'precio_sin_isv_centavos', x.sin_isv_centavos,
      'isv_centavos', x.isv_centavos, 'precio_con_isv_centavos', x.con_isv_centavos,
      'permite_fracciones', p.permite_fracciones, 'activo', p.activo, 'campos_extra', p.campos_extra),
    'existencias', v_exist);
END $$;
