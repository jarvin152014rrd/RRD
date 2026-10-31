-- =====================================================================
-- 010_administracion.sql  -  Perfil del usuario y tareas de administración
--
--   mi_perfil()                  quién soy, empresa, rol, permisos, módulos,
--                                licencia (la app arma el menú con esto)
--   agregar_usuario_empresa      agrega (o reactiva / cambia rol) un usuario
--   desactivar_usuario_empresa   lo desactiva (nunca se borra)
--   crear_sucursal / desactivar_sucursal
--   crear_caja / desactivar_caja (con punto de emisión SAR)
--   crear_subcuenta              subcuenta de detalle bajo una cuenta existente
--
-- Todas revisan sesión, empresa, permiso y licencia, y quedan en bitácora.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('ULTIMA_SUCURSAL', 'Es la única sucursal activa.', 'Cree o active otra sucursal antes de desactivar esta.');

-- ---------------------------------------------------------------------
-- mi_perfil: si el usuario tiene varias empresas y no indica una,
-- "empresa" viene en null y la app muestra la lista "empresas" para elegir.
-- Fechas en ISO 8601.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.mi_perfil(p_empresa_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_emp      public.empresa;
  v_ue       public.usuario_empresa;
  v_empresas jsonb;
  v_soporte  timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre, 'rol', ue.rol)
                            ORDER BY e.nombre), '[]')
    INTO v_empresas
    FROM public.usuario_empresa ue JOIN public.empresa e ON e.id = ue.empresa_id
   WHERE ue.user_id = v_uid AND ue.activo;

  IF p_empresa_id IS NOT NULL AND public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  SELECT * INTO v_emp FROM public.empresa WHERE id = coalesce(p_empresa_id, public.empresa_actual());

  IF v_emp.id IS NULL THEN
    RETURN jsonb_build_object(
      'usuario',  jsonb_build_object('id', v_uid, 'correo', (SELECT u.email FROM auth.users u WHERE u.id = v_uid)),
      'empresas', v_empresas,
      'empresa',  NULL);
  END IF;

  SELECT * INTO v_ue FROM public.usuario_empresa
   WHERE user_id = v_uid AND empresa_id = v_emp.id AND activo;

  SELECT max(s.vence_en) INTO v_soporte FROM public.acceso_soporte s
   WHERE s.empresa_id = v_emp.id AND s.revocado_en IS NULL AND now() BETWEEN s.desde AND s.vence_en;

  RETURN jsonb_build_object(
    'usuario', jsonb_build_object(
        'id', v_uid,
        'correo', (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
        'nombre', v_ue.nombre),
    'empresas', v_empresas,
    'empresa', jsonb_build_object(
        'id', v_emp.id, 'nombre', v_emp.nombre, 'rtn', v_emp.rtn, 'rubro', v_emp.rubro,
        'moneda', v_emp.moneda, 'pais', v_emp.pais, 'zona_horaria', v_emp.zona_horaria,
        'fecha_inicio', to_char(v_emp.fecha_inicio, 'YYYY-MM-DD'),
        'dias_futuro_max', v_emp.dias_futuro_max,
        'hoy', to_char(public.hoy_local(v_emp.id), 'YYYY-MM-DD')),
    'rol', jsonb_build_object('codigo', v_ue.rol,
                              'nombre', (SELECT r.nombre FROM public.rol r WHERE r.codigo = v_ue.rol)),
    'permisos', (SELECT coalesce(jsonb_agg(p.codigo ORDER BY p.codigo), '[]')
                   FROM public.permiso p WHERE public.tiene_permiso(p.codigo, v_emp.id)),
    'modulos',  (SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]')
                   FROM public.modulo_activo m WHERE m.empresa_id = v_emp.id AND m.activo),
    'licencia', interno.estado_licencia(v_emp.id),
    'soporte_vigente_hasta', public.iso(v_soporte),
    'hora_servidor', public.iso(now()));
END $$;

