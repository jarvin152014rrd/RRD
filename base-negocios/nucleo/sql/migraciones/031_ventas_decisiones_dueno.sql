-- =====================================================================
-- 031_ventas_decisiones_dueno.sql  -  Núcleo 0.8.0: decisiones del dueño
-- sobre ventas y ventas sin inventario.
--
--   PROMOCIONES: nunca descuento sobre descuento.
--     * Varias promociones vigentes para una línea: la venta NO elige sola;
--       quien vende elige una ("promocion_id" en la línea). Si no elige:
--       PROMOCION_A_ELEGIR con la lista. Una sola: se aplica sola.
--       promociones_aplicables(empresa, producto, fecha?, cantidad?) muestra
--       las que aplican para que la app las ofrezca.
--     * Una línea con promoción no admite descuento manual (DESCUENTO_DOBLE).
--     * El descuento de FACTURA solo se reparte entre las líneas SIN otro
--       descuento (sin promoción ni descuento manual); las demás quedan fuera.
--       Si ninguna línea queda libre: DESCUENTO_DOBLE.
--     => ninguna línea queda con más de un descuento.
--   VENDEDOR QUE COBRA: empresa.vendedor_cobra (false por defecto; solo el
--     dueño con configurar_empresa, motivo y bitácora; perfil pequeño = true).
--     Con true el vendedor recibe dinero como el cajero (mismas reglas de
--     turno: interno.cuenta_efectivo_cobro). Con false, como antes.
--   VENTAS SIN INVENTARIO: con "inventario" apagado (o nunca activado) la
--     venta solo acepta SERVICIOS; un bien da MODULO_INACTIVO. El catálogo se
--     edita con "ventas" (030, interno.modulo_alterno).
--   Confirmados por el dueño (sin cambios): topes de descuento (cajero y
--     vendedor 5 %; admin 10 % y aprueba hasta 20 %), el admin aprueba
--     créditos y anulaciones hasta L 5,000.00 y cotizaciones de 15 días
--     (configurables).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('PROMOCION_A_ELEGIR', 'Este producto tiene varias promociones y no se suman.',
   'Elija cuál promoción aplicar en esa línea (solo una).'),
  ('PROMOCION_INVALIDA', 'La promoción elegida no aplica a ese producto en esa fecha.',
   'Elija una de las promociones que muestra el sistema para ese producto.'),
  ('DESCUENTO_DOBLE', 'No se puede dar un descuento sobre otro descuento.',
   'Una línea con promoción no lleva descuento manual, y el descuento de factura solo va a las líneas sin otro descuento.');

-- ---------------------------------------------------------------------
-- 1) Vendedor que cobra (empresa y perfiles)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa ADD COLUMN vendedor_cobra boolean NOT NULL DEFAULT false;
ALTER TABLE interno.plantilla_perfil ADD COLUMN vendedor_cobra boolean NOT NULL DEFAULT false;
UPDATE interno.plantilla_perfil SET vendedor_cobra = true WHERE codigo = 'pequeno';

-- ¿El usuario puede recibir el dinero de una venta?
CREATE FUNCTION interno.puede_cobrar(p_empresa_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.tiene_permiso('ventas.cobrar', p_empresa_id)
      OR (public.mi_rol(p_empresa_id) = 'vendedor'
          AND coalesce((SELECT e.vendedor_cobra FROM public.empresa e WHERE e.id = p_empresa_id), false))
$$;

-- ---------------------------------------------------------------------
-- 2) Promociones que aplican a un producto (la venta y la app usan la misma)
-- ---------------------------------------------------------------------
-- [{"promocion_id","nombre","tipo","porcentaje","monto_centavos","descuento_centavos"}],
-- de la que más descuenta a la que menos. Descuento en los términos del precio.
CREATE FUNCTION interno.promociones_de(p_empresa_id uuid, p public.producto, p_fecha date, p_cantidad numeric) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
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
    FROM x
$$;

-- RPC: promociones_aplicables(empresa, producto, fecha?, cantidad?)   ventas.vender o ventas.cotizar
CREATE FUNCTION public.promociones_aplicables(p_empresa_id uuid, p_producto_id uuid, p_fecha date DEFAULT NULL,
                                              p_cantidad numeric DEFAULT 1)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE p public.producto;
