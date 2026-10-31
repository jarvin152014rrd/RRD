-- =====================================================================
-- 025_arranque_facil.sql  -  Núcleo 0.6.0 (etapa 2b-1.1): arranque fácil
-- para negocios pequeños, medianos y grandes.
--
--   1) Saldo negativo POR cuenta de dinero (lo decide el dueño, con motivo):
--        no_permitir (por defecto) | permitir_con_alerta ("revise el saldo
--        inicial" mientras esté en negativo) | sobregiro_hasta (con límite).
--      El rastro (de dónde viene y a dónde va) sigue siendo obligatorio.
--   2) Turnos de caja obligatorios o no, por empresa. Sin turnos obligatorios
--      el efectivo entra a la caja sin turno (interno.cuenta_efectivo_cobro).
--   3) Perfiles por tamaño (pequeno, mediano, grande) como DATOS
--      (interno.plantilla_perfil*): vista_previa_perfil y aplicar_perfil (solo
--      el dueño, con motivo y bitácora). Nunca borran datos ni activan o
--      desactivan módulos (eso es del proveedor según el plan).
--      crear_empresa_inicial acepta "perfil" en la ficha.
--   4) Asistente de arranque: estado_arranque (7 pasos, se marcan "hechos"
--      solos con los datos reales) y marcar_paso_arranque (saltar o volver
--      a pendiente). Nunca bloquea operar. empezar_cuenta_en_cero deja
--      constancia de que una caja o banco empieza en L 0.00.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('PERFIL_INVALIDO', 'Ese perfil de negocio no existe.', 'Elija uno de los perfiles: pequeno, mediano o grande.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('arranque.gestionar', 'Ver el avance del asistente de arranque y marcar pasos como saltados o pendientes', false, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'arranque.gestionar'), ('admin', 'arranque.gestionar');
SELECT interno.repartir_permisos(ARRAY['arranque.gestionar'], 'Núcleo 0.6.0: asistente de arranque');

-- ---------------------------------------------------------------------
-- 1) Columnas nuevas (las empresas y cuentas de antes quedan como estaban:
--    turnos obligatorios, contabilidad visible, sin saldo negativo)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa
  ADD COLUMN turnos_obligatorios  boolean NOT NULL DEFAULT true,
  ADD COLUMN contabilidad_visible boolean NOT NULL DEFAULT true,   -- bandera para el menú de la app
  ADD COLUMN doble_aprobacion     boolean NOT NULL DEFAULT false,  -- se aplicará en 2b-2 (ventas)
  ADD COLUMN perfil               text CHECK (perfil IN ('pequeno', 'mediano', 'grande'));

ALTER TABLE public.cuenta_dinero
  ADD COLUMN politica_saldo_negativo   text NOT NULL DEFAULT 'no_permitir'
    CHECK (politica_saldo_negativo IN ('no_permitir', 'permitir_con_alerta', 'sobregiro_hasta')),
  ADD COLUMN sobregiro_limite_centavos bigint CHECK (sobregiro_limite_centavos BETWEEN 1 AND 9007199254740991),
  ADD COLUMN inicia_en_cero_en         timestamptz,     -- "empezar en cero" (asistente de arranque)
  ADD COLUMN inicia_en_cero_por        uuid,
  ADD CONSTRAINT cuenta_dinero_sobregiro CHECK ((politica_saldo_negativo = 'sobregiro_hasta') = (sobregiro_limite_centavos IS NOT NULL)),
  ADD CONSTRAINT cuenta_dinero_transito_sin_negativo CHECK (tipo <> 'transito' OR politica_saldo_negativo = 'no_permitir'),
  ADD CONSTRAINT cuenta_dinero_en_cero CHECK (inicia_en_cero_por IS NULL OR inicia_en_cero_en IS NOT NULL);

