-- =====================================================================
-- 028_ventas.sql  -  Núcleo 0.7.0 (etapa 2b-2a): ventas todo-o-nada
--
--   venta / venta_linea / venta_pago   una venta con sus líneas y sus formas
--       de pago. registrar_venta guarda TODO o NADA: documento (factura del
--       régimen fiscal activo, o ticket interno), salida del kardex a costo
--       promedio (los SERVICIOS no tocan el kardex), asiento y rastro del
--       dinero, en una transacción. Bienes y servicios en la misma venta.
--   Impuestos: los de la tabla public.impuesto (026); cada línea guarda el
--       código, la tasa y la clase que usó.
--   Formas de pago: efectivo (caja del turno; interno.cuenta_efectivo_cobro),
--       tarjeta (POS por liquidar), transferencia (por confirmar hasta
--       confirmar_transferencia_venta con banco y referencia), crédito (CxC,
--       requiere cliente) y mixto (varias formas; la suma = el total exacto).
--   Descuentos: por categoría (promociones con fechas), por artículo (en la
--       línea) y por factura (prorrateado a las líneas para el ISV). Sobre el
--       tope del puesto la venta queda "pendiente de aprobación" SIN mover
--       dinero, inventario ni número CAI.
--   Crédito configurable: segun_limite | siempre_aprobacion.
--   Anular: el vendedor SOLICITA; aprueba admin o dueño con motivo, con el mes
--       abierto. La factura conserva su número y queda ANULADA; el dinero
--       vuelve a la MISMA cuenta de la que entró.
--   Aprobaciones genéricas (024) con doble aprobación (empresa.doble_aprobacion)
--       para gastos y ventas.
-- Asiento de una venta:
--   Dr caja / POS por liquidar / transferencias por confirmar / Clientes (crédito)  = total
--   Dr Descuentos sobre ventas (4.1.01.03)  Cr Ventas (4.1.01.01, precio sin ISV)
--   Cr el impuesto por pagar de cada impuesto gravado (Honduras: ISV por pagar 2.1.02.01)
--   Dr Costo de mercadería vendida (5.1.01.01)  Cr Inventario (1.1.03.01)
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('PAGO_NO_CUADRA', 'Las formas de pago no suman el total de la venta.',
   'Revise los montos: efectivo + tarjeta + transferencia + crédito debe ser igual al total exacto.'),
  ('CLIENTE_REQUERIDO', 'Esta venta necesita un cliente.',
   'Elija o registre el cliente. El crédito (y más adelante el apartado y el saldo a favor) siempre lleva cliente.'),
  ('VENTA_CON_COBROS', 'La venta ya tiene cobros registrados.',
   'Anule primero esos cobros y después la venta.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('ventas.ver',                 'Ver todas las ventas, cuentas por cobrar y reportes de ventas', false, true),
  ('ventas.vender',              'Registrar ventas (al contado, solo si además cobra) y elegir cliente', true, false),
  ('ventas.cobrar',              'Recibir el pago de una venta (efectivo, tarjeta o transferencia)', true, false),
  ('ventas.cotizar',             'Hacer cotizaciones (no mueven inventario ni dinero)', false, false),
  ('ventas.aprobar',             'Aprobar o rechazar descuentos y créditos pendientes, hasta el tope del puesto', true, false),
  ('ventas.solicitar_anulacion', 'Pedir que se anule una venta (la aprueba otra persona)', false, false),
  ('ventas.anular',              'Aprobar o rechazar la anulación de ventas, hasta el tope del puesto', true, false),
  ('ventas.promociones',         'Crear, cambiar, activar y desactivar promociones por categoría', false, false);

-- Criterio (REQUISITOS): el vendedor vende y solicita (no cobra, no ve
-- costos); el cajero cobra; el admin aprueba dentro de sus topes; el
-- contador solo lee.
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'ventas.ver'), ('dueno', 'ventas.vender'), ('dueno', 'ventas.cobrar'), ('dueno', 'ventas.cotizar'),
  ('dueno', 'ventas.aprobar'), ('dueno', 'ventas.solicitar_anulacion'), ('dueno', 'ventas.anular'), ('dueno', 'ventas.promociones'),
  ('admin', 'ventas.ver'), ('admin', 'ventas.vender'), ('admin', 'ventas.cobrar'), ('admin', 'ventas.cotizar'),
  ('admin', 'ventas.aprobar'), ('admin', 'ventas.solicitar_anulacion'), ('admin', 'ventas.anular'), ('admin', 'ventas.promociones'),
  ('cajero', 'ventas.vender'), ('cajero', 'ventas.cobrar'), ('cajero', 'ventas.cotizar'), ('cajero', 'ventas.solicitar_anulacion'),
  ('vendedor', 'ventas.vender'), ('vendedor', 'ventas.cotizar'), ('vendedor', 'ventas.solicitar_anulacion'),
  ('contador', 'ventas.ver');
SELECT interno.repartir_permisos(ARRAY['ventas.ver', 'ventas.vender', 'ventas.cobrar', 'ventas.cotizar', 'ventas.aprobar',
  'ventas.solicitar_anulacion', 'ventas.anular', 'ventas.promociones'], 'Núcleo 0.7.0: permisos de ventas');

-- ---------------------------------------------------------------------
-- 1) Cuentas que usa el módulo (todas vienen en la plantilla del catálogo).
--    Clientes (1.1.02.01) la controla el módulo: sin asientos manuales.
-- ---------------------------------------------------------------------
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('cxc',              '1.1.02.01', 'Clientes: ventas al crédito por cobrar (CxC)', 'ventas'),
  ('ventas',           '4.1.01.01', 'Ventas de mercadería (precio sin ISV, antes de descuentos)', NULL),
  ('descuento_ventas', '4.1.01.03', 'Descuentos sobre ventas (promociones, por artículo y por factura)', NULL),
  ('costo_ventas',     '5.1.01.01', 'Costo de mercadería vendida (costo promedio del kardex)', NULL);

-- ---------------------------------------------------------------------
-- 2) Configuración de la empresa (solo el dueño, configurar_empresa)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa
  ADD COLUMN credito_politica          text NOT NULL DEFAULT 'segun_limite'
    CHECK (credito_politica IN ('segun_limite', 'siempre_aprobacion')),
  ADD COLUMN cotizacion_dias_vigencia  integer NOT NULL DEFAULT 15 CHECK (cotizacion_dias_vigencia BETWEEN 1 AND 365),
  ADD COLUMN cotizacion_precios        text NOT NULL DEFAULT 'respetar' CHECK (cotizacion_precios IN ('respetar', 'recalcular'));

-- ---------------------------------------------------------------------
-- 3) Topes por puesto para ventas (los cambia el dueño)
--    descuento:        porcentaje que el puesto da sin aprobación y hasta
--                      cuánto aprueba (columnas *_porcentaje).
--    credito:          monto a crédito de una venta que el puesto aprueba.
--    anulacion_venta:  total de la venta cuya anulación aprueba.
-- ---------------------------------------------------------------------
ALTER TABLE public.tope_rol
  DROP CONSTRAINT tope_rol_tipo_check,
  ADD CONSTRAINT tope_rol_tipo_check CHECK (tipo IN ('gasto', 'descuento', 'credito', 'anulacion_venta')),
  ADD COLUMN sin_aprobacion_porcentaje numeric(5,2) CHECK (sin_aprobacion_porcentaje BETWEEN 0 AND 100),
  ADD COLUMN aprueba_hasta_porcentaje  numeric(5,2) CHECK (aprueba_hasta_porcentaje BETWEEN 0 AND 100),
  ADD CONSTRAINT tope_rol_porcentaje CHECK ((tipo = 'descuento') = (sin_aprobacion_porcentaje IS NOT NULL AND aprueba_hasta_porcentaje IS NOT NULL));
ALTER TABLE interno.plantilla_tope_rol
  ADD COLUMN sin_aprobacion_porcentaje numeric(5,2),
  ADD COLUMN aprueba_hasta_porcentaje  numeric(5,2);

-- Valores iniciales (A CONFIRMAR CON EL DUEÑO; los cambia con configurar_tope_*):
--   descuento: cajero y vendedor dan hasta 5 % sin aprobación; el admin
--              da hasta 10 % y aprueba hasta 20 %.
--   crédito y anulación de ventas: el admin aprueba hasta L 5,000.00.
INSERT INTO interno.plantilla_tope_rol (rol, tipo, sin_aprobacion_centavos, aprueba_hasta_centavos,
                                        sin_aprobacion_porcentaje, aprueba_hasta_porcentaje) VALUES
  ('admin',    'descuento', 0, 0, 10.00, 20.00),
  ('cajero',   'descuento', 0, 0,  5.00,  0.00),
  ('vendedor', 'descuento', 0, 0,  5.00,  0.00),
  ('admin',    'credito',         0, 500000, NULL, NULL),
  ('admin',    'anulacion_venta', 0, 500000, NULL, NULL);

-- Tope de descuento de un puesto (fila de la empresa, si no la plantilla, si no 0 %).
CREATE FUNCTION interno.tope_descuento(p_empresa_id uuid, p_rol text,
                                       OUT sin_aprobacion numeric, OUT aprueba_hasta numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(t.sin_aprobacion_porcentaje, p.sin_aprobacion_porcentaje, 0),
         coalesce(t.aprueba_hasta_porcentaje, p.aprueba_hasta_porcentaje, 0)
    FROM (SELECT 1) x
    LEFT JOIN public.tope_rol t ON t.empresa_id = p_empresa_id AND t.rol = p_rol AND t.tipo = 'descuento'
    LEFT JOIN interno.plantilla_tope_rol p ON p.rol = p_rol AND p.tipo = 'descuento'
$$;

-- configurar_tope_rol (reemplaza la de 024; misma firma): tipos en centavos
-- gasto, credito y anulacion_venta. El descuento va en configurar_tope_descuento.
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
  IF coalesce(p_tipo, '') NOT IN ('gasto', 'credito', 'anulacion_venta') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de tope es "gasto", "credito" o "anulacion_venta".';
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

-- configurar_tope_descuento(empresa, rol, sin_aprobacion %, aprueba_hasta %, motivo)   solo el dueño
CREATE FUNCTION public.configurar_tope_descuento(p_empresa_id uuid, p_rol text, p_sin_aprobacion_porcentaje numeric,
                                                 p_aprueba_hasta_porcentaje numeric, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rol r WHERE r.codigo = p_rol) OR p_rol IN ('dueno', 'proveedor', 'contador') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el puesto "%" no existe o no lleva tope de descuento (el dueño no tiene tope).', p_rol;
  END IF;
  IF p_sin_aprobacion_porcentaje IS NULL OR p_sin_aprobacion_porcentaje NOT BETWEEN 0 AND 100
     OR p_sin_aprobacion_porcentaje <> round(p_sin_aprobacion_porcentaje, 2)
     OR p_aprueba_hasta_porcentaje IS NULL OR p_aprueba_hasta_porcentaje NOT BETWEEN 0 AND 100
     OR p_aprueba_hasta_porcentaje <> round(p_aprueba_hasta_porcentaje, 2) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los topes de descuento son porcentajes de 0 a 100 (hasta 2 decimales).';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.tope_rol (empresa_id, rol, tipo, sin_aprobacion_centavos, aprueba_hasta_centavos,
                               sin_aprobacion_porcentaje, aprueba_hasta_porcentaje, actualizado_por)
  VALUES (p_empresa_id, p_rol, 'descuento', 0, 0, p_sin_aprobacion_porcentaje, p_aprueba_hasta_porcentaje, auth.uid())
  ON CONFLICT (empresa_id, rol, tipo) DO UPDATE
     SET sin_aprobacion_porcentaje = excluded.sin_aprobacion_porcentaje, aprueba_hasta_porcentaje = excluded.aprueba_hasta_porcentaje,
         actualizado_por = excluded.actualizado_por, actualizado_en = now();
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('rol', p_rol, 'tipo', 'descuento', 'sin_aprobacion_porcentaje', p_sin_aprobacion_porcentaje,
                            'aprueba_hasta_porcentaje', p_aprueba_hasta_porcentaje);
END $$;

-- ---------------------------------------------------------------------
-- 4) Doble aprobación (empresa.doble_aprobacion, ya guardada en 0.6.0).
--    Se fija al pedir (no cambia si el dueño mueve la bandera después).
--    Con 2: dos personas distintas (ninguna es quien pidió); el dueño
--    aprueba solo (su aprobación cuenta como las dos). Un rechazo basta.
-- ---------------------------------------------------------------------
ALTER TABLE public.aprobacion
  ADD COLUMN aprobaciones_requeridas    smallint NOT NULL DEFAULT 1 CHECK (aprobaciones_requeridas IN (1, 2)),
  ADD COLUMN primera_aprobacion_por     uuid,
  ADD COLUMN primera_aprobacion_rol     text,
  ADD COLUMN primera_aprobacion_en      timestamptz,
  ADD COLUMN primera_aprobacion_motivo  text,
  ADD COLUMN primera_id_operacion       uuid,
  ADD CONSTRAINT aprobacion_primera CHECK ((primera_aprobacion_por IS NULL) = (primera_aprobacion_en IS NULL)
                                          AND (primera_aprobacion_por IS NULL OR aprobaciones_requeridas = 2));

CREATE FUNCTION interno.aprobaciones_requeridas() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  NEW.aprobaciones_requeridas := CASE WHEN coalesce((SELECT e.doble_aprobacion FROM public.empresa e WHERE e.id = NEW.empresa_id), false)
                                      THEN 2 ELSE 1 END;
  RETURN NEW;
END $$;
CREATE TRIGGER requeridas BEFORE INSERT ON public.aprobacion FOR EACH ROW EXECUTE FUNCTION interno.aprobaciones_requeridas();

-- Defensa (reemplaza la de 024): la primera aprobación se anota una vez y la
-- resolución final una vez.
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
  RAISE EXCEPTION 'PROHIBIDO: una aprobación no se edita; se resuelve una sola vez.';
