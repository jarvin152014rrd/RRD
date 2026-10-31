-- =====================================================================
-- 035_devoluciones.sql  -  Núcleo 0.9.0 (etapa 2b-2b): devoluciones,
-- notas de crédito y cambio de producto (dentro del módulo "ventas").
--
--   registrar_devolucion(venta, datos, id_operacion)   ventas.devolver
--     Parcial o total, por línea: cantidad <= vendida - ya devuelta (las
--     pendientes de aprobación también cuentan). Montos por línea en
--     proporción (la última devolución de la línea toma lo que falte, sin
--     perder centavos).
--     Cada devolución es una NOTA DE CRÉDITO: con CAI propio (tipo
--     nota_credito) si la venta fue factura y fiscal_hn está activo; si no,
--     numeración interna NC-001-001-00000001.
--     Regresa el inventario al COSTO DE LA VENTA ORIGINAL (los servicios no
--     tocan inventario); revierte ingreso (4.1.01.04 Devoluciones sobre
--     ventas) e impuesto (cada impuesto a su cuenta).
--     A dónde va el valor (NUNCA dos veces):
--       1) si la venta tiene saldo por cobrar, primero REBAJA la CxC (sin
--          devolver dinero por esa parte);
--       2) lo que quede (lo que el cliente ya pagó) va al destino elegido:
--          "dinero" (de la cuenta elegida), "saldo_favor" (nota de crédito al
--          cliente; sin cliente = VALE con código) o "cambio" (otra venta).
--     El dueño elige en Ajustes qué permite: empresa.devolucion_tipos
--     (devolver_dinero, cambio_producto, nota_credito). La rebaja de CxC
--     siempre se permite (corrige lo que se debe).
--     Cambio de producto = devolución + venta nueva ENLAZADAS: se cobra o se
--     devuelve la diferencia.
--     Tope por puesto (tope_rol tipo "devolucion"): sobre el tope queda
--     pendiente de aprobación SIN mover nada; se resuelve con resolver_aprobacion.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('DEVOLUCION_INVALIDA', 'No se puede devolver eso.',
   'Revise la venta, las líneas y las cantidades: no se devuelve más de lo vendido menos lo ya devuelto.'),
  ('DEVOLUCION_NO_PERMITIDA', 'El dueño no permite ese tipo de devolución.',
   'Use otro destino (dinero, nota de crédito o cambio de producto) según lo que el dueño activó en Ajustes.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('ventas.devolver', 'Registrar devoluciones de clientes (notas de crédito, cambio de producto)', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'ventas.devolver'), ('admin', 'ventas.devolver'), ('cajero', 'ventas.devolver');
SELECT interno.repartir_permisos(ARRAY['ventas.devolver'], 'Núcleo 0.9.0: devoluciones');

INSERT INTO interno.plantilla_cuenta (codigo, nombre, tipo, naturaleza, es_detalle) VALUES
  ('4.1.01.04', 'Devoluciones sobre ventas', 'ingreso', 'deudora', true);
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('devolucion_ventas', '4.1.01.04', 'Devoluciones sobre ventas (notas de crédito, sin impuesto)', NULL);
DO $$
DECLARE e record;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.9.0: cuenta de devoluciones sobre ventas', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    PERFORM interno.asegurar_cuenta_uso(e.id, 'devolucion_ventas', 'Devoluciones sobre ventas');
  END LOOP;
  PERFORM set_config('app.motivo', '', true);
END $$;

-- Qué devoluciones permite el dueño (A CONFIRMAR CON EL DUEÑO: por defecto las tres).
ALTER TABLE public.empresa
  ADD COLUMN devolucion_tipos text[] NOT NULL DEFAULT ARRAY['devolver_dinero', 'cambio_producto', 'nota_credito']
    CHECK (devolucion_tipos <@ ARRAY['devolver_dinero', 'cambio_producto', 'nota_credito']);

-- Tope de devolución por puesto (en centavos). A CONFIRMAR: el admin registra
-- y aprueba hasta L 5,000.00; cajero siempre con aprobación; el dueño sin tope.
ALTER TABLE public.tope_rol DROP CONSTRAINT tope_rol_tipo_check,
  ADD CONSTRAINT tope_rol_tipo_check CHECK (tipo IN ('gasto', 'descuento', 'credito', 'anulacion_venta', 'devolucion'));
INSERT INTO interno.plantilla_tope_rol (rol, tipo, sin_aprobacion_centavos, aprueba_hasta_centavos) VALUES
  ('admin', 'devolucion', 500000, 500000);

-- configurar_tope_rol (reemplaza la de 028; misma firma): acepta "devolucion".
CREATE OR REPLACE FUNCTION public.configurar_tope_rol(p_empresa_id uuid, p_rol text, p_tipo text, p_sin_aprobacion_centavos bigint,
                                                      p_aprueba_hasta_centavos bigint, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rol r WHERE r.codigo = p_rol) OR p_rol IN ('dueno', 'proveedor') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el puesto "%" no existe o no lleva topes (el dueño no tiene tope).', p_rol;
  END IF;
  IF coalesce(p_tipo, '') = 'descuento' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tope de descuento va en porcentaje; use configurar_tope_descuento.';
  END IF;
  IF coalesce(p_tipo, '') NOT IN ('gasto', 'credito', 'anulacion_venta', 'devolucion') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de tope es "gasto", "credito", "anulacion_venta" o "devolucion".';
  END IF;
  IF p_sin_aprobacion_centavos IS NULL OR p_sin_aprobacion_centavos NOT BETWEEN 0 AND 9007199254740991
     OR p_aprueba_hasta_centavos IS NULL OR p_aprueba_hasta_centavos NOT BETWEEN 0 AND 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los topes son enteros de centavos, 0 o más.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.tope_rol (empresa_id, rol, tipo, sin_aprobacion_centavos, aprueba_hasta_centavos, actualizado_por)
  VALUES (p_empresa_id, p_rol, p_tipo, p_sin_aprobacion_centavos, p_aprueba_hasta_centavos, auth.uid())
  ON CONFLICT (empresa_id, rol, tipo) DO UPDATE
     SET sin_aprobacion_centavos = excluded.sin_aprobacion_centavos, aprueba_hasta_centavos = excluded.aprueba_hasta_centavos,
         actualizado_por = excluded.actualizado_por, actualizado_en = now();
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('rol', p_rol, 'tipo', p_tipo, 'sin_aprobacion_centavos', p_sin_aprobacion_centavos,
                            'aprueba_hasta_centavos', p_aprueba_hasta_centavos);
END $$;

-- ---------------------------------------------------------------------
-- 1) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.devolucion (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  venta_id                 uuid NOT NULL,
  cliente_id               uuid,
  cliente_nombre           text NOT NULL,
  caja_id                  uuid NOT NULL REFERENCES public.caja(id),
  sucursal_id              uuid NOT NULL,
  fecha_contable           date NOT NULL,
  motivo                   text NOT NULL CHECK (length(trim(motivo)) >= 5),
  destino                  text CHECK (destino IN ('dinero', 'saldo_favor', 'cambio')),   -- de lo que no rebaja CxC
  cuenta_dinero_id         uuid,                  -- dinero (o la diferencia de un cambio)
  subtotal_centavos        bigint NOT NULL CHECK (subtotal_centavos >= 0),     -- sin impuesto
  impuesto_centavos        bigint NOT NULL CHECK (impuesto_centavos >= 0),
  total_centavos           bigint NOT NULL CHECK (total_centavos BETWEEN 1 AND 9007199254740991),
  desglose_impuestos       jsonb NOT NULL,
  costo_centavos           bigint NOT NULL CHECK (costo_centavos >= 0),        -- bienes, al costo de la venta
  costo_estimado_centavos  bigint NOT NULL DEFAULT 0,                          -- servicios (comisiones; no va a los libros)
  tipo_documento           text,                  -- nota_credito (régimen fiscal) | nota_credito_interna
  numero_documento         text,
  regimen_fiscal           text,
  datos_fiscales           jsonb,
  -- Reparto (al aplicar): rebaja de CxC + dinero + saldo a favor + cambio = total
  cxc_centavos             bigint NOT NULL DEFAULT 0 CHECK (cxc_centavos >= 0),
  dinero_centavos          bigint NOT NULL DEFAULT 0 CHECK (dinero_centavos >= 0),
  saldo_favor_centavos     bigint NOT NULL DEFAULT 0 CHECK (saldo_favor_centavos >= 0),
  cambio_centavos          bigint NOT NULL DEFAULT 0 CHECK (cambio_centavos >= 0),
  saldo_favor_id           uuid,
  venta_cambio_id          uuid,                  -- la venta nueva del cambio de producto
  cambio                   jsonb,                 -- lo pedido para la venta nueva
  estado                   text NOT NULL CHECK (estado IN ('por_aplicar', 'pendiente_aprobacion', 'aplicada', 'rechazada')),
  aprobacion_id            uuid,
  asiento_id               uuid,
  aplicada_en              timestamptz,
  aplicada_por             uuid,
  equipo                   text,
  id_operacion             uuid NOT NULL,
  creado_por               uuid,
  registrado_en            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, venta_id)         REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, cliente_id)       REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id)      REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id) REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, saldo_favor_id)   REFERENCES public.saldo_favor(empresa_id, id),
  FOREIGN KEY (empresa_id, venta_cambio_id)  REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, aprobacion_id)    REFERENCES public.aprobacion(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)       REFERENCES public.asiento(empresa_id, id),
  CHECK (total_centavos = subtotal_centavos + impuesto_centavos),
  CHECK (estado <> 'aplicada' OR (asiento_id IS NOT NULL AND numero_documento IS NOT NULL
         AND cxc_centavos + dinero_centavos + saldo_favor_centavos + cambio_centavos = total_centavos)),
  CHECK (estado = 'aplicada' OR (asiento_id IS NULL AND numero_documento IS NULL)),
  CHECK ((saldo_favor_centavos + cambio_centavos > 0) = (saldo_favor_id IS NOT NULL) OR estado <> 'aplicada'),
  CHECK (dinero_centavos = 0 OR cuenta_dinero_id IS NOT NULL)
);
CREATE UNIQUE INDEX devolucion_numero_documento ON public.devolucion (empresa_id, numero_documento) WHERE numero_documento IS NOT NULL;
CREATE INDEX devolucion_venta ON public.devolucion (venta_id);
CREATE INDEX devolucion_empresa_fecha ON public.devolucion (empresa_id, fecha_contable);

