-- =====================================================================
-- 058_tienda_bodegas_datos_fiscales.sql  -  Núcleo 0.22.0
--
-- 1) Tienda y bodegas.
--    Cada bodega dice si se VENDE desde ahí ("tienda") o solo GUARDA mercadería
--    ("bodega"): columna bodega.vende. En cada sucursal hay a lo más UNA bodega
--    activa que vende; las ventas, los apartados y las ventas sin internet salen
--    de esa (antes: de la primera bodega por código, que es la que queda marcada).
--    - La primera bodega activa de una sucursal vende sola (también con la
--      crear_bodega de siempre). Si se desactiva la que vende, pasa a vender la
--      siguiente de la sucursal.
--    - Toda empresa nueva nace con su "Tienda principal" (crear_empresa_inicial;
--      la ficha puede traer "bodega_inicial": false para no crearla).
--    - Las empresas que ya existen y tienen una sucursal sin bodega reciben su
--      tienda aquí (era la causa de "Agotado" y de "Primero cree una bodega").
--    - guardar_bodega: crear una bodega o tienda (el código se pone solo) y
--      cambiarle el nombre o si vende.
-- 2) Datos fiscales editables por el dueño: configurar_datos_fiscales (nombre
--    legal y RTN, con motivo y en la bitácora). Las facturas ya emitidas no
--    cambian (guardan su copia). Como el CAI lo da el SAR para un RTN, si el RTN
--    cambia y hay rangos de CAI activos, hay que confirmarlo y esos rangos se
--    desactivan (se pide un CAI nuevo para el RTN nuevo).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('CAI_ACTIVO', 'Hay rangos de CAI activos para el RTN actual.',
   'El CAI es para un RTN. Si cambia el RTN, confirme que se desactiven los rangos y pida un CAI nuevo al SAR.'),
  ('ACTUALIZACION_INCOMPLETA', 'La base no tiene lo que esta actualización espera encontrar.',
   'No se cambió nada. Revise que tenga instalada la versión anterior completa y avise a su proveedor.')
ON CONFLICT (codigo) DO NOTHING;

-- ---------------------------------------------------------------------
-- 1) bodega.vende
-- ---------------------------------------------------------------------
ALTER TABLE public.bodega ADD COLUMN vende boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.bodega.vende IS
  'true = tienda: las ventas de la sucursal salen de aquí (una sola activa por sucursal). false = solo guarda.';

-- El protector de catálogo solo dejaba cambiar nombre y activa; la bodega además "vende".
DROP TRIGGER proteger ON public.bodega;
CREATE FUNCTION interno.proteger_bodega() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF to_jsonb(NEW) - 'activa' - 'nombre' - 'vende' IS DISTINCT FROM to_jsonb(OLD) - 'activa' - 'nombre' - 'vende' THEN
    RAISE EXCEPTION 'PROHIBIDO: de una bodega solo se puede cambiar el nombre, si vende o desactivarla.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.bodega FOR EACH ROW EXECUTE FUNCTION interno.proteger_bodega();

-- Marca la que vende en cada sucursal: la primera activa por código (la que ya usaban las ventas).
UPDATE public.bodega b SET vende = true
 WHERE b.id IN (SELECT DISTINCT ON (x.sucursal_id) x.id FROM public.bodega x WHERE x.activa
                 ORDER BY x.sucursal_id, x.codigo);

CREATE UNIQUE INDEX bodega_una_tienda ON public.bodega (sucursal_id) WHERE vende AND activa;

-- Al crear: vende si la sucursal todavía no tiene tienda. Al reactivar una que vendía
-- y ya hay otra tienda activa: queda como bodega.
CREATE FUNCTION interno.bodega_vende_antes() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.vende := NEW.activa AND NOT EXISTS (SELECT 1 FROM public.bodega x
      WHERE x.sucursal_id = NEW.sucursal_id AND x.activa AND x.vende);
  ELSIF NEW.activa AND NOT OLD.activa AND NEW.vende AND EXISTS (SELECT 1 FROM public.bodega x
      WHERE x.sucursal_id = NEW.sucursal_id AND x.activa AND x.vende AND x.id <> NEW.id) THEN
    NEW.vende := false;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER vende_antes BEFORE INSERT OR UPDATE OF activa ON public.bodega
  FOR EACH ROW EXECUTE FUNCTION interno.bodega_vende_antes();

