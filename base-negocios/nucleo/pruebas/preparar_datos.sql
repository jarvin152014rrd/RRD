-- =====================================================================
-- preparar_datos.sql  -  SOLO PRUEBAS. Datos y ayudantes comunes.
--   Empresa A: dueño, admin, cajero, vendedor y proveedor.
--   Empresa B: su dueño (para probar que A y B no se ven).
-- Las empresas se crean con la llave service_role, como en la vida real.
-- =====================================================================

CREATE SCHEMA pruebas;
GRANT USAGE ON SCHEMA pruebas TO anon, authenticated, service_role;

CREATE TABLE pruebas.usuario (apodo text PRIMARY KEY, id uuid NOT NULL);
CREATE TABLE pruebas.dato    (clave text PRIMARY KEY, valor uuid NOT NULL);
GRANT SELECT ON pruebas.usuario, pruebas.dato TO anon, authenticated, service_role;

INSERT INTO pruebas.usuario (apodo, id) VALUES
  ('dueno_a',     'a0000000-0000-0000-0000-000000000001'),
  ('admin_a',     'a0000000-0000-0000-0000-000000000002'),
  ('cajero_a',    'a0000000-0000-0000-0000-000000000003'),
  ('vendedor_a',  'a0000000-0000-0000-0000-000000000004'),
  ('proveedor',   'a0000000-0000-0000-0000-000000000005'),
  ('dueno_b',     'b0000000-0000-0000-0000-000000000001'),
  ('sin_empresa', 'c0000000-0000-0000-0000-000000000001');
INSERT INTO auth.users (id, email) SELECT id, apodo || '@prueba.hn' FROM pruebas.usuario;

-- ---------------------------------------------------------------------
-- Ayudantes
-- ---------------------------------------------------------------------
CREATE FUNCTION pruebas.usuario(p_apodo text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT id FROM pruebas.usuario WHERE apodo = p_apodo $$;

CREATE FUNCTION pruebas.empresa(p_clave text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT valor FROM pruebas.dato WHERE clave = p_clave $$;

-- Cambia "quién soy" dentro de la transacción actual, igual que Supabase:
-- rol de base de datos + claims del JWT.
CREATE FUNCTION pruebas.como(p_quien text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_quien = 'superusuario' THEN
    PERFORM set_config('role', 'none', true);
    PERFORM set_config('request.jwt.claims', '', true);
  ELSIF p_quien IN ('anon', 'service_role') THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', p_quien)::text, true);
    PERFORM set_config('role', p_quien, true);
  ELSIF p_quien = 'sin_sesion' THEN       -- rol authenticated pero sin usuario
    PERFORM set_config('request.jwt.claims', '{"role":"authenticated"}', true);
    PERFORM set_config('role', 'authenticated', true);
  ELSE
    IF pruebas.usuario(p_quien) IS NULL THEN
      RAISE EXCEPTION 'FALLA: usuario de prueba desconocido %', p_quien;
    END IF;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', pruebas.usuario(p_quien), 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
  END IF;
END $$;

-- Falla la prueba si la condición no se cumple.
CREATE FUNCTION pruebas.afirmar(p_condicion boolean, p_que text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT coalesce(p_condicion, false) THEN
    RAISE EXCEPTION 'FALLA: %', p_que;
  END IF;
END $$;

-- Ejecuta p_sql y exige que falle con un error que contenga p_esperado
-- (texto del mensaje o código SQLSTATE, p. ej. 42501 = permiso denegado).
CREATE FUNCTION pruebas.debe_fallar(p_sql text, p_esperado text, p_que text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_paso boolean := false;
BEGIN
  BEGIN
    EXECUTE p_sql;
    v_paso := true;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = p_esperado OR SQLERRM ILIKE '%' || p_esperado || '%' THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'FALLA [%]: se esperaba "%" pero salió: % (%)', p_que, p_esperado, SQLERRM, SQLSTATE;
  END;
  IF v_paso THEN
    RAISE EXCEPTION 'FALLA [%]: se esperaba el error "%" pero la operación pasó.', p_que, p_esperado;
  END IF;
END $$;

-- Arma el texto SQL de una llamada a registrar_asiento (para debe_fallar).
CREATE FUNCTION pruebas.sql_registrar(p_empresa uuid, p_fecha date, p_lineas jsonb,
                                      p_id_op uuid DEFAULT gen_random_uuid(),
                                      p_desc text DEFAULT 'Asiento de prueba') RETURNS text
LANGUAGE sql AS $$
  SELECT format('SELECT public.registrar_asiento(%L::uuid, %L::date, %L, %L::jsonb, %L::uuid)',
                p_empresa, p_fecha, p_desc, p_lineas, p_id_op)
$$;

-- Asiento simple de dos líneas: monto al debe de una cuenta y al haber de otra.
CREATE FUNCTION pruebas.lineas(p_cta_debe text, p_cta_haber text, p_monto bigint) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_array(
    jsonb_build_object('cuenta', p_cta_debe,  'debe',  p_monto),
    jsonb_build_object('cuenta', p_cta_haber, 'haber', p_monto))
$$;

-- Saldo (según naturaleza) de una cuenta, en centavos.
CREATE FUNCTION pruebas.saldo(p_empresa uuid, p_codigo text) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT saldo_centavos FROM public.v_saldo_cuenta WHERE empresa_id = p_empresa AND codigo = p_codigo
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pruebas TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Empresas (con la llave del proveedor: service_role)
-- ---------------------------------------------------------------------
SET ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
SELECT set_config('pruebas.emp_a', public.crear_empresa_inicial(
  'Ferretería El Martillo', '08011999000001',
  'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005')::text, false);
SELECT set_config('pruebas.emp_b', public.crear_empresa_inicial(
  'Pulpería La Esquina', '08011999000002',
  'b0000000-0000-0000-0000-000000000001')::text, false);
-- Licencias vigentes por 30 días.
INSERT INTO public.licencia (empresa_id, vence_el)
VALUES (current_setting('pruebas.emp_a')::uuid, public.hoy_local() + 30),
       (current_setting('pruebas.emp_b')::uuid, public.hoy_local() + 30);
RESET ROLE;
SELECT set_config('request.jwt.claims', '', false);

INSERT INTO pruebas.dato (clave, valor) VALUES
  ('A', current_setting('pruebas.emp_a')::uuid),
  ('B', current_setting('pruebas.emp_b')::uuid);

-- Resto del personal de la empresa A.
INSERT INTO public.usuario_empresa (user_id, empresa_id, rol)
SELECT pruebas.usuario(x.apodo), pruebas.empresa('A'), x.rol
FROM (VALUES ('admin_a','admin'), ('cajero_a','cajero'), ('vendedor_a','vendedor')) AS x(apodo, rol);
