-- =====================================================================
-- 012_roles_admin.sql  -  Lo que puede el administrador y lo que es
-- SOLO del dueño (decisión del dueño, etapa 2a). Configuración de empresa.
--
-- * El admin, por defecto: agrega y desactiva usuarios CAJERO y VENDEDOR
--   (crear o desactivar administradores y dueños es solo del dueño; nunca
--   toca al proveedor ni da un rol con permisos que él no tiene), crea y
--   desactiva sucursales y cajas. (Bodegas, catálogos,
--   terceros y precios se le dan en 013-016.)
-- * SOLO del dueño (ni el dueño se los puede dar a otro rol):
--   permisos.editar, periodos.reabrir, soporte.otorgar, empresa.configurar.
-- * configurar_empresa: el dueño fija el tope de límite de crédito que el
--   admin puede dar a un cliente y si se permite existencia negativa.
-- * interno.repartir_permisos: da a las empresas YA instaladas los
--   permisos nuevos según la plantilla (lo usan 012-016).
-- Contraseñas: viven en Supabase Auth, no aquí (ver nucleo/docs/usuarios.md).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('TOPE_CREDITO', 'El límite de crédito pasa el tope que fijó el dueño.',
   'Ponga un límite menor o pida al dueño que lo autorice (o que suba el tope).');

-- ---------------------------------------------------------------------
-- Configuración de la empresa (columnas nuevas, con valor seguro por defecto)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa
  -- Máximo límite de crédito (centavos) que alguien que no es dueño puede
  -- dar a un cliente. 0 = solo el dueño da crédito.
  ADD COLUMN tope_credito_centavos bigint NOT NULL DEFAULT 0
    CHECK (tope_credito_centavos BETWEEN 0 AND 9007199254740991),
  -- true = el inventario puede quedar en negativo (queda alerta). Ver 015.
  ADD COLUMN permite_existencia_negativa boolean NOT NULL DEFAULT false;

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('empresa.configurar', 'Cambiar la configuración del negocio (tope de crédito, inventario negativo)', false, false);

INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'empresa.configurar'),
  ('admin', 'usuarios.administrar'),
  ('admin', 'sucursales.administrar');

