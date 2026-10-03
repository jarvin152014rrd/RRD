-- =====================================================================
-- 007_instalacion.sql  -  Crear una empresa lista para trabajar
-- La usa el proveedor con la llave service_role al instalar un cliente.
-- Crea: empresa, sucursal 001, caja 001 (punto de emisión 001),
-- dueño (y proveedor si se indica), permisos por defecto, módulo
-- contabilidad y catálogo de cuentas.
-- NO crea licencia: sin licencia la empresa queda en solo lectura
-- hasta que el proveedor la active (seguro por defecto).
-- =====================================================================

CREATE FUNCTION public.crear_empresa_inicial(
  p_nombre            text,
  p_rtn               text,
  p_dueno_user_id     uuid,
  p_proveedor_user_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_empresa  uuid;
  v_sucursal uuid;
BEGIN
  IF p_dueno_user_id IS NULL THEN
    RAISE EXCEPTION 'FALTA_DUENO: indique el usuario dueño.';
  END IF;

  INSERT INTO public.empresa (nombre, rtn) VALUES (trim(p_nombre), p_rtn)
  RETURNING id INTO v_empresa;

  INSERT INTO public.sucursal (empresa_id, codigo, nombre)
  VALUES (v_empresa, '001', 'Principal') RETURNING id INTO v_sucursal;

  INSERT INTO public.caja (empresa_id, sucursal_id, nombre, punto_emision)
  VALUES (v_empresa, v_sucursal, 'Caja principal', '001');

  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol)
  VALUES (p_dueno_user_id, v_empresa, 'dueno');
  IF p_proveedor_user_id IS NOT NULL THEN
    INSERT INTO public.usuario_empresa (user_id, empresa_id, rol)
    VALUES (p_proveedor_user_id, v_empresa, 'proveedor');
  END IF;

  INSERT INTO public.rol_permiso (empresa_id, rol, permiso)
  SELECT v_empresa, rol, permiso FROM interno.plantilla_rol_permiso;

  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (v_empresa, 'contabilidad');

  PERFORM interno.copiar_catalogo(v_empresa);

  RETURN v_empresa;
END $$;

REVOKE EXECUTE ON FUNCTION public.crear_empresa_inicial(text, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.crear_empresa_inicial(text, text, uuid, uuid) TO service_role;
