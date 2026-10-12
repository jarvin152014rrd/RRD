#!/usr/bin/env bash
# =====================================================================
# probar_app.sh  -  Prueba la app en un navegador real (Chromium).
#
#   bash herramientas/probar_app.sh
#
# 1. Crea la base "demo_pruebas_app" con los datos de demostración.
# 2. Arranca herramientas/servidor_app.js en el puerto 8091 (revisa la
#    sesión cada 2 segundos para probar el "cerrar a distancia").
# 3. Corre app-pruebas/probar_app.cjs con Playwright (Chromium ya instalado
#    en /opt/pw-browsers; no descarga nada).
# Capturas en app-pruebas/capturas/ (no van a git).
# =====================================================================
set -uo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export RAIZ
export BASE_DEMO=demo_pruebas_app
PUERTO_PRUEBA="${PUERTO_PRUEBA:-8091}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"
export NODE_PATH="${NODE_PATH:-}:$RAIZ/app-pruebas/node_modules:/opt/node22/lib/node_modules"
export CAPTURAS="$RAIZ/app-pruebas/capturas"
mkdir -p "$CAPTURAS"

source "$RAIZ/herramientas/servidor_local.sh"
unset PGDATABASE DATABASE_URL
local_encender || exit 1

SERVIDOR_PID=""
terminar() {
  [ -n "$SERVIDOR_PID" ] && kill "$SERVIDOR_PID" 2>/dev/null
  dropdb --if-exists "$BASE_DEMO" >/dev/null 2>&1
  local_apagar
}
trap terminar EXIT

SOLO_PREPARAR=1 bash "$RAIZ/herramientas/demo_app.sh" || { echo "FALLA: no se pudo preparar la base de demo."; exit 1; }

BASE="$BASE_DEMO" PUERTO="$PUERTO_PRUEBA" REVISAR_SESION_SEGUNDOS=2 node "$RAIZ/herramientas/servidor_app.js" \
  > "$CAPTURAS/servidor.log" 2>&1 &
SERVIDOR_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PUERTO_PRUEBA/" && break
  sleep 0.2
done

URL_APP="http://127.0.0.1:$PUERTO_PRUEBA" node "$RAIZ/app-pruebas/probar_app.cjs"