-- ---------------------------------------------------------------------
-- Reparte permisos nuevos a las empresas ya instaladas, según la plantilla.
-- Solo agrega (si el dueño ya lo tenía, no cambia nada). Queda en bitácora.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.repartir_permisos(p_permisos text[], p_motivo text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_n integer;
BEGIN
  PERFORM set_config('app.motivo', p_motivo, true);
  INSERT INTO public.rol_permiso (empresa_id, rol, permiso)
  SELECT e.id, p.rol, p.permiso
    FROM public.empresa e
    JOIN interno.plantilla_rol_permiso p ON p.permiso = ANY (p_permisos)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('app.motivo', '', true);
  RETURN v_n;
END $$;

SELECT interno.repartir_permisos(ARRAY['empresa.configurar', 'usuarios.administrar', 'sucursales.administrar'],
  'Núcleo 0.3.0: el admin administra usuarios y sucursales; configuración del dueño');

-- ---------------------------------------------------------------------
-- Permisos que SOLO puede tener el dueño. Reemplaza la regla de 006.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.validar_rol_permiso() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.rol = 'proveedor' THEN
    RAISE EXCEPTION 'PROHIBIDO: el rol proveedor no recibe permisos ("%"). Para soporte, el dueño da un acceso temporal.', NEW.permiso;
  END IF;
  IF NEW.permiso IN ('soporte.otorgar', 'permisos.editar', 'periodos.reabrir', 'empresa.configurar')
     AND NEW.rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: el permiso "%" es solo del dueño.', NEW.permiso;
  END IF;
  RETURN NEW;
END $$;

-- ¿El rol p_rol tiene algún permiso que p_mi_rol no tiene? (en esta empresa)
CREATE FUNCTION interno.rol_supera(p_empresa_id uuid, p_rol text, p_mi_rol text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.rol_permiso o
     WHERE o.empresa_id = p_empresa_id AND o.rol = p_rol
       AND NOT EXISTS (SELECT 1 FROM public.rol_permiso m
                        WHERE m.empresa_id = p_empresa_id AND m.rol = p_mi_rol AND m.permiso = o.permiso))
$$;

-- ---------------------------------------------------------------------
-- agregar_usuario_empresa (reemplaza la de 010; misma firma).
-- Nuevo: quien no es dueño solo da los puestos cajero o vendedor, y no
-- da un rol con permisos que él no tiene, ni toca a alguien cuyo rol sea
-- otro o tenga permisos que él no tiene.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.agregar_usuario_empresa(p_empresa_id uuid, p_correo text, p_rol text,
                                                          p_nombre text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_user  uuid;
  v_ue    public.usuario_empresa;
  v_yo    text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'usuarios.administrar', NULL);
  v_yo := public.mi_rol(p_empresa_id);

  IF NOT EXISTS (SELECT 1 FROM public.rol WHERE codigo = p_rol) THEN
    RAISE EXCEPTION 'NO_EXISTE: el rol "%" no existe.', p_rol;
  END IF;
  IF p_rol = 'proveedor' THEN
    RAISE EXCEPTION 'PROHIBIDO: el rol proveedor solo se asigna al instalar.';
  END IF;
  IF p_rol = 'dueno' AND v_yo <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: solo un dueño puede nombrar a otro dueño.';
  END IF;
  IF v_yo <> 'dueno' AND p_rol NOT IN ('cajero', 'vendedor') THEN
    RAISE EXCEPTION 'PROHIBIDO: solo el dueño crea administradores; usted puede dar los puestos cajero o vendedor.';
  END IF;
  IF v_yo <> 'dueno' AND interno.rol_supera(p_empresa_id, p_rol, v_yo) THEN
    RAISE EXCEPTION 'PROHIBIDO: el rol "%" tiene permisos que usted no tiene; solo el dueño puede asignarlo.', p_rol;
  END IF;

  SELECT u.id INTO v_user FROM auth.users u WHERE lower(u.email) = lower(trim(coalesce(p_correo, '')));
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'USUARIO_NO_EXISTE: no hay ninguna cuenta con el correo "%". Pídale que se registre primero.', p_correo;
  END IF;
  IF v_user = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede cambiar su propio usuario.';
  END IF;

  SELECT * INTO v_ue FROM public.usuario_empresa WHERE user_id = v_user AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_ue.id IS NULL THEN
    INSERT INTO public.usuario_empresa (user_id, empresa_id, rol, nombre)
    VALUES (v_user, p_empresa_id, p_rol, nullif(trim(p_nombre), ''));
    RETURN jsonb_build_object('usuario_id', v_user, 'rol', p_rol, 'nuevo', true);
  END IF;

  IF v_ue.rol = 'proveedor' THEN
    RAISE EXCEPTION 'PROHIBIDO: el usuario del proveedor no cambia de rol.';
  END IF;
  IF v_ue.rol = 'dueno' AND v_yo <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: solo un dueño puede cambiar a otro dueño.';
  END IF;
  IF v_yo <> 'dueno' AND v_ue.rol NOT IN ('cajero', 'vendedor') THEN
    RAISE EXCEPTION 'PROHIBIDO: solo el dueño cambia a un administrador.';
  END IF;
  IF v_yo <> 'dueno' AND interno.rol_supera(p_empresa_id, v_ue.rol, v_yo) THEN
    RAISE EXCEPTION 'PROHIBIDO: ese usuario tiene un rol con permisos que usted no tiene; solo el dueño puede cambiarlo.';
  END IF;

  UPDATE public.usuario_empresa
     SET rol = p_rol, activo = true, nombre = coalesce(nullif(trim(p_nombre), ''), nombre)
   WHERE id = v_ue.id;
  RETURN jsonb_build_object('usuario_id', v_user, 'rol', p_rol, 'nuevo', false);
END $$;

-- desactivar_usuario_empresa (reemplaza la de 010; misma firma).
-- Nuevo: quien no es dueño solo desactiva cajeros y vendedores (y no a
-- quien tenga permisos que él no tiene); nunca al proveedor.
CREATE OR REPLACE FUNCTION public.desactivar_usuario_empresa(p_empresa_id uuid, p_user_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ue public.usuario_empresa;
  v_yo text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'usuarios.administrar', NULL, false);
  v_yo := public.mi_rol(p_empresa_id);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva al usuario (mínimo 5 letras).';
  END IF;

  SELECT * INTO v_ue FROM public.usuario_empresa
   WHERE user_id = p_user_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_ue.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: ese usuario no está en esta empresa.';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'PROHIBIDO: no puede desactivarse a sí mismo.';
  END IF;
  IF v_ue.rol = 'dueno' AND v_yo <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: solo un dueño puede desactivar a otro dueño.';
  END IF;
  IF v_ue.rol = 'proveedor' AND v_yo <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: solo el dueño puede desactivar al usuario del proveedor.';
  END IF;
  IF v_yo <> 'dueno' AND v_ue.rol NOT IN ('cajero', 'vendedor') THEN
    RAISE EXCEPTION 'PROHIBIDO: solo el dueño desactiva a un administrador.';
  END IF;
  IF v_yo <> 'dueno' AND interno.rol_supera(p_empresa_id, v_ue.rol, v_yo) THEN
    RAISE EXCEPTION 'PROHIBIDO: ese usuario tiene un rol con permisos que usted no tiene; solo el dueño puede desactivarlo.';
  END IF;
  IF NOT v_ue.activo THEN
    RETURN jsonb_build_object('usuario_id', p_user_id, 'activo', false, 'ya_estaba', true);
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.usuario_empresa SET activo = false WHERE id = v_ue.id;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('usuario_id', p_user_id, 'activo', false, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: configurar_empresa (solo dueño). Cambia solo las claves enviadas:
--   {"tope_credito_centavos": 500000, "permite_existencia_negativa": false}
-- ---------------------------------------------------------------------
CREATE FUNCTION public.configurar_empresa(p_empresa_id uuid, p_datos jsonb, p_motivo text)
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
    IF k NOT IN ('tope_credito_centavos', 'permite_existencia_negativa') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'tope_credito_centavos' AND NOT (jsonb_typeof(p_datos->'tope_credito_centavos') = 'number'
       AND (p_datos->>'tope_credito_centavos') ~ '^[0-9]{1,16}$'
       AND (p_datos->>'tope_credito_centavos')::numeric <= 9007199254740991) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "tope_credito_centavos" debe ser un entero de centavos, 0 o más.';
  END IF;
  IF p_datos ? 'permite_existencia_negativa' AND jsonb_typeof(p_datos->'permite_existencia_negativa') <> 'boolean' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: "permite_existencia_negativa" debe ser true o false.';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET
    tope_credito_centavos = coalesce((p_datos->>'tope_credito_centavos')::bigint, tope_credito_centavos),
    permite_existencia_negativa = coalesce((p_datos->>'permite_existencia_negativa')::boolean, permite_existencia_negativa)
  WHERE id = p_empresa_id
  RETURNING * INTO v_emp;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('tope_credito_centavos', v_emp.tope_credito_centavos,
                            'permite_existencia_negativa', v_emp.permite_existencia_negativa);
END $$;

REVOKE EXECUTE ON FUNCTION
  public.configurar_empresa(uuid, jsonb, text),
  interno.repartir_permisos(text[], text),
  interno.rol_supera(uuid, text, text)
FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.configurar_empresa(uuid, jsonb, text) TO authenticated;
