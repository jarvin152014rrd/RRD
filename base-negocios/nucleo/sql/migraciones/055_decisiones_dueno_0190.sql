-- =====================================================================
-- 055_decisiones_dueno_0190.sql  -  Núcleo 0.19.0.
-- Las 001-054 no se tocan. Decisiones del dueño (docs/REQUISITOS.md,
-- "Decisiones del dueño 0.19.0"):
--
--   A1) DEVOLUCIÓN PARCIAL CON PRECIO MAYORISTA POR CANTIDAD
--       Un cliente que NO es mayorista compró con precio mayorista porque llegó
--       a "desde cantidad". Si devuelve unidades y lo que se QUEDA baja de esa
--       cantidad, lo que conserva se recalcula a precio normal y la diferencia
--       se descuenta de lo que se le devuelve ("Ajuste por perder precio
--       mayorista"). Siempre sobre lo devuelto ACUMULADO (varias devoluciones
--       seguidas dan lo mismo que una sola). Si el ajuste se come todo lo que se
--       devolvería, se rechaza con un mensaje claro. La nota de crédito lleva el
--       neto (base e ISV), así ISV por pagar = ventas - notas, como siempre.
--       Garantías: sin ajuste (el producto vino malo).
--   A2) Mayorista y promociones no se suman: ya estaba (0.18.0). Sin cambios.
--   A3) ESTADO DE CUENTA DEL SOCIO: aportes, aportes anulados, repartos
--       asignados, pagos recibidos, saldo por pagar y total invertido, con
--       rango de fechas; cuadra con 3.1.01.04 y 2.1.01.03 de los libros.
--   A4) CAMBIO EXACTO (regla de la empresa "cambio_exacto", encendida por
--       defecto): un cambio de producto solo se hace por uno o varios productos
--       que sumen EXACTAMENTE lo devuelto; si no, se devuelve todo el dinero.
--       Sin diferencia en dinero ni saldo a favor. El cambio por garantía con
--       "precio de garantía" sigue igual (ya vale lo pagado). Con la regla
--       apagada, el cambio funciona como en 0.16.0 (con diferencia).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('CAMBIO_NO_EXACTO', 'El cambio debe valer exactamente lo mismo que lo que se devuelve.',
   'Agregue o quite productos hasta que la cuenta quede exacta, o devuelva todo el dinero al cliente.');

-- =====================================================================
-- 1) Columnas nuevas
-- =====================================================================
-- Regla de la empresa (A4). Encendida para todas: las empresas que ya existen
-- (la del dueño) y las nuevas. La cambia solo el dueño con configurar_empresa.
ALTER TABLE public.empresa ADD COLUMN cambio_exacto boolean NOT NULL DEFAULT true;

-- (A1) Por qué la línea llevó precio mayorista y desde cuántas unidades, como
-- eran AL VENDER (el cliente o el producto pueden cambiar después).
ALTER TABLE public.venta_linea
  ADD COLUMN mayorista_por   text CHECK (mayorista_por IN ('cliente', 'cantidad')),
  ADD COLUMN mayorista_desde numeric(18,4);
-- (A1) Ajuste de esta devolución por perder el precio mayorista (con ISV). Positivo:
-- se descontó de lo devuelto; negativo: se devolvió un ajuste anterior (devolvió más).
ALTER TABLE public.devolucion      ADD COLUMN ajuste_mayorista_centavos bigint NOT NULL DEFAULT 0;
ALTER TABLE public.devolucion_linea ADD COLUMN ajuste_mayorista_centavos bigint NOT NULL DEFAULT 0;

-- Al guardar una línea vendida: por qué lleva el precio mayorista (cliente mayorista o
-- cantidad) y el "desde cantidad" del producto en ese momento. Las líneas de antes de
-- 0.19.0 quedan en null: al devolver se usa el cliente y el producto de hoy.
CREATE FUNCTION interno.mayorista_de_linea() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.precio_tipo = 'mayorista' THEN
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
CREATE TRIGGER mayorista_origen BEFORE INSERT ON public.venta_linea FOR EACH ROW EXECUTE FUNCTION interno.mayorista_de_linea();

