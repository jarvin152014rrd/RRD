-- =====================================================================
-- 007_instalacion.sql  -  Crear una empresa lista para trabajar
-- La usa el proveedor con la llave service_role al instalar un cliente
-- (normalmente con herramientas/nuevo_cliente.sh).
--
-- Recibe la FICHA del cliente en jsonb (ver personal/ficha.schema.json):
--   {
--     "nombre": "Ferretería El Martillo",          obligatorio
--     "rtn": "08011999000001",                      opcional, 14 dígitos
--     "rubro": "Ferretería",                         opcional
--     "moneda": "HNL",                               ISO 4217, defecto HNL
--     "pais": "HN",                                  ISO 3166-1, defecto HN
--     "zona_horaria": "America/Tegucigalpa",         defecto America/Tegucigalpa
--     "fecha_inicio": "2026-01-01",                  obligatorio, AAAA-MM-DD
--     "dias_futuro_max": 3,                          0 a 31, defecto 3
--     "modulos": ["contabilidad"],                   contabilidad siempre va
--     "dueno":     {"correo": "...", "nombre": "..."}  o {"user_id": "..."}
--     "proveedor": {"correo": "..."}                 opcional
--     "tema": {...}                                  lo usa la app; aquí se ignora
--   }
-- El dueño (y el proveedor) deben existir ya como usuarios (auth.users).
--
-- Crea: empresa, sucursal 001, caja 001 (punto de emisión 001), dueño
-- (y proveedor), permisos por defecto, módulos y catálogo de cuentas.
-- NO crea licencia: sin licencia la empresa queda en solo lectura
-- hasta que el proveedor la active (seguro por defecto).
-- =====================================================================

