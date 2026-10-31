-- =====================================================================
-- 021_correcciones_revision_040.sql  -  Núcleo 0.5.0
-- Correcciones de la revisión de 0.4.0 (las migraciones 001-020 no se tocan):
--
--   A. registrar_compra: la factura ya cargada como saldo inicial se busca
--      comparando el proveedor como uuid (antes como texto: un uuid escrito
--      en MAYÚSCULAS dejaba entrar la misma factura dos veces). Además la
--      revisión se hace con el candado de la empresa tomado.
--   B. Activar un módulo toma primero el candado de la empresa
--      (bloquear_libros): nadie registra un asiento a la cuenta controlada
--      mientras se compara libros contra módulo.
--   C. id_operacion por tipo: las RPC que lo revisaban ANTES del candado lo
--      vuelven a revisar DESPUÉS de bloquear_libros. Antes, dos operaciones
--      distintas con el mismo id al mismo tiempo podían pasar las dos (un
--      asiento manual podía devolver el asiento de una compra como "duplicado").
--   F. permite_fracciones: el motor de inventario bloquea el producto (FOR
--      SHARE) antes de su saldo y no deja una existencia con decimales en un
--      producto que no los acepta; el trigger que apaga la marca bloquea los
--      saldos del producto antes de revisarlos. Así no hay carrera entre
--      "quitar decimales" y un movimiento con decimales.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Ayudante de C: candado de la empresa + revisión del id_operacion.
-- Quien llama ya pasó exigir_escritura (así un usuario sin permiso no
-- puede hacer esperar a los demás).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.reservar_operacion(p_empresa_id uuid, p_id uuid, p_tipo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.bloquear_libros(p_empresa_id);
  -- Sentencia nueva = foto nueva: ya ve lo que otros confirmaron mientras se esperaba.
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id, p_tipo);
END $$;

-- ---------------------------------------------------------------------
-- B) Activación de módulos (reemplaza la de 019): primero el candado.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.revisar_activacion_modulo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_libros bigint;
  v_modulo bigint;
  v_cta    text;
BEGIN
  -- Mismo candado que asientos, compras, ajustes y pagos: mientras se
  -- compara, nadie mueve la cuenta que el módulo va a controlar.
  PERFORM interno.bloquear_libros(NEW.empresa_id);
  IF NOT NEW.activo OR (TG_OP = 'UPDATE' AND OLD.activo) THEN
    RETURN NEW;
  END IF;
  IF NEW.modulo = 'inventario' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'inventario');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := coalesce((SELECT sum(s.valor_centavos) FROM public.inventario_saldo s WHERE s.empresa_id = NEW.empresa_id), 0);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (inventario) tiene % en los libros y el kardex tiene %. Para activar el módulo: 1) registre un asiento que pase la diferencia a % Saldos de apertura (Dr %, Cr %); 2) active el módulo; 3) cargue las existencias con cargar_saldo_inicial (vuelve a llevar el valor a % contra Saldos de apertura).',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo),
        interno.cuenta_de(NEW.empresa_id, 'apertura_inventario'), interno.cuenta_de(NEW.empresa_id, 'apertura_inventario'), v_cta, v_cta;
    END IF;
  ELSIF NEW.modulo = 'compras' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'cxp');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_cxp(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (proveedores) tiene % en los libros y las facturas por pagar del sistema suman %. Para activar el módulo: 1) registre un asiento que pase la diferencia a % Saldos de apertura (Dr %, Cr %); 2) active el módulo; 3) registre cada factura pendiente con registrar_saldo_inicial_cxp.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo),
        interno.cuenta_de(NEW.empresa_id, 'apertura_cxp'), v_cta, interno.cuenta_de(NEW.empresa_id, 'apertura_cxp');
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- A + C) registrar_compra (envoltura; misma firma).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_compra(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_doc  text;
  v_prov uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.registrar', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'compra');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'compra');
  IF jsonb_typeof(p_datos) = 'object' AND jsonb_typeof(p_datos->'numero_documento') = 'string'
     AND jsonb_typeof(p_datos->'proveedor_id') = 'string'
     AND NOT EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    v_doc  := trim(p_datos->>'numero_documento');
    v_prov := interno.json_uuid(p_datos->'proveedor_id', 'proveedor_id');   -- uuid, no texto
    IF EXISTS (SELECT 1 FROM public.cxp_saldo_inicial s
                WHERE s.empresa_id = p_empresa_id AND s.proveedor_id = v_prov
                  AND upper(s.numero_documento) = upper(v_doc) AND s.anulada_en IS NULL) THEN
      RAISE EXCEPTION 'YA_EXISTE: la factura % de este proveedor ya está registrada como saldo inicial.', v_doc;
    END IF;
  END IF;
  RETURN interno.registrar_compra_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- ---------------------------------------------------------------------
-- C) Envolturas de 017 (mismas firmas): revisión rápida, candado y otra vez.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_asiento(p_empresa_id uuid, p_fecha date, p_descripcion text, p_lineas jsonb,
                                                    p_id_operacion uuid, p_sucursal_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'asientos.registrar');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'asiento');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'asiento');
  RETURN interno.registrar_asiento_base(p_empresa_id, p_fecha, p_descripcion, p_lineas, p_id_operacion, p_sucursal_id);
