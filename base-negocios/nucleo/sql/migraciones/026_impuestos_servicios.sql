-- =====================================================================
-- 026_impuestos_servicios.sql  -  Núcleo 0.7.0 (etapa 2b-2a)
--
-- Decisión del dueño: el programa se venderá a cualquier tipo de negocio
-- y, más adelante, a otros países.
--
--   1) IMPUESTOS COMO DATOS (tabla public.impuesto, por empresa): código,
--      nombre, porcentaje, clase (gravado / exento / exonerado), cuenta del
--      impuesto por pagar y del crédito fiscal, activo y uno predeterminado.
--      Se siembra por país (interno.plantilla_impuesto). Honduras: ISV15,
--      ISV18, EXENTO y EXONERADO. producto.tipo_impuesto pasa a ser el código
--      de esa tabla (los valores de antes siguen igual). Otro país = otros datos.
--      Ventas, compras y gastos calculan con la tabla.
--   2) SERVICIOS además de bienes: producto.tipo 'bien' | 'servicio'
--      (defecto 'bien'). Un servicio no mueve kardex, no tiene existencia ni
--      bodega y no se bloquea por falta de existencia. Su costo estimado
--      (opcional, en public.servicio_costo, solo lo ve quien ve costos) sirve
--      para margen y comisiones; NUNCA genera asiento de costo de inventario.
--      empresa.permite_servicios (defecto true) lo apaga el dueño.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('IMPUESTO_INVALIDO', 'Ese impuesto no existe en la empresa o está desactivado.',
   'Elija uno de los impuestos configurados (en Honduras: ISV15, ISV18, EXENTO o EXONERADO) o pida al dueño que lo agregue.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('impuestos.configurar', 'Crear y cambiar los impuestos de la empresa (tasa, clase y cuentas)', false, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES ('dueno', 'impuestos.configurar');
SELECT interno.repartir_permisos(ARRAY['impuestos.configurar'], 'Núcleo 0.7.0: impuestos como datos');

ALTER TABLE public.empresa ADD COLUMN permite_servicios boolean NOT NULL DEFAULT true;

-- ---------------------------------------------------------------------
-- 1) Impuestos
-- ---------------------------------------------------------------------
-- Plantilla por país (la ajusta el proveedor con una migración).
CREATE TABLE interno.plantilla_impuesto (
  pais                  text NOT NULL CHECK (pais ~ '^[A-Z]{2}$'),
  codigo                text NOT NULL CHECK (codigo ~ '^[A-Z][A-Z0-9_]{1,14}$'),
  nombre                text NOT NULL,
  porcentaje            numeric(6,3) NOT NULL CHECK (porcentaje BETWEEN 0 AND 100),
  clase                 text NOT NULL CHECK (clase IN ('gravado', 'exento', 'exonerado')),
  cuenta_por_pagar      text,       -- código del catálogo (impuesto de las ventas)
  cuenta_credito_fiscal text,       -- código del catálogo (impuesto de las compras y gastos)
  predeterminado        boolean NOT NULL DEFAULT false,
  orden                 integer NOT NULL,
  PRIMARY KEY (pais, codigo)
);
INSERT INTO interno.plantilla_impuesto VALUES
  ('HN', 'ISV15',     'ISV 15 %',  15, 'gravado',   '2.1.02.01', '1.1.04.01', true,  1),
  ('HN', 'ISV18',     'ISV 18 %',  18, 'gravado',   '2.1.02.01', '1.1.04.01', false, 2),
  ('HN', 'EXENTO',    'Exento',     0, 'exento',    NULL,        NULL,        false, 3),
  ('HN', 'EXONERADO', 'Exonerado',  0, 'exonerado', NULL,        NULL,        false, 4);

CREATE TABLE public.impuesto (
  empresa_id            uuid NOT NULL REFERENCES public.empresa(id),
  codigo                text NOT NULL CHECK (codigo ~ '^[A-Z][A-Z0-9_]{1,14}$'),
  nombre                text NOT NULL CHECK (length(trim(nombre)) BETWEEN 1 AND 60),
  porcentaje            numeric(6,3) NOT NULL CHECK (porcentaje BETWEEN 0 AND 100),
  clase                 text NOT NULL CHECK (clase IN ('gravado', 'exento', 'exonerado')),
  cuenta_por_pagar      text,
  cuenta_credito_fiscal text,
  predeterminado        boolean NOT NULL DEFAULT false,
  orden                 integer NOT NULL DEFAULT 1,
  activo                boolean NOT NULL DEFAULT true,
  creado_en             timestamptz NOT NULL DEFAULT now(),
  actualizado_en        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (empresa_id, codigo),
  CHECK ((clase = 'gravado') = (porcentaje > 0)),
  CHECK (clase <> 'gravado' OR (cuenta_por_pagar IS NOT NULL AND cuenta_credito_fiscal IS NOT NULL))
);
CREATE UNIQUE INDEX impuesto_predeterminado ON public.impuesto (empresa_id) WHERE predeterminado;

