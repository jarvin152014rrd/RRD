-- =====================================================================
-- 023_caja_turnos.sql  -  Núcleo 0.5.0 (etapa 2b-1): turnos de caja POR CAJERO
--
--   abrir_turno(empresa, caja, fondo contado, id_operacion, datos?)
--       Un cajero no tiene dos turnos abiertos y una caja no tiene dos
--       cajeros a la vez. El fondo contado debe ser lo que la caja tiene en
--       el sistema; si no, se trae o se lleva la diferencia desde otra cuenta
--       ("cuenta_origen_id", pide dinero.trasladar) o se rechaza (FONDO_NO_CUADRA).
--   cerrar_turno(turno, contado, id_operacion, datos?)
--       Arqueo (conteo por denominación opcional). Esperado = fondo +
--       entradas en efectivo - salidas del turno. Diferencia = contado -
--       esperado; la caja queda con lo contado y la diferencia queda
--       "pendiente" en 1.1.02.04 Diferencias de caja por resolver.
--   resolver_diferencia(turno, destino, motivo, id_operacion, fecha?)   caja.supervisar
--       faltante: "cobrar_al_cajero" (1.1.02.05 CxC empleados) o "gasto"
--       (6.1.02.11 Faltantes de caja); sobrante: "otros_ingresos" (4.2.01.03).
--   El cajero NO ve el esperado mientras su turno está abierto (conteo a
--   ciegas); lo ve al cerrar.
-- Para la etapa 2b-2: interno.exigir_turno_abierto(empresa) = el turno
-- abierto del usuario (sin él no se cobra en efectivo).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('TURNO_YA_ABIERTO', 'Usted ya tiene un turno de caja abierto.', 'Cierre ese turno (con su arqueo) antes de abrir otro.'),
  ('CAJA_OCUPADA', 'Esa caja ya tiene un turno abierto de otro cajero.', 'Use otra caja o pida que cierren ese turno.'),
  ('TURNO_CERRADO', 'Ese turno ya está cerrado.', 'Abra un turno nuevo para seguir cobrando.'),
  ('FONDO_NO_CUADRA', 'El fondo contado no es lo que la caja tiene en el sistema.',
   'Cuente otra vez. Si de verdad falta o sobra, el administrador trae o lleva la diferencia desde otra cuenta al abrir el turno.'),
  ('SIN_TURNO_ABIERTO', 'No tiene un turno de caja abierto.', 'Abra su turno (con el fondo contado) para cobrar en efectivo.'),
  ('YA_RESUELTO', 'Esto ya fue resuelto.', 'No hace falta hacerlo otra vez; revise el historial.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('caja.turno',      'Abrir y cerrar su propio turno de caja (con arqueo)', true, false),
  ('caja.supervisar', 'Cerrar turnos de otros cajeros y resolver diferencias de arqueo', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'caja.turno'), ('dueno', 'caja.supervisar'),
  ('admin', 'caja.turno'), ('admin', 'caja.supervisar'),
  ('cajero', 'caja.turno');
SELECT interno.repartir_permisos(ARRAY['caja.turno', 'caja.supervisar'], 'Núcleo 0.5.0: turnos de caja');

-- ---------------------------------------------------------------------
-- 1) Tabla
-- ---------------------------------------------------------------------
CREATE TABLE public.turno_caja (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id               uuid NOT NULL REFERENCES public.empresa(id),
  numero                   bigint NOT NULL,
  caja_id                  uuid NOT NULL REFERENCES public.caja(id),
  cuenta_dinero_id         uuid NOT NULL,
  sucursal_id              uuid NOT NULL,
  cajero_id                uuid NOT NULL,              -- auth.uid() de quien abrió
  estado                   text NOT NULL CHECK (estado IN ('abierto', 'cerrado')),
  abierto_en               timestamptz NOT NULL DEFAULT now(),
  fecha_apertura           date NOT NULL,
  fondo_inicial_centavos   bigint NOT NULL CHECK (fondo_inicial_centavos BETWEEN 0 AND 9007199254740991),
  conteo_apertura          jsonb,
  equipo_apertura          text,
  apertura_id_operacion    uuid NOT NULL,
  -- Cierre (una vez)
  cerrado_en               timestamptz,
  cerrado_por              uuid,
  fecha_cierre             date,
  contado_centavos         bigint CHECK (contado_centavos BETWEEN 0 AND 9007199254740991),
  conteo_cierre            jsonb,
  entradas_centavos        bigint,
  salidas_centavos         bigint,
  esperado_centavos        bigint,
  diferencia_centavos      bigint,                     -- contado - esperado (- falta, + sobra)
  asiento_diferencia_id    uuid,
  nota_cierre              text,
  equipo_cierre            text,
  cierre_id_operacion      uuid,
  diferencia_estado        text CHECK (diferencia_estado IN ('sin_diferencia', 'pendiente', 'resuelta')),
  -- Resolución de la diferencia (una vez)
  resolucion_destino       text CHECK (resolucion_destino IN ('cobrar_al_cajero', 'gasto', 'otros_ingresos')),
  resuelto_por             uuid,
  resuelto_en              timestamptz,
  fecha_resolucion         date,
  motivo_resolucion        text,
  asiento_resolucion_id    uuid,
  resolucion_id_operacion  uuid,
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, apertura_id_operacion),
  FOREIGN KEY (empresa_id, cuenta_dinero_id)      REFERENCES public.cuenta_dinero(empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id)           REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_diferencia_id) REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_resolucion_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((estado = 'cerrado') = (cerrado_en IS NOT NULL)),
  CHECK ((estado = 'cerrado') = (diferencia_estado IS NOT NULL)),
  CHECK (estado = 'abierto' OR (contado_centavos IS NOT NULL AND esperado_centavos IS NOT NULL
                                AND diferencia_centavos = contado_centavos - esperado_centavos
                                AND esperado_centavos = fondo_inicial_centavos + entradas_centavos - salidas_centavos)),
  CHECK ((diferencia_estado = 'sin_diferencia') = (estado = 'cerrado' AND diferencia_centavos = 0)),
  CHECK ((asiento_diferencia_id IS NULL) = (coalesce(diferencia_centavos, 0) = 0)),
  CHECK ((diferencia_estado = 'resuelta') = (asiento_resolucion_id IS NOT NULL)),
  CHECK (resolucion_destino IS NULL
         OR (diferencia_centavos < 0 AND resolucion_destino IN ('cobrar_al_cajero', 'gasto'))
         OR (diferencia_centavos > 0 AND resolucion_destino = 'otros_ingresos'))
);
-- Un cajero, un turno abierto (por empresa). Una caja, un turno abierto.
CREATE UNIQUE INDEX turno_caja_cajero_abierto ON public.turno_caja (empresa_id, cajero_id) WHERE estado = 'abierto';
CREATE UNIQUE INDEX turno_caja_caja_abierta   ON public.turno_caja (cuenta_dinero_id) WHERE estado = 'abierto';
CREATE INDEX turno_caja_cajero ON public.turno_caja (empresa_id, cajero_id, abierto_en);
CREATE INDEX turno_caja_pendiente ON public.turno_caja (empresa_id) WHERE diferencia_estado = 'pendiente';

