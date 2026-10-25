#!/usr/bin/env bash
# PRUEBA: (0.18.0) actualizar en "Supabase" una base 0.17.0 instalada con las partes del SQL Editor (mini Supabase con Storage, rol sin superusuario, una petición por archivo) pegando SOLO dist/actualizar_supabase_0.18.0.sql: dice ACTUALIZADO A 0.18.0 (fotos LISTO), verificar_instalacion dice TODO BIEN, el dueño y el admin ven lo mismo que antes (productos, perfil, dinero, proyección y resumen; sin contar lo nuevo), pegarlo otra vez no cambia nada, sin núcleo o sin la 053 se rechaza sin tocar nada (y lo dice claro: "053 (núcleo 0.17.0)"), un error a mitad no deja nada a medias, la bitácora queda íntegra, lo nuevo funciona (precio mayorista, garantía, cheque y antigüedad que cuadra) y migrar.sh la reconoce
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
VIEJA="${BASE}_017"
OTRA="${BASE}_sin053"
TMP="$(mktemp -d)"
limpiar() { for b in "$VIEJA" "$OTRA"; do dropdb --if-exists "$b" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
una() { python3 "$RAIZ/herramientas/sql_una_peticion.py" "$PGHOST" "$PGPORT" supa_postgres "$1" "$2"; }

# 1) Paquete 0.17.0 (migraciones 001-053) y el paquete actual (con la actualización a 0.18.0).
mkdir -p "$TMP/v017/herramientas" "$TMP/v017/nucleo/sql/migraciones" "$TMP/dist017" "$TMP/dist"
cp "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/v017/herramientas/"
cp "$RAIZ/CHANGELOG.md" "$TMP/v017/"
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-4][0-9]_*.sql "$RAIZ"/nucleo/sql/migraciones/05[0-3]_*.sql; do cp "$f" "$TMP/v017/nucleo/sql/migraciones/"; done
echo "0.17.0" > "$TMP/v017/VERSION_NUCLEO"
bash "$TMP/v017/herramientas/armar_instalacion.sh" "$TMP/dist017" >/dev/null || falla "no se armó el paquete 0.17.0"
bash "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/dist" >/dev/null || falla "no se armó el paquete actual"
ACT="$TMP/dist/actualizar_supabase_${VERSION}.sql"
[ -f "$ACT" ] || falla "no hay $ACT"
[ "$(ls "$TMP"/dist/actualizar_supabase_* | wc -l)" = "1" ] || falla "la actualización debía ser un solo archivo"
[ "$(stat -c %s "$ACT")" -lt $((200 * 1024)) ] || falla "la actualización pasa de 200 KB"
grep -q "Migración 054_" "$ACT" && ! grep -q "Migración 053_" "$ACT" || falla "la actualización debe traer solo la 054"

# 2) Base 0.17.0 como en Supabase (partes del SQL Editor) con datos de enero.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase"
for p in "$TMP"/dist017/instalar_supabase_parte*.sql; do una "$VIEJA" "$p" >/dev/null || falla "parte 0.17.0 $(basename "$p")"; done
[ "$(q "$VIEJA" "SELECT version_nucleo || '/' || ultima_migracion FROM public.version_esquema")" = "0.17.0/53" ] || falla "no quedó en 0.17.0"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null || falla "preparar_datos"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "datos"
BEGIN;
SELECT pruebas.preparar_enero();
COMMIT;
SQL

# Lo que ve cada uno (sin las claves nuevas de 0.18.0 ni horas).
foto() {
  psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" <<SQL
BEGIN;
SELECT pruebas.como('$1') \g /dev/null
SELECT jsonb_build_object(
  'productos', (SELECT jsonb_agg(to_jsonb(x) - 'precio_mayorista_centavos' - 'cantidad_mayorista' - 'precio_mayorista_con_isv_centavos'
                                 - 'dias_garantia' ORDER BY x.codigo) FROM public.v_producto x),
  'perfil', public.mi_perfil(pruebas.empresa('A')) - 'hora_servidor' - 'permisos',
  'dinero', public.donde_esta_mi_dinero(pruebas.empresa('A')) - 'hora_servidor' - 'cheques_por_depositar',
  'proyeccion', public.proyeccion_flujo(pruebas.empresa('A')) - 'generado_en' - 'semanas' - 'cheques_por_depositar_centavos' - 'nota',
  'semanas', (SELECT jsonb_agg(s - 'cheques_centavos') FROM jsonb_array_elements(public.proyeccion_flujo(pruebas.empresa('A'))->'semanas') s),
  'resumen', public.resumen_hoy(pruebas.empresa('A')) - 'generado_en')::text;
ROLLBACK;
SQL
}
ANTES_DUENO="$(foto dueno_a)"
ANTES_ADMIN="$(foto admin_a)"
[ -n "$ANTES_DUENO" ] && [ -n "$ANTES_ADMIN" ] || falla "no se tomó la foto de antes"

# 3) Rechazos sin tocar nada: base sin núcleo y base sin la 053.
createdb "$OTRA"
psql -X -q -d "$OTRA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase (otra)"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó en una base sin núcleo"; fi
grep -q "FALTA_NUCLEO" "$TMP/sal.txt" || falla "sin núcleo debía decir FALTA_NUCLEO: $(cat "$TMP/sal.txt")"
for p in "$TMP"/dist017/instalar_supabase_parte*.sql; do
  grep -q "Migración 053_" "$p" && continue
  una "$OTRA" "$p" >/dev/null || falla "parte $(basename "$p") en la otra base"
