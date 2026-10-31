#!/usr/bin/env bash
# =====================================================================
# exportar_supabase.sh  -  "Exportar para Supabase": arma el SQL del primer
# cliente (crear la empresa con su ficha) para pegarlo en el SQL Editor.
#
#   bash herramientas/exportar_supabase.sh clientes/<cliente>/ficha.json [ID_DUENO] [ID_PROVEEDOR]
#
# ID_DUENO: el "User UID" del dueño (Supabase > Authentication > Users). Si no
# se pone, el archivo trae la marca PEGUE-AQUI-EL-ID-DEL-DUENO para pegarlo ahí.
# ID_PROVEEDOR (opcional): el usuario de soporte del proveedor en ese proyecto.
# Deja dist/instalar_supabase_primer_cliente_<cliente>.sql (dist/ no va a git).
# El archivo no lleva claves; sí lleva los datos del negocio (nombre, RTN,
# correos): no lo comparta fuera del dueño y del proveedor.
# Lo mismo hace el Armador: Clientes > "Exportar para Supabase".
# =====================================================================
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in ""|-h|--ayuda) sed -n '2,16p' "$0"; exit 2 ;; esac
FICHA="$1"; ID_DUENO="${2:-}"; ID_PROV="${3:-}"
ULTIMA="$(ls "$RAIZ"/nucleo/sql/migraciones/[0-9][0-9][0-9]_*.sql | sort | tail -1 | xargs basename | cut -c1-3)"
CLIENTE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cliente") or "")' "$FICHA")"
[[ "$CLIENTE" =~ ^[a-z0-9][a-z0-9_-]{1,40}$ ]] || { echo "ERROR: la ficha no tiene un \"cliente\" válido." >&2; exit 1; }
mkdir -p "$RAIZ/dist"
SALIDA="$RAIZ/dist/instalar_supabase_primer_cliente_${CLIENTE}.sql"
python3 "$RAIZ/herramientas/ficha.py" primer_cliente "$FICHA" "$ID_DUENO" "$ID_PROV" "$((10#$ULTIMA))" > "$SALIDA.tmp"
mv "$SALIDA.tmp" "$SALIDA"
echo "Listo: $SALIDA"
[ -n "$ID_DUENO" ] || echo "Falta pegar el User UID del dueño donde dice PEGUE-AQUI-EL-ID-DEL-DUENO (arriba del archivo)."
