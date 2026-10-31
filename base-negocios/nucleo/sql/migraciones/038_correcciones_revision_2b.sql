-- =====================================================================
-- 038_correcciones_revision_2b.sql  -  Núcleo 0.9.1: correcciones de la
-- revisión de la etapa 2 (docs/PENDIENTES.md). Las 001-037 no se tocan.
--
--   GRAVE
--   1. Saldo a favor ajeno: la venta ya NO acepta "saldo_favor_id" desde la
--      app (solo el cambio de producto usa su propio lote) y el lote debe ser
--      de la misma empresa y del mismo cliente (interno.usar_saldo_favor_lote).
--   IMPORTANTES
--   2. interno.ocultar_costos limpia también los costos ANIDADOS (la venta
--      nueva de un cambio de producto ya no muestra costo_centavos al cajero).
--   3. Devoluciones en partes: base, ISV y costo por cantidad ACUMULADA (lo
--      que corresponde a todo lo devuelto menos lo ya devuelto).
--   4. Tope de descuento también POR LÍNEA (al vender, al apartar y al aprobar).
--   5. Comisión solo sobre lo realmente cobrado: se resta lo condonado
--      (DECIDIDO POR EL DUEÑO).
--   6. Efectivo de anulaciones y devoluciones: sale del turno abierto de quien
--      hace la operación, a su nombre, con referencia al turno original
--      (dinero_movimiento.turno_origen_id). Nadie saca dinero del turno de otro
--      cajero (TURNO_AJENO). (DECIDIDO POR EL DUEÑO)
--   MENORES
--   - Vales vencidos: dar_baja_vales_vencidos (permiso cobros.baja_vales, solo
--     el dueño; motivo, bitácora y asiento Dr Saldos a favor / Cr 4.2.01.04).
--   - Devolución pendiente atascada: definir_destino_devolucion y se vuelve a
--     aprobar (o se rechaza; el error lo dice claro).
--   - Descuento de factura en monto: exacto al centavo (ajusta la última línea).
--   - vendedor_id: solo usuarios activos de la empresa con puesto que vende.
--   - Porcentaje de comisión: no retroactivo (desde >= hoy).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('TURNO_AJENO', 'Ese efectivo está en el turno de otro cajero.',
   'Nadie saca dinero del turno de otro cajero. Abra su propio turno de caja (el efectivo sale de su turno, a su nombre) o pida al cajero de ese turno que lo haga.'),
  ('SIN_VALES_VENCIDOS', 'No hay vales vencidos con saldo para dar de baja.',
   'Revise los vales: solo se dan de baja los vales sin cliente, ya vencidos y con saldo.');

-- Permiso nuevo (solo el dueño): dar de baja vales vencidos.
INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('cobros.baja_vales', 'Dar de baja vales vencidos (pasan a otros ingresos, con motivo)', true, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES ('dueno', 'cobros.baja_vales');
SELECT interno.repartir_permisos(ARRAY['cobros.baja_vales'], 'Núcleo 0.9.1: dar de baja vales vencidos');

-- Cuenta de otros ingresos para los vales vencidos.
INSERT INTO interno.plantilla_cuenta (codigo, nombre, tipo, naturaleza, es_detalle) VALUES
  ('4.2.01.04', 'Vales vencidos no reclamados', 'ingreso', 'acreedora', true);
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('vales_vencidos', '4.2.01.04', 'Vales vencidos dados de baja (otros ingresos)', NULL);
DO $$
DECLARE e record;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.9.1: cuenta de vales vencidos', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    PERFORM interno.asegurar_cuenta_uso(e.id, 'vales_vencidos', 'Vales vencidos no reclamados');
  END LOOP;
  PERFORM set_config('app.motivo', '', true);
END $$;

-- Referencia al turno donde había entrado el efectivo que sale por una
-- anulación o devolución (NULL en todo lo demás y en los datos de antes).
ALTER TABLE public.dinero_movimiento
  ADD COLUMN turno_origen_id uuid,
  ADD CONSTRAINT dinero_movimiento_turno_origen_fk FOREIGN KEY (empresa_id, turno_origen_id)
    REFERENCES public.turno_caja(empresa_id, id);

-- ---------------------------------------------------------------------
-- 1) Ayudantes
-- ---------------------------------------------------------------------
-- Quita (pone en null) las claves de costo en TODOS los niveles de un JSON.
CREATE FUNCTION interno.quitar_claves(p_valor jsonb, p_claves text[]) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  k   text;
  v   jsonb;
  out jsonb;
BEGIN
  IF jsonb_typeof(p_valor) = 'object' THEN
    out := '{}';
    FOR k, v IN SELECT * FROM jsonb_each(p_valor) LOOP
      out := out || jsonb_build_object(k, CASE WHEN k = ANY (p_claves) THEN 'null'::jsonb ELSE interno.quitar_claves(v, p_claves) END);
    END LOOP;
    RETURN out;
  ELSIF jsonb_typeof(p_valor) = 'array' THEN
    SELECT coalesce(jsonb_agg(interno.quitar_claves(x, p_claves) ORDER BY n), '[]') INTO out
      FROM jsonb_array_elements(p_valor) WITH ORDINALITY AS t(x, n);
    RETURN out;
  END IF;
  RETURN p_valor;
END $$;

