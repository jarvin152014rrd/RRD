#!/usr/bin/env bash
# =====================================================================
# demo_app.sh  -  Levanta la app con datos de demostración (ferretería).
#
#   bash herramientas/demo_app.sh            crea la base demo y arranca
#   SOLO_PREPARAR=1 bash herramientas/demo_app.sh   solo crea la base
#
# Qué hace:
#   1. Enciende el PostgreSQL local de pruebas (.pgdata, sin red).
#   2. Crea de cero la base "demo_app": simulador de Supabase + todas las
#      migraciones + emulador (herramientas/emulador_supabase.sql) + datos
#      de demostración (herramientas/demo_datos.sql). Nunca toca otra base.
#   3. Arranca herramientas/servidor_app.js en http://127.0.0.1:8080
#
# Usuarios: dueno@demo.hn, admin@demo.hn, cajero@demo.hn, vendedor@demo.hn
# Clave de todos: demo1234 (o la que ponga en DEMO_CLAVE).
# Variables: PUERTO, BASE_DEMO (demo_app), REVISAR_SESION_SEGUNDOS; NUCLEO_HASTA y NUCLEO_VERSION (probar la
# app con un núcleo anterior, ej. 053 y 0.17.0).
# =====================================================================
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export RAIZ
BASE_DEMO="${BASE_DEMO:-demo_app}"
case "$BASE_DEMO" in demo_*) ;; *) echo "FALLA: la base de demo debe llamarse demo_algo."; exit 1 ;; esac

source "$RAIZ/herramientas/servidor_local.sh"
unset PGDATABASE DATABASE_URL
local_encender || exit 1
MANTENER_SERVIDOR=1

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "Preparando la base de demostración \"$BASE_DEMO\" ..."
dropdb --if-exists "$BASE_DEMO" >/dev/null 2>&1
createdb "$BASE_DEMO"
psql_q -d "$BASE_DEMO" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
if [ -n "${NUCLEO_HASTA:-}" ]; then
  # Solo para probar la app con un núcleo anterior: NUCLEO_HASTA=053 NUCLEO_VERSION=0.17.0 (copia aparte de las
  # migraciones hasta esa, con su versión; el repositorio no se toca).
  VIEJO="$(mktemp -d)"
  mkdir -p "$VIEJO/nucleo/sql/migraciones"
  cp -r "$RAIZ/herramientas" "$VIEJO/"
  for f in "$RAIZ"/nucleo/sql/migraciones/[0-9][0-9][0-9]_*.sql; do
    n="$(basename "$f" | cut -c1-3)"
    [ "$((10#$n))" -le "$((10#$NUCLEO_HASTA))" ] && cp "$f" "$VIEJO/nucleo/sql/migraciones/"
  done
  echo "${NUCLEO_VERSION:?indique NUCLEO_VERSION}" > "$VIEJO/VERSION_NUCLEO"
  PGDATABASE="$BASE_DEMO" SIN_PREGUNTAR=1 SIN_RESPALDO=1 BASE_LOCAL_SOCKET="$PGHOST" bash "$VIEJO/herramientas/migrar.sh" >/dev/null
  rm -rf "$VIEJO"
else
  PGDATABASE="$BASE_DEMO" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null
fi
psql_q -d "$BASE_DEMO" -f "$RAIZ/herramientas/emulador_supabase.sql" >/dev/null
psql_q -d "$BASE_DEMO" -f "$RAIZ/herramientas/demo_datos.sql" >/dev/null
echo "Base lista."

if [ "${SOLO_PREPARAR:-0}" = "1" ]; then exit 0; fi

echo
echo "Usuarios: dueno@demo.hn, admin@demo.hn, cajero@demo.hn, vendedor@demo.hn"
echo "Clave:    ${DEMO_CLAVE:-demo1234}"
echo "Abra el navegador en http://127.0.0.1:${PUERTO:-8080}  (Ctrl+C para salir)"
BASE="$BASE_DEMO" exec node "$RAIZ/herramientas/servidor_app.js"
