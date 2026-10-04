-- =====================================================================
-- 043_conciliacion.sql  -  Núcleo 0.11.0 (etapa 3b-1): conciliación bancaria
-- (módulo "conciliacion", necesita "dinero").
--
--   conciliacion          una por cuenta bancaria y mes (abierta / cerrada). Al
--                         cerrar guarda su FOTO (resumen_cierre) y ya no cambia.
--   banco_importacion     cada vez que se carga el estado de cuenta (la app
--                         convierte el CSV del banco en filas JSON).
--   banco_movimiento      una fila del estado de cuenta: fecha, descripción,
--                         referencia y monto con signo (+ entra al banco, - sale).
--                         Solo agregar. La misma fila cargada dos veces no se repite
--                         (huella: fecha, monto, referencia, descripción y el número
--                         de vez que se repite igual dentro del archivo).
--   conciliacion_pareja   fila del banco <-> movimiento del sistema (dinero_movimiento):
--                         automatico | manual | creado (el movimiento se creó desde la
--                         diferencia del banco) | anterior (movimiento de antes de la
--                         primera conciliación que ya estaba en el banco; sin fila).
--                         Se deshace con motivo mientras su conciliación esté abierta
--                         (nunca se borra: queda "deshecha").
--   banco_diferencia      movimiento faltante creado desde una fila del banco
--                         (comisión bancaria, intereses u otra cuenta) con su asiento
--                         y su rastro de dinero.
--
-- Cuadre al cerrar (al último día del mes):
--   saldo del banco = saldo del sistema
--                     - lo que está en el sistema y todavía no en el banco
--                     + lo que está en el banco y todavía no en el sistema
--   (el saldo inicial de la cuenta de dinero es la apertura: no queda pendiente).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('CONCILIACION_CERRADA', 'Esa conciliación bancaria ya está cerrada.', 'Lo que falte se trabaja en la conciliación del mes siguiente.'),
  ('CONCILIACION_NO_CUADRA', 'El saldo del banco no cuadra con el sistema y sus partidas pendientes.',
   'Revise las diferencias: empareje lo que falta o cree el movimiento faltante (comisión, intereses) desde la fila del banco.'),
  ('CONCILIACION_EN_ORDEN', 'Hay un mes anterior de esta cuenta sin conciliar.', 'Cierre primero la conciliación del mes anterior.'),
  ('NO_EMPAREJA', 'Esa fila del banco y ese movimiento no se pueden emparejar.',
   'Deben ser de la misma cuenta, por el mismo monto y no estar emparejados ya. Si el monto es distinto, cree el movimiento faltante por la diferencia.'),
  ('YA_CONCILIADO', 'Esa fila del banco o ese movimiento ya está conciliado.', 'Si el emparejamiento está mal, deshágalo con su motivo y vuelva a emparejar.');

INSERT INTO public.modulo (codigo, nombre) VALUES ('conciliacion', 'Conciliación bancaria');
INSERT INTO public.modulo_dependencia (modulo, requiere, motivo) VALUES
  ('conciliacion', 'dinero', 'Se concilian las cuentas bancarias del módulo de dinero contra el estado de cuenta del banco.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('conciliacion.ver',       'Ver las conciliaciones bancarias y sus diferencias', false, true),
  ('conciliacion.conciliar', 'Cargar el estado de cuenta del banco, emparejar, deshacer y cerrar la conciliación', false, false),
  ('conciliacion.registrar', 'Crear desde el estado de cuenta el movimiento que falta (comisión, intereses)', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'conciliacion.ver'), ('dueno', 'conciliacion.conciliar'), ('dueno', 'conciliacion.registrar'),
  ('admin', 'conciliacion.ver'), ('admin', 'conciliacion.conciliar'), ('admin', 'conciliacion.registrar'),
  ('contador', 'conciliacion.ver');
SELECT interno.repartir_permisos(ARRAY['conciliacion.ver', 'conciliacion.conciliar', 'conciliacion.registrar'],
  'Núcleo 0.11.0: conciliación bancaria');

-- Cuentas para los movimientos que solo conoce el banco (ya están en la plantilla).
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('comisiones_bancarias', '6.2.01.02', 'Comisiones y cargos del banco (desde la conciliación)', NULL),
  ('intereses_pagados',    '6.2.01.01', 'Intereses que cobra el banco (desde la conciliación)', NULL),
  ('intereses_ganados',    '4.2.01.01', 'Intereses que paga el banco (desde la conciliación)', NULL);
DO $$
DECLARE e record;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.11.0: cuentas de la conciliación bancaria', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    PERFORM interno.asegurar_cuenta_uso(e.id, 'comisiones_bancarias', 'Comisiones bancarias');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'intereses_pagados', 'Intereses');
    PERFORM interno.asegurar_cuenta_uso(e.id, 'intereses_ganados', 'Ingresos financieros');
  END LOOP;
  PERFORM set_config('app.motivo', '', true);
END $$;

-- ---------------------------------------------------------------------
-- 1) Tablas
-- ---------------------------------------------------------------------
CREATE TABLE public.conciliacion (
  id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                    uuid NOT NULL REFERENCES public.empresa(id),
  cuenta_dinero_id              uuid NOT NULL,
  anio                          integer NOT NULL CHECK (anio BETWEEN 2000 AND 2100),
  mes                           integer NOT NULL CHECK (mes BETWEEN 1 AND 12),
  estado                        text NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta', 'cerrada')),
  dias_tolerancia               integer NOT NULL DEFAULT 3 CHECK (dias_tolerancia BETWEEN 0 AND 15),
  saldo_banco_inicial_centavos  bigint,           -- lo que dice el estado de cuenta (opcional)
  saldo_banco_final_centavos    bigint,           -- lo que dice el estado de cuenta (obligatorio para cerrar)
  cerrada_en                    timestamptz,
  cerrada_por                   uuid,
  resumen_cierre                jsonb,            -- la foto al cerrar
  creado_por                    uuid,
  creado_en                     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (cuenta_dinero_id, anio, mes),
  FOREIGN KEY (empresa_id, cuenta_dinero_id) REFERENCES public.cuenta_dinero(empresa_id, id),
  CHECK ((estado = 'cerrada') = (cerrada_en IS NOT NULL)),
  CHECK (estado = 'abierta' OR (resumen_cierre IS NOT NULL AND saldo_banco_final_centavos IS NOT NULL))
);