-- Defensa de la cuenta de dinero (reemplaza la de 022): además, "empezar en
-- cero" se marca una sola vez.
CREATE OR REPLACE FUNCTION interno.proteger_cuenta_dinero() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.tipo, NEW.cuenta_id, NEW.caja_id, NEW.moneda, NEW.creado_por, NEW.creado_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.tipo, OLD.cuenta_id, OLD.caja_id, OLD.moneda, OLD.creado_por, OLD.creado_en) THEN
    RAISE EXCEPTION 'PROHIBIDO: de una cuenta de dinero no se cambia el tipo, la subcuenta, la caja ni la moneda.';
  END IF;
  IF OLD.inicia_en_cero_en IS NOT NULL
     AND (NEW.inicia_en_cero_en, NEW.inicia_en_cero_por) IS DISTINCT FROM (OLD.inicia_en_cero_en, OLD.inicia_en_cero_por) THEN
    RAISE EXCEPTION 'PROHIBIDO: "empezar en cero" se marca una sola vez.';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 2) El rastro con la política de saldo negativo (reemplaza la de 022;
--    misma firma). Solo se revisa la cuenta de la que SALE dinero en este
--    asiento: una entrada nunca se rechaza aunque la cuenta siga en negativo.
--    Quien llama tiene tomado bloquear_libros (los saldos no cambian por debajo).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.rastrear_dinero(p_asiento_id uuid, p_operacion text, p_documento_tipo text,
                                                   p_documento_id uuid, p_referencia text DEFAULT NULL, p_equipo text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r       record;
  v_emp   uuid;
  v_fecha date;
  v_n     integer := 0;
  v_cds   uuid[] := '{}';
  d       public.cuenta_dinero;
  v_saldo bigint;
  v_neto  bigint;
BEGIN
  IF p_asiento_id IS NULL THEN
    RETURN 0;
  END IF;
  SELECT a.empresa_id, a.fecha_contable INTO v_emp, v_fecha FROM public.asiento a WHERE a.id = p_asiento_id;
  PERFORM interno.bloquear_libros(v_emp);
  FOR r IN SELECT l.id, l.debe_centavos, l.haber_centavos, cd.id AS cd_id
             FROM public.asiento_linea l JOIN public.cuenta_dinero cd ON cd.cuenta_id = l.cuenta_id
            WHERE l.asiento_id = p_asiento_id
              AND NOT EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.asiento_linea_id = l.id)
            ORDER BY l.linea LOOP
    INSERT INTO public.dinero_movimiento (empresa_id, cuenta_dinero_id, asiento_id, asiento_linea_id, fecha_contable,
      monto_centavos, operacion, documento_tipo, documento_id, contrapartida, turno_id, referencia, equipo, creado_por)
    VALUES (v_emp, r.cd_id, p_asiento_id, r.id, v_fecha, r.debe_centavos - r.haber_centavos, p_operacion,
      p_documento_tipo, p_documento_id, interno.contrapartida_linea(p_asiento_id, r.id), interno.turno_de_cuenta(r.cd_id),
      nullif(trim(p_referencia), ''), p_equipo, auth.uid());
    v_n := v_n + 1;
    v_cds := v_cds || r.cd_id;
  END LOOP;

  FOR d IN SELECT * FROM public.cuenta_dinero x WHERE x.id = ANY (v_cds) LOOP
    v_saldo := interno.saldo_dinero(d.id);
    SELECT coalesce(sum(m.monto_centavos), 0) INTO v_neto
      FROM public.dinero_movimiento m WHERE m.asiento_id = p_asiento_id AND m.cuenta_dinero_id = d.id;
    IF v_saldo < 0 AND v_neto < 0 THEN
      IF d.politica_saldo_negativo = 'no_permitir' THEN
        RAISE EXCEPTION 'SALDO_INSUFICIENTE: la cuenta "%" quedaría en % (no alcanza el dinero).',
          d.nombre, interno.lempiras(v_saldo);
      ELSIF d.politica_saldo_negativo = 'sobregiro_hasta' AND v_saldo < -d.sobregiro_limite_centavos THEN
        RAISE EXCEPTION 'SALDO_INSUFICIENTE: la cuenta "%" quedaría en % y su sobregiro autorizado es hasta %.',
          d.nombre, interno.lempiras(v_saldo), interno.lempiras(-d.sobregiro_limite_centavos);
      END IF;
    END IF;
    IF d.tipo = 'caja_chica' AND v_saldo > d.fondo_fijo_centavos THEN
      RAISE EXCEPTION 'TOPE_CAJA_CHICA: la caja chica "%" quedaría con % y su fondo fijo es %.',
        d.nombre, interno.lempiras(v_saldo), interno.lempiras(d.fondo_fijo_centavos);
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- Alerta de una cuenta en negativo (NULL si no está en negativo).
CREATE FUNCTION interno.alerta_saldo_negativo(d public.cuenta_dinero, p_saldo bigint) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_saldo >= 0 THEN NULL
    WHEN d.politica_saldo_negativo = 'sobregiro_hasta' THEN
      'La cuenta "' || d.nombre || '" está en sobregiro: ' || interno.lempiras(p_saldo)
        || ' (autorizado hasta ' || interno.lempiras(-d.sobregiro_limite_centavos) || ').'
    ELSE 'Revise el saldo inicial: la cuenta "' || d.nombre || '" está en negativo (' || interno.lempiras(p_saldo) || ').'
  END
$$;

-- RPC: configurar_saldo_negativo(empresa, cuenta, politica, limite, motivo)   empresa.configurar (solo el dueño)
--   politica: 'no_permitir' | 'permitir_con_alerta' | 'sobregiro_hasta' (con limite_centavos > 0).
--   No se pasa a una política más estricta si la cuenta ya está por debajo
--   de lo que esa política permite (primero se registra la entrada que falta).
CREATE FUNCTION public.configurar_saldo_negativo(p_empresa_id uuid, p_cuenta_dinero_id uuid, p_politica text,
                                                 p_limite_centavos bigint, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d       public.cuenta_dinero;
  v_saldo bigint;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', 'dinero');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF coalesce(p_politica, '') NOT IN ('no_permitir', 'permitir_con_alerta', 'sobregiro_hasta') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la política es no_permitir, permitir_con_alerta o sobregiro_hasta.';
  END IF;
  IF p_politica = 'sobregiro_hasta' AND (p_limite_centavos IS NULL OR p_limite_centavos NOT BETWEEN 1 AND 9007199254740991) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el sobregiro necesita su límite en centavos (mayor que cero).';
  END IF;
  IF p_politica <> 'sobregiro_hasta' AND p_limite_centavos IS NOT NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el límite solo va con la política sobregiro_hasta.';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = p_cuenta_dinero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de dinero no existe en esta empresa.';
  END IF;
  IF d.tipo = 'transito' AND p_politica <> 'no_permitir' THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: el dinero en tránsito nunca queda en negativo.';
  END IF;
  v_saldo := interno.saldo_dinero(d.id);
  IF v_saldo < 0 AND (p_politica = 'no_permitir' OR (p_politica = 'sobregiro_hasta' AND v_saldo < -p_limite_centavos)) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la cuenta "%" está hoy en %; registre primero su saldo inicial o la entrada que falta.',
      d.nombre, interno.lempiras(v_saldo);
  END IF;
  IF (d.politica_saldo_negativo, d.sobregiro_limite_centavos) IS NOT DISTINCT FROM (p_politica, p_limite_centavos) THEN
    RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'politica', d.politica_saldo_negativo,
      'sobregiro_limite_centavos', d.sobregiro_limite_centavos, 'saldo_centavos', v_saldo, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.cuenta_dinero SET politica_saldo_negativo = p_politica, sobregiro_limite_centavos = p_limite_centavos
   WHERE id = d.id
  RETURNING * INTO d;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'politica', d.politica_saldo_negativo,
    'sobregiro_limite_centavos', d.sobregiro_limite_centavos, 'saldo_centavos', v_saldo,
    'alerta', interno.alerta_saldo_negativo(d, v_saldo), 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- 3) Turnos de caja obligatorios o no