-- (reemplaza la de 017; misma firma) Sin inventario.costos, los costos llegan en
-- null en cualquier nivel de la respuesta (antes solo el primero).
CREATE OR REPLACE FUNCTION interno.ocultar_costos(p_empresa_id uuid, p_respuesta jsonb, p_claves text[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_respuesta IS NULL OR public.puede_leer(p_empresa_id, 'inventario.costos') THEN
    RETURN p_respuesta;
  END IF;
  RETURN interno.quitar_claves(p_respuesta, p_claves) || '{"costos_ocultos": true}'::jsonb;
END $$;

-- De qué cuenta sale el EFECTIVO de una anulación o devolución (decisión del dueño):
--   * banco, POS, transferencias o caja sin punto de emisión (caja fuerte): la misma.
--   * la caja tiene abierto el turno de alguien autorizado (quien hace la operación
--     o quien la pidió): de ese turno.
--   * p_sustituir (anular un cobro o una venta): del turno abierto de quien anula,
--     a su nombre, aunque el dinero hubiera entrado en otro turno ya cerrado.
--   * la caja tiene abierto el turno de OTRO cajero: TURNO_AJENO.
--   * sin turno y turnos obligatorios: SIN_TURNO_ABIERTO; si no son obligatorios, la misma caja.
CREATE FUNCTION interno.cuenta_salida_efectivo(p_empresa_id uuid, p_cuenta_id uuid, p_autorizados uuid[], p_sustituir boolean)
RETURNS public.cuenta_dinero
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d   public.cuenta_dinero;
  t   public.turno_caja;
  tm  public.turno_caja;
BEGIN
  SELECT * INTO d FROM public.cuenta_dinero x WHERE x.id = p_cuenta_id AND x.empresa_id = p_empresa_id;
  IF d.id IS NULL OR d.tipo <> 'efectivo_caja' OR d.caja_id IS NULL THEN
    RETURN d;
  END IF;
  SELECT * INTO t FROM public.turno_caja x WHERE x.cuenta_dinero_id = d.id AND x.estado = 'abierto';
  IF t.id IS NOT NULL AND t.cajero_id = ANY (p_autorizados) THEN
    RETURN d;
  END IF;
  IF p_sustituir THEN
    SELECT * INTO tm FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cajero_id = auth.uid() AND x.estado = 'abierto';
    IF tm.id IS NOT NULL THEN
      SELECT * INTO d FROM public.cuenta_dinero x WHERE x.id = tm.cuenta_dinero_id;
      RETURN d;
    END IF;
  END IF;
  IF t.id IS NOT NULL THEN
    RAISE EXCEPTION 'TURNO_AJENO: el efectivo de "%" está en el turno #% de %; nadie saca dinero del turno de otro cajero. %',
      d.nombre, t.numero, coalesce(public.nombre_usuario(p_empresa_id, t.cajero_id), 'otro cajero'),
      CASE WHEN p_sustituir THEN 'Abra su propio turno de caja y vuelva a intentar (el efectivo sale de su turno, a su nombre).'
           ELSE 'Elija la caja de su propio turno.' END;
  END IF;
  IF coalesce((SELECT e.turnos_obligatorios FROM public.empresa e WHERE e.id = p_empresa_id), true) THEN
    RAISE EXCEPTION 'SIN_TURNO_ABIERTO: la caja "%" no tiene un turno abierto suyo; abra su turno de caja para entregar el efectivo (sale de su turno, a su nombre).',
      d.nombre;
  END IF;
  RETURN d;
END $$;

-- Mayor descuento manual de UNA línea que pasa el tope (NULL si ninguna).
-- Por línea: (descuento del artículo + parte del descuento de factura) / precio
-- ya con promoción, en las mismas unidades en que se escribió el precio. Se
-- tolera 1 centavo de redondeo (un 5 % de factura exacto nunca pide aprobación).
CREATE FUNCTION interno.descuento_linea_sobre_tope(p_lineas jsonb, p_tope numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT max(round(y.m * 100.0 / y.b, 2))
    FROM (SELECT (x->>'bruto_centavos')::bigint - coalesce((x->>'descuento_promocion_precio_centavos')::bigint, 0) AS b,
                 coalesce((x->>'descuento_linea_centavos')::bigint, 0) + coalesce((x->>'descuento_factura_centavos')::bigint, 0) AS m
            FROM jsonb_array_elements(coalesce(p_lineas, '[]'::jsonb)) x) y
   WHERE y.b > 0 AND (y.m - 1) * 100.0 > p_tope * y.b
$$;

-- ---------------------------------------------------------------------
-- 2) Rastro del dinero (reemplaza la de 025; misma firma): anota el turno
--    de origen (app.turno_origen) en las salidas de efectivo.
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
  FOR r IN SELECT l.id, l.debe_centavos, l.haber_centavos, cd.id AS cd_id, cd.tipo AS cd_tipo
             FROM public.asiento_linea l JOIN public.cuenta_dinero cd ON cd.cuenta_id = l.cuenta_id
            WHERE l.asiento_id = p_asiento_id
              AND NOT EXISTS (SELECT 1 FROM public.dinero_movimiento m WHERE m.asiento_linea_id = l.id)
            ORDER BY l.linea LOOP
    INSERT INTO public.dinero_movimiento (empresa_id, cuenta_dinero_id, asiento_id, asiento_linea_id, fecha_contable,
      monto_centavos, operacion, documento_tipo, documento_id, contrapartida, turno_id, referencia, equipo, creado_por,
      turno_origen_id)
    VALUES (v_emp, r.cd_id, p_asiento_id, r.id, v_fecha, r.debe_centavos - r.haber_centavos, p_operacion,
      p_documento_tipo, p_documento_id, interno.contrapartida_linea(p_asiento_id, r.id), interno.turno_de_cuenta(r.cd_id),
      nullif(trim(p_referencia), ''), p_equipo, auth.uid(),
      -- 0.9.1: salida de efectivo de una anulación o devolución: turno donde había entrado el dinero.
      CASE WHEN r.haber_centavos > 0 AND r.cd_tipo = 'efectivo_caja'
           THEN nullif(current_setting('app.turno_origen', true), '')::uuid END);
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

-- ---------------------------------------------------------------------
-- 3) Ventas: cálculo (reemplaza la de 031; misma firma): descuento de factura
--    en monto exacto al centavo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.calcular_venta(p_empresa_id uuid, p_fecha date, p_lineas jsonb, p_desc_factura jsonb)
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
  a_elig   boolean[] := '{}';
  a_we     bigint[] := '{}';
  v_tot_we bigint := 0;
  v_promos jsonb;
  v_fpct   numeric;
  v_fmto   bigint;
  v_tot_w  bigint := 0;
  v_v3     bigint;
  s0 bigint; s1 bigint; s3 bigint; i3 bigint; c3 bigint;
  v_out    jsonb := '[]';
  v_desg   jsonb;
  t_sub bigint := 0; t_dpro bigint := 0; t_sin1 bigint := 0; t_base bigint := 0;
  t_grav bigint := 0; t_exe bigint := 0; t_exo bigint := 0; t_imp bigint := 0; t_tot bigint := 0;
  v_dif    bigint;
  v_c0     bigint;
  v_x      bigint;
  v_r      bigint;
  v_mejor  integer;
  v_mejor_x bigint;
  v_mejor_r bigint;
BEGIN
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad', 'descuento_porcentaje', 'descuento_centavos', 'promocion_id']);
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

    -- Promociones vigentes de su categoría (o de una categoría madre). NUNCA
    -- se suman: con una sola se aplica; con varias, quien vende elige una
    -- ("promocion_id"); si no elige, PROMOCION_A_ELEGIR con la lista.
    v_promos := interno.promociones_de(p_empresa_id, p, p_fecha, q);
    v_pid := NULL; v_dp := NULL;
    IF coalesce(l->'promocion_id', 'null'::jsonb) <> 'null'::jsonb THEN
      v_pid := interno.json_uuid(l->'promocion_id', 'promocion_id');
      SELECT (y->>'descuento_centavos')::bigint INTO v_dp FROM jsonb_array_elements(v_promos) y WHERE (y->>'promocion_id')::uuid = v_pid;
      IF v_dp IS NULL THEN
        RAISE EXCEPTION 'PROMOCION_INVALIDA: la promoción elegida en la línea % no aplica a "%" en la fecha de la venta (no existe, está desactivada, vencida o es de otra categoría).', i, p.nombre;
      END IF;
    ELSIF jsonb_array_length(v_promos) = 1 THEN
      v_pid := (v_promos->0->>'promocion_id')::uuid;
      v_dp := (v_promos->0->>'descuento_centavos')::bigint;
    ELSIF jsonb_array_length(v_promos) > 1 THEN
      RAISE EXCEPTION 'PROMOCION_A_ELEGIR: la línea % ("%") tiene % promociones vigentes y no se suman; elija una con "promocion_id": %',
        i, p.nombre, jsonb_array_length(v_promos),
        (SELECT string_agg(format('"%s" (promocion_id %s, descuento %s)', y->>'nombre', y->>'promocion_id',
                                  interno.lempiras((y->>'descuento_centavos')::bigint)), '; ') FROM jsonb_array_elements(v_promos) y);
    END IF;
    a_promo := a_promo || v_pid;
    a_dpro := a_dpro || coalesce(v_dp, 0);

    -- Descuento del artículo (uno solo: porcentaje o monto).
    v_pct := NULL; v_mto := NULL; v_dl := 0;
    IF coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb
       AND coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % trae descuento en porcentaje y en monto; use solo uno.', i;
    END IF;
    -- Nunca descuento sobre descuento: una línea con promoción no lleva descuento manual.
    IF v_pid IS NOT NULL AND (coalesce(l->'descuento_porcentaje', 'null'::jsonb) <> 'null'::jsonb
                              OR coalesce(l->'descuento_centavos', 'null'::jsonb) <> 'null'::jsonb) THEN
      RAISE EXCEPTION 'DESCUENTO_DOBLE: la línea % ("%") ya tiene una promoción; no admite además un descuento manual (nunca descuento sobre descuento).', i, p.nombre;
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
    -- El descuento de factura solo va a las líneas SIN otro descuento.
    a_elig := a_elig || (v_pid IS NULL AND coalesce(v_pct, 0) = 0 AND coalesce(v_mto, 0) = 0);
    a_we := a_we || CASE WHEN a_elig[i] THEN a_w[i] ELSE 0 END;
    v_tot_we := v_tot_we + a_we[i];
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
      IF v_fpct > 0 AND v_tot_we = 0 THEN
        RAISE EXCEPTION 'DESCUENTO_DOBLE: todas las líneas ya tienen promoción o descuento; el descuento de factura no se suma sobre otro descuento.';
      END IF;
      FOR i IN 1..n LOOP
        a_dfac[i] := CASE WHEN a_elig[i] THEN round(a_v2[i] * v_fpct / 100)::bigint ELSE 0 END;
      END LOOP;
    ELSIF coalesce(p_desc_factura->'monto_centavos', 'null'::jsonb) <> 'null'::jsonb THEN
      v_fmto := interno.json_centavos(p_desc_factura->'monto_centavos', 'descuento_factura.monto_centavos');
      IF v_fmto > 0 AND v_tot_we = 0 THEN
        RAISE EXCEPTION 'DESCUENTO_DOBLE: todas las líneas ya tienen promoción o descuento; el descuento de factura no se suma sobre otro descuento.';
      END IF;
      IF v_fmto > v_tot_we THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el descuento de factura (%) pasa el total de las líneas sin otro descuento (%).', interno.lempiras(v_fmto), interno.lempiras(v_tot_we);
      END IF;
      IF v_fmto > 0 THEN
        -- Reparto por el total con impuesto de cada línea; los centavos que sobran van a las de resto mayor.
        SELECT array_agg(y.parte ORDER BY y.k) INTO a_part
          FROM (SELECT x.k, x.base + CASE WHEN row_number() OVER (ORDER BY x.resto DESC, x.k) <= v_fmto - sum(x.base) OVER ()
                                          THEN 1 ELSE 0 END AS parte
                  FROM (SELECT t.k, floor(v_fmto::numeric * t.w / v_tot_we)::bigint AS base,
                               v_fmto::numeric * t.w - floor(v_fmto::numeric * t.w / v_tot_we) * v_tot_we AS resto
                          FROM unnest(a_we) WITH ORDINALITY AS t(w, k)) x) y;
        FOR i IN 1..n LOOP
          a_dfac[i] := least(a_v2[i], CASE WHEN a_inc[i] THEN a_part[i]
                                           ELSE round(a_part[i] / (1 + a_tasa[i] / 100))::bigint END);
        END LOOP;
        -- 0.9.1: al centavo. En líneas con precio SIN impuesto el reparto (sin ISV) más el ISV
        -- recalculado podía quedar 1 centavo arriba o abajo por línea. Se ajusta la ÚLTIMA línea
        -- que pueda dar el monto exacto (con precio con impuesto o exenta siempre puede); si
        -- ninguna puede (pasa rara vez, solo con líneas sin impuesto incluido), queda lo más cerca.
        v_dif := v_fmto;
        FOR i IN 1..n LOOP
          IF a_elig[i] THEN
            v_dif := v_dif - (a_w[i] - (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_v2[i] - a_dfac[i], a_inc[i], a_tasa[i], 1) x));
          END IF;
        END LOOP;
        IF v_dif <> 0 THEN
          v_mejor := NULL;
          FOR i IN REVERSE n..1 LOOP
            CONTINUE WHEN NOT a_elig[i];
            v_c0 := (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_v2[i] - a_dfac[i], a_inc[i], a_tasa[i], 1) x);
            -- candidatos: del más cercano al reparto original al más lejano
            FOR v_x IN SELECT g FROM generate_series(greatest(0, a_dfac[i] - abs(v_dif) - 3), least(a_v2[i], a_dfac[i] + abs(v_dif) + 3)) g
                        ORDER BY abs(g - a_dfac[i]), g LOOP
              -- lo que faltaría si esta línea llevara v_x de descuento
              v_r := v_dif - (v_c0 - (SELECT x.con_isv_centavos FROM public.precio_con_tasa(a_v2[i] - v_x, a_inc[i], a_tasa[i], 1) x));
              IF v_mejor IS NULL OR abs(v_r) < abs(v_mejor_r) THEN
                v_mejor := i;  v_mejor_x := v_x;  v_mejor_r := v_r;
              END IF;
              EXIT WHEN v_mejor_r = 0;
            END LOOP;
            EXIT WHEN v_mejor_r = 0;
          END LOOP;
          IF v_mejor IS NOT NULL THEN
            a_dfac[v_mejor] := v_mejor_x;
          END IF;
        END IF;
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
-- 4) Ventas: saldo a favor solo del mismo cliente y empresa; vendedor que
--    vende; tope de descuento por línea. (reemplazan las de 034/035)
-- ---------------------------------------------------------------------
-- Usa un lote en particular (bloqueado). Error si no alcanza, venció o es de otro cliente / empresa.
CREATE OR REPLACE FUNCTION interno.usar_saldo_favor_lote(p_lote_id uuid, p_monto bigint, p_documento_tipo text, p_documento_id uuid,
                                              p_fecha date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s      public.saldo_favor;
  v_disp bigint;
BEGIN
  SELECT * INTO s FROM public.saldo_favor WHERE id = p_lote_id FOR UPDATE;
  IF s.id IS NULL OR s.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'VALE_INVALIDO: el saldo a favor no existe o está anulado.';
  END IF;
  -- 0.9.1: el lote debe ser de la misma empresa y del mismo cliente que la venta que lo usa.
  IF p_documento_tipo = 'venta' AND NOT EXISTS (SELECT 1 FROM public.venta v WHERE v.id = p_documento_id
                                                   AND v.empresa_id = s.empresa_id AND v.cliente_id IS NOT DISTINCT FROM s.cliente_id) THEN
    RAISE EXCEPTION 'VALE_INVALIDO: ese saldo a favor no es de este cliente en esta empresa.';
  END IF;
  IF s.vence_el < public.hoy_local(s.empresa_id) THEN
    RAISE EXCEPTION 'VALE_VENCIDO: el vale % venció el %.', s.codigo, to_char(s.vence_el, 'DD/MM/YYYY');
  END IF;
  v_disp := interno.saldo_favor_lote(s.id);
  IF v_disp < p_monto THEN
    RAISE EXCEPTION 'SALDO_FAVOR_INSUFICIENTE: el saldo a favor #% tiene % y se quieren usar %.', s.numero,
      interno.lempiras(v_disp), interno.lempiras(p_monto);
  END IF;
  INSERT INTO public.saldo_favor_uso (empresa_id, saldo_favor_id, monto_centavos, documento_tipo, documento_id, fecha_contable, creado_por)
  VALUES (s.empresa_id, s.id, p_monto, p_documento_tipo, p_documento_id, p_fecha, auth.uid());
  RETURN jsonb_build_array(jsonb_build_object('saldo_favor_id', s.id, 'codigo', s.codigo, 'monto_centavos', p_monto));
END $$;

-- Registrar una venta (reemplaza la de 034; misma firma).
CREATE OR REPLACE FUNCTION interno.registrar_venta_base(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid,
                                             p_cotizacion_id uuid DEFAULT NULL, p_calculo jsonb DEFAULT NULL,
                                             p_apartado_id uuid DEFAULT NULL)
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
  v_din    bigint := 0;
  v_ncred  integer := 0;
  v_nant   integer := 0;
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
  v_vale   text;
  v_lote   uuid;
  v_sf     bigint;
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
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;

  v_caja := interno.caja_de_venta(p_empresa_id, p_datos->'caja_id');
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

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

  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) <> 'null'::jsonb THEN
    SELECT * INTO v_cli FROM public.tercero t
     WHERE t.id = interno.json_uuid(p_datos->'cliente_id', 'cliente_id') AND t.empresa_id = p_empresa_id;
    IF v_cli.id IS NULL OR NOT v_cli.es_cliente OR NOT v_cli.activo THEN
      RAISE EXCEPTION 'TERCERO_INVALIDO: el cliente no existe, no está marcado como cliente o está desactivado.';
    END IF;
  END IF;
  v_vend := coalesce(interno.json_uuid(p_datos->'vendedor_id', 'vendedor_id'), auth.uid());
  -- 0.9.1: el vendedor (a quien se le paga la comisión) es un usuario activo de ESTA empresa
  -- cuyo puesto vende (permiso ventas.vender). Al completar un apartado se respeta quien lo hizo.
  IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = v_vend
                   AND ue.activo AND ue.rol NOT IN ('proveedor', 'contador')
                   AND (p_apartado_id IS NOT NULL OR v_vend = auth.uid()
                        OR EXISTS (SELECT 1 FROM public.rol_permiso rp WHERE rp.empresa_id = p_empresa_id AND rp.rol = ue.rol
                                     AND rp.permiso = 'ventas.vender'))) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el vendedor no es un usuario activo de la empresa con un puesto que vende (permiso "ventas.vender").';
  END IF;

  v_calc := coalesce(p_calculo, interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura'));
  v_total := (v_calc->>'total_centavos')::bigint;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el total de la venta debe ser mayor que cero.';
  END IF;
  IF coalesce((v_calc->>'tiene_bienes')::boolean, true) AND NOT public.modulo_esta_activo(p_empresa_id, 'inventario') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "inventario" no está activo: esta venta solo puede llevar servicios (quite los productos que son bienes).';
  END IF;
  IF coalesce(p_datos->'bodega_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_bod := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  ELSIF coalesce((v_calc->>'tiene_bienes')::boolean, true) THEN
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa; cree una o indique "bodega_id".';
    END IF;
  END IF;

  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique cómo paga el cliente ("pagos": efectivo, tarjeta, transferencia, crédito o saldo a favor).';
  END IF;
  IF jsonb_array_length(p_datos->'pagos') > 10 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: máximo 10 formas de pago por venta.';
  END IF;
  FOR pj IN SELECT * FROM jsonb_array_elements(p_datos->'pagos') LOOP
    k := k + 1;
    IF jsonb_typeof(pj) <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: cada pago es {"forma", "monto_centavos"}.';
    END IF;
    PERFORM interno.exigir_claves(pj, ARRAY['forma', 'monto_centavos', 'cuenta_dinero_id', 'referencia', 'recibido_centavos',
                                            'vale', 'saldo_favor_id']);
    v_forma := interno.json_texto(pj->'forma', 'forma', 20);
    IF coalesce(v_forma, '') NOT IN ('efectivo', 'tarjeta', 'transferencia', 'credito', 'saldo_favor', 'anticipo') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma de pago es efectivo, tarjeta, transferencia, credito o saldo_favor.';
    END IF;
    IF v_forma = 'anticipo' AND p_apartado_id IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la forma "anticipo" solo se usa al completar un apartado (completar_apartado).';
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
    IF v_forma IN ('efectivo', 'credito', 'saldo_favor', 'anticipo') AND coalesce(pj->'cuenta_dinero_id', 'null'::jsonb) <> 'null'::jsonb THEN
      RAISE EXCEPTION 'DATO_INVALIDO: en % no se indica cuenta (el efectivo entra a la caja de la venta).', v_forma;
    END IF;
    IF v_forma <> 'saldo_favor' AND (pj ? 'vale' OR pj ? 'saldo_favor_id') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "vale" y "saldo_favor_id" solo van con la forma saldo_favor.';
    END IF;
    v_vale := NULL; v_lote := NULL;
    IF v_forma = 'saldo_favor' THEN
      v_vale := upper(interno.json_texto(pj->'vale', 'vale', 20));
      v_lote := interno.json_uuid(pj->'saldo_favor_id', 'saldo_favor_id');
      IF v_vale IS NOT NULL AND v_lote IS NOT NULL THEN
        RAISE EXCEPTION 'DATO_INVALIDO: indique "vale" o "saldo_favor_id", no los dos.';
      END IF;
      -- 0.9.1: "saldo_favor_id" NO se acepta desde la app: solo el cambio de producto (035) usa
      -- su propio lote. Y aun así el lote debe ser de esta empresa y de este mismo cliente.
      IF v_lote IS NOT NULL AND v_lote::text IS DISTINCT FROM nullif(current_setting('app.lote_cambio', true), '') THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "saldo_favor_id" no se acepta en una venta; pague con el saldo a favor del cliente (sin indicar lote) o con el código del vale ("vale").';
      END IF;
      IF v_lote IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.saldo_favor s WHERE s.id = v_lote AND s.empresa_id = p_empresa_id
                                              AND s.cliente_id IS NOT DISTINCT FROM v_cli.id) THEN
        RAISE EXCEPTION 'VALE_INVALIDO: ese saldo a favor no es de este cliente en esta empresa.';
      END IF;
      IF v_vale IS NULL AND v_lote IS NULL AND v_cli.id IS NULL THEN
        RAISE EXCEPTION 'CLIENTE_REQUERIDO: para pagar con saldo a favor indique el cliente o el código del vale ("vale").';
      END IF;
      -- Revisión previa (se consume al emitir, con el lote bloqueado).
      v_sf := CASE WHEN v_lote IS NOT NULL THEN interno.saldo_favor_lote(v_lote)
                   WHEN v_vale IS NOT NULL THEN (SELECT interno.saldo_favor_lote(s.id) FROM public.saldo_favor s
                                                  WHERE s.empresa_id = p_empresa_id AND s.codigo = v_vale)
                   ELSE interno.saldo_favor_cliente(p_empresa_id, v_cli.id) END;
      IF v_vale IS NOT NULL AND v_sf IS NULL THEN
        RAISE EXCEPTION 'VALE_INVALIDO: el vale % no existe.', v_vale;
      END IF;
      IF coalesce(v_sf, 0) < v_monto THEN
        RAISE EXCEPTION 'SALDO_FAVOR_INSUFICIENTE: el saldo a favor disponible es % y se quieren usar %.', interno.lempiras(coalesce(v_sf, 0)), interno.lempiras(v_monto);
      END IF;
    END IF;
    IF v_forma = 'credito' THEN
      v_ncred := v_ncred + 1;
      v_cred := v_cred + v_monto;
    ELSIF v_forma = 'anticipo' THEN
      v_nant := v_nant + 1;
      IF v_monto <> interno.anticipos_apartado(p_apartado_id) THEN
        RAISE EXCEPTION 'PAGO_NO_CUADRA: el anticipo (%) no es lo abonado al apartado (%).', interno.lempiras(v_monto),
          interno.lempiras(interno.anticipos_apartado(p_apartado_id));
      END IF;
    ELSIF v_forma IN ('efectivo', 'tarjeta', 'transferencia') THEN
      v_din := v_din + v_monto;
    END IF;
    v_suma := v_suma + v_monto;
    v_norm := v_norm || jsonb_build_object('linea', k, 'forma', v_forma, 'monto', v_monto, 'recibido', v_rec,
      'cuenta', interno.json_uuid(pj->'cuenta_dinero_id', 'cuenta_dinero_id'), 'referencia', interno.json_texto(pj->'referencia', 'referencia', 100),
      'vale', v_vale, 'saldo_favor_id', v_lote);
  END LOOP;
  IF v_ncred > 1 OR v_nant > 1 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el crédito (o el anticipo) va en una sola forma de pago.';
  END IF;
  IF v_suma <> v_total THEN
    RAISE EXCEPTION 'PAGO_NO_CUADRA: las formas de pago suman % y el total de la venta es % (diferencia %).',
      interno.lempiras(v_suma), interno.lempiras(v_total), interno.lempiras(v_suma - v_total);
  END IF;
  IF v_cred > 0 AND v_cli.id IS NULL THEN
    RAISE EXCEPTION 'CLIENTE_REQUERIDO: una venta al crédito necesita cliente (no puede ser Consumidor final).';
  END IF;
  IF v_suma > v_cred AND NOT interno.puede_cobrar(p_empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "ventas.cobrar"; haga una cotización y el cajero la cobra (o el dueño permite que el vendedor cobre).';
  END IF;
  IF v_din > 0 AND NOT public.modulo_esta_activo(p_empresa_id, 'dinero') THEN
    RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo para esta empresa (el cobro entra a una cuenta de dinero).';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'venta');
  SELECT * INTO v FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF v.id IS NOT NULL THEN
    RETURN interno.venta_respuesta(v, true);
  END IF;

  -- ¿Necesita aprobación? (el dueño no tiene topes; el descuento de un apartado ya se revisó al crearlo)
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    IF p_apartado_id IS NULL AND (v_calc->>'descuento_manual_porcentaje')::numeric > v_td.sin_aprobacion THEN
      v_req := v_req || 'descuento'::text;
      v_desc := 'descuento de ' || (v_calc->>'descuento_manual_porcentaje') || ' % (su tope: ' || v_td.sin_aprobacion || ' %)';
    -- 0.9.1: el tope también vale POR LÍNEA (100 % en una línea chica dentro de una factura grande).
    ELSIF p_apartado_id IS NULL AND interno.descuento_linea_sobre_tope(v_calc->'lineas', v_td.sin_aprobacion) IS NOT NULL THEN
      v_req := v_req || 'descuento'::text;
      v_desc := 'descuento de ' || interno.descuento_linea_sobre_tope(v_calc->'lineas', v_td.sin_aprobacion)
                || ' % en una línea (su tope: ' || v_td.sin_aprobacion || ' %)';
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
    estado, requiere_aprobacion, aprobacion_id, nota, equipo, id_operacion, creado_por, apartado_id)
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
    interno.json_texto(p_datos->'nota', 'nota', 500), interno.equipo(p_datos), p_id_operacion, auth.uid(), p_apartado_id)
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

  FOR pj IN SELECT * FROM jsonb_array_elements(v_norm) LOOP
    d := NULL;
    IF pj->>'forma' = 'efectivo' THEN
      d := interno.cuenta_efectivo_cobro(p_empresa_id, v_caja.id);
    ELSIF pj->>'forma' IN ('tarjeta', 'transferencia') THEN
      d := interno.cuenta_cobro_venta(p_empresa_id, pj->>'forma', (pj->>'cuenta')::uuid);
    END IF;
    INSERT INTO public.venta_pago (empresa_id, venta_id, linea, forma, monto_centavos, cuenta_dinero_id, turno_id, referencia,
                                   recibido_centavos, vuelto_centavos, estado_transferencia, vale, saldo_favor_id)
    VALUES (p_empresa_id, v.id, (pj->>'linea')::smallint, pj->>'forma', (pj->>'monto')::bigint, d.id,
            CASE WHEN pj->>'forma' = 'efectivo' THEN interno.turno_de_cuenta(d.id) END, pj->>'referencia',
            (pj->>'recibido')::bigint, (pj->>'recibido')::bigint - (pj->>'monto')::bigint,
            CASE WHEN pj->>'forma' = 'transferencia' THEN 'por_confirmar' END, pj->>'vale', (pj->>'saldo_favor_id')::uuid);
  END LOOP;

  IF v.estado = 'por_emitir' THEN
    v := interno.emitir_venta(v.id, v_fecha, p_id_operacion);
  END IF;
  RETURN interno.venta_respuesta(v, false);