BEGIN
  IF public.tiene_permiso('ventas.cotizar', p_empresa_id) THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.cotizar');
  ELSE
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.vender');
  END IF;
  SELECT * INTO p FROM public.producto x WHERE x.id = p_producto_id AND x.empresa_id = p_empresa_id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe.';
  END IF;
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cantidad debe ser mayor que cero.';
  END IF;
  RETURN jsonb_build_object('producto_id', p.id, 'fecha', to_char(coalesce(p_fecha, public.hoy_local(p_empresa_id)), 'YYYY-MM-DD'),
    'promociones', interno.promociones_de(p_empresa_id, p, coalesce(p_fecha, public.hoy_local(p_empresa_id)), p_cantidad));
END $$;

-- ---------------------------------------------------------------------
-- 3) Cálculo de la venta (reemplaza la de 028; misma firma). Nuevo: "promocion_id"
--    por línea y nunca descuento sobre descuento.
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
BEGIN
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad', 'descuento_porcentaje', 'descuento_centavos', 'promocion_id']);
  FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, true);
    imp := interno.impuesto_de(p_empresa_id, p.tipo_impuesto);
    q := interno.json_numero(l->'cantidad', 'cantidad', i);
    PERFORM interno.validar_cantidad(p, q, i);
    a_prod := a_prod || p.id;  a_nom := a_nom || p.nombre;  a_q := a_q || q;
    a_pre := a_pre || p.precio_venta_centavos;  a_inc := a_inc || p.precio_incluye_isv;  a_imp := a_imp || p.tipo_impuesto;
    a_tasa := a_tasa || imp.porcentaje;  a_clase := a_clase || imp.clase;  a_serv := a_serv || (p.tipo = 'servicio');
    a_cest := a_cest || CASE WHEN p.tipo = 'servicio' THEN
      (SELECT round(q * sc.costo_estimado_centavos)::bigint FROM public.servicio_costo sc WHERE sc.producto_id = p.id) END;
    a_bruto := a_bruto || round(q * p.precio_venta_centavos)::bigint;

    -- Promociones vigentes de su categoría (o de una categoría madre). NUNCA
    -- se suman: con una sola se aplica; con varias, quien vende elige una
    -- ("promocion_id"); si no elige, PROMOCION_A_ELEGIR con la lista.
    v_promos := interno.promociones_de(p_empresa_id, p, p_fecha, q);
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
                                  interno.lempiras((y->>'descuento_centavos')::bigint)), '; ') FROM jsonb_array_elements(v_promos) y);
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
    a_elig := a_elig || (v_pid IS NULL AND coalesce(v_pct, 0) = 0 AND coalesce(v_mto, 0) = 0);
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
        RAISE EXCEPTION 'DESCUENTO_DOBLE: todas las líneas ya tienen promoción o descuento; el descuento de factura no se suma sobre otro descuento.';
      END IF;
      FOR i IN 1..n LOOP
        a_dfac[i] := CASE WHEN a_elig[i] THEN round(a_v2[i] * v_fpct / 100)::bigint ELSE 0 END;
      END LOOP;
    ELSIF coalesce(p_desc_factura->'monto_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      v_fmto := interno.json_centavos(p_desc_factura->'monto_centavos', 'descuento_factura.monto_centavos');
      IF v_fmto > 0 AND v_tot_we = 0 THEN
        RAISE EXCEPTION 'DESCUENTO_DOBLE: todas las líneas ya tienen promoción o descuento; el descuento de factura no se suma sobre otro descuento.';
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
      'base_centavos', s3, 'impuesto_centavos', i3, 'total_centavos', c3);
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

