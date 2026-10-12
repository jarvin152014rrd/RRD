-- =====================================================================
-- 050_app_cobro_cajero_marca.sql  -  Núcleo 0.14.0 (para la app 0.3.0).
-- Las 001-049 no se tocan.
--
-- 1) EL CAJERO COBRA ABONOS (decisión del dueño). Permiso nuevo
--    "cobros.ver_saldos" (dueño, admin y cajero): ver lo que debe cada cliente
--    factura por factura PARA COBRAR, sin ventas.ver (no ve ventas de toda la
--    empresa, ni costos, ni ganancias, ni reportes).
--      cxc_para_cobrar(empresa, cliente?) -> clientes con saldo (y sus facturas
--      pendientes si se indica el cliente). Usuario restringido por sucursal:
--      solo ventas al crédito emitidas en sus sucursales y nada de saldos
--      iniciales (no tienen sucursal), igual que resumen_hoy (0.13.1).
--    El cobro sigue siendo registrar_cobro (ventas.cobrar, que el cajero ya
--    tenía) con su turno y su sucursal revisados por el servidor.
--
-- 2) VENTA PREVIA CON DESCUENTO CON ISV. calcular_venta_previa (049) pasa a
--    interno.calcular_venta_previa_049 (sin cambios) y la pública agrega, por
--    línea y en total, "bruto_con_isv_centavos" / "subtotal_con_isv_centavos" y
--    "descuento_con_isv_centavos" (lo que el cliente ve rebajado). Siempre:
--    subtotal con ISV - descuento con ISV = total.
--    Ej.: galón L 520.00 con ISV y promoción de L 60: subtotal 52,000 -
--    descuento 6,000 = total 46,000 (ISV incluido 6,000). Antes el descuento
--    salía sin ISV (5,217) y no sumaba a la vista.
--
-- 3) MARCA DEL NEGOCIO (Ajustes > Mi negocio): nombre comercial, logo y
--    colores, con "volver al anterior". Permiso nuevo "empresa.marca" (dueño y
--    admin). No toca nombre legal ni RTN (datos fiscales: ficha del proveedor).
--      marca_empresa(empresa)                  cualquiera de la empresa
--      configurar_marca(empresa, datos, motivo) {"nombre_comercial","logo",
--        "color_principal","color_acento"} o {"volver_anterior": true}
-- =====================================================================

-- ---------------------------------------------------------------------
-- Permisos nuevos
-- ---------------------------------------------------------------------
INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('cobros.ver_saldos', 'Ver lo que debe cada cliente (factura por factura) para cobrarle', false, true),
  ('empresa.marca', 'Cambiar nombre comercial, logo y colores del programa', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'cobros.ver_saldos'), ('admin', 'cobros.ver_saldos'), ('cajero', 'cobros.ver_saldos'),
  ('dueno', 'empresa.marca'), ('admin', 'empresa.marca');
SELECT interno.repartir_permisos(ARRAY['cobros.ver_saldos', 'empresa.marca'], 'Núcleo 0.14.0: el cajero cobra abonos; marca del negocio');

-- ---------------------------------------------------------------------
-- 1) Saldos para cobrar
-- ---------------------------------------------------------------------
CREATE FUNCTION public.cxc_para_cobrar(p_empresa_id uuid, p_cliente_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy   date;
  v_restr boolean;
  v_res   jsonb;
BEGIN
  IF public.tiene_permiso('ventas.ver', p_empresa_id) THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.ver');
  ELSE
    PERFORM interno.exigir_lectura(p_empresa_id, 'cobros.ver_saldos');
  END IF;
  v_hoy   := public.hoy_local(p_empresa_id);
  v_restr := interno.usuario_restringido(p_empresa_id);

  WITH d AS (
    SELECT x.documento_id, x.origen, x.cliente_id, x.numero_documento, x.fecha_documento, x.vence_el,
           x.monto_centavos, x.saldo_centavos, v_hoy - x.fecha_documento AS dias,
           greatest(v_hoy - x.vence_el, 0) AS dias_vencido
      FROM interno.cxc_al(p_empresa_id, 'infinity') x
     WHERE x.saldo_centavos > 0
       AND (p_cliente_id IS NULL OR x.cliente_id = p_cliente_id)
       AND (NOT v_restr OR interno.documento_cxc_permitido(p_empresa_id, x.origen, x.documento_id))
  ), c AS (
    SELECT d.cliente_id, t.nombre, t.codigo, t.telefono,
           sum(d.saldo_centavos)::bigint AS saldo,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias_vencido > 0), 0)::bigint AS vencido,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias <= 30), 0)::bigint AS a30,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 31 AND 60), 0)::bigint AS a60,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias BETWEEN 61 AND 90), 0)::bigint AS a90,
           coalesce(sum(d.saldo_centavos) FILTER (WHERE d.dias > 90), 0)::bigint AS mas90,
           count(*) AS documentos,
           jsonb_agg(jsonb_build_object('origen', d.origen, 'documento_id', d.documento_id,
             'venta_id', CASE WHEN d.origen = 'venta' THEN d.documento_id END,
             'saldo_inicial_id', CASE WHEN d.origen = 'saldo_inicial' THEN d.documento_id END,
             'numero_documento', d.numero_documento, 'fecha_documento', d.fecha_documento, 'vence_el', d.vence_el,
             'monto_centavos', d.monto_centavos, 'saldo_centavos', d.saldo_centavos, 'dias_vencido', d.dias_vencido)
             ORDER BY d.fecha_documento, d.vence_el, d.numero_documento) AS facturas
      FROM d JOIN public.tercero t ON t.id = d.cliente_id AND t.empresa_id = p_empresa_id
     GROUP BY d.cliente_id, t.nombre, t.codigo, t.telefono
  )
  SELECT jsonb_build_object(
    'todas_las_sucursales', NOT v_restr,
    'total_centavos', coalesce(sum(c.saldo), 0),
    'clientes', coalesce(jsonb_agg(jsonb_build_object(
      'cliente_id', c.cliente_id, 'cliente', c.nombre, 'codigo', c.codigo, 'telefono', c.telefono,
      'saldo_centavos', c.saldo, 'vencido_centavos', c.vencido, 'documentos', c.documentos,
      'de_0_a_30', c.a30, 'de_31_a_60', c.a60, 'de_61_a_90', c.a90, 'mas_de_90', c.mas90,
      'facturas', CASE WHEN p_cliente_id IS NOT NULL THEN c.facturas END)
      ORDER BY c.vencido DESC, c.saldo DESC), '[]'::jsonb))
    INTO v_res FROM c;
  RETURN v_res;