END $$;

CREATE OR REPLACE FUNCTION public.anular_asiento(p_asiento_id uuid, p_motivo text, p_id_operacion uuid DEFAULT NULL,
                                                 p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_orig  public.asiento;
  v_fecha date;
BEGIN
  SELECT * INTO v_orig FROM public.asiento WHERE id = p_asiento_id;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el asiento no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v_orig.empresa_id, 'asientos.anular');
  PERFORM interno.exigir_tipo_operacion(v_orig.empresa_id, p_id_operacion, 'anulacion_asiento');
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(v_orig.empresa_id), v_orig.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v_orig.empresa_id, v_fecha);
  IF v_fecha < v_orig.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación (%) no puede tener fecha anterior al asiento #% (%).',
      to_char(v_fecha, 'DD/MM/YYYY'), v_orig.numero, to_char(v_orig.fecha_contable, 'DD/MM/YYYY');
  END IF;
  PERFORM interno.reservar_operacion(v_orig.empresa_id, p_id_operacion, 'anulacion_asiento');
  RETURN interno.anular_asiento_base(p_asiento_id, p_motivo, p_id_operacion, v_fecha);
END $$;

CREATE OR REPLACE FUNCTION public.ajustar_inventario(p_empresa_id uuid, p_bodega_id uuid, p_fecha date,
                                                     p_lineas jsonb, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.ajustar', 'inventario');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'inventario_ajuste');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'inventario_ajuste');
  RETURN interno.ocultar_costos(p_empresa_id,
    interno.ajustar_inventario_base(p_empresa_id, p_bodega_id, p_fecha, p_lineas, p_motivo, p_id_operacion),
    ARRAY['sobrante_centavos', 'faltante_centavos', 'total_centavos']);
END $$;

CREATE OR REPLACE FUNCTION public.trasladar_inventario(p_empresa_id uuid, p_bodega_origen_id uuid, p_bodega_destino_id uuid,
                                                       p_fecha date, p_lineas jsonb, p_id_operacion uuid,
                                                       p_nota text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.trasladar', 'inventario');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'inventario_traslado');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'inventario_traslado');
  RETURN interno.ocultar_costos(p_empresa_id,
    interno.trasladar_inventario_base(p_empresa_id, p_bodega_origen_id, p_bodega_destino_id, p_fecha,
                                      p_lineas, p_id_operacion, p_nota),
    ARRAY['sobrante_centavos', 'faltante_centavos', 'total_centavos']);
END $$;

CREATE OR REPLACE FUNCTION public.crear_tercero(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'terceros.editar', NULL);
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'tercero');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'tercero');
  RETURN interno.crear_tercero_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- ---------------------------------------------------------------------
