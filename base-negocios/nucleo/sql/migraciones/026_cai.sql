-- =====================================================================
-- 026_cai.sql  -  Núcleo 0.7.0 (etapa 2b-2a): CAI de la SAR (Honduras)
--
-- Régimen de facturación, Acuerdo 481-2017. NOTA: las reglas fiscales de
-- este archivo (formato del CAI, del número de documento, leyendas y
-- fecha límite) las debe revisar y validar un CONTADOR antes de usarlas
-- con clientes reales.
--
--   cai_rango   rangos autorizados por la SAR, POR CAJA (punto de emisión) y
--               tipo de documento (factura, nota de crédito, nota de débito):
--               número CAI, rango desde-hasta con el formato
--               000-001-01-00000001 (establecimiento-punto de emisión-tipo-
--               correlativo), fecha límite de emisión y el último número
--               usado. El correlativo lo pone SIEMPRE el servidor, dentro
--               del rango de ESA caja: así, en la etapa sin internet, cada
--               caja numera sola con su propio rango y nunca choca con otra.
--   Se rechaza un rango vencido o agotado (CAI_VENCIDO / CAI_AGOTADO); sin
--   rango vigente: SIN_CAI. Alertas: CAI por vencer (N días) y rango por
--   agotarse (% usado), configurables por el dueño.
--   Documento interno sin CAI ("recibo"): para negocios que no facturan
--   todo; se activa con empresa.documento_venta_modo.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('SIN_CAI', 'Esta caja no tiene un rango de facturación (CAI) vigente.',
   'Registre el CAI que le autorizó la SAR para esta caja (Ajustes > CAI) o, si el negocio lo permite, emita un recibo interno.'),
  ('CAI_VENCIDO', 'La fecha límite de emisión del CAI ya pasó.',
   'Solicite un CAI nuevo a la SAR y regístrelo. No se pueden emitir facturas con un CAI vencido.'),
  ('CAI_AGOTADO', 'Se usaron todos los números del rango autorizado (CAI).',
   'Solicite a la SAR un rango nuevo y regístrelo para esta caja.'),
  ('CAI_INVALIDO', 'Los datos del CAI no son válidos.',
   'Revise el número CAI, el rango (formato 000-001-01-00000001) y la fecha límite tal como vienen en la resolución de la SAR.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('cai.administrar', 'Registrar, desactivar y reactivar rangos de facturación (CAI) y ver sus alertas', false, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'cai.administrar'), ('admin', 'cai.administrar');
SELECT interno.repartir_permisos(ARRAY['cai.administrar'], 'Núcleo 0.7.0: rangos de facturación (CAI)');

-- ---------------------------------------------------------------------
-- 1) Configuración de la empresa (la cambia el dueño con configurar_empresa, 027)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa
  -- solo_factura (defecto): toda venta lleva factura con CAI.
  -- factura_o_recibo: se elige en cada venta (defecto factura).
  -- solo_recibo: negocio que aún no factura: recibo interno sin CAI.
  ADD COLUMN documento_venta_modo   text NOT NULL DEFAULT 'solo_factura'
    CHECK (documento_venta_modo IN ('solo_factura', 'factura_o_recibo', 'solo_recibo')),
  ADD COLUMN cai_dias_alerta        integer NOT NULL DEFAULT 30 CHECK (cai_dias_alerta BETWEEN 0 AND 365),
  ADD COLUMN cai_porcentaje_alerta  integer NOT NULL DEFAULT 80 CHECK (cai_porcentaje_alerta BETWEEN 1 AND 100),
  ADD COLUMN leyenda_factura        text CHECK (leyenda_factura IS NULL OR length(leyenda_factura) BETWEEN 1 AND 300);

