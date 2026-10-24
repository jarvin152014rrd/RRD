-- =====================================================================
-- 053_fotos_productos.sql  -  Núcleo 0.17.0: fotos livianas de productos.
-- Las 001-052 no se tocan.
--
--   1) Interruptor por empresa: empresa.fotos_productos (APAGADO por defecto).
--      Lo cambia el dueño (activar_fotos_productos) o la ficha del cliente
--      ("opciones": {"fotos_productos": true}; Armador / aplicar_ficha).
--      mi_perfil lo devuelve en "empresa" para que la app sepa si mostrar fotos.
--   2) El producto guarda la RUTA de su foto (no la imagen): foto_ruta (unos
--      600 px) y foto_miniatura_ruta (unos 120 px), dentro de la carpeta
--      <empresa_id>/<producto_id>/ del bucket privado "fotos-productos".
--      poner_foto_producto(empresa, producto, {"ruta","miniatura"} | null,
--      id_operacion): con productos.editar, bitácora e historial
--      (producto_foto: nunca se borra; cada cambio queda con la foto anterior).
--      v_producto devuelve las dos rutas.
--   3) Supabase Storage: bucket privado "fotos-productos" (solo WEBP o JPEG,
--      hasta 1 MB) y sus políticas en storage.objects:
--        leer:                  usuarios de esa empresa (con fotos encendidas)
--        subir / cambiar:       quien tiene productos.editar en esa empresa
--                               (con fotos encendidas; ruta de un producto suyo)
--        borrar:                quien tiene productos.editar en esa empresa
--      Si la base no tiene Storage (no es Supabase) o el rol no puede crear el
--      bucket o las políticas, la migración NO falla: estado_fotos_storage()
--      dice qué falta (verificar_instalacion.sql lo muestra) y docs/SUPABASE.md
--      explica los clics.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Interruptor por empresa (apagado por defecto: nada cambia hasta que
--    el dueño lo enciende)
-- ---------------------------------------------------------------------
ALTER TABLE public.empresa ADD COLUMN fotos_productos boolean NOT NULL DEFAULT false;

-- RPC: activar_fotos_productos(empresa, activo, motivo)   empresa.configurar (solo dueño)
CREATE FUNCTION public.activar_fotos_productos(p_empresa_id uuid, p_activo boolean, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF p_activo IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: indique si se encienden (true) o se apagan (false) las fotos de productos.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.empresa SET fotos_productos = p_activo WHERE id = p_empresa_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('fotos_productos', p_activo, 'storage', public.estado_fotos_storage());
END $$;

-- ---------------------------------------------------------------------
-- 2) Ruta de la foto en el producto
--    <empresa_id>/<producto_id>/<nombre>.webp|jpg (nombre: letras, números,
--    guion y guion bajo). La app usa la huella del archivo como nombre.
-- ---------------------------------------------------------------------
ALTER TABLE public.producto
  ADD COLUMN foto_ruta           text,
  ADD COLUMN foto_miniatura_ruta text,
  ADD CONSTRAINT producto_foto_par CHECK ((foto_ruta IS NULL) = (foto_miniatura_ruta IS NULL)),
  ADD CONSTRAINT producto_foto_ruta CHECK (
    foto_ruta IS NULL OR (
      foto_ruta ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[a-z0-9_-]{8,80}\.(webp|jpg)$'
      AND foto_miniatura_ruta ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[a-z0-9_-]{8,80}\.(webp|jpg)$'
      AND split_part(foto_ruta, '/', 1) = empresa_id::text AND split_part(foto_ruta, '/', 2) = id::text
      AND split_part(foto_miniatura_ruta, '/', 1) = empresa_id::text AND split_part(foto_miniatura_ruta, '/', 2) = id::text
      AND foto_ruta <> foto_miniatura_ruta));