-- ---------------------------------------------------------------------
-- 4) Registrar una venta (reemplaza la de 028; misma firma). Nuevo: sin
--    "inventario" solo servicios; el vendedor cobra si vendedor_cobra.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.registrar_venta_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_cotizacion_id uuid DEFAULT NULL, p_calculo jsonb DEFAULT NULL)
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
  v_ncred  integer := 0;
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

  -- Caja y fecha (la bodega, después del cálculo: solo si hay bienes).
  v_caja := interno.caja_de_venta(p_empresa_id, p_datos->'caja_id');
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  -- Documento: sin régimen fiscal activo, siempre ticket interno; con
  -- régimen (fiscal_hn), según lo que el dueño configuró.
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

  -- Cliente (opcional) y vendedor.
  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    SELECT * INTO v_cli FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_datos->'cliente_id', 'cliente_id') AND t.empresa_id = p_empresa_id;
    IF v_cli.id IS NULL OR NOT v_cli.es_cliente OR NOT v_cli.activo THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente no existe, no está marcado como cliente o está desactivado.';
    END IF;
  END IF;
  v_vend := coalesce(interno.json_uuid(p_datos->'vendedor_id', 'vendedor_id'), auth.uid());
  IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = v_vend
                   AND ue.activo AND ue.rol NOT IN ('proveedor', 'contador')) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el vendedor no es un usuario activo de la empresa.';
  END IF;

  -- Cálculo (o el de la cotización con precios respetados).
  v_calc := coalesce(p_calculo, interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura'));
  v_total := (v_calc->>'total_centavos')::bigint;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el total de la venta debe ser mayor que cero.';
  END IF;
  -- Sin el módulo "inventario" solo se venden servicios (los bienes llevan kardex).
  IF coalesce((v_calc->>'tiene_bienes')::boolean, true) AND NOT public.modulo_esta_activo(p_empresa_id, 'inventario') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo: esta venta solo puede llevar servicios (quite los productos que son bienes).';
  END IF;
  -- Bodega: solo si se venden bienes (los servicios no tienen existencia).
  IF coalesce(p_datos->'bodega_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_bod := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  ELSIF coalesce((v_calc->>'tiene_bienes')::boolean, true) THEN
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa; cree una o indique "bodega_id".';
    END IF;
  END IF;

  -- Formas de pago (estructura): la suma debe ser el total exacto.
  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia o crédito).';
  END IF;
  IF jsonb_array_length(p_datos->'pagos') > 10 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 10 formas de pago por venta.';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    k := k + 1;
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    PERFORM interno.exigir_claves(pj, ARRAY['forma', 'monto_centavos', 'cuenta_dinero_id', 'referencia', 'recibido_centavos']);
    v_forma := interno.json_texto(pj->'forma', 'forma', 20);
    IF coalesce(v_forma, '') NOT IN ('efectivo', 'tarjeta', 'transferencia', 'credito') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago es efectivo, tarjeta, transferencia o credito.';
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
    IF v_forma IN ('efectivo', 'credito') AND coalesce(pj->'cuenta_dinero_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: en % no se indica cuenta (el efectivo entra a la caja de la venta).', v_forma;
    END IF;
    IF v_forma = 'credito' THEN
      v_ncred := v_ncred + 1;
      v_cred := v_cred + v_monto;
    END IF;
    v_suma := v_suma + v_monto;
    v_norm := v_norm || jsonb_build_object('linea', k, 'forma', v_forma, 'monto', v_monto, 'recibido', v_rec,
      'cuenta', interno.json_uuid(pj->'cuenta_dinero_id', 'cuenta_dinero_id'), 'referencia', interno.json_texto(pj->'referencia', 'referencia', 100));
  END LOOP;
  IF v_ncred > 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el crédito va en una sola forma de pago.';
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
  IF v_suma > v_cred AND NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa (el cobro entra a una cuenta de dinero).';
  END IF;

  -- Candado, reintento y número.
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'venta');
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;

  -- ¿Necesita aprobación? (el dueño no tiene topes)
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    IF (v_calc->>'descuento_manual_porcentaje')::numeric > v_td.sin_aprobacion THEN
      v_req := v_req || 'descuento'::text;
      v_desc := 'descuento de ' || (v_calc->>'descuento_manual_porcentaje') || ' % (su tope: ' || v_td.sin_aprobacion || ' %)';
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
    estado, requiere_aprobacion, aprobacion_id, nota, equipo, id_operacion, creado_por)
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
    interno.json_texto(p_datos->'nota', 'nota', 500), interno.equipo(p_datos), p_id_operacion, auth.uid())
  RETURNING * INTO v;

  INSERT INTO public.venta_linea (empresa_id, venta_id, linea, producto_id, descripcion, cantidad, precio_unitario_centavos,
    precio_incluye_isv, tipo_impuesto, impuesto_porcentaje, impuesto_clase, es_servicio, costo_estimado_centavos,
    promocion_id, descuento_linea_porcentaje, descuento_linea_monto_centavos,
    bruto_centavos, descuento_promocion_precio_centavos, descuento_linea_centavos, descuento_factura_centavos, neto_centavos,
    subtotal_centavos, descuento_promocion_centavos, descuento_centavos, base_centavos, impuesto_centavos, total_centavos)
  SELECT p_empresa_id, v.id, x.linea, x.producto_id, x.descripcion, x.cantidad, x.precio_unitario_centavos,
         x.precio_incluye_isv, x.tipo_impuesto, x.impuesto_porcentaje, x.impuesto_clase, x.es_servicio, x.costo_estimado_centavos,
         x.promocion_id, x.descuento_linea_porcentaje, x.descuento_linea_monto_centavos,
         x.bruto_centavos, x.descuento_promocion_precio_centavos, x.descuento_linea_centavos, x.descuento_factura_centavos,
         x.neto_centavos, x.subtotal_centavos, x.descuento_promocion_centavos, x.descuento_centavos, x.base_centavos,
         x.impuesto_centavos, x.total_centavos
    FROM jsonb_to_recordset(v_calc->'lineas') AS x(linea smallint, producto_id uuid, descripcion text, cantidad numeric,
         precio_unitario_centavos bigint, precio_incluye_isv boolean, tipo_impuesto text, impuesto_porcentaje numeric,
         impuesto_clase text, es_servicio boolean, costo_estimado_centavos bigint, promocion_id uuid,
         descuento_linea_porcentaje numeric, descuento_linea_monto_centavos bigint, bruto_centavos bigint,
         descuento_promocion_precio_centavos bigint, descuento_linea_centavos bigint, descuento_factura_centavos bigint,
         neto_centavos bigint, subtotal_centavos bigint, descuento_promocion_centavos bigint, descuento_centavos bigint,
         base_centavos bigint, impuesto_centavos bigint, total_centavos bigint);

  -- Cuentas de dinero de cada pago (con el candado: se pueden crear la primera vez).
  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    d := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(p_empresa_id, v_caja.id);
    ELSIF pj->>'forma' IN ('tarjeta', 'transferencia') THEN
      d := interno.cuenta_cobro_venta(p_empresa_id, pj->>'forma', (pj->>'cuenta')::uuid);
    END IF;
    INSERT INTO public.venta_pago (empresa_id, venta_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos, estado_transferencia)
    VALUES (p_empresa_id, v.id, (pj->>'linea')::smallint, pj->>'forma', (pj->>'monto')::bigint, d.id,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta(d.id) END, pj->>'referencia',
            (pj->>'recibido')::bigint, (pj->>'recibido')::bigint - (pj->>'monto')::bigint,
            CASE WHEN pj->>'forma' = 'transferencia' THEN 'por_confirmar' END);
  END LOOP;

  IF v.estado = 'por_emitir' THEN
    v := interno.emitir_venta(v.id, v_fecha, p_id_operacion);
  END IF;
  RETURN interno.venta_respuesta(v, false);
