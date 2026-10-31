-- =====================================================================
-- 051_supabase_real.sql  -  Núcleo 0.15.0: lo que hace falta para el
-- proyecto REAL de Supabase (etapa 6). Las 001-050 no se tocan.
--
-- Revisión de compatibilidad con Supabase real (detalle en docs/SUPABASE.md,
-- sección "Diferencias con el simulador"): las 001-050 NO crean roles, NO crean
-- el esquema auth, NO usan pgcrypto (sha256 y md5 son del propio PostgreSQL),
-- todo lo crea el rol "postgres" del SQL Editor (dueño de tablas y funciones),
-- las funciones SECURITY DEFINER tienen search_path vacío, el esquema
-- "interno" no se expone en la API (Supabase solo expone public) y la lectura
-- de auth.sessions ya tenía plan B (si no se puede leer, usa el "iat").
-- Lo único nuevo que pide Supabase real:
--
--   1. revocar_sesiones_auth(usuario): borra las sesiones de Supabase Auth del
--      usuario (sus "refresh tokens" se borran en cascada), para que "Cerrar
--      sesión a distancia" también le quite la renovación del token. La llama
--      SOLO la Edge Function "cerrar-sesion-remota" con la llave service_role,
--      y SOLO si en los últimos 10 minutos alguien con permiso ya hizo
--      cerrar_sesion_usuario sobre ese usuario (doble candado).
--      (auth.admin.signOut de supabase-js necesita el token DEL USUARIO que se
--      cierra, que no tenemos: por eso se hace así.)
--      Si la base no deja borrar en auth.sessions, devuelve -1 y no falla:
--      el cierre de 0.13.1 (session_id / iat) sigue bloqueando todo igual.
-- =====================================================================

CREATE FUNCTION public.revocar_sesiones_auth(p_user_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_n integer;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'DATO_INVALIDO: falta el usuario.';
  END IF;
  -- Doble candado: solo después de un cierre hecho por alguien con permiso.
  IF NOT EXISTS (SELECT 1 FROM public.usuario_empresa ue
                  WHERE ue.user_id = p_user_id AND ue.sesion_cerrada_en > now() - interval '10 minutes') THEN
    RAISE EXCEPTION 'PROHIBIDO: primero se cierra la sesión con cerrar_sesion_usuario (permiso usuarios.administrar).';
  END IF;
  IF to_regclass('auth.sessions') IS NULL OR NOT has_table_privilege('auth.sessions', 'DELETE') THEN
    RETURN -1;
  END IF;
  DELETE FROM auth.sessions s WHERE s.user_id = p_user_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE EXECUTE ON FUNCTION public.revocar_sesiones_auth(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.revocar_sesiones_auth(uuid) TO service_role;
