#!/usr/bin/env bash
# =====================================================================
# lista_clientes.sh  -  Tabla de todos los clientes del proveedor.
#
#   bash herramientas/lista_clientes.sh [--sin-conectar]
#
# Recorre clientes/*/ficha.json. Si la ficha trae "conexion" y hay acceso
# SIN preguntar nada (clave en ~/.pgpass o PGPASSFILE, o la base local de
# pruebas), consulta esa base: módulos activos, vencimiento de la licencia,
# versión del núcleo, uso / límite del contrato y solicitudes pendientes.
# Sin acceso (o con --sin-conectar) muestra lo que dice la ficha.
# (!) = el cliente usa el 80 % o más de algún límite.
#
# Nunca cambia nada. Variable opcional: DIR_CLIENTES (defecto base-negocios/clientes).
# =====================================================================
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR_CLIENTES="${DIR_CLIENTES:-$RAIZ/clientes}"
SIN_CONECTAR=0
for arg in "$@"; do
  case "$arg" in
    --sin-conectar) SIN_CONECTAR=1 ;;
    -h|--ayuda)     sed -n '2,15p' "$0"; exit 0 ;;
    *)              echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
  esac
done
TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/clientes.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# SQL de la consulta (el código va como -c; los datos de la ficha, por la entrada estándar).
SQL_CONSULTA="$(cat <<'PY'
import json, secrets, sys
n = json.load(sys.stdin)
nuevo = sys.argv[1] == "t"
def q(t):
    t = str(t)
    while True:
        m = "c_" + secrets.token_hex(6)
        if m not in t:
            return "$%s$%s$%s$" % (m, t, m)
filtro = ("e.id = %s::uuid" % q(n["empresa_id"])) if n.get("empresa_id") else ("e.nombre = %s" % q(n["nombre"]))
extra = ("'limites', interno.limites_y_uso(e.id), 'solicitudes', (SELECT count(*) FROM public.solicitud_proveedor s "
         "WHERE s.empresa_id = e.id AND s.estado = 'pendiente')") if nuevo else "'limites', NULL, 'solicitudes', 0"
print("""SELECT json_build_object('empresa', e.nombre,
  'modulos', (SELECT string_agg(m.modulo, ',' ORDER BY m.modulo) FROM public.modulo_activo m WHERE m.empresa_id = e.id AND m.activo),
  'vence', to_char(l.vence_el, 'YYYY-MM-DD'), 'nucleo', (SELECT v.version_nucleo FROM public.version_esquema v), %s)
FROM public.empresa e LEFT JOIN public.licencia l ON l.empresa_id = e.id WHERE %s LIMIT 1;""" % (extra, filtro))
PY
)"

# Consulta una base en un proceso aparte (la clave temporal se borra al salir).
# $1 = cadena sin clave, $2 = ficha normalizada. Imprime una línea JSON.
consultar() {
  (
    source "$RAIZ/herramientas/conexion.sh"
    trap conexion_limpiar EXIT
    export CONEX_SIN_PEDIR_CLAVE=1 PGCONNECT_TIMEOUT=5
    conexion_preparar "$1" argumento >/dev/null 2>&1 || exit 1
    nuevo="$(psql -X -w -q -tA -c "SELECT to_regclass('public.limite_contrato') IS NOT NULL" 2>/dev/null)" || exit 1
    printf '%s' "$2" | python3 -c "$SQL_CONSULTA" "$nuevo" | psql -X -w -q -tA -v ON_ERROR_STOP=1 2>/dev/null
  )
}

n=0
for f in "$DIR_CLIENTES"/*/ficha.json; do
  [ -f "$f" ] || continue
  if ! norm="$(python3 "$RAIZ/herramientas/ficha.py" normalizar "$f" 2>"$TMP/err")"; then
    echo "AVISO: $f no se pudo leer: $(cat "$TMP/err")" >&2; continue
  fi
  base=""
  cadena="$(printf '%s' "$norm" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("conexion") or "")')"
  if [ "$SIN_CONECTAR" = "0" ] && [ -n "$cadena" ]; then
    base="$(consultar "$cadena" "$norm" | head -1)" || base=""
  fi
  printf '%s\x1f%s\n' "$norm" "$base" >> "$TMP/filas"
  n=$((n + 1))
done
if [ "$n" = "0" ]; then
  echo "No hay fichas en $DIR_CLIENTES/*/ficha.json"; exit 0
fi
python3 "$RAIZ/herramientas/ficha.py" tabla < "$TMP/filas"
