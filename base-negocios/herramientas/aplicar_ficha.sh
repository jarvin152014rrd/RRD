#!/usr/bin/env bash
# =====================================================================
# aplicar_ficha.sh  -  Lleva a la base de un cliente lo que dice su ficha:
# módulos (sí/no), perfil, licencia y límites del contrato.
#
#   bash herramientas/aplicar_ficha.sh [--solo-mostrar] clientes/<cliente>/ficha.json [cadena_de_conexion]
#
# Pasos:
#   1. Revisa la ficha: JSON válido, personal/ficha.schema.json (formato 2,
#      con "negocio") y que "cliente" sea el nombre de su carpeta.
#   2. Se conecta (cadena del 2.º argumento SIN clave, o la "conexion" de la
#      ficha, o DATABASE_URL / PGHOST-PGDATABASE, y lo AVISA). La clave se
#      pide sin mostrarla y nunca va como argumento (ver conexion.sh).
#   3. Busca la empresa (negocio.empresa_id, o el nombre exacto).
#   4. VISTA PREVIA: módulos a activar y a desactivar (en el orden que piden
#      las dependencias), perfil, licencia y límites (uso / límite). Prueba
#      aplicar y DESHACE, para mostrar cualquier error antes de confirmar
#      (por ejemplo MODULO_DEPENDENCIA o MODULO_CON_SALDO).
#      Con --solo-mostrar termina aquí.
#   5. Pide escribir el identificador del cliente ("cliente" de la ficha).
#   6. Respaldo completo CIFRADO en base-negocios/respaldos/ (P-03). Si
#      falla, no aplica nada.
#   7. Aplica TODO en una transacción (aplicar_ficha en la base, con la
#      conexión del proveedor). Queda en la bitácora con el motivo.
#
# Nunca borra datos: apagar un módulo solo impide operaciones nuevas, y
# bajar un límite solo impide agregar más.
#
# Variables opcionales (SOLO con la base local de pruebas: el socket de
# base-negocios/.pgdata o el declarado en BASE_LOCAL_SOCKET):
#   SIN_PREGUNTAR=1   no pide confirmación
#   SIN_RESPALDO=1    no hace respaldo
#   DIR_RESPALDOS     carpeta de respaldos (defecto base-negocios/respaldos)
#   MOTIVO            texto para la bitácora (defecto: "Ficha del cliente <cliente>")
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR_RESPALDOS="${DIR_RESPALDOS:-$RAIZ/respaldos}"
source "$RAIZ/herramientas/conexion.sh"
SOLO_MOSTRAR=0
FICHA=""
CADENA=""
for arg in "$@"; do
  case "$arg" in
    --solo-mostrar) SOLO_MOSTRAR=1 ;;
    -h|--ayuda)     sed -n '2,37p' "$0"; exit 0 ;;
    -*)             echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)              if [ -z "$FICHA" ]; then FICHA="$arg"; else CADENA="$arg"; fi ;;
  esac
done
[ -n "$FICHA" ] || { echo "Uso: bash herramientas/aplicar_ficha.sh [--solo-mostrar] clientes/<cliente>/ficha.json [cadena]" >&2; exit 2; }

# ---------------------------------------------------------------------
# 1) Ficha
# ---------------------------------------------------------------------
python3 "$RAIZ/herramientas/ficha.py" validar "$FICHA" || exit 1
NORM="$(python3 "$RAIZ/herramientas/ficha.py" normalizar "$FICHA")" || exit 1
campo() { printf '%s' "$NORM" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"; }
[ "$(campo formato)" = "2" ] || { echo "ERROR: aplicar_ficha.sh usa el formato de ficha con \"negocio\" (vea clientes/ejemplo/ficha.json)." >&2; exit 1; }
CLIENTE="$(campo cliente)"
NOMBRE="$(campo nombre)"
echo "Cliente: $CLIENTE   Negocio: $NOMBRE   Paquete: $(campo paquete) (informativo)"

# ---------------------------------------------------------------------
# 2) Destino
# ---------------------------------------------------------------------
ORIGEN="argumento"
if [ -z "$CADENA" ]; then
  CADENA="$(campo conexion)"
  if [ -z "$CADENA" ]; then
    if [ -n "${DATABASE_URL:-}" ]; then CADENA="$DATABASE_URL"; ORIGEN="DATABASE_URL"
    elif [ -n "${PGDATABASE:-}" ] || [ -n "${PGHOST:-}" ]; then ORIGEN="variables"
    else echo "ERROR: indique la cadena de conexión (o \"conexion\" en la ficha)." >&2; exit 2; fi
  fi
fi
trap conexion_limpiar EXIT
conexion_preparar "$CADENA" "$ORIGEN" || exit 1
psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
conexion_mostrar
conexion_info || exit 1
if [ "$(psql_q -tAc "SELECT to_regprocedure('public.aplicar_ficha(uuid,jsonb,text)') IS NOT NULL")" != "t" ]; then
  echo "ERROR: esa base no tiene el núcleo 0.8.0 o más nuevo. Actualícela primero (migrar.sh, P-02)." >&2; exit 1
fi

SQL_FICHA="$(cat <<'PY'
import json, secrets, sys
n = json.load(sys.stdin)
accion, emp, motivo = sys.argv[1], sys.argv[2], sys.argv[3]
def q(t):
    t = str(t)
    while True:
        m = "f_" + secrets.token_hex(6)
        if m not in t:
            return "$%s$%s$%s$" % (m, t, m)
cambios = q(json.dumps(n["cambios"], ensure_ascii=False)) + "::jsonb"
if accion == "buscar":
    if n.get("empresa_id"):
        print("SELECT count(*) || ' ' || coalesce(min(id::text), '') FROM public.empresa WHERE id = %s::uuid;" % q(n["empresa_id"]))
    else:
        print("SELECT count(*) || ' ' || coalesce(min(id::text), '') FROM public.empresa WHERE nombre = %s;" % q(n["nombre"]))
elif accion == "vista":
    print("SELECT public.vista_previa_ficha(%s::uuid, %s);" % (q(emp), cambios))
else:
    print("BEGIN;")
    print("SELECT (public.aplicar_ficha(%s::uuid, %s, %s))->>'aplicado';" % (q(emp), cambios, q(motivo)))
    print("COMMIT;" if accion == "aplicar" else "ROLLBACK;")
PY
)"