END $$;

-- Paso de aprobación con la regla de doble aprobación. Devuelve true si
-- con esta aprobación ya queda resuelta; false si fue la primera de dos.
CREATE FUNCTION interno.paso_aprobacion(a public.aprobacion, p_rol text, p_motivo text, p_id_operacion uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF a.primera_aprobacion_por = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: usted ya dio la primera aprobación; la segunda la da otra persona (o el dueño).';
  END IF;
  IF a.aprobaciones_requeridas = 2 AND p_rol <> 'dueno' AND a.primera_aprobacion_por IS NULL THEN
    UPDATE public.aprobacion
       SET primera_aprobacion_por = auth.uid(), primera_aprobacion_rol = p_rol, primera_aprobacion_en = now(),
           primera_aprobacion_motivo = nullif(trim(p_motivo), ''), primera_id_operacion = p_id_operacion
     WHERE id = a.id;
    RETURN false;
  END IF;
  RETURN true;
END $$;

-- v_aprobacion (reemplaza la de 024: mismas columnas y al final las de la doble aprobación).
CREATE OR REPLACE VIEW public.v_aprobacion WITH (security_invoker = true) AS
  SELECT a.empresa_id, a.id AS aprobacion_id, a.numero, a.tipo, a.documento_tipo, a.documento_id, a.monto_centavos,
         a.descripcion, a.estado, a.solicitado_por, public.nombre_usuario(a.empresa_id, a.solicitado_por) AS solicitante,
         a.rol_solicitante, a.solicitado_en, a.resuelto_por, public.nombre_usuario(a.empresa_id, a.resuelto_por) AS resolutor,
         a.rol_resolutor, a.resuelto_en, a.motivo_resolucion,
         a.aprobaciones_requeridas, a.primera_aprobacion_por,
         public.nombre_usuario(a.empresa_id, a.primera_aprobacion_por) AS primera_aprobacion,
         a.primera_aprobacion_en, a.primera_aprobacion_motivo,
         (a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL) AS falta_segunda_aprobacion
  FROM public.aprobacion a;

-- ---------------------------------------------------------------------
-- 5) Promociones por categoría (con fecha de inicio y fin, activables)
-- ---------------------------------------------------------------------
CREATE TABLE public.promocion (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  nombre          text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 100),
  categoria_id    uuid NOT NULL,                -- vale también para sus subcategorías
  tipo            text NOT NULL CHECK (tipo IN ('porcentaje', 'monto')),
  porcentaje      numeric(5,2) CHECK (porcentaje > 0 AND porcentaje <= 100),
  monto_centavos  bigint CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),   -- por unidad, en los términos del precio
  fecha_inicio    date NOT NULL,
  fecha_fin       date NOT NULL,
  activa          boolean NOT NULL DEFAULT true,
  creado_por      uuid,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, categoria_id) REFERENCES public.categoria_producto(empresa_id, id),
  CHECK (fecha_fin >= fecha_inicio),
  CHECK ((tipo = 'porcentaje') = (porcentaje IS NOT NULL)),
  CHECK ((tipo = 'monto') = (monto_centavos IS NOT NULL))
);
CREATE INDEX promocion_vigente ON public.promocion (empresa_id, categoria_id, fecha_inicio, fecha_fin) WHERE activa;

CREATE FUNCTION interno.proteger_promocion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.creado_por, NEW.creado_en) IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: no se puede cambiar el id, la empresa ni quién creó la promoción.';
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.promocion FOR EACH ROW EXECUTE FUNCTION interno.proteger_promocion();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.promocion FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.promocion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la promoción en vez de borrarla.');

-- Aplica los datos de una promoción (crear y editar) y valida.
CREATE FUNCTION interno.aplicar_datos_promocion(p public.promocion, p_datos jsonb) RETURNS public.promocion
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_claves(p_datos, ARRAY['nombre', 'categoria_id', 'tipo', 'porcentaje', 'monto_centavos',
                                               'fecha_inicio', 'fecha_fin', 'activa']);
  IF p_datos ? 'nombre' THEN
    p.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 100);
  END IF;
  IF p.nombre IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la promoción (ej. "Semana de la pintura").';
  END IF;
  IF p_datos ? 'categoria_id' THEN
    v_id := interno.json_uuid(p_datos->'categoria_id', 'categoria_id');
    IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.categoria_producto c WHERE c.id = v_id AND c.empresa_id = p.empresa_id AND c.activa) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la categoría no existe en esta empresa o está desactivada.';
    END IF;
    p.categoria_id := v_id;
  END IF;
  IF p.categoria_id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique la categoría de la promoción.';
  END IF;
  IF p_datos ? 'tipo' THEN
    p.tipo := interno.json_texto(p_datos->'tipo', 'tipo', 20);
    IF p.tipo = 'porcentaje' THEN p.monto_centavos := NULL; ELSIF p.tipo = 'monto' THEN p.porcentaje := NULL; END IF;
  END IF;
  IF coalesce(p.tipo, '') NOT IN ('porcentaje', 'monto') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de promoción es "porcentaje" o "monto" (por unidad).';
  END IF;
  IF p_datos ? 'porcentaje' AND p_datos->'porcentaje' <> 'null'::jsonb THEN
    IF jsonb_typeof(p_datos->'porcentaje') <> 'number' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "porcentaje" debe ser un número.';
    END IF;
    p.porcentaje := (p_datos->>'porcentaje')::numeric;
  END IF;
  IF p_datos ? 'monto_centavos' AND p_datos->'monto_centavos' <> 'null'::jsonb THEN
    p.monto_centavos := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
  END IF;
  IF p.tipo = 'porcentaje' AND (p.porcentaje IS NULL OR p.porcentaje <= 0 OR p.porcentaje > 100 OR p.porcentaje <> round(p.porcentaje, 2)) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el porcentaje de la promoción va de 0.01 a 100 (hasta 2 decimales).';
  END IF;
  IF p.tipo = 'monto' AND coalesce(p.monto_centavos, 0) = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el descuento por unidad en centavos ("monto_centavos", mayor que cero).';
  END IF;
  IF p.tipo = 'porcentaje' THEN p.monto_centavos := NULL; ELSE p.porcentaje := NULL; END IF;
  IF p_datos ? 'fecha_inicio' THEN p.fecha_inicio := interno.json_fecha(p_datos->'fecha_inicio', 'fecha_inicio'); END IF;
  IF p_datos ? 'fecha_fin'    THEN p.fecha_fin    := interno.json_fecha(p_datos->'fecha_fin', 'fecha_fin'); END IF;
  IF p.fecha_inicio IS NULL OR p.fecha_fin IS NULL OR p.fecha_fin < p.fecha_inicio THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique fecha de inicio y de fin (la de fin no antes que la de inicio).';
  END IF;
  IF p_datos ? 'activa' THEN p.activa := interno.json_si_no(p_datos->'activa', 'activa'); END IF;
  RETURN p;
END $$;

-- crear_promocion(empresa, datos)   ventas.promociones
-- datos = {"nombre":"Semana de la pintura","categoria_id":"...","tipo":"porcentaje","porcentaje":10,
--          "fecha_inicio":"2026-01-10","fecha_fin":"2026-01-20"}   (o "tipo":"monto","monto_centavos":500)
CREATE FUNCTION public.crear_promocion(p_empresa_id uuid, p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p public.promocion;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.promociones', 'ventas');
  p.empresa_id := p_empresa_id;
  p.activa := true;
  p := interno.aplicar_datos_promocion(p, p_datos);
  INSERT INTO public.promocion (empresa_id, nombre, categoria_id, tipo, porcentaje, monto_centavos, fecha_inicio, fecha_fin,
                                activa, creado_por)
  VALUES (p_empresa_id, p.nombre, p.categoria_id, p.tipo, p.porcentaje, p.monto_centavos, p.fecha_inicio, p.fecha_fin,
          p.activa, auth.uid())
  RETURNING * INTO p;
  RETURN jsonb_build_object('promocion_id', p.id, 'activa', p.activa);
END $$;

-- editar_promocion(empresa, promocion, datos, motivo)   ventas.promociones
-- Cambia lo indicado; "activa": false la desactiva. Queda en la bitácora.
-- Las ventas ya hechas guardan su descuento (no cambian).
CREATE FUNCTION public.editar_promocion(p_empresa_id uuid, p_promocion_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p public.promocion;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.promociones', 'ventas');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  SELECT * INTO p FROM public.promocion WHERE id = p_promocion_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la promoción no existe en esta empresa.';
  END IF;
  p := interno.aplicar_datos_promocion(p, p_datos);
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.promocion
     SET nombre = p.nombre, categoria_id = p.categoria_id, tipo = p.tipo, porcentaje = p.porcentaje,
         monto_centavos = p.monto_centavos, fecha_inicio = p.fecha_inicio, fecha_fin = p.fecha_fin, activa = p.activa
   WHERE id = p.id
  RETURNING * INTO p;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('promocion_id', p.id, 'activa', p.activa);
END $$;

-- ---------------------------------------------------------------------
-- 6) Tablas de la venta
-- ---------------------------------------------------------------------
CREATE TABLE public.venta (
  id                               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                       uuid NOT NULL REFERENCES public.empresa(id),
  numero                           bigint NOT NULL,          -- correlativo interno (también las pendientes)
  sucursal_id                      uuid NOT NULL,
  caja_id                          uuid NOT NULL REFERENCES public.caja(id),
  bodega_id                        uuid,                     -- NULL si la venta es solo de servicios
  fecha_contable                   date NOT NULL,            -- fecha de emisión
  tipo_documento                   text NOT NULL CHECK (tipo_documento IN ('factura', 'ticket')),
  numero_documento                 text,                     -- factura según el régimen (HN 001-001-01-00000001); ticket T-001-001-00000001
  regimen_fiscal                   text,                     -- fiscal_hn (factura) o NULL (ticket)
  datos_fiscales                   jsonb,                    -- lo que el régimen pide guardar e imprimir (HN: CAI, rango, fecha límite)
  emisor_nombre                    text NOT NULL,
  emisor_rtn                       text,
  cliente_id                       uuid,                     -- NULL = Consumidor final
  cliente_nombre                   text NOT NULL,
  cliente_rtn                      text,
  vendedor_id                      uuid NOT NULL,
  cotizacion_id                    uuid,
  condicion                        text NOT NULL CHECK (condicion IN ('contado', 'credito')),
  credito_centavos                 bigint NOT NULL DEFAULT 0 CHECK (credito_centavos >= 0),
  plazo_dias                       integer CHECK (plazo_dias BETWEEN 0 AND 365),
  vence_el                         date,
  descuento_factura_porcentaje     numeric(5,2),             -- lo que se pidió (el reparto queda en las líneas)
  descuento_factura_monto_centavos bigint,
  subtotal_centavos                bigint NOT NULL CHECK (subtotal_centavos >= 0),   -- precio sin ISV antes de descuentos
  descuento_centavos               bigint NOT NULL CHECK (descuento_centavos >= 0),  -- todos los descuentos, sin ISV
  descuento_promocion_centavos     bigint NOT NULL CHECK (descuento_promocion_centavos >= 0),
  descuento_manual_centavos        bigint NOT NULL CHECK (descuento_manual_centavos >= 0),
  descuento_manual_porcentaje      numeric(7,2) NOT NULL,    -- artículo + factura sobre el precio ya con promoción
  gravado_centavos                 bigint NOT NULL,          -- base sin impuesto de las líneas gravadas
  exento_centavos                  bigint NOT NULL,
  exonerado_centavos               bigint NOT NULL,
  impuesto_centavos                bigint NOT NULL,          -- suma de los impuestos (ISV en Honduras)
  desglose_impuestos               jsonb NOT NULL,           -- [{codigo, nombre, porcentaje, clase, base_centavos, impuesto_centavos, cuenta_por_pagar}]
  total_centavos                   bigint NOT NULL CHECK (total_centavos BETWEEN 1 AND 9007199254740991),
  costo_centavos                   bigint,                   -- costo de lo vendido (al emitir)
  estado                           text NOT NULL CHECK (estado IN ('por_emitir', 'pendiente_aprobacion', 'emitida',
                                                                   'rechazada', 'cancelada', 'anulada')),
  requiere_aprobacion              text[] NOT NULL DEFAULT '{}',   -- {descuento, credito}
  aprobacion_id                    uuid,
  asiento_id                       uuid,
  emitida_en                       timestamptz,
  emitida_por                      uuid,
  nota                             text,
  equipo                           text,
  id_operacion                     uuid NOT NULL,
  creado_por                       uuid,
  registrado_en                    timestamptz NOT NULL DEFAULT now(),
  -- Cancelación de una venta pendiente (una vez)
  cancelada_en                     timestamptz,
  cancelada_por                    uuid,
  motivo_cancelacion               text,
  cancelacion_id_operacion         uuid,
  -- Anulación de una venta emitida (una vez)
  anulada_en                       timestamptz,
  anulada_por                      uuid,
  motivo_anulacion                 text,
  fecha_anulacion                  date,
  asiento_anulacion_id             uuid,
  anulacion_id_operacion           uuid,
  anulacion_solicitud_id           uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, sucursal_id)          REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, bodega_id)            REFERENCES public.bodega(empresa_id, id),
  FOREIGN KEY (empresa_id, cliente_id)           REFERENCES public.tercero(empresa_id, id),
  FOREIGN KEY (empresa_id, aprobacion_id)        REFERENCES public.aprobacion(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)           REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_anulacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK (total_centavos = subtotal_centavos - descuento_centavos + impuesto_centavos),
  CHECK (subtotal_centavos - descuento_centavos = gravado_centavos + exento_centavos + exonerado_centavos),
  CHECK (jsonb_typeof(desglose_impuestos) = 'array'),
  CHECK (descuento_centavos = descuento_promocion_centavos + descuento_manual_centavos),
  CHECK ((condicion = 'credito') = (credito_centavos > 0)),
  CHECK (credito_centavos <= total_centavos),
  CHECK (credito_centavos = 0 OR (cliente_id IS NOT NULL AND plazo_dias IS NOT NULL)),
  CHECK (vence_el IS NULL OR credito_centavos > 0),
  CHECK (estado NOT IN ('emitida', 'anulada') OR (numero_documento IS NOT NULL AND asiento_id IS NOT NULL
                                                  AND costo_centavos IS NOT NULL AND (credito_centavos = 0 OR vence_el IS NOT NULL))),
  CHECK (estado IN ('emitida', 'anulada') OR (numero_documento IS NULL AND asiento_id IS NULL)),
  CHECK (tipo_documento <> 'factura' OR numero_documento IS NULL OR (regimen_fiscal IS NOT NULL AND datos_fiscales IS NOT NULL)),
  CHECK (tipo_documento <> 'ticket' OR regimen_fiscal IS NULL),
  CHECK (cardinality(requiere_aprobacion) = 0 OR aprobacion_id IS NOT NULL),
  CHECK ((estado = 'cancelada') = (cancelada_en IS NOT NULL)),
  CHECK ((estado = 'anulada') = (anulada_en IS NOT NULL)),
  CHECK ((anulada_en IS NULL) = (asiento_anulacion_id IS NULL))
);
-- Un número de documento (factura o ticket) no se repite nunca en la empresa.
CREATE UNIQUE INDEX venta_numero_documento ON public.venta (empresa_id, numero_documento) WHERE numero_documento IS NOT NULL;
CREATE INDEX venta_empresa_fecha ON public.venta (empresa_id, fecha_contable);
CREATE INDEX venta_cliente ON public.venta (empresa_id, cliente_id, fecha_contable) WHERE cliente_id IS NOT NULL;
CREATE INDEX venta_vendedor ON public.venta (empresa_id, vendedor_id, fecha_contable);
CREATE INDEX venta_caja ON public.venta (caja_id, fecha_contable);
CREATE INDEX venta_pendiente ON public.venta (empresa_id) WHERE estado = 'pendiente_aprobacion';

