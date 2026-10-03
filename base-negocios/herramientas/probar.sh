#!/usr/bin/env bash
# =====================================================================
# probar.sh  -  Corre TODAS las pruebas del núcleo en una base local.
#
#   bash herramientas/probar.sh
#
# Qué hace:
#   1. Levanta un PostgreSQL 16 local en base-negocios/.pgdata (lo crea
#      la primera vez; no usa red, solo un socket local).
#   2. Crea una base "plantilla" vacía y le aplica: simulador de
#      Supabase + migraciones en orden + datos de prueba.
#   3. Cada prueba corre en su propia copia de la plantilla, así una
#      prueba nunca afecta a otra. Hay dos tipos:
#        prueba_NN_*.sql  se corre con psql (variable :version_nucleo)
#        prueba_NN_*.sh   se corre con bash, recibe el nombre de su base
#                         como $1 (para probar herramientas y varias
#                         conexiones a la vez)
#   4. Muestra OK / FALLA y termina con código 1 si algo falló.
#
# Variables opcionales: PGBIN, PRUEBAS_PGDATA, PRUEBAS_PUERTO,
#                       MANTENER_SERVIDOR=1 (no apagarlo al final)
# =====================================================================
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR_PRUEBAS="$RAIZ/nucleo/pruebas"
PLANTILLA="nucleo_plantilla"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
export RAIZ

falla_fatal() { echo; echo "FALLA: $*"; exit 1; }

# ---------------------------------------------------------------------
# 1) Servidor local
# ---------------------------------------------------------------------
source "$RAIZ/herramientas/servidor_local.sh"
# Las pruebas NUNCA usan una base real aunque la terminal tenga una puesta.
unset PGDATABASE DATABASE_URL
local_encender || exit 1
trap local_apagar EXIT

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# ---------------------------------------------------------------------
# 2) Plantilla: simulador + migraciones + datos de prueba
# ---------------------------------------------------------------------
echo "Preparando base de pruebas ..."
dropdb --if-exists "$PLANTILLA" >/dev/null 2>&1
createdb "$PLANTILLA" || falla_fatal "no se pudo crear la base plantilla."

psql_q -d "$PLANTILLA" -f "$DIR_PRUEBAS/simular_supabase.sql" >/dev/null \
  || falla_fatal "error en simular_supabase.sql"
# Base desechable: sin confirmación ni respaldo.
PGDATABASE="$PLANTILLA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null \
  || falla_fatal "error aplicando migraciones."
psql_q -d "$PLANTILLA" -f "$DIR_PRUEBAS/preparar_datos.sql" >/dev/null \
  || falla_fatal "error en preparar_datos.sql"

# ---------------------------------------------------------------------
# 3) Pruebas (cada una en su copia)
# ---------------------------------------------------------------------
echo
echo "Corriendo pruebas:"
total=0; buenas=0; malas=()

# .sql y .sh juntos, en orden de número.
mapfile -t archivos < <(ls "$DIR_PRUEBAS"/prueba_*.sql "$DIR_PRUEBAS"/prueba_*.sh 2>/dev/null | sort)
for archivo in "${archivos[@]}"; do
  nombre="$(basename "$archivo")"; nombre="${nombre%.*}"
  que="$(grep -m1 -E '^(--|#) PRUEBA:' "$archivo" | sed -E 's/^(--|#) PRUEBA: *//')"
  base="t_${nombre}"
  total=$((total + 1))

  dropdb --if-exists "$base" >/dev/null 2>&1
  if ! createdb -T "$PLANTILLA" "$base" >/dev/null 2>&1; then
    echo "  FALLA  $nombre  (no se pudo copiar la plantilla)"; malas+=("$nombre"); continue
  fi

  if [[ "$archivo" == *.sql ]]; then
    salida="$(psql_q -d "$base" -v version_nucleo="$VERSION" -f "$archivo" 2>&1)"; codigo=$?
  else
    salida="$(bash "$archivo" "$base" 2>&1)"; codigo=$?
  fi

  if [ "$codigo" = "0" ]; then
    echo "  OK     $nombre - $que"
    buenas=$((buenas + 1))
  else
    echo "  FALLA  $nombre - $que"
    echo "$salida" | grep -E 'ERROR|FALLA|DETAIL|CONTEXT' | head -8 | sed 's/^/           /'
    malas+=("$nombre")
  fi
  dropdb --if-exists "$base" >/dev/null 2>&1
done

echo
if [ "${#malas[@]}" -eq 0 ]; then
  echo "RESULTADO: TODO OK ($buenas de $total pruebas pasaron)"
  exit 0
else
  echo "RESULTADO: FALLA ($buenas de $total pasaron). Fallaron: ${malas[*]}"
  exit 1
fi