-- =====================================================================
-- 2) A1: montos de una devolución (UNA sola cuenta para registrar, el cálculo
--    previo de la devolución y el del cambio)
-- =====================================================================
-- interno.montos_devolucion(venta, [{"linea","cantidad"}]) -> jsonb
--   Valida las líneas (número de línea, sin repetir, cantidad <= vendida - ya devuelta;
--   las pendientes de aprobación cuentan) y calcula por cantidad ACUMULADA (0.9.1):
--     total acumulado = round(total de la línea x devuelto acumulado / vendida)
--   Precio mayorista por CANTIDAD (A1): si lo que se queda (K = vendida - devuelto
--   acumulado) es mayor que cero y menor que "desde cantidad", lo que conserva vale a
--   precio normal: ajuste acumulado = precio_con_tasa(round(K x precio normal)) - lo que
--   pagó por esas K (con ISV; la base igual). Lo que corresponde devolver en total es el
--   total acumulado menos ese ajuste; esta devolución = eso menos lo ya devuelto. Así:
--     - varias devoluciones seguidas dan lo mismo que una sola;
--     - si después devuelve todo (K = 0), el ajuste anterior vuelve al cliente;
--     - si el ajuste se come todo lo que se devolvería: DEVOLUCION_INVALIDA (se explica).
--   Sin ajuste: el cliente mayorista (por cliente), garantías (app.devolucion_garantia
--   o app.precio_garantia) y líneas sin precio mayorista.
-- Devuelve {lineas: [...], base, impuesto, total, costo, costo_estimado, valor, ajuste,
--           hay_servicio, desglose}. Lleva costos: quien lo muestre los quita.
CREATE FUNCTION interno.montos_devolucion(v public.venta, p_lineas jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  vl      public.venta_linea;
  p       public.producto;
  lj      jsonb;
  i       integer := 0;
  q       numeric;
  q0      numeric;
  b0 bigint; i0 bigint; c0 bigint; e0 bigint;
  v_r     numeric;
  v_k     numeric;
  t_acum  bigint;
  b_acum  bigint;
  v_por   text;
  v_desde numeric;
  pc      record;
  a_tot   bigint;
  a_base  bigint;
  v_tot   bigint;
  v_base  bigint;
  v_imp   bigint;
  v_cost  bigint;
  v_cest  bigint;
  v_valor bigint;
  v_aj    bigint;
  v_cand  boolean;
  v_txt   text;
  v_gar   boolean := nullif(current_setting('app.devolucion_garantia', true), '') IS NOT NULL
                     OR nullif(current_setting('app.precio_garantia', true), '') IS NOT NULL;
  v_lin   jsonb := '[]';
  t_base bigint := 0; t_imp bigint := 0; t_cost bigint := 0; t_cest bigint := 0; t_aj bigint := 0; t_val bigint := 0;
  v_serv  boolean := false;
  v_desg  jsonb;
BEGIN
  IF jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lineas) = 0 THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: indique qué líneas devuelve ("lineas": [{"linea": 1, "cantidad": 2}]).';
  END IF;
  FOR lj IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    IF jsonb_typeof(lj) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'DEVOLUCION_INVALIDA: la línea % no es válida ({"linea": 1, "cantidad": 2}).', i;
    END IF;
    PERFORM interno.exigir_claves(lj, ARRAY['linea', 'cantidad']);
    IF jsonb_typeof(lj->'linea') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'DEVOLUCION_INVALIDA: en la línea % indique el número de línea de la venta ("linea").', i;
    END IF;
    SELECT * INTO vl FROM public.venta_linea x WHERE x.venta_id = v.id AND x.linea = (lj->>'linea')::numeric;
    IF vl.id IS NULL THEN
      RAISE EXCEPTION 'DEVOLUCION_INVALIDA: la venta % no tiene la línea %.', v.numero_documento, lj->>'linea';
    END IF;
    IF v_lin @> jsonb_build_array(jsonb_build_object('venta_linea_id', vl.id)) THEN
      RAISE EXCEPTION 'DEVOLUCION_INVALIDA: la línea % viene dos veces.', vl.linea;
    END IF;
    SELECT * INTO p FROM public.producto x WHERE x.id = vl.producto_id;
    q := interno.json_numero(lj->'cantidad', 'cantidad', i);
    PERFORM interno.validar_cantidad(p, q, i);
    SELECT coalesce(sum(x.cantidad), 0), coalesce(sum(x.base_centavos), 0), coalesce(sum(x.impuesto_centavos), 0),
           coalesce(sum(x.costo_centavos), 0), coalesce(sum(x.costo_estimado_centavos), 0)
      INTO q0, b0, i0, c0, e0
      FROM public.devolucion_linea x JOIN public.devolucion y ON y.id = x.devolucion_id
     WHERE x.venta_linea_id = vl.id AND y.estado IN ('aplicada', 'pendiente_aprobacion', 'por_aplicar');
    IF q > vl.cantidad - q0 THEN
      RAISE EXCEPTION 'DEVOLUCION_INVALIDA: de la línea % ("%") se vendieron % y ya se devolvieron %; no se pueden devolver %.',
        vl.linea, vl.descripcion, trim_scale(vl.cantidad), trim_scale(q0), trim_scale(q);
    END IF;
    v_r := q0 + q;
    v_k := vl.cantidad - v_r;
    t_acum := round(vl.total_centavos * v_r / vl.cantidad)::bigint;
    b_acum := round(vl.base_centavos * v_r / vl.cantidad)::bigint;

    -- A1: ¿pierde el precio mayorista lo que se queda?
    a_tot := 0;  a_base := 0;  v_cand := false;  v_desde := NULL;
    IF vl.precio_tipo = 'mayorista' AND NOT v_gar AND vl.precio_normal_centavos IS NOT NULL THEN
      v_por := coalesce(vl.mayorista_por,
                        CASE WHEN EXISTS (SELECT 1 FROM public.tercero t WHERE t.id = v.cliente_id AND t.es_cliente AND t.es_mayorista)
                             THEN 'cliente' ELSE 'cantidad' END);
      v_desde := coalesce(vl.mayorista_desde, (SELECT x.cantidad_mayorista FROM public.producto x WHERE x.id = vl.producto_id));
      v_cand := v_por = 'cantidad' AND v_desde IS NOT NULL;
      IF v_cand AND v_k > 0 AND v_k < v_desde THEN
        SELECT * INTO pc FROM public.precio_con_tasa(round(v_k * vl.precio_normal_centavos)::bigint, vl.precio_incluye_isv,
                                                     vl.impuesto_porcentaje, 1);
        a_tot := pc.con_isv_centavos - (vl.total_centavos - t_acum);
        IF a_tot > 0 THEN
          a_base := least(greatest(pc.sin_isv_centavos - (vl.base_centavos - b_acum), 0), a_tot);
        ELSE
          a_tot := 0;
        END IF;
      END IF;
    END IF;

    v_tot := (t_acum - a_tot) - (b0 + i0);                        -- lo que se devuelve en esta devolución
    v_valor := t_acum - round(vl.total_centavos * q0 / vl.cantidad)::bigint;   -- lo que pagó por estas unidades
    IF v_cand THEN
      v_aj := v_valor - v_tot;
      IF v_tot <= 0 THEN
        RAISE EXCEPTION 'DEVOLUCION_INVALIDA: de "%" se quedaría con % y el precio mayorista es desde %: lo que se queda pasa a precio normal y el ajuste (%) es igual o mayor que lo que se le devolvería (%). No queda nada que devolver: devuelva más unidades (o todas) o no haga la devolución.',
          vl.descripcion, trim_scale(v_k), trim_scale(v_desde), interno.lempiras(v_aj), interno.lempiras(v_valor);
      END IF;
    ELSE
      v_aj := 0;
      v_valor := greatest(v_tot, 0);
    END IF;
    v_base := least(greatest((b_acum - a_base) - b0, 0), greatest(v_tot, 0));
    v_imp := greatest(v_tot, 0) - v_base;
    v_cost := greatest(round(coalesce(vl.costo_centavos, 0) * v_r / vl.cantidad)::bigint - c0, 0);
    v_cest := greatest(round(coalesce(vl.costo_estimado_centavos, 0) * v_r / vl.cantidad)::bigint - e0, 0);
    v_txt := CASE WHEN v_aj > 0 THEN 'Ajuste por perder precio mayorista: ' || interno.lempiras(v_aj)
                                     || ' (se queda con ' || trim_scale(v_k) || '; el precio mayorista es desde ' || trim_scale(v_desde) || ')'
                  WHEN v_aj < 0 THEN 'Se devuelve el ajuste por precio mayorista: ' || interno.lempiras(-v_aj) END;
    v_serv := v_serv OR vl.es_servicio;
    v_lin := v_lin || jsonb_build_object('linea', i, 'venta_linea_id', vl.id, 'linea_venta', vl.linea, 'producto_id', vl.producto_id,
      'descripcion', vl.descripcion, 'es_servicio', vl.es_servicio, 'cantidad', q, 'tipo_impuesto', vl.tipo_impuesto,
      'impuesto_porcentaje', vl.impuesto_porcentaje, 'base', v_base, 'impuesto', v_imp, 'total', v_base + v_imp,
      'costo', v_cost, 'costo_estimado', v_cest, 'valor', v_valor, 'ajuste', v_aj, 'ajuste_texto', v_txt,
      'precio_tipo', vl.precio_tipo, 'conserva', v_k, 'mayorista_desde', CASE WHEN v_cand THEN v_desde END);
    t_base := t_base + v_base;  t_imp := t_imp + v_imp;  t_cost := t_cost + v_cost;  t_cest := t_cest + v_cest;
    t_aj := t_aj + v_aj;  t_val := t_val + v_valor;
  END LOOP;

  -- Desglose por impuesto (cada uno a su cuenta).
  SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', x.codigo, 'nombre', im.nombre, 'porcentaje', x.porcentaje,
           'base_centavos', x.base, 'impuesto_centavos', x.impuesto, 'cuenta_por_pagar', im.cuenta_por_pagar) ORDER BY im.orden, x.codigo), '[]')
    INTO v_desg
    FROM (SELECT y->>'tipo_impuesto' AS codigo, (y->>'impuesto_porcentaje')::numeric AS porcentaje,
                 sum((y->>'base')::bigint) AS base, sum((y->>'impuesto')::bigint) AS impuesto
            FROM jsonb_array_elements(v_lin) y GROUP BY 1, 2) x
    JOIN public.impuesto im ON im.empresa_id = v.empresa_id AND im.codigo = x.codigo;

  RETURN jsonb_build_object('lineas', v_lin, 'base', t_base, 'impuesto', t_imp, 'total', t_base + t_imp, 'costo', t_cost,
    'costo_estimado', t_cest, 'valor', t_val, 'ajuste', t_aj, 'hay_servicio', v_serv, 'desglose', v_desg);
END $$;

