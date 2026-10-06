# Verificador IAIP

Revisa el **portal público**, descarga y revisa los **documentos nuevos** y te deja un **Excel con la propuesta** de verificación.
**No inicia sesión y no envía nada al formulario.** Tú revisas y decides.

## Instalar (una sola vez)
1. Instala Python desde https://www.python.org/downloads/ — marca **"Add python.exe to PATH"**.
2. Doble clic en **`instalar.bat`**.

## Usar
1. Doble clic en **`ejecutar.bat`**.
2. Elige **1** (una institución) o **2** (todas las de `instituciones.txt`, una tras otra).
3. Responde año, mes y cuántos apartados revisar (**para probar pon `3`**). El programa recuerda tus últimas respuestas: Enter = la misma.
4. Si es una institución: escribe su número (el de la dirección, ej. `28` en `portalunico.iaip.gob.hn/28/7/`).
   "¿Desde qué mes?" ya viene lleno con el mes siguiente a tu verificación anterior.
5. Se abre Chrome solo y va despacio (10 a 20 s entre páginas; 1 a 2 minutos entre instituciones).
6. Al terminar se abre el Excel de la carpeta **`resultados`**.

## El Excel
- **Propuesta:** un renglón por apartado.
  - PROPUESTA (Cumple / No cumple / No aplica / **Sin calificar**), casillas a quitar y observación ya escrita.
  - **Dudas:** por qué no se calificó. **Avisos:** información que no cambia la propuesta.
  - **Captura:** vínculo a la imagen del apartado (institución, apartado, fecha editable y tabla).
  - **Docs nuevos:** cuántos documentos aparecieron desde tu verificación anterior.
  - Columnas azules **DECISIÓN FINAL / QUITAR FINAL / OBSERVACIÓN FINAL**: corrígelas tú. La Fase 2 llenará el formulario con eso.
    Si la propuesta es "Sin calificar", la decisión final queda vacía para que la pongas tú.
- **Pendientes:** tu lista de trabajo. Solo los apartados **Sin calificar** (no se pudo abrir algo o no había
  certeza), con el motivo y vínculos a la captura y al portal.
- **Alertas:** todas las dudas y avisos, uno por renglón.
- **Documentos:** todos los documentos; "Nuevo = Sí" si no estaban la vez anterior.
- **Sin regla:** apartados del menú que no están en tu checklist.
- El Excel **nunca se reemplaza**: si ya existe, se crea otro con la fecha y hora.

## Documentos (PDF y Excel)
Si respondes **S** a "¿Descargar y revisar los documentos…?":
- Baja **los nuevos** desde tu verificación anterior y **los del periodo** (en anuales o "cuando existan cambios", el más reciente).
- Revisa que sea de verdad un PDF o un Excel. Los Excel se leen **sin abrir Microsoft Excel** (no sale "Habilitar edición").
- **Sin IA (gratis):** páginas, si es escaneado, meses que menciona, palabras clave del checklist
  (BRUTO/NETO, ALCALDE, DEVENGADO/APROBADO, aguinaldo en junio y diciembre…; si falta una, queda **Sin calificar**)
  y, en **Compras y Contrataciones**, que estén el **cuadro Excel y el PDF en el mismo orden** (si no, se quita Adecuada).
- **Con IA (cuando el IAIP lo autorice):** firma, sello, nombre y puesto, legibilidad, orientación y contenido según checklist.
  La IA dice **en qué página** lo vio. Si no está segura, pide revisión manual.
- Si un documento **no se puede leer** (dañado, no es PDF/Excel, ilegible), el apartado queda **"Sin calificar"** con la alerta del motivo.
- Hoja **Análisis documentos** del Excel: un renglón por documento.
- **Error 1015:** espera 10 y 30 minutos; si sigue, se detiene y guarda. **"Soy humano":** el programa **suena y espera a que la marques tú** (no la marca solo).

## Activar la IA (solo con autorización del IAIP)
1. Cuenta de Anthropic **a nombre del IAIP**, con **límite de gasto** en la consola.
2. Crear una clave y guardarla en Windows (ventana negra): `setx ANTHROPIC_API_KEY "la-clave"` y cerrar/abrir la ventana.
   **Nunca** escribas la clave en los archivos del programa.
3. En `config_ia.json` cambiar `"ia_activada": false` por `true`. Ahí también está el **tope de gasto por corrida** (US$5).
4. Antes de enviar, el programa muestra el **costo aproximado** y pregunta. Cada documento se revisa una sola vez (se guarda su resultado).

## Varias instituciones
Escribe en **`instituciones.txt`** una por línea:  `número ; M o I ; desde` (lo último es opcional).
Al final sale un **resumen_….xlsx** con el conteo de cada institución.

## Si el portal bloquea (Error 1015)
El programa **se detiene solo** y guarda lo leído. Espera una hora y vuelve a correrlo: sigue donde se quedó.

## Volver a revisar lo mismo
Si la institución y el mes ya se leyeron, pregunta si **leer de nuevo** (por si corrigieron) o **usar lo guardado** (no toca el portal, solo recalcula).

## Archivos
- `reglas.json` — tus checklists convertidos en reglas. Si cambias los Excel: `py crear_reglas.py Municipalidades.xlsx Instituciones.xlsx`.
- `comun.py` — las frases y la lógica de decisión.
- `fase1.py` — el programa principal.
- `documentos.py` — descarga segura. `analisis.py` — lectura sin IA. `ia.py` — revisión con IA.
- `config_ia.json` — IA apagada/encendida, modelo, tope de gasto.
- `resultados/` — Excel, lo leído (`lectura_…json`) y el historial para comparar (`historial_…json`).
- `pruebas/servidor_prueba.py` — portal falso para probar sin tocar el real
  (`pruebas/crear_archivos_prueba.py` crea sus documentos).
