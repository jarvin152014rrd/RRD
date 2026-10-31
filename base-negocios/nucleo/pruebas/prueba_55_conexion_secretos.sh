#!/usr/bin/env bash
# PRUEBA: las herramientas nunca pasan la clave a psql/pg_dump como argumento ni en PGPASSWORD (usan un pgpass temporal 600 que se borra), muestran el host completo y la DATABASE_URL tomada del entorno, y confirman con un identificador único (ref de Supabase o nombre de la empresa)
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
H="$RAIZ/herramientas"
UNA="${BASE}_una"
TMP="$(mktemp -d)"
limpiar() { dropdb --if-exists "$UNA" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }

# psql, pg_dump y pg_restore "espías": anotan argumentos y entorno, y llaman al real.
REAL="$(dirname "$(command -v psql)")"
mkdir "$TMP/bin"
for p in psql pg_dump pg_restore; do
  cat > "$TMP/bin/$p" <<EOF
#!/usr/bin/env bash
{ echo "ARGS: \$*"
  echo "ENV_PGPASSWORD=\${PGPASSWORD:-}"
  echo "ENV_DATABASE_URL=\${DATABASE_URL:-}"
  echo "PGPASSFILE=\${PGPASSFILE:-}"
  if [ -n "\${PGPASSFILE:-}" ] && [ -f "\$PGPASSFILE" ]; then
    echo "PERM=\$(stat -c %a "\$PGPASSFILE")"
    grep -q "\$ESPERADA" "\$PGPASSFILE" && echo "PGPASS_CON_CLAVE=si"
  fi
} >> "$TMP/log"
exec "$REAL/$p" "\$@"
EOF
  chmod +x "$TMP/bin/$p"
done
SOCK="host=$PGHOST&port=$PGPORT"

# 1) Clave en la cadena (con ":" y "@" codificados): no aparece en argumentos ni en pantalla.
: > "$TMP/log"
salida="$(ESPERADA='Secreto\\:Muy@Raro' PATH="$TMP/bin:$PATH" bash "$H/migrar.sh" --solo-mostrar \
  "postgresql://postgres:Secreto%3AMuy%40Raro@/$BASE?$SOCK" 2>&1)" || { echo "$salida"; falla "migrar con cadena"; }
echo "$salida" | grep -q 'postgresql://postgres:\*\*\*\*@' || falla "no muestra la cadena con la clave tapada"
echo "$salida" | grep -q "Secreto" && falla "la clave salió en pantalla"
grep -q "ARGS:" "$TMP/log" || falla "no llamó a psql"
grep "ARGS:" "$TMP/log" | grep -q "Secreto" && falla "la clave fue como argumento de psql"
grep -q "ENV_PGPASSWORD=$" "$TMP/log" || falla "falta el registro de PGPASSWORD"
grep -q "ENV_PGPASSWORD=." "$TMP/log" && falla "la clave fue en PGPASSWORD"
grep -q "PERM=600" "$TMP/log" || falla "el pgpass temporal no tiene permisos 600"
grep -q "PGPASS_CON_CLAVE=si" "$TMP/log" || falla "la clave no llegó al pgpass (con : escapado)"
pgpass="$(grep -m1 '^PGPASSFILE=' "$TMP/log" | cut -d= -f2-)"
[ -n "$pgpass" ] && [ ! -e "$pgpass" ] || falla "el pgpass temporal no se borró: $pgpass"
echo "$salida" | grep -q "base \"$BASE\"" || falla "no muestra la base"

# 2) DATABASE_URL de la terminal: se AVISA, se muestra (tapada) y no llega a psql.
: > "$TMP/log"
salida="$(ESPERADA='OtraClave' DATABASE_URL="postgresql://postgres:OtraClave@/$BASE?$SOCK" PATH="$TMP/bin:$PATH" \
  bash "$H/migrar.sh" --solo-mostrar 2>&1)" || { echo "$salida"; falla "migrar con DATABASE_URL"; }
echo "$salida" | grep -q "DATABASE_URL que ya estaba" || falla "no avisa que usa DATABASE_URL"
echo "$salida" | grep -q "OtraClave" && falla "mostró la clave de DATABASE_URL"
grep -q "OtraClave" "$TMP/log" && falla "la clave de DATABASE_URL llegó a psql"
grep -q "ENV_DATABASE_URL=." "$TMP/log" && falla "DATABASE_URL quedó en el entorno de psql"
grep -q "PGPASS_CON_CLAVE=si" "$TMP/log" || falla "no usó el pgpass temporal"