END $$;

-- ---------------------------------------------------------------------
-- 2) Venta previa con el descuento con ISV
-- ---------------------------------------------------------------------
ALTER FUNCTION public.calcular_venta_previa(uuid, jsonb) SET SCHEMA interno;
ALTER FUNCTION interno.calcular_venta_previa(uuid, jsonb) RENAME TO calcular_venta_previa_049;

CREATE FUNCTION public.calcular_venta_previa(p_empresa_id uuid, p_datos jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      jsonb := interno.calcular_venta_previa_049(p_empresa_id, p_datos);
  l      jsonb;
  v_out  jsonb := '[]';
  v_con  bigint;
  v_sub  bigint := 0;
BEGIN
  FOR l IN SELECT * FROM jsonb_array_elements(r->'lineas') LOOP
    -- Precio x cantidad con ISV, por línea y redondeado como la venta (precio_con_tasa).
    v_con := (public.precio_con_tasa((l->>'precio_unitario_centavos')::bigint, (l->>'precio_incluye_isv')::boolean,
              coalesce((l->>'impuesto_porcentaje')::numeric, 0), (l->>'cantidad')::numeric)).con_isv_centavos;
    v_sub := v_sub + v_con;
    v_out := v_out || jsonb_build_array(l || jsonb_build_object('bruto_con_isv_centavos', v_con,
               'descuento_con_isv_centavos', v_con - (l->>'total_centavos')::bigint));
  END LOOP;
  RETURN r || jsonb_build_object('lineas', v_out, 'subtotal_con_isv_centavos', v_sub,
    'descuento_con_isv_centavos', v_sub - (r->>'total_centavos')::bigint);
END $$;

-- ---------------------------------------------------------------------
-- 3) Marca del negocio
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa
  ADD COLUMN marca jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN marca_anterior jsonb;

CREATE FUNCTION public.marca_empresa(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.empresa;
BEGIN
  IF auth.uid() IS NOT NULL AND (p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL) THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  SELECT * INTO e FROM public.empresa WHERE id = p_empresa_id;
  RETURN jsonb_build_object('nombre', e.nombre, 'rtn', e.rtn, 'marca', e.marca,
    'puede_volver', e.marca_anterior IS NOT NULL);
END $$;

CREATE FUNCTION public.configurar_marca(p_empresa_id uuid, p_datos jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e     public.empresa;
  k     text;
  v_new jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.marca', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  SELECT * INTO e FROM public.empresa WHERE id = p_empresa_id FOR UPDATE;

  IF p_datos ? 'volver_anterior' THEN
    IF e.marca_anterior IS NULL THEN
      RAISE EXCEPTION 'NO_PERMITIDO: no hay una marca anterior a la cual volver.';
    END IF;
    v_new := e.marca_anterior;
  ELSE
    FOR k IN SELECT jsonb_object_keys(p_datos) LOOP
      IF k NOT IN ('nombre_comercial', 'logo', 'color_principal', 'color_acento') THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
      END IF;
      CONTINUE WHEN p_datos->k = 'null'::jsonb;   -- null = quitar
      IF jsonb_typeof(p_datos->k) <> 'string' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser texto.', k;
      END IF;
    END LOOP;
    IF p_datos->>'nombre_comercial' IS NOT NULL AND length(trim(p_datos->>'nombre_comercial')) NOT BETWEEN 2 AND 80 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el nombre comercial lleva de 2 a 80 letras.';
    END IF;
    IF p_datos->>'logo' IS NOT NULL AND (p_datos->>'logo' !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$'
                                         OR length(p_datos->>'logo') > 300000) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el logo debe ser una imagen PNG, JPG o WEBP de hasta 200 KB.';
    END IF;
    FOREACH k IN ARRAY ARRAY['color_principal', 'color_acento'] LOOP
      IF p_datos->>k IS NOT NULL AND p_datos->>k !~ '^#[0-9a-fA-F]{6}$' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "%" es un color como #0f1f3d.', k;
      END IF;
    END LOOP;
    v_new := jsonb_strip_nulls(e.marca || p_datos);
    IF v_new ? 'nombre_comercial' THEN
      v_new := v_new || jsonb_build_object('nombre_comercial', trim(v_new->>'nombre_comercial'));
    END IF;
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET marca_anterior = e.marca, marca = v_new WHERE id = p_empresa_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN public.marca_empresa(p_empresa_id);
END $$;

-- ---------------------------------------------------------------------
-- Permisos de ejecución
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION interno.calcular_venta_previa_049(uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cxc_para_cobrar(uuid, uuid), public.calcular_venta_previa(uuid, jsonb),
  public.marca_empresa(uuid), public.configurar_marca(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cxc_para_cobrar(uuid, uuid), public.calcular_venta_previa(uuid, jsonb),
  public.marca_empresa(uuid), public.configurar_marca(uuid, jsonb, text) TO authenticated;