END $$;

-- ---------------------------------------------------------------------
-- 5) configurar_empresa (reemplaza la de 028; misma firma). Clave nueva
--    (solo el dueño): vendedor_cobra.
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
    IF k NOT IN ('tope_credito_centavos', 'permite_existencia_negativa', 'precio_incluye_isv_defecto', 'dias_alerta_transito',
                 'turnos_obligatorios', 'contabilidad_visible', 'doble_aprobacion',
                 'credito_politica', 'documento_venta_modo', 'cai_dias_alerta', 'cai_porcentaje_alerta', 'leyenda_factura',
                 'cotizacion_dias_vigencia', 'cotizacion_precios', 'permite_servicios', 'vendedor_cobra') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'tope_credito_centavos' AND NOT (jsonb_typeof(p_datos->'tope_credito_centavos') = 'number'
       AND (p_datos->>'tope_credito_centavos') ~ '^[0-9]{1,16}$'
       AND (p_datos->>'tope_credito_centavos')::numeric <= 9007199254740991) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "tope_credito_centavos" debe ser un entero de centavos, 0 o más.';
  END IF;
  FOREACH k IN ARRAY ARRAY['permite_existencia_negativa', 'precio_incluye_isv_defecto', 'turnos_obligatorios',
                           'contabilidad_visible', 'doble_aprobacion', 'permite_servicios', 'vendedor_cobra'] LOOP
    IF p_datos ? k AND jsonb_typeof(p_datos->k) <> 'boolean' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser true o false.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'dias_alerta_transito' AND NOT (jsonb_typeof(p_datos->'dias_alerta_transito') = 'number'
       AND (p_datos->>'dias_alerta_transito') ~ '^[0-9]{1,2}$' AND (p_datos->>'dias_alerta_transito')::integer <= 60) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "dias_alerta_transito" debe ser un número entero de 0 a 60.';
  END IF;
  IF p_datos ? 'credito_politica' AND coalesce(p_datos->>'credito_politica', '') NOT IN ('segun_limite', 'siempre_aprobacion') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "credito_politica" es "segun_limite" o "siempre_aprobacion".';
  END IF;
  IF p_datos ? 'documento_venta_modo' AND coalesce(p_datos->>'documento_venta_modo', '') NOT IN ('solo_factura', 'factura_o_ticket', 'solo_ticket') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "documento_venta_modo" es "solo_factura", "factura_o_ticket" o "solo_ticket".';
  END IF;
  IF p_datos ? 'cai_dias_alerta' AND NOT (jsonb_typeof(p_datos->'cai_dias_alerta') = 'number'
       AND (p_datos->>'cai_dias_alerta') ~ '^[0-9]{1,3}$' AND (p_datos->>'cai_dias_alerta')::integer <= 365) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "cai_dias_alerta" debe ser un número entero de 0 a 365.';
  END IF;
  IF p_datos ? 'cai_porcentaje_alerta' AND NOT (jsonb_typeof(p_datos->'cai_porcentaje_alerta') = 'number'
       AND (p_datos->>'cai_porcentaje_alerta') ~ '^[0-9]{1,3}$' AND (p_datos->>'cai_porcentaje_alerta')::integer BETWEEN 1 AND 100) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "cai_porcentaje_alerta" debe ser un número entero de 1 a 100.';
  END IF;
  IF p_datos ? 'cotizacion_dias_vigencia' AND NOT (jsonb_typeof(p_datos->'cotizacion_dias_vigencia') = 'number'
       AND (p_datos->>'cotizacion_dias_vigencia') ~ '^[0-9]{1,3}$' AND (p_datos->>'cotizacion_dias_vigencia')::integer BETWEEN 1 AND 365) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "cotizacion_dias_vigencia" debe ser un número entero de 1 a 365.';
  END IF;
  IF p_datos ? 'cotizacion_precios' AND coalesce(p_datos->>'cotizacion_precios', '') NOT IN ('respetar', 'recalcular') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "cotizacion_precios" es "respetar" o "recalcular".';
  END IF;
  IF p_datos ? 'leyenda_factura' AND p_datos->'leyenda_factura' <> 'null'::jsonb
     AND (jsonb_typeof(p_datos->'leyenda_factura') <> 'string' OR length(trim(p_datos->>'leyenda_factura')) NOT BETWEEN 1 AND 300) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "leyenda_factura" es un texto de 1 a 300 letras (o null para quitarla).';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET
    tope_credito_centavos = coalesce((p_datos->>'tope_credito_centavos')::bigint, tope_credito_centavos),
    permite_existencia_negativa = coalesce((p_datos->>'permite_existencia_negativa')::boolean, permite_existencia_negativa),
    precio_incluye_isv_defecto = coalesce((p_datos->>'precio_incluye_isv_defecto')::boolean, precio_incluye_isv_defecto),
    dias_alerta_transito = coalesce((p_datos->>'dias_alerta_transito')::integer, dias_alerta_transito),
    turnos_obligatorios = coalesce((p_datos->>'turnos_obligatorios')::boolean, turnos_obligatorios),
    contabilidad_visible = coalesce((p_datos->>'contabilidad_visible')::boolean, contabilidad_visible),
    doble_aprobacion = coalesce((p_datos->>'doble_aprobacion')::boolean, doble_aprobacion),
    credito_politica = coalesce(p_datos->>'credito_politica', credito_politica),
    documento_venta_modo = coalesce(p_datos->>'documento_venta_modo', documento_venta_modo),
    cai_dias_alerta = coalesce((p_datos->>'cai_dias_alerta')::integer, cai_dias_alerta),
    cai_porcentaje_alerta = coalesce((p_datos->>'cai_porcentaje_alerta')::integer, cai_porcentaje_alerta),
    leyenda_factura = CASE WHEN p_datos ? 'leyenda_factura' THEN nullif(trim(p_datos->>'leyenda_factura'), '') ELSE leyenda_factura END,
    cotizacion_dias_vigencia = coalesce((p_datos->>'cotizacion_dias_vigencia')::integer, cotizacion_dias_vigencia),
    cotizacion_precios = coalesce(p_datos->>'cotizacion_precios', cotizacion_precios),
    permite_servicios = coalesce((p_datos->>'permite_servicios')::boolean, permite_servicios),
    vendedor_cobra = coalesce((p_datos->>'vendedor_cobra')::boolean, vendedor_cobra)
  WHERE id = p_empresa_id
  RETURNING * INTO v_emp;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('tope_credito_centavos', v_emp.tope_credito_centavos,
                            'permite_existencia_negativa', v_emp.permite_existencia_negativa,
                            'precio_incluye_isv_defecto', v_emp.precio_incluye_isv_defecto,
                            'dias_alerta_transito', v_emp.dias_alerta_transito,
                            'turnos_obligatorios', v_emp.turnos_obligatorios,
                            'contabilidad_visible', v_emp.contabilidad_visible,
                            'doble_aprobacion', v_emp.doble_aprobacion,
                            'credito_politica', v_emp.credito_politica,
                            'documento_venta_modo', v_emp.documento_venta_modo,
                            'cai_dias_alerta', v_emp.cai_dias_alerta,
                            'cai_porcentaje_alerta', v_emp.cai_porcentaje_alerta,
                            'leyenda_factura', v_emp.leyenda_factura,
                            'cotizacion_dias_vigencia', v_emp.cotizacion_dias_vigencia,
                            'cotizacion_precios', v_emp.cotizacion_precios,
                            'permite_servicios', v_emp.permite_servicios,
                            'vendedor_cobra', v_emp.vendedor_cobra);