CREATE TABLE public.venta_linea (
  id                                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id                           uuid NOT NULL,
  venta_id                             uuid NOT NULL,
  linea                                smallint NOT NULL CHECK (linea > 0),
  producto_id                          uuid NOT NULL,
  descripcion                          text NOT NULL,
  cantidad                             numeric(18,4) NOT NULL CHECK (cantidad > 0),
  precio_unitario_centavos             bigint NOT NULL CHECK (precio_unitario_centavos >= 0),  -- como estaba escrito
  precio_incluye_isv                   boolean NOT NULL,
  tipo_impuesto                        text NOT NULL,           -- código del impuesto (tabla public.impuesto)
  impuesto_porcentaje                  numeric(6,3) NOT NULL,   -- la tasa que se usó
  impuesto_clase                       text NOT NULL CHECK (impuesto_clase IN ('gravado', 'exento', 'exonerado')),
  es_servicio                          boolean NOT NULL DEFAULT false,
  promocion_id                         uuid,
  descuento_linea_porcentaje           numeric(5,2),       -- lo que se pidió en la línea
  descuento_linea_monto_centavos       bigint,
  -- En los términos del precio (con ISV si el precio lo incluye):
  bruto_centavos                       bigint NOT NULL CHECK (bruto_centavos >= 0),           -- round(cantidad x precio)
  descuento_promocion_precio_centavos  bigint NOT NULL CHECK (descuento_promocion_precio_centavos >= 0),
  descuento_linea_centavos             bigint NOT NULL CHECK (descuento_linea_centavos >= 0),
  descuento_factura_centavos           bigint NOT NULL CHECK (descuento_factura_centavos >= 0),
  neto_centavos                        bigint NOT NULL CHECK (neto_centavos >= 0),
  -- Sin ISV (lo que va a los libros) y el ISV de la línea:
  subtotal_centavos                    bigint NOT NULL,     -- sin ISV del bruto
  descuento_promocion_centavos         bigint NOT NULL,     -- sin ISV
  descuento_centavos                   bigint NOT NULL,     -- sin ISV (promoción + artículo + factura)
  base_centavos                        bigint NOT NULL,     -- sin ISV del neto (gravado o exento)
  impuesto_centavos                    bigint NOT NULL CHECK (impuesto_centavos >= 0),
  total_centavos                       bigint NOT NULL CHECK (total_centavos >= 0),
  costo_centavos                       bigint,              -- al emitir: costo promedio del kardex (0 en servicios)
  movimiento_id                        bigint REFERENCES public.inventario_movimiento(id),
  costo_estimado_centavos              bigint,              -- servicios: cantidad x costo estimado (no va a los libros)
  UNIQUE (venta_id, linea),
  FOREIGN KEY (empresa_id, venta_id)    REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id),
  FOREIGN KEY (empresa_id, promocion_id) REFERENCES public.promocion(empresa_id, id),
  FOREIGN KEY (empresa_id, tipo_impuesto) REFERENCES public.impuesto(empresa_id, codigo),
  CHECK (neto_centavos = bruto_centavos - descuento_promocion_precio_centavos - descuento_linea_centavos - descuento_factura_centavos),
  CHECK (total_centavos = base_centavos + impuesto_centavos),
  CHECK (descuento_centavos = subtotal_centavos - base_centavos),
  CHECK (descuento_promocion_centavos BETWEEN 0 AND descuento_centavos),
  CHECK (es_servicio OR (costo_centavos IS NULL) = (movimiento_id IS NULL)),
  CHECK (NOT es_servicio OR (movimiento_id IS NULL AND coalesce(costo_centavos, 0) = 0)),
  CHECK (es_servicio OR costo_estimado_centavos IS NULL)
);
CREATE INDEX venta_linea_producto ON public.venta_linea (empresa_id, producto_id);

CREATE TABLE public.venta_pago (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                 uuid NOT NULL,
  venta_id                   uuid NOT NULL,
  linea                      smallint NOT NULL CHECK (linea > 0),
  forma                      text NOT NULL CHECK (forma IN ('efectivo', 'tarjeta', 'transferencia', 'credito')),
  monto_centavos             bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  cuenta_dinero_id           uuid,                 -- a dónde entra el dinero (NULL en crédito)
  turno_id                   uuid,                 -- efectivo: turno con el que se registró
  referencia                 text,                 -- voucher de la tarjeta, referencia de la transferencia...
  recibido_centavos          bigint,               -- efectivo: lo que entregó el cliente
  vuelto_centavos            bigint,
  -- Transferencia: por confirmar hasta que el banco la tiene
  estado_transferencia       text CHECK (estado_transferencia IN ('por_confirmar', 'confirmada')),
  banco_id                   uuid,
  referencia_confirmacion    text,
  fecha_confirmacion         date,
  asiento_confirmacion_id    uuid,
  confirmacion_id_operacion  uuid,
  confirmada_por             uuid,
  confirmada_en              timestamptz,
  UNIQUE (empresa_id, id),
  UNIQUE (venta_id, linea),
  FOREIGN KEY (empresa_id, venta_id)                REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id)        REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, turno_id)                REFERENCES public.turno_caja(empresa_id, id),
  FOREIGN KEY (empresa_id, banco_id)                REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_confirmacion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((forma = 'credito') = (cuenta_dinero_id IS NULL)),
  CHECK (forma = 'efectivo' OR (recibido_centavos IS NULL AND vuelto_centavos IS NULL AND turno_id IS NULL)),
  CHECK ((recibido_centavos IS NULL) = (vuelto_centavos IS NULL)),
  CHECK (recibido_centavos IS NULL OR (recibido_centavos >= monto_centavos AND vuelto_centavos = recibido_centavos - monto_centavos)),
  CHECK ((forma = 'transferencia') = (estado_transferencia IS NOT NULL)),
  CHECK ((estado_transferencia = 'confirmada') = (asiento_confirmacion_id IS NOT NULL)),
  CHECK ((asiento_confirmacion_id IS NULL) = (banco_id IS NULL))
);
CREATE INDEX venta_pago_venta ON public.venta_pago (venta_id);
CREATE INDEX venta_pago_por_confirmar ON public.venta_pago (empresa_id) WHERE estado_transferencia = 'por_confirmar';

-- Solicitudes de anulación (el vendedor pide; aprueba admin o dueño).
CREATE TABLE public.venta_anulacion (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  venta_id        uuid NOT NULL,
  motivo          text NOT NULL CHECK (length(trim(motivo)) >= 5),
  estado          text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'aprobada', 'rechazada')),
  aprobacion_id   uuid NOT NULL,
  id_operacion    uuid NOT NULL,
  solicitado_por  uuid,
  solicitado_en   timestamptz NOT NULL DEFAULT now(),
  resuelto_en     timestamptz,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, venta_id)      REFERENCES public.venta(empresa_id, id),
  FOREIGN KEY (empresa_id, aprobacion_id) REFERENCES public.aprobacion(empresa_id, id),
  CHECK ((estado = 'pendiente') = (resuelto_en IS NULL))
);
-- Una venta tiene a lo más una solicitud pendiente (o aprobada).
CREATE UNIQUE INDEX venta_anulacion_viva ON public.venta_anulacion (venta_id) WHERE estado IN ('pendiente', 'aprobada');
ALTER TABLE public.venta ADD CONSTRAINT venta_anulacion_solicitud_fk
  FOREIGN KEY (empresa_id, anulacion_solicitud_id) REFERENCES public.venta_anulacion(empresa_id, id);

-- ---------------------------------------------------------------------
-- 7) Defensas de tabla
-- ---------------------------------------------------------------------
-- La venta no se edita: se emite una vez (o se rechaza / cancela si estaba
-- pendiente) y se anula una vez.
CREATE FUNCTION interno.proteger_venta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_emi constant text[] := ARRAY['estado', 'fecha_contable', 'numero_documento', 'regimen_fiscal', 'datos_fiscales',
    'vence_el', 'asiento_id', 'costo_centavos', 'emitida_en', 'emitida_por'];
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
CREATE TRIGGER proteger BEFORE UPDATE ON public.venta FOR EACH ROW EXECUTE FUNCTION interno.proteger_venta();

-- Al confirmar: ninguna venta queda "por emitir" (estado de paso dentro de registrar_venta).
CREATE FUNCTION interno.venta_sin_emitir() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (SELECT v.estado FROM public.venta v WHERE v.id = NEW.id) = 'por_emitir' THEN
    RAISE EXCEPTION 'NO_CUADRA: la venta % quedó sin emitir. No se guardó nada; avise a soporte.', NEW.numero;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER venta_emitida AFTER INSERT ON public.venta
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION interno.venta_sin_emitir();

-- La línea solo recibe su costo y su movimiento del kardex al emitir (una vez).
CREATE FUNCTION interno.proteger_venta_linea() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.costo_centavos IS NULL AND NEW.costo_centavos IS NOT NULL
     AND (to_jsonb(NEW) - 'costo_centavos' - 'movimiento_id') = (to_jsonb(OLD) - 'costo_centavos' - 'movimiento_id') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: las líneas de una venta no se editan.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.venta_linea FOR EACH ROW EXECUTE FUNCTION interno.proteger_venta_linea();

-- El pago solo se confirma (transferencia) una vez.
CREATE FUNCTION interno.proteger_venta_pago() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c_conf constant text[] := ARRAY['estado_transferencia', 'banco_id', 'referencia_confirmacion', 'fecha_confirmacion',
                                        'asiento_confirmacion_id', 'confirmacion_id_operacion', 'confirmada_por', 'confirmada_en'];
BEGIN
  IF OLD.estado_transferencia = 'por_confirmar' AND NEW.estado_transferencia = 'confirmada'
     AND (to_jsonb(NEW) - c_conf) = (to_jsonb(OLD) - c_conf) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: un pago no se edita; la transferencia se confirma una sola vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.venta_pago FOR EACH ROW EXECUTE FUNCTION interno.proteger_venta_pago();

CREATE FUNCTION interno.proteger_venta_anulacion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF OLD.estado = 'pendiente' AND NEW.estado <> 'pendiente'
     AND (to_jsonb(NEW) - 'estado' - 'resuelto_en') = (to_jsonb(OLD) - 'estado' - 'resuelto_en') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una solicitud de anulación no se edita; se resuelve una sola vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.venta_anulacion FOR EACH ROW EXECUTE FUNCTION interno.proteger_venta_anulacion();

CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.venta           FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.venta_pago      FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.venta_anulacion FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.venta
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las ventas no se borran: se anulan.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.venta_linea
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las ventas no se borran: se anulan.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.venta_pago
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los pagos de una venta no se borran.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.venta_anulacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las solicitudes de anulación no se borran.');