# 3) PGPASSWORD de la terminal: pasa al pgpass y sale del entorno.
: > "$TMP/log"
ESPERADA='TerceraClave' PGPASSWORD='TerceraClave' PGDATABASE="$BASE" PATH="$TMP/bin:$PATH" bash "$H/migrar.sh" --solo-mostrar >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "migrar con PGPASSWORD"; }
grep -q "ENV_PGPASSWORD=." "$TMP/log" && falla "PGPASSWORD llegó a psql"
grep -q "PGPASS_CON_CLAVE=si" "$TMP/log" || falla "PGPASSWORD no pasó al pgpass"
grep -q "variables PGHOST/PGDATABASE que ya estaban" "$TMP/s.txt" || falla "no avisa que usa variables de la terminal"

# 4) Variables de prueba con una base remota: se niega ANTES de conectarse.
: > "$TMP/log"
if SIN_PREGUNTAR=1 ESPERADA=x PATH="$TMP/bin:$PATH" bash "$H/migrar.sh" \
     "postgresql://postgres@db.abcdefghijklmnopqrst.supabase.co:5432/postgres" >"$TMP/s.txt" 2>&1; then
  falla "aceptó SIN_PREGUNTAR con una base remota"
fi
grep -q "SIN_PREGUNTAR=1 solo se acepta" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no explica por qué"; }
[ ! -s "$TMP/log" ] || falla "intentó conectarse"
if bash "$H/migrar.sh" --solo-mostrar "mysql://x@y/z" >"$TMP/s.txt" 2>&1; then falla "aceptó una cadena que no es de PostgreSQL"; fi
grep -q "no es válida" "$TMP/s.txt" || falla "no dice que la cadena no es válida"

# 5) Identificador del proyecto de Supabase (conexión directa y por el pooler).
source "$H/conexion.sh"
[ "$(conexion_ref_supabase db.abcdefghijklmnopqrst.supabase.co postgres)" = "abcdefghijklmnopqrst" ] || falla "ref directa"
[ "$(conexion_ref_supabase aws-0-us-east-1.pooler.supabase.com postgres.abcdefghijklmnopqrst)" = "abcdefghijklmnopqrst" ] || falla "ref por pooler"
[ -z "$(conexion_ref_supabase localhost postgres)" ] || falla "localhost no es Supabase"

# 6) Base con UNA empresa: hay que escribir el nombre de esa empresa (no el de la base).
createdb "$UNA"
psql -X -q -d "$UNA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
PGDATABASE="$UNA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$H/migrar.sh" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d "$UNA" >/dev/null <<'SQL'
INSERT INTO auth.users (email) VALUES ('uno@prueba.hn'), ('dueno@minegocio.hn'), ('soporte@proveedor.hn');
SET ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
SELECT public.crear_empresa_inicial('{"nombre": "Empresa Uno", "fecha_inicio": "2026-01-01", "dueno": {"correo": "uno@prueba.hn"}}');
SQL
if echo "$UNA" | PGDATABASE="$UNA" bash "$H/nuevo_cliente.sh" "$RAIZ/personal/ficha.ejemplo.json" >"$TMP/s.txt" 2>&1; then
  falla "aceptó el nombre de la base cuando ya hay una empresa"
fi
grep -q "el nombre de la empresa que ya está en esa base (Empresa Uno)" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no pide el nombre de la empresa"; }
grep -q "Cancelado" "$TMP/s.txt" || falla "no dice Cancelado"
echo "Empresa Uno" | DATABASE_URL="postgresql://postgres@/$UNA?$SOCK" bash "$H/nuevo_cliente.sh" "$RAIZ/personal/ficha.ejemplo.json" >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "no creó con el nombre de la empresa"; }
grep -q "DATABASE_URL que ya estaba" "$TMP/s.txt" || falla "nuevo_cliente no avisa que usa DATABASE_URL"
grep -q "Empresa creada" "$TMP/s.txt" || falla "no dice Empresa creada"
[ "$(psql -X -tA -d "$UNA" -c "SELECT count(*) FROM public.empresa")" = "2" ] || falla "no quedaron 2 empresas"
echo "ok"
