"""Portal falso para probar fase1.py sin tocar el portal real.

Copia la forma de portalunico.iaip.gob.hn vista en las capturas (FONAC, id 28).
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote
import sys

VERSION = int(sys.argv[2]) if len(sys.argv) > 2 else 1
NOMBRES = {"28": "Foro Nacional De Convergencia (FONAC)", "30": "Municipalidad de Prueba"}

MENU = [(1, "Organigrama"), (7, "Remuneracion de Empleados"), (12, "Licitacion"),
        (20, "Compras"), (31, "Diario Oficial La Gaceta"), (40, "Apartado Raro"),
        (50, "Balance General"), (60, "Gasto")]

def fila(n, d, s, a, m):
    return (f"<tr><td>{n}</td><td>{d}</td><td>{s}</td><td>{a}</td><td>{m}</td>"
            f"<td><a href='/ver_archivo/{quote(d + m)}'>PDF</a></td></tr>")

DATOS = {
    1: ("", "Periodo de Actualización: Cuando existan cambios.", "Agosto 2026",
        [fila("Organigrama", "Organigrama 2026", "2026-01-10", "2026", "Enero")]),
    7: ("", "Periodo de Actualización: Mensual.", "Agosto 2026", [
        fila("Remuneración de Empleados", "Sueldos mes de Agosto 2026", "2026-09-14", "2026", "Agosto"),
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
        fila("Compras", "", "2026-02-12", "2026", "Enero"),
        fila("Compras", "Compras de marzo", "2026-04-12", "2026", "Marzo")]),
    31: ("", "Periodo de Actualización: Trimestral.", "Junio 2026", [
        fila("Gaceta", "Primer trimestre", "2026-04-02", "2026", "Marzo")]),
    40: ("", "", "", []),
    50: ("", "Periodo de Actualización: Mensual.", "31/08/2026", [
        fila("Balance", "Notas a los estados financieros junio", "2026-07-02", "2026", "Junio"),
        fila("Balance", "Balance julio", "2026-08-02", "2026", "Julio"),
        fila("Balance", "Balance agosto", "2026-09-02", "2026", "Agosto")]),
    60: ("", "Periodo de Actualización: Mensual.", "Agosto 2026", [
        fila("Gasto", "Gasto agosto", "2026-09-02", "2026", "Agosto"),
        fila("Gasto", "=SUMA raro\x07", "2026-09-02", "2026", "Agosto")]),
}
PIE = {60: "<div>Mostrando 1 a 1 de 4 registros</div>"}

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        partes = [p for p in self.path.split("/") if p]
        inst = partes[0] if partes else "28"
        nombre = NOMBRES.get(inst, "Institucion X")
        menu = "".join(f"<li><a href='/{inst}/{i}/'>{n}</a></li>" for i, n in MENU)
        cuerpo = f"<nav><a href='/'>Inicio</a> / <a href='/{inst}/'>{nombre}</a><ul>{menu}</ul></nav>"
        if len(partes) == 2 and int(partes[1]) in DATOS:
            area, perio, fecha, filas = DATOS[int(partes[1])]
            if VERSION >= 2 and int(partes[1]) == 7:  # en la versión 2 aparece un documento nuevo
                filas = [fila("Remuneración de Empleados", "Sueldos Septiembre 2026", "2026-10-01",
                              "2026", "Septiembre")] + filas
            cuerpo += (f"<h3>{nombre}</h3><h2>TITULO</h2>"
                       f"<span>Fecha de actualizacion: 14/09/26</span><div>{area}</div>"
                       f"<div>Fecha de Actualización: {fecha}</div><div>{perio}</div>"
                       "<table><thead><tr><th>Nombre</th><th>Descripción</th><th>Subido</th>"
                       f"<th>Año</th><th>Mes</th><th>ver</th></tr></thead><tbody>{''.join(filas)}"
                       "</tbody></table>" + PIE.get(int(partes[1]), ""))
        else:
            cuerpo += f"<h3>{nombre}</h3>"
        html = f"<html><head><title>Portal</title></head><body>{cuerpo}</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode())
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