END $$;

-- Venta nueva de un cambio de producto (reemplaza la de 035; misma firma).
CREATE OR REPLACE FUNCTION interno.venta_de_cambio(d public.devolucion, p_id_operacion uuid) RETURNS jsonb
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
  -- 0.9.1: solo aquí se acepta "saldo_favor_id" (el lote de esta devolución).
  PERFORM set_config('app.lote_cambio', coalesce(d.saldo_favor_id::text, ''), true);
  r := interno.registrar_venta_base(d.empresa_id,
         jsonb_strip_nulls(jsonb_build_object('cliente_id', v.cliente_id, 'lineas', d.cambio->'lineas',
           'descuento_factura', d.cambio->'descuento_factura', 'caja_id', to_jsonb(d.caja_id), 'bodega_id', d.cambio->'bodega_id',
           'tipo_documento', d.cambio->'tipo_documento', 'fecha', to_char(d.fecha_contable, 'YYYY-MM-DD'),
           'nota', 'Cambio de producto (nota de crédito ' || d.numero_documento || ')', 'equipo', d.equipo, 'pagos', v_pag)),
         md5(p_id_operacion::text || ':cambio')::uuid);
  PERFORM set_config('app.lote_cambio', '', true);
  IF r->>'estado' <> 'emitida' THEN
    RAISE EXCEPTION 'APROBACION_REQUERIDA: la venta del cambio necesita aprobación (%); haga el cambio dentro de su tope o que lo haga quien aprueba.',
      r->'requiere_aprobacion';
  END IF;
  UPDATE public.devolucion SET venta_cambio_id = (r->>'venta_id')::uuid WHERE id = d.id;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 5) Efectivo de anulaciones: del turno de quien anula (reemplazan las de 033/034)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.anular_cobro(p_cobro_id uuid, p_motivo text, p_id_operacion uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c       public.cobro;
  pg      public.cobro_pago;
  v_fecha date;
  v_lin   jsonb := '[]';
  v_asto  uuid;
  v_cta   uuid;
  v_vtas  uuid[];
  v       uuid;
  v_torig uuid;
BEGIN
  SELECT * INTO c FROM public.cobro WHERE id = p_cobro_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el cobro no existe.';
  END IF;
  PERFORM interno.exigir_escritura(c.empresa_id, 'cobros.anular', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(c.empresa_id, p_id_operacion, 'anulacion_cobro');
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cobro_respuesta(c, true) || jsonb_build_object('asiento_anulacion_id', c.asiento_anulacion_id);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(c.empresa_id), c.fecha_contable));
  PERFORM interno.exigir_fecha_contable(c.empresa_id, v_fecha);
  IF v_fecha < c.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al cobro (%).', to_char(c.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.reservar_operacion(c.empresa_id, p_id_operacion, 'anulacion_cobro');
  SELECT * INTO c FROM public.cobro WHERE id = p_cobro_id FOR UPDATE;
  IF c.anulacion_id_operacion = p_id_operacion THEN
    RETURN interno.cobro_respuesta(c, true) || jsonb_build_object('asiento_anulacion_id', c.asiento_anulacion_id);
  END IF;
  IF c.anulada_en IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el cobro #% ya fue anulado.', c.numero;
  END IF;
  PERFORM interno.validar_anulacion_cobro(c);
  PERFORM interno.exigir_periodo_abierto(c.empresa_id, v_fecha);

  -- El excedente que quedó a favor del cliente se anula (si nadie lo usó).
  IF c.saldo_favor_id IS NOT NULL THEN
    PERFORM interno.anular_saldo_favor(c.saldo_favor_id, 'Anulación del cobro #' || c.numero || ': ' || trim(p_motivo));
  END IF;
  FOR pg IN SELECT * FROM public.cobro_pago x WHERE x.cobro_id = c.id ORDER BY x.linea LOOP
    IF pg.forma = 'saldo_favor' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos, 'descripcion', 'Vuelve el saldo a favor usado');
    ELSE
      v_cta := CASE WHEN pg.estado_transferencia = 'confirmada' THEN pg.banco_id ELSE pg.cuenta_dinero_id END;
      -- 0.9.1: el efectivo sale del turno abierto de quien anula (nunca del turno de otro cajero).
      IF pg.forma = 'efectivo' THEN
        v_cta := (interno.cuenta_salida_efectivo(c.empresa_id, v_cta, ARRAY[auth.uid()], true)).id;
        v_torig := coalesce(v_torig, pg.turno_id);
      END IF;
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(v_cta), 'haber', pg.monto_centavos,
                                           'descripcion', 'Devolución del cobro (' || pg.forma || ')');
    END IF;
  END LOOP;
  v_lin := v_lin || jsonb_build_object('uso', CASE c.tipo WHEN 'apartado' THEN 'anticipo_clientes' ELSE 'cxc' END,
                                       'debe', c.aplicado_centavos, 'descripcion', 'Vuelve el saldo por cobrar')
                 || jsonb_build_object('uso', 'saldo_favor', 'debe', c.excedente_centavos, 'descripcion', 'Se anula el saldo a favor del excedente');
  v_asto := interno.asiento_sistema(c.empresa_id, interno.sucursal_activa(c.sucursal_id), v_fecha,
    'ANULACIÓN cobro #' || c.numero || ': ' || trim(p_motivo), 'anulacion_cobro', p_id_operacion, v_lin, c.asiento_id, trim(p_motivo));

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  PERFORM interno.devolver_usos_saldo_favor(c.id, 'Anulación del cobro #' || c.numero);
  SELECT array_agg(DISTINCT a.venta_id) INTO v_vtas FROM public.cxc_aplicacion a
   WHERE a.origen = 'cobro' AND a.origen_id = c.id AND a.anulada_en IS NULL AND a.venta_id IS NOT NULL;
  UPDATE public.cxc_aplicacion SET anulada_en = now() WHERE origen = 'cobro' AND origen_id = c.id AND anulada_en IS NULL;
  UPDATE public.cobro SET anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo), fecha_anulacion = v_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion
   WHERE id = c.id
  RETURNING * INTO c;
  PERFORM set_config('app.motivo', '', true);
  PERFORM set_config('app.turno_origen', coalesce(v_torig::text, ''), true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_cobro', 'cobro', c.id, trim(p_motivo), NULL);
  PERFORM set_config('app.turno_origen', '', true);
  FOREACH v IN ARRAY coalesce(v_vtas, '{}') LOOP
    PERFORM interno.recalcular_comision(v, p_id_operacion, v_fecha);
  END LOOP;
  RETURN interno.cobro_respuesta(c, false) || jsonb_build_object('asiento_anulacion_id', v_asto);
END $$;

CREATE OR REPLACE FUNCTION interno.anular_venta_base(p_venta_id uuid, p_fecha date, p_motivo text, p_id_operacion uuid,
                                                     p_solicitud_id uuid) RETURNS public.venta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v      public.venta;
  ln     public.venta_linea;
  pg     public.venta_pago;
  v_lin  jsonb := '[]';
  v_asto uuid;
  v_cta  uuid;
  v_ant  bigint := 0;
  v_torig uuid;
  v_aut  uuid[];
BEGIN
  SELECT * INTO v FROM public.venta WHERE id = p_venta_id FOR UPDATE;
  IF interno.devoluciones_vigentes_venta(v.id) > 0 THEN
    RAISE EXCEPTION 'VENTA_CON_DEVOLUCIONES: la venta % tiene devoluciones (notas de crédito); ya no se anula completa.', v.numero_documento;
  END IF;
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
    ELSIF pg.forma = 'saldo_favor' THEN
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos, 'descripcion', 'Vuelve el saldo a favor usado');
    ELSIF pg.forma = 'anticipo' THEN
      v_ant := v_ant + pg.monto_centavos;
      v_lin := v_lin || jsonb_build_object('uso', 'saldo_favor', 'haber', pg.monto_centavos,
                                           'descripcion', 'El anticipo del apartado queda a favor del cliente');
    ELSE
      v_cta := CASE WHEN pg.estado_transferencia = 'confirmada' THEN pg.banco_id ELSE pg.cuenta_dinero_id END;
      -- 0.9.1: el efectivo sale del turno de quien anula (o de quien pidió la anulación, si su
      -- turno donde entró sigue abierto); nunca del turno de otro cajero.
      IF pg.forma = 'efectivo' THEN
        v_aut := ARRAY[auth.uid(), (SELECT s.solicitado_por FROM public.venta_anulacion s WHERE s.id = p_solicitud_id)];
        v_cta := (interno.cuenta_salida_efectivo(v.empresa_id, v_cta, v_aut, true)).id;
        v_torig := coalesce(v_torig, pg.turno_id);
      END IF;
      v_lin := v_lin || jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(v_cta),
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
  PERFORM interno.devolver_usos_saldo_favor(v.id, 'Anulación de la venta ' || v.numero_documento);
  IF v_ant > 0 THEN
    PERFORM interno.crear_saldo_favor(v.empresa_id, v.cliente_id, 'anulacion_venta', 'venta', v.id, v_ant, p_fecha);
  END IF;
  UPDATE public.venta
     SET estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = p_motivo, fecha_anulacion = p_fecha,
         asiento_anulacion_id = v_asto, anulacion_id_operacion = p_id_operacion, anulacion_solicitud_id = p_solicitud_id
   WHERE id = v.id
  RETURNING * INTO v;
  PERFORM set_config('app.motivo', '', true);
  PERFORM set_config('app.turno_origen', coalesce(v_torig::text, ''), true);
  PERFORM interno.rastrear_dinero(v_asto, 'anulacion_venta', 'venta', v.id, p_motivo, NULL);
  PERFORM set_config('app.turno_origen', '', true);
  PERFORM interno.recalcular_comision(v.id, p_id_operacion, p_fecha);
  RETURN v;
