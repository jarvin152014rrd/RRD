#!/usr/bin/env bash
# PRUEBA: (0.17.0) actualizar en "Supabase" una base 0.16.0 instalada con las partes del SQL Editor (mini Supabase con Storage, rol sin superusuario, una petición por archivo) pegando SOLO dist/actualizar_supabase_0.17.0.sql: dice ACTUALIZADO A 0.17.0 y fotos LISTO (bucket privado y 4 políticas creados por SQL), verificar_instalacion dice TODO BIEN, el dueño y el admin ven lo mismo que antes (productos, perfil, dinero y resumen; fotos apagadas), pegarlo otra vez no cambia nada, sin núcleo o sin la 052 se rechaza sin tocar nada (y lo dice claro: "052 (núcleo 0.16.0)"), un error a mitad no deja nada a medias (ni el bucket), la bitácora queda íntegra, las fotos funcionan y migrar.sh la reconoce; en un Supabase donde el rol NO puede crear el bucket ni las políticas, la actualización igual termina, dice qué falta y, hechos los clics de docs/SUPABASE.md, queda LISTO
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
VIEJA="${BASE}_016"
OTRA="${BASE}_sin052"
SINPERM="${BASE}_sinperm"
TMP="$(mktemp -d)"
limpiar() { for b in "$VIEJA" "$OTRA" "$SINPERM"; do dropdb --if-exists "$b" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
una() { python3 "$RAIZ/herramientas/sql_una_peticion.py" "$PGHOST" "$PGPORT" supa_postgres "$1" "$2"; }

# 1) Paquete 0.16.0 (migraciones 001-052) y el paquete actual (con la actualización a 0.17.0).
mkdir -p "$TMP/v016/herramientas" "$TMP/v016/nucleo/sql/migraciones" "$TMP/dist016" "$TMP/dist"
cp "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/v016/herramientas/"
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-4][0-9]_*.sql "$RAIZ"/nucleo/sql/migraciones/05[012]_*.sql; do cp "$f" "$TMP/v016/nucleo/sql/migraciones/"; done
echo "0.16.0" > "$TMP/v016/VERSION_NUCLEO"
bash "$TMP/v016/herramientas/armar_instalacion.sh" "$TMP/dist016" >/dev/null || falla "no se armó el paquete 0.16.0"
bash "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/dist" >/dev/null || falla "no se armó el paquete actual"
ACT="$TMP/dist/actualizar_supabase_0.17.0.sql"
[ -f "$ACT" ] || falla "no hay $ACT"
[ "$(ls "$TMP"/dist/actualizar_supabase_* | wc -l)" = "1" ] || falla "la actualización debía ser un solo archivo"
[ "$(stat -c %s "$ACT")" -lt $((200 * 1024)) ] || falla "la actualización pasa de 200 KB"
grep -q "Migración 053_" "$ACT" && ! grep -q "Migración 052_" "$ACT" || falla "la actualización debe traer solo la 053"

# 2) Base 0.16.0 como en Supabase (partes del SQL Editor) con productos.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase"
for p in "$TMP"/dist016/instalar_supabase_parte*.sql; do una "$VIEJA" "$p" >/dev/null || falla "parte 0.16.0 $(basename "$p")"; done
[ "$(q "$VIEJA" "SELECT version_nucleo || '/' || ultima_migracion FROM public.version_esquema")" = "0.16.0/52" ] || falla "no quedó en 0.16.0"
[ "$(q "$VIEJA" "SELECT count(*) FROM storage.buckets")" = "0" ] || falla "0.16.0 no debía tener buckets"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null || falla "preparar_datos"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "datos"
BEGIN;
SELECT pruebas.preparar_enero();
COMMIT;
SQL

# Lo que ve el dueño (sin las columnas nuevas ni horas).
foto() {
  psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" <<SQL
BEGIN;
SELECT pruebas.como('$1') \g /dev/null
SELECT jsonb_build_object(
  'productos', (SELECT jsonb_agg(to_jsonb(x) - 'foto_ruta' - 'foto_miniatura_ruta' ORDER BY x.codigo) FROM public.v_producto x),
  'perfil', public.mi_perfil(pruebas.empresa('A')) - 'hora_servidor' #- '{empresa,fotos_productos}',
  'dinero', public.donde_esta_mi_dinero(pruebas.empresa('A')) - 'hora_servidor',
  'resumen', public.resumen_hoy(pruebas.empresa('A')) - 'generado_en')::text;
ROLLBACK;
SQL
}
ANTES_DUENO="$(foto dueno_a)"
ANTES_VEND="$(foto admin_a)"
[ -n "$ANTES_DUENO" ] && [ -n "$ANTES_VEND" ] || falla "no se tomó la foto de antes"