-- Busca un usuario de la ficha ({"user_id"} o {"correo"}). Lanza error si no existe.
CREATE FUNCTION interno.usuario_de_ficha(p_dato jsonb, p_campo text) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  IF jsonb_typeof(p_dato) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "%" debe ser un objeto con "correo" o "user_id".', p_campo;
  END IF;
  IF p_dato ? 'user_id' THEN
    IF NOT (p_dato->>'user_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'FICHA_INVALIDA: "%.user_id" no es un uuid válido.', p_campo;
    END IF;
    SELECT u.id INTO v_id FROM auth.users u WHERE u.id = (p_dato->>'user_id')::uuid;
  ELSIF p_dato ? 'correo' THEN
    SELECT u.id INTO v_id FROM auth.users u WHERE lower(u.email) = lower(trim(p_dato->>'correo'));
  ELSE
    RAISE EXCEPTION 'FICHA_INVALIDA: "%" necesita "correo" o "user_id".', p_campo;
  END IF;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'USUARIO_NO_EXISTE: el usuario de "%" (%) no está registrado. Créelo primero en Supabase (Authentication).',
      p_campo, coalesce(p_dato->>'correo', p_dato->>'user_id');
  END IF;
  RETURN v_id;
END $$;

-- Revisa la ficha completa. Lanza FICHA_INVALIDA diciendo qué campo falla.
CREATE FUNCTION interno.validar_ficha(f jsonb) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k       text;
  v_fecha date;
  c_permitidos constant text[] := ARRAY['$schema','nombre','rtn','rubro','moneda','pais','zona_horaria',
    'fecha_inicio','dias_futuro_max','modulos','dueno','proveedor','tema'];
BEGIN
  IF jsonb_typeof(f) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: la ficha debe ser un objeto JSON.';
  END IF;
  FOR k IN SELECT jsonb_object_keys(f) LOOP
    IF NOT k = ANY (c_permitidos) THEN
      RAISE EXCEPTION 'FICHA_INVALIDA: el campo "%" no se reconoce (¿está bien escrito?).', k;
    END IF;
  END LOOP;

  IF jsonb_typeof(f->'nombre') IS DISTINCT FROM 'string' OR length(trim(f->>'nombre')) = 0 THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: falta "nombre" (nombre del negocio).';
  END IF;
  IF f ? 'rtn' AND f->'rtn' <> 'null' AND NOT coalesce(f->>'rtn' ~ '^[0-9]{14}$', false) THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "rtn" debe tener 14 dígitos, sin guiones.';
  END IF;
  IF f ? 'moneda' AND NOT coalesce(f->>'moneda' ~ '^[A-Z]{3}$', false) THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "moneda" debe ser un código ISO 4217 de 3 letras mayúsculas (ej. HNL).';
  END IF;
  IF f ? 'pais' AND NOT coalesce(f->>'pais' ~ '^[A-Z]{2}$', false) THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "pais" debe ser un código ISO 3166 de 2 letras mayúsculas (ej. HN).';
  END IF;
  IF f ? 'zona_horaria' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names z
                                         WHERE z.name = f->>'zona_horaria') THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "zona_horaria" no existe (ej. America/Tegucigalpa).';
  END IF;
  IF NOT coalesce(f->>'fecha_inicio' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$', false) THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "fecha_inicio" es obligatoria con formato AAAA-MM-DD (ej. 2026-01-01).';
  END IF;
  BEGIN
    v_fecha := (f->>'fecha_inicio')::date;
  EXCEPTION WHEN OTHERS THEN
    v_fecha := NULL;                      -- ej. 2026-02-30
  END;
  IF v_fecha IS NULL OR v_fecha NOT BETWEEN '2000-01-01' AND '2100-12-31' THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "fecha_inicio" no es una fecha válida entre 2000 y 2100.';
  END IF;
  IF f ? 'dias_futuro_max' AND NOT (jsonb_typeof(f->'dias_futuro_max') = 'number'
       AND (f->>'dias_futuro_max') ~ '^[0-9]+$' AND (f->>'dias_futuro_max')::integer BETWEEN 0 AND 31) THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "dias_futuro_max" debe ser un número entero de 0 a 31.';
  END IF;
  IF f ? 'rubro' AND jsonb_typeof(f->'rubro') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "rubro" debe ser texto.';
  END IF;
  IF f ? 'modulos' THEN
    IF jsonb_typeof(f->'modulos') <> 'array' THEN
      RAISE EXCEPTION 'FICHA_INVALIDA: "modulos" debe ser una lista, ej. ["contabilidad"].';
    END IF;
    FOR k IN SELECT jsonb_array_elements_text(f->'modulos') LOOP
      IF NOT EXISTS (SELECT 1 FROM public.modulo m WHERE m.codigo = k) THEN
        RAISE EXCEPTION 'FICHA_INVALIDA: el módulo "%" no existe.', k;
      END IF;
    END LOOP;
  END IF;
  IF NOT f ? 'dueno' THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: falta "dueno" (correo o user_id del dueño).';
  END IF;
  IF jsonb_typeof(f->'dueno') = 'object' AND f->'dueno' ? 'nombre'
     AND jsonb_typeof(f->'dueno'->'nombre') <> 'string' THEN
    RAISE EXCEPTION 'FICHA_INVALIDA: "dueno.nombre" debe ser texto.';
  END IF;
END $$;

CREATE FUNCTION public.crear_empresa_inicial(p_ficha jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_empresa   uuid;
  v_sucursal  uuid;
  v_dueno     uuid;
  v_proveedor uuid;
BEGIN
  PERFORM interno.validar_ficha(p_ficha);
  v_dueno := interno.usuario_de_ficha(p_ficha->'dueno', 'dueno');
  IF p_ficha ? 'proveedor' AND p_ficha->'proveedor' <> 'null' THEN
    v_proveedor := interno.usuario_de_ficha(p_ficha->'proveedor', 'proveedor');
    IF v_proveedor = v_dueno THEN
      RAISE EXCEPTION 'FICHA_INVALIDA: el dueño y el proveedor no pueden ser el mismo usuario.';
    END IF;
  END IF;

  INSERT INTO public.empresa (nombre, rtn, rubro, moneda, pais, zona_horaria, fecha_inicio, dias_futuro_max)
  VALUES (trim(p_ficha->>'nombre'),
          nullif(p_ficha->>'rtn', ''),
          nullif(trim(p_ficha->>'rubro'), ''),
          coalesce(p_ficha->>'moneda', 'HNL'),
          coalesce(p_ficha->>'pais', 'HN'),
          coalesce(p_ficha->>'zona_horaria', 'America/Tegucigalpa'),
          (p_ficha->>'fecha_inicio')::date,
          coalesce((p_ficha->>'dias_futuro_max')::integer, 3))
  RETURNING id INTO v_empresa;

  INSERT INTO public.sucursal (empresa_id, codigo, nombre)
  VALUES (v_empresa, '001', 'Principal') RETURNING id INTO v_sucursal;

  INSERT INTO public.caja (empresa_id, sucursal_id, nombre, punto_emision)
  VALUES (v_empresa, v_sucursal, 'Caja principal', '001');

  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol, nombre)
  VALUES (v_dueno, v_empresa, 'dueno', nullif(trim(p_ficha->'dueno'->>'nombre'), ''));
  IF v_proveedor IS NOT NULL THEN
    INSERT INTO public.usuario_empresa (user_id, empresa_id, rol, nombre)
    VALUES (v_proveedor, v_empresa, 'proveedor', nullif(trim(p_ficha->'proveedor'->>'nombre'), ''));
  END IF;

  INSERT INTO public.rol_permiso (empresa_id, rol, permiso)
  SELECT v_empresa, rol, permiso FROM interno.plantilla_rol_permiso;

  -- Contabilidad siempre; los demás según la ficha.
  INSERT INTO public.modulo_activo (empresa_id, modulo)
  SELECT v_empresa, m FROM (
    SELECT 'contabilidad' AS m
    UNION
    SELECT jsonb_array_elements_text(coalesce(p_ficha->'modulos', '[]'))) x;

  PERFORM interno.copiar_catalogo(v_empresa);

  RETURN v_empresa;
END $$;

REVOKE EXECUTE ON FUNCTION public.crear_empresa_inicial(jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.crear_empresa_inicial(jsonb) TO service_role;
