-- =====================================================================
-- 047_sucursales_control.sql  -  Núcleo 0.13.0 (etapa 3b-2b): crecimiento
-- por sucursal y centro de control del dueño.
--
--  1) Usuarios por sucursal (usuario_sucursal): un usuario puede quedar
--     restringido a una o varias sucursales. El dueño y quien no tenga
--     restricción ven todo. Lo respetan:
--       - las lecturas: políticas RLS "restrictivas" en las tablas con sucursal,
--         bodega o cuenta de dinero, y las vistas "del sistema" de ventas;
--       - las operaciones: triggers en venta, cobro, turno, gasto, apartado,
--         devolución, compra, kardex y rastro del dinero (así vale para TODA
--         RPC que vende, cobra, abre turnos, gasta, ajusta o traslada).
--     asignar_sucursales_usuario (dueño/admin; el admin no amplía su alcance).
--  2) reporte_sucursales: ventas, ganancia, gastos y dinero por sucursal y total.
--  3) Envío de dinero entre sucursales (en tránsito hasta que B lo recibe) y
--     confirmación de recepción de traslados de mercadería entre sucursales.
--  4) Precios por sucursal (se activan con activar_precios_sucursal).
--  5) Centro de control: vigilancia por empleado, bitácora legible, cerrar
--     sesión de un usuario y horario de acceso por puesto.
--  6) Índices para volumen (bitácora por usuario, ventas por sucursal).
-- Las migraciones 001-046 no se tocan.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('SUCURSAL_NO_PERMITIDA', 'Su usuario no trabaja en esa sucursal.', 'Pida al dueño o al administrador que le asigne esa sucursal, o pida a alguien de esa sucursal que lo haga.'),
  ('SESION_CERRADA', 'El dueño o el administrador cerró su sesión.', 'Vuelva a entrar con su correo y contraseña.'),
  ('FUERA_DE_HORARIO', 'Su puesto no puede trabajar a esta hora.', 'Espere a su horario o pida al dueño que lo cambie.');

-- ---------------------------------------------------------------------
-- 1) Usuarios por sucursal
-- ---------------------------------------------------------------------
CREATE TABLE public.usuario_sucursal (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id   uuid NOT NULL REFERENCES public.empresa(id),
  user_id      uuid NOT NULL,
  sucursal_id  uuid NOT NULL,
  activo       boolean NOT NULL DEFAULT true,
  cambiado_por uuid,
  cambiado_en  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, user_id, sucursal_id),
  FOREIGN KEY (user_id, empresa_id) REFERENCES public.usuario_empresa(user_id, empresa_id),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id)
);
CREATE INDEX usuario_sucursal_usuario ON public.usuario_sucursal (user_id, empresa_id) WHERE activo;