-- Si se desactiva la tienda, vende la siguiente bodega activa de la sucursal (si hay).
CREATE FUNCTION interno.bodega_vende_despues() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF OLD.activa AND NOT NEW.activa AND OLD.vende THEN
    UPDATE public.bodega b SET vende = true
     WHERE b.id = (SELECT x.id FROM public.bodega x WHERE x.sucursal_id = NEW.sucursal_id AND x.activa
                    ORDER BY x.codigo LIMIT 1)
       AND NOT EXISTS (SELECT 1 FROM public.bodega x WHERE x.sucursal_id = NEW.sucursal_id AND x.activa AND x.vende);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER vende_despues AFTER UPDATE OF activa ON public.bodega
  FOR EACH ROW EXECUTE FUNCTION interno.bodega_vende_despues();

-- Las ventas, apartados y ventas sin internet tomaban "la primera bodega activa de la
-- sucursal"; ahora toman la que vende. Se cambia SOLO esa línea en las 4 funciones
-- que siguen en uso (el resto del texto queda igual), y se revisa que haya cambiado
-- exactamente una vez en cada una.
DO $parche$
DECLARE
  f     text;
  v_def text;
  v_new text;
BEGIN
  FOREACH f IN ARRAY ARRAY['interno.registrar_venta_base', 'interno.crear_apartado_038', 'interno.vsi_registrar',
                           'public.preparar_sin_internet'] LOOP
    v_def := pg_catalog.pg_get_functiondef(f::regproc);
    IF (SELECT count(*) FROM regexp_matches(v_def, 'AND b\.activa(\s+ORDER BY b\.codigo LIMIT 1)', 'g')) <> 1 THEN
      RAISE EXCEPTION 'ACTUALIZACION_INCOMPLETA: % no tiene exactamente una "primera bodega" para cambiar.', f;
    END IF;
    v_new := regexp_replace(v_def, 'AND b\.activa(\s+ORDER BY b\.codigo LIMIT 1)', 'AND b.activa AND b.vende\1');
    EXECUTE v_new;
  END LOOP;
END $parche$;

-- Sucursales activas sin bodega activa: reciben su tienda (código T + sucursal, ej. T001).
CREATE FUNCTION interno.codigo_bodega_libre(p_empresa_id uuid, p_base text) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE
  v_cod text := p_base;
  n     integer := 1;
BEGIN
  WHILE EXISTS (SELECT 1 FROM public.bodega b WHERE b.empresa_id = p_empresa_id AND b.codigo = v_cod) LOOP
    n := n + 1;
    v_cod := left(p_base, 7) || '-' || n;
  END LOOP;
  RETURN v_cod;
END $$;

INSERT INTO public.bodega (empresa_id, sucursal_id, codigo, nombre)
SELECT s.empresa_id, s.id, interno.codigo_bodega_libre(s.empresa_id, 'T' || s.codigo),
       CASE WHEN s.codigo = '001' THEN 'Tienda principal' ELSE 'Tienda ' || s.nombre END
  FROM public.sucursal s
 WHERE s.activa AND NOT EXISTS (SELECT 1 FROM public.bodega b WHERE b.sucursal_id = s.id AND b.activa);

-- ---------------------------------------------------------------------
-- Empresa nueva: con su "Tienda principal" en la sucursal 001.
-- ---------------------------------------------------------------------
ALTER FUNCTION public.crear_empresa_inicial(jsonb) SET SCHEMA interno;
ALTER FUNCTION interno.crear_empresa_inicial(jsonb) RENAME TO crear_empresa_inicial_057;