ALTER TABLE public.dinero_movimiento
  ADD CONSTRAINT dinero_movimiento_turno_fk FOREIGN KEY (empresa_id, turno_id) REFERENCES public.turno_caja(empresa_id, id);
CREATE INDEX dinero_movimiento_turno ON public.dinero_movimiento (turno_id) WHERE turno_id IS NOT NULL;

-- El turno no se edita: se cierra una vez y su diferencia se resuelve una vez.
CREATE FUNCTION interno.proteger_turno_caja() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c_cierre constant text[] := ARRAY['estado', 'cerrado_en', 'cerrado_por', 'fecha_cierre', 'contado_centavos', 'conteo_cierre',
    'entradas_centavos', 'salidas_centavos', 'esperado_centavos', 'diferencia_centavos', 'asiento_diferencia_id',
    'nota_cierre', 'equipo_cierre', 'cierre_id_operacion', 'diferencia_estado'];
  c_resol constant text[] := ARRAY['diferencia_estado', 'resolucion_destino', 'resuelto_por', 'resuelto_en',
    'fecha_resolucion', 'motivo_resolucion', 'asiento_resolucion_id', 'resolucion_id_operacion'];
BEGIN
  IF OLD.estado = 'abierto' AND NEW.estado = 'cerrado' AND NEW.diferencia_estado <> 'resuelta'
     AND (to_jsonb(NEW) - c_cierre) = (to_jsonb(OLD) - c_cierre) THEN
    RETURN NEW;
  END IF;
  IF OLD.diferencia_estado = 'pendiente' AND NEW.diferencia_estado = 'resuelta'
     AND (to_jsonb(NEW) - c_resol) = (to_jsonb(OLD) - c_resol) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: un turno de caja no se edita; se cierra una vez y su diferencia se resuelve una vez.';
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.turno_caja FOR EACH ROW EXECUTE FUNCTION interno.proteger_turno_caja();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.turno_caja FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.turno_caja
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los turnos de caja no se borran.');

