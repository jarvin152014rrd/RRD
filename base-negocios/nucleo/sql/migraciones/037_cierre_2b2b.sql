-- =====================================================================
-- 037_cierre_2b2b.sql  -  Núcleo 0.9.0 (etapa 2b-2b): lo que une cobros,
-- saldo a favor, apartados, devoluciones y comisiones.
--
--   configurar_empresa: claves nuevas (solo el dueño) vale_dias_vigencia,
--     apartado_dias_vigencia, apartado_cancelacion, devolucion_tipos.
--   Activar un módulo con saldo en su cuenta que el módulo no explica:
--     ventas (Clientes y Saldos a favor), apartados (Anticipos de clientes),
--     comisiones (Comisiones por pagar) -> MODULO_CON_SALDO.
--   Módulo apagado: se puede anular cobros, condonaciones y saldos iniciales
--     de clientes (ventas) y confirmar transferencias de cobros (dinero).
--   Asistente: el paso "clientes" también se marca solo con un saldo inicial.
--   estado_cuenta_cliente: cargos, abonos y saldo corrido de un cliente.
-- =====================================================================

INSERT INTO interno.modulo_apagado_permite (modulo, funcion, motivo) VALUES
  ('ventas', 'public.anular_cobro',              'Corregir un cobro mal registrado (el dinero vuelve a salir de su cuenta).'),
  ('ventas', 'public.anular_condonacion',        'Corregir una condonación.'),
  ('ventas', 'public.anular_saldo_inicial_cxc',  'Corregir un saldo inicial de cliente.'),
  ('dinero', 'public.confirmar_transferencia_cobro', 'Pasar al banco una transferencia ya cobrada.');

-- ---------------------------------------------------------------------
-- 1) configurar_empresa (reemplaza la de 031; misma firma)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.configurar_empresa(p_empresa_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k     text;
  v_emp public.empresa;
  v_tip text[];
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
                 'cotizacion_dias_vigencia', 'cotizacion_precios', 'permite_servicios', 'vendedor_cobra',
                 'vale_dias_vigencia', 'apartado_dias_vigencia', 'apartado_cancelacion', 'devolucion_tipos') THEN
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
  IF p_datos ? 'vale_dias_vigencia' AND p_datos->'vale_dias_vigencia' <> 'null'::jsonb
     AND NOT (jsonb_typeof(p_datos->'vale_dias_vigencia') = 'number' AND (p_datos->>'vale_dias_vigencia') ~ '^[0-9]{1,4}$'
              AND (p_datos->>'vale_dias_vigencia')::integer BETWEEN 1 AND 3650) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "vale_dias_vigencia" es un número de días de 1 a 3650 (o null: los vales no vencen).';
  END IF;
  IF p_datos ? 'apartado_dias_vigencia' AND NOT (jsonb_typeof(p_datos->'apartado_dias_vigencia') = 'number'
       AND (p_datos->>'apartado_dias_vigencia') ~ '^[0-9]{1,3}$' AND (p_datos->>'apartado_dias_vigencia')::integer BETWEEN 1 AND 365) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "apartado_dias_vigencia" debe ser un número entero de 1 a 365.';
  END IF;
  IF p_datos ? 'apartado_cancelacion' AND coalesce(p_datos->>'apartado_cancelacion', '') NOT IN ('saldo_favor', 'devolver', 'elegir') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "apartado_cancelacion" es "saldo_favor", "devolver" o "elegir".';
  END IF;
  IF p_datos ? 'devolucion_tipos' THEN
    IF jsonb_typeof(p_datos->'devolucion_tipos') <> 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_datos->'devolucion_tipos') x
                   WHERE jsonb_typeof(x) <> 'string' OR x #>> '{}' NOT IN ('devolver_dinero', 'cambio_producto', 'nota_credito')) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "devolucion_tipos" es una lista con "devolver_dinero", "cambio_producto" y/o "nota_credito".';
    END IF;
    SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}') INTO v_tip FROM jsonb_array_elements_text(p_datos->'devolucion_tipos') x;
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
    vendedor_cobra = coalesce((p_datos->>'vendedor_cobra')::boolean, vendedor_cobra),
    vale_dias_vigencia = CASE WHEN p_datos ? 'vale_dias_vigencia' THEN (p_datos->>'vale_dias_vigencia')::integer ELSE vale_dias_vigencia END,
    apartado_dias_vigencia = coalesce((p_datos->>'apartado_dias_vigencia')::integer, apartado_dias_vigencia),
    apartado_cancelacion = coalesce(p_datos->>'apartado_cancelacion', apartado_cancelacion),
    devolucion_tipos = coalesce(v_tip, devolucion_tipos)
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
                            'vendedor_cobra', v_emp.vendedor_cobra,
                            'vale_dias_vigencia', v_emp.vale_dias_vigencia,
                            'apartado_dias_vigencia', v_emp.apartado_dias_vigencia,
                            'apartado_cancelacion', v_emp.apartado_cancelacion,
                            'devolucion_tipos', to_jsonb(v_emp.devolucion_tipos));
