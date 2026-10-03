#!/usr/bin/env bash
# =====================================================================
# migrar.sh  -  Aplica las migraciones pendientes, en orden, una vez.
#
# Usa las variables normales de PostgreSQL para conectarse:
#   PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD
# o una cadena de conexión como primer argumento.
#
# Reglas:
#   * Cada migración se aplica completa o no se aplica (una transacción).
#   * Solo hacia adelante: si una migración ya aplicada fue modificada,
#     se detiene con error (cree una migración nueva para corregir).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR_MIG="$RAIZ/nucleo/sql/migraciones"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
CONEXION=("${1:-}")
[ -z "${CONEXION[0]}" ] && CONEXION=()

psql_q() { psql "${CONEXION[@]}" -X -q -v ON_ERROR_STOP=1 "$@"; }

existe_tabla="$(psql_q -tAc "SELECT to_regclass('interno._migraciones') IS NOT NULL")"
aplicadas=0

for archivo in "$DIR_MIG"/[0-9][0-9][0-9]_*.sql; do
  base="$(basename "$archivo" .sql)"
  numero=$((10#${base%%_*}))
  suma="$(sha256sum "$archivo" | cut -d' ' -f1)"

  if [ "$existe_tabla" = "t" ]; then
    previa="$(psql_q -tAc "SELECT checksum FROM interno._migraciones WHERE numero = $numero")"
    if [ -n "$previa" ]; then
      if [ "$previa" != "$suma" ]; then
        echo "ERROR: la migración $base ya estaba aplicada y su archivo fue modificado." >&2
        echo "       Las migraciones no se editan: cree una nueva con el siguiente número." >&2
        exit 1
      fi
      continue
    fi
  fi

  echo "  aplicando $base"
  # -1: todo el archivo y su registro en una sola transacción (todo-o-nada).
  psql_q -1 -f "$archivo" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo)
        VALUES ($numero, '$base', '$suma', '$VERSION')"
  existe_tabla="t"
  aplicadas=$((aplicadas + 1))
done

echo "  migraciones aplicadas ahora: $aplicadas"