END $$;

-- ---------------------------------------------------------------------
-- 6) Perfiles con vendedor_cobra (reemplazan las de 025/028; mismas firmas).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.cambios_perfil(p_empresa_id uuid, p_perfil text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p         interno.plantilla_perfil := interno.perfil_de(p_perfil);
  e         public.empresa;
  v_cambios jsonb := '[]';
  v_topes   jsonb;
  v_sug     jsonb;
  v_act     jsonb;
  v_faltan  jsonb;
  v_sobran  jsonb;
  v_avisos  jsonb := '[]';
BEGIN
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  IF e.perfil IS DISTINCT FROM p.codigo THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'perfil', 'actual', e.perfil, 'nuevo', p.codigo);
  END IF;
  IF e.turnos_obligatorios IS DISTINCT FROM p.turnos_obligatorios THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'turnos_obligatorios', 'actual', e.turnos_obligatorios, 'nuevo', p.turnos_obligatorios);
    v_avisos := v_avisos || to_jsonb(CASE WHEN p.turnos_obligatorios
      THEN 'Para cobrar en efectivo cada cajero tendrá que abrir su turno de caja.'
      ELSE 'El efectivo podrá entrar a la caja sin turno; los turnos abiertos siguen igual hasta cerrarlos.' END);
  END IF;
  IF e.contabilidad_visible IS DISTINCT FROM p.contabilidad_visible THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'contabilidad_visible', 'actual', e.contabilidad_visible, 'nuevo', p.contabilidad_visible);
    IF NOT p.contabilidad_visible THEN
      v_avisos := v_avisos || to_jsonb('La contabilidad se esconde del menú; los libros se siguen llevando igual y el contador la sigue viendo.'::text);
    END IF;
  END IF;
  IF e.doble_aprobacion IS DISTINCT FROM p.doble_aprobacion THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'doble_aprobacion', 'actual', e.doble_aprobacion, 'nuevo', p.doble_aprobacion);
    IF p.doble_aprobacion THEN
      v_avisos := v_avisos || to_jsonb('Con doble aprobación cada solicitud nueva (gastos, descuentos, créditos y anulaciones) necesita dos personas distintas; el dueño aprueba solo.'::text);
    END IF;
  END IF;
  IF e.vendedor_cobra IS DISTINCT FROM p.vendedor_cobra THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'vendedor_cobra', 'actual', e.vendedor_cobra, 'nuevo', p.vendedor_cobra);
    v_avisos := v_avisos || to_jsonb(CASE WHEN p.vendedor_cobra
      THEN 'El vendedor también podrá cobrar (efectivo, tarjeta o transferencia), con las mismas reglas de turno de caja.'
      ELSE 'El vendedor ya no cobra: vende al crédito o hace la cotización y el cajero la cobra.' END);
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('rol', t.rol, 'tipo', t.tipo,
           'actual_sin_aprobacion_centavos', a.sin_aprobacion, 'nuevo_sin_aprobacion_centavos', t.sin_aprobacion_centavos,
           'actual_aprueba_hasta_centavos', a.aprueba_hasta, 'nuevo_aprueba_hasta_centavos', t.aprueba_hasta_centavos)
           ORDER BY t.rol, t.tipo), '[]')
    INTO v_topes
    FROM interno.plantilla_perfil_tope t
    CROSS JOIN LATERAL interno.tope_rol(p_empresa_id, t.rol, t.tipo) a
   WHERE t.perfil = p.codigo
     AND (a.sin_aprobacion, a.aprueba_hasta) IS DISTINCT FROM (t.sin_aprobacion_centavos, t.aprueba_hasta_centavos);

  SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]') INTO v_sug
    FROM interno.plantilla_perfil_modulo m WHERE m.perfil = p.codigo;
  SELECT coalesce(jsonb_agg(a.modulo ORDER BY a.modulo), '[]') INTO v_act
    FROM public.modulo_activo a WHERE a.empresa_id = p_empresa_id AND a.activo;
  SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') INTO v_faltan
    FROM jsonb_array_elements_text(v_sug) x WHERE NOT v_act ? x;
  SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') INTO v_sobran
    FROM jsonb_array_elements_text(v_act) x WHERE NOT v_sug ? x;
  IF jsonb_array_length(v_faltan) > 0 THEN
    v_avisos := v_avisos || to_jsonb('Módulos sugeridos que no están activos: los activa el proveedor según su plan (pídalos en "Mi cuenta").'::text);
  END IF;
  IF jsonb_array_length(v_sobran) > 0 THEN
    v_avisos := v_avisos || to_jsonb('Los módulos activos que el perfil no sugiere siguen activos: un perfil nunca desactiva módulos ni borra datos.'::text);
  END IF;

  RETURN jsonb_build_object('perfil', p.codigo, 'nombre', p.nombre, 'descripcion', p.descripcion,
    'cambios', v_cambios, 'topes', v_topes,
    'modulos', jsonb_build_object('sugeridos', v_sug, 'activos', v_act, 'faltan', v_faltan, 'activos_no_sugeridos', v_sobran),
    'avisos', v_avisos,
    'hay_cambios', jsonb_array_length(v_cambios) > 0 OR jsonb_array_length(v_topes) > 0);
