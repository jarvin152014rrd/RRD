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
#      prueba nunca afecta a otra.
#   4. Muestra OK / FALLA y termina con código 1 si algo falló.
#
# Variables opcionales: PGBIN, PRUEBAS_PGDATA, PRUEBAS_PUERTO,
#                       MANTENER_SERVIDOR=1 (no apagarlo al final)
# =====================================================================
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
DATOS="${PRUEBAS_PGDATA:-$RAIZ/.pgdata}"
PUERTO="${PRUEBAS_PUERTO:-54329}"
DIR_PRUEBAS="$RAIZ/nucleo/pruebas"
PLANTILLA="nucleo_plantilla"

export PATH="$PGBIN:$PATH"
export PGHOST="$DATOS" PGPORT="$PUERTO" PGUSER="postgres"
unset PGDATABASE PGPASSWORD

# PostgreSQL no arranca como root: en ese caso usamos el usuario postgres.
como_postgres() {
  if [ "$(id -u)" = "0" ]; then runuser -u postgres -- "$@"; else "$@"; fi
}

falla_fatal() { echo; echo "FALLA: $*"; exit 1; }

# ---------------------------------------------------------------------
# 1) Servidor local
# ---------------------------------------------------------------------
if [ ! -f "$DATOS/PG_VERSION" ]; then
  echo "Creando servidor local de pruebas en $DATOS ..."
  mkdir -p "$DATOS"
  [ "$(id -u)" = "0" ] && chown postgres:postgres "$DATOS"
  chmod 700 "$DATOS"
  como_postgres initdb -D "$DATOS" -U postgres --auth=trust --encoding=UTF8 \
    --locale=C.UTF-8 >/dev/null || falla_fatal "no se pudo crear el servidor (initdb)."
fi

ENCENDI_YO=0
if ! como_postgres pg_ctl -D "$DATOS" status >/dev/null 2>&1; then
  como_postgres pg_ctl -D "$DATOS" -l "$DATOS/servidor.log" -w \
    -o "-p $PUERTO -k $DATOS -c listen_addresses='' -c timezone=UTC" start >/dev/null \
    || falla_fatal "no arrancó PostgreSQL. Revise $DATOS/servidor.log"
  ENCENDI_YO=1
fi

apagar() {
  if [ "$ENCENDI_YO" = "1" ] && [ "${MANTENER_SERVIDOR:-0}" != "1" ]; then
    como_postgres pg_ctl -D "$DATOS" -m fast stop >/dev/null 2>&1
  fi
}
trap apagar EXIT

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# ---------------------------------------------------------------------
# 2) Plantilla: simulador + migraciones + datos de prueba
# ---------------------------------------------------------------------
echo "Preparando base de pruebas ..."
dropdb --if-exists "$PLANTILLA" >/dev/null 2>&1
createdb "$PLANTILLA" || falla_fatal "no se pudo crear la base plantilla."

psql_q -d "$PLANTILLA" -f "$DIR_PRUEBAS/simular_supabase.sql" >/dev/null \
  || falla_fatal "error en simular_supabase.sql"
PGDATABASE="$PLANTILLA" bash "$RAIZ/herramientas/migrar.sh" \
  || falla_fatal "error aplicando migraciones."
psql_q -d "$PLANTILLA" -f "$DIR_PRUEBAS/preparar_datos.sql" >/dev/null \
  || falla_fatal "error en preparar_datos.sql"

# ---------------------------------------------------------------------
# 3) Pruebas (cada una en su copia)
# ---------------------------------------------------------------------
echo
echo "Corriendo pruebas:"
total=0; buenas=0; malas=()

for archivo in "$DIR_PRUEBAS"/prueba_*.sql; do
  nombre="$(basename "$archivo" .sql)"
  que="$(grep -m1 '^-- PRUEBA:' "$archivo" | sed 's/^-- PRUEBA: *//')"
  base="t_${nombre}"
  total=$((total + 1))

  dropdb --if-exists "$base" >/dev/null 2>&1
  if ! createdb -T "$PLANTILLA" "$base" >/dev/null 2>&1; then
    echo "  FALLA  $nombre  (no se pudo copiar la plantilla)"; malas+=("$nombre"); continue
  fi

  if salida="$(psql_q -d "$base" -f "$archivo" 2>&1)"; then
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
