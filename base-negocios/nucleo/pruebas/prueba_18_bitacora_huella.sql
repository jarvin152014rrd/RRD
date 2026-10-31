-- PRUEBA: la bitácora lleva huella encadenada por empresa y verificar_bitacora() detecta alteraciones forzadas
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  b   uuid := pruebas.empresa('B');
  v_id bigint;
  v_n  integer;
  v_problemas text;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(e, '2026-01-10', 'Venta 1', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid());
  PERFORM public.registrar_asiento(e, '2026-01-11', 'Venta 2', pruebas.lineas('1.1.01.01', '4.1.01.01', 2000), gen_random_uuid());
  PERFORM public.registrar_asiento(e, '2026-01-12', 'Venta 3', pruebas.lineas('1.1.01.01', '4.1.01.01', 3000), gen_random_uuid());

  -- El dueño verifica su bitácora: intacta. El cajero no puede.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora de A intacta (dueño)');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'sin empresa usa la del usuario');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.verificar_bitacora(%L)', e), 'SIN_PERMISO', 'cajero verifica');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.verificar_bitacora(%L)', e), 'NO_PERTENECE', 'B verifica A');

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'toda la bitácora intacta');

  -- Estructura de la cadena: 1, 2, 3... por empresa; la primera apunta a ceros.
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.bitacora WHERE huella IS NULL OR secuencia IS NULL), 'todas con huella');
  PERFORM pruebas.afirmar((SELECT huella_anterior FROM public.bitacora WHERE empresa_id = e AND secuencia = 1) = repeat('0', 64), 'primera fila apunta a ceros');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e)
                          = (SELECT max(secuencia) FROM public.bitacora WHERE empresa_id = e), 'secuencia sin huecos');
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.bitacora x JOIN public.bitacora y
      ON y.empresa_id = x.empresa_id AND y.secuencia = x.secuencia + 1
    WHERE y.huella_anterior <> x.huella), 'cada fila apunta a la huella de la anterior');
  PERFORM pruebas.afirmar((SELECT huella FROM public.bitacora WHERE empresa_id = e ORDER BY secuencia LIMIT 1) ~ '^[0-9a-f]{64}$', 'huella sha256');

  SELECT id INTO v_id FROM public.bitacora WHERE empresa_id = e AND tabla = 'asiento' ORDER BY secuencia LIMIT 1;

  -- Caso 1: el superusuario apaga el candado y EDITA una fila.
  BEGIN
    ALTER TABLE public.bitacora DISABLE TRIGGER bitacora_inmutable;
    UPDATE public.bitacora SET motivo = 'nadie se va a dar cuenta' WHERE id = v_id;
    ALTER TABLE public.bitacora ENABLE TRIGGER bitacora_inmutable;
    SELECT string_agg(problema, ' | ') INTO v_problemas FROM public.verificar_bitacora(e) WHERE bitacora_id = v_id;
    PERFORM pruebas.afirmar(v_problemas LIKE '%fila alterada%', 'detecta fila editada: ' || coalesce(v_problemas, 'nada'));
    PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(b)) = 0, 'la cadena de B no se afecta');
    RAISE EXCEPTION 'deshacer caso 1';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'deshacer caso 1' THEN RAISE; END IF;
  END;

  -- Caso 2: BORRA una fila del medio.
  BEGIN
    ALTER TABLE public.bitacora DISABLE TRIGGER bitacora_inmutable;
    DELETE FROM public.bitacora WHERE id = v_id;
    ALTER TABLE public.bitacora ENABLE TRIGGER bitacora_inmutable;
    SELECT string_agg(problema, ' | ') INTO v_problemas FROM public.verificar_bitacora(e);
    PERFORM pruebas.afirmar(v_problemas LIKE '%cadena rota%' AND v_problemas LIKE '%faltan filas antes%',
      'detecta fila borrada: ' || coalesce(v_problemas, 'nada'));
    RAISE EXCEPTION 'deshacer caso 2';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'deshacer caso 2' THEN RAISE; END IF;
  END;

  -- Caso 3: BORRA la última fila.
  BEGIN
    ALTER TABLE public.bitacora DISABLE TRIGGER bitacora_inmutable;
    DELETE FROM public.bitacora WHERE id = (SELECT max(id) FROM public.bitacora WHERE empresa_id = e);
    ALTER TABLE public.bitacora ENABLE TRIGGER bitacora_inmutable;
    SELECT string_agg(problema, ' | ') INTO v_problemas FROM public.verificar_bitacora(e);
    PERFORM pruebas.afirmar(v_problemas LIKE '%faltan filas al final%', 'detecta última fila borrada: ' || coalesce(v_problemas, 'nada'));
    RAISE EXCEPTION 'deshacer caso 3';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'deshacer caso 3' THEN RAISE; END IF;
  END;

  -- Caso 4: METE una fila falsa saltando el trigger de la cadena.
  BEGIN
    ALTER TABLE public.bitacora DISABLE TRIGGER encadenar;
    INSERT INTO public.bitacora (empresa_id, accion, tabla, motivo) VALUES (e, 'INSERT', 'asiento', 'fila inventada');
    ALTER TABLE public.bitacora ENABLE TRIGGER encadenar;
    SELECT count(*) INTO v_n FROM public.verificar_bitacora(e) WHERE problema LIKE 'fila sin huella%';
    PERFORM pruebas.afirmar(v_n = 1, 'detecta fila metida sin huella');
    RAISE EXCEPTION 'deshacer caso 4';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'deshacer caso 4' THEN RAISE; END IF;
  END;

  -- Caso 5: cambia una fila Y recalcula su huella (pero no las siguientes).
  BEGIN
    ALTER TABLE public.bitacora DISABLE TRIGGER bitacora_inmutable;
    UPDATE public.bitacora SET motivo = 'trampa con huella nueva' WHERE id = v_id;
    UPDATE public.bitacora x SET huella = interno.huella_bitacora(x) WHERE id = v_id;
    ALTER TABLE public.bitacora ENABLE TRIGGER bitacora_inmutable;
    SELECT string_agg(problema, ' | ') INTO v_problemas FROM public.verificar_bitacora(e);
    PERFORM pruebas.afirmar(v_problemas LIKE '%cadena rota%', 'detecta huella recalculada: ' || coalesce(v_problemas, 'nada'));
    RAISE EXCEPTION 'deshacer caso 5';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'deshacer caso 5' THEN RAISE; END IF;
  END;

  -- Todo deshecho: intacta otra vez, y los triggers siguen activos.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'intacta tras deshacer');
  PERFORM pruebas.debe_fallar(format('UPDATE public.bitacora SET motivo = %L WHERE id = %s', 'x', v_id), 'PROHIBIDO', 'candado sigue puesto');
END $$;
