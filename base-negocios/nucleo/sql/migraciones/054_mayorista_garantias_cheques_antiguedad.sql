-- =====================================================================
-- 054_mayorista_garantias_cheques_antiguedad.sql  -  Núcleo 0.18.0.
-- Las 001-053 no se tocan. Cuatro funciones que aprobó el dueño:
--
--   1) PRECIO MAYORISTA (nucleo/docs/productos.md y ventas.md)
--      producto.precio_mayorista_centavos (como el precio: con o sin ISV según
--      "precio incluye ISV") y producto.cantidad_mayorista ("desde cuántas");
--      tercero.es_mayorista. Al calcular una venta, cotización, apartado,
--      cambio o venta previa, la línea usa el precio mayorista si el producto
--      lo tiene y (el cliente es mayorista o la cantidad >= cantidad_mayorista).
--      DECISIÓN (regla del dueño "nunca descuento sobre descuento"): el
--      mayorista es un PRECIO, pero cuenta como la rebaja de la línea: no se
--      suma a una promoción, a un descuento manual ni al descuento de factura.
--      Quien vende puede elegir ("precio_tipo": "normal" | "mayorista"); si no
--      elige, se usa lo mejor para el cliente entre el mayorista y la
--      promoción (si hay varias promociones y una gana, se elige como siempre).
--      La línea guarda qué precio se usó (venta_linea.precio_tipo).
--   2) GARANTÍAS (nucleo/docs/garantias.md)
--   3) ABONOS CON CHEQUE (nucleo/docs/cheques.md)
--   4) ANTIGÜEDAD DE SALDOS (nucleo/docs/antiguedad.md)
-- =====================================================================

-- =====================================================================
-- 1) PRECIO MAYORISTA
-- =====================================================================
INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('PRECIO_MAYORISTA_INVALIDO', 'El precio mayorista no es válido.',
   'El precio mayorista no puede ser mayor que el precio normal, y "desde cantidad" necesita el precio mayorista.'),
  ('PRECIO_MAYORISTA_NO_APLICA', 'Esa línea no lleva precio mayorista.',
   'El precio mayorista se usa si el cliente es mayorista o si la cantidad llega a la de "desde cantidad".');

ALTER TABLE public.producto
  ADD COLUMN precio_mayorista_centavos bigint CHECK (precio_mayorista_centavos BETWEEN 1 AND 9007199254740991),
  ADD COLUMN cantidad_mayorista        numeric(18,4) CHECK (cantidad_mayorista > 0 AND cantidad_mayorista < 100000000000000);
ALTER TABLE public.tercero ADD COLUMN es_mayorista boolean NOT NULL DEFAULT false;
ALTER TABLE public.venta_linea
  ADD COLUMN precio_tipo            text NOT NULL DEFAULT 'normal' CHECK (precio_tipo IN ('normal', 'mayorista')),
  ADD COLUMN precio_normal_centavos bigint;     -- con mayorista: el precio normal de ese momento (para el comprobante)

-- El precio mayorista nunca pasa el normal (por cualquier camino: ficha, cambio de precio o Excel).
CREATE FUNCTION interno.revisar_precio_mayorista() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.cantidad_mayorista IS NOT NULL AND NEW.precio_mayorista_centavos IS NULL THEN
    RAISE EXCEPTION 'PRECIO_MAYORISTA_INVALIDO: "desde cantidad" necesita el precio mayorista del producto %.', NEW.codigo;
  END IF;
  IF NEW.precio_mayorista_centavos > NEW.precio_venta_centavos THEN
    RAISE EXCEPTION 'PRECIO_MAYORISTA_INVALIDO: el precio mayorista (%) del producto % no puede ser mayor que el precio normal (%).',
      interno.lempiras(NEW.precio_mayorista_centavos), NEW.codigo, interno.lempiras(NEW.precio_venta_centavos);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER revisar_mayorista BEFORE INSERT OR UPDATE OF precio_venta_centavos, precio_mayorista_centavos, cantidad_mayorista
  ON public.producto FOR EACH ROW EXECUTE FUNCTION interno.revisar_precio_mayorista();

-- ¿El cliente de la venta que se está calculando es mayorista? Lo anota quien calcula
-- (app.cliente_venta, local a la transacción) para no cambiar la firma de calcular_venta.
CREATE FUNCTION interno.cliente_venta_mayorista(p_empresa_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT t.es_mayorista FROM public.tercero t
                    WHERE t.empresa_id = p_empresa_id AND t.es_cliente
                      AND t.id::text = nullif(current_setting('app.cliente_venta', true), '')), false)
$$;