END $$;

-- ---------------------------------------------------------------------
-- 6) Devoluciones (reemplazan las de 035): montos acumulados, efectivo del
--    turno propio, destino de una pendiente.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.proteger_devolucion() RETURNS trigger
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
  -- 0.9.1: mientras espera aprobación solo se puede cambiar a dónde va lo ya pagado (definir_destino_devolucion).
  IF OLD.estado = 'pendiente_aprobacion' AND NEW.estado = 'pendiente_aprobacion'
     AND (to_jsonb(NEW) - ARRAY['destino', 'cuenta_dinero_id']) = (to_jsonb(OLD) - ARRAY['destino', 'cuenta_dinero_id']) THEN
    RETURN NEW;
  END IF;
  IF OLD.estado = 'pendiente_aprobacion' AND NEW.estado = 'rechazada' AND (to_jsonb(NEW) - 'estado') = (to_jsonb(OLD) - 'estado') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'PROHIBIDO: una devolución (nota de crédito) no se edita; se aplica o se rechaza una sola vez.';
END $$;

CREATE OR REPLACE FUNCTION interno.aplicar_devolucion(p_devolucion_id uuid, p_fecha date, p_id_operacion uuid) RETURNS public.devolucion
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
  v_torig uuid;
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
      RAISE EXCEPTION 'DATO_INVALIDO: la venta ya está pagada en parte (el cliente pagó después de pedir la devolución #%): indique a dónde va % con definir_destino_devolucion ("destino": dinero o saldo_favor) y vuelva a aprobar, o rechace la devolución.',
        d.numero, interno.lempiras(v_resto);
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
    -- 0.9.1: de una caja sale solo del turno abierto de quien aplica o de quien pidió la devolución
    -- (nunca del turno de otro cajero; si se cerró, cambie la cuenta con definir_destino_devolucion).
    PERFORM interno.cuenta_salida_efectivo(d.empresa_id, d.cuenta_dinero_id, ARRAY[auth.uid(), d.creado_por], false);
    SELECT g.turno_id INTO v_torig FROM public.venta_pago g WHERE g.venta_id = v.id AND g.forma = 'efectivo' ORDER BY g.linea LIMIT 1;
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
  PERFORM set_config('app.turno_origen', coalesce(v_torig::text, ''), true);
  PERFORM interno.rastrear_dinero(v_asto, 'devolucion', 'devolucion', d.id, v_num, d.equipo);
  PERFORM set_config('app.turno_origen', '', true);
  PERFORM interno.recalcular_comision(v.id, p_id_operacion, p_fecha);
  RETURN d;