-- ¿Esta ruta de Storage es de una foto válida de un producto de su empresa?
-- (la usan la política de subir de storage.objects y poner_foto_producto)
CREATE FUNCTION public.ruta_foto_producto_valida(p_ruta text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(p_ruta ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[a-z0-9_-]{8,80}\.(webp|jpg)$', false)
     AND EXISTS (SELECT 1 FROM public.producto p
                  WHERE p.empresa_id::text = split_part(p_ruta, '/', 1) AND p.id::text = split_part(p_ruta, '/', 2))
$$;

-- Historial de fotos: solo agregar (la foto anterior queda anotada).
CREATE TABLE public.producto_foto (
  id                           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                   uuid NOT NULL,
  producto_id                  uuid NOT NULL,
  foto_ruta                    text,          -- NULL = se quitó la foto
  foto_miniatura_ruta          text,
  anterior_foto_ruta           text,
  anterior_foto_miniatura_ruta text,
  id_operacion                 uuid NOT NULL,
  creado_por                   uuid,
  creado_en                    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id)
);
CREATE INDEX producto_foto_producto ON public.producto_foto (producto_id, creado_en);
CREATE TRIGGER proteger BEFORE UPDATE ON public.producto_foto
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El historial de fotos no se edita.');
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.producto_foto
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.producto_foto
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El historial de fotos no se borra.');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.producto_foto
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
ALTER TABLE public.producto_foto ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.producto_foto FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.producto_foto TO authenticated, service_role;
CREATE POLICY leer ON public.producto_foto FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()));

INSERT INTO interno.id_operacion_uso (tabla, columna, tipo, orden) VALUES
  ('producto_foto', 'id_operacion', 'foto_producto', 94);

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('FOTOS_APAGADAS', 'Las fotos de productos están apagadas en este negocio.',
   'El dueño las enciende en Ajustes > Mi negocio > Fotos de productos.'),
  ('FOTO_INVALIDA', 'La foto no es válida para este producto.',
   'Vuelva a elegir la foto desde la pantalla del producto (la app la prepara sola).');

CREATE FUNCTION interno.foto_respuesta(f public.producto_foto, p_duplicado boolean) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('producto_id', f.producto_id, 'foto_ruta', f.foto_ruta,
    'foto_miniatura_ruta', f.foto_miniatura_ruta, 'anterior_foto_ruta', f.anterior_foto_ruta,
    'quitada', f.foto_ruta IS NULL, 'historial_id', f.id, 'duplicado', p_duplicado)
$$;

