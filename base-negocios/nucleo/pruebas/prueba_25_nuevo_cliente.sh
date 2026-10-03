#!/usr/bin/env bash
# PRUEBA: nuevo_cliente.sh lee una ficha, la valida (JSON, esquema y base), pide confirmación y crea la empresa
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
NUEVO="$RAIZ/herramientas/nuevo_cliente.sh"
EJEMPLO="$RAIZ/personal/ficha.ejemplo.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PGDATABASE="$BASE"
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -c "$1"; }
contar() { q "SELECT count(*) FROM public.empresa WHERE nombre = 'Mi Negocio S. de R.L.'"; }

# Los usuarios de la ficha de ejemplo deben existir en auth.users.
q "INSERT INTO auth.users (email) VALUES ('dueno@minegocio.hn'), ('soporte@proveedor.hn')"

# 1) La ficha de ejemplo cumple el esquema y la base la acepta (sin crear nada).
SIN_PREGUNTAR=1 bash "$NUEVO" --solo-validar "$EJEMPLO" >"$TMP/s.txt" 2>&1 || { cat "$TMP/s.txt"; falla "la ficha de ejemplo debería ser válida"; }
grep -q "Ficha válida" "$TMP/s.txt" || falla "no dice Ficha válida"
grep -q "ficha.schema.json: bien" "$TMP/s.txt" || falla "no revisó el esquema"
[ "$(contar)" = "0" ] || falla "--solo-validar creó la empresa"

# 2) Nombre de base equivocado: cancela.
if echo "otra" | bash "$NUEVO" "$EJEMPLO" >"$TMP/s.txt" 2>&1; then falla "debía cancelar"; fi
grep -q "Cancelado" "$TMP/s.txt" || falla "no dice Cancelado"
[ "$(contar)" = "0" ] || falla "creó la empresa aunque canceló"

# 3) Con el nombre correcto: la crea con los datos de la ficha.
echo "$BASE" | bash "$NUEVO" "$EJEMPLO" >"$TMP/s.txt" 2>&1 || { cat "$TMP/s.txt"; falla "no creó la empresa"; }
grep -q "Empresa creada" "$TMP/s.txt" || falla "no dice Empresa creada"
[ "$(contar)" = "1" ] || falla "no está la empresa"
[ "$(q "SELECT rubro || moneda || pais || fecha_inicio FROM public.empresa WHERE nombre = 'Mi Negocio S. de R.L.'")" = "FerreteríaHNLHN2026-01-01" ] \
  || falla "datos de la empresa distintos a la ficha"
[ "$(q "SELECT count(*) FROM public.usuario_empresa ue JOIN auth.users u ON u.id = ue.user_id
        WHERE u.email = 'dueno@minegocio.hn' AND ue.rol = 'dueno' AND ue.nombre = 'Juan Pérez'")" = "1" ] || falla "dueño mal creado"

# 4) Ficha que no cumple el esquema: error claro, nada creado.
python3 - "$EJEMPLO" "$TMP/mala.json" <<'PY'
import json, sys
f = json.load(open(sys.argv[1], encoding="utf-8")); f["nombre"] = "Otra"; f["moneda"] = "hnl"
json.dump(f, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
if SIN_PREGUNTAR=1 bash "$NUEVO" "$TMP/mala.json" >"$TMP/s.txt" 2>&1; then falla "aceptó moneda en minúsculas"; fi
grep -q "moneda" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "el error no menciona el campo moneda"; }

# 5) Ficha que cumple el esquema pero la base rechaza (dueño no registrado).
python3 - "$EJEMPLO" "$TMP/sin_dueno.json" <<'PY'
import json, sys
f = json.load(open(sys.argv[1], encoding="utf-8")); f["nombre"] = "Otra"; f["dueno"] = {"correo": "nadie@nada.hn"}
json.dump(f, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
if SIN_PREGUNTAR=1 bash "$NUEVO" "$TMP/sin_dueno.json" >"$TMP/s.txt" 2>&1; then falla "aceptó dueño no registrado"; fi
grep -q "USUARIO_NO_EXISTE" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no explica que el dueño no existe"; }

# 6) JSON roto.
printf '{"nombre": "Rota",' > "$TMP/rota.json"
if SIN_PREGUNTAR=1 bash "$NUEVO" "$TMP/rota.json" >"$TMP/s.txt" 2>&1; then falla "aceptó JSON roto"; fi
grep -q "no es JSON válido" "$TMP/s.txt" || falla "no dice que el JSON está roto"

[ "$(q "SELECT count(*) FROM public.empresa WHERE nombre IN ('Otra', 'Rota')")" = "0" ] || falla "se creó algo con fichas malas"
echo "ok"
