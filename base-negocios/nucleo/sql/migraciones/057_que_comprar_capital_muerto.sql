-- =====================================================================
-- 057_que_comprar_capital_muerto.sql  -  Núcleo 0.21.0: dos reportes de inventario
-- (ideas tomadas de RRD; solo LEEN, no cambian nada guardado).
--
--   que_comprar(empresa, dias, cubrir_dias)
--       Lo que más sale y lo que se va a acabar: por producto, lo vendido (neto de
--       devoluciones) en los últimos "dias", cuánto sale por día, lo que hay, para
--       cuántos días alcanza y cuánto conviene pedir para cubrir "cubrir_dias"
--       (o llegar al mínimo, lo que sea mayor).
--   capital_muerto(empresa, dias)
--       Productos con existencias que no se venden desde hace "dias" o más: cuánto
--       hay, la última venta y cuánto dinero hay parado ahí (al costo; solo con
--       inventario.costos).
--
-- Las dos piden inventario.ver, cuentan solo las sucursales del usuario (ventas,
-- devoluciones y bodegas) y esconden los costos sin inventario.costos.
-- Las cantidades son de la unidad del producto; con decimales solo si el producto
-- los admite (los demás se redondean hacia arriba al pedir).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('DIAS_INVALIDOS', 'El número de días no es válido.', 'Elija entre 7 y 365 días.')
;