END $$;

-- ---------------------------------------------------------------------
-- 2) Activar un módulo con saldo que no explica (reemplaza la de 028)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.revisar_activacion_modulo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_libros bigint;
  v_modulo bigint;
  v_cta    text;
BEGIN
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
  ELSIF NEW.modulo = 'dinero' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'diferencia_caja');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := coalesce((SELECT -sum(t.diferencia_centavos) FROM public.turno_caja t
                           WHERE t.empresa_id = NEW.empresa_id AND t.diferencia_estado = 'pendiente'), 0);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (diferencias de caja) tiene % en los libros y los turnos pendientes suman %. Pase la diferencia con un asiento a la cuenta que corresponda y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  ELSIF NEW.modulo = 'ventas' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'cxc');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_cxc(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (clientes) tiene % en los libros y las facturas por cobrar del sistema suman %. Para activar el módulo: 1) registre un asiento que pase la diferencia a % Saldos de apertura (Dr %, Cr %); 2) active el módulo; 3) cargue cada factura pendiente con registrar_saldo_inicial_cxc.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo),
        interno.cuenta_de(NEW.empresa_id, 'apertura_cxc'), interno.cuenta_de(NEW.empresa_id, 'apertura_cxc'), v_cta;
    END IF;
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'saldo_favor');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_saldo_favor(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (saldos a favor de clientes) tiene % en los libros y los saldos a favor del sistema suman %. Pase la diferencia con un asiento a la cuenta que corresponda y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  ELSIF NEW.modulo = 'apartados' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'anticipo_clientes');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := coalesce((SELECT sum(interno.anticipos_apartado(a.id)) FROM public.apartado a
                           WHERE a.empresa_id = NEW.empresa_id AND a.estado = 'vigente'), 0);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (anticipos de clientes) tiene % en los libros y los apartados vigentes suman %. Pase la diferencia con un asiento (por ejemplo a saldos a favor) y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  ELSIF NEW.modulo = 'comisiones' THEN
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'comisiones_por_pagar');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := interno.total_comisiones_por_pagar(NEW.empresa_id);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (comisiones por pagar) tiene % en los libros y las comisiones del sistema suman %. Pague o pase la diferencia con un asiento y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 3) Asistente de arranque (reemplaza la de 028; misma forma): el paso
--    "clientes" se marca solo con un cliente o un saldo inicial de cliente,
--    y su detalle dice cuántos saldos iniciales hay cargados.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.estado_arranque(p_empresa_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e          public.empresa;
  v_ctas     jsonb;
  v_hay_ctas boolean;
  v_pasos    jsonb;
  v_hechos   integer;
  v_pend     integer;
  v_neg      integer;
  v_venta    boolean;
  v_si_n     integer;
  v_si_m     bigint;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'arranque.gestionar');
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la empresa no existe.';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', d.id, 'nombre', d.nombre, 'tipo', d.tipo)
                            ORDER BY d.nombre), '[]')
    INTO v_ctas
    FROM public.cuenta_dinero d
   WHERE d.empresa_id = p_empresa_id AND d.activa AND d.tipo <> 'transito' AND d.inicia_en_cero_en IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.operacion_dinero o
                      WHERE o.destino_id = d.id AND o.tipo = 'saldo_inicial' AND o.anulada_en IS NULL);
  v_hay_ctas := EXISTS (SELECT 1 FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id AND d.activa AND d.tipo <> 'transito');
  SELECT count(*) INTO v_neg FROM public.cuenta_dinero d
   WHERE d.empresa_id = p_empresa_id AND interno.saldo_dinero(d.id) < 0;
  v_venta := EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.numero_documento IS NOT NULL);
  SELECT count(*), coalesce(sum(s.monto_centavos), 0) INTO v_si_n, v_si_m
    FROM public.cxc_saldo_inicial s WHERE s.empresa_id = p_empresa_id AND s.anulada_en IS NULL;

  WITH p (orden, paso, titulo, hecho, detalle) AS (VALUES
    (1, 'datos_negocio', 'Datos del negocio (nombre, RTN, rubro)', e.rtn IS NOT NULL,
        CASE WHEN e.rtn IS NULL THEN 'Falta el RTN del negocio.' END),
    (2, 'usuarios', 'Usuarios del equipo',
        EXISTS (SELECT 1 FROM public.usuario_empresa u WHERE u.empresa_id = p_empresa_id AND u.activo
                  AND u.rol NOT IN ('dueno', 'proveedor')), NULL),
    (3, 'cuentas_dinero', 'Cajas y bancos con su saldo inicial (o empezar en cero)',
        v_hay_ctas AND jsonb_array_length(v_ctas) = 0,
        CASE WHEN NOT v_hay_ctas THEN 'Todavía no hay cajas ni bancos registrados.'
             WHEN jsonb_array_length(v_ctas) > 0 THEN jsonb_array_length(v_ctas) || ' cuenta(s) sin saldo inicial ni "empezar en cero".' END),
    (4, 'productos', 'Productos',
        EXISTS (SELECT 1 FROM public.producto x WHERE x.empresa_id = p_empresa_id), NULL),
    (5, 'clientes', 'Clientes (con sus saldos)',
        v_si_n > 0 OR EXISTS (SELECT 1 FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.es_cliente),
        CASE WHEN v_si_n > 0 THEN v_si_n || ' saldo(s) inicial(es) de clientes cargado(s) por ' || interno.lempiras(v_si_m) || '.'
             ELSE 'Si sus clientes le deben facturas de antes, cárguelas como saldos iniciales.' END),
    (6, 'proveedores', 'Proveedores (con sus saldos)',
        EXISTS (SELECT 1 FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.es_proveedor), NULL),
    (7, 'primera_venta', 'Primera venta', v_venta,
        CASE WHEN NOT v_venta THEN 'Registre su primera venta (se marca sola al emitirla).' END))
  SELECT jsonb_agg(jsonb_build_object('orden', p.orden, 'paso', p.paso, 'titulo', p.titulo,
           'estado', CASE WHEN p.hecho THEN 'hecho' WHEN a.estado = 'saltado' THEN 'saltado' ELSE 'pendiente' END,
           'detalle', p.detalle, 'marcado_en', public.iso(a.marcado_en)) ORDER BY p.orden),
         count(*) FILTER (WHERE p.hecho),
         count(*) FILTER (WHERE NOT p.hecho AND a.estado IS DISTINCT FROM 'saltado')
    INTO v_pasos, v_hechos, v_pend
    FROM p LEFT JOIN public.arranque_paso a ON a.empresa_id = p_empresa_id AND a.paso = p.paso;

  RETURN jsonb_build_object('empresa_id', e.id, 'perfil', e.perfil, 'pasos', v_pasos,
    'hechos', v_hechos, 'saltados', 7 - v_hechos - v_pend, 'pendientes', v_pend,
    'porcentaje', round(v_hechos * 100.0 / 7)::integer, 'terminado', v_pend = 0,
    'cuentas_sin_saldo_inicial', v_ctas, 'cuentas_en_negativo', v_neg);
