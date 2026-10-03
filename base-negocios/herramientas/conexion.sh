#!/usr/bin/env bash
# =====================================================================
# conexion.sh  -  Conexión segura a una base y respaldos cifrados.
# No se ejecuta solo: lo cargan con "source" migrar.sh, nuevo_cliente.sh,
# respaldar.sh y restaurar.sh.
#
# Secretos (regla): la clave NUNCA va como argumento visible de psql o
# pg_dump (se vería con "ps" y queda en el historial). Se guarda en un
# archivo pgpass temporal con permisos 600 dentro de una carpeta temporal
# privada, que se borra al terminar (conexion_limpiar). La cadena de
# conexión se lee de un argumento, de DATABASE_URL o de PGHOST/PGDATABASE;
# si no trae clave y la base no es local, se pide con "read -s" (no se ve).
#
#   conexion_preparar CADENA ORIGEN   arma PGHOST/PGPORT/PGUSER/PGDATABASE
#                                     y PGPASSFILE (temporal, 600)
#   conexion_mostrar                  a dónde se conecta (host completo)
#   conexion_info                     datos del servidor y empresas que hay
#   conexion_identificador            qué debe escribir el usuario
#   conexion_confirmar "ACCION"       pide escribirlo (SIN_PREGUNTAR=1 solo en base local)
#   respaldo_hacer RUTA_SIN_EXTENSION pg_dump cifrado (age o gpg); deja RESPALDO_ARCHIVO
#   respaldo_descifrar ARCHIVO        descifra a la salida estándar (para pg_restore)
#   conexion_limpiar                  borra la carpeta temporal (con la clave)
#
# Variables opcionales:
#   RESPALDO_AGE_DESTINATARIO  llave PÚBLICA age ("age1...") o archivo de llaves:
#                              cifra sin pedir clave; la llave privada queda fuera.
#   RESPALDO_AGE_IDENTIDAD     archivo con la llave PRIVADA age (solo para restaurar)
#   RESPALDO_CLAVE_ARCHIVO     archivo (permisos 600) con la frase de gpg; si no
#                              está, la frase se pide en la terminal (dos veces)
#   RESPALDO_SIN_CIFRAR=1      solo base local de pruebas, si no hay age ni gpg
#   BASE_LOCAL_SOCKET          carpeta del socket de OTRA base local de pruebas
#                              que se quiere tratar como local (por defecto solo
#                              cuenta el socket de base-negocios/.pgdata)
# =====================================================================

CONEX_TMP=""
CONEX_ORIGEN=""
CONEX_MOSTRAR=""
CONEX_BASE=""
CONEX_N_EMPRESAS=0
CONEX_EMPRESAS=""
CONEX_ID=""
CONEX_ID_QUE=""
RESPALDO_ARCHIVO=""

conexion_error() { echo "ERROR: $*" >&2; }

conexion_limpiar() {
  if [ -n "$CONEX_TMP" ] && [ -d "$CONEX_TMP" ]; then
    rm -rf "$CONEX_TMP"
  fi
}

# ¿Se puede preguntar algo en la terminal?
conexion_hay_terminal() { { : < /dev/tty; } 2>/dev/null; }

# Base local de PRUEBAS: SOLO el socket del servidor de pruebas del proyecto
# (carpeta base-negocios/.pgdata, o PRUEBAS_PGDATA si se usa otra) o la
# carpeta de socket que se declare a propósito en BASE_LOCAL_SOCKET.
# "localhost", "127.0.0.1" o un socket cualquiera NO cuentan como locales:
# por un túnel SSH o un proxy pueden ser la base de un cliente.
CONEX_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
conexion_es_local() {
  local h="${PGHOST:-}" real permitido
  [ -n "$h" ] && [ "${h:0:1}" = "/" ] && [ -d "$h" ] || return 1
  real="$(cd "$h" 2>/dev/null && pwd -P)" || return 1
  for permitido in "${PRUEBAS_PGDATA:-$CONEX_RAIZ/.pgdata}" "${BASE_LOCAL_SOCKET:-}"; do
    [ -n "$permitido" ] && [ -d "$permitido" ] || continue
    [ "$real" = "$(cd "$permitido" && pwd -P)" ] && return 0
  done
  return 1
}