CREATE FUNCTION interno.proteger_impuesto() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.empresa_id, NEW.codigo, NEW.creado_en) IS DISTINCT FROM (OLD.empresa_id, OLD.codigo, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: el código de un impuesto no se cambia (los documentos ya lo usan); cree otro.';
  END IF;
  NEW.actualizado_en := now();
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.impuesto FOR EACH ROW EXECUTE FUNCTION interno.proteger_impuesto();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.impuesto FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.impuesto
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive el impuesto en vez de borrarlo.');

-- Empresa nueva: recibe los impuestos de la plantilla de su país.
CREATE FUNCTION interno.sembrar_impuestos() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.impuesto (empresa_id, codigo, nombre, porcentaje, clase, cuenta_por_pagar, cuenta_credito_fiscal,
                               predeterminado, orden)
  SELECT NEW.id, p.codigo, p.nombre, p.porcentaje, p.clase, p.cuenta_por_pagar, p.cuenta_credito_fiscal, p.predeterminado, p.orden
    FROM interno.plantilla_impuesto p WHERE p.pais = NEW.pais
  ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;
CREATE TRIGGER sembrar_impuestos AFTER INSERT ON public.empresa FOR EACH ROW EXECUTE FUNCTION interno.sembrar_impuestos();

-- Empresas ya instaladas: sus productos usaban los códigos de Honduras.
SELECT set_config('app.motivo', 'Núcleo 0.7.0: impuestos como datos', true);
INSERT INTO public.impuesto (empresa_id, codigo, nombre, porcentaje, clase, cuenta_por_pagar, cuenta_credito_fiscal, predeterminado, orden)
SELECT e.id, p.codigo, p.nombre, p.porcentaje, p.clase, p.cuenta_por_pagar, p.cuenta_credito_fiscal, p.predeterminado, p.orden
  FROM public.empresa e JOIN interno.plantilla_impuesto p ON p.pais = 'HN'
ON CONFLICT DO NOTHING;
SELECT set_config('app.motivo', '', true);

-- El producto y la compra apuntan al impuesto de la tabla (antes: lista fija).
ALTER TABLE public.producto DROP CONSTRAINT producto_tipo_impuesto_check,
  ADD CONSTRAINT producto_impuesto_fk FOREIGN KEY (empresa_id, tipo_impuesto) REFERENCES public.impuesto(empresa_id, codigo);
ALTER TABLE public.producto ALTER COLUMN tipo_impuesto DROP DEFAULT;
ALTER TABLE public.compra_linea DROP CONSTRAINT compra_linea_tipo_impuesto_check,
  ADD CONSTRAINT compra_linea_impuesto_fk FOREIGN KEY (empresa_id, tipo_impuesto) REFERENCES public.impuesto(empresa_id, codigo);

-- Impuesto de la empresa (error claro si no existe; activo si se pide).
CREATE FUNCTION interno.impuesto_de(p_empresa_id uuid, p_codigo text, p_activo boolean DEFAULT false) RETURNS public.impuesto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.impuesto;
BEGIN
  SELECT * INTO i FROM public.impuesto x WHERE x.empresa_id = p_empresa_id AND x.codigo = p_codigo;
  IF i.codigo IS NULL OR (p_activo AND NOT i.activo) THEN
    RAISE EXCEPTION 'IMPUESTO_INVALIDO: el impuesto "%" no existe en la empresa o está desactivado.', coalesce(p_codigo, '');
  END IF;
  RETURN i;
END $$;

-- LA REGLA DE CÁLCULO, en un solo lugar y sin tasas fijas (la de 020, con
-- la tasa como dato): por LÍNEA, sobre round(cantidad x precio), a centavo
-- con mitades hacia arriba.
--   incluye: con = total; sin = round(total / (1 + %/100)); impuesto = con - sin
--   no incluye: sin = total; impuesto = round(sin x %/100); con = sin + impuesto
CREATE FUNCTION public.precio_con_tasa(p_precio_centavos bigint, p_incluye boolean, p_porcentaje numeric,
                                       p_cantidad numeric DEFAULT 1,
                                       OUT sin_isv_centavos bigint, OUT isv_centavos bigint, OUT con_isv_centavos bigint)
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH x AS (SELECT round(coalesce(p_cantidad, 1) * p_precio_centavos)::bigint AS total, coalesce(p_porcentaje, 0) / 100 AS tasa)
  SELECT s.sin, c.con - s.sin, c.con
    FROM x
    CROSS JOIN LATERAL (SELECT CASE WHEN p_incluye THEN round(x.total / (1 + x.tasa))::bigint ELSE x.total END AS sin) s
    CROSS JOIN LATERAL (SELECT CASE WHEN p_incluye THEN x.total ELSE s.sin + round(s.sin * x.tasa)::bigint END AS con) c
$$;

-- Lo mismo con el código de impuesto de la empresa (lee la tabla).
CREATE FUNCTION public.precio_impuesto(p_empresa_id uuid, p_precio_centavos bigint, p_incluye boolean, p_impuesto text,
                                       p_cantidad numeric DEFAULT 1,
                                       OUT sin_isv_centavos bigint, OUT isv_centavos bigint, OUT con_isv_centavos bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT x.sin_isv_centavos, x.isv_centavos, x.con_isv_centavos
    FROM public.precio_con_tasa(p_precio_centavos, p_incluye,
           (SELECT i.porcentaje FROM public.impuesto i WHERE i.empresa_id = p_empresa_id AND i.codigo = p_impuesto), p_cantidad) x
$$;

-- Tasa de un impuesto para las COMPRAS (reemplaza la de 016; misma firma):
-- la compra pone su empresa en app.empresa_impuestos y aquí se lee la
-- tabla. Sin empresa (llamadas viejas) quedan las tasas de Honduras.
CREATE OR REPLACE FUNCTION interno.tasa_isv(p_tipo text) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_emp text := nullif(current_setting('app.empresa_impuestos', true), '');
  v     numeric;
BEGIN
  IF v_emp IS NOT NULL THEN
    SELECT i.porcentaje / 100 INTO v FROM public.impuesto i WHERE i.empresa_id = v_emp::uuid AND i.codigo = p_tipo;
    IF v IS NULL THEN
      RAISE EXCEPTION 'IMPUESTO_INVALIDO: el impuesto "%" no existe en la empresa.', p_tipo;
    END IF;
    RETURN v;
  END IF;
  RETURN CASE p_tipo WHEN 'ISV15' THEN 0.15 WHEN 'ISV18' THEN 0.18 ELSE 0 END::numeric;
END $$;

-- registrar_compra (reemplaza la de 022; misma firma): igual, y la tasa de
-- cada línea sale de la tabla de impuestos de la empresa.
CREATE OR REPLACE FUNCTION public.registrar_compra(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_doc   text;
  v_prov  uuid;
  v_datos jsonb := p_datos;
  v_cd    uuid;
  v_cod   text;
  r       jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.registrar', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'compra');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'compra');
  IF jsonb_typeof(p_datos) = 'object' AND NOT EXISTS (SELECT 1 FROM public.compra x
                                                       WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion) THEN
    IF jsonb_typeof(p_datos->'numero_documento') = 'string' AND jsonb_typeof(p_datos->'proveedor_id') = 'string' THEN
      v_doc  := trim(p_datos->>'numero_documento');
      v_prov := interno.json_uuid(p_datos->'proveedor_id', 'proveedor_id');
      IF EXISTS (SELECT 1 FROM public.cxp_saldo_inicial s
                  WHERE s.empresa_id = p_empresa_id AND s.proveedor_id = v_prov
                    AND upper(s.numero_documento) = upper(v_doc) AND s.anulada_en IS NULL) THEN
        RAISE EXCEPTION 'YA_EXISTE: la factura % de este proveedor ya está registrada como saldo inicial.', v_doc;
      END IF;
    END IF;
    IF p_datos ? 'cuenta_dinero_id' OR (p_datos ? 'cuenta_pago' AND jsonb_typeof(p_datos->'cuenta_pago') = 'string') THEN
      v_cd  := interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id');
      v_cod := interno.codigo_cuenta_pago(p_empresa_id, v_cd, p_datos->>'cuenta_pago');
      v_datos := v_datos - 'cuenta_dinero_id';
      IF v_cd IS NOT NULL THEN
        v_datos := v_datos || jsonb_build_object('cuenta_pago', v_cod);
        IF NOT v_datos ? 'forma_pago' AND coalesce(v_datos->>'condicion', '') = 'contado' THEN
          v_datos := v_datos || jsonb_build_object('forma_pago',
            CASE WHEN (SELECT x.tipo FROM public.cuenta_dinero x WHERE x.id = v_cd) = 'banco' THEN 'banco' ELSE 'caja' END);
        END IF;
      END IF;
    END IF;
  END IF;
  PERFORM set_config('app.empresa_impuestos', p_empresa_id::text, true);
  r := interno.registrar_compra_base(p_empresa_id, v_datos, p_id_operacion);
  PERFORM set_config('app.empresa_impuestos', '', true);
  IF NOT (r->>'duplicado')::boolean THEN
    PERFORM interno.rastrear_dinero((r->>'asiento_id')::uuid, 'compra', 'compra', (r->>'compra_id')::uuid,
                                    'Factura ' || (p_datos->>'numero_documento'), interno.equipo(p_datos));
  END IF;
  RETURN r;
END $$;

-- registrar_gasto (reemplaza la de 024; misma firma). Nuevo: "impuesto"
-- (código de la tabla) en vez de "isv_centavos": el crédito fiscal se
-- calcula del total con la tasa de la tabla: total - round(total / (1 + %)).
-- Ej. 115,000 con ISV15 -> crédito fiscal 15,000.
CREATE OR REPLACE FUNCTION public.registrar_gasto(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_datos jsonb := p_datos;
  i       public.impuesto;
  v_total bigint;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'gastos.registrar', 'dinero');
  IF jsonb_typeof(p_datos) = 'object' AND p_datos ? 'impuesto' THEN
    IF p_datos ? 'isv_centavos' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique "impuesto" (se calcula) o "isv_centavos" (monto de la factura), no los dos.';
    END IF;
    i := interno.impuesto_de(p_empresa_id, interno.json_texto(p_datos->'impuesto', 'impuesto', 15), true);
    v_total := interno.json_centavos(p_datos->'monto_centavos', 'monto_centavos');
    v_datos := (p_datos - 'impuesto') || jsonb_build_object('isv_centavos',
      v_total - (SELECT x.sin_isv_centavos FROM public.precio_con_tasa(v_total, true, i.porcentaje, 1) x));
  END IF;
  RETURN interno.registrar_gasto_base(p_empresa_id, v_datos, p_id_operacion);
END $$;

-- configurar_impuesto(empresa, datos, motivo)   impuestos.configurar (solo el dueño)
-- datos = {"codigo":"IVA13","nombre":"IVA 13 %","porcentaje":13,"clase":"gravado",
--          "cuenta_por_pagar":"2.1.02.01","cuenta_credito_fiscal":"1.1.04.01",
--          "predeterminado":true,"activo":true,"orden":1}
-- Crea o cambia. Cambiar la tasa vale para lo que se registre DESPUÉS (cada
-- venta guarda la tasa que usó). El código no cambia nunca.
CREATE FUNCTION public.configurar_impuesto(p_empresa_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  i     public.impuesto;
  v_cod text;
  c     text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'impuestos.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['codigo', 'nombre', 'porcentaje', 'clase', 'cuenta_por_pagar',
                                               'cuenta_credito_fiscal', 'predeterminado', 'activo', 'orden']);
  v_cod := upper(interno.json_texto(p_datos->'codigo', 'codigo', 15));
  IF coalesce(v_cod, '') !~ '^[A-Z][A-Z0-9_]{1,14}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el código del impuesto lleva letras mayúsculas, números o guion bajo (2 a 15), ej. ISV15.';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO i FROM public.impuesto x WHERE x.empresa_id = p_empresa_id AND x.codigo = v_cod FOR UPDATE;
  IF i.codigo IS NULL THEN
    i.empresa_id := p_empresa_id; i.codigo := v_cod; i.activo := true; i.predeterminado := false; i.orden := 1;
  END IF;
  IF p_datos ? 'nombre' THEN i.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 60); END IF;
  IF p_datos ? 'porcentaje' THEN
    IF jsonb_typeof(p_datos->'porcentaje') <> 'number' OR (p_datos->>'porcentaje')::numeric NOT BETWEEN 0 AND 100
       OR (p_datos->>'porcentaje')::numeric <> round((p_datos->>'porcentaje')::numeric, 3) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el porcentaje va de 0 a 100 (hasta 3 decimales).';
    END IF;
    i.porcentaje := (p_datos->>'porcentaje')::numeric;
  END IF;
  IF p_datos ? 'clase' THEN i.clase := interno.json_texto(p_datos->'clase', 'clase', 15); END IF;
  IF p_datos ? 'cuenta_por_pagar' THEN i.cuenta_por_pagar := interno.json_texto(p_datos->'cuenta_por_pagar', 'cuenta_por_pagar', 30); END IF;
  IF p_datos ? 'cuenta_credito_fiscal' THEN
    i.cuenta_credito_fiscal := interno.json_texto(p_datos->'cuenta_credito_fiscal', 'cuenta_credito_fiscal', 30);
  END IF;
  IF p_datos ? 'predeterminado' THEN i.predeterminado := interno.json_si_no(p_datos->'predeterminado', 'predeterminado'); END IF;
  IF p_datos ? 'activo' THEN i.activo := interno.json_si_no(p_datos->'activo', 'activo'); END IF;
  IF p_datos ? 'orden' THEN
    IF jsonb_typeof(p_datos->'orden') <> 'number' OR (p_datos->>'orden') !~ '^[0-9]{1,3}$' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "orden" es un número entero de 0 a 999.';
    END IF;
    i.orden := (p_datos->>'orden')::integer;
  END IF;
  IF i.nombre IS NULL OR i.porcentaje IS NULL OR coalesce(i.clase, '') NOT IN ('gravado', 'exento', 'exonerado') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un impuesto nuevo necesita nombre, porcentaje y clase (gravado, exento o exonerado).';
  END IF;
  IF (i.clase = 'gravado') <> (i.porcentaje > 0) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un impuesto "gravado" tiene porcentaje mayor que 0; "exento" y "exonerado" van con 0.';
  END IF;
  IF i.clase = 'gravado' THEN
    FOREACH c IN ARRAY ARRAY[i.cuenta_por_pagar, i.cuenta_credito_fiscal] LOOP
      IF c IS NULL OR NOT EXISTS (SELECT 1 FROM public.cuenta x WHERE x.empresa_id = p_empresa_id AND x.codigo = c
                                    AND x.es_detalle AND x.activa) THEN
        RAISE EXCEPTION 'CUENTA_INVALIDA: un impuesto gravado necesita su cuenta por pagar y de crédito fiscal (cuentas de detalle activas); "%" no sirve.', coalesce(c, '');
      END IF;
    END LOOP;
  ELSE
    i.cuenta_por_pagar := NULL; i.cuenta_credito_fiscal := NULL;
  END IF;
  IF i.predeterminado AND NOT i.activo THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el impuesto predeterminado debe estar activo.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  IF i.predeterminado THEN
    UPDATE public.impuesto SET predeterminado = false WHERE empresa_id = p_empresa_id AND predeterminado AND codigo <> v_cod;
  END IF;
  INSERT INTO public.impuesto (empresa_id, codigo, nombre, porcentaje, clase, cuenta_por_pagar, cuenta_credito_fiscal,
                               predeterminado, orden, activo)
  VALUES (p_empresa_id, v_cod, trim(i.nombre), i.porcentaje, i.clase, i.cuenta_por_pagar, i.cuenta_credito_fiscal,
          i.predeterminado, i.orden, i.activo)
  ON CONFLICT (empresa_id, codigo) DO UPDATE
     SET nombre = excluded.nombre, porcentaje = excluded.porcentaje, clase = excluded.clase,
         cuenta_por_pagar = excluded.cuenta_por_pagar, cuenta_credito_fiscal = excluded.cuenta_credito_fiscal,
         predeterminado = excluded.predeterminado, orden = excluded.orden, activo = excluded.activo
  RETURNING * INTO i;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('codigo', i.codigo, 'nombre', i.nombre, 'porcentaje', i.porcentaje, 'clase', i.clase,
    'cuenta_por_pagar', i.cuenta_por_pagar, 'cuenta_credito_fiscal', i.cuenta_credito_fiscal,
    'predeterminado', i.predeterminado, 'activo', i.activo);
END $$;

-- ---------------------------------------------------------------------
-- 2) Servicios
-- ---------------------------------------------------------------------
ALTER TABLE public.producto ADD COLUMN tipo text NOT NULL DEFAULT 'bien' CHECK (tipo IN ('bien', 'servicio'));