END $$;

CREATE OR REPLACE FUNCTION public.registrar_devolucion(p_venta_id uuid, p_datos jsonb, p_id_operacion uuid)
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
    -- 0.9.1: de una caja solo sale efectivo del turno propio (nunca del de otro cajero).
    PERFORM interno.cuenta_salida_efectivo(v.empresa_id, v_cta, ARRAY[auth.uid()], false);
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
    -- 0.9.1: montos por cantidad ACUMULADA: lo que corresponde a todo lo devuelto
    -- (q0 + q) menos lo ya devuelto. Así las devoluciones en partes suman igual
    -- que una sola (sin perder ni ganar centavos de ISV) y la última toma lo que falte.
    DECLARE
      t_acum bigint := round(vl.total_centavos * (q0 + q) / vl.cantidad)::bigint;     -- total (con impuesto) acumulado
      b_acum bigint := round(vl.base_centavos * (q0 + q) / vl.cantidad)::bigint;      -- base acumulada
      v_tot  bigint;
    BEGIN
      v_tot := t_acum - (b0 + i0);                        -- total de esta devolución
      v_base := least(greatest(b_acum - b0, 0), greatest(v_tot, 0));
      v_imp := greatest(v_tot, 0) - v_base;
      v_cost := greatest(round(coalesce(vl.costo_centavos, 0) * (q0 + q) / vl.cantidad)::bigint - c0, 0);
      v_cest := greatest(round(coalesce(vl.costo_estimado_centavos, 0) * (q0 + q) / vl.cantidad)::bigint - e0, 0);
    END;
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