END $$;

CREATE OR REPLACE FUNCTION interno.guardar_perfil(p_empresa_id uuid, p_perfil text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p interno.plantilla_perfil := interno.perfil_de(p_perfil);
BEGIN
  UPDATE public.empresa
     SET perfil = p.codigo, turnos_obligatorios = p.turnos_obligatorios,
         contabilidad_visible = p.contabilidad_visible, doble_aprobacion = p.doble_aprobacion,
         vendedor_cobra = p.vendedor_cobra
   WHERE id = p_empresa_id
     AND (perfil, turnos_obligatorios, contabilidad_visible, doble_aprobacion, vendedor_cobra)
         IS DISTINCT FROM (p.codigo, p.turnos_obligatorios, p.contabilidad_visible, p.doble_aprobacion, p.vendedor_cobra);
  INSERT INTO public.tope_rol (empresa_id, rol, tipo, sin_aprobacion_centavos, aprueba_hasta_centavos, actualizado_por)
  SELECT p_empresa_id, t.rol, t.tipo, t.sin_aprobacion_centavos, t.aprueba_hasta_centavos, auth.uid()
    FROM interno.plantilla_perfil_tope t
    CROSS JOIN LATERAL interno.tope_rol(p_empresa_id, t.rol, t.tipo) a
   WHERE t.perfil = p.codigo
     AND (a.sin_aprobacion, a.aprueba_hasta) IS DISTINCT FROM (t.sin_aprobacion_centavos, t.aprueba_hasta_centavos)
  ON CONFLICT (empresa_id, rol, tipo) DO UPDATE
     SET sin_aprobacion_centavos = excluded.sin_aprobacion_centavos, aprueba_hasta_centavos = excluded.aprueba_hasta_centavos,
         actualizado_por = excluded.actualizado_por, actualizado_en = now();
END $$;

CREATE OR REPLACE FUNCTION public.perfiles_negocio()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('perfil', p.codigo, 'nombre', p.nombre, 'descripcion', p.descripcion,
           'turnos_obligatorios', p.turnos_obligatorios, 'contabilidad_visible', p.contabilidad_visible,
           'doble_aprobacion', p.doble_aprobacion, 'vendedor_cobra', p.vendedor_cobra,
           'modulos_sugeridos', (SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]')
                                   FROM interno.plantilla_perfil_modulo m WHERE m.perfil = p.codigo),
           'topes', (SELECT coalesce(jsonb_agg(jsonb_build_object('rol', t.rol, 'tipo', t.tipo,
                              'sin_aprobacion_centavos', t.sin_aprobacion_centavos,
                              'aprueba_hasta_centavos', t.aprueba_hasta_centavos) ORDER BY t.rol, t.tipo), '[]')
                       FROM interno.plantilla_perfil_tope t WHERE t.perfil = p.codigo))
           ORDER BY p.orden), '[]')
    FROM interno.plantilla_perfil p