# Arma el SQL. La ficha va por la ENTRADA ESTÁNDAR de psql (nunca como
# argumento), entre $marca$ ... $marca$ con una marca al azar.
#   $1 = buscar | vista | probar | aplicar
script_sql() {
  printf '%s' "$NORM" | python3 -c "$SQL_FICHA" "$1" "${EMPRESA_ID:-}" "${MOTIVO:-Ficha del cliente $CLIENTE aplicada con aplicar_ficha.sh}"
}
error_base() { echo "$1" | sed -n 's/^.*ERROR: *//p' | head -3 | sed 's/^/  /' >&2; }

# ---------------------------------------------------------------------
# 3) Empresa
# ---------------------------------------------------------------------
EMPRESA_ID=""
read -r N EMPRESA_ID <<< "$(script_sql buscar | psql_q -tA)"
if [ "$N" != "1" ]; then
  echo "ERROR: no se encontró UNA empresa \"$NOMBRE\" en esa base (encontradas: $N). Revise la base o ponga negocio.empresa_id en la ficha." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 4) Vista previa (y prueba deshaciendo)
# ---------------------------------------------------------------------
echo
echo "VISTA PREVIA (todavía no se cambia nada):"
if ! VISTA="$(script_sql vista | psql_q -tA 2>&1)"; then
  echo "ERROR: la base rechazó la ficha:" >&2; error_base "$VISTA"; exit 1
fi
printf '%s' "$VISTA" | python3 "$RAIZ/herramientas/ficha.py" vista_previa
HAY="$(printf '%s' "$VISTA" | python3 -c 'import json,sys; v=json.load(sys.stdin); print("errores" if v["errores"] else ("si" if v["hay_cambios"] else "no"))')"
[ "$HAY" = "errores" ] && { echo "ERROR: corrija la ficha (ver PROBLEMA arriba). No se aplicó nada." >&2; exit 1; }
[ "$HAY" = "no" ] && exit 0
if ! PRUEBA="$(script_sql probar | psql_q -tA 2>&1)"; then
  echo "ERROR: al probar, la base rechazó el cambio (no se aplicó nada):" >&2; error_base "$PRUEBA"; exit 1
fi
if [ "$SOLO_MOSTRAR" = "1" ]; then
  echo "(--solo-mostrar: se probó y se deshizo; no se aplicó nada)"
  exit 0
fi

# ---------------------------------------------------------------------
# 5) Confirmación con el identificador del cliente
# ---------------------------------------------------------------------
CONEX_ID="$CLIENTE"; CONEX_ID_QUE="el identificador del cliente"
conexion_confirmar "aplicar la ficha a \"$NOMBRE\"" || exit 1

# ---------------------------------------------------------------------
# 6) Respaldo previo (cifrado)
# ---------------------------------------------------------------------
if [ "${SIN_RESPALDO:-0}" = "1" ]; then
  conexion_es_local || { echo "ERROR: SIN_RESPALDO=1 solo se acepta con la base local de pruebas." >&2; exit 1; }
  echo "AVISO: sin respaldo previo (SIN_RESPALDO=1). Solo para bases de prueba."
else
  echo "Respaldando la base (cifrado) en $DIR_RESPALDOS ..."
  if ! respaldo_hacer "$DIR_RESPALDOS/${CLIENTE}_$(date -u +%Y%m%dT%H%M%SZ)"; then
    echo "ERROR: no se pudo hacer el respaldo. No se aplicó nada." >&2; exit 1
  fi
  echo "Respaldo listo: $RESPALDO_ARCHIVO"
fi

# ---------------------------------------------------------------------
# 7) Aplicar (todo o nada)
# ---------------------------------------------------------------------
if ! SALIDA="$(script_sql aplicar | psql_q -tA 2>&1)"; then
  echo "ERROR: la base rechazó el cambio (no se aplicó nada):" >&2; error_base "$SALIDA"; exit 1
fi
echo "Ficha aplicada a \"$NOMBRE\" (empresa $EMPRESA_ID). Queda en la bitácora."