-- ---------------------------------------------------------------------
-- Reemplaza la de 023: si la empresa NO exige turnos y el usuario no tiene
-- uno abierto, devuelve un turno vacío (id NULL) en vez de error.
CREATE OR REPLACE FUNCTION interno.exigir_turno_abierto(p_empresa_id uuid) RETURNS public.turno_caja
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.turno_caja;
BEGIN
  SELECT * INTO t FROM public.turno_caja x
   WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
  IF t.id IS NULL AND coalesce((SELECT e.turnos_obligatorios FROM public.empresa e WHERE e.id = p_empresa_id), true) THEN
    RAISE EXCEPTION 'SIN_TURNO_ABIERTO: abra su turno de caja para cobrar en efectivo.';
  END IF;
  RETURN t;
END $$;

-- Para la etapa 2b-2 (cobros en efectivo): a qué cuenta de dinero entra el efectivo.
--   * Con turno abierto: la caja de su turno (si indica otra caja, error).
--   * Sin turno y turnos obligatorios: SIN_TURNO_ABIERTO (regla de siempre).
--   * Sin turno y turnos NO obligatorios: la cuenta de efectivo de la caja
--     indicada (o de la única caja activa); se crea si no existe. Si esa caja
--     tiene abierto el turno de otro cajero: CAJA_OCUPADA (no se mezcla con su arqueo).
CREATE FUNCTION interno.cuenta_efectivo_cobro(p_empresa_id uuid, p_caja_id uuid DEFAULT NULL) RETURNS public.cuenta_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t      public.turno_caja;
  v_caja public.caja;
  v_suc  public.sucursal;
  v_id   uuid := p_caja_id;
  v_n    integer;
  d      public.cuenta_dinero;
BEGIN
  SELECT * INTO t FROM public.turno_caja x
   WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
  IF t.id IS NOT NULL THEN
    IF v_id IS NOT NULL AND v_id <> t.caja_id THEN
      RAISE EXCEPTION 'DATO_INVALIDO: usted tiene abierto el turno #% en la caja "%"; cobre en esa caja.',
        t.numero, (SELECT c.nombre FROM public.caja c WHERE c.id = t.caja_id);
    END IF;
    SELECT * INTO d FROM public.cuenta_dinero x WHERE x.id = t.cuenta_dinero_id;
    RETURN d;
  END IF;
  IF coalesce((SELECT e.turnos_obligatorios FROM public.empresa e WHERE e.id = p_empresa_id), true) THEN
    RAISE EXCEPTION 'SIN_TURNO_ABIERTO: abra su turno de caja para cobrar en efectivo.';
  END IF;
  IF v_id IS NULL THEN
    SELECT count(*), min(c.id::text)::uuid INTO v_n, v_id FROM public.caja c
     WHERE c.empresa_id = p_empresa_id AND c.activa;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique en qué caja entra el efectivo (la empresa tiene % cajas activas).', v_n;
    END IF;
  END IF;
  SELECT * INTO v_caja FROM public.caja c WHERE c.id = v_id AND c.empresa_id = p_empresa_id AND c.activa;
  SELECT * INTO v_suc FROM public.sucursal s WHERE s.id = v_caja.sucursal_id AND s.activa;
  IF v_caja.id IS NULL OR v_suc.id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la caja no existe en esta empresa o está desactivada (ella o su sucursal).';
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
    RAISE EXCEPTION 'CAJA_OCUPADA: la caja "%" tiene abierto el turno de otro cajero; cobre en otra caja o abra su propio turno.', v_caja.nombre;
  END IF;
  RETURN d;
END $$;

-- ---------------------------------------------------------------------
-- 4) configurar_empresa (reemplaza la de 022; misma firma). Claves nuevas
--    (solo el dueño): "turnos_obligatorios", "contabilidad_visible",
--    "doble_aprobacion" (true/false).
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
                 'turnos_obligatorios', 'contabilidad_visible', 'doble_aprobacion') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'tope_credito_centavos' AND NOT (jsonb_typeof(p_datos->'tope_credito_centavos') = 'number'
       AND (p_datos->>'tope_credito_centavos') ~ '^[0-9]{1,16}$'
       AND (p_datos->>'tope_credito_centavos')::numeric <= 9007199254740991) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "tope_credito_centavos" debe ser un entero de centavos, 0 o más.';
  END IF;
  FOREACH k IN ARRAY ARRAY['permite_existencia_negativa', 'precio_incluye_isv_defecto', 'turnos_obligatorios',
                           'contabilidad_visible', 'doble_aprobacion'] LOOP
    IF p_datos ? k AND jsonb_typeof(p_datos->k) <> 'boolean' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "%" debe ser true o false.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'dias_alerta_transito' AND NOT (jsonb_typeof(p_datos->'dias_alerta_transito') = 'number'
       AND (p_datos->>'dias_alerta_transito') ~ '^[0-9]{1,2}$' AND (p_datos->>'dias_alerta_transito')::integer <= 60) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "dias_alerta_transito" debe ser un número entero de 0 a 60.';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET
    tope_credito_centavos = coalesce((p_datos->>'tope_credito_centavos')::bigint, tope_credito_centavos),
    permite_existencia_negativa = coalesce((p_datos->>'permite_existencia_negativa')::boolean, permite_existencia_negativa),
    precio_incluye_isv_defecto = coalesce((p_datos->>'precio_incluye_isv_defecto')::boolean, precio_incluye_isv_defecto),
    dias_alerta_transito = coalesce((p_datos->>'dias_alerta_transito')::integer, dias_alerta_transito),
    turnos_obligatorios = coalesce((p_datos->>'turnos_obligatorios')::boolean, turnos_obligatorios),
    contabilidad_visible = coalesce((p_datos->>'contabilidad_visible')::boolean, contabilidad_visible),
    doble_aprobacion = coalesce((p_datos->>'doble_aprobacion')::boolean, doble_aprobacion)
  WHERE id = p_empresa_id
  RETURNING * INTO v_emp;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('tope_credito_centavos', v_emp.tope_credito_centavos,
                            'permite_existencia_negativa', v_emp.permite_existencia_negativa,
                            'precio_incluye_isv_defecto', v_emp.precio_incluye_isv_defecto,
                            'dias_alerta_transito', v_emp.dias_alerta_transito,
                            'turnos_obligatorios', v_emp.turnos_obligatorios,
                            'contabilidad_visible', v_emp.contabilidad_visible,
                            'doble_aprobacion', v_emp.doble_aprobacion);