# Referencia del proyecto de Supabase (o nada) a partir del host y usuario.
#   db.<ref>.supabase.co               conexión directa
#   *.pooler.supabase.com + postgres.<ref>   conexión por el pooler
conexion_ref_supabase() {
  local h="${1:-}" u="${2:-}"
  if [[ "$h" =~ ^db\.([a-z0-9]+)\.supabase\.(co|com|net)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$h" == *.pooler.supabase.com ]] && [[ "$u" =~ ^[a-z_]+\.([a-z0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

conexion_preparar() {
  local cadena="${1:-}"
  CONEX_ORIGEN="${2:-variables}"
  CONEX_TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/conexion.XXXXXX")" || { conexion_error "no se pudo crear la carpeta temporal."; return 1; }
  local clave="$CONEX_TMP/clave" datos estado h po us db ssl tiene

  if [ -n "$cadena" ]; then
    # La cadena entra por la entrada estándar (no queda en la lista de procesos).
    datos="$(printf '%s' "$cadena" | python3 -c '
import os, sys, urllib.parse as u
c = sys.stdin.read().strip()
try:
    p = u.urlsplit(c)
    if p.scheme not in ("postgres", "postgresql"):
        raise ValueError("debe empezar con postgresql://")
    q = dict(u.parse_qsl(p.query))
    host = q.get("host") or (p.hostname or "")
    port = q.get("port") or (str(p.port) if p.port else "")
    user = q.get("user") or u.unquote(p.username or "")
    db   = q.get("dbname") or u.unquote(p.path.lstrip("/"))
    pw   = q.get("password") or (u.unquote(p.password) if p.password is not None else "")
    ssl  = q.get("sslmode", "")
except Exception as e:
    print("ERROR\x1f" + str(e)); sys.exit(0)
if pw:
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, pw.encode("utf-8")); os.close(fd)
print("\x1f".join(["OK", host, port, user, db, ssl, "1" if pw else "0"]))
' "$clave")"
    IFS=$'\x1f' read -r estado h po us db ssl tiene <<< "$datos"
    if [ "$estado" != "OK" ]; then
      conexion_error "la cadena de conexión no es válida (${h:-formato desconocido}). Ejemplo: postgresql://postgres@db.xxxx.supabase.co:5432/postgres"
      return 1
    fi
    [ -n "$h" ]   && export PGHOST="$h"
    [ -n "$po" ]  && export PGPORT="$po"
    [ -n "$us" ]  && export PGUSER="$us"
    [ -n "$db" ]  && export PGDATABASE="$db"
    [ -n "$ssl" ] && export PGSSLMODE="$ssl"
    CONEX_MOSTRAR="postgresql://${PGUSER:-}$([ "$tiene" = "1" ] && echo ':****')@${PGHOST:-(socket local)}:${PGPORT:-5432}/${PGDATABASE:-}"
  else
    CONEX_MOSTRAR="PGHOST=${PGHOST:-(socket local)} PGPORT=${PGPORT:-5432} PGDATABASE=${PGDATABASE:-} PGUSER=${PGUSER:-}"
  fi
  # La cadena ya no hace falta: que no llegue a los procesos hijos.
  unset DATABASE_URL

  # Una clave en PGPASSWORD se pasa al archivo temporal y se quita del entorno.
  if [ ! -s "$clave" ] && [ -n "${PGPASSWORD:-}" ]; then
    (umask 077; printf '%s' "$PGPASSWORD" > "$clave")
  fi
  unset PGPASSWORD

  # Seguridad: las variables de pruebas solo valen con una base local.
  if [ "${SIN_PREGUNTAR:-0}" = "1" ] && ! conexion_es_local; then
    conexion_error "SIN_PREGUNTAR=1 solo se acepta con la base local de pruebas, no con $PGHOST."
    return 1
  fi

  # Sin clave, base remota y sin archivo pgpass propio: pedirla sin mostrarla.
  if [ ! -s "$clave" ] && ! conexion_es_local && [ -z "${PGPASSFILE:-}" ] && [ ! -f "$HOME/.pgpass" ]; then
    if conexion_hay_terminal; then
      local c=""
      IFS= read -rs -p "Clave de la base para ${PGUSER:-postgres}@${PGHOST} (no se muestra): " c < /dev/tty || true
      echo >&2
      (umask 077; printf '%s' "$c" > "$clave")
      c=""
    fi
  fi
  if [ -s "$clave" ]; then
    # Formato pgpass: host:puerto:base:usuario:clave (\ y : se escapan).
    python3 -c '
import sys
pw = open(sys.argv[1], encoding="utf-8").read()
pw = pw.replace("\\", "\\\\").replace(":", "\\:")
import os
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, ("*:*:*:*:" + pw + "\n").encode("utf-8")); os.close(fd)
' "$clave" "$CONEX_TMP/pgpass"
    rm -f "$clave"
    export PGPASSFILE="$CONEX_TMP/pgpass"
  fi
  return 0
}

conexion_mostrar() {
  echo "Destino: servidor ${PGHOST:-(socket local)}  puerto ${PGPORT:-5432}  base \"${PGDATABASE:-}\"  usuario ${PGUSER:-}"
  case "$CONEX_ORIGEN" in
    DATABASE_URL) echo "  OJO: se usa la variable DATABASE_URL que ya estaba en esta terminal: $CONEX_MOSTRAR" ;;
    variables)    echo "  OJO: se usan las variables PGHOST/PGDATABASE que ya estaban en esta terminal." ;;
    argumento)    echo "  Cadena: $CONEX_MOSTRAR" ;;
  esac
}

