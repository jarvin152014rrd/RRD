"""Portal falso para probar fase1.py sin tocar el portal real.

Copia la forma de portalunico.iaip.gob.hn vista en las capturas (FONAC, id 28).
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import quote
import sys

VERSION = int(sys.argv[2]) if len(sys.argv) > 2 else 1
NOMBRES = {"28": "Foro Nacional De Convergencia (FONAC)", "30": "Municipalidad de Prueba"}

MENU = [(1, "Organigrama"), (7, "Remuneracion de Empleados"), (12, "Licitacion"),
        (20, "Compras"), (31, "Diario Oficial La Gaceta"), (40, "Apartado Raro"),
        (50, "Balance General"), (60, "Gasto")]

ARCHIVOS = Path(__file__).parent / "archivos"
VISTOS = set()  # para que 'bloqueo_una_vez' dé Error 1015 solo la primera vez
VECES = {}


def fila(n, d, s, a, m, archivo=None):
    enlace = archivo or quote(d + m)
    return (f"<tr><td>{n}</td><td>{d}</td><td>{s}</td><td>{a}</td><td>{m}</td>"
            f"<td><a href='/ver_archivo/{enlace}'>PDF</a></td></tr>")

DATOS = {
    1: ("", "Periodo de Actualización: Cuando existan cambios.", "Agosto 2026",
        [fila("Organigrama", "Organigrama 2026", "2026-01-10", "2026", "Enero", "organigrama.pdf"),
         fila("Organigrama", "Organigrama actualizado agosto", "2026-09-01", "2026", "Agosto",
              "humano_dos_veces")]),
    7: ("", "Periodo de Actualización: Mensual.", "Agosto 2026", [
        fila("Remuneración de Empleados", "Sueldos mes de Agosto 2026", "2026-09-14", "2026", "Agosto",
             "planilla_agosto.pdf"),
        fila("Remuneración de Empleados", "Sueldos Julio 2026", "2026-08-14", "2026", "Julio"),
        fila("Remuneración de Empleados", "Sueldos junio 2026", "2026-07-14", "2026", "Junio"),
        fila("Remuneracion de Empleados", "Sueldos Mayo 2026", "2026-06-12", "2026", "Mayo"),
        fila("Remuneracion de Empleados", "Sueldos Mayo 2026", "2026-06-12", "2026", "Mayo"),
        fila("Nota aclaratoria", "Nota aclaratoria abril", "2026-05-08", "2026", "Abril"),
        fila("Remuneracion de Empleados", "Sueldos Marzo 2026", "2026-04-09", "2026", "Febrero"),
        fila("Remuneracion de Empleados", "Sueldos Enero 2026", "2026-02-12", "2026", "Enero")]),
    12: ("FONAC NO APLICA", "Periodo de Actualización: Anual.", "Agosto 2026",
         [fila("Licitación", "Licitación Enero 2026", "2026-02-12", "2026", "Enero")]),
    20: ("", "Periodo de Actualización: Mensual.", "Mayo 2026", [
        fila("Compras", "Cuadro de compras agosto", "2026-09-05", "2026", "Agosto", "compras_agosto.xlsx"),
        fila("Compras", "Soporte de compras agosto", "2026-09-05", "2026", "Agosto", "compras_agosto.pdf"),
        fila("Compras", "", "2026-02-12", "2026", "Enero"),
        fila("Compras", "Compras de marzo", "2026-04-12", "2026", "Marzo")]),
    31: ("", "Periodo de Actualización: Trimestral.", "Junio 2026", [
        fila("Gaceta", "Primer trimestre", "2026-04-02", "2026", "Marzo")]),
    40: ("", "", "", []),
    50: ("", "Periodo de Actualización: Mensual.", "31/08/2026", [
        fila("Balance", "Notas a los estados financieros junio", "2026-07-02", "2026", "Junio"),
        fila("Balance", "Balance julio", "2026-08-02", "2026", "Julio"),
        fila("Balance", "Balance agosto", "2026-09-02", "2026", "Agosto", "escaneado.pdf"),
        fila("Balance", "Balance agosto anexo", "2026-09-02", "2026", "Agosto", "danado.pdf")]),
    60: ("", "Periodo de Actualización: Mensual.", "Agosto 2026", [
        fila("Gasto", "Gasto agosto", "2026-09-02", "2026", "Agosto", "bloqueo_una_vez"),
        fila("Gasto", "=SUMA raro\x07", "2026-09-02", "2026", "Agosto")]),
}
PIE = {60: "<div>Mostrando 1 a 1 de 4 registros</div>"}

ESTILO = """
body{margin:0;font-family:Arial,sans-serif;color:#333;background:#fff}
header{padding:14px 28px;font-size:20px;color:#2e7d32;box-shadow:0 2px 4px #ddd}
.ruta{padding:12px 90px;font-size:14px;color:#555}.ruta a{color:#2e7d32;text-decoration:none}
nav{float:left;width:260px;margin:10px 20px 0 50px}.logo{color:#1565c0;font-weight:bold;text-align:center;
font-size:15px;padding:30px 0}.grupo{background:#2e7d32;color:#fff;padding:12px;font-size:18px}
nav ul{list-style:none;margin:0;padding:0}nav li{background:#6aa84f;border-bottom:1px solid #fff;text-align:center}
nav li a{color:#fff;text-decoration:none;display:block;padding:9px;font-size:14px}
main{margin-left:340px;padding:0 30px}h3{color:#2e7d32;text-align:center;font-size:22px;margin:16px 0 6px}
h2{color:#2e7d32;font-size:26px;margin:6px 0 14px}.sello{float:right;background:#2e7d32;color:#fff;padding:4px 10px;
border-radius:4px;font-size:13px;font-weight:bold;margin-top:-50px}
.caja{border-top:3px solid #2e7d32;border-bottom:3px solid #2e7d32;text-align:center;padding:14px;font-size:14px;
line-height:1.6;margin-bottom:16px;box-shadow:0 2px 6px #ddd}
table{border-collapse:collapse;width:100%;font-size:13px}th{background:#4a8c3a;color:#fff;padding:9px}
td{padding:8px;border-bottom:1px solid #ddd}tr:nth-child(odd) td{background:#f4f4f4}td a{color:#c62828}
"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/ver_archivo/"):
            return self.archivo(self.path.split("/")[-1])
        partes = [p for p in self.path.split("/") if p]
        inst = partes[0] if partes else "28"
        nombre = NOMBRES.get(inst, "Institucion X")
        menu = "".join(f"<li><a href='/{inst}/{i}/'>{n}</a></li>" for i, n in MENU)
        titulo_ap = dict(MENU).get(int(partes[1]), "") if len(partes) == 2 and partes[1].isdigit() else ""
        cuerpo = (f"<header>Portal Único de Transparencia</header><div class='ruta'><a href='/'>Inicio</a> / "
                  f"<a href='/{inst}/'>{nombre}</a> / {titulo_ap}</div>"
                  f"<nav><div class='logo'>Portal Único<br>de Transparencia</div>"
                  f"<div class='grupo'>Estructura Orgánica</div><ul>{menu}</ul></nav><main>")
        if len(partes) == 2 and int(partes[1]) in DATOS:
            area, perio, fecha, filas = DATOS[int(partes[1])]
            if VERSION >= 2 and int(partes[1]) == 7:  # en la versión 2 aparece un documento nuevo
                filas = [fila("Remuneración de Empleados", "Sueldos Septiembre 2026", "2026-10-01",
                              "2026", "Septiembre", "planilla_sin_firma.pdf")] + filas
            cuerpo += (f"<h3>{nombre}</h3><h2>{titulo_ap.upper()}</h2>"
                       f"<span class='sello'>Fecha de actualizacion: 14/09/26</span><div class='caja'>"
                       f"<div>{area}</div><div>Fecha de Actualización: {fecha}</div><div>{perio}</div>"
                       "<div>Unidad Responsable: Unidad de Administración</div></div>"
                       "<table><thead><tr><th>Nombre</th><th>Descripción</th><th>Subido</th>"
                       f"<th>Año</th><th>Mes</th><th>ver</th></tr></thead><tbody>{''.join(filas)}"
                       "</tbody></table>" + PIE.get(int(partes[1]), "") + "</main>")
        else:
            cuerpo += f"<h3>{nombre}</h3></main>"
        html = f"<html><head><meta charset='utf-8'><title>Portal</title><style>{ESTILO}</style></head><body>{cuerpo}</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode())
    def archivo(self, nombre):
        if nombre == "bloqueo_una_vez" and nombre not in VISTOS:
            VISTOS.add(nombre)
            return self.responder(b"<html><body>Error 1015 You are being rate limited</body></html>",
                                  "text/html")
        if nombre == "bloqueo_una_vez":
            nombre = "gasto_agosto.pdf"
        if nombre == "humano_dos_veces":  # la casilla 'Soy humano' sale las 2 primeras veces
            VECES[nombre] = VECES.get(nombre, 0) + 1
            if VECES[nombre] <= 2:
                return self.responder(b"<html><head><title>Just a moment...</title></head>"
                                      b"<body>Verify you are human</body></html>", "text/html")
            nombre = "organigrama.pdf"
        ruta = ARCHIVOS / nombre
        if ruta.exists():
            tipo = "application/pdf" if nombre.endswith(".pdf") else "application/octet-stream"
            return self.responder(ruta.read_bytes(), tipo)
        self.responder("<html><body>Documento no disponible</body></html>".encode(), "text/html")

    def responder(self, datos, tipo):
        self.send_response(200)
        self.send_header("Content-Type", tipo)
        self.end_headers()
        self.wfile.write(datos)

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