-- =====================================================================
-- 3) Registrar la devolución (reemplaza interno.registrar_devolucion_base de
--    038/052; misma firma y respuesta). Cambios:
--    - los montos salen de interno.montos_devolucion (A1) y se vuelven a
--      calcular con el candado puesto (si otra devolución cambió algo: error);
--    - A4: con la regla cambio_exacto, el cambio vale EXACTAMENTE lo devuelto.
-- =====================================================================
CREATE OR REPLACE FUNCTION interno.registrar_devolucion_base(p_venta_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v        public.venta;
  e        public.empresa;
  d        public.devolucion;
  m        jsonb;
  m2       jsonb;
  v_tot    bigint;
  v_dest   text;
  v_cta    uuid;
  v_caja   public.caja;
  v_fecha  date;
  v_rol    text;
  v_tope   record;
  v_req    boolean := false;
  v_apr    uuid;
  v_cam    jsonb;
  v_calc   jsonb;
  v_nuevo  bigint;
  r        jsonb;
  v_motivo text;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la venta no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v.empresa_id, 'ventas.devolver', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v.empresa_id, p_id_operacion, 'devolucion');
  SELECT * INTO d FROM public.devolucion x WHERE x.empresa_id = v.empresa_id AND x.id_operacion = p_id_operacion;
  IF d.id IS NOT NULL THEN
    RETURN interno.ocultar_costos(v.empresa_id, interno.devolucion_respuesta(d, true), ARRAY['costo_centavos']);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['lineas', 'motivo', 'destino', 'cuenta_dinero_id', 'caja_id', 'fecha', 'cambio', 'equipo']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = v.empresa_id;
  v_rol := public.mi_rol(v.empresa_id);
  v_motivo := interno.json_texto(p_datos->'motivo', 'motivo', 300);
  IF length(coalesce(v_motivo, '')) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué devuelve el cliente (mínimo 5 letras).';
  END IF;
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: solo se devuelve de una venta emitida (esta está %).', v.estado;
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), greatest(public.hoy_local(v.empresa_id), v.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v.empresa_id, v_fecha);
  IF v_fecha < v.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la devolución no puede tener fecha anterior a la venta (%).', to_char(v.fecha_contable, 'DD/MM/YYYY');
  END IF;
  IF coalesce(p_datos->'caja_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_caja := interno.caja_de_venta(v.empresa_id, p_datos->'caja_id');
  ELSE
    SELECT c.* INTO v_caja FROM public.caja c JOIN public.sucursal s ON s.id = c.sucursal_id
     WHERE c.id = v.caja_id AND c.activa AND s.activa;
    IF v_caja.id IS NULL THEN
      v_caja := interno.caja_de_venta(v.empresa_id, NULL);
    END IF;
  END IF;

  -- Destino de lo ya pagado (lo que no rebaja CxC) y lo que el dueño permite.
  v_dest := interno.json_texto(p_datos->'destino', 'destino', 20);
  IF v_dest IS NOT NULL AND v_dest NOT IN ('dinero', 'saldo_favor', 'cambio') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el destino es "dinero", "saldo_favor" (nota de crédito) o "cambio" (cambio de producto).';
  END IF;
  IF v_dest IS NOT NULL AND NOT (CASE v_dest WHEN 'dinero' THEN 'devolver_dinero' WHEN 'saldo_favor' THEN 'nota_credito'
                                             ELSE 'cambio_producto' END) = ANY (e.devolucion_tipos) THEN
    RAISE EXCEPTION 'DEVOLUCION_NO_PERMITIDA: el dueño no permite "%" (permitidos: %).', v_dest, array_to_string(e.devolucion_tipos, ', ');
  END IF;
  v_cta := interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id');
  IF v_dest = 'dinero' AND v_cta IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique de qué cuenta sale el dinero ("cuenta_dinero_id": caja, caja chica o banco).';
  END IF;
  -- A4: en un cambio exacto no sale dinero ni queda saldo a favor (no lleva cuenta, "diferencia" ni "pagos").
  IF v_dest = 'cambio' AND e.cambio_exacto AND nullif(current_setting('app.precio_garantia', true), '') IS NULL
     AND (v_cta IS NOT NULL OR nullif(current_setting('app.cambio_diferencia', true), '') IS NOT NULL
          OR coalesce(p_datos->'cambio'->'pagos', 'null'::jsonb) NOT IN ('null'::jsonb, '[]'::jsonb)) THEN
    RAISE EXCEPTION 'CAMBIO_NO_EXACTO: en este negocio el cambio de producto no lleva diferencia: no se cobra, no se devuelve dinero ni queda saldo a favor. Elija productos que sumen exactamente lo devuelto, o devuelva todo el dinero (destino "dinero").';
  END IF;
  IF v_cta IS NOT NULL THEN
    IF v_dest NOT IN ('dinero', 'cambio') OR v_dest IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de dinero solo va al devolver dinero (o la diferencia de un cambio).';
    END IF;
    PERFORM interno.cuenta_dinero_para_pagar(v.empresa_id, v_cta);
    -- 0.9.1: de una caja solo sale efectivo del turno propio (nunca del de otro cajero).
    PERFORM interno.cuenta_salida_efectivo(v.empresa_id, v_cta, ARRAY[auth.uid()], false);
  END IF;
  IF coalesce(v_dest = 'cambio', false) <> (coalesce(p_datos->'cambio', 'null'::jsonb) <> 'null'::jsonb) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un cambio de producto lleva "destino": "cambio" y los datos de la venta nueva en "cambio".';
  END IF;

  -- Líneas y montos (A1: con el ajuste por perder el precio mayorista).
  m := interno.montos_devolucion(v, p_datos->'lineas');
  v_tot := (m->>'total')::bigint;
  IF v_tot <= 0 THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: el valor devuelto debe ser mayor que cero.';
  END IF;
  -- Servicios: solo nota de crédito o dinero (no cambio de producto).
  IF (m->>'hay_servicio')::boolean AND v_dest = 'cambio' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: un servicio se devuelve como nota de crédito o dinero, no como cambio de producto.';
  END IF;

  -- Cambio de producto: se calcula la venta nueva (para saber la diferencia).
  IF v_dest = 'cambio' THEN
    v_cam := p_datos->'cambio';
    PERFORM interno.exigir_claves(v_cam, ARRAY['lineas', 'pagos', 'descuento_factura', 'tipo_documento', 'bodega_id']);
    v_calc := interno.calcular_venta(v.empresa_id, v_fecha, v_cam->'lineas', v_cam->'descuento_factura');
    v_nuevo := (v_calc->>'total_centavos')::bigint;
    v_cam := v_cam || jsonb_build_object('total_nuevo', v_nuevo);
    -- A4: cambio exacto (el de garantía con "precio de garantía" ya vale lo pagado).
    IF e.cambio_exacto AND nullif(current_setting('app.precio_garantia', true), '') IS NULL THEN
      IF v_nuevo <> v_tot THEN
        RAISE EXCEPTION 'CAMBIO_NO_EXACTO: lo devuelto vale % y los productos nuevos suman %: %. Agregue o quite productos hasta que quede exacto, o devuelva todo el dinero.',
          interno.lempiras(v_tot), interno.lempiras(v_nuevo),
          CASE WHEN v_nuevo < v_tot THEN 'falta ' || interno.lempiras(v_tot - v_nuevo) ELSE 'sobra ' || interno.lempiras(v_nuevo - v_tot) END;
      END IF;
      v_cam := v_cam || jsonb_build_object('exacto', true);
    END IF;
  END IF;

  -- ¿Necesita aprobación? (tope del puesto; el dueño no tiene tope)
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_tope FROM interno.tope_rol(v.empresa_id, v_rol, 'devolucion');
    v_req := v_tot > v_tope.sin_aprobacion;
  END IF;
  IF v_req AND v_dest = 'cambio' THEN
    RAISE EXCEPTION 'APROBACION_REQUERIDA: la devolución (%) pasa su tope (%); un cambio de producto no queda pendiente. Que lo haga quien aprueba, o registre la devolución como nota de crédito (pendiente de aprobación) y venda después con ese saldo.',
      interno.lempiras(v_tot), interno.lempiras(v_tope.sin_aprobacion);
  END IF;

  PERFORM interno.reservar_operacion(v.empresa_id, p_id_operacion, 'devolucion');
  SELECT * INTO d FROM public.devolucion x WHERE x.empresa_id = v.empresa_id AND x.id_operacion = p_id_operacion;
  IF d.id IS NOT NULL THEN
    RETURN interno.ocultar_costos(v.empresa_id, interno.devolucion_respuesta(d, true), ARRAY['costo_centavos']);
  END IF;
  -- Otra vez con el candado: la venta sigue emitida y las cuentas son las mismas (si otra
  -- devolución de esta venta entró mientras tanto, las cantidades o el ajuste cambian).
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: la venta ya está %.', v.estado;
  END IF;
  BEGIN
    m2 := interno.montos_devolucion(v, p_datos->'lineas');
  EXCEPTION WHEN raise_exception THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: otra devolución de esta venta se registró mientras tanto; revise las cantidades.';
  END;
  IF m2 IS DISTINCT FROM m THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: otra devolución de esta venta se registró mientras tanto; revise las cantidades.';
  END IF;

  d.id := gen_random_uuid();
  d.numero := interno.siguiente_numero(v.empresa_id, 'devolucion');
  IF v_req THEN
    v_apr := gen_random_uuid();
    INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                   solicitado_por, rol_solicitante)
    VALUES (v_apr, v.empresa_id, interno.siguiente_numero(v.empresa_id, 'aprobacion'), 'devolucion', 'devolucion', d.id, v_tot,
            'Devolución #' || d.numero || ' de la venta ' || v.numero_documento || ' (' || v.cliente_nombre || ') por '
              || interno.lempiras(v_tot) || ': ' || v_motivo, auth.uid(), v_rol);
  END IF;
  INSERT INTO public.devolucion (id, empresa_id, numero, venta_id, cliente_id, cliente_nombre, caja_id, sucursal_id, fecha_contable,
    motivo, destino, cuenta_dinero_id, subtotal_centavos, impuesto_centavos, total_centavos, desglose_impuestos, costo_centavos,
    costo_estimado_centavos, cambio, estado, aprobacion_id, equipo, id_operacion, creado_por, ajuste_mayorista_centavos)
  VALUES (d.id, v.empresa_id, d.numero, v.id, v.cliente_id, v.cliente_nombre, v_caja.id, v_caja.sucursal_id, v_fecha,
    v_motivo, v_dest, v_cta, (m->>'base')::bigint, (m->>'impuesto')::bigint, v_tot, m->'desglose', (m->>'costo')::bigint,
    (m->>'costo_estimado')::bigint, v_cam,
    CASE WHEN v_req THEN 'pendiente_aprobacion' ELSE 'por_aplicar' END, v_apr, interno.equipo(p_datos), p_id_operacion, auth.uid(),
    (m->>'ajuste')::bigint)
  RETURNING * INTO d;
  INSERT INTO public.devolucion_linea (empresa_id, devolucion_id, linea, venta_linea_id, producto_id, descripcion, es_servicio, cantidad,
    tipo_impuesto, impuesto_porcentaje, base_centavos, impuesto_centavos, total_centavos, costo_centavos, costo_estimado_centavos,
    ajuste_mayorista_centavos)
  SELECT v.empresa_id, d.id, (y->>'linea')::smallint, (y->>'venta_linea_id')::bigint, (y->>'producto_id')::uuid, y->>'descripcion',
         (y->>'es_servicio')::boolean, (y->>'cantidad')::numeric, y->>'tipo_impuesto', (y->>'impuesto_porcentaje')::numeric,
         (y->>'base')::bigint, (y->>'impuesto')::bigint, (y->>'base')::bigint + (y->>'impuesto')::bigint,
         (y->>'costo')::bigint, (y->>'costo_estimado')::bigint, (y->>'ajuste')::bigint
    FROM jsonb_array_elements(m->'lineas') y;

  IF NOT v_req THEN
    d := interno.aplicar_devolucion(d.id, v_fecha, p_id_operacion);
    IF v_dest = 'cambio' THEN
      r := interno.venta_de_cambio(d, p_id_operacion);
      SELECT * INTO d FROM public.devolucion WHERE id = d.id;
    END IF;
  END IF;
  RETURN interno.ocultar_costos(v.empresa_id, interno.devolucion_respuesta(d, false)
           || CASE WHEN r IS NOT NULL THEN jsonb_build_object('venta_cambio', r) ELSE '{}'::jsonb END, ARRAY['costo_centavos']);