CREATE TABLE public.banco_importacion (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id       uuid NOT NULL REFERENCES public.empresa(id),
  conciliacion_id  uuid NOT NULL,
  archivo          text,
  filas_recibidas  integer NOT NULL,
  filas_nuevas     integer NOT NULL,
  filas_repetidas  integer NOT NULL,
  id_operacion     uuid NOT NULL,
  creado_por       uuid,
  creado_en        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, conciliacion_id) REFERENCES public.conciliacion(empresa_id, id)
);

CREATE TABLE public.banco_movimiento (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id        uuid NOT NULL REFERENCES public.empresa(id),
  conciliacion_id   uuid NOT NULL,
  importacion_id    uuid NOT NULL,
  cuenta_dinero_id  uuid NOT NULL,
  fila              integer NOT NULL,                 -- número de fila en el archivo
  fecha             date NOT NULL,
  descripcion       text NOT NULL CHECK (length(trim(descripcion)) BETWEEN 1 AND 200),
  referencia        text CHECK (referencia IS NULL OR length(referencia) <= 100),
  monto_centavos    bigint NOT NULL CHECK (monto_centavos <> 0 AND abs(monto_centavos) <= 9007199254740991),
  huella            text NOT NULL,
  registrado_en     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (cuenta_dinero_id, huella),
  FOREIGN KEY (empresa_id, conciliacion_id)  REFERENCES public.conciliacion(empresa_id, id),
  FOREIGN KEY (empresa_id, importacion_id)   REFERENCES public.banco_importacion(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_dinero_id) REFERENCES public.cuenta_dinero(empresa_id, id)
);
CREATE INDEX banco_movimiento_cuenta_fecha ON public.banco_movimiento (cuenta_dinero_id, fecha);

CREATE TABLE public.conciliacion_pareja (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id            uuid NOT NULL REFERENCES public.empresa(id),
  conciliacion_id       uuid NOT NULL,                       -- dónde se hizo
  banco_movimiento_id   uuid,                                -- NULL solo en "anterior"
  dinero_movimiento_id  bigint NOT NULL REFERENCES public.dinero_movimiento(id),
  tipo                  text NOT NULL CHECK (tipo IN ('automatico', 'manual', 'creado', 'anterior')),
  motivo                text,
  creado_por            uuid,
  creado_en             timestamptz NOT NULL DEFAULT now(),
  deshecha_en           timestamptz,
  deshecha_por          uuid,
  motivo_deshacer       text,
  FOREIGN KEY (empresa_id, conciliacion_id)     REFERENCES public.conciliacion(empresa_id, id),
  FOREIGN KEY (empresa_id, banco_movimiento_id) REFERENCES public.banco_movimiento(empresa_id, id),
  CHECK ((tipo = 'anterior') = (banco_movimiento_id IS NULL)),
  CHECK ((deshecha_en IS NULL) = (motivo_deshacer IS NULL))
);
CREATE UNIQUE INDEX conciliacion_pareja_banco ON public.conciliacion_pareja (banco_movimiento_id) WHERE deshecha_en IS NULL;
CREATE UNIQUE INDEX conciliacion_pareja_dinero ON public.conciliacion_pareja (dinero_movimiento_id) WHERE deshecha_en IS NULL;

CREATE TABLE public.banco_diferencia (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id           uuid NOT NULL REFERENCES public.empresa(id),
  banco_movimiento_id  uuid NOT NULL UNIQUE,
  tipo                 text NOT NULL CHECK (tipo IN ('comision_bancaria', 'interes', 'otro')),
  cuenta_id            uuid NOT NULL,              -- la contrapartida (gasto o ingreso)
  monto_centavos       bigint NOT NULL CHECK (monto_centavos <> 0),
  fecha_contable       date NOT NULL,
  descripcion          text NOT NULL,
  asiento_id           uuid NOT NULL,
  id_operacion         uuid NOT NULL,
  creado_por           uuid,
  registrado_en        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, banco_movimiento_id) REFERENCES public.banco_movimiento(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_id)           REFERENCES public.cuenta(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)          REFERENCES public.asiento(empresa_id, id)
);

-- Defensas: nada se borra; solo cambia lo que se llena una vez.
CREATE FUNCTION interno.proteger_conciliacion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c constant text[] := ARRAY['estado', 'saldo_banco_inicial_centavos', 'saldo_banco_final_centavos', 'dias_tolerancia',
                                   'cerrada_en', 'cerrada_por', 'resumen_cierre'];
BEGIN
  IF OLD.estado = 'abierta' AND (to_jsonb(NEW) - c) = (to_jsonb(OLD) - c) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'CONCILIACION_CERRADA: la conciliación de %/% ya está cerrada; no cambia.', lpad(OLD.mes::text, 2, '0'), OLD.anio;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.conciliacion FOR EACH ROW EXECUTE FUNCTION interno.proteger_conciliacion();

CREATE FUNCTION interno.proteger_conciliacion_pareja() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c constant text[] := ARRAY['deshecha_en', 'deshecha_por', 'motivo_deshacer'];
BEGIN
  IF OLD.deshecha_en IS NULL AND NEW.deshecha_en IS NOT NULL AND (to_jsonb(NEW) - c) = (to_jsonb(OLD) - c) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: un emparejamiento no se edita; se deshace una vez con su motivo.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.conciliacion_pareja FOR EACH ROW EXECUTE FUNCTION interno.proteger_conciliacion_pareja();
CREATE TRIGGER inmutable BEFORE UPDATE ON public.banco_importacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Una carga del estado de cuenta no se edita.');
CREATE TRIGGER inmutable BEFORE UPDATE ON public.banco_movimiento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las filas del estado de cuenta no se editan.');
CREATE TRIGGER inmutable BEFORE UPDATE ON public.banco_diferencia
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Un movimiento creado desde la conciliación no se edita.');
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['conciliacion', 'banco_importacion', 'banco_movimiento', 'conciliacion_pareja', 'banco_diferencia'] LOOP
    EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.auditar()', t);
    EXECUTE format('CREATE TRIGGER no_borrar BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'La conciliación bancaria no se borra (los emparejamientos se deshacen con motivo).');
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.');
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', t, 'conciliacion.ver');
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 2) Ayudantes
-- ---------------------------------------------------------------------
-- Una conciliación de la empresa, bloqueada para escribir (y el candado de su cuenta).
CREATE FUNCTION interno.conciliacion_para_escribir(p_conciliacion_id uuid, p_permiso text) RETURNS public.conciliacion
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.conciliacion;
BEGIN
  SELECT * INTO c FROM public.conciliacion WHERE id = p_conciliacion_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la conciliación no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, p_permiso, 'conciliacion');
  PERFORM pg_advisory_xact_lock(hashtext('conciliacion:' || c.cuenta_dinero_id::text));
  SELECT * INTO c FROM public.conciliacion WHERE id = p_conciliacion_id FOR UPDATE;
  IF c.estado = 'cerrada' THEN
    RAISE EXCEPTION 'CONCILIACION_CERRADA: la conciliación de %/% ya está cerrada.', lpad(c.mes::text, 2, '0'), c.anio;
  END IF;
  RETURN c;