END $$;

-- ---------------------------------------------------------------------
-- 5) Perfiles por tamaño: plantillas como DATOS (el proveedor las ajusta
--    con una migración; el dueño elige y aplica uno, y después cambia lo
--    que quiera con configurar_empresa / configurar_tope_rol).
-- ---------------------------------------------------------------------
CREATE TABLE interno.plantilla_perfil (
  codigo                text PRIMARY KEY CHECK (codigo IN ('pequeno', 'mediano', 'grande')),
  orden                 integer NOT NULL UNIQUE,
  nombre                text NOT NULL,
  descripcion           text NOT NULL,
  turnos_obligatorios   boolean NOT NULL,
  contabilidad_visible  boolean NOT NULL,
  doble_aprobacion      boolean NOT NULL
);
-- Módulos que el perfil SUGIERE (los activa el proveedor según el plan).
CREATE TABLE interno.plantilla_perfil_modulo (
  perfil  text NOT NULL REFERENCES interno.plantilla_perfil(codigo),
  modulo  text NOT NULL REFERENCES public.modulo(codigo),
  PRIMARY KEY (perfil, modulo)
);
-- Topes por puesto que pone el perfil (los mismos tipos que tope_rol).
CREATE TABLE interno.plantilla_perfil_tope (
  perfil                   text NOT NULL REFERENCES interno.plantilla_perfil(codigo),
  rol                      text NOT NULL REFERENCES public.rol(codigo),
  tipo                     text NOT NULL CHECK (tipo IN ('gasto')),
  sin_aprobacion_centavos  bigint NOT NULL CHECK (sin_aprobacion_centavos BETWEEN 0 AND 9007199254740991),
  aprueba_hasta_centavos   bigint NOT NULL CHECK (aprueba_hasta_centavos BETWEEN 0 AND 9007199254740991),
  PRIMARY KEY (perfil, rol, tipo),
  CHECK (rol NOT IN ('dueno', 'proveedor'))
);

INSERT INTO interno.plantilla_perfil VALUES
  ('pequeno', 1, 'Negocio pequeño',
   'El dueño y pocas personas. El efectivo entra a la caja sin turno (los turnos se pueden usar si se quiere); la contabilidad no sale en el menú (los libros se llevan igual); una sola aprobación.',
   false, false, false),
  ('mediano', 2, 'Negocio mediano',
   'Varios empleados y cajeros. Turno por cajero con arqueo a ciegas; contabilidad en el menú; una sola aprobación.',
   true, true, false),
  ('grande', 3, 'Negocio grande',
   'Varias sucursales o muchos empleados. Turno por cajero con arqueo a ciegas; contabilidad en el menú; doble aprobación.',
   true, true, true);
INSERT INTO interno.plantilla_perfil_modulo (perfil, modulo) VALUES
  ('pequeno', 'contabilidad'), ('pequeno', 'ventas'), ('pequeno', 'inventario'), ('pequeno', 'dinero'),
  ('mediano', 'contabilidad'), ('mediano', 'ventas'), ('mediano', 'inventario'), ('mediano', 'compras'), ('mediano', 'dinero'),
  ('grande',  'contabilidad'), ('grande',  'ventas'), ('grande',  'inventario'), ('grande',  'compras'), ('grande',  'dinero');
-- Valor aprobado por el dueño: el admin registra y aprueba gastos hasta L 5,000.00 (igual en los tres).
INSERT INTO interno.plantilla_perfil_tope VALUES
  ('pequeno', 'admin', 'gasto', 500000, 500000),
  ('mediano', 'admin', 'gasto', 500000, 500000),
  ('grande',  'admin', 'gasto', 500000, 500000);

CREATE FUNCTION interno.perfil_de(p_perfil text) RETURNS interno.plantilla_perfil
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE p interno.plantilla_perfil;
BEGIN
  SELECT * INTO p FROM interno.plantilla_perfil x WHERE x.codigo = p_perfil;
  IF p.codigo IS NULL THEN
    RAISE EXCEPTION 'PERFIL_INVALIDO: el perfil "%" no existe (use pequeno, mediano o grande).', coalesce(p_perfil, '');
  END IF;
  RETURN p;
END $$;

-- Qué cambiaría el perfil en la empresa, SIN aplicarlo.
CREATE FUNCTION interno.cambios_perfil(p_empresa_id uuid, p_perfil text) RETURNS jsonb
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
      v_avisos := v_avisos || to_jsonb('La doble aprobación queda guardada; se aplicará a las aprobaciones de ventas (etapa 2b-2). Los gastos siguen con una aprobación.'::text);
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

