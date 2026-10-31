-- =====================================================================
-- 009_soporte.sql  -  Acceso de soporte temporal para el proveedor
--
-- Por defecto el proveedor NO ve cifras (asientos, saldos, bitácora).
-- Cuando el dueño pide ayuda, le da un acceso con motivo y fecha de
-- vencimiento (máximo 30 días). Mientras esté vigente, el proveedor
-- puede LEER (permisos es_financiero), nunca mover los libros.
-- Vence solo. El dueño lo puede revocar antes. Todo queda en bitácora.
-- (La tabla public.acceso_soporte está en 001.)
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('VENCIMIENTO_INVALIDO', 'La fecha de vencimiento del acceso no es válida.',
   'Elija una fecha futura, como máximo dentro de 30 días.');

-- Un acceso no se edita: solo se puede revocar una vez.
CREATE FUNCTION interno.validar_acceso_soporte() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.motivo, NEW.otorgado_por, NEW.desde, NEW.vence_en)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.motivo, OLD.otorgado_por, OLD.desde, OLD.vence_en)
     OR OLD.revocado_en IS NOT NULL THEN
    RAISE EXCEPTION 'PROHIBIDO: un acceso de soporte no se edita; solo se revoca una vez.';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER validar BEFORE UPDATE ON public.acceso_soporte
  FOR EACH ROW EXECUTE FUNCTION interno.validar_acceso_soporte();

-- ---------------------------------------------------------------------
-- RPC: el dueño da acceso de soporte hasta p_vence_en.
-- Funciona aunque la licencia esté vencida (justo cuando más se necesita).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.otorgar_acceso_soporte(p_empresa_id uuid, p_vence_en timestamptz, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'soporte.otorgar', NULL, false);

  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba para qué necesita el soporte (mínimo 5 letras).';
  END IF;
  IF p_vence_en IS NULL OR p_vence_en <= now() OR p_vence_en > now() + interval '30 days' THEN
    RAISE EXCEPTION 'VENCIMIENTO_INVALIDO: el acceso debe vencer en el futuro y en 30 días o menos.';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.acceso_soporte (empresa_id, motivo, otorgado_por, vence_en)
  VALUES (p_empresa_id, trim(p_motivo), auth.uid(), p_vence_en)
  RETURNING id INTO v_id;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('acceso_id', v_id, 'vence_en', public.iso(p_vence_en));
END $$;

-- ---------------------------------------------------------------------
-- RPC: el dueño quita YA todos los accesos de soporte vigentes.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.revocar_acceso_soporte(p_empresa_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_n integer;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'soporte.otorgar', NULL, false);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo para quitar el acceso (mínimo 5 letras).';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.acceso_soporte
     SET revocado_en = now(), revocado_por = auth.uid(), motivo_revocacion = trim(p_motivo)
   WHERE empresa_id = p_empresa_id AND revocado_en IS NULL AND vence_en > now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('revocados', v_n);
END $$;

REVOKE EXECUTE ON FUNCTION
  public.otorgar_acceso_soporte(uuid, timestamptz, text),
  public.revocar_acceso_soporte(uuid, text),
  interno.validar_acceso_soporte()
FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
  public.otorgar_acceso_soporte(uuid, timestamptz, text),
  public.revocar_acceso_soporte(uuid, text)
TO authenticated;