# 3) Rechazos sin tocar nada: base sin núcleo y base sin la 052 (0.15.0).
createdb "$OTRA"
psql -X -q -d "$OTRA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase (otra)"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó en una base sin núcleo"; fi
grep -q "FALTA_NUCLEO" "$TMP/sal.txt" || falla "sin núcleo debía decir FALTA_NUCLEO: $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT to_regclass('interno._migraciones') IS NULL")" = "t" ] || falla "la base sin núcleo quedó tocada"
for p in "$TMP"/dist016/instalar_supabase_parte*.sql; do
  grep -q "Migración 052_" "$p" && continue
  una "$OTRA" "$p" >/dev/null || falla "parte $(basename "$p") en la otra base"
done
[ "$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")" = "51" ] || falla "la otra base debía quedar en la 051"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó sin la 052"; fi
grep -q "FALTA_VERSION_ANTERIOR" "$TMP/sal.txt" || falla "sin la 052 debía decir FALTA_VERSION_ANTERIOR: $(cat "$TMP/sal.txt")"
grep -q "052 (núcleo 0.16.0)" "$TMP/sal.txt" || falla "el aviso debía decir 052 (núcleo 0.16.0): $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT max(numero) || '/' || (SELECT count(*) FROM storage.buckets) FROM interno._migraciones")" = "51/0" ] || falla "la base sin la 052 quedó tocada"

# 3b) Un error a mitad (copia con una división por cero justo antes del final): no queda nada a medias, ni el bucket.
sed 's/^NOTIFY pgrst, .reload schema.;$/SELECT 1 \/ 0 AS falla_a_proposito;\n&/' "$ACT" > "$TMP/act_roto.sql"
grep -q "falla_a_proposito" "$TMP/act_roto.sql" || falla "no se pudo armar la copia con error"
if una "$VIEJA" "$TMP/act_roto.sql" >"$TMP/sal.txt" 2>&1; then falla "la copia con error se aplicó"; fi
[ "$(q "$VIEJA" "SELECT max(numero) || '/' || (to_regprocedure('public.poner_foto_producto(uuid,uuid,jsonb,uuid)') IS NULL)
      || '/' || (SELECT count(*) FROM storage.buckets) || '/' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage')
      || '/' || (SELECT count(*) FROM information_schema.columns WHERE table_name = 'empresa' AND column_name = 'fotos_productos')
      FROM interno._migraciones")" = "52/true/0/0/0" ] || falla "el error a mitad dejó algo a medias"
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || falla "el error a mitad cambió lo que ve el dueño"

# 4) Actualizar: una sola petición, todo o nada.
una "$VIEJA" "$ACT" >"$TMP/sal.txt" || falla "la actualización dio error: $(cat "$TMP/sal.txt")"
grep -q "^ACTUALIZADO A $VERSION | $VERSION | 53 | 53 | LISTO" "$TMP/sal.txt" || falla "no dijo ACTUALIZADO A $VERSION ... LISTO: $(cat "$TMP/sal.txt")"
una "$VIEJA" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION | 53 | 53 | LISTO" || falla "verificar_instalacion no dice TODO BIEN ... LISTO"
[ "$(q "$VIEJA" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'interno') AND pg_get_userbyid(p.proowner) <> 'supa_postgres'")" = "0" ] || falla "funciones con otro dueño"
[ "$(q "$VIEJA" "SELECT checksum FROM interno._migraciones WHERE numero = 53")" \
  = "$(sha256sum "$RAIZ/nucleo/sql/migraciones/053_fotos_productos.sql" | cut -d' ' -f1)" ] || falla "huella de la 053"
[ "$(q "$VIEJA" "SELECT public || '/' || file_size_limit || '/' || array_to_string(allowed_mime_types, ',') FROM storage.buckets WHERE id = 'fotos-productos'")" \
  = "false/1048576/image/webp,image/jpeg" ] || falla "bucket mal creado"
[ "$(q "$VIEJA" "SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'fotos_productos_%'")" = "4" ] \
  || falla "faltan políticas"
[ "$(q "$VIEJA" "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la bitácora no quedó íntegra"
[ "$(q "$VIEJA" "SELECT count(*) FROM public.empresa WHERE fotos_productos")" = "0" ] || falla "las fotos debían quedar apagadas"

# 5) El dueño y el admin ven lo mismo que antes.
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || { echo "antes:   $ANTES_DUENO"; echo "despues: $(foto dueno_a)"; falla "el dueño ve otra cosa después de actualizar"; }
[ "$(foto admin_a)" = "$ANTES_VEND" ] || falla "el admin ve otra cosa después de actualizar"

# 6) Otra vez: no cambia nada y sigue diciendo ACTUALIZADO.
antes="$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")"
una "$VIEJA" "$ACT" | grep -q "^ACTUALIZADO A $VERSION |" || falla "al repetir no dijo ACTUALIZADO"
[ "$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")" = "$antes" ] || falla "repetir cambió las migraciones"

