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
    -- Revisión 0.19.0: una devolución pendiente de aprobación entra en la cuenta acumulada de esta; si después se
    -- rechazara, esta quedaría pagada de más (con el ajuste mayorista). Primero se resuelve la pendiente.
    IF EXISTS (SELECT 1 FROM public.devolucion_linea x JOIN public.devolucion y ON y.id = x.devolucion_id
                WHERE x.venta_linea_id = vl.id AND y.estado = 'pendiente_aprobacion') THEN
      RAISE EXCEPTION 'DEVOLUCION_INVALIDA: hay una devolución de "%" de esta venta esperando aprobación; resuélvala primero (que la aprueben o la rechacen) y después registre esta.',
        vl.descripcion;
    END IF;
    v_r := q0 + q;
    v_k := vl.cantidad - v_r;
    t_acum := round(vl.total_centavos * v_r / vl.cantidad)::bigint;
    b_acum := round(vl.base_centavos * v_r / vl.cantidad)::bigint;

    -- A1: ¿pierde el precio mayorista lo que se queda?
    a_tot := 0;  a_base := 0;  v_cand := false;  v_desde := NULL;
    IF vl.precio_tipo = 'mayorista' AND NOT v_gar AND vl.precio_normal_centavos IS NOT NULL THEN
      v_desde := coalesce(vl.mayorista_desde, (SELECT x.cantidad_mayorista FROM public.producto x WHERE x.id = vl.producto_id));
      -- Líneas de antes de 0.19.0 (sin mayorista_por): cliente mayorista hoy, o vendida con menos que "desde
      -- cantidad" (solo pudo ser por cliente) = "por cliente" (sin ajuste).
      v_por := coalesce(vl.mayorista_por,
                        CASE WHEN EXISTS (SELECT 1 FROM public.tercero t WHERE t.id = v.cliente_id AND t.es_cliente AND t.es_mayorista)
                                  OR vl.cantidad < coalesce(v_desde, 0) THEN 'cliente' ELSE 'cantidad' END);
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
    IF v_gar THEN
      -- Garantía (revisión 0.19.0): solo el valor proporcional de estas unidades; un ajuste mayorista ya cobrado en
      -- una devolución anterior se mantiene (no se le devuelve al cliente).
      v_tot := v_valor;
      v_aj := 0;
      v_base := least(greatest(b_acum - round(vl.base_centavos * q0 / vl.cantidad)::bigint, 0), greatest(v_tot, 0));
      v_imp := greatest(v_tot, 0) - v_base;
    ELSIF v_cand THEN
      v_aj := v_valor - v_tot;
      IF v_tot <= 0 THEN
        RAISE EXCEPTION 'DEVOLUCION_INVALIDA: de "%" se quedaría con % y el precio mayorista es desde %: lo que se queda pasa a precio normal y el ajuste (%) es igual o mayor que lo que se le devolvería (%). No queda nada que devolver: devuelva más unidades (o todas) o no haga la devolución.',
          vl.descripcion, trim_scale(v_k), trim_scale(v_desde), interno.lempiras(v_aj), interno.lempiras(v_valor);
      END IF;
    ELSE
      v_aj := 0;
      v_valor := greatest(v_tot, 0);
    END IF;
    IF NOT v_gar THEN
      v_base := least(greatest((b_acum - a_base) - b0, 0), greatest(v_tot, 0));
      v_imp := greatest(v_tot, 0) - v_base;
    END IF;
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
  -- Revisión 0.19.0: el crédito "de vuelta" (hasta lo que la devolución rebajó de la deuda) no pide aprobación de
  -- crédito ni cuenta para el límite, y la venta nueva vence cuando vencía la original (la antigüedad no se reinicia).
  IF d.cxc_centavos > 0 THEN
    PERFORM set_config('app.credito_de_cambio', d.cxc_centavos::text, true);
    PERFORM set_config('app.vence_de_cambio', coalesce(to_char(v.vence_el, 'YYYY-MM-DD'), ''), true);
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
  PERFORM set_config('app.credito_de_cambio', '', true);
  PERFORM set_config('app.vence_de_cambio', '', true);
  IF r->>'estado' <> 'emitida' THEN
    RAISE EXCEPTION 'APROBACION_REQUERIDA: la venta del cambio necesita aprobación (%); haga el cambio dentro de su tope o que lo haga quien aprueba.',
      r->'requiere_aprobacion';
  END IF;
  UPDATE public.devolucion SET venta_cambio_id = (r->>'venta_id')::uuid WHERE id = d.id;
  RETURN r;
