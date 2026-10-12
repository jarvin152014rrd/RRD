#!/usr/bin/env bash
# =====================================================================
# armar_app.sh  -  Arma la app de UN cliente lista para hosting estático
# (Netlify: se arrastra la carpeta). Ver docs/SUPABASE.md, paso 10.
#
#   bash herramientas/armar_app.sh <cliente> <Project URL> <anon key>
#   ej.: bash herramientas/armar_app.sh ferreteria-lopez https://abcd1234.supabase.co eyJhbGciOi...
#
# Deja dist/app-<cliente>/ (dist/ no va a git) con:
#   * los archivos de app/ (sin config.js local, ni LEEME/CHANGELOG/PENDIENTES)
#   * config.js con modo "supabase", la URL y la llave PÚBLICA (anon o
#     "publishable"); rubro y palabras de clientes/<cliente>/app.json si existe
#   * _headers: cabeceras de seguridad básicas (CSP que solo deja hablar con su
#     Supabase, sin marcos, nosniff...) y sw.js / config.js / index.html sin
#     caché, para que una versión nueva llegue sola a los celulares
# No hace falta _redirects: la app navega con "#/..." (siempre abre index.html).
#
# Seguridad: se NIEGA si la llave es la service_role (JWT con role
# "service_role") o una llave secreta "sb_secret_...", y al final revisa que
# en la carpeta no haya ninguna llave secreta.
# =====================================================================
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in -h|--ayuda) sed -n '2,21p' "$0"; exit 0 ;; esac
[ "$#" -eq 3 ] || { echo "Uso: bash herramientas/armar_app.sh <cliente> <Project URL> <anon key>" >&2; exit 2; }
CLIENTE="$1"; URL="${2%/}"; LLAVE="$3"

[[ "$CLIENTE" =~ ^[a-z0-9][a-z0-9_-]{1,40}$ ]] || { echo "ERROR: el cliente va en minúsculas, números, - o _ (como su carpeta en clientes/)." >&2; exit 1; }
[[ "$URL" =~ ^https://[A-Za-z0-9.-]+$ ]] || { echo "ERROR: la Project URL es como https://abcd1234.supabase.co (sin nada después)." >&2; exit 1; }
[[ "$URL" =~ \.supabase\.co$ ]] || echo "AVISO: la URL no termina en .supabase.co; revise que sea la Project URL."

# La llave: pública sí, secreta nunca.
python3 - "$LLAVE" <<'PY' || exit 1
import base64, json, sys
k = sys.argv[1].strip()
def no(msg):
    print("ERROR: " + msg, file=sys.stderr); sys.exit(1)
if k.startswith("sb_secret_"):
    no("esa es una llave SECRETA (sb_secret_...). Use la publishable/anon (es la pública).")
if k.startswith("sb_publishable_"):
    sys.exit(0)
partes = k.split(".")
if len(partes) != 3:
    no("la llave no parece la anon key de Supabase (Project Settings > API Keys > anon public).")
try:
    datos = json.loads(base64.urlsafe_b64decode(partes[1] + "=" * (-len(partes[1]) % 4)))
except Exception:
    no("la llave no se puede leer; cópiela completa (es un texto largo que empieza con eyJ).")
if datos.get("role") != "anon":
    no("esa llave es \"%s\", NO la anon. Nunca ponga la service_role en la app." % datos.get("role"))
PY

DESTINO="$RAIZ/dist/app-$CLIENTE"
rm -rf "$DESTINO"
mkdir -p "$DESTINO"
# Copia de la app sin lo que no se publica.
(cd "$RAIZ/app" && tar cf - --exclude=./config.js --exclude=./config.ejemplo.js --exclude=./LEEME.md \
  --exclude=./CHANGELOG.md --exclude=./PENDIENTES.md .) | (cd "$DESTINO" && tar xf -)

# config.js (rubro y palabras del Armador si existen).
python3 - "$RAIZ/clientes/$CLIENTE/app.json" "$URL" "$LLAVE" "$CLIENTE" > "$DESTINO/config.js" <<'PY'
import json, os, sys
app_json, url, llave, cliente = sys.argv[1:]
extra = ""
if os.path.exists(app_json):
    a = json.load(open(app_json, encoding="utf-8"))
    if a.get("rubro"):
        extra += "  rubro: %s,\n" % json.dumps(a["rubro"], ensure_ascii=False)
    if a.get("palabras"):
        extra += "  // Palabras del rubro: solo cambian títulos del menú (ver js/menu_datos.js).\n"
        extra += "  palabras: %s,\n" % json.dumps(a["palabras"], ensure_ascii=False, indent=2).replace("\n", "\n  ")
print("""// Configuración de la app de %s (la armó herramientas/armar_app.sh).
// La llave de aquí es la PÚBLICA (anon): la seguridad está en la base. Nunca la service_role.
export default {
  modo: 'supabase',
  supabaseUrl: %s,
  supabaseAnonKey: %s,
  revisarSesionSegundos: 60,
  bucketComprobantes: '',
%s};""" % (cliente, json.dumps(url), json.dumps(llave.strip()), extra))
PY

# Cabeceras de Netlify.
cat > "$DESTINO/_headers" <<EOF
# Cabeceras para Netlify (las armó herramientas/armar_app.sh).
/*
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(self), microphone=(), geolocation=(), payment=()
  Strict-Transport-Security: max-age=31536000
  Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: blob: $URL; connect-src 'self' $URL; manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'

# El service worker y la configuración: siempre la versión nueva.
/sw.js
  Cache-Control: no-cache, no-store, must-revalidate
/config.js
  Cache-Control: no-cache, no-store, must-revalidate
EOF

# Revisión final: ninguna llave secreta en lo que se va a publicar.
if grep -rIl -E 'sb_secret_|service_role\.key|SUPABASE_SERVICE_ROLE_KEY' "$DESTINO" >/dev/null 2>&1; then
  echo "ERROR: hay algo que parece una llave secreta en $DESTINO. No lo publique." >&2; exit 1
fi
python3 - "$DESTINO" <<'PY' || exit 1
import base64, json, os, re, sys
for raiz, _, archivos in os.walk(sys.argv[1]):
    for a in archivos:
        texto = open(os.path.join(raiz, a), "rb").read().decode("utf-8", "ignore")
        for t in re.findall(r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", texto):
            p = t.split(".")[1]
            try:
                rol = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("role")
            except Exception:
                continue
            if rol != "anon":
                print("ERROR: %s tiene una llave con role \"%s\". No lo publique." % (a, rol), file=sys.stderr)
                sys.exit(1)
PY

echo "Listo: $DESTINO"
echo "Súbala a Netlify: app.netlify.com > Add new site > Deploy manually > arrastre la carpeta app-$CLIENTE."
