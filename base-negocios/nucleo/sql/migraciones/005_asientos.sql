-- =====================================================================
-- 005_asientos.sql  -  Partida doble: asientos y sus líneas
-- * Todo-o-nada: si algo falla, no se guarda nada.
-- * Nada se edita ni se borra: se anula con un contra-asiento enlazado.
-- * id_operacion único por empresa: reintentos no duplican.
-- =====================================================================

CREATE TABLE public.asiento (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id        uuid   NOT NULL REFERENCES public.empresa(id),
  sucursal_id       uuid   NOT NULL,
  numero            bigint NOT NULL,                 -- correlativo por empresa, sin huecos
  fecha_contable    date   NOT NULL,                 -- fecha que cuenta para los libros
  descripcion       text   NOT NULL CHECK (length(trim(descripcion)) > 0),
  origen            text   NOT NULL DEFAULT 'manual', -- manual, anulacion, venta, compra...
  id_operacion      uuid   NOT NULL,
  total_centavos    bigint NOT NULL CHECK (total_centavos > 0),
  anula_asiento_id  uuid,                            -- si es contra-asiento: a quién anula
  motivo_anulacion  text,
  creado_por        uuid,                            -- auth.uid(); lo pone el trigger
  registrado_en     timestamptz NOT NULL DEFAULT now(), -- hora del servidor; lo pone el trigger
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  UNIQUE (anula_asiento_id),                         -- no se anula dos veces
  FOREIGN KEY (empresa_id, sucursal_id)      REFERENCES public.sucursal(empresa_id, id),
  FOREIGN KEY (empresa_id, anula_asiento_id) REFERENCES public.asiento(empresa_id, id),
  CHECK ((anula_asiento_id IS NULL) = (motivo_anulacion IS NULL))
);
CREATE INDEX asiento_empresa_fecha ON public.asiento (empresa_id, fecha_contable);

CREATE TABLE public.asiento_linea (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id      uuid     NOT NULL,
  asiento_id      uuid     NOT NULL,
  linea           smallint NOT NULL CHECK (linea > 0),
  cuenta_id       uuid     NOT NULL,
  debe_centavos   bigint   NOT NULL DEFAULT 0 CHECK (debe_centavos  >= 0),
  haber_centavos  bigint   NOT NULL DEFAULT 0 CHECK (haber_centavos >= 0),
  descripcion     text,
  UNIQUE (asiento_id, linea),
  FOREIGN KEY (empresa_id, asiento_id) REFERENCES public.asiento(empresa_id, id),
  FOREIGN KEY (empresa_id, cuenta_id)  REFERENCES public.cuenta(empresa_id, id),
  -- Cada línea va al debe O al haber, nunca a los dos ni en cero.
  CHECK ((debe_centavos > 0 AND haber_centavos = 0) OR (haber_centavos > 0 AND debe_centavos = 0))
);
CREATE INDEX asiento_linea_cuenta ON public.asiento_linea (empresa_id, cuenta_id);
CREATE INDEX asiento_linea_asiento ON public.asiento_linea (asiento_id);

-- ---------------------------------------------------------------------
-- Defensas a nivel de tabla (valen aunque alguien salte las funciones)
-- ---------------------------------------------------------------------

-- Antes de guardar un asiento: mes abierto, hora y usuario del servidor.
CREATE FUNCTION interno.antes_de_asiento() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_periodo_abierto(NEW.empresa_id, NEW.fecha_contable);
  NEW.registrado_en := now();
  NEW.creado_por    := auth.uid();
  RETURN NEW;
END $$;

CREATE TRIGGER antes_de_insertar BEFORE INSERT ON public.asiento
  FOR EACH ROW EXECUTE FUNCTION interno.antes_de_asiento();

-- Antes de guardar una línea: la cuenta debe ser de detalle y estar activa
-- (en una anulación se acepta cuenta desactivada, para poder revertir).
CREATE FUNCTION interno.antes_de_linea() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cuenta public.cuenta;
  v_es_anulacion boolean;
BEGIN
  SELECT * INTO v_cuenta FROM public.cuenta
   WHERE id = NEW.cuenta_id AND empresa_id = NEW.empresa_id;
  SELECT a.anula_asiento_id IS NOT NULL INTO v_es_anulacion
    FROM public.asiento a WHERE a.id = NEW.asiento_id;
  IF v_cuenta.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta no existe en esta empresa.';
  END IF;
  IF NOT v_cuenta.es_detalle THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta % (%) es de agrupación; use una cuenta de detalle.',
      v_cuenta.codigo, v_cuenta.nombre;
  END IF;
  IF NOT v_cuenta.activa AND NOT coalesce(v_es_anulacion, false) THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta % (%) está desactivada.', v_cuenta.codigo, v_cuenta.nombre;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER antes_de_insertar BEFORE INSERT ON public.asiento_linea
  FOR EACH ROW EXECUTE FUNCTION interno.antes_de_linea();