-- Aplica el perfil: banderas de la empresa y topes que difieren. NUNCA toca
-- módulos ni datos. Quien llama pone app.motivo (bitácora).
CREATE FUNCTION interno.guardar_perfil(p_empresa_id uuid, p_perfil text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p interno.plantilla_perfil := interno.perfil_de(p_perfil);
BEGIN
  UPDATE public.empresa
     SET perfil = p.codigo, turnos_obligatorios = p.turnos_obligatorios,
         contabilidad_visible = p.contabilidad_visible, doble_aprobacion = p.doble_aprobacion
   WHERE id = p_empresa_id
     AND (perfil, turnos_obligatorios, contabilidad_visible, doble_aprobacion)
         IS DISTINCT FROM (p.codigo, p.turnos_obligatorios, p.contabilidad_visible, p.doble_aprobacion);
  INSERT INTO public.tope_rol (empresa_id, rol, tipo, sin_aprobacion_centavos, aprueba_hasta_centavos, actualizado_por)
  SELECT p_empresa_id, t.rol, t.tipo, t.sin_aprobacion_centavos, t.aprueba_hasta_centavos, auth.uid()
    FROM interno.plantilla_perfil_tope t
    CROSS JOIN LATERAL interno.tope_rol(p_empresa_id, t.rol, t.tipo) a
   WHERE t.perfil = p.codigo
     AND (a.sin_aprobacion, a.aprueba_hasta) IS DISTINCT FROM (t.sin_aprobacion_centavos, t.aprueba_hasta_centavos)
  ON CONFLICT (empresa_id, rol, tipo) DO UPDATE
     SET sin_aprobacion_centavos = excluded.sin_aprobacion_centavos, aprueba_hasta_centavos = excluded.aprueba_hasta_centavos,
         actualizado_por = excluded.actualizado_por, actualizado_en = now();
END $$;

-- RPC: perfiles_negocio()   los perfiles disponibles con lo que traen (para elegir).
CREATE FUNCTION public.perfiles_negocio()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('perfil', p.codigo, 'nombre', p.nombre, 'descripcion', p.descripcion,
           'turnos_obligatorios', p.turnos_obligatorios, 'contabilidad_visible', p.contabilidad_visible,
           'doble_aprobacion', p.doble_aprobacion,
           'modulos_sugeridos', (SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]')
                                   FROM interno.plantilla_perfil_modulo m WHERE m.perfil = p.codigo),
           'topes', (SELECT coalesce(jsonb_agg(jsonb_build_object('rol', t.rol, 'tipo', t.tipo,
                              'sin_aprobacion_centavos', t.sin_aprobacion_centavos,
                              'aprueba_hasta_centavos', t.aprueba_hasta_centavos) ORDER BY t.rol, t.tipo), '[]')
                       FROM interno.plantilla_perfil_tope t WHERE t.perfil = p.codigo))
           ORDER BY p.orden), '[]')
    FROM interno.plantilla_perfil p
$$;

-- RPC: vista_previa_perfil(empresa, perfil)   empresa.configurar (solo el dueño)
-- Devuelve qué cambiaría (cambios, topes, módulos, avisos) sin cambiar nada.
CREATE FUNCTION public.vista_previa_perfil(p_empresa_id uuid, p_perfil text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'empresa.configurar');
  IF NOT EXISTS (SELECT 1 FROM public.empresa e WHERE e.id = p_empresa_id) THEN
    RAISE EXCEPTION 'NO_EXISTE: la empresa no existe.';
  END IF;
  RETURN interno.cambios_perfil(p_empresa_id, p_perfil);
END $$;

-- RPC: aplicar_perfil(empresa, perfil, motivo)   empresa.configurar (solo el dueño)
-- Aplica lo que muestra la vista previa (queda en la bitácora con el motivo).
-- Se puede volver a aplicar otro perfil cuando se quiera.
CREATE FUNCTION public.aplicar_perfil(p_empresa_id uuid, p_perfil text, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM interno.perfil_de(p_perfil);
  PERFORM 1 FROM public.empresa e WHERE e.id = p_empresa_id FOR UPDATE;
  v := interno.cambios_perfil(p_empresa_id, p_perfil);
  PERFORM set_config('app.motivo', 'Perfil ' || p_perfil || ': ' || trim(p_motivo), true);
  PERFORM interno.guardar_perfil(p_empresa_id, p_perfil);
  PERFORM set_config('app.motivo', '', true);
  RETURN v || jsonb_build_object('aplicado', true);
END $$;

-- crear_empresa_inicial (reemplaza la de 007; misma firma). Nuevo: "perfil"
-- en la ficha (pequeno, mediano, grande). Si la ficha NO trae "modulos", se
-- activan los que sugiere el perfil (lo decide quien instala: el proveedor).
CREATE OR REPLACE FUNCTION public.crear_empresa_inicial(p_ficha jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_empresa   uuid;
  v_sucursal  uuid;
  v_dueno     uuid;
  v_proveedor uuid;
  v_perfil    text;
BEGIN
  IF jsonb_typeof(p_ficha) = 'object' AND p_ficha ? 'perfil' AND p_ficha->'perfil' <> 'null'::jsonb THEN
    IF jsonb_typeof(p_ficha->'perfil') <> 'string'
       OR NOT EXISTS (SELECT 1 FROM interno.plantilla_perfil x WHERE x.codigo = p_ficha->>'perfil') THEN
      RAISE EXCEPTION 'FICHA_INVALIDA: "perfil" debe ser pequeno, mediano o grande.';
    END IF;
    v_perfil := p_ficha->>'perfil';
  END IF;
  PERFORM interno.validar_ficha(CASE WHEN jsonb_typeof(p_ficha) = 'object' THEN p_ficha - 'perfil' ELSE p_ficha END);
  v_dueno := interno.usuario_de_ficha(p_ficha->'dueno', 'dueno');
  IF p_ficha ? 'proveedor' AND p_ficha->'proveedor' <> 'null' THEN
    v_proveedor := interno.usuario_de_ficha(p_ficha->'proveedor', 'proveedor');
    IF v_proveedor = v_dueno THEN
      RAISE EXCEPTION 'FICHA_INVALIDA: el dueño y el proveedor no pueden ser el mismo usuario.';
    END IF;
  END IF;

  INSERT INTO public.empresa (nombre, rtn, rubro, moneda, pais, zona_horaria, fecha_inicio, dias_futuro_max)
  VALUES (trim(p_ficha->>'nombre'),
          nullif(p_ficha->>'rtn', ''),
          nullif(trim(p_ficha->>'rubro'), ''),
          coalesce(p_ficha->>'moneda', 'HNL'),
          coalesce(p_ficha->>'pais', 'HN'),
          coalesce(p_ficha->>'zona_horaria', 'America/Tegucigalpa'),
          (p_ficha->>'fecha_inicio')::date,
          coalesce((p_ficha->>'dias_futuro_max')::integer, 3))
  RETURNING id INTO v_empresa;

  INSERT INTO public.sucursal (empresa_id, codigo, nombre)
  VALUES (v_empresa, '001', 'Principal') RETURNING id INTO v_sucursal;

  INSERT INTO public.caja (empresa_id, sucursal_id, nombre, punto_emision)
  VALUES (v_empresa, v_sucursal, 'Caja principal', '001');

  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol, nombre)
  VALUES (v_dueno, v_empresa, 'dueno', nullif(trim(p_ficha->'dueno'->>'nombre'), ''));
  IF v_proveedor IS NOT NULL THEN
    INSERT INTO public.usuario_empresa (user_id, empresa_id, rol, nombre)
    VALUES (v_proveedor, v_empresa, 'proveedor', nullif(trim(p_ficha->'proveedor'->>'nombre'), ''));
  END IF;

  INSERT INTO public.rol_permiso (empresa_id, rol, permiso)
  SELECT v_empresa, rol, permiso FROM interno.plantilla_rol_permiso;

  -- Contabilidad siempre; los demás según la ficha (o, sin "modulos", los del perfil).
  INSERT INTO public.modulo_activo (empresa_id, modulo)
  SELECT v_empresa, m FROM (
    SELECT 'contabilidad' AS m
    UNION
    SELECT jsonb_array_elements_text(coalesce(p_ficha->'modulos', '[]'))
    UNION
    SELECT pm.modulo FROM interno.plantilla_perfil_modulo pm
     WHERE pm.perfil = v_perfil AND NOT p_ficha ? 'modulos') x;

  PERFORM interno.copiar_catalogo(v_empresa);

  IF v_perfil IS NOT NULL THEN
    PERFORM set_config('app.motivo', 'Perfil inicial ' || v_perfil || ' (ficha del cliente)', true);
    PERFORM interno.guardar_perfil(v_empresa, v_perfil);
    PERFORM set_config('app.motivo', '', true);
  END IF;

  RETURN v_empresa;
END $$;

-- ---------------------------------------------------------------------
-- 6) Asistente de arranque
-- ---------------------------------------------------------------------
CREATE TABLE public.arranque_paso (
  empresa_id   uuid NOT NULL REFERENCES public.empresa(id),
  paso         text NOT NULL CHECK (paso IN ('datos_negocio', 'usuarios', 'cuentas_dinero', 'productos',
                                             'clientes', 'proveedores', 'primera_venta')),
  estado       text NOT NULL CHECK (estado IN ('saltado', 'pendiente')),
  marcado_por  uuid,
  marcado_en   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (empresa_id, paso)
);
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.arranque_paso FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.arranque_paso
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los pasos del arranque no se borran: se marcan pendientes.');

