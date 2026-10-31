-- =====================================================================
-- 039_correcciones_revision_091.sql  -  Núcleo 0.9.2: correcciones de la
-- revisión de 0.9.1 (docs/PENDIENTES.md). Las 001-038 no se tocan.
--
--   IMPORTANTE
--   1. Vendedor heredado: la regla de vendedor_id (activo y con puesto que
--      vende) vale solo cuando el vendedor se ELIGE en el momento. Al completar
--      un apartado o convertir una cotización se respeta el vendedor del
--      documento guardado (aunque hoy esté dado de baja o su puesto solo
--      cotice); la comisión sigue yendo a él (el dueño decide al liquidar).
--   MENORES
--   2. Cuenta de salida elegida: anular_cobro y resolver_aprobacion (anular
--      una venta) aceptan un último parámetro opcional p_cuenta_salida_id
--      (caja fuerte, banco, caja chica o la caja del turno propio) para el
--      efectivo; nunca el turno de otro cajero (TURNO_AJENO).
--   3. El porcentaje de comisión queda guardado en la venta al emitirla
--      (venta.comision_porcentaje) y se usa al devengar; las ventas de antes
--      (sin porcentaje guardado) siguen con la regla anterior.
--   4. definir_destino_devolucion actualiza el texto de la aprobación
--      pendiente (destino actual) y reinicia una primera aprobación.
--   5. Tope por línea: 2 centavos de tolerancia (el ajuste del último centavo
--      del descuento de factura en monto ya no pide aprobación).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Ayudantes
-- ---------------------------------------------------------------------
-- Cuenta de salida que ELIGE quien anula para el efectivo (0.9.2). Se puede pagar
-- desde ella (caja, caja chica o banco) y, si es una caja con turnos, solo la del
-- turno abierto propio: nunca el turno de otro cajero (TURNO_AJENO).
CREATE FUNCTION interno.cuenta_salida_elegida(p_empresa_id uuid, p_cuenta_id uuid) RETURNS public.cuenta_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  d := interno.cuenta_dinero_para_pagar(p_empresa_id, p_cuenta_id);
  PERFORM interno.cuenta_salida_efectivo(p_empresa_id, d.id, ARRAY[auth.uid()], false);
  RETURN d;
END $$;

-- (reemplaza la de 038; misma firma) Mayor descuento manual de UNA línea que pasa
-- el tope (NULL si ninguna). 0.9.2: se toleran 2 centavos de redondeo (antes 1): el
-- ajuste del último centavo del descuento de factura en monto puede dejar 1 o 2
-- centavos más en una línea chica y eso no debe pedir aprobación.
CREATE OR REPLACE FUNCTION interno.descuento_linea_sobre_tope(p_lineas jsonb, p_tope numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT max(round(y.m * 100.0 / y.b, 2))
    FROM (SELECT (x->>'bruto_centavos')::bigint - coalesce((x->>'descuento_promocion_precio_centavos')::bigint, 0) AS b,
                 coalesce((x->>'descuento_linea_centavos')::bigint, 0) + coalesce((x->>'descuento_factura_centavos')::bigint, 0) AS m
            FROM jsonb_array_elements(coalesce(p_lineas, '[]'::jsonb)) x) y
   WHERE y.b > 0 AND (y.m - 2) * 100.0 > p_tope * y.b
$$;

-- ---------------------------------------------------------------------
-- 2) Porcentaje de comisión guardado en la venta al emitirla
-- ---------------------------------------------------------------------
-- NULL en las ventas de antes de 0.9.2 (siguen con la regla anterior: el vigente en su fecha).
ALTER TABLE public.venta ADD COLUMN comision_porcentaje numeric(5,2);