CREATE FUNCTION public.crear_empresa_inicial(p_ficha jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_empresa uuid;
  v_tienda  boolean := true;
BEGIN
  IF jsonb_typeof(p_ficha) = 'object' AND p_ficha ? 'bodega_inicial' THEN
    IF jsonb_typeof(p_ficha->'bodega_inicial') <> 'boolean' THEN
      RAISE EXCEPTION 'FICHA_INVALIDA: "bodega_inicial" debe ser true o false.';
    END IF;
    v_tienda := (p_ficha->>'bodega_inicial')::boolean;
    p_ficha := p_ficha - 'bodega_inicial';
  END IF;
  v_empresa := interno.crear_empresa_inicial_057(p_ficha);
  IF v_tienda THEN
    INSERT INTO public.bodega (empresa_id, sucursal_id, codigo, nombre)
    SELECT v_empresa, s.id, 'T001', 'Tienda principal'
      FROM public.sucursal s WHERE s.empresa_id = v_empresa AND s.codigo = '001';
  END IF;
  RETURN v_empresa;
END $$;

-- ---------------------------------------------------------------------
-- guardar_bodega(empresa, datos, motivo)
--   Crear:  {"sucursal_id", "nombre", "vende"?}       (motivo no hace falta)
--   Editar: {"bodega_id", "nombre"?, "vende"?}        (motivo de 5 letras o más)
--   vende = true la vuelve LA tienda de su sucursal (la anterior pasa a solo guardar).
--   vende = false: solo si la sucursal no tiene cajas activas o tiene otra tienda
--   (si no, las ventas no tendrían de dónde salir).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.guardar_bodega(p_empresa_id uuid, p_datos jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k        text;
  v_b      public.bodega;
  v_suc    uuid;
  v_nombre text;
  v_vende  boolean;
  v_nueva  boolean := NOT (p_datos ? 'bodega_id');
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'bodegas.administrar', 'inventario');
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_datos) LOOP
    IF k NOT IN ('bodega_id', 'sucursal_id', 'nombre', 'vende') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
    END IF;
  END LOOP;
  IF p_datos ? 'nombre' THEN
    v_nombre := trim(coalesce(p_datos->>'nombre', ''));
    IF length(v_nombre) NOT BETWEEN 2 AND 60 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el nombre de la bodega lleva de 2 a 60 letras.';
    END IF;
  END IF;
  IF p_datos ? 'vende' THEN
    IF jsonb_typeof(p_datos->'vende') <> 'boolean' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "vende" es true o false.';
    END IF;
    v_vende := (p_datos->>'vende')::boolean;
  END IF;

  IF v_nueva THEN
    IF v_nombre IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la bodega.';
    END IF;
    v_suc := interno.json_uuid(p_datos->'sucursal_id', 'sucursal_id');
    IF NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = v_suc AND s.empresa_id = p_empresa_id AND s.activa) THEN
      RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal no existe en esta empresa o está desactivada.';
    END IF;
    IF NOT interno.sucursal_permitida(p_empresa_id, v_suc) THEN
      RAISE EXCEPTION 'SUCURSAL_NO_PERMITIDA: no tiene permiso en esa sucursal.';
    END IF;
    PERFORM 1 FROM public.sucursal s WHERE s.id = v_suc FOR UPDATE;   -- dos a la vez en la misma sucursal
    INSERT INTO public.bodega (empresa_id, sucursal_id, codigo, nombre)
    VALUES (p_empresa_id, v_suc, interno.codigo_bodega_libre(p_empresa_id,
              'B' || lpad(((SELECT count(*) FROM public.bodega b WHERE b.empresa_id = p_empresa_id) + 1)::text, 2, '0')),
            v_nombre)
    RETURNING * INTO v_b;
  ELSE
    IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
      RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
    END IF;
    SELECT * INTO v_b FROM public.bodega b
     WHERE b.id = interno.json_uuid(p_datos->'bodega_id', 'bodega_id') AND b.empresa_id = p_empresa_id;
    IF v_b.id IS NULL THEN
      RAISE EXCEPTION 'NO_EXISTE: la bodega no existe en esta empresa.';
    END IF;
    IF NOT interno.sucursal_permitida(p_empresa_id, v_b.sucursal_id) THEN
      RAISE EXCEPTION 'SUCURSAL_NO_PERMITIDA: no tiene permiso en esa sucursal.';
    END IF;
    PERFORM 1 FROM public.sucursal s WHERE s.id = v_b.sucursal_id FOR UPDATE;
    SELECT * INTO v_b FROM public.bodega b WHERE b.id = v_b.id;
    IF NOT v_b.activa AND v_vende IS NOT NULL THEN
      RAISE EXCEPTION 'NO_PERMITIDO: la bodega está desactivada; reactívela primero.';
    END IF;
    PERFORM set_config('app.motivo', trim(p_motivo), true);
    IF v_nombre IS NOT NULL AND v_nombre <> v_b.nombre THEN
      UPDATE public.bodega SET nombre = v_nombre WHERE id = v_b.id;
    END IF;
  END IF;

  -- Vender desde aquí / solo guardar.
  IF v_vende IS TRUE THEN
    UPDATE public.bodega SET vende = false
     WHERE sucursal_id = v_b.sucursal_id AND activa AND vende AND id <> v_b.id;
    UPDATE public.bodega SET vende = true WHERE id = v_b.id AND NOT vende;
  ELSIF v_vende IS FALSE THEN
    SELECT * INTO v_b FROM public.bodega b WHERE b.id = v_b.id;
    IF v_b.vende AND EXISTS (SELECT 1 FROM public.caja c WHERE c.sucursal_id = v_b.sucursal_id AND c.activa) THEN
      RAISE EXCEPTION 'NO_PERMITIDO: las cajas de esta sucursal venden desde aquí. Marque primero otra bodega como tienda.';
    END IF;
    UPDATE public.bodega SET vende = false WHERE id = v_b.id AND vende;
  END IF;
  PERFORM set_config('app.motivo', '', true);

  SELECT * INTO v_b FROM public.bodega b WHERE b.id = v_b.id;
  RETURN jsonb_build_object('bodega_id', v_b.id, 'codigo', v_b.codigo, 'nombre', v_b.nombre,
    'sucursal_id', v_b.sucursal_id, 'vende', v_b.vende, 'activa', v_b.activa, 'nueva', v_nueva);