-- RPC: estado_arranque(empresa)   arranque.gestionar
-- Los 7 pasos con estado hecho / saltado / pendiente. "hecho" sale de los
-- datos reales (y gana a "saltado"); porcentaje = pasos hechos de 7.
CREATE FUNCTION public.estado_arranque(p_empresa_id uuid)
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
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'arranque.gestionar');
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la empresa no existe.';
  END IF;
  -- Cajas y bancos activos sin saldo inicial vigente ni "empezar en cero".
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
    (7, 'primera_venta', 'Primera venta', false,
        'Se marcará sola cuando exista el módulo de ventas (etapa 2b-2); mientras tanto se puede saltar.'))
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

-- RPC: marcar_paso_arranque(empresa, paso, estado)   arranque.gestionar
-- estado: 'saltado' (el programa lo recuerda sin bloquear) o 'pendiente'.
CREATE FUNCTION public.marcar_paso_arranque(p_empresa_id uuid, p_paso text, p_estado text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'arranque.gestionar', NULL);
  IF coalesce(p_paso, '') NOT IN ('datos_negocio', 'usuarios', 'cuentas_dinero', 'productos', 'clientes', 'proveedores', 'primera_venta') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el paso es datos_negocio, usuarios, cuentas_dinero, productos, clientes, proveedores o primera_venta.';
  END IF;
  IF coalesce(p_estado, '') NOT IN ('saltado', 'pendiente') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el estado es "saltado" o "pendiente" (hecho se marca solo con los datos).';
  END IF;
  INSERT INTO public.arranque_paso (empresa_id, paso, estado, marcado_por)
  VALUES (p_empresa_id, p_paso, p_estado, auth.uid())
  ON CONFLICT (empresa_id, paso) DO UPDATE
     SET estado = excluded.estado, marcado_por = excluded.marcado_por, marcado_en = now()
   WHERE public.arranque_paso.estado <> excluded.estado;
  RETURN public.estado_arranque(p_empresa_id);
END $$;

-- RPC: empezar_cuenta_en_cero(empresa, cuenta)   dinero.saldo_inicial (dueño)
-- Deja constancia de que la caja o banco empieza en L 0.00 (no mueve dinero).
-- Si después aparece dinero de antes, el dueño registra su saldo inicial
-- (registrar_saldo_inicial_dinero, una vez por cuenta, anulable).
CREATE FUNCTION public.empezar_cuenta_en_cero(p_empresa_id uuid, p_cuenta_dinero_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.cuenta_dinero;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'dinero.saldo_inicial', 'dinero');
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO d FROM public.cuenta_dinero WHERE id = p_cuenta_dinero_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: la cuenta de dinero no existe en esta empresa.';
  END IF;
  IF d.tipo = 'transito' THEN
    RAISE EXCEPTION 'CUENTA_DINERO_INVALIDA: el dinero en tránsito no lleva saldo inicial.';
  END IF;
  IF d.inicia_en_cero_en IS NOT NULL THEN
    RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'inicia_en_cero', true, 'ya_estaba', true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.destino_id = d.id AND x.tipo = 'saldo_inicial' AND x.anulada_en IS NULL) THEN
    RAISE EXCEPTION 'SALDO_INICIAL_YA_CARGADO: la cuenta "%" ya tiene saldo inicial; no puede empezar en cero.', d.nombre;
  END IF;
  PERFORM set_config('app.motivo', 'Empezar en cero (asistente de arranque)', true);
  UPDATE public.cuenta_dinero SET inicia_en_cero_en = now(), inicia_en_cero_por = auth.uid() WHERE id = d.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('cuenta_dinero_id', d.id, 'inicia_en_cero', true, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- 7) Lecturas con la alerta de saldo negativo