-- ---------------------------------------------------------------------
-- 2) Ayudantes
-- ---------------------------------------------------------------------
-- Turno abierto de una cuenta de dinero (reemplaza el de 022): lo usa el
-- rastro para marcar cada entrada o salida de la caja con su turno.
CREATE OR REPLACE FUNCTION interno.turno_de_cuenta(p_cuenta_dinero_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT t.id FROM public.turno_caja t WHERE t.cuenta_dinero_id = p_cuenta_dinero_id AND t.estado = 'abierto'
$$;

-- Conteo por denominación: [{"denominacion_centavos":50000,"cantidad":3}, ...]
-- (L 500 x 3). Devuelve el total en centavos.
CREATE FUNCTION interno.total_conteo(p_conteo jsonb) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  l       jsonb;
  v_total numeric := 0;
  v_vistas bigint[] := '{}';
  v_den   bigint;
  v_cant  bigint;
BEGIN
  IF jsonb_typeof(p_conteo) IS DISTINCT FROM 'array' OR jsonb_array_length(p_conteo) = 0 OR jsonb_array_length(p_conteo) > 40 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el conteo es una lista (1 a 40) de {"denominacion_centavos", "cantidad"}.';
  END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_conteo) LOOP
    IF jsonb_typeof(l) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada fila del conteo es {"denominacion_centavos", "cantidad"}.';
    END IF;
    PERFORM interno.exigir_claves(l, ARRAY['denominacion_centavos', 'cantidad']);
    v_den  := interno.json_centavos(l->'denominacion_centavos', 'denominacion_centavos');
    v_cant := interno.json_centavos(l->'cantidad', 'cantidad');
    IF v_den = 0 OR v_den > 100000000 OR v_cant > 1000000 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: denominación o cantidad fuera de rango en el conteo.';
    END IF;
    IF v_den = ANY (v_vistas) THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la denominación % está repetida en el conteo.', v_den;
    END IF;
    v_vistas := v_vistas || v_den;
    v_total := v_total + v_den * v_cant;
  END LOOP;
  RETURN v_total::bigint;
END $$;