-- Precio mayorista de una línea. p = el producto como lo da producto_de (con el precio de la
-- sucursal, si hay). Aplica si el producto lo tiene, si (el cliente es mayorista o la cantidad
-- llega a cantidad_mayorista) y si de verdad es más barato que el precio normal (con impuesto).
CREATE FUNCTION interno.mayorista_de(p public.producto, p_tasa numeric, p_cantidad numeric, p_cliente_mayorista boolean,
                                     OUT o_aplica boolean, OUT o_precio bigint, OUT o_incluye boolean,
                                     OUT o_cantidad numeric, OUT o_mas_barato boolean, OUT o_por text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  SELECT x.precio_mayorista_centavos, x.precio_incluye_isv, x.cantidad_mayorista INTO o_precio, o_incluye, o_cantidad
    FROM public.producto x WHERE x.id = p.id;
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

-- Avisos de precio por debajo del costo promedio (solo a quien ve costos; no impide guardar).
CREATE FUNCTION interno.avisos_precio_costo(p_producto_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p      public.producto;
  v_tasa numeric;
  v_cost numeric;
  v_sin  bigint;
  r      jsonb := '[]';
BEGIN
  SELECT * INTO p FROM public.producto WHERE id = p_producto_id;
  IF p.id IS NULL OR NOT public.puede_leer(p.empresa_id, 'inventario.costos') THEN
    RETURN r;
  END IF;
  SELECT i.porcentaje INTO v_tasa FROM public.impuesto i WHERE i.empresa_id = p.empresa_id AND i.codigo = p.tipo_impuesto;
  IF p.tipo = 'servicio' THEN
    SELECT sc.costo_estimado_centavos INTO v_cost FROM public.servicio_costo sc WHERE sc.producto_id = p.id;
  ELSE
    SELECT CASE WHEN sum(s.cantidad) > 0 THEN sum(s.valor_centavos) / sum(s.cantidad) END INTO v_cost
      FROM public.inventario_saldo s WHERE s.producto_id = p.id AND s.cantidad > 0;
  END IF;
  IF v_cost IS NULL OR v_cost <= 0 THEN
    RETURN r;
  END IF;
  v_sin := (public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, coalesce(v_tasa, 0), 1)).sin_isv_centavos;
  IF v_sin < v_cost THEN
    r := r || jsonb_build_object('tipo', 'precio_bajo_costo', 'mensaje',
      'El precio normal sin ISV (' || interno.lempiras(v_sin) || ') queda por debajo del costo promedio (' || interno.lempiras(round(v_cost)::bigint) || ').');
  END IF;
  IF p.precio_mayorista_centavos IS NOT NULL THEN
    v_sin := (public.precio_con_tasa(p.precio_mayorista_centavos, p.precio_incluye_isv, coalesce(v_tasa, 0), 1)).sin_isv_centavos;
    IF v_sin < v_cost THEN
      r := r || jsonb_build_object('tipo', 'mayorista_bajo_costo', 'mensaje',
        'El precio mayorista sin ISV (' || interno.lempiras(v_sin) || ') queda por debajo del costo promedio (' || interno.lempiras(round(v_cost)::bigint) || ').');
    END IF;
  END IF;
  RETURN r;
END $$;

-- Lee y valida "precio_mayorista_centavos" y "cantidad_mayorista" de unos datos (null = quitar).
CREATE FUNCTION interno.datos_mayorista(p_datos jsonb, OUT o_hay boolean, OUT o_precio bigint, OUT o_cantidad numeric,
                                        OUT o_hay_cantidad boolean)
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  o_hay := p_datos ? 'precio_mayorista_centavos';
  o_hay_cantidad := p_datos ? 'cantidad_mayorista';
  IF o_hay AND p_datos->'precio_mayorista_centavos' <> 'null'::jsonb THEN
    o_precio := interno.json_centavos(p_datos->'precio_mayorista_centavos', 'precio_mayorista_centavos');
    IF o_precio = 0 THEN
      RAISE EXCEPTION 'PRECIO_MAYORISTA_INVALIDO: el precio mayorista debe ser mayor que cero (o null para quitarlo).';
    END IF;
  END IF;
  IF o_hay_cantidad AND p_datos->'cantidad_mayorista' <> 'null'::jsonb THEN
    IF jsonb_typeof(p_datos->'cantidad_mayorista') <> 'number' OR (p_datos->>'cantidad_mayorista')::numeric <= 0
       OR (p_datos->>'cantidad_mayorista')::numeric >= 100000000000000
       OR (p_datos->>'cantidad_mayorista')::numeric <> round((p_datos->>'cantidad_mayorista')::numeric, 4) THEN
      RAISE EXCEPTION 'PRECIO_MAYORISTA_INVALIDO: "desde cantidad" es un número mayor que cero (hasta 4 decimales).';
    END IF;
    o_cantidad := (p_datos->>'cantidad_mayorista')::numeric;
  END IF;
END $$;

-- crear_producto / editar_producto (las de 026 pasan a interno sin cambios; las públicas, misma
-- firma, aceptan además "precio_mayorista_centavos" y "cantidad_mayorista" y responden "avisos").
--   Crear: con productos.editar (como el precio de un producto nuevo).
--   Editar: con productos.precios y motivo (como un cambio de precio); null quita el mayorista.
ALTER FUNCTION public.crear_producto(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.crear_producto(uuid, jsonb, uuid) RENAME TO crear_producto_026;
ALTER FUNCTION public.editar_producto(uuid, uuid, jsonb, text) SET SCHEMA interno;
ALTER FUNCTION interno.editar_producto(uuid, uuid, jsonb, text) RENAME TO editar_producto_026;

-- Claves nuevas del producto (0.18.0) que las funciones de antes no conocen.
CREATE FUNCTION interno.claves_producto_054() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['precio_mayorista_centavos', 'cantidad_mayorista']
$$;

-- Aplica las claves nuevas a un producto ya guardado (con el motivo de quien llama).
CREATE FUNCTION interno.aplicar_producto_054(p_empresa_id uuid, p_producto_id uuid, p_datos jsonb, p_motivo text,
                                             p_nuevo boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p   public.producto;
  m   record;
  v_p bigint;
  v_c numeric;
BEGIN
  IF NOT (p_datos ?| interno.claves_producto_054()) THEN
    RETURN;
  END IF;
  SELECT * INTO p FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id FOR UPDATE;
  SELECT * INTO m FROM interno.datos_mayorista(p_datos);
  v_p := CASE WHEN m.o_hay THEN m.o_precio ELSE p.precio_mayorista_centavos END;
  v_c := CASE WHEN m.o_hay_cantidad THEN m.o_cantidad WHEN m.o_hay AND m.o_precio IS NULL THEN NULL ELSE p.cantidad_mayorista END;
  IF (v_p, v_c) IS DISTINCT FROM (p.precio_mayorista_centavos, p.cantidad_mayorista) AND NOT p_nuevo THEN
    IF NOT public.tiene_permiso('productos.precios', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: cambiar el precio mayorista pide el permiso "productos.precios".';
    END IF;
    IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué cambia el precio mayorista (mínimo 5 letras); queda en la bitácora.';
    END IF;
  END IF;
  IF (v_p, v_c) IS NOT DISTINCT FROM (p.precio_mayorista_centavos, p.cantidad_mayorista) THEN
    RETURN;
  END IF;
  PERFORM set_config('app.motivo', coalesce(nullif(trim(p_motivo), ''), CASE WHEN p_nuevo THEN 'Producto nuevo' END, ''), true);
  UPDATE public.producto SET precio_mayorista_centavos = v_p, cantidad_mayorista = v_c WHERE id = p.id;
  PERFORM set_config('app.motivo', '', true);
END $$;

CREATE FUNCTION public.crear_producto(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RETURN interno.crear_producto_026(p_empresa_id, p_datos, p_id_operacion);
  END IF;
  r := interno.crear_producto_026(p_empresa_id, p_datos - interno.claves_producto_054(), p_id_operacion);
  IF NOT (r->>'duplicado')::boolean THEN
    PERFORM interno.aplicar_producto_054(p_empresa_id, (r->>'producto_id')::uuid, p_datos, NULL, true);
  END IF;
  RETURN r || jsonb_build_object('avisos', interno.avisos_precio_costo((r->>'producto_id')::uuid));
END $$;

CREATE FUNCTION public.editar_producto(p_empresa_id uuid, p_producto_id uuid, p_datos jsonb, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r     jsonb;
  v_dat jsonb;
BEGIN
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' OR NOT (p_datos ?| interno.claves_producto_054()) THEN
    r := interno.editar_producto_026(p_empresa_id, p_producto_id, p_datos, p_motivo);
  ELSE
    PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
    v_dat := p_datos - interno.claves_producto_054();
    IF v_dat <> '{}'::jsonb THEN
      r := interno.editar_producto_026(p_empresa_id, p_producto_id, v_dat, p_motivo);
    ELSIF NOT EXISTS (SELECT 1 FROM public.producto x WHERE x.id = p_producto_id AND x.empresa_id = p_empresa_id) THEN
      RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
    END IF;
    PERFORM interno.aplicar_producto_054(p_empresa_id, p_producto_id, p_datos, p_motivo, false);
    IF r IS NULL THEN
      r := jsonb_build_object('producto_id', p_producto_id);
    END IF;
  END IF;
  RETURN r || jsonb_build_object('avisos', interno.avisos_precio_costo(p_producto_id));
END $$;

-- cambiar_precio_producto (misma firma): además los avisos de costo. (El trigger ya impide bajar
-- el precio normal por debajo del mayorista.)
ALTER FUNCTION public.cambiar_precio_producto(uuid, uuid, bigint, text) SET SCHEMA interno;
ALTER FUNCTION interno.cambiar_precio_producto(uuid, uuid, bigint, text) RENAME TO cambiar_precio_producto_014;
CREATE FUNCTION public.cambiar_precio_producto(p_empresa_id uuid, p_producto_id uuid, p_precio_centavos bigint, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN interno.cambiar_precio_producto_014(p_empresa_id, p_producto_id, p_precio_centavos, p_motivo)
         || jsonb_build_object('avisos', interno.avisos_precio_costo(p_producto_id));
END $$;

-- Clientes mayoristas: crear_tercero / editar_tercero aceptan "es_mayorista" (true/false). Marcar o
-- quitar a un mayorista cambia precios: pide productos.precios (dueño y admin), queda en la bitácora.
ALTER FUNCTION public.editar_tercero(uuid, uuid, jsonb, text) SET SCHEMA interno;
ALTER FUNCTION interno.editar_tercero(uuid, uuid, jsonb, text) RENAME TO editar_tercero_013;

CREATE FUNCTION interno.poner_mayorista(p_empresa_id uuid, p_tercero_id uuid, p_valor jsonb, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t     public.tercero;
  v_may boolean := interno.json_si_no(p_valor, 'es_mayorista');
BEGIN
  SELECT * INTO t FROM public.tercero WHERE id = p_tercero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF t.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cliente o proveedor no existe en esta empresa.';
  END IF;
  IF v_may IS NULL OR v_may = t.es_mayorista THEN
    RETURN;
  END IF;
  IF NOT public.tiene_permiso('productos.precios', p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: marcar a un cliente como mayorista cambia sus precios; pide el permiso "productos.precios".';
  END IF;
  IF v_may AND NOT t.es_cliente THEN
    RAISE EXCEPTION 'DATO_INVALIDO: solo un cliente puede ser mayorista.';
  END IF;
  PERFORM set_config('app.motivo', coalesce(nullif(trim(p_motivo), ''), CASE WHEN v_may THEN 'Cliente mayorista' ELSE 'Ya no es mayorista' END), true);
  UPDATE public.tercero SET es_mayorista = v_may WHERE id = t.id;
  PERFORM set_config('app.motivo', '', true);
END $$;

CREATE OR REPLACE FUNCTION public.crear_tercero(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'terceros.editar', NULL);
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'tercero');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'tercero');
  IF jsonb_typeof(p_datos) = 'object' AND p_datos ? 'es_mayorista' THEN
    r := interno.crear_tercero_base(p_empresa_id, p_datos - 'es_mayorista', p_id_operacion);
    IF NOT (r->>'duplicado')::boolean THEN
      PERFORM interno.poner_mayorista(p_empresa_id, (r->>'tercero_id')::uuid, p_datos->'es_mayorista', NULL);
    END IF;
    RETURN r;
  END IF;
  RETURN interno.crear_tercero_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

CREATE FUNCTION public.editar_tercero(p_empresa_id uuid, p_tercero_id uuid, p_datos jsonb, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' OR NOT p_datos ? 'es_mayorista' THEN
    RETURN interno.editar_tercero_013(p_empresa_id, p_tercero_id, p_datos, p_motivo);
  END IF;
  PERFORM interno.exigir_escritura(p_empresa_id, 'terceros.editar', NULL);
  IF p_datos - 'es_mayorista' <> '{}'::jsonb THEN
    r := interno.editar_tercero_013(p_empresa_id, p_tercero_id, p_datos - 'es_mayorista', p_motivo);
  END IF;
  PERFORM interno.poner_mayorista(p_empresa_id, p_tercero_id, p_datos->'es_mayorista', p_motivo);
  RETURN coalesce(r, jsonb_build_object('tercero_id', p_tercero_id)) || jsonb_build_object('es_mayorista',
    (SELECT t.es_mayorista FROM public.tercero t WHERE t.id = p_tercero_id));
END $$;

-- ---------------------------------------------------------------------
-- Cálculo de la venta (reemplaza la de 038; misma firma). Nuevo: precio mayorista por línea
-- ("precio_tipo" opcional) y en cada línea "precio_tipo", "precio_normal_centavos" y
-- "precio_mayorista_disponible". El cliente sale de app.cliente_venta (lo anota quien calcula).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.calcular_venta(p_empresa_id uuid, p_fecha date, p_lineas jsonb, p_desc_factura jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l        jsonb;
  i        integer := 0;
  n        integer;
  p        public.producto;
  imp      public.impuesto;
  q        numeric;
  v_pct    numeric;
  v_mto    bigint;
  v_pid    uuid;
  v_dp     bigint;
  v_dl     bigint;
  a_prod   uuid[] := '{}';
  a_nom    text[] := '{}';
  a_q      numeric[] := '{}';
  a_pre    bigint[] := '{}';
  a_inc    boolean[] := '{}';
  a_imp    text[] := '{}';
  a_tasa   numeric[] := '{}';
  a_clase  text[] := '{}';
  a_serv   boolean[] := '{}';
  a_cest   bigint[] := '{}';
  a_promo  uuid[] := '{}';
  a_lpct   numeric[] := '{}';
  a_lmto   bigint[] := '{}';
  a_bruto  bigint[] := '{}';
  a_dpro   bigint[] := '{}';
  a_dlin   bigint[] := '{}';
  a_v2     bigint[] := '{}';
  a_w      bigint[] := '{}';
  a_part   bigint[];
  a_dfac   bigint[];
  a_elig   boolean[] := '{}';
  a_we     bigint[] := '{}';
  v_tot_we bigint := 0;
  v_promos jsonb;
  v_fpct   numeric;
  v_fmto   bigint;
  v_tot_w  bigint := 0;
  v_v3     bigint;
  s0 bigint; s1 bigint; s3 bigint; i3 bigint; c3 bigint;
  v_out    jsonb := '[]';
  v_desg   jsonb;
  t_sub bigint := 0; t_dpro bigint := 0; t_sin1 bigint := 0; t_base bigint := 0;
  t_grav bigint := 0; t_exe bigint := 0; t_exo bigint := 0; t_imp bigint := 0; t_tot bigint := 0;
  v_dif    bigint;
  v_c0     bigint;
  v_x      bigint;
  v_r      bigint;
  v_mejor  integer;
  v_mejor_x bigint;
  v_mejor_r bigint;
  -- 0.18.0: precio mayorista
  v_cli_may boolean := interno.cliente_venta_mayorista(p_empresa_id);
  m        record;
  v_ptip   text;
  v_usa_may boolean;
  v_con_may bigint;
  v_con_pro bigint;
  v_hay_desc boolean;
  v_hay_promo boolean;
  a_tip    text[] := '{}';
  a_pnor   bigint[] := '{}';
  a_mdis   boolean[] := '{}';
BEGIN
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad', 'descuento_porcentaje', 'descuento_centavos', 'promocion_id',
                                                'precio_tipo']);
  FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, true);
    imp := interno.impuesto_de(p_empresa_id, p.tipo_impuesto);
    q := interno.json_numero(l->'cantidad', 'cantidad', i);
    PERFORM interno.validar_cantidad(p, q, i);

    -- 0.18.0: precio mayorista. Es un PRECIO (no cuenta para el tope de descuento del puesto),
    -- pero NO se suma a otro descuento: la línea lleva mayorista, o promoción, o descuento manual.
    v_ptip := interno.json_texto(l->'precio_tipo', 'precio_tipo', 20);
    IF v_ptip IS NOT NULL AND v_ptip NOT IN ('normal', 'mayorista') THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: "precio_tipo" de la línea % es "normal" o "mayorista".', i;
    END IF;
    v_hay_desc := coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb
                  OR coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb;
    v_hay_promo := coalesce(l->'promocion_id', 'null'::jsonb) <> 'null'::jsonb;
    SELECT * INTO m FROM interno.mayorista_de(p, imp.porcentaje, q, v_cli_may);
    v_usa_may := false;
    IF v_ptip = 'mayorista' THEN
      IF NOT m.o_aplica THEN
        RAISE EXCEPTION 'PRECIO_MAYORISTA_NO_APLICA: la línea % ("%") no lleva precio mayorista (%).', i, p.nombre,
          CASE WHEN m.o_precio IS NULL THEN 'el producto no tiene precio mayorista'
               WHEN NOT m.o_mas_barato THEN 'en esta sucursal el precio normal ya es igual o menor'
               WHEN m.o_cantidad IS NOT NULL THEN 'el cliente no es mayorista y la cantidad es menor que ' || trim_scale(m.o_cantidad)
               ELSE 'el cliente no es mayorista' END;
      END IF;
      IF v_hay_promo OR v_hay_desc THEN
        RAISE EXCEPTION 'DESCUENTO_DOBLE: la línea % ("%") va con precio mayorista; no admite además una promoción ni un descuento (nunca descuento sobre descuento).', i, p.nombre;
      END IF;
      v_usa_may := true;
    ELSIF v_ptip IS NULL AND m.o_aplica AND NOT v_hay_promo THEN
      IF v_hay_desc THEN
        RAISE EXCEPTION 'DESCUENTO_DOBLE: la línea % ("%") tiene precio mayorista; para darle un descuento manual mande "precio_tipo": "normal" (nunca descuento sobre descuento).', i, p.nombre;
      END IF;
      -- Sin elegir: el mejor para el cliente entre el mayorista y la promoción (si hay una sola, o la
      -- que más descuenta). Si hay varias promociones y alguna gana al mayorista, quien vende elige (abajo).
      v_promos := interno.promociones_de(p_empresa_id, p, p_fecha, q);
      v_usa_may := true;
      IF jsonb_array_length(v_promos) > 0 THEN
        v_con_may := (public.precio_con_tasa(round(q * m.o_precio)::bigint, m.o_incluye, imp.porcentaje, 1)).con_isv_centavos;
        v_con_pro := (public.precio_con_tasa(round(q * p.precio_venta_centavos)::bigint - (v_promos->0->>'descuento_centavos')::bigint,
                                             p.precio_incluye_isv, imp.porcentaje, 1)).con_isv_centavos;
        v_usa_may := v_con_may <= v_con_pro;
      END IF;
    END IF;
    a_mdis := a_mdis || m.o_aplica;
    a_pnor := a_pnor || CASE WHEN v_usa_may THEN p.precio_venta_centavos END;
    a_tip := a_tip || CASE WHEN v_usa_may THEN 'mayorista' ELSE 'normal' END;
    IF v_usa_may THEN
      p.precio_venta_centavos := m.o_precio;
      p.precio_incluye_isv := m.o_incluye;
    END IF;

    a_prod := a_prod || p.id;  a_nom := a_nom || p.nombre;  a_q := a_q || q;
    a_pre := a_pre || p.precio_venta_centavos;  a_inc := a_inc || p.precio_incluye_isv;  a_imp := a_imp || p.tipo_impuesto;
    a_tasa := a_tasa || imp.porcentaje;  a_clase := a_clase || imp.clase;  a_serv := a_serv || (p.tipo = 'servicio');
    a_cest := a_cest || CASE WHEN p.tipo = 'servicio' THEN
      (SELECT round(q * sc.costo_estimado_centavos)::bigint FROM public.servicio_costo sc WHERE sc.producto_id = p.id) END;
    a_bruto := a_bruto || round(q * p.precio_venta_centavos)::bigint;

    -- Promociones vigentes de su categoría (o de una categoría madre). NUNCA
    -- se suman: con una sola se aplica; con varias, quien vende elige una
    -- ("promocion_id"); si no elige, PROMOCION_A_ELEGIR con la lista.
    v_promos := CASE WHEN v_usa_may THEN '[]'::jsonb ELSE interno.promociones_de(p_empresa_id, p, p_fecha, q) END;
    v_pid := NULL; v_dp := NULL;
    IF coalesce(l->'promocion_id', 'null'::jsonb) <> 'null'::jsonb THEN
      v_pid := interno.json_uuid(l->'promocion_id', 'promocion_id');
      SELECT (y->>'descuento_centavos')::bigint INTO v_dp FROM jsonb_array_elements(v_promos) y WHERE (y->>'promocion_id')::uuid = v_pid;
      IF v_dp IS NULL THEN
        RAISE EXCEPTION 'PROMOCION_INVALIDA: la promoción elegida en la línea % no aplica a "%" en la fecha de la venta (no existe, está desactivada, vencida o es de otra categoría).', i, p.nombre;
      END IF;
    ELSIF jsonb_array_length(v_promos) = 1 THEN
      v_pid := (v_promos->0->>'promocion_id')::uuid;
      v_dp := (v_promos->0->>'descuento_centavos')::bigint;
    ELSIF jsonb_array_length(v_promos) > 1 THEN
      RAISE EXCEPTION 'PROMOCION_A_ELEGIR: la línea % ("%") tiene % promociones vigentes y no se suman; elija una con "promocion_id": %',
        i, p.nombre, jsonb_array_length(v_promos),
        (SELECT string_agg(format('"%s" (promocion_id %s, descuento %s)', y->>'nombre', y->>'promocion_id',
                                  interno.lempiras((y->>'descuento_centavos')::bigint)), '; ') FROM jsonb_array_elements(v_promos) y)
        || CASE WHEN m.o_aplica THEN ' (o el precio mayorista con "precio_tipo": "mayorista")' ELSE '' END;
    END IF;
    a_promo := a_promo || v_pid;
    a_dpro := a_dpro || coalesce(v_dp, 0);

    -- Descuento del artículo (uno solo: porcentaje o monto).
    v_pct := NULL; v_mto := NULL; v_dl := 0;
    IF coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb
       AND coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % trae descuento en porcentaje y en monto; use solo uno.', i;
    END IF;
    -- Nunca descuento sobre descuento: una línea con promoción no lleva descuento manual.
    IF v_pid IS NOT NULL AND (coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb
                              OR coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb) THEN
      RAISE EXCEPTION 'DESCUENTO_DOBLE: la línea % ("%") ya tiene una promoción; no admite además un descuento manual (nunca descuento sobre descuento).', i, p.nombre;
    END IF;
    IF coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb THEN
      v_pct := interno.json_numero(l->'descuento_porcentaje', 'descuento_porcentaje', i);
      IF v_pct < 0 OR v_pct > 100 OR v_pct <> round(v_pct, 2) THEN
        RAISE EXCEPTION 'LINEA_INVALIDA: el descuento de la línea % va de 0 a 100 %% (hasta 2 decimales).', i;
      END IF;
      v_dl := round((a_bruto[i] - a_dpro[i]) * v_pct / 100)::bigint;
    ELSIF coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      v_mto := interno.json_centavos(l->'descuento_centavos', 'descuento_centavos');
      IF v_mto > a_bruto[i] - a_dpro[i] THEN
        RAISE EXCEPTION 'LINEA_INVALIDA: el descuento de la línea % (% centavos) pasa su precio (% centavos).', i, v_mto, a_bruto[i] - a_dpro[i];
      END IF;
      v_dl := v_mto;
    END IF;
    a_lpct := a_lpct || v_pct;  a_lmto := a_lmto || v_mto;  a_dlin := a_dlin || v_dl;
    a_v2 := a_v2 || (a_bruto[i] - a_dpro[i] - v_dl);
    a_w := a_w || (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_bruto[i] - a_dpro[i] - v_dl, p.precio_incluye_isv, imp.porcentaje, 1) x);
    v_tot_w := v_tot_w + a_w[i];
    -- El descuento de factura solo va a las líneas SIN otro descuento.
    -- 0.18.0: la línea con precio mayorista tampoco (el mayorista ya es su rebaja).
    a_elig := a_elig || (NOT v_usa_may AND v_pid IS NULL AND coalesce(v_pct, 0) = 0 AND coalesce(v_mto, 0) = 0);
    a_we := a_we || CASE WHEN a_elig[i] THEN a_w[i] ELSE 0 END;
    v_tot_we := v_tot_we + a_we[i];
  END LOOP;
  n := i;

  -- Descuento de factura (uno solo: porcentaje o monto con impuesto).
  a_dfac := array_fill(0::bigint, ARRAY[n]);
  IF p_desc_factura IS NOT NULL AND p_desc_factura <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(p_desc_factura, ARRAY['porcentaje', 'monto_centavos']);
    IF coalesce(p_desc_factura->'porcentaje', 'null'::jsonb) <> 'null'::jsonb
       AND coalesce(p_desc_factura->'monto_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el descuento de factura va en porcentaje o en monto, no los dos.';
    END IF;
    IF coalesce(p_desc_factura->'porcentaje', 'null'::jsonb) <> 'null'::jsonb THEN
      IF jsonb_typeof(p_desc_factura->'porcentaje') <> 'number' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el porcentaje del descuento de factura debe ser un número.';
      END IF;
      v_fpct := (p_desc_factura->>'porcentaje')::numeric;
      IF v_fpct < 0 OR v_fpct > 100 OR v_fpct <> round(v_fpct, 2) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el descuento de factura va de 0 a 100 %% (hasta 2 decimales).';
      END IF;
      IF v_fpct > 0 AND v_tot_we = 0 THEN
        RAISE EXCEPTION 'DESCUENTO_DOBLE: todas las líneas ya tienen promoción, precio mayorista o descuento; el descuento de factura no se suma sobre otro descuento.';
      END IF;
      FOR i IN 1..n LOOP
        a_dfac[i] := CASE WHEN a_elig[i] THEN round(a_v2[i] * v_fpct / 100)::bigint ELSE 0 END;
      END LOOP;
    ELSIF coalesce(p_desc_factura->'monto_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      v_fmto := interno.json_centavos(p_desc_factura->'monto_centavos', 'descuento_factura.monto_centavos');
      IF v_fmto > 0 AND v_tot_we = 0 THEN
        RAISE EXCEPTION 'DESCUENTO_DOBLE: todas las líneas ya tienen promoción, precio mayorista o descuento; el descuento de factura no se suma sobre otro descuento.';
      END IF;
      IF v_fmto > v_tot_we THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el descuento de factura (%) pasa el total de las líneas sin otro descuento (%).', interno.lempiras(v_fmto), interno.lempiras(v_tot_we);
      END IF;
      IF v_fmto > 0 THEN
        -- Reparto por el total con impuesto de cada línea; los centavos que sobran van a las de resto mayor.
        SELECT array_agg(y.parte ORDER BY y.k) INTO a_part
          FROM (SELECT x.k, x.base + CASE WHEN row_number() OVER (ORDER BY x.resto DESC, x.k) <= v_fmto - sum(x.base) OVER ()
                                          THEN 1 ELSE 0 END AS parte
                  FROM (SELECT t.k, floor(v_fmto::numeric * t.w / v_tot_we)::bigint AS base,
                               v_fmto::numeric * t.w - floor(v_fmto::numeric * t.w / v_tot_we) * v_tot_we AS resto
                          FROM unnest(a_we) WITH ORDINALITY AS t(w, k)) x) y;
        FOR i IN 1..n LOOP
          a_dfac[i] := least(a_v2[i], CASE WHEN a_inc[i] THEN a_part[i]
                                           ELSE round(a_part[i] / (1 + a_tasa[i] / 100))::bigint END);
        END LOOP;
        -- 0.9.1: al centavo. En líneas con precio SIN impuesto el reparto (sin ISV) más el ISV
        -- recalculado podía quedar 1 centavo arriba o abajo por línea. Se ajusta la ÚLTIMA línea
        -- que pueda dar el monto exacto (con precio con impuesto o exenta siempre puede); si
        -- ninguna puede (pasa rara vez, solo con líneas sin impuesto incluido), queda lo más cerca.
        v_dif := v_fmto;
        FOR i IN 1..n LOOP
          IF a_elig[i] THEN
            v_dif := v_dif - (a_w[i] - (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_v2[i] - a_dfac[i], a_inc[i], a_tasa[i], 1) x));
          END IF;
        END LOOP;
        IF v_dif <> 0 THEN
          v_mejor := NULL;
          FOR i IN REVERSE n..1 LOOP
            CONTINUE WHEN NOT a_elig[i];
            v_c0 := (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_v2[i] - a_dfac[i], a_inc[i], a_tasa[i], 1) x);
            -- candidatos: del más cercano al reparto original al más lejano
            FOR v_x IN SELECT g FROM generate_series(greatest(0, a_dfac[i] - abs(v_dif) - 3), least(a_v2[i], a_dfac[i] + abs(v_dif) + 3)) g
                        ORDER BY abs(g - a_dfac[i]), g LOOP
              -- lo que faltaría si esta línea llevara v_x de descuento
              v_r := v_dif - (v_c0 - (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_v2[i] - v_x, a_inc[i], a_tasa[i], 1) x));
              IF v_mejor IS NULL OR abs(v_r) < abs(v_mejor_r) THEN
                v_mejor := i;  v_mejor_x := v_x;  v_mejor_r := v_r;
              END IF;
              EXIT WHEN v_mejor_r = 0;
            END LOOP;
            EXIT WHEN v_mejor_r = 0;
          END LOOP;
          IF v_mejor IS NOT NULL THEN
            a_dfac[v_mejor] := v_mejor_x;
          END IF;
        END IF;
      END IF;
    END IF;
  END IF;

  -- Impuesto por línea sobre el neto (la regla de public.precio_con_tasa) y totales.
  FOR i IN 1..n LOOP
    v_v3 := a_v2[i] - a_dfac[i];
    SELECT x.sin_isv_centavos INTO s0 FROM public.precio_con_tasa(a_bruto[i], a_inc[i], a_tasa[i], 1) x;
    SELECT x.sin_isv_centavos INTO s1 FROM public.precio_con_tasa(a_bruto[i] - a_dpro[i], a_inc[i], a_tasa[i], 1) x;
    SELECT x.sin_isv_centavos, x.isv_centavos, x.con_isv_centavos INTO s3, i3, c3
      FROM public.precio_con_tasa(v_v3, a_inc[i], a_tasa[i], 1) x;
    v_out := v_out || jsonb_build_object('linea', i, 'producto_id', a_prod[i], 'descripcion', a_nom[i], 'cantidad', a_q[i],
      'precio_unitario_centavos', a_pre[i], 'precio_incluye_isv', a_inc[i], 'tipo_impuesto', a_imp[i],
      'impuesto_porcentaje', a_tasa[i], 'impuesto_clase', a_clase[i], 'es_servicio', a_serv[i],
      'costo_estimado_centavos', a_cest[i],
      'promocion_id', a_promo[i], 'descuento_linea_porcentaje', a_lpct[i], 'descuento_linea_monto_centavos', a_lmto[i],
      'bruto_centavos', a_bruto[i], 'descuento_promocion_precio_centavos', a_dpro[i], 'descuento_linea_centavos', a_dlin[i],
      'descuento_factura_centavos', a_dfac[i], 'neto_centavos', v_v3,
      'subtotal_centavos', s0, 'descuento_promocion_centavos', s0 - s1, 'descuento_centavos', s0 - s3,
      'base_centavos', s3, 'impuesto_centavos', i3, 'total_centavos', c3,
      'precio_tipo', a_tip[i], 'precio_normal_centavos', a_pnor[i], 'precio_mayorista_disponible', a_mdis[i]);
    t_sub := t_sub + s0;  t_dpro := t_dpro + (s0 - s1);  t_sin1 := t_sin1 + s1;  t_base := t_base + s3;
    t_imp := t_imp + i3;  t_tot := t_tot + c3;
    IF a_clase[i] = 'gravado' THEN t_grav := t_grav + s3;
    ELSIF a_clase[i] = 'exonerado' THEN t_exo := t_exo + s3;
    ELSE t_exe := t_exe + s3; END IF;
  END LOOP;

  -- Desglose por impuesto (para el documento y el asiento).
  SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', d.codigo, 'nombre', im.nombre, 'porcentaje', d.porcentaje,
           'clase', d.clase, 'base_centavos', d.base, 'impuesto_centavos', d.impuesto, 'cuenta_por_pagar', im.cuenta_por_pagar)
           ORDER BY im.orden, d.codigo), '[]')
    INTO v_desg
    FROM (SELECT x->>'tipo_impuesto' AS codigo, (x->>'impuesto_porcentaje')::numeric AS porcentaje, x->>'impuesto_clase' AS clase,
                 sum((x->>'base_centavos')::bigint) AS base, sum((x->>'impuesto_centavos')::bigint) AS impuesto
            FROM jsonb_array_elements(v_out) x GROUP BY 1, 2, 3) d
    JOIN public.impuesto im ON im.empresa_id = p_empresa_id AND im.codigo = d.codigo;

  RETURN jsonb_build_object('lineas', v_out,
    'subtotal_centavos', t_sub, 'descuento_centavos', t_sub - t_base, 'descuento_promocion_centavos', t_dpro,
    'descuento_manual_centavos', t_sub - t_base - t_dpro,
    'descuento_manual_porcentaje', CASE WHEN t_sin1 > 0 THEN round((t_sin1 - t_base) * 100.0 / t_sin1, 2) ELSE 0 END,
    'gravado_centavos', t_grav, 'exento_centavos', t_exe, 'exonerado_centavos', t_exo,
    'impuesto_centavos', t_imp, 'total_centavos', t_tot, 'desglose_impuestos', v_desg,
    'tiene_bienes', NOT (true = ALL (a_serv)),
    'descuento_factura_porcentaje', v_fpct, 'descuento_factura_monto_centavos', v_fmto);
END $$;

-- Registrar una venta (reemplaza la de 039; misma firma): anota el cliente para el cálculo y
-- guarda en cada línea qué precio se usó.
CREATE OR REPLACE FUNCTION interno.registrar_venta_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_cotizacion_id uuid DEFAULT NULL, p_calculo jsonb DEFAULT NULL,
                                             p_apartado_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e        public.empresa;
  v        public.venta;
  v_caja   public.caja;
  v_bod    public.bodega;
  v_cli    public.tercero;
  v_tdoc   text;
  v_fecha  date;
  v_calc   jsonb;
  v_total  bigint;
  pj       jsonb;
  v_forma  text;
  v_monto  bigint;
  v_rec    bigint;
  v_suma   bigint := 0;
  v_cred   bigint := 0;
  v_din    bigint := 0;
  v_ncred  integer := 0;
  v_nant   integer := 0;
  v_norm   jsonb := '[]';
  v_rol    text := public.mi_rol(p_empresa_id);
  v_vend   uuid;
  v_req    text[] := '{}';
  v_td     record;
  v_saldo  bigint;
  v_apr    uuid;
  v_desc   text := '';
  d        public.cuenta_dinero;
  k        integer := 0;
  v_vale   text;
  v_lote   uuid;
  v_sf     bigint;
  v_prev   text := coalesce(current_setting('app.cliente_venta', true), '');
BEGIN
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cliente_id', 'caja_id', 'bodega_id', 'fecha', 'tipo_documento', 'lineas',
                                               'descuento_factura', 'pagos', 'vendedor_id', 'nota', 'equipo']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;

  v_caja := interno.caja_de_venta(p_empresa_id, p_datos->'caja_id');
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  v_tdoc := interno.json_texto(p_datos->'tipo_documento', 'tipo_documento', 20);
  IF v_tdoc IS NOT NULL AND v_tdoc NOT IN ('factura', 'ticket') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el documento es "factura" o "ticket".';
  END IF;
  IF interno.regimen_fiscal(p_empresa_id) IS NULL THEN
    IF v_tdoc = 'factura' THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: la empresa no tiene un régimen fiscal activo; la venta sale con ticket interno.';
    END IF;
    v_tdoc := 'ticket';
  ELSE
    v_tdoc := coalesce(v_tdoc, CASE e.documento_venta_modo WHEN 'solo_ticket' THEN 'ticket' ELSE 'factura' END);
    IF v_tdoc = 'ticket' AND e.documento_venta_modo = 'solo_factura' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la empresa emite factura en todas sus ventas (el dueño puede permitir tickets internos en Ajustes).';
    END IF;
    IF v_tdoc = 'factura' AND e.documento_venta_modo = 'solo_ticket' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la empresa está configurada para emitir solo tickets internos.';
    END IF;
  END IF;

  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    SELECT * INTO v_cli FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_datos->'cliente_id', 'cliente_id') AND t.empresa_id = p_empresa_id;
    IF v_cli.id IS NULL OR NOT v_cli.es_cliente OR NOT v_cli.activo THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente no existe, no está marcado como cliente o está desactivado.';
    END IF;
  END IF;
  v_vend := coalesce(interno.json_uuid(p_datos->'vendedor_id', 'vendedor_id'), auth.uid());
  IF p_apartado_id IS NULL AND p_cotizacion_id IS NULL THEN
    -- 0.9.1: el vendedor ELEGIDO AHORA (a quien se le paga la comisión) es un usuario activo de
    -- ESTA empresa cuyo puesto vende (permiso ventas.vender).
    IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = v_vend
                     AND ue.activo AND ue.rol NOT IN ('proveedor', 'contador')
                     AND (v_vend = auth.uid()
                          OR EXISTS (SELECT 1 FROM public.rol_permiso rp WHERE rp.empresa_id = p_empresa_id AND rp.rol = ue.rol
                                       AND rp.permiso = 'ventas.vender'))) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el vendedor no es un usuario activo de la empresa con un puesto que vende (permiso "ventas.vender").';
    END IF;
  -- 0.9.2: al completar un apartado o convertir una cotización el vendedor se HEREDA del documento
  -- guardado (quien lo hizo) y se respeta aunque hoy esté dado de baja o su puesto solo cotice; la
  -- comisión sigue yendo a él (comisiones.md). Solo se exige que sea de esta empresa.
  ELSIF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = v_vend) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el vendedor del documento no es usuario de esta empresa.';
  END IF;

  -- 0.18.0: el cálculo sabe quién es el cliente (precio mayorista por cliente).
  PERFORM set_config('app.cliente_venta', coalesce(v_cli.id::text, ''), true);
  v_calc := coalesce(p_calculo, interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura'));
  PERFORM set_config('app.cliente_venta', v_prev, true);
  v_total := (v_calc->>'total_centavos')::bigint;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el total de la venta debe ser mayor que cero.';
  END IF;
  IF coalesce((v_calc->>'tiene_bienes')::boolean, true) AND NOT public.modulo_esta_activo(p_empresa_id, 'inventario') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo: esta venta solo puede llevar servicios (quite los productos que son bienes).';
  END IF;
  IF coalesce(p_datos->'bodega_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_bod := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  ELSIF coalesce((v_calc->>'tiene_bienes')::boolean, true) THEN
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa; cree una o indique "bodega_id".';
    END IF;
  END IF;

  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia, crédito o saldo a favor).';
  END IF;
  IF jsonb_array_length(p_datos->'pagos') > 10 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 10 formas de pago por venta.';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    k := k + 1;
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    PERFORM interno.exigir_claves(pj, ARRAY['forma', 'monto_centavos', 'cuenta_dinero_id', 'referencia', 'recibido_centavos',
                                            'vale', 'saldo_favor_id']);
    v_forma := interno.json_texto(pj->'forma', 'forma', 20);
    IF coalesce(v_forma, '') NOT IN ('efectivo', 'tarjeta', 'transferencia', 'credito', 'saldo_favor', 'anticipo') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago es efectivo, tarjeta, transferencia, credito o saldo_favor.';
    END IF;
    IF v_forma = 'anticipo' AND p_apartado_id IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma "anticipo" solo se usa al completar un apartado (completar_apartado).';
    END IF;
    IF coalesce(pj->'monto_centavos', 'null'::jsonb) = 'null'::jsonb THEN
      IF jsonb_array_length(p_datos->'pagos') > 1 THEN
        RAISE EXCEPTION 'PAGO_NO_CUADRA: con varias formas de pago cada una lleva su monto.';
      END IF;
      v_monto := v_total;
    ELSE
      v_monto := interno.json_centavos(pj->'monto_centavos', 'monto_centavos');
    END IF;
    IF v_monto = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada forma de pago lleva un monto mayor que cero.';
    END IF;
    v_rec := NULL;
    IF coalesce(pj->'recibido_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      IF v_forma <> 'efectivo' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "recibido_centavos" (para el vuelto) solo va en efectivo.';
      END IF;
      v_rec := interno.json_centavos(pj->'recibido_centavos', 'recibido_centavos');
      IF v_rec < v_monto THEN
        RAISE EXCEPTION 'DATO_INVALIDO: lo recibido (%) es menos que lo que se cobra en efectivo (%).', interno.lempiras(v_rec), interno.lempiras(v_monto);
      END IF;
    END IF;
    IF v_forma IN ('efectivo', 'credito', 'saldo_favor', 'anticipo') AND coalesce(pj->'cuenta_dinero_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: en % no se indica cuenta (el efectivo entra a la caja de la venta).', v_forma;
    END IF;
    IF v_forma <> 'saldo_favor' AND (pj ? 'vale' OR pj ? 'saldo_favor_id') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "vale" y "saldo_favor_id" solo van con la forma saldo_favor.';
    END IF;
    v_vale := NULL; v_lote := NULL;
    IF v_forma = 'saldo_favor' THEN
      v_vale := upper(interno.json_texto(pj->'vale', 'vale', 20));
      v_lote := interno.json_uuid(pj->'saldo_favor_id', 'saldo_favor_id');
      IF v_vale IS NOT NULL AND v_lote IS NOT NULL THEN
        RAISE EXCEPTION 'DATO_INVALIDO: indique "vale" o "saldo_favor_id", no los dos.';
      END IF;
      -- 0.9.1: "saldo_favor_id" NO se acepta desde la app: solo el cambio de producto (035) usa
      -- su propio lote. Y aun así el lote debe ser de esta empresa y de este mismo cliente.
      IF v_lote IS NOT NULL AND v_lote::text IS DISTINCT FROM nullif(current_setting('app.lote_cambio', true), '') THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "saldo_favor_id" no se acepta en una venta; pague con el saldo a favor del cliente (sin indicar lote) o con el código del vale ("vale").';
      END IF;
      IF v_lote IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.saldo_favor s WHERE s.id = v_lote AND s.empresa_id = p_empresa_id
                                              AND s.cliente_id IS NOT DISTINCT FROM v_cli.id) THEN
        RAISE EXCEPTION 'VALE_INVALIDO: ese saldo a favor no es de este cliente en esta empresa.';
      END IF;
      IF v_vale IS NULL AND v_lote IS NULL AND v_cli.id IS NULL THEN
        RAISE EXCEPTION 'CLIENTE_REQUERIDO: para pagar con saldo a favor indique el cliente o el código del vale ("vale").';
      END IF;
      -- Revisión previa (se consume al emitir, con el lote bloqueado).
      v_sf := CASE WHEN v_lote IS NOT NULL THEN interno.saldo_favor_lote(v_lote)
                   WHEN v_vale IS NOT NULL THEN (SELECT interno.saldo_favor_lote(s.id) FROM public.saldo_favor s
                                                  WHERE s.empresa_id = p_empresa_id AND s.codigo = v_vale)
                   ELSE interno.saldo_favor_cliente(p_empresa_id, v_cli.id) END;
      IF v_vale IS NOT NULL AND v_sf IS NULL THEN
        RAISE EXCEPTION 'VALE_INVALIDO: el vale % no existe.', v_vale;
      END IF;
      IF coalesce(v_sf, 0) < v_monto THEN
        RAISE EXCEPTION 'SALDO_FAVOR_INSUFICIENTE: el saldo a favor disponible es % y se quieren usar %.', interno.lempiras(coalesce(v_sf, 0)), interno.lempiras(v_monto);
      END IF;
    END IF;
    IF v_forma = 'credito' THEN
      v_ncred := v_ncred + 1;
      v_cred := v_cred + v_monto;
    ELSIF v_forma = 'anticipo' THEN
      v_nant := v_nant + 1;
      IF v_monto <> interno.anticipos_apartado(p_apartado_id) THEN
        RAISE EXCEPTION 'PAGO_NO_CUADRA: el anticipo (%) no es lo abonado al apartado (%).', interno.lempiras(v_monto),
          interno.lempiras(interno.anticipos_apartado(p_apartado_id));
      END IF;
    ELSIF v_forma IN ('efectivo', 'tarjeta', 'transferencia') THEN
      v_din := v_din + v_monto;
    END IF;
    v_suma := v_suma + v_monto;
    v_norm := v_norm || jsonb_build_object('linea', k, 'forma', v_forma, 'monto', v_monto, 'recibido', v_rec,
      'cuenta', interno.json_uuid(pj->'cuenta_dinero_id', 'cuenta_dinero_id'), 'referencia', interno.json_texto(pj->'referencia', 'referencia', 100),
      'vale', v_vale, 'saldo_favor_id', v_lote);
  END LOOP;
  IF v_ncred > 1 OR v_nant > 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el crédito (o el anticipo) va en una sola forma de pago.';
  END IF;
  IF v_suma <> v_total THEN
    RAISE EXCEPTION 'PAGO_NO_CUADRA: las formas de pago suman % y el total de la venta es % (diferencia %).',
      interno.lempiras(v_suma), interno.lempiras(v_total), interno.lempiras(v_suma - v_total);
  END IF;
  IF v_cred > 0 AND v_cli.id IS NULL THEN
    RAISE EXCEPTION 'CLIENTE_REQUERIDO: una venta al crédito necesita cliente (no puede ser Consumidor final).';
  END IF;
  IF v_suma > v_cred AND NOT interno.puede_cobrar(p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.cobrar"; haga una cotización y el cajero la cobra (o el dueño permite que el vendedor cobre).';
  END IF;
  IF v_din > 0 AND NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa (el cobro entra a una cuenta de dinero).';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'venta');
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;

  -- ¿Necesita aprobación? (el dueño no tiene topes; el descuento de un apartado ya se revisó al crearlo)
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    IF p_apartado_id IS NULL AND (v_calc->>'descuento_manual_porcentaje')::numeric > v_td.sin_aprobacion THEN
      v_req := v_req || 'descuento'::text;
      v_desc := 'descuento de ' || (v_calc->>'descuento_manual_porcentaje') || ' % (su tope: ' || v_td.sin_aprobacion || ' %)';
    -- 0.9.1: el tope también vale POR LÍNEA (100 % en una línea chica dentro de una factura grande).
    ELSIF p_apartado_id IS NULL AND interno.descuento_linea_sobre_tope(v_calc->'lineas', v_td.sin_aprobacion) IS NOT NULL THEN
      v_req := v_req || 'descuento'::text;
      v_desc := 'descuento de ' || interno.descuento_linea_sobre_tope(v_calc->'lineas', v_td.sin_aprobacion)
                || ' % en una línea (su tope: ' || v_td.sin_aprobacion || ' %)';
    END IF;
    IF v_cred > 0 THEN
      v_saldo := interno.saldo_cxc_cliente(p_empresa_id, v_cli.id);
      IF e.credito_politica = 'siempre_aprobacion' OR v_cli.limite_credito_centavos = 0
         OR v_saldo + v_cred > v_cli.limite_credito_centavos THEN
        v_req := v_req || 'credito'::text;
        v_desc := v_desc || CASE WHEN v_desc <> '' THEN '; ' ELSE '' END || 'crédito de ' || interno.lempiras(v_cred)
          || CASE WHEN e.credito_politica = 'siempre_aprobacion' THEN ' (todo crédito pide aprobación)'
                  WHEN v_cli.limite_credito_centavos = 0 THEN ' (cliente sin límite de crédito)'
                  ELSE ' (debe ' || interno.lempiras(v_saldo) || ', límite ' || interno.lempiras(v_cli.limite_credito_centavos) || ')' END;
      END IF;
    END IF;
  END IF;

  v.id := gen_random_uuid();
  v.numero := interno.siguiente_numero(p_empresa_id, 'venta');
  IF cardinality(v_req) > 0 THEN
    v_apr := gen_random_uuid();
    INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                   solicitado_por, rol_solicitante)
    VALUES (v_apr, p_empresa_id, interno.siguiente_numero(p_empresa_id, 'aprobacion'), 'venta', 'venta', v.id, v_total,
            'Venta #' || v.numero || ' a ' || coalesce(v_cli.nombre, 'Consumidor final') || ' por ' || interno.lempiras(v_total) || ': ' || v_desc,
            auth.uid(), v_rol);
  END IF;

  INSERT INTO public.venta (id, empresa_id, numero, sucursal_id, caja_id, bodega_id, fecha_contable, tipo_documento,
    emisor_nombre, emisor_rtn, cliente_id, cliente_nombre, cliente_rtn, vendedor_id, cotizacion_id,
    condicion, credito_centavos, plazo_dias,
    descuento_factura_porcentaje, descuento_factura_monto_centavos,
    subtotal_centavos, descuento_centavos, descuento_promocion_centavos, descuento_manual_centavos, descuento_manual_porcentaje,
    gravado_centavos, exento_centavos, exonerado_centavos, impuesto_centavos, desglose_impuestos, total_centavos,
    estado, requiere_aprobacion, aprobacion_id, nota, equipo, id_operacion, creado_por, apartado_id)
  VALUES (v.id, p_empresa_id, v.numero, v_caja.sucursal_id, v_caja.id, v_bod.id, v_fecha, v_tdoc,
    e.nombre, e.rtn, v_cli.id, coalesce(v_cli.nombre, 'Consumidor final'), v_cli.rtn, v_vend, p_cotizacion_id,
    CASE WHEN v_cred > 0 THEN 'credito' ELSE 'contado' END, v_cred, CASE WHEN v_cred > 0 THEN v_cli.plazo_dias END,
    (v_calc->>'descuento_factura_porcentaje')::numeric, (v_calc->>'descuento_factura_monto_centavos')::bigint,
    (v_calc->>'subtotal_centavos')::bigint, (v_calc->>'descuento_centavos')::bigint,
    (v_calc->>'descuento_promocion_centavos')::bigint, (v_calc->>'descuento_manual_centavos')::bigint,
    (v_calc->>'descuento_manual_porcentaje')::numeric,
    (v_calc->>'gravado_centavos')::bigint, (v_calc->>'exento_centavos')::bigint, (v_calc->>'exonerado_centavos')::bigint,
    (v_calc->>'impuesto_centavos')::bigint, v_calc->'desglose_impuestos', v_total,
    CASE WHEN cardinality(v_req) > 0 THEN 'pendiente_aprobacion' ELSE 'por_emitir' END, v_req, v_apr,
    interno.json_texto(p_datos->'nota', 'nota', 500), interno.equipo(p_datos), p_id_operacion, auth.uid(), p_apartado_id)
  RETURNING * INTO v;

  INSERT INTO public.venta_linea (empresa_id, venta_id, linea, producto_id, descripcion, cantidad, precio_unitario_centavos,
    precio_incluye_isv, tipo_impuesto, impuesto_porcentaje, impuesto_clase, es_servicio, costo_estimado_centavos,
    promocion_id, descuento_linea_porcentaje, descuento_linea_monto_centavos,
    bruto_centavos, descuento_promocion_precio_centavos, descuento_linea_centavos, descuento_factura_centavos, neto_centavos,
    subtotal_centavos, descuento_promocion_centavos, descuento_centavos, base_centavos, impuesto_centavos, total_centavos,
    precio_tipo, precio_normal_centavos)
  SELECT p_empresa_id, v.id, x.linea, x.producto_id, x.descripcion, x.cantidad, x.precio_unitario_centavos,
         x.precio_incluye_isv, x.tipo_impuesto, x.impuesto_porcentaje, x.impuesto_clase, x.es_servicio, x.costo_estimado_centavos,
         x.promocion_id, x.descuento_linea_porcentaje, x.descuento_linea_monto_centavos,
         x.bruto_centavos, x.descuento_promocion_precio_centavos, x.descuento_linea_centavos, x.descuento_factura_centavos,
         x.neto_centavos, x.subtotal_centavos, x.descuento_promocion_centavos, x.descuento_centavos, x.base_centavos,
         x.impuesto_centavos, x.total_centavos,
         coalesce(x.precio_tipo, 'normal'), x.precio_normal_centavos
    FROM jsonb_to_recordset(v_calc->'lineas') AS x(linea smallint, producto_id uuid, descripcion text, cantidad numeric,
         precio_unitario_centavos bigint, precio_incluye_isv boolean, tipo_impuesto text, impuesto_porcentaje numeric,
         impuesto_clase text, es_servicio boolean, costo_estimado_centavos bigint, promocion_id uuid,
         descuento_linea_porcentaje numeric, descuento_linea_monto_centavos bigint, bruto_centavos bigint,
         descuento_promocion_precio_centavos bigint, descuento_linea_centavos bigint, descuento_factura_centavos bigint,
         neto_centavos bigint, subtotal_centavos bigint, descuento_promocion_centavos bigint, descuento_centavos bigint,
         base_centavos bigint, impuesto_centavos bigint, total_centavos bigint, precio_tipo text, precio_normal_centavos bigint);

  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    d := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(p_empresa_id, v_caja.id);
    ELSIF pj->>'forma' IN ('tarjeta', 'transferencia') THEN
      d := interno.cuenta_cobro_venta(p_empresa_id, pj->>'forma', (pj->>'cuenta')::uuid);
    END IF;
    INSERT INTO public.venta_pago (empresa_id, venta_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos, estado_transferencia, vale, saldo_favor_id)
    VALUES (p_empresa_id, v.id, (pj->>'linea')::smallint, pj->>'forma', (pj->>'monto')::bigint, d.id,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta(d.id) END, pj->>'referencia',
            (pj->>'recibido')::bigint, (pj->>'recibido')::bigint - (pj->>'monto')::bigint,
            CASE WHEN pj->>'forma' = 'transferencia' THEN 'por_confirmar' END, pj->>'vale', (pj->>'saldo_favor_id')::uuid);
  END LOOP;

  IF v.estado = 'por_emitir' THEN
    v := interno.emitir_venta(v.id, v_fecha, p_id_operacion);
  END IF;
  RETURN interno.venta_respuesta(v, false);
END $$;

-- Quien calcula una venta fuera de registrar_venta anota el cliente (y lo deja como estaba).
-- crear_cotizacion y crear_apartado (029 / 038) pasan a interno sin cambios.
ALTER FUNCTION public.crear_cotizacion(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.crear_cotizacion(uuid, jsonb, uuid) RENAME TO crear_cotizacion_029;
ALTER FUNCTION public.crear_apartado(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.crear_apartado(uuid, jsonb, uuid) RENAME TO crear_apartado_038;
ALTER FUNCTION public.registrar_devolucion(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.registrar_devolucion(uuid, jsonb, uuid) RENAME TO registrar_devolucion_052;
ALTER FUNCTION public.calcular_cambio_previo(uuid, jsonb) SET SCHEMA interno;
ALTER FUNCTION interno.calcular_cambio_previo(uuid, jsonb) RENAME TO calcular_cambio_previo_052;

-- Texto del cliente de unos datos (sin validar: lo valida la función de siempre).
CREATE FUNCTION interno.cliente_en_datos(p_datos jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN jsonb_typeof(p_datos) = 'object' AND jsonb_typeof(p_datos->'cliente_id') = 'string'
              THEN p_datos->>'cliente_id' ELSE '' END
$$;

CREATE FUNCTION public.crear_cotizacion(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_prev text := coalesce(current_setting('app.cliente_venta', true), '');
  r      jsonb;
BEGIN
  PERFORM set_config('app.cliente_venta', interno.cliente_en_datos(p_datos), true);
  r := interno.crear_cotizacion_029(p_empresa_id, p_datos, p_id_operacion);
  PERFORM set_config('app.cliente_venta', v_prev, true);
  RETURN r;
END $$;

CREATE FUNCTION public.crear_apartado(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_prev text := coalesce(current_setting('app.cliente_venta', true), '');
  r      jsonb;
BEGIN
  PERFORM set_config('app.cliente_venta', interno.cliente_en_datos(p_datos), true);
  r := interno.crear_apartado_038(p_empresa_id, p_datos, p_id_operacion);
  PERFORM set_config('app.cliente_venta', v_prev, true);
  RETURN r;
END $$;

-- Un cambio de producto se calcula con el cliente de la venta original.
CREATE FUNCTION public.registrar_devolucion(p_venta_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_prev text := coalesce(current_setting('app.cliente_venta', true), '');
  r      jsonb;
BEGIN
  PERFORM set_config('app.cliente_venta', coalesce((SELECT v.cliente_id::text FROM public.venta v WHERE v.id = p_venta_id), ''), true);
  r := interno.registrar_devolucion_052(p_venta_id, p_datos, p_id_operacion);
  PERFORM set_config('app.cliente_venta', v_prev, true);
  RETURN r;
END $$;

CREATE FUNCTION public.calcular_cambio_previo(p_venta_id uuid, p_datos jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_prev text := coalesce(current_setting('app.cliente_venta', true), '');
  r      jsonb;
BEGIN
  PERFORM set_config('app.cliente_venta', coalesce((SELECT v.cliente_id::text FROM public.venta v WHERE v.id = p_venta_id), ''), true);
  r := interno.calcular_cambio_previo_052(p_venta_id, p_datos);
  PERFORM set_config('app.cliente_venta', v_prev, true);
  RETURN r;
END $$;

-- Venta previa (reemplaza la de 050; misma firma y respuesta, con lo nuevo):
--   datos: además "cliente_id" (opcional: con un cliente mayorista, sus líneas salen con el mayorista).
--   Cada línea: además "precio_tipo" (normal | mayorista), "precio_normal_centavos" y
--   "precio_mayorista_disponible" (para el chip "Mayorista" y el botón para elegir).
--   Varias promociones sin elegir: la previa sugiere la que más descuenta, salvo que el mayorista
--   gane (entonces la línea sale con el mayorista y sin sugerencia).
CREATE OR REPLACE FUNCTION public.calcular_venta_previa(p_empresa_id uuid, p_datos jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_fecha   date;
  v_lineas  jsonb := '[]';
  v_promos  jsonb := '[]';
  l         jsonb;
  i         integer := 0;
  p         public.producto;
  imp       public.impuesto;
  q         numeric;
  pr        jsonb;
  m         record;
  v_sug     jsonb := '[]';
  v_calc    jsonb;
  v_out     jsonb := '[]';
  v_rol     text := public.mi_rol(p_empresa_id);
  v_td      record;
  v_tope    numeric;
  v_pide    boolean := false;
  v_costos  boolean := public.tiene_permiso('inventario.costos', p_empresa_id);
  v_prev    text := coalesce(current_setting('app.cliente_venta', true), '');
  v_cli     public.tercero;
  v_may     boolean;
  v_gana    boolean;
  v_con     bigint;
  v_sub     bigint := 0;
BEGIN
  IF public.tiene_permiso('ventas.cotizar', p_empresa_id) THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.cotizar');
  ELSE
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.vender');
  END IF;
  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: faltan los datos de la venta.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['lineas', 'descuento_factura', 'fecha', 'cliente_id']);
  IF jsonb_typeof(p_datos->'lineas') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'lineas') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la venta necesita al menos una línea.';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_cli := interno.cliente_de(p_empresa_id, p_datos->'cliente_id');
  END IF;
  PERFORM set_config('app.cliente_venta', coalesce(v_cli.id::text, ''), true);
  v_may := interno.cliente_venta_mayorista(p_empresa_id);

  FOR l IN SELECT * FROM jsonb_array_elements(p_datos->'lineas') LOOP
    i := i + 1;
    IF jsonb_typeof(l) <> 'object' THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % no es válida.', i;
    END IF;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, true);
    q := interno.json_numero(l->'cantidad', 'cantidad', i);
    IF q IS NULL OR q <= 0 THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la cantidad de la línea % debe ser mayor que cero.', i;
    END IF;
    pr := interno.promociones_de(p_empresa_id, p, v_fecha, q);
    v_promos := v_promos || jsonb_build_array(pr);
    IF coalesce(l->'promocion_id', 'null'::jsonb) = 'null'::jsonb AND jsonb_array_length(pr) > 1
       AND coalesce(l->>'precio_tipo', '') <> 'mayorista' THEN
      -- ¿Gana el mayorista? (solo si la línea no trae descuento manual ni pide el precio normal)
      imp := interno.impuesto_de(p_empresa_id, p.tipo_impuesto);
      SELECT * INTO m FROM interno.mayorista_de(p, imp.porcentaje, q, v_may);
      v_gana := m.o_aplica AND coalesce(l->>'precio_tipo', '') <> 'normal'
        AND coalesce(l->'descuento_porcentaje', 'null'::jsonb) = 'null'::jsonb AND coalesce(l->'descuento_centavos', 'null'::jsonb) = 'null'::jsonb
        AND (public.precio_con_tasa(round(q * m.o_precio)::bigint, m.o_incluye, imp.porcentaje, 1)).con_isv_centavos
            <= (public.precio_con_tasa(round(q * p.precio_venta_centavos)::bigint - (pr->0->>'descuento_centavos')::bigint,
                                       p.precio_incluye_isv, imp.porcentaje, 1)).con_isv_centavos;
      IF v_gana THEN
        v_sug := v_sug || jsonb_build_array(NULL::jsonb);
      ELSE
        l := l || jsonb_build_object('promocion_id', pr->0->'promocion_id');
        v_sug := v_sug || jsonb_build_array(pr->0->'promocion_id');
      END IF;
    ELSE
      v_sug := v_sug || jsonb_build_array(NULL::jsonb);
    END IF;
    v_lineas := v_lineas || jsonb_build_array(l);
  END LOOP;

  v_calc := interno.calcular_venta(p_empresa_id, v_fecha, v_lineas, p_datos->'descuento_factura');
  PERFORM set_config('app.cliente_venta', v_prev, true);

  -- Tope del puesto (la misma regla que registrar_venta; el dueño no tiene).
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    v_tope := v_td.sin_aprobacion;
    v_pide := (v_calc->>'descuento_manual_porcentaje')::numeric > v_tope
              OR interno.descuento_linea_sobre_tope(v_calc->'lineas', v_tope) IS NOT NULL;
  END IF;

  FOR i IN 0 .. jsonb_array_length(v_calc->'lineas') - 1 LOOP
    l := (v_calc->'lineas'->i) || jsonb_build_object('promociones', v_promos->i, 'promocion_sugerida_id', v_sug->i);
    IF NOT v_costos THEN
      l := l - 'costo_estimado_centavos';
    END IF;
    -- Precio x cantidad con ISV, por línea y redondeado como la venta (lo de 050).
    v_con := (public.precio_con_tasa((l->>'precio_unitario_centavos')::bigint, (l->>'precio_incluye_isv')::boolean,
              coalesce((l->>'impuesto_porcentaje')::numeric, 0), (l->>'cantidad')::numeric)).con_isv_centavos;
    v_sub := v_sub + v_con;
    v_out := v_out || jsonb_build_array(l || jsonb_build_object('bruto_con_isv_centavos', v_con,
               'descuento_con_isv_centavos', v_con - (l->>'total_centavos')::bigint));
  END LOOP;

  RETURN (v_calc - 'lineas') || jsonb_build_object('lineas', v_out, 'fecha', to_char(v_fecha, 'YYYY-MM-DD'),
    'tope_descuento_porcentaje', v_tope, 'descuento_pide_aprobacion', v_pide,
    'subtotal_con_isv_centavos', v_sub, 'descuento_con_isv_centavos', v_sub - (v_calc->>'total_centavos')::bigint,
    'cliente_mayorista', coalesce(v_may, false));
END $$;

-- Comprobante (documento_venta de 029 pasa a interno sin cambios): cada línea dice además
-- "precio_tipo" y, con mayorista, "precio_normal_centavos" (el comprobante lo dice en texto).
ALTER FUNCTION public.documento_venta(uuid) SET SCHEMA interno;
ALTER FUNCTION interno.documento_venta(uuid) RENAME TO documento_venta_029;
CREATE FUNCTION public.documento_venta(p_venta_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb := interno.documento_venta_029(p_venta_id);
BEGIN
  RETURN r || jsonb_build_object('lineas', (SELECT coalesce(jsonb_agg(x.l || jsonb_strip_nulls(jsonb_build_object(
        'precio_tipo', vl.precio_tipo,
        'precio_normal_centavos', vl.precio_normal_centavos,
        'precio_texto', CASE WHEN vl.precio_tipo = 'mayorista' THEN 'Precio mayorista' END)) ORDER BY x.n), '[]')
      FROM jsonb_array_elements(r->'lineas') WITH ORDINALITY AS x(l, n)
      LEFT JOIN public.venta_linea vl ON vl.venta_id = p_venta_id AND vl.linea = (x.l->>'linea')::smallint));
END $$;

-- v_producto (reemplaza la de 053: mismas columnas y al final el precio mayorista).
CREATE OR REPLACE VIEW public.v_producto WITH (security_invoker = true) AS
  SELECT p.empresa_id, p.id AS producto_id, p.codigo, p.codigo_barras, p.nombre,
         p.categoria_id, c.nombre AS categoria, p.unidad_id, u.codigo AS unidad,
         p.tipo_impuesto, p.precio_venta_centavos, p.precio_incluye_isv,
         x.sin_isv_centavos AS precio_sin_isv_centavos, x.isv_centavos, x.con_isv_centavos AS precio_con_isv_centavos,
         p.stock_minimo, p.permite_fracciones, p.activo, p.campos_extra, p.actualizado_en,
         p.tipo, i.nombre AS impuesto, i.porcentaje AS impuesto_porcentaje, i.clase AS impuesto_clase,
         sc.costo_estimado_centavos,
         p.foto_ruta, p.foto_miniatura_ruta,
         p.precio_mayorista_centavos, p.cantidad_mayorista,
         CASE WHEN p.precio_mayorista_centavos IS NOT NULL
              THEN (public.precio_con_tasa(p.precio_mayorista_centavos, p.precio_incluye_isv, i.porcentaje)).con_isv_centavos END
           AS precio_mayorista_con_isv_centavos
  FROM public.producto p
  JOIN public.unidad u ON u.id = p.unidad_id
  JOIN public.impuesto i ON i.empresa_id = p.empresa_id AND i.codigo = p.tipo_impuesto
  LEFT JOIN public.categoria_producto c ON c.id = p.categoria_id
  LEFT JOIN public.servicio_costo sc ON sc.producto_id = p.id      -- sin inventario.costos: vacío (RLS)
  CROSS JOIN LATERAL public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, i.porcentaje) x;

-- ---------------------------------------------------------------------
-- Excel (046/048): columnas nuevas. Productos: "Precio mayorista (L)" y "Desde cantidad";
-- Clientes y proveedores: "Mayorista". Las funciones de antes pasan a interno sin cambios y las
-- nuevas agregan solo lo suyo (celda vacía = se conserva, como siempre; se quita en la app).
-- ---------------------------------------------------------------------
ALTER FUNCTION interno.excel_columnas(uuid, text, boolean) RENAME TO excel_columnas_046;
ALTER FUNCTION interno.excel_fila_productos(uuid, jsonb, text, uuid) RENAME TO excel_fila_productos_046;
ALTER FUNCTION interno.excel_fila_terceros(uuid, jsonb, text, uuid) RENAME TO excel_fila_terceros_046;
ALTER FUNCTION public.exportar_plantilla(uuid, text) SET SCHEMA interno;
ALTER FUNCTION interno.exportar_plantilla(uuid, text) RENAME TO exportar_plantilla_048;

-- Columnas nuevas de cada hoja, con la clave de la columna DESPUÉS de la cual van.
CREATE FUNCTION interno.excel_columnas_054(p_hoja text) RETURNS TABLE (despues text, col jsonb)
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT x.despues, x.col FROM (VALUES
    ('productos', 'precio_incluye_isv', 1, interno.excel_col('precio_mayorista', 'Precio mayorista (L)', true, 'monto',
       'Precio para clientes mayoristas o desde cierta cantidad, igual que el precio de venta (con o sin ISV). No puede ser mayor que el precio de venta.')),
    ('productos', 'precio_incluye_isv', 2, interno.excel_col('desde_cantidad', 'Desde cantidad', true, 'cantidad',
       'Desde cuántas unidades se usa el precio mayorista (vacío = solo para clientes mayoristas).')),
    ('clientes_proveedores', 'plazo_dias', 1, interno.excel_col('mayorista', 'Mayorista', true, 'si_no',
       'Sí = cliente mayorista: paga el precio mayorista de los productos que lo tienen.', '["Sí", "No"]'::jsonb))
  ) AS x(hoja, despues, orden, col)
  WHERE x.hoja = p_hoja ORDER BY x.orden
$$;

CREATE FUNCTION interno.excel_columnas(p_empresa_id uuid, p_hoja text, p_todas boolean) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c   jsonb := interno.excel_columnas_046(p_empresa_id, p_hoja, p_todas);
  r   jsonb := '[]';
  x   jsonb;
BEGIN
  IF c IS NULL THEN
    RETURN c;
  END IF;
  FOR x IN SELECT y FROM jsonb_array_elements(c) y LOOP
    r := r || jsonb_build_array(x);
    r := r || coalesce((SELECT jsonb_agg(n.col) FROM interno.excel_columnas_054(p_hoja) n WHERE n.despues = x->>'clave'), '[]');
  END LOOP;
  RETURN r;
END $$;

CREATE FUNCTION interno.excel_fila_productos(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      jsonb := interno.excel_fila_productos_046(p_empresa_id, c - 'precio_mayorista' - 'desde_cantidad', p_motivo, p_id);
  p      public.producto;
  v_dat  jsonb := '{}';
  v_camb jsonb := '[]';
BEGIN
  IF NOT (c ? 'precio_mayorista' OR c ? 'desde_cantidad') THEN
    RETURN r;
  END IF;
  SELECT * INTO p FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.codigo = c->>'codigo';
  IF c ? 'precio_mayorista' AND (c->>'precio_mayorista')::bigint IS DISTINCT FROM p.precio_mayorista_centavos THEN
    IF (c->>'precio_mayorista')::bigint = 0 THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Precio mayorista (L)|debe ser mayor que cero (para quitarlo, hágalo en la ficha del producto).';
    END IF;
    IF (c->>'precio_mayorista')::bigint > p.precio_venta_centavos THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Precio mayorista (L)|no puede ser mayor que el precio de venta (%).', interno.lempiras(p.precio_venta_centavos);
    END IF;
    v_dat := v_dat || jsonb_build_object('precio_mayorista_centavos', (c->>'precio_mayorista')::bigint);
    v_camb := v_camb || '["precio_mayorista"]';
  END IF;
  IF c ? 'desde_cantidad' AND (c->>'desde_cantidad')::numeric IS DISTINCT FROM p.cantidad_mayorista THEN
    IF (c->>'desde_cantidad')::numeric = 0 THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Desde cantidad|debe ser mayor que cero.';
    END IF;
    IF p.precio_mayorista_centavos IS NULL AND NOT v_dat ? 'precio_mayorista_centavos' THEN
      RAISE EXCEPTION 'EXCEL_CELDA: Desde cantidad|escriba también el precio mayorista.';
    END IF;
    v_dat := v_dat || jsonb_build_object('cantidad_mayorista', (c->>'desde_cantidad')::numeric);
    v_camb := v_camb || '["desde_cantidad"]';
  END IF;
  IF v_dat = '{}' THEN
    RETURN r;
  END IF;
  PERFORM interno.aplicar_producto_054(p_empresa_id, p.id, v_dat, p_motivo, r->>'accion' = 'crear');
  RETURN r || jsonb_build_object('accion', CASE WHEN r->>'accion' = 'sin_cambios' THEN 'actualizar' ELSE r->>'accion' END,
                                 'cambios', coalesce(r->'cambios', '[]') || v_camb);
END $$;

CREATE FUNCTION interno.excel_fila_terceros(p_empresa_id uuid, c jsonb, p_motivo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r     jsonb := interno.excel_fila_terceros_046(p_empresa_id, c - 'mayorista', p_motivo, p_id);
  t     public.tercero;
BEGIN
  IF NOT c ? 'mayorista' THEN
    RETURN r;
  END IF;
  SELECT * INTO t FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.codigo = r->>'llave';
  IF t.id IS NULL OR (c->'mayorista')::boolean = t.es_mayorista THEN
    RETURN r;
  END IF;
  PERFORM interno.poner_mayorista(p_empresa_id, t.id, c->'mayorista', p_motivo);
  RETURN r || jsonb_build_object('accion', CASE WHEN r->>'accion' = 'sin_cambios' THEN 'actualizar' ELSE r->>'accion' END,
                                 'cambios', coalesce(r->'cambios', '[]') || '["mayorista"]');
END $$;

CREATE FUNCTION public.exportar_plantilla(p_empresa_id uuid, p_hoja text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb := interno.exportar_plantilla_048(p_empresa_id, p_hoja);
BEGIN
  IF p_hoja = 'productos' THEN
    r := jsonb_set(r, '{filas}', (SELECT coalesce(jsonb_agg(f.x || jsonb_build_object(
           'precio_mayorista', interno.excel_lps(p.precio_mayorista_centavos),
           'desde_cantidad', trim_scale(p.cantidad_mayorista)) ORDER BY f.n), '[]')
      FROM jsonb_array_elements(r->'filas') WITH ORDINALITY AS f(x, n)
      LEFT JOIN public.producto p ON p.empresa_id = p_empresa_id AND p.codigo = f.x->>'codigo'));
  ELSIF p_hoja = 'clientes_proveedores' THEN
    r := jsonb_set(r, '{filas}', (SELECT coalesce(jsonb_agg(f.x || CASE WHEN t.es_cliente
             THEN jsonb_build_object('mayorista', interno.excel_si_no(t.es_mayorista)) ELSE '{}'::jsonb END ORDER BY f.n), '[]')
      FROM jsonb_array_elements(r->'filas') WITH ORDINALITY AS f(x, n)
      LEFT JOIN public.tercero t ON t.empresa_id = p_empresa_id AND t.codigo = f.x->>'codigo'));
  END IF;
  RETURN r;
END $$;

-- Seguridad de la parte 1: lo que pasó a interno ya no lo llama la app; lo público, solo authenticated.
REVOKE EXECUTE ON FUNCTION
  interno.crear_producto_026(uuid, jsonb, uuid), interno.editar_producto_026(uuid, uuid, jsonb, text),
  interno.cambiar_precio_producto_014(uuid, uuid, bigint, text), interno.editar_tercero_013(uuid, uuid, jsonb, text),
  interno.crear_cotizacion_029(uuid, jsonb, uuid), interno.crear_apartado_038(uuid, jsonb, uuid),
  interno.registrar_devolucion_052(uuid, jsonb, uuid), interno.calcular_cambio_previo_052(uuid, jsonb),
  interno.documento_venta_029(uuid), interno.exportar_plantilla_048(uuid, text),
  interno.revisar_precio_mayorista(), interno.cliente_venta_mayorista(uuid),
  interno.mayorista_de(public.producto, numeric, numeric, boolean), interno.avisos_precio_costo(uuid),
  interno.datos_mayorista(jsonb), interno.claves_producto_054(), interno.aplicar_producto_054(uuid, uuid, jsonb, text, boolean),
  interno.poner_mayorista(uuid, uuid, jsonb, text), interno.cliente_en_datos(jsonb),
  interno.excel_columnas_054(text), interno.excel_columnas_046(uuid, text, boolean), interno.excel_columnas(uuid, text, boolean),
  interno.excel_fila_productos_046(uuid, jsonb, text, uuid), interno.excel_fila_productos(uuid, jsonb, text, uuid),
  interno.excel_fila_terceros_046(uuid, jsonb, text, uuid), interno.excel_fila_terceros(uuid, jsonb, text, uuid)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.crear_producto(uuid, jsonb, uuid), public.editar_producto(uuid, uuid, jsonb, text),
  public.cambiar_precio_producto(uuid, uuid, bigint, text), public.crear_tercero(uuid, jsonb, uuid),
  public.editar_tercero(uuid, uuid, jsonb, text), public.crear_cotizacion(uuid, jsonb, uuid),
  public.crear_apartado(uuid, jsonb, uuid), public.registrar_devolucion(uuid, jsonb, uuid),
  public.calcular_cambio_previo(uuid, jsonb), public.calcular_venta_previa(uuid, jsonb),
  public.documento_venta(uuid), public.exportar_plantilla(uuid, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_producto(uuid, jsonb, uuid), public.editar_producto(uuid, uuid, jsonb, text),
  public.cambiar_precio_producto(uuid, uuid, bigint, text), public.crear_tercero(uuid, jsonb, uuid),
  public.editar_tercero(uuid, uuid, jsonb, text), public.crear_cotizacion(uuid, jsonb, uuid),
  public.crear_apartado(uuid, jsonb, uuid), public.registrar_devolucion(uuid, jsonb, uuid),
  public.calcular_cambio_previo(uuid, jsonb), public.calcular_venta_previa(uuid, jsonb),
  public.exportar_plantilla(uuid, text)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.documento_venta(uuid) TO authenticated, service_role;

-- =====================================================================
-- 2) GARANTÍAS (nucleo/docs/garantias.md)
--    producto.dias_garantia; cada línea vendida guarda sus días y, al emitirse la venta, su
--    fecha de vencimiento (fecha de la venta + días). Reclamos sobre una línea vigente con
--    estado (recibido -> en_revision -> resuelto | rechazado), historial y bitácora. Se
--    resuelven: reparado (sin dinero; costo de reparación opcional como gasto), cambiado o
--    devuelto (con la devolución / cambio de siempre, ligada al reclamo).
-- =====================================================================
INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('GARANTIA_VENCIDA', 'La garantía de ese producto ya venció.',
   'Un reclamo fuera de plazo solo entra si alguien con permiso de resolver garantías lo autoriza con motivo.'),
  ('GARANTIA_INVALIDA', 'Ese reclamo de garantía no se puede registrar o resolver así.',
   'Revise que la línea tenga garantía, la cantidad y el estado del reclamo.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('garantias.registrar', 'Buscar garantías y registrar reclamos de garantía', true, false),
  ('garantias.resolver', 'Resolver o rechazar reclamos de garantía y autorizar los que están fuera de plazo', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'garantias.registrar'), ('admin', 'garantias.registrar'), ('cajero', 'garantias.registrar'), ('vendedor', 'garantias.registrar'),
  ('dueno', 'garantias.resolver'), ('admin', 'garantias.resolver');
SELECT interno.repartir_permisos(ARRAY['garantias.registrar', 'garantias.resolver'], 'Núcleo 0.18.0: garantías');

ALTER TABLE public.producto ADD COLUMN dias_garantia integer CHECK (dias_garantia BETWEEN 1 AND 3650);
ALTER TABLE public.venta_linea
  ADD COLUMN garantia_dias  integer CHECK (garantia_dias BETWEEN 1 AND 3650),
  ADD COLUMN garantia_hasta date;

-- Las claves nuevas del producto ahora incluyen "dias_garantia" (productos.editar; null la quita).
CREATE OR REPLACE FUNCTION interno.claves_producto_054() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['precio_mayorista_centavos', 'cantidad_mayorista', 'dias_garantia']
$$;

CREATE OR REPLACE FUNCTION interno.aplicar_producto_054(p_empresa_id uuid, p_producto_id uuid, p_datos jsonb, p_motivo text,
                                                        p_nuevo boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p   public.producto;
  m   record;
  v_p bigint;
  v_c numeric;
  v_g integer;
BEGIN
  IF NOT (p_datos ?| interno.claves_producto_054()) THEN
    RETURN;
  END IF;
  SELECT * INTO p FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id FOR UPDATE;
  SELECT * INTO m FROM interno.datos_mayorista(p_datos);
  v_p := CASE WHEN m.o_hay THEN m.o_precio ELSE p.precio_mayorista_centavos END;
  v_c := CASE WHEN m.o_hay_cantidad THEN m.o_cantidad WHEN m.o_hay AND m.o_precio IS NULL THEN NULL ELSE p.cantidad_mayorista END;
  v_g := p.dias_garantia;
  IF p_datos ? 'dias_garantia' THEN
    IF p_datos->'dias_garantia' = 'null'::jsonb THEN
      v_g := NULL;
    ELSIF jsonb_typeof(p_datos->'dias_garantia') <> 'number' OR (p_datos->>'dias_garantia') !~ '^[0-9]{1,4}$'
          OR (p_datos->>'dias_garantia')::integer NOT BETWEEN 1 AND 3650 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: los días de garantía son un número entero de 1 a 3650 (o null para quitarla).';
    ELSE
      v_g := (p_datos->>'dias_garantia')::integer;
    END IF;
  END IF;
  IF (v_p, v_c) IS DISTINCT FROM (p.precio_mayorista_centavos, p.cantidad_mayorista) AND NOT p_nuevo THEN
    IF NOT public.tiene_permiso('productos.precios', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: cambiar el precio mayorista pide el permiso "productos.precios".';
    END IF;
    IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué cambia el precio mayorista (mínimo 5 letras); queda en la bitácora.';
    END IF;
  END IF;
  IF (v_p, v_c, v_g) IS NOT DISTINCT FROM (p.precio_mayorista_centavos, p.cantidad_mayorista, p.dias_garantia) THEN
    RETURN;
  END IF;
  PERFORM set_config('app.motivo', coalesce(nullif(trim(p_motivo), ''), CASE WHEN p_nuevo THEN 'Producto nuevo' END, ''), true);
  UPDATE public.producto SET precio_mayorista_centavos = v_p, cantidad_mayorista = v_c, dias_garantia = v_g WHERE id = p.id;
  PERFORM set_config('app.motivo', '', true);
END $$;

-- Al guardar una línea vendida: los días de garantía del producto en ese momento.
CREATE FUNCTION interno.garantia_de_linea() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.garantia_dias IS NULL THEN
    SELECT p.dias_garantia INTO NEW.garantia_dias FROM public.producto p WHERE p.id = NEW.producto_id;
  END IF;
  NEW.garantia_hasta := NULL;   -- se fija al emitir (la fecha de la venta puede cambiar si espera aprobación)
  RETURN NEW;
END $$;
CREATE TRIGGER garantia BEFORE INSERT ON public.venta_linea FOR EACH ROW EXECUTE FUNCTION interno.garantia_de_linea();

-- Al emitirse la venta: garantía hasta = fecha de la venta + días.
CREATE FUNCTION interno.fijar_garantia_venta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.venta_linea SET garantia_hasta = NEW.fecha_contable + garantia_dias
   WHERE venta_id = NEW.id AND garantia_dias IS NOT NULL AND garantia_hasta IS NULL;
  RETURN NEW;
END $$;
CREATE TRIGGER garantia AFTER UPDATE OF estado ON public.venta FOR EACH ROW
  WHEN (NEW.estado = 'emitida' AND OLD.estado IS DISTINCT FROM 'emitida')
  EXECUTE FUNCTION interno.fijar_garantia_venta();

-- Las líneas no se editan (reemplaza la de 028): además del costo al emitir, se deja poner UNA vez
-- la fecha de la garantía (nada más cambia).
CREATE OR REPLACE FUNCTION interno.proteger_venta_linea() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.costo_centavos IS NULL AND NEW.costo_centavos IS NOT NULL
     AND (to_jsonb(NEW) - 'costo_centavos' - 'movimiento_id') = (to_jsonb(OLD) - 'costo_centavos' - 'movimiento_id') THEN
    RETURN NEW;
  END IF;
  IF OLD.garantia_hasta IS NULL AND NEW.garantia_hasta IS NOT NULL AND NEW.garantia_dias IS NOT NULL
     AND (to_jsonb(NEW) - 'garantia_hasta') = (to_jsonb(OLD) - 'garantia_hasta') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: las líneas de una venta no se editan.';
END $$;

-- Comprobante: además "garantia_hasta" (dd/mm/aaaa) en las líneas con garantía.
CREATE OR REPLACE FUNCTION public.documento_venta(p_venta_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb := interno.documento_venta_029(p_venta_id);
BEGIN
  RETURN r || jsonb_build_object('lineas', (SELECT coalesce(jsonb_agg(x.l || jsonb_strip_nulls(jsonb_build_object(
        'precio_tipo', vl.precio_tipo,
        'precio_normal_centavos', vl.precio_normal_centavos,
        'precio_texto', CASE WHEN vl.precio_tipo = 'mayorista' THEN 'Precio mayorista' END,
        'garantia_hasta', to_char(vl.garantia_hasta, 'DD/MM/YYYY'),
        'garantia_texto', CASE WHEN vl.garantia_hasta IS NOT NULL THEN 'Garantía hasta ' || to_char(vl.garantia_hasta, 'DD/MM/YYYY') END))
        ORDER BY x.n), '[]')
      FROM jsonb_array_elements(r->'lineas') WITH ORDINALITY AS x(l, n)
      LEFT JOIN public.venta_linea vl ON vl.venta_id = p_venta_id AND vl.linea = (x.l->>'linea')::smallint));
END $$;

-- v_producto: además los días de garantía al final.
CREATE OR REPLACE VIEW public.v_producto WITH (security_invoker = true) AS
  SELECT p.empresa_id, p.id AS producto_id, p.codigo, p.codigo_barras, p.nombre,
         p.categoria_id, c.nombre AS categoria, p.unidad_id, u.codigo AS unidad,
         p.tipo_impuesto, p.precio_venta_centavos, p.precio_incluye_isv,
         x.sin_isv_centavos AS precio_sin_isv_centavos, x.isv_centavos, x.con_isv_centavos AS precio_con_isv_centavos,
         p.stock_minimo, p.permite_fracciones, p.activo, p.campos_extra, p.actualizado_en,
         p.tipo, i.nombre AS impuesto, i.porcentaje AS impuesto_porcentaje, i.clase AS impuesto_clase,
         sc.costo_estimado_centavos,
         p.foto_ruta, p.foto_miniatura_ruta,
         p.precio_mayorista_centavos, p.cantidad_mayorista,
         CASE WHEN p.precio_mayorista_centavos IS NOT NULL
              THEN (public.precio_con_tasa(p.precio_mayorista_centavos, p.precio_incluye_isv, i.porcentaje)).con_isv_centavos END
           AS precio_mayorista_con_isv_centavos,
         p.dias_garantia
  FROM public.producto p
  JOIN public.unidad u ON u.id = p.unidad_id
  JOIN public.impuesto i ON i.empresa_id = p.empresa_id AND i.codigo = p.tipo_impuesto
  LEFT JOIN public.categoria_producto c ON c.id = p.categoria_id
  LEFT JOIN public.servicio_costo sc ON sc.producto_id = p.id      -- sin inventario.costos: vacío (RLS)
  CROSS JOIN LATERAL public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, i.porcentaje) x;

-- Reclamos de garantía.
CREATE TABLE public.garantia_reclamo (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                uuid NOT NULL REFERENCES public.empresa(id),
  numero                    bigint NOT NULL,
  venta_id                  uuid NOT NULL,
  venta_linea_id            bigint NOT NULL REFERENCES public.venta_linea(id),
  numero_documento          text,
  fecha_venta               date NOT NULL,
  linea                     smallint NOT NULL,
  producto_id               uuid NOT NULL,
  descripcion_producto      text NOT NULL,
  cliente_id                uuid,
  cliente_nombre            text NOT NULL,
  sucursal_id               uuid NOT NULL,
  cantidad                  numeric(18,4) NOT NULL CHECK (cantidad > 0),
  garantia_hasta            date NOT NULL,
  fecha                     date NOT NULL,
  motivo                    text NOT NULL CHECK (length(trim(motivo)) BETWEEN 3 AND 200),
  descripcion               text CHECK (length(descripcion) <= 1000),
  estado                    text NOT NULL DEFAULT 'recibido' CHECK (estado IN ('recibido', 'en_revision', 'resuelto', 'rechazado')),
  fuera_de_plazo            boolean NOT NULL DEFAULT false,
  autorizado_por            uuid,
  autorizacion_motivo       text,
  resolucion                text CHECK (resolucion IN ('reparado', 'cambiado', 'devuelto')),
  resolucion_nota           text,
  devolucion_id             uuid,
  gasto_id                  uuid,
  costo_reparacion_centavos bigint CHECK (costo_reparacion_centavos BETWEEN 1 AND 9007199254740991),
  rechazo_motivo            text,
  resuelto_por              uuid,
  resuelto_en               timestamptz,
  resolucion_id_operacion   uuid,
  id_operacion              uuid NOT NULL,
  creado_por                uuid,
  creado_en                 timestamptz NOT NULL DEFAULT now(),
  actualizado_en            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  UNIQUE (empresa_id, resolucion_id_operacion),
  FOREIGN KEY (empresa_id, venta_id) REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id),
  CHECK (NOT fuera_de_plazo OR (autorizado_por IS NOT NULL AND length(trim(autorizacion_motivo)) >= 5)),
  CHECK ((estado = 'resuelto') = (resolucion IS NOT NULL)),
  CHECK (estado <> 'rechazado' OR length(trim(rechazo_motivo)) >= 5),
  CHECK (resolucion IS DISTINCT FROM 'reparado' OR devolucion_id IS NULL),
  CHECK (resolucion NOT IN ('cambiado', 'devuelto') OR devolucion_id IS NOT NULL)
);
CREATE INDEX garantia_reclamo_venta ON public.garantia_reclamo (venta_id);
CREATE INDEX garantia_reclamo_estado ON public.garantia_reclamo (empresa_id, estado);

-- Historial: cada cambio de estado (solo agregar).
CREATE TABLE public.garantia_reclamo_evento (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id       uuid NOT NULL,
  reclamo_id       uuid NOT NULL,
  estado_anterior  text,
  estado_nuevo     text NOT NULL,
  nota             text,
  id_operacion     uuid,
  creado_por       uuid,
  creado_en        timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, reclamo_id) REFERENCES public.garantia_reclamo(empresa_id, id)
);
CREATE INDEX garantia_reclamo_evento_reclamo ON public.garantia_reclamo_evento (reclamo_id, id);

-- El reclamo solo cambia de estado hacia adelante y no cambia lo que se reclamó.
CREATE FUNCTION interno.proteger_garantia_reclamo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.numero, NEW.venta_id, NEW.venta_linea_id, NEW.producto_id, NEW.cantidad, NEW.motivo,
      NEW.garantia_hasta, NEW.fecha, NEW.fuera_de_plazo, NEW.id_operacion, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.numero, OLD.venta_id, OLD.venta_linea_id, OLD.producto_id, OLD.cantidad, OLD.motivo,
      OLD.garantia_hasta, OLD.fecha, OLD.fuera_de_plazo, OLD.id_operacion, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: lo que se reclamó no se edita (registre otro reclamo).';
  END IF;
  IF OLD.estado IN ('resuelto', 'rechazado') THEN
    RAISE EXCEPTION 'PROHIBIDO: el reclamo #% ya está %.', OLD.numero, OLD.estado;
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.garantia_reclamo
  FOR EACH ROW EXECUTE FUNCTION interno.proteger_garantia_reclamo();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.garantia_reclamo
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.garantia_reclamo
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los reclamos de garantía no se borran (se rechazan con motivo).');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.garantia_reclamo
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
CREATE TRIGGER proteger BEFORE UPDATE ON public.garantia_reclamo_evento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El historial de un reclamo no se edita.');
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.garantia_reclamo_evento
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.garantia_reclamo_evento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El historial de un reclamo no se borra.');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.garantia_reclamo_evento
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');

ALTER TABLE public.garantia_reclamo ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.garantia_reclamo_evento ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.garantia_reclamo, public.garantia_reclamo_evento FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.garantia_reclamo, public.garantia_reclamo_evento TO authenticated, service_role;
CREATE POLICY leer ON public.garantia_reclamo FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('garantias.registrar')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('garantias.resolver')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
CREATE POLICY por_sucursal ON public.garantia_reclamo AS RESTRICTIVE FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_sin_restriccion()))
         OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())));
CREATE POLICY leer ON public.garantia_reclamo_evento FOR SELECT TO authenticated
  USING (reclamo_id IN (SELECT r.id FROM public.garantia_reclamo r));

INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('garantia_reclamo', 'id_operacion', 'reclamo_garantia', 95),
  ('garantia_reclamo', 'resolucion_id_operacion', 'resolucion_garantia', 96);

-- Vista para la app: reclamos con su venta y su producto (respeta RLS).
CREATE VIEW public.v_garantia_reclamo WITH (security_invoker = true) AS
  SELECT r.empresa_id, r.id AS reclamo_id, r.numero, r.estado, r.fecha, r.venta_id, r.numero_documento, r.fecha_venta,
         r.linea, r.producto_id, r.descripcion_producto, r.cantidad, r.cliente_id, r.cliente_nombre, r.sucursal_id,
         r.garantia_hasta, r.motivo, r.descripcion, r.fuera_de_plazo, r.autorizacion_motivo,
         r.resolucion, r.resolucion_nota, r.devolucion_id, r.gasto_id, r.costo_reparacion_centavos, r.rechazo_motivo,
         r.resuelto_en, public.nombre_usuario(r.empresa_id, r.creado_por) AS registrado_por, r.creado_en, r.actualizado_en
    FROM public.garantia_reclamo r;
REVOKE ALL ON public.v_garantia_reclamo FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_garantia_reclamo TO authenticated, service_role;

CREATE FUNCTION interno.reclamo_respuesta(r public.garantia_reclamo, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('reclamo_id', r.id, 'numero', r.numero, 'estado', r.estado, 'venta_id', r.venta_id, 'linea', r.linea,
    'producto', r.descripcion_producto, 'cantidad', r.cantidad, 'cliente', r.cliente_nombre,
    'garantia_hasta', to_char(r.garantia_hasta, 'YYYY-MM-DD'), 'fuera_de_plazo', r.fuera_de_plazo,
    'resolucion', r.resolucion, 'devolucion_id', r.devolucion_id, 'gasto_id', r.gasto_id, 'duplicado', p_duplicado)
$$;

-- Cantidad de una línea ya devuelta (las devoluciones pendientes también cuentan).
CREATE FUNCTION interno.cantidad_devuelta_linea(p_venta_linea_id bigint) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(dl.cantidad), 0) FROM public.devolucion_linea dl JOIN public.devolucion d ON d.id = dl.devolucion_id
   WHERE dl.venta_linea_id = p_venta_linea_id AND d.estado IN ('por_aplicar', 'pendiente_aprobacion', 'aplicada')
$$;

-- Permiso para leer garantías: registrar, resolver o ventas.ver.
CREATE FUNCTION interno.exigir_lectura_garantias(p_empresa_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, CASE WHEN public.tiene_permiso('garantias.resolver', p_empresa_id) THEN 'garantias.resolver'
                                                    WHEN public.tiene_permiso('garantias.registrar', p_empresa_id) THEN 'garantias.registrar'
                                                    ELSE 'ventas.ver' END);
END $$;

-- buscar_garantia(empresa, texto, solo_vigentes?)   garantias.registrar / garantias.resolver / ventas.ver
-- Líneas vendidas CON garantía cuyo número de factura, cliente o producto (nombre o código) contiene el texto.
CREATE FUNCTION public.buscar_garantia(p_empresa_id uuid, p_texto text, p_solo_vigentes boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy   date;
  v_restr boolean;
  v_q     text := '%' || lower(trim(coalesce(p_texto, ''))) || '%';
BEGIN
  PERFORM interno.exigir_lectura_garantias(p_empresa_id);
  IF length(trim(coalesce(p_texto, ''))) < 2 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba al menos 2 letras o números para buscar (factura, cliente o producto).';
  END IF;
  v_hoy := public.hoy_local(p_empresa_id);
  v_restr := interno.usuario_restringido(p_empresa_id);
  RETURN jsonb_build_object('hoy', to_char(v_hoy, 'YYYY-MM-DD'), 'lineas', coalesce((SELECT jsonb_agg(x.j ORDER BY x.f DESC, x.n, x.l) FROM (
    SELECT v.fecha_contable AS f, v.numero AS n, vl.linea AS l, jsonb_build_object(
      'venta_id', v.id, 'numero_documento', v.numero_documento, 'fecha_venta', to_char(v.fecha_contable, 'YYYY-MM-DD'),
      'cliente_id', v.cliente_id, 'cliente', v.cliente_nombre, 'linea', vl.linea, 'producto_id', vl.producto_id,
      'codigo', p.codigo, 'producto', vl.descripcion, 'cantidad', vl.cantidad,
      'devuelta', interno.cantidad_devuelta_linea(vl.id),
      'garantia_dias', vl.garantia_dias, 'garantia_hasta', to_char(vl.garantia_hasta, 'YYYY-MM-DD'),
      'vigente', vl.garantia_hasta >= v_hoy, 'dias_restantes', vl.garantia_hasta - v_hoy,
      'reclamos_abiertos', (SELECT count(*) FROM public.garantia_reclamo r WHERE r.venta_linea_id = vl.id AND r.estado IN ('recibido', 'en_revision')),
      'reclamos', (SELECT count(*) FROM public.garantia_reclamo r WHERE r.venta_linea_id = vl.id)) AS j
      FROM public.venta_linea vl
      JOIN public.venta v ON v.id = vl.venta_id
      JOIN public.producto p ON p.id = vl.producto_id
     WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND vl.garantia_hasta IS NOT NULL
       AND (NOT p_solo_vigentes OR vl.garantia_hasta >= v_hoy)
       AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, v.sucursal_id))
       AND (lower(coalesce(v.numero_documento, '')) LIKE v_q OR lower(v.cliente_nombre) LIKE v_q
            OR lower(vl.descripcion) LIKE v_q OR lower(p.codigo) LIKE v_q OR lower(coalesce(p.codigo_barras, '')) LIKE v_q)
     ORDER BY v.fecha_contable DESC, v.numero DESC, vl.linea LIMIT 50) x), '[]'));
END $$;

-- registrar_reclamo_garantia(empresa, datos, id_operacion)   garantias.registrar
-- datos = {"venta_id", "linea", "cantidad"? (1), "motivo", "descripcion"?, "fecha"? (hoy),
--          "autorizar_fuera_de_plazo"?: "motivo de la autorización" (pide garantias.resolver)}
CREATE FUNCTION public.registrar_reclamo_garantia(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r       public.garantia_reclamo;
  v       public.venta;
  vl      public.venta_linea;
  v_q     numeric;
  v_fecha date;
  v_aut   text;
  v_mot   text;
  v_fuera boolean;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'garantias.registrar', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'reclamo_garantia');
  SELECT * INTO r FROM public.garantia_reclamo x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF r.id IS NOT NULL THEN
    RETURN interno.reclamo_respuesta(r, true);
  END IF;
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['venta_id', 'linea', 'cantidad', 'motivo', 'descripcion', 'fecha', 'autorizar_fuera_de_plazo']);
  SELECT * INTO v FROM public.venta x WHERE x.id = interno.json_uuid(p_datos->'venta_id', 'venta_id') AND x.empresa_id = p_empresa_id;
  IF v.id IS NULL OR v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'GARANTIA_INVALIDA: la venta no existe en esta empresa o no está emitida (una venta anulada no tiene garantía).';
  END IF;
  PERFORM interno.exigir_sucursal(p_empresa_id, v.sucursal_id);
  IF jsonb_typeof(p_datos->'linea') IS DISTINCT FROM 'number' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique la línea de la venta ("linea": 1, 2...).';
  END IF;
  SELECT * INTO vl FROM public.venta_linea x WHERE x.venta_id = v.id AND x.linea = (p_datos->>'linea')::numeric;
  IF vl.id IS NULL THEN
    RAISE EXCEPTION 'GARANTIA_INVALIDA: la venta no tiene la línea %.', p_datos->>'linea';
  END IF;
  IF vl.garantia_hasta IS NULL THEN
    RAISE EXCEPTION 'GARANTIA_INVALIDA: "%" se vendió sin garantía.', vl.descripcion;
  END IF;
  v_q := CASE WHEN coalesce(p_datos->'cantidad', 'null'::jsonb) = 'null'::jsonb THEN 1 ELSE interno.json_numero(p_datos->'cantidad', 'cantidad', 1) END;
  IF v_q <= 0 OR v_q > vl.cantidad - interno.cantidad_devuelta_linea(vl.id) THEN
    RAISE EXCEPTION 'GARANTIA_INVALIDA: la cantidad reclamada (%) pasa lo vendido que queda sin devolver (%).',
      trim_scale(v_q), trim_scale(vl.cantidad - interno.cantidad_devuelta_linea(vl.id));
  END IF;
  v_mot := interno.json_texto(p_datos->'motivo', 'motivo', 200);
  IF length(coalesce(v_mot, '')) < 3 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del reclamo (qué falla).';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  IF v_fecha > public.hoy_local(p_empresa_id) OR v_fecha < v.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el reclamo va desde la fecha de la venta hasta hoy.';
  END IF;
  v_fuera := v_fecha > vl.garantia_hasta;
  v_aut := interno.json_texto(p_datos->'autorizar_fuera_de_plazo', 'autorizar_fuera_de_plazo', 300);
  IF v_fuera THEN
    IF v_aut IS NULL THEN
      RAISE EXCEPTION 'GARANTIA_VENCIDA: la garantía de "%" venció el % (hace % días).', vl.descripcion,
        to_char(vl.garantia_hasta, 'DD/MM/YYYY'), v_fecha - vl.garantia_hasta;
    END IF;
    IF NOT public.tiene_permiso('garantias.resolver', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: autorizar un reclamo fuera de plazo pide el permiso "garantias.resolver".';
    END IF;
    IF length(v_aut) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se autoriza fuera de plazo (mínimo 5 letras).';
    END IF;
  ELSIF v_aut IS NOT NULL THEN
    v_aut := NULL;   -- vigente: no hace falta autorizar
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'reclamo_garantia');
  SELECT * INTO r FROM public.garantia_reclamo x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF r.id IS NOT NULL THEN
    RETURN interno.reclamo_respuesta(r, true);
  END IF;
  PERFORM set_config('app.motivo', coalesce(v_aut, 'Reclamo de garantía: ' || v_mot), true);
  INSERT INTO public.garantia_reclamo (empresa_id, numero, venta_id, venta_linea_id, numero_documento, fecha_venta, linea, producto_id, descripcion_producto,
    cliente_id, cliente_nombre, sucursal_id, cantidad, garantia_hasta, fecha, motivo, descripcion, fuera_de_plazo,
    autorizado_por, autorizacion_motivo, id_operacion, creado_por)
  VALUES (p_empresa_id, interno.siguiente_numero(p_empresa_id, 'garantia_reclamo'), v.id, vl.id, v.numero_documento, v.fecha_contable, vl.linea, vl.producto_id, vl.descripcion,
    v.cliente_id, v.cliente_nombre, v.sucursal_id, v_q, vl.garantia_hasta, v_fecha, v_mot,
    interno.json_texto(p_datos->'descripcion', 'descripcion', 1000), v_fuera,
    CASE WHEN v_fuera THEN auth.uid() END, v_aut, p_id_operacion, auth.uid())
  RETURNING * INTO r;
  INSERT INTO public.garantia_reclamo_evento (empresa_id, reclamo_id, estado_anterior, estado_nuevo, nota, id_operacion, creado_por)
  VALUES (p_empresa_id, r.id, NULL, 'recibido', coalesce('Fuera de plazo, autorizado: ' || v_aut, v_mot), p_id_operacion, auth.uid());
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.reclamo_respuesta(r, false);
END $$;

-- Cambio de estado con historial y bitácora (lo usan las dos funciones de abajo).
CREATE FUNCTION interno.reclamo_a_estado(p_reclamo public.garantia_reclamo, p_estado text, p_nota text, p_id_operacion uuid)
RETURNS public.garantia_reclamo
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.garantia_reclamo;
BEGIN
  PERFORM set_config('app.motivo', coalesce(p_nota, ''), true);
  UPDATE public.garantia_reclamo SET estado = p_estado WHERE id = p_reclamo.id RETURNING * INTO r;
  INSERT INTO public.garantia_reclamo_evento (empresa_id, reclamo_id, estado_anterior, estado_nuevo, nota, id_operacion, creado_por)
  VALUES (r.empresa_id, r.id, p_reclamo.estado, p_estado, p_nota, p_id_operacion, auth.uid());
  PERFORM set_config('app.motivo', '', true);
  RETURN r;
END $$;

-- cambiar_estado_reclamo(reclamo, estado, nota, id_operacion)
--   "en_revision": garantias.registrar o garantias.resolver.   "rechazado": garantias.resolver y motivo.
--   Reintento: si el reclamo ya está en ese estado por esta misma operación, devuelve lo mismo.
CREATE FUNCTION public.cambiar_estado_reclamo(p_reclamo_id uuid, p_estado text, p_nota text, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.garantia_reclamo;
BEGIN
  SELECT * INTO r FROM public.garantia_reclamo WHERE id = p_reclamo_id;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el reclamo de garantía no existe.';
  END IF;
  IF p_estado NOT IN ('en_revision', 'rechazado') OR p_estado IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el estado es "en_revision" o "rechazado" (para resolver use resolver_reclamo_garantia).';
  END IF;
  IF p_estado = 'rechazado' OR NOT public.tiene_permiso('garantias.registrar', r.empresa_id) THEN
    PERFORM interno.exigir_escritura(r.empresa_id, 'garantias.resolver', 'ventas');
  ELSE
    PERFORM interno.exigir_escritura(r.empresa_id, 'garantias.registrar', 'ventas');
  END IF;
  PERFORM interno.exigir_sucursal(r.empresa_id, r.sucursal_id);
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.garantia_reclamo_evento e WHERE e.reclamo_id = r.id AND e.id_operacion = p_id_operacion AND e.estado_nuevo = p_estado) THEN
    RETURN interno.reclamo_respuesta(r, true);
  END IF;
  IF p_estado = 'rechazado' AND length(trim(coalesce(p_nota, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se rechaza el reclamo (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(r.empresa_id);
  SELECT * INTO r FROM public.garantia_reclamo WHERE id = p_reclamo_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.garantia_reclamo_evento e WHERE e.reclamo_id = r.id AND e.id_operacion = p_id_operacion AND e.estado_nuevo = p_estado) THEN
    RETURN interno.reclamo_respuesta(r, true);
  END IF;
  IF r.estado NOT IN ('recibido', 'en_revision') OR (p_estado = 'en_revision' AND r.estado = 'en_revision') THEN
    RAISE EXCEPTION 'GARANTIA_INVALIDA: el reclamo #% está "%"; no pasa a "%".', r.numero, r.estado, p_estado;
  END IF;
  IF p_estado = 'rechazado' THEN
    UPDATE public.garantia_reclamo SET rechazo_motivo = trim(p_nota), resuelto_por = auth.uid(), resuelto_en = now(),
           resolucion_id_operacion = p_id_operacion
     WHERE id = r.id;
  END IF;
  r := interno.reclamo_a_estado(r, p_estado, nullif(trim(coalesce(p_nota, '')), ''), p_id_operacion);
  RETURN interno.reclamo_respuesta(r, false);
END $$;

-- resolver_reclamo_garantia(reclamo, datos, id_operacion)   garantias.resolver
-- datos = {"resolucion": "reparado" | "cambiado" | "devuelto", "nota"?,
--   reparado:  "costo_reparacion"?: {"cuenta_dinero_id", "categoria_id", "monto_centavos"} -> registrar_gasto
--   cambiado:  "cambio"?: lo mismo que registrar_devolucion (por defecto: el mismo producto y cantidad);
--              "cuenta_dinero_id"?, "caja_id"?
--   devuelto:  "destino": "dinero" | "saldo_favor", "cuenta_dinero_id"? , "caja_id"?}
-- El cambio y la devolución usan registrar_devolucion (pide además ventas.devolver); el gasto, registrar_gasto
-- (pide gastos.registrar). Todo junto o nada; reintento con el mismo id_operacion = la misma respuesta.
CREATE FUNCTION public.resolver_reclamo_garantia(p_reclamo_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      public.garantia_reclamo;
  v_res  text;
  v_dev  jsonb;
  v_gas  jsonb;
  v_c    jsonb;
  d      jsonb;
  v_nota text;
BEGIN
  SELECT * INTO r FROM public.garantia_reclamo WHERE id = p_reclamo_id;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el reclamo de garantía no existe.';
  END IF;
  PERFORM interno.exigir_escritura(r.empresa_id, 'garantias.resolver', 'ventas');
  PERFORM interno.exigir_sucursal(r.empresa_id, r.sucursal_id);
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(r.empresa_id, p_id_operacion, 'resolucion_garantia');
  IF r.resolucion_id_operacion = p_id_operacion THEN
    RETURN interno.reclamo_respuesta(r, true);
  END IF;
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['resolucion', 'nota', 'costo_reparacion', 'cambio', 'destino', 'cuenta_dinero_id', 'caja_id']);
  v_res := interno.json_texto(p_datos->'resolucion', 'resolucion', 20);
  IF v_res IS NULL OR v_res NOT IN ('reparado', 'cambiado', 'devuelto') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la resolución es "reparado", "cambiado" o "devuelto".';
  END IF;
  IF v_res <> 'reparado' AND p_datos ? 'costo_reparacion' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el costo de reparación solo va con "reparado".';
  END IF;
  IF v_res <> 'cambiado' AND p_datos ? 'cambio' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "cambio" solo va con "cambiado".';
  END IF;
  v_nota := interno.json_texto(p_datos->'nota', 'nota', 500);

  PERFORM interno.reservar_operacion(r.empresa_id, p_id_operacion, 'resolucion_garantia');
  SELECT * INTO r FROM public.garantia_reclamo WHERE id = p_reclamo_id FOR UPDATE;
  IF r.resolucion_id_operacion = p_id_operacion THEN
    RETURN interno.reclamo_respuesta(r, true);
  END IF;
  IF r.estado NOT IN ('recibido', 'en_revision') THEN
    RAISE EXCEPTION 'GARANTIA_INVALIDA: el reclamo #% ya está "%".', r.numero, r.estado;
  END IF;

  IF v_res = 'reparado' AND coalesce(p_datos->'costo_reparacion', 'null'::jsonb) <> 'null'::jsonb THEN
    v_c := p_datos->'costo_reparacion';
    PERFORM interno.exigir_claves(v_c, ARRAY['cuenta_dinero_id', 'categoria_id', 'monto_centavos']);
    v_gas := public.registrar_gasto(r.empresa_id, jsonb_build_object('cuenta_dinero_id', v_c->'cuenta_dinero_id',
               'categoria_id', v_c->'categoria_id', 'monto_centavos', v_c->'monto_centavos',
               'descripcion', 'Reparación por garantía, reclamo #' || r.numero || ' (' || r.descripcion_producto || ')'),
               md5(p_id_operacion::text || ':gasto_garantia')::uuid);
  ELSIF v_res IN ('cambiado', 'devuelto') THEN
    d := jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('linea', r.linea, 'cantidad', r.cantidad)),
           'motivo', 'Garantía, reclamo #' || r.numero || ': ' || r.motivo,
           'destino', CASE v_res WHEN 'cambiado' THEN 'cambio' ELSE coalesce(p_datos->>'destino', 'dinero') END)
         || CASE WHEN p_datos ? 'cuenta_dinero_id' THEN jsonb_build_object('cuenta_dinero_id', p_datos->'cuenta_dinero_id') ELSE '{}' END
         || CASE WHEN p_datos ? 'caja_id' THEN jsonb_build_object('caja_id', p_datos->'caja_id') ELSE '{}' END;
    IF v_res = 'cambiado' THEN
      d := d || jsonb_build_object('cambio', coalesce(p_datos->'cambio',
             jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', r.producto_id, 'cantidad', r.cantidad)))));
    END IF;
    v_dev := public.registrar_devolucion(r.venta_id, d, md5(p_id_operacion::text || ':devolucion_garantia')::uuid);
  END IF;

  PERFORM set_config('app.motivo', coalesce(v_nota, initcap(v_res)), true);
  UPDATE public.garantia_reclamo SET estado = 'resuelto', resolucion = v_res, resolucion_nota = v_nota,
         devolucion_id = (v_dev->>'devolucion_id')::uuid, gasto_id = (v_gas->>'gasto_id')::uuid,
         costo_reparacion_centavos = CASE WHEN v_gas IS NOT NULL THEN (v_c->>'monto_centavos')::bigint END,
         resuelto_por = auth.uid(), resuelto_en = now(), resolucion_id_operacion = p_id_operacion
   WHERE id = r.id;
  INSERT INTO public.garantia_reclamo_evento (empresa_id, reclamo_id, estado_anterior, estado_nuevo, nota, id_operacion, creado_por)
  VALUES (r.empresa_id, r.id, r.estado, 'resuelto', coalesce(v_nota, initcap(v_res)), p_id_operacion, auth.uid());
  PERFORM set_config('app.motivo', '', true);
  SELECT * INTO r FROM public.garantia_reclamo WHERE id = r.id;
  RETURN interno.reclamo_respuesta(r, false) || jsonb_strip_nulls(jsonb_build_object('devolucion', v_dev, 'gasto', v_gas));
END $$;

-- Comprobante del reclamo (lo que se imprime; la app lo arma sin íconos ni emojis).
CREATE FUNCTION public.documento_reclamo_garantia(p_reclamo_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r public.garantia_reclamo;
  v public.venta;
BEGIN
  SELECT * INTO r FROM public.garantia_reclamo WHERE id = p_reclamo_id;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el reclamo de garantía no existe.';
  END IF;
  PERFORM interno.exigir_lectura_garantias(r.empresa_id);
  PERFORM interno.exigir_sucursal(r.empresa_id, r.sucursal_id);
  SELECT * INTO v FROM public.venta WHERE id = r.venta_id;
  RETURN jsonb_build_object('titulo', 'RECLAMO DE GARANTÍA', 'numero', r.numero, 'estado', r.estado,
    'emisor', jsonb_build_object('nombre', v.emisor_nombre, 'rtn', v.emisor_rtn,
                                 'sucursal', (SELECT s.codigo || ' ' || s.nombre FROM public.sucursal s WHERE s.id = r.sucursal_id)),
    'fecha', to_char(r.fecha, 'DD/MM/YYYY'), 'cliente', r.cliente_nombre,
    'factura', v.numero_documento, 'fecha_venta', to_char(v.fecha_contable, 'DD/MM/YYYY'),
    'producto', r.descripcion_producto, 'cantidad', r.cantidad, 'garantia_hasta', to_char(r.garantia_hasta, 'DD/MM/YYYY'),
    'fuera_de_plazo', r.fuera_de_plazo, 'autorizacion', r.autorizacion_motivo,
    'motivo', r.motivo, 'descripcion', r.descripcion, 'resolucion', r.resolucion, 'resolucion_nota', r.resolucion_nota,
    'rechazo_motivo', r.rechazo_motivo, 'registrado_por', public.nombre_usuario(r.empresa_id, r.creado_por),
    'historial', (SELECT coalesce(jsonb_agg(jsonb_build_object('estado', e.estado_nuevo, 'nota', e.nota,
        'cuando', public.iso(e.creado_en), 'quien', public.nombre_usuario(r.empresa_id, e.creado_por)) ORDER BY e.id), '[]')
      FROM public.garantia_reclamo_evento e WHERE e.reclamo_id = r.id));
END $$;

REVOKE EXECUTE ON FUNCTION
  interno.garantia_de_linea(), interno.fijar_garantia_venta(), interno.proteger_garantia_reclamo(),
  interno.reclamo_respuesta(public.garantia_reclamo, boolean), interno.cantidad_devuelta_linea(bigint),
  interno.exigir_lectura_garantias(uuid), interno.reclamo_a_estado(public.garantia_reclamo, text, text, uuid)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.buscar_garantia(uuid, text, boolean), public.registrar_reclamo_garantia(uuid, jsonb, uuid),
  public.cambiar_estado_reclamo(uuid, text, text, uuid), public.resolver_reclamo_garantia(uuid, jsonb, uuid),
  public.documento_reclamo_garantia(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.buscar_garantia(uuid, text, boolean), public.registrar_reclamo_garantia(uuid, jsonb, uuid),
  public.cambiar_estado_reclamo(uuid, text, text, uuid), public.resolver_reclamo_garantia(uuid, jsonb, uuid),
  public.documento_reclamo_garantia(uuid)
TO authenticated;

-- =====================================================================
-- 3) ABONOS CON CHEQUE (nucleo/docs/cheques.md)
--    Forma de pago "cheque" en los cobros a clientes (no en ventas: ver cheques.md). El cheque
--    NO es efectivo disponible: entra a la cuenta de dinero "Cheques por depositar" (tipo
--    cheques_por_depositar, subcuenta 1.1.01.NN; se crea sola la primera vez) y de ahí se
--    deposita a un banco con el flujo de siempre (en tránsito -> confirmar_deposito). Si
--    rebota: registrar_cheque_rechazado revierte el cobro con contrapartida (el cliente vuelve
--    a deber) y, si se pide, registra el cargo del banco como gasto.
-- =====================================================================
INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('CHEQUE_INVALIDO', 'Los datos del cheque no son válidos.',
   'Revise el número, el banco que lo emitió y la fecha. Un cheque va solo en el cobro y no deja saldo a favor.'),
  ('CHEQUE_POSFECHADO', 'Ese cheque todavía no se puede depositar.',
   'El cheque es posfechado: se deposita desde la fecha escrita en el cheque.'),
  ('CHEQUE_DEPOSITADO', 'El cheque ya salió de "Cheques por depositar".',
   'Si el banco lo devolvió, use "Rebotó" (cheque rechazado): revierte el cobro y deja la constancia.');

ALTER TABLE public.cuenta_dinero DROP CONSTRAINT cuenta_dinero_tipo_check;
ALTER TABLE public.cuenta_dinero ADD CONSTRAINT cuenta_dinero_tipo_check CHECK (tipo IN ('efectivo_caja', 'banco', 'caja_chica',
  'pos_por_liquidar', 'transferencia_por_confirmar', 'transito', 'cheques_por_depositar'));
ALTER TABLE public.cobro_pago DROP CONSTRAINT cobro_pago_forma_check;
ALTER TABLE public.cobro_pago ADD CONSTRAINT cobro_pago_forma_check CHECK (forma IN ('efectivo', 'tarjeta', 'transferencia', 'saldo_favor', 'cheque'));

-- Cada cheque recibido (uno por cobro).
CREATE TABLE public.cheque_recibido (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id              uuid NOT NULL REFERENCES public.empresa(id),
  numero                  bigint NOT NULL,
  cobro_id                uuid NOT NULL,
  cliente_id              uuid NOT NULL,
  cliente_nombre          text NOT NULL,
  sucursal_id             uuid,
  numero_cheque           text NOT NULL CHECK (length(numero_cheque) BETWEEN 1 AND 30),
  banco_emisor            text NOT NULL CHECK (length(banco_emisor) BETWEEN 2 AND 100),
  fecha_cheque            date NOT NULL,
  fecha_recibido          date NOT NULL,
  monto_centavos          bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  cuenta_dinero_id        uuid NOT NULL,          -- "Cheques por depositar"
  estado                  text NOT NULL DEFAULT 'por_depositar'
                            CHECK (estado IN ('por_depositar', 'depositado', 'rechazado', 'anulado')),
  operacion_deposito_id   uuid,                   -- el depósito vigente (en tránsito o confirmado)
  banco_id                uuid,
  fecha_deposito          date,
  motivo_rechazo          text,
  fecha_rechazo           date,
  cargo_banco_gasto_id    uuid,
  rechazo_id_operacion    uuid,
  rechazado_por           uuid,
  rechazado_en            timestamptz,
  creado_por              uuid,
  creado_en               timestamptz NOT NULL DEFAULT now(),
  actualizado_en          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (cobro_id),
  UNIQUE (empresa_id, rechazo_id_operacion),
  FOREIGN KEY (empresa_id, cobro_id) REFERENCES public.cobro(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id) REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, banco_id) REFERENCES public.cuenta_dinero(empresa_id, id),
  CHECK (estado <> 'depositado' OR operacion_deposito_id IS NOT NULL),
  CHECK (estado <> 'por_depositar' OR operacion_deposito_id IS NULL),
  CHECK (estado <> 'rechazado' OR length(trim(motivo_rechazo)) >= 5)
);
CREATE INDEX cheque_recibido_estado ON public.cheque_recibido (empresa_id, estado);

-- Lo que se recibió no cambia; el estado solo lo mueven las funciones (y queda en la bitácora).
CREATE FUNCTION interno.proteger_cheque() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.numero, NEW.cobro_id, NEW.cliente_id, NEW.numero_cheque, NEW.banco_emisor, NEW.fecha_cheque,
      NEW.fecha_recibido, NEW.monto_centavos, NEW.cuenta_dinero_id, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.numero, OLD.cobro_id, OLD.cliente_id, OLD.numero_cheque, OLD.banco_emisor, OLD.fecha_cheque,
      OLD.fecha_recibido, OLD.monto_centavos, OLD.cuenta_dinero_id, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: los datos de un cheque recibido no se editan.';
  END IF;
  IF OLD.estado IN ('rechazado', 'anulado') THEN
    RAISE EXCEPTION 'PROHIBIDO: el cheque #% ya está %.', OLD.numero, OLD.estado;
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.cheque_recibido FOR EACH ROW EXECUTE FUNCTION interno.proteger_cheque();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.cheque_recibido FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.cheque_recibido
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los cheques recibidos no se borran.');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.cheque_recibido
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
ALTER TABLE public.cheque_recibido ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cheque_recibido FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cheque_recibido TO authenticated, service_role;
CREATE POLICY leer ON public.cheque_recibido FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('cobros.ver_saldos'))));
CREATE POLICY por_sucursal ON public.cheque_recibido AS RESTRICTIVE FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_sin_restriccion()))
         OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())));

INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('cheque_recibido', 'rechazo_id_operacion', 'rechazo_cheque', 97);

CREATE VIEW public.v_cheque_recibido WITH (security_invoker = true) AS
  SELECT ch.empresa_id, ch.id AS cheque_id, ch.numero, ch.estado, ch.cobro_id, cb.numero AS cobro_numero,
         ch.cliente_id, ch.cliente_nombre, ch.sucursal_id, ch.numero_cheque, ch.banco_emisor, ch.fecha_cheque,
         ch.fecha_recibido, ch.monto_centavos, ch.cuenta_dinero_id, ch.operacion_deposito_id,
         (SELECT o.estado FROM public.operacion_dinero o WHERE o.id = ch.operacion_deposito_id) AS estado_deposito,
         ch.banco_id, (SELECT d.nombre FROM public.cuenta_dinero d WHERE d.id = ch.banco_id) AS banco,
         ch.fecha_deposito, ch.motivo_rechazo, ch.fecha_rechazo, ch.cargo_banco_gasto_id, ch.creado_en, ch.actualizado_en
    FROM public.cheque_recibido ch
    JOIN public.cobro cb ON cb.id = ch.cobro_id;
REVOKE ALL ON public.v_cheque_recibido FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_cheque_recibido TO authenticated, service_role;

