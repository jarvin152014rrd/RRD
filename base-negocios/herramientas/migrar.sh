#!/usr/bin/env bash
# =====================================================================
# migrar.sh  -  Aplica las migraciones pendientes, en orden, una vez.
#
#   bash herramientas/migrar.sh [--solo-mostrar] [cadena_de_conexion]
#
# Cadena SIN clave (la clave se pide sin mostrarla):
#   bash herramientas/migrar.sh "postgresql://postgres@db.<ref>.supabase.co:5432/postgres"
# También acepta DATABASE_URL o PGHOST/PGDATABASE ya puestas (y lo AVISA).
# La clave nunca se pasa como argumento a psql ni pg_dump: va en un archivo
# temporal con permisos 600 que se borra al terminar (ver conexion.sh).
#
# Pasos:
#   1. Muestra a qué base se conecta (servidor completo, base, usuario) y
#      qué empresas tiene.
#   2. Lista las migraciones pendientes. Con --solo-mostrar termina aquí.
#   3. Pide escribir un identificador único: la referencia del proyecto
#      de Supabase, o el nombre de la empresa que ya está en la base, o
#      (base nueva local) el nombre de la base.
#   4. Respaldo completo CIFRADO en base-negocios/respaldos/ (age o gpg;
#      ver docs/PROCEDIMIENTOS.md P-03). Si el respaldo falla, no sigue.
#   5. Aplica cada migración completa o nada (una transacción por archivo).
#
# Reglas:
#   * Solo hacia adelante: si una migración ya aplicada fue modificada,
#     se detiene con error (cree una migración nueva para corregir).
#
# Variables opcionales (SOLO con base local de pruebas):
#   SIN_PREGUNTAR=1   no pide confirmación
#   SIN_RESPALDO=1    no hace respaldo
#   DIR_RESPALDOS     carpeta de respaldos (defecto base-negocios/respaldos)
#   Del respaldo: RESPALDO_AGE_DESTINATARIO, RESPALDO_CLAVE_ARCHIVO (ver conexion.sh)
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR_MIG="$RAIZ/nucleo/sql/migraciones"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
DIR_RESPALDOS="${DIR_RESPALDOS:-$RAIZ/respaldos}"
source "$RAIZ/herramientas/conexion.sh"

SOLO_MOSTRAR=0
CADENA=""
for arg in "$@"; do
  case "$arg" in
    --solo-mostrar) SOLO_MOSTRAR=1 ;;
    -h|--ayuda)     sed -n '2,36p' "$0"; exit 0 ;;
    -*)             echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)              CADENA="$arg" ;;
  esac
done

ORIGEN="argumento"
if [ -z "$CADENA" ]; then
  if [ -n "${DATABASE_URL:-}" ]; then CADENA="$DATABASE_URL"; ORIGEN="DATABASE_URL"; else ORIGEN="variables"; fi
fi
trap conexion_limpiar EXIT
conexion_preparar "$CADENA" "$ORIGEN" || exit 1

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# ---------------------------------------------------------------------
# 1) ¿A qué base estoy conectado?
# ---------------------------------------------------------------------
conexion_mostrar
conexion_info || exit 1
BASE="$CONEX_BASE"

# ---------------------------------------------------------------------
# 2) Migraciones pendientes (y revisión de las ya aplicadas)
# ---------------------------------------------------------------------
existe_tabla="$(psql_q -tAc "SELECT to_regclass('interno._migraciones') IS NOT NULL")"
pendientes=()

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
  pendientes+=("$archivo")
done

if [ "${#pendientes[@]}" -eq 0 ]; then
  echo "No hay migraciones pendientes. La base está al día (núcleo $VERSION)."
  exit 0
fi

echo "Migraciones pendientes (${#pendientes[@]}):"
for archivo in "${pendientes[@]}"; do echo "  - $(basename "$archivo" .sql)"; done

if [ "$SOLO_MOSTRAR" = "1" ]; then
  echo "(--solo-mostrar: no se aplicó nada)"
  exit 0
fi

# ---------------------------------------------------------------------
# 3) Confirmación con un identificador único del proyecto
# ---------------------------------------------------------------------
conexion_identificador
conexion_confirmar "aplicar las migraciones" || exit 1

# ---------------------------------------------------------------------
# 4) Respaldo previo (cifrado)
# ---------------------------------------------------------------------
if [ "${SIN_RESPALDO:-0}" = "1" ]; then
  conexion_es_local || { echo "ERROR: SIN_RESPALDO=1 solo se acepta con la base local de pruebas." >&2; exit 1; }
  echo "AVISO: sin respaldo previo (SIN_RESPALDO=1). Solo para bases de prueba."
else
  NOMBRE="$(printf '%s' "$CONEX_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)"
  echo "Respaldando la base (cifrado) en $DIR_RESPALDOS ..."
  if ! respaldo_hacer "$DIR_RESPALDOS/${NOMBRE}_$(date -u +%Y%m%dT%H%M%SZ)"; then
    echo "ERROR: no se pudo hacer el respaldo. No se aplicó nada." >&2
    echo "       (pg_dump debe ser de la misma versión que el servidor o más nueva)" >&2
    exit 1
  fi
  echo "Respaldo listo: $RESPALDO_ARCHIVO  (para restaurar: docs/PROCEDIMIENTOS.md P-03)"
fi

# ---------------------------------------------------------------------
# 5) Aplicar
# ---------------------------------------------------------------------
aplicadas=0
for archivo in "${pendientes[@]}"; do
  base="$(basename "$archivo" .sql)"
  numero=$((10#${base%%_*}))
  suma="$(sha256sum "$archivo" | cut -d' ' -f1)"
  echo "  aplicando $base"
  # -1: todo el archivo y su registro en una sola transacción (todo-o-nada).
  psql_q -1 -f "$archivo" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo)
        VALUES ($numero, '$base', '$suma', '$VERSION')"
  aplicadas=$((aplicadas + 1))
done

echo "  migraciones aplicadas ahora: $aplicadas (núcleo $VERSION)"