-- RPC: poner_foto_producto(empresa, producto, {"ruta","miniatura"} | null, id_operacion)   productos.editar
--   null = quitar la foto. Poner o cambiar exige las fotos encendidas; quitar se puede siempre.
--   Los archivos los sube la app ANTES a Storage (bucket fotos-productos); aquí solo se guarda la ruta.
CREATE FUNCTION public.poner_foto_producto(p_empresa_id uuid, p_producto_id uuid, p_foto jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f        public.producto_foto;
  p        public.producto;
  v_quitar boolean := p_foto IS NULL OR p_foto = 'null'::jsonb;
  v_ruta   text;
  v_mini   text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'foto_producto');
  SELECT * INTO f FROM public.producto_foto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF f.id IS NOT NULL THEN
    RETURN interno.foto_respuesta(f, true);
  END IF;
  SELECT * INTO p FROM public.producto x WHERE x.id = p_producto_id AND x.empresa_id = p_empresa_id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el producto no existe en esta empresa.';
  END IF;
  IF v_quitar THEN
    IF p.foto_ruta IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el producto no tiene foto.';
    END IF;
  ELSE
    IF NOT (SELECT e.fotos_productos FROM public.empresa e WHERE e.id = p_empresa_id) THEN
      RAISE EXCEPTION 'FOTOS_APAGADAS: las fotos de productos están apagadas; el dueño las enciende en Ajustes > Mi negocio.';
    END IF;
    IF jsonb_typeof(p_foto) <> 'object' THEN
      RAISE EXCEPTION 'FOTO_INVALIDA: la foto va como {"ruta": ..., "miniatura": ...} o null para quitarla.';
    END IF;
    PERFORM interno.exigir_claves(p_foto, ARRAY['ruta', 'miniatura']);
    v_ruta := p_foto->>'ruta';
    v_mini := p_foto->>'miniatura';
    IF jsonb_typeof(p_foto->'ruta') IS DISTINCT FROM 'string' OR jsonb_typeof(p_foto->'miniatura') IS DISTINCT FROM 'string'
       OR v_ruta = v_mini
       OR split_part(v_ruta, '/', 1) <> p_empresa_id::text OR split_part(v_ruta, '/', 2) <> p_producto_id::text
       OR split_part(v_mini, '/', 1) <> p_empresa_id::text OR split_part(v_mini, '/', 2) <> p_producto_id::text
       OR NOT public.ruta_foto_producto_valida(v_ruta) OR NOT public.ruta_foto_producto_valida(v_mini) THEN
      RAISE EXCEPTION 'FOTO_INVALIDA: la ruta debe ser <empresa>/<producto>/<nombre>.webp o .jpg, de este producto, y la miniatura otra distinta.';
    END IF;
  END IF;

  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'foto_producto');
  SELECT * INTO f FROM public.producto_foto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF f.id IS NOT NULL THEN
    RETURN interno.foto_respuesta(f, true);
  END IF;
  SELECT * INTO p FROM public.producto x WHERE x.id = p_producto_id AND x.empresa_id = p_empresa_id FOR UPDATE;
  PERFORM set_config('app.motivo', CASE WHEN v_quitar THEN 'Quitar la foto del producto' ELSE 'Poner o cambiar la foto del producto' END, true);
  INSERT INTO public.producto_foto (empresa_id, producto_id, foto_ruta, foto_miniatura_ruta, anterior_foto_ruta,
                                    anterior_foto_miniatura_ruta, id_operacion, creado_por)
  VALUES (p_empresa_id, p.id, v_ruta, v_mini, p.foto_ruta, p.foto_miniatura_ruta, p_id_operacion, auth.uid())
  RETURNING * INTO f;
  UPDATE public.producto SET foto_ruta = v_ruta, foto_miniatura_ruta = v_mini WHERE id = p.id;
  PERFORM set_config('app.motivo', '', true);
  RETURN interno.foto_respuesta(f, false);
END $$;

-- v_producto (reemplaza la de 026: mismas columnas y al final las dos rutas de la foto).
CREATE OR REPLACE VIEW public.v_producto WITH (security_invoker = true) AS
  SELECT p.empresa_id, p.id AS producto_id, p.codigo, p.codigo_barras, p.nombre,
         p.categoria_id, c.nombre AS categoria, p.unidad_id, u.codigo AS unidad,
         p.tipo_impuesto, p.precio_venta_centavos, p.precio_incluye_isv,
         x.sin_isv_centavos AS precio_sin_isv_centavos, x.isv_centavos, x.con_isv_centavos AS precio_con_isv_centavos,
         p.stock_minimo, p.permite_fracciones, p.activo, p.campos_extra, p.actualizado_en,
         p.tipo, i.nombre AS impuesto, i.porcentaje AS impuesto_porcentaje, i.clase AS impuesto_clase,
         sc.costo_estimado_centavos,
         p.foto_ruta, p.foto_miniatura_ruta
  FROM public.producto p
  JOIN public.unidad u ON u.id = p.unidad_id
  JOIN public.impuesto i ON i.empresa_id = p.empresa_id AND i.codigo = p.tipo_impuesto
  LEFT JOIN public.categoria_producto c ON c.id = p.categoria_id
  LEFT JOIN public.servicio_costo sc ON sc.producto_id = p.id      -- sin inventario.costos: vacío (RLS)
  CROSS JOIN LATERAL public.precio_con_tasa(p.precio_venta_centavos, p.precio_incluye_isv, i.porcentaje) x;