-- Cuenta "Cheques por depositar" de la empresa (la primera activa; se crea la primera vez).
CREATE FUNCTION interno.cuenta_cheques(p_empresa_id uuid) RETURNS public.cuenta_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  SELECT * INTO d FROM public.cuenta_dinero x WHERE x.empresa_id = p_empresa_id AND x.tipo = 'cheques_por_depositar' AND x.activa
   ORDER BY x.creado_en, x.id LIMIT 1;
  IF d.id IS NOT NULL THEN
    RETURN d;
  END IF;
  RETURN interno.crear_cuenta_dinero_base(p_empresa_id, 'cheques_por_depositar',
    CASE WHEN EXISTS (SELECT 1 FROM public.cuenta_dinero x WHERE x.empresa_id = p_empresa_id AND lower(x.nombre) = 'cheques por depositar')
         THEN 'Cheques por depositar (' || to_char(public.hoy_local(p_empresa_id), 'YYYY-MM-DD') || ')' ELSE 'Cheques por depositar' END,
    NULL, NULL, NULL, NULL, NULL, (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id), NULL);
END $$;

-- Datos del cheque de un pago (y sus reglas): {"numero_cheque", "banco_emisor", "fecha_cheque"}.
CREATE FUNCTION interno.datos_cheque(pj jsonb, p_pagos integer, p_apartado_id uuid, p_tipo text, p_excedente boolean,
                                     p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_num   text := interno.json_texto(pj->'numero_cheque', 'numero_cheque', 30);
  v_banco text := interno.json_texto(pj->'banco_emisor', 'banco_emisor', 100);
  v_fecha date := interno.json_fecha(pj->'fecha_cheque', 'fecha_cheque');
  v_hoy   date := public.hoy_local(p_empresa_id);
BEGIN
  IF p_apartado_id IS NOT NULL OR p_tipo <> 'cxc' THEN
    RAISE EXCEPTION 'CHEQUE_INVALIDO: un cheque se recibe solo como abono a lo que el cliente debe (no como anticipo ni apartado).';
  END IF;
  IF p_pagos <> 1 THEN
    RAISE EXCEPTION 'CHEQUE_INVALIDO: el cheque va solo en el cobro (si paga parte en efectivo, son dos cobros).';
  END IF;
  IF p_excedente THEN
    RAISE EXCEPTION 'CHEQUE_INVALIDO: un cheque no deja saldo a favor (si rebota no habría con qué devolverlo); cobre solo lo que debe.';
  END IF;
  IF v_num IS NULL OR v_banco IS NULL OR length(v_banco) < 2 OR v_fecha IS NULL THEN
    RAISE EXCEPTION 'CHEQUE_INVALIDO: indique el número del cheque, el banco que lo emitió y la fecha del cheque.';
  END IF;
  IF v_fecha < v_hoy - 180 OR v_fecha > v_hoy + 365 THEN
    RAISE EXCEPTION 'CHEQUE_INVALIDO: la fecha del cheque va de 6 meses atrás a un año adelante (posfechado).';
  END IF;
  RETURN jsonb_build_object('numero_cheque', v_num, 'banco_emisor', v_banco, 'fecha_cheque', v_fecha);
END $$;

-- Cobros (reemplaza la de 033; misma firma): acepta la forma "cheque" y guarda el cheque.
CREATE OR REPLACE FUNCTION interno.registrar_cobro_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_apartado_id uuid DEFAULT NULL, p_apartado_saldo bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c        public.cobro;
  v_cli    public.tercero;
  v_tipo   text;
  v_fecha  date;
  v_caja   uuid;
  pj       jsonb;
  k        integer := 0;
  v_forma  text;
  v_monto  bigint;
  v_rec    bigint;
  v_total  bigint := 0;
  v_dinero bigint := 0;
  v_sfav   bigint := 0;
  v_norm   jsonb := '[]';
  v_apl    jsonb := '[]';
  v_aplic  bigint := 0;
  v_exc    bigint;
  v_doc    uuid;
  v_esvta  boolean;
  v_saldo  bigint;
  v_resto  bigint;
  r        record;
  d        public.cuenta_dinero;
  f        public.saldo_favor;
  v_lin    jsonb := '[]';
  v_usos   jsonb;
  v_vale   text;
  v_suc    uuid;
  v_asto   uuid;
  v_pid    uuid;
  a        jsonb;
  v_cheq   jsonb;      -- 0.18.0: datos del cheque (número, banco emisor, fecha)
BEGIN
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  SELECT * INTO c FROM public.cobro x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF c.id IS NOT NULL THEN
    RETURN interno.cobro_respuesta(c, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cliente_id', 'tipo', 'pagos', 'aplicar', 'excedente', 'caja_id', 'fecha',
                                               'referencia', 'nota', 'equipo']);
  IF NOT interno.puede_cobrar(p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.cobrar" (recibir dinero de clientes).';
  END IF;
  v_cli := interno.cliente_de(p_empresa_id, p_datos->'cliente_id');
  v_tipo := CASE WHEN p_apartado_id IS NOT NULL THEN 'apartado'
                 ELSE coalesce(interno.json_texto(p_datos->'tipo', 'tipo', 20), 'cxc') END;
  IF p_apartado_id IS NULL AND v_tipo NOT IN ('cxc', 'anticipo') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de cobro es "cxc" (a facturas) o "anticipo" (queda como saldo a favor).';
  END IF;
  IF coalesce(p_datos->'excedente', 'null'::jsonb) <> 'null'::jsonb AND interno.json_texto(p_datos->'excedente', 'excedente', 20) <> 'saldo_favor' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "excedente" solo puede ser "saldo_favor" (lo que pase del saldo queda a favor del cliente).';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  v_caja := interno.json_uuid(p_datos->'caja_id', 'caja_id');

  -- Formas de pago.
  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia o saldo a favor).';
  END IF;
  IF jsonb_array_length(p_datos->'pagos') > 10 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 10 formas de pago por cobro.';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    k := k + 1;
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    PERFORM interno.exigir_claves(pj, ARRAY['forma', 'monto_centavos', 'cuenta_dinero_id', 'referencia', 'recibido_centavos', 'vale',
                                            'numero_cheque', 'banco_emisor', 'fecha_cheque']);
    v_forma := interno.json_texto(pj->'forma', 'forma', 20);
    IF coalesce(v_forma, '') NOT IN ('efectivo', 'tarjeta', 'transferencia', 'saldo_favor', 'cheque') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago de un cobro es efectivo, tarjeta, transferencia, cheque o saldo_favor.';
    END IF;
    -- 0.18.0: cheque. Va solo en el cobro, a facturas (no anticipo, apartado ni excedente) y con sus datos.
    IF v_forma <> 'cheque' AND (pj ? 'numero_cheque' OR pj ? 'banco_emisor' OR pj ? 'fecha_cheque') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el número, el banco y la fecha del cheque solo van con la forma "cheque".';
    END IF;
    IF v_forma = 'cheque' THEN
      v_cheq := interno.datos_cheque(pj, jsonb_array_length(p_datos->'pagos'), p_apartado_id, v_tipo,
                                     coalesce(p_datos->>'excedente', '') = 'saldo_favor', p_empresa_id);
    END IF;
    v_monto := interno.json_centavos(pj->'monto_centavos', 'monto_centavos');
    IF v_monto = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada forma de pago lleva un monto mayor que cero ("monto_centavos").';
    END IF;
    v_rec := NULL;
    IF coalesce(pj->'recibido_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      IF v_forma <> 'efectivo' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "recibido_centavos" (para el vuelto) solo va en efectivo.';
      END IF;
      v_rec := interno.json_centavos(pj->'recibido_centavos', 'recibido_centavos');
      IF v_rec < v_monto THEN
        RAISE EXCEPTION 'DATO_INVALIDO: lo recibido (%) es menos que lo que se cobra en efectivo (%).', interno.lempiras(v_rec), interno.lempiras(v_monto);
      END IF;
    END IF;
    IF v_forma IN ('efectivo', 'saldo_favor', 'cheque') AND coalesce(pj->'cuenta_dinero_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: en % no se indica cuenta de dinero.', v_forma;
    END IF;
    IF v_forma <> 'saldo_favor' AND pj ? 'vale' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "vale" solo va con la forma saldo_favor.';
    END IF;
    IF v_forma = 'saldo_favor' THEN
      v_sfav := v_sfav + v_monto;
    ELSE
      v_dinero := v_dinero + v_monto;
    END IF;
    v_total := v_total + v_monto;
    v_norm := v_norm || jsonb_build_object('linea', k, 'forma', v_forma, 'monto', v_monto, 'recibido', v_rec,
      'cuenta', interno.json_uuid(pj->'cuenta_dinero_id', 'cuenta_dinero_id'),
      'referencia', interno.json_texto(pj->'referencia', 'referencia', 100), 'vale', interno.json_texto(pj->'vale', 'vale', 20));
  END LOOP;
  IF v_dinero > 0 AND NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa (el cobro entra a una cuenta de dinero).';
  END IF;
  IF v_tipo = 'anticipo' AND v_sfav > 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un anticipo no se paga con saldo a favor (ya es saldo a favor).';
  END IF;
  IF v_tipo = 'anticipo' AND p_datos ? 'aplicar' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un anticipo no se aplica a facturas; todo queda como saldo a favor del cliente.';
  END IF;

  -- Candado, reintento.
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'cobro');
  SELECT * INTO c FROM public.cobro x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF c.id IS NOT NULL THEN
    RETURN interno.cobro_respuesta(c, true);
  END IF;

  -- A qué se aplica (con el candado: los saldos no cambian por debajo).
  IF v_tipo = 'apartado' THEN
    IF v_total > p_apartado_saldo THEN
      RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: el abono (%) pasa lo que falta pagar del apartado (%).', interno.lempiras(v_total), interno.lempiras(p_apartado_saldo);
    END IF;
    v_aplic := v_total;
  ELSIF v_tipo = 'cxc' THEN
    IF coalesce(p_datos->'aplicar', 'null'::jsonb) <> 'null'::jsonb THEN
      IF jsonb_typeof(p_datos->'aplicar') <> 'array' OR jsonb_array_length(p_datos->'aplicar') = 0 THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "aplicar" es una lista [{"venta_id" o "saldo_inicial_id", "monto_centavos"}].';
      END IF;
      FOR a IN SELECT * FROM jsonb_array_elements(p_datos->'aplicar') LOOP
        PERFORM interno.exigir_claves(a, ARRAY['venta_id', 'saldo_inicial_id', 'monto_centavos']);
        v_doc := coalesce(interno.json_uuid(a->'venta_id', 'venta_id'), interno.json_uuid(a->'saldo_inicial_id', 'saldo_inicial_id'));
        IF v_doc IS NULL OR (a ? 'venta_id' AND a ? 'saldo_inicial_id') THEN
          RAISE EXCEPTION 'DATO_INVALIDO: cada aplicación lleva "venta_id" o "saldo_inicial_id" (uno solo).';
        END IF;
        IF v_apl @> jsonb_build_array(jsonb_build_object('doc', v_doc)) THEN
          RAISE EXCEPTION 'DATO_INVALIDO: la misma factura viene dos veces en "aplicar".';
        END IF;
        v_monto := interno.json_centavos(a->'monto_centavos', 'monto_centavos');
        IF v_monto = 0 THEN
          RAISE EXCEPTION 'DATO_INVALIDO: cada aplicación lleva un monto mayor que cero.';
        END IF;
        v_esvta := a ? 'venta_id';
        IF v_esvta THEN
          PERFORM 1 FROM public.venta x WHERE x.id = v_doc AND x.empresa_id = p_empresa_id AND x.cliente_id = v_cli.id
             AND x.estado = 'emitida' AND x.credito_centavos > 0 FOR UPDATE;
        ELSE
          PERFORM 1 FROM public.cxc_saldo_inicial x WHERE x.id = v_doc AND x.empresa_id = p_empresa_id AND x.cliente_id = v_cli.id
             AND x.anulada_en IS NULL FOR UPDATE;
        END IF;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'DATO_INVALIDO: la factura indicada no es una cuenta por cobrar vigente de este cliente.';
        END IF;
        v_saldo := interno.saldo_documento_cxc(v_doc);
        IF v_monto > v_saldo THEN
          RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: a esa factura se le quieren aplicar % y su saldo es %.', interno.lempiras(v_monto), interno.lempiras(v_saldo);
        END IF;
        v_apl := v_apl || jsonb_build_object('doc', v_doc, 'es_venta', v_esvta, 'monto', v_monto);
        v_aplic := v_aplic + v_monto;
      END LOOP;
      IF v_aplic > v_total THEN
        RAISE EXCEPTION 'DATO_INVALIDO: lo aplicado a facturas (%) pasa lo recibido (%).', interno.lempiras(v_aplic), interno.lempiras(v_total);
      END IF;
    ELSE
      -- La más vieja primero (fecha de la factura, vencimiento, número).
      v_resto := v_total;
      FOR r IN SELECT x.doc, x.es_venta FROM (
                 SELECT v.id AS doc, true AS es_venta, v.fecha_contable AS f, v.vence_el AS ve, v.numero AS n
                   FROM public.venta v
                  WHERE v.empresa_id = p_empresa_id AND v.cliente_id = v_cli.id AND v.estado = 'emitida' AND v.credito_centavos > 0
                 UNION ALL
                 SELECT s.id, false, s.fecha_documento, s.fecha_vencimiento, s.numero
                   FROM public.cxc_saldo_inicial s
                  WHERE s.empresa_id = p_empresa_id AND s.cliente_id = v_cli.id AND s.anulada_en IS NULL) x
               ORDER BY x.f, x.ve, NOT x.es_venta, x.n LOOP
        EXIT WHEN v_resto = 0;
        IF r.es_venta THEN
          PERFORM 1 FROM public.venta x WHERE x.id = r.doc FOR UPDATE;
        ELSE
          PERFORM 1 FROM public.cxc_saldo_inicial x WHERE x.id = r.doc FOR UPDATE;
        END IF;
        v_saldo := interno.saldo_documento_cxc(r.doc);
        CONTINUE WHEN v_saldo <= 0;
        v_monto := least(v_saldo, v_resto);
        v_apl := v_apl || jsonb_build_object('doc', r.doc, 'es_venta', r.es_venta, 'monto', v_monto);
        v_aplic := v_aplic + v_monto;
        v_resto := v_resto - v_monto;
      END LOOP;
    END IF;
  END IF;
  v_exc := v_total - v_aplic;
  IF v_exc > 0 THEN
    IF coalesce(p_datos->>'excedente', '') <> 'saldo_favor' AND v_tipo <> 'anticipo' THEN
      RAISE EXCEPTION 'COBRO_EXCEDE_SALDO: se reciben % y el cliente debe % en lo indicado (excedente %). Cobre solo el saldo o indique "excedente": "saldo_favor" para dejarlo a favor del cliente.',
        interno.lempiras(v_total), interno.lempiras(v_aplic), interno.lempiras(v_exc);
    END IF;
    IF v_sfav > 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el excedente no puede venir de un saldo a favor; use menos saldo a favor.';
    END IF;
  END IF;

  -- Guardar.
  c.id := gen_random_uuid();
  -- Caja: la indicada o la del turno abierto del usuario.
  IF v_caja IS NULL THEN
    SELECT t.caja_id INTO v_caja FROM public.turno_caja t
     WHERE t.empresa_id = p_empresa_id AND t.cajero_id = auth.uid() AND t.estado = 'abierto';
  END IF;
  IF v_caja IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.caja x WHERE x.id = v_caja AND x.empresa_id = p_empresa_id) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja no existe en esta empresa.';
  END IF;
  SELECT x.sucursal_id INTO v_suc FROM public.caja x WHERE x.id = v_caja;

  -- Pagos (las cuentas de dinero se pueden crear la primera vez, con el candado).
  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    d := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(p_empresa_id, v_caja);
      IF v_caja IS NULL THEN
        v_caja := d.caja_id;
        SELECT x.sucursal_id INTO v_suc FROM public.caja x WHERE x.id = v_caja;
      END IF;
    ELSIF pj->>'forma' IN ('tarjeta', 'transferencia') THEN
      d := interno.cuenta_cobro_venta(p_empresa_id, pj->>'forma', (pj->>'cuenta')::uuid);
    ELSIF pj->>'forma' = 'cheque' THEN
      d := interno.cuenta_cheques(p_empresa_id);
    END IF;
    IF d.id IS NOT NULL THEN
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'debe', (pj->>'monto')::bigint,
                                           'descripcion', 'Cobro a ' || v_cli.nombre || ' (' || (pj->>'forma') || ')');
    ELSE
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'debe', (pj->>'monto')::bigint,
                                           'descripcion', 'Cobro con saldo a favor de ' || v_cli.nombre);
    END IF;
    pj := pj || jsonb_build_object('cuenta_id', d.id);
    v_norm := jsonb_set(v_norm, ARRAY[((pj->>'linea')::integer - 1)::text], pj);
  END LOOP;

  v_lin := v_lin || jsonb_build_object('uso', CASE v_tipo WHEN 'apartado' THEN 'anticipo_clientes' ELSE 'cxc' END,
                                       'haber', v_aplic,
                                       'descripcion', CASE v_tipo WHEN 'apartado' THEN 'Anticipo de apartado de ' ELSE 'Cobro a ' END || v_cli.nombre)
                 || jsonb_build_object('uso', 'saldo_favor', 'haber', v_exc,
                                       'descripcion', 'Saldo a favor de ' || v_cli.nombre);
  c.numero := interno.siguiente_numero(p_empresa_id, 'cobro');
  v_asto := interno.asiento_sistema(p_empresa_id, interno.sucursal_activa(v_suc), v_fecha,
    CASE v_tipo WHEN 'cxc' THEN 'Cobro #' || c.numero || ' a ' || v_cli.nombre
                WHEN 'anticipo' THEN 'Anticipo #' || c.numero || ' de ' || v_cli.nombre || ' (saldo a favor)'
                ELSE 'Abono #' || c.numero || ' a apartado de ' || v_cli.nombre END
      || coalesce(' ref. ' || interno.json_texto(p_datos->'referencia', 'referencia', 100), ''),
    'cobro', p_id_operacion, v_lin);

  -- El excedente es un lote de saldo a favor del cliente (documento = este cobro).
  IF v_exc > 0 THEN
    f := interno.crear_saldo_favor(p_empresa_id, v_cli.id, CASE WHEN v_tipo = 'anticipo' THEN 'anticipo' ELSE 'excedente_cobro' END,
                                   'cobro', c.id, v_exc, v_fecha);
  END IF;
  INSERT INTO public.cobro (id, empresa_id, numero, tipo, cliente_id, apartado_id, caja_id, sucursal_id, fecha_contable,
    monto_centavos, aplicado_centavos, excedente_centavos, saldo_favor_id, referencia, nota, equipo, asiento_id, id_operacion, creado_por)
  VALUES (c.id, p_empresa_id, c.numero, v_tipo, v_cli.id, p_apartado_id, v_caja, v_suc, v_fecha, v_total, v_aplic, v_exc, f.id,
    interno.json_texto(p_datos->'referencia', 'referencia', 100), interno.json_texto(p_datos->'nota', 'nota', 500),
    interno.equipo(p_datos), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO c;

  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    INSERT INTO public.cobro_pago (empresa_id, cobro_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos, estado_transferencia)
    VALUES (p_empresa_id, c.id, (pj->>'linea')::smallint, pj->>'forma', (pj->>'monto')::bigint, (pj->>'cuenta_id')::uuid,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta((pj->>'cuenta_id')::uuid) END, pj->>'referencia',
            (pj->>'recibido')::bigint, (pj->>'recibido')::bigint - (pj->>'monto')::bigint,
            CASE WHEN pj->>'forma' = 'transferencia' THEN 'por_confirmar' END);
    IF pj->>'forma' = 'saldo_favor' THEN
      v_usos := interno.usar_saldo_favor(p_empresa_id, v_cli.id, pj->>'vale', (pj->>'monto')::bigint, 'cobro', c.id, v_fecha);
    ELSIF pj->>'forma' = 'cheque' THEN
      INSERT INTO public.cheque_recibido (empresa_id, numero, cobro_id, cliente_id, cliente_nombre, sucursal_id, numero_cheque, banco_emisor,
                                          fecha_cheque, fecha_recibido, monto_centavos, cuenta_dinero_id, creado_por)
      VALUES (p_empresa_id, interno.siguiente_numero(p_empresa_id, 'cheque_recibido'), c.id, v_cli.id, v_cli.nombre, v_suc,
              v_cheq->>'numero_cheque', v_cheq->>'banco_emisor', (v_cheq->>'fecha_cheque')::date, v_fecha, (pj->>'monto')::bigint,
              (pj->>'cuenta_id')::uuid, auth.uid());
    END IF;
  END LOOP;

  FOR a IN SELECT * FROM jsonb_array_elements(v_apl) LOOP
    INSERT INTO public.cxc_aplicacion (empresa_id, cliente_id, venta_id, saldo_inicial_id, origen, origen_id, monto_centavos,
                                       fecha_contable, creado_por)
    VALUES (p_empresa_id, v_cli.id, CASE WHEN (a->>'es_venta')::boolean THEN (a->>'doc')::uuid END,
            CASE WHEN NOT (a->>'es_venta')::boolean THEN (a->>'doc')::uuid END, 'cobro', c.id, (a->>'monto')::bigint, v_fecha, auth.uid());
  END LOOP;

  PERFORM interno.rastrear_dinero(v_asto, 'cobro', 'cobro', c.id,
    coalesce(interno.json_texto(p_datos->'referencia', 'referencia', 100), 'Cobro #' || c.numero), interno.equipo(p_datos));
  FOR a IN SELECT * FROM jsonb_array_elements(v_apl) LOOP
    IF (a->>'es_venta')::boolean THEN
      PERFORM interno.recalcular_comision((a->>'doc')::uuid, p_id_operacion, v_fecha);
    END IF;
  END LOOP;
  RETURN interno.cobro_respuesta(c, false);
END $$;

-- Anular un cobro con cheque (reemplaza la de 034; misma firma): solo mientras el cheque sigue
-- "por depositar" (el valor está en esa cuenta). Depositado: se usa registrar_cheque_rechazado.
CREATE OR REPLACE FUNCTION interno.validar_anulacion_cobro(c public.cobro) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_est text;
BEGIN
  IF c.tipo = 'apartado' THEN
    SELECT a.estado INTO v_est FROM public.apartado a WHERE a.id = c.apartado_id FOR UPDATE;
    IF v_est <> 'vigente' THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el apartado de este anticipo ya está %; el anticipo ya se aplicó.', v_est;
    END IF;
  END IF;
  SELECT ch.estado INTO v_est FROM public.cheque_recibido ch WHERE ch.cobro_id = c.id FOR UPDATE;
  IF v_est IS NOT NULL AND v_est <> 'por_depositar' THEN
    RAISE EXCEPTION 'CHEQUE_DEPOSITADO: el cheque de este cobro está "%"; si el banco lo devolvió, regístrelo como cheque rechazado.', v_est;
  END IF;
END $$;

-- Al anular el cobro: su cheque queda "anulado" (salvo que lo anule registrar_cheque_rechazado).
CREATE FUNCTION interno.cheque_de_cobro_anulado() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  -- (registrar_cheque_rechazado lo marca él mismo, con sus datos)
  UPDATE public.cheque_recibido SET estado = 'anulado'
   WHERE cobro_id = NEW.id AND estado = 'por_depositar' AND coalesce(current_setting('app.cheque_rechazo', true), '') <> NEW.id::text;
  RETURN NEW;
END $$;
CREATE TRIGGER cheque AFTER UPDATE OF anulada_en ON public.cobro FOR EACH ROW
  WHEN (OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL) EXECUTE FUNCTION interno.cheque_de_cobro_anulado();

-- Si se anula el depósito de un cheque (todavía en tránsito), el cheque vuelve a "por depositar".
CREATE FUNCTION interno.cheque_deposito_anulado() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.cheque_recibido SET estado = 'por_depositar', operacion_deposito_id = NULL, banco_id = NULL, fecha_deposito = NULL
   WHERE operacion_deposito_id = NEW.id AND estado = 'depositado';
  RETURN NEW;
END $$;
CREATE TRIGGER cheque AFTER UPDATE OF anulada_en ON public.operacion_dinero FOR EACH ROW
  WHEN (OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL) EXECUTE FUNCTION interno.cheque_deposito_anulado();

CREATE FUNCTION interno.cheque_respuesta(ch public.cheque_recibido, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('cheque_id', ch.id, 'numero', ch.numero, 'estado', ch.estado, 'cobro_id', ch.cobro_id,
    'numero_cheque', ch.numero_cheque, 'banco_emisor', ch.banco_emisor, 'fecha_cheque', to_char(ch.fecha_cheque, 'YYYY-MM-DD'),
    'monto_centavos', ch.monto_centavos, 'operacion_deposito_id', ch.operacion_deposito_id, 'banco_id', ch.banco_id,
    'fecha_deposito', to_char(ch.fecha_deposito, 'YYYY-MM-DD'), 'motivo_rechazo', ch.motivo_rechazo, 'duplicado', p_duplicado)
$$;

-- depositar_cheque(cheque, banco, fecha?, referencia?, id_operacion)   dinero.trasladar
-- Un depósito de siempre (operacion_dinero "deposito"): Dr Depósitos en tránsito / Cr Cheques por depositar,
-- en tránsito hasta confirmar_deposito (Dr banco / Cr tránsito). Un cheque posfechado se deposita desde su fecha.
CREATE FUNCTION public.depositar_cheque(p_cheque_id uuid, p_banco_id uuid, p_fecha date, p_referencia text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  ch      public.cheque_recibido;
  o       public.cuenta_dinero;
  b       public.cuenta_dinero;
  t       public.cuenta_dinero;
  v_op    public.operacion_dinero;
  v_fecha date;
BEGIN
  SELECT * INTO ch FROM public.cheque_recibido WHERE id = p_cheque_id;
  IF ch.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cheque no existe.';
  END IF;
  PERFORM interno.exigir_escritura(ch.empresa_id, 'dinero.trasladar', 'dinero');
  PERFORM interno.exigir_sucursal(ch.empresa_id, ch.sucursal_id);
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(ch.empresa_id, p_id_operacion, 'dinero_deposito');
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = ch.empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    RETURN interno.cheque_respuesta(ch, true) || jsonb_build_object('deposito', interno.operacion_dinero_respuesta(v_op, true));
  END IF;
  b := interno.cuenta_dinero_de(ch.empresa_id, p_banco_id);
  IF b.tipo <> 'banco' OR NOT b.activa THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: un cheque se deposita en una cuenta de banco activa.';
  END IF;
  PERFORM interno.exigir_sucursal(ch.empresa_id, b.sucursal_id);
  v_fecha := coalesce(p_fecha, public.hoy_local(ch.empresa_id));
  PERFORM interno.exigir_fecha_contable(ch.empresa_id, v_fecha);
  IF v_fecha < ch.fecha_cheque THEN
    RAISE EXCEPTION 'CHEQUE_POSFECHADO: el cheque #% es del % y no se puede depositar antes.', ch.numero_cheque, to_char(ch.fecha_cheque, 'DD/MM/YYYY');
  END IF;
  IF v_fecha < ch.fecha_recibido THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el depósito no puede tener fecha anterior al cobro (%).', to_char(ch.fecha_recibido, 'DD/MM/YYYY');
  END IF;
  IF length(trim(coalesce(p_referencia, ''))) > 100 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la referencia es demasiado larga (máximo 100 letras).';
  END IF;

  PERFORM interno.reservar_operacion(ch.empresa_id, p_id_operacion, 'dinero_deposito');
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = ch.empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    SELECT * INTO ch FROM public.cheque_recibido WHERE id = p_cheque_id;
    RETURN interno.cheque_respuesta(ch, true) || jsonb_build_object('deposito', interno.operacion_dinero_respuesta(v_op, true));
  END IF;
  SELECT * INTO ch FROM public.cheque_recibido WHERE id = p_cheque_id FOR UPDATE;
  IF ch.estado <> 'por_depositar' THEN
    RAISE EXCEPTION 'CHEQUE_DEPOSITADO: el cheque #% ya está "%".', ch.numero_cheque, ch.estado;
  END IF;
  PERFORM interno.exigir_periodo_abierto(ch.empresa_id, v_fecha);
  o := interno.cuenta_dinero_de(ch.empresa_id, ch.cuenta_dinero_id);
  t := interno.cuenta_transito(ch.empresa_id, NULL);
  v_op := interno.guardar_operacion_dinero(ch.empresa_id, 'deposito', o, b, t, NULL, ch.monto_centavos, v_fecha,
    coalesce(nullif(trim(p_referencia), ''), 'Cheque ' || ch.numero_cheque), 'Cheque #' || ch.numero_cheque || ' de ' || ch.banco_emisor
      || ' (' || ch.cliente_nombre || ')', NULL, NULL,
    'Depósito #N del cheque ' || ch.numero_cheque || ' de ' || ch.cliente_nombre || ' a ' || b.nombre || ' (en tránsito)',
    jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = t.cuenta_id), 'debe', ch.monto_centavos),
                      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = o.cuenta_id), 'haber', ch.monto_centavos)),
    p_id_operacion);
  UPDATE public.cheque_recibido SET estado = 'depositado', operacion_deposito_id = v_op.id, banco_id = b.id, fecha_deposito = v_fecha
   WHERE id = ch.id RETURNING * INTO ch;
  RETURN interno.cheque_respuesta(ch, false) || jsonb_build_object('deposito', interno.operacion_dinero_respuesta(v_op, false));