CREATE TABLE public.devolucion_linea (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id               uuid NOT NULL,
  devolucion_id            uuid NOT NULL,
  linea                    smallint NOT NULL CHECK (linea > 0),
  venta_linea_id           bigint NOT NULL REFERENCES public.venta_linea(id),
  producto_id              uuid NOT NULL,
  descripcion              text NOT NULL,
  es_servicio              boolean NOT NULL,
  cantidad                 numeric(18,4) NOT NULL CHECK (cantidad > 0),
  tipo_impuesto            text NOT NULL,
  impuesto_porcentaje      numeric(6,3) NOT NULL,
  base_centavos            bigint NOT NULL CHECK (base_centavos >= 0),
  impuesto_centavos        bigint NOT NULL CHECK (impuesto_centavos >= 0),
  total_centavos           bigint NOT NULL,
  costo_centavos           bigint NOT NULL CHECK (costo_centavos >= 0),
  costo_estimado_centavos  bigint NOT NULL DEFAULT 0,
  movimiento_id            bigint REFERENCES public.inventario_movimiento(id),
  UNIQUE (devolucion_id, linea),
  FOREIGN KEY (empresa_id, devolucion_id) REFERENCES public.devolucion(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id)   REFERENCES public.producto(empresa_id, id),
  CHECK (total_centavos = base_centavos + impuesto_centavos)
);
CREATE INDEX devolucion_linea_venta_linea ON public.devolucion_linea (venta_linea_id);

