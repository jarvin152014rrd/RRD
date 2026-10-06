"""Convierte los checklists de Excel en reglas.json.

Uso:  py crear_reglas.py Checklist_Municipalidades.xlsx Checklist_Instituciones.xlsx
(el primer archivo es el de Municipalidades y el segundo el de Instituciones)
"""
import json
import sys
from pathlib import Path

import openpyxl

from comun import clasificar_periodicidad, normalizar

# Nombres del Excel que en el portal aparecen como varios apartados.
ALIAS = {
    "servicios prestados, procedimientos y requisitos": [
        "servicios prestados", "procedimiento", "procedimientos", "requisitos"],
    "balance general / estado de resultados": [
        "balance general", "estado de resultados"],
    "plan operativo anual": ["plan operativo"],
    "plan estrategico:": ["plan estrategico"],
    "registro publico": ["registro publico", "registros publicos"],
    "oficial de informacion publica (oip)": [
        "oficial de informacion publica (oip)", "oficial de informacion publica"],
    "licitacion": ["licitacion", "licitaciones"],
    "subastas de obras": ["subastas de obras", "subastas"],
    "fideicomisos": ["fideicomisos", "fideicomiso"],
}

# Reglas que el checklist dice con palabras y el programa debe saber.
ESPECIALES = {
    ("municipalidad", "fideicomisos"): {"siempre_no_aplica": True},
    ("municipalidad", "participacion ciudadana"): {"nunca_no_aplica": True},
    ("municipalidad", "remuneracion de empleados"): {"nota_no_valida": True},
    ("institucion", "remuneracion de empleados"): {"nota_no_valida": True},
}


def leer(archivo, sector):
    reglas = []
    wb = openpyxl.load_workbook(archivo, data_only=True)
    for hoja in wb:
        actual = None
        for fila in hoja.iter_rows(min_row=2, values_only=True):
            celdas = [("" if c is None else str(c).strip()) for c in fila[1:5]]
            celdas += [""] * (4 - len(celdas))
            nombre, publicar, obs, perio = celdas
            if nombre.lower().startswith("hacer incapie") or nombre.startswith("*"):
                continue  # notas generales al pie de la hoja
            if nombre and nombre != "Apartado":
                clave = normalizar(nombre)
                actual = {
                    "sector": sector,
                    "componente": hoja.title.strip(),
                    "apartado": nombre.rstrip(":"),
                    "alias": ALIAS.get(clave, [clave.rstrip(":")]),
                    "periodicidad": clasificar_periodicidad(perio),
                    "periodicidad_texto": perio,
                    "publicar": [publicar] if publicar else [],
                    "observaciones": [obs] if obs else [],
                }
                actual.update(ESPECIALES.get((sector, clave), {}))
                reglas.append(actual)
            elif actual is not None:
                if publicar:
                    actual["publicar"].append(publicar)
                if obs:
                    actual["observaciones"].append(obs)
                if perio:
                    actual["periodicidad_texto"] += " " + perio
    return reglas


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    reglas = leer(sys.argv[1], "municipalidad") + leer(sys.argv[2], "institucion")
    salida = Path(__file__).with_name("reglas.json")
    salida.write_text(json.dumps(reglas, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"Listo: {len(reglas)} apartados guardados en {salida.name}")


if __name__ == "__main__":
    main()
