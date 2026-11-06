#!/usr/bin/env bash
# PRUEBA: (0.22.0) actualizar en "Supabase" una base 0.21.0 instalada con las partes del SQL Editor (mini Supabase, rol sin superusuario, una petición por archivo) pegando SOLO dist/actualizar_supabase_0.22.0.sql: trae solo la 058, dice ACTUALIZADO A 0.22.0, verificar_instalacion dice TODO BIEN, el dueño ve lo mismo que antes, pegarlo otra vez no cambia nada, sin la 057 se rechaza sin tocar nada ("057 (núcleo 0.21.0)"), la bitácora queda íntegra, lo nuevo funciona (B1 queda como tienda, la empresa sin bodega recibe su tienda, guardar_bodega y datos fiscales) y migrar.sh la reconoce
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
VIEJA="${BASE}_021"
OTRA="${BASE}_sin057"
TMP="$(mktemp -d)"
limpiar() { for b in "$VIEJA" "$OTRA"; do dropdb --if-exists "$b" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
una() { python3 "$RAIZ/herramientas/sql_una_peticion.py" "$PGHOST" "$PGPORT" supa_postgres "$1" "$2"; }
NUM="$(ls "$RAIZ"/nucleo/sql/migraciones/[0-9]*_*.sql | wc -l)"

# 1) Paquete 0.21.0 (migraciones 001-057) y el paquete actual.
mkdir -p "$TMP/v021/herramientas" "$TMP/v021/nucleo/sql/migraciones" "$TMP/dist021" "$TMP/dist"
cp "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/v021/herramientas/"
cp "$RAIZ/CHANGELOG.md" "$TMP/v021/"
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-4][0-9]_*.sql "$RAIZ"/nucleo/sql/migraciones/05[0-7]_*.sql; do cp "$f" "$TMP/v021/nucleo/sql/migraciones/"; done
echo "0.21.0" > "$TMP/v021/VERSION_NUCLEO"
bash "$TMP/v021/herramientas/armar_instalacion.sh" "$TMP/dist021" >/dev/null || falla "no se armó el paquete 0.21.0"
bash "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/dist" >/dev/null || falla "no se armó el paquete actual"
ACT="$TMP/dist/actualizar_supabase_${VERSION}.sql"
[ -f "$ACT" ] || falla "no hay $ACT"
[ "$(ls "$TMP"/dist/actualizar_supabase_* | wc -l)" = "1" ] || falla "la actualización debía ser un solo archivo"
grep -q "Migración 058_" "$ACT" && ! grep -q "Migración 057_" "$ACT" || falla "la actualización debe traer solo la 058"

# 2) Base 0.21.0 como en Supabase, con ventas de enero.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase"
for p in "$TMP"/dist021/instalar_supabase_parte*.sql; do una "$VIEJA" "$p" >/dev/null || falla "parte 0.21.0 $(basename "$p")"; done
[ "$(q "$VIEJA" "SELECT version_nucleo || '/' || ultima_migracion FROM public.version_esquema")" = "0.21.0/57" ] || falla "no quedó en 0.21.0"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null || falla "preparar_datos"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -c "SELECT pruebas.preparar_enero()" >/dev/null || falla "datos"
foto() {
  psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" <<SQL
BEGIN;
SELECT pruebas.como('$1') \g /dev/null
SELECT jsonb_build_object('productos', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.codigo) FROM public.v_producto x),
  'dinero', public.donde_esta_mi_dinero(pruebas.empresa('A')) - 'hora_servidor',
  'resumen', public.resumen_hoy(pruebas.empresa('A')) - 'generado_en')::text;
ROLLBACK;
SQL
}
ANTES="$(foto dueno_a)"
[ -n "$ANTES" ] || falla "no se tomó la foto de antes"

# 3) Sin la 057: se rechaza sin tocar nada.
createdb "$OTRA"
psql -X -q -d "$OTRA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase (otra)"
for p in "$TMP"/dist021/instalar_supabase_parte*.sql; do
  grep -q "Migración 057_" "$p" && continue
  una "$OTRA" "$p" >/dev/null || falla "parte $(basename "$p") en la otra base"