END $$;

-- registrar_cheque_rechazado(cheque, datos, id_operacion)   cobros.anular
-- datos = {"motivo", "fecha"?, "cargo_banco"?: {"categoria_id", "monto_centavos", "cuenta_dinero_id"? (el banco del depósito)}}
-- 1) El valor vuelve a "Cheques por depositar": si el depósito sigue en tránsito, se anula ese depósito; si ya
--    se confirmó, el banco lo devuelve (Dr Cheques por depositar / Cr banco, operación "traslado").
-- 2) Se anula el cobro (anular_cobro de siempre): Dr Clientes / Cr Cheques por depositar; las facturas
--    recuperan su saldo y las comisiones se ajustan. El cliente vuelve a deber.
-- 3) Opcional: el cargo del banco como gasto (registrar_gasto, pide gastos.registrar).
-- Todo junto o nada; reintento con el mismo id_operacion = la misma respuesta.
CREATE FUNCTION public.registrar_cheque_rechazado(p_cheque_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  ch      public.cheque_recibido;
  od      public.operacion_dinero;
  o       public.cuenta_dinero;
  b       public.cuenta_dinero;
  v_mot   text;
  v_fecha date;
  v_cargo jsonb;
  v_gas   jsonb;
  r       jsonb;
BEGIN
  SELECT * INTO ch FROM public.cheque_recibido WHERE id = p_cheque_id;
  IF ch.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cheque no existe.';
  END IF;
  PERFORM interno.exigir_escritura(ch.empresa_id, 'cobros.anular', 'ventas');
  PERFORM interno.exigir_sucursal(ch.empresa_id, ch.sucursal_id);
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(ch.empresa_id, p_id_operacion, 'rechazo_cheque');
  IF ch.rechazo_id_operacion = p_id_operacion THEN
    RETURN interno.cheque_respuesta(ch, true);
  END IF;
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['motivo', 'fecha', 'cargo_banco']);
  v_mot := interno.json_texto(p_datos->'motivo', 'motivo', 300);
  IF length(coalesce(v_mot, '')) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué rebotó el cheque (mínimo 5 letras), ej. "fondos insuficientes".';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), greatest(public.hoy_local(ch.empresa_id), ch.fecha_recibido));
  v_cargo := CASE WHEN coalesce(p_datos->'cargo_banco', 'null'::jsonb) <> 'null'::jsonb THEN p_datos->'cargo_banco' END;
  IF v_cargo IS NOT NULL THEN
    PERFORM interno.exigir_claves(v_cargo, ARRAY['categoria_id', 'monto_centavos', 'cuenta_dinero_id']);
  END IF;

  PERFORM interno.reservar_operacion(ch.empresa_id, p_id_operacion, 'rechazo_cheque');
  SELECT * INTO ch FROM public.cheque_recibido WHERE id = p_cheque_id FOR UPDATE;
  IF ch.rechazo_id_operacion = p_id_operacion THEN
    RETURN interno.cheque_respuesta(ch, true);
  END IF;
  IF ch.estado NOT IN ('por_depositar', 'depositado') THEN
    RAISE EXCEPTION 'CHEQUE_INVALIDO: el cheque #% ya está "%".', ch.numero_cheque, ch.estado;
  END IF;
  b := CASE WHEN ch.banco_id IS NOT NULL THEN interno.cuenta_dinero_de(ch.empresa_id, ch.banco_id) END;

  -- 1) El valor vuelve a "Cheques por depositar".
  IF ch.estado = 'depositado' THEN
    SELECT * INTO od FROM public.operacion_dinero WHERE id = ch.operacion_deposito_id FOR UPDATE;
    IF od.estado = 'en_transito' THEN
      PERFORM public.anular_operacion_dinero(od.id, 'Cheque rechazado: ' || v_mot, md5(p_id_operacion::text || ':anula_deposito')::uuid, v_fecha);
    ELSE
      o := interno.cuenta_dinero_de(ch.empresa_id, ch.cuenta_dinero_id);
      PERFORM interno.exigir_fecha_contable(ch.empresa_id, v_fecha);
      PERFORM interno.exigir_periodo_abierto(ch.empresa_id, v_fecha);
      PERFORM interno.guardar_operacion_dinero(ch.empresa_id, 'traslado', b, o, NULL, NULL, ch.monto_centavos, v_fecha,
        'Cheque ' || ch.numero_cheque || ' rechazado', v_mot, NULL, NULL,
        'Cheque ' || ch.numero_cheque || ' de ' || ch.cliente_nombre || ' devuelto por ' || b.nombre || ' (#N)',
        jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = o.cuenta_id), 'debe', ch.monto_centavos),
                          jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = b.cuenta_id), 'haber', ch.monto_centavos)),
        md5(p_id_operacion::text || ':devuelve_banco')::uuid);
    END IF;
    UPDATE public.cheque_recibido SET estado = 'por_depositar', operacion_deposito_id = NULL WHERE id = ch.id;
  END IF;

  -- 2) Se anula el cobro: el cliente vuelve a deber.
  PERFORM set_config('app.cheque_rechazo', ch.cobro_id::text, true);
  r := public.anular_cobro(ch.cobro_id, 'Cheque ' || ch.numero_cheque || ' rechazado: ' || v_mot,
                           md5(p_id_operacion::text || ':anula_cobro')::uuid, v_fecha);
  PERFORM set_config('app.cheque_rechazo', '', true);

  -- 3) Cargo del banco como gasto (opcional).
  IF v_cargo IS NOT NULL THEN
    v_gas := public.registrar_gasto(ch.empresa_id, jsonb_build_object(
      'cuenta_dinero_id', coalesce(v_cargo->'cuenta_dinero_id', to_jsonb(b.id)), 'categoria_id', v_cargo->'categoria_id',
      'monto_centavos', v_cargo->'monto_centavos', 'fecha', v_fecha,
      'descripcion', 'Cargo del banco por el cheque ' || ch.numero_cheque || ' rechazado (' || ch.cliente_nombre || ')'),
      md5(p_id_operacion::text || ':cargo_banco')::uuid);
  END IF;
  PERFORM set_config('app.motivo', v_mot, true);
  UPDATE public.cheque_recibido SET estado = 'rechazado', motivo_rechazo = v_mot, fecha_rechazo = v_fecha, banco_id = coalesce(banco_id, b.id),
         cargo_banco_gasto_id = (v_gas->>'gasto_id')::uuid, rechazo_id_operacion = p_id_operacion,
         rechazado_por = auth.uid(), rechazado_en = now()
   WHERE id = ch.id RETURNING * INTO ch;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.cheque_respuesta(ch, false) || jsonb_strip_nulls(jsonb_build_object('cobro', r, 'gasto', v_gas));