END $$;

-- Venta nueva de un cambio (reemplaza la de 038; misma firma). A4: en un cambio exacto de una
-- venta que todavía debía, la devolución primero rebajó esa deuda; esa parte se vuelve a
-- deber en la venta nueva (al crédito): el cliente queda debiendo lo mismo que antes.
CREATE OR REPLACE FUNCTION interno.venta_de_cambio(d public.devolucion, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v      public.venta;
  v_pag  jsonb;
  r      jsonb;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = d.venta_id;
  v_pag := CASE WHEN d.cambio_centavos > 0
                THEN jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'monto_centavos', d.cambio_centavos, 'saldo_favor_id', d.saldo_favor_id))
                ELSE '[]'::jsonb END
           || coalesce(d.cambio->'pagos', '[]'::jsonb);
  IF coalesce((d.cambio->>'exacto')::boolean, false) AND d.cxc_centavos > 0
     AND coalesce(d.cambio->'pagos', 'null'::jsonb) IN ('null'::jsonb, '[]'::jsonb) THEN
    v_pag := v_pag || jsonb_build_array(jsonb_build_object('forma', 'credito', 'monto_centavos', d.cxc_centavos));
  END IF;
  -- 0.9.1: solo aquí se acepta "saldo_favor_id" (el lote de esta devolución).
  PERFORM set_config('app.lote_cambio', coalesce(d.saldo_favor_id::text, ''), true);
  r := interno.registrar_venta_base(d.empresa_id,
         jsonb_strip_nulls(jsonb_build_object('cliente_id', v.cliente_id, 'lineas', d.cambio->'lineas',
           'descuento_factura', d.cambio->'descuento_factura', 'caja_id', to_jsonb(d.caja_id), 'bodega_id', d.cambio->'bodega_id',
           'tipo_documento', d.cambio->'tipo_documento', 'fecha', to_char(d.fecha_contable, 'YYYY-MM-DD'),
           'nota', 'Cambio de producto (nota de crédito ' || d.numero_documento || ')', 'equipo', d.equipo, 'pagos', v_pag)),
         md5(p_id_operacion::text || ':cambio')::uuid);
  PERFORM set_config('app.lote_cambio', '', true);
  IF r->>'estado' <> 'emitida' THEN
    RAISE EXCEPTION 'APROBACION_REQUERIDA: la venta del cambio necesita aprobación (%); haga el cambio dentro de su tope o que lo haga quien aprueba.',
      r->'requiere_aprobacion';
  END IF;
  UPDATE public.devolucion SET venta_cambio_id = (r->>'venta_id')::uuid WHERE id = d.id;
  RETURN r;
END $$;

