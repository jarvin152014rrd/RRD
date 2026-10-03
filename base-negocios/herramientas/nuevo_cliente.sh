#!/usr/bin/env bash
# =====================================================================
# nuevo_cliente.sh  -  Crea la empresa de un cliente nuevo desde su ficha.
#
#   bash herramientas/nuevo_cliente.sh [--solo-validar] personal/ficha.json
#
# Pasos:
#   1. Revisa que la ficha sea JSON válido.
#   2. La compara con personal/ficha.schema.json (si python3 tiene el
#      paquete jsonschema; si no, avisa y sigue: la base valida igual).
#   3. Muestra a qué base se conecta y pide escribir su nombre.
#   4. Llama crear_empresa_inicial(ficha) en una transacción.
#      Con --solo-validar hace todo y al final DESHACE (no crea nada).
#
# A qué base se conecta:
#   * Si hay PGDATABASE (o PGHOST/DATABASE_URL), a esa (ej. Supabase).
#     DATABASE_URL = "postgresql://usuario:clave@host:5432/postgres"
#   * Si no, a la base local de pruebas "base_local" (la crea si falta,
#     con el simulador de Supabase y todas las migraciones).
#
# Antes: el dueño (y el proveedor) deben estar registrados en Supabase
# (Authentication > Users) con el correo de la ficha.
# Después: activar la licencia (sin licencia la empresa queda en solo lectura).
#
# Variable opcional: SIN_PREGUNTAR=1 (no pide confirmación; pruebas).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SOLO_VALIDAR=0
FICHA=""
for arg in "$@"; do
  case "$arg" in
    --solo-validar) SOLO_VALIDAR=1 ;;
    -h|--ayuda)     sed -n '2,30p' "$0"; exit 0 ;;
    -*)             echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)              FICHA="$arg" ;;
  esac
done
[ -n "$FICHA" ] || { echo "Uso: bash herramientas/nuevo_cliente.sh [--solo-validar] ruta/ficha.json" >&2; exit 2; }
[ -f "$FICHA" ] || { echo "ERROR: no existe el archivo $FICHA" >&2; exit 1; }

# ---------------------------------------------------------------------
# 1 y 2) JSON válido y esquema
# ---------------------------------------------------------------------
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$FICHA" 2>/dev/null; then
  echo "ERROR: la ficha no es JSON válido (revise comas, comillas y llaves)." >&2
  python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$FICHA" 2>&1 | tail -1 >&2 || true
  exit 1
fi

if python3 -c 'import jsonschema' 2>/dev/null; then
  if ! python3 - "$FICHA" "$RAIZ/personal/ficha.schema.json" <<'PY'
import json, sys, jsonschema
ficha = json.load(open(sys.argv[1], encoding="utf-8"))
esquema = json.load(open(sys.argv[2], encoding="utf-8"))
errores = sorted(jsonschema.Draft202012Validator(esquema).iter_errors(ficha), key=lambda e: list(e.path))
for e in errores:
    campo = ".".join(str(p) for p in e.path) or "(ficha)"
    print(f"  - {campo}: {e.message}", file=sys.stderr)
sys.exit(1 if errores else 0)
PY
  then
    echo "ERROR: la ficha no cumple personal/ficha.schema.json (ver arriba)." >&2
    exit 1
  fi
  echo "Ficha revisada contra ficha.schema.json: bien."
else
  echo "AVISO: python3 no tiene 'jsonschema'; se omite esa revisión (la base valida igual)."
fi

# ---------------------------------------------------------------------
# 3) Destino
# ---------------------------------------------------------------------
CONEXION=()
if [ -n "${DATABASE_URL:-}" ]; then
  CONEXION=("$DATABASE_URL")
elif [ -z "${PGDATABASE:-}" ] && [ -z "${PGHOST:-}" ]; then
  source "$RAIZ/herramientas/servidor_local.sh"
  local_encender
  trap local_apagar EXIT
  export PGDATABASE="base_local"
  if [ "$(psql -X -tA -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = 'base_local'")" = "0" ]; then
    echo "Creando la base local de pruebas \"base_local\" ..."
    createdb base_local
    psql -X -q -v ON_ERROR_STOP=1 -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
    SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null
  fi
fi
psql_q() { psql "${CONEXION[@]}" -X -q -v ON_ERROR_STOP=1 "$@"; }

info="$(psql_q -tA -F'|' -c "SELECT current_database(), coalesce(inet_server_addr()::text, 'socket local'), current_user")" \
  || { echo "ERROR: no se pudo conectar a la base." >&2; exit 1; }
IFS='|' read -r BASE SERVIDOR USUARIO <<< "$info"
echo "Destino: base \"$BASE\" en $SERVIDOR como $USUARIO"
NOMBRE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("nombre",""))' "$FICHA")"
echo "Empresa: $NOMBRE"

if [ "$SOLO_VALIDAR" = "0" ] && [ "${SIN_PREGUNTAR:-0}" != "1" ]; then
  printf 'Para crearla escriba el nombre de la base (%s): ' "$BASE"
  respuesta=""
  read -r respuesta || true
  if [ "$respuesta" != "$BASE" ]; then
    echo; echo "Cancelado: el nombre no coincide. No se creó nada." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------
# 4) Crear (o validar y deshacer)
# ---------------------------------------------------------------------
FIN="COMMIT"; [ "$SOLO_VALIDAR" = "1" ] && FIN="ROLLBACK"
if ! salida="$(psql_q -tA -v ficha="$(cat "$FICHA")" 2>&1 <<SQL
BEGIN;
SELECT public.crear_empresa_inicial(:'ficha'::jsonb);
$FIN;
SQL
)"; then
  echo "ERROR: la base rechazó la ficha:" >&2
  echo "$salida" | sed -n 's/^.*ERROR: *//p' | head -3 | sed 's/^/  /' >&2
  exit 1
fi
EMPRESA_ID="$(echo "$salida" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"

if [ "$SOLO_VALIDAR" = "1" ]; then
  echo "Ficha válida. (--solo-validar: no se creó nada)"
else
  echo "Empresa creada. id: $EMPRESA_ID"
  echo "Siguiente paso: activar la licencia (ver docs/PROCEDIMIENTOS.md)."
fi
