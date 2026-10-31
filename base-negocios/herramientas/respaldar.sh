#!/usr/bin/env bash
# =====================================================================
# respaldar.sh  -  Respaldo completo y CIFRADO de una base.
#
#   bash herramientas/respaldar.sh [cadena_de_conexion]
#
# Cadena SIN clave (la clave se pide sin mostrarla), o DATABASE_URL /
# PGHOST+PGDATABASE ya puestas (lo avisa). Ver herramientas/conexion.sh.
#
# Cifrado (nunca queda una copia sin cifrar en disco):
#   * age, si se indica RESPALDO_AGE_DESTINATARIO (llave pública "age1..."):
#     no pide nada; para abrirlo hace falta la llave privada (guárdela fuera).
#   * si no, gpg simétrico AES256: pide una frase (2 veces, mínimo 12 letras)
#     o la toma de RESPALDO_CLAVE_ARCHIVO (archivo con permisos 600).
#   * sin age ni gpg: avisa y exige escribir SIN CIFRAR.
# Resultado: respaldos/<identificador>_<fecha UTC>.dump.gpg (o .age),
# permisos 600. Cómo descifrar y restaurar: docs/PROCEDIMIENTOS.md P-03.
#
# Variables opcionales: DIR_RESPALDOS (defecto base-negocios/respaldos).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR_RESPALDOS="${DIR_RESPALDOS:-$RAIZ/respaldos}"
source "$RAIZ/herramientas/conexion.sh"

CADENA=""
for arg in "$@"; do
  case "$arg" in
    -h|--ayuda) sed -n '2,22p' "$0"; exit 0 ;;
    -*)         echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)          CADENA="$arg" ;;
  esac
done
ORIGEN="argumento"
if [ -z "$CADENA" ]; then
  if [ -n "${DATABASE_URL:-}" ]; then CADENA="$DATABASE_URL"; ORIGEN="DATABASE_URL"; else ORIGEN="variables"; fi
fi
trap conexion_limpiar EXIT
conexion_preparar "$CADENA" "$ORIGEN" || exit 1
conexion_mostrar
conexion_info || exit 1
conexion_identificador

NOMBRE="$(printf '%s' "$CONEX_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)"
echo "Respaldando (cifrado) en $DIR_RESPALDOS ..."
respaldo_hacer "$DIR_RESPALDOS/${NOMBRE}_$(date -u +%Y%m%dT%H%M%SZ)" || exit 1
echo "Respaldo listo: $RESPALDO_ARCHIVO"
echo "Guárdelo fuera de este equipo (disco cifrado o nube privada). Nunca en git."