-- Existencias por producto en las bodegas que el usuario puede ver (sus sucursales).
CREATE FUNCTION interno.existencias_permitidas(p_empresa_id uuid)
RETURNS TABLE (producto_id uuid, cantidad numeric, valor_centavos bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT s.producto_id, sum(s.cantidad), sum(s.valor_centavos)::bigint
    FROM public.inventario_saldo s JOIN public.bodega b ON b.id = s.bodega_id
   WHERE s.empresa_id = p_empresa_id AND interno.sucursal_permitida(p_empresa_id, b.sucursal_id)
   GROUP BY s.producto_id
$$;

-- Vendido neto (ventas emitidas - devoluciones aplicadas) por producto entre dos fechas, en las sucursales del usuario.
CREATE FUNCTION interno.vendido_neto(p_empresa_id uuid, p_desde date, p_hasta date)
RETURNS TABLE (producto_id uuid, cantidad numeric, ventas bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH ven AS (
    SELECT l.producto_id, sum(l.cantidad) AS cant, count(DISTINCT l.venta_id) AS ventas
      FROM public.venta_linea l JOIN public.venta v ON v.id = l.venta_id
     WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND v.fecha_contable BETWEEN p_desde AND p_hasta
       AND interno.sucursal_permitida(p_empresa_id, v.sucursal_id)
     GROUP BY l.producto_id
  ), dev AS (
    SELECT l.producto_id, sum(l.cantidad) AS cant
      FROM public.devolucion_linea l JOIN public.devolucion d ON d.id = l.devolucion_id
     WHERE d.empresa_id = p_empresa_id AND d.estado = 'aplicada' AND d.fecha_contable BETWEEN p_desde AND p_hasta
       AND interno.sucursal_permitida(p_empresa_id, d.sucursal_id)
     GROUP BY l.producto_id
  )
  SELECT coalesce(ven.producto_id, dev.producto_id), greatest(coalesce(ven.cant, 0) - coalesce(dev.cant, 0), 0), coalesce(ven.ventas, 0)
    FROM ven FULL JOIN dev ON dev.producto_id = ven.producto_id
$$;

-- ---------------------------------------------------------------------
-- 1) ¿Qué comprar más?
-- ---------------------------------------------------------------------
CREATE FUNCTION public.que_comprar(p_empresa_id uuid, p_dias integer DEFAULT 30, p_cubrir_dias integer DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy   date;
  v_desde date;
  v_filas jsonb;
  v_tot   jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'inventario.ver');
  IF p_dias IS NULL OR p_dias NOT BETWEEN 7 AND 365 OR p_cubrir_dias IS NULL OR p_cubrir_dias NOT BETWEEN 7 AND 365 THEN
    RAISE EXCEPTION 'DIAS_INVALIDOS: los días van de 7 a 365.';
  END IF;
  v_hoy := public.hoy_local(p_empresa_id);
  v_desde := v_hoy - (p_dias - 1);
  WITH x AS (
    SELECT p.id, p.codigo, p.nombre, u.codigo AS unidad, p.stock_minimo, p.permite_fracciones,
           coalesce(n.cantidad, 0) AS vendido, coalesce(n.ventas, 0) AS ventas,
           coalesce(e.cantidad, 0) AS hay, e.valor_centavos,
           coalesce(n.cantidad, 0) / p_dias AS por_dia   -- solo para mostrar
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      LEFT JOIN interno.vendido_neto(p_empresa_id, v_desde, v_hoy) n ON n.producto_id = p.id
      LEFT JOIN interno.existencias_permitidas(p_empresa_id) e ON e.producto_id = p.id
     WHERE p.empresa_id = p_empresa_id AND p.activo AND p.tipo = 'bien'
  ), y AS (
    SELECT x.*,
           -- Sin redondeos intermedios (vendido / días * cubrir daría 50.0000001 y pediría 1 de más).
           CASE WHEN x.vendido > 0 THEN floor(greatest(x.hay, 0) * p_dias / x.vendido)::integer END AS dias_alcanza,
           greatest(x.vendido * p_cubrir_dias / p_dias - x.hay, x.stock_minimo - x.hay, 0) AS falta
      FROM x
  ), z AS (
    SELECT y.*,
           CASE WHEN y.permite_fracciones THEN round(y.falta, 3) ELSE ceil(y.falta) END AS pedir,
           CASE WHEN y.hay <= 0 AND y.vendido > 0 THEN 'agotado'
                WHEN y.dias_alcanza IS NOT NULL AND y.dias_alcanza < 7 THEN 'urgente'
                WHEN y.hay < y.stock_minimo THEN 'bajo_minimo'
                WHEN round(y.falta, 3) > 0 THEN 'pedir'
                ELSE 'alcanza' END AS estado
      FROM y
     WHERE y.vendido > 0 OR y.hay < y.stock_minimo
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'producto_id', z.id, 'codigo', z.codigo, 'nombre', z.nombre, 'unidad', z.unidad,
           'vendido', z.vendido, 'ventas', z.ventas, 'por_dia', round(z.por_dia, 3),
           'hay', z.hay, 'minimo', z.stock_minimo, 'dias_alcanza', z.dias_alcanza,
           'pedir', z.pedir, 'estado', z.estado,
           -- Costo aproximado del pedido al costo promedio de lo que hay (se esconde sin inventario.costos).
           'costo_aprox_centavos', CASE WHEN z.hay > 0 AND z.valor_centavos IS NOT NULL
                                        THEN round(z.valor_centavos::numeric / z.hay * z.pedir)::bigint END)
         ORDER BY CASE z.estado WHEN 'agotado' THEN 0 WHEN 'urgente' THEN 1 WHEN 'bajo_minimo' THEN 2 WHEN 'pedir' THEN 3 ELSE 4 END,
                  z.dias_alcanza NULLS LAST, z.vendido DESC, z.nombre, z.id), '[]'),
         jsonb_build_object('productos', count(*), 'por_pedir', count(*) FILTER (WHERE z.pedir > 0),
           'agotados', count(*) FILTER (WHERE z.estado = 'agotado'), 'urgentes', count(*) FILTER (WHERE z.estado = 'urgente'),
           'costo_aprox_centavos', coalesce(sum(CASE WHEN z.hay > 0 AND z.valor_centavos IS NOT NULL
                                                     THEN round(z.valor_centavos::numeric / z.hay * z.pedir)::bigint END), 0))
    INTO v_filas, v_tot FROM z;
  RETURN interno.ocultar_costos(p_empresa_id, jsonb_build_object(
    'desde', to_char(v_desde, 'YYYY-MM-DD'), 'hasta', to_char(v_hoy, 'YYYY-MM-DD'), 'dias', p_dias, 'cubrir_dias', p_cubrir_dias,
    'filas', v_filas, 'total', v_tot, 'solo_mis_sucursales', interno.usuario_restringido(p_empresa_id), 'generado_en', public.iso(now()),
    'nota', 'Vendido = ventas emitidas menos devoluciones en esas fechas. Pedir = lo que falta para cubrir los días elegidos o llegar al mínimo. Es una sugerencia: usted decide.'),
    ARRAY['costo_aprox_centavos']);