-- ---------------------------------------------------------------------
-- 3) Supabase Storage: ayudantes para las políticas (se calculan UNA vez por
--    consulta con ARRAY(SELECT ...)) y estado de la instalación.
-- ---------------------------------------------------------------------
-- Empresas (como texto: la primera carpeta de la ruta) donde el usuario conectado puede:
--   'leer'   -> pertenece a la empresa y las fotos están encendidas
--   'subir'  -> tiene productos.editar y las fotos están encendidas (también cambiar)
--   'borrar' -> tiene productos.editar (aunque las fotos estén apagadas: limpiar)
CREATE FUNCTION public.empresas_fotos_productos(p_accion text) RETURNS SETOF text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT e.id::text FROM public.empresa e
   WHERE (p_accion = 'leer' AND e.fotos_productos AND e.id IN (SELECT public.mis_empresas()))
      OR (p_accion = 'subir' AND e.fotos_productos AND e.id IN (SELECT public.empresas_con_permiso('productos.editar')))
      OR (p_accion = 'borrar' AND e.id IN (SELECT public.empresas_con_permiso('productos.editar')))
$$;

-- ¿Quedó listo Storage para las fotos? (bucket privado y las 4 políticas)
-- Lo muestran verificar_instalacion.sql y Ajustes > Mi negocio (al dueño).
CREATE FUNCTION public.estado_fotos_storage() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_bucket  jsonb;
  v_faltan  text[] := '{}';
  v_nombre  text;
BEGIN
  IF to_regclass('storage.buckets') IS NULL OR to_regclass('storage.objects') IS NULL THEN
    RETURN jsonb_build_object('listo', false, 'storage', false, 'texto', 'FALTA: esta base no tiene Supabase Storage.');
  END IF;
  EXECUTE 'SELECT to_jsonb(b) FROM storage.buckets b WHERE b.id = $1' INTO v_bucket USING 'fotos-productos';
  FOREACH v_nombre IN ARRAY ARRAY['fotos_productos_leer', 'fotos_productos_subir', 'fotos_productos_cambiar', 'fotos_productos_borrar'] LOOP
    -- El panel de Supabase agrega un sufijo al nombre de la política (ej. "fotos_productos_leer 1a2b_0").
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies x WHERE x.schemaname = 'storage' AND x.tablename = 'objects'
                    AND x.policyname LIKE v_nombre || '%') THEN
      v_faltan := v_faltan || v_nombre;
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'storage', true,
    'bucket', v_bucket IS NOT NULL,
    'privado', v_bucket IS NOT NULL AND NOT coalesce((v_bucket->>'public')::boolean, false),
    'politicas_faltan', to_jsonb(v_faltan),
    'listo', v_bucket IS NOT NULL AND NOT coalesce((v_bucket->>'public')::boolean, false) AND cardinality(v_faltan) = 0,
    'texto', CASE
      WHEN v_bucket IS NULL THEN 'FALTA: crear el bucket fotos-productos (docs/SUPABASE.md, Fotos de productos).'
      WHEN coalesce((v_bucket->>'public')::boolean, false) THEN 'FALTA: el bucket fotos-productos debe ser PRIVADO (apague "Public bucket").'
      WHEN cardinality(v_faltan) > 0 THEN 'FALTA: crear las políticas ' || array_to_string(v_faltan, ', ') || ' (docs/SUPABASE.md, Fotos de productos).'
      ELSE 'LISTO' END);
END $$;