-- Al confirmar la transacción: el asiento debe cuadrar (debe = haber = total)
-- y tener al menos 2 líneas. Es "diferido": se revisa al final de todo.
CREATE FUNCTION interno.revisar_cuadre() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id     uuid := CASE WHEN TG_TABLE_NAME = 'asiento' THEN NEW.id ELSE NEW.asiento_id END;
  v_total  bigint;
  v_debe   numeric;
  v_haber  numeric;
  v_lineas integer;
BEGIN
  SELECT a.total_centavos INTO v_total FROM public.asiento a WHERE a.id = v_id;
  SELECT coalesce(sum(debe_centavos), 0), coalesce(sum(haber_centavos), 0), count(*)
    INTO v_debe, v_haber, v_lineas
    FROM public.asiento_linea WHERE asiento_id = v_id;
  IF v_lineas < 2 OR v_debe <> v_haber OR v_debe <> v_total THEN
    RAISE EXCEPTION 'NO_CUADRA: el asiento % no cuadra (debe %, haber %, total %, líneas %).',
      v_id, v_debe, v_haber, v_total, v_lineas;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER revisar_cuadre AFTER INSERT ON public.asiento
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION interno.revisar_cuadre();
CREATE CONSTRAINT TRIGGER revisar_cuadre AFTER INSERT ON public.asiento_linea
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION interno.revisar_cuadre();

-- Inmutables: ni UPDATE, ni DELETE, ni TRUNCATE. Ni siquiera el dueño de la tabla.
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.asiento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Para corregir, anule el asiento (contra-asiento).');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.asiento_linea
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Para corregir, anule el asiento (contra-asiento).');

CREATE TRIGGER auditar AFTER INSERT ON public.asiento
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();

