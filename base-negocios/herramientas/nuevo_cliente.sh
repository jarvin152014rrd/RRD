#!/usr/bin/env bash
# =====================================================================
# nuevo_cliente.sh  -  Crea la empresa de un cliente nuevo desde su ficha.
#
#   bash herramientas/nuevo_cliente.sh [--solo-validar] personal/ficha.json [cadena_de_conexion]
#
# Pasos:
#   1. Revisa que la ficha sea JSON válido.
#   2. La compara con personal/ficha.schema.json (si python3 tiene el
#      paquete jsonschema; si no, avisa y sigue: la base valida igual).
#   3. Muestra a qué base se conecta (servidor completo) y qué empresas ya
#      tiene, y pide escribir un identificador único: la referencia del
#      proyecto de Supabase, o el nombre de la empresa que ya está en esa
#      base, o (base local nueva) el nombre de la base.
#   4. Llama crear_empresa_inicial(ficha) en una transacción. La ficha va por
#      la ENTRADA ESTÁNDAR de psql, nunca como argumento (no se ve con "ps").
#      Con --solo-validar hace todo y al final DESHACE (no crea nada).
#
# A qué base se conecta (la clave nunca va como argumento de psql; ver conexion.sh):
#   * La cadena del tercer argumento, SIN clave (se pide sin mostrarla):
#     "postgresql://postgres@db.<ref>.supabase.co:5432/postgres"
#   * Si no, DATABASE_URL o PGHOST/PGDATABASE de la terminal (y lo AVISA).
#   * Si no hay nada, la base local de pruebas "base_local" (la crea si
#     falta, con el simulador de Supabase y todas las migraciones).
#
# Antes: el dueño (y el proveedor) deben estar registrados en Supabase
# (Authentication > Users) con el correo de la ficha.
# Después: activar la licencia (sin licencia la empresa queda en solo lectura).
#
# Variable opcional: SIN_PREGUNTAR=1 (no pide confirmación; SOLO la base local de
# pruebas: el socket de base-negocios/.pgdata o el declarado en BASE_LOCAL_SOCKET).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
source "$RAIZ/herramientas/conexion.sh"
SOLO_VALIDAR=0
FICHA=""
CADENA=""
for arg in "$@"; do
  case "$arg" in
    --solo-validar) SOLO_VALIDAR=1 ;;
    -h|--ayuda)     sed -n '2,32p' "$0"; exit 0 ;;
    -*)             echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)              if [ -z "$FICHA" ]; then FICHA="$arg"; else CADENA="$arg"; fi ;;
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
ORIGEN="argumento"
apagar_local() { :; }
if [ -n "$CADENA" ]; then
  :
elif [ -n "${DATABASE_URL:-}" ]; then
  CADENA="$DATABASE_URL"; ORIGEN="DATABASE_URL"
elif [ -n "${PGDATABASE:-}" ] || [ -n "${PGHOST:-}" ]; then
  ORIGEN="variables"
else
  ORIGEN="local"
  source "$RAIZ/herramientas/servidor_local.sh"
  local_encender
  apagar_local() { local_apagar; }
  export PGDATABASE="base_local"
  if [ "$(psql -X -tA -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = 'base_local'")" = "0" ]; then
    echo "Creando la base local de pruebas \"base_local\" ..."
    createdb base_local
    psql -X -q -v ON_ERROR_STOP=1 -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
    SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null
  fi
fi
trap 'conexion_limpiar; apagar_local' EXIT
conexion_preparar "$CADENA" "$ORIGEN" || exit 1
psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

conexion_mostrar
conexion_info || exit 1
NOMBRE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("nombre",""))' "$FICHA")"
echo "Empresa nueva: $NOMBRE"

if [ "$SOLO_VALIDAR" = "0" ]; then
  conexion_identificador
  conexion_confirmar "crear la empresa \"$NOMBRE\" en esa base" || exit 1
fi

# ---------------------------------------------------------------------
# 4) Crear (o validar y deshacer)
# ---------------------------------------------------------------------
FIN="COMMIT"; [ "$SOLO_VALIDAR" = "1" ] && FIN="ROLLBACK"
# La ficha (correos, RTN, nombres) va por la ENTRADA ESTÁNDAR de psql, nunca
# como argumento (se vería con "ps" y en el historial). Se escribe como texto
# entre $marca$ ... $marca$ con una marca al azar que no aparece en la ficha.
script_sql() {
  python3 - "$FICHA" "$FIN" <<'PY'
import secrets, sys
ficha = open(sys.argv[1], encoding="utf-8").read()
while True:
    marca = "ficha_" + secrets.token_hex(8)
    if marca not in ficha:
        break
print("BEGIN;")
print(f"SELECT public.crear_empresa_inicial(${marca}${ficha}${marca}$::jsonb);")
print(sys.argv[2] + ";")
PY
}
if ! salida="$(script_sql | psql_q -tA 2>&1)"; then
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