-- ---------------------------------------------------------------------
-- 7) Apartados (reemplazan los de 034) y resolver_aprobacion (reemplaza la de 035)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_apartado(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.apartado;
  e       public.empresa;
  v_cli   public.tercero;
  v_caja  public.caja;
  v_bod   public.bodega;
  v_fecha date;
  v_vence date;
  v_calc  jsonb;
  v_rol   text := public.mi_rol(p_empresa_id);
  v_td    record;
  l       jsonb;
  v_disp  numeric;
  v_cod   text;
  r       jsonb;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'apartados.registrar', 'apartados');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'apartado');
  SELECT * INTO a FROM public.apartado x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF a.id IS NOT NULL THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  PERFORM interno.exigir_claves(p_datos, ARRAY['cliente_id', 'lineas', 'descuento_factura', 'pagos', 'caja_id', 'bodega_id',
                                               'fecha', 'vence_el', 'referencia', 'nota', 'equipo']);
  IF coalesce(p_datos->'cliente_id', 'null'::jsonb) = 'null'::jsonb THEN
    RAISE EXCEPTION 'CLIENTE_REQUERIDO: un apartado siempre lleva cliente.';
  END IF;
  v_cli := interno.cliente_de(p_empresa_id, p_datos->'cliente_id', true);
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  v_caja := interno.caja_de_venta(p_empresa_id, p_datos->'caja_id');
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);
  v_vence := coalesce(interno.json_fecha(p_datos->'vence_el', 'vence_el'), v_fecha + e.apartado_dias_vigencia);
  IF v_vence < v_fecha OR v_vence > v_fecha + 365 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el vencimiento del apartado va desde su fecha hasta un año después.';
  END IF;
  IF coalesce(p_datos->'bodega_id', 'null'::jsonb) <> 'null'::jsonb THEN
    v_bod := interno.bodega_activa(p_empresa_id, interno.json_uuid(p_datos->'bodega_id', 'bodega_id'));
  ELSE
    SELECT b.* INTO v_bod FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.sucursal_id = v_caja.sucursal_id AND b.activa
     ORDER BY b.codigo LIMIT 1;
    IF v_bod.id IS NULL THEN
      RAISE EXCEPTION 'BODEGA_INVALIDA: la sucursal de la caja no tiene bodega activa; indique "bodega_id".';
    END IF;
  END IF;
  v_calc := interno.calcular_venta(p_empresa_id, v_fecha, p_datos->'lineas', p_datos->'descuento_factura');
  IF NOT coalesce((v_calc->>'tiene_bienes')::boolean, false) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: un apartado reserva mercadería; lleva al menos un producto (bien).';
  END IF;
  IF v_rol <> 'dueno' THEN
    SELECT * INTO v_td FROM interno.tope_descuento(p_empresa_id, v_rol);
    IF (v_calc->>'descuento_manual_porcentaje')::numeric > v_td.sin_aprobacion THEN
      RAISE EXCEPTION 'APROBACION_REQUERIDA: el descuento del apartado (% %%) pasa su tope (% %%); que lo haga quien pueda darlo.',
        v_calc->>'descuento_manual_porcentaje', v_td.sin_aprobacion;
    END IF;
    -- 0.9.1: también por línea.
    IF interno.descuento_linea_sobre_tope(v_calc->'lineas', v_td.sin_aprobacion) IS NOT NULL THEN
      RAISE EXCEPTION 'APROBACION_REQUERIDA: una línea del apartado lleva % %% de descuento y su tope es % %%; que lo haga quien pueda darlo.',
        interno.descuento_linea_sobre_tope(v_calc->'lineas', v_td.sin_aprobacion), v_td.sin_aprobacion;
    END IF;
  END IF;
  IF jsonb_typeof(p_datos->'pagos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos->'pagos') = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el apartado necesita un anticipo ("pagos").';
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'apartado');
  SELECT * INTO a FROM public.apartado x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF a.id IS NOT NULL THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  -- Disponible = existencia - lo ya apartado (con el candado).
  FOR l IN SELECT * FROM jsonb_array_elements(v_calc->'lineas') LOOP
    CONTINUE WHEN (l->>'es_servicio')::boolean;
    PERFORM interno.bloquear_saldo(p_empresa_id, v_bod.id, (l->>'producto_id')::uuid);
    v_disp := coalesce((SELECT s.cantidad FROM public.inventario_saldo s WHERE s.bodega_id = v_bod.id AND s.producto_id = (l->>'producto_id')::uuid), 0)
              - interno.reservado(v_bod.id, (l->>'producto_id')::uuid)
              - coalesce((SELECT sum((y->>'cantidad')::numeric) FROM jsonb_array_elements(v_calc->'lineas') y
                           WHERE y->>'producto_id' = l->>'producto_id' AND (y->>'linea')::int < (l->>'linea')::int), 0);
    IF v_disp < (l->>'cantidad')::numeric THEN
      SELECT p.codigo INTO v_cod FROM public.producto p WHERE p.id = (l->>'producto_id')::uuid;
      RAISE EXCEPTION 'EXISTENCIA_INSUFICIENTE: del producto % hay % disponibles para apartar y se piden %.', v_cod, greatest(v_disp, 0), l->>'cantidad';
    END IF;
  END LOOP;

  a.id := gen_random_uuid();
  INSERT INTO public.apartado (id, empresa_id, numero, cliente_id, vendedor_id, caja_id, sucursal_id, bodega_id, fecha, vence_el,
    entrada, calculo, subtotal_centavos, descuento_centavos, impuesto_centavos, total_centavos, nota, equipo, id_operacion, creado_por)
  VALUES (a.id, p_empresa_id, interno.siguiente_numero(p_empresa_id, 'apartado'), v_cli.id, auth.uid(), v_caja.id, v_caja.sucursal_id,
    v_bod.id, v_fecha, v_vence, jsonb_build_object('lineas', p_datos->'lineas', 'descuento_factura', p_datos->'descuento_factura'),
    v_calc, (v_calc->>'subtotal_centavos')::bigint, (v_calc->>'descuento_centavos')::bigint, (v_calc->>'impuesto_centavos')::bigint,
    (v_calc->>'total_centavos')::bigint, interno.json_texto(p_datos->'nota', 'nota', 500), interno.equipo(p_datos), p_id_operacion, auth.uid())
  RETURNING * INTO a;
  INSERT INTO public.apartado_linea (empresa_id, apartado_id, linea, producto_id, cantidad, es_servicio)
  SELECT p_empresa_id, a.id, (y->>'linea')::smallint, (y->>'producto_id')::uuid, (y->>'cantidad')::numeric, (y->>'es_servicio')::boolean
    FROM jsonb_array_elements(v_calc->'lineas') y;
  -- Anticipo inicial: un cobro tipo "apartado" (su propio id_operacion, derivado).
  r := interno.registrar_cobro_base(p_empresa_id,
         jsonb_strip_nulls(jsonb_build_object('cliente_id', v_cli.id, 'pagos', p_datos->'pagos', 'caja_id', v_caja.id, 'fecha', v_fecha,
                                              'referencia', coalesce(p_datos->>'referencia', 'Apartado #' || a.numero),
                                              'equipo', p_datos->'equipo')),
         md5(p_id_operacion::text || ':anticipo')::uuid, a.id, a.total_centavos);
  RETURN interno.apartado_respuesta(a, false) || jsonb_build_object('cobro_id', r->'cobro_id', 'vuelto_centavos', r->'vuelto_centavos');
END $$;