END $$;

-- Último día del mes de una conciliación.
CREATE FUNCTION interno.fin_conciliacion(c public.conciliacion) RETURNS date
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT (make_date(c.anio, c.mes, 1) + interval '1 month' - interval '1 day')::date
$$;

-- Movimientos del sistema que cuentan en la conciliación (el saldo inicial es la apertura).
CREATE FUNCTION interno.mov_conciliable(m public.dinero_movimiento) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT m.operacion <> 'dinero_saldo_inicial'
$$;

-- Emparejamiento automático: por monto exacto y fecha (± días de tolerancia); entre
-- varios candidatos gana el que coincide en referencia, después el de fecha más cercana.
CREATE FUNCTION interno.emparejar_automatico(c public.conciliacion) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  b      public.banco_movimiento;
  v_fin  date := interno.fin_conciliacion(c);
  v_mid  bigint;
  n      integer := 0;
BEGIN
  FOR b IN SELECT x.* FROM public.banco_movimiento x
            WHERE x.cuenta_dinero_id = c.cuenta_dinero_id AND x.fecha <= v_fin
              AND NOT EXISTS (SELECT 1 FROM public.conciliacion_pareja p WHERE p.banco_movimiento_id = x.id AND p.deshecha_en IS NULL)
            ORDER BY x.fecha, x.fila, x.id LOOP
    SELECT m.id INTO v_mid FROM public.dinero_movimiento m
     WHERE m.cuenta_dinero_id = c.cuenta_dinero_id AND m.monto_centavos = b.monto_centavos AND interno.mov_conciliable(m)
       AND abs(m.fecha_contable - b.fecha) <= c.dias_tolerancia
       AND NOT EXISTS (SELECT 1 FROM public.conciliacion_pareja p WHERE p.dinero_movimiento_id = m.id AND p.deshecha_en IS NULL)
     ORDER BY (b.referencia IS NOT NULL AND m.referencia IS NOT NULL
               AND (strpos(lower(m.referencia), lower(b.referencia)) > 0 OR strpos(lower(b.referencia), lower(m.referencia)) > 0)) DESC,
              abs(m.fecha_contable - b.fecha), m.id
     LIMIT 1;
    IF v_mid IS NOT NULL THEN
      INSERT INTO public.conciliacion_pareja (empresa_id, conciliacion_id, banco_movimiento_id, dinero_movimiento_id, tipo, creado_por)
      VALUES (c.empresa_id, c.id, b.id, v_mid, 'automatico', auth.uid());
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- El cálculo de una conciliación (en vivo) al último día de su mes.
CREATE FUNCTION interno.calcular_conciliacion(c public.conciliacion) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_fin      date := interno.fin_conciliacion(c);
  v_ini      date := make_date(c.anio, c.mes, 1);
  d          public.cuenta_dinero;
  v_sis      bigint;
  v_ps       bigint;
  v_pb       bigint;
  v_filas    bigint;
  j_ps       jsonb;
  j_pb       jsonb;
  j_ok       jsonb;
BEGIN
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = c.cuenta_dinero_id;
  SELECT coalesce(sum(m.monto_centavos), 0) INTO v_sis FROM public.dinero_movimiento m
   WHERE m.cuenta_dinero_id = c.cuenta_dinero_id AND m.fecha_contable <= v_fin;
  -- En el sistema y todavía no en el banco (al fin del mes).
  SELECT coalesce(sum(m.monto_centavos), 0),
         coalesce(jsonb_agg(jsonb_build_object('dinero_movimiento_id', m.id, 'fecha', to_char(m.fecha_contable, 'YYYY-MM-DD'),
           'monto_centavos', m.monto_centavos, 'operacion', m.operacion, 'detalle', m.contrapartida, 'referencia', m.referencia)
           ORDER BY m.fecha_contable, m.id), '[]')
    INTO v_ps, j_ps
    FROM public.dinero_movimiento m
   WHERE m.cuenta_dinero_id = c.cuenta_dinero_id AND m.fecha_contable <= v_fin AND interno.mov_conciliable(m)
     AND NOT EXISTS (SELECT 1 FROM public.conciliacion_pareja p LEFT JOIN public.banco_movimiento b ON b.id = p.banco_movimiento_id
                      WHERE p.dinero_movimiento_id = m.id AND p.deshecha_en IS NULL AND (b.id IS NULL OR b.fecha <= v_fin));
  -- En el banco y todavía no en el sistema (al fin del mes).
  SELECT coalesce(sum(b.monto_centavos), 0),
         coalesce(jsonb_agg(jsonb_build_object('banco_movimiento_id', b.id, 'fecha', to_char(b.fecha, 'YYYY-MM-DD'),
           'monto_centavos', b.monto_centavos, 'descripcion', b.descripcion, 'referencia', b.referencia) ORDER BY b.fecha, b.fila), '[]')
    INTO v_pb, j_pb
    FROM public.banco_movimiento b
   WHERE b.cuenta_dinero_id = c.cuenta_dinero_id AND b.fecha <= v_fin
     AND NOT EXISTS (SELECT 1 FROM public.conciliacion_pareja p JOIN public.dinero_movimiento m ON m.id = p.dinero_movimiento_id
                      WHERE p.banco_movimiento_id = b.id AND p.deshecha_en IS NULL AND m.fecha_contable <= v_fin);
  -- Lo emparejado de este mes (filas del banco del mes).
  SELECT coalesce(jsonb_agg(jsonb_build_object('pareja_id', p.id, 'tipo', p.tipo, 'banco_movimiento_id', b.id,
           'fecha_banco', to_char(b.fecha, 'YYYY-MM-DD'), 'descripcion', b.descripcion, 'dinero_movimiento_id', m.id,
           'fecha_sistema', to_char(m.fecha_contable, 'YYYY-MM-DD'), 'monto_centavos', m.monto_centavos, 'operacion', m.operacion)
           ORDER BY b.fecha, b.fila), '[]')
    INTO j_ok
    FROM public.conciliacion_pareja p JOIN public.banco_movimiento b ON b.id = p.banco_movimiento_id
    JOIN public.dinero_movimiento m ON m.id = p.dinero_movimiento_id
   WHERE b.cuenta_dinero_id = c.cuenta_dinero_id AND p.deshecha_en IS NULL AND b.fecha BETWEEN v_ini AND v_fin;
  SELECT coalesce(sum(b.monto_centavos), 0) INTO v_filas FROM public.banco_movimiento b
   WHERE b.cuenta_dinero_id = c.cuenta_dinero_id AND b.fecha BETWEEN v_ini AND v_fin;

  RETURN jsonb_build_object(
    'titulo', 'Conciliación bancaria', 'empresa', interno.encabezado_empresa(c.empresa_id),
    'conciliacion_id', c.id, 'cuenta_dinero_id', d.id, 'cuenta', d.nombre, 'banco', d.banco, 'numero_enmascarado', d.numero_enmascarado,
    'anio', c.anio, 'mes', c.mes, 'desde', to_char(v_ini, 'YYYY-MM-DD'), 'hasta', to_char(v_fin, 'YYYY-MM-DD'),
    'estado', c.estado, 'dias_tolerancia', c.dias_tolerancia,
    'saldo_sistema_centavos', v_sis,
    'en_sistema_no_en_banco_centavos', v_ps, 'en_sistema_no_en_banco', j_ps,
    'en_banco_no_en_sistema_centavos', v_pb, 'en_banco_no_en_sistema', j_pb,
    'saldo_banco_calculado_centavos', v_sis - v_ps + v_pb,
    'saldo_banco_inicial_centavos', c.saldo_banco_inicial_centavos,
    'saldo_banco_final_centavos', c.saldo_banco_final_centavos,
    'movimientos_banco_mes_centavos', v_filas,
    'estado_cuenta_completo', CASE WHEN c.saldo_banco_inicial_centavos IS NULL OR c.saldo_banco_final_centavos IS NULL THEN NULL
                                   ELSE c.saldo_banco_inicial_centavos + v_filas = c.saldo_banco_final_centavos END,
    'diferencia_centavos', CASE WHEN c.saldo_banco_final_centavos IS NULL THEN NULL
                                ELSE c.saldo_banco_final_centavos - (v_sis - v_ps + v_pb) END,
    'cuadra', CASE WHEN c.saldo_banco_final_centavos IS NULL THEN NULL
                   ELSE c.saldo_banco_final_centavos = v_sis - v_ps + v_pb END,
    'conciliados', j_ok,
    'nota', 'Saldo del banco = saldo del sistema - lo que está en el sistema y no en el banco + lo que está en el banco y no en el sistema.');
