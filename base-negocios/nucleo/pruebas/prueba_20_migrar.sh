#!/usr/bin/env bash
# PRUEBA: migrar.sh muestra la base, lista pendientes (--solo-mostrar), pide el identificador y respalda CIFRADO (gpg) antes de aplicar
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
MIGRAR="$RAIZ/herramientas/migrar.sh"
NUEVA="${BASE}_vacia"
TMP="$(mktemp -d)"
limpiar() { dropdb --if-exists "$NUEVA" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
(umask 077; echo "frase-de-prueba-muy-larga" > "$TMP/frase")
export RESPALDO_CLAVE_ARCHIVO="$TMP/frase"
total_mig="$(ls "$RAIZ"/nucleo/sql/migraciones/[0-9][0-9][0-9]_*.sql | wc -l)"

# 1) Base al día: lo dice y muestra a qué base se conectó.
salida="$(PGDATABASE="$BASE" bash "$MIGRAR" --solo-mostrar)"
echo "$salida" | grep -q "base \"$BASE\"" || falla "no muestra el nombre de la base"
echo "$salida" | grep -q "No hay migraciones pendientes" || falla "debía decir que está al día"

# 2) Base vacía: --solo-mostrar lista todas y no aplica nada.
createdb "$NUEVA"
psql -X -q -d "$NUEVA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
salida="$(PGDATABASE="$NUEVA" bash "$MIGRAR" --solo-mostrar)"
echo "$salida" | grep -q "Migraciones pendientes ($total_mig)" || falla "no lista las $total_mig pendientes"
echo "$salida" | grep -q -- "- 001_base" || falla "no lista 001_base"
[ "$(psql -X -tA -d "$NUEVA" -c "SELECT to_regclass('interno._migraciones') IS NULL")" = "t" ] \
  || falla "--solo-mostrar aplicó algo"

# 3) Nombre equivocado: cancela, no respalda, no aplica.
if echo "otra_base" | PGDATABASE="$NUEVA" DIR_RESPALDOS="$TMP" bash "$MIGRAR" >"$TMP/salida.txt" 2>&1; then
  falla "debía cancelar con nombre equivocado"
fi
grep -q "Cancelado" "$TMP/salida.txt" || falla "no dice Cancelado"
[ -z "$(ls "$TMP"/*.dump* 2>/dev/null)" ] || falla "respaldó aunque canceló"
[ "$(psql -X -tA -d "$NUEVA" -c "SELECT to_regclass('interno._migraciones') IS NULL")" = "t" ] \
  || falla "aplicó aunque canceló"

# 4) Nombre correcto: respalda y aplica todo.
echo "$NUEVA" | PGDATABASE="$NUEVA" DIR_RESPALDOS="$TMP" bash "$MIGRAR" >"$TMP/salida.txt" 2>&1 \
  || { cat "$TMP/salida.txt"; falla "no aplicó con el nombre correcto"; }
respaldo="$(ls "$TMP"/"$NUEVA"_*.dump.gpg 2>/dev/null | head -1)"
[ -s "$respaldo" ] || falla "no creó el respaldo cifrado (.dump.gpg)"
[ "$(stat -c %a "$respaldo")" = "600" ] || falla "el respaldo no tiene permisos 600"
[ -z "$(ls "$TMP"/*.dump 2>/dev/null)" ] || falla "quedó una copia sin cifrar"
if pg_restore --list "$respaldo" >/dev/null 2>&1; then falla "el respaldo se lee sin descifrar"; fi
grep -a -q "error_catalogo" "$respaldo" && falla "el respaldo deja ver texto de la base"
mkdir -m 700 "$TMP/gnupg"
GNUPGHOME="$TMP/gnupg" gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$TMP/frase" --decrypt "$respaldo" \
  | pg_restore --list >/dev/null || falla "el respaldo descifrado no se puede leer con pg_restore"
[ "$(psql -X -tA -d "$NUEVA" -c "SELECT count(*) FROM interno._migraciones")" = "$total_mig" ] \
  || falla "no quedaron registradas las $total_mig migraciones"

# 5) Sin confirmar por variable (pruebas automáticas) y sin nada pendiente: no respalda de más.
antes="$(ls "$TMP"/*.dump.gpg | wc -l)"
SIN_PREGUNTAR=1 PGDATABASE="$NUEVA" DIR_RESPALDOS="$TMP" bash "$MIGRAR" | grep -q "No hay migraciones pendientes" \
  || falla "segunda corrida debía estar al día"
[ "$(ls "$TMP"/*.dump.gpg | wc -l)" = "$antes" ] || falla "respaldó sin tener nada que aplicar"

# 6) La carpeta de respaldos del proyecto está ignorada por git.
grep -qx "respaldos/" "$RAIZ/.gitignore" || falla "respaldos/ no está en .gitignore"
echo "ok"