-- Respuesta de una devolución (reemplaza la de 035; misma firma): además el ajuste mayorista.
CREATE OR REPLACE FUNCTION interno.devolucion_respuesta(d public.devolucion, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('devolucion_id', d.id, 'numero', d.numero, 'estado', d.estado, 'venta_id', d.venta_id,
    'tipo_documento', d.tipo_documento, 'numero_documento', d.numero_documento, 'fecha', to_char(d.fecha_contable, 'YYYY-MM-DD'),
    'subtotal_centavos', d.subtotal_centavos, 'impuesto_centavos', d.impuesto_centavos, 'total_centavos', d.total_centavos,
    'costo_centavos', d.costo_centavos, 'cxc_centavos', d.cxc_centavos, 'dinero_centavos', d.dinero_centavos,
    'saldo_favor_centavos', d.saldo_favor_centavos, 'cambio_centavos', d.cambio_centavos,
    'saldo_favor', (SELECT jsonb_build_object('saldo_favor_id', s.id, 'codigo', s.codigo, 'vence_el', to_char(s.vence_el, 'YYYY-MM-DD'))
                      FROM public.saldo_favor s WHERE s.id = d.saldo_favor_id),
    'venta_cambio_id', d.venta_cambio_id, 'aprobacion_id', d.aprobacion_id, 'asiento_id', d.asiento_id, 'duplicado', p_duplicado,
    'ajuste_mayorista_centavos', d.ajuste_mayorista_centavos,
    'valor_centavos', d.total_centavos + d.ajuste_mayorista_centavos,
    'ajuste_mayorista_texto', CASE WHEN d.ajuste_mayorista_centavos > 0
                                   THEN 'Ajuste por perder precio mayorista: ' || interno.lempiras(d.ajuste_mayorista_centavos)
                                   WHEN d.ajuste_mayorista_centavos < 0
                                   THEN 'Se devuelve el ajuste por precio mayorista: ' || interno.lempiras(-d.ajuste_mayorista_centavos) END)
$$;

-- =====================================================================
-- 4) Lecturas previas (no guardan nada)
-- =====================================================================
-- calcular_devolucion_previa(venta, {"lineas":[{"linea","cantidad"}]}) (ventas.devolver)
--   Lo que vale lo devuelto, el ajuste por perder el precio mayorista (A1), lo que se
--   devuelve, cuánto rebaja lo que la venta todavía debe y cuánto le queda al cliente.
--   Sin costos. Venta de otra sucursal (usuario limitado): SUCURSAL_NO_PERMITIDA.
CREATE FUNCTION public.calcular_devolucion_previa(p_venta_id uuid, p_datos jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v     public.venta;
  m     jsonb;
  v_tot bigint;
  v_cxc bigint;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la venta no existe.';
  END IF;
  PERFORM interno.exigir_lectura(v.empresa_id, 'ventas.devolver');
  PERFORM interno.exigir_sucursal(v.empresa_id, v.sucursal_id);
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: faltan las líneas que se devuelven.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['lineas']);
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: solo se devuelve de una venta emitida (esta está %).', v.estado;
  END IF;
  m := interno.montos_devolucion(v, p_datos->'lineas');
  v_tot := (m->>'total')::bigint;
  v_cxc := least(greatest(v_tot, 0), greatest(interno.saldo_documento_cxc(v.id), 0));
  RETURN jsonb_build_object('venta_id', v.id, 'numero_documento', v.numero_documento, 'cliente_nombre', v.cliente_nombre,
    'lineas', (SELECT coalesce(jsonb_agg(jsonb_build_object('linea_venta', y->'linea_venta', 'descripcion', y->'descripcion',
                 'cantidad', y->'cantidad', 'valor_centavos', y->'valor', 'ajuste_mayorista_centavos', y->'ajuste',
                 'ajuste_texto', y->'ajuste_texto', 'total_centavos', y->'total', 'base_centavos', y->'base',
                 'impuesto_centavos', y->'impuesto', 'conserva', y->'conserva', 'mayorista_desde', y->'mayorista_desde')), '[]')
                 FROM jsonb_array_elements(m->'lineas') y),
    'valor_centavos', (m->>'valor')::bigint, 'ajuste_mayorista_centavos', (m->>'ajuste')::bigint,
    'total_centavos', v_tot, 'subtotal_centavos', (m->>'base')::bigint, 'impuesto_centavos', (m->>'impuesto')::bigint,
    'rebaja_deuda_centavos', v_cxc, 'para_el_cliente_centavos', greatest(v_tot, 0) - v_cxc,
    'ajuste_mayorista_texto', CASE WHEN (m->>'ajuste')::bigint > 0
                                   THEN 'Ajuste por perder precio mayorista: ' || interno.lempiras((m->>'ajuste')::bigint)
                                   WHEN (m->>'ajuste')::bigint < 0
                                   THEN 'Se devuelve el ajuste por precio mayorista: ' || interno.lempiras(-(m->>'ajuste')::bigint) END,
    'nota', 'Cálculo previo: no se guardó nada. Lo devuelto primero rebaja lo que la venta todavía debe.');
END $$;

-- calcular_cambio_previo (la de 052 en interno, misma firma; la pública de 054 anota el
-- cliente). Ahora con los montos de interno.montos_devolucion (A1), la venta nueva con el
-- cliente de la venta (mayorista igual que al registrar) y, con la regla cambio_exacto (A4):
-- "cambio_exacto": true, "exacto", "falta_centavos" / "sobra_centavos" (contra lo devuelto),
-- "a_credito_centavos" (lo que rebaja la deuda vuelve a deberse en la venta nueva) y
-- "opciones_diferencia" vacía. "puede_devolver_dinero": si el dueño permite devolver todo el dinero.
CREATE OR REPLACE FUNCTION interno.calcular_cambio_previo_052(p_venta_id uuid, p_datos jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v       public.venta;
  e       public.empresa;
  m       jsonb;
  v_total bigint;
  v_fecha date;
  v_nueva jsonb;
  v_tnuevo bigint;
  v_cxc   bigint;
  v_resto bigint;
  v_dif   bigint;
  v_rol   text;
  v_tope  bigint;
  v_opc   jsonb := '[]';
  v_ex    boolean;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la venta no existe.';
  END IF;
  PERFORM interno.exigir_lectura(v.empresa_id, 'ventas.devolver');
  PERFORM interno.exigir_sucursal(v.empresa_id, v.sucursal_id);
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: faltan los datos del cambio.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['lineas', 'cambio', 'fecha']);
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: solo se devuelve de una venta emitida (esta está %).', v.estado;
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = v.empresa_id;
  IF NOT 'cambio_producto' = ANY (e.devolucion_tipos) THEN
    RAISE EXCEPTION 'DEVOLUCION_NO_PERMITIDA: el dueño no permite el cambio de producto (permitidos: %).', array_to_string(e.devolucion_tipos, ', ');
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), greatest(public.hoy_local(v.empresa_id), v.fecha_contable));
  m := interno.montos_devolucion(v, p_datos->'lineas');
  v_total := (m->>'total')::bigint;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: el valor devuelto debe ser mayor que cero.';
  END IF;
  IF (m->>'hay_servicio')::boolean THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: un servicio se devuelve como nota de crédito o dinero, no como cambio de producto.';
  END IF;
  IF jsonb_typeof(p_datos->'cambio') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el producto nuevo ("cambio": {"lineas": [...]}).';
  END IF;
  PERFORM interno.exigir_claves(p_datos->'cambio', ARRAY['lineas', 'descuento_factura']);
  -- La venta nueva, con el cliente de la venta (como al registrar el cambio).
  v_nueva := public.calcular_venta_previa(v.empresa_id, jsonb_strip_nulls(jsonb_build_object('lineas', p_datos->'cambio'->'lineas',
               'descuento_factura', p_datos->'cambio'->'descuento_factura', 'fecha', to_char(v_fecha, 'YYYY-MM-DD'),
               'cliente_id', v.cliente_id)));
  v_tnuevo := (v_nueva->>'total_centavos')::bigint;
  -- Reparto como al aplicar: primero lo que la venta todavía debe; lo demás paga el cambio.
  v_cxc := least(v_total, greatest(interno.saldo_documento_cxc(v.id), 0));
  v_resto := v_total - v_cxc;
  v_dif := v_tnuevo - v_resto;
  v_ex := e.cambio_exacto;
  IF v_dif < 0 AND NOT v_ex THEN
    IF 'devolver_dinero' = ANY (e.devolucion_tipos) THEN
      v_opc := v_opc || jsonb_build_object('diferencia', 'dinero', 'texto', 'Devolver la diferencia en dinero');
    END IF;
    IF 'nota_credito' = ANY (e.devolucion_tipos) THEN
      v_opc := v_opc || jsonb_build_object('diferencia', 'saldo_favor',
        'texto', CASE WHEN v.cliente_id IS NULL THEN 'Dejar la diferencia en un vale (código para una próxima compra)'
                      ELSE 'Dejar la diferencia como saldo a favor del cliente' END);
    END IF;
  END IF;
  v_rol := public.mi_rol(v.empresa_id);
  IF v_rol <> 'dueno' THEN
    SELECT x.sin_aprobacion INTO v_tope FROM interno.tope_rol(v.empresa_id, v_rol, 'devolucion') x;
  END IF;
  RETURN jsonb_build_object(
    'venta_id', v.id, 'numero_documento', v.numero_documento, 'cliente_id', v.cliente_id, 'cliente_nombre', v.cliente_nombre,
    'fecha', to_char(v_fecha, 'YYYY-MM-DD'),
    'devuelto', jsonb_build_object('lineas', (SELECT coalesce(jsonb_agg(jsonb_build_object('linea_venta', y->'linea_venta',
                    'producto_id', y->'producto_id', 'descripcion', y->'descripcion', 'cantidad', y->'cantidad',
                    'total_centavos', y->'total', 'base_centavos', y->'base', 'impuesto_centavos', y->'impuesto',
                    'valor_centavos', y->'valor', 'ajuste_mayorista_centavos', y->'ajuste', 'ajuste_texto', y->'ajuste_texto')), '[]')
                    FROM jsonb_array_elements(m->'lineas') y),
                  'total_centavos', v_total, 'valor_centavos', (m->>'valor')::bigint, 'ajuste_mayorista_centavos', (m->>'ajuste')::bigint),
    'ajuste_mayorista_centavos', (m->>'ajuste')::bigint,
    'rebaja_deuda_centavos', v_cxc, 'para_el_cambio_centavos', v_resto,
    'nuevo', v_nueva,
    'total_nuevo_centavos', v_tnuevo,
    'a_cobrar_centavos', greatest(v_dif, 0), 'a_favor_cliente_centavos', greatest(-v_dif, 0),
    'opciones_diferencia', v_opc,
    'cambio_exacto', v_ex,
    'exacto', v_tnuevo = v_total,
    'falta_centavos', greatest(v_total - v_tnuevo, 0), 'sobra_centavos', greatest(v_tnuevo - v_total, 0),
    'a_credito_centavos', CASE WHEN v_ex THEN v_cxc ELSE 0 END,
    'puede_devolver_dinero', 'devolver_dinero' = ANY (e.devolucion_tipos),
    'pasa_tope', v_rol <> 'dueno' AND v_total > coalesce(v_tope, 0),
    'tope_centavos', v_tope,
    'nota', CASE WHEN v_ex
              THEN 'Cálculo previo: no se guardó nada. En este negocio el cambio debe valer exactamente lo devuelto; si no, se devuelve todo el dinero.'
              ELSE 'Cálculo previo: no se guardó nada. Lo devuelto primero rebaja lo que la venta todavía debe; lo demás paga el producto nuevo.' END);