-- ¿El usuario conectado tiene sucursales asignadas en esta empresa? (el dueño nunca)
CREATE FUNCTION interno.usuario_restringido(p_empresa_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL
     AND coalesce(public.mi_rol(p_empresa_id), '') <> 'dueno'
     AND EXISTS (SELECT 1 FROM public.usuario_sucursal us
                  WHERE us.empresa_id = p_empresa_id AND us.user_id = auth.uid() AND us.activo)
$$;

CREATE FUNCTION interno.sucursal_permitida(p_empresa_id uuid, p_sucursal_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_sucursal_id IS NULL OR NOT interno.usuario_restringido(p_empresa_id)
      OR EXISTS (SELECT 1 FROM public.usuario_sucursal us
                  WHERE us.empresa_id = p_empresa_id AND us.user_id = auth.uid() AND us.sucursal_id = p_sucursal_id AND us.activo)
$$;

CREATE FUNCTION interno.exigir_sucursal(p_empresa_id uuid, p_sucursal_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT interno.sucursal_permitida(p_empresa_id, p_sucursal_id) THEN
    RAISE EXCEPTION 'SUCURSAL_NO_PERMITIDA: su usuario no trabaja en la sucursal "%"; solo en: %.',
      (SELECT s.codigo || ' ' || s.nombre FROM public.sucursal s WHERE s.id = p_sucursal_id),
      (SELECT string_agg(s.codigo || ' ' || s.nombre, ', ' ORDER BY s.codigo) FROM public.usuario_sucursal us
         JOIN public.sucursal s ON s.id = us.sucursal_id
        WHERE us.empresa_id = p_empresa_id AND us.user_id = auth.uid() AND us.activo);
  END IF;
END $$;

-- Para políticas y vistas (una vez por consulta): sucursales, bodegas, cajas y
-- cuentas de dinero que el usuario conectado puede ver en todas sus empresas.
-- Sin usuario (service_role o administrador de la base): todas.
CREATE FUNCTION public.sucursales_permitidas() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT s.id FROM public.sucursal s
   WHERE auth.uid() IS NULL AND coalesce(auth.role(), '') NOT IN ('anon', 'authenticated')
  UNION ALL
  SELECT s.id
    FROM public.usuario_empresa ue
    JOIN public.sucursal s ON s.empresa_id = ue.empresa_id
   WHERE ue.user_id = auth.uid() AND ue.activo
     AND (ue.rol = 'dueno'
          OR NOT EXISTS (SELECT 1 FROM public.usuario_sucursal us
                          WHERE us.empresa_id = ue.empresa_id AND us.user_id = ue.user_id AND us.activo)
          OR EXISTS (SELECT 1 FROM public.usuario_sucursal us
                      WHERE us.empresa_id = ue.empresa_id AND us.user_id = ue.user_id AND us.sucursal_id = s.id AND us.activo))
$$;

CREATE FUNCTION public.bodegas_permitidas() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT b.id FROM public.bodega b WHERE b.sucursal_id IN (SELECT public.sucursales_permitidas())
$$;

CREATE FUNCTION public.cajas_permitidas() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT c.id FROM public.caja c WHERE c.sucursal_id IN (SELECT public.sucursales_permitidas())
$$;

-- Cuentas de dinero de una sucursal permitida o de toda la empresa (sin sucursal).
CREATE FUNCTION public.cuentas_dinero_permitidas() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT d.id FROM public.cuenta_dinero d
   WHERE d.empresa_id IN (SELECT public.mis_empresas()
                          UNION ALL SELECT e.id FROM public.empresa e
                           WHERE auth.uid() IS NULL AND coalesce(auth.role(), '') NOT IN ('anon', 'authenticated'))
     AND (d.sucursal_id IS NULL OR d.sucursal_id IN (SELECT public.sucursales_permitidas()))
$$;

-- Trigger de operación: la fila nueva debe ser de una sucursal permitida.
--   TG_ARGV[0] = 'sucursal' (columna sucursal_id), 'bodega' (bodega_id) o 'cuenta' (cuenta_dinero_id).
-- La ENTRADA de un traslado de mercadería a otra sucursal sí pasa (la manda quien
-- trabaja en el origen; la otra sucursal confirma la recepción).
CREATE FUNCTION interno.revisar_sucursal_fila() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  j     jsonb;
  v_suc uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  j := to_jsonb(NEW);
  IF TG_ARGV[0] = 'sucursal' THEN
    v_suc := (j->>'sucursal_id')::uuid;
  ELSIF TG_ARGV[0] = 'bodega' THEN
    IF j->>'origen' = 'traslado' AND (j->>'cantidad')::numeric > 0 THEN
      RETURN NEW;
    END IF;
    SELECT b.sucursal_id INTO v_suc FROM public.bodega b WHERE b.id = (j->>'bodega_id')::uuid;
  ELSE
    SELECT d.sucursal_id INTO v_suc FROM public.cuenta_dinero d WHERE d.id = (j->>'cuenta_dinero_id')::uuid;
  END IF;
  PERFORM interno.exigir_sucursal(NEW.empresa_id, v_suc);
  RETURN NEW;
END $$;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('venta', 'sucursal'), ('cobro', 'sucursal'), ('turno_caja', 'sucursal'), ('gasto', 'sucursal'),
                                 ('apartado', 'sucursal'), ('devolucion', 'sucursal'), ('compra', 'sucursal'),
                                 ('inventario_movimiento', 'bodega'), ('dinero_movimiento', 'cuenta')) x(t, tipo) LOOP
    EXECUTE format('CREATE TRIGGER revisar_sucursal BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.revisar_sucursal_fila(%L)',
                   r.t, r.tipo);
  END LOOP;

  -- Lecturas: política RESTRICTIVA (se suma a la de siempre: hay que cumplir las dos).
  FOR r IN SELECT * FROM (VALUES
      ('venta',       '(sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('cobro',       '(sucursal_id IS NULL OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('turno_caja',  '(sucursal_id IS NULL OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('gasto',       '(sucursal_id IS NULL OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('apartado',    '(sucursal_id IS NULL OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('devolucion',  '(sucursal_id IS NULL OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('compra',      '(sucursal_id IS NULL OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('caja',        '(sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('bodega',      '(sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('cuenta_dinero', '(sucursal_id IS NULL OR sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'),
      ('operacion_dinero', '(origen_id = ANY (ARRAY(SELECT public.cuentas_dinero_permitidas())) OR destino_id = ANY (ARRAY(SELECT public.cuentas_dinero_permitidas())))'),
      ('dinero_movimiento', '(cuenta_dinero_id = ANY (ARRAY(SELECT public.cuentas_dinero_permitidas())))'),
      ('inventario_saldo', '(bodega_id = ANY (ARRAY(SELECT public.bodegas_permitidas())))'),
      ('inventario_movimiento', '(bodega_id = ANY (ARRAY(SELECT public.bodegas_permitidas())))'),
      ('inventario_documento', '(bodega_id = ANY (ARRAY(SELECT public.bodegas_permitidas())) OR bodega_destino_id = ANY (ARRAY(SELECT public.bodegas_permitidas())))'),
      ('conteo_fisico', '(bodega_id = ANY (ARRAY(SELECT public.bodegas_permitidas())))'),
      ('venta_linea', '(venta_id IN (SELECT v.id FROM public.venta v))'),
      ('venta_pago',  '(venta_id IN (SELECT v.id FROM public.venta v))')) x(t, filtro) LOOP
    EXECUTE format('CREATE POLICY por_sucursal ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated USING %s', r.t, r.filtro);
  END LOOP;
END $$;

-- Vistas "del sistema" (no security_invoker: no pasan por RLS): se envuelven con
-- el mismo filtro, sin cambiar sus columnas.
DO $$
DECLARE
  r        record;
  v_cols   text[];
  v_filtro text;
BEGIN
  FOR r IN SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind = 'v' AND c.relname LIKE 'v\_%'
              AND NOT coalesce(c.reloptions::text LIKE '%security_invoker=true%', false) LOOP
    SELECT array_agg(a.attname::text) INTO v_cols FROM pg_attribute a WHERE a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped;
    v_filtro := CASE
      WHEN 'sucursal_id' = ANY (v_cols) THEN '(x.sucursal_id IS NULL OR x.sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas())))'
      WHEN 'bodega_id' = ANY (v_cols)   THEN '(x.bodega_id IS NULL OR x.bodega_id = ANY (ARRAY(SELECT public.bodegas_permitidas())))'
      WHEN 'caja_id' = ANY (v_cols)     THEN '(x.caja_id IS NULL OR x.caja_id = ANY (ARRAY(SELECT public.cajas_permitidas())))'
      WHEN 'venta_id' = ANY (v_cols)    THEN '(x.venta_id IS NULL OR x.venta_id IN (SELECT v.id FROM public.venta v WHERE v.sucursal_id = ANY (ARRAY(SELECT public.sucursales_permitidas()))))'
    END;
    IF v_filtro IS NOT NULL THEN
      EXECUTE format('CREATE OR REPLACE VIEW public.%I AS SELECT x.* FROM (%s) x WHERE %s',
                     r.relname, rtrim(pg_get_viewdef(r.oid, false), E'; \n'), v_filtro);
    END IF;
  END LOOP;
END $$;

-- RPC: asignar_sucursales_usuario(empresa, usuario, sucursales, motivo)   usuarios.administrar
-- Lista vacía = sin restricción (ve y trabaja en todas). Nunca al dueño ni al proveedor; nadie a sí mismo.
-- Quien no es dueño: solo cajeros y vendedores (como desactivar) y, si él mismo está restringido,
-- solo dentro de sus sucursales y nunca "sin restricción".
CREATE FUNCTION public.asignar_sucursales_usuario(p_empresa_id uuid, p_user_id uuid, p_sucursales uuid[], p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ue  public.usuario_empresa;
  v_yo  text;
  v_lst uuid[] := ARRAY(SELECT DISTINCT x FROM unnest(coalesce(p_sucursales, '{}')) x WHERE x IS NOT NULL);
  v_s   uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'usuarios.administrar', NULL);
  v_yo := public.mi_rol(p_empresa_id);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué cambia las sucursales del usuario (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_ue FROM public.usuario_empresa WHERE user_id = p_user_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_ue.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: ese usuario no está en esta empresa.';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede cambiar sus propias sucursales.';
  END IF;
  IF v_ue.rol IN ('dueno', 'proveedor') THEN
    RAISE EXCEPTION 'PROHIBIDO: el dueño y el proveedor siempre ven toda la empresa.';
  END IF;
  IF v_yo <> 'dueno' AND v_ue.rol NOT IN ('cajero', 'vendedor') THEN
    RAISE EXCEPTION 'PROHIBIDO: solo el dueño cambia las sucursales de un administrador.';
  END IF;
  IF v_yo <> 'dueno' AND interno.rol_supera(p_empresa_id, v_ue.rol, v_yo) THEN
    RAISE EXCEPTION 'PROHIBIDO: ese usuario tiene un rol con permisos que usted no tiene; solo el dueño puede cambiarlo.';
  END IF;
  IF interno.usuario_restringido(p_empresa_id) AND cardinality(v_lst) = 0 THEN
    RAISE EXCEPTION 'PROHIBIDO: usted trabaja solo en algunas sucursales; no puede dar acceso a todas.';
  END IF;
  FOREACH v_s IN ARRAY v_lst LOOP
    IF NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = v_s AND s.empresa_id = p_empresa_id AND s.activa) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: una de las sucursales no existe en esta empresa o está desactivada.';
    END IF;
    PERFORM interno.exigir_sucursal(p_empresa_id, v_s);   -- el admin restringido no amplía el alcance
  END LOOP;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.usuario_sucursal SET activo = false, cambiado_por = auth.uid(), cambiado_en = now()
   WHERE empresa_id = p_empresa_id AND user_id = p_user_id AND activo AND NOT (sucursal_id = ANY (v_lst));
  INSERT INTO public.usuario_sucursal (empresa_id, user_id, sucursal_id, cambiado_por)
  SELECT p_empresa_id, p_user_id, x, auth.uid() FROM unnest(v_lst) x
  ON CONFLICT (empresa_id, user_id, sucursal_id)
  DO UPDATE SET activo = true, cambiado_por = excluded.cambiado_por, cambiado_en = now()
  WHERE NOT public.usuario_sucursal.activo;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('usuario_id', p_user_id, 'todas', cardinality(v_lst) = 0,
    'sucursales', coalesce((SELECT jsonb_agg(jsonb_build_object('sucursal_id', s.id, 'codigo', s.codigo, 'nombre', s.nombre) ORDER BY s.codigo)
                              FROM public.sucursal s WHERE s.id = ANY (v_lst)), '[]'));
END $$;

-- ---------------------------------------------------------------------
-- 2) Reporte por sucursal y consolidado
-- ---------------------------------------------------------------------
-- reporte_sucursales(empresa, desde, hasta): una fila por sucursal (las que el usuario puede ver),
-- la fila "de toda la empresa" (gastos y dinero sin sucursal; solo para quien no está restringido)
-- y el total. Cada parte con su permiso: ventas (ventas.ver), ganancia (además inventario.costos),
-- gastos y dinero (dinero.ver).
--   ventas = total con ISV de las ventas emitidas (no anuladas); ventas_sin_isv = total - ISV;
--   costo = costo de lo vendido; ganancia_bruta = ventas_sin_isv - costo;
--   gastos = gastos aplicados sin ISV (sucursal del gasto o, si no tiene, de su cuenta de dinero);
--   ganancia = ganancia_bruta - gastos; dinero = saldo al "hasta" de cajas, caja chica y bancos.
CREATE FUNCTION public.reporte_sucursales(p_empresa_id uuid, p_desde date, p_hasta date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ventas boolean := public.puede_leer(p_empresa_id, 'ventas.ver');
  v_costos boolean := public.puede_leer(p_empresa_id, 'inventario.costos');
  v_dinero boolean := public.puede_leer(p_empresa_id, 'dinero.ver');
  v_filas  jsonb;
  v_total  jsonb;
  v_ocultos text[] := '{}';
BEGIN
  PERFORM interno.exigir_miembro(p_empresa_id);
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta OR p_hasta - p_desde > 366 THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique desde y hasta (desde antes que hasta, máximo un año).';
  END IF;
  IF NOT (v_ventas OR v_dinero) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.ver" ni "dinero.ver".';
  END IF;

  WITH s AS (
    SELECT x.id, x.codigo, x.nombre, x.activa FROM public.sucursal x
     WHERE x.empresa_id = p_empresa_id AND interno.sucursal_permitida(p_empresa_id, x.id)
    UNION ALL
    SELECT NULL::uuid, NULL, 'De toda la empresa (sin sucursal)', true WHERE NOT interno.usuario_restringido(p_empresa_id)
  ), v AS (
    SELECT x.sucursal_id, count(*) AS n, sum(x.total_centavos) AS tot, sum(x.total_centavos - x.impuesto_centavos) AS sin,
           sum(coalesce(x.costo_centavos, 0)) AS costo
      FROM public.venta x
     WHERE x.empresa_id = p_empresa_id AND x.estado = 'emitida' AND x.fecha_contable BETWEEN p_desde AND p_hasta
     GROUP BY x.sucursal_id
  ), g AS (
    SELECT coalesce(x.sucursal_id, d.sucursal_id) AS sucursal_id, count(*) AS n,
           sum(x.monto_centavos - coalesce(x.isv_centavos, 0)) AS monto
      FROM public.gasto x LEFT JOIN public.cuenta_dinero d ON d.id = x.cuenta_dinero_id
     WHERE x.empresa_id = p_empresa_id AND x.estado = 'aplicado' AND x.anulado_en IS NULL
       AND x.fecha_contable BETWEEN p_desde AND p_hasta
     GROUP BY 1
  ), d AS (
    SELECT c.sucursal_id, sum(m.monto_centavos) AS saldo
      FROM public.cuenta_dinero c JOIN public.dinero_movimiento m ON m.cuenta_dinero_id = c.id AND m.fecha_contable <= p_hasta
     WHERE c.empresa_id = p_empresa_id AND c.tipo IN ('efectivo_caja', 'banco', 'caja_chica')
     GROUP BY c.sucursal_id
  ), f AS (
    SELECT s.*, coalesce(v.n, 0) AS ventas_n, coalesce(v.tot, 0) AS ventas, coalesce(v.sin, 0) AS sin_isv,
           coalesce(v.costo, 0) AS costo, coalesce(g.n, 0) AS gastos_n, coalesce(g.monto, 0) AS gastos, coalesce(d.saldo, 0) AS dinero
      FROM s LEFT JOIN v ON v.sucursal_id IS NOT DISTINCT FROM s.id
             LEFT JOIN g ON g.sucursal_id IS NOT DISTINCT FROM s.id
             LEFT JOIN d ON d.sucursal_id IS NOT DISTINCT FROM s.id
     WHERE s.id IS NOT NULL OR coalesce(g.monto, 0) <> 0 OR coalesce(d.saldo, 0) <> 0
  ), j AS (
    SELECT f.codigo, f.id, jsonb_build_object(
      'sucursal_id', f.id, 'codigo', f.codigo, 'nombre', f.nombre, 'activa', f.activa,
      'ventas_cantidad', CASE WHEN v_ventas THEN f.ventas_n END,
      'ventas_centavos', CASE WHEN v_ventas THEN f.ventas END,
      'ventas_sin_isv_centavos', CASE WHEN v_ventas THEN f.sin_isv END,
      'costo_centavos', CASE WHEN v_ventas AND v_costos THEN f.costo END,
      'ganancia_bruta_centavos', CASE WHEN v_ventas AND v_costos THEN f.sin_isv - f.costo END,
      'gastos_cantidad', CASE WHEN v_dinero THEN f.gastos_n END,
      'gastos_centavos', CASE WHEN v_dinero THEN f.gastos END,
      'ganancia_centavos', CASE WHEN v_ventas AND v_costos AND v_dinero THEN f.sin_isv - f.costo - f.gastos END,
      'dinero_centavos', CASE WHEN v_dinero THEN f.dinero END,
      'participacion_ventas_porcentaje', CASE WHEN v_ventas AND sum(f.ventas) OVER () <> 0
                                              THEN round(f.ventas * 100.0 / sum(f.ventas) OVER (), 1) END) AS fila,
      f.ventas_n, f.ventas, f.sin_isv, f.costo, f.gastos_n, f.gastos, f.dinero
    FROM f
  )
  SELECT jsonb_agg(j.fila ORDER BY j.id IS NULL, j.codigo),
         jsonb_build_object(
           'ventas_cantidad', CASE WHEN v_ventas THEN coalesce(sum(j.ventas_n), 0) END,
           'ventas_centavos', CASE WHEN v_ventas THEN coalesce(sum(j.ventas), 0) END,
           'ventas_sin_isv_centavos', CASE WHEN v_ventas THEN coalesce(sum(j.sin_isv), 0) END,
           'costo_centavos', CASE WHEN v_ventas AND v_costos THEN coalesce(sum(j.costo), 0) END,
           'ganancia_bruta_centavos', CASE WHEN v_ventas AND v_costos THEN coalesce(sum(j.sin_isv - j.costo), 0) END,
           'gastos_cantidad', CASE WHEN v_dinero THEN coalesce(sum(j.gastos_n), 0) END,
           'gastos_centavos', CASE WHEN v_dinero THEN coalesce(sum(j.gastos), 0) END,
           'ganancia_centavos', CASE WHEN v_ventas AND v_costos AND v_dinero THEN coalesce(sum(j.sin_isv - j.costo - j.gastos), 0) END,
           'dinero_centavos', CASE WHEN v_dinero THEN coalesce(sum(j.dinero), 0) END)
    INTO v_filas, v_total FROM j;

  IF NOT v_ventas THEN v_ocultos := v_ocultos || ARRAY['ventas']; END IF;
  IF NOT (v_ventas AND v_costos) THEN v_ocultos := v_ocultos || ARRAY['ganancia']; END IF;
  IF NOT v_dinero THEN v_ocultos := v_ocultos || ARRAY['gastos', 'dinero']; END IF;
  RETURN jsonb_build_object('desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'sucursales', coalesce(v_filas, '[]'), 'total', v_total, 'restringido', interno.usuario_restringido(p_empresa_id),
    'costos_ocultos', NOT v_costos, 'ocultos', to_jsonb(v_ocultos), 'generado_en', public.iso(now()),
    'nota', 'Ventas con ISV (emitidas, no anuladas). Ganancia = ventas sin ISV - costo - gastos sin ISV. Dinero = saldo de cajas, caja chica y bancos al final del rango.');
END $$;

-- ---------------------------------------------------------------------
-- 3a) Envío de dinero entre sucursales (en tránsito hasta que la otra lo recibe)
-- ---------------------------------------------------------------------
ALTER TABLE public.operacion_dinero DROP CONSTRAINT operacion_dinero_tipo_check;
ALTER TABLE public.operacion_dinero ADD CONSTRAINT operacion_dinero_tipo_check
  CHECK (tipo IN ('saldo_inicial', 'deposito', 'retiro', 'reposicion_caja_chica', 'traslado', 'envio_sucursal'));
ALTER TABLE public.operacion_dinero DROP CONSTRAINT operacion_dinero_check2;
ALTER TABLE public.operacion_dinero ADD CONSTRAINT operacion_dinero_check2
  CHECK ((tipo IN ('deposito', 'envio_sucursal')) = (transito_id IS NOT NULL));
ALTER TABLE public.operacion_dinero DROP CONSTRAINT operacion_dinero_check4;
ALTER TABLE public.operacion_dinero ADD CONSTRAINT operacion_dinero_check4
  CHECK ((tipo IN ('deposito', 'envio_sucursal')) = (estado <> 'aplicada'));

-- guardar_operacion_dinero (reemplaza la de 022; misma firma): el envío entre sucursales
-- también queda "en tránsito".
CREATE OR REPLACE FUNCTION interno.guardar_operacion_dinero(p_empresa_id uuid, p_tipo text, p_origen public.cuenta_dinero,
                                                 p_destino public.cuenta_dinero, p_transito public.cuenta_dinero,
                                                 p_contrapartida_id uuid, p_monto bigint, p_fecha date,
                                                 p_referencia text, p_nota text, p_equipo text, p_comprobante jsonb,
                                                 p_descripcion text, p_lineas jsonb, p_id_operacion uuid)
RETURNS public.operacion_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id   uuid := gen_random_uuid();
  v_num  bigint := interno.siguiente_numero(p_empresa_id, 'operacion_dinero');
  v_suc  uuid := coalesce(interno.sucursal_activa(p_origen.sucursal_id), interno.sucursal_activa(p_destino.sucursal_id));
  v_asto uuid;
  o      public.operacion_dinero;
BEGIN
  v_asto := interno.asiento_sistema(p_empresa_id, v_suc, p_fecha,
    replace(p_descripcion, '#N', '#' || v_num) || coalesce(' ref. ' || nullif(trim(p_referencia), ''), ''),
    'dinero_' || p_tipo, p_id_operacion, p_lineas);
  INSERT INTO public.operacion_dinero (id, empresa_id, numero, tipo, origen_id, destino_id, transito_id,
    contrapartida_cuenta_id, monto_centavos, fecha_contable, sucursal_id, referencia, nota, equipo, estado,
    asiento_id, id_operacion, creado_por)
  VALUES (v_id, p_empresa_id, v_num, p_tipo, p_origen.id, p_destino.id, p_transito.id, p_contrapartida_id, p_monto,
    p_fecha, v_suc, nullif(trim(p_referencia), ''), nullif(trim(p_nota), ''), p_equipo,
    CASE WHEN p_tipo IN ('deposito', 'envio_sucursal') THEN 'en_transito' ELSE 'aplicada' END, v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO o;
  PERFORM interno.rastrear_dinero(v_asto, 'dinero_' || p_tipo, 'operacion_dinero', v_id, p_referencia, p_equipo);
  PERFORM interno.guardar_adjunto(p_empresa_id, 'operacion_dinero', v_id, p_comprobante);
  RETURN o;
END $$;

-- RPC: enviar_dinero_sucursal(empresa, datos, id_operacion)   dinero.trasladar
-- datos = {"origen_id","destino_id","monto_centavos","fecha"?,"referencia"?,"nota"?,"equipo"?,"comprobante"?}
-- Origen y destino: cuentas de dinero de DOS sucursales distintas. Sale del origen y queda en la cuenta
-- "Envíos entre sucursales" (tránsito) hasta que la sucursal destino lo recibe (recibir_dinero_sucursal).
-- Asiento: Dr Envíos entre sucursales / Cr origen. Anular antes de recibir: anular_operacion_dinero.
CREATE FUNCTION public.enviar_dinero_sucursal(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o       public.cuenta_dinero;
  d       public.cuenta_dinero;
  t       public.cuenta_dinero;
  v_monto bigint;
  v_fecha date;
  v_op    public.operacion_dinero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.trasladar', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['origen_id', 'destino_id', 'monto_centavos', 'fecha', 'referencia', 'nota',
                                               'equipo', 'comprobante']);
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'dinero_envio_sucursal');
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    RETURN interno.operacion_dinero_respuesta(v_op, true);
  END IF;
  o := interno.cuenta_dinero_de(p_empresa_id, interno.json_uuid(p_datos->'origen_id', 'origen_id'));
  d := interno.cuenta_dinero_de(p_empresa_id, interno.json_uuid(p_datos->'destino_id', 'destino_id'));
  IF o.tipo NOT IN ('efectivo_caja', 'banco', 'caja_chica') OR d.tipo NOT IN ('efectivo_caja', 'banco', 'caja_chica') THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: el envío va de una caja, caja chica o banco a otra (no de tránsito ni por confirmar).';
  END IF;
  IF o.sucursal_id IS NULL OR d.sucursal_id IS NULL OR o.sucursal_id = d.sucursal_id THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: el envío es entre cuentas de dos sucursales distintas; dentro de la misma use trasladar_dinero.';
  END IF;
  PERFORM interno.exigir_sucursal(p_empresa_id, o.sucursal_id);
  v_monto := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  IF v_monto IS NULL OR v_monto = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el monto en centavos ("monto_centavos"), mayor que cero.';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'dinero_envio_sucursal');
  SELECT * INTO v_op FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v_op.id IS NOT NULL THEN
    RETURN interno.operacion_dinero_respuesta(v_op, true);
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  SELECT * INTO t FROM public.cuenta_dinero x
   WHERE x.empresa_id = p_empresa_id AND x.tipo = 'transito' AND lower(x.nombre) = lower('Envíos entre sucursales');
  IF t.id IS NULL THEN
    t := interno.crear_cuenta_dinero_base(p_empresa_id, 'transito', 'Envíos entre sucursales', NULL, NULL, NULL, NULL, NULL,
           (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id), NULL);
  ELSIF NOT t.activa THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta "Envíos entre sucursales" está desactivada; reactívela.';
  END IF;

  v_op := interno.guardar_operacion_dinero(p_empresa_id, 'envio_sucursal', o, d, t, NULL, v_monto, v_fecha,
    interno.json_texto(p_datos->'referencia', 'referencia', 100), interno.json_texto(p_datos->'nota', 'nota', 500),
    interno.equipo(p_datos), p_datos->'comprobante', 'Envío #N de ' || o.nombre || ' a ' || d.nombre || ' (en tránsito)',
    jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = t.cuenta_id), 'debe', v_monto),
                      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = o.cuenta_id), 'haber', v_monto)),
    p_id_operacion);
  RETURN interno.operacion_dinero_respuesta(v_op, false);
END $$;

-- RPC: recibir_dinero_sucursal(operacion, id_operacion, fecha?, referencia?)   dinero.trasladar
-- La sucursal destino confirma que llegó: Dr destino / Cr Envíos entre sucursales. Una sola vez.
-- Lo hace alguien que trabaje en la sucursal destino (o sin restricción).
CREATE FUNCTION public.recibir_dinero_sucursal(p_operacion_id uuid, p_id_operacion uuid, p_fecha date DEFAULT NULL,
                                               p_referencia text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o       public.operacion_dinero;
  d       public.cuenta_dinero;
  v_fecha date;
  v_asto  uuid;
  v_ref   text := nullif(trim(p_referencia), '');
BEGIN
  SELECT * INTO o FROM public.operacion_dinero WHERE id = p_operacion_id;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la operación de dinero no existe.';
  END IF;
  PERFORM interno.exigir_escritura(o.empresa_id, 'dinero.trasladar', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(o.empresa_id, p_id_operacion, 'confirmacion_deposito');
  IF o.confirmacion_id_operacion = p_id_operacion THEN
    RETURN interno.operacion_dinero_respuesta(o, true);
  END IF;
  IF o.tipo <> 'envio_sucursal' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: solo los envíos entre sucursales se reciben así (los depósitos se confirman con confirmar_deposito).';
  END IF;
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = o.destino_id;
  PERFORM interno.exigir_sucursal(o.empresa_id, d.sucursal_id);
  IF length(v_ref) > 100 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la referencia es demasiado larga (máximo 100 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(o.empresa_id), o.fecha_contable));
  PERFORM interno.exigir_fecha_contable(o.empresa_id, v_fecha);
  IF v_fecha < o.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la recepción no puede tener fecha anterior al envío (%).', to_char(o.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(o.empresa_id, p_id_operacion, 'confirmacion_deposito');
  SELECT * INTO o FROM public.operacion_dinero WHERE id = p_operacion_id FOR UPDATE;
  IF o.confirmacion_id_operacion = p_id_operacion THEN
    RETURN interno.operacion_dinero_respuesta(o, true);
  END IF;
  IF o.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el envío #% está anulado.', o.numero;
  END IF;
  IF o.estado = 'confirmada' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el envío #% ya fue recibido.', o.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(o.empresa_id, v_fecha);

  v_asto := interno.asiento_sistema(o.empresa_id, interno.sucursal_activa(d.sucursal_id), v_fecha,
    'Recepción del envío #' || o.numero || ' en ' || d.nombre || coalesce(' ref. ' || v_ref, ''),
    'recepcion_envio_sucursal', p_id_operacion,
    jsonb_build_array(
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id), 'debe', o.monto_centavos),
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta_dinero x JOIN public.cuenta c ON c.id = x.cuenta_id WHERE x.id = o.transito_id), 'haber', o.monto_centavos)));
  UPDATE public.operacion_dinero
     SET estado = 'confirmada', confirmada_en = now(), confirmada_por = auth.uid(), fecha_confirmacion = v_fecha,
         referencia_confirmacion = v_ref, asiento_confirmacion_id = v_asto, confirmacion_id_operacion = p_id_operacion
   WHERE id = o.id
  RETURNING * INTO o;
  PERFORM interno.rastrear_dinero(v_asto, 'recepcion_envio_sucursal', 'operacion_dinero', o.id, coalesce(v_ref, o.referencia), NULL);
  RETURN interno.operacion_dinero_respuesta(o, false);
END $$;

-- ---------------------------------------------------------------------
-- 3b) Recepción de traslados de mercadería entre sucursales
--     (el kardex ya deja la salida en el origen y la entrada en el destino)
-- ---------------------------------------------------------------------
CREATE TABLE public.traslado_recepcion (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id    uuid NOT NULL REFERENCES public.empresa(id),
  documento_id  uuid NOT NULL UNIQUE REFERENCES public.inventario_documento(id),
  nota          text CHECK (nota IS NULL OR length(nota) <= 500),
  id_operacion  uuid NOT NULL,
  recibido_por  uuid,
  recibido_en   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id_operacion)
);
CREATE TRIGGER inmutable BEFORE UPDATE ON public.traslado_recepcion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La recepción de un traslado no se edita.');

INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('traslado_recepcion', 'id_operacion', 'recepcion_traslado', 80);

-- RPC: confirmar_recepcion_traslado(documento, id_operacion, nota?)   inventario.trasladar
-- Solo traslados entre bodegas de DISTINTAS sucursales, no anulados, una vez. La confirma alguien
-- que trabaje en la sucursal destino (o sin restricción). Si llegó menos, anótelo en la nota y
-- haga el ajuste de inventario en la bodega destino.
CREATE FUNCTION public.confirmar_recepcion_traslado(p_documento_id uuid, p_id_operacion uuid, p_nota text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  doc   public.inventario_documento;
  bo    public.bodega;
  bd    public.bodega;
  r     public.traslado_recepcion;
BEGIN
  SELECT * INTO doc FROM public.inventario_documento WHERE id = p_documento_id;
  IF doc.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el traslado no existe.';
  END IF;
  PERFORM interno.exigir_escritura(doc.empresa_id, 'inventario.trasladar', 'inventario');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(doc.empresa_id, p_id_operacion, 'recepcion_traslado');
  SELECT * INTO r FROM public.traslado_recepcion x WHERE x.empresa_id = doc.empresa_id AND x.id_operacion = p_id_operacion;
  IF r.id IS NOT NULL THEN
    RETURN jsonb_build_object('recepcion_id', r.id, 'documento_id', r.documento_id, 'duplicado', true);
  END IF;
  SELECT * INTO bo FROM public.bodega WHERE id = doc.bodega_id;
  SELECT * INTO bd FROM public.bodega WHERE id = doc.bodega_destino_id;
  IF doc.tipo <> 'traslado' OR bd.id IS NULL OR bo.sucursal_id = bd.sucursal_id THEN
    RAISE EXCEPTION 'NO_PERMITIDO: solo se confirma la recepción de un traslado entre bodegas de distintas sucursales.';
  END IF;
  PERFORM interno.exigir_sucursal(doc.empresa_id, bd.sucursal_id);
  IF length(trim(coalesce(p_nota, ''))) > 500 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la nota es demasiado larga (máximo 500 letras).';
  END IF;

  PERFORM interno.reservar_operacion(doc.empresa_id, p_id_operacion, 'recepcion_traslado');
  SELECT * INTO r FROM public.traslado_recepcion x WHERE x.empresa_id = doc.empresa_id AND x.id_operacion = p_id_operacion;
  IF r.id IS NOT NULL THEN
    RETURN jsonb_build_object('recepcion_id', r.id, 'documento_id', r.documento_id, 'duplicado', true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventario_documento_anulacion a WHERE a.documento_id = doc.id) THEN
    RAISE EXCEPTION 'YA_ANULADO: el traslado #% está anulado.', doc.numero;
  END IF;
  IF EXISTS (SELECT 1 FROM public.traslado_recepcion x WHERE x.documento_id = doc.id) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el traslado #% ya fue recibido.', doc.numero;
  END IF;
  INSERT INTO public.traslado_recepcion (empresa_id, documento_id, nota, id_operacion, recibido_por)
  VALUES (doc.empresa_id, doc.id, nullif(trim(p_nota), ''), p_id_operacion, auth.uid())
  RETURNING * INTO r;
  RETURN jsonb_build_object('recepcion_id', r.id, 'documento_id', doc.id, 'numero', doc.numero,
    'recibido_en', public.iso(r.recibido_en), 'duplicado', false);
END $$;

-- RPC: pendientes_entre_sucursales(empresa): envíos de dinero y traslados de mercadería que aún
-- no se reciben, con días de espera. El usuario ve los que salen de o llegan a sus sucursales.
CREATE FUNCTION public.pendientes_entre_sucursales(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy date := public.hoy_local(p_empresa_id);
  v_dinero jsonb;
  v_merc   jsonb;
BEGIN
  PERFORM interno.exigir_miembro(p_empresa_id);
  IF public.puede_leer(p_empresa_id, 'dinero.ver') THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('operacion_id', o.id, 'numero', o.numero, 'fecha', to_char(o.fecha_contable, 'YYYY-MM-DD'),
             'monto_centavos', o.monto_centavos, 'de', co.nombre, 'a', cd.nombre, 'de_sucursal_id', co.sucursal_id, 'a_sucursal_id', cd.sucursal_id,
             'puedo_recibir', interno.sucursal_permitida(p_empresa_id, cd.sucursal_id), 'dias', v_hoy - o.fecha_contable,
             'referencia', o.referencia) ORDER BY o.fecha_contable, o.numero), '[]')
      INTO v_dinero
      FROM public.operacion_dinero o
      JOIN public.cuenta_dinero co ON co.id = o.origen_id
      JOIN public.cuenta_dinero cd ON cd.id = o.destino_id
     WHERE o.empresa_id = p_empresa_id AND o.tipo = 'envio_sucursal' AND o.estado = 'en_transito' AND o.anulada_en IS NULL
       AND (interno.sucursal_permitida(p_empresa_id, co.sucursal_id) OR interno.sucursal_permitida(p_empresa_id, cd.sucursal_id));
  END IF;
  IF public.puede_leer(p_empresa_id, 'inventario.ver') THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('documento_id', d.id, 'numero', d.numero, 'fecha', to_char(d.fecha_contable, 'YYYY-MM-DD'),
             'de', bo.nombre, 'a', bd.nombre, 'de_sucursal_id', bo.sucursal_id, 'a_sucursal_id', bd.sucursal_id,
             'puedo_recibir', interno.sucursal_permitida(p_empresa_id, bd.sucursal_id), 'dias', v_hoy - d.fecha_contable,
             'lineas', (SELECT count(*) FROM public.inventario_documento_linea l WHERE l.documento_id = d.id))
             ORDER BY d.fecha_contable, d.numero), '[]')
      INTO v_merc
      FROM public.inventario_documento d
      JOIN public.bodega bo ON bo.id = d.bodega_id
      JOIN public.bodega bd ON bd.id = d.bodega_destino_id
     WHERE d.empresa_id = p_empresa_id AND d.tipo = 'traslado' AND bo.sucursal_id <> bd.sucursal_id
       AND NOT EXISTS (SELECT 1 FROM public.traslado_recepcion r WHERE r.documento_id = d.id)
       AND NOT EXISTS (SELECT 1 FROM public.inventario_documento_anulacion a WHERE a.documento_id = d.id)
       AND (interno.sucursal_permitida(p_empresa_id, bo.sucursal_id) OR interno.sucursal_permitida(p_empresa_id, bd.sucursal_id));
  END IF;
  RETURN jsonb_build_object('dinero', v_dinero, 'mercaderia', v_merc);
