-- =====================================================================
-- 004_periodos.sql  -  Meses contables (abierto / cerrado) y fechas válidas
-- Un mes sin fila se considera abierto y se crea solo al usarlo.
--
-- Reglas:
--   * La fecha contable va desde empresa.fecha_inicio hasta
--     hoy + empresa.dias_futuro_max (3 por defecto).
--   * Los meses se cierran EN ORDEN: no se cierra un mes si uno anterior
--     con movimientos sigue abierto, ni un mes que no ha terminado.
--     Al cerrar, los meses anteriores SIN movimientos se cierran solos.
--   * Se reabre solo el último mes cerrado (en orden inverso).
-- =====================================================================

CREATE TABLE public.periodo (
  empresa_id   uuid    NOT NULL REFERENCES public.empresa(id),
  anio         integer NOT NULL CHECK (anio BETWEEN 2000 AND 2100),
  mes          integer NOT NULL CHECK (mes BETWEEN 1 AND 12),
  estado       text    NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','cerrado')),
  cambiado_por uuid,
  cambiado_en  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (empresa_id, anio, mes)
);

CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.periodo
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.periodo
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los períodos no se borran.');

-- Texto "mm/aaaa" para los mensajes.
CREATE FUNCTION interno.mes_texto(p_fecha date) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT to_char(p_fecha, 'MM/YYYY')
$$;

-- Bloquea "los libros" de la empresa hasta el fin de la transacción.
-- Registrar, anular, cerrar y reabrir lo toman PRIMERO, así esperan en
-- fila y en el mismo orden (sin bloqueos cruzados).
CREATE FUNCTION interno.bloquear_libros(p_empresa_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO interno.contador (empresa_id, clave) VALUES (p_empresa_id, 'asiento')
  ON CONFLICT DO NOTHING;
  PERFORM 1 FROM interno.contador
   WHERE empresa_id = p_empresa_id AND clave = 'asiento' FOR UPDATE;
END $$;

-- La fecha contable debe estar entre el inicio de la empresa y hoy + N días.
CREATE FUNCTION interno.exigir_fecha_contable(p_empresa_id uuid, p_fecha date) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_emp  public.empresa;
  v_tope date;
BEGIN
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: falta la fecha contable.';
  END IF;
  SELECT * INTO v_emp FROM public.empresa WHERE id = p_empresa_id;
  IF p_fecha < v_emp.fecha_inicio THEN
    RAISE EXCEPTION 'FECHA_ANTERIOR_AL_INICIO: la fecha % es anterior al inicio de la empresa (%).',
      to_char(p_fecha, 'DD/MM/YYYY'), to_char(v_emp.fecha_inicio, 'DD/MM/YYYY');
  END IF;
  v_tope := public.hoy_local(p_empresa_id) + v_emp.dias_futuro_max;
  IF p_fecha > v_tope THEN
    RAISE EXCEPTION 'FECHA_MUY_FUTURA: la fecha % está demasiado adelante. Lo más lejos permitido es %.',
      to_char(p_fecha, 'DD/MM/YYYY'), to_char(v_tope, 'DD/MM/YYYY');
  END IF;
END $$;

-- Revisa la fecha y que su mes esté abierto. Bloquea la fila del mes
-- (FOR SHARE) para que nadie lo cierre mientras se guarda el asiento.
CREATE FUNCTION interno.exigir_periodo_abierto(p_empresa_id uuid, p_fecha date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_anio   integer := extract(year  FROM p_fecha);
  v_mes    integer := extract(month FROM p_fecha);
  v_estado text;
BEGIN
  PERFORM interno.exigir_fecha_contable(p_empresa_id, p_fecha);
  INSERT INTO public.periodo (empresa_id, anio, mes) VALUES (p_empresa_id, v_anio, v_mes)
  ON CONFLICT DO NOTHING;
  SELECT estado INTO v_estado FROM public.periodo
   WHERE empresa_id = p_empresa_id AND anio = v_anio AND mes = v_mes
   FOR SHARE;
  IF v_estado = 'cerrado' THEN
    RAISE EXCEPTION 'PERIODO_CERRADO: el mes %/% está cerrado. No se pueden registrar asientos con esa fecha.',
      lpad(v_mes::text, 2, '0'), v_anio;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- RPC: cerrar un mes. Si ya estaba cerrado no hace nada (seguro reintentar).
-- Devuelve {anio, mes, estado, ya_estaba, meses_vacios_cerrados}.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.cerrar_periodo(p_empresa_id uuid, p_anio integer, p_mes integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_estado    text;
  v_mes_ini   date;
  v_inicio    date;
  v_pendiente date;
  v_vacios    integer := 0;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'periodos.cerrar');

  IF p_anio IS NULL OR p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 OR p_anio NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'PERIODO_INVALIDO: el mes o el año no son válidos.';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);

  v_mes_ini := make_date(p_anio, p_mes, 1);
  SELECT date_trunc('month', e.fecha_inicio)::date INTO v_inicio
    FROM public.empresa e WHERE e.id = p_empresa_id;

  IF v_mes_ini < v_inicio THEN
    RAISE EXCEPTION 'FECHA_ANTERIOR_AL_INICIO: el mes % es anterior al inicio de la empresa.',
      interno.mes_texto(v_mes_ini);
  END IF;
  IF (v_mes_ini + interval '1 month')::date > public.hoy_local(p_empresa_id) THEN
    RAISE EXCEPTION 'MES_NO_TERMINADO: el mes % todavía no ha terminado; se cierra a partir del día 1 del mes siguiente.',
      interno.mes_texto(v_mes_ini);
  END IF;

  SELECT estado INTO v_estado FROM public.periodo
   WHERE empresa_id = p_empresa_id AND anio = p_anio AND mes = p_mes;
  IF v_estado = 'cerrado' THEN
    RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'cerrado',
                              'ya_estaba', true, 'meses_vacios_cerrados', 0);
  END IF;

  -- ¿Hay un mes anterior con movimientos que sigue abierto?
  SELECT min(date_trunc('month', a.fecha_contable))::date INTO v_pendiente
    FROM public.asiento a
   WHERE a.empresa_id = p_empresa_id
     AND a.fecha_contable < v_mes_ini
     AND NOT EXISTS (SELECT 1 FROM public.periodo p
                      WHERE p.empresa_id = a.empresa_id
                        AND p.anio = extract(year FROM a.fecha_contable)
                        AND p.mes  = extract(month FROM a.fecha_contable)
                        AND p.estado = 'cerrado');
  IF v_pendiente IS NOT NULL THEN
    RAISE EXCEPTION 'MES_ANTERIOR_ABIERTO: primero cierre el mes %, que tiene movimientos y sigue abierto.',
      interno.mes_texto(v_pendiente);
  END IF;

  -- Meses anteriores sin movimientos: se cierran solos (quedan en bitácora).
  PERFORM set_config('app.motivo', 'Cierre automático: mes sin movimientos, al cerrar '
                     || interno.mes_texto(v_mes_ini), true);
  INSERT INTO public.periodo AS p (empresa_id, anio, mes, estado, cambiado_por, cambiado_en)
  SELECT p_empresa_id, extract(year FROM m)::integer, extract(month FROM m)::integer,
         'cerrado', auth.uid(), now()
    FROM generate_series(v_inicio::timestamp, v_mes_ini - interval '1 month', interval '1 month') AS m
  ON CONFLICT (empresa_id, anio, mes) DO UPDATE
     SET estado = 'cerrado', cambiado_por = auth.uid(), cambiado_en = now()
   WHERE p.estado = 'abierto';
  GET DIAGNOSTICS v_vacios = ROW_COUNT;
  PERFORM set_config('app.motivo', '', true);

  INSERT INTO public.periodo AS p (empresa_id, anio, mes, estado, cambiado_por, cambiado_en)
  VALUES (p_empresa_id, p_anio, p_mes, 'cerrado', auth.uid(), now())
  ON CONFLICT (empresa_id, anio, mes) DO UPDATE
     SET estado = 'cerrado', cambiado_por = auth.uid(), cambiado_en = now();

  RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'cerrado',
                            'ya_estaba', false, 'meses_vacios_cerrados', v_vacios);