END $$;

-- ---------------------------------------------------------------------
-- 2) Capital muerto
-- ---------------------------------------------------------------------
CREATE FUNCTION public.capital_muerto(p_empresa_id uuid, p_dias integer DEFAULT 90)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy   date;
  v_filas jsonb;
  v_tot   jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'inventario.ver');
  IF p_dias IS NULL OR p_dias NOT BETWEEN 7 AND 365 THEN
    RAISE EXCEPTION 'DIAS_INVALIDOS: los días van de 7 a 365.';
  END IF;
  v_hoy := public.hoy_local(p_empresa_id);
  WITH ult AS (
    SELECT l.producto_id, max(v.fecha_contable) AS ultima
      FROM public.venta_linea l JOIN public.venta v ON v.id = l.venta_id
     WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida'
       AND interno.sucursal_permitida(p_empresa_id, v.sucursal_id)
     GROUP BY l.producto_id
  ), x AS (
    SELECT p.id, p.codigo, p.nombre, u.codigo AS unidad, e.cantidad AS hay, e.valor_centavos, ult.ultima,
           p.creado_en::date AS desde
      FROM public.producto p
      JOIN public.unidad u ON u.id = p.unidad_id
      JOIN interno.existencias_permitidas(p_empresa_id) e ON e.producto_id = p.id
      LEFT JOIN ult ON ult.producto_id = p.id
     WHERE p.empresa_id = p_empresa_id AND p.tipo = 'bien' AND e.cantidad > 0
  ), z AS (
    -- Sin venta nunca: cuenta desde que se creó el producto (un producto nuevo no es "muerto").
    SELECT x.*, v_hoy - coalesce(x.ultima, x.desde) AS dias_sin_vender FROM x
     WHERE v_hoy - coalesce(x.ultima, x.desde) >= p_dias
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'producto_id', z.id, 'codigo', z.codigo, 'nombre', z.nombre, 'unidad', z.unidad, 'hay', z.hay,
           'ultima_venta', to_char(z.ultima, 'YYYY-MM-DD'), 'dias_sin_vender', z.dias_sin_vender,
           'valor_centavos', z.valor_centavos)
         ORDER BY z.valor_centavos DESC NULLS LAST, z.dias_sin_vender DESC, z.nombre, z.id), '[]'),
         jsonb_build_object('productos', count(*), 'valor_centavos', coalesce(sum(z.valor_centavos), 0))
    INTO v_filas, v_tot FROM z;
  RETURN interno.ocultar_costos(p_empresa_id, jsonb_build_object(
    'dias', p_dias, 'al', to_char(v_hoy, 'YYYY-MM-DD'), 'filas', v_filas, 'total', v_tot,
    'solo_mis_sucursales', interno.usuario_restringido(p_empresa_id), 'generado_en', public.iso(now()),
    'nota', 'Productos con existencias que no se venden desde hace esos días (o desde que se crearon). Valor = al costo promedio de lo que hay. Ideas: promoción, cambiar al proveedor o dejar de comprarlo.'),
    ARRAY['valor_centavos']);
END $$;

REVOKE EXECUTE ON FUNCTION interno.existencias_permitidas(uuid), interno.vendido_neto(uuid, date, date)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.que_comprar(uuid, integer, integer), public.capital_muerto(uuid, integer) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.que_comprar(uuid, integer, integer), public.capital_muerto(uuid, integer) TO authenticated;
