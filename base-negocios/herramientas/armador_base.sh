#!/usr/bin/env bash
# =====================================================================
# armador_base.sh  -  Prepara la base LOCAL de demostración del Armador.
# No se usa solo: lo llama herramientas/servidor_armador.js al arrancar.
#
#   bash herramientas/armador_base.sh        (BASE_ARMADOR, defecto demo_armador)
#
# 1. Enciende el PostgreSQL local de pruebas (base-negocios/.pgdata, sin red)
#    y lo deja encendido (lo usa el Armador).
# 2. Si la base no existe: la crea con el simulador de Supabase, todas las
#    migraciones y el emulador de la app. Si ya existe: solo aplica las
#    migraciones que falten. NUNCA borra la base ni sus empresas.
# El nombre debe empezar con "demo_" (así nunca se confunde con un cliente).
# =====================================================================
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export RAIZ
BASE_ARMADOR="${BASE_ARMADOR:-demo_armador}"
case "$BASE_ARMADOR" in demo_*) ;; *) echo "FALLA: la base del Armador debe llamarse demo_algo." >&2; exit 1 ;; esac

source "$RAIZ/herramientas/servidor_local.sh"
unset PGDATABASE DATABASE_URL
MANTENER_SERVIDOR=1
local_encender || exit 1
psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

if [ "$(psql_q -tA -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$BASE_ARMADOR'")" = "0" ]; then
  echo "Creando la base de demostración \"$BASE_ARMADOR\" (la primera vez tarda un poco) ..."
  createdb "$BASE_ARMADOR"
  psql_q -d "$BASE_ARMADOR" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
  PGDATABASE="$BASE_ARMADOR" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null
  psql_q -d "$BASE_ARMADOR" -f "$RAIZ/herramientas/emulador_supabase.sql" >/dev/null
else
  PGDATABASE="$BASE_ARMADOR" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null
  psql_q -d "$BASE_ARMADOR" -f "$RAIZ/herramientas/emulador_supabase.sql" >/dev/null
fi
echo "BASE_LISTA $BASE_ARMADOR $PGHOST $PGPORT"