END $$;

-- ---------------------------------------------------------------------
-- 3) RPC
-- ---------------------------------------------------------------------
-- importar_estado_cuenta(empresa, cuenta_bancaria, año, mes, datos, id_operacion)   conciliacion.conciliar
--   {"archivo":"bac_enero.csv","saldo_inicial_centavos":1000000,"saldo_final_centavos":883984,"dias_tolerancia":3,
--    "filas":[{"fecha":"2026-01-22","descripcion":"PAGO ENEE","referencia":"123","monto_centavos":-11500}, ...]}
-- Crea la conciliación del mes si no existe, guarda las filas nuevas (las repetidas se
-- ignoran) y empareja solo. Las filas deben ser de ese mes.
CREATE FUNCTION public.importar_estado_cuenta(p_empresa_id uuid, p_cuenta_dinero_id uuid, p_anio integer, p_mes integer,
                                              p_datos jsonb, p_id_operacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d       public.cuenta_dinero;
  c       public.conciliacion;
  imp     public.banco_importacion;
  f       jsonb;
  i       integer := 0;
  v_ini   date;
  v_fin   date;
  v_fecha date;
  v_desc  text;
  v_ref   text;
  v_monto bigint;
  v_base  text;
  v_vistas jsonb := '{}';
  v_vez   integer;
  v_nuev  integer := 0;
  v_filas jsonb := '[]';
  v_auto  integer;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'conciliacion.conciliar', 'conciliacion');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'importar_estado_cuenta');
  SELECT * INTO imp FROM public.banco_importacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF imp.id IS NOT NULL THEN
    RETURN jsonb_build_object('conciliacion_id', imp.conciliacion_id, 'importacion_id', imp.id, 'filas_nuevas', imp.filas_nuevas,
                              'filas_repetidas', imp.filas_repetidas, 'duplicado', true);
  END IF;
  d := interno.cuenta_dinero_de(p_empresa_id, p_cuenta_dinero_id, false);
  IF d.tipo <> 'banco' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: solo se concilian cuentas de banco ("%" es %).', d.nombre, d.tipo;
  END IF;
  SELECT * INTO v_ini, v_fin FROM interno.rango_mes(p_empresa_id, p_anio, p_mes);
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos del estado de cuenta van en un objeto JSON.';
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['archivo', 'saldo_inicial_centavos', 'saldo_final_centavos', 'dias_tolerancia', 'filas']);
  IF jsonb_typeof(p_datos->'filas') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'filas') NOT BETWEEN 1 AND 5000 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "filas" es una lista de 1 a 5000 movimientos del estado de cuenta.';
  END IF;
  IF p_datos ? 'dias_tolerancia' AND (jsonb_typeof(p_datos->'dias_tolerancia') <> 'number'
     OR (p_datos->>'dias_tolerancia')::numeric NOT IN (0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15)) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "dias_tolerancia" es un número entero de 0 a 15.';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'importar_estado_cuenta');
  SELECT * INTO imp FROM public.banco_importacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF imp.id IS NOT NULL THEN
    RETURN jsonb_build_object('conciliacion_id', imp.conciliacion_id, 'importacion_id', imp.id, 'filas_nuevas', imp.filas_nuevas,
                              'filas_repetidas', imp.filas_repetidas, 'duplicado', true);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('conciliacion:' || d.id::text));
  INSERT INTO public.conciliacion (empresa_id, cuenta_dinero_id, anio, mes, creado_por)
  VALUES (p_empresa_id, d.id, p_anio, p_mes, auth.uid()) ON CONFLICT (cuenta_dinero_id, anio, mes) DO NOTHING;
  SELECT * INTO c FROM public.conciliacion x WHERE x.cuenta_dinero_id = d.id AND x.anio = p_anio AND x.mes = p_mes FOR UPDATE;
  IF c.estado = 'cerrada' THEN
    RAISE EXCEPTION 'CONCILIACION_CERRADA: la conciliación de %/% de "%" ya está cerrada.', lpad(p_mes::text, 2, '0'), p_anio, d.nombre;
  END IF;
  UPDATE public.conciliacion SET
    saldo_banco_inicial_centavos = CASE WHEN p_datos ? 'saldo_inicial_centavos' AND p_datos->'saldo_inicial_centavos' <> 'null'::jsonb
      THEN interno.json_entero_con_signo(p_datos->'saldo_inicial_centavos', 'saldo_inicial_centavos') ELSE saldo_banco_inicial_centavos END,
    saldo_banco_final_centavos = CASE WHEN p_datos ? 'saldo_final_centavos' AND p_datos->'saldo_final_centavos' <> 'null'::jsonb
      THEN interno.json_entero_con_signo(p_datos->'saldo_final_centavos', 'saldo_final_centavos') ELSE saldo_banco_final_centavos END,
    dias_tolerancia = coalesce((p_datos->>'dias_tolerancia')::integer, dias_tolerancia)
   WHERE id = c.id RETURNING * INTO c;

  -- Primero se validan todas las filas (si una está mal, no se guarda ninguna).
  FOR f IN SELECT x FROM jsonb_array_elements(p_datos->'filas') x LOOP
    i := i + 1;
    IF jsonb_typeof(f) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la fila % del estado de cuenta no es un objeto.', i;
    END IF;
    PERFORM interno.exigir_claves(f, ARRAY['fecha', 'descripcion', 'referencia', 'monto_centavos']);
    v_fecha := interno.json_fecha(f->'fecha', 'fecha (fila ' || i || ')');
    IF v_fecha IS NULL OR v_fecha NOT BETWEEN v_ini AND v_fin THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la fila % tiene fecha % y el estado de cuenta es de %/%.', i, coalesce(to_char(v_fecha, 'DD/MM/YYYY'), '(vacía)'),
        lpad(p_mes::text, 2, '0'), p_anio;
    END IF;
    v_desc := interno.json_texto(f->'descripcion', 'descripcion (fila ' || i || ')', 200);
    IF v_desc IS NULL OR trim(v_desc) = '' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la fila % no tiene descripción.', i;
    END IF;
    v_ref := nullif(trim(coalesce(interno.json_texto(f->'referencia', 'referencia (fila ' || i || ')', 100), '')), '');
    v_monto := interno.json_entero_con_signo(f->'monto_centavos', 'monto_centavos (fila ' || i || ')');
    IF v_monto IS NULL OR v_monto = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la fila % no tiene monto (centavos con signo: + entra al banco, - sale).', i;
    END IF;
    -- Huella: la misma fila cargada otra vez no se repite (la vez que se repite igual dentro del archivo cuenta).
    v_base := md5(to_char(v_fecha, 'YYYY-MM-DD') || '|' || v_monto || '|' || lower(coalesce(v_ref, '')) || '|' || lower(trim(v_desc)));
    v_vez := coalesce((v_vistas->>v_base)::integer, 0) + 1;
    v_vistas := v_vistas || jsonb_build_object(v_base, v_vez);
    v_filas := v_filas || jsonb_build_object('fila', i, 'fecha', v_fecha, 'descripcion', trim(v_desc), 'referencia', v_ref,
                                             'monto', v_monto, 'huella', v_base || ':' || v_vez);
  END LOOP;
  SELECT count(*) INTO v_nuev FROM jsonb_array_elements(v_filas) x
   WHERE NOT EXISTS (SELECT 1 FROM public.banco_movimiento b WHERE b.cuenta_dinero_id = d.id AND b.huella = x->>'huella');

  imp.id := gen_random_uuid();
  INSERT INTO public.banco_importacion (id, empresa_id, conciliacion_id, archivo, filas_recibidas, filas_nuevas, filas_repetidas,
                                        id_operacion, creado_por)
  VALUES (imp.id, p_empresa_id, c.id, interno.json_texto(p_datos->'archivo', 'archivo', 200), i, v_nuev, i - v_nuev,
          p_id_operacion, auth.uid());
  INSERT INTO public.banco_movimiento (empresa_id, conciliacion_id, importacion_id, cuenta_dinero_id, fila, fecha, descripcion,
                                       referencia, monto_centavos, huella)
  SELECT p_empresa_id, c.id, imp.id, d.id, x.fila, x.fecha, x.descripcion, x.referencia, x.monto, x.huella
    FROM jsonb_to_recordset(v_filas) AS x(fila integer, fecha date, descripcion text, referencia text, monto bigint, huella text)
  ON CONFLICT (cuenta_dinero_id, huella) DO NOTHING;
  v_auto := interno.emparejar_automatico(c);
  RETURN jsonb_build_object('conciliacion_id', c.id, 'importacion_id', imp.id, 'filas_recibidas', i, 'filas_nuevas', v_nuev,
    'filas_repetidas', i - v_nuev, 'emparejadas_automaticamente', v_auto, 'duplicado', false,
    'resumen', interno.calcular_conciliacion(c) - 'conciliados' - 'empresa');