-- La devolución se aplica (o se rechaza) una vez; la línea solo recibe su movimiento del kardex.
CREATE FUNCTION interno.proteger_devolucion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_apl constant text[] := ARRAY['estado', 'fecha_contable', 'tipo_documento', 'numero_documento', 'regimen_fiscal', 'datos_fiscales',
                                 'cxc_centavos', 'dinero_centavos', 'saldo_favor_centavos', 'cambio_centavos', 'saldo_favor_id',
                                 'venta_cambio_id', 'asiento_id', 'aplicada_en', 'aplicada_por', 'caja_id', 'sucursal_id'];
BEGIN
  IF OLD.estado IN ('por_aplicar', 'pendiente_aprobacion') AND NEW.estado = 'aplicada'
     AND (to_jsonb(NEW) - c_apl) = (to_jsonb(OLD) - c_apl) THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'aplicada' AND NEW.estado = 'aplicada' AND OLD.venta_cambio_id IS NULL AND NEW.venta_cambio_id IS NOT NULL
     AND (to_jsonb(NEW) - 'venta_cambio_id') = (to_jsonb(OLD) - 'venta_cambio_id') THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'pendiente_aprobacion' AND NEW.estado = 'rechazada' AND (to_jsonb(NEW) - 'estado') = (to_jsonb(OLD) - 'estado') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una devolución (nota de crédito) no se edita; se aplica o se rechaza una sola vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.devolucion FOR EACH ROW EXECUTE FUNCTION interno.proteger_devolucion();

CREATE FUNCTION interno.proteger_devolucion_linea() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.movimiento_id IS NULL AND NEW.movimiento_id IS NOT NULL
     AND (to_jsonb(NEW) - 'movimiento_id') = (to_jsonb(OLD) - 'movimiento_id') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: las líneas de una devolución no se editan.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.devolucion_linea FOR EACH ROW EXECUTE FUNCTION interno.proteger_devolucion_linea();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['devolucion', 'devolucion_linea'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'Las devoluciones no se borran.');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
-- Guardan costos: la tabla la leen quienes ven ventas y costos; los demás, por v_devolucion.
CREATE POLICY leer ON public.devolucion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         AND empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))));
CREATE POLICY leer ON public.devolucion_linea FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         AND empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))));

-- ---------------------------------------------------------------------
-- 2) Ayudantes
-- ---------------------------------------------------------------------
-- Gancho de 034: lo devuelto (aplicado o pendiente) de una venta.
CREATE OR REPLACE FUNCTION interno.devoluciones_vigentes_venta(p_venta_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(d.total_centavos), 0)::bigint FROM public.devolucion d
   WHERE d.venta_id = p_venta_id AND d.estado IN ('aplicada', 'pendiente_aprobacion', 'por_aplicar')
$$;

