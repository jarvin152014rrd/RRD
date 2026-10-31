#!/usr/bin/env bash
# =====================================================================
# restaurar.sh  -  Restaura un respaldo (cifrado o no) en una base NUEVA.
#
#   bash herramientas/restaurar.sh ARCHIVO [cadena_de_conexion_de_la_base_NUEVA]
#
# Reglas (P-03 de docs/PROCEDIMIENTOS.md):
#   * Nunca encima de una base en uso: si la base de destino ya tiene el
#     núcleo (esquema "interno" o tabla public.empresa), se niega.
#   * Pide escribir el identificador de la base de destino para confirmar.
#   * Descifra en tubería (no deja copia descifrada en disco) y restaura
#     todo o nada (pg_restore --single-transaction).
#   * Al final revisa: versión del núcleo, verificar_bitacora() y cuentas.
#
# Para descifrar: .gpg pide la frase (o RESPALDO_CLAVE_ARCHIVO);
# .age pide RESPALDO_AGE_IDENTIDAD (archivo con la llave privada).
# Variable opcional: SIN_PREGUNTAR=1 (solo base local de pruebas).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
source "$RAIZ/herramientas/conexion.sh"

ARCHIVO=""
CADENA=""
for arg in "$@"; do
  case "$arg" in
    -h|--ayuda) sed -n '2,20p' "$0"; exit 0 ;;
    -*)         echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
    *)          if [ -z "$ARCHIVO" ]; then ARCHIVO="$arg"; else CADENA="$arg"; fi ;;
  esac
done
[ -n "$ARCHIVO" ] || { echo "Uso: bash herramientas/restaurar.sh ARCHIVO [cadena_base_nueva]" >&2; exit 2; }
[ -s "$ARCHIVO" ] || { echo "ERROR: no existe o está vacío: $ARCHIVO" >&2; exit 1; }

ORIGEN="argumento"
if [ -z "$CADENA" ]; then
  if [ -n "${DATABASE_URL:-}" ]; then CADENA="$DATABASE_URL"; ORIGEN="DATABASE_URL"; else ORIGEN="variables"; fi
fi
trap conexion_limpiar EXIT
conexion_preparar "$CADENA" "$ORIGEN" || exit 1
conexion_mostrar
conexion_info || exit 1

if [ "$(psql -X -q -tA -c "SELECT to_regnamespace('interno') IS NOT NULL OR to_regclass('public.empresa') IS NOT NULL")" = "t" ]; then
  echo "ERROR: la base de destino \"$CONEX_BASE\" ya tiene datos del núcleo. Restaure en una base NUEVA y vacía." >&2
  exit 1
fi
conexion_identificador
conexion_confirmar "restaurar $(basename "$ARCHIVO") en esa base" || exit 1

# La frase se pide ANTES de la tubería (si hace falta).
case "$ARCHIVO" in *.gpg) respaldo_frase 1 || exit 1 ;; esac

echo "Restaurando (todo o nada) ..."
if ! respaldo_descifrar "$ARCHIVO" | pg_restore --no-owner --single-transaction --exit-on-error --dbname="$CONEX_BASE"; then
  echo "ERROR: la restauración falló; la base de destino quedó como estaba (vacía)." >&2
  exit 1
fi

echo "Revisión de la base restaurada:"
psql -X -q -tA -F ' | ' -c "SELECT 'núcleo ' || version_nucleo || ' (migración ' || ultima_migracion || ')' FROM public.version_esquema"
problemas="$(psql -X -q -tA -c "SELECT count(*) FROM public.verificar_bitacora()")"
echo "verificar_bitacora(): $problemas problemas"
psql -X -q -tA -c "SELECT 'empresas: ' || (SELECT count(*) FROM public.empresa) || ', asientos: ' || (SELECT count(*) FROM public.asiento)
                    || ', movimientos de kardex: ' || (SELECT count(*) FROM public.inventario_movimiento)"
[ "$problemas" = "0" ] || { echo "ERROR: la bitácora restaurada tiene problemas. No use esta base; avise." >&2; exit 1; }
echo "Restauración lista. Compare saldos con el último reporte antes de usarla (P-03)."