-- Costo estimado de un servicio (centavos por unidad): solo lo ve quien ve
-- costos; sirve para margen y comisiones, nunca va a los libros.
CREATE TABLE public.servicio_costo (
  empresa_id               uuid NOT NULL,
  producto_id              uuid PRIMARY KEY,
  costo_estimado_centavos  bigint NOT NULL CHECK (costo_estimado_centavos BETWEEN 0 AND 9007199254740991),
  actualizado_por          uuid,
  actualizado_en           timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id)
);
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.servicio_costo FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.servicio_costo
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El costo estimado se cambia, no se borra.');

INSERT INTO public.unidad (codigo, nombre) VALUES
  ('SERV', 'Servicio'), ('HORA', 'Hora'), ('SES', 'Sesión'), ('MES', 'Mes')
ON CONFLICT DO NOTHING;

-- Un bien con movimientos de inventario no pasa a servicio (en 028 se
-- agrega: un servicio que ya se vendió no pasa a bien).
CREATE FUNCTION interno.tipo_producto_fijo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.tipo IS DISTINCT FROM OLD.tipo AND OLD.tipo = 'bien'
     AND EXISTS (SELECT 1 FROM public.inventario_movimiento m WHERE m.producto_id = NEW.id) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el producto % ya tiene movimientos de inventario; no puede pasar a servicio.', NEW.codigo;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tipo_fijo BEFORE UPDATE OF tipo ON public.producto FOR EACH ROW EXECUTE FUNCTION interno.tipo_producto_fijo();

