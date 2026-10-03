#!/usr/bin/env bash
# =====================================================================
# migrar.sh  -  Aplica las migraciones pendientes, en orden, una vez.
#
#   bash herramientas/migrar.sh [--solo-mostrar] [cadena_de_conexion]
#
# Se conecta con una cadena de conexión como argumento
# ("postgresql://usuario:clave@host:5432/base"), o con la variable
# DATABASE_URL, o con las variables normales de PostgreSQL
# (PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD).
#
# Pasos:
#   1. Muestra a qué base se conectó (nombre, servidor, usuario).
#   2. Lista las migraciones pendientes. Con --solo-mostrar termina aquí.
#   3. Pide escribir el nombre de la base para confirmar.
#   4. Respaldo completo con pg_dump en base-negocios/respaldos/
#      (carpeta ignorada por git). Si el respaldo falla, no sigue.
#   5. Aplica cada migración completa o nada (una transacción por archivo).
#
# Reglas:
#   * Solo hacia adelante: si una migración ya aplicada fue modificada,
#     se detiene con error (cree una migración nueva para corregir).
#
# Variables opcionales:
#   SIN_PREGUNTAR=1   no pide confirmación (solo pruebas automáticas)
#   SIN_RESPALDO=1    no hace respaldo (solo bases de prueba desechables)
#   DIR_RESPALDOS     carpeta de respaldos (defecto base-negocios/respaldos)
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR_MIG="$RAIZ/nucleo/sql/migraciones"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
DIR_RESPALDOS="${DIR_RESPALDOS:-$RAIZ/respaldos}"

SOLO_MOSTRAR=0
CONEXION=()
for arg in "$@"; do
  case "$arg" in
    --solo-mostrar) SOLO_MOSTRAR=1 ;;
    -h|--ayuda)     sed -n '2,33p' "$0"; exit 0 ;;
    -*)             echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)              CONEXION=("$arg") ;;
  esac
done

[ "${#CONEXION[@]}" -eq 0 ] && [ -n "${DATABASE_URL:-}" ] && CONEXION=("$DATABASE_URL")

psql_q() { psql "${CONEXION[@]}" -X -q -v ON_ERROR_STOP=1 "$@"; }

# ---------------------------------------------------------------------
# 1) ¿A qué base estoy conectado?
# ---------------------------------------------------------------------
if ! info="$(psql_q -tA -F'|' -c "SELECT current_database(),
      coalesce(inet_server_addr()::text, 'socket local'), current_setting('port'),
      current_user, current_setting('server_version')")"; then
  echo "ERROR: no se pudo conectar a la base. Revise PGHOST/PGDATABASE o la cadena de conexión." >&2
  exit 1
fi
IFS='|' read -r BASE SERVIDOR PUERTO USUARIO VERSION_PG <<< "$info"
echo "Conectado a:  base \"$BASE\"  en $SERVIDOR:$PUERTO  como $USUARIO  (PostgreSQL $VERSION_PG)"

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
# 3) Confirmación: escribir el nombre de la base
# ---------------------------------------------------------------------
if [ "${SIN_PREGUNTAR:-0}" != "1" ]; then
  printf 'Para aplicarlas escriba el nombre de la base (%s): ' "$BASE"
  respuesta=""
  read -r respuesta || true
  if [ "$respuesta" != "$BASE" ]; then
    echo
    echo "Cancelado: el nombre no coincide. No se aplicó nada." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------
# 4) Respaldo previo
# ---------------------------------------------------------------------
if [ "${SIN_RESPALDO:-0}" = "1" ]; then
  echo "AVISO: sin respaldo previo (SIN_RESPALDO=1). Use esto solo en bases de prueba."
else
  mkdir -p "$DIR_RESPALDOS"
  RESPALDO="$DIR_RESPALDOS/${BASE}_$(date -u +%Y%m%dT%H%M%SZ).dump"
  echo "Respaldando la base en $RESPALDO ..."
  if ! pg_dump "${CONEXION[@]}" --format=custom --file="$RESPALDO" || [ ! -s "$RESPALDO" ]; then
    rm -f "$RESPALDO"
    echo "ERROR: no se pudo hacer el respaldo. No se aplicó nada." >&2
    echo "       (pg_dump debe ser de la misma versión que el servidor o más nueva)" >&2
    exit 1
  fi
  echo "Respaldo listo. Para restaurar: ver docs/PROCEDIMIENTOS.md"
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