-- Al pasar a "emitida" se guarda el porcentaje vigente del vendedor en ese momento
-- (el que vale para la fecha de la venta). Un cambio hecho después, aunque sea con
-- "desde" = hoy, ya no toca esta venta. Se llama "comision_..." para correr antes
-- que "proteger" (los triggers corren por orden de nombre).
CREATE FUNCTION interno.venta_comision_al_emitir() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.estado IN ('por_emitir', 'pendiente_aprobacion') AND NEW.estado = 'emitida' THEN
    NEW.comision_porcentaje := interno.porcentaje_comision(NEW.empresa_id, NEW.vendedor_id, NEW.fecha_contable);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER comision_al_emitir BEFORE UPDATE ON public.venta FOR EACH ROW EXECUTE FUNCTION interno.venta_comision_al_emitir();

-- (reemplaza la de 028; misma firma) Al emitir también se anota comision_porcentaje.
CREATE OR REPLACE FUNCTION interno.proteger_venta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_emi constant text[] := ARRAY['estado', 'fecha_contable', 'numero_documento', 'regimen_fiscal', 'datos_fiscales',
    'vence_el', 'asiento_id', 'costo_centavos', 'emitida_en', 'emitida_por', 'comision_porcentaje'];
  c_can constant text[] := ARRAY['estado', 'cancelada_en', 'cancelada_por', 'motivo_cancelacion', 'cancelacion_id_operacion'];
  c_anu constant text[] := ARRAY['estado', 'anulada_en', 'anulada_por', 'motivo_anulacion', 'fecha_anulacion',
    'asiento_anulacion_id', 'anulacion_id_operacion', 'anulacion_solicitud_id'];
BEGIN
  IF OLD.estado IN ('por_emitir', 'pendiente_aprobacion') AND NEW.estado = 'emitida'
     AND (to_jsonb(NEW) - c_emi) = (to_jsonb(OLD) - c_emi) THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'pendiente_aprobacion' AND NEW.estado IN ('rechazada', 'cancelada')
     AND (to_jsonb(NEW) - c_can) = (to_jsonb(OLD) - c_can) THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'emitida' AND NEW.estado = 'anulada'
     AND (to_jsonb(NEW) - c_anu) = (to_jsonb(OLD) - c_anu) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una venta no se edita; se emite, se rechaza o se anula una sola vez.';
END $$;