# Datos del servidor y empresas que ya tiene la base.
conexion_info() {
  local info ip puerto usuario version hay
  if ! info="$(psql -X -q -tA -v ON_ERROR_STOP=1 -F $'\x1f' -c "SELECT current_database(),
        coalesce(host(inet_server_addr()), 'socket local'), current_setting('port'),
        current_user, current_setting('server_version'), to_regclass('public.empresa') IS NOT NULL" 2>&1)"; then
    conexion_error "no se pudo conectar a la base. Revise servidor, base, usuario y clave."
    echo "$info" | sed -n 's/^.*\(FATAL\|ERROR\): */  /p' | head -2 >&2
    return 1
  fi
  IFS=$'\x1f' read -r CONEX_BASE ip puerto usuario version hay <<< "$info"
  echo "Conectado: base \"$CONEX_BASE\" en ${PGHOST:-socket local} ($ip):$puerto como $usuario (PostgreSQL $version)"
  CONEX_N_EMPRESAS=0; CONEX_EMPRESAS=""
  if [ "$hay" = "t" ]; then
    CONEX_EMPRESAS="$(psql -X -q -tA -c "SELECT nombre FROM public.empresa ORDER BY creado_en, nombre")"
    CONEX_N_EMPRESAS="$(printf '%s' "$CONEX_EMPRESAS" | grep -c . || true)"
    if [ "$CONEX_N_EMPRESAS" -gt 0 ]; then
      echo "Empresas en esa base ($CONEX_N_EMPRESAS):"
      printf '%s\n' "$CONEX_EMPRESAS" | sed 's/^/  - /'
    fi
  else
    echo "Esa base todavía no tiene el núcleo instalado."
  fi
}

# Lo que hay que escribir para confirmar, de más a menos fuerte:
#   1) referencia del proyecto de Supabase; 2) nombre de la única empresa
#   que ya está en la base; 3) nombre de la base.
conexion_identificador() {
  local ref
  ref="$(conexion_ref_supabase "${PGHOST:-}" "${PGUSER:-}")"
  if [ -n "$ref" ]; then
    CONEX_ID="$ref"; CONEX_ID_QUE="la referencia del proyecto de Supabase"
  elif [ "$CONEX_N_EMPRESAS" = "1" ]; then
    CONEX_ID="$CONEX_EMPRESAS"; CONEX_ID_QUE="el nombre de la empresa que ya está en esa base"
  else
    CONEX_ID="$CONEX_BASE"; CONEX_ID_QUE="el nombre de la base"
  fi
}

conexion_confirmar() {
  local accion="$1" respuesta=""
  if [ "${SIN_PREGUNTAR:-0}" = "1" ]; then
    conexion_es_local && return 0
    conexion_error "SIN_PREGUNTAR=1 solo se acepta con la base local de pruebas."; return 1
  fi
  printf 'Para %s escriba %s (%s): ' "$accion" "$CONEX_ID_QUE" "$CONEX_ID"
  IFS= read -r respuesta || true
  respuesta="$(printf '%s' "$respuesta" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ "$respuesta" != "$CONEX_ID" ]; then
    echo
    echo "Cancelado: lo escrito no coincide. No se hizo nada." >&2
    return 1
  fi
  return 0
}