-- Bucket y políticas. Solo si la base tiene Storage (Supabase). Si el rol que
-- instala no puede (permisos de Supabase), se avisa y se sigue: la migración
-- no falla y estado_fotos_storage() dice qué falta.
DO $storage$
DECLARE v_pol text;
BEGIN
  IF to_regclass('storage.buckets') IS NULL OR to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'Fotos de productos: esta base no tiene Supabase Storage; no se crea el bucket.';
    RETURN;
  END IF;
  BEGIN
    -- Privado, solo WEBP o JPEG, hasta 1 MB (la app manda unos 40 KB).
    EXECUTE $b$
      INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
      VALUES ('fotos-productos', 'fotos-productos', false, 1048576, ARRAY['image/webp', 'image/jpeg'])
      ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 1048576,
                                     allowed_mime_types = ARRAY['image/webp', 'image/jpeg']
    $b$;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Fotos de productos: no se pudo crear el bucket por SQL (%). Créelo con clics (docs/SUPABASE.md).', SQLERRM;
  END;
  BEGIN
    -- Si ya estaban (con este mismo nombre), se reemplazan.
    FOR v_pol IN SELECT x.policyname FROM pg_catalog.pg_policies x WHERE x.schemaname = 'storage' AND x.tablename = 'objects'
                  AND x.policyname IN ('fotos_productos_leer', 'fotos_productos_subir', 'fotos_productos_cambiar', 'fotos_productos_borrar') LOOP
      EXECUTE format('DROP POLICY %I ON storage.objects', v_pol);
    END LOOP;
    EXECUTE $p$
      CREATE POLICY fotos_productos_leer ON storage.objects FOR SELECT TO authenticated
        USING (bucket_id = 'fotos-productos'
               AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('leer'))));
      CREATE POLICY fotos_productos_subir ON storage.objects FOR INSERT TO authenticated
        WITH CHECK (bucket_id = 'fotos-productos'
                    AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir')))
                    AND public.ruta_foto_producto_valida(name));
      CREATE POLICY fotos_productos_cambiar ON storage.objects FOR UPDATE TO authenticated
        USING (bucket_id = 'fotos-productos'
               AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir'))))
        WITH CHECK (bucket_id = 'fotos-productos'
                    AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir')))
                    AND public.ruta_foto_producto_valida(name));
      CREATE POLICY fotos_productos_borrar ON storage.objects FOR DELETE TO authenticated
        USING (bucket_id = 'fotos-productos'
               AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('borrar'))));
    $p$;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Fotos de productos: no se pudieron crear las políticas por SQL (%). Créelas con clics (docs/SUPABASE.md).', SQLERRM;
  END;
END $storage$;

-- ---------------------------------------------------------------------
-- 4) mi_perfil (reemplaza la de 032; misma firma). Nuevo: empresa.fotos_productos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mi_perfil(p_empresa_id uuid DEFAULT NULL)
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
        'hoy', to_char(public.hoy_local(v_emp.id), 'YYYY-MM-DD'),
        'perfil', v_emp.perfil,
        'turnos_obligatorios', v_emp.turnos_obligatorios,
        'contabilidad_visible', v_emp.contabilidad_visible,
        'doble_aprobacion', v_emp.doble_aprobacion,
        'vendedor_cobra', v_emp.vendedor_cobra,
        'fotos_productos', v_emp.fotos_productos),
    'rol', jsonb_build_object('codigo', v_ue.rol,
                              'nombre', (SELECT r.nombre FROM public.rol r WHERE r.codigo = v_ue.rol)),
    'permisos', (SELECT coalesce(jsonb_agg(p.codigo ORDER BY p.codigo), '[]')
                   FROM public.permiso p WHERE public.tiene_permiso(p.codigo, v_emp.id)),
    'modulos',  (SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]')
                   FROM public.modulo_activo m WHERE m.empresa_id = v_emp.id AND m.activo),
    'licencia', interno.estado_licencia(v_emp.id),
    'limites', interno.limites_y_uso(v_emp.id),
    'soporte_vigente_hasta', public.iso(v_soporte),
    'hora_servidor', public.iso(now()));
END $$;