-- Datos del producto (reemplaza la de 020; misma firma): el impuesto es un
-- código ACTIVO de la tabla de la empresa (ya no una lista fija).
CREATE OR REPLACE FUNCTION interno.aplicar_datos_producto(p public.producto, p_datos jsonb) RETURNS public.producto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_claves(p_datos, ARRAY['codigo','codigo_barras','nombre','categoria_id','unidad_id',
    'tipo_impuesto','precio_venta_centavos','precio_incluye_isv','stock_minimo','permite_fracciones','campos_extra']);

  IF p_datos ? 'codigo' THEN
    p.codigo := upper(interno.json_texto(p_datos->'codigo', 'codigo', 30));
    IF p.codigo IS NULL OR p.codigo !~ '^[A-Z0-9._/-]{1,30}$' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el código interno lleva letras, números, punto, guion o barra (máx. 30), ej. TOR-001.';
    END IF;
  END IF;
  IF p_datos ? 'codigo_barras' THEN
    p.codigo_barras := interno.json_texto(p_datos->'codigo_barras', 'codigo_barras', 48);
    IF p.codigo_barras IS NOT NULL AND p.codigo_barras !~ '^[A-Za-z0-9-]{4,48}$' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el código de barras lleva de 4 a 48 letras o números.';
    END IF;
  END IF;
  IF p_datos ? 'nombre' THEN
    p.nombre := interno.json_texto(p_datos->'nombre', 'nombre', 200);
    IF p.nombre IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre del producto.';
    END IF;
  END IF;
  IF p_datos ? 'categoria_id' THEN
    v_id := interno.json_uuid(p_datos->'categoria_id', 'categoria_id');
    IF v_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.categoria_producto c
                                         WHERE c.id = v_id AND c.empresa_id = p.empresa_id AND c.activa) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la categoría no existe en esta empresa o está desactivada.';
    END IF;
    p.categoria_id := v_id;
  END IF;
  IF p_datos ? 'unidad_id' THEN
    v_id := interno.json_uuid(p_datos->'unidad_id', 'unidad_id');
    IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.unidad u WHERE u.id = v_id AND u.activa
                                     AND (u.empresa_id IS NULL OR u.empresa_id = p.empresa_id)) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la unidad de medida no existe o está desactivada.';
    END IF;
    p.unidad_id := v_id;
  END IF;
  IF p_datos ? 'tipo_impuesto' THEN
    p.tipo_impuesto := upper(interno.json_texto(p_datos->'tipo_impuesto', 'tipo_impuesto', 15));
    PERFORM interno.impuesto_de(p.empresa_id, p.tipo_impuesto, true);
  END IF;
  IF p_datos ? 'precio_venta_centavos' THEN
    p.precio_venta_centavos := interno.json_centavos(p_datos->'precio_venta_centavos', 'precio_venta_centavos');
  END IF;
  IF p_datos ? 'precio_incluye_isv' THEN
    p.precio_incluye_isv := interno.json_si_no(p_datos->'precio_incluye_isv', 'precio_incluye_isv');
  END IF;
  IF p_datos ? 'stock_minimo' THEN
    IF jsonb_typeof(p_datos->'stock_minimo') <> 'number' OR (p_datos->>'stock_minimo')::numeric < 0
       OR (p_datos->>'stock_minimo')::numeric >= 100000000000000
       OR (p_datos->>'stock_minimo')::numeric <> round((p_datos->>'stock_minimo')::numeric, 4) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el stock mínimo es un número de 0 o más (hasta 4 decimales).';
    END IF;
    p.stock_minimo := (p_datos->>'stock_minimo')::numeric;
  END IF;
  IF p_datos ? 'permite_fracciones' THEN
    p.permite_fracciones := interno.json_si_no(p_datos->'permite_fracciones', 'permite_fracciones');
  END IF;
  p.campos_extra := interno.validar_campos_extra(p.empresa_id, 'producto', p.campos_extra, p_datos->'campos_extra');
  RETURN p;