CREATE FUNCTION interno.devolucion_respuesta(d public.devolucion, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('devolucion_id', d.id, 'numero', d.numero, 'estado', d.estado, 'venta_id', d.venta_id,
    'tipo_documento', d.tipo_documento, 'numero_documento', d.numero_documento, 'fecha', to_char(d.fecha_contable, 'YYYY-MM-DD'),
    'subtotal_centavos', d.subtotal_centavos, 'impuesto_centavos', d.impuesto_centavos, 'total_centavos', d.total_centavos,
    'costo_centavos', d.costo_centavos, 'cxc_centavos', d.cxc_centavos, 'dinero_centavos', d.dinero_centavos,
    'saldo_favor_centavos', d.saldo_favor_centavos, 'cambio_centavos', d.cambio_centavos,
    'saldo_favor', (SELECT jsonb_build_object('saldo_favor_id', s.id, 'codigo', s.codigo, 'vence_el', to_char(s.vence_el, 'YYYY-MM-DD'))
                      FROM public.saldo_favor s WHERE s.id = d.saldo_favor_id),
    'venta_cambio_id', d.venta_cambio_id, 'aprobacion_id', d.aprobacion_id, 'asiento_id', d.asiento_id, 'duplicado', p_duplicado)
$$;

-- APLICAR una devolución ya guardada (por aplicar o recién aprobada): número
-- de la nota de crédito, kardex, reparto (CxC primero), asiento, rastro y
-- comisiones. Quien llama tiene el candado. Devuelve la devolución aplicada.
CREATE FUNCTION interno.aplicar_devolucion(p_devolucion_id uuid, p_fecha date, p_id_operacion uuid) RETURNS public.devolucion
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d       public.devolucion;
  v       public.venta;
  l       public.devolucion_linea;
  m       public.inventario_movimiento;
  rf      record;
  v_num   text;
  v_tdoc  text;
  v_reg   text;
  v_fis   jsonb;
  v_cxc   bigint;
  v_resto bigint;
  v_din   bigint := 0;
  v_sf    bigint := 0;
  v_cam   bigint := 0;
  v_t2    bigint;
  f       public.saldo_favor;
  v_lin   jsonb := '[]';
  v_asto  uuid;
BEGIN
  SELECT * INTO d FROM public.devolucion WHERE id = p_devolucion_id FOR UPDATE;
  SELECT * INTO v FROM public.venta WHERE id = d.venta_id FOR UPDATE;
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: la venta % está % ; no se le aplica la devolución.', v.numero_documento, v.estado;
  END IF;
  PERFORM interno.exigir_periodo_abierto(d.empresa_id, p_fecha);

  -- Reparto: primero rebaja lo que la venta todavía debe; lo demás al destino.
  v_cxc := least(d.total_centavos, greatest(interno.saldo_documento_cxc(v.id), 0));
  v_resto := d.total_centavos - v_cxc;
  IF v_resto > 0 THEN
    IF d.destino IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la venta ya está pagada en parte: indique a dónde va % ("destino": dinero, saldo_favor o cambio).',
        interno.lempiras(v_resto);
    ELSIF d.destino = 'dinero' THEN
      v_din := v_resto;
    ELSIF d.destino = 'saldo_favor' THEN
      v_sf := v_resto;
    ELSE
      v_t2 := coalesce((d.cambio->>'total_nuevo')::bigint, 0);
      v_cam := least(v_resto, v_t2);
      v_din := v_resto - v_cam;          -- el cambio vale menos: se devuelve la diferencia
      IF v_din > 0 AND d.cuenta_dinero_id IS NULL THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el producto nuevo vale menos; indique de qué cuenta se devuelve la diferencia (%) ("cuenta_dinero_id").',
          interno.lempiras(v_din);
      END IF;
    END IF;
  END IF;
  IF v_din > 0 THEN
    PERFORM interno.cuenta_dinero_para_pagar(d.empresa_id, d.cuenta_dinero_id);
    IF NOT public.modulo_esta_activo(d.empresa_id, 'dinero') THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo; el valor devuelto solo puede quedar como saldo a favor.';
    END IF;
  END IF;

  -- Número: nota de crédito del régimen fiscal (si la venta fue factura) o interna.
  IF v.tipo_documento = 'factura' AND interno.regimen_fiscal(d.empresa_id) IS NOT NULL THEN
    SELECT * INTO rf FROM interno.numero_fiscal(d.empresa_id, d.caja_id, 'nota_credito', p_fecha);
    v_num := rf.o_numero;  v_fis := rf.o_datos || jsonb_build_object('factura_que_modifica', v.numero_documento);
    v_reg := v_fis->>'regimen';  v_tdoc := 'nota_credito';
  ELSE
    SELECT 'NC-' || s.codigo || '-' || c.punto_emision || '-'
           || lpad(interno.siguiente_numero(d.empresa_id, 'nota_credito:' || d.caja_id)::text, 8, '0')
      INTO v_num FROM public.caja c JOIN public.sucursal s ON s.id = c.sucursal_id WHERE c.id = d.caja_id;
    v_tdoc := 'nota_credito_interna';
  END IF;

  -- Inventario: vuelve al costo de la venta original (los servicios no).
  FOR l IN SELECT * FROM public.devolucion_linea x WHERE x.devolucion_id = d.id AND NOT x.es_servicio ORDER BY x.linea LOOP
    m := interno.mover_inventario(d.empresa_id, v.bodega_id, l.producto_id, 'entrada', 'devolucion_venta', p_fecha, l.cantidad,
                                  l.costo_centavos, 'devolucion', d.id, p_id_operacion, 'Devolución ' || v_num || ' de la venta ' || v.numero_documento, false);
    UPDATE public.devolucion_linea SET movimiento_id = m.id WHERE id = l.id;
  END LOOP;

  IF v_sf + v_cam > 0 THEN
    f := interno.crear_saldo_favor(d.empresa_id, v.cliente_id, 'devolucion', 'devolucion', d.id, v_sf + v_cam, p_fecha);
  END IF;
  v_lin := jsonb_build_array(
    jsonb_build_object('uso', 'devolucion_ventas', 'debe', d.subtotal_centavos, 'descripcion', 'Devolución ' || v_num),
    jsonb_build_object('uso', 'cxc', 'haber', v_cxc, 'descripcion', 'Rebaja de la factura ' || v.numero_documento),
    jsonb_build_object('uso', 'saldo_favor', 'haber', v_sf + v_cam,
                       'descripcion', CASE WHEN v_cam > 0 THEN 'Cambio de producto' ELSE 'Nota de crédito a favor del cliente' END),
    jsonb_build_object('uso', 'inventario', 'debe', d.costo_centavos, 'descripcion', 'Mercadería devuelta (costo de la venta)'),
    jsonb_build_object('uso', 'costo_ventas', 'haber', d.costo_centavos, 'descripcion', 'Reversión del costo'));
  IF v_din > 0 THEN
    v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.cuenta_dinero_id), 'haber', v_din,
                                         'descripcion', 'Devolución de dinero ' || v_num);
  END IF;
  v_lin := v_lin || coalesce((SELECT jsonb_agg(jsonb_build_object('cuenta', x->>'cuenta_por_pagar', 'debe', (x->>'impuesto_centavos')::bigint,
                                 'descripcion', 'Reversión impuesto ' || (x->>'nombre')))
                                FROM jsonb_array_elements(d.desglose_impuestos) x WHERE (x->>'impuesto_centavos')::bigint > 0), '[]');
  v_asto := interno.asiento_sistema(d.empresa_id, interno.sucursal_activa(d.sucursal_id), p_fecha,
    'Nota de crédito ' || v_num || ' (devolución de la venta ' || v.numero_documento || ' de ' || v.cliente_nombre || '): ' || d.motivo,
    'devolucion', p_id_operacion, v_lin);

  IF v_cxc > 0 THEN
    INSERT INTO public.cxc_aplicacion (empresa_id, cliente_id, venta_id, origen, origen_id, monto_centavos, fecha_contable, creado_por)
    VALUES (d.empresa_id, v.cliente_id, v.id, 'devolucion', d.id, v_cxc, p_fecha, auth.uid());
  END IF;
  UPDATE public.devolucion
     SET estado = 'aplicada', fecha_contable = p_fecha, tipo_documento = v_tdoc, numero_documento = v_num, regimen_fiscal = v_reg,
         datos_fiscales = v_fis, cxc_centavos = v_cxc, dinero_centavos = v_din, saldo_favor_centavos = v_sf, cambio_centavos = v_cam,
         saldo_favor_id = f.id, asiento_id = v_asto, aplicada_en = now(), aplicada_por = auth.uid()
   WHERE id = d.id
  RETURNING * INTO d;
  PERFORM interno.rastrear_dinero(v_asto, 'devolucion', 'devolucion', d.id, v_num, d.equipo);
  PERFORM interno.recalcular_comision(v.id, p_id_operacion, p_fecha);
  RETURN d;
