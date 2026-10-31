#!/usr/bin/env python3
# =====================================================================
# sql_una_peticion.py  -  SOLO PRUEBAS LOCALES. Manda un archivo SQL completo
# en UNA sola petición ("simple query"), igual que el SQL Editor de Supabase:
# PostgreSQL lo corre en una sola transacción implícita (todo o nada).
# psql no sirve para esto: parte el archivo en sentencias, y "psql -c" no
# acepta textos de más de 128 KB.
#
#   python3 herramientas/sql_una_peticion.py SOCKET_DIR PUERTO USUARIO BASE ARCHIVO.sql
#
# Solo socket local con autenticación "trust" (la base de pruebas). Imprime la
# última tabla de resultados (como el SQL Editor) y los avisos (NOTICE) si
# AVISOS=1. Sale con código 1 y el mensaje si PostgreSQL devuelve error.
# =====================================================================
import os
import socket
import struct
import sys


def leer_exacto(s, n):
    b = b""
    while len(b) < n:
        parte = s.recv(n - len(b))
        if not parte:
            raise SystemExit("ERROR: el servidor cerró la conexión.")
        b += parte
    return b


def mensaje(s):
    tipo = leer_exacto(s, 1)
    largo = struct.unpack("!I", leer_exacto(s, 4))[0]
    return tipo, leer_exacto(s, largo - 4)


def campos(cuerpo):
    # ErrorResponse / NoticeResponse: pares (código de 1 byte, texto\0)
    d = {}
    for trozo in cuerpo.split(b"\0"):
        if trozo:
            d[chr(trozo[0])] = trozo[1:].decode("utf-8", "replace")
    return d


def main():
    if len(sys.argv) != 6:
        raise SystemExit("uso: sql_una_peticion.py SOCKET_DIR PUERTO USUARIO BASE ARCHIVO.sql")
    carpeta, puerto, usuario, base, archivo = sys.argv[1:]
    sql = open(archivo, encoding="utf-8").read()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.path.join(carpeta, ".s.PGSQL.%s" % puerto))
    inicio = struct.pack("!I", 196608) + b"user\0" + usuario.encode() + b"\0database\0" + base.encode() + b"\0\0"
    s.sendall(struct.pack("!I", len(inicio) + 4) + inicio)
    while True:
        t, c = mensaje(s)
        if t == b"R" and struct.unpack("!I", c[:4])[0] != 0:
            raise SystemExit("ERROR: la base pide clave; esta herramienta es solo para la base local de pruebas.")
        if t == b"E":
            raise SystemExit("ERROR: " + campos(c).get("M", "?"))
        if t == b"Z":
            break
    q = sql.encode("utf-8") + b"\0"
    s.sendall(b"Q" + struct.pack("!I", len(q) + 4) + q)
    error, columnas, filas, avisos = None, [], [], []
    while True:
        t, c = mensaje(s)
        if t == b"T":
            n = struct.unpack("!H", c[:2])[0]
            columnas, filas, p = [], [], 2
            for _ in range(n):
                fin = c.index(b"\0", p)
                columnas.append(c[p:fin].decode())
                p = fin + 1 + 18
        elif t == b"D":
            n = struct.unpack("!H", c[:2])[0]
            fila, p = [], 2
            for _ in range(n):
                largo = struct.unpack("!i", c[p:p + 4])[0]
                p += 4
                if largo < 0:
                    fila.append("")
                else:
                    fila.append(c[p:p + largo].decode("utf-8", "replace"))
                    p += largo
            filas.append(fila)
        elif t == b"N":
            avisos.append(campos(c).get("M", ""))
        elif t == b"E":
            error = campos(c)
        elif t == b"Z":
            break
    s.close()
    if os.environ.get("AVISOS") == "1":
        for a in avisos:
            print("AVISO: " + a)
    if error:
        print("ERROR: %s%s" % (error.get("M", "?"), (" (" + error["W"].splitlines()[0] + ")") if "W" in error else ""), file=sys.stderr)
        sys.exit(1)
    if columnas:
        print(" | ".join(columnas))
        for f in filas:
            print(" | ".join(f))


if __name__ == "__main__":
    main()
