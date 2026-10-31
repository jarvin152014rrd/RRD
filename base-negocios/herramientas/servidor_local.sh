#!/usr/bin/env bash
# =====================================================================
# servidor_local.sh  -  Funciones para el PostgreSQL local de pruebas.
# No se ejecuta solo: lo cargan probar.sh y nuevo_cliente.sh con "source".
#
#   local_encender   crea (si hace falta) y arranca el servidor en
#                    base-negocios/.pgdata, solo por socket (sin red)
#   local_apagar     lo apaga si lo encendimos nosotros
#                    (salvo MANTENER_SERVIDOR=1)
#
# Variables opcionales: PGBIN, PRUEBAS_PGDATA, PRUEBAS_PUERTO
# =====================================================================

RAIZ="${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
DATOS="${PRUEBAS_PGDATA:-$RAIZ/.pgdata}"
PUERTO="${PRUEBAS_PUERTO:-54329}"
ENCENDI_YO=0

# PostgreSQL no arranca como root: en ese caso usamos el usuario postgres.
como_postgres() {
  if [ "$(id -u)" = "0" ]; then runuser -u postgres -- "$@"; else "$@"; fi
}

local_encender() {
  export PATH="$PGBIN:$PATH"
  if [ ! -f "$DATOS/PG_VERSION" ]; then
    echo "Creando servidor local de pruebas en $DATOS ..."
    mkdir -p "$DATOS"
    [ "$(id -u)" = "0" ] && chown postgres:postgres "$DATOS"
    chmod 700 "$DATOS"
    como_postgres initdb -D "$DATOS" -U postgres --auth=trust --encoding=UTF8 \
      --locale=C.UTF-8 >/dev/null || { echo "FALLA: no se pudo crear el servidor (initdb)."; return 1; }
  fi
  if ! como_postgres pg_ctl -D "$DATOS" status >/dev/null 2>&1; then
    como_postgres pg_ctl -D "$DATOS" -l "$DATOS/servidor.log" -w \
      -o "-p $PUERTO -k $DATOS -c listen_addresses='' -c timezone=UTC" start >/dev/null \
      || { echo "FALLA: no arrancó PostgreSQL. Revise $DATOS/servidor.log"; return 1; }
    ENCENDI_YO=1
  fi
  export PGHOST="$DATOS" PGPORT="$PUERTO" PGUSER="postgres"
  unset PGPASSWORD
}

local_apagar() {
  if [ "$ENCENDI_YO" = "1" ] && [ "${MANTENER_SERVIDOR:-0}" != "1" ]; then
    como_postgres pg_ctl -D "$DATOS" -m fast stop >/dev/null 2>&1
  fi
}
