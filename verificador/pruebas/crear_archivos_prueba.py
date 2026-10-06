"""Crea documentos de prueba (PDF y Excel) para el portal falso. No toca el portal real."""
from pathlib import Path

import openpyxl
from PIL import Image, ImageDraw

CARPETA = Path(__file__).parent / "archivos"


def pdf_con_texto(lineas):
    """PDF de una página con texto (sin librerías externas)."""
    contenido = "BT /F1 11 Tf 50 780 Td 14 TL\n" + "".join(
        "(" + l.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") + ") Tj T*\n"
        for l in lineas) + "ET"
    objetos = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        f"<< /Length {len(contenido.encode('latin-1'))} >>\nstream\n{contenido}\nendstream",
    ]
    salida = b"%PDF-1.4\n"
    posiciones = []
    for i, o in enumerate(objetos, 1):
        posiciones.append(len(salida))
        salida += f"{i} 0 obj\n{o}\nendobj\n".encode("latin-1")
    xref = len(salida)
    salida += f"xref\n0 {len(objetos) + 1}\n0000000000 65535 f \n".encode()
    salida += "".join(f"{p:010d} 00000 n \n" for p in posiciones).encode()
    salida += f"trailer\n<< /Size {len(objetos) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return salida


def main():
    CARPETA.mkdir(exist_ok=True)
    (CARPETA / "planilla_agosto.pdf").write_bytes(pdf_con_texto([
        "FORO NACIONAL DE CONVERGENCIA", "PLANILLA DE SUELDOS MES DE AGOSTO 2026",
        "No.  Puesto  Sueldo Bruto  Sueldo Neto", "1 Secretario Ejecutivo 120,000.00 80,839.39",
        "2 Auditor Interno 50,760.00 10,937.21", "Firma: Maria Arita, Administradora  Sello: FONAC"]))
    (CARPETA / "planilla_sin_firma.pdf").write_bytes(pdf_con_texto([
        "FORO NACIONAL DE CONVERGENCIA", "PLANILLA DE SUELDOS MES DE SEPTIEMBRE 2026",
        "No.  Puesto  Sueldo Bruto  Sueldo Neto", "1 Secretario Ejecutivo 120,000.00 80,839.39"]))
    (CARPETA / "organigrama.pdf").write_bytes(pdf_con_texto([
        "ORGANIGRAMA INSTITUCIONAL 2026", "Secretaria Ejecutiva - Administracion - Comunicaciones",
        "Firma y sello de la Secretaria Ejecutiva"]))
    (CARPETA / "gasto_agosto.pdf").write_bytes(pdf_con_texto([
        "REPORTE DE GASTO AGOSTO 2026", "Combustibles 12,000.00", "Firma Sello Administracion"]))
    # Escaneado: una imagen sin texto.
    img = Image.new("RGB", (850, 1100), "white")
    ImageDraw.Draw(img).text((60, 60), "BALANCE GENERAL AGOSTO 2026 (escaneado)", fill="black")
    img.save(CARPETA / "escaneado.pdf", "PDF")
    (CARPETA / "danado.pdf").write_bytes(b"%PDF-1.4\nesto no es un PDF valido\n")
    # Compras: Excel y PDF con las mismas filas en distinto orden.
    filas = [("OC-1001", "Distribuidora La Ceiba", "Papeleria"), ("OC-1002", "Ferreteria El Pino", "Cemento"),
             ("OC-1003", "Farmacia Kielsa", "Medicamentos"), ("OC-1004", "Comercial Lopez", "Repuestos")]
    libro = openpyxl.Workbook()
    hoja = libro.active
    hoja.append(["Orden", "Proveedor", "Descripcion"])
    for f in filas:
        hoja.append(list(f))
    libro.save(CARPETA / "compras_agosto.xlsx")
    desordenadas = [filas[2], filas[0], filas[3], filas[1]]
    (CARPETA / "compras_agosto.pdf").write_bytes(pdf_con_texto(
        ["COMPRAS AGOSTO 2026"] + [f"{a} {b} {c}" for a, b, c in desordenadas] + ["Firma Sello"]))
    print(f"Archivos de prueba creados en {CARPETA}")


if __name__ == "__main__":
    main()