END $$;

-- Registrar una venta (reemplaza la de 054; misma firma y el mismo código) con un solo cambio (revisión 0.19.0):
-- el crédito "de vuelta" de un cambio de producto (app.credito_de_cambio, lo anota interno.venta_de_cambio) no pide
-- aprobación de crédito ni cuenta para el límite del cliente, porque su deuda no sube.
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
    -- 0.19.0: el crédito "de vuelta" de un cambio (la deuda que la devolución rebajó vuelve a la venta nueva) no
    -- cuenta para la regla de crédito ni para el límite: la deuda del cliente no sube (app.credito_de_cambio).
    IF v_cred > 0 AND v_cred > coalesce(nullif(current_setting('app.credito_de_cambio', true), '')::bigint, 0) THEN
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

-- Revisión 0.19.0: la venta nueva de un cambio con deuda vence cuando vencía la original (app.vence_de_cambio, lo
-- anota interno.venta_de_cambio): la antigüedad de saldos no se reinicia. "vence_el" es de lo que se llena al emitir.
CREATE FUNCTION interno.vence_de_cambio() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.estado IS DISTINCT FROM 'emitida' AND NEW.estado = 'emitida' AND NEW.credito_centavos > 0
     AND nullif(current_setting('app.vence_de_cambio', true), '') IS NOT NULL THEN
    NEW.vence_el := current_setting('app.vence_de_cambio', true)::date;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER a_vence_de_cambio BEFORE UPDATE ON public.venta FOR EACH ROW EXECUTE FUNCTION interno.vence_de_cambio();

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
  v_garp  boolean := false;
  v_res   jsonb;
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
  PERFORM interno.exigir_claves(p_datos, ARRAY['lineas', 'cambio', 'fecha', 'reclamo_id']);
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: solo se devuelve de una venta emitida (esta está %).', v.estado;
  END IF;
  -- Revisión 0.19.0: el cambio por garantía (reclamo de esta venta) se calcula como lo registra
  -- resolver_reclamo_garantia: sin ajuste mayorista.
  IF coalesce(p_datos->'reclamo_id', 'null'::jsonb) <> 'null'::jsonb THEN
    IF NOT EXISTS (SELECT 1 FROM public.garantia_reclamo g WHERE g.id = interno.json_uuid(p_datos->'reclamo_id', 'reclamo_id')
                    AND g.venta_id = v.id) THEN
      RAISE EXCEPTION 'GARANTIA_INVALIDA: el reclamo no es de esta venta.';
    END IF;
    v_garp := true;
    PERFORM set_config('app.devolucion_garantia', '1', true);
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
  IF v_garp THEN
    PERFORM set_config('app.devolucion_garantia', '', true);
  END IF;
  v_res := jsonb_build_object(
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
  RETURN v_res || jsonb_build_object('garantia', v_garp);
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
-- La de 054, ya en interno, con un solo cambio (revisión 0.19.0): el "precio de garantía" es el valor proporcional
-- de las unidades del reclamo (un ajuste mayorista ya cobrado no se le devuelve al cliente).
CREATE OR REPLACE FUNCTION interno.resolver_reclamo_garantia_054(p_reclamo_id uuid, p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      public.garantia_reclamo;
  v_res  text;
  v_dev  jsonb;
  v_gas  jsonb;
  v_c    jsonb;
  d      jsonb;
  v_nota text;
  vl     public.venta_linea;
  v_mismo boolean;
  q0 numeric; b0 bigint; i0 bigint;
  v_gar  bigint;
  v_deu  bigint;
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
    IF (SELECT g.estado FROM public.gasto g WHERE g.id = (v_gas->>'gasto_id')::uuid) IS DISTINCT FROM 'aplicado' THEN
      RAISE EXCEPTION 'APROBACION_REQUERIDA: el costo de la reparación (%) pasa lo que su puesto registra sin aprobación; el reclamo no se cerró. Que lo resuelva quien aprueba (o registre el reclamo como reparado sin costo y el gasto aparte).',
        interno.lempiras((v_c->>'monto_centavos')::bigint);
    END IF;
  ELSIF v_res IN ('cambiado', 'devuelto') THEN
    d := jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('linea', r.linea, 'cantidad', r.cantidad)),
           'motivo', 'Garantía, reclamo #' || r.numero || ': ' || r.motivo,
           'destino', CASE v_res WHEN 'cambiado' THEN 'cambio' ELSE coalesce(p_datos->>'destino', 'dinero') END)
         || CASE WHEN p_datos ? 'cuenta_dinero_id' THEN jsonb_build_object('cuenta_dinero_id', p_datos->'cuenta_dinero_id') ELSE '{}' END
         || CASE WHEN p_datos ? 'caja_id' THEN jsonb_build_object('caja_id', p_datos->'caja_id') ELSE '{}' END;
    IF v_res = 'cambiado' THEN
      d := d || jsonb_build_object('cambio', coalesce(p_datos->'cambio',
             jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', r.producto_id, 'cantidad', r.cantidad)))));
      -- ¿Se entrega lo mismo (mismo producto y cantidad, una línea)? Entonces con precio de garantía:
      -- lo que vale lo devuelto, con la misma cuenta que registrar_devolucion (cantidad acumulada).
      v_mismo := jsonb_typeof(d->'cambio'->'lineas') = 'array' AND jsonb_array_length(d->'cambio'->'lineas') = 1
                 AND d->'cambio'->'lineas'->0->>'producto_id' = r.producto_id::text
                 AND jsonb_typeof(d->'cambio'->'lineas'->0->'cantidad') = 'number'
                 AND (d->'cambio'->'lineas'->0->>'cantidad')::numeric = r.cantidad;
      IF v_mismo THEN
        SELECT * INTO vl FROM public.venta_linea x WHERE x.venta_id = r.venta_id AND x.linea = r.linea;
        SELECT coalesce(sum(x.cantidad), 0), coalesce(sum(x.base_centavos), 0), coalesce(sum(x.impuesto_centavos), 0)
          INTO q0, b0, i0
          FROM public.devolucion_linea x JOIN public.devolucion y ON y.id = x.devolucion_id
         WHERE x.venta_linea_id = vl.id AND y.estado IN ('aplicada', 'pendiente_aprobacion', 'por_aplicar');
        -- 0.19.0: el valor proporcional de las unidades de la garantía (lo pagado por ellas). Un ajuste mayorista
        -- que ya se cobró en una devolución anterior se mantiene (igual que interno.montos_devolucion en garantía).
        v_gar := round(vl.total_centavos * (q0 + r.cantidad) / vl.cantidad)::bigint - round(vl.total_centavos * q0 / vl.cantidad)::bigint;
        PERFORM set_config('app.precio_garantia', jsonb_build_object('producto_id', r.producto_id, 'cantidad', r.cantidad,
                                                                     'total_centavos', v_gar)::text, true);
        -- Venta al crédito todavía sin pagar: la devolución primero rebaja esa deuda; lo que rebajó se vuelve a
        -- deber en la venta del cambio (al crédito). El cliente queda debiendo lo mismo que antes.
        IF NOT (d->'cambio' ? 'pagos') THEN
          v_deu := least(v_gar, greatest(interno.saldo_documento_cxc(r.venta_id), 0));
          IF v_deu > 0 THEN
            d := jsonb_set(d, '{cambio,pagos}', jsonb_build_array(jsonb_build_object('forma', 'credito', 'monto_centavos', v_deu)));
          END IF;
        END IF;
      END IF;
    END IF;
    v_dev := public.registrar_devolucion(r.venta_id, d, md5(p_id_operacion::text || ':devolucion_garantia')::uuid);
    PERFORM set_config('app.precio_garantia', '', true);
    IF (SELECT x.estado FROM public.devolucion x WHERE x.id = (v_dev->>'devolucion_id')::uuid) IS DISTINCT FROM 'aplicada' THEN
      RAISE EXCEPTION 'APROBACION_REQUERIDA: la devolución (%) pasa lo que su puesto devuelve sin aprobación; el reclamo no se cerró. Que lo resuelva quien aprueba.',
        interno.lempiras((v_dev->>'total_centavos')::bigint);
    END IF;
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
  interno.vence_de_cambio(),
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