-- ---------------------------------------------------------------------
-- Usuarios
-- ---------------------------------------------------------------------
CREATE FUNCTION public.agregar_usuario_empresa(p_empresa_id uuid, p_correo text, p_rol text,
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

  UPDATE public.usuario_empresa
     SET rol = p_rol, activo = true, nombre = coalesce(nullif(trim(p_nombre), ''), nombre)
   WHERE id = v_ue.id;
  RETURN jsonb_build_object('usuario_id', v_user, 'rol', p_rol, 'nuevo', false);
END $$;

-- Funciona aunque la licencia esté vencida (es una acción de seguridad).
CREATE FUNCTION public.desactivar_usuario_empresa(p_empresa_id uuid, p_user_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ue public.usuario_empresa;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'usuarios.administrar', NULL, false);
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
  IF v_ue.rol = 'dueno' AND public.mi_rol(p_empresa_id) <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: solo un dueño puede desactivar a otro dueño.';
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
-- Sucursales y cajas
-- ---------------------------------------------------------------------
CREATE FUNCTION public.crear_sucursal(p_empresa_id uuid, p_codigo text, p_nombre text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF NOT coalesce(p_codigo ~ '^[0-9]{3}$', false) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el código de sucursal (establecimiento SAR) son 3 dígitos, ej. 002.';
  END IF;
  IF length(trim(coalesce(p_nombre, ''))) = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la sucursal.';
  END IF;
  BEGIN
    INSERT INTO public.sucursal (empresa_id, codigo, nombre)
    VALUES (p_empresa_id, p_codigo, trim(p_nombre)) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay una sucursal con el código %.', p_codigo;
  END;
  RETURN jsonb_build_object('sucursal_id', v_id, 'codigo', p_codigo);
END $$;

-- Desactiva la sucursal y sus cajas. No deja a la empresa sin sucursal activa.
CREATE FUNCTION public.desactivar_sucursal(p_empresa_id uuid, p_sucursal_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_suc   public.sucursal;
  v_cajas integer;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva la sucursal (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_suc FROM public.sucursal
   WHERE id = p_sucursal_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_suc.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la sucursal no existe en esta empresa.';
  END IF;
  IF NOT v_suc.activa THEN
    RETURN jsonb_build_object('sucursal_id', p_sucursal_id, 'activa', false, 'ya_estaba', true);
  END IF;
  -- Bloquea las sucursales de la empresa para que dos personas no
  -- desactiven "la penúltima" al mismo tiempo.
  PERFORM 1 FROM public.sucursal WHERE empresa_id = p_empresa_id FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM public.sucursal
                  WHERE empresa_id = p_empresa_id AND activa AND id <> p_sucursal_id) THEN
    RAISE EXCEPTION 'ULTIMA_SUCURSAL: es la única sucursal activa; cree o active otra antes.';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.sucursal SET activa = false WHERE id = p_sucursal_id;
  UPDATE public.caja SET activa = false WHERE sucursal_id = p_sucursal_id AND activa;
  GET DIAGNOSTICS v_cajas = ROW_COUNT;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('sucursal_id', p_sucursal_id, 'activa', false, 'ya_estaba', false,
                            'cajas_desactivadas', v_cajas);
END $$;

CREATE FUNCTION public.crear_caja(p_empresa_id uuid, p_sucursal_id uuid, p_nombre text, p_punto_emision text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF NOT EXISTS (SELECT 1 FROM public.sucursal
                  WHERE id = p_sucursal_id AND empresa_id = p_empresa_id AND activa) THEN
    RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal no existe en esta empresa o está desactivada.';
  END IF;
  IF NOT coalesce(p_punto_emision ~ '^[0-9]{3}$', false) THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el punto de emisión son 3 dígitos, ej. 002.';
  END IF;
  IF length(trim(coalesce(p_nombre, ''))) = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la caja.';
  END IF;
  BEGIN
    INSERT INTO public.caja (empresa_id, sucursal_id, nombre, punto_emision)
    VALUES (p_empresa_id, p_sucursal_id, trim(p_nombre), p_punto_emision) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: esa sucursal ya tiene una caja con el punto de emisión %.', p_punto_emision;
  END;
  RETURN jsonb_build_object('caja_id', v_id, 'punto_emision', p_punto_emision);
END $$;

CREATE FUNCTION public.desactivar_caja(p_empresa_id uuid, p_caja_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_caja public.caja;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva la caja (mínimo 5 letras).';
  END IF;
  SELECT * INTO v_caja FROM public.caja WHERE id = p_caja_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_caja.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la caja no existe en esta empresa.';
  END IF;
  IF NOT v_caja.activa THEN
    RETURN jsonb_build_object('caja_id', p_caja_id, 'activa', false, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.caja SET activa = false WHERE id = p_caja_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('caja_id', p_caja_id, 'activa', false, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- Catálogo: subcuenta DE DETALLE bajo una cuenta de agrupación existente.
-- El código es el de la madre + un nivel: 6.1.02 -> 6.1.02.11
-- Tipo igual al de la madre; naturaleza la de la madre salvo que se
-- indique (para cuentas "contra", ej. depreciación acumulada).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.crear_subcuenta(p_empresa_id uuid, p_codigo_madre text, p_codigo text,
                                       p_nombre text, p_naturaleza text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_madre public.cuenta;
  v_id    uuid;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'catalogo.editar');

  SELECT * INTO v_madre FROM public.cuenta WHERE empresa_id = p_empresa_id AND codigo = p_codigo_madre;
  IF v_madre.id IS NULL THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta madre "%" no existe.', p_codigo_madre;
  END IF;
  IF v_madre.es_detalle THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta % (%) es de detalle; las subcuentas van bajo una cuenta de agrupación.',
      v_madre.codigo, v_madre.nombre;
  END IF;
  IF NOT v_madre.activa THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta madre % está desactivada.', v_madre.codigo;
  END IF;
  IF NOT coalesce(p_codigo ~ ('^' || replace(v_madre.codigo, '.', '\.') || '\.[0-9]{1,3}$'), false) THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: el código debe ser el de la madre más un número, ej. %.99', v_madre.codigo;
  END IF;
  IF length(trim(coalesce(p_nombre, ''))) = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la cuenta.';
  END IF;
  IF p_naturaleza IS NOT NULL AND p_naturaleza NOT IN ('deudora', 'acreedora') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: la naturaleza es "deudora" o "acreedora".';
  END IF;

  BEGIN
    INSERT INTO public.cuenta (empresa_id, codigo, nombre, tipo, naturaleza, padre_id, es_detalle)
    VALUES (p_empresa_id, p_codigo, trim(p_nombre), v_madre.tipo,
            coalesce(p_naturaleza, v_madre.naturaleza), v_madre.id, true)
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya existe la cuenta %.', p_codigo;
  END;
  RETURN jsonb_build_object('cuenta_id', v_id, 'codigo', p_codigo);
END $$;

-- ---------------------------------------------------------------------
-- Permisos de ejecución
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  public.mi_perfil(uuid),
  public.agregar_usuario_empresa(uuid, text, text, text),
  public.desactivar_usuario_empresa(uuid, uuid, text),
  public.crear_sucursal(uuid, text, text),
  public.desactivar_sucursal(uuid, uuid, text),
  public.crear_caja(uuid, uuid, text, text),
  public.desactivar_caja(uuid, uuid, text),
  public.crear_subcuenta(uuid, text, text, text, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.mi_perfil(uuid),
  public.agregar_usuario_empresa(uuid, text, text, text),
  public.desactivar_usuario_empresa(uuid, uuid, text),
  public.crear_sucursal(uuid, text, text),
  public.desactivar_sucursal(uuid, uuid, text),
  public.crear_caja(uuid, uuid, text, text),
  public.desactivar_caja(uuid, uuid, text),
  public.crear_subcuenta(uuid, text, text, text, text)
TO authenticated;