END $$;

-- ---------------------------------------------------------------------
-- 4) Precios por sucursal (opcional)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa ADD COLUMN precios_por_sucursal boolean NOT NULL DEFAULT false;
ALTER TABLE public.producto_precio ADD COLUMN sucursal_id uuid REFERENCES public.sucursal(id);   -- NULL = precio general

CREATE TABLE public.producto_precio_sucursal (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id            uuid NOT NULL REFERENCES public.empresa(id),
  producto_id           uuid NOT NULL,
  sucursal_id           uuid NOT NULL,
  precio_venta_centavos bigint NOT NULL CHECK (precio_venta_centavos BETWEEN 0 AND 9007199254740991),
  precio_incluye_isv    boolean NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  cambiado_por          uuid,
  cambiado_en           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (producto_id, sucursal_id),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id)
);

-- RPC: activar_precios_sucursal(empresa, activo, motivo)   empresa.configurar (solo dueño)
CREATE FUNCTION public.activar_precios_sucursal(p_empresa_id uuid, p_activo boolean, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF p_activo IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si se activan (true) o se apagan (false) los precios por sucursal.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET precios_por_sucursal = p_activo WHERE id = p_empresa_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('precios_por_sucursal', p_activo);
END $$;

-- RPC: fijar_precio_sucursal(empresa, producto, sucursal, precio_centavos, motivo, incluye_isv?)   productos.precios
-- precio NULL = quitar (vuelve al precio general). Cada cambio queda en producto_precio con su sucursal.
CREATE FUNCTION public.fijar_precio_sucursal(p_empresa_id uuid, p_producto_id uuid, p_sucursal_id uuid,
                                             p_precio_centavos bigint, p_motivo text, p_incluye_isv boolean DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p   public.producto;
  ps  public.producto_precio_sucursal;
  v_inc boolean;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.precios', 'inventario');
  IF NOT (SELECT e.precios_por_sucursal FROM public.empresa e WHERE e.id = p_empresa_id) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: los precios por sucursal están apagados; el dueño los activa con activar_precios_sucursal.';
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio de precio (mínimo 5 letras).';
  END IF;
  IF p_precio_centavos IS NOT NULL AND (p_precio_centavos < 0 OR p_precio_centavos > 9007199254740991) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el precio es un entero de centavos, 0 o más (L 5.50 = 550).';
  END IF;
  SELECT * INTO p FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = p_sucursal_id AND s.empresa_id = p_empresa_id) THEN
    RAISE EXCEPTION 'NO_EXISTE: la sucursal no existe en esta empresa.';
  END IF;
  PERFORM interno.exigir_sucursal(p_empresa_id, p_sucursal_id);
  SELECT * INTO ps FROM public.producto_precio_sucursal x WHERE x.producto_id = p.id AND x.sucursal_id = p_sucursal_id FOR UPDATE;
  v_inc := coalesce(p_incluye_isv, CASE WHEN ps.activo THEN ps.precio_incluye_isv END, p.precio_incluye_isv);

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  IF p_precio_centavos IS NULL THEN
    IF ps.id IS NULL OR NOT ps.activo THEN
      PERFORM set_config('app.motivo', '', true);
      RETURN jsonb_build_object('producto_id', p.id, 'sucursal_id', p_sucursal_id, 'origen', 'general', 'cambio', false);
    END IF;
    UPDATE public.producto_precio_sucursal SET activo = false, cambiado_por = auth.uid(), cambiado_en = now() WHERE id = ps.id;
    INSERT INTO public.producto_precio (empresa_id, producto_id, sucursal_id, precio_anterior_centavos, precio_nuevo_centavos,
                                        incluye_isv_anterior, incluye_isv_nuevo, motivo, cambiado_por)
    VALUES (p_empresa_id, p.id, p_sucursal_id, ps.precio_venta_centavos, p.precio_venta_centavos, ps.precio_incluye_isv,
            p.precio_incluye_isv, 'Vuelve al precio general: ' || trim(p_motivo), auth.uid());
  ELSE
    IF ps.activo AND ps.precio_venta_centavos = p_precio_centavos AND ps.precio_incluye_isv = v_inc THEN
      PERFORM set_config('app.motivo', '', true);
      RETURN jsonb_build_object('producto_id', p.id, 'sucursal_id', p_sucursal_id, 'precio_centavos', p_precio_centavos, 'origen', 'sucursal', 'cambio', false);
    END IF;
    INSERT INTO public.producto_precio_sucursal (empresa_id, producto_id, sucursal_id, precio_venta_centavos, precio_incluye_isv, cambiado_por)
    VALUES (p_empresa_id, p.id, p_sucursal_id, p_precio_centavos, v_inc, auth.uid())
    ON CONFLICT (producto_id, sucursal_id) DO UPDATE
      SET precio_venta_centavos = excluded.precio_venta_centavos, precio_incluye_isv = excluded.precio_incluye_isv,
          activo = true, cambiado_por = excluded.cambiado_por, cambiado_en = now();
    INSERT INTO public.producto_precio (empresa_id, producto_id, sucursal_id, precio_anterior_centavos, precio_nuevo_centavos,
                                        incluye_isv_anterior, incluye_isv_nuevo, motivo, cambiado_por)
    VALUES (p_empresa_id, p.id, p_sucursal_id,
            CASE WHEN ps.activo THEN ps.precio_venta_centavos ELSE p.precio_venta_centavos END, p_precio_centavos,
            CASE WHEN ps.activo THEN ps.precio_incluye_isv ELSE p.precio_incluye_isv END, v_inc, trim(p_motivo), auth.uid());
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('producto_id', p.id, 'sucursal_id', p_sucursal_id, 'precio_centavos', coalesce(p_precio_centavos, p.precio_venta_centavos),
    'precio_incluye_isv', CASE WHEN p_precio_centavos IS NULL THEN p.precio_incluye_isv ELSE v_inc END,
    'origen', CASE WHEN p_precio_centavos IS NULL THEN 'general' ELSE 'sucursal' END, 'cambio', true);
END $$;

-- Precio de venta de un producto en una sucursal (el de la sucursal si hay y está activo; si no, el general).
CREATE FUNCTION public.precio_en_sucursal(p_empresa_id uuid, p_producto_id uuid, p_sucursal_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p  public.producto;
  ps public.producto_precio_sucursal;
BEGIN
  PERFORM interno.exigir_miembro(p_empresa_id);
  SELECT * INTO p FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
  END IF;
  SELECT x.* INTO ps FROM public.producto_precio_sucursal x JOIN public.empresa e ON e.id = x.empresa_id
   WHERE x.producto_id = p.id AND x.sucursal_id = p_sucursal_id AND x.activo AND e.precios_por_sucursal;
  RETURN jsonb_build_object('producto_id', p.id, 'sucursal_id', p_sucursal_id,
    'precio_centavos', coalesce(ps.precio_venta_centavos, p.precio_venta_centavos),
    'precio_incluye_isv', coalesce(ps.precio_incluye_isv, p.precio_incluye_isv),
    'origen', CASE WHEN ps.id IS NULL THEN 'general' ELSE 'sucursal' END);
END $$;

-- caja_de_venta (reemplaza la de 028; misma firma): además anota la sucursal de la venta para que
-- producto_de use el precio de esa sucursal (solo dentro de esta transacción).
CREATE OR REPLACE FUNCTION interno.caja_de_venta(p_empresa_id uuid, p_valor jsonb) RETURNS public.caja
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c   public.caja;
  v_n integer;
  v_id uuid := interno.json_uuid(p_valor, 'caja_id');
BEGIN
  IF v_id IS NULL THEN
    SELECT t.caja_id INTO v_id FROM public.turno_caja t
     WHERE t.empresa_id = p_empresa_id AND t.cajero_id = auth.uid() AND t.estado = 'abierto';
  END IF;
  IF v_id IS NULL THEN
    SELECT count(*), min(x.id::text)::uuid INTO v_n, v_id FROM public.caja x WHERE x.empresa_id = p_empresa_id AND x.activa;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique la caja de la venta ("caja_id"; la empresa tiene % cajas activas).', v_n;
    END IF;
  END IF;
  SELECT x.* INTO c FROM public.caja x JOIN public.sucursal s ON s.id = x.sucursal_id
   WHERE x.id = v_id AND x.empresa_id = p_empresa_id AND x.activa AND s.activa;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja no existe en esta empresa o está desactivada (ella o su sucursal).';
  END IF;
  PERFORM set_config('app.sucursal_venta', c.sucursal_id::text, true);
  RETURN c;
END $$;

-- producto_de (reemplaza la de 015; misma firma): con precios por sucursal activos y una venta en
-- curso (app.sucursal_venta), el precio es el de esa sucursal si tiene uno.
CREATE OR REPLACE FUNCTION interno.producto_de(p_empresa_id uuid, p_valor jsonb, p_linea integer, p_activo boolean)
RETURNS public.producto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p     public.producto;
  ps    public.producto_precio_sucursal;
  v_suc uuid := nullif(current_setting('app.sucursal_venta', true), '')::uuid;
BEGIN
  SELECT * INTO p FROM public.producto x
   WHERE x.empresa_id = p_empresa_id AND x.id = interno.json_uuid(p_valor, 'producto_id');
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'PRODUCTO_INVALIDO: el producto de la línea % no existe en esta empresa.', p_linea;
  END IF;
  IF p_activo AND NOT p.activo THEN
    RAISE EXCEPTION 'PRODUCTO_INVALIDO: el producto % (línea %) está desactivado.', p.codigo, p_linea;
  END IF;
  IF v_suc IS NOT NULL THEN
    SELECT x.* INTO ps FROM public.producto_precio_sucursal x JOIN public.empresa e ON e.id = x.empresa_id
     WHERE x.producto_id = p.id AND x.sucursal_id = v_suc AND x.activo AND e.precios_por_sucursal;
    IF ps.id IS NOT NULL THEN
      p.precio_venta_centavos := ps.precio_venta_centavos;
      p.precio_incluye_isv := ps.precio_incluye_isv;
    END IF;
  END IF;
  RETURN p;
END $$;

-- ---------------------------------------------------------------------
-- 5) Centro de control: sesión cerrada a distancia y horario de acceso
-- ---------------------------------------------------------------------
ALTER TABLE public.usuario_empresa ADD COLUMN sesion_cerrada_en timestamptz;
ALTER TABLE public.usuario_empresa ADD COLUMN sesion_cerrada_por uuid;

-- Horario por puesto: {"1":{"desde":"07:00","hasta":"18:00"}, ... "7":...} (1 = lunes ... 7 = domingo,
-- hora de la empresa). Un día que no está = ese día no se trabaja. Sin fila (o horario NULL) = sin límite.
CREATE TABLE public.horario_acceso (
  empresa_id     uuid NOT NULL REFERENCES public.empresa(id),
  rol            text NOT NULL REFERENCES public.rol(codigo) CHECK (rol NOT IN ('dueno', 'proveedor')),
  horario        jsonb CHECK (horario IS NULL OR jsonb_typeof(horario) = 'object'),
  cambiado_por   uuid,
  cambiado_en    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (empresa_id, rol)
);

-- Revisa la sesión (cerrada por el dueño/admin) y, si p_operar, el horario del puesto.
-- La sesión vale si el token se emitió DESPUÉS del cierre (claim "iat" del JWT de Supabase).
CREATE FUNCTION interno.revisar_acceso(p_empresa_id uuid, p_operar boolean) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  ue      public.usuario_empresa;
  v_iat   numeric;
  v_h     jsonb;
  v_local timestamp;
  v_dia   jsonb;
BEGIN
  SELECT * INTO ue FROM public.usuario_empresa x WHERE x.user_id = auth.uid() AND x.empresa_id = p_empresa_id AND x.activo;
  IF ue.id IS NULL THEN
    RETURN;
  END IF;
  IF ue.sesion_cerrada_en IS NOT NULL THEN
    v_iat := (nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'iat')::numeric;
    IF v_iat IS NULL OR to_timestamp(v_iat) <= ue.sesion_cerrada_en THEN
      RAISE EXCEPTION 'SESION_CERRADA: su sesión fue cerrada el %; vuelva a entrar.',
        to_char(ue.sesion_cerrada_en AT TIME ZONE (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id), 'DD/MM/YYYY HH24:MI');
    END IF;
  END IF;
  IF p_operar AND ue.rol NOT IN ('dueno', 'proveedor') THEN
    SELECT h.horario INTO v_h FROM public.horario_acceso h WHERE h.empresa_id = p_empresa_id AND h.rol = ue.rol;
    IF v_h IS NOT NULL THEN
      v_local := now() AT TIME ZONE (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id);
      v_dia := v_h->(extract(isodow FROM v_local)::integer::text);
      IF v_dia IS NULL OR v_local::time < (v_dia->>'desde')::time OR v_local::time >= (v_dia->>'hasta')::time THEN
        RAISE EXCEPTION 'FUERA_DE_HORARIO: el puesto "%" no puede operar ahora (%).', ue.rol,
          coalesce('hoy de ' || (v_dia->>'desde') || ' a ' || (v_dia->>'hasta'), 'hoy no es día de trabajo');
      END IF;
    END IF;
  END IF;
END $$;

-- exigir_escritura (reemplaza la de 030; misma firma y mismo orden). Nuevo: sesión cerrada y horario.
CREATE OR REPLACE FUNCTION interno.exigir_escritura(p_empresa_id uuid, p_permiso text,
                                                    p_modulo text DEFAULT 'contabilidad',
                                                    p_exigir_licencia boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  PERFORM interno.revisar_acceso(p_empresa_id, true);
  IF NOT public.tiene_permiso(p_permiso, p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "%".', p_permiso;
  END IF;
  IF p_exigir_licencia AND NOT public.licencia_activa(p_empresa_id) THEN
    RAISE EXCEPTION 'LICENCIA_VENCIDA: el sistema está en modo solo lectura. Puede consultar y exportar.';
  END IF;
  IF p_modulo IS NOT NULL AND NOT public.modulo_esta_activo(p_empresa_id, p_modulo)
     AND NOT interno.modulo_permite_apagado(p_empresa_id, p_modulo, p_permiso) THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "%" no está activo para esta empresa.', p_modulo;
  END IF;
END $$;

-- exigir_lectura (reemplaza la de 001; misma firma). Nuevo: sesión cerrada (el horario no impide consultar).
CREATE OR REPLACE FUNCTION interno.exigir_lectura(p_empresa_id uuid, p_permiso text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    IF coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
    END IF;
    RETURN;
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  PERFORM interno.revisar_acceso(p_empresa_id, false);
  IF NOT public.tiene_permiso(p_permiso, p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "%".', p_permiso;
  END IF;
END $$;

-- exigir_miembro (reemplaza la de 045; misma firma). Nuevo: sesión cerrada.
CREATE OR REPLACE FUNCTION interno.exigir_miembro(p_empresa_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    IF coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
    END IF;
    RETURN;
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  PERFORM interno.revisar_acceso(p_empresa_id, false);
END $$;

-- RPC: cerrar_sesion_usuario(empresa, usuario, motivo)   usuarios.administrar (mismas reglas que desactivar)
-- Marca la sesión como cerrada: desde ya el servidor rechaza todo lo que haga con su sesión anterior
-- (SESION_CERRADA) y la app lo manda a entrar de nuevo. Al entrar otra vez trabaja normal.
CREATE FUNCTION public.cerrar_sesion_usuario(p_empresa_id uuid, p_user_id uuid, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ue public.usuario_empresa;
  v_yo text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'usuarios.administrar', NULL, false);
  v_yo := public.mi_rol(p_empresa_id);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué cierra la sesión (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_ue FROM public.usuario_empresa WHERE user_id = p_user_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_ue.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: ese usuario no está en esta empresa.';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: para cerrar su propia sesión use "Salir" en la app.';
  END IF;
  IF v_ue.rol = 'dueno' AND v_yo <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: solo un dueño puede cerrar la sesión de otro dueño.';
  END IF;
  IF v_yo <> 'dueno' AND v_ue.rol NOT IN ('cajero', 'vendedor') THEN
    RAISE EXCEPTION 'PROHIBIDO: solo el dueño cierra la sesión de un administrador o del proveedor.';
  END IF;
  IF v_yo <> 'dueno' AND interno.rol_supera(p_empresa_id, v_ue.rol, v_yo) THEN
    RAISE EXCEPTION 'PROHIBIDO: ese usuario tiene un rol con permisos que usted no tiene; solo el dueño puede hacerlo.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.usuario_empresa SET sesion_cerrada_en = now(), sesion_cerrada_por = auth.uid() WHERE id = v_ue.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('usuario_id', p_user_id, 'sesion_cerrada_en', public.iso(now()));
END $$;

-- RPC: configurar_horario_acceso(empresa, rol, horario, motivo)   empresa.configurar (solo dueño)
-- horario NULL o {} = sin límite. Nunca para el dueño.
CREATE FUNCTION public.configurar_horario_acceso(p_empresa_id uuid, p_rol text, p_horario jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k   text;
  v   jsonb;
  v_h jsonb := nullif(nullif(p_horario, 'null'::jsonb), '{}'::jsonb);
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF p_rol IN ('dueno', 'proveedor') OR NOT EXISTS (SELECT 1 FROM public.rol r WHERE r.codigo = p_rol) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el horario es para un puesto existente que no sea dueño ni proveedor.';
  END IF;
  IF v_h IS NOT NULL THEN
    IF jsonb_typeof(v_h) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el horario es {"1":{"desde":"07:00","hasta":"18:00"}, ...} (1 = lunes, 7 = domingo).';
    END IF;
    FOR k, v IN SELECT * FROM jsonb_each(v_h) LOOP
      IF k !~ '^[1-7]$' OR jsonb_typeof(v) <> 'object' OR (v - 'desde' - 'hasta') <> '{}'::jsonb
         OR coalesce(v->>'desde', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
         OR coalesce(v->>'hasta', '') !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$'
         OR (v->>'desde')::time >= (v->>'hasta')::time THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el día "%" debe ser 1 a 7 con {"desde":"HH:MM","hasta":"HH:MM"} y desde antes que hasta.', k;
      END IF;
    END LOOP;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.horario_acceso (empresa_id, rol, horario, cambiado_por) VALUES (p_empresa_id, p_rol, v_h, auth.uid())
  ON CONFLICT (empresa_id, rol) DO UPDATE SET horario = excluded.horario, cambiado_por = excluded.cambiado_por, cambiado_en = now();
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('rol', p_rol, 'horario', v_h);
END $$;

-- RPC: mi_estado_sesion(empresa): la app la consulta (al abrir y cada pocos minutos) para saber si
-- debe sacar al usuario (sesión cerrada), si está dentro de su horario y en qué sucursales trabaja.
CREATE FUNCTION public.mi_estado_sesion(p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  ue      public.usuario_empresa;
  v_iat   numeric := (nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'iat')::numeric;
  v_h     jsonb;
  v_local timestamp;
  v_dia   jsonb;
  v_dentro boolean := true;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  SELECT * INTO ue FROM public.usuario_empresa x WHERE x.user_id = auth.uid() AND x.empresa_id = p_empresa_id;
  IF ue.id IS NULL OR NOT ue.activo THEN
    RETURN jsonb_build_object('activo', false, 'debe_salir', true, 'motivo', 'Su usuario fue desactivado en esta empresa.');
  END IF;
  IF ue.rol NOT IN ('dueno', 'proveedor') THEN
    SELECT h.horario INTO v_h FROM public.horario_acceso h WHERE h.empresa_id = p_empresa_id AND h.rol = ue.rol;
    IF v_h IS NOT NULL THEN
      v_local := now() AT TIME ZONE (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id);
      v_dia := v_h->(extract(isodow FROM v_local)::integer::text);
      v_dentro := v_dia IS NOT NULL AND v_local::time >= (v_dia->>'desde')::time AND v_local::time < (v_dia->>'hasta')::time;
    END IF;
  END IF;
  RETURN jsonb_build_object('activo', true,
    'debe_salir', ue.sesion_cerrada_en IS NOT NULL AND (v_iat IS NULL OR to_timestamp(v_iat) <= ue.sesion_cerrada_en),
    'sesion_cerrada_en', public.iso(ue.sesion_cerrada_en),
    'horario', v_h, 'horario_hoy', v_dia, 'dentro_de_horario', v_dentro,
    'sucursales', CASE WHEN interno.usuario_restringido(p_empresa_id) THEN
      (SELECT jsonb_agg(jsonb_build_object('sucursal_id', s.id, 'codigo', s.codigo, 'nombre', s.nombre) ORDER BY s.codigo)
         FROM public.usuario_sucursal us JOIN public.sucursal s ON s.id = us.sucursal_id
        WHERE us.empresa_id = p_empresa_id AND us.user_id = auth.uid() AND us.activo) END,
    'todas_las_sucursales', NOT interno.usuario_restringido(p_empresa_id));
END $$;

-- ---------------------------------------------------------------------
-- 5b) Vigilancia por empleado y bitácora legible
-- ---------------------------------------------------------------------
-- RPC: vigilancia_empleados(empresa, desde, hasta, usuario?)   bitacora.ver
-- Por empleado: ventas (ventas.ver), ganancia generada (además inventario.costos), descuentos dados,
-- anulaciones pedidas, diferencias de caja de sus turnos cerrados y horario de uso (primera y última
-- acción guardada de cada día, de la bitácora). Ventas y turnos solo de las sucursales que uno ve.
CREATE FUNCTION public.vigilancia_empleados(p_empresa_id uuid, p_desde date, p_hasta date, p_user_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ventas boolean;
  v_costos boolean;
  v_zona   text := (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id);
  v_r      jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'bitacora.ver');
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta OR p_hasta - p_desde > 366 THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: indique desde y hasta (desde antes que hasta, máximo un año).';
  END IF;
  v_ventas := public.puede_leer(p_empresa_id, 'ventas.ver');
  v_costos := public.puede_leer(p_empresa_id, 'inventario.costos');

  WITH u AS (
    SELECT ue.user_id, coalesce(ue.nombre, au.email) AS nombre, ue.rol, ue.activo
      FROM public.usuario_empresa ue JOIN auth.users au ON au.id = ue.user_id
     WHERE ue.empresa_id = p_empresa_id AND ue.rol <> 'proveedor' AND (p_user_id IS NULL OR ue.user_id = p_user_id)
  ), v AS (
    SELECT x.emitida_por AS user_id, count(*) AS n, sum(x.total_centavos) AS tot,
           sum(x.total_centavos - x.impuesto_centavos - coalesce(x.costo_centavos, 0)) AS ganancia,
           count(*) FILTER (WHERE x.descuento_manual_centavos > 0) AS desc_n, coalesce(sum(x.descuento_manual_centavos), 0) AS desc_tot
      FROM public.venta x
     WHERE x.empresa_id = p_empresa_id AND x.estado = 'emitida' AND x.fecha_contable BETWEEN p_desde AND p_hasta
       AND interno.sucursal_permitida(p_empresa_id, x.sucursal_id)
     GROUP BY 1
  ), a AS (
    SELECT x.solicitado_por AS user_id, count(*) AS n,
           count(*) FILTER (WHERE x.estado = 'aprobada') AS aprobadas, coalesce(sum(vv.total_centavos), 0) AS monto
      FROM public.venta_anulacion x JOIN public.venta vv ON vv.id = x.venta_id
     WHERE x.empresa_id = p_empresa_id AND (x.solicitado_en AT TIME ZONE v_zona)::date BETWEEN p_desde AND p_hasta
       AND interno.sucursal_permitida(p_empresa_id, vv.sucursal_id)
     GROUP BY 1
  ), t AS (
    SELECT x.cajero_id AS user_id, count(*) AS n,
           coalesce(sum(x.diferencia_centavos) FILTER (WHERE x.diferencia_centavos < 0), 0) AS faltante,
           coalesce(sum(x.diferencia_centavos) FILTER (WHERE x.diferencia_centavos > 0), 0) AS sobrante,
           count(*) FILTER (WHERE x.diferencia_centavos <> 0) AS con_dif
      FROM public.turno_caja x
     WHERE x.empresa_id = p_empresa_id AND x.estado <> 'abierto' AND x.fecha_cierre BETWEEN p_desde AND p_hasta
       AND interno.sucursal_permitida(p_empresa_id, x.sucursal_id)
     GROUP BY 1
  ), h AS (
    SELECT y.usuario_id AS user_id, jsonb_agg(jsonb_build_object('fecha', to_char(y.dia, 'YYYY-MM-DD'),
             'primera', to_char(y.primera, 'HH24:MI'), 'ultima', to_char(y.ultima, 'HH24:MI'), 'acciones', y.n) ORDER BY y.dia) AS dias
      FROM (SELECT b.usuario_id, (b.ocurrido_en AT TIME ZONE v_zona)::date AS dia,
                   min(b.ocurrido_en AT TIME ZONE v_zona) AS primera, max(b.ocurrido_en AT TIME ZONE v_zona) AS ultima, count(*) AS n
              FROM public.bitacora b
             WHERE b.empresa_id = p_empresa_id AND b.usuario_id IN (SELECT u.user_id FROM u)
               AND b.ocurrido_en >= (p_desde::timestamp AT TIME ZONE v_zona)
               AND b.ocurrido_en < ((p_hasta + 1)::timestamp AT TIME ZONE v_zona)
             GROUP BY 1, 2) y
     GROUP BY 1
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'usuario_id', u.user_id, 'nombre', u.nombre, 'rol', u.rol, 'activo', u.activo,
      'ventas', CASE WHEN v_ventas THEN jsonb_build_object('cantidad', coalesce(v.n, 0), 'total_centavos', coalesce(v.tot, 0)) END,
      'ganancia_centavos', CASE WHEN v_ventas AND v_costos THEN coalesce(v.ganancia, 0) END,
      'descuentos', CASE WHEN v_ventas THEN jsonb_build_object('ventas_con_descuento', coalesce(v.desc_n, 0), 'total_centavos', coalesce(v.desc_tot, 0)) END,
      'anulaciones_pedidas', jsonb_build_object('cantidad', coalesce(a.n, 0), 'aprobadas', coalesce(a.aprobadas, 0),
                                                'monto_centavos', CASE WHEN v_ventas THEN coalesce(a.monto, 0) END),
      'diferencias_caja', jsonb_build_object('turnos', coalesce(t.n, 0), 'turnos_con_diferencia', coalesce(t.con_dif, 0),
                                             'faltante_centavos', coalesce(t.faltante, 0), 'sobrante_centavos', coalesce(t.sobrante, 0),
                                             'neto_centavos', coalesce(t.faltante, 0) + coalesce(t.sobrante, 0)),
      'horario_uso', coalesce(h.dias, '[]'))
      ORDER BY coalesce(v.tot, 0) DESC, u.nombre), '[]')
    INTO v_r
    FROM u LEFT JOIN v ON v.user_id = u.user_id LEFT JOIN a ON a.user_id = u.user_id
           LEFT JOIN t ON t.user_id = u.user_id LEFT JOIN h ON h.user_id = u.user_id;

  RETURN jsonb_build_object('desde', to_char(p_desde, 'YYYY-MM-DD'), 'hasta', to_char(p_hasta, 'YYYY-MM-DD'),
    'empleados', v_r, 'costos_ocultos', NOT v_costos, 'generado_en', public.iso(now()),
    'nota', 'Ventas emitidas por quien las registró. Ganancia = ventas sin ISV - costo. Descuentos = los manuales (no las promociones). Horario de uso = primera y última vez que guardó algo cada día (consultar no queda en la bitácora).');
END $$;

-- Palabras sencillas para la bitácora: tipo y nombre de cada tabla.
CREATE TABLE interno.bitacora_palabra (
  tabla   text PRIMARY KEY,
  tipo    text NOT NULL,
  nombre  text NOT NULL,      -- "una venta", "un gasto"
  detalle boolean NOT NULL DEFAULT false   -- true = renglones internos (solo con "detalle": true)
);
INSERT INTO interno.bitacora_palabra (tabla, tipo, nombre, detalle) VALUES
  ('venta', 'ventas', 'una venta', false), ('venta_anulacion', 'ventas', 'una solicitud de anulación', false),
  ('cotizacion', 'ventas', 'una cotización', false), ('apartado', 'ventas', 'un apartado', false),
  ('devolucion', 'ventas', 'una devolución', false), ('cobro', 'ventas', 'un cobro', false),
  ('tercero', 'ventas', 'un cliente o proveedor', false), ('saldo_favor', 'ventas', 'un saldo a favor', false),
  ('gasto', 'dinero', 'un gasto', false), ('operacion_dinero', 'dinero', 'un movimiento de dinero', false),
  ('turno_caja', 'dinero', 'un turno de caja', false), ('cuenta_dinero', 'dinero', 'una cuenta de dinero', false),
  ('pago_fijo', 'dinero', 'un pago fijo', false), ('conciliacion', 'dinero', 'una conciliación', false),
  ('inventario_documento', 'inventario', 'un documento de inventario', false), ('conteo_fisico', 'inventario', 'un conteo físico', false),
  ('traslado_recepcion', 'inventario', 'la recepción de un traslado', false),
  ('producto', 'productos', 'un producto', false), ('producto_precio', 'productos', 'un precio', false),
  ('producto_precio_sucursal', 'productos', 'un precio por sucursal', false), ('categoria_producto', 'productos', 'una categoría', false),
  ('promocion', 'productos', 'una promoción', false),
  ('compra', 'compras', 'una compra', false), ('pago_proveedor', 'compras', 'un pago a proveedor', false),
  ('usuario_empresa', 'usuarios', 'un usuario', false), ('usuario_sucursal', 'usuarios', 'las sucursales de un usuario', false),
  ('horario_acceso', 'usuarios', 'el horario de un puesto', false), ('rol_permiso', 'usuarios', 'un permiso de un puesto', false),
  ('empresa', 'configuracion', 'la configuración de la empresa', false), ('sucursal', 'configuracion', 'una sucursal', false),
  ('caja', 'configuracion', 'una caja', false), ('bodega', 'configuracion', 'una bodega', false),
  ('aprobacion', 'aprobaciones', 'una aprobación', false),
  ('asiento', 'contabilidad', 'un asiento contable', false), ('periodo', 'contabilidad', 'un mes contable', false),
  ('cierre', 'contabilidad', 'un cierre de mes', false),
  ('asiento_linea', 'contabilidad', 'una línea de asiento', true), ('dinero_movimiento', 'dinero', 'un movimiento del rastro', true),
  ('inventario_movimiento', 'inventario', 'un movimiento del kardex', true), ('inventario_saldo', 'inventario', 'una existencia', true),
  ('venta_linea', 'ventas', 'una línea de venta', true), ('venta_pago', 'ventas', 'un pago de venta', true),
  ('inventario_documento_linea', 'inventario', 'una línea de inventario', true), ('compra_linea', 'compras', 'una línea de compra', true),
  ('cierre_detalle', 'contabilidad', 'un detalle de cierre', true), ('adjunto', 'otros', 'un comprobante', false);

-- Verbo de una fila de la bitácora.
CREATE FUNCTION interno.bitacora_verbo(p_accion text, p_antes jsonb, p_despues jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_accion = 'INSERT' THEN 'creó'
    WHEN p_accion = 'DELETE' THEN 'borró'
    WHEN p_despues->>'anulada_en' IS NOT NULL AND p_antes->>'anulada_en' IS NULL THEN 'anuló'
    WHEN p_despues->>'anulado_en' IS NOT NULL AND p_antes->>'anulado_en' IS NULL THEN 'anuló'
    WHEN coalesce(p_antes->>'activo', p_antes->>'activa') = 'true' AND coalesce(p_despues->>'activo', p_despues->>'activa') = 'false' THEN 'desactivó'
    WHEN coalesce(p_antes->>'activo', p_antes->>'activa') = 'false' AND coalesce(p_despues->>'activo', p_despues->>'activa') = 'true' THEN 'reactivó'
    WHEN p_despues->>'sesion_cerrada_en' IS DISTINCT FROM p_antes->>'sesion_cerrada_en' THEN 'cerró la sesión de'
    WHEN p_despues->>'estado' IS DISTINCT FROM p_antes->>'estado' THEN 'cambió a "' || replace(p_despues->>'estado', '_', ' ') || '"'
    ELSE 'cambió' END
$$;

-- RPC: bitacora_legible(empresa, filtros)   bitacora.ver
-- filtros = {"usuario_id"?, "desde"? "AAAA-MM-DD", "hasta"?, "tipo"? (ventas, dinero, inventario, productos,
--            compras, usuarios, configuracion, aprobaciones, contabilidad, otros), "detalle"? false,
--            "antes_de"? (secuencia, para pedir la página siguiente), "limite"? 100 (máximo 500)}
-- Cada fila: fecha y hora (de la empresa), persona, tipo, texto ("María Pérez creó una venta #15"), motivo.
CREATE FUNCTION public.bitacora_legible(p_empresa_id uuid, p_filtros jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f        jsonb := coalesce(nullif(p_filtros, 'null'::jsonb), '{}');
  v_zona   text := (SELECT e.zona_horaria FROM public.empresa e WHERE e.id = p_empresa_id);
  v_user   uuid;
  v_desde  date;
  v_hasta  date;
  v_tipo   text;
  v_det    boolean;
  v_antes  bigint;
  v_lim    integer;
  v_filas  jsonb;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'bitacora.ver');
  PERFORM interno.exigir_claves(f, ARRAY['usuario_id', 'desde', 'hasta', 'tipo', 'detalle', 'antes_de', 'limite']);
  v_user := interno.json_uuid(f->'usuario_id', 'usuario_id');
  v_desde := interno.json_fecha(f->'desde', 'desde');
  v_hasta := interno.json_fecha(f->'hasta', 'hasta');
  v_tipo := interno.json_texto(f->'tipo', 'tipo', 30);
  IF v_tipo IS NOT NULL AND v_tipo NOT IN (SELECT DISTINCT bp.tipo FROM interno.bitacora_palabra bp) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo es ventas, dinero, inventario, productos, compras, usuarios, configuracion, aprobaciones, contabilidad u otros.';
  END IF;
  v_det := coalesce((f->>'detalle')::boolean, false);
  v_antes := (f->>'antes_de')::bigint;
  v_lim := least(greatest(coalesce((f->>'limite')::integer, 100), 1), 500);

  SELECT coalesce(jsonb_agg(x.fila ORDER BY x.secuencia DESC), '[]') INTO v_filas FROM (
    SELECT b.secuencia, jsonb_build_object(
      'secuencia', b.secuencia,
      'fecha', to_char(b.ocurrido_en AT TIME ZONE v_zona, 'YYYY-MM-DD'),
      'hora', to_char(b.ocurrido_en AT TIME ZONE v_zona, 'HH24:MI:SS'),
      'ocurrido_en', public.iso(b.ocurrido_en),
      'usuario_id', b.usuario_id,
      'persona', coalesce(ue.nombre, au.email, 'El sistema'),
      'rol', b.rol_sesion,
      'tipo', coalesce(bp.tipo, 'otros'),
      'texto', coalesce(ue.nombre, au.email, 'El sistema') || ' ' || interno.bitacora_verbo(b.accion, b.antes, b.despues) || ' '
               || coalesce(bp.nombre, 'un registro (' || replace(b.tabla, '_', ' ') || ')')
               || coalesce(' #' || (coalesce(b.despues, b.antes)->>'numero'), '')
               || coalesce(' "' || (coalesce(b.despues, b.antes)->>'nombre') || '"', ''),
      'motivo', b.motivo,
      'tabla', b.tabla,
      'registro_id', b.registro_id) AS fila
      FROM public.bitacora b
      LEFT JOIN interno.bitacora_palabra bp ON bp.tabla = b.tabla
      LEFT JOIN public.usuario_empresa ue ON ue.user_id = b.usuario_id AND ue.empresa_id = p_empresa_id
      LEFT JOIN auth.users au ON au.id = b.usuario_id
     WHERE b.empresa_id = p_empresa_id
       AND (v_user IS NULL OR b.usuario_id = v_user)
       AND (v_desde IS NULL OR b.ocurrido_en >= (v_desde::timestamp AT TIME ZONE v_zona))
       AND (v_hasta IS NULL OR b.ocurrido_en < ((v_hasta + 1)::timestamp AT TIME ZONE v_zona))
       AND (v_tipo IS NULL OR coalesce(bp.tipo, 'otros') = v_tipo)
       AND (v_det OR NOT coalesce(bp.detalle, false))
       AND (v_antes IS NULL OR b.secuencia < v_antes)
     ORDER BY b.secuencia DESC
     LIMIT v_lim) x;

  RETURN jsonb_build_object('filas', v_filas, 'cantidad', jsonb_array_length(v_filas),
    'siguiente_antes_de', CASE WHEN jsonb_array_length(v_filas) = v_lim THEN (v_filas->(v_lim - 1)->>'secuencia')::bigint END);
END $$;

-- ---------------------------------------------------------------------
-- 6) Índices (volumen)
-- ---------------------------------------------------------------------
CREATE INDEX bitacora_usuario_fecha ON public.bitacora (empresa_id, usuario_id, ocurrido_en);
CREATE INDEX venta_sucursal_fecha ON public.venta (empresa_id, sucursal_id, fecha_contable);
CREATE INDEX venta_emitida_por ON public.venta (empresa_id, emitida_por, fecha_contable);
-- Saldo de una cuenta de dinero sin leer cada fila de la tabla.
CREATE INDEX dinero_movimiento_cuenta_monto ON public.dinero_movimiento (cuenta_dinero_id) INCLUDE (monto_centavos);
-- Cada operación pregunta "¿este id_operacion ya se usó?" en muchas columnas (interno.tipo_operacion*).
-- Las que no tenían índice hacían recorrer la tabla entera: con 20,000 ventas, cada venta tardaba el doble.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.relname AS t, a.attname AS col
             FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
              AND a.attname LIKE '%id_operacion' AND a.atttypid = 'uuid'::regtype
              AND EXISTS (SELECT 1 FROM pg_attribute x WHERE x.attrelid = c.oid AND x.attname = 'empresa_id')
              AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid
                                AND (i.indkey[0] = a.attnum
                                     OR (i.indkey[1] = a.attnum AND i.indkey[0] = (SELECT x.attnum FROM pg_attribute x
                                                                                     WHERE x.attrelid = c.oid AND x.attname = 'empresa_id'))))
  LOOP
    EXECUTE format('CREATE INDEX %I ON public.%I (empresa_id, %I) WHERE %I IS NOT NULL',
                   left(r.t || '_' || r.col, 63), r.t, r.col, r.col);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 7) Seguridad de las tablas nuevas
-- ---------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('usuario_sucursal', '(empresa_id IN (SELECT public.mis_empresas()))'),
                                 ('traslado_recepcion', '(empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(''inventario.ver''))))'),
                                 ('producto_precio_sucursal', '(empresa_id IN (SELECT public.mis_empresas()))'),
                                 ('horario_acceso', '(empresa_id IN (SELECT public.mis_empresas()))')) x(t, filtro) LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', r.t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   r.t, 'No se borra: se desactiva o se cambia.');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   r.t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', r.t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', r.t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated USING %s', r.t, r.filtro);
  END LOOP;
END $$;
REVOKE ALL ON interno.bitacora_palabra FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION
  interno.usuario_restringido(uuid), interno.sucursal_permitida(uuid, uuid), interno.exigir_sucursal(uuid, uuid),
  interno.revisar_sucursal_fila(), interno.revisar_acceso(uuid, boolean), interno.bitacora_verbo(text, jsonb, jsonb)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.sucursales_permitidas(), public.bodegas_permitidas(), public.cajas_permitidas(), public.cuentas_dinero_permitidas()
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.sucursales_permitidas(), public.bodegas_permitidas(), public.cajas_permitidas(), public.cuentas_dinero_permitidas()
TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.asignar_sucursales_usuario(uuid, uuid, uuid[], text), public.reporte_sucursales(uuid, date, date),
  public.enviar_dinero_sucursal(uuid, jsonb, uuid), public.recibir_dinero_sucursal(uuid, uuid, date, text),
  public.confirmar_recepcion_traslado(uuid, uuid, text), public.pendientes_entre_sucursales(uuid),
  public.activar_precios_sucursal(uuid, boolean, text), public.fijar_precio_sucursal(uuid, uuid, uuid, bigint, text, boolean),
  public.precio_en_sucursal(uuid, uuid, uuid), public.cerrar_sesion_usuario(uuid, uuid, text),
  public.configurar_horario_acceso(uuid, text, jsonb, text), public.mi_estado_sesion(uuid),
  public.vigilancia_empleados(uuid, date, date, uuid), public.bitacora_legible(uuid, jsonb)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.asignar_sucursales_usuario(uuid, uuid, uuid[], text), public.reporte_sucursales(uuid, date, date),
  public.enviar_dinero_sucursal(uuid, jsonb, uuid), public.recibir_dinero_sucursal(uuid, uuid, date, text),
  public.confirmar_recepcion_traslado(uuid, uuid, text), public.pendientes_entre_sucursales(uuid),
  public.activar_precios_sucursal(uuid, boolean, text), public.fijar_precio_sucursal(uuid, uuid, uuid, bigint, text, boolean),
  public.precio_en_sucursal(uuid, uuid, uuid), public.cerrar_sesion_usuario(uuid, uuid, text),
  public.configurar_horario_acceso(uuid, text, jsonb, text), public.mi_estado_sesion(uuid),
  public.vigilancia_empleados(uuid, date, date, uuid), public.bitacora_legible(uuid, jsonb)
TO authenticated;
