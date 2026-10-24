-- =====================================================================
-- simular_supabase.sql
-- SOLO PARA PRUEBAS LOCALES. No se aplica en Supabase real.
-- Imita lo mínimo de Supabase para que las migraciones y las pruebas
-- se comporten igual que en la nube:
--   * roles anon, authenticated, service_role
--   * esquema auth con auth.users, auth.sessions (0.13.1), auth.uid() y auth.role()
--   * permisos por defecto "generosos" de Supabase en el esquema public
--     (así comprobamos que nuestras migraciones los quitan bien)
-- =====================================================================

-- Los roles son de todo el servidor; se crean solo si no existen.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    -- En Supabase service_role salta RLS.
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email      text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Sesiones de Supabase Auth (lo mínimo): cada inicio de sesión crea una fila; el JWT
-- lleva su id en el claim "session_id" y la renovación del token conserva ese id.
CREATE TABLE IF NOT EXISTS auth.sessions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Igual que Supabase: el usuario sale del JWT (claim "sub").
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::json->>'sub')::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::json->>'role')::text
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role() TO anon, authenticated, service_role;
GRANT SELECT ON auth.users TO service_role;

-- Permisos por defecto de Supabase en public (amplios a propósito).
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Storage (0.17.0, fotos de productos): lo mínimo de Supabase Storage.
-- storage.buckets (con file_size_limit y allowed_mime_types) y
-- storage.objects (una fila por archivo; los bytes NO van en la base: en
-- Supabase van a S3 y en la demo, a una carpeta de servidor_app.js). RLS
-- activado y sin políticas: las pone la migración 053. El API de Storage
-- hace INSERT / SELECT / DELETE en storage.objects COMO el usuario
-- (authenticated + JWT), así que las políticas deciden igual que en la nube.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL UNIQUE,
  owner              uuid,
  public             boolean DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now()
);
CREATE TABLE IF NOT EXISTS storage.objects (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id        text REFERENCES storage.buckets(id),
  name             text,
  owner            uuid,
  metadata         jsonb,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now(),
  last_accessed_at timestamptz DEFAULT now(),
  UNIQUE (bucket_id, name)
);
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO anon, authenticated, service_role;
GRANT SELECT ON storage.buckets TO anon, authenticated, service_role;
