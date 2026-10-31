#!/usr/bin/env bash
# =====================================================================
# probar_armador.sh  -  Prueba el Armador del proveedor en un navegador real.
#
#   bash herramientas/probar_armador.sh
#
# 1. Crea una clave de prueba y una carpeta de clientes TEMPORALES (nunca toca
#    clientes/ ni la clave real del proveedor).
# 2. Arranca herramientas/servidor_armador.js (puerto 8093, app del cliente en
#    8094) con la base local "demo_pruebas_armador" (se borra al terminar).
# 3. Corre app-pruebas/probar_armador.cjs con Playwright.
# Capturas p4_*.png en CAPTURAS (defecto app-pruebas/capturas/, no van a git).
# =====================================================================
set -uo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export RAIZ
export BASE_ARMADOR=demo_pruebas_armador
export PUERTO_ARMADOR="${PUERTO_ARMADOR:-8093}" PUERTO_APP_CLIENTE="${PUERTO_APP_CLIENTE:-8094}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"
export NODE_PATH="${NODE_PATH:-}:$RAIZ/app-pruebas/node_modules:/opt/node22/lib/node_modules"
export CAPTURAS="${CAPTURAS:-$RAIZ/app-pruebas/capturas}"
mkdir -p "$CAPTURAS"

source "$RAIZ/herramientas/servidor_local.sh"
unset PGDATABASE DATABASE_URL
local_encender || exit 1
TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/armador_prueba.XXXXXX")"
export ARMADOR_CLAVE_ARCHIVO="$TMP/clave" DIR_CLIENTES="$TMP/clientes" CLAVE_ARMADOR="clave-de-prueba-$RANDOM$RANDOM"
SERVIDOR_PID=""
terminar() {
  [ -n "$SERVIDOR_PID" ] && kill "$SERVIDOR_PID" 2>/dev/null
  sleep 0.5
  dropdb --if-exists "$BASE_ARMADOR" >/dev/null 2>&1
  rm -rf "$TMP"
  local_apagar
}
trap terminar EXIT

dropdb --if-exists "$BASE_ARMADOR" >/dev/null 2>&1
printf '%s\n' "$CLAVE_ARMADOR" | node "$RAIZ/herramientas/servidor_armador.js" --poner-clave >/dev/null || { echo "FALLA: no se pudo poner la clave."; exit 1; }
node "$RAIZ/herramientas/servidor_armador.js" > "$CAPTURAS/armador.log" 2>&1 &
SERVIDOR_PID=$!
for _ in $(seq 1 600); do
  grep -q "Base de demostración lista" "$CAPTURAS/armador.log" 2>/dev/null && break
  kill -0 "$SERVIDOR_PID" 2>/dev/null || { echo "FALLA: el Armador no arrancó:"; cat "$CAPTURAS/armador.log"; exit 1; }
  sleep 0.2
done
export PGDATABASE="$BASE_ARMADOR"
URL_ARMADOR="http://127.0.0.1:$PUERTO_ARMADOR" node "$RAIZ/app-pruebas/probar_armador.cjs"