-- ---------------------------------------------------------------------
-- 8) Cálculo de una venta (lo usan la venta y la cotización)
--
-- Por línea, en los términos del precio (con ISV si el precio lo incluye):
--   bruto     = round(cantidad x precio)
--   promoción = la de su categoría (o categoría madre) vigente en la fecha que
--               más descuenta: % -> round(bruto x %), monto -> min(bruto, round(cantidad x monto))
--   artículo  = "descuento_porcentaje" -> round((bruto - promoción) x %), o
--               "descuento_centavos" (monto de la línea, no más que lo que queda)
--   factura   = "porcentaje" -> round(neto de la línea x %), o
--               "monto_centavos" (lo que el cliente deja de pagar, con ISV):
--               se reparte por el total con ISV de cada línea (resto mayor, al
--               centavo exacto) y, si el precio no incluye ISV, se pasa a sin
--               ISV con round(parte / (1 + tasa)) (puede variar ±1 centavo).
--   neto      = bruto - promoción - artículo - factura
-- Después la regla de siempre (public.precio_con_tasa, con la tasa del
-- impuesto de la tabla) sobre el neto de la LÍNEA: base sin impuesto, impuesto y total. Así el ISV se calcula sobre el precio ya
-- rebajado (los descuentos prorrateados bajan el ISV de cada línea).
-- descuento_manual_porcentaje = (artículo + factura, sin ISV) / (precio con
-- promoción, sin ISV) x 100: es lo que se compara con el tope del puesto
-- (las promociones ya las autorizó el admin al crearlas).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.calcular_venta(p_empresa_id uuid, p_fecha date, p_lineas jsonb, p_desc_factura jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l        jsonb;
  i        integer := 0;
  n        integer;
  p        public.producto;
  imp      public.impuesto;
  q        numeric;
  v_pct    numeric;
  v_mto    bigint;
  v_pid    uuid;
  v_dp     bigint;
  v_dl     bigint;
  a_prod   uuid[] := '{}';
  a_nom    text[] := '{}';
  a_q      numeric[] := '{}';
  a_pre    bigint[] := '{}';
  a_inc    boolean[] := '{}';
  a_imp    text[] := '{}';
  a_tasa   numeric[] := '{}';
  a_clase  text[] := '{}';
  a_serv   boolean[] := '{}';
  a_cest   bigint[] := '{}';
  a_promo  uuid[] := '{}';
  a_lpct   numeric[] := '{}';
  a_lmto   bigint[] := '{}';
  a_bruto  bigint[] := '{}';
  a_dpro   bigint[] := '{}';
  a_dlin   bigint[] := '{}';
  a_v2     bigint[] := '{}';
  a_w      bigint[] := '{}';
  a_part   bigint[];
  a_dfac   bigint[];
  v_fpct   numeric;
  v_fmto   bigint;
  v_tot_w  bigint := 0;
  v_v3     bigint;
  s0 bigint; s1 bigint; s3 bigint; i3 bigint; c3 bigint;
  v_out    jsonb := '[]';
  v_desg   jsonb;
  t_sub bigint := 0; t_dpro bigint := 0; t_sin1 bigint := 0; t_base bigint := 0;
  t_grav bigint := 0; t_exe bigint := 0; t_exo bigint := 0; t_imp bigint := 0; t_tot bigint := 0;
BEGIN
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad', 'descuento_porcentaje', 'descuento_centavos']);
  FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, true);
    imp := interno.impuesto_de(p_empresa_id, p.tipo_impuesto);
    q := interno.json_numero(l->'cantidad', 'cantidad', i);
    PERFORM interno.validar_cantidad(p, q, i);
    a_prod := a_prod || p.id;  a_nom := a_nom || p.nombre;  a_q := a_q || q;
    a_pre := a_pre || p.precio_venta_centavos;  a_inc := a_inc || p.precio_incluye_isv;  a_imp := a_imp || p.tipo_impuesto;
    a_tasa := a_tasa || imp.porcentaje;  a_clase := a_clase || imp.clase;  a_serv := a_serv || (p.tipo = 'servicio');
    a_cest := a_cest || CASE WHEN p.tipo = 'servicio' THEN
      (SELECT round(q * sc.costo_estimado_centavos)::bigint FROM public.servicio_costo sc WHERE sc.producto_id = p.id) END;
    a_bruto := a_bruto || round(q * p.precio_venta_centavos)::bigint;

    -- Promoción de la categoría (o de una categoría madre) vigente: la que más descuenta.
    v_pid := NULL; v_dp := NULL;
    SELECT x.id, x.d INTO v_pid, v_dp FROM (
      WITH RECURSIVE cats(id, padre_id, nivel) AS (
        SELECT c.id, c.padre_id, 1 FROM public.categoria_producto c WHERE c.id = p.categoria_id
        UNION ALL
        SELECT c.id, c.padre_id, cats.nivel + 1 FROM public.categoria_producto c JOIN cats ON c.id = cats.padre_id WHERE cats.nivel < 5)
      SELECT pr.id, pr.creado_en,
             CASE pr.tipo WHEN 'porcentaje' THEN round(a_bruto[i] * pr.porcentaje / 100)::bigint
                          ELSE least(a_bruto[i], round(q * pr.monto_centavos)::bigint) END AS d
        FROM public.promocion pr
       WHERE pr.empresa_id = p_empresa_id AND pr.activa AND p_fecha BETWEEN pr.fecha_inicio AND pr.fecha_fin
         AND pr.categoria_id IN (SELECT cats.id FROM cats)) x
     ORDER BY x.d DESC, x.creado_en, x.id
     LIMIT 1;
    a_promo := a_promo || v_pid;
    a_dpro := a_dpro || coalesce(v_dp, 0);

    -- Descuento del artículo (uno solo: porcentaje o monto).
    v_pct := NULL; v_mto := NULL; v_dl := 0;
    IF coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb
       AND coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % trae descuento en porcentaje y en monto; use solo uno.', i;
    END IF;
    IF coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb THEN
      v_pct := interno.json_numero(l->'descuento_porcentaje', 'descuento_porcentaje', i);
      IF v_pct < 0 OR v_pct > 100 OR v_pct <> round(v_pct, 2) THEN
        RAISE EXCEPTION 'LINEA_INVALIDA: el descuento de la línea % va de 0 a 100 %% (hasta 2 decimales).', i;
      END IF;
      v_dl := round((a_bruto[i] - a_dpro[i]) * v_pct / 100)::bigint;
    ELSIF coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      v_mto := interno.json_centavos(l->'descuento_centavos', 'descuento_centavos');
      IF v_mto > a_bruto[i] - a_dpro[i] THEN
        RAISE EXCEPTION 'LINEA_INVALIDA: el descuento de la línea % (% centavos) pasa su precio (% centavos).', i, v_mto, a_bruto[i] - a_dpro[i];
      END IF;
      v_dl := v_mto;
    END IF;
    a_lpct := a_lpct || v_pct;  a_lmto := a_lmto || v_mto;  a_dlin := a_dlin || v_dl;
    a_v2 := a_v2 || (a_bruto[i] - a_dpro[i] - v_dl);
    a_w := a_w || (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_bruto[i] - a_dpro[i] - v_dl, p.precio_incluye_isv, imp.porcentaje, 1) x);
    v_tot_w := v_tot_w + a_w[i];
  END LOOP;
  n := i;

  -- Descuento de factura (uno solo: porcentaje o monto con impuesto).
  a_dfac := array_fill(0::bigint, ARRAY[n]);
  IF p_desc_factura IS NOT NULL AND p_desc_factura <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(p_desc_factura, ARRAY['porcentaje', 'monto_centavos']);
    IF coalesce(p_desc_factura->'porcentaje', 'null'::jsonb) <> 'null'::jsonb
       AND coalesce(p_desc_factura->'monto_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el descuento de factura va en porcentaje o en monto, no los dos.';
    END IF;
    IF coalesce(p_desc_factura->'porcentaje', 'null'::jsonb) <> 'null'::jsonb THEN
      IF jsonb_typeof(p_desc_factura->'porcentaje') <> 'number' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el porcentaje del descuento de factura debe ser un número.';
      END IF;
      v_fpct := (p_desc_factura->>'porcentaje')::numeric;
      IF v_fpct < 0 OR v_fpct > 100 OR v_fpct <> round(v_fpct, 2) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el descuento de factura va de 0 a 100 %% (hasta 2 decimales).';
      END IF;
      FOR i IN 1..n LOOP
        a_dfac[i] := round(a_v2[i] * v_fpct / 100)::bigint;
      END LOOP;
    ELSIF coalesce(p_desc_factura->'monto_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      v_fmto := interno.json_centavos(p_desc_factura->'monto_centavos', 'descuento_factura.monto_centavos');
      IF v_fmto > v_tot_w THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el descuento de factura (%) pasa el total de la venta (%).', interno.lempiras(v_fmto), interno.lempiras(v_tot_w);
      END IF;
      IF v_fmto > 0 THEN
        -- Reparto por el total con impuesto de cada línea; los centavos que sobran van a las de resto mayor.
        SELECT array_agg(y.parte ORDER BY y.k) INTO a_part
          FROM (SELECT x.k, x.base + CASE WHEN row_number() OVER (ORDER BY x.resto DESC, x.k) <= v_fmto - sum(x.base) OVER ()
                                          THEN 1 ELSE 0 END AS parte
                  FROM (SELECT t.k, floor(v_fmto::numeric * t.w / v_tot_w)::bigint AS base,
                               v_fmto::numeric * t.w - floor(v_fmto::numeric * t.w / v_tot_w) * v_tot_w AS resto
                          FROM unnest(a_w) WITH ORDINALITY AS t(w, k)) x) y;
        FOR i IN 1..n LOOP
          a_dfac[i] := least(a_v2[i], CASE WHEN a_inc[i] THEN a_part[i]
                                           ELSE round(a_part[i] / (1 + a_tasa[i] / 100))::bigint END);
        END LOOP;
      END IF;
    END IF;
  END IF;

  -- Impuesto por línea sobre el neto (la regla de public.precio_con_tasa) y totales.
  FOR i IN 1..n LOOP
    v_v3 := a_v2[i] - a_dfac[i];
    SELECT x.sin_isv_centavos INTO s0 FROM public.precio_con_tasa(a_bruto[i], a_inc[i], a_tasa[i], 1) x;
    SELECT x.sin_isv_centavos INTO s1 FROM public.precio_con_tasa(a_bruto[i] - a_dpro[i], a_inc[i], a_tasa[i], 1) x;
    SELECT x.sin_isv_centavos, x.isv_centavos, x.con_isv_centavos INTO s3, i3, c3
      FROM public.precio_con_tasa(v_v3, a_inc[i], a_tasa[i], 1) x;
    v_out := v_out || jsonb_build_object('linea', i, 'producto_id', a_prod[i], 'descripcion', a_nom[i], 'cantidad', a_q[i],
      'precio_unitario_centavos', a_pre[i], 'precio_incluye_isv', a_inc[i], 'tipo_impuesto', a_imp[i],
      'impuesto_porcentaje', a_tasa[i], 'impuesto_clase', a_clase[i], 'es_servicio', a_serv[i],
      'costo_estimado_centavos', a_cest[i],
      'promocion_id', a_promo[i], 'descuento_linea_porcentaje', a_lpct[i], 'descuento_linea_monto_centavos', a_lmto[i],
      'bruto_centavos', a_bruto[i], 'descuento_promocion_precio_centavos', a_dpro[i], 'descuento_linea_centavos', a_dlin[i],
      'descuento_factura_centavos', a_dfac[i], 'neto_centavos', v_v3,
      'subtotal_centavos', s0, 'descuento_promocion_centavos', s0 - s1, 'descuento_centavos', s0 - s3,
      'base_centavos', s3, 'impuesto_centavos', i3, 'total_centavos', c3);
    t_sub := t_sub + s0;  t_dpro := t_dpro + (s0 - s1);  t_sin1 := t_sin1 + s1;  t_base := t_base + s3;
    t_imp := t_imp + i3;  t_tot := t_tot + c3;
    IF a_clase[i] = 'gravado' THEN t_grav := t_grav + s3;
    ELSIF a_clase[i] = 'exonerado' THEN t_exo := t_exo + s3;
    ELSE t_exe := t_exe + s3; END IF;
  END LOOP;

  -- Desglose por impuesto (para el documento y el asiento).
  SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', d.codigo, 'nombre', im.nombre, 'porcentaje', d.porcentaje,
           'clase', d.clase, 'base_centavos', d.base, 'impuesto_centavos', d.impuesto, 'cuenta_por_pagar', im.cuenta_por_pagar)
           ORDER BY im.orden, d.codigo), '[]')
    INTO v_desg
    FROM (SELECT x->>'tipo_impuesto' AS codigo, (x->>'impuesto_porcentaje')::numeric AS porcentaje, x->>'impuesto_clase' AS clase,
                 sum((x->>'base_centavos')::bigint) AS base, sum((x->>'impuesto_centavos')::bigint) AS impuesto
            FROM jsonb_array_elements(v_out) x GROUP BY 1, 2, 3) d
    JOIN public.impuesto im ON im.empresa_id = p_empresa_id AND im.codigo = d.codigo;

  RETURN jsonb_build_object('lineas', v_out,
    'subtotal_centavos', t_sub, 'descuento_centavos', t_sub - t_base, 'descuento_promocion_centavos', t_dpro,
    'descuento_manual_centavos', t_sub - t_base - t_dpro,
    'descuento_manual_porcentaje', CASE WHEN t_sin1 > 0 THEN round((t_sin1 - t_base) * 100.0 / t_sin1, 2) ELSE 0 END,
    'gravado_centavos', t_grav, 'exento_centavos', t_exe, 'exonerado_centavos', t_exo,
    'impuesto_centavos', t_imp, 'total_centavos', t_tot, 'desglose_impuestos', v_desg,
    'tiene_bienes', NOT (true = ALL (a_serv)),
    'descuento_factura_porcentaje', v_fpct, 'descuento_factura_monto_centavos', v_fmto);
END $$;

-- ---------------------------------------------------------------------
-- 9) Ayudantes de la venta
-- ---------------------------------------------------------------------
-- GANCHO para 2b-2b (cobros): lo cobrado vigente (sin cobros anulados) de una
-- venta. Hoy no hay cobros: 0. La etapa de cobros reemplaza estas funciones.
CREATE FUNCTION interno.cobros_vigentes_venta(p_venta_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT 0::bigint
$$;

-- Saldo por cobrar de un cliente (ventas al crédito emitidas - cobros).
CREATE FUNCTION interno.saldo_cxc_cliente(p_empresa_id uuid, p_cliente_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(v.credito_centavos - interno.cobros_vigentes_venta(v.id)), 0)::bigint
    FROM public.venta v
   WHERE v.empresa_id = p_empresa_id AND v.cliente_id = p_cliente_id AND v.estado = 'emitida' AND v.credito_centavos > 0
$$;

-- Total por cobrar de la empresa según el módulo (debe = saldo de 1.1.02.01).
CREATE FUNCTION interno.total_cxc(p_empresa_id uuid) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(v.credito_centavos - interno.cobros_vigentes_venta(v.id)), 0)::bigint
    FROM public.venta v
   WHERE v.empresa_id = p_empresa_id AND v.estado = 'emitida' AND v.credito_centavos > 0