END $$;

-- ---------------------------------------------------------------------
-- RPC: reabrir un mes. Exige motivo; queda en la bitácora.
-- Solo el último mes cerrado (para reabrir uno anterior, reabra primero
-- los posteriores, de atrás para adelante).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.reabrir_periodo(p_empresa_id uuid, p_anio integer, p_mes integer, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_estado  text;
  v_ultimo  record;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'periodos.reabrir');

  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo para reabrir el mes (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);

  SELECT estado INTO v_estado FROM public.periodo
   WHERE empresa_id = p_empresa_id AND anio = p_anio AND mes = p_mes FOR UPDATE;
  IF v_estado IS DISTINCT FROM 'cerrado' THEN
    RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'abierto', 'ya_estaba', true);
  END IF;

  SELECT p.anio, p.mes INTO v_ultimo FROM public.periodo p
   WHERE p.empresa_id = p_empresa_id AND p.estado = 'cerrado'
     AND (p.anio, p.mes) > (p_anio, p_mes)
   ORDER BY p.anio DESC, p.mes DESC LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'REABRIR_EN_ORDEN: primero reabra el mes %/% (se reabre del último cerrado hacia atrás).',
      lpad(v_ultimo.mes::text, 2, '0'), v_ultimo.anio;
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);   -- lo toma la bitácora
  UPDATE public.periodo
     SET estado = 'abierto', cambiado_por = auth.uid(), cambiado_en = now()
   WHERE empresa_id = p_empresa_id AND anio = p_anio AND mes = p_mes;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'abierto', 'ya_estaba', false);
END $$;