-- Contado: el monto, el conteo o los dos (deben coincidir).
CREATE FUNCTION interno.monto_contado(p_monto bigint, p_conteo jsonb, p_que text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v bigint;
BEGIN
  IF p_conteo IS NOT NULL AND p_conteo <> 'null'::jsonb THEN
    v := interno.total_conteo(p_conteo);
    IF p_monto IS NOT NULL AND p_monto <> v THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el % (% centavos) no es igual a la suma del conteo (% centavos).', p_que, p_monto, v;
    END IF;
    RETURN v;
  END IF;
  IF p_monto IS NULL OR p_monto < 0 OR p_monto > 9007199254740991 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique el % en centavos (0 o más) o el conteo por denominación.', p_que;
  END IF;
  RETURN p_monto;
END $$;

CREATE FUNCTION interno.turno_respuesta(t public.turno_caja, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('turno_id', t.id, 'numero', t.numero, 'estado', t.estado, 'caja_id', t.caja_id,
    'cuenta_dinero_id', t.cuenta_dinero_id, 'fondo_inicial_centavos', t.fondo_inicial_centavos,
    'entradas_centavos', t.entradas_centavos, 'salidas_centavos', t.salidas_centavos,
    'esperado_centavos', t.esperado_centavos, 'contado_centavos', t.contado_centavos,
    'diferencia_centavos', t.diferencia_centavos, 'diferencia_estado', t.diferencia_estado,
    'resolucion_destino', t.resolucion_destino, 'duplicado', p_duplicado)
$$;

-- Para la etapa 2b-2 (cobros en efectivo): el turno abierto del usuario.
CREATE FUNCTION interno.exigir_turno_abierto(p_empresa_id uuid) RETURNS public.turno_caja
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.turno_caja;
BEGIN
  SELECT * INTO t FROM public.turno_caja x
   WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
  IF t.id IS NULL THEN
    RAISE EXCEPTION 'SIN_TURNO_ABIERTO: abra su turno de caja para cobrar en efectivo.';
  END IF;
  RETURN t;
END $$;

-- ---------------------------------------------------------------------
-- 3) RPC
-- ---------------------------------------------------------------------
-- abrir_turno(empresa, caja, fondo_centavos, id_operacion, datos?)   caja.turno
-- datos = {"conteo":[{"denominacion_centavos":10000,"cantidad":5}], "cuenta_origen_id":"...",
--          "equipo":"Caja 1", "nota":"..."}
-- Si la caja aún no tiene su cuenta de efectivo, se crea ("Efectivo <caja> (001-001)").
CREATE FUNCTION public.abrir_turno(p_empresa_id uuid, p_caja_id uuid, p_fondo_centavos bigint, p_id_operacion uuid,
                                   p_datos jsonb DEFAULT '{}')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_datos jsonb := coalesce(p_datos, '{}');
  v_caja  public.caja;
  v_suc   public.sucursal;
  d       public.cuenta_dinero;
  o       public.cuenta_dinero;
  t       public.turno_caja;
  v_fondo bigint;
  v_saldo bigint;
  v_dif   bigint;
  v_hoy   date := public.hoy_local(p_empresa_id);
  v_eq    text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'caja.turno', 'dinero');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'abrir_turno');
  SELECT * INTO t FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.apertura_id_operacion = p_id_operacion;
  IF t.id IS NOT NULL THEN
    RETURN interno.turno_respuesta(t, true);
  END IF;
  PERFORM interno.exigir_claves(v_datos, ARRAY['conteo', 'cuenta_origen_id', 'equipo', 'nota']);
  SELECT * INTO v_caja FROM public.caja c WHERE c.id = p_caja_id AND c.empresa_id = p_empresa_id AND c.activa;
  SELECT * INTO v_suc FROM public.sucursal s WHERE s.id = v_caja.sucursal_id AND s.activa;
  IF v_caja.id IS NULL OR v_suc.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja no existe en esta empresa o está desactivada (ella o su sucursal).';
  END IF;
  v_fondo := interno.monto_contado(p_fondo_centavos, v_datos->'conteo', 'fondo inicial');
  v_eq := interno.equipo(v_datos);

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'abrir_turno');
  SELECT * INTO t FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.apertura_id_operacion = p_id_operacion;
  IF t.id IS NOT NULL THEN
    RETURN interno.turno_respuesta(t, true);
  END IF;
  SELECT * INTO t FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
  IF t.id IS NOT NULL THEN
    RAISE EXCEPTION 'TURNO_YA_ABIERTO: usted ya tiene abierto el turno #% (caja "%"); ciérrelo antes de abrir otro.',
      t.numero, (SELECT c.nombre FROM public.caja c WHERE c.id = t.caja_id);
  END IF;

  SELECT * INTO d FROM public.cuenta_dinero x WHERE x.caja_id = v_caja.id FOR UPDATE;
  IF d.id IS NULL THEN
    d := interno.crear_cuenta_dinero_base(p_empresa_id, 'efectivo_caja',
           'Efectivo ' || v_caja.nombre || ' (' || v_suc.codigo || '-' || v_caja.punto_emision || ')',
           v_suc.id, v_caja.id, NULL, NULL, NULL, (SELECT e.moneda FROM public.empresa e WHERE e.id = p_empresa_id), NULL);
  ELSIF NOT d.activa THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de efectivo de la caja "%" está desactivada; reactívela primero.', v_caja.nombre;
  END IF;
  IF interno.turno_de_cuenta(d.id) IS NOT NULL THEN
    RAISE EXCEPTION 'CAJA_OCUPADA: la caja "%" ya tiene un turno abierto.', v_caja.nombre;
  END IF;

  -- El fondo contado debe ser lo que la caja tiene; si no, se trae o se
  -- lleva la diferencia desde otra cuenta (una operación de traslado).
  v_saldo := interno.saldo_dinero(d.id);
  v_dif := v_fondo - v_saldo;
  IF v_dif <> 0 THEN
    IF NOT (v_datos ? 'cuenta_origen_id') OR v_datos->'cuenta_origen_id' = 'null'::jsonb THEN
      RAISE EXCEPTION 'FONDO_NO_CUADRA: la caja "%" tiene % en el sistema y usted contó %. Cuente otra vez o pida al administrador que traiga o lleve la diferencia (%).',
        v_caja.nombre, interno.lempiras(v_saldo), interno.lempiras(v_fondo), interno.lempiras(v_dif);
    END IF;
    IF NOT public.tiene_permiso('dinero.trasladar', p_empresa_id) THEN
      RAISE EXCEPTION 'SIN_PERMISO: traer o llevar dinero a la caja pide el permiso "dinero.trasladar".';
    END IF;
    o := interno.cuenta_dinero_de(p_empresa_id, interno.json_uuid(v_datos->'cuenta_origen_id', 'cuenta_origen_id'));
    IF o.id = d.id OR o.tipo = 'transito' THEN
      RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: elija otra cuenta (no la misma caja ni el dinero en tránsito) para el fondo.';
    END IF;
    PERFORM interno.exigir_fecha_contable(p_empresa_id, v_hoy);
    PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_hoy);
    IF v_dif > 0 THEN
      PERFORM interno.guardar_operacion_dinero(p_empresa_id, 'traslado', o, d, NULL, NULL, v_dif, v_hoy,
        'Fondo de turno', interno.json_texto(v_datos->'nota', 'nota', 500), v_eq, NULL,
        'Traslado #N de ' || o.nombre || ' a ' || d.nombre || ' para el fondo del turno',
        jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id), 'debe', v_dif),
                          jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = o.cuenta_id), 'haber', v_dif)),
        md5('fondo_turno:' || p_id_operacion)::uuid);
    ELSE
      PERFORM interno.guardar_operacion_dinero(p_empresa_id, 'traslado', d, o, NULL, NULL, -v_dif, v_hoy,
        'Fondo de turno', interno.json_texto(v_datos->'nota', 'nota', 500), v_eq, NULL,
        'Traslado #N de ' || d.nombre || ' a ' || o.nombre || ' (sobraba para el fondo del turno)',
        jsonb_build_array(jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = o.cuenta_id), 'debe', -v_dif),
                          jsonb_build_object('cuenta', (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id), 'haber', -v_dif)),
        md5('fondo_turno:' || p_id_operacion)::uuid);
    END IF;
  END IF;

  INSERT INTO public.turno_caja (empresa_id, numero, caja_id, cuenta_dinero_id, sucursal_id, cajero_id, estado,
    fecha_apertura, fondo_inicial_centavos, conteo_apertura, equipo_apertura, apertura_id_operacion)
  VALUES (p_empresa_id, interno.siguiente_numero(p_empresa_id, 'turno_caja'), v_caja.id, d.id, v_suc.id, auth.uid(), 'abierto',
    v_hoy, v_fondo, nullif(v_datos->'conteo', 'null'::jsonb), v_eq, p_id_operacion)
  RETURNING * INTO t;
  RETURN interno.turno_respuesta(t, false);
