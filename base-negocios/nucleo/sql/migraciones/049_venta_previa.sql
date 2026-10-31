-- =====================================================================
-- 049_venta_previa.sql  -  Núcleo 0.13.2: cálculo previo de una venta para
-- la pantalla Vender (app 0.2.0). Las 001-048 no se tocan.
--
-- La app nunca calcula dinero: para mostrar el total con ISV desglosado, el
-- vuelto y si el descuento pedirá aprobación ANTES de cobrar, pregunta al
-- servidor con la MISMA regla de la venta (interno.calcular_venta).
--
--   calcular_venta_previa(empresa, {"lineas", "descuento_factura", "fecha"?})
--   - No guarda nada (STABLE): no mueve inventario, dinero ni números.
--   - Permiso: ventas.vender o ventas.cotizar (igual que promociones_aplicables).
--   - Promociones: en cada línea trae "promociones" (de la que más descuenta a
--     la que menos). Si aplican VARIAS y la línea no trae "promocion_id", la
--     previa usa la que más descuenta y la marca en "promocion_sugerida_id"
--     (la venta de verdad sigue exigiendo que la app mande la elegida:
--     PROMOCION_A_ELEGIR no cambia). Nunca se suman.
--   - Tope: "tope_descuento_porcentaje" del puesto y "descuento_pide_aprobacion"
--     (total o por línea, la misma regla de registrar_venta). El dueño: sin tope.
--   - Sin costos: "costo_estimado_centavos" solo a quien tiene inventario.costos.
-- =====================================================================

CREATE FUNCTION public.calcular_venta_previa(p_empresa_id uuid, p_datos jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_fecha   date;
  v_lineas  jsonb := '[]';
  v_promos  jsonb := '[]';
  l         jsonb;
  i         integer := 0;
  p         public.producto;
  q         numeric;
  pr        jsonb;
  v_sug     jsonb := '[]';
  v_calc    jsonb;
  v_out     jsonb := '[]';
  v_rol     text := public.mi_rol(p_empresa_id);
  v_td      record;
  v_tope    numeric;
  v_pide    boolean := false;
  v_costos  boolean := public.tiene_permiso('inventario.costos', p_empresa_id);
BEGIN
  IF public.tiene_permiso('ventas.cotizar', p_empresa_id) THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.cotizar');
  ELSE
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.vender');
  END IF;
  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: faltan los datos de la venta.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['lineas', 'descuento_factura', 'fecha']);
  IF jsonb_typeof(p_datos->'lineas') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'lineas') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la venta necesita al menos una línea.';
  END IF;
  v_fecha := coalesce(nullif(p_datos->>'fecha', '')::date, public.hoy_local(p_empresa_id));

  -- Promociones de cada línea; con varias y sin elegir, la que más descuenta.
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
    IF coalesce(l->'promocion_id', 'null'::jsonb) = 'null'::jsonb AND jsonb_array_length(pr) > 1 THEN
      l := l || jsonb_build_object('promocion_id', pr->0->'promocion_id');
      v_sug := v_sug || jsonb_build_array(pr->0->'promocion_id');
    ELSE
      v_sug := v_sug || jsonb_build_array(NULL::jsonb);
    END IF;
    v_lineas := v_lineas || jsonb_build_array(l);
  END LOOP;

  v_calc := interno.calcular_venta(p_empresa_id, v_fecha, v_lineas, p_datos->'descuento_factura');

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
    v_out := v_out || jsonb_build_array(l);
  END LOOP;

  RETURN (v_calc - 'lineas') || jsonb_build_object('lineas', v_out, 'fecha', to_char(v_fecha, 'YYYY-MM-DD'),
    'tope_descuento_porcentaje', v_tope, 'descuento_pide_aprobacion', v_pide);
END $$;

REVOKE EXECUTE ON FUNCTION public.calcular_venta_previa(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.calcular_venta_previa(uuid, jsonb) TO authenticated;