done
ANTES_OTRA="$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")"
[ "$ANTES_OTRA" -lt 57 ] || falla "la otra base debía quedar antes de la 057"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó sin la 057"; fi
grep -q "FALTA_VERSION_ANTERIOR" "$TMP/sal.txt" && grep -q "057 (núcleo 0.21.0)" "$TMP/sal.txt" || falla "sin la 057 debía decir FALTA_VERSION_ANTERIOR 057 (núcleo 0.21.0): $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")" = "$ANTES_OTRA" ] || falla "la base sin la 057 quedó tocada"

# 4) Actualizar.
una "$VIEJA" "$ACT" >"$TMP/sal.txt" || falla "la actualización dio error: $(cat "$TMP/sal.txt")"
grep -q "^ACTUALIZADO A $VERSION | $VERSION | $NUM | $NUM" "$TMP/sal.txt" || falla "no dijo ACTUALIZADO A $VERSION: $(cat "$TMP/sal.txt")"
una "$VIEJA" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION | $NUM | $NUM" || falla "verificar_instalacion no dice TODO BIEN"
[ "$(q "$VIEJA" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'interno') AND pg_get_userbyid(p.proowner) <> 'supa_postgres'")" = "0" ] || falla "funciones con otro dueño"
[ "$(q "$VIEJA" "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la bitácora no quedó íntegra"
[ "$(foto dueno_a)" = "$ANTES" ] || falla "el dueño ve otra cosa después de actualizar"

# 5) Otra vez: no cambia nada.
antes="$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")"
una "$VIEJA" "$ACT" | grep -q "^ACTUALIZADO A $VERSION |" || falla "al repetir no dijo ACTUALIZADO"
[ "$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")" = "$antes" ] || falla "repetir cambió las migraciones"

# 6) Lo nuevo funciona: A tenía B1 y B2 (B1 queda como tienda); B no tenía bodega y recibe "Tienda principal";
#    el dueño cambia la tienda y el nombre legal.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "lo nuevo no funciona en la base actualizada"
BEGIN;
DO $$
BEGIN
  PERFORM pruebas.afirmar((SELECT string_agg(codigo || ':' || vende, ',' ORDER BY codigo) FROM public.bodega
                            WHERE empresa_id = pruebas.empresa('A')) = 'B1:true,B2:false', 'A: B1 tienda, B2 bodega');
  PERFORM pruebas.afirmar((SELECT string_agg(codigo || ':' || nombre || ':' || vende, ',') FROM public.bodega
                            WHERE empresa_id = pruebas.empresa('B')) = 'T001:Tienda principal:true', 'B: recibe su tienda');
END $$;
SELECT pruebas.como('dueno_a');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.guardar_bodega(pruebas.empresa('A'), jsonb_build_object('bodega_id', pruebas.id('B2'), 'vende', true), 'Vendemos desde atrás');
  PERFORM pruebas.afirmar((r->>'vende')::boolean, 'B2 pasa a tienda: ' || r::text);
  PERFORM pruebas.afirmar(NOT (SELECT vende FROM public.bodega WHERE id = pruebas.id('B1')), 'B1 deja de vender');
  r := public.configurar_datos_fiscales(pruebas.empresa('A'), '{"nombre": "Ferretería El Martillo S. de R.L."}', 'Nombre legal completo');
  PERFORM pruebas.afirmar(r->>'nombre' = 'Ferretería El Martillo S. de R.L.', 'nombre legal: ' || r::text);
END $$;
ROLLBACK;
SQL
PEND="$(PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" --solo-mostrar)" || falla "migrar.sh"
{ echo "$PEND" | grep -q "No hay migraciones pendientes" || echo "$PEND" | grep -qE "^  - 0(59|[6-9][0-9])_"; } \
  && ! echo "$PEND" | grep -E "^  - 0([0-4][0-9]|5[0-8])_" >/dev/null || falla "migrar.sh no reconoce la base actualizada: $PEND"
echo "ok"