# 7) Funciona: encender, subir a Storage y poner la foto.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "fotos en la base actualizada"
BEGIN;
DO $$
DECLARE e uuid := pruebas.empresa('A'); p uuid := pruebas.id('P1'); r jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.activar_fotos_productos(e, true, 'Encender fotos');
  INSERT INTO storage.objects (bucket_id, name) VALUES ('fotos-productos', e || '/' || p || '/0123456789ab.webp'),
                                                       ('fotos-productos', e || '/' || p || '/0123456789ab_mini.webp');
  r := public.poner_foto_producto(e, p, jsonb_build_object('ruta', e || '/' || p || '/0123456789ab.webp',
                                                           'miniatura', e || '/' || p || '/0123456789ab_mini.webp'), gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT foto_miniatura_ruta FROM public.v_producto WHERE producto_id = p) LIKE '%_mini.webp', 'foto puesta: ' || r::text);
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM storage.objects) = 0, 'B no ve las fotos de A');
END $$;
ROLLBACK;
SQL
PEND="$(PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" --solo-mostrar)" || falla "migrar.sh"
echo "$PEND" | grep -q "No hay migraciones pendientes" || falla "migrar.sh no reconoce la base actualizada: $PEND"

# 8) Un Supabase donde el rol "postgres" NO puede crear el bucket ni las políticas (storage de otro dueño,
#    sin permisos): la actualización igual termina, dice qué falta y, con los "clics" de docs/SUPABASE.md
#    (aquí hechos por el dueño de storage), queda LISTO.
createdb "$SINPERM"
psql -X -q -d "$SINPERM" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase (sin permisos)"
psql -X -q -v ON_ERROR_STOP=1 -d "$SINPERM" >/dev/null <<'SQL' || falla "quitar permisos de storage"
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supa_storage_ajeno') THEN CREATE ROLE supa_storage_ajeno NOLOGIN; END IF;
END $$;
ALTER TABLE storage.buckets OWNER TO supa_storage_ajeno;
ALTER TABLE storage.objects OWNER TO supa_storage_ajeno;
REVOKE ALL ON storage.buckets, storage.objects FROM supa_postgres;
GRANT SELECT ON storage.buckets TO supa_postgres;
GRANT USAGE ON SCHEMA storage TO supa_storage_ajeno;
-- Como en Supabase, "postgres" ve todos los buckets (en el SQL Editor no lo frena RLS).
CREATE POLICY ver_todo_postgres ON storage.buckets FOR SELECT TO supa_postgres USING (true);
GRANT USAGE ON SCHEMA public TO supa_storage_ajeno;
SQL
for p in "$TMP"/dist016/instalar_supabase_parte*.sql; do una "$SINPERM" "$p" >/dev/null || falla "parte 0.16.0 (sin permisos)"; done
una "$SINPERM" "$ACT" >"$TMP/sal.txt" || falla "sin permisos la actualización dio error: $(cat "$TMP/sal.txt")"
grep -q "^ACTUALIZADO A $VERSION | $VERSION | 53 | 53 | FALTA: crear el bucket fotos-productos" "$TMP/sal.txt" \
  || falla "sin permisos debía decir qué falta: $(cat "$TMP/sal.txt")"
# Los "clics": bucket privado y las 4 políticas con el texto de docs/SUPABASE.md (el panel agrega un sufijo al nombre).
psql -X -q -v ON_ERROR_STOP=1 -d "$SINPERM" >/dev/null <<'SQL' || falla "los clics de docs/SUPABASE.md"
SET ROLE supa_storage_ajeno;
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('fotos-productos', 'fotos-productos', false, 1048576, ARRAY['image/webp', 'image/jpeg']);
SQL
una "$SINPERM" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION | 53 | 53 | FALTA: crear (o corregir) las políticas fotos_productos_leer, fotos_productos_subir" \
  || falla "con el bucket y sin políticas debía decir qué políticas faltan"
psql -X -q -v ON_ERROR_STOP=1 -d "$SINPERM" >/dev/null <<'SQL' || falla "las políticas de docs/SUPABASE.md"
SET ROLE supa_storage_ajeno;
CREATE POLICY "fotos_productos_leer 1x2y_0" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('leer'))));
CREATE POLICY "fotos_productos_subir 1x2y_0" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir'))) AND public.ruta_foto_producto_valida(name));
CREATE POLICY "fotos_productos_cambiar 1x2y_0" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir'))) AND public.ruta_foto_producto_valida(name))
  WITH CHECK (bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir'))) AND public.ruta_foto_producto_valida(name));
CREATE POLICY "fotos_productos_borrar 1x2y_0" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('borrar'))) AND NOT public.foto_producto_en_uso(name));
SQL
una "$SINPERM" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION | 53 | 53 | LISTO" || falla "después de los clics debía decir LISTO"
echo "ok"