-- (reemplaza la de 036; misma firma) Usa el porcentaje guardado en la venta.
CREATE OR REPLACE FUNCTION interno.recalcular_comision(p_venta_id uuid, p_id_operacion uuid, p_fecha date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v        public.venta;
  e        public.empresa;
  m0       public.comision_movimiento;
  v_hay    integer;
  v_actual bigint;
  v_pct    numeric;
  v_btipo  text;
  v_base   bigint := 0;
  v_obj    bigint := 0;
  v_dif    bigint;
  v_asto   uuid;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RETURN;
  END IF;
  SELECT * INTO e FROM public.empresa WHERE id = v.empresa_id;
  SELECT count(*), coalesce(sum(x.monto_centavos), 0) INTO v_hay, v_actual FROM public.comision_movimiento x WHERE x.venta_id = v.id;
  SELECT * INTO m0 FROM public.comision_movimiento x WHERE x.venta_id = v.id ORDER BY x.id LIMIT 1;
  IF m0.id IS NOT NULL THEN
    v_pct := m0.porcentaje;  v_btipo := m0.base_tipo;   -- se respetan el % y la base con que se devengó
  ELSE
    IF NOT (e.comisiones_activas AND public.modulo_esta_activo(v.empresa_id, 'comisiones')) THEN
      RETURN;
    END IF;
    -- 0.9.2: el porcentaje que quedó guardado en la venta al emitirla; las ventas de antes
    -- (sin porcentaje guardado) siguen con la regla anterior (el vigente en su fecha).
    v_pct := coalesce(v.comision_porcentaje, interno.porcentaje_comision(v.empresa_id, v.vendedor_id, v.fecha_contable));
    v_btipo := e.comision_base;
    IF v_pct = 0 THEN
      RETURN;
    END IF;
  END IF;
  IF v.estado = 'emitida' AND interno.saldo_documento_cxc(v.id) <= 0 THEN
    v_base := interno.base_comision(v.id, v_btipo);
    v_obj := greatest(round(v_base * v_pct / 100), 0)::bigint;
  END IF;
  v_dif := v_obj - v_actual;
  IF v_dif = 0 THEN
    RETURN;
  END IF;
  v_asto := interno.asiento_sistema(v.empresa_id, interno.sucursal_activa(v.sucursal_id), p_fecha,
    CASE WHEN v_dif > 0 THEN 'Comisión de ' ELSE 'Ajuste de comisión de ' END || coalesce(public.nombre_usuario(v.empresa_id, v.vendedor_id), 'vendedor')
      || ' por la venta ' || v.numero_documento,
    'comision', md5(p_id_operacion::text || ':comision:' || v.id::text || ':' || v_hay)::uuid,
    jsonb_build_array(
      jsonb_build_object('uso', 'gasto_comisiones',     'debe',  greatest(v_dif, 0),  'descripcion', 'Comisión devengada'),
      jsonb_build_object('uso', 'comisiones_por_pagar', 'haber', greatest(v_dif, 0),  'descripcion', 'Comisión por pagar'),
      jsonb_build_object('uso', 'comisiones_por_pagar', 'debe',  greatest(-v_dif, 0), 'descripcion', 'Ajuste de comisión'),
      jsonb_build_object('uso', 'gasto_comisiones',     'haber', greatest(-v_dif, 0), 'descripcion', 'Ajuste de comisión')));
  INSERT INTO public.comision_movimiento (empresa_id, vendedor_id, venta_id, tipo, base_tipo, base_centavos, porcentaje, monto_centavos,
                                          fecha_contable, asiento_id, creado_por)
  VALUES (v.empresa_id, v.vendedor_id, v.id, CASE WHEN v_hay = 0 THEN 'devengo' ELSE 'ajuste' END, v_btipo, v_base, v_pct, v_dif,
          p_fecha, v_asto, auth.uid());
END $$;


-- ---------------------------------------------------------------------
-- 3) Aprobaciones (reemplaza la defensa de 028; misma firma): definir el
--    destino de una devolución pendiente cambia el texto de su solicitud y
--    reinicia la primera aprobación (solo esa función, con su marca).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.proteger_aprobacion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_mut constant text[] := ARRAY['estado', 'resuelto_por', 'rol_resolutor', 'resuelto_en', 'motivo_resolucion', 'resolucion_id_operacion'];
  c_pri constant text[] := ARRAY['primera_aprobacion_por', 'primera_aprobacion_rol', 'primera_aprobacion_en',
                                 'primera_aprobacion_motivo', 'primera_id_operacion'];
BEGIN
  IF OLD.estado = 'pendiente' AND NEW.estado = 'pendiente' AND OLD.primera_aprobacion_por IS NULL
     AND NEW.primera_aprobacion_por IS NOT NULL AND (to_jsonb(NEW) - c_pri) = (to_jsonb(OLD) - c_pri) THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'pendiente' AND NEW.estado <> 'pendiente'
     AND (to_jsonb(NEW) - c_mut) = (to_jsonb(OLD) - c_mut) THEN
    RETURN NEW;
  END IF;
  -- 0.9.2: definir_destino_devolucion (marca app.reiniciar_aprobacion = esta solicitud): cambia el
  -- texto y deja la primera aprobación en blanco; nada más.
  IF OLD.estado = 'pendiente' AND NEW.estado = 'pendiente' AND OLD.documento_tipo = 'devolucion'
     AND current_setting('app.reiniciar_aprobacion', true) = OLD.id::text
     AND NEW.primera_aprobacion_por IS NULL AND NEW.primera_aprobacion_en IS NULL AND NEW.primera_id_operacion IS NULL
     AND (to_jsonb(NEW) - c_pri - 'descripcion') = (to_jsonb(OLD) - c_pri - 'descripcion') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una aprobación no se edita; se resuelve una sola vez.';
END $$;