$$;

CREATE FUNCTION interno.venta_respuesta(v public.venta, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('venta_id', v.id, 'numero', v.numero, 'estado', v.estado, 'tipo_documento', v.tipo_documento,
    'numero_documento', v.numero_documento, 'fecha', to_char(v.fecha_contable, 'YYYY-MM-DD'),
    'cliente_id', v.cliente_id, 'cliente', v.cliente_nombre,
    'subtotal_centavos', v.subtotal_centavos, 'descuento_centavos', v.descuento_centavos,
    'descuento_manual_porcentaje', v.descuento_manual_porcentaje, 'impuesto_centavos', v.impuesto_centavos,
    'desglose_impuestos', v.desglose_impuestos,
    'total_centavos', v.total_centavos, 'condicion', v.condicion, 'credito_centavos', v.credito_centavos,
    'vence_el', to_char(v.vence_el, 'YYYY-MM-DD'), 'requiere_aprobacion', to_jsonb(v.requiere_aprobacion),
    'aprobacion_id', v.aprobacion_id, 'asiento_id', v.asiento_id,
    'vuelto_centavos', (SELECT sum(pg.vuelto_centavos) FROM public.venta_pago pg WHERE pg.venta_id = v.id),
    'costo_centavos', v.costo_centavos, 'duplicado', p_duplicado)
$$;

-- Caja de la venta: la indicada; si no, la del turno abierto del usuario;
-- si no, la única caja activa de la empresa.
CREATE FUNCTION interno.caja_de_venta(p_empresa_id uuid, p_valor jsonb) RETURNS public.caja
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
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
  RETURN c;
END $$;

-- Cuenta de dinero de un cobro con tarjeta (POS por liquidar) o
-- transferencia (por confirmar): la indicada, la única activa de ese tipo, o
-- se crea la primera vez.
CREATE FUNCTION interno.cuenta_cobro_venta(p_empresa_id uuid, p_forma text, p_id uuid) RETURNS public.cuenta_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d      public.cuenta_dinero;
  v_tipo text := CASE p_forma WHEN 'tarjeta' THEN 'pos_por_liquidar' ELSE 'transferencia_por_confirmar' END;
  v_n    integer;
  v_id   uuid;
BEGIN
  IF p_id IS NOT NULL THEN
    d := interno.cuenta_dinero_de(p_empresa_id, p_id);
    IF d.tipo <> v_tipo THEN
      RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: un cobro con % entra a una cuenta "%"; "%" es %.', p_forma, v_tipo, d.nombre, d.tipo;
    END IF;
    RETURN d;
  END IF;
  SELECT count(*), min(x.id::text)::uuid INTO v_n, v_id FROM public.cuenta_dinero x
   WHERE x.empresa_id = p_empresa_id AND x.tipo = v_tipo AND x.activa;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: hay % cuentas de %; indique en cuál entra el cobro ("cuenta_dinero_id").', v_n, replace(v_tipo, '_', ' ');
  END IF;
  IF v_n = 1 THEN
    RETURN interno.cuenta_dinero_de(p_empresa_id, v_id);
  END IF;
  RETURN interno.crear_cuenta_dinero_base(p_empresa_id, v_tipo,
    CASE p_forma WHEN 'tarjeta' THEN 'Tarjetas por liquidar (POS)' ELSE 'Transferencias por confirmar' END,
    NULL, NULL, NULL, NULL, NULL, (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id), NULL);
END $$;

-- EMITIR una venta ya guardada (por emitir o recién aprobada): número
-- (factura del régimen fiscal o ticket), salida del kardex a costo promedio, asiento y
-- rastro del dinero. Todo en la transacción de quien llama (que tiene
-- bloquear_libros). Devuelve la venta emitida.
CREATE FUNCTION interno.emitir_venta(p_venta_id uuid, p_fecha date, p_id_operacion uuid) RETURNS public.venta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v      public.venta;
  pg     public.venta_pago;
  ln     public.venta_linea;
  m      public.inventario_movimiento;
  rf     record;
  v_num  text;
  v_reg  text;
  v_fis  jsonb;
  v_cost bigint := 0;
  v_neg  boolean;
  v_lin  jsonb := '[]';
  v_asto uuid;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  PERFORM interno.exigir_periodo_abierto(v.empresa_id, p_fecha);
  IF NOT EXISTS (SELECT 1 FROM public.caja c JOIN public.sucursal s ON s.id = c.sucursal_id
                  WHERE c.id = v.caja_id AND c.activa AND s.activa) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja de la venta está desactivada (ella o su sucursal).';
  END IF;

  -- Formas de pago: la cuenta sigue activa y el efectivo entra al mismo turno con que se registró.
  FOR pg IN SELECT * FROM public.venta_pago x WHERE x.venta_id = v.id ORDER BY x.linea LOOP
    IF pg.forma = 'credito' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'cxc', 'debe', pg.monto_centavos, 'descripcion', 'Venta al crédito: ' || v.cliente_nombre);
      CONTINUE;
    END IF;
    PERFORM interno.cuenta_dinero_de(v.empresa_id, pg.cuenta_dinero_id);
    IF pg.forma = 'efectivo' THEN
      IF pg.turno_id IS NOT NULL AND interno.turno_de_cuenta(pg.cuenta_dinero_id) IS DISTINCT FROM pg.turno_id THEN
        RAISE EXCEPTION 'TURNO_CERRADO: el turno de caja en que se iba a cobrar la venta #% ya se cerró; regístrela otra vez en un turno abierto.', v.numero;
      ELSIF pg.turno_id IS NULL AND interno.turno_de_cuenta(pg.cuenta_dinero_id) IS NOT NULL THEN
        RAISE EXCEPTION 'CAJA_OCUPADA: la caja de la venta #% tiene ahora abierto el turno de un cajero; regístrela otra vez en ese turno.', v.numero;
      ELSIF pg.turno_id IS NULL AND coalesce((SELECT e.turnos_obligatorios FROM public.empresa e WHERE e.id = v.empresa_id), true) THEN
        RAISE EXCEPTION 'SIN_TURNO_ABIERTO: la empresa exige turno de caja para cobrar en efectivo.';
      END IF;
    END IF;
    v_lin := v_lin || jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                                     WHERE d.id = pg.cuenta_dinero_id),
                                         'debe', pg.monto_centavos, 'descripcion', 'Cobro de la venta (' || pg.forma || ')');
  END LOOP;

  -- Número: factura del régimen fiscal activo (en Honduras: rango CAI de ESTA caja) o ticket interno.
  IF v.tipo_documento = 'factura' THEN
    SELECT * INTO rf FROM interno.numero_fiscal(v.empresa_id, v.caja_id, 'factura', p_fecha);
    v_num := rf.o_numero;
    v_fis := rf.o_datos;
    v_reg := v_fis->>'regimen';
  ELSE
    v_num := interno.siguiente_ticket(v.empresa_id, v.caja_id);
  END IF;

  -- Salida del kardex a costo promedio (política de existencia negativa de
  -- siempre). Los servicios no tocan el kardex (costo 0 en los libros).
  v_neg := interno.permite_negativo(v.empresa_id);
  FOR ln IN SELECT * FROM public.venta_linea x WHERE x.venta_id = v.id ORDER BY x.linea LOOP
    IF ln.es_servicio THEN
      UPDATE public.venta_linea SET costo_centavos = 0 WHERE id = ln.id;
      CONTINUE;
    END IF;
    m := interno.mover_inventario(v.empresa_id, v.bodega_id, ln.producto_id, 'salida', 'venta', p_fecha, -ln.cantidad, NULL,
                                  'venta', v.id, p_id_operacion, 'Venta ' || v_num, v_neg);
    UPDATE public.venta_linea SET costo_centavos = -m.valor_centavos, movimiento_id = m.id WHERE id = ln.id;
    v_cost := v_cost - m.valor_centavos;
  END LOOP;

  v_lin := v_lin || jsonb_build_array(
    jsonb_build_object('uso', 'descuento_ventas', 'debe',  v.descuento_centavos, 'descripcion', 'Descuentos sobre ventas'),
    jsonb_build_object('uso', 'ventas',           'haber', v.subtotal_centavos,  'descripcion', 'Ventas (precio sin impuesto)'),
    jsonb_build_object('uso', 'costo_ventas',     'debe',  v_cost,               'descripcion', 'Costo de lo vendido'),
    jsonb_build_object('uso', 'inventario',       'haber', v_cost,               'descripcion', 'Salida de inventario por venta'));
  -- Cada impuesto gravado a SU cuenta por pagar (tabla de impuestos).
  v_lin := v_lin || coalesce((SELECT jsonb_agg(jsonb_build_object('cuenta', d->>'cuenta_por_pagar',
                                 'haber', (d->>'impuesto_centavos')::bigint, 'descripcion', 'Impuesto ' || (d->>'nombre')))
                                FROM jsonb_array_elements(v.desglose_impuestos) d
                               WHERE (d->>'impuesto_centavos')::bigint > 0), '[]');
  v_asto := interno.asiento_sistema(v.empresa_id, interno.sucursal_activa(v.sucursal_id), p_fecha,
    'Venta ' || v.tipo_documento || ' ' || v_num || ' a ' || v.cliente_nombre, 'venta', p_id_operacion, v_lin);

  UPDATE public.venta
     SET estado = 'emitida', fecha_contable = p_fecha, numero_documento = v_num, regimen_fiscal = v_reg, datos_fiscales = v_fis,
         vence_el = CASE WHEN v.credito_centavos > 0 THEN p_fecha + v.plazo_dias END,
         asiento_id = v_asto, costo_centavos = v_cost, emitida_en = now(), emitida_por = auth.uid()
   WHERE id = v.id
  RETURNING * INTO v;
  PERFORM interno.rastrear_dinero(v_asto, 'venta', 'venta', v.id, v_num, v.equipo);
  RETURN v;
END $$;

-- Número de un ticket interno (sin régimen fiscal): correlativo propio de
-- la caja: T-001-001-00000001 (establecimiento y punto de emisión de la caja).
CREATE FUNCTION interno.siguiente_ticket(p_empresa_id uuid, p_caja_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_n   bigint := interno.siguiente_numero(p_empresa_id, 'ticket:' || p_caja_id);
  v_pre text;
BEGIN
  SELECT s.codigo || '-' || c.punto_emision INTO v_pre
    FROM public.caja c JOIN public.sucursal s ON s.id = c.sucursal_id WHERE c.id = p_caja_id;
  RETURN 'T-' || v_pre || '-' || lpad(v_n::text, 8, '0');
END $$;

-- REGISTRAR una venta (la usan registrar_venta y convertir_cotizacion_a_venta).
-- datos = {"lineas":[{"producto_id":"...","cantidad":2,"descuento_porcentaje":5}],
--          "pagos":[{"forma":"efectivo","monto_centavos":10000,"recibido_centavos":20000},
--                   {"forma":"tarjeta","monto_centavos":5000,"referencia":"Voucher 123"},
--                   {"forma":"transferencia","monto_centavos":5000,"referencia":"..."},
--                   {"forma":"credito","monto_centavos":3000}],
--          "cliente_id":"..." (sin cliente = Consumidor final), "caja_id":"...", "bodega_id":"...",
--          "fecha":"2026-01-15" (defecto hoy), "tipo_documento":"factura"|"ticket",
--          "descuento_factura":{"porcentaje":5} o {"monto_centavos":1000}, "vendedor_id":"...",
--          "nota":"...", "equipo":"Caja 1"}
-- Un solo pago sin "monto_centavos" = el total. p_calculo: líneas ya calculadas
-- (cotización con precios respetados).
CREATE FUNCTION interno.registrar_venta_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_cotizacion_id uuid DEFAULT NULL, p_calculo jsonb DEFAULT NULL)
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
  v_ncred  integer := 0;
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
  IF NOT public.modulo_esta_activo(p_empresa_id, 'inventario') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo para esta empresa (ahí vive el catálogo de productos y servicios).';
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;

  -- Caja y fecha (la bodega, después del cálculo: solo si hay bienes).
  v_caja := interno.caja_de_venta(p_empresa_id, p_datos->'caja_id');
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  -- Documento: sin régimen fiscal activo, siempre ticket interno; con
  -- régimen (fiscal_hn), según lo que el dueño configuró.
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

  -- Cliente (opcional) y vendedor.
  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    SELECT * INTO v_cli FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_datos->'cliente_id', 'cliente_id') AND t.empresa_id = p_empresa_id;
    IF v_cli.id IS NULL OR NOT v_cli.es_cliente OR NOT v_cli.activo THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente no existe, no está marcado como cliente o está desactivado.';
    END IF;
  END IF;
  v_vend := coalesce(interno.json_uuid(p_datos->'vendedor_id', 'vendedor_id'), auth.uid());
  IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = v_vend
                   AND ue.activo AND ue.rol NOT IN ('proveedor', 'contador')) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el vendedor no es un usuario activo de la empresa.';
  END IF;

  -- Cálculo (o el de la cotización con precios respetados).
  v_calc := coalesce(p_calculo, interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura'));
  v_total := (v_calc->>'total_centavos')::bigint;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el total de la venta debe ser mayor que cero.';
  END IF;
  -- Bodega: solo si se venden bienes (los servicios no tienen existencia).
  IF coalesce(p_datos->'bodega_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_bod := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  ELSIF coalesce((v_calc->>'tiene_bienes')::boolean, true) THEN
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa; cree una o indique "bodega_id".';
    END IF;
  END IF;

  -- Formas de pago (estructura): la suma debe ser el total exacto.
  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia o crédito).';
  END IF;
  IF jsonb_array_length(p_datos->'pagos') > 10 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 10 formas de pago por venta.';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    k := k + 1;
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    PERFORM interno.exigir_claves(pj, ARRAY['forma', 'monto_centavos', 'cuenta_dinero_id', 'referencia', 'recibido_centavos']);
    v_forma := interno.json_texto(pj->'forma', 'forma', 20);
    IF coalesce(v_forma, '') NOT IN ('efectivo', 'tarjeta', 'transferencia', 'credito') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago es efectivo, tarjeta, transferencia o credito.';
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
    IF v_forma IN ('efectivo', 'credito') AND coalesce(pj->'cuenta_dinero_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: en % no se indica cuenta (el efectivo entra a la caja de la venta).', v_forma;
    END IF;
    IF v_forma = 'credito' THEN
      v_ncred := v_ncred + 1;
      v_cred := v_cred + v_monto;
    END IF;
    v_suma := v_suma + v_monto;
    v_norm := v_norm || jsonb_build_object('linea', k, 'forma', v_forma, 'monto', v_monto, 'recibido', v_rec,
      'cuenta', interno.json_uuid(pj->'cuenta_dinero_id', 'cuenta_dinero_id'), 'referencia', interno.json_texto(pj->'referencia', 'referencia', 100));
  END LOOP;
  IF v_ncred > 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el crédito va en una sola forma de pago.';
  END IF;
  IF v_suma <> v_total THEN
    RAISE EXCEPTION 'PAGO_NO_CUADRA: las formas de pago suman % y el total de la venta es % (diferencia %).',
      interno.lempiras(v_suma), interno.lempiras(v_total), interno.lempiras(v_suma - v_total);
  END IF;
  IF v_cred > 0 AND v_cli.id IS NULL THEN
    RAISE EXCEPTION 'CLIENTE_REQUERIDO: una venta al crédito necesita cliente (no puede ser Consumidor final).';
  END IF;
  IF v_suma > v_cred AND NOT public.tiene_permiso('ventas.cobrar', p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.cobrar"; haga una cotización y el cajero la cobra.';
  END IF;
  IF v_suma > v_cred AND NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa (el cobro entra a una cuenta de dinero).';
  END IF;

  -- Candado, reintento y número.
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'venta');
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;

  -- ¿Necesita aprobación? (el dueño no tiene topes)
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    IF (v_calc->>'descuento_manual_porcentaje')::numeric > v_td.sin_aprobacion THEN
      v_req := v_req || 'descuento'::text;
      v_desc := 'descuento de ' || (v_calc->>'descuento_manual_porcentaje') || ' % (su tope: ' || v_td.sin_aprobacion || ' %)';
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
    estado, requiere_aprobacion, aprobacion_id, nota, equipo, id_operacion, creado_por)
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
    interno.json_texto(p_datos->'nota', 'nota', 500), interno.equipo(p_datos), p_id_operacion, auth.uid())
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

  -- Cuentas de dinero de cada pago (con el candado: se pueden crear la primera vez).
  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    d := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(p_empresa_id, v_caja.id);
    ELSIF pj->>'forma' IN ('tarjeta', 'transferencia') THEN
      d := interno.cuenta_cobro_venta(p_empresa_id, pj->>'forma', (pj->>'cuenta')::uuid);
    END IF;
    INSERT INTO public.venta_pago (empresa_id, venta_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos, estado_transferencia)
    VALUES (p_empresa_id, v.id, (pj->>'linea')::smallint, pj->>'forma', (pj->>'monto')::bigint, d.id,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta(d.id) END, pj->>'referencia',
            (pj->>'recibido')::bigint, (pj->>'recibido')::bigint - (pj->>'monto')::bigint,
            CASE WHEN pj->>'forma' = 'transferencia' THEN 'por_confirmar' END);
  END LOOP;

  IF v.estado = 'por_emitir' THEN
    v := interno.emitir_venta(v.id, v_fecha, p_id_operacion);
  END IF;
  RETURN interno.venta_respuesta(v, false);
