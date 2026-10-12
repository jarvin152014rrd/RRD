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
# Opción --paquete (etapa 6): en vez del simulador + migrar.sh, la plantilla
# se arma como en Supabase real: nucleo/pruebas/mini_supabase.sql (auth,
# roles, pgcrypto en extensions; sin simulador) y las partes de
# herramientas/armar_instalacion.sh, cada una en UNA petición (como el SQL
# Editor) con el rol supa_postgres (NO superusuario, como "postgres" en
# Supabase). Revisa además: que correr todo otra vez no cambia nada, que una
# parte fuera de orden se rechaza sin tocar nada y que la verificación dice
# "TODO BIEN". Después corren las mismas pruebas.
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
PAQUETE=0
for arg in "$@"; do
  case "$arg" in
    --paquete) PAQUETE=1 ;;
    *) echo "Uso: bash herramientas/probar.sh [--paquete]" >&2; exit 2 ;;
  esac
done

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

# --paquete: instala el paquete de dist/ como en Supabase real (ver arriba).
una_peticion() { python3 "$RAIZ/herramientas/sql_una_peticion.py" "$PGHOST" "$PGPORT" supa_postgres "$@"; }
instalar_paquete() {
  local dir partes p base_mal
  dir="$(mktemp -d)"
  bash "$RAIZ/herramientas/armar_instalacion.sh" "$dir" >/dev/null || falla_fatal "armar_instalacion.sh falló."
  mapfile -t partes < <(ls "$dir"/instalar_supabase_parte*.sql | sort)
  echo "  paquete: ${#partes[@]} partes (mini Supabase, rol supa_postgres sin superusuario)"
  psql_q -d "$PLANTILLA" -f "$DIR_PRUEBAS/mini_supabase.sql" >/dev/null 2>&1 || falla_fatal "error en mini_supabase.sql"
  # Fuera de orden: la parte 2 en una base nueva se rechaza y no deja nada.
  base_mal="${PLANTILLA}_orden"
  dropdb --if-exists "$base_mal" >/dev/null 2>&1; createdb -T "$PLANTILLA" "$base_mal"
  if una_peticion "$base_mal" "${partes[1]}" >/dev/null 2>&1; then falla_fatal "la parte 2 se aplicó sin la parte 1."; fi
  [ "$(psql_q -d "$base_mal" -tAc "SELECT to_regclass('interno._migraciones') IS NULL")" = "t" ] \
    || falla_fatal "la parte rechazada dejó algo creado."
  dropdb "$base_mal"
  for p in "${partes[@]}"; do
    una_peticion "$PLANTILLA" "$p" >/dev/null || falla_fatal "error en $(basename "$p")"
  done
  # Correr todo otra vez no cambia nada (salta lo instalado).
  local antes despues
  antes="$(psql_q -d "$PLANTILLA" -tAc "SELECT count(*), max(aplicada_en) FROM interno._migraciones")"
  for p in "${partes[@]}"; do
    una_peticion "$PLANTILLA" "$p" >/dev/null || falla_fatal "error al repetir $(basename "$p")"
  done
  despues="$(psql_q -d "$PLANTILLA" -tAc "SELECT count(*), max(aplicada_en) FROM interno._migraciones")"
  [ "$antes" = "$despues" ] || falla_fatal "repetir el paquete cambió interno._migraciones."
  una_peticion "$PLANTILLA" "$dir/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION |" \
    || falla_fatal "verificar_instalacion.sql no dice TODO BIEN $VERSION."
  # Dueño de todo: el rol sin superusuario (como "postgres" en Supabase).
  [ "$(psql_q -d "$PLANTILLA" -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('public', 'interno') AND pg_get_userbyid(p.proowner) <> 'supa_postgres'")" = "0" ] \
    || falla_fatal "hay funciones con otro dueño."
  # migrar.sh reconoce la base instalada con el paquete (misma huella): nada pendiente.
  PGDATABASE="$PLANTILLA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" | grep -q "No hay migraciones pendientes" \
    || falla_fatal "migrar.sh no reconoce la base instalada con el paquete."
  # Primer cliente (exportar_supabase / Armador) en una copia: crea la empresa y no se repite.
  local base_pc uid ultima
  base_pc="${PLANTILLA}_primer"
  dropdb --if-exists "$base_pc" >/dev/null 2>&1; createdb -T "$PLANTILLA" "$base_pc"
  uid="$(psql_q -d "$base_pc" -tAc "INSERT INTO auth.users (email) VALUES ('dueno@ejemplo.hn') RETURNING id")"
  ultima="$(psql_q -d "$PLANTILLA" -tAc "SELECT max(numero) FROM interno._migraciones")"
  python3 "$RAIZ/herramientas/ficha.py" primer_cliente "$RAIZ/clientes/ejemplo/ficha.json" "$uid" "" "$ultima" > "$dir/primer.sql" 2>/dev/null \
    || falla_fatal "ficha.py primer_cliente falló."
  una_peticion "$base_pc" "$dir/primer.sql" | grep -q "^Empresa creada" || falla_fatal "el SQL del primer cliente no creó la empresa."
  if una_peticion "$base_pc" "$dir/primer.sql" >/dev/null 2>&1; then falla_fatal "el primer cliente se creó dos veces."; fi
  [ "$(psql_q -d "$base_pc" -tAc "SELECT count(*) FROM public.licencia")" = "1" ] || falla_fatal "primer cliente sin licencia."
  dropdb "$base_pc"
  rm -rf "$dir"
  echo "  paquete OK: instala de cero, repetirlo no cambia nada, fuera de orden se rechaza, TODO BIEN $VERSION, primer cliente creado una sola vez"
}

# ---------------------------------------------------------------------
# 2) Plantilla: simulador + migraciones + datos de prueba
# ---------------------------------------------------------------------
echo "Preparando base de pruebas ..."
dropdb --if-exists "$PLANTILLA" >/dev/null 2>&1
createdb "$PLANTILLA" || falla_fatal "no se pudo crear la base plantilla."

if [ "$PAQUETE" = "1" ]; then
  instalar_paquete
else
  psql_q -d "$PLANTILLA" -f "$DIR_PRUEBAS/simular_supabase.sql" >/dev/null \
    || falla_fatal "error en simular_supabase.sql"
  # Base desechable: sin confirmación ni respaldo.
  PGDATABASE="$PLANTILLA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null \
    || falla_fatal "error aplicando migraciones."
fi
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
