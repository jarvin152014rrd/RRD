-- =====================================================================
-- 006_seguridad.sql  -  Permisos de tablas, RLS y edición de permisos
--
-- Idea simple:
--   * anon (sin sesión): no ve ni hace nada.
--   * authenticated: solo LEE, y solo lo de sus empresas (RLS).
--     Para escribir llama funciones (RPC) que revisan todo.
--   * service_role (llave del proveedor): lee todo y escribe SOLO licencia.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Permisos de tablas
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA public  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL TABLES    IN SCHEMA interno FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT INSERT, UPDATE ON public.licencia TO service_role;   -- sin DELETE

-- ---------------------------------------------------------------------
-- 2) Funciones: nadie las ejecuta salvo que se diga aquí
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public  FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA interno FROM PUBLIC, anon, authenticated, service_role;

-- Lectura / ayuda (las usan las políticas RLS y la app).
GRANT EXECUTE ON FUNCTION
  public.hoy_local(uuid),
  public.iso(timestamptz),
  public.verificar_bitacora(uuid),
  public.mis_empresas(),
  public.empresa_actual(),
  public.mi_rol(uuid),
  public.tiene_permiso(text, uuid),
  public.licencia_activa(uuid),
  public.modulo_esta_activo(uuid, text)
TO authenticated, service_role;

-- Escritura (RPC). Cada una revisa sesión, empresa, permiso, licencia y módulo.
GRANT EXECUTE ON FUNCTION
  public.registrar_asiento(uuid, date, text, jsonb, uuid, uuid),
  public.anular_asiento(uuid, text, uuid, date),
  public.cerrar_periodo(uuid, integer, integer),
  public.reabrir_periodo(uuid, integer, integer, text)
TO authenticated;

-- ---------------------------------------------------------------------
-- 3) RLS en TODAS las tablas de public (la prueba 14 lo vigila)
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind = 'r'
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    -- Nadie vacía tablas de golpe (TRUNCATE salta los triggers de DELETE).
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)',
                   t, 'No se permite vaciar tablas.')
    ;
  END LOOP;
END $$;
-- (bitacora ya tenía su propio trigger anti-TRUNCATE; tener dos no estorba)

-- Catálogos globales: cualquiera con sesión los puede leer.
CREATE POLICY leer ON public.rol     FOR SELECT TO authenticated USING (true);
CREATE POLICY leer ON public.permiso FOR SELECT TO authenticated USING (true);
CREATE POLICY leer ON public.modulo  FOR SELECT TO authenticated USING (true);

-- Datos de la empresa: solo miembros activos.
CREATE POLICY leer ON public.empresa         FOR SELECT TO authenticated USING (id         IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.sucursal        FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.caja            FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.usuario_empresa FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.rol_permiso     FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.modulo_activo   FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.licencia        FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.periodo         FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.cuenta          FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.acceso_soporte  FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));

-- Contabilidad y bitácora: además piden permiso de lectura.
CREATE POLICY leer ON public.asiento       FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('contabilidad.ver', empresa_id));
CREATE POLICY leer ON public.asiento_linea FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('contabilidad.ver', empresa_id));
CREATE POLICY leer ON public.bitacora      FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('bitacora.ver', empresa_id));

-- ---------------------------------------------------------------------
-- 4) El proveedor no recibe permisos por la tabla rol x permiso.
--    Para leer cifras necesita un acceso de soporte temporal (ver 009),
--    y nunca puede mover los libros.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.validar_rol_permiso() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.rol = 'proveedor' THEN
    RAISE EXCEPTION 'PROHIBIDO: el rol proveedor no recibe permisos ("%"). Para soporte, el dueño da un acceso temporal.', NEW.permiso;
  END IF;
  IF NEW.permiso = 'soporte.otorgar' AND NEW.rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: solo el dueño puede dar acceso de soporte.';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER validar BEFORE INSERT OR UPDATE ON public.rol_permiso
  FOR EACH ROW EXECUTE FUNCTION interno.validar_rol_permiso();

-- ---------------------------------------------------------------------
-- 5) RPC: dar o quitar un permiso a un rol (tabla rol x permiso).
--    Exige motivo (mínimo 5 letras); queda en la bitácora.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.cambiar_permiso_rol(p_empresa_id uuid, p_rol text, p_permiso text,
                                           p_otorgar boolean, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'permisos.editar', NULL);

  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio de permisos (mínimo 5 letras).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rol WHERE codigo = p_rol) THEN
    RAISE EXCEPTION 'NO_EXISTE: el rol "%" no existe.', p_rol;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.permiso WHERE codigo = p_permiso) THEN
    RAISE EXCEPTION 'NO_EXISTE: el permiso "%" no existe.', p_permiso;
  END IF;
  IF p_otorgar IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si el permiso se da (true) o se quita (false).';
  END IF;
  -- Evita que el negocio se quede sin nadie que pueda editar permisos.
  IF p_rol = 'dueno' AND p_permiso = 'permisos.editar' AND NOT p_otorgar THEN
    RAISE EXCEPTION 'PROHIBIDO: no se le puede quitar al dueño el permiso de editar permisos.';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);   -- lo toma la bitácora
  IF p_otorgar THEN
    INSERT INTO public.rol_permiso (empresa_id, rol, permiso) VALUES (p_empresa_id, p_rol, p_permiso)
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.rol_permiso
     WHERE empresa_id = p_empresa_id AND rol = p_rol AND permiso = p_permiso;
  END IF;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('rol', p_rol, 'permiso', p_permiso, 'otorgado', p_otorgar);
END $$;

REVOKE EXECUTE ON FUNCTION public.cambiar_permiso_rol(uuid, text, text, boolean, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.cambiar_permiso_rol(uuid, text, text, boolean, text) TO authenticated;