done
ANTES_OTRA="$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")"
[ "$ANTES_OTRA" -lt 53 ] || falla "la otra base debía quedar antes de la 053"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó sin la 053"; fi
grep -q "FALTA_VERSION_ANTERIOR" "$TMP/sal.txt" || falla "sin la 053 debía decir FALTA_VERSION_ANTERIOR: $(cat "$TMP/sal.txt")"
grep -q "053 (núcleo 0.17.0)" "$TMP/sal.txt" || falla "el aviso debía decir 053 (núcleo 0.17.0): $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")" = "$ANTES_OTRA" ] || falla "la base sin la 053 quedó tocada"

# 3b) Un error a mitad (división por cero justo antes del final): no queda nada a medias.
sed 's/^NOTIFY pgrst, .reload schema.;$/SELECT 1 \/ 0 AS falla_a_proposito;\n&/' "$ACT" > "$TMP/act_roto.sql"
grep -q "falla_a_proposito" "$TMP/act_roto.sql" || falla "no se pudo armar la copia con error"
if una "$VIEJA" "$TMP/act_roto.sql" >"$TMP/sal.txt" 2>&1; then falla "la copia con error se aplicó"; fi
[ "$(q "$VIEJA" "SELECT max(numero) || '/' || (to_regprocedure('public.antiguedad_saldos(uuid,date,text)') IS NULL)
      || '/' || (to_regclass('public.cheque_recibido') IS NULL)
      || '/' || (SELECT count(*) FROM information_schema.columns WHERE table_name = 'producto' AND column_name = 'precio_mayorista_centavos')
      FROM interno._migraciones")" = "53/true/true/0" ] || falla "el error a mitad dejó algo a medias"
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || falla "el error a mitad cambió lo que ve el dueño"

# 4) Actualizar: una sola petición, todo o nada.
una "$VIEJA" "$ACT" >"$TMP/sal.txt" || falla "la actualización dio error: $(cat "$TMP/sal.txt")"
grep -q "^ACTUALIZADO A $VERSION | $VERSION | 54 | 54 | LISTO" "$TMP/sal.txt" || falla "no dijo ACTUALIZADO A $VERSION ... LISTO: $(cat "$TMP/sal.txt")"
una "$VIEJA" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION | 54 | 54 | LISTO" || falla "verificar_instalacion no dice TODO BIEN"
[ "$(q "$VIEJA" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'interno') AND pg_get_userbyid(p.proowner) <> 'supa_postgres'")" = "0" ] || falla "funciones con otro dueño"
[ "$(q "$VIEJA" "SELECT checksum FROM interno._migraciones WHERE numero = 54")" \
  = "$(sha256sum "$RAIZ"/nucleo/sql/migraciones/054_*.sql | cut -d' ' -f1)" ] || falla "huella de la 054"
[ "$(q "$VIEJA" "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la bitácora no quedó íntegra"

# 5) El dueño y el admin ven lo mismo que antes.
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || { echo "antes:   $ANTES_DUENO"; echo "despues: $(foto dueno_a)"; falla "el dueño ve otra cosa después de actualizar"; }
[ "$(foto admin_a)" = "$ANTES_ADMIN" ] || falla "el admin ve otra cosa después de actualizar"

# 6) Otra vez: no cambia nada y sigue diciendo ACTUALIZADO.
antes="$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")"
una "$VIEJA" "$ACT" | grep -q "^ACTUALIZADO A $VERSION |" || falla "al repetir no dijo ACTUALIZADO"
[ "$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")" = "$antes" ] || falla "repetir cambió las migraciones"

# 7) Lo nuevo funciona en la base actualizada (y se deshace: ROLLBACK).
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "lo nuevo no funciona en la base actualizada"
BEGIN;
DO $$
DECLARE e uuid := pruebas.empresa('A'); r jsonb; v jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.editar_producto(e, pruebas.id('P1'), '{"precio_mayorista_centavos": 1200, "cantidad_mayorista": 12, "dias_garantia": 30}', 'Mayoreo');
  v := public.registrar_venta(e, pruebas.venta('P1', 12, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 14400, 'mayorista: ' || v::text);
  PERFORM pruebas.afirmar((SELECT garantia_hasta FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid) = public.hoy_local(e) + 30, 'garantía');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v->'venta_id', 'monto_centavos', 14400)),
         'pagos', jsonb_build_array(jsonb_build_object('forma', 'cheque', 'monto_centavos', 14400, 'numero_cheque', '1',
           'banco_emisor', 'BAC', 'fecha_cheque', public.hoy_local(e)))), gen_random_uuid());
  r := public.antiguedad_saldos(e);
  PERFORM pruebas.afirmar((r->>'cuadra')::boolean, 'antigüedad cuadra');
END $$;
ROLLBACK;
SQL
PEND="$(PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" --solo-mostrar)" || falla "migrar.sh"
echo "$PEND" | grep -q "No hay migraciones pendientes" || falla "migrar.sh no reconoce la base actualizada: $PEND"
echo "ok"
