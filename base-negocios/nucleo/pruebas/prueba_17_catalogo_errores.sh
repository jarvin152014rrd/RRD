#!/usr/bin/env bash
# PRUEBA: todo código de error usado en el SQL (RAISE 'CLAVE:') está en el catálogo con mensaje y qué hacer
# Uso: bash prueba_17_catalogo_errores.sh <base>   (lo llama probar.sh)
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
DIR="$RAIZ/nucleo/sql/migraciones"
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }

# 1) Todo RAISE EXCEPTION debe llevar el texto en la misma línea y empezar con CLAVE:
sin_clave="$(grep -nE "RAISE[[:space:]]+EXCEPTION" "$DIR"/*.sql \
  | grep -vE "RAISE[[:space:]]+EXCEPTION[[:space:]]+'[A-Z][A-Z_]+:" || true)"
if [ -n "$sin_clave" ]; then
  echo "FALLA: hay errores sin CLAVE: al inicio:"; echo "$sin_clave"; exit 1
fi

# 2) Cada clave usada está en el catálogo, con mensaje y qué hacer.
codigos="$(grep -ohE "RAISE[[:space:]]+EXCEPTION[[:space:]]+'[A-Z][A-Z_]+:" "$DIR"/*.sql \
  | sed -E "s/.*'([A-Z_]+):/\1/" | sort -u)"
[ -n "$codigos" ] || { echo "FALLA: no se encontró ningún código de error"; exit 1; }

faltan=()
for c in $codigos; do
  n="$(q "SELECT count(*) FROM public.error_catalogo WHERE codigo = '$c'
          AND length(trim(mensaje_usuario)) > 0 AND length(trim(que_hacer)) > 0")"
  [ "$n" = "1" ] || faltan+=("$c")
done
if [ "${#faltan[@]}" -gt 0 ]; then
  echo "FALLA: códigos usados en el SQL que no están en public.error_catalogo: ${faltan[*]}"; exit 1
fi

# 3) La app (usuario con sesión) puede leer el catálogo; anon no.
n="$(q "BEGIN; SET LOCAL ROLE authenticated; SELECT count(*) FROM public.error_catalogo; COMMIT;" | tail -1)"
[ "$n" -ge "$(echo "$codigos" | wc -l)" ] || { echo "FALLA: authenticated no lee el catálogo ($n)"; exit 1; }
if q "BEGIN; SET LOCAL ROLE anon; SELECT count(*) FROM public.error_catalogo; COMMIT;" >/dev/null 2>&1; then
  echo "FALLA: anon no debería leer el catálogo"; exit 1
fi
echo "ok: $(echo "$codigos" | wc -l) códigos revisados"