END $$;

-- "tipo" y "costo_estimado_centavos" de los datos (crear y editar).
CREATE FUNCTION interno.datos_servicio(p_empresa_id uuid, p_datos jsonb, p_tipo_actual text,
                                       OUT o_tipo text, OUT o_costo bigint, OUT o_hay_costo boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  o_tipo := coalesce(interno.json_texto(p_datos->'tipo', 'tipo', 10), p_tipo_actual, 'bien');
  IF o_tipo NOT IN ('bien', 'servicio') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo de producto es "bien" (lleva inventario) o "servicio" (no lleva inventario).';
  END IF;
  IF o_tipo = 'servicio' AND o_tipo IS DISTINCT FROM p_tipo_actual
     AND NOT coalesce((SELECT e.permite_servicios FROM public.empresa e WHERE e.id = p_empresa_id), false) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la empresa no tiene activados los servicios (el dueño los activa en Ajustes).';
  END IF;
  o_hay_costo := p_datos ? 'costo_estimado_centavos';
  IF o_hay_costo THEN
    IF o_tipo <> 'servicio' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el costo estimado es solo para servicios (el costo de un bien sale del kardex).';
    END IF;
    IF NOT public.tiene_permiso('inventario.costos', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: el costo estimado pide el permiso "inventario.costos".';
    END IF;
    IF p_datos->'costo_estimado_centavos' <> 'null'::jsonb THEN
      o_costo := interno.json_centavos(p_datos->'costo_estimado_centavos', 'costo_estimado_centavos');
    END IF;
  END IF;
END $$;

-- crear_producto (reemplaza la envoltura de 021; misma firma). Nuevo:
-- "tipo" (bien | servicio) y "costo_estimado_centavos" (servicios). Sin
-- "tipo_impuesto": el impuesto predeterminado de la empresa.
CREATE OR REPLACE FUNCTION public.crear_producto(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s     record;
  v_dat jsonb;
  r     jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'producto');
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'producto');
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  SELECT * INTO s FROM interno.datos_servicio(p_empresa_id, p_datos, NULL);
  v_dat := p_datos - 'tipo' - 'costo_estimado_centavos';
  IF NOT v_dat ? 'tipo_impuesto' THEN
    v_dat := v_dat || jsonb_build_object('tipo_impuesto', coalesce(
      (SELECT i.codigo FROM public.impuesto i WHERE i.empresa_id = p_empresa_id AND i.predeterminado AND i.activo),
      (SELECT i.codigo FROM public.impuesto i WHERE i.empresa_id = p_empresa_id AND i.activo ORDER BY i.orden, i.codigo LIMIT 1),
      'ISV15'));
  END IF;
  r := interno.crear_producto_base(p_empresa_id, v_dat, p_id_operacion);
  IF NOT (r->>'duplicado')::boolean THEN
    IF s.o_tipo <> 'bien' THEN
      UPDATE public.producto SET tipo = s.o_tipo WHERE id = (r->>'producto_id')::uuid;
    END IF;
    IF s.o_costo IS NOT NULL THEN
      INSERT INTO public.servicio_costo (empresa_id, producto_id, costo_estimado_centavos, actualizado_por)
      VALUES (p_empresa_id, (r->>'producto_id')::uuid, s.o_costo, auth.uid());
    END IF;
  END IF;
  RETURN r || jsonb_build_object('tipo', (SELECT x.tipo FROM public.producto x WHERE x.id = (r->>'producto_id')::uuid));
END $$;

-- editar_producto (reemplaza la de 020; misma firma). Nuevo: "tipo" y
-- "costo_estimado_centavos" (null lo quita).
CREATE OR REPLACE FUNCTION public.editar_producto(p_empresa_id uuid, p_producto_id uuid, p_datos jsonb,
                                                  p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_antes public.producto;
  p       public.producto;
  v_datos jsonb;
  s       record;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  IF p_datos ? 'precio_venta_centavos' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el precio se cambia con "cambiar precio" (queda en el historial con motivo).';
  END IF;
  SELECT * INTO v_antes FROM public.producto WHERE id = p_producto_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_antes.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
  END IF;
  SELECT * INTO s FROM interno.datos_servicio(p_empresa_id, p_datos, v_antes.tipo);
  v_datos := p_datos - 'tipo' - 'costo_estimado_centavos';
  p := v_antes;
  IF v_datos ? 'activo' THEN
    p.activo := interno.json_si_no(v_datos->'activo', 'activo');
    IF p.activo IS DISTINCT FROM v_antes.activo AND length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se activa o desactiva el producto (mínimo 5 letras).';
    END IF;
    v_datos := v_datos - 'activo';
  END IF;
  p := interno.aplicar_datos_producto(p, v_datos);
  IF p.precio_incluye_isv IS DISTINCT FROM v_antes.precio_incluye_isv THEN
    IF NOT public.tiene_permiso('productos.precios', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: cambiar si el precio incluye ISV pide el permiso "productos.precios".';
    END IF;
    IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué cambia "precio incluye ISV" (mínimo 5 letras); queda en el historial de precios.';
    END IF;
  END IF;

  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  BEGIN
    UPDATE public.producto SET
      codigo = p.codigo, codigo_barras = p.codigo_barras, nombre = p.nombre, categoria_id = p.categoria_id,
      unidad_id = p.unidad_id, tipo_impuesto = p.tipo_impuesto, stock_minimo = p.stock_minimo,
      permite_fracciones = p.permite_fracciones, campos_extra = p.campos_extra, activo = p.activo,
      precio_incluye_isv = p.precio_incluye_isv, tipo = s.o_tipo
    WHERE id = p_producto_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ese código o código de barras ya es de otro producto.';
  END;
  IF s.o_hay_costo THEN
    INSERT INTO public.servicio_costo (empresa_id, producto_id, costo_estimado_centavos, actualizado_por)
    VALUES (p_empresa_id, p_producto_id, coalesce(s.o_costo, 0), auth.uid())
    ON CONFLICT (producto_id) DO UPDATE
       SET costo_estimado_centavos = excluded.costo_estimado_centavos, actualizado_por = excluded.actualizado_por, actualizado_en = now();
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('producto_id', p_producto_id, 'tipo', s.o_tipo, 'editado', true);
END $$;

-- Motor de inventario (reemplaza el de 021; igual más: un SERVICIO no
-- entra al kardex). Así ninguna compra, ajuste, traslado o carga le crea existencia.
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
  v_q      numeric;
  v_mov    bigint;
  v_sale   bigint;
  v_v      bigint;
  v_prom   numeric;
  v_codigo text;
  v_fracc  boolean;
  v_ptipo  text;
  v_ultima date;
  v_suc    uuid;
BEGIN
  IF p_cantidad IS NULL OR p_cantidad = 0 THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: un movimiento de inventario necesita cantidad.';
  END IF;
  SELECT p.codigo, p.permite_fracciones, p.tipo INTO v_codigo, v_fracc, v_ptipo
    FROM public.producto p WHERE p.id = p_producto_id FOR SHARE;
  IF v_ptipo = 'servicio' THEN
    RAISE EXCEPTION 'PRODUCTO_INVALIDO: % es un servicio; los servicios no llevan inventario.', v_codigo;
  END IF;
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

-- v_producto (reemplaza la de 020: mismas columnas y al final tipo,
-- impuesto y costo estimado). El precio con y sin impuesto sale de la tabla.
CREATE OR REPLACE VIEW public.v_producto WITH (security_invoker = true) AS
  SELECT p.empresa_id, p.id AS producto_id, p.codigo, p.codigo_barras, p.nombre,
         p.categoria_id, c.nombre AS categoria, p.unidad_id, u.codigo AS unidad,
         p.tipo_impuesto, p.precio_venta_centavos, p.precio_incluye_isv,
         x.sin_isv_centavos AS precio_sin_isv_centavos, x.isv_centavos, x.con_isv_centavos AS precio_con_isv_centavos,
         p.stock_minimo, p.permite_fracciones, p.activo, p.campos_extra, p.actualizado_en,
         p.tipo, i.nombre AS impuesto, i.porcentaje AS impuesto_porcentaje, i.clase AS impuesto_clase,
         sc.costo_estimado_centavos
  FROM public.producto p
  JOIN public.unidad u ON u.id = p.unidad_id
  JOIN public.impuesto i ON i.empresa_id = p.empresa_id AND i.codigo = p.tipo_impuesto
  LEFT JOIN public.categoria_producto c ON c.id = p.categoria_id
  LEFT JOIN public.servicio_costo sc ON sc.producto_id = p.id      -- sin inventario.costos: vacío (RLS)
  CROSS JOIN LATERAL public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, i.porcentaje) x;

-- buscar_producto_por_codigo (reemplaza la de 020; misma firma): impuesto
-- de la tabla y el tipo (un servicio no trae existencias).
CREATE OR REPLACE FUNCTION public.buscar_producto_por_codigo(p_empresa_id uuid, p_codigo text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cod    text := trim(coalesce(p_codigo, ''));
  p        public.producto;
  v_por    text;
  v_exist  jsonb;
  v_costos boolean;
  x        record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  IF v_cod = '' THEN
    RETURN jsonb_build_object('encontrado', false, 'codigo', v_cod);
  END IF;
  SELECT * INTO p FROM public.producto z WHERE z.empresa_id = p_empresa_id AND z.codigo_barras = v_cod;
  v_por := 'codigo_barras';
  IF p.id IS NULL THEN
    SELECT * INTO p FROM public.producto z WHERE z.empresa_id = p_empresa_id AND z.codigo = upper(v_cod);
    v_por := 'codigo';
  END IF;
  IF p.id IS NULL THEN
    RETURN jsonb_build_object('encontrado', false, 'codigo', v_cod);
  END IF;

  v_costos := public.tiene_permiso('inventario.costos', p_empresa_id);
  IF p.tipo = 'bien' AND public.tiene_permiso('inventario.ver', p_empresa_id) THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'bodega_id', b.id, 'bodega', b.codigo, 'cantidad', s.cantidad,
             'costo_promedio', CASE WHEN v_costos THEN s.costo_promedio END)
             ORDER BY b.codigo), '[]')
      INTO v_exist
      FROM public.inventario_saldo s JOIN public.bodega b ON b.id = s.bodega_id
     WHERE s.producto_id = p.id AND b.activa;
  END IF;
  SELECT * INTO x FROM public.precio_impuesto(p_empresa_id, p.precio_venta_centavos, p.precio_incluye_isv, p.tipo_impuesto);

  RETURN jsonb_build_object(
    'encontrado', true, 'por', v_por,
    'producto', jsonb_build_object(
      'id', p.id, 'codigo', p.codigo, 'codigo_barras', p.codigo_barras, 'nombre', p.nombre, 'tipo', p.tipo,
      'unidad', (SELECT u.codigo FROM public.unidad u WHERE u.id = p.unidad_id),
      'tipo_impuesto', p.tipo_impuesto, 'precio_venta_centavos', p.precio_venta_centavos,
      'precio_incluye_isv', p.precio_incluye_isv, 'precio_sin_isv_centavos', x.sin_isv_centavos,
      'isv_centavos', x.isv_centavos, 'precio_con_isv_centavos', x.con_isv_centavos,
      'permite_fracciones', p.permite_fracciones, 'activo', p.activo, 'campos_extra', p.campos_extra),
    'existencias', v_exist);
END $$;

-- ---------------------------------------------------------------------
-- 3) Seguridad
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['impuesto', 'servicio_costo'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
CREATE POLICY leer ON public.impuesto FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.servicio_costo FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))));
REVOKE ALL ON interno.plantilla_impuesto FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  interno.proteger_impuesto(),
  interno.sembrar_impuestos(),
  interno.impuesto_de(uuid, text, boolean),
  interno.tipo_producto_fijo(),
  interno.datos_servicio(uuid, jsonb, text)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.precio_con_tasa(bigint, boolean, numeric, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.precio_con_tasa(bigint, boolean, numeric, numeric) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.precio_impuesto(uuid, bigint, boolean, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.precio_impuesto(uuid, bigint, boolean, text, numeric) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.configurar_impuesto(uuid, jsonb, text) FROM PUBLIC, anon, service_role;
GRANT  EXECUTE ON FUNCTION public.configurar_impuesto(uuid, jsonb, text) TO authenticated;