END $$;

-- ---------------------------------------------------------------------
-- 10) RPC de ventas
-- ---------------------------------------------------------------------
-- registrar_venta(empresa, datos, id_operacion)   ventas.vender (+ ventas.cobrar si entra dinero)
CREATE FUNCTION public.registrar_venta(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'ventas.vender', 'ventas');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'venta');
  RETURN interno.ocultar_costos(p_empresa_id, interno.registrar_venta_base(p_empresa_id, p_datos, p_id_operacion),
                                ARRAY['costo_centavos']);
END $$;

-- cancelar_venta(venta, motivo, id_operacion): una venta PENDIENTE de
-- aprobación se cancela (no movió nada). Quien la registró (ventas.vender) o
-- quien aprueba (ventas.aprobar).
CREATE FUNCTION public.cancelar_venta(p_venta_id uuid, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.venta;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la venta no existe.';
  END IF;
  IF v.creado_por = auth.uid() THEN
    PERFORM interno.exigir_escritura(v.empresa_id, 'ventas.vender', 'ventas');
  ELSE
    PERFORM interno.exigir_escritura(v.empresa_id, 'ventas.aprobar', 'ventas');
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v.empresa_id, p_id_operacion, 'cancelacion_venta');
  IF v.cancelacion_id_operacion = p_id_operacion THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se cancela (mínimo 5 letras).';
  END IF;
  PERFORM interno.reservar_operacion(v.empresa_id, p_id_operacion, 'cancelacion_venta');
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  IF v.cancelacion_id_operacion = p_id_operacion THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;
  IF v.estado <> 'pendiente_aprobacion' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: solo se cancela una venta pendiente de aprobación (esta está %); una emitida se anula.', v.estado;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.aprobacion SET estado = 'cancelada', resuelto_por = auth.uid(), rol_resolutor = public.mi_rol(v.empresa_id),
         resuelto_en = now(), motivo_resolucion = trim(p_motivo), resolucion_id_operacion = p_id_operacion
   WHERE id = v.aprobacion_id AND estado = 'pendiente';
  UPDATE public.venta SET estado = 'cancelada', cancelada_en = now(), cancelada_por = auth.uid(),
         motivo_cancelacion = trim(p_motivo), cancelacion_id_operacion = p_id_operacion
   WHERE id = v.id
  RETURNING * INTO v;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.venta_respuesta(v, false);
END $$;

-- solicitar_anulacion_venta(venta, motivo, id_operacion)   ventas.solicitar_anulacion
-- El vendedor (o quien sea) SOLO pide; la anulación la aprueba admin o dueño
-- con resolver_aprobacion. Solo ventas emitidas, de un mes abierto y sin cobros.
CREATE FUNCTION public.solicitar_anulacion_venta(p_venta_id uuid, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v     public.venta;
  s     public.venta_anulacion;
  v_apr uuid := gen_random_uuid();
  v_est text;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la venta no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v.empresa_id, 'ventas.solicitar_anulacion', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v.empresa_id, p_id_operacion, 'solicitar_anulacion_venta');
  SELECT * INTO s FROM public.venta_anulacion x WHERE x.empresa_id = v.empresa_id AND x.id_operacion = p_id_operacion;
  IF s.id IS NOT NULL THEN
    RETURN jsonb_build_object('solicitud_id', s.id, 'aprobacion_id', s.aprobacion_id, 'venta_id', s.venta_id, 'estado', s.estado,
                              'duplicado', true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se debe anular la venta (mínimo 5 letras).';
  END IF;
  PERFORM interno.reservar_operacion(v.empresa_id, p_id_operacion, 'solicitar_anulacion_venta');
  SELECT * INTO s FROM public.venta_anulacion x WHERE x.empresa_id = v.empresa_id AND x.id_operacion = p_id_operacion;
  IF s.id IS NOT NULL THEN
    RETURN jsonb_build_object('solicitud_id', s.id, 'aprobacion_id', s.aprobacion_id, 'venta_id', s.venta_id, 'estado', s.estado,
                              'duplicado', true);
  END IF;
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  IF v.estado = 'anulada' THEN
    RAISE EXCEPTION 'YA_ANULADO: la venta % ya está anulada.', v.numero_documento;
  END IF;
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: solo se anula una venta emitida (esta está %).', v.estado;
  END IF;
  SELECT p.estado INTO v_est FROM public.periodo p
   WHERE p.empresa_id = v.empresa_id AND p.anio = extract(year FROM v.fecha_contable) AND p.mes = extract(month FROM v.fecha_contable);
  IF v_est = 'cerrado' THEN
    RAISE EXCEPTION 'PERIODO_CERRADO: la venta % es de un mes cerrado (%); ya no se anula (se corregirá con una nota de crédito).',
      v.numero_documento, to_char(v.fecha_contable, 'MM/YYYY');
  END IF;
  IF interno.cobros_vigentes_venta(v.id) > 0 THEN
    RAISE EXCEPTION 'VENTA_CON_COBROS: la venta % tiene cobros; anúlelos primero.', v.numero_documento;
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta_anulacion x WHERE x.venta_id = v.id AND x.estado = 'pendiente') THEN
    RAISE EXCEPTION 'YA_EXISTE: la venta % ya tiene una solicitud de anulación pendiente.', v.numero_documento;
  END IF;
  s.id := gen_random_uuid();
  INSERT INTO public.aprobacion (id, empresa_id, numero, tipo, documento_tipo, documento_id, monto_centavos, descripcion,
                                 solicitado_por, rol_solicitante)
  VALUES (v_apr, v.empresa_id, interno.siguiente_numero(v.empresa_id, 'aprobacion'), 'anulacion_venta', 'venta_anulacion', s.id,
          v.total_centavos, 'Anular la venta ' || v.numero_documento || ' (' || v.cliente_nombre || ', ' || interno.lempiras(v.total_centavos)
          || '): ' || trim(p_motivo), auth.uid(), public.mi_rol(v.empresa_id));
  INSERT INTO public.venta_anulacion (id, empresa_id, venta_id, motivo, aprobacion_id, id_operacion, solicitado_por)
  VALUES (s.id, v.empresa_id, v.id, trim(p_motivo), v_apr, p_id_operacion, auth.uid())
  RETURNING * INTO s;
  RETURN jsonb_build_object('solicitud_id', s.id, 'aprobacion_id', s.aprobacion_id, 'venta_id', s.venta_id, 'estado', s.estado,
                            'duplicado', false);
END $$;

-- Anula una venta emitida (quien llama ya resolvió la aprobación y tiene el
-- candado): devuelve la mercadería a lo que costó, contra-asiento enlazado al
-- original, el dinero sale de la MISMA cuenta a la que entró (una
-- transferencia ya confirmada, del banco donde quedó) y la CxC se revierte.
CREATE FUNCTION interno.anular_venta_base(p_venta_id uuid, p_fecha date, p_motivo text, p_id_operacion uuid,
                                          p_solicitud_id uuid) RETURNS public.venta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v      public.venta;
  ln     public.venta_linea;
  pg     public.venta_pago;
  v_lin  jsonb := '[]';
  v_asto uuid;
  v_cta  uuid;
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
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
    ELSE
      v_cta := CASE WHEN pg.estado_transferencia = 'confirmada' THEN pg.banco_id ELSE pg.cuenta_dinero_id END;
      v_lin := v_lin || jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                                       WHERE d.id = v_cta),
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
  UPDATE public.venta
     SET estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = p_motivo, fecha_anulacion = p_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion, anulacion_solicitud_id = p_solicitud_id
   WHERE id = v.id
  RETURNING * INTO v;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_venta', 'venta', v.id, p_motivo, NULL);
  RETURN v;
END $$;

-- confirmar_transferencia_venta(pago, datos, id_operacion)   dinero.trasladar
-- datos = {"banco_id":"<cuenta de dinero banco>","referencia":"TRF-55821","fecha":"2026-01-16","equipo":"..."}
-- El banco ya tiene la transferencia: Dr banco / Cr Transferencias por confirmar. Una vez.
CREATE FUNCTION public.confirmar_transferencia_venta(p_venta_pago_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  pg      public.venta_pago;
  v       public.venta;
  b       public.cuenta_dinero;
  v_ref   text;
  v_fecha date;
  v_asto  uuid;
BEGIN
  SELECT * INTO pg FROM public.venta_pago WHERE id = p_venta_pago_id;
  IF pg.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el pago no existe.';
  END IF;
  SELECT * INTO v FROM public.venta WHERE id = pg.venta_id;
  PERFORM interno.exigir_escritura(v.empresa_id, 'dinero.trasladar', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(v.empresa_id, p_id_operacion, 'confirmacion_transferencia');
  IF pg.confirmacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('venta_pago_id', pg.id, 'estado_transferencia', pg.estado_transferencia,
                              'asiento_id', pg.asiento_confirmacion_id, 'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['banco_id', 'referencia', 'fecha', 'equipo']);
  IF pg.forma <> 'transferencia' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: solo se confirman pagos por transferencia.';
  END IF;
  b := interno.cuenta_dinero_de(v.empresa_id, interno.json_uuid(p_datos->'banco_id', 'banco_id'));
  IF b.tipo <> 'banco' THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la transferencia se confirma en una cuenta de banco ("%" es %).', b.nombre, b.tipo;
  END IF;
  v_ref := interno.json_texto(p_datos->'referencia', 'referencia', 100);
  IF length(coalesce(v_ref, '')) < 3 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba la referencia de la transferencia que aparece en el banco (mínimo 3 letras o números).';
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), greatest(public.hoy_local(v.empresa_id), v.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v.empresa_id, v_fecha);
  IF v_fecha < v.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la confirmación no puede tener fecha anterior a la venta (%).', to_char(v.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(v.empresa_id, p_id_operacion, 'confirmacion_transferencia');
  SELECT * INTO pg FROM public.venta_pago WHERE id = p_venta_pago_id FOR UPDATE;
  SELECT * INTO v FROM public.venta WHERE id = pg.venta_id FOR UPDATE;
  IF pg.confirmacion_id_operacion = p_id_operacion THEN
    RETURN jsonb_build_object('venta_pago_id', pg.id, 'estado_transferencia', pg.estado_transferencia,
                              'asiento_id', pg.asiento_confirmacion_id, 'duplicado', true);
  END IF;
  IF v.estado = 'anulada' THEN
    RAISE EXCEPTION 'YA_ANULADO: la venta % está anulada.', v.numero_documento;
  END IF;
  IF v.estado <> 'emitida' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la venta todavía no está emitida (está %).', v.estado;
  END IF;
  IF pg.estado_transferencia = 'confirmada' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la transferencia ya fue confirmada (%).', pg.referencia_confirmacion;
  END IF;
  PERFORM interno.exigir_periodo_abierto(v.empresa_id, v_fecha);
  v_asto := interno.asiento_sistema(v.empresa_id, interno.sucursal_activa(v.sucursal_id), v_fecha,
    'Confirmación de transferencia de la venta ' || v.numero_documento || ' en ' || b.nombre || ' ref. ' || v_ref,
    'confirmacion_transferencia', p_id_operacion,
    jsonb_build_array(
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = b.cuenta_id), 'debe', pg.monto_centavos),
      jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                     WHERE d.id = pg.cuenta_dinero_id), 'haber', pg.monto_centavos)));
  UPDATE public.venta_pago
     SET estado_transferencia = 'confirmada', banco_id = b.id, referencia_confirmacion = v_ref, fecha_confirmacion = v_fecha,
         asiento_confirmacion_id = v_asto, confirmacion_id_operacion = p_id_operacion, confirmada_por = auth.uid(), confirmada_en = now()
   WHERE id = pg.id
  RETURNING * INTO pg;
  PERFORM interno.rastrear_dinero(v_asto, 'confirmacion_transferencia', 'venta', v.id, v_ref, interno.equipo(p_datos));
  RETURN jsonb_build_object('venta_pago_id', pg.id, 'estado_transferencia', pg.estado_transferencia, 'asiento_id', v_asto,
                            'banco', b.nombre, 'saldo_banco_centavos', interno.saldo_dinero(b.id), 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 11) resolver_aprobacion (reemplaza la de 024; misma firma). Despacha por