-- C) RPC completas de 018-020: pasan a interno.*_base y la pública
--    revisa permiso, toma el candado y revisa el id_operacion.
-- ---------------------------------------------------------------------
ALTER FUNCTION public.cargar_saldo_inicial(uuid, uuid, date, jsonb, uuid, text) SET SCHEMA interno;
ALTER FUNCTION interno.cargar_saldo_inicial(uuid, uuid, date, jsonb, uuid, text) RENAME TO cargar_saldo_inicial_base;
ALTER FUNCTION public.anular_documento_inventario(uuid, text, uuid, date) SET SCHEMA interno;
ALTER FUNCTION interno.anular_documento_inventario(uuid, text, uuid, date) RENAME TO anular_documento_inventario_base;
ALTER FUNCTION public.registrar_saldo_inicial_cxp(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.registrar_saldo_inicial_cxp(uuid, jsonb, uuid) RENAME TO registrar_saldo_inicial_cxp_base;
ALTER FUNCTION public.anular_saldo_inicial_cxp(uuid, text, uuid, date) SET SCHEMA interno;
ALTER FUNCTION interno.anular_saldo_inicial_cxp(uuid, text, uuid, date) RENAME TO anular_saldo_inicial_cxp_base;
ALTER FUNCTION public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text) SET SCHEMA interno;
ALTER FUNCTION interno.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text) RENAME TO pagar_proveedor_base;
ALTER FUNCTION public.anular_pago_proveedor(uuid, text, uuid, date) SET SCHEMA interno;
ALTER FUNCTION interno.anular_pago_proveedor(uuid, text, uuid, date) RENAME TO anular_pago_proveedor_base;
ALTER FUNCTION public.anular_compra(uuid, text, uuid, date) SET SCHEMA interno;
ALTER FUNCTION interno.anular_compra(uuid, text, uuid, date) RENAME TO anular_compra_base;
ALTER FUNCTION public.crear_producto(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.crear_producto(uuid, jsonb, uuid) RENAME TO crear_producto_base;

CREATE FUNCTION public.cargar_saldo_inicial(p_empresa_id uuid, p_bodega_id uuid, p_fecha date,
                                            p_lineas jsonb, p_id_operacion uuid, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.carga_inicial', 'inventario');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'inventario_carga_inicial');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'inventario_carga_inicial');
  RETURN interno.cargar_saldo_inicial_base(p_empresa_id, p_bodega_id, p_fecha, p_lineas, p_id_operacion, p_motivo);
END $$;

CREATE FUNCTION public.anular_documento_inventario(p_documento_id uuid, p_motivo text, p_id_operacion uuid,
                                                   p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_emp uuid;
BEGIN
  SELECT d.empresa_id INTO v_emp FROM public.inventario_documento d WHERE d.id = p_documento_id;
  IF v_emp IS NOT NULL AND p_id_operacion IS NOT NULL THEN
    PERFORM interno.exigir_escritura(v_emp, 'inventario.anular', 'inventario');
    PERFORM interno.exigir_tipo_operacion(v_emp, p_id_operacion, 'anulacion_inventario');
    PERFORM interno.reservar_operacion(v_emp, p_id_operacion, 'anulacion_inventario');
  END IF;
  RETURN interno.anular_documento_inventario_base(p_documento_id, p_motivo, p_id_operacion, p_fecha);
END $$;

CREATE FUNCTION public.registrar_saldo_inicial_cxp(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.saldo_inicial', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'saldo_inicial_cxp');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'saldo_inicial_cxp');
  RETURN interno.registrar_saldo_inicial_cxp_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

CREATE FUNCTION public.anular_saldo_inicial_cxp(p_saldo_inicial_id uuid, p_motivo text, p_id_operacion uuid,
                                                p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_emp uuid;
BEGIN
  SELECT s.empresa_id INTO v_emp FROM public.cxp_saldo_inicial s WHERE s.id = p_saldo_inicial_id;
  IF v_emp IS NOT NULL AND p_id_operacion IS NOT NULL THEN
    PERFORM interno.exigir_escritura(v_emp, 'compras.saldo_inicial', 'compras');
    PERFORM interno.exigir_tipo_operacion(v_emp, p_id_operacion, 'anulacion_saldo_inicial_cxp');
    PERFORM interno.reservar_operacion(v_emp, p_id_operacion, 'anulacion_saldo_inicial_cxp');
  END IF;
  RETURN interno.anular_saldo_inicial_cxp_base(p_saldo_inicial_id, p_motivo, p_id_operacion, p_fecha);
END $$;

CREATE FUNCTION public.pagar_proveedor(p_empresa_id uuid, p_compra_id uuid, p_monto_centavos bigint,
                                       p_fecha date, p_forma_pago text, p_id_operacion uuid,
                                       p_referencia text DEFAULT NULL, p_cuenta_pago text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.pagar', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'pago_proveedor');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'pago_proveedor');
  RETURN interno.pagar_proveedor_base(p_empresa_id, p_compra_id, p_monto_centavos, p_fecha, p_forma_pago,
                                      p_id_operacion, p_referencia, p_cuenta_pago);
END $$;

CREATE FUNCTION public.anular_pago_proveedor(p_pago_id uuid, p_motivo text, p_id_operacion uuid,
                                             p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_emp uuid;
BEGIN
  SELECT p.empresa_id INTO v_emp FROM public.pago_proveedor p WHERE p.id = p_pago_id;
  IF v_emp IS NOT NULL AND p_id_operacion IS NOT NULL THEN
    PERFORM interno.exigir_escritura(v_emp, 'compras.anular', 'compras');
    PERFORM interno.exigir_tipo_operacion(v_emp, p_id_operacion, 'anulacion_pago_proveedor');
    PERFORM interno.reservar_operacion(v_emp, p_id_operacion, 'anulacion_pago_proveedor');
  END IF;
  RETURN interno.anular_pago_proveedor_base(p_pago_id, p_motivo, p_id_operacion, p_fecha);
END $$;

CREATE FUNCTION public.anular_compra(p_compra_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_emp uuid;
BEGIN
  SELECT c.empresa_id INTO v_emp FROM public.compra c WHERE c.id = p_compra_id;
  IF v_emp IS NOT NULL AND p_id_operacion IS NOT NULL THEN
    PERFORM interno.exigir_escritura(v_emp, 'compras.anular', 'compras');
    PERFORM interno.exigir_tipo_operacion(v_emp, p_id_operacion, 'anulacion_compra');
    PERFORM interno.reservar_operacion(v_emp, p_id_operacion, 'anulacion_compra');
  END IF;
  RETURN interno.anular_compra_base(p_compra_id, p_motivo, p_id_operacion, p_fecha);
END $$;

CREATE FUNCTION public.crear_producto(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'producto');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'producto');
  RETURN interno.crear_producto_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- ---------------------------------------------------------------------
-- F) Motor de inventario (reemplaza el de 018; igual más el candado del
--    producto y la regla "sin decimales" sobre la existencia que queda).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.mover_inventario(
  p_empresa_id uuid, p_bodega_id uuid, p_producto_id uuid, p_tipo text, p_origen text,
  p_fecha date, p_cantidad numeric, p_valor bigint,
  p_documento_tipo text, p_documento_id uuid, p_id_operacion uuid,
  p_nota text DEFAULT NULL, p_negativo boolean DEFAULT false)
RETURNS public.inventario_movimiento
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s        public.inventario_saldo;
  m        public.inventario_movimiento;
  a        public.inventario_movimiento;
  v_q      numeric;      -- cantidad nueva
  v_mov    bigint;       -- valor del movimiento (con signo)
  v_sale   bigint;       -- valor que sale (positivo)
  v_v      bigint;       -- valor nuevo
  v_prom   numeric;      -- costo promedio nuevo
  v_codigo text;
  v_fracc  boolean;
  v_ultima date;
  v_suc    uuid;
BEGIN
  IF p_cantidad IS NULL OR p_cantidad = 0 THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: un movimiento de inventario necesita cantidad.';
  END IF;
  -- F) Primero el producto (FOR SHARE: quien apaga "permite_fracciones" espera
  -- a que este movimiento termine, o este espera a que el cambio se confirme
  -- y lee la marca nueva). Siempre producto antes que saldo: sin bloqueos cruzados.
  SELECT p.codigo, p.permite_fracciones INTO v_codigo, v_fracc
    FROM public.producto p WHERE p.id = p_producto_id FOR SHARE;
  s   := interno.bloquear_saldo(p_empresa_id, p_bodega_id, p_producto_id);
  v_q := s.cantidad + p_cantidad;
  IF NOT v_fracc AND v_q <> trunc(v_q) THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: el producto % se maneja por unidades enteras; la existencia en la bodega quedaría en %.',
      v_codigo, v_q;
  END IF;

  IF p_cantidad > 0 THEN
    IF p_valor IS NULL OR p_valor < 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: una entrada de inventario necesita su valor (0 o más).';
    END IF;
    -- Orden de registro: no entra nada "antes" de una salida ya hecha.
    SELECT max(x.fecha_contable) INTO v_ultima FROM public.inventario_movimiento x
     WHERE x.bodega_id = p_bodega_id AND x.producto_id = p_producto_id AND x.cantidad < 0;
    IF v_ultima > p_fecha AND NOT public.tiene_permiso('inventario.fecha_atrasada', p_empresa_id) THEN
      RAISE EXCEPTION 'ENTRADA_FECHA_ATRASADA: el producto % ya tiene una salida con fecha % en esta bodega; una entrada con fecha % cambiaría costos ya usados. Use la fecha % o posterior (o pida al dueño el permiso inventario.fecha_atrasada).',
        v_codigo, to_char(v_ultima, 'DD/MM/YYYY'), to_char(p_fecha, 'DD/MM/YYYY'), to_char(v_ultima, 'DD/MM/YYYY');
    END IF;
    v_mov := p_valor;
  ELSE
    IF v_q < 0 AND NOT p_negativo THEN
      RAISE EXCEPTION 'EXISTENCIA_INSUFICIENTE: el producto % solo tiene % en la bodega y se quieren sacar %.',
        v_codigo, s.cantidad, -p_cantidad;
    END IF;
    v_sale := coalesce(p_valor, round(-p_cantidad * s.costo_promedio)::bigint);
    IF v_q = 0 THEN
      v_sale := greatest(s.valor_centavos, 0);
    ELSIF v_q > 0 THEN
      v_sale := least(v_sale, greatest(s.valor_centavos, 0));
    END IF;
    v_mov := -v_sale;
  END IF;

  v_v := s.valor_centavos + v_mov;
  IF v_q > 0 THEN
    v_prom := round(v_v::numeric / v_q, 6);
  ELSIF p_cantidad > 0 THEN
    v_prom := round(p_valor::numeric / p_cantidad, 6);
  ELSE
    v_prom := s.costo_promedio;
  END IF;

  INSERT INTO public.inventario_movimiento (empresa_id, bodega_id, producto_id, tipo, origen, fecha_contable,
    cantidad, valor_centavos, costo_unitario, saldo_cantidad, saldo_valor_centavos, saldo_costo_promedio,
    documento_tipo, documento_id, id_operacion, nota, creado_por)
  VALUES (p_empresa_id, p_bodega_id, p_producto_id, p_tipo, p_origen, p_fecha,
    p_cantidad, v_mov, round(abs(v_mov)::numeric / abs(p_cantidad), 6), v_q, v_v, v_prom,
    p_documento_tipo, p_documento_id, p_id_operacion, p_nota, auth.uid())
  RETURNING * INTO m;

  IF v_q < 0 AND p_cantidad < 0 THEN
    INSERT INTO public.inventario_alerta (empresa_id, tipo, bodega_id, producto_id, movimiento_id,
                                          cantidad_resultante, creado_por)
    VALUES (p_empresa_id, 'existencia_negativa', p_bodega_id, p_producto_id, m.id, v_q, auth.uid());
  END IF;

  IF v_q = 0 AND v_v <> 0 THEN
    INSERT INTO public.inventario_movimiento (empresa_id, bodega_id, producto_id, tipo, origen, fecha_contable,
      cantidad, valor_centavos, costo_unitario, saldo_cantidad, saldo_valor_centavos, saldo_costo_promedio,
      documento_tipo, documento_id, id_operacion, nota, creado_por)
    VALUES (p_empresa_id, p_bodega_id, p_producto_id, 'ajuste_costo', 'ajuste_costo', p_fecha,
      0, -v_v, 0, 0, 0, v_prom, p_documento_tipo, p_documento_id, p_id_operacion,
      'Existencia en 0: el valor que quedaba (' || v_v || ' centavos) pasa a ajuste de costo', auth.uid())
    RETURNING * INTO a;

    SELECT s2.id INTO v_suc FROM public.bodega b JOIN public.sucursal s2 ON s2.id = b.sucursal_id
     WHERE b.id = p_bodega_id AND s2.activa;
    PERFORM interno.asiento_sistema(p_empresa_id, v_suc, p_fecha,
      'Ajuste de costo de inventario: ' || v_codigo || ' quedó en 0 unidades con ' || v_v || ' centavos',
      'ajuste_costo_inventario', md5('ajuste_costo:' || a.id)::uuid,
      jsonb_build_array(
        jsonb_build_object('uso', 'perdida_inventario', 'debe',  greatest(v_v, 0),  'descripcion', 'Ajuste de costo'),
        jsonb_build_object('uso', 'inventario',         'haber', greatest(v_v, 0),  'descripcion', 'Ajuste de costo'),
        jsonb_build_object('uso', 'inventario',         'debe',  greatest(-v_v, 0), 'descripcion', 'Ajuste de costo'),
        jsonb_build_object('uso', 'perdida_inventario', 'haber', greatest(-v_v, 0), 'descripcion', 'Ajuste de costo')));
    v_v := 0;
  END IF;

  UPDATE public.inventario_saldo
     SET cantidad = v_q, valor_centavos = v_v, costo_promedio = v_prom,
         ultimo_movimiento_id = coalesce(a.id, m.id), actualizado_en = now()
   WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id;
  RETURN m;
END $$;

-- F) Quitar "permite_fracciones": bloquea los saldos del producto (espera a
-- los movimientos en curso) y luego revisa con una foto nueva.
CREATE OR REPLACE FUNCTION interno.fracciones_con_existencia() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_q numeric;
BEGIN
  IF OLD.permite_fracciones AND NOT NEW.permite_fracciones THEN
    PERFORM 1 FROM public.inventario_saldo s WHERE s.producto_id = NEW.id FOR SHARE;
    SELECT s.cantidad INTO v_q FROM public.inventario_saldo s
     WHERE s.producto_id = NEW.id AND s.cantidad <> trunc(s.cantidad) LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el producto % tiene existencias con decimales (por ejemplo %); ajústelas a números enteros antes de quitar "se vende con decimales".',
        NEW.codigo, v_q;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Permisos de ejecución
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.reservar_operacion(uuid, uuid, text),
  interno.cargar_saldo_inicial_base(uuid, uuid, date, jsonb, uuid, text),
  interno.anular_documento_inventario_base(uuid, text, uuid, date),
  interno.registrar_saldo_inicial_cxp_base(uuid, jsonb, uuid),
  interno.anular_saldo_inicial_cxp_base(uuid, text, uuid, date),
  interno.pagar_proveedor_base(uuid, uuid, bigint, date, text, uuid, text, text),
  interno.anular_pago_proveedor_base(uuid, text, uuid, date),
  interno.anular_compra_base(uuid, text, uuid, date),
  interno.crear_producto_base(uuid, jsonb, uuid)
FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  public.cargar_saldo_inicial(uuid, uuid, date, jsonb, uuid, text),
  public.anular_documento_inventario(uuid, text, uuid, date),
  public.registrar_saldo_inicial_cxp(uuid, jsonb, uuid),
  public.anular_saldo_inicial_cxp(uuid, text, uuid, date),
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text),
  public.anular_pago_proveedor(uuid, text, uuid, date),
  public.anular_compra(uuid, text, uuid, date),
  public.crear_producto(uuid, jsonb, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.cargar_saldo_inicial(uuid, uuid, date, jsonb, uuid, text),
  public.anular_documento_inventario(uuid, text, uuid, date),
  public.registrar_saldo_inicial_cxp(uuid, jsonb, uuid),
  public.anular_saldo_inicial_cxp(uuid, text, uuid, date),
  public.pagar_proveedor(uuid, uuid, bigint, date, text, uuid, text, text),
  public.anular_pago_proveedor(uuid, text, uuid, date),
  public.anular_compra(uuid, text, uuid, date),
  public.crear_producto(uuid, jsonb, uuid)
TO authenticated;