END $$;

-- El dinero de "Cheques por depositar" solo se mueve cheque por cheque (depositar_cheque / rebote).
ALTER FUNCTION public.trasladar_dinero(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.trasladar_dinero(uuid, jsonb, uuid) RENAME TO trasladar_dinero_022;
CREATE FUNCTION public.trasladar_dinero(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF jsonb_typeof(p_datos) = 'object' AND EXISTS (SELECT 1 FROM public.cuenta_dinero d
       WHERE d.empresa_id = p_empresa_id AND d.tipo = 'cheques_por_depositar'
         AND d.id::text IN (p_datos->>'origen_id', p_datos->>'destino_id')) THEN
    PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.trasladar', 'dinero');
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: los cheques por depositar se mueven uno por uno: "Depositar" (depositar_cheque) o "Rebotó".';
  END IF;
  RETURN interno.trasladar_dinero_022(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- ¿Dónde está mi dinero? (la de 052 pasa a interno sin cambios): además "cheques_por_depositar" con
-- cada cheque (los que el usuario puede ver), su fecha y si ya se puede depositar.
ALTER FUNCTION public.donde_esta_mi_dinero(uuid) SET SCHEMA interno;
ALTER FUNCTION interno.donde_esta_mi_dinero(uuid) RENAME TO donde_esta_mi_dinero_052;
CREATE FUNCTION public.donde_esta_mi_dinero(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      jsonb := interno.donde_esta_mi_dinero_052(p_empresa_id);
  v_restr boolean := interno.usuario_restringido(p_empresa_id);
  v_hoy  date := public.hoy_local(p_empresa_id);
BEGIN
  RETURN r || jsonb_build_object('cheques_por_depositar', (SELECT jsonb_build_object(
      'total_centavos', coalesce(sum(ch.monto_centavos), 0), 'cantidad', count(*),
      'posfechados_centavos', coalesce(sum(ch.monto_centavos) FILTER (WHERE ch.fecha_cheque > v_hoy), 0),
      'cheques', coalesce(jsonb_agg(jsonb_build_object('cheque_id', ch.id, 'numero_cheque', ch.numero_cheque, 'banco_emisor', ch.banco_emisor,
         'cliente', ch.cliente_nombre, 'fecha_cheque', to_char(ch.fecha_cheque, 'YYYY-MM-DD'), 'monto_centavos', ch.monto_centavos,
         'se_puede_depositar', ch.fecha_cheque <= v_hoy) ORDER BY ch.fecha_cheque, ch.numero), '[]'))
    FROM public.cheque_recibido ch
   WHERE ch.empresa_id = p_empresa_id AND ch.estado = 'por_depositar'
     AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, ch.sucursal_id))));
END $$;

-- Proyección (la de 052 pasa a interno sin cambios): los cheques por depositar entran en la semana de su fecha
-- (los de hoy o antes, en la semana 1). La cuenta "Cheques por depositar" nunca cuenta como disponible.
ALTER FUNCTION public.proyeccion_flujo(uuid, integer, text) SET SCHEMA interno;
ALTER FUNCTION interno.proyeccion_flujo(uuid, integer, text) RENAME TO proyeccion_flujo_052;
CREATE FUNCTION public.proyeccion_flujo(p_empresa_id uuid, p_dias integer DEFAULT 30, p_agrupar text DEFAULT 'semana') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r       jsonb := interno.proyeccion_flujo_052(p_empresa_id, p_dias, p_agrupar);
  v_hoy   date;
  v_hasta date;
  v_restr boolean := interno.usuario_restringido(p_empresa_id);
  v_ch    jsonb;
  v_sem   jsonb := '[]';
  s       jsonb;
  v_acum  bigint := 0;
  v_mas   bigint;
  v_alert jsonb := '[]';
  i       integer;
BEGIN
  v_hoy := (r->>'desde')::date;
  v_hasta := (r->>'hasta')::date;
  SELECT coalesce(jsonb_agg(jsonb_build_object('semana', least(greatest((ch.fecha_cheque - v_hoy) / 7 + 1, 1), jsonb_array_length(r->'semanas')),
           'tipo', 'cheque', 'monto', ch.monto_centavos, 'fecha', to_char(greatest(ch.fecha_cheque, v_hoy), 'YYYY-MM-DD'),
           'detalle', 'Cheque ' || ch.numero_cheque || ' de ' || ch.cliente_nombre || ' (' || ch.banco_emisor || ')')
           ORDER BY ch.fecha_cheque, ch.numero), '[]')
    INTO v_ch
    FROM public.cheque_recibido ch
   WHERE ch.empresa_id = p_empresa_id AND ch.estado = 'por_depositar' AND ch.fecha_cheque <= v_hasta
     AND (NOT v_restr OR interno.sucursal_permitida(p_empresa_id, ch.sucursal_id));
  i := 0;
  FOR s IN SELECT x FROM jsonb_array_elements(r->'semanas') x LOOP
    i := i + 1;
    v_mas := coalesce((SELECT sum((m->>'monto')::bigint) FROM jsonb_array_elements(v_ch) m WHERE (m->>'semana')::integer = i), 0);
    s := s || jsonb_build_object('cheques_centavos', v_mas,
      'saldo_inicial_centavos', (s->>'saldo_inicial_centavos')::bigint + v_acum,
      'entradas_centavos', (s->>'entradas_centavos')::bigint + v_mas);
    v_acum := v_acum + v_mas;
    s := s || jsonb_build_object('saldo_final_centavos', (s->>'saldo_final_centavos')::bigint + v_acum,
                                 'negativo', (s->>'saldo_final_centavos')::bigint + v_acum < 0);
    IF (s->>'negativo')::boolean THEN
      v_alert := v_alert || jsonb_build_object('semana', i, 'saldo_final_centavos', (s->>'saldo_final_centavos')::bigint,
        'mensaje', 'En la semana ' || i || ' (desde el ' || to_char((s->>'desde')::date, 'DD/MM/YYYY') || ') el dinero proyectado queda en '
                   || interno.lempiras((s->>'saldo_final_centavos')::bigint) || '. Busque cobrar antes o mover pagos.');
    END IF;
    v_sem := v_sem || jsonb_build_array(s);
  END LOOP;
  RETURN r || jsonb_build_object('semanas', v_sem, 'saldo_final_proyectado_centavos', (r->>'saldo_final_proyectado_centavos')::bigint + v_acum,
    'cheques_por_depositar_centavos', v_acum, 'alerta', jsonb_array_length(v_alert) > 0, 'alertas', v_alert,
    'detalle', (SELECT coalesce(jsonb_agg(m ORDER BY (m->>'semana')::integer, m->>'fecha', m->>'tipo'), '[]')
                  FROM jsonb_array_elements((r->'detalle') || v_ch) m),
    'nota', (r->>'nota') || ' Los cheques por depositar entran en la semana de su fecha.');
END $$;

REVOKE EXECUTE ON FUNCTION
  interno.proteger_cheque(), interno.cuenta_cheques(uuid), interno.datos_cheque(jsonb, integer, uuid, text, boolean, uuid),
  interno.cheque_de_cobro_anulado(), interno.cheque_deposito_anulado(), interno.cheque_respuesta(public.cheque_recibido, boolean),
  interno.trasladar_dinero_022(uuid, jsonb, uuid), interno.donde_esta_mi_dinero_052(uuid), interno.proyeccion_flujo_052(uuid, integer, text)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.depositar_cheque(uuid, uuid, date, text, uuid), public.registrar_cheque_rechazado(uuid, jsonb, uuid),
  public.trasladar_dinero(uuid, jsonb, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.depositar_cheque(uuid, uuid, date, text, uuid), public.registrar_cheque_rechazado(uuid, jsonb, uuid),
  public.trasladar_dinero(uuid, jsonb, uuid)
TO authenticated;
-- Lecturas: como antes (también service_role).
REVOKE EXECUTE ON FUNCTION public.donde_esta_mi_dinero(uuid), public.proyeccion_flujo(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.donde_esta_mi_dinero(uuid), public.proyeccion_flujo(uuid, integer, text) TO authenticated, service_role;
