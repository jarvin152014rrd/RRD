"""Copia FALSA del sistema de evaluación (gvt) para probar la Fase 2 sin tocar el real.

Hecha a partir del video del verificador: inicio de sesión, formulario de verificar.php,
caja para pegar la captura, ventana 'Resultado' y el reporte de apartados verificados.
Uso: python servidor_gvt.py 8770
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

NOMBRES = {"28": "Foro Nacional De Convergencia (FONAC)", "30": "Municipalidad de Prueba"}
APARTADOS = ["Organigrama", "Remuneración de Empleados", "Licitación", "Compras",
             "Diario Oficial La Gaceta", "Balance General", "Gasto", "Plan Operativo"]
MESES = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto", "Septiembre",
         "Octubre", "Noviembre", "Diciembre"]
# Ya verificado antes, para probar que el programa lo salta.
VERIFICADOS = {("28", "2026", "9"): {"Organigrama"}}
ENVIOS = []

FORMULARIO = """<html><head><meta charset="utf-8"><title>Administracion del Portal Unico</title><style>
body{font-family:Arial;margin:0}.barra{background:#3b8bc2;color:#fff;padding:10px 20px;font-size:20px}
.cont{display:flex;padding:20px}.izq{width:620px}.der{flex:1;margin-left:20px}
.f{margin:10px 0}.f label.t{display:inline-block;width:140px;text-align:right;margin-right:10px}
select,textarea{width:420px}#pegar{width:95%;height:50px}#calidad{display:none;margin-left:150px}
.miniatura{border:1px solid #ccc;margin:8px 0;padding:6px}.miniatura img{width:240px}
#modal{display:none;position:fixed;top:120px;left:300px;background:#fff;border:1px solid #888;padding:20px;width:420px}
</style></head><body>
<div class="barra">Portal Único de Transparencia - Bienvenido Jarvin Mendoza - 21</div>
<h2 style="color:#3b8bc2;margin-left:20px">Verificar (__NOMBRE__) <small>» Agregar Verificaciones</small></h2>
<div class="cont"><div class="izq">
 <div class="f"><label class="t">Apartado</label><select id="apartado"><option value=""></option>__OPCIONES__</select>
   <a href="#" id="ant">&larr;</a> <a href="#" id="sig">&rarr;</a></div>
 <div class="f"><label class="t">Año</label><select id="anio"><option>2025</option><option selected>2026</option></select></div>
 <div class="f"><label class="t">Mes</label><select id="mes"><option value=""></option>__MESES__</select></div>
 <div class="f" style="margin-left:150px">
   <label><input type="radio" name="resultado" value="1"> Cumple</label>
   <label><input type="radio" name="resultado" value="2"> No cumple</label>
   <label><input type="radio" name="resultado" value="3"> No aplica</label></div>
 <div id="calidad"><button type="button" id="todos">todos</button><br>Caracteristicas de calidad<br>
   <label><input type="checkbox" value="completa"> Completa</label>
   <label><input type="checkbox" value="veraz"> Veraz</label>
   <label><input type="checkbox" value="adecuada"> Adecuada</label>
   <label><input type="checkbox" value="oportuna"> Oportuna</label></div>
 <div class="f"><label class="t">Recomendaciones</label><textarea id="recomendaciones" placeholder="Recomendaciones"></textarea></div>
 <button id="enviar" type="button">Enviar</button>
</div><div class="der">
 <textarea id="pegar" placeholder="1. Presional en el teclado 'Impr Pant'  2.Posicionarse en la paca de texto y Clic Derecho Pegar(Control + v)"></textarea>
 <div id="imagenes"></div>
</div></div>
<div id="modal"><b>Resultado</b><div id="texto"></div><button id="ok">OK</button></div>
<script>
const radios = document.querySelectorAll('input[name=resultado]');
radios.forEach(r => r.addEventListener('change', () => {
  document.getElementById('calidad').style.display = r.value === '1' && r.checked ? 'block' : 'none'; }));
document.getElementById('todos').onclick = () =>
  document.querySelectorAll('#calidad input').forEach(c => c.checked = true);
document.getElementById('pegar').addEventListener('paste', e => {
  for (const it of e.clipboardData.items) {
    if (!it.type.startsWith('image/')) continue;
    const lector = new FileReader();
    lector.onload = () => {
      const d = document.createElement('div'); d.className = 'miniatura';
      d.innerHTML = '<img src="' + lector.result + '"><textarea placeholder="descripcion"></textarea><a href="#">x</a>';
      document.getElementById('imagenes').appendChild(d); };
    lector.readAsDataURL(it.getAsFile()); e.preventDefault(); } });
document.getElementById('enviar').onclick = async () => {
  const sel = document.getElementById('apartado');
  const datos = {id: '__ID__', apartado: sel.options[sel.selectedIndex].text,
    anio: document.getElementById('anio').value, mes: document.getElementById('mes').value,
    resultado: (document.querySelector('input[name=resultado]:checked') || {}).value || '',
    calidad: [...document.querySelectorAll('#calidad input:checked')].map(c => c.value),
    recomendaciones: document.getElementById('recomendaciones').value,
    imagenes: document.querySelectorAll('#imagenes img').length};
  const r = await fetch('/guardar', {method: 'POST', body: JSON.stringify(datos)});
  document.getElementById('texto').innerHTML = await r.text();
  document.getElementById('modal').style.display = 'block'; };
document.getElementById('ok').onclick = () => location.reload();
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def sesion(self):
        return "sesion=ok" in (self.headers.get("Cookie") or "")

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/login.php":
            return self.html("<html><body><h3>Iniciar sesión</h3><form method='post' action='/login.php'>"
                             "<input name='usuario'><input type='password' name='clave'>"
                             "<button>Entrar</button></form></body></html>")
        if not self.sesion():
            return self.redirigir("/login.php")
        if url.path == "/verificar.php":
            nombre = NOMBRES.get(q.get("id", ""), "Institucion X")
            pagina = (FORMULARIO.replace("__NOMBRE__", nombre).replace("__ID__", q.get("id", ""))
                      .replace("__OPCIONES__", "".join(f"<option value='{i + 1}'>{a}</option>"
                                                         for i, a in enumerate(APARTADOS)))
                      .replace("__MESES__", "".join(f"<option value='{i + 1}'>{m}</option>"
                                                    for i, m in enumerate(MESES))))
            return self.html(pagina)
        if url.path == "/reporteCompleto_porcentajePorApartado.php":
            hechos = VERIFICADOS.get((q.get("idPortal"), q.get("ano"), q.get("mes")), set())
            filas = "".join(f"<tr><td>{a}</td>" + ("<td>✔</td><td>100%</td>" if a in hechos else
                            "<td colspan='2'>No ha verificacion</td>") + "</tr>" for a in APARTADOS)
            nombre = NOMBRES.get(q.get("idPortal", ""), "Institucion X")
            mes_txt = MESES[int(q.get("mes", "1")) - 1]
            return self.html(f"<html><body><h3>VERIFICACIÓN DEL PORTAL DE TRANSPARENCIA</h3>"
                             f"<p>Institución: {nombre}  Año: {q.get('ano')}  Mes: {mes_txt}</p>"
                             f"<table>{filas}</table></body></html>")
        if url.path == "/envios":
            return self.html(json.dumps(ENVIOS, ensure_ascii=False))
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        largo = int(self.headers.get("Content-Length", 0))
        cuerpo = self.rfile.read(largo).decode()
        if self.path == "/login.php":
            self.send_response(302)
            self.send_header("Set-Cookie", "sesion=ok; Path=/")
            self.send_header("Location", "/verificar.php?id=28")
            return self.end_headers()
        if self.path == "/guardar" and self.sesion():
            d = json.loads(cuerpo)
            ENVIOS.append(d)
            VERIFICADOS.setdefault((d["id"], d["anio"], d["mes"]), set()).add(d["apartado"])
            nombre = NOMBRES.get(d["id"], "Institucion X")
            return self.html("Se han guardado la verificación exitosamente<br>Nombre del Verificador: "
                             f"Jarvin Mendoza<br>Nombre del Portal: {nombre}<br>Nombre del Seccion: "
                             f"{d['apartado']}<br>Ano: {d['anio']} - Mes: {d['mes']}")
        self.send_response(403)
        self.end_headers()

    def html(self, texto):
        datos = texto.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(datos)))
        self.end_headers()
        self.wfile.write(datos)

    def redirigir(self, destino):
        self.send_response(302)
        self.send_header("Location", destino)
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
