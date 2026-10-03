-- =====================================================================
-- 002_bitacora.sql  -  Auditoría solo-agregar y protección contra borrado
-- =====================================================================

CREATE TABLE public.bitacora (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id    uuid,
  usuario_id    uuid,                                   -- auth.uid() (NULL = sistema)
  rol_sesion    text,                                   -- authenticated / service_role / postgres
  ocurrido_en   timestamptz NOT NULL DEFAULT now(),     -- hora del SERVIDOR
  accion        text NOT NULL,                          -- INSERT / UPDATE / DELETE / otra
  tabla         text NOT NULL,
  registro_id   text,
  antes         jsonb,
  despues       jsonb,
  id_operacion  uuid,
  motivo        text
);
CREATE INDEX bitacora_empresa_fecha ON public.bitacora (empresa_id, ocurrido_en);

-- ---------------------------------------------------------------------
-- Trigger genérico de auditoría.
-- Las funciones pueden pasar un motivo con set_config('app.motivo', ..., true)
-- y un id de operación con set_config('app.id_operacion', ..., true).
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.auditar() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_antes    jsonb := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
  v_despues  jsonb := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END;
  v_fila     jsonb := coalesce(v_despues, v_antes);
  v_empresa  text;
  v_id_op    text;
  v_rol      text;
BEGIN
  v_empresa := CASE WHEN TG_TABLE_NAME = 'empresa' THEN v_fila->>'id' ELSE v_fila->>'empresa_id' END;
  v_id_op   := coalesce(v_fila->>'id_operacion', nullif(current_setting('app.id_operacion', true), ''));
  v_rol     := coalesce(auth.role(), nullif(current_setting('role'), 'none'), session_user::text);

  INSERT INTO public.bitacora (empresa_id, usuario_id, rol_sesion, accion, tabla,
                               registro_id, antes, despues, id_operacion, motivo)
  VALUES (v_empresa::uuid, auth.uid(), v_rol, TG_OP, TG_TABLE_NAME,
          coalesce(v_fila->>'id', v_fila->>'empresa_id'),
          v_antes, v_despues, v_id_op::uuid,
          nullif(current_setting('app.motivo', true), ''));
  RETURN NULL;   -- AFTER trigger
END $$;

-- ---------------------------------------------------------------------
-- Trigger que prohíbe cambios. Aplica incluso al dueño de la tabla.
-- TG_ARGV[0] = texto de ayuda para el mensaje.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.prohibir_cambios() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'PROHIBIDO: no se permite % en "%". %',
    TG_OP, TG_TABLE_NAME, coalesce(TG_ARGV[0], 'Nada se borra ni se edita.');
END $$;

-- La bitácora no se edita, no se borra y no se vacía. Nunca.
CREATE TRIGGER bitacora_inmutable BEFORE UPDATE OR DELETE ON public.bitacora
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La bitácora es de solo agregar.');
CREATE TRIGGER bitacora_no_vaciar BEFORE TRUNCATE ON public.bitacora
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('La bitácora es de solo agregar.');

-- Auditoría de las tablas sensibles de 001.
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.empresa         FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.sucursal        FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.caja            FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.usuario_empresa FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.rol_permiso     FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.modulo_activo   FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.licencia        FOR EACH ROW EXECUTE FUNCTION interno.auditar();

-- Estas filas no se borran: se desactivan (activa/activo = false).
CREATE TRIGGER no_borrar BEFORE DELETE ON public.empresa         FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las empresas no se borran.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.sucursal        FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la sucursal en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.caja            FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la caja en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.usuario_empresa FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive al usuario en vez de borrarlo.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.licencia        FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La licencia se actualiza, no se borra.');