-- ---------------------------------------------------------------------
-- v_cuenta_dinero (reemplaza la de 022: mismas columnas y al final las nuevas).
CREATE OR REPLACE VIEW public.v_cuenta_dinero WITH (security_invoker = true) AS
  SELECT d.empresa_id, d.id AS cuenta_dinero_id, d.tipo, d.nombre, d.sucursal_id, s.nombre AS sucursal,
         d.caja_id, cj.nombre AS caja, d.banco, d.numero_enmascarado, d.tipo_cuenta, d.moneda,
         d.fondo_fijo_centavos, d.activa, c.codigo AS cuenta_codigo,
         coalesce(m.saldo, 0)::bigint AS saldo_centavos, m.ultimo_movimiento_en,
         d.politica_saldo_negativo, d.sobregiro_limite_centavos,
         coalesce(m.saldo, 0) < 0 AS alerta_saldo_negativo,
         d.inicia_en_cero_en
  FROM public.cuenta_dinero d
  JOIN public.cuenta c ON c.id = d.cuenta_id
  LEFT JOIN public.sucursal s ON s.id = d.sucursal_id
  LEFT JOIN public.caja cj ON cj.id = d.caja_id
  LEFT JOIN (SELECT x.cuenta_dinero_id, sum(x.monto_centavos) AS saldo, max(x.registrado_en) AS ultimo_movimiento_en
               FROM public.dinero_movimiento x GROUP BY x.cuenta_dinero_id) m ON m.cuenta_dinero_id = d.id;

-- donde_esta_mi_dinero (reemplaza la de 022; misma firma). Nuevo: por cuenta
-- su política y su alerta; arriba la lista "alertas" de cuentas en negativo.
CREATE OR REPLACE FUNCTION public.donde_esta_mi_dinero(p_empresa_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cuentas  jsonb;
  v_tipos    jsonb;
  v_transito jsonb;
  v_otras    jsonb;
  v_alertas  jsonb;
  v_total    bigint;
BEGIN
  PERFORM interno.exigir_lectura(p_empresa_id, 'dinero.ver');
  WITH s AS (
    SELECT d AS fila, d.*, interno.saldo_dinero(d.id) AS saldo, c.codigo AS cuenta_codigo
      FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
     WHERE d.empresa_id = p_empresa_id)
  SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', s.id, 'tipo', s.tipo, 'nombre', s.nombre,
           'banco', s.banco, 'numero_enmascarado', s.numero_enmascarado, 'sucursal_id', s.sucursal_id,
           'cuenta_codigo', s.cuenta_codigo, 'activa', s.activa, 'saldo_centavos', s.saldo,
           'fondo_fijo_centavos', s.fondo_fijo_centavos, 'turno_abierto_id', interno.turno_de_cuenta(s.id),
           'politica_saldo_negativo', s.politica_saldo_negativo, 'sobregiro_limite_centavos', s.sobregiro_limite_centavos,
           'alerta', interno.alerta_saldo_negativo(s.fila, s.saldo))
           ORDER BY s.tipo, s.nombre) FILTER (WHERE s.activa OR s.saldo <> 0), '[]'),
         coalesce(sum(s.saldo), 0),
         coalesce(jsonb_agg(jsonb_build_object('cuenta_dinero_id', s.id, 'nombre', s.nombre, 'saldo_centavos', s.saldo,
           'politica_saldo_negativo', s.politica_saldo_negativo, 'mensaje', interno.alerta_saldo_negativo(s.fila, s.saldo))
           ORDER BY s.nombre) FILTER (WHERE s.saldo < 0), '[]')
    INTO v_cuentas, v_total, v_alertas FROM s;
  SELECT coalesce(jsonb_object_agg(t.tipo, t.saldo), '{}') INTO v_tipos
    FROM (SELECT d.tipo, sum(interno.saldo_dinero(d.id))::bigint AS saldo
            FROM public.cuenta_dinero d WHERE d.empresa_id = p_empresa_id GROUP BY d.tipo) t;
  SELECT jsonb_build_object('total_centavos', coalesce(sum(o.monto_centavos), 0),
           'con_alerta', count(*) FILTER (WHERE (public.hoy_local(o.empresa_id) - o.fecha_contable) > e.dias_alerta_transito),
           'depositos', coalesce(jsonb_agg(jsonb_build_object('operacion_id', o.id, 'numero', o.numero,
              'fecha', to_char(o.fecha_contable, 'YYYY-MM-DD'), 'monto_centavos', o.monto_centavos,
              'banco', (SELECT x.nombre FROM public.cuenta_dinero x WHERE x.id = o.destino_id),
              'dias', public.hoy_local(o.empresa_id) - o.fecha_contable,
              'alerta', (public.hoy_local(o.empresa_id) - o.fecha_contable) > e.dias_alerta_transito) ORDER BY o.fecha_contable), '[]'))
    INTO v_transito
    FROM public.operacion_dinero o JOIN public.empresa e ON e.id = o.empresa_id
   WHERE o.empresa_id = p_empresa_id AND o.tipo = 'deposito' AND o.estado = 'en_transito' AND o.anulada_en IS NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object('cuenta_codigo', x.codigo, 'nombre', x.nombre, 'saldo_centavos', x.saldo)
                            ORDER BY x.codigo), '[]')
    INTO v_otras
    FROM (SELECT c.codigo, c.nombre, interno.saldo_libros(p_empresa_id, c.codigo) AS saldo
            FROM public.cuenta c
           WHERE c.empresa_id = p_empresa_id AND c.es_detalle AND c.codigo LIKE '1.1.01.%'
             AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d WHERE d.cuenta_id = c.id)) x
   WHERE x.saldo <> 0;
  RETURN jsonb_build_object('fecha', to_char(public.hoy_local(p_empresa_id), 'YYYY-MM-DD'), 'hora_servidor', public.iso(now()),
    'total_centavos', v_total, 'por_tipo', v_tipos, 'cuentas', v_cuentas, 'en_transito', v_transito,
    'otras_cuentas_efectivo_sin_rastro', v_otras,
    'total_con_otras_centavos', v_total + coalesce((SELECT sum((x->>'saldo_centavos')::bigint) FROM jsonb_array_elements(v_otras) x), 0),
    'alertas', v_alertas);