END $$;

-- emparejar_conciliacion(conciliacion, dias?)   conciliacion.conciliar   vuelve a correr el emparejamiento automático.
CREATE FUNCTION public.emparejar_conciliacion(p_conciliacion_id uuid, p_dias_tolerancia integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.conciliacion;
        n integer;
BEGIN
  c := interno.conciliacion_para_escribir(p_conciliacion_id, 'conciliacion.conciliar');
  IF p_dias_tolerancia IS NOT NULL THEN
    IF p_dias_tolerancia NOT BETWEEN 0 AND 15 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: los días de tolerancia van de 0 a 15.';
    END IF;
    UPDATE public.conciliacion SET dias_tolerancia = p_dias_tolerancia WHERE id = c.id RETURNING * INTO c;
  END IF;
  n := interno.emparejar_automatico(c);
  RETURN jsonb_build_object('conciliacion_id', c.id, 'emparejadas_automaticamente', n,
                            'resumen', interno.calcular_conciliacion(c) - 'conciliados' - 'empresa');
END $$;

-- emparejar_manual(conciliacion, fila_banco, movimiento_sistema, motivo?)   conciliacion.conciliar
-- Mismo monto; la fecha puede ser cualquiera hasta el fin del mes de la conciliación.
CREATE FUNCTION public.emparejar_manual(p_conciliacion_id uuid, p_banco_movimiento_id uuid, p_dinero_movimiento_id bigint,
                                        p_motivo text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c     public.conciliacion;
  b     public.banco_movimiento;
  m     public.dinero_movimiento;
  v_id  uuid;
BEGIN
  c := interno.conciliacion_para_escribir(p_conciliacion_id, 'conciliacion.conciliar');
  SELECT * INTO b FROM public.banco_movimiento WHERE id = p_banco_movimiento_id AND empresa_id = c.empresa_id;
  SELECT * INTO m FROM public.dinero_movimiento WHERE id = p_dinero_movimiento_id AND empresa_id = c.empresa_id;
  IF b.id IS NULL OR m.id IS NULL OR b.cuenta_dinero_id <> c.cuenta_dinero_id OR m.cuenta_dinero_id <> c.cuenta_dinero_id THEN
    RAISE EXCEPTION 'NO_EMPAREJA: la fila del banco y el movimiento deben ser de la cuenta de esta conciliación.';
  END IF;
  IF b.monto_centavos <> m.monto_centavos THEN
    RAISE EXCEPTION 'NO_EMPAREJA: el banco dice % y el sistema %; los montos deben ser iguales.',
      interno.lempiras(b.monto_centavos), interno.lempiras(m.monto_centavos);
  END IF;
  IF b.fecha > interno.fin_conciliacion(c) OR m.fecha_contable > interno.fin_conciliacion(c) OR NOT interno.mov_conciliable(m) THEN
    RAISE EXCEPTION 'NO_EMPAREJA: solo se emparejan movimientos hasta el fin del mes de esta conciliación (y no el saldo inicial).';
  END IF;
  IF EXISTS (SELECT 1 FROM public.conciliacion_pareja p WHERE p.deshecha_en IS NULL
              AND (p.banco_movimiento_id = b.id OR p.dinero_movimiento_id = m.id)) THEN
    RAISE EXCEPTION 'YA_CONCILIADO: la fila del banco o el movimiento ya está emparejado.';
  END IF;
  INSERT INTO public.conciliacion_pareja (empresa_id, conciliacion_id, banco_movimiento_id, dinero_movimiento_id, tipo, motivo, creado_por)
  VALUES (c.empresa_id, c.id, b.id, m.id, 'manual', nullif(trim(coalesce(p_motivo, '')), ''), auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('pareja_id', v_id, 'conciliacion_id', c.id, 'resumen', interno.calcular_conciliacion(c) - 'conciliados' - 'empresa');
END $$;

-- deshacer_emparejamiento(pareja, motivo)   conciliacion.conciliar   (solo con la conciliación abierta)
CREATE FUNCTION public.deshacer_emparejamiento(p_pareja_id uuid, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p public.conciliacion_pareja;
  c public.conciliacion;
BEGIN
  SELECT * INTO p FROM public.conciliacion_pareja WHERE id = p_pareja_id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el emparejamiento no existe.';
  END IF;
  c := interno.conciliacion_para_escribir(p.conciliacion_id, 'conciliacion.conciliar');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se deshace el emparejamiento (mínimo 5 letras).';
  END IF;
  SELECT * INTO p FROM public.conciliacion_pareja WHERE id = p_pareja_id FOR UPDATE;
  IF p.deshecha_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: ese emparejamiento ya se deshizo.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.conciliacion_pareja SET deshecha_en = now(), deshecha_por = auth.uid(), motivo_deshacer = trim(p_motivo) WHERE id = p.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('pareja_id', p.id, 'deshecha', true, 'resumen', interno.calcular_conciliacion(c) - 'conciliados' - 'empresa');
END $$;

-- marcar_conciliados_anteriores(conciliacion, motivo)   conciliacion.conciliar
-- Solo en la PRIMERA conciliación de la cuenta: los movimientos de antes de su mes que
-- siguen sin emparejar se dan por conciliados (ya estaban en el banco antes de empezar).
CREATE FUNCTION public.marcar_conciliados_anteriores(p_conciliacion_id uuid, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.conciliacion;
  n integer;
BEGIN
  c := interno.conciliacion_para_escribir(p_conciliacion_id, 'conciliacion.conciliar');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo (mínimo 5 letras).';
  END IF;
  IF EXISTS (SELECT 1 FROM public.conciliacion x WHERE x.cuenta_dinero_id = c.cuenta_dinero_id
              AND make_date(x.anio, x.mes, 1) < make_date(c.anio, c.mes, 1)) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: esto solo se hace en la primera conciliación de la cuenta.';
  END IF;
  INSERT INTO public.conciliacion_pareja (empresa_id, conciliacion_id, banco_movimiento_id, dinero_movimiento_id, tipo, motivo, creado_por)
  SELECT c.empresa_id, c.id, NULL, m.id, 'anterior', trim(p_motivo), auth.uid()
    FROM public.dinero_movimiento m
   WHERE m.cuenta_dinero_id = c.cuenta_dinero_id AND m.fecha_contable < make_date(c.anio, c.mes, 1) AND interno.mov_conciliable(m)
     AND NOT EXISTS (SELECT 1 FROM public.conciliacion_pareja p WHERE p.dinero_movimiento_id = m.id AND p.deshecha_en IS NULL);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('conciliacion_id', c.id, 'marcados', n, 'resumen', interno.calcular_conciliacion(c) - 'conciliados' - 'empresa');
END $$;

-- registrar_diferencia_banco(conciliacion, fila_banco, datos, id_operacion)   conciliacion.registrar
--   {"tipo":"comision_bancaria"|"interes"|"otro", "cuenta":"6.1.02.05" (solo "otro"), "descripcion":"...", "fecha":"2026-01-31"}
-- Crea el movimiento que el banco ya tiene y el sistema no (asiento + rastro) y lo empareja.
--   sale del banco (-): Dr gasto / Cr banco     entra al banco (+): Dr banco / Cr ingreso
CREATE FUNCTION public.registrar_diferencia_banco(p_conciliacion_id uuid, p_banco_movimiento_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c       public.conciliacion;
  b       public.banco_movimiento;
  x       public.banco_diferencia;
  d       public.cuenta_dinero;
  cta     public.cuenta;
  v_tipo  text;
  v_cod   text;
  v_fecha date;
  v_desc  text;
  v_asto  uuid;
  v_mid   bigint;
  v_abs   bigint;
BEGIN
  SELECT * INTO c FROM public.conciliacion WHERE id = p_conciliacion_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la conciliación no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, 'conciliacion.registrar', 'conciliacion');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(c.empresa_id, p_id_operacion, 'diferencia_banco');
  SELECT * INTO x FROM public.banco_diferencia z WHERE z.empresa_id = c.empresa_id AND z.id_operacion = p_id_operacion;
  IF x.id IS NOT NULL THEN
    RETURN jsonb_build_object('banco_diferencia_id', x.id, 'asiento_id', x.asiento_id, 'duplicado', true);
  END IF;
  PERFORM interno.exigir_claves(coalesce(p_datos, '{}'), ARRAY['tipo', 'cuenta', 'descripcion', 'fecha']);
  SELECT * INTO b FROM public.banco_movimiento WHERE id = p_banco_movimiento_id AND cuenta_dinero_id = c.cuenta_dinero_id;
  IF b.id IS NULL OR b.fecha > interno.fin_conciliacion(c) THEN
    RAISE EXCEPTION 'NO_EMPAREJA: la fila del banco no es de la cuenta de esta conciliación o es de un mes posterior.';
  END IF;
  v_tipo := interno.json_texto(p_datos->'tipo', 'tipo', 30);
  v_abs := abs(b.monto_centavos);
  IF v_tipo = 'comision_bancaria' THEN
    IF b.monto_centavos > 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: una comisión bancaria es dinero que SALE del banco; esta fila es una entrada.';
    END IF;
    v_cod := interno.cuenta_de(c.empresa_id, 'comisiones_bancarias');
  ELSIF v_tipo = 'interes' THEN
    v_cod := interno.cuenta_de(c.empresa_id, CASE WHEN b.monto_centavos > 0 THEN 'intereses_ganados' ELSE 'intereses_pagados' END);
  ELSIF v_tipo = 'otro' THEN
    v_cod := interno.json_texto(p_datos->'cuenta', 'cuenta', 30);
  ELSE
    RAISE EXCEPTION 'DATO_INVALIDO: "tipo" es comision_bancaria, interes u otro.';
  END IF;
  SELECT * INTO cta FROM public.cuenta z WHERE z.empresa_id = c.empresa_id AND z.codigo = v_cod;
  IF cta.id IS NULL OR NOT cta.es_detalle OR NOT cta.activa OR cta.tipo NOT IN ('ingreso', 'gasto', 'costo') THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la contrapartida debe ser una cuenta de detalle activa de ingresos, costos o gastos ("%").', coalesce(v_cod, '');
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), b.fecha);
  PERFORM interno.exigir_fecha_contable(c.empresa_id, v_fecha);
  IF v_fecha < b.fecha THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el movimiento no puede tener fecha anterior a la del banco (%).', to_char(b.fecha, 'DD/MM/YYYY');
  END IF;
  v_desc := coalesce(nullif(trim(coalesce(interno.json_texto(p_datos->'descripcion', 'descripcion', 200), '')), ''), b.descripcion);

  PERFORM interno.reservar_operacion(c.empresa_id, p_id_operacion, 'diferencia_banco');
  SELECT * INTO x FROM public.banco_diferencia z WHERE z.empresa_id = c.empresa_id AND z.id_operacion = p_id_operacion;
  IF x.id IS NOT NULL THEN
    RETURN jsonb_build_object('banco_diferencia_id', x.id, 'asiento_id', x.asiento_id, 'duplicado', true);
  END IF;
  c := interno.conciliacion_para_escribir(p_conciliacion_id, 'conciliacion.registrar');
  IF EXISTS (SELECT 1 FROM public.conciliacion_pareja p WHERE p.banco_movimiento_id = b.id AND p.deshecha_en IS NULL)
     OR EXISTS (SELECT 1 FROM public.banco_diferencia z WHERE z.banco_movimiento_id = b.id) THEN
    RAISE EXCEPTION 'YA_CONCILIADO: esa fila del banco ya está emparejada o ya se creó su movimiento.';
  END IF;
  PERFORM interno.exigir_periodo_abierto(c.empresa_id, v_fecha);
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = c.cuenta_dinero_id;
  x.id := gen_random_uuid();
  v_asto := interno.asiento_sistema(c.empresa_id, interno.sucursal_activa(d.sucursal_id), v_fecha,
    'Conciliación ' || d.nombre || ': ' || v_desc, 'diferencia_banco', p_id_operacion,
    CASE WHEN b.monto_centavos < 0 THEN
      jsonb_build_array(jsonb_build_object('cuenta', cta.codigo, 'debe', v_abs, 'descripcion', v_desc),
                        jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'haber', v_abs, 'descripcion', 'Según estado de cuenta'))
    ELSE
      jsonb_build_array(jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'debe', v_abs, 'descripcion', 'Según estado de cuenta'),
                        jsonb_build_object('cuenta', cta.codigo, 'haber', v_abs, 'descripcion', v_desc))
    END);
  INSERT INTO public.banco_diferencia (id, empresa_id, banco_movimiento_id, tipo, cuenta_id, monto_centavos, fecha_contable, descripcion,
                                       asiento_id, id_operacion, creado_por)
  VALUES (x.id, c.empresa_id, b.id, v_tipo, cta.id, b.monto_centavos, v_fecha, v_desc, v_asto, p_id_operacion, auth.uid());
  PERFORM interno.rastrear_dinero(v_asto, 'diferencia_banco', 'banco_diferencia', x.id, coalesce(b.referencia, left(b.descripcion, 100)), NULL);
  SELECT m.id INTO v_mid FROM public.dinero_movimiento m WHERE m.asiento_id = v_asto AND m.cuenta_dinero_id = d.id;
  INSERT INTO public.conciliacion_pareja (empresa_id, conciliacion_id, banco_movimiento_id, dinero_movimiento_id, tipo, creado_por)
  VALUES (c.empresa_id, c.id, b.id, v_mid, 'creado', auth.uid());
  RETURN jsonb_build_object('banco_diferencia_id', x.id, 'asiento_id', v_asto, 'dinero_movimiento_id', v_mid, 'cuenta', cta.codigo,
    'monto_centavos', b.monto_centavos, 'duplicado', false, 'resumen', interno.calcular_conciliacion(c) - 'conciliados' - 'empresa');
END $$;

-- cerrar_conciliacion(conciliacion, saldo_banco_final?)   conciliacion.conciliar
-- Solo un mes ya terminado, en orden, y si cuadra. Guarda la foto; después no cambia.
CREATE FUNCTION public.cerrar_conciliacion(p_conciliacion_id uuid, p_saldo_banco_final_centavos bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c  public.conciliacion;
  r  jsonb;
  ab public.conciliacion;
BEGIN
  c := interno.conciliacion_para_escribir(p_conciliacion_id, 'conciliacion.conciliar');
  IF interno.fin_conciliacion(c) >= public.hoy_local(c.empresa_id) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el mes %/% todavía no termina; se concilia con el estado de cuenta del mes completo.',
      lpad(c.mes::text, 2, '0'), c.anio;
  END IF;
  SELECT * INTO ab FROM public.conciliacion x WHERE x.cuenta_dinero_id = c.cuenta_dinero_id AND x.estado = 'abierta'
     AND make_date(x.anio, x.mes, 1) < make_date(c.anio, c.mes, 1) ORDER BY x.anio, x.mes LIMIT 1;
  IF ab.id IS NOT NULL THEN
    RAISE EXCEPTION 'CONCILIACION_EN_ORDEN: cierre primero la conciliación de %/% de esta cuenta.', lpad(ab.mes::text, 2, '0'), ab.anio;
  END IF;
  IF p_saldo_banco_final_centavos IS NOT NULL THEN
    UPDATE public.conciliacion SET saldo_banco_final_centavos = p_saldo_banco_final_centavos WHERE id = c.id RETURNING * INTO c;
  END IF;
  IF c.saldo_banco_final_centavos IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: falta el saldo final que dice el estado de cuenta del banco.';
  END IF;
  r := interno.calcular_conciliacion(c);
  IF NOT (r->>'cuadra')::boolean THEN
    RAISE EXCEPTION 'CONCILIACION_NO_CUADRA: el banco dice % y el sistema con sus pendientes da % (diferencia %).',
      interno.lempiras(c.saldo_banco_final_centavos), interno.lempiras((r->>'saldo_banco_calculado_centavos')::bigint),
      interno.lempiras((r->>'diferencia_centavos')::bigint);
  END IF;
  r := jsonb_set(r, '{estado}', '"cerrada"');
  UPDATE public.conciliacion SET estado = 'cerrada', cerrada_en = now(), cerrada_por = auth.uid(), resumen_cierre = r
   WHERE id = c.id;
  RETURN jsonb_build_object('conciliacion_id', c.id, 'estado', 'cerrada', 'resumen', r - 'conciliados' - 'empresa');
END $$;

-- ver_conciliacion(conciliacion)   conciliacion.ver   (cerrada: la foto; abierta: en vivo)
CREATE FUNCTION public.ver_conciliacion(p_conciliacion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.conciliacion;
BEGIN
  SELECT * INTO c FROM public.conciliacion WHERE id = p_conciliacion_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la conciliación no existe.';
  END IF;
  PERFORM interno.exigir_lectura(c.empresa_id, 'conciliacion.ver');
  IF c.estado = 'cerrada' THEN
    RETURN c.resumen_cierre || jsonb_build_object('generado_en', public.iso(c.cerrada_en), 'foto', true);
  END IF;
  RETURN interno.calcular_conciliacion(c) || jsonb_build_object('generado_en', public.iso(now()), 'foto', false);
END $$;

-- Lista de conciliaciones (para la pantalla).
CREATE VIEW public.v_conciliacion WITH (security_invoker = true) AS
  SELECT c.empresa_id, c.id AS conciliacion_id, c.cuenta_dinero_id, d.nombre AS cuenta, d.banco, c.anio, c.mes, c.estado,
         c.dias_tolerancia, c.saldo_banco_inicial_centavos, c.saldo_banco_final_centavos, c.cerrada_en,
         public.nombre_usuario(c.empresa_id, c.cerrada_por) AS cerrada_por,
         (SELECT count(*) FROM public.banco_movimiento b WHERE b.conciliacion_id = c.id) AS filas_banco,
         (SELECT count(*) FROM public.banco_movimiento b WHERE b.conciliacion_id = c.id
             AND EXISTS (SELECT 1 FROM public.conciliacion_pareja p WHERE p.banco_movimiento_id = b.id AND p.deshecha_en IS NULL)) AS filas_conciliadas
    FROM public.conciliacion c JOIN public.cuenta_dinero d ON d.id = c.cuenta_dinero_id;
GRANT SELECT ON public.v_conciliacion TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4) Integración: entero con signo, id_operacion, apagado, seguridad
-- ---------------------------------------------------------------------
-- Centavos enteros que pueden ser negativos (filas y saldos del banco).
CREATE FUNCTION interno.json_entero_con_signo(p_valor jsonb, p_campo text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_valor IS NULL OR p_valor = 'null'::jsonb THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_valor) <> 'number' OR (p_valor #>> '{}')::numeric <> trunc((p_valor #>> '{}')::numeric)
     OR abs((p_valor #>> '{}')::numeric) > 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "%" va en centavos enteros (con signo), sin decimales.', p_campo;
  END IF;
  RETURN (p_valor #>> '{}')::bigint;
END $$;

INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('banco_importacion', 'id_operacion', 'importar_estado_cuenta', 60),
  ('banco_diferencia',  'id_operacion', 'diferencia_banco',       61);
INSERT INTO interno.modulo_apagado_permite (modulo, funcion, motivo) VALUES
  ('conciliacion', 'public.deshacer_emparejamiento', 'Corregir un emparejamiento mal hecho de una conciliación abierta.');

REVOKE EXECUTE ON FUNCTION
  interno.proteger_conciliacion(), interno.proteger_conciliacion_pareja(), interno.conciliacion_para_escribir(uuid, text),
  interno.fin_conciliacion(public.conciliacion), interno.mov_conciliable(public.dinero_movimiento),
  interno.emparejar_automatico(public.conciliacion), interno.calcular_conciliacion(public.conciliacion),
  interno.json_entero_con_signo(jsonb, text)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.importar_estado_cuenta(uuid, uuid, integer, integer, jsonb, uuid), public.emparejar_conciliacion(uuid, integer),
  public.emparejar_manual(uuid, uuid, bigint, text), public.deshacer_emparejamiento(uuid, text),
  public.marcar_conciliados_anteriores(uuid, text), public.registrar_diferencia_banco(uuid, uuid, jsonb, uuid),
  public.cerrar_conciliacion(uuid, bigint), public.ver_conciliacion(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.importar_estado_cuenta(uuid, uuid, integer, integer, jsonb, uuid), public.emparejar_conciliacion(uuid, integer),
  public.emparejar_manual(uuid, uuid, bigint, text), public.deshacer_emparejamiento(uuid, text),
  public.marcar_conciliados_anteriores(uuid, text), public.registrar_diferencia_banco(uuid, uuid, jsonb, uuid),
  public.cerrar_conciliacion(uuid, bigint)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.ver_conciliacion(uuid) TO authenticated, service_role;
