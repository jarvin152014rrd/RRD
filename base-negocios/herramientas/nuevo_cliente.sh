#!/usr/bin/env bash
# =====================================================================
# nuevo_cliente.sh  -  Crea la empresa de un cliente nuevo desde su ficha.
#
#   bash herramientas/nuevo_cliente.sh [--solo-validar] clientes/<cliente>/ficha.json [cadena_de_conexion]
#
# Ficha: formato 2 (clientes/<cliente>/ficha.json, ver clientes/ejemplo) o el
# formato 1 de antes (plano, personal/ficha.ejemplo.json).
#
# Pasos:
#   1. Revisa que la ficha sea JSON válido.
#   2. La compara con personal/ficha.schema.json (si python3 tiene el
#      paquete jsonschema; si no, avisa y sigue: la base valida igual).
#      Formato 2: "cliente" debe ser el nombre de su carpeta y "conexion"
#      no puede traer la clave.
#   3. Muestra a qué base se conecta (servidor completo) y qué empresas ya
#      tiene, y pide escribir un identificador único: la referencia del
#      proyecto de Supabase, o el nombre de la empresa que ya está en esa
#      base, o (base local nueva) el nombre de la base.
#   4. Llama crear_empresa_inicial(ficha) en una transacción; con el formato 2,
#      en la MISMA transacción pone la licencia y los límites del contrato
#      (aplicar_ficha). La ficha va por la ENTRADA ESTÁNDAR de psql, nunca como argumento (no se ve con "ps").
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
# Después (formato 1, o formato 2 sin "licencia"): activar la licencia (sin
# licencia la empresa queda en solo lectura). Anotar el id de empresa en la
# ficha (negocio.empresa_id) para aplicar_ficha.sh y lista_clientes.sh.
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
    -h|--ayuda)     sed -n '2,40p' "$0"; exit 0 ;;
    -*)             echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)              if [ -z "$FICHA" ]; then FICHA="$arg"; else CADENA="$arg"; fi ;;
  esac
done
[ -n "$FICHA" ] || { echo "Uso: bash herramientas/nuevo_cliente.sh [--solo-validar] ruta/ficha.json" >&2; exit 2; }
[ -f "$FICHA" ] || { echo "ERROR: no existe el archivo $FICHA" >&2; exit 1; }

# ---------------------------------------------------------------------
# 1 y 2) JSON válido y esquema
# ---------------------------------------------------------------------
python3 "$RAIZ/herramientas/ficha.py" validar "$FICHA" || exit 1
NORM="$(python3 "$RAIZ/herramientas/ficha.py" normalizar "$FICHA")" || exit 1

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
NOMBRE="$(printf '%s' "$NORM" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("nombre") or "")')"
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
SQL_CREAR="$(cat <<'PY'
import json, secrets, sys
n = json.load(sys.stdin)
def q(t):
    while True:
        m = "ficha_" + secrets.token_hex(8)
        if m not in t:
            return "$%s$%s$%s$" % (m, t, m)
print("BEGIN;")
print("SELECT public.crear_empresa_inicial(%s::jsonb) AS empresa_nueva \\gset" % q(json.dumps(n["crear"], ensure_ascii=False)))
extra = {k: n["cambios"][k] for k in ("licencia", "limites") if k in n["cambios"]}
if extra:
    print("SELECT (public.aplicar_ficha(:'empresa_nueva'::uuid, %s::jsonb, %s))->>'aplicado' AS ficha_aplicada \\gset"
          % (q(json.dumps(extra, ensure_ascii=False)), q("Ficha inicial del cliente " + (n.get("cliente") or ""))))
print("SELECT :'empresa_nueva';")
print(sys.argv[1] + ";")
PY
)"
script_sql() { printf '%s' "$NORM" | python3 -c "$SQL_CREAR" "$FIN"; }
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
  if printf '%s' "$NORM" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("licencia") else 1)'; then
    echo "Licencia y límites de la ficha aplicados. Anote el id en la ficha (negocio.empresa_id)."
  else
    echo "Siguiente paso: activar la licencia (ver docs/PROCEDIMIENTOS.md)."
  fi
fi