END $$;

-- Nota de crédito impresa (reemplaza la de 035; misma firma): por línea "valor_centavos" y
-- "ajuste_mayorista_centavos"; arriba "valor_devuelto_centavos", "ajuste_mayorista_centavos" y
-- "ajuste_mayorista_texto" ("Ajuste por perder precio mayorista: L X").
CREATE OR REPLACE FUNCTION public.documento_nota_credito(p_devolucion_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d   public.devolucion;
  v   public.venta;
  e   public.empresa;
BEGIN
  SELECT * INTO d FROM public.devolucion WHERE id = p_devolucion_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la devolución no existe.';
  END IF;
  IF auth.uid() IS NULL OR NOT (public.mi_rol(d.empresa_id) IS NOT NULL AND auth.uid() = d.creado_por) THEN
    PERFORM interno.exigir_lectura(d.empresa_id, 'ventas.ver');
  END IF;
  IF d.numero_documento IS NULL THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la devolución #% está % ; todavía no tiene nota de crédito.', d.numero, d.estado;
  END IF;
  SELECT * INTO v FROM public.venta WHERE id = d.venta_id;
  SELECT * INTO e FROM public.empresa WHERE id = d.empresa_id;
  RETURN jsonb_build_object('tipo', 'NOTA DE CRÉDITO', 'numero_documento', d.numero_documento,
    'fecha', to_char(d.fecha_contable, 'DD/MM/YYYY'), 'fecha_iso', to_char(d.fecha_contable, 'YYYY-MM-DD'),
    'emisor', jsonb_build_object('nombre', v.emisor_nombre, 'rtn', v.emisor_rtn),
    'cliente', jsonb_build_object('nombre', v.cliente_nombre, 'rtn', v.cliente_rtn),
    'documento_que_modifica', v.numero_documento, 'motivo', d.motivo,
    'lineas', (SELECT jsonb_agg(jsonb_build_object('linea', l.linea, 'cantidad', l.cantidad, 'descripcion', l.descripcion,
                 'impuesto', l.tipo_impuesto, 'base_centavos', l.base_centavos, 'impuesto_centavos', l.impuesto_centavos,
                 'total_centavos', l.total_centavos, 'valor_centavos', l.total_centavos + l.ajuste_mayorista_centavos,
                 'ajuste_mayorista_centavos', l.ajuste_mayorista_centavos) ORDER BY l.linea)
                 FROM public.devolucion_linea l WHERE l.devolucion_id = d.id),
    'totales', jsonb_build_object('subtotal_centavos', d.subtotal_centavos, 'impuestos', d.desglose_impuestos,
                 'impuesto_centavos', d.impuesto_centavos, 'total_centavos', d.total_centavos,
                 'total_en_letras', interno.monto_en_letras(d.total_centavos, e.moneda), 'moneda', e.moneda),
    'valor_devuelto_centavos', d.total_centavos + d.ajuste_mayorista_centavos,
    'ajuste_mayorista_centavos', d.ajuste_mayorista_centavos,
    'ajuste_mayorista_texto', CASE WHEN d.ajuste_mayorista_centavos > 0
                                   THEN 'Ajuste por perder precio mayorista: ' || interno.lempiras(d.ajuste_mayorista_centavos)
                                   WHEN d.ajuste_mayorista_centavos < 0
                                   THEN 'Se devuelve el ajuste por precio mayorista: ' || interno.lempiras(-d.ajuste_mayorista_centavos) END,
    'aplicacion', jsonb_build_object('rebaja_cxc_centavos', d.cxc_centavos, 'dinero_centavos', d.dinero_centavos,
                 'saldo_favor_centavos', d.saldo_favor_centavos, 'cambio_centavos', d.cambio_centavos,
                 'vale', (SELECT s.codigo FROM public.saldo_favor s WHERE s.id = d.saldo_favor_id)),
    'fiscal', CASE WHEN d.regimen_fiscal = 'fiscal_hn' THEN jsonb_build_object('regimen', 'fiscal_hn', 'cai', d.datos_fiscales->>'cai',
                 'rango_autorizado', (d.datos_fiscales->>'rango_desde') || ' al ' || (d.datos_fiscales->>'rango_hasta'),
                 'fecha_limite_emision', to_char((d.datos_fiscales->>'fecha_limite_emision')::date, 'DD/MM/YYYY'),
                 'leyendas', jsonb_build_array('Nota de crédito que modifica la factura ' || v.numero_documento,
                                               'Original: Cliente. Copia: Obligado tributario emisor.'))
                   ELSE jsonb_build_object('regimen', NULL, 'leyendas', jsonb_build_array('Documento interno, sin valor fiscal.')) END);
END $$;

-- Garantías: sin ajuste mayorista (el producto vino malo). resolver_reclamo_garantia de 054
-- pasa a interno sin cambios; la pública lo anota (app.devolucion_garantia) y la llama.
ALTER FUNCTION public.resolver_reclamo_garantia(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.resolver_reclamo_garantia(uuid, jsonb, uuid) RENAME TO resolver_reclamo_garantia_054;
CREATE FUNCTION public.resolver_reclamo_garantia(p_reclamo_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_prev text := coalesce(current_setting('app.devolucion_garantia', true), '');
  r      jsonb;
BEGIN
  PERFORM set_config('app.devolucion_garantia', '1', true);
  r := interno.resolver_reclamo_garantia_054(p_reclamo_id, p_datos, p_id_operacion);
  PERFORM set_config('app.devolucion_garantia', v_prev, true);
  RETURN r;
END $$;

-- =====================================================================
-- 5) A4: la regla "cambio_exacto" en configurar_empresa (solo el dueño, con motivo
--    y bitácora). La de 037 pasa a interno sin cambios; la pública acepta además
--    "cambio_exacto": true | false y devuelve su valor.
-- =====================================================================
ALTER FUNCTION public.configurar_empresa(uuid, jsonb, text) SET SCHEMA interno;
ALTER FUNCTION interno.configurar_empresa(uuid, jsonb, text) RENAME TO configurar_empresa_037;
CREATE FUNCTION public.configurar_empresa(p_empresa_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r     jsonb;
  v_ex  boolean;
BEGIN
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' OR NOT p_datos ? 'cambio_exacto' THEN
    RETURN interno.configurar_empresa_037(p_empresa_id, p_datos, p_motivo)
           || jsonb_build_object('cambio_exacto', (SELECT x.cambio_exacto FROM public.empresa x WHERE x.id = p_empresa_id));
  END IF;
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF jsonb_typeof(p_datos->'cambio_exacto') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "cambio_exacto" debe ser true o false.';
  END IF;
  IF p_datos - 'cambio_exacto' <> '{}'::jsonb THEN
    r := interno.configurar_empresa_037(p_empresa_id, p_datos - 'cambio_exacto', p_motivo);
  END IF;
  v_ex := (p_datos->>'cambio_exacto')::boolean;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET cambio_exacto = v_ex WHERE id = p_empresa_id AND cambio_exacto IS DISTINCT FROM v_ex;
  PERFORM set_config('app.motivo', '', true);
  RETURN coalesce(r, '{}'::jsonb) || jsonb_build_object('cambio_exacto', v_ex);
END $$;

-- =====================================================================
-- 6) A3: estado de cuenta de un socio
-- =====================================================================
-- Movimientos de un socio, cada uno en SU fecha (las anulaciones en la fecha de anulación).
CREATE FUNCTION interno.movimientos_socio(p_empresa_id uuid, p_socio_id uuid)
RETURNS TABLE (fecha date, momento timestamptz, orden integer, tipo text, texto text, invertido bigint, por_pagar bigint,
               documento_id uuid, numero bigint, detalle text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH meses(m) AS (SELECT ARRAY['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre',
                                 'octubre', 'noviembre', 'diciembre'])
  SELECT a.fecha_contable, a.registrado_en, 1, 'aporte', 'Aporte de capital #' || a.numero, a.monto_centavos, 0::bigint, a.id, a.numero,
         concat_ws(' · ', 'entró a ' || d.nombre, a.referencia, a.nota)
    FROM public.socio_aporte a JOIN public.cuenta_dinero d ON d.id = a.cuenta_dinero_id
   WHERE a.empresa_id = p_empresa_id AND a.socio_id = p_socio_id
  UNION ALL
  SELECT a.fecha_anulacion, a.anulada_en, 2, 'aporte_anulado', 'Aporte #' || a.numero || ' anulado', -a.monto_centavos, 0::bigint, a.id, a.numero,
         a.motivo_anulacion
    FROM public.socio_aporte a
   WHERE a.empresa_id = p_empresa_id AND a.socio_id = p_socio_id AND a.anulada_en IS NOT NULL
  UNION ALL
  SELECT x.fecha_contable, x.registrado_en, 3, 'reparto',
         'Reparto de utilidad de ' || (SELECT m[x.mes] FROM meses) || ' de ' || x.anio || ' (#' || x.numero || ')',
         0::bigint, dd.monto_centavos, x.id, x.numero, trim_scale(dd.porcentaje) || ' % de la utilidad cobrada'
    FROM public.distribucion_detalle dd JOIN public.distribucion x ON x.id = dd.distribucion_id
   WHERE x.empresa_id = p_empresa_id AND dd.socio_id = p_socio_id AND dd.monto_centavos > 0
  UNION ALL
  SELECT x.fecha_anulacion, x.anulada_en, 4, 'reparto_anulado',
         'Reparto de ' || (SELECT m[x.mes] FROM meses) || ' de ' || x.anio || ' anulado (#' || x.numero || ')',
         0::bigint, -dd.monto_centavos, x.id, x.numero, x.motivo_anulacion
    FROM public.distribucion_detalle dd JOIN public.distribucion x ON x.id = dd.distribucion_id
   WHERE x.empresa_id = p_empresa_id AND dd.socio_id = p_socio_id AND dd.monto_centavos > 0 AND x.anulada_en IS NOT NULL
  UNION ALL
  SELECT p.fecha_contable, p.registrado_en, 5, 'pago', 'Pago recibido #' || p.numero, 0::bigint, -p.monto_centavos, p.id, p.numero,
         concat_ws(' · ', 'salió de ' || d.nombre, p.referencia)
    FROM public.dividendo_pago p JOIN public.cuenta_dinero d ON d.id = p.cuenta_dinero_id
   WHERE p.empresa_id = p_empresa_id AND p.socio_id = p_socio_id
  UNION ALL
  SELECT p.fecha_anulacion, p.anulada_en, 6, 'pago_anulado', 'Pago #' || p.numero || ' anulado', 0::bigint, p.monto_centavos, p.id, p.numero,
         p.motivo_anulacion
    FROM public.dividendo_pago p
   WHERE p.empresa_id = p_empresa_id AND p.socio_id = p_socio_id AND p.anulada_en IS NOT NULL
$$;

-- estado_cuenta_socio(empresa, socio, desde?, hasta?)   fondos.ver
--   Movimientos con la fecha de cada uno (la anulación cuenta en SU fecha, como en los libros):
--     aporte (+ invertido), aporte anulado (- invertido), reparto de utilidad asignado
--     (+ por pagar), reparto anulado (- por pagar), pago recibido (- por pagar) y pago anulado
--     (+ por pagar). Saldo al empezar (antes de "desde"), saldo corrido y saldo al "hasta".
--   "total_invertido_centavos" = aportes vigentes al "hasta"; "saldo_por_pagar_centavos" =
--   repartos asignados - pagos al "hasta".
--   Cuadre con la contabilidad al "hasta": la suma de TODOS los socios contra la cuenta de
--   aportes de socios (3.1.01.04) y la de dividendos por pagar (2.1.01.03). Una sola cuenta
--   contable por concepto; el detalle por socio vive en el sistema (decisión del dueño).
--   Es información de toda la empresa: un usuario limitado a su sucursal no la ve
--   (SUCURSAL_NO_PERMITIDA).
CREATE FUNCTION public.estado_cuenta_socio(p_empresa_id uuid, p_socio_id uuid, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s       public.socio;
  v_hasta date;
  v_ini_inv bigint;
  v_ini_pp  bigint;
  v_movs  jsonb;
  v_tot   jsonb;
  v_fin_inv bigint;
  v_fin_pp  bigint;
  v_cta_ap text;
  v_cta_dv text;
  v_lib_ap bigint;
  v_lib_dv bigint;
  v_tod_ap bigint;
  v_tod_dv bigint;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'fondos.ver');
  IF interno.usuario_restringido(p_empresa_id) THEN
    RAISE EXCEPTION 'SUCURSAL_NO_PERMITIDA: el estado de cuenta de un socio es de toda la empresa; lo ve quien trabaja con todas las sucursales.';
  END IF;
  SELECT * INTO s FROM public.socio x WHERE x.id = p_socio_id AND x.empresa_id = p_empresa_id;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el socio no existe en esta empresa.';
  END IF;
  v_hasta := coalesce(p_hasta, public.hoy_local(p_empresa_id));
  IF p_desde IS NOT NULL AND p_desde > v_hasta THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: "desde" va antes que "hasta".';
  END IF;

  SELECT coalesce(sum(x.invertido), 0), coalesce(sum(x.por_pagar), 0) INTO v_ini_inv, v_ini_pp
    FROM interno.movimientos_socio(p_empresa_id, s.id) x WHERE p_desde IS NOT NULL AND x.fecha < p_desde;
  SELECT coalesce(sum(x.invertido), 0), coalesce(sum(x.por_pagar), 0) INTO v_fin_inv, v_fin_pp
    FROM interno.movimientos_socio(p_empresa_id, s.id) x WHERE x.fecha <= v_hasta;
  SELECT coalesce(jsonb_agg(jsonb_build_object('fecha', to_char(m.fecha, 'YYYY-MM-DD'), 'tipo', m.tipo, 'texto', m.texto,
           'detalle', nullif(m.detalle, ''), 'numero', m.numero, 'documento_id', m.documento_id,
           'invertido_centavos', m.invertido, 'por_pagar_centavos', m.por_pagar,
           'saldo_invertido_centavos', v_ini_inv + m.acum_inv, 'saldo_por_pagar_centavos', v_ini_pp + m.acum_pp)
           ORDER BY m.fecha, m.momento, m.orden, m.numero), '[]')
    INTO v_movs
    FROM (SELECT x.*, sum(x.invertido) OVER w AS acum_inv, sum(x.por_pagar) OVER w AS acum_pp
            FROM interno.movimientos_socio(p_empresa_id, s.id) x
           WHERE (p_desde IS NULL OR x.fecha >= p_desde) AND x.fecha <= v_hasta
          WINDOW w AS (ORDER BY x.fecha, x.momento, x.orden, x.numero ROWS UNBOUNDED PRECEDING)) m;
  SELECT jsonb_build_object(
           'aportes_centavos', coalesce(sum(x.invertido) FILTER (WHERE x.tipo = 'aporte'), 0),
           'aportes_anulados_centavos', coalesce(-sum(x.invertido) FILTER (WHERE x.tipo = 'aporte_anulado'), 0),
           'repartos_centavos', coalesce(sum(x.por_pagar) FILTER (WHERE x.tipo = 'reparto'), 0),
           'repartos_anulados_centavos', coalesce(-sum(x.por_pagar) FILTER (WHERE x.tipo = 'reparto_anulado'), 0),
           'pagos_centavos', coalesce(-sum(x.por_pagar) FILTER (WHERE x.tipo = 'pago'), 0),
           'pagos_anulados_centavos', coalesce(sum(x.por_pagar) FILTER (WHERE x.tipo = 'pago_anulado'), 0),
           'movimientos', count(*))
    INTO v_tot
    FROM interno.movimientos_socio(p_empresa_id, s.id) x WHERE (p_desde IS NULL OR x.fecha >= p_desde) AND x.fecha <= v_hasta;

  -- Cuadre con los libros al "hasta": todos los socios contra las dos cuentas.
  v_cta_ap := interno.cuenta_de(p_empresa_id, 'aportes_socios');
  v_cta_dv := interno.cuenta_de(p_empresa_id, 'dividendos_por_pagar');
  v_lib_ap := interno.saldo_libros_al(p_empresa_id, v_cta_ap, v_hasta);
  v_lib_dv := interno.saldo_libros_al(p_empresa_id, v_cta_dv, v_hasta);
  SELECT coalesce(sum(a.monto_centavos), 0) INTO v_tod_ap FROM public.socio_aporte a
   WHERE a.empresa_id = p_empresa_id AND a.fecha_contable <= v_hasta AND NOT (a.anulada_en IS NOT NULL AND a.fecha_anulacion <= v_hasta);
  SELECT coalesce((SELECT sum(dd.monto_centavos) FROM public.distribucion_detalle dd JOIN public.distribucion x ON x.id = dd.distribucion_id
                    WHERE x.empresa_id = p_empresa_id AND dd.socio_id IS NOT NULL AND x.fecha_contable <= v_hasta
                      AND NOT (x.anulada_en IS NOT NULL AND x.fecha_anulacion <= v_hasta)), 0)
       - coalesce((SELECT sum(p.monto_centavos) FROM public.dividendo_pago p
                    WHERE p.empresa_id = p_empresa_id AND p.fecha_contable <= v_hasta
                      AND NOT (p.anulada_en IS NOT NULL AND p.fecha_anulacion <= v_hasta)), 0)
    INTO v_tod_dv;

  RETURN jsonb_build_object('titulo', 'Estado de cuenta del socio', 'empresa', interno.encabezado_empresa(p_empresa_id),
    'socio', jsonb_build_object('socio_id', s.id, 'nombre', s.nombre, 'porcentaje', s.porcentaje, 'activo', s.activo),
    'desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(v_hasta, 'YYYY-MM-DD'),
    'saldo_inicial', jsonb_build_object('invertido_centavos', v_ini_inv, 'por_pagar_centavos', v_ini_pp),
    'movimientos', v_movs, 'totales', v_tot,
    'saldo_final', jsonb_build_object('invertido_centavos', v_fin_inv, 'por_pagar_centavos', v_fin_pp),
    'total_invertido_centavos', v_fin_inv, 'saldo_por_pagar_centavos', v_fin_pp,
    'cuadre', jsonb_build_object(
      'cuenta_aportes', v_cta_ap, 'aportes_todos_los_socios_centavos', v_tod_ap, 'aportes_libros_centavos', v_lib_ap,
      'cuenta_dividendos', v_cta_dv, 'por_pagar_todos_los_socios_centavos', v_tod_dv, 'dividendos_libros_centavos', v_lib_dv,
      'cuadra', v_tod_ap = v_lib_ap AND v_tod_dv = v_lib_dv),
    'generado_en', public.iso(now()),
    'nota', 'Aportes: capital que el socio metió al negocio (patrimonio, cuenta ' || v_cta_ap || '). Repartos: su parte de la utilidad cobrada; '
            || 'lo que todavía no se le paga está en ' || v_cta_dv || '. Una cuenta por concepto; el detalle por socio está aquí.');
END $$;

-- =====================================================================
-- 7) Vista de devoluciones (reemplaza la de 035; mismas columnas + el ajuste al final)
-- =====================================================================
CREATE OR REPLACE VIEW public.v_devolucion AS
  SELECT d.empresa_id, d.id AS devolucion_id, d.numero, d.estado, d.venta_id, v.numero_documento AS venta_documento,
         d.tipo_documento, d.numero_documento, d.fecha_contable, d.cliente_id, d.cliente_nombre, d.motivo, d.destino,
         d.subtotal_centavos, d.impuesto_centavos, d.total_centavos, d.cxc_centavos, d.dinero_centavos, d.saldo_favor_centavos,
         d.cambio_centavos, d.venta_cambio_id, d.aprobacion_id,
         CASE WHEN x.costos THEN d.costo_centavos END AS costo_centavos,
         d.creado_por, public.nombre_usuario(d.empresa_id, d.creado_por) AS registrado_por, d.registrado_en,
         d.ajuste_mayorista_centavos
  FROM public.devolucion d
  JOIN public.venta v ON v.id = d.venta_id
  CROSS JOIN LATERAL (SELECT d.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
                             AND d.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))) AS costos) x
  WHERE d.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
     OR (d.empresa_id IN (SELECT public.mis_empresas()) AND d.creado_por = (SELECT auth.uid()));

-- =====================================================================
-- 8) Seguridad
-- =====================================================================
REVOKE EXECUTE ON FUNCTION
  interno.mayorista_de_linea(), interno.montos_devolucion(public.venta, jsonb), interno.movimientos_socio(uuid, uuid),
  interno.resolver_reclamo_garantia_054(uuid, jsonb, uuid), interno.configurar_empresa_037(uuid, jsonb, text)
FROM PUBLIC, anon, authenticated, service_role;
-- Lecturas.
REVOKE EXECUTE ON FUNCTION
  public.calcular_devolucion_previa(uuid, jsonb), public.estado_cuenta_socio(uuid, uuid, date, date)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.calcular_devolucion_previa(uuid, jsonb), public.estado_cuenta_socio(uuid, uuid, date, date)
TO authenticated, service_role;
-- Escrituras (solo con sesión de usuario), como antes.
REVOKE EXECUTE ON FUNCTION
  public.resolver_reclamo_garantia(uuid, jsonb, uuid), public.configurar_empresa(uuid, jsonb, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.resolver_reclamo_garantia(uuid, jsonb, uuid), public.configurar_empresa(uuid, jsonb, text)
TO authenticated;
