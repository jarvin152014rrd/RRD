-- PRUEBA: asiento correcto se guarda (temporal)
DO $$ BEGIN PERFORM pruebas.como('dueno_a'); PERFORM pruebas.afirmar(auth.uid() = pruebas.usuario('dueno_a'), 'uid'); PERFORM pruebas.afirmar(current_user = 'authenticated', 'rol '||current_user); PERFORM pruebas.como('superusuario'); PERFORM pruebas.afirmar(current_user = 'postgres', 'rol2 '||current_user); END $$;