CREATE OR REPLACE FUNCTION public.cancelar_apartado(p_apartado_id uuid, p_motivo text, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a       public.apartado;
  e       public.empresa;
  v_dest  text;
  v_ant   bigint;
  v_fecha date;
  d       public.cuenta_dinero;
  f       public.saldo_favor;
  v_asto  uuid;
BEGIN
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el apartado no existe.';
  END IF;
  PERFORM interno.exigir_escritura(a.empresa_id, 'apartados.cancelar', 'apartados');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(a.empresa_id, p_id_operacion, 'cancelacion_apartado');
  IF a.cancelacion_id_operacion = p_id_operacion THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  p_datos := coalesce(p_datos, '{}'::jsonb);
  PERFORM interno.exigir_claves(p_datos, ARRAY['destino', 'cuenta_dinero_id', 'fecha', 'referencia', 'equipo']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se cancela el apartado (mínimo 5 letras).';
  END IF;
  SELECT * INTO e FROM public.empresa x WHERE x.id = a.empresa_id;
  v_dest := interno.json_texto(p_datos->'destino', 'destino', 20);
  IF v_dest IS NOT NULL AND v_dest NOT IN ('saldo_favor', 'devolver') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el destino del anticipo es "saldo_favor" o "devolver".';
  END IF;
  IF e.apartado_cancelacion = 'elegir' THEN
    IF v_dest IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique qué pasa con el anticipo ("destino": "saldo_favor" o "devolver").';
    END IF;
  ELSIF v_dest IS NOT NULL AND v_dest <> e.apartado_cancelacion THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el dueño configuró que al cancelar un apartado el anticipo %.',
      CASE e.apartado_cancelacion WHEN 'saldo_favor' THEN 'queda como saldo a favor del cliente' ELSE 'se devuelve' END;
  ELSE
    v_dest := e.apartado_cancelacion;
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), greatest(public.hoy_local(a.empresa_id), a.fecha));
  PERFORM interno.exigir_fecha_contable(a.empresa_id, v_fecha);
  IF v_dest = 'devolver' THEN
    IF NOT public.modulo_esta_activo(a.empresa_id, 'dinero') THEN
      RAISE EXCEPTION 'MODULO_INACTIVO: el módulo "dinero" no está activo; el anticipo solo puede quedar como saldo a favor.';
    END IF;
    d := interno.cuenta_dinero_para_pagar(a.empresa_id, interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id'));
    -- 0.9.1: de una caja solo sale efectivo del turno propio (nunca del de otro cajero).
    PERFORM interno.cuenta_salida_efectivo(a.empresa_id, d.id, ARRAY[auth.uid()], false);
  ELSIF p_datos ? 'cuenta_dinero_id' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de dinero solo va cuando el anticipo se devuelve.';
  END IF;

  PERFORM interno.reservar_operacion(a.empresa_id, p_id_operacion, 'cancelacion_apartado');
  SELECT * INTO a FROM public.apartado WHERE id = p_apartado_id FOR UPDATE;
  IF a.cancelacion_id_operacion = p_id_operacion THEN
    RETURN interno.apartado_respuesta(a, true);
  END IF;
  IF a.estado <> 'vigente' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el apartado #% ya está %.', a.numero, a.estado;
  END IF;
  v_ant := interno.anticipos_apartado(a.id);
  IF v_ant > 0 THEN
    PERFORM interno.exigir_periodo_abierto(a.empresa_id, v_fecha);
    IF v_dest = 'saldo_favor' THEN
      f := interno.crear_saldo_favor(a.empresa_id, a.cliente_id, 'apartado_cancelado', 'apartado', a.id, v_ant, v_fecha);
    END IF;
    v_asto := interno.asiento_sistema(a.empresa_id, interno.sucursal_activa(a.sucursal_id), v_fecha,
      'Cancelación del apartado #' || a.numero || ': ' || trim(p_motivo), 'cancelacion_apartado', p_id_operacion,
      jsonb_build_array(
        jsonb_build_object('uso', 'anticipo_clientes', 'debe', v_ant, 'descripcion', 'Se libera el anticipo'),
        CASE WHEN v_dest = 'saldo_favor' THEN jsonb_build_object('uso', 'saldo_favor', 'haber', v_ant, 'descripcion', 'Queda a favor del cliente')
             ELSE jsonb_build_object('cuenta', interno.codigo_cuenta_dinero(d.id), 'haber', v_ant, 'descripcion', 'Devolución del anticipo') END));
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.apartado
     SET estado = 'cancelado', cancelado_en = now(), cancelado_por = auth.uid(), motivo_cancelacion = trim(p_motivo),
         destino_anticipo = v_dest, anticipo_devuelto_centavos = v_ant, cuenta_devolucion_id = d.id, saldo_favor_id = f.id,
         asiento_cancelacion_id = v_asto, cancelacion_id_operacion = p_id_operacion
   WHERE id = a.id
  RETURNING * INTO a;
  PERFORM set_config('app.motivo', '', true);
  PERFORM interno.rastrear_dinero(v_asto, 'cancelacion_apartado', 'apartado', a.id,
                                  coalesce(interno.json_texto(p_datos->'referencia', 'referencia', 100), 'Apartado #' || a.numero),
                                  interno.equipo(p_datos));
  RETURN interno.apartado_respuesta(a, false);
END $$;

CREATE OR REPLACE FUNCTION public.resolver_aprobacion(p_aprobacion_id uuid, p_aprobar boolean, p_motivo text, p_id_operacion uuid,
                                                      p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a      public.aprobacion;
  v_td   record;
  v_pct  numeric;
BEGIN
  SELECT * INTO a FROM public.aprobacion WHERE id = p_aprobacion_id;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la solicitud de aprobación no existe.';
  END IF;
  IF a.tipo = 'gasto' THEN
    RETURN interno.resolver_aprobacion_gasto(p_aprobacion_id, p_aprobar, p_motivo, p_id_operacion, p_fecha);
  ELSIF a.tipo = 'venta' THEN
    -- 0.9.1: quien aprueba tampoco pasa su tope en una sola línea (salvo el dueño).
    IF p_aprobar AND a.estado = 'pendiente' AND public.mi_rol(a.empresa_id) <> 'dueno'
       AND public.tiene_permiso('ventas.aprobar', a.empresa_id)
       AND EXISTS (SELECT 1 FROM public.venta v WHERE v.id = a.documento_id AND 'descuento' = ANY (v.requiere_aprobacion)) THEN
      SELECT * INTO v_td FROM interno.tope_descuento(a.empresa_id, public.mi_rol(a.empresa_id));
      v_pct := interno.descuento_linea_sobre_tope((SELECT jsonb_agg(to_jsonb(l)) FROM public.venta_linea l WHERE l.venta_id = a.documento_id),
                                                 v_td.aprueba_hasta);
      IF v_pct IS NOT NULL THEN
        RAISE EXCEPTION 'TOPE_APROBACION: una línea lleva % %% de descuento y usted aprueba hasta % %%; pídale al dueño que lo apruebe.',
          v_pct, v_td.aprueba_hasta;
      END IF;
    END IF;
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

-- ---------------------------------------------------------------------
-- 8) Devolución pendiente atascada: a dónde va lo ya pagado
-- ---------------------------------------------------------------------
-- definir_destino_devolucion(devolucion, {"destino":"dinero"|"saldo_favor","cuenta_dinero_id"}, motivo)
--   ventas.devolver (quien la pidió) o ventas.aprobar (quien aprueba).
-- Solo mientras espera aprobación. Caso típico: se pidió sobre una venta al
-- crédito (todo iba a rebajar la deuda, sin destino) y el cliente pagó antes de
-- aprobarla; o el turno de la caja elegida ya se cerró. Después se vuelve a
-- aprobar con resolver_aprobacion. Queda en la bitácora con el motivo.
CREATE FUNCTION public.definir_destino_devolucion(p_devolucion_id uuid, p_datos jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d      public.devolucion;
  e      public.empresa;
  v_dest text;
  v_cta  uuid;
BEGIN
  SELECT * INTO d FROM public.devolucion WHERE id = p_devolucion_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la devolución no existe.';
  END IF;
  PERFORM interno.exigir_escritura(d.empresa_id, 'ventas.devolver', 'ventas');
  IF auth.uid() IS DISTINCT FROM d.creado_por AND NOT public.tiene_permiso('ventas.aprobar', d.empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: solo quien pidió la devolución o quien la aprueba (permiso "ventas.aprobar") cambia su destino.';
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM interno.exigir_claves(coalesce(p_datos, '{}'::jsonb), ARRAY['destino', 'cuenta_dinero_id']);
  SELECT * INTO e FROM public.empresa x WHERE x.id = d.empresa_id;
  v_dest := interno.json_texto(p_datos->'destino', 'destino', 20);
  IF coalesce(v_dest, '') NOT IN ('dinero', 'saldo_favor') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el destino es "dinero" o "saldo_favor" (un cambio de producto no queda pendiente).';
  END IF;
  IF NOT (CASE v_dest WHEN 'dinero' THEN 'devolver_dinero' ELSE 'nota_credito' END) = ANY (e.devolucion_tipos) THEN
    RAISE EXCEPTION 'DEVOLUCION_NO_PERMITIDA: el dueño no permite "%" (permitidos: %).', v_dest, array_to_string(e.devolucion_tipos, ', ');
  END IF;
  v_cta := interno.json_uuid(p_datos->'cuenta_dinero_id', 'cuenta_dinero_id');
  IF v_dest = 'dinero' THEN
    IF v_cta IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: indique de qué cuenta sale el dinero ("cuenta_dinero_id": caja, caja chica o banco).';
    END IF;
    PERFORM interno.cuenta_dinero_para_pagar(d.empresa_id, v_cta);
    PERFORM interno.cuenta_salida_efectivo(d.empresa_id, v_cta, ARRAY[auth.uid(), d.creado_por], false);
  ELSIF v_cta IS NOT NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la cuenta de dinero solo va al devolver dinero.';
  END IF;

  SELECT * INTO d FROM public.devolucion WHERE id = p_devolucion_id FOR UPDATE;
  IF d.estado <> 'pendiente_aprobacion' THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la devolución #% ya está %; su destino ya no cambia.', d.numero, d.estado;
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.devolucion SET destino = v_dest, cuenta_dinero_id = v_cta WHERE id = d.id RETURNING * INTO d;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.ocultar_costos(d.empresa_id, interno.devolucion_respuesta(d, false)
           || jsonb_build_object('destino', d.destino, 'cuenta_dinero_id', d.cuenta_dinero_id), ARRAY['costo_centavos']);
END $$;

-- ---------------------------------------------------------------------
-- 9) Comisiones
-- ---------------------------------------------------------------------
-- Base de la comisión (reemplaza la de 036; misma firma). DECIDIDO POR EL DUEÑO:
-- solo sobre lo realmente cobrado. A la base (sin ISV, menos lo devuelto) se le
-- resta la parte sin ISV de lo condonado: round(condonado x base sin ISV / total con ISV).
-- Ej.: venta 1,150 (1,000 + 150 ISV), condonan 50: se restan round(50 x 1,000 / 1,150) = 43.
CREATE OR REPLACE FUNCTION interno.base_comision(p_venta_id uuid, p_base_tipo text) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH l AS (
    SELECT coalesce(sum(l.base_centavos - coalesce(dv.base, 0)), 0) AS sin_isv,
           coalesce(sum(l.total_centavos - coalesce(dv.total, 0)), 0) AS total,
           coalesce(sum(l.base_centavos - coalesce(dv.base, 0)
                        - CASE WHEN p_base_tipo = 'ganancia'
                               THEN coalesce(l.costo_centavos, 0) - coalesce(dv.costo, 0)
                                    + coalesce(l.costo_estimado_centavos, 0) - coalesce(dv.est, 0)
                               ELSE 0 END), 0) AS base
      FROM public.venta_linea l
      LEFT JOIN LATERAL (SELECT sum(x.base_centavos) AS base, sum(x.total_centavos) AS total, sum(x.costo_centavos) AS costo,
                                sum(x.costo_estimado_centavos) AS est
                           FROM public.devolucion_linea x JOIN public.devolucion d ON d.id = x.devolucion_id
                          WHERE x.venta_linea_id = l.id AND d.estado = 'aplicada') dv ON true
     WHERE l.venta_id = p_venta_id),
  c AS (
    SELECT coalesce(sum(a.monto_centavos), 0) AS condonado FROM public.cxc_aplicacion a
     WHERE a.venta_id = p_venta_id AND a.origen = 'condonacion' AND a.anulada_en IS NULL)
  SELECT (l.base - CASE WHEN c.condonado > 0 AND l.total > 0 THEN round(c.condonado::numeric * l.sin_isv / l.total) ELSE 0 END)::bigint
    FROM l, c
$$;

-- fijar_porcentaje_comision (reemplaza la de 036; misma firma): NO retroactivo,
-- "desde" es hoy o una fecha futura (lo ya vendido no cambia de porcentaje).
CREATE OR REPLACE FUNCTION public.fijar_porcentaje_comision(p_empresa_id uuid, p_user_id uuid, p_porcentaje numeric, p_desde date, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_desde date;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'comisiones.configurar', 'comisiones');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue WHERE ue.empresa_id = p_empresa_id AND ue.user_id = p_user_id
                   AND ue.rol NOT IN ('proveedor', 'contador')) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el empleado no es usuario de esta empresa (o es contador o proveedor).';
  END IF;
  IF p_porcentaje IS NULL OR p_porcentaje NOT BETWEEN 0 AND 100 OR p_porcentaje <> round(p_porcentaje, 2) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el porcentaje va de 0 a 100 (hasta 2 decimales).';
  END IF;
  v_desde := coalesce(p_desde, public.hoy_local(p_empresa_id));
  IF v_desde < public.hoy_local(p_empresa_id) THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: el porcentaje de comisión no es retroactivo: "desde" debe ser hoy (%) o una fecha futura.',
      to_char(public.hoy_local(p_empresa_id), 'DD/MM/YYYY');
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.comision_porcentaje (empresa_id, user_id, porcentaje, desde, motivo, creado_por)
  VALUES (p_empresa_id, p_user_id, p_porcentaje, v_desde, trim(p_motivo), auth.uid());
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('user_id', p_user_id, 'porcentaje', p_porcentaje, 'desde', to_char(v_desde, 'YYYY-MM-DD'));
END $$;

-- ---------------------------------------------------------------------
-- 10) Vales vencidos: darlos de baja (opción del dueño)
-- ---------------------------------------------------------------------
-- Un vale vencido sigue en el pasivo (2.1.04.02) y ya no se puede usar. El
-- dueño decide darlo de baja: cada vale queda "usado" por la baja (su saldo a
-- 0) y el total pasa a otros ingresos (Dr Saldos a favor / Cr 4.2.01.04).
CREATE TABLE public.saldo_favor_baja (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id        uuid NOT NULL REFERENCES public.empresa(id),
  numero            bigint NOT NULL,
  fecha_contable    date NOT NULL,
  monto_centavos    bigint NOT NULL CHECK (monto_centavos BETWEEN 1 AND 9007199254740991),
  vales             integer NOT NULL CHECK (vales > 0),
  motivo            text NOT NULL CHECK (length(trim(motivo)) >= 5),
  asiento_id        uuid NOT NULL,
  id_operacion      uuid NOT NULL,
  creado_por        uuid,
  registrado_en     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, asiento_id) REFERENCES public.asiento(empresa_id, id)
);
CREATE TRIGGER proteger BEFORE UPDATE ON public.saldo_favor_baja
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La baja de vales vencidos no se edita.');
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.saldo_favor_baja FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.saldo_favor_baja
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La baja de vales vencidos no se borra.');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.saldo_favor_baja
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
ALTER TABLE public.saldo_favor_baja ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.saldo_favor_baja TO authenticated, service_role;
CREATE POLICY leer ON public.saldo_favor_baja FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('ventas.ver'))));