END $$;

-- mi_perfil (reemplaza la de 010; misma firma). Nuevo en "empresa": perfil,
-- turnos_obligatorios, contabilidad_visible (para el menú) y doble_aprobacion.
CREATE OR REPLACE FUNCTION public.mi_perfil(p_empresa_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_emp      public.empresa;
  v_ue       public.usuario_empresa;
  v_empresas jsonb;
  v_soporte  timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre, 'rol', ue.rol)
                            ORDER BY e.nombre), '[]')
    INTO v_empresas
    FROM public.usuario_empresa ue JOIN public.empresa e ON e.id = ue.empresa_id
   WHERE ue.user_id = v_uid AND ue.activo;

  IF p_empresa_id IS NOT NULL AND public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  SELECT * INTO v_emp FROM public.empresa WHERE id = coalesce(p_empresa_id, public.empresa_actual());

  IF v_emp.id IS NULL THEN
    RETURN jsonb_build_object(
      'usuario',  jsonb_build_object('id', v_uid, 'correo', (SELECT u.email FROM auth.users u WHERE u.id = v_uid)),
      'empresas', v_empresas,
      'empresa',  NULL);
  END IF;

  SELECT * INTO v_ue FROM public.usuario_empresa
   WHERE user_id = v_uid AND empresa_id = v_emp.id AND activo;

  SELECT max(s.vence_en) INTO v_soporte FROM public.acceso_soporte s
   WHERE s.empresa_id = v_emp.id AND s.revocado_en IS NULL AND now() BETWEEN s.desde AND s.vence_en;

  RETURN jsonb_build_object(
    'usuario', jsonb_build_object(
        'id', v_uid,
        'correo', (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
        'nombre', v_ue.nombre),
    'empresas', v_empresas,
    'empresa', jsonb_build_object(
        'id', v_emp.id, 'nombre', v_emp.nombre, 'rtn', v_emp.rtn, 'rubro', v_emp.rubro,
        'moneda', v_emp.moneda, 'pais', v_emp.pais, 'zona_horaria', v_emp.zona_horaria,
        'fecha_inicio', to_char(v_emp.fecha_inicio, 'YYYY-MM-DD'),
        'dias_futuro_max', v_emp.dias_futuro_max,
        'hoy', to_char(public.hoy_local(v_emp.id), 'YYYY-MM-DD'),
        'perfil', v_emp.perfil,
        'turnos_obligatorios', v_emp.turnos_obligatorios,
        'contabilidad_visible', v_emp.contabilidad_visible,
        'doble_aprobacion', v_emp.doble_aprobacion),
    'rol', jsonb_build_object('codigo', v_ue.rol,
                              'nombre', (SELECT r.nombre FROM public.rol r WHERE r.codigo = v_ue.rol)),
    'permisos', (SELECT coalesce(jsonb_agg(p.codigo ORDER BY p.codigo), '[]')
                   FROM public.permiso p WHERE public.tiene_permiso(p.codigo, v_emp.id)),
    'modulos',  (SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]')
                   FROM public.modulo_activo m WHERE m.empresa_id = v_emp.id AND m.activo),
    'licencia', interno.estado_licencia(v_emp.id),
    'soporte_vigente_hasta', public.iso(v_soporte),
    'hora_servidor', public.iso(now()));
END $$;

-- ---------------------------------------------------------------------
-- 8) Seguridad
-- ---------------------------------------------------------------------
ALTER TABLE public.arranque_paso ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.arranque_paso
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
GRANT SELECT ON public.arranque_paso TO authenticated, service_role;
CREATE POLICY leer ON public.arranque_paso FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()));

REVOKE ALL ON interno.plantilla_perfil, interno.plantilla_perfil_modulo, interno.plantilla_perfil_tope
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  interno.alerta_saldo_negativo(public.cuenta_dinero, bigint),
  interno.cuenta_efectivo_cobro(uuid, uuid),
  interno.perfil_de(text),
  interno.cambios_perfil(uuid, text),
  interno.guardar_perfil(uuid, text)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.configurar_saldo_negativo(uuid, uuid, text, bigint, text),
  public.perfiles_negocio(),
  public.vista_previa_perfil(uuid, text),
  public.aplicar_perfil(uuid, text, text),
  public.estado_arranque(uuid),
  public.marcar_paso_arranque(uuid, text, text),
  public.empezar_cuenta_en_cero(uuid, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.configurar_saldo_negativo(uuid, uuid, text, bigint, text),
  public.aplicar_perfil(uuid, text, text),
  public.marcar_paso_arranque(uuid, text, text),
  public.empezar_cuenta_en_cero(uuid, uuid)
TO authenticated;
GRANT EXECUTE ON FUNCTION
  public.perfiles_negocio(),
  public.vista_previa_perfil(uuid, text),
  public.estado_arranque(uuid)
TO authenticated, service_role;
