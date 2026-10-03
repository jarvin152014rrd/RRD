-- =====================================================================
-- 004_periodos.sql  -  Meses contables (abierto / cerrado)
-- Un mes sin fila se considera abierto y se crea solo al usarlo.
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

-- Revisa que el mes de una fecha esté abierto. Bloquea la fila del mes
-- (FOR SHARE) para que nadie lo cierre mientras se guarda el asiento.
CREATE FUNCTION interno.exigir_periodo_abierto(p_empresa_id uuid, p_fecha date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_anio   integer := extract(year  FROM p_fecha);
  v_mes    integer := extract(month FROM p_fecha);
  v_estado text;
BEGIN
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: falta la fecha contable.';
  END IF;
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
-- ---------------------------------------------------------------------
CREATE FUNCTION public.cerrar_periodo(p_empresa_id uuid, p_anio integer, p_mes integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_estado text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'periodos.cerrar');

  INSERT INTO public.periodo (empresa_id, anio, mes) VALUES (p_empresa_id, p_anio, p_mes)
  ON CONFLICT DO NOTHING;
  SELECT estado INTO v_estado FROM public.periodo
   WHERE empresa_id = p_empresa_id AND anio = p_anio AND mes = p_mes FOR UPDATE;

  IF v_estado = 'cerrado' THEN
    RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'cerrado', 'ya_estaba', true);
  END IF;

  UPDATE public.periodo
     SET estado = 'cerrado', cambiado_por = auth.uid(), cambiado_en = now()
   WHERE empresa_id = p_empresa_id AND anio = p_anio AND mes = p_mes;

  RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'cerrado', 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: reabrir un mes. Exige motivo; queda en la bitácora.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.reabrir_periodo(p_empresa_id uuid, p_anio integer, p_mes integer, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_estado text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'periodos.reabrir');

  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo para reabrir el mes (mínimo 5 letras).';
  END IF;

  SELECT estado INTO v_estado FROM public.periodo
   WHERE empresa_id = p_empresa_id AND anio = p_anio AND mes = p_mes FOR UPDATE;
  IF v_estado IS DISTINCT FROM 'cerrado' THEN
    RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'abierto', 'ya_estaba', true);
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);   -- lo toma la bitácora
  UPDATE public.periodo
     SET estado = 'abierto', cambiado_por = auth.uid(), cambiado_en = now()
   WHERE empresa_id = p_empresa_id AND anio = p_anio AND mes = p_mes;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('anio', p_anio, 'mes', p_mes, 'estado', 'abierto', 'ya_estaba', false);
END $$;
