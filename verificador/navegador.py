"""Abre un Chrome NORMAL (sin la marca de "navegador automatizado") y el programa se conecta a él.

Así el portal no rechaza la ventana sin fin. La casilla "Soy humano" la sigue marcando el
verificador: el programa nunca la toca.

Seguridad:
- Cada uso tiene su propio perfil de Chrome (portal o sistema de evaluación), sin cuentas personales.
- El puerto de conexión solo se abre en esta computadora (127.0.0.1), cambia en cada uso
  y Chrome se cierra al terminar.
"""
import json
import os
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

PRUEBA = "PORTAL_PRUEBA" in os.environ  # solo para pruebas locales


def ruta_chrome():
    """Busca chrome.exe: variable CHROME_RUTA, registro de Windows y carpetas de siempre."""
    if os.environ.get("CHROME_RUTA"):
        return os.environ["CHROME_RUTA"]
    try:
        import winreg  # solo existe en Windows
        for raiz in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
            try:
                with winreg.OpenKey(raiz, r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe") as k:
                    ruta = winreg.QueryValue(k, None)
                    if ruta and Path(ruta).exists():
                        return ruta
            except OSError:
                pass
    except ImportError:
        pass
    for base in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
        if os.environ.get(base):
            ruta = Path(os.environ[base]) / "Google" / "Chrome" / "Application" / "chrome.exe"
            if ruta.exists():
                return str(ruta)
    raise RuntimeError("No encontré Google Chrome. Instálalo o indica su ruta en la variable CHROME_RUTA.")


def _puerto_libre():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _esperar_puerto(puerto, segundos=30):
    sin_proxy = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    limite = time.time() + segundos
    while time.time() < limite:
        try:
            with sin_proxy.open(f"http://127.0.0.1:{puerto}/json/version", timeout=2) as r:
                return json.load(r)
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("Chrome no respondió al abrirse.")


class Chrome:
    """Chrome normal + conexión del programa. Usar con 'with Chrome(p, perfil) as c:'."""

    def __init__(self, playwright, perfil):
        self.playwright, self.perfil = playwright, Path(perfil)

    def __enter__(self):
        self.perfil.mkdir(parents=True, exist_ok=True)
        puerto = _puerto_libre()
        args = [ruta_chrome(), f"--remote-debugging-port={puerto}", f"--user-data-dir={self.perfil}",
                "--no-first-run", "--no-default-browser-check", "--window-size=1366,1000"]
        if PRUEBA:  # solo pruebas en el servidor (Linux como administrador, sin pantalla)
            args += ["--headless=new", "--no-sandbox"]
        args.append("about:blank")
        self.proceso = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            _esperar_puerto(puerto)
            self.navegador = self.playwright.chromium.connect_over_cdp(f"http://127.0.0.1:{puerto}")
        except Exception:
            self.proceso.terminate()
            raise
        # La ventana que ya existe (con sus cookies); una nueva no tendría el permiso del portal.
        self.contexto = self.navegador.contexts[0]
        self.pagina = self.contexto.pages[0] if self.contexto.pages else self.contexto.new_page()
        return self

    def nueva_pagina(self):
        return self.contexto.new_page()

    def __exit__(self, *_):
        try:
            self.navegador.close()  # solo desconecta
        except Exception:
            pass
        try:
            self.proceso.terminate()  # cierra Chrome
            self.proceso.wait(timeout=10)
        except Exception:
            pass
        return False