$$;

-- ---------------------------------------------------------------------
-- 7) resolver_aprobacion (reemplaza la de 028; misma firma). Aprobar una venta
--    pendiente la emite: con "inventario" o "dinero" apagados se rechaza como
--    una venta nueva (rechazar o cancelar sí se puede).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolver_aprobacion(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                      p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.aprobacion;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la solicitud de aprobación no existe.';
  END IF;
  IF a.tipo = 'gasto' THEN
    RETURN interno.resolver_aprobacion_gasto(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha);
  ELSIF a.tipo = 'venta' THEN
    -- Aprobar EMITE la venta (mueve inventario y dinero): pide esos módulos
    -- como una venta nueva. Rechazar siempre se puede.
    IF p_aprobar AND NOT public.modulo_esta_activo(a.empresa_id, 'inventario')
       AND EXISTS (SELECT 1 FROM public.venta_linea l WHERE l.venta_id = a.documento_id AND NOT l.es_servicio) THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo: esta venta lleva bienes y no se puede emitir; recházela o cancélela.';
    END IF;
    IF p_aprobar AND NOT public.modulo_esta_activo(a.empresa_id, 'dinero')
       AND EXISTS (SELECT 1 FROM public.venta_pago g WHERE g.venta_id = a.documento_id AND g.forma <> 'credito') THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo: esta venta se cobra al contado y no se puede emitir; recházela o cancélela.';
    END IF;
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_aprobacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  ELSIF a.tipo = 'anulacion_venta' THEN
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_anulacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  END IF;
  RAISE EXCEPTION 'NO_PERMITIDO: este tipo de aprobación (%) todavía no se resuelve aquí.', a.tipo;
END $$;

-- ---------------------------------------------------------------------
-- 8) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.puede_cobrar(uuid),
  interno.promociones_de(uuid, public.producto, date, numeric)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.promociones_aplicables(uuid, uuid, date, numeric) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.promociones_aplicables(uuid, uuid, date, numeric) TO authenticated;