-- ---------------------------------------------------------------------
-- 2) Tabla de rangos
-- ---------------------------------------------------------------------
CREATE TABLE public.cai_rango (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id             uuid NOT NULL REFERENCES public.empresa(id),
  sucursal_id            uuid NOT NULL,
  caja_id                uuid NOT NULL REFERENCES public.caja(id),
  tipo_documento         text NOT NULL CHECK (tipo_documento IN ('factura', 'nota_credito', 'nota_debito')),
  cai                    text NOT NULL CHECK (cai ~ '^[0-9A-F]{6}(-[0-9A-F]{6}){4}-[0-9A-F]{2}$'),
  prefijo                text NOT NULL CHECK (prefijo ~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}$'),   -- 000-001-01
  rango_desde            text NOT NULL CHECK (rango_desde ~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{8}$'),
  rango_hasta            text NOT NULL CHECK (rango_hasta ~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{8}$'),
  numero_desde           bigint NOT NULL CHECK (numero_desde BETWEEN 1 AND 99999999),
  numero_hasta           bigint NOT NULL CHECK (numero_hasta BETWEEN 1 AND 99999999),
  ultimo_numero          bigint NOT NULL,              -- último correlativo usado (numero_desde - 1 = ninguno)
  ultima_fecha_emision   date,                         -- los documentos de un rango van en orden de fecha
  fecha_limite_emision   date NOT NULL,
  activo                 boolean NOT NULL DEFAULT true,
  creado_por             uuid,
  creado_en              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id),
  CHECK (numero_desde <= numero_hasta),
  CHECK (ultimo_numero BETWEEN numero_desde - 1 AND numero_hasta),
  CHECK (left(rango_desde, 10) = prefijo AND left(rango_hasta, 10) = prefijo),
  CHECK (right(rango_desde, 8)::bigint = numero_desde AND right(rango_hasta, 8)::bigint = numero_hasta)
);
CREATE INDEX cai_rango_caja ON public.cai_rango (caja_id, tipo_documento, numero_desde);
CREATE INDEX cai_rango_empresa ON public.cai_rango (empresa_id, fecha_limite_emision);

-- El rango no se edita: solo avanza su correlativo (de uno en uno, nunca
-- hacia atrás) y se desactiva o reactiva.
CREATE FUNCTION interno.proteger_cai_rango() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (to_jsonb(NEW) - 'ultimo_numero' - 'ultima_fecha_emision' - 'activo')
     IS DISTINCT FROM (to_jsonb(OLD) - 'ultimo_numero' - 'ultima_fecha_emision' - 'activo') THEN
    RAISE EXCEPTION 'PROHIBIDO: un rango de CAI no se edita; si está mal, desactívelo y registre el correcto.';
  END IF;
  IF NEW.ultimo_numero NOT IN (OLD.ultimo_numero, OLD.ultimo_numero + 1) THEN
    RAISE EXCEPTION 'PROHIBIDO: el correlativo del CAI avanza de uno en uno y nunca hacia atrás.';
  END IF;
  IF NEW.ultima_fecha_emision < OLD.ultima_fecha_emision THEN
    RAISE EXCEPTION 'PROHIBIDO: los documentos de un rango van en orden de fecha.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.cai_rango FOR EACH ROW EXECUTE FUNCTION interno.proteger_cai_rango();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.cai_rango FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.cai_rango
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los rangos de CAI no se borran: se desactivan.');

-- ---------------------------------------------------------------------
-- 3) Ayudantes
-- ---------------------------------------------------------------------
-- Estado de un rango hoy: vigente, vencido, agotado o inactivo.
CREATE FUNCTION interno.estado_cai(r public.cai_rango, p_hoy date) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN NOT r.activo THEN 'inactivo'
              WHEN r.ultimo_numero >= r.numero_hasta THEN 'agotado'
              WHEN p_hoy > r.fecha_limite_emision THEN 'vencido'
              ELSE 'vigente' END
$$;

