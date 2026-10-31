-- =====================================================================
-- 002_bitacora.sql  -  Auditoría solo-agregar y protección contra borrado
--
-- Huella encadenada: cada fila guarda la huella (sha256) de su contenido
-- más la huella de la fila anterior DE LA MISMA EMPRESA. Si alguien con
-- acceso total a la base cambia, borra o mete una fila (por ejemplo
-- desactivando los triggers), verificar_bitacora() lo detecta.
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
  motivo        text,
  secuencia        bigint,     -- 1, 2, 3... por empresa (la pone el trigger)
  huella_anterior  text,       -- huella de la fila anterior de la empresa
  huella           text        -- sha256 de esta fila (incluye huella_anterior)
);
CREATE INDEX bitacora_empresa_fecha ON public.bitacora (empresa_id, ocurrido_en);
CREATE UNIQUE INDEX bitacora_cadena_secuencia
  ON public.bitacora ((coalesce(empresa_id, '00000000-0000-0000-0000-000000000000'::uuid)), secuencia);

-- Último eslabón de cada cadena (una por empresa; la de sistema usa el uuid 0).
-- Bloquear su fila ordena a quienes escriben en la bitácora al mismo tiempo.
CREATE TABLE interno.bitacora_cadena (
  clave             uuid   PRIMARY KEY,
  ultima_secuencia  bigint NOT NULL DEFAULT 0,
  ultima_huella     text   NOT NULL DEFAULT repeat('0', 64)
);

-- Huella de una fila: sha256 del contenido en texto fijo (la hora va en
-- UTC para que no dependa de la zona de la sesión).
CREATE FUNCTION interno.huella_bitacora(b public.bitacora) RETURNS text
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT encode(sha256(convert_to(jsonb_build_object(
    'id', b.id, 'empresa_id', b.empresa_id, 'secuencia', b.secuencia,
    'usuario_id', b.usuario_id, 'rol_sesion', b.rol_sesion,
    'ocurrido_en', to_char(b.ocurrido_en AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'accion', b.accion, 'tabla', b.tabla, 'registro_id', b.registro_id,
    'antes', b.antes, 'despues', b.despues, 'id_operacion', b.id_operacion,
    'motivo', b.motivo, 'huella_anterior', b.huella_anterior)::text, 'UTF8')), 'hex')
$$;

-- Antes de guardar una fila: hora del servidor, número y huella encadenada.
CREATE FUNCTION interno.encadenar_bitacora() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_clave uuid := coalesce(NEW.empresa_id, '00000000-0000-0000-0000-000000000000');
  v_cad   interno.bitacora_cadena;
BEGIN
  INSERT INTO interno.bitacora_cadena (clave) VALUES (v_clave) ON CONFLICT DO NOTHING;
  SELECT * INTO v_cad FROM interno.bitacora_cadena WHERE clave = v_clave FOR UPDATE;

  NEW.ocurrido_en     := now();
  NEW.secuencia       := v_cad.ultima_secuencia + 1;
  NEW.huella_anterior := v_cad.ultima_huella;
  NEW.huella          := interno.huella_bitacora(NEW);

  UPDATE interno.bitacora_cadena
     SET ultima_secuencia = NEW.secuencia, ultima_huella = NEW.huella
   WHERE clave = v_clave;
  RETURN NEW;
END $$;

CREATE TRIGGER encadenar BEFORE INSERT ON public.bitacora
  FOR EACH ROW EXECUTE FUNCTION interno.encadenar_bitacora();

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
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.acceso_soporte  FOR EACH ROW EXECUTE FUNCTION interno.auditar();

-- Estas filas no se borran: se desactivan (activa/activo = false).
CREATE TRIGGER no_borrar BEFORE DELETE ON public.empresa         FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las empresas no se borran.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.sucursal        FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la sucursal en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.caja            FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la caja en vez de borrarla.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.usuario_empresa FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive al usuario en vez de borrarlo.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.licencia        FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('La licencia se actualiza, no se borra.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.acceso_soporte  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El acceso de soporte se revoca, no se borra.');

-- ---------------------------------------------------------------------
-- verificar_bitacora: revisa la cadena de una empresa (o de todas si la
-- llama service_role / el administrador sin indicar empresa).
-- Devuelve UNA FILA POR PROBLEMA. Sin filas = bitácora intacta.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.verificar_bitacora(p_empresa_id uuid DEFAULT NULL)
RETURNS TABLE (empresa_id uuid, secuencia bigint, bitacora_id bigint, problema text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
#variable_conflict use_column
DECLARE
  c_cero constant uuid := '00000000-0000-0000-0000-000000000000';
  v_empresa uuid := p_empresa_id;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    v_empresa := coalesce(p_empresa_id, public.empresa_actual());
    PERFORM interno.exigir_lectura(v_empresa, 'bitacora.ver');
  ELSE
    PERFORM interno.exigir_lectura(NULL, 'bitacora.ver');
  END IF;

  RETURN QUERY
  WITH filas AS (
    SELECT b.*, coalesce(b.empresa_id, c_cero) AS clave,
           interno.huella_bitacora(b) AS huella_calculada,
           lag(b.huella)    OVER w AS huella_previa,
           lag(b.secuencia) OVER w AS secuencia_previa
    FROM public.bitacora b
    WHERE v_empresa IS NULL OR b.empresa_id = v_empresa
    WINDOW w AS (PARTITION BY coalesce(b.empresa_id, c_cero) ORDER BY b.secuencia, b.id)
  )
  SELECT f.empresa_id, f.secuencia, f.id, x.problema
  FROM filas f
  CROSS JOIN LATERAL (VALUES
    (CASE WHEN f.huella IS NULL OR f.secuencia IS NULL
          THEN 'fila sin huella (se metió sin pasar por el sistema)' END),
    (CASE WHEN f.huella IS NOT NULL AND f.huella <> f.huella_calculada
          THEN 'fila alterada: su contenido no coincide con su huella' END),
    (CASE WHEN f.huella_anterior IS DISTINCT FROM coalesce(f.huella_previa, repeat('0', 64))
          THEN 'cadena rota: la fila anterior fue cambiada, borrada o agregada' END),
    (CASE WHEN f.secuencia IS DISTINCT FROM coalesce(f.secuencia_previa, 0) + 1
          THEN 'faltan filas antes de esta (número salteado)' END)
  ) AS x(problema)
  WHERE x.problema IS NOT NULL
  UNION ALL
  -- Filas borradas al final de la cadena.
  SELECT nullif(c.clave, c_cero), c.ultima_secuencia, NULL::bigint,
         'faltan filas al final: la última registrada era la número ' || c.ultima_secuencia
  FROM interno.bitacora_cadena c
  WHERE (v_empresa IS NULL OR c.clave = v_empresa)
    AND c.ultima_secuencia <> coalesce((SELECT max(b.secuencia) FROM public.bitacora b
                                         WHERE coalesce(b.empresa_id, c_cero) = c.clave), 0);
END $$;
