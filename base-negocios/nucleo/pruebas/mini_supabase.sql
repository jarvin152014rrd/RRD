-- =====================================================================
-- mini_supabase.sql  -  SOLO PRUEBAS LOCALES (probar.sh --paquete).
-- Una base "como recién creada en Supabase", para probar que el paquete de
-- dist/ (herramientas/armar_instalacion.sh) instala de cero SIN el simulador:
--   * roles anon, authenticated, service_role (los crea Supabase, no el paquete)
--   * rol "supa_postgres": hace de "postgres" de Supabase, que NO es superusuario.
--     El paquete se instala con él, así sus tablas y funciones quedan con un
--     dueño sin superpoderes, como en la nube.
--   * esquema auth con users, sessions y refresh_tokens (borrado en cascada),
--     de dueño otro rol (en Supabase es supabase_auth_admin); auth.uid(),
--     auth.role() y auth.jwt() con la definición de Supabase
--   * pgcrypto en el esquema "extensions" (como Supabase; el núcleo no la usa)
--   * permisos "generosos" por defecto de Supabase en public para lo que cree
--     supa_postgres (el paquete debe quitarlos)
-- Lo corre el superusuario local. Los roles son de todo el servidor local.
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supa_postgres') THEN
    -- Como "postgres" en Supabase: entra, crea bases y roles, NO es superusuario.
    CREATE ROLE supa_postgres LOGIN NOSUPERUSER CREATEDB CREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supa_auth_admin') THEN
    CREATE ROLE supa_auth_admin NOLOGIN NOSUPERUSER;
  END IF;
END $$;
-- Supabase deja que postgres "se ponga" estos roles (SQL Editor, pruebas de RLS).
GRANT anon, authenticated, service_role TO supa_postgres;

DO $$ BEGIN EXECUTE format('GRANT CREATE, CONNECT ON DATABASE %I TO supa_postgres', current_database()); END $$;
GRANT USAGE, CREATE ON SCHEMA public TO supa_postgres;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- auth (de supa_auth_admin, como supabase_auth_admin)
-- ---------------------------------------------------------------------
CREATE SCHEMA auth AUTHORIZATION supa_auth_admin;
CREATE TABLE auth.users (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aud         varchar(255),
  role        varchar(255),
  email       varchar(255) UNIQUE,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);
CREATE TABLE auth.sessions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);
CREATE TABLE auth.refresh_tokens (
  id          bigserial PRIMARY KEY,
  token       varchar(255),
  user_id     varchar(255),
  session_id  uuid REFERENCES auth.sessions(id) ON DELETE CASCADE,
  revoked     boolean,
  created_at  timestamptz DEFAULT now()
);
ALTER TABLE auth.users OWNER TO supa_auth_admin;
ALTER TABLE auth.sessions OWNER TO supa_auth_admin;
ALTER TABLE auth.refresh_tokens OWNER TO supa_auth_admin;

-- Definiciones de Supabase (GoTrue).
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;
ALTER FUNCTION auth.uid() OWNER TO supa_auth_admin;
ALTER FUNCTION auth.role() OWNER TO supa_auth_admin;
ALTER FUNCTION auth.jwt() OWNER TO supa_auth_admin;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role, supa_postgres;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role(), auth.jwt() TO PUBLIC;
-- Lo que "postgres" puede en auth en Supabase (leer, referenciar y borrar sesiones).
GRANT SELECT, REFERENCES ON auth.users TO supa_postgres;
GRANT SELECT, DELETE ON auth.sessions TO supa_postgres;
GRANT SELECT, DELETE ON auth.refresh_tokens TO supa_postgres;

-- ---------------------------------------------------------------------
-- extensions (pgcrypto vive aquí en Supabase)
-- ---------------------------------------------------------------------
CREATE SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role, supa_postgres;

-- ---------------------------------------------------------------------
-- Permisos por defecto "generosos" de Supabase para lo que cree postgres.
-- ---------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE supa_postgres IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supa_postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supa_postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