--     tipo: gasto, venta (descuento y/o crédito) y anulacion_venta. Igual
--     para todos: permiso del tipo, tope del puesto (el dueño sin tope),
--     nadie resuelve lo que pidió (salvo el dueño), rechazo con motivo, una
--     sola vez y la DOBLE aprobación si la empresa la tiene.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.resolver_aprobacion_gasto(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                  p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.aprobacion;
  g       public.gasto;
  v_rol   text;
  v_tope  record;
  v_fecha date;
  v_asto  uuid;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  PERFORM interno.exigir_escritura(a.empresa_id, 'gastos.aprobar', 'dinero');
  v_rol := public.mi_rol(a.empresa_id);
  IF p_aprobar IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si aprueba (true) o rechaza (false).';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    SELECT * INTO g FROM public.gasto WHERE id = a.documento_id;
    RETURN interno.gasto_respuesta(g, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF NOT p_aprobar AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se rechaza (mínimo 5 letras).';
  END IF;
  IF a.solicitado_por = auth.uid() AND v_rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede aprobar ni rechazar su propia solicitud; lo hace otra persona con permiso o el dueño.';
  END IF;
  SELECT * INTO v_tope FROM interno.tope_rol(a.empresa_id, v_rol, 'gasto');
  IF p_aprobar AND v_rol <> 'dueno' AND a.monto_centavos > v_tope.aprueba_hasta THEN
    RAISE EXCEPTION 'TOPE_APROBACION: el gasto es de % y usted aprueba hasta %; pídale al dueño que lo apruebe.',
      interno.lempiras(a.monto_centavos), interno.lempiras(v_tope.aprueba_hasta);
  END IF;
  SELECT * INTO g FROM public.gasto WHERE id = a.documento_id;
  v_fecha := coalesce(p_fecha, g.fecha_contable);
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_fecha < g.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la fecha del gasto aprobado no puede ser anterior a la de la solicitud (%).', to_char(g.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id FOR UPDATE;
  SELECT * INTO g FROM public.gasto WHERE id = a.documento_id FOR UPDATE;
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.gasto_respuesta(g, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF a.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la solicitud #% ya está %.', a.numero, a.estado;
  END IF;
  IF a.primera_aprobacion_por = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: usted ya dio la primera aprobación; la segunda la da otra persona (o el dueño).';
  END IF;
  -- Doble aprobación: la primera solo se anota.
  IF p_aprobar AND NOT interno.paso_aprobacion(a, v_rol, p_motivo, p_id_operacion) THEN
    SELECT * INTO a FROM public.aprobacion WHERE id = a.id;
    RETURN interno.gasto_respuesta(g, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', true);
  END IF;

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  UPDATE public.aprobacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_por = auth.uid(),
         rol_resolutor = v_rol, resuelto_en = now(), motivo_resolucion = nullif(trim(p_motivo), ''),
         resolucion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  IF p_aprobar THEN
    g.fecha_contable := v_fecha;
    v_asto := interno.aplicar_gasto(g, v_fecha, p_id_operacion);
    UPDATE public.gasto SET estado = 'aplicado', fecha_contable = v_fecha, asiento_id = v_asto, aplicado_en = now(),
           aplicado_por = auth.uid()
     WHERE id = g.id;
  ELSE
    UPDATE public.gasto SET estado = 'rechazado' WHERE id = g.id;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  SELECT * INTO g FROM public.gasto WHERE id = g.id;
  RETURN interno.gasto_respuesta(g, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
    'falta_segunda_aprobacion', false);
END $$;

-- Venta con descuento sobre el tope y/o crédito: aprobar la EMITE en ese
-- momento (número CAI, kardex, asiento y rastro) con la fecha de hoy (o
-- p_fecha); rechazar la deja "rechazada" sin mover nada.
CREATE FUNCTION interno.resolver_aprobacion_venta(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                  p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.aprobacion;
  v       public.venta;
  v_rol   text;
  v_td    record;
  v_tope  record;
  v_fecha date;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  SELECT * INTO v FROM public.venta WHERE id = a.documento_id;
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
    RETURN interno.venta_respuesta(v, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF NOT p_aprobar AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se rechaza (mínimo 5 letras).';
  END IF;
  IF a.solicitado_por = auth.uid() AND v_rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede aprobar ni rechazar su propia solicitud; lo hace otra persona con permiso o el dueño.';
  END IF;
  IF p_aprobar AND v_rol <> 'dueno' THEN
    IF 'descuento' = ANY (v.requiere_aprobacion) THEN
      SELECT * INTO v_td FROM interno.tope_descuento(a.empresa_id, v_rol);
      IF v.descuento_manual_porcentaje > v_td.aprueba_hasta THEN
        RAISE EXCEPTION 'TOPE_APROBACION: el descuento es de % %% y usted aprueba hasta % %%; pídale al dueño que lo apruebe.',
          v.descuento_manual_porcentaje, v_td.aprueba_hasta;
      END IF;
    END IF;
    IF 'credito' = ANY (v.requiere_aprobacion) THEN
      SELECT * INTO v_tope FROM interno.tope_rol(a.empresa_id, v_rol, 'credito');
      IF v.credito_centavos > v_tope.aprueba_hasta THEN
        RAISE EXCEPTION 'TOPE_APROBACION: el crédito es de % y usted aprueba hasta %; pídale al dueño que lo apruebe.',
          interno.lempiras(v.credito_centavos), interno.lempiras(v_tope.aprueba_hasta);
      END IF;
    END IF;
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(a.empresa_id), v.fecha_contable));
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_fecha < v.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la venta aprobada no puede tener fecha anterior a la solicitud (%).', to_char(v.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id FOR UPDATE;
  SELECT * INTO v FROM public.venta WHERE id = a.documento_id FOR UPDATE;
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.venta_respuesta(v, true) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF a.estado <> 'pendiente' OR v.estado <> 'pendiente_aprobacion' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la solicitud #% ya está % (venta %).', a.numero, a.estado, v.estado;
  END IF;
  IF a.primera_aprobacion_por = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: usted ya dio la primera aprobación; la segunda la da otra persona (o el dueño).';
  END IF;
  IF p_aprobar AND NOT interno.paso_aprobacion(a, v_rol, p_motivo, p_id_operacion) THEN
    SELECT * INTO a FROM public.aprobacion WHERE id = a.id;
    RETURN interno.venta_respuesta(v, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
      'falta_segunda_aprobacion', true);
  END IF;

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  UPDATE public.aprobacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_por = auth.uid(),
         rol_resolutor = v_rol, resuelto_en = now(), motivo_resolucion = nullif(trim(p_motivo), ''),
         resolucion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  IF p_aprobar THEN
    v := interno.emitir_venta(v.id, v_fecha, p_id_operacion);
  ELSE
    UPDATE public.venta SET estado = 'rechazada' WHERE id = v.id RETURNING * INTO v;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.venta_respuesta(v, false) || jsonb_build_object('aprobacion_id', a.id, 'aprobacion_estado', a.estado,
    'falta_segunda_aprobacion', false);
END $$;

-- Anulación de venta: aprobar ANULA (motivo obligatorio también al aprobar).
CREATE FUNCTION interno.resolver_anulacion_venta(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                 p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.aprobacion;
  s       public.venta_anulacion;
  v       public.venta;
  v_rol   text;
  v_tope  record;
  v_fecha date;
  v_est   text;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  SELECT * INTO s FROM public.venta_anulacion WHERE id = a.documento_id;
  SELECT * INTO v FROM public.venta WHERE id = s.venta_id;
  PERFORM interno.exigir_escritura(a.empresa_id, 'ventas.anular', 'ventas');
  v_rol := public.mi_rol(a.empresa_id);
  IF p_aprobar IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si aprueba (true) o rechaza (false).';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.venta_respuesta(v, true) || jsonb_build_object('solicitud_id', s.id, 'aprobacion_id', a.id,
      'aprobacion_estado', a.estado, 'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de su decisión (mínimo 5 letras).';
  END IF;
  IF a.solicitado_por = auth.uid() AND v_rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede aprobar ni rechazar su propia solicitud; lo hace otra persona con permiso o el dueño.';
  END IF;
  SELECT * INTO v_tope FROM interno.tope_rol(a.empresa_id, v_rol, 'anulacion_venta');
  IF p_aprobar AND v_rol <> 'dueno' AND v.total_centavos > v_tope.aprueba_hasta THEN
    RAISE EXCEPTION 'TOPE_APROBACION: la venta es de % y usted aprueba anulaciones hasta %; pídale al dueño que la apruebe.',
      interno.lempiras(v.total_centavos), interno.lempiras(v_tope.aprueba_hasta);
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(a.empresa_id), v.fecha_contable));
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_fecha < v.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior a la venta (%).', to_char(v.fecha_contable, 'DD/MM/YYYY');
  END IF;
  IF p_aprobar THEN
    SELECT p.estado INTO v_est FROM public.periodo p
     WHERE p.empresa_id = v.empresa_id AND p.anio = extract(year FROM v.fecha_contable) AND p.mes = extract(month FROM v.fecha_contable);
    IF v_est = 'cerrado' THEN
      RAISE EXCEPTION 'PERIODO_CERRADO: la venta % es de un mes cerrado (%); ya no se anula (se corregirá con una nota de crédito).',
        v.numero_documento, to_char(v.fecha_contable, 'MM/YYYY');
    END IF;
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'resolver_aprobacion');
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id FOR UPDATE;
  SELECT * INTO s FROM public.venta_anulacion WHERE id = a.documento_id FOR UPDATE;
  SELECT * INTO v FROM public.venta WHERE id = s.venta_id FOR UPDATE;
  IF a.resolucion_id_operacion = p_id_operacion OR a.primera_id_operacion = p_id_operacion THEN
    RETURN interno.venta_respuesta(v, true) || jsonb_build_object('solicitud_id', s.id, 'aprobacion_id', a.id,
      'aprobacion_estado', a.estado, 'falta_segunda_aprobacion', a.estado = 'pendiente' AND a.primera_aprobacion_por IS NOT NULL);
  END IF;
  IF a.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la solicitud #% ya está %.', a.numero, a.estado;
  END IF;
  IF a.primera_aprobacion_por = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: usted ya dio la primera aprobación; la segunda la da otra persona (o el dueño).';
  END IF;
  IF p_aprobar THEN
    IF v.estado = 'anulada' THEN
      RAISE EXCEPTION 'YA_ANULADO: la venta % ya está anulada.', v.numero_documento;
    END IF;
    IF interno.cobros_vigentes_venta(v.id) > 0 THEN
      RAISE EXCEPTION 'VENTA_CON_COBROS: la venta % tiene cobros; anúlelos primero.', v.numero_documento;
    END IF;
    IF NOT interno.paso_aprobacion(a, v_rol, p_motivo, p_id_operacion) THEN
      SELECT * INTO a FROM public.aprobacion WHERE id = a.id;
      RETURN interno.venta_respuesta(v, false) || jsonb_build_object('solicitud_id', s.id, 'aprobacion_id', a.id,
        'aprobacion_estado', a.estado, 'falta_segunda_aprobacion', true);
    END IF;
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.aprobacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_por = auth.uid(),
         rol_resolutor = v_rol, resuelto_en = now(), motivo_resolucion = trim(p_motivo), resolucion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  UPDATE public.venta_anulacion SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END, resuelto_en = now()
   WHERE id = s.id;
  PERFORM set_config('app.motivo', '', true);
  IF p_aprobar THEN
    v := interno.anular_venta_base(v.id, v_fecha, s.motivo, p_id_operacion, s.id);
  END IF;
  RETURN interno.venta_respuesta(v, false) || jsonb_build_object('solicitud_id', s.id, 'aprobacion_id', a.id,
    'aprobacion_estado', a.estado, 'falta_segunda_aprobacion', false);
END $$;

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
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_aprobacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  ELSIF a.tipo = 'anulacion_venta' THEN
    RETURN interno.ocultar_costos(a.empresa_id,
      interno.resolver_anulacion_venta(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha), ARRAY['costo_centavos']);
  END IF;
  RAISE EXCEPTION 'NO_PERMITIDO: este tipo de aprobación (%) todavía no se resuelve aquí.', a.tipo;
END $$;

-- ---------------------------------------------------------------------
-- 12) configurar_empresa (reemplaza la de 025; misma firma). Claves nuevas
--     (solo el dueño): credito_politica, documento_venta_modo,
--     cai_dias_alerta, cai_porcentaje_alerta, leyenda_factura,
--     cotizacion_dias_vigencia, cotizacion_precios, permite_servicios.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.configurar_empresa(p_empresa_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k     text;
  v_emp public.empresa;
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
                 'cotizacion_dias_vigencia', 'cotizacion_precios', 'permite_servicios') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'tope_credito_centavos' AND NOT (jsonb_typeof(p_datos->'tope_credito_centavos') = 'number'
       AND (p_datos->>'tope_credito_centavos') ~ '^[0-9]{1,16}$'
       AND (p_datos->>'tope_credito_centavos')::numeric <= 9007199254740991) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "tope_credito_centavos" debe ser un entero de centavos, 0 o más.';
  END IF;
  FOREACH k IN ARRAY ARRAY['permite_existencia_negativa', 'precio_incluye_isv_defecto', 'turnos_obligatorios',
                           'contabilidad_visible', 'doble_aprobacion', 'permite_servicios'] LOOP
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
    permite_servicios = coalesce((p_datos->>'permite_servicios')::boolean, permite_servicios)
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
                            'permite_servicios', v_emp.permite_servicios);
