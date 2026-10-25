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
# 3b. Corre app-pruebas/probar_compras_dinero.cjs: Compras y Dinero (app 0.7.0), con
#    la misma base y el mismo servidor; después app-pruebas/probar_reportes.cjs (app 0.8.0).
# 3e. Corre app-pruebas/probar_0120.cjs: lo nuevo de la app 0.12.0 (núcleo 0.18.0).
# 3d. Corre app-pruebas/probar_fotos.cjs: fotos de productos (app 0.11.0) con el Storage mínimo del
#    servidor (al final: enciende las fotos y sube una).
# 4. Corre app-pruebas/probar_funciones.mjs: las Edge Functions reales de
#    supabase/functions/ contra el emulador (con una llave de servicio de
#    prueba) y la app de armar_app.sh con sus cabeceras de Netlify.
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
  [ -n "${ALMACEN:-}" ] && rm -rf "$ALMACEN"
  local_apagar
}
trap terminar EXIT

SOLO_PREPARAR=1 bash "$RAIZ/herramientas/demo_app.sh" || { echo "FALLA: no se pudo preparar la base de demo."; exit 1; }

# SERVICE_KEY: solo para probar las Edge Functions reales (probar_funciones.mjs).
export SERVICE_KEY="prueba-servicio-$RANDOM$RANDOM"
export ALMACEN="$(mktemp -d)"   # archivos del Storage de la demo (se borran al terminar)
BASE="$BASE_DEMO" PUERTO="$PUERTO_PRUEBA" REVISAR_SESION_SEGUNDOS=2 node "$RAIZ/herramientas/servidor_app.js" \
  > "$CAPTURAS/servidor.log" 2>&1 &
SERVIDOR_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PUERTO_PRUEBA/" && break
  sleep 0.2
done

URL_APP="http://127.0.0.1:$PUERTO_PRUEBA" node "$RAIZ/app-pruebas/probar_app.cjs"
codigo_app=$?
echo
URL_APP="http://127.0.0.1:$PUERTO_PRUEBA" node "$RAIZ/app-pruebas/probar_compras_dinero.cjs"
codigo_dinero=$?
echo
# 3c. Reportes y cierre de mes (app 0.8.0): va después porque reabre y cierra el mes pasado.
URL_APP="http://127.0.0.1:$PUERTO_PRUEBA" node "$RAIZ/app-pruebas/probar_reportes.cjs"
codigo_reportes=$?
echo
# 4. Las Edge Functions reales (supabase/functions) contra el mismo emulador, y la app armada
#    para Netlify (armar_app.sh) con sus cabeceras (CSP) en Chromium.
URL_APP="http://127.0.0.1:$PUERTO_PRUEBA" node "$RAIZ/app-pruebas/probar_funciones.mjs" 2> >(grep -v ExperimentalWarning >&2)
codigo_funciones=$?
echo
# 4b. App 0.12.0 (núcleo 0.18.0): precio mayorista, garantías, cheques y antigüedad de saldos.
URL_APP="http://127.0.0.1:$PUERTO_PRUEBA" node "$RAIZ/app-pruebas/probar_0120.cjs"
codigo_0120=$?
echo
# 5. Fotos de productos (app 0.11.0): al final, porque enciende las fotos y sube archivos.
URL_APP="http://127.0.0.1:$PUERTO_PRUEBA" node "$RAIZ/app-pruebas/probar_fotos.cjs"
codigo_fotos=$?
[ "$codigo_app" = "0" ] && [ "$codigo_dinero" = "0" ] && [ "$codigo_reportes" = "0" ] && [ "$codigo_funciones" = "0" ] && [ "$codigo_fotos" = "0" ] && [ "$codigo_0120" = "0" ]
