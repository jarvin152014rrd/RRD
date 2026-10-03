-- PRUEBA: revisión de seguridad de la estructura (RLS en todo, sin escritura directa, search_path fijo)
DO $$
DECLARE r record;
BEGIN
  -- Toda tabla de public tiene RLS.
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity LOOP
    RAISE EXCEPTION 'FALLA: la tabla public.% no tiene RLS', r.relname;
  END LOOP;

  -- anon y authenticated no pueden escribir ninguna tabla; anon ni leer.
  FOR r IN SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname IN ('public', 'interno') AND c.relkind IN ('r', 'v') LOOP
    IF has_table_privilege('authenticated', r.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
       OR has_table_privilege('anon', r.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
      RAISE EXCEPTION 'FALLA: permisos de escritura indebidos en %', r.relname;
    END IF;
  END LOOP;

  -- El esquema interno no es accesible.
  PERFORM pruebas.afirmar(NOT has_schema_privilege('authenticated', 'interno', 'USAGE'), 'interno oculto a authenticated');
  PERFORM pruebas.afirmar(NOT has_schema_privilege('anon', 'interno', 'USAGE'), 'interno oculto a anon');

  -- Toda función SECURITY DEFINER nuestra tiene search_path fijo.
  FOR r IN SELECT p.oid::regprocedure AS f FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname IN ('public', 'interno') AND p.prosecdef
             AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%') LOOP
    RAISE EXCEPTION 'FALLA: % es SECURITY DEFINER sin search_path fijo', r.f;
  END LOOP;

  -- anon no ejecuta ninguna función nuestra.
  FOR r IN SELECT p.oid::regprocedure AS f FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname IN ('public', 'interno') AND has_function_privilege('anon', p.oid, 'EXECUTE') LOOP
    RAISE EXCEPTION 'FALLA: anon puede ejecutar %', r.f;
  END LOOP;

  -- Las funciones internas no las ejecuta authenticated; crear empresa tampoco.
  PERFORM pruebas.afirmar(NOT has_function_privilege('authenticated', 'interno.crear_cabecera(uuid,uuid,date,text,text,uuid,bigint,uuid,text)', 'EXECUTE'), 'crear_cabecera oculta');
  PERFORM pruebas.afirmar(NOT has_function_privilege('authenticated', 'public.crear_empresa_inicial(text,text,uuid,uuid)', 'EXECUTE'), 'crear_empresa solo service_role');
  PERFORM pruebas.afirmar(has_function_privilege('service_role', 'public.crear_empresa_inicial(text,text,uuid,uuid)', 'EXECUTE'), 'service_role crea empresas');
  PERFORM pruebas.afirmar(NOT has_table_privilege('authenticated', 'public.licencia', 'UPDATE'), 'licencia no editable por usuario');
  PERFORM pruebas.afirmar(has_table_privilege('service_role', 'public.licencia', 'UPDATE'), 'licencia editable por service_role');

  -- Migraciones registradas y versión visible.
  PERFORM pruebas.afirmar((SELECT count(*) FROM interno._migraciones) >= 7, 'migraciones registradas');
  PERFORM pruebas.afirmar((SELECT version_nucleo FROM public.version_esquema) = '0.1.0', 'versión del núcleo 0.1.0');

  -- Catálogo: cada cuenta de detalle es hoja y cada hoja es de detalle.
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.cuenta c
    WHERE c.es_detalle = EXISTS (SELECT 1 FROM public.cuenta h WHERE h.padre_id = c.id)), 'árbol de cuentas coherente');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta WHERE empresa_id = pruebas.empresa('A') AND padre_id IS NULL) = 6,
    '6 cuentas principales (activo, pasivo, patrimonio, ingresos, costos, gastos)');
  PERFORM pruebas.afirmar((SELECT naturaleza FROM public.cuenta WHERE empresa_id = pruebas.empresa('A') AND codigo = '1.2.01.06') = 'acreedora',
    'depreciación acumulada es acreedora');
END $$;