END $$;

-- Venta nueva de un cambio de producto: paga con el saldo de la devolución
-- (lote) y lo que falte con las formas indicadas. Debe emitirse de una vez.
CREATE FUNCTION interno.venta_de_cambio(d public.devolucion, p_id_operacion uuid) RETURNS jsonb
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
  r := interno.registrar_venta_base(d.empresa_id,
         jsonb_strip_nulls(jsonb_build_object('cliente_id', v.cliente_id, 'lineas', d.cambio->'lineas',
           'descuento_factura', d.cambio->'descuento_factura', 'caja_id', to_jsonb(d.caja_id), 'bodega_id', d.cambio->'bodega_id',
           'tipo_documento', d.cambio->'tipo_documento', 'fecha', to_char(d.fecha_contable, 'YYYY-MM-DD'),
           'nota', 'Cambio de producto (nota de crédito ' || d.numero_documento || ')', 'equipo', d.equipo, 'pagos', v_pag)),
         md5(p_id_operacion::text || ':cambio')::uuid);
  IF r->>'estado' <> 'emitida' THEN
    RAISE EXCEPTION 'APROBACION_REQUERIDA: la venta del cambio necesita aprobación (%); haga el cambio dentro de su tope o que lo haga quien aprueba.',
      r->'requiere_aprobacion';
  END IF;
  UPDATE public.devolucion SET venta_cambio_id = (r->>'venta_id')::uuid WHERE id = d.id;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 3) RPC
