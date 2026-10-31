-- =====================================================================
-- emulador_supabase.sql  -  SOLO PARA LA DEMO LOCAL DE LA APP.
-- Nunca se aplica en Supabase real (allá PostgREST hace este trabajo).
--
-- Dos funciones que usa herramientas/servidor_app.js para imitar a PostgREST:
--   emulador.rpc(fn, args)       llama public.<fn> con argumentos con nombre
--                                (como POST /rest/v1/rpc/<fn>)
--   emulador.leer(vista, filtros, orden, limite)
--                                lee una tabla o vista de public con filtros
--                                "igual a" (como GET /rest/v1/<vista>?col=eq.x)
-- Son SECURITY INVOKER: corren con el rol y el JWT que puso el servidor
-- (authenticated + request.jwt.claims), así RLS y permisos aplican igual.
-- Contra inyección: los nombres se validan contra el catálogo y se citan
-- con %I; los valores viajan como jsonb en un parámetro ($1), nunca pegados.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS emulador;
GRANT USAGE ON SCHEMA emulador TO anon, authenticated, service_role;   -- service_role: pruebas de las Edge Functions

CREATE OR REPLACE FUNCTION emulador.rpc(p_fn text, p_args jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  f        record;
  v_partes text[] := '{}';
  v_tipo   text;
  v_nombre text;
  v_sql    text;
  v_res    jsonb;
  i        int;
BEGIN
  p_args := coalesce(p_args, '{}'::jsonb);
  IF p_fn !~ '^[a-z_][a-z0-9_]{0,62}$' OR jsonb_typeof(p_args) <> 'object' THEN
    RAISE EXCEPTION 'PGRST202: función o argumentos no válidos';
  END IF;
  -- La función de public cuyos nombres de argumento cubren lo enviado
  -- (y que recibe todo lo que no tiene valor por defecto). Igual que PostgREST.
  FOR f IN
    SELECT p.oid, p.proretset, p.proargnames, p.proargtypes::oid[] AS tipos, p.pronargs, p.pronargdefaults,
           p.prorettype
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = p_fn
     ORDER BY p.pronargs DESC
  LOOP
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_args) k
                WHERE NOT k = ANY (coalesce(f.proargnames[1:f.pronargs], '{}'))) THEN
      CONTINUE;
    END IF;
    IF EXISTS (SELECT 1 FROM generate_series(1, f.pronargs - f.pronargdefaults) g
                WHERE NOT p_args ? f.proargnames[g]) THEN
      CONTINUE;
    END IF;
    FOR i IN 1 .. f.pronargs LOOP
      v_nombre := f.proargnames[i];
      CONTINUE WHEN NOT p_args ? v_nombre;
      v_tipo := format_type(f.tipos[i - 1], NULL);  -- oidvector empieza en 0
      IF v_tipo IN ('jsonb', 'json') THEN
        v_partes := v_partes || format('%I => ($1->%L)::%s', v_nombre, v_nombre, v_tipo);
      ELSE
        v_partes := v_partes || format('%I => ($1->>%L)::%s', v_nombre, v_nombre, v_tipo);
      END IF;
    END LOOP;
    IF f.proretset THEN
      v_sql := format('SELECT coalesce(jsonb_agg(to_jsonb(x)), ''[]'') FROM public.%I(%s) x', p_fn, array_to_string(v_partes, ', '));
    ELSIF f.prorettype = 'void'::regtype THEN
      v_sql := format('SELECT public.%I(%s), NULL::jsonb', p_fn, array_to_string(v_partes, ', '));
      EXECUTE v_sql USING p_args;
      RETURN NULL;
    ELSE
      v_sql := format('SELECT to_jsonb(public.%I(%s))', p_fn, array_to_string(v_partes, ', '));
    END IF;
    EXECUTE v_sql INTO v_res USING p_args;
    RETURN v_res;
  END LOOP;
  RAISE EXCEPTION 'PGRST202: no existe la función public.% con esos argumentos', p_fn;