-- Siguiente número fiscal de una caja y tipo de documento (SOLO el servidor
-- numera). Toma el rango vigente más antiguo (por número) de ESA caja, lo
-- bloquea (FOR UPDATE: dos cajeros a la vez esperan en fila, sin repetir ni
-- saltar números) y avanza su correlativo. Quien llama ya tiene bloquear_libros.
-- Devuelve el rango (con ultimo_numero ya avanzado) y el número con formato.
CREATE FUNCTION interno.asignar_numero_fiscal(p_empresa_id uuid, p_caja_id uuid, p_tipo text, p_fecha date,
                                              OUT o_rango public.cai_rango, OUT o_numero text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_hoy  date := public.hoy_local(p_empresa_id);
  v_caja text;
BEGIN
  SELECT * INTO o_rango FROM public.cai_rango r
   WHERE r.empresa_id = p_empresa_id AND r.caja_id = p_caja_id AND r.tipo_documento = p_tipo
     AND r.activo AND r.ultimo_numero < r.numero_hasta AND r.fecha_limite_emision >= v_hoy
   ORDER BY r.numero_desde
   LIMIT 1
   FOR UPDATE;
  IF o_rango.id IS NULL THEN
    SELECT c.nombre INTO v_caja FROM public.caja c WHERE c.id = p_caja_id;
    IF EXISTS (SELECT 1 FROM public.cai_rango r WHERE r.caja_id = p_caja_id AND r.tipo_documento = p_tipo AND r.activo
                 AND r.ultimo_numero < r.numero_hasta) THEN
      RAISE EXCEPTION 'CAI_VENCIDO: el CAI de la caja "%" (%) ya pasó su fecha límite de emisión.', v_caja, replace(p_tipo, '_', ' ');
    ELSIF EXISTS (SELECT 1 FROM public.cai_rango r WHERE r.caja_id = p_caja_id AND r.tipo_documento = p_tipo AND r.activo) THEN
      RAISE EXCEPTION 'CAI_AGOTADO: el rango autorizado de la caja "%" (%) ya se usó completo.', v_caja, replace(p_tipo, '_', ' ');
    END IF;
    RAISE EXCEPTION 'SIN_CAI: la caja "%" no tiene un rango de CAI vigente para %.', v_caja, replace(p_tipo, '_', ' ');
  END IF;
  -- Los documentos de un rango van en orden de fecha (el número nunca "retrocede" en el tiempo).
  IF p_fecha > v_hoy THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: un documento fiscal no lleva fecha futura (%).', to_char(p_fecha, 'DD/MM/YYYY');
  END IF;
  IF o_rango.ultima_fecha_emision > p_fecha THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el último documento de este rango tiene fecha %; uno nuevo no puede tener fecha anterior (%).',
      to_char(o_rango.ultima_fecha_emision, 'DD/MM/YYYY'), to_char(p_fecha, 'DD/MM/YYYY');
  END IF;
  UPDATE public.cai_rango SET ultimo_numero = ultimo_numero + 1,
         ultima_fecha_emision = greatest(coalesce(ultima_fecha_emision, p_fecha), p_fecha)
   WHERE id = o_rango.id
  RETURNING * INTO o_rango;
  o_numero := o_rango.prefijo || '-' || lpad(o_rango.ultimo_numero::text, 8, '0');
END $$;

-- Número de un recibo interno (sin CAI): correlativo propio de la caja.
-- REC-001-001-00000001 (establecimiento y punto de emisión de la caja).
CREATE FUNCTION interno.siguiente_recibo(p_empresa_id uuid, p_caja_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_n   bigint := interno.siguiente_numero(p_empresa_id, 'recibo:' || p_caja_id);
  v_pre text;
BEGIN
  SELECT s.codigo || '-' || c.punto_emision INTO v_pre
    FROM public.caja c JOIN public.sucursal s ON s.id = c.sucursal_id WHERE c.id = p_caja_id;
  RETURN 'REC-' || v_pre || '-' || lpad(v_n::text, 8, '0');
END $$;

-- ¿Quién puede ver los CAI y sus alertas? (cai.administrar, ventas.ver o
-- quien vende: el cajero debe saber si su caja se queda sin números).
CREATE FUNCTION interno.exigir_lectura_cai(p_empresa_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    PERFORM interno.exigir_lectura(p_empresa_id, 'cai.administrar');
    RETURN;
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  IF NOT (public.tiene_permiso('cai.administrar', p_empresa_id) OR public.tiene_permiso('ventas.ver', p_empresa_id)
          OR public.tiene_permiso('ventas.vender', p_empresa_id)) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "cai.administrar".';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 4) RPC
-- ---------------------------------------------------------------------
-- registrar_cai(empresa, datos)   cai.administrar (dueño y admin), módulo ventas
-- datos = {"caja_id":"...","tipo_documento":"factura"|"nota_credito"|"nota_debito",
--          "cai":"A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6",
--          "rango_desde":"001-001-01-00000001","rango_hasta":"001-001-01-00005000",
--          "fecha_limite_emision":"2026-12-31",
--          "ultimo_usado":"001-001-01-00000120" (opcional: si la caja ya facturó a mano parte del rango)}
-- El establecimiento y el punto de emisión del rango deben ser los de la caja.
-- Dos rangos con el mismo prefijo no se pueden cruzar.
CREATE FUNCTION public.registrar_cai(p_empresa_id uuid, p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_caja   public.caja;
  v_suc    public.sucursal;
  v_tipo   text;
  v_cai    text;
  v_desde  text;
  v_hasta  text;
  v_ult    text;
  v_lim    date;
  v_ultimo bigint;
  r        public.cai_rango;
  x        public.cai_rango;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'cai.administrar', 'ventas');
  PERFORM interno.exigir_claves(p_datos, ARRAY['caja_id', 'tipo_documento', 'cai', 'rango_desde', 'rango_hasta',
                                               'fecha_limite_emision', 'ultimo_usado']);
  SELECT * INTO v_caja FROM public.caja c
   WHERE c.id = interno.json_uuid(p_datos->'caja_id', 'caja_id') AND c.empresa_id = p_empresa_id AND c.activa;
  SELECT * INTO v_suc FROM public.sucursal s WHERE s.id = v_caja.sucursal_id AND s.activa;
  IF v_caja.id IS NULL OR v_suc.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja no existe en esta empresa o está desactivada (ella o su sucursal).';
  END IF;
  v_tipo := coalesce(interno.json_texto(p_datos->'tipo_documento', 'tipo_documento', 20), 'factura');
  IF v_tipo NOT IN ('factura', 'nota_credito', 'nota_debito') THEN
    RAISE EXCEPTION 'CAI_INVALIDO: el tipo de documento es factura, nota_credito o nota_debito.';
  END IF;
  v_cai := upper(regexp_replace(coalesce(interno.json_texto(p_datos->'cai', 'cai', 60), ''), '[[:space:]]', '', 'g'));
  IF v_cai !~ '^[0-9A-F]{6}(-[0-9A-F]{6}){4}-[0-9A-F]{2}$' THEN
    RAISE EXCEPTION 'CAI_INVALIDO: el CAI tiene 6 grupos separados por guion (5 de 6 caracteres y 1 de 2, letras A-F y números), ej. A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6.';
  END IF;
  v_desde := interno.json_texto(p_datos->'rango_desde', 'rango_desde', 20);
  v_hasta := interno.json_texto(p_datos->'rango_hasta', 'rango_hasta', 20);
  IF coalesce(v_desde, '') !~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{8}$' OR coalesce(v_hasta, '') !~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{8}$' THEN
    RAISE EXCEPTION 'CAI_INVALIDO: el rango va con el formato 000-001-01-00000001 (establecimiento-punto de emisión-tipo-correlativo).';
  END IF;
  IF left(v_desde, 10) <> left(v_hasta, 10) THEN
    RAISE EXCEPTION 'CAI_INVALIDO: el inicio y el final del rango deben tener el mismo establecimiento, punto de emisión y tipo (%).', left(v_desde, 10);
  END IF;
  IF right(v_desde, 8)::bigint = 0 OR right(v_desde, 8)::bigint > right(v_hasta, 8)::bigint THEN
    RAISE EXCEPTION 'CAI_INVALIDO: el rango empieza en 1 o más y el inicio no puede ser mayor que el final.';
  END IF;
  IF split_part(v_desde, '-', 1) <> v_suc.codigo OR split_part(v_desde, '-', 2) <> v_caja.punto_emision THEN
    RAISE EXCEPTION 'CAI_INVALIDO: el rango es del establecimiento % y punto de emisión %, pero la caja "%" es %-%.',
      split_part(v_desde, '-', 1), split_part(v_desde, '-', 2), v_caja.nombre, v_suc.codigo, v_caja.punto_emision;
  END IF;
  v_lim := interno.json_fecha(p_datos->'fecha_limite_emision', 'fecha_limite_emision');
  IF v_lim IS NULL THEN
    RAISE EXCEPTION 'CAI_INVALIDO: indique la fecha límite de emisión (AAAA-MM-DD).';
  END IF;
  IF v_lim < public.hoy_local(p_empresa_id) THEN
    RAISE EXCEPTION 'CAI_VENCIDO: la fecha límite de emisión (%) ya pasó; no se puede registrar.', to_char(v_lim, 'DD/MM/YYYY');
  END IF;
  v_ultimo := right(v_desde, 8)::bigint - 1;
  IF p_datos ? 'ultimo_usado' AND p_datos->'ultimo_usado' <> 'null'::jsonb THEN
    v_ult := interno.json_texto(p_datos->'ultimo_usado', 'ultimo_usado', 20);
    IF coalesce(v_ult, '') !~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{8}$' OR left(v_ult, 10) <> left(v_desde, 10)
       OR right(v_ult, 8)::bigint NOT BETWEEN right(v_desde, 8)::bigint AND right(v_hasta, 8)::bigint THEN
      RAISE EXCEPTION 'CAI_INVALIDO: el último número usado debe estar dentro del rango (%).', v_desde || ' a ' || v_hasta;
    END IF;
    v_ultimo := right(v_ult, 8)::bigint;
  END IF;

  PERFORM interno.bloquear_libros(p_empresa_id);
  -- Un mismo código de tipo no se usa para dos tipos de documento en la empresa.
  SELECT * INTO x FROM public.cai_rango y
   WHERE y.empresa_id = p_empresa_id AND split_part(y.prefijo, '-', 3) = split_part(v_desde, '-', 3) AND y.tipo_documento <> v_tipo
   LIMIT 1;
  IF x.id IS NOT NULL THEN
    RAISE EXCEPTION 'CAI_INVALIDO: el código de tipo "%" ya se usa para %; revise el rango.', split_part(v_desde, '-', 3), replace(x.tipo_documento, '_', ' ');
  END IF;
  -- Rangos del mismo prefijo no se cruzan (aunque estén desactivados: un número fiscal no se repite nunca).
  SELECT * INTO x FROM public.cai_rango y
   WHERE y.empresa_id = p_empresa_id AND y.prefijo = left(v_desde, 10)
     AND y.numero_desde <= right(v_hasta, 8)::bigint AND y.numero_hasta >= right(v_desde, 8)::bigint
   LIMIT 1;
  IF x.id IS NOT NULL THEN
    IF x.cai = v_cai AND x.numero_desde = right(v_desde, 8)::bigint AND x.numero_hasta = right(v_hasta, 8)::bigint THEN
      RETURN jsonb_build_object('cai_rango_id', x.id, 'ya_estaba', true);
    END IF;
    RAISE EXCEPTION 'CAI_INVALIDO: el rango se cruza con otro ya registrado (% a %).', x.rango_desde, x.rango_hasta;
  END IF;

  INSERT INTO public.cai_rango (empresa_id, sucursal_id, caja_id, tipo_documento, cai, prefijo, rango_desde, rango_hasta,
                                numero_desde, numero_hasta, ultimo_numero, fecha_limite_emision, creado_por)
  VALUES (p_empresa_id, v_suc.id, v_caja.id, v_tipo, v_cai, left(v_desde, 10), v_desde, v_hasta,
          right(v_desde, 8)::bigint, right(v_hasta, 8)::bigint, v_ultimo, v_lim, auth.uid())
  RETURNING * INTO r;
  RETURN jsonb_build_object('cai_rango_id', r.id, 'caja_id', r.caja_id, 'tipo_documento', r.tipo_documento,
    'cai', r.cai, 'rango_desde', r.rango_desde, 'rango_hasta', r.rango_hasta,
    'fecha_limite_emision', to_char(r.fecha_limite_emision, 'YYYY-MM-DD'),
    'disponibles', r.numero_hasta - r.ultimo_numero, 'ya_estaba', false);
END $$;

-- desactivar_cai / reactivar_cai(empresa, rango, motivo)   cai.administrar
CREATE FUNCTION public.desactivar_cai(p_empresa_id uuid, p_cai_rango_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.cai_rango;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'cai.administrar', 'ventas');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva el rango (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO r FROM public.cai_rango WHERE id = p_cai_rango_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el rango de CAI no existe en esta empresa.';
  END IF;
  IF NOT r.activo THEN
    RETURN jsonb_build_object('cai_rango_id', r.id, 'activo', false, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cai_rango SET activo = false WHERE id = r.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('cai_rango_id', r.id, 'activo', false, 'ya_estaba', false);
END $$;

CREATE FUNCTION public.reactivar_cai(p_empresa_id uuid, p_cai_rango_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.cai_rango;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'cai.administrar', 'ventas');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva el rango (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO r FROM public.cai_rango WHERE id = p_cai_rango_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el rango de CAI no existe en esta empresa.';
  END IF;
  IF r.activo THEN
    RETURN jsonb_build_object('cai_rango_id', r.id, 'activo', true, 'ya_estaba', true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.caja c WHERE c.id = r.caja_id AND c.activa) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la caja del rango está desactivada; reactívela primero.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cai_rango SET activo = true WHERE id = r.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('cai_rango_id', r.id, 'activo', true, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- 5) Lecturas: rangos con su estado y alertas
-- ---------------------------------------------------------------------
CREATE VIEW public.v_cai_rango WITH (security_invoker = true) AS
  SELECT r.empresa_id, r.id AS cai_rango_id, r.caja_id, c.nombre AS caja, r.sucursal_id, r.tipo_documento, r.cai,
         r.rango_desde, r.rango_hasta, r.fecha_limite_emision, r.activo,
         CASE WHEN r.ultimo_numero >= r.numero_desde THEN r.prefijo || '-' || lpad(r.ultimo_numero::text, 8, '0') END AS ultimo_emitido,
         (r.numero_hasta - r.ultimo_numero) AS numeros_disponibles,
         (r.numero_hasta - r.numero_desde + 1) AS numeros_total,
         round((r.ultimo_numero - r.numero_desde + 1) * 100.0 / (r.numero_hasta - r.numero_desde + 1), 1) AS porcentaje_usado,
         r.fecha_limite_emision - public.hoy_local(r.empresa_id) AS dias_para_vencer,
         interno_estado.estado,
         (interno_estado.estado = 'vigente' AND r.fecha_limite_emision - public.hoy_local(r.empresa_id) <= e.cai_dias_alerta) AS alerta_vencimiento,
         (interno_estado.estado = 'vigente'
          AND (r.ultimo_numero - r.numero_desde + 1) * 100.0 / (r.numero_hasta - r.numero_desde + 1) >= e.cai_porcentaje_alerta) AS alerta_agotamiento,
         r.creado_en
  FROM public.cai_rango r
  JOIN public.caja c ON c.id = r.caja_id
  JOIN public.empresa e ON e.id = r.empresa_id
  CROSS JOIN LATERAL (SELECT CASE WHEN NOT r.activo THEN 'inactivo'
                                  WHEN r.ultimo_numero >= r.numero_hasta THEN 'agotado'
                                  WHEN public.hoy_local(r.empresa_id) > r.fecha_limite_emision THEN 'vencido'
                                  ELSE 'vigente' END AS estado) interno_estado;

-- cai_alertas(empresa): CAI por vencer, rangos por agotarse, vencidos o
-- agotados que siguen activos y cajas activas sin factura vigente (si la
-- empresa factura). Lo ven cai.administrar, ventas.ver y quien vende.
CREATE FUNCTION public.cai_alertas(p_empresa_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e        public.empresa;
  v_hoy    date;
  v_alert  jsonb := '[]';
  r        record;
BEGIN
  PERFORM interno.exigir_lectura_cai(p_empresa_id);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  v_hoy := public.hoy_local(p_empresa_id);
  FOR r IN SELECT x.*, c.nombre AS caja, interno.estado_cai(x, v_hoy) AS estado,
                  (x.ultimo_numero - x.numero_desde + 1) * 100.0 / (x.numero_hasta - x.numero_desde + 1) AS pct
             FROM public.cai_rango x JOIN public.caja c ON c.id = x.caja_id
            WHERE x.empresa_id = p_empresa_id AND x.activo AND c.activa
            ORDER BY c.nombre, x.tipo_documento, x.numero_desde LOOP
    IF r.estado = 'vencido' THEN
      v_alert := v_alert || jsonb_build_object('tipo', 'vencido', 'cai_rango_id', r.id, 'caja_id', r.caja_id, 'caja', r.caja,
        'tipo_documento', r.tipo_documento, 'mensaje', 'El CAI de la caja "' || r.caja || '" venció el ' || to_char(r.fecha_limite_emision, 'DD/MM/YYYY') || '.');
    ELSIF r.estado = 'agotado' THEN
      v_alert := v_alert || jsonb_build_object('tipo', 'agotado', 'cai_rango_id', r.id, 'caja_id', r.caja_id, 'caja', r.caja,
        'tipo_documento', r.tipo_documento, 'mensaje', 'El rango ' || r.rango_desde || ' a ' || r.rango_hasta || ' de la caja "' || r.caja || '" ya se usó completo.');
    ELSE
      IF r.fecha_limite_emision - v_hoy <= e.cai_dias_alerta THEN
        v_alert := v_alert || jsonb_build_object('tipo', 'por_vencer', 'cai_rango_id', r.id, 'caja_id', r.caja_id, 'caja', r.caja,
          'tipo_documento', r.tipo_documento, 'dias', r.fecha_limite_emision - v_hoy,
          'mensaje', 'El CAI de la caja "' || r.caja || '" vence en ' || (r.fecha_limite_emision - v_hoy) || ' día(s) (' || to_char(r.fecha_limite_emision, 'DD/MM/YYYY') || ').');
      END IF;
      IF r.pct >= e.cai_porcentaje_alerta THEN
        v_alert := v_alert || jsonb_build_object('tipo', 'por_agotarse', 'cai_rango_id', r.id, 'caja_id', r.caja_id, 'caja', r.caja,
          'tipo_documento', r.tipo_documento, 'porcentaje_usado', round(r.pct, 1), 'disponibles', r.numero_hasta - r.ultimo_numero,
          'mensaje', 'La caja "' || r.caja || '" ya usó el ' || round(r.pct, 1) || ' % de su rango; quedan ' || (r.numero_hasta - r.ultimo_numero) || ' número(s).');
      END IF;
    END IF;
  END LOOP;
  IF e.documento_venta_modo <> 'solo_recibo' THEN
    FOR r IN SELECT c.id, c.nombre FROM public.caja c JOIN public.sucursal s ON s.id = c.sucursal_id
              WHERE c.empresa_id = p_empresa_id AND c.activa AND s.activa
                AND NOT EXISTS (SELECT 1 FROM public.cai_rango x WHERE x.caja_id = c.id AND x.tipo_documento = 'factura'
                                  AND interno.estado_cai(x, v_hoy) = 'vigente')
              ORDER BY c.nombre LOOP
      v_alert := v_alert || jsonb_build_object('tipo', 'sin_cai', 'caja_id', r.id, 'caja', r.nombre, 'tipo_documento', 'factura',
        'mensaje', 'La caja "' || r.nombre || '" no tiene un CAI vigente para facturar.');
    END LOOP;
  END IF;
  RETURN jsonb_build_object('fecha', to_char(v_hoy, 'YYYY-MM-DD'), 'dias_alerta', e.cai_dias_alerta,
                            'porcentaje_alerta', e.cai_porcentaje_alerta, 'alertas', v_alert,
                            'cantidad', jsonb_array_length(v_alert));
END $$;

-- ---------------------------------------------------------------------
-- 6) Seguridad
-- ---------------------------------------------------------------------
ALTER TABLE public.cai_rango ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.cai_rango
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
GRANT SELECT ON public.cai_rango TO authenticated, service_role;
CREATE POLICY leer ON public.cai_rango FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('cai.administrar')))
         OR empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));
GRANT SELECT ON public.v_cai_rango TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  interno.proteger_cai_rango(),
  interno.estado_cai(public.cai_rango, date),
  interno.asignar_numero_fiscal(uuid, uuid, text, date),
  interno.siguiente_recibo(uuid, uuid),
  interno.exigir_lectura_cai(uuid)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.registrar_cai(uuid, jsonb),
  public.desactivar_cai(uuid, uuid, text),
  public.reactivar_cai(uuid, uuid, text),
  public.cai_alertas(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.registrar_cai(uuid, jsonb),
  public.desactivar_cai(uuid, uuid, text),
  public.reactivar_cai(uuid, uuid, text)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.cai_alertas(uuid) TO authenticated, service_role;
