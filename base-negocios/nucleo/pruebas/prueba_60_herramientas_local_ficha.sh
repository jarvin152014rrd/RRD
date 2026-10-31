#!/usr/bin/env bash
# PRUEBA: herramientas: "base local" es SOLO el socket de .pgdata del proyecto (o BASE_LOCAL_SOCKET), nunca localhost/127.0.0.1 ni otro socket (D); nuevo_cliente.sh pasa la ficha por la entrada estándar de psql, nunca como argumento, y nombres con comillas o $ se guardan tal cual (E)
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
H="$RAIZ/herramientas"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }

# ---------------------------------------------------------------------
# D) Qué cuenta como local
# ---------------------------------------------------------------------
SOCK_PRUEBAS="$PGHOST"      # probar.sh lo deja en el socket de .pgdata
(
  source "$H/conexion.sh"
  PGHOST="$SOCK_PRUEBAS"; conexion_es_local || falla "el socket de .pgdata debe ser local"
  PGHOST="localhost";     conexion_es_local && falla "localhost no debe contar como local"
  PGHOST="127.0.0.1";     conexion_es_local && falla "127.0.0.1 no debe contar como local"
  PGHOST="::1";           conexion_es_local && falla "::1 no debe contar como local"
  PGHOST="";              conexion_es_local && falla "sin PGHOST (socket del sistema) no debe contar como local"
  mkdir "$TMP/otro_socket"
  PGHOST="$TMP/otro_socket"; conexion_es_local && falla "otro socket cualquiera no debe contar como local"
  BASE_LOCAL_SOCKET="$TMP/otro_socket"; conexion_es_local || falla "BASE_LOCAL_SOCKET declarado debe contar como local"
  exit 0
) || exit 1

# Con localhost, las variables de prueba se rechazan ANTES de conectarse.
if SIN_PREGUNTAR=1 bash "$H/migrar.sh" "postgresql://postgres@localhost:5432/postgres" >"$TMP/s.txt" 2>&1; then
  falla "aceptó SIN_PREGUNTAR con localhost"
fi
grep -q "SIN_PREGUNTAR=1 solo se acepta" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no explica por qué (localhost)"; }
# Con el socket de pruebas, sí (no hay nada pendiente en esta base).
PGDATABASE="$BASE" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$H/migrar.sh" >"$TMP/s.txt" 2>&1 || { cat "$TMP/s.txt"; falla "rechazó la base local de pruebas"; }

# ---------------------------------------------------------------------
# E) La ficha no viaja como argumento de psql
# ---------------------------------------------------------------------
REAL="$(dirname "$(command -v psql)")"
mkdir "$TMP/bin"
cat > "$TMP/bin/psql" <<EOF
#!/usr/bin/env bash
echo "ARGS: \$*" >> "$TMP/log"
exec "$REAL/psql" "\$@"
EOF
chmod +x "$TMP/bin/psql"
q "INSERT INTO auth.users (email) VALUES ('dueno@minegocio.hn'), ('soporte@proveedor.hn'), ('raro@prueba.hn')"

: > "$TMP/log"
PGDATABASE="$BASE" SIN_PREGUNTAR=1 PATH="$TMP/bin:$PATH" bash "$H/nuevo_cliente.sh" --solo-validar "$RAIZ/personal/ficha.ejemplo.json" >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "la ficha de ejemplo debería ser válida"; }
grep -q "Ficha válida" "$TMP/s.txt" || falla "no dice Ficha válida"
grep -q "ARGS:" "$TMP/log" || falla "no llamó a psql"
grep "ARGS:" "$TMP/log" | grep -qiE "minegocio|Mi Negocio|fecha_inicio|ficha=" && { grep "ARGS:" "$TMP/log"; falla "la ficha viajó como argumento de psql"; }

# Nombre con comillas, $ y una marca parecida: se guarda tal cual.
python3 - "$TMP/rara.json" <<'PY'
import json, sys
f = {"nombre": "D'Ángelo $uper $$ \"Tienda\" $ficha_x$", "fecha_inicio": "2026-01-01", "dueno": {"correo": "raro@prueba.hn"}}
json.dump(f, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PY
: > "$TMP/log"
PGDATABASE="$BASE" SIN_PREGUNTAR=1 PATH="$TMP/bin:$PATH" bash "$H/nuevo_cliente.sh" "$TMP/rara.json" >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "no creó la empresa con nombre raro"; }
grep -q "Empresa creada" "$TMP/s.txt" || falla "no dice Empresa creada"
grep "ARGS:" "$TMP/log" | grep -q "Ángelo" && falla "el nombre viajó como argumento"
[ "$(q "SELECT count(*) FROM public.empresa WHERE nombre = 'D''Ángelo \$uper \$\$ \"Tienda\" \$ficha_x\$'")" = "1" ] \
  || { q "SELECT nombre FROM public.empresa"; falla "el nombre no se guardó tal cual"; }
echo "ok"