END $$;

-- ---------------------------------------------------------------------
-- 2) configurar_datos_fiscales(empresa, datos, motivo)  -  solo el dueño
--   {"nombre": "...", "rtn": "08011999000001" | null, "desactivar_cai": true?}
--   El RTN se acepta con o sin guiones. Si cambia el RTN y hay rangos de CAI
--   activos: sin "desactivar_cai": true no se cambia nada (CAI_ACTIVO); con él,
--   los rangos se desactivan con el mismo motivo.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.configurar_datos_fiscales(p_empresa_id uuid, p_datos jsonb, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k        text;
  e        public.empresa;
  v_nombre text;
  v_rtn    text;
  v_cai    integer := 0;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'empresa.configurar', NULL);
  IF public.mi_rol(p_empresa_id) IS DISTINCT FROM 'dueno' THEN
    RAISE EXCEPTION 'SIN_PERMISO: solo el dueño cambia el nombre legal y el RTN.';
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  IF jsonb_typeof(p_datos) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los datos deben ser un objeto JSON.';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_datos) LOOP
    IF k NOT IN ('nombre', 'rtn', 'desactivar_cai') THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el campo "%" no se reconoce.', k;
    END IF;
  END LOOP;
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id FOR UPDATE;

  v_nombre := e.nombre;
  IF p_datos ? 'nombre' THEN
    v_nombre := trim(coalesce(p_datos->>'nombre', ''));
    IF length(v_nombre) NOT BETWEEN 2 AND 120 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: el nombre legal lleva de 2 a 120 letras.';
    END IF;
  END IF;
  v_rtn := e.rtn;
  IF p_datos ? 'rtn' THEN
    IF p_datos->'rtn' = 'null'::jsonb OR trim(p_datos->>'rtn') = '' THEN
      v_rtn := NULL;
    ELSE
      v_rtn := regexp_replace(p_datos->>'rtn', '[\s-]', '', 'g');
      IF v_rtn !~ '^[0-9]{14}$' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el RTN son 14 números (con o sin guiones).';
      END IF;
    END IF;
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  IF v_rtn IS DISTINCT FROM e.rtn THEN
    SELECT count(*) INTO v_cai FROM public.cai_rango r WHERE r.empresa_id = p_empresa_id AND r.activo;
    IF v_cai > 0 THEN
      IF coalesce(p_datos->'desactivar_cai', 'false'::jsonb) <> 'true'::jsonb THEN
        RAISE EXCEPTION 'CAI_ACTIVO: hay % rango(s) de CAI activos para el RTN actual; al cambiar el RTN se desactivan y debe pedir un CAI nuevo al SAR.', v_cai;
      END IF;
      PERFORM interno.bloquear_libros(p_empresa_id);
      UPDATE public.cai_rango SET activo = false WHERE empresa_id = p_empresa_id AND activo;
    END IF;
  END IF;
  UPDATE public.empresa SET nombre = v_nombre, rtn = v_rtn
   WHERE id = p_empresa_id AND (nombre, rtn) IS DISTINCT FROM (v_nombre, v_rtn);
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('nombre', v_nombre, 'rtn', v_rtn,
    'cai_desactivados', CASE WHEN v_rtn IS DISTINCT FROM e.rtn THEN v_cai ELSE 0 END);
END $$;

-- ---------------------------------------------------------------------
-- Permisos de ejecución
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION interno.proteger_bodega(), interno.bodega_vende_antes(), interno.bodega_vende_despues(),
  interno.codigo_bodega_libre(uuid, text), interno.crear_empresa_inicial_057(jsonb)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.crear_empresa_inicial(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crear_empresa_inicial(jsonb) TO service_role;
REVOKE EXECUTE ON FUNCTION public.guardar_bodega(uuid, jsonb, text), public.configurar_datos_fiscales(uuid, jsonb, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_bodega(uuid, jsonb, text), public.configurar_datos_fiscales(uuid, jsonb, text)
TO authenticated;
