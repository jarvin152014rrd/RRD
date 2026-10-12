#!/usr/bin/env bash
# =====================================================================
# armador_sql.sh  -  Corre un guion SQL (por la ENTRADA ESTÁNDAR) en la base
# de un cliente, con la misma conexión segura de las otras herramientas.
# No se usa solo: lo llama herramientas/servidor_armador.js (marca, categorías
# y campos de la plantilla del rubro; datos de demostración).
#
#   bash herramientas/armador_sql.sh "postgresql://usuario@servidor:5432/base"
#
# La cadena va SIN clave. Nunca pregunta nada: la clave sale de ~/.pgpass o
# PGPASSFILE (o no hace falta: base local de pruebas). Todo o nada (el guion
# trae su BEGIN/COMMIT). Imprime lo que devuelve psql.
# =====================================================================
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
source "$RAIZ/herramientas/conexion.sh"
[ -n "${1:-}" ] || { echo "Uso: bash herramientas/armador_sql.sh CADENA < guion.sql" >&2; exit 2; }
trap conexion_limpiar EXIT
export CONEX_SIN_PEDIR_CLAVE=1
conexion_preparar "$1" argumento >/dev/null || exit 1
psql -X -w -q -tA -v ON_ERROR_STOP=1