-- ---------------------------------------------------------------------
-- registrar_devolucion(venta, datos, id_operacion)   ventas.devolver
-- datos = {"lineas":[{"linea":1,"cantidad":2}, ...]  (línea de la venta y cuánto se devuelve),
--          "motivo":"Producto dañado", "destino":"dinero"|"saldo_favor"|"cambio" (para lo ya pagado),
--          "cuenta_dinero_id":"..." (dinero, o la diferencia de un cambio), "caja_id":"...", "fecha":"...",
--          "cambio":{"lineas":[...],"pagos":[...diferencia...],"descuento_factura":{...},"tipo_documento":"..."},
--          "equipo":"..."}
CREATE FUNCTION public.registrar_devolucion(p_venta_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v        public.venta;
  e        public.empresa;
  d        public.devolucion;
  vl       public.venta_linea;
  p        public.producto;
  lj       jsonb;
  i        integer := 0;
  q        numeric;
  q0       numeric;
  b0 bigint; i0 bigint; c0 bigint; e0 bigint;
  v_lin    jsonb := '[]';
  v_base   bigint; v_imp bigint; v_cost bigint; v_cest bigint;
  t_base   bigint := 0; t_imp bigint := 0; t_cost bigint := 0; t_cest bigint := 0;
  v_hay_serv boolean := false;
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
  v_desg   jsonb;
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
  IF v_cta IS NOT NULL THEN
    IF v_dest NOT IN ('dinero', 'cambio') OR v_dest IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de dinero solo va al devolver dinero (o la diferencia de un cambio).';
    END IF;
    PERFORM interno.cuenta_dinero_para_pagar(v.empresa_id, v_cta);
  END IF;
  IF coalesce(v_dest = 'cambio', false) <> (coalesce(p_datos->'cambio', 'null'::jsonb) <> 'null'::jsonb) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un cambio de producto lleva "destino": "cambio" y los datos de la venta nueva en "cambio".';
  END IF;

  -- Líneas: cantidad <= vendida - ya devuelta (aplicada o pendiente).
  IF jsonb_typeof(p_datos->'lineas') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'lineas') = 0 THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: indique qué líneas devuelve ("lineas": [{"linea": 1, "cantidad": 2}]).';
  END IF;
  FOR lj IN SELECT * FROM jsonb_array_elements(p_datos->'lineas') LOOP
    i := i + 1;
    PERFORM interno.exigir_claves(lj, ARRAY['linea', 'cantidad']);
    IF jsonb_typeof(lj->'linea') <> 'number' THEN
      RAISE EXCEPTION 'DEVOLUCION_INVALIDA: en la línea % indique el número de línea de la venta ("linea").', i;
    END IF;
    SELECT * INTO vl FROM public.venta_linea x WHERE x.venta_id = v.id AND x.linea = (lj->>'linea')::integer;
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
        vl.linea, vl.descripcion, vl.cantidad, q0, q;
    END IF;
    IF q = vl.cantidad - q0 THEN      -- lo último de la línea: lo que falte (sin perder centavos)
      v_base := vl.base_centavos - b0;  v_imp := vl.impuesto_centavos - i0;
      v_cost := coalesce(vl.costo_centavos, 0) - c0;  v_cest := coalesce(vl.costo_estimado_centavos, 0) - e0;
    ELSE
      -- El total en proporción (lo que el cliente pagó por esas unidades) y la base en proporción; el impuesto es la diferencia.
      v_base := least(round(vl.base_centavos * q / vl.cantidad)::bigint, round(vl.total_centavos * q / vl.cantidad)::bigint);
      v_imp := round(vl.total_centavos * q / vl.cantidad)::bigint - v_base;
      v_cost := round(coalesce(vl.costo_centavos, 0) * q / vl.cantidad)::bigint;
      v_cest := round(coalesce(vl.costo_estimado_centavos, 0) * q / vl.cantidad)::bigint;
    END IF;
    v_hay_serv := v_hay_serv OR vl.es_servicio;
    v_lin := v_lin || jsonb_build_object('linea', i, 'venta_linea_id', vl.id, 'producto_id', vl.producto_id, 'descripcion', vl.descripcion,
      'es_servicio', vl.es_servicio, 'cantidad', q, 'tipo_impuesto', vl.tipo_impuesto, 'impuesto_porcentaje', vl.impuesto_porcentaje,
      'base', v_base, 'impuesto', v_imp, 'costo', v_cost, 'costo_estimado', v_cest);
    t_base := t_base + v_base;  t_imp := t_imp + v_imp;  t_cost := t_cost + v_cost;  t_cest := t_cest + v_cest;
  END LOOP;
  IF t_base + t_imp <= 0 THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: el valor devuelto debe ser mayor que cero.';
  END IF;
  -- Servicios: solo nota de crédito o dinero (no cambio de producto).
  IF v_hay_serv AND v_dest = 'cambio' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: un servicio se devuelve como nota de crédito o dinero, no como cambio de producto.';
  END IF;
  -- Desglose por impuesto (cada uno a su cuenta).
  SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', x.codigo, 'nombre', im.nombre, 'porcentaje', x.porcentaje,
           'base_centavos', x.base, 'impuesto_centavos', x.impuesto, 'cuenta_por_pagar', im.cuenta_por_pagar) ORDER BY im.orden, x.codigo), '[]')
    INTO v_desg
    FROM (SELECT y->>'tipo_impuesto' AS codigo, (y->>'impuesto_porcentaje')::numeric AS porcentaje,
                 sum((y->>'base')::bigint) AS base, sum((y->>'impuesto')::bigint) AS impuesto
            FROM jsonb_array_elements(v_lin) y GROUP BY 1, 2) x
    JOIN public.impuesto im ON im.empresa_id = v.empresa_id AND im.codigo = x.codigo;

  -- Cambio de producto: se calcula la venta nueva (para saber la diferencia).
  IF v_dest = 'cambio' THEN
    v_cam := p_datos->'cambio';
    PERFORM interno.exigir_claves(v_cam, ARRAY['lineas', 'pagos', 'descuento_factura', 'tipo_documento', 'bodega_id']);
    v_calc := interno.calcular_venta(v.empresa_id, v_fecha, v_cam->'lineas', v_cam->'descuento_factura');
    v_cam := v_cam || jsonb_build_object('total_nuevo', (v_calc->>'total_centavos')::bigint);
  END IF;

  -- ¿Necesita aprobación? (tope del puesto; el dueño no tiene tope)
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_tope FROM interno.tope_rol(v.empresa_id, v_rol, 'devolucion');
    v_req := (t_base + t_imp) > v_tope.sin_aprobacion;
  END IF;
  IF v_req AND v_dest = 'cambio' THEN
    RAISE EXCEPTION 'APROBACION_REQUERIDA: la devolución (%) pasa su tope (%); un cambio de producto no queda pendiente. Que lo haga quien aprueba, o registre la devolución como nota de crédito (pendiente de aprobación) y venda después con ese saldo.',
      interno.lempiras(t_base + t_imp), interno.lempiras(v_tope.sin_aprobacion);
  END IF;

  PERFORM interno.reservar_operacion(v.empresa_id, p_id_operacion, 'devolucion');
  SELECT * INTO d FROM public.devolucion x WHERE x.empresa_id = v.empresa_id AND x.id_operacion = p_id_operacion;
  IF d.id IS NOT NULL THEN
    RETURN interno.ocultar_costos(v.empresa_id, interno.devolucion_respuesta(d, true), ARRAY['costo_centavos']);
  END IF;
  -- Otra vez con el candado: la venta sigue emitida y las cantidades alcanzan.
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: la venta ya está %.', v.estado;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lin) y JOIN public.venta_linea vl2 ON vl2.id = (y->>'venta_linea_id')::bigint
              WHERE (y->>'cantidad')::numeric > vl2.cantidad - coalesce((SELECT sum(x.cantidad) FROM public.devolucion_linea x
                       JOIN public.devolucion z ON z.id = x.devolucion_id
                      WHERE x.venta_linea_id = vl2.id AND z.estado IN ('aplicada', 'pendiente_aprobacion', 'por_aplicar')), 0)) THEN
    RAISE EXCEPTION 'DEVOLUCION_INVALIDA: otra devolución de esta venta se registró mientras tanto; revise las cantidades.';
  END IF;

  d.id := gen_random_uuid();
  d.numero := interno.siguiente_numero(v.empresa_id, 'devolucion');
  IF v_req THEN
    v_apr := gen_random_uuid();
    INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                   solicitado_por, rol_solicitante)
    VALUES (v_apr, v.empresa_id, interno.siguiente_numero(v.empresa_id, 'aprobacion'), 'devolucion', 'devolucion', d.id, t_base + t_imp,
            'Devolución #' || d.numero || ' de la venta ' || v.numero_documento || ' (' || v.cliente_nombre || ') por '
              || interno.lempiras(t_base + t_imp) || ': ' || v_motivo, auth.uid(), v_rol);
  END IF;
  INSERT INTO public.devolucion (id, empresa_id, numero, venta_id, cliente_id, cliente_nombre, caja_id, sucursal_id, fecha_contable,
    motivo, destino, cuenta_dinero_id, subtotal_centavos, impuesto_centavos, total_centavos, desglose_impuestos, costo_centavos,
    costo_estimado_centavos, cambio, estado, aprobacion_id, equipo, id_operacion, creado_por)
  VALUES (d.id, v.empresa_id, d.numero, v.id, v.cliente_id, v.cliente_nombre, v_caja.id, v_caja.sucursal_id, v_fecha,
    v_motivo, v_dest, v_cta, t_base, t_imp, t_base + t_imp, v_desg, t_cost, t_cest, v_cam,
    CASE WHEN v_req THEN 'pendiente_aprobacion' ELSE 'por_aplicar' END, v_apr, interno.equipo(p_datos), p_id_operacion, auth.uid())
  RETURNING * INTO d;
  INSERT INTO public.devolucion_linea (empresa_id, devolucion_id, linea, venta_linea_id, producto_id, descripcion, es_servicio, cantidad,
    tipo_impuesto, impuesto_porcentaje, base_centavos, impuesto_centavos, total_centavos, costo_centavos, costo_estimado_centavos)
  SELECT v.empresa_id, d.id, (y->>'linea')::smallint, (y->>'venta_linea_id')::bigint, (y->>'producto_id')::uuid, y->>'descripcion',
         (y->>'es_servicio')::boolean, (y->>'cantidad')::numeric, y->>'tipo_impuesto', (y->>'impuesto_porcentaje')::numeric,
         (y->>'base')::bigint, (y->>'impuesto')::bigint, (y->>'base')::bigint + (y->>'impuesto')::bigint,
         (y->>'costo')::bigint, (y->>'costo_estimado')::bigint
    FROM jsonb_array_elements(v_lin) y;

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