END $$;

-- ---------------------------------------------------------------------
-- 13) Perfil "grande": el aviso de la doble aprobación ya es real
--     (reemplaza la de 025; mismo resultado salvo el texto del aviso).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.cambios_perfil(p_empresa_id uuid, p_perfil text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p         interno.plantilla_perfil := interno.perfil_de(p_perfil);
  e         public.empresa;
  v_cambios jsonb := '[]';
  v_topes   jsonb;
  v_sug     jsonb;
  v_act     jsonb;
  v_faltan  jsonb;
  v_sobran  jsonb;
  v_avisos  jsonb := '[]';
BEGIN
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  IF e.perfil IS DISTINCT FROM p.codigo THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'perfil', 'actual', e.perfil, 'nuevo', p.codigo);
  END IF;
  IF e.turnos_obligatorios IS DISTINCT FROM p.turnos_obligatorios THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'turnos_obligatorios', 'actual', e.turnos_obligatorios, 'nuevo', p.turnos_obligatorios);
    v_avisos := v_avisos || to_jsonb(CASE WHEN p.turnos_obligatorios
      THEN 'Para cobrar en efectivo cada cajero tendrá que abrir su turno de caja.'
      ELSE 'El efectivo podrá entrar a la caja sin turno; los turnos abiertos siguen igual hasta cerrarlos.' END);
  END IF;
  IF e.contabilidad_visible IS DISTINCT FROM p.contabilidad_visible THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'contabilidad_visible', 'actual', e.contabilidad_visible, 'nuevo', p.contabilidad_visible);
    IF NOT p.contabilidad_visible THEN
      v_avisos := v_avisos || to_jsonb('La contabilidad se esconde del menú; los libros se siguen llevando igual y el contador la sigue viendo.'::text);
    END IF;
  END IF;
  IF e.doble_aprobacion IS DISTINCT FROM p.doble_aprobacion THEN
    v_cambios := v_cambios || jsonb_build_object('campo', 'doble_aprobacion', 'actual', e.doble_aprobacion, 'nuevo', p.doble_aprobacion);
    IF p.doble_aprobacion THEN
      v_avisos := v_avisos || to_jsonb('Con doble aprobación cada solicitud nueva (gastos, descuentos, créditos y anulaciones) necesita dos personas distintas; el dueño aprueba solo.'::text);
    END IF;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('rol', t.rol, 'tipo', t.tipo,
           'actual_sin_aprobacion_centavos', a.sin_aprobacion, 'nuevo_sin_aprobacion_centavos', t.sin_aprobacion_centavos,
           'actual_aprueba_hasta_centavos', a.aprueba_hasta, 'nuevo_aprueba_hasta_centavos', t.aprueba_hasta_centavos)
           ORDER BY t.rol, t.tipo), '[]')
    INTO v_topes
    FROM interno.plantilla_perfil_tope t
    CROSS JOIN LATERAL interno.tope_rol(p_empresa_id, t.rol, t.tipo) a
   WHERE t.perfil = p.codigo
     AND (a.sin_aprobacion, a.aprueba_hasta) IS DISTINCT FROM (t.sin_aprobacion_centavos, t.aprueba_hasta_centavos);

  SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]') INTO v_sug
    FROM interno.plantilla_perfil_modulo m WHERE m.perfil = p.codigo;
  SELECT coalesce(jsonb_agg(a.modulo ORDER BY a.modulo), '[]') INTO v_act
    FROM public.modulo_activo a WHERE a.empresa_id = p_empresa_id AND a.activo;
  SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') INTO v_faltan
    FROM jsonb_array_elements_text(v_sug) x WHERE NOT v_act ? x;
  SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') INTO v_sobran
    FROM jsonb_array_elements_text(v_act) x WHERE NOT v_sug ? x;
  IF jsonb_array_length(v_faltan) > 0 THEN
    v_avisos := v_avisos || to_jsonb('Módulos sugeridos que no están activos: los activa el proveedor según su plan (pídalos en "Mi cuenta").'::text);
  END IF;
  IF jsonb_array_length(v_sobran) > 0 THEN
    v_avisos := v_avisos || to_jsonb('Los módulos activos que el perfil no sugiere siguen activos: un perfil nunca desactiva módulos ni borra datos.'::text);
  END IF;

  RETURN jsonb_build_object('perfil', p.codigo, 'nombre', p.nombre, 'descripcion', p.descripcion,
    'cambios', v_cambios, 'topes', v_topes,
    'modulos', jsonb_build_object('sugeridos', v_sug, 'activos', v_act, 'faltan', v_faltan, 'activos_no_sugeridos', v_sobran),
    'avisos', v_avisos,
    'hay_cambios', jsonb_array_length(v_cambios) > 0 OR jsonb_array_length(v_topes) > 0);
END $$;

-- ---------------------------------------------------------------------
-- 14) Asistente de arranque: "primera venta" se marca sola (reemplaza la
--     de 025; misma firma y forma).
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
  -- Primera venta: una venta emitida (aunque después se haya anulado).
  v_venta := EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.numero_documento IS NOT NULL);

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
        EXISTS (SELECT 1 FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.es_cliente), NULL),
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
-- 15) Activar el módulo "ventas": Clientes (1.1.02.01) debe coincidir con
--     las ventas al crédito del sistema (reemplaza la de 023 + rama ventas).
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
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (clientes) tiene % en los libros y las ventas al crédito del sistema suman %. Para activar el módulo: 1) registre un asiento que pase la diferencia a % Saldos de apertura (Dr %, Cr %); 2) active el módulo; 3) cargue cada factura pendiente de los clientes como saldo inicial (llega en la etapa de cobros).',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo),
        interno.cuenta_de(NEW.empresa_id, 'apertura_cxp'), interno.cuenta_de(NEW.empresa_id, 'apertura_cxp'), v_cta;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 16) id_operacion por tipo (reemplaza la de 024) y adjuntos a ventas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.tipo_operacion_2b(p_empresa_id uuid, p_id uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  SELECT 'dinero_' || x.tipo INTO v FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN v;
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.confirmacion_id_operacion = p_id) THEN
    RETURN 'confirmacion_deposito';
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_operacion_dinero';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.apertura_id_operacion = p_id) THEN
    RETURN 'abrir_turno';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cierre_id_operacion = p_id) THEN
    RETURN 'cerrar_turno';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.resolucion_id_operacion = p_id) THEN
    RETURN 'resolver_diferencia';
  END IF;
  IF EXISTS (SELECT 1 FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'gasto';
  END IF;
  IF EXISTS (SELECT 1 FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_gasto';
  END IF;
  IF EXISTS (SELECT 1 FROM public.aprobacion x WHERE x.empresa_id = p_empresa_id
               AND ((x.resolucion_id_operacion = p_id AND x.estado IN ('aprobada', 'rechazada')) OR x.primera_id_operacion = p_id)) THEN
    RETURN 'resolver_aprobacion';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.cancelacion_id_operacion = p_id) THEN
    RETURN 'cancelacion_venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta_anulacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'solicitar_anulacion_venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta_pago x WHERE x.empresa_id = p_empresa_id AND x.confirmacion_id_operacion = p_id) THEN
    RETURN 'confirmacion_transferencia';
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION interno.empresa_de_documento(p_tipo text, p_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN CASE p_tipo
    WHEN 'operacion_dinero' THEN (SELECT x.empresa_id FROM public.operacion_dinero x WHERE x.id = p_id)
    WHEN 'turno_caja'       THEN (SELECT x.empresa_id FROM public.turno_caja x WHERE x.id = p_id)
    WHEN 'gasto'            THEN (SELECT x.empresa_id FROM public.gasto x WHERE x.id = p_id)
    WHEN 'compra'           THEN (SELECT x.empresa_id FROM public.compra x WHERE x.id = p_id)
    WHEN 'pago_proveedor'   THEN (SELECT x.empresa_id FROM public.pago_proveedor x WHERE x.id = p_id)
    WHEN 'cxp_saldo_inicial' THEN (SELECT x.empresa_id FROM public.cxp_saldo_inicial x WHERE x.id = p_id)
    WHEN 'inventario_documento' THEN (SELECT x.empresa_id FROM public.inventario_documento x WHERE x.id = p_id)
    WHEN 'venta'            THEN (SELECT x.empresa_id FROM public.venta x WHERE x.id = p_id)
    WHEN 'venta_pago'       THEN (SELECT x.empresa_id FROM public.venta_pago x WHERE x.id = p_id)
  END;
END $$;

-- Tipo de producto (reemplaza la de 026): además, un servicio que ya se
-- vendió no pasa a bien (sus ventas no tocaron el kardex).
CREATE OR REPLACE FUNCTION interno.tipo_producto_fijo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.tipo IS DISTINCT FROM OLD.tipo THEN
    IF OLD.tipo = 'bien' AND EXISTS (SELECT 1 FROM public.inventario_movimiento m WHERE m.producto_id = NEW.id) THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el producto % ya tiene movimientos de inventario; no puede pasar a servicio.', NEW.codigo;
    END IF;
    IF OLD.tipo = 'servicio' AND EXISTS (SELECT 1 FROM public.venta_linea l WHERE l.producto_id = NEW.id) THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el servicio % ya se vendió; no puede pasar a bien (cree un producto nuevo).', NEW.codigo;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 17) Seguridad
--   venta y venta_linea guardan costos: la tabla la leen quienes tienen
--   ventas.ver Y inventario.costos; los demás (cajero, vendedor, o quien no
--   ve costos) leen por las vistas del sistema de 028 (sin costos).
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['promocion', 'venta', 'venta_linea', 'venta_pago', 'venta_anulacion'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
CREATE POLICY leer ON public.promocion FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.venta FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         AND empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))));
CREATE POLICY leer ON public.venta_linea FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         AND empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))));
CREATE POLICY leer ON public.venta_pago FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
CREATE POLICY leer ON public.venta_anulacion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver')))
         OR (solicitado_por = (SELECT auth.uid()) AND empresa_id IN (SELECT public.mis_empresas())));

REVOKE EXECUTE ON FUNCTION
  interno.tope_descuento(uuid, text),
  interno.aprobaciones_requeridas(),
  interno.paso_aprobacion(public.aprobacion, text, text, uuid),
  interno.proteger_promocion(),
  interno.aplicar_datos_promocion(public.promocion, jsonb),
  interno.proteger_venta(),
  interno.venta_sin_emitir(),
  interno.proteger_venta_linea(),
  interno.proteger_venta_pago(),
  interno.proteger_venta_anulacion(),
  interno.calcular_venta(uuid, date, jsonb, jsonb),
  interno.cobros_vigentes_venta(uuid),
  interno.saldo_cxc_cliente(uuid, uuid),
  interno.total_cxc(uuid),
  interno.venta_respuesta(public.venta, boolean),
  interno.caja_de_venta(uuid, jsonb),
  interno.cuenta_cobro_venta(uuid, text, uuid),
  interno.emitir_venta(uuid, date, uuid),
  interno.siguiente_ticket(uuid, uuid),
  interno.registrar_venta_base(uuid, jsonb, uuid, uuid, jsonb),
  interno.anular_venta_base(uuid, date, text, uuid, uuid),
  interno.resolver_aprobacion_gasto(uuid, boolean, text, uuid, date),
  interno.resolver_aprobacion_venta(uuid, boolean, text, uuid, date),
  interno.resolver_anulacion_venta(uuid, boolean, text, uuid, date)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.configurar_tope_descuento(uuid, text, numeric, numeric, text),
  public.crear_promocion(uuid, jsonb),
  public.editar_promocion(uuid, uuid, jsonb, text),
  public.registrar_venta(uuid, jsonb, uuid),
  public.cancelar_venta(uuid, text, uuid),
  public.solicitar_anulacion_venta(uuid, text, uuid),
  public.confirmar_transferencia_venta(uuid, jsonb, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.configurar_tope_descuento(uuid, text, numeric, numeric, text),
  public.crear_promocion(uuid, jsonb),
  public.editar_promocion(uuid, uuid, jsonb, text),
  public.registrar_venta(uuid, jsonb, uuid),
  public.cancelar_venta(uuid, text, uuid),
  public.solicitar_anulacion_venta(uuid, text, uuid),
  public.confirmar_transferencia_venta(uuid, jsonb, uuid)
TO authenticated;