-- dar_baja_vales_vencidos(empresa, {"vales":["VALE-..."] (opcional: si no, todos los vencidos), "fecha"}, motivo, id_operacion)
--   cobros.baja_vales (solo el dueño). Solo vales SIN cliente, vencidos a la fecha y con saldo.
CREATE FUNCTION public.dar_baja_vales_vencidos(p_empresa_id uuid, p_datos jsonb, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  b       public.saldo_favor_baja;
  s       public.saldo_favor;
  v_fecha date;
  v_cods  text[];
  v_c     text;
  v_saldo bigint;
  v_total bigint := 0;
  v_n     integer := 0;
  v_det   jsonb := '[]';
  v_asto  uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'cobros.baja_vales', 'ventas');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'baja_vales');
  SELECT * INTO b FROM public.saldo_favor_baja x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF b.id IS NOT NULL THEN
    RETURN jsonb_build_object('baja_id', b.id, 'numero', b.numero, 'monto_centavos', b.monto_centavos, 'vales', b.vales,
                              'asiento_id', b.asiento_id, 'duplicado', true);
  END IF;
  p_datos := coalesce(p_datos, '{}'::jsonb);
  PERFORM interno.exigir_claves(p_datos, ARRAY['vales', 'fecha']);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se dan de baja los vales (mínimo 5 letras).';
  END IF;
  IF coalesce(p_datos->'vales', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_datos->'vales') <> 'array' OR jsonb_array_length(p_datos->'vales') = 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "vales" es una lista de códigos ["VALE-..."].';
    END IF;
    SELECT array_agg(DISTINCT upper(trim(x))) INTO v_cods FROM jsonb_array_elements_text(p_datos->'vales') x;
  END IF;
  v_fecha := coalesce(interno.json_fecha(p_datos->'fecha', 'fecha'), public.hoy_local(p_empresa_id));
  PERFORM interno.exigir_fecha_contable(p_empresa_id, v_fecha);

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'baja_vales');
  SELECT * INTO b FROM public.saldo_favor_baja x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF b.id IS NOT NULL THEN
    RETURN jsonb_build_object('baja_id', b.id, 'numero', b.numero, 'monto_centavos', b.monto_centavos, 'vales', b.vales,
                              'asiento_id', b.asiento_id, 'duplicado', true);
  END IF;
  -- Los vales pedidos deben existir, ser vales (sin cliente), estar vencidos y tener saldo.
  FOREACH v_c IN ARRAY coalesce(v_cods, '{}') LOOP
    SELECT * INTO s FROM public.saldo_favor x WHERE x.empresa_id = p_empresa_id AND x.codigo = v_c;
    IF s.id IS NULL OR s.anulada_en IS NOT NULL THEN
      RAISE EXCEPTION 'VALE_INVALIDO: el vale % no existe o está anulado.', v_c;
    END IF;
    IF s.vence_el IS NULL OR s.vence_el >= v_fecha THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el vale % no está vencido (vence %).', v_c, coalesce(to_char(s.vence_el, 'DD/MM/YYYY'), 'nunca');
    END IF;
  END LOOP;
  b.id := gen_random_uuid();
  FOR s IN SELECT * FROM public.saldo_favor x
            WHERE x.empresa_id = p_empresa_id AND x.cliente_id IS NULL AND x.anulada_en IS NULL AND x.vence_el < v_fecha
              AND (v_cods IS NULL OR x.codigo = ANY (v_cods))
            ORDER BY x.numero FOR UPDATE LOOP
    v_saldo := interno.saldo_favor_lote(s.id);
    CONTINUE WHEN v_saldo <= 0;
    INSERT INTO public.saldo_favor_uso (empresa_id, saldo_favor_id, monto_centavos, documento_tipo, documento_id, fecha_contable, creado_por)
    VALUES (p_empresa_id, s.id, v_saldo, 'baja_vencido', b.id, v_fecha, auth.uid());
    v_total := v_total + v_saldo;
    v_n := v_n + 1;
    v_det := v_det || jsonb_build_object('codigo', s.codigo, 'vence_el', to_char(s.vence_el, 'YYYY-MM-DD'), 'monto_centavos', v_saldo);
  END LOOP;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'SIN_VALES_VENCIDOS: no hay vales vencidos con saldo%.', CASE WHEN v_cods IS NOT NULL THEN ' entre los indicados' ELSE '' END;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, v_fecha);
  b.numero := interno.siguiente_numero(p_empresa_id, 'saldo_favor_baja');
  v_asto := interno.asiento_sistema(p_empresa_id, NULL, v_fecha,
    'Baja #' || b.numero || ' de ' || v_n || ' vale(s) vencido(s): ' || trim(p_motivo), 'baja_vales', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'saldo_favor', 'debe', v_total, 'descripcion', 'Vales vencidos no reclamados'),
                      jsonb_build_object('uso', 'vales_vencidos', 'haber', v_total, 'descripcion', 'Vales vencidos a otros ingresos')));
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.saldo_favor_baja (id, empresa_id, numero, fecha_contable, monto_centavos, vales, motivo, asiento_id, id_operacion, creado_por)
  VALUES (b.id, p_empresa_id, b.numero, v_fecha, v_total, v_n, trim(p_motivo), v_asto, p_id_operacion, auth.uid())
  RETURNING * INTO b;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('baja_id', b.id, 'numero', b.numero, 'monto_centavos', v_total, 'vales', v_n, 'detalle', v_det,
                            'asiento_id', v_asto, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- 11) id_operacion y seguridad
-- ---------------------------------------------------------------------
INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('saldo_favor_baja', 'id_operacion', 'baja_vales', 50);

REVOKE EXECUTE ON FUNCTION
  interno.quitar_claves(jsonb, text[]),
  interno.cuenta_salida_efectivo(uuid, uuid, uuid[], boolean),
  interno.descuento_linea_sobre_tope(jsonb, numeric)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.definir_destino_devolucion(uuid, jsonb, text),
  public.dar_baja_vales_vencidos(uuid, jsonb, text, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.definir_destino_devolucion(uuid, jsonb, text),
  public.dar_baja_vales_vencidos(uuid, jsonb, text, uuid)
TO authenticated;