-- Aprobación de una devolución pendiente: aprobar la APLICA (fecha de hoy o
-- p_fecha); rechazar no mueve nada.
CREATE FUNCTION interno.resolver_aprobacion_devolucion(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                       p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.aprobacion;
  d       public.devolucion;
  v_rol   text;
  v_tope  record;
  v_fecha date;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  SELECT * INTO d FROM public.devolucion WHERE id = a.documento_id;
  PERFORM interno.exigir_escritura(a.empresa_id, 'ventas.aprobar', 'ventas');
  v_rol := public.mi_rol(a.empresa_id);
  IF p_aprobar IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si aprueba (true) o rechaza (false).';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.devolucion_respuesta(d, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF NOT p_aprobar AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se rechaza (mínimo 5 letras).';
  END IF;
  IF a.solicitado_por = auth.uid() AND v_rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede aprobar ni rechazar su propia solicitud; lo hace otra persona con permiso o el dueño.';
  END IF;
  SELECT * INTO v_tope FROM interno.tope_rol(a.empresa_id, v_rol, 'devolucion');
  IF p_aprobar AND v_rol <> 'dueno' AND a.monto_centavos > v_tope.aprueba_hasta THEN
    RAISE EXCEPTION 'TOPE_APROBACION: la devolución es de % y usted aprueba hasta %; pídale al dueño que la apruebe.',
      interno.lempiras(a.monto_centavos), interno.lempiras(v_tope.aprueba_hasta);
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(a.empresa_id), d.fecha_contable));
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_fecha < d.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la devolución aprobada no puede tener fecha anterior a la solicitud (%).', to_char(d.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id FOR UPDATE;
  SELECT * INTO d FROM public.devolucion WHERE id = a.documento_id FOR UPDATE;
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.devolucion_respuesta(d, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF a.estado <> 'pendiente' OR d.estado <> 'pendiente_aprobacion' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la solicitud #% ya está % (devolución %).', a.numero, a.estado, d.estado;
  END IF;
  IF a.primera_aprobacion_por = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: usted ya dio la primera aprobación; la segunda la da otra persona (o el dueño).';
  END IF;
  IF p_aprobar AND NOT interno.paso_aprobacion(a, v_rol, p_motivo, p_id_operacion) THEN
    SELECT * INTO a FROM public.aprobacion WHERE id = a.id;
    RETURN interno.devolucion_respuesta(d, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', true);
  END IF;
  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  UPDATE public.aprobacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_por = auth.uid(),
         rol_resolutor = v_rol, resuelto_en = now(), motivo_resolucion = nullif(trim(p_motivo), ''), resolucion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  IF p_aprobar THEN
    d := interno.aplicar_devolucion(d.id, v_fecha, p_id_operacion);
  ELSE
    UPDATE public.devolucion SET estado = 'rechazada' WHERE id = d.id RETURNING * INTO d;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.devolucion_respuesta(d, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
    'falta_segunda_aprobacion', false);
END $$;

-- resolver_aprobacion (reemplaza la de 031; misma firma): rama "devolucion".
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
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_anulacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  ELSIF a.tipo = 'devolucion' THEN
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_aprobacion_devolucion(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  END IF;
  RAISE EXCEPTION 'NO_PERMITIDO: este tipo de aprobación (%) todavía no se resuelve aquí.', a.tipo;
END $$;

-- documento_nota_credito(devolucion): lo que se imprime. Sin costos.
-- NOTA: las leyendas fiscales (SAR) las debe validar un contador.
CREATE FUNCTION public.documento_nota_credito(p_devolucion_id uuid)
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
                 'total_centavos', l.total_centavos) ORDER BY l.linea) FROM public.devolucion_linea l WHERE l.devolucion_id = d.id),
    'totales', jsonb_build_object('subtotal_centavos', d.subtotal_centavos, 'impuestos', d.desglose_impuestos,
                 'impuesto_centavos', d.impuesto_centavos, 'total_centavos', d.total_centavos,
                 'total_en_letras', interno.monto_en_letras(d.total_centavos, e.moneda), 'moneda', e.moneda),
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