-- ---------------------------------------------------------------------
-- Cabecera común para registrar y anular.
-- Bloquea el contador de la empresa (ordena a los que guardan a la vez),
-- vuelve a buscar el id_operacion ya con el bloqueo y recién ahí numera.
-- Devuelve (id, numero, duplicado).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.crear_cabecera(
  p_empresa_id uuid, p_sucursal_id uuid, p_fecha date, p_descripcion text,
  p_origen text, p_id_operacion uuid, p_total bigint,
  p_anula_id uuid DEFAULT NULL, p_motivo text DEFAULT NULL,
  OUT o_id uuid, OUT o_numero bigint, OUT o_duplicado boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO interno.contador (empresa_id, clave) VALUES (p_empresa_id, 'asiento')
  ON CONFLICT DO NOTHING;
  PERFORM 1 FROM interno.contador
   WHERE empresa_id = p_empresa_id AND clave = 'asiento' FOR UPDATE;

  SELECT a.id, a.numero INTO o_id, o_numero FROM public.asiento a
   WHERE a.empresa_id = p_empresa_id AND a.id_operacion = p_id_operacion;
  IF FOUND THEN
    o_duplicado := true;
    RETURN;
  END IF;

  o_numero := interno.siguiente_numero(p_empresa_id, 'asiento');
  INSERT INTO public.asiento (empresa_id, sucursal_id, numero, fecha_contable, descripcion,
                              origen, id_operacion, total_centavos, anula_asiento_id, motivo_anulacion)
  VALUES (p_empresa_id,
          coalesce(p_sucursal_id, (SELECT s.id FROM public.sucursal s
                                    WHERE s.empresa_id = p_empresa_id
                                    ORDER BY s.codigo LIMIT 1)),
          o_numero, p_fecha, trim(p_descripcion), p_origen, p_id_operacion, p_total,
          p_anula_id, p_motivo)
  RETURNING id INTO o_id;
  o_duplicado := false;
END $$;

-- ---------------------------------------------------------------------
-- RPC: registrar_asiento
-- p_lineas = [{"cuenta":"1.1.01.01","debe":11500,"haber":0,"descripcion":"..."}, ...]
-- Montos en CENTAVOS enteros (L 115.00 = 11500).
-- Devuelve {"asiento_id","numero","duplicado"}.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_asiento(
  p_empresa_id   uuid,
  p_fecha        date,
  p_descripcion  text,
  p_lineas       jsonb,
  p_id_operacion uuid,
  p_sucursal_id  uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  -- Tope: el mayor entero que JavaScript maneja sin perder precisión.
  c_max   constant numeric := 9007199254740991;
  v_l     jsonb;
  v_i     integer := 0;
  v_debe  numeric;
  v_haber numeric;
  v_cta   public.cuenta;
  v_tot_d numeric := 0;
  v_tot_h numeric := 0;
  v_cab   record;
  v_ids   uuid[] := '{}';
  v_debes bigint[] := '{}';
  v_habers bigint[] := '{}';
  v_descs text[] := '{}';
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'asientos.registrar');

  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;

  -- Reintento: si ya existe, devolver el mismo asiento sin tocar nada.
  SELECT a.id, a.numero INTO v_cab FROM public.asiento a
   WHERE a.empresa_id = p_empresa_id AND a.id_operacion = p_id_operacion;
  IF FOUND THEN
    RETURN jsonb_build_object('asiento_id', v_cab.id, 'numero', v_cab.numero, 'duplicado', true);
  END IF;

  IF length(trim(coalesce(p_descripcion, ''))) = 0 THEN
    RAISE EXCEPTION 'FALTA_DESCRIPCION: escriba una descripción para el asiento.';
  END IF;
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: falta la fecha contable.';
  END IF;
  IF jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lineas) < 2 THEN
    RAISE EXCEPTION 'NO_CUADRA: un asiento necesita al menos 2 líneas.';
  END IF;

  -- Validar cada línea.
  FOR v_l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    v_i := v_i + 1;
    IF jsonb_typeof(v_l) <> 'object' THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % no tiene el formato correcto.', v_i;
    END IF;
    IF coalesce(jsonb_typeof(v_l->'debe'), 'number') NOT IN ('number','null')
       OR coalesce(jsonb_typeof(v_l->'haber'), 'number') NOT IN ('number','null') THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: en la línea % el debe y el haber deben ser números (centavos).', v_i;
    END IF;
    v_debe  := coalesce((v_l->>'debe')::numeric, 0);
    v_haber := coalesce((v_l->>'haber')::numeric, 0);
    IF v_debe <> trunc(v_debe) OR v_haber <> trunc(v_haber) THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: en la línea % los montos deben ser centavos enteros (sin decimales).', v_i;
    END IF;
    IF v_debe < 0 OR v_haber < 0 THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: en la línea % hay montos negativos.', v_i;
    END IF;
    IF v_debe > c_max OR v_haber > c_max THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: en la línea % el monto es demasiado grande.', v_i;
    END IF;
    IF (v_debe > 0) = (v_haber > 0) THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % debe llevar monto en el debe O en el haber (uno solo, mayor que cero).', v_i;
    END IF;

    SELECT * INTO v_cta FROM public.cuenta c
     WHERE c.empresa_id = p_empresa_id AND c.codigo = v_l->>'cuenta';
    IF v_cta.id IS NULL THEN
      RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta "%" (línea %) no existe.', v_l->>'cuenta', v_i;
    END IF;
    IF NOT v_cta.es_detalle THEN
      RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta % (%) es de agrupación; use una cuenta de detalle (línea %).',
        v_cta.codigo, v_cta.nombre, v_i;
    END IF;
    IF NOT v_cta.activa THEN
      RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta % (%) está desactivada (línea %).', v_cta.codigo, v_cta.nombre, v_i;
    END IF;

    v_tot_d := v_tot_d + v_debe;
    v_tot_h := v_tot_h + v_haber;
    v_ids    := v_ids    || v_cta.id;
    v_debes  := v_debes  || v_debe::bigint;
    v_habers := v_habers || v_haber::bigint;
    v_descs  := v_descs  || (v_l->>'descripcion');
  END LOOP;

  IF v_tot_d <> v_tot_h THEN
    RAISE EXCEPTION 'NO_CUADRA: el debe (%) no es igual al haber (%). Diferencia: % centavos.',
      v_tot_d, v_tot_h, v_tot_d - v_tot_h;
  END IF;
  IF v_tot_d > c_max THEN
    RAISE EXCEPTION 'LINEA_INVALIDA: el total del asiento es demasiado grande.';
  END IF;

  SELECT * INTO v_cab FROM interno.crear_cabecera(
    p_empresa_id, p_sucursal_id, p_fecha, p_descripcion, 'manual', p_id_operacion, v_tot_d::bigint);
  IF v_cab.o_duplicado THEN
    RETURN jsonb_build_object('asiento_id', v_cab.o_id, 'numero', v_cab.o_numero, 'duplicado', true);
  END IF;

  INSERT INTO public.asiento_linea (empresa_id, asiento_id, linea, cuenta_id, debe_centavos, haber_centavos, descripcion)
  SELECT p_empresa_id, v_cab.o_id, n, v_ids[n], v_debes[n], v_habers[n], v_descs[n]
  FROM generate_series(1, v_i) AS n;

  RETURN jsonb_build_object('asiento_id', v_cab.o_id, 'numero', v_cab.o_numero, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: anular_asiento
-- Crea un contra-asiento (debe <-> haber) enlazado al original.
-- Fecha por defecto: hoy en Honduras. Exige motivo. No se anula dos veces.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.anular_asiento(
  p_asiento_id   uuid,
  p_motivo       text,
  p_id_operacion uuid DEFAULT NULL,
  p_fecha        date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_orig public.asiento;
  v_cab  record;
  v_id_op uuid := coalesce(p_id_operacion, gen_random_uuid());
BEGIN
  SELECT * INTO v_orig FROM public.asiento WHERE id = p_asiento_id;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el asiento no existe.';
  END IF;

  PERFORM interno.exigir_escritura(v_orig.empresa_id, 'asientos.anular');

  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  IF v_orig.anula_asiento_id IS NOT NULL THEN
    RAISE EXCEPTION 'NO_PERMITIDO: este asiento ya es una anulación; no se puede anular.';
  END IF;

  -- Reintento con el mismo id_operacion: devolver lo ya hecho.
  SELECT a.id, a.numero INTO v_cab FROM public.asiento a
   WHERE a.empresa_id = v_orig.empresa_id AND a.id_operacion = v_id_op;
  IF FOUND THEN
    RETURN jsonb_build_object('asiento_id', v_cab.id, 'numero', v_cab.numero, 'duplicado', true);
  END IF;

  IF EXISTS (SELECT 1 FROM public.asiento WHERE anula_asiento_id = v_orig.id) THEN
    RAISE EXCEPTION 'YA_ANULADO: el asiento #% ya fue anulado.', v_orig.numero;
  END IF;

  BEGIN
    SELECT * INTO v_cab FROM interno.crear_cabecera(
      v_orig.empresa_id, v_orig.sucursal_id, coalesce(p_fecha, public.hoy_local()),
      'ANULACIÓN del asiento #' || v_orig.numero || ': ' || trim(p_motivo),
      'anulacion', v_id_op, v_orig.total_centavos, v_orig.id, trim(p_motivo));
  EXCEPTION WHEN unique_violation THEN
    -- Otra persona lo anuló al mismo tiempo.
    RAISE EXCEPTION 'YA_ANULADO: el asiento #% ya fue anulado.', v_orig.numero;
  END;
  IF v_cab.o_duplicado THEN
    RETURN jsonb_build_object('asiento_id', v_cab.o_id, 'numero', v_cab.o_numero, 'duplicado', true);
  END IF;

  -- Mismas cuentas y montos, con debe y haber invertidos.
  INSERT INTO public.asiento_linea (empresa_id, asiento_id, linea, cuenta_id, debe_centavos, haber_centavos, descripcion)
  SELECT l.empresa_id, v_cab.o_id, l.linea, l.cuenta_id, l.haber_centavos, l.debe_centavos,
         'Reversión: ' || coalesce(l.descripcion, '')
  FROM public.asiento_linea l WHERE l.asiento_id = v_orig.id;

  RETURN jsonb_build_object('asiento_id', v_cab.o_id, 'numero', v_cab.o_numero, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- Vistas de lectura (respetan RLS del usuario: security_invoker)
-- ---------------------------------------------------------------------
CREATE VIEW public.v_asiento WITH (security_invoker = true) AS
  SELECT a.*,
         CASE WHEN a.anula_asiento_id IS NOT NULL THEN 'anulacion'
              WHEN EXISTS (SELECT 1 FROM public.asiento x WHERE x.anula_asiento_id = a.id) THEN 'anulado'
              ELSE 'vigente' END AS estado
  FROM public.asiento a;

-- Saldo por cuenta de detalle. saldo_centavos es positivo según su naturaleza.
CREATE VIEW public.v_saldo_cuenta WITH (security_invoker = true) AS
  SELECT c.empresa_id, c.id AS cuenta_id, c.codigo, c.nombre, c.tipo, c.naturaleza,
         coalesce(sum(l.debe_centavos), 0)::bigint  AS debe_centavos,
         coalesce(sum(l.haber_centavos), 0)::bigint AS haber_centavos,
         (CASE WHEN c.naturaleza = 'deudora'
               THEN coalesce(sum(l.debe_centavos), 0) - coalesce(sum(l.haber_centavos), 0)
               ELSE coalesce(sum(l.haber_centavos), 0) - coalesce(sum(l.debe_centavos), 0)
          END)::bigint AS saldo_centavos
  FROM public.cuenta c
  LEFT JOIN public.asiento_linea l ON l.cuenta_id = c.id AND l.empresa_id = c.empresa_id
  WHERE c.es_detalle
  GROUP BY c.empresa_id, c.id, c.codigo, c.nombre, c.tipo, c.naturaleza;
