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
# Variables: PUERTO, BASE_DEMO (demo_app), REVISAR_SESION_SEGUNDOS.
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
PGDATABASE="$BASE_DEMO" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null
psql_q -d "$BASE_DEMO" -f "$RAIZ/herramientas/emulador_supabase.sql" >/dev/null
psql_q -d "$BASE_DEMO" -f "$RAIZ/herramientas/demo_datos.sql" >/dev/null
echo "Base lista."

if [ "${SOLO_PREPARAR:-0}" = "1" ]; then exit 0; fi

echo
echo "Usuarios: dueno@demo.hn, admin@demo.hn, cajero@demo.hn, vendedor@demo.hn"
echo "Clave:    ${DEMO_CLAVE:-demo1234}"
echo "Abra el navegador en http://127.0.0.1:${PUERTO:-8080}  (Ctrl+C para salir)"
BASE="$BASE_DEMO" exec node "$RAIZ/herramientas/servidor_app.js"