-- Lecturas: devoluciones (sin costos salvo quien los ve).
CREATE VIEW public.v_devolucion AS
  SELECT d.empresa_id, d.id AS devolucion_id, d.numero, d.estado, d.venta_id, v.numero_documento AS venta_documento,
         d.tipo_documento, d.numero_documento, d.fecha_contable, d.cliente_id, d.cliente_nombre, d.motivo, d.destino,
         d.subtotal_centavos, d.impuesto_centavos, d.total_centavos, d.cxc_centavos, d.dinero_centavos, d.saldo_favor_centavos,
         d.cambio_centavos, d.venta_cambio_id, d.aprobacion_id,
         CASE WHEN x.costos THEN d.costo_centavos END AS costo_centavos,
         d.creado_por, public.nombre_usuario(d.empresa_id, d.creado_por) AS registrado_por, d.registrado_en
  FROM public.devolucion d
  JOIN public.venta v ON v.id = d.venta_id
  CROSS JOIN LATERAL (SELECT d.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
                             AND d.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))) AS costos) x
  WHERE d.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
     OR (d.empresa_id IN (SELECT public.mis_empresas()) AND d.creado_por = (SELECT auth.uid()));
GRANT SELECT ON public.v_devolucion TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4) id_operacion y seguridad
-- ---------------------------------------------------------------------
INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('devolucion', 'id_operacion', 'devolucion', 30);

REVOKE EXECUTE ON FUNCTION
  interno.proteger_devolucion(),
  interno.proteger_devolucion_linea(),
  interno.devolucion_respuesta(public.devolucion, boolean),
  interno.aplicar_devolucion(uuid, date, uuid),
  interno.venta_de_cambio(public.devolucion, uuid),
  interno.resolver_aprobacion_devolucion(uuid, boolean, text, uuid, date)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.registrar_devolucion(uuid, jsonb, uuid), public.documento_nota_credito(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_devolucion(uuid, jsonb, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.documento_nota_credito(uuid) TO authenticated, service_role;