END $$;

-- cerrar_turno(turno, contado_centavos, id_operacion, datos?)   caja.turno
-- (el turno de otro cajero pide caja.supervisar)
-- datos = {"conteo":[...], "nota":"...", "equipo":"...", "fecha":"2026-01-15"}
CREATE FUNCTION public.cerrar_turno(p_turno_id uuid, p_contado_centavos bigint, p_id_operacion uuid, p_datos jsonb DEFAULT '{}')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_datos  jsonb := coalesce(p_datos, '{}');
  t        public.turno_caja;
  d        public.cuenta_dinero;
  v_cont   bigint;
  v_fecha  date;
  v_ent    bigint;
  v_sal    bigint;
  v_esp    bigint;
  v_dif    bigint;
  v_cta    text;
  v_asto   uuid;
  v_eq     text;
BEGIN
  SELECT * INTO t FROM public.turno_caja WHERE id = p_turno_id;
  IF t.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el turno de caja no existe.';
  END IF;
  PERFORM interno.exigir_escritura(t.empresa_id, 'caja.turno', 'dinero');
  IF t.cajero_id IS DISTINCT FROM auth.uid() AND NOT public.tiene_permiso('caja.supervisar', t.empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: solo el cajero del turno o un supervisor (permiso "caja.supervisar") lo cierra.';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(t.empresa_id, p_id_operacion, 'cerrar_turno');
  IF t.cierre_id_operacion = p_id_operacion THEN
    RETURN interno.turno_respuesta(t, true);
  END IF;
  PERFORM interno.exigir_claves(v_datos, ARRAY['conteo', 'nota', 'equipo', 'fecha']);
  v_cont := interno.monto_contado(p_contado_centavos, v_datos->'conteo', 'monto contado');
  v_fecha := coalesce(interno.json_fecha(v_datos->'fecha', 'fecha'), public.hoy_local(t.empresa_id));
  PERFORM interno.exigir_fecha_contable(t.empresa_id, v_fecha);
  IF v_fecha < t.fecha_apertura THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el cierre no puede tener fecha anterior a la apertura (%).', to_char(t.fecha_apertura, 'DD/MM/YYYY');
  END IF;
  v_eq := interno.equipo(v_datos);

  PERFORM interno.reservar_operacion(t.empresa_id, p_id_operacion, 'cerrar_turno');
  SELECT * INTO t FROM public.turno_caja WHERE id = p_turno_id FOR UPDATE;
  IF t.cierre_id_operacion = p_id_operacion THEN
    RETURN interno.turno_respuesta(t, true);
  END IF;
  IF t.estado <> 'abierto' THEN
    RAISE EXCEPTION 'TURNO_CERRADO: el turno #% ya está cerrado.', t.numero;
  END IF;
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = t.cuenta_dinero_id;

  -- Esperado = fondo + entradas - salidas del turno (= saldo de la caja en el sistema).
  SELECT coalesce(sum(m.monto_centavos) FILTER (WHERE m.monto_centavos > 0), 0),
         coalesce(-sum(m.monto_centavos) FILTER (WHERE m.monto_centavos < 0), 0)
    INTO v_ent, v_sal FROM public.dinero_movimiento m WHERE m.turno_id = t.id;
  v_esp := t.fondo_inicial_centavos + v_ent - v_sal;
  IF v_esp <> interno.saldo_dinero(d.id) THEN
    RAISE EXCEPTION 'NO_CUADRA: el esperado del turno #% (%) no es el saldo de la caja (%). Avise a soporte.',
      t.numero, v_esp, interno.saldo_dinero(d.id);
  END IF;
  v_dif := v_cont - v_esp;

  IF v_dif <> 0 THEN
    PERFORM interno.exigir_periodo_abierto(t.empresa_id, v_fecha);
    v_cta := (SELECT c.codigo FROM public.cuenta c WHERE c.id = d.cuenta_id);
    v_asto := interno.asiento_sistema(t.empresa_id, interno.sucursal_activa(t.sucursal_id), v_fecha,
      CASE WHEN v_dif < 0 THEN 'Faltante' ELSE 'Sobrante' END || ' en arqueo del turno #' || t.numero || ' (' || d.nombre
        || '): esperado ' || interno.lempiras(v_esp) || ', contado ' || interno.lempiras(v_cont),
      'diferencia_arqueo', p_id_operacion,
      jsonb_build_array(
        jsonb_build_object('uso', 'diferencia_caja', 'debe',  greatest(-v_dif, 0), 'descripcion', 'Faltante por resolver'),
        jsonb_build_object('cuenta', v_cta,          'haber', greatest(-v_dif, 0), 'descripcion', 'Faltante en caja'),
        jsonb_build_object('cuenta', v_cta,          'debe',  greatest(v_dif, 0),  'descripcion', 'Sobrante en caja'),
        jsonb_build_object('uso', 'diferencia_caja', 'haber', greatest(v_dif, 0),  'descripcion', 'Sobrante por resolver')));
  END IF;

  UPDATE public.turno_caja
     SET estado = 'cerrado', cerrado_en = now(), cerrado_por = auth.uid(), fecha_cierre = v_fecha,
         contado_centavos = v_cont, conteo_cierre = nullif(v_datos->'conteo', 'null'::jsonb),
         entradas_centavos = v_ent, salidas_centavos = v_sal, esperado_centavos = v_esp, diferencia_centavos = v_dif,
         asiento_diferencia_id = v_asto, nota_cierre = interno.json_texto(v_datos->'nota', 'nota', 500),
         equipo_cierre = v_eq, cierre_id_operacion = p_id_operacion,
         diferencia_estado = CASE WHEN v_dif = 0 THEN 'sin_diferencia' ELSE 'pendiente' END
   WHERE id = t.id
  RETURNING * INTO t;
  -- Después de cerrar: el ajuste de la diferencia no cuenta como movimiento del turno.
  PERFORM interno.rastrear_dinero(v_asto, 'diferencia_arqueo', 'turno_caja', t.id, 'Arqueo turno #' || t.numero, v_eq);
  RETURN interno.turno_respuesta(t, false);
END $$;

-- resolver_diferencia(turno, destino, motivo, id_operacion, fecha?)   caja.supervisar
-- destino: faltante -> "cobrar_al_cajero" | "gasto"; sobrante -> "otros_ingresos".
-- Nadie resuelve la diferencia de su propio turno (salvo el dueño).
CREATE FUNCTION public.resolver_diferencia(p_turno_id uuid, p_destino text, p_motivo text, p_id_operacion uuid,
                                           p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t       public.turno_caja;
  v_fecha date;
  v_monto bigint;
  v_uso   text;
  v_asto  uuid;
BEGIN
  SELECT * INTO t FROM public.turno_caja WHERE id = p_turno_id;
  IF t.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el turno de caja no existe.';
  END IF;
  PERFORM interno.exigir_escritura(t.empresa_id, 'caja.supervisar', 'dinero');
  IF t.cajero_id = auth.uid() AND public.mi_rol(t.empresa_id) <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede resolver la diferencia de su propio turno; lo hace otro supervisor o el dueño.';
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(t.empresa_id, p_id_operacion, 'resolver_diferencia');
  IF t.resolucion_id_operacion = p_id_operacion THEN
    RETURN interno.turno_respuesta(t, true);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se resuelve así (mínimo 5 letras).';
  END IF;
  IF t.estado <> 'cerrado' OR t.diferencia_estado = 'sin_diferencia' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el turno #% no tiene una diferencia que resolver.', t.numero;
  END IF;
  IF t.diferencia_centavos < 0 AND coalesce(p_destino, '') NOT IN ('cobrar_al_cajero', 'gasto') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un faltante se resuelve con "cobrar_al_cajero" o "gasto".';
  END IF;
  IF t.diferencia_centavos > 0 AND coalesce(p_destino, '') <> 'otros_ingresos' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un sobrante se resuelve con "otros_ingresos".';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(t.empresa_id), t.fecha_cierre));
  PERFORM interno.exigir_fecha_contable(t.empresa_id, v_fecha);
  IF v_fecha < t.fecha_cierre THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la resolución no puede tener fecha anterior al cierre del turno (%).', to_char(t.fecha_cierre, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(t.empresa_id, p_id_operacion, 'resolver_diferencia');
  SELECT * INTO t FROM public.turno_caja WHERE id = p_turno_id FOR UPDATE;
  IF t.resolucion_id_operacion = p_id_operacion THEN
    RETURN interno.turno_respuesta(t, true);
  END IF;
  IF t.diferencia_estado = 'resuelta' THEN
    RAISE EXCEPTION 'YA_RESUELTO: la diferencia del turno #% ya se resolvió (%).', t.numero, t.resolucion_destino;
  END IF;
  PERFORM interno.exigir_periodo_abierto(t.empresa_id, v_fecha);

  v_monto := abs(t.diferencia_centavos);
  v_uso := CASE p_destino WHEN 'cobrar_al_cajero' THEN 'cxc_empleados' WHEN 'gasto' THEN 'faltante_caja' ELSE 'sobrante_caja' END;
  v_asto := interno.asiento_sistema(t.empresa_id, interno.sucursal_activa(t.sucursal_id), v_fecha,
    CASE WHEN t.diferencia_centavos < 0 THEN 'Faltante' ELSE 'Sobrante' END || ' del turno #' || t.numero || ' a '
      || replace(p_destino, '_', ' ') || ': ' || trim(p_motivo),
    'resolucion_diferencia_caja', p_id_operacion,
    CASE WHEN t.diferencia_centavos < 0 THEN
      jsonb_build_array(jsonb_build_object('uso', v_uso, 'debe', v_monto),
                        jsonb_build_object('uso', 'diferencia_caja', 'haber', v_monto))
    ELSE
      jsonb_build_array(jsonb_build_object('uso', 'diferencia_caja', 'debe', v_monto),
                        jsonb_build_object('uso', v_uso, 'haber', v_monto))
    END);
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.turno_caja
     SET diferencia_estado = 'resuelta', resolucion_destino = p_destino, resuelto_por = auth.uid(), resuelto_en = now(),
         fecha_resolucion = v_fecha, motivo_resolucion = trim(p_motivo), asiento_resolucion_id = v_asto,
         resolucion_id_operacion = p_id_operacion
   WHERE id = t.id
  RETURNING * INTO t;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.turno_respuesta(t, false);
END $$;

-- mi_turno(empresa): el turno abierto del usuario (sin el esperado: el
-- arqueo es a ciegas). {"turno": null} si no tiene.
CREATE FUNCTION public.mi_turno(p_empresa_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.turno_caja;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  IF public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  SELECT * INTO t FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
  IF t.id IS NULL THEN
    RETURN jsonb_build_object('turno', NULL);
  END IF;
  RETURN jsonb_build_object('turno', jsonb_build_object('turno_id', t.id, 'numero', t.numero, 'caja_id', t.caja_id,
    'caja', (SELECT c.nombre FROM public.caja c WHERE c.id = t.caja_id), 'abierto_en', public.iso(t.abierto_en),
    'fondo_inicial_centavos', t.fondo_inicial_centavos));
END $$;

-- desactivar_caja (reemplaza la de 010; misma firma): no con un turno abierto.
CREATE OR REPLACE FUNCTION public.desactivar_caja(p_empresa_id uuid, p_caja_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_caja public.caja;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva la caja (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO v_caja FROM public.caja WHERE id = p_caja_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_caja.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la caja no existe en esta empresa.';
  END IF;
  IF NOT v_caja.activa THEN
    RETURN jsonb_build_object('caja_id', p_caja_id, 'activa', false, 'ya_estaba', true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja t WHERE t.caja_id = p_caja_id AND t.estado = 'abierto') THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la caja "%" tiene un turno abierto; ciérrelo primero.', v_caja.nombre;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.caja SET activa = false WHERE id = p_caja_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('caja_id', p_caja_id, 'activa', false, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- 4) Activar el módulo "dinero": los libros deben coincidir con el módulo
--    (reemplaza la de 021: igual más el caso "dinero").
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
    -- Diferencias de caja por resolver = faltantes - sobrantes pendientes de los turnos.
    v_cta    := interno.cuenta_de(NEW.empresa_id, 'diferencia_caja');
    v_libros := interno.saldo_libros(NEW.empresa_id, v_cta);
    v_modulo := coalesce((SELECT -sum(t.diferencia_centavos) FROM public.turno_caja t
                           WHERE t.empresa_id = NEW.empresa_id AND t.diferencia_estado = 'pendiente'), 0);
    IF v_libros <> v_modulo THEN
      RAISE EXCEPTION 'MODULO_CON_SALDO: la cuenta % (diferencias de caja) tiene % en los libros y los turnos pendientes suman %. Pase la diferencia con un asiento a la cuenta que corresponda y vuelva a activar el módulo.',
        v_cta, interno.lempiras(v_libros), interno.lempiras(v_modulo);
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 5) id_operacion por tipo (reemplaza la de 022) y adjuntos a turnos
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
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION interno.empresa_de_documento(p_tipo text, p_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN CASE p_tipo
    WHEN 'operacion_dinero' THEN (SELECT x.empresa_id FROM public.operacion_dinero x WHERE x.id = p_id)
    WHEN 'turno_caja'       THEN (SELECT x.empresa_id FROM public.turno_caja x WHERE x.id = p_id)
    WHEN 'compra'           THEN (SELECT x.empresa_id FROM public.compra x WHERE x.id = p_id)
    WHEN 'pago_proveedor'   THEN (SELECT x.empresa_id FROM public.pago_proveedor x WHERE x.id = p_id)
    WHEN 'cxp_saldo_inicial' THEN (SELECT x.empresa_id FROM public.cxp_saldo_inicial x WHERE x.id = p_id)
    WHEN 'inventario_documento' THEN (SELECT x.empresa_id FROM public.inventario_documento x WHERE x.id = p_id)
  END;
END $$;

-- ---------------------------------------------------------------------
-- 6) Lecturas: turnos e historial de diferencias por cajero
--    (dinero.ver ve todos; cada cajero ve los suyos)
-- ---------------------------------------------------------------------
-- Nombre (o correo) de un usuario de la empresa, solo para quien es de la empresa.
CREATE FUNCTION public.nombre_usuario(p_empresa_id uuid, p_user_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(ue.nombre, u.email)
    FROM public.usuario_empresa ue JOIN auth.users u ON u.id = ue.user_id
   WHERE ue.empresa_id = p_empresa_id AND ue.user_id = p_user_id
     AND (auth.uid() IS NULL OR public.mi_rol(p_empresa_id) IS NOT NULL)
$$;
REVOKE EXECUTE ON FUNCTION public.nombre_usuario(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.nombre_usuario(uuid, uuid) TO authenticated, service_role;

CREATE VIEW public.v_turno_caja WITH (security_invoker = true) AS
  SELECT t.empresa_id, t.id AS turno_id, t.numero, t.estado, t.caja_id, c.nombre AS caja, t.sucursal_id,
         t.cuenta_dinero_id, t.cajero_id, public.nombre_usuario(t.empresa_id, t.cajero_id) AS cajero,
         t.abierto_en, t.fecha_apertura, t.fondo_inicial_centavos, t.cerrado_en, t.fecha_cierre,
         t.entradas_centavos, t.salidas_centavos, t.esperado_centavos, t.contado_centavos,
         t.diferencia_centavos, t.diferencia_estado, t.resolucion_destino, t.resuelto_en, t.motivo_resolucion,
         t.conteo_apertura, t.conteo_cierre, t.nota_cierre
  FROM public.turno_caja t
  JOIN public.caja c ON c.id = t.caja_id;

CREATE VIEW public.v_diferencia_cajero WITH (security_invoker = true) AS
  SELECT t.empresa_id, t.cajero_id, public.nombre_usuario(t.empresa_id, t.cajero_id) AS cajero,
         count(*) AS turnos,
         count(*) FILTER (WHERE t.estado = 'cerrado' AND t.diferencia_centavos <> 0) AS turnos_con_diferencia,
         coalesce(-sum(t.diferencia_centavos) FILTER (WHERE t.diferencia_centavos < 0), 0)::bigint AS faltantes_centavos,
         coalesce(sum(t.diferencia_centavos) FILTER (WHERE t.diferencia_centavos > 0), 0)::bigint AS sobrantes_centavos,
         coalesce(-sum(t.diferencia_centavos) FILTER (WHERE t.diferencia_estado = 'pendiente'), 0)::bigint AS pendiente_neto_centavos,
         coalesce(-sum(t.diferencia_centavos) FILTER (WHERE t.resolucion_destino = 'cobrar_al_cajero'), 0)::bigint AS cobrado_al_cajero_centavos,
         coalesce(-sum(t.diferencia_centavos) FILTER (WHERE t.resolucion_destino = 'gasto'), 0)::bigint AS enviado_a_gasto_centavos,
         coalesce(sum(t.diferencia_centavos) FILTER (WHERE t.resolucion_destino = 'otros_ingresos'), 0)::bigint AS a_otros_ingresos_centavos,
         max(t.abierto_en) AS ultimo_turno_en
  FROM public.turno_caja t
  GROUP BY t.empresa_id, t.cajero_id;

-- ---------------------------------------------------------------------
-- 7) Seguridad
-- ---------------------------------------------------------------------
ALTER TABLE public.turno_caja ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.turno_caja
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
GRANT SELECT ON public.turno_caja TO authenticated, service_role;
CREATE POLICY leer ON public.turno_caja FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('dinero.ver')))
         OR (cajero_id = (SELECT auth.uid()) AND empresa_id IN (SELECT public.mis_empresas())));
GRANT SELECT ON public.v_turno_caja, public.v_diferencia_cajero TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  interno.proteger_turno_caja(),
  interno.total_conteo(jsonb),
  interno.monto_contado(bigint, jsonb, text),
  interno.turno_respuesta(public.turno_caja, boolean),
  interno.exigir_turno_abierto(uuid)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.abrir_turno(uuid, uuid, bigint, uuid, jsonb),
  public.cerrar_turno(uuid, bigint, uuid, jsonb),
  public.resolver_diferencia(uuid, text, text, uuid, date),
  public.mi_turno(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.abrir_turno(uuid, uuid, bigint, uuid, jsonb),
  public.cerrar_turno(uuid, bigint, uuid, jsonb),
  public.resolver_diferencia(uuid, text, text, uuid, date),
  public.mi_turno(uuid)
TO authenticated;