-- (reemplaza la de 038) resolver_aprobacion con un parámetro opcional más:
-- p_cuenta_salida_id, de dónde sale el EFECTIVO al aprobar la anulación de una venta.
DROP FUNCTION public.resolver_aprobacion(uuid, boolean, text, uuid, date);
CREATE FUNCTION public.resolver_aprobacion(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                           p_fecha date DEFAULT NULL, p_cuenta_salida_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a      public.aprobacion;
  v_td   record;
  v_pct  numeric;
  r      jsonb;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la solicitud de aprobación no existe.';
  END IF;
  IF p_cuenta_salida_id IS NOT NULL AND a.tipo <> 'anulacion_venta' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de salida solo se indica al aprobar la anulación de una venta (en una devolución, use definir_destino_devolucion).';
  END IF;
  IF a.tipo = 'gasto' THEN
    RETURN interno.resolver_aprobacion_gasto(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha);
  ELSIF a.tipo = 'venta' THEN
    -- 0.9.1: quien aprueba tampoco pasa su tope en una sola línea (salvo el dueño).
    IF p_aprobar AND a.estado = 'pendiente' AND public.mi_rol(a.empresa_id) <> 'dueno'
       AND public.tiene_permiso('ventas.aprobar', a.empresa_id)
       AND EXISTS (SELECT 1 FROM public.venta v WHERE v.id = a.documento_id AND 'descuento' = ANY (v.requiere_aprobacion)) THEN
      SELECT * INTO v_td FROM interno.tope_descuento(a.empresa_id, public.mi_rol(a.empresa_id));
      v_pct := interno.descuento_linea_sobre_tope((SELECT jsonb_agg(to_jsonb(l)) FROM public.venta_linea l WHERE l.venta_id = a.documento_id),
                                                 v_td.aprueba_hasta);
      IF v_pct IS NOT NULL THEN
        RAISE EXCEPTION 'TOPE_APROBACION: una línea lleva % %% de descuento y usted aprueba hasta % %%; pídale al dueño que lo apruebe.',
          v_pct, v_td.aprueba_hasta;
      END IF;
    END IF;
    IF p_aprobar AND NOT public.modulo_esta_activo(a.empresa_id, 'inventario')
       AND EXISTS (SELECT 1 FROM public.venta_linea l WHERE l.venta_id = a.documento_id AND NOT l.es_servicio) THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo: esta venta lleva bienes y no se puede emitir; recházela o cancélela.';
    END IF;
    IF p_aprobar AND NOT public.modulo_esta_activo(a.empresa_id, 'dinero')
       AND EXISTS (SELECT 1 FROM public.venta_pago g WHERE g.venta_id = a.documento_id AND g.forma IN ('efectivo', 'tarjeta', 'transferencia')) THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo: esta venta se cobra al contado y no se puede emitir; recházela o cancélela.';
    END IF;
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_aprobacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  ELSIF a.tipo = 'anulacion_venta' THEN
    -- 0.9.2: el efectivo puede salir de la cuenta que elige quien aprueba (caja fuerte, banco o su
    -- propio turno), por ejemplo cuando la única caja tiene abierto el turno de otro cajero.
    IF p_cuenta_salida_id IS NOT NULL AND p_aprobar THEN
      PERFORM interno.exigir_escritura(a.empresa_id, 'ventas.anular', 'ventas');
      PERFORM interno.cuenta_salida_elegida(a.empresa_id, p_cuenta_salida_id);
      PERFORM set_config('app.cuenta_salida', p_cuenta_salida_id::text, true);
    END IF;
    r := interno.ocultar_costos(a.empresa_id,
      interno.resolver_anulacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
    PERFORM set_config('app.cuenta_salida', '', true);
    RETURN r;
  ELSIF a.tipo = 'devolucion' THEN
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_aprobacion_devolucion(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  END IF;
  RAISE EXCEPTION 'NO_PERMITIDO: este tipo de aprobación (%) todavía no se resuelve aquí.', a.tipo;
END $$;

-- ---------------------------------------------------------------------
-- 4) Anular un cobro (reemplaza la de 038, con un parámetro opcional más:
--    p_cuenta_salida_id) y anular una venta (reemplaza la de 038; misma firma)
-- ---------------------------------------------------------------------
DROP FUNCTION public.anular_cobro(uuid, text, uuid, date);
CREATE FUNCTION public.anular_cobro(p_cobro_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL,
                                    p_cuenta_salida_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c       public.cobro;
  pg      public.cobro_pago;
  v_fecha date;
  v_lin   jsonb := '[]';
  v_asto  uuid;
  v_cta   uuid;
  v_vtas  uuid[];
  v       uuid;
  v_torig uuid;
  v_sal   public.cuenta_dinero;
BEGIN
  SELECT * INTO c FROM public.cobro WHERE id = p_cobro_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cobro no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, 'cobros.anular', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(c.empresa_id, p_id_operacion, 'anulacion_cobro');
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cobro_respuesta(c, true) || jsonb_build_object('asiento_anulacion_id', c.asiento_anulacion_id);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(c.empresa_id), c.fecha_contable));
  PERFORM interno.exigir_fecha_contable(c.empresa_id, v_fecha);
  IF v_fecha < c.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al cobro (%).', to_char(c.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(c.empresa_id, p_id_operacion, 'anulacion_cobro');
  SELECT * INTO c FROM public.cobro WHERE id = p_cobro_id FOR UPDATE;
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cobro_respuesta(c, true) || jsonb_build_object('asiento_anulacion_id', c.asiento_anulacion_id);
  END IF;
  IF c.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el cobro #% ya fue anulado.', c.numero;
  END IF;
  PERFORM interno.validar_anulacion_cobro(c);
  PERFORM interno.exigir_periodo_abierto(c.empresa_id, v_fecha);
  -- 0.9.2: cuenta de salida elegida para el efectivo (caja fuerte, banco o el turno propio).
  IF p_cuenta_salida_id IS NOT NULL THEN
    v_sal := interno.cuenta_salida_elegida(c.empresa_id, p_cuenta_salida_id);
  END IF;

  -- El excedente que quedó a favor del cliente se anula (si nadie lo usó).
  IF c.saldo_favor_id IS NOT NULL THEN
    PERFORM interno.anular_saldo_favor(c.saldo_favor_id, 'Anulación del cobro #' || c.numero || ': ' || trim(p_motivo));
  END IF;
  FOR pg IN SELECT * FROM public.cobro_pago x WHERE x.cobro_id = c.id ORDER BY x.linea LOOP
    IF pg.forma = 'saldo_favor' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos, 'descripcion', 'Vuelve el saldo a favor usado');
    ELSE
      v_cta := CASE WHEN pg.estado_transferencia = 'confirmada' THEN pg.banco_id ELSE pg.cuenta_dinero_id END;
      -- 0.9.1: el efectivo sale del turno abierto de quien anula (nunca del turno de otro cajero);
      -- 0.9.2: o de la cuenta de salida elegida.
      IF pg.forma = 'efectivo' THEN
        v_cta := coalesce(v_sal.id, (interno.cuenta_salida_efectivo(c.empresa_id, v_cta, ARRAY[auth.uid()], true)).id);
        v_torig := coalesce(v_torig, pg.turno_id);
      END IF;
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(v_cta), 'haber', pg.monto_centavos,
                                           'descripcion', 'Devolución del cobro (' || pg.forma || ')');
    END IF;
  END LOOP;
  v_lin := v_lin || jsonb_build_object('uso', CASE c.tipo WHEN 'apartado' THEN 'anticipo_clientes' ELSE 'cxc' END,
                                       'debe', c.aplicado_centavos, 'descripcion', 'Vuelve el saldo por cobrar')
                 || jsonb_build_object('uso', 'saldo_favor', 'debe', c.excedente_centavos, 'descripcion', 'Se anula el saldo a favor del excedente');
  v_asto := interno.asiento_sistema(c.empresa_id, interno.sucursal_activa(c.sucursal_id), v_fecha,
    'ANULACIÓN cobro #' || c.numero || ': ' || trim(p_motivo), 'anulacion_cobro', p_id_operacion, v_lin, c.asiento_id, trim(p_motivo));

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  PERFORM interno.devolver_usos_saldo_favor(c.id, 'Anulación del cobro #' || c.numero);
  SELECT array_agg(DISTINCT a.venta_id) INTO v_vtas FROM public.cxc_aplicacion a
   WHERE a.origen = 'cobro' AND a.origen_id = c.id AND a.anulada_en IS NULL AND a.venta_id IS NOT NULL;
  UPDATE public.cxc_aplicacion SET anulada_en = now() WHERE origen = 'cobro' AND origen_id = c.id AND anulada_en IS NULL;
  UPDATE public.cobro SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo), fecha_anulacion = v_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = c.id
  RETURNING * INTO c;
  PERFORM set_config('app.motivo', '', true);
  PERFORM set_config('app.turno_origen', coalesce(v_torig::text, ''), true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_cobro', 'cobro', c.id, trim(p_motivo), NULL);
  PERFORM set_config('app.turno_origen', '', true);
  FOREACH v IN ARRAY coalesce(v_vtas, '{}') LOOP
    PERFORM interno.recalcular_comision(v, p_id_operacion, v_fecha);
  END LOOP;
  RETURN interno.cobro_respuesta(c, false) || jsonb_build_object('asiento_anulacion_id', v_asto);
END $$;

CREATE OR REPLACE FUNCTION interno.anular_venta_base(p_venta_id uuid, p_fecha date, p_motivo text, p_id_operacion uuid,
                                                     p_solicitud_id uuid) RETURNS public.venta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v      public.venta;
  ln     public.venta_linea;
  pg     public.venta_pago;
  v_lin  jsonb := '[]';
  v_asto uuid;
  v_cta  uuid;
  v_ant  bigint := 0;
  v_torig uuid;
  v_aut  uuid[];
  v_sal  uuid := nullif(current_setting('app.cuenta_salida', true), '')::uuid;   -- 0.9.2 (ya validada)
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  IF interno.devoluciones_vigentes_venta(v.id) > 0 THEN
    RAISE EXCEPTION 'VENTA_CON_DEVOLUCIONES: la venta % tiene devoluciones (notas de crédito); ya no se anula completa.', v.numero_documento;
  END IF;
  PERFORM interno.exigir_periodo_abierto(v.empresa_id, v.fecha_contable);
  PERFORM interno.exigir_periodo_abierto(v.empresa_id, p_fecha);
  FOR ln IN SELECT * FROM public.venta_linea x WHERE x.venta_id = v.id AND NOT x.es_servicio ORDER BY x.linea LOOP
    PERFORM interno.mover_inventario(v.empresa_id, v.bodega_id, ln.producto_id, 'entrada', 'anulacion_venta', p_fecha,
                                     ln.cantidad, ln.costo_centavos, 'venta', v.id, p_id_operacion,
                                     'Anulación venta ' || v.numero_documento || ': ' || p_motivo, false);
  END LOOP;
  FOR pg IN SELECT * FROM public.venta_pago x WHERE x.venta_id = v.id ORDER BY x.linea LOOP
    IF pg.forma = 'credito' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'cxc', 'haber', pg.monto_centavos, 'descripcion', 'Reversión del crédito');
    ELSIF pg.forma = 'saldo_favor' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos, 'descripcion', 'Vuelve el saldo a favor usado');
    ELSIF pg.forma = 'anticipo' THEN
      v_ant := v_ant + pg.monto_centavos;
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos,
                                           'descripcion', 'El anticipo del apartado queda a favor del cliente');
    ELSE
      v_cta := CASE WHEN pg.estado_transferencia = 'confirmada' THEN pg.banco_id ELSE pg.cuenta_dinero_id END;
      -- 0.9.1: el efectivo sale del turno de quien anula (o de quien pidió la anulación, si su
      -- turno donde entró sigue abierto); nunca del turno de otro cajero.
      -- 0.9.2: o de la cuenta de salida que eligió quien aprueba (resolver_aprobacion).
      IF pg.forma = 'efectivo' THEN
        v_aut := ARRAY[auth.uid(), (SELECT s.solicitado_por FROM public.venta_anulacion s WHERE s.id = p_solicitud_id)];
        v_cta := coalesce(v_sal, (interno.cuenta_salida_efectivo(v.empresa_id, v_cta, v_aut, true)).id);
        v_torig := coalesce(v_torig, pg.turno_id);
      END IF;
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(v_cta),
                                           'haber', pg.monto_centavos, 'descripcion', 'Devolución del cobro (' || pg.forma || ')');
    END IF;
  END LOOP;
  v_lin := v_lin || jsonb_build_array(
    jsonb_build_object('uso', 'ventas',           'debe',  v.subtotal_centavos,  'descripcion', 'Reversión de ventas'),
    jsonb_build_object('uso', 'descuento_ventas', 'haber', v.descuento_centavos, 'descripcion', 'Reversión de descuentos'),
    jsonb_build_object('uso', 'inventario',       'debe',  v.costo_centavos,     'descripcion', 'Mercadería devuelta al inventario'),
    jsonb_build_object('uso', 'costo_ventas',     'haber', v.costo_centavos,     'descripcion', 'Reversión del costo'));
  v_lin := v_lin || coalesce((SELECT jsonb_agg(jsonb_build_object('cuenta', d->>'cuenta_por_pagar',
                                 'debe', (d->>'impuesto_centavos')::bigint, 'descripcion', 'Reversión impuesto ' || (d->>'nombre')))
                                FROM jsonb_array_elements(v.desglose_impuestos) d
                               WHERE (d->>'impuesto_centavos')::bigint > 0), '[]');
  v_asto := interno.asiento_sistema(v.empresa_id, v.sucursal_id, p_fecha,
    'ANULACIÓN venta ' || v.numero_documento || ': ' || p_motivo, 'anulacion_venta', p_id_operacion, v_lin,
    v.asiento_id, p_motivo);
  PERFORM set_config('app.motivo', p_motivo, true);
  PERFORM interno.devolver_usos_saldo_favor(v.id, 'Anulación de la venta ' || v.numero_documento);
  IF v_ant > 0 THEN
    PERFORM interno.crear_saldo_favor(v.empresa_id, v.cliente_id, 'anulacion_venta', 'venta', v.id, v_ant, p_fecha);
  END IF;
  UPDATE public.venta
     SET estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = p_motivo, fecha_anulacion = p_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion, anulacion_solicitud_id = p_solicitud_id
   WHERE id = v.id
  RETURNING * INTO v;
  PERFORM set_config('app.motivo', '', true);
  PERFORM set_config('app.turno_origen', coalesce(v_torig::text, ''), true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_venta', 'venta', v.id, p_motivo, NULL);
  PERFORM set_config('app.turno_origen', '', true);
  PERFORM interno.recalcular_comision(v.id, p_id_operacion, p_fecha);
  RETURN v;
END $$;

-- ---------------------------------------------------------------------
-- 5) Registrar una venta (reemplaza la de 038; misma firma): la regla del
--    vendedor solo cuando se elige en el momento.
-- ---------------------------------------------------------------------
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

  v_calc := coalesce(p_calculo, interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura'));
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

-- ---------------------------------------------------------------------
-- 6) Devolución pendiente: el destino actual en la solicitud de aprobación
--    (reemplaza la de 038; misma firma)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.definir_destino_devolucion(p_devolucion_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d      public.devolucion;
  e      public.empresa;
  v_dest text;
  v_cta  uuid;
  a      public.aprobacion;
  v_cambia boolean;
  v_reini  boolean := false;
BEGIN
  SELECT * INTO d FROM public.devolucion WHERE id = p_devolucion_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la devolución no existe.';
  END IF;
  PERFORM interno.exigir_escritura(d.empresa_id, 'ventas.devolver', 'ventas');
  IF auth.uid() IS DISTINCT FROM d.creado_por AND NOT public.tiene_permiso('ventas.aprobar', d.empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: solo quien pidió la devolución o quien la aprueba (permiso "ventas.aprobar") cambia su destino.';
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM interno.exigir_claves(coalesce(p_datos, '{}'::jsonb), ARRAY['destino', 'cuenta_dinero_id']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = d.empresa_id;
  v_dest := interno.json_texto(p_datos->'destino', 'destino', 20);
  IF coalesce(v_dest, '') NOT IN ('dinero', 'saldo_favor') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el destino es "dinero" o "saldo_favor" (un cambio de producto no queda pendiente).';
  END IF;
  IF NOT (CASE v_dest WHEN 'dinero' THEN 'devolver_dinero' ELSE 'nota_credito' END) = ANY (e.devolucion_tipos) THEN
    RAISE EXCEPTION 'DEVOLUCION_NO_PERMITIDA: el dueño no permite "%" (permitidos: %).', v_dest, array_to_string(e.devolucion_tipos, ', ');
  END IF;
  v_cta := interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id');
  IF v_dest = 'dinero' THEN
    IF v_cta IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique de qué cuenta sale el dinero ("cuenta_dinero_id": caja, caja chica o banco).';
    END IF;
    PERFORM interno.cuenta_dinero_para_pagar(d.empresa_id, v_cta);
    PERFORM interno.cuenta_salida_efectivo(d.empresa_id, v_cta, ARRAY[auth.uid(), d.creado_por], false);
  ELSIF v_cta IS NOT NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de dinero solo va al devolver dinero.';
  END IF;

  SELECT * INTO d FROM public.devolucion WHERE id = p_devolucion_id FOR UPDATE;
  IF d.estado <> 'pendiente_aprobacion' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la devolución #% ya está %; su destino ya no cambia.', d.numero, d.estado;
  END IF;
  v_cambia := (d.destino, d.cuenta_dinero_id) IS DISTINCT FROM (v_dest, v_cta);
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.devolucion SET destino = v_dest, cuenta_dinero_id = v_cta WHERE id = d.id RETURNING * INTO d;
  -- 0.9.2: quien aprueba ve el destino ACTUAL en el texto de la solicitud; si ya había una primera
  -- aprobación (doble aprobación), se aprobó otro destino: se reinicia y hay que aprobar de nuevo.
  SELECT * INTO a FROM public.aprobacion x WHERE x.id = d.aprobacion_id FOR UPDATE;
  IF v_cambia AND a.id IS NOT NULL AND a.estado = 'pendiente' THEN
    v_reini := a.primera_aprobacion_por IS NOT NULL;
    PERFORM set_config('app.reiniciar_aprobacion', a.id::text, true);
    UPDATE public.aprobacion
       SET descripcion = regexp_replace(a.descripcion, ' [|] Destino: .*$', '') || ' | Destino: '
             || CASE WHEN v_dest = 'dinero'
                     THEN 'devolver dinero de "' || (SELECT x.nombre FROM public.cuenta_dinero x WHERE x.id = v_cta) || '"'
                     ELSE 'saldo a favor del cliente (nota de crédito)' END
             || ' (cambiado: ' || trim(p_motivo) || ')',
           primera_aprobacion_por = NULL, primera_aprobacion_rol = NULL, primera_aprobacion_en = NULL,
           primera_aprobacion_motivo = NULL, primera_id_operacion = NULL
     WHERE id = a.id;
    PERFORM set_config('app.reiniciar_aprobacion', '', true);
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.ocultar_costos(d.empresa_id, interno.devolucion_respuesta(d, false)
           || jsonb_build_object('destino', d.destino, 'cuenta_dinero_id', d.cuenta_dinero_id,
                                 'aprobacion_descripcion', (SELECT x.descripcion FROM public.aprobacion x WHERE x.id = d.aprobacion_id),
                                 'aprobacion_reiniciada', v_reini), ARRAY['costo_centavos']);
END $$;

-- ---------------------------------------------------------------------
-- 7) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.cuenta_salida_elegida(uuid, uuid),
  interno.venta_comision_al_emitir()
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.resolver_aprobacion(uuid, boolean, text, uuid, date, uuid),
  public.anular_cobro(uuid, text, uuid, date, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.resolver_aprobacion(uuid, boolean, text, uuid, date, uuid),
  public.anular_cobro(uuid, text, uuid, date, uuid)
TO authenticated;