END $$;

-- App 0.15.0: p_desde (offset de PostgREST, para leer por páginas) y orden por varias columnas ("a.asc,b.desc").
DROP FUNCTION IF EXISTS emulador.leer(text, jsonb, text, int);
CREATE OR REPLACE FUNCTION emulador.leer(p_vista text, p_filtros jsonb, p_orden text, p_limite int, p_desde int DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_rel   oid;
  v_where text[] := '{}';
  v_col   text;
  v_orden text := '';
  v_dir   text;
  v_res   jsonb;
  v_tipo  text;
  v_parte text;
  v_lista text[] := '{}';
BEGIN
  SELECT c.oid INTO v_rel FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = p_vista AND c.relkind IN ('r', 'v');
  IF v_rel IS NULL THEN
    RAISE EXCEPTION 'PGRST205: no existe la tabla o vista %', p_vista;
  END IF;
  FOR v_col IN SELECT jsonb_object_keys(coalesce(p_filtros, '{}')) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v_rel AND attname = v_col AND attnum > 0) THEN
      RAISE EXCEPTION 'PGRST100: columna desconocida %', v_col;
    END IF;
    IF jsonb_typeof(p_filtros->v_col) = 'object' THEN
      -- "mayor o igual" / "menor o igual" (gte. / lte. de PostgREST), comparado con el tipo de la columna.
      SELECT format_type(atttypid, atttypmod) INTO v_tipo FROM pg_attribute WHERE attrelid = v_rel AND attname = v_col AND attnum > 0;
      IF p_filtros->v_col ? 'gte' THEN v_where := v_where || format('%I >= ($1->%L->>''gte'')::%s', v_col, v_col, v_tipo); END IF;
      IF p_filtros->v_col ? 'lte' THEN v_where := v_where || format('%I <= ($1->%L->>''lte'')::%s', v_col, v_col, v_tipo); END IF;
      -- "uno de" (in.(a,b) de PostgREST)
      IF p_filtros->v_col ? 'in' THEN
        v_where := v_where || format('%I::text = ANY (ARRAY(SELECT jsonb_array_elements_text($1->%L->''in'')))', v_col, v_col);
      END IF;
    ELSE
      v_where := v_where || format('%I::text = ($1->>%L)', v_col, v_col);
    END IF;
  END LOOP;
  IF p_orden IS NOT NULL AND p_orden <> '' THEN
    FOREACH v_parte IN ARRAY string_to_array(p_orden, ',') LOOP
      v_col := split_part(v_parte, '.', 1);
      v_dir := CASE WHEN split_part(v_parte, '.', 2) = 'desc' THEN 'DESC' ELSE 'ASC' END;
      IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v_rel AND attname = v_col AND attnum > 0) THEN
        RAISE EXCEPTION 'PGRST100: columna desconocida %', v_col;
      END IF;
      v_lista := v_lista || format('%I %s', v_col, v_dir);
    END LOOP;
    v_orden := ' ORDER BY ' || array_to_string(v_lista, ', ');
  END IF;
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t)), ''[]'') FROM (SELECT * FROM public.%I%s%s LIMIT %s OFFSET %s) t',
                 p_vista,
                 CASE WHEN cardinality(v_where) > 0 THEN ' WHERE ' || array_to_string(v_where, ' AND ') ELSE '' END,
                 v_orden, least(greatest(coalesce(p_limite, 200), 1), 1000), greatest(coalesce(p_desde, 0), 0))
    INTO v_res USING p_filtros;
  RETURN v_res;
END $$;

REVOKE ALL ON FUNCTION emulador.rpc(text, jsonb), emulador.leer(text, jsonb, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION emulador.rpc(text, jsonb), emulador.leer(text, jsonb, text, int, int) TO anon, authenticated, service_role;