-- ---------------------------------------------------------------------
-- 5) Ficha del cliente: "opciones": {"fotos_productos": true|false}
--    (reemplazan las de 032; misma firma; lo de antes sigue igual)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.cambios_ficha(p_empresa_id uuid, p_cambios jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e         public.empresa;
  l         public.licencia;
  k         text;
  v_final   text[];
  v_act     jsonb := '[]';
  v_des     jsonb := '[]';
  v_err     jsonb := '[]';
  v_lic     jsonb;
  v_perfil  jsonb;
  v_vence   date;
  v_gracia  integer;
  v_limact  jsonb := interno.limites_y_uso(p_empresa_id);
  v_lims    jsonb;
  v_limn    jsonb := '{}';
  v_opc     jsonb;
  v_opcn    jsonb := '{}';
  r         record;
BEGIN
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la empresa no existe en esta base.';
  END IF;
  IF jsonb_typeof(p_cambios) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los cambios deben ser un objeto JSON.';
  END IF;
  PERFORM interno.exigir_claves(p_cambios, ARRAY['modulos', 'perfil', 'licencia', 'limites', 'opciones']);

  -- Módulos: estado final = lo de hoy + lo que dice la ficha.
  SELECT coalesce(array_agg(m.modulo), '{}') INTO v_final FROM public.modulo_activo m WHERE m.empresa_id = p_empresa_id AND m.activo;
  IF coalesce(p_cambios->'modulos', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_cambios->'modulos') <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "modulos" es un objeto {"ventas": true, ...}.';
    END IF;
    FOR k IN SELECT jsonb_object_keys(p_cambios->'modulos') LOOP
      IF NOT EXISTS (SELECT 1 FROM public.modulo x WHERE x.codigo = k) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el módulo "%" no existe.', k;
      END IF;
      IF jsonb_typeof(p_cambios->'modulos'->k) <> 'boolean' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el módulo "%" va con true o false.', k;
      END IF;
      IF (p_cambios->'modulos'->>k)::boolean AND NOT k = ANY (v_final) THEN
        v_final := v_final || k;
      ELSIF NOT (p_cambios->'modulos'->>k)::boolean AND k = ANY (v_final) THEN
        v_final := array_remove(v_final, k);
      END IF;
    END LOOP;
    SELECT coalesce(jsonb_agg(m.codigo ORDER BY interno.nivel_modulo(m.codigo), m.codigo), '[]') INTO v_act
      FROM public.modulo m
     WHERE m.codigo = ANY (v_final) AND NOT public.modulo_esta_activo(p_empresa_id, m.codigo);
    SELECT coalesce(jsonb_agg(m.codigo ORDER BY interno.nivel_modulo(m.codigo) DESC, m.codigo), '[]') INTO v_des
      FROM public.modulo m
     WHERE NOT m.codigo = ANY (v_final) AND public.modulo_esta_activo(p_empresa_id, m.codigo);
    FOR r IN SELECT d.modulo, d.requiere FROM public.modulo_dependencia d
              WHERE d.modulo = ANY (v_final) AND NOT d.requiere = ANY (v_final) ORDER BY 1, 2 LOOP
      v_err := v_err || to_jsonb(format('El módulo "%s" necesita "%s": actívelo también o apague "%s".', r.modulo, r.requiere, r.modulo));
    END LOOP;
    IF (SELECT count(*) FROM unnest(v_final) x WHERE x LIKE 'fiscal\_%') > 1 THEN
      v_err := v_err || to_jsonb('Solo un régimen fiscal activo a la vez.'::text);
    END IF;
  END IF;

  -- Perfil.
  IF coalesce(p_cambios->'perfil', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_cambios->'perfil') <> 'string' THEN
      RAISE EXCEPTION 'PERFIL_INVALIDO: el perfil es pequeno, mediano o grande.';
    END IF;
    PERFORM interno.perfil_de(p_cambios->>'perfil');
    IF e.perfil IS DISTINCT FROM p_cambios->>'perfil' THEN
      v_perfil := jsonb_build_object('actual', e.perfil, 'nuevo', p_cambios->>'perfil',
        'detalle', interno.cambios_perfil(p_empresa_id, p_cambios->>'perfil'));
    END IF;
  END IF;

  -- Licencia.
  IF coalesce(p_cambios->'licencia', 'null'::jsonb) <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(p_cambios->'licencia', ARRAY['vence_el', 'dias_gracia']);
    v_vence := interno.json_fecha(p_cambios->'licencia'->'vence_el', 'vence_el');
    IF v_vence IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la licencia necesita "vence_el" (AAAA-MM-DD).';
    END IF;
    IF coalesce(p_cambios->'licencia'->'dias_gracia', 'null'::jsonb) <> 'null'::jsonb THEN
      IF jsonb_typeof(p_cambios->'licencia'->'dias_gracia') <> 'number'
         OR (p_cambios->'licencia'->>'dias_gracia') !~ '^[0-9]{1,2}$' OR (p_cambios->'licencia'->>'dias_gracia')::integer > 60 THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "dias_gracia" es un número entero de 0 a 60.';
      END IF;
      v_gracia := (p_cambios->'licencia'->>'dias_gracia')::integer;
    END IF;
    SELECT * INTO l FROM public.licencia x WHERE x.empresa_id = p_empresa_id;
    v_gracia := coalesce(v_gracia, l.dias_gracia, 5);
    IF (l.vence_el, l.dias_gracia) IS DISTINCT FROM (v_vence, v_gracia) THEN
      v_lic := jsonb_build_object('actual', CASE WHEN l.empresa_id IS NOT NULL THEN jsonb_build_object('vence_el', to_char(l.vence_el, 'YYYY-MM-DD'), 'dias_gracia', l.dias_gracia) END,
                                  'nuevo', jsonb_build_object('vence_el', to_char(v_vence, 'YYYY-MM-DD'), 'dias_gracia', v_gracia));
    END IF;
  END IF;

  -- Límites del contrato (lo que no viene no cambia; null = sin límite).
  IF coalesce(p_cambios->'limites', 'null'::jsonb) <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(p_cambios->'limites', ARRAY['usuarios', 'cajas', 'sucursales', 'bodegas']);
    FOR k IN SELECT jsonb_object_keys(p_cambios->'limites') LOOP
      IF p_cambios->'limites'->k <> 'null'::jsonb AND (jsonb_typeof(p_cambios->'limites'->k) <> 'number'
           OR (p_cambios->'limites'->>k) !~ '^[0-9]{1,6}$' OR (p_cambios->'limites'->>k)::integer > 100000) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el límite de "%" es un entero de 0 a 100000, o null (sin límite).', k;
      END IF;
      IF (v_limact->k->'limite') IS DISTINCT FROM (p_cambios->'limites'->k) THEN
        v_limn := v_limn || jsonb_build_object(k, jsonb_build_object('actual', v_limact->k->'limite', 'nuevo', p_cambios->'limites'->k,
          'uso', v_limact->k->'uso',
          'aviso', CASE WHEN p_cambios->'limites'->k <> 'null'::jsonb AND (v_limact->k->>'uso')::integer > (p_cambios->'limites'->>k)::integer
                        THEN 'Ya hay más que el límite nuevo: nada se desactiva; solo no se podrán agregar más.' END));
      END IF;
    END LOOP;
    IF v_limn <> '{}'::jsonb THEN
      v_lims := v_limn;
    END IF;
  END IF;

  -- Opciones (0.17.0): por ahora solo "fotos_productos" (sí/no). Lo que no viene no cambia.
  IF coalesce(p_cambios->'opciones', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_cambios->'opciones') <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "opciones" es un objeto {"fotos_productos": true}.';
    END IF;
    PERFORM interno.exigir_claves(p_cambios->'opciones', ARRAY['fotos_productos']);
    IF p_cambios->'opciones' ? 'fotos_productos' THEN
      IF jsonb_typeof(p_cambios->'opciones'->'fotos_productos') <> 'boolean' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "fotos_productos" va con true o false.';
      END IF;
      IF e.fotos_productos IS DISTINCT FROM (p_cambios->'opciones'->>'fotos_productos')::boolean THEN
        v_opcn := v_opcn || jsonb_build_object('fotos_productos', jsonb_build_object('actual', e.fotos_productos,
          'nuevo', (p_cambios->'opciones'->>'fotos_productos')::boolean));
      END IF;
    END IF;
    IF v_opcn <> '{}'::jsonb THEN
      v_opc := v_opcn;
    END IF;
  END IF;

  RETURN jsonb_build_object('empresa_id', e.id, 'empresa', e.nombre,
    'modulos', jsonb_build_object('activar', v_act, 'desactivar', v_des,
                                  'quedan_activos', (SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') FROM unnest(v_final) x)),
    'perfil', v_perfil, 'licencia', v_lic, 'limites', v_lims, 'limites_hoy', v_limact, 'opciones', v_opc,
    'opciones_hoy', jsonb_build_object('fotos_productos', e.fotos_productos), 'errores', v_err,
    'hay_cambios', jsonb_array_length(v_act) > 0 OR jsonb_array_length(v_des) > 0 OR v_perfil IS NOT NULL OR v_lic IS NOT NULL
                   OR v_lims IS NOT NULL OR v_opc IS NOT NULL);
END $$;

CREATE OR REPLACE FUNCTION public.aplicar_ficha(p_empresa_id uuid, p_cambios jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v  jsonb;
  m  text;
BEGIN
  PERFORM interno.exigir_proveedor_llave();
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM 1 FROM public.empresa e WHERE e.id = p_empresa_id FOR UPDATE;
  v := interno.cambios_ficha(p_empresa_id, p_cambios);
  IF jsonb_array_length(v->'errores') > 0 THEN
    RAISE EXCEPTION 'MODULO_DEPENDENCIA: %', (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(v->'errores') x);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  FOR m IN SELECT jsonb_array_elements_text(v->'modulos'->'desactivar') LOOP
    UPDATE public.modulo_activo SET activo = false WHERE empresa_id = p_empresa_id AND modulo = m;
  END LOOP;
  FOR m IN SELECT jsonb_array_elements_text(v->'modulos'->'activar') LOOP
    INSERT INTO public.modulo_activo (empresa_id, modulo, activo) VALUES (p_empresa_id, m, true)
    ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  END LOOP;
  IF v->'perfil' <> 'null'::jsonb THEN
    PERFORM interno.guardar_perfil(p_empresa_id, v->'perfil'->>'nuevo');
  END IF;
  IF v->'licencia' <> 'null'::jsonb THEN
    INSERT INTO public.licencia (empresa_id, vence_el, dias_gracia)
    VALUES (p_empresa_id, (v->'licencia'->'nuevo'->>'vence_el')::date, (v->'licencia'->'nuevo'->>'dias_gracia')::integer)
    ON CONFLICT (empresa_id) DO UPDATE SET vence_el = excluded.vence_el, dias_gracia = excluded.dias_gracia, actualizado_en = now();
  END IF;
  IF v->'limites' <> 'null'::jsonb THEN
    INSERT INTO public.limite_contrato (empresa_id, usuarios, cajas, sucursales, bodegas)
    SELECT p_empresa_id,
      CASE WHEN v->'limites' ? 'usuarios'   THEN (v->'limites'->'usuarios'->>'nuevo')::integer   ELSE l.usuarios END,
      CASE WHEN v->'limites' ? 'cajas'      THEN (v->'limites'->'cajas'->>'nuevo')::integer      ELSE l.cajas END,
      CASE WHEN v->'limites' ? 'sucursales' THEN (v->'limites'->'sucursales'->>'nuevo')::integer ELSE l.sucursales END,
      CASE WHEN v->'limites' ? 'bodegas'    THEN (v->'limites'->'bodegas'->>'nuevo')::integer    ELSE l.bodegas END
      FROM (SELECT 1) x LEFT JOIN public.limite_contrato l ON l.empresa_id = p_empresa_id
    ON CONFLICT (empresa_id) DO UPDATE SET usuarios = excluded.usuarios, cajas = excluded.cajas,
       sucursales = excluded.sucursales, bodegas = excluded.bodegas, actualizado_en = now();
  END IF;
  IF v->'opciones' <> 'null'::jsonb AND v->'opciones' ? 'fotos_productos' THEN
    UPDATE public.empresa SET fotos_productos = (v->'opciones'->'fotos_productos'->>'nuevo')::boolean WHERE id = p_empresa_id;
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN v || jsonb_build_object('aplicado', true);
END $$;

-- ---------------------------------------------------------------------
-- 6) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION interno.foto_respuesta(public.producto_foto, boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION
  public.activar_fotos_productos(uuid, boolean, text), public.poner_foto_producto(uuid, uuid, jsonb, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.activar_fotos_productos(uuid, boolean, text), public.poner_foto_producto(uuid, uuid, jsonb, uuid)
TO authenticated;
-- Las políticas de storage.objects corren como el usuario: necesita ejecutar los ayudantes.
REVOKE EXECUTE ON FUNCTION
  public.empresas_fotos_productos(text), public.ruta_foto_producto_valida(text), public.estado_fotos_storage()
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.empresas_fotos_productos(text), public.ruta_foto_producto_valida(text), public.estado_fotos_storage()
TO authenticated, service_role;