END $$;

-- ---------------------------------------------------------------------
-- 4) Estado de cuenta de un cliente
-- ---------------------------------------------------------------------
-- estado_cuenta_cliente(empresa, cliente, desde?, hasta?)   ventas.ver
-- Cargos (ventas al crédito, saldos iniciales, anulaciones de cobros) y abonos
-- (cobros, condonaciones, notas de crédito, anulaciones de ventas) con saldo
-- corrido; saldo anterior a "desde"; facturas pendientes y saldo a favor.
CREATE FUNCTION public.estado_cuenta_cliente(p_empresa_id uuid, p_cliente_id uuid, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t       public.tercero;
  v_desde date;
  v_hasta date := coalesce(p_hasta, public.hoy_local(p_empresa_id));
  v_ini   bigint;
  v_movs  jsonb;
  v_fin   bigint;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'ventas.ver');
  SELECT * INTO t FROM public.tercero x WHERE x.id = p_cliente_id AND x.empresa_id = p_empresa_id AND x.es_cliente;
  IF t.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cliente no existe en esta empresa.';
  END IF;
  v_desde := coalesce(p_desde, (SELECT e.fecha_inicio FROM public.empresa e WHERE e.id = p_empresa_id), '2000-01-01');
  IF v_hasta < v_desde THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "hasta" no puede ser antes de "desde".';
  END IF;
  WITH ec (fecha, orden, tipo, documento, referencia, cargo, abono) AS (
  -- Ventas al crédito (y su anulación)
  SELECT v.fecha_contable, 1, 'venta_credito', v.numero_documento, NULL, v.credito_centavos, 0
    FROM public.venta v WHERE v.empresa_id = p_empresa_id AND v.cliente_id = t.id AND v.credito_centavos > 0 AND v.estado IN ('emitida', 'anulada')
  UNION ALL
  SELECT v.fecha_anulacion, 2, 'anulacion_venta', v.numero_documento, v.motivo_anulacion, 0, v.credito_centavos
    FROM public.venta v WHERE v.empresa_id = p_empresa_id AND v.cliente_id = t.id AND v.credito_centavos > 0 AND v.estado = 'anulada'
  UNION ALL
  -- Saldos iniciales (y su anulación)
  SELECT s.fecha_documento, 0, 'saldo_inicial', s.numero_documento, s.notas, s.monto_centavos, 0
    FROM public.cxc_saldo_inicial s WHERE s.empresa_id = p_empresa_id AND s.cliente_id = t.id
  UNION ALL
  SELECT s.fecha_anulacion, 2, 'anulacion_saldo_inicial', s.numero_documento, s.motivo_anulacion, 0, s.monto_centavos
    FROM public.cxc_saldo_inicial s WHERE s.empresa_id = p_empresa_id AND s.cliente_id = t.id AND s.anulada_en IS NOT NULL
  UNION ALL
  -- Cobros, condonaciones y notas de crédito aplicadas a facturas (y sus anulaciones)
  SELECT a.fecha_contable, 3, a.origen, coalesce(v.numero_documento, s.numero_documento),
         CASE a.origen WHEN 'cobro' THEN 'Cobro #' || c.numero WHEN 'condonacion' THEN 'Condonación #' || x.numero
                       ELSE 'Nota de crédito ' || d.numero_documento END, 0, a.monto_centavos
    FROM public.cxc_aplicacion a
    LEFT JOIN public.venta v ON v.id = a.venta_id
    LEFT JOIN public.cxc_saldo_inicial s ON s.id = a.saldo_inicial_id
    LEFT JOIN public.cobro c ON a.origen = 'cobro' AND c.id = a.origen_id
    LEFT JOIN public.cxc_condonacion x ON a.origen = 'condonacion' AND x.id = a.origen_id
    LEFT JOIN public.devolucion d ON a.origen = 'devolucion' AND d.id = a.origen_id
   WHERE a.empresa_id = p_empresa_id AND a.cliente_id = t.id
  UNION ALL
  SELECT coalesce(c.fecha_anulacion, x.fecha_anulacion), 4, 'anulacion_' || a.origen, coalesce(v.numero_documento, s.numero_documento),
         coalesce(c.motivo_anulacion, x.motivo_anulacion), a.monto_centavos, 0
    FROM public.cxc_aplicacion a
    LEFT JOIN public.venta v ON v.id = a.venta_id
    LEFT JOIN public.cxc_saldo_inicial s ON s.id = a.saldo_inicial_id
    LEFT JOIN public.cobro c ON a.origen = 'cobro' AND c.id = a.origen_id
    LEFT JOIN public.cxc_condonacion x ON a.origen = 'condonacion' AND x.id = a.origen_id
   WHERE a.empresa_id = p_empresa_id AND a.cliente_id = t.id AND a.anulada_en IS NOT NULL)
  SELECT (SELECT coalesce(sum(cargo - abono), 0) FROM ec WHERE fecha < v_desde),
         (SELECT coalesce(jsonb_agg(jsonb_build_object('fecha', to_char(z.fecha, 'YYYY-MM-DD'), 'tipo', z.tipo, 'documento', z.documento,
                    'referencia', z.referencia, 'cargo_centavos', z.cargo, 'abono_centavos', z.abono, 'saldo_centavos', z.saldo) ORDER BY z.n), '[]')
            FROM (SELECT y.*, (SELECT coalesce(sum(cargo - abono), 0) FROM ec WHERE fecha < v_desde)
                              + sum(y.cargo - y.abono) OVER (ORDER BY y.fecha, y.orden, y.documento ROWS UNBOUNDED PRECEDING) AS saldo,
                         row_number() OVER (ORDER BY y.fecha, y.orden, y.documento) AS n
                    FROM ec y WHERE y.fecha BETWEEN v_desde AND v_hasta) z),
         (SELECT coalesce(sum(cargo - abono), 0) FROM ec WHERE fecha <= v_hasta)
    INTO v_ini, v_movs, v_fin;
  RETURN jsonb_build_object('cliente_id', t.id, 'cliente', t.nombre, 'rtn', t.rtn, 'limite_credito_centavos', t.limite_credito_centavos,
    'desde', to_char(v_desde, 'YYYY-MM-DD'), 'hasta', to_char(v_hasta, 'YYYY-MM-DD'),
    'saldo_anterior_centavos', v_ini, 'movimientos', v_movs, 'saldo_final_centavos', v_fin,
    'saldo_actual_centavos', interno.saldo_cxc_cliente(p_empresa_id, t.id),
    'saldo_favor_centavos', interno.saldo_favor_cliente(p_empresa_id, t.id),
    'pendientes', (SELECT coalesce(jsonb_agg(jsonb_build_object('documento', d.numero_documento, 'origen', d.origen,
                     'fecha', to_char(d.fecha_documento, 'YYYY-MM-DD'), 'vence_el', to_char(d.vence_el, 'YYYY-MM-DD'),
                     'saldo_centavos', d.saldo_centavos, 'dias_vencido', d.dias_vencido) ORDER BY d.fecha_documento), '[]')
                     FROM public.v_cxc_documento d WHERE d.empresa_id = p_empresa_id AND d.cliente_id = t.id AND d.saldo_centavos > 0));
END $$;

REVOKE EXECUTE ON FUNCTION public.estado_cuenta_cliente(uuid, uuid, date, date) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.estado_cuenta_cliente(uuid, uuid, date, date) TO authenticated, service_role;