# Frase para gpg en un archivo (de RESPALDO_CLAVE_ARCHIVO o pedida en la terminal).
respaldo_frase() {
  local veces="${1:-2}" f1="" f2="" permisos
  if [ -n "${RESPALDO_CLAVE_ARCHIVO:-}" ]; then
    [ -r "$RESPALDO_CLAVE_ARCHIVO" ] || { conexion_error "no se puede leer RESPALDO_CLAVE_ARCHIVO."; return 1; }
    permisos="$(stat -c %a "$RESPALDO_CLAVE_ARCHIVO" 2>/dev/null || echo 600)"
    case "$permisos" in 600|400) ;; *) echo "AVISO: $RESPALDO_CLAVE_ARCHIVO tiene permisos $permisos; deberían ser 600 (chmod 600)." >&2 ;; esac
    RESPALDO_FRASE_ARCHIVO="$RESPALDO_CLAVE_ARCHIVO"
    return 0
  fi
  conexion_hay_terminal || { conexion_error "no hay terminal para pedir la frase del respaldo; use RESPALDO_CLAVE_ARCHIVO."; return 1; }
  IFS= read -rs -p "Frase para cifrar/descifrar el respaldo (no se muestra): " f1 < /dev/tty || true; echo >&2
  if [ "$veces" = "2" ]; then
    if [ "${#f1}" -lt 12 ]; then conexion_error "la frase debe tener al menos 12 letras."; return 1; fi
    IFS= read -rs -p "Repita la frase: " f2 < /dev/tty || true; echo >&2
    [ "$f1" = "$f2" ] || { conexion_error "las frases no coinciden."; return 1; }
  fi
  RESPALDO_FRASE_ARCHIVO="$CONEX_TMP/frase"
  (umask 077; printf '%s' "$f1" > "$RESPALDO_FRASE_ARCHIVO")
  f1=""; f2=""
}

# Respaldo completo, cifrado. $1 = ruta sin extensión. Nunca deja una copia
# sin cifrar en disco (pg_dump pasa directo al cifrado).
respaldo_hacer() {
  local destino="$1" archivo
  mkdir -p "$(dirname "$destino")"
  if [ -n "${RESPALDO_AGE_DESTINATARIO:-}" ] && command -v age >/dev/null 2>&1; then
    archivo="$destino.dump.age"
    local opcion=(-r "$RESPALDO_AGE_DESTINATARIO")
    [ -f "$RESPALDO_AGE_DESTINATARIO" ] && opcion=(-R "$RESPALDO_AGE_DESTINATARIO")
    if ! pg_dump --format=custom | age "${opcion[@]}" -o "$archivo"; then
      rm -f "$archivo"; conexion_error "falló el respaldo cifrado con age."; return 1
    fi
  elif command -v gpg >/dev/null 2>&1; then
    archivo="$destino.dump.gpg"
    respaldo_frase 2 || return 1
    mkdir -p "$CONEX_TMP/gnupg"; chmod 700 "$CONEX_TMP/gnupg"
    if ! pg_dump --format=custom | GNUPGHOME="$CONEX_TMP/gnupg" gpg --batch --yes --quiet --pinentry-mode loopback \
         --passphrase-file "$RESPALDO_FRASE_ARCHIVO" --symmetric --cipher-algo AES256 --output "$archivo"; then
      rm -f "$archivo"; conexion_error "falló el respaldo cifrado con gpg."; return 1
    fi
  else
    archivo="$destino.dump"
    echo "AVISO: no hay age ni gpg en este equipo; el respaldo quedaría SIN CIFRAR (con datos de clientes)." >&2
    if [ "${RESPALDO_SIN_CIFRAR:-0}" = "1" ] && conexion_es_local; then
      :
    else
      local r=""
      conexion_hay_terminal || { conexion_error "instale gpg o age (recomendado)."; return 1; }
      IFS= read -r -p 'Para seguir sin cifrar escriba SIN CIFRAR: ' r < /dev/tty || true
      [ "$r" = "SIN CIFRAR" ] || { conexion_error "cancelado: instale gpg o age."; return 1; }
    fi
    (umask 077; pg_dump --format=custom --file="$archivo") || { rm -f "$archivo"; conexion_error "falló pg_dump."; return 1; }
  fi
  if [ ! -s "$archivo" ]; then
    rm -f "$archivo"; conexion_error "el respaldo quedó vacío."; return 1
  fi
  chmod 600 "$archivo"
  RESPALDO_ARCHIVO="$archivo"
}

# Descifra un respaldo a la salida estándar (.age, .gpg o .dump sin cifrar).
respaldo_descifrar() {
  local archivo="$1"
  case "$archivo" in
    *.age)
      [ -n "${RESPALDO_AGE_IDENTIDAD:-}" ] || { conexion_error "indique la llave privada en RESPALDO_AGE_IDENTIDAD."; return 1; }
      age -d -i "$RESPALDO_AGE_IDENTIDAD" "$archivo" ;;
    *.gpg)
      [ -n "${RESPALDO_FRASE_ARCHIVO:-}" ] || respaldo_frase 1 || return 1
      mkdir -p "$CONEX_TMP/gnupg"; chmod 700 "$CONEX_TMP/gnupg"
      GNUPGHOME="$CONEX_TMP/gnupg" gpg --batch --quiet --pinentry-mode loopback \
        --passphrase-file "$RESPALDO_FRASE_ARCHIVO" --decrypt "$archivo" ;;
    *)
      cat "$archivo" ;;
  esac
}
