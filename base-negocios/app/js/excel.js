// Excel de ida y vuelta (núcleo: exportar_plantilla / importar_vista_previa / importar_aplicar).
// El servidor solo da y recibe JSON: aquí se arma y se lee el .xlsx con SheetJS
// (xlsx-js-style 1.2.0, copia local en vendor/: funciona sin internet y pinta las columnas).
// Azul = se puede cambiar y se sube; gris = solo información (el servidor la ignora).

let carga = null;
export function cargarXLSX() {
  if (window.XLSX) return Promise.resolve(window.XLSX);
  if (!carga) {
    carga = new Promise((ok, mal) => {
      const s = document.createElement('script');
      s.src = new URL('../vendor/xlsx.bundle.js', import.meta.url).href;
      s.onload = () => ok(window.XLSX);
      s.onerror = () => { carga = null; mal(new Error('No se pudo cargar el lector de Excel.')); };
      document.head.append(s);
    });
  }
  return carga;
}

const AZUL = { fill: { patternType: 'solid', fgColor: { rgb: '1A2F52' } }, font: { bold: true, color: { rgb: 'FFFFFF' } } };
const GRIS = { fill: { patternType: 'solid', fgColor: { rgb: 'D9D9D9' } }, font: { bold: true, color: { rgb: '4A4A4A' } } };
const CELDA_GRIS = { fill: { patternType: 'solid', fgColor: { rgb: 'F2F2F2' } }, font: { color: { rgb: '4A4A4A' } } };
const NOMBRES = { productos: 'Productos', clientes_proveedores: 'Clientes y proveedores', categorias: 'Categorías',
  existencias_iniciales: 'Existencias iniciales', saldos_iniciales: 'Saldos iniciales', conteo_fisico: 'Conteo físico' };
export const nombreHoja = (h) => NOMBRES[h] || h;

// Una hoja a partir de lo que devuelve exportar_plantilla.
function hojaDe(XLSX, p) {
  const cols = p.columnas;
  const filas = [cols.map((c) => c.titulo), ...p.filas.map((f) => cols.map((c) => (f[c.clave] === null || f[c.clave] === undefined ? '' : f[c.clave])))];
  const ws = XLSX.utils.aoa_to_sheet(filas);
  cols.forEach((c, i) => {
    const dir = XLSX.utils.encode_cell({ r: 0, c: i });
    ws[dir].s = c.editable ? AZUL : GRIS;
    if (!c.editable) {
      for (let r = 1; r < filas.length; r++) {
        const d = XLSX.utils.encode_cell({ r, c: i });
        if (ws[d]) ws[d].s = CELDA_GRIS;
      }
    }
  });
  ws['!cols'] = cols.map((c) => ({ wch: Math.max(12, Math.min(40, c.titulo.length + 4)) }));
  ws['!freeze'] = { xSplit: 0, ySplit: 1 };
  return ws;
}

function instrucciones(XLSX, plantillas) {
  const filas = [['Cómo usar este archivo'], ['Columnas AZULES: se pueden cambiar. Columnas GRISES: solo información (no se suben).'], []];
  for (const p of plantillas) {
    filas.push([`Hoja "${nombreHoja(p.hoja)}"`]);
    for (const r of p.reglas || []) filas.push(['', r]);
    filas.push(['Columna', '¿Se puede cambiar?', 'Qué es', 'Valores válidos']);
    for (const c of p.columnas) {
      filas.push([c.titulo, c.editable ? (c.obligatorio ? 'Sí (obligatoria)' : 'Sí') : 'No (gris)', c.descripcion || '', (c.valores || []).join(', ')]);
    }
    filas.push([]);
  }
  const ws = XLSX.utils.aoa_to_sheet(filas);
  ws['!cols'] = [{ wch: 28 }, { wch: 20 }, { wch: 60 }, { wch: 40 }];
  return ws;
}

// Descarga un .xlsx con una hoja por plantilla + la hoja "Instrucciones".
export async function descargarExcel(nombreArchivo, plantillas) {
  const XLSX = await cargarXLSX();
  const wb = XLSX.utils.book_new();
  for (const p of plantillas) XLSX.utils.book_append_sheet(wb, hojaDe(XLSX, p), nombreHoja(p.hoja).slice(0, 31));
  XLSX.utils.book_append_sheet(wb, instrucciones(XLSX, plantillas), 'Instrucciones');
  XLSX.writeFile(wb, nombreArchivo);
}

const sinTildes = (t) => String(t).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();

// Lee la hoja de un archivo y la convierte en filas para el servidor:
// [{ fila: N (número real del Excel), <clave>: valor }]. Los títulos se cambian por la clave;
// un título que no se reconoce va tal cual (el servidor lo marca como error).
export async function leerHoja(archivo, plantilla) {
  const XLSX = await cargarXLSX();
  const wb = XLSX.read(await archivo.arrayBuffer(), { type: 'array', cellDates: true });
  const buscada = sinTildes(nombreHoja(plantilla.hoja));
  const nombre = wb.SheetNames.find((n) => sinTildes(n) === buscada) || wb.SheetNames.find((n) => sinTildes(n) !== 'instrucciones');
  if (!nombre) throw new Error('El archivo no tiene hojas con datos.');
  const aoa = XLSX.utils.sheet_to_json(wb.Sheets[nombre], { header: 1, raw: true, defval: null, blankrows: true });
  if (!aoa.length) throw new Error('La hoja está vacía.');
  const porTitulo = new Map(plantilla.columnas.flatMap((c) => [[sinTildes(c.titulo), c], [sinTildes(c.clave), c]]));
  const enc = aoa[0].map((t) => (t === null ? null : porTitulo.get(sinTildes(t)) || { clave: String(t).trim(), editable: true }));
  const filas = [];
  for (let i = 1; i < aoa.length; i++) {
    const fila = aoa[i] || [];
    const obj = { fila: i + 1 };
    let algo = false;
    enc.forEach((c, j) => {
      if (!c || !c.editable) return; // gris: el servidor la ignora; no se manda
      let v = fila[j];
      if (v === null || v === undefined || v === '') return;
      if (v instanceof Date) v = `${v.getFullYear()}-${String(v.getMonth() + 1).padStart(2, '0')}-${String(v.getDate()).padStart(2, '0')}`;
      else if (typeof v === 'boolean') v = v ? 'Sí' : 'No';
      else if (typeof v === 'number') v = String(Math.round(v * 10000) / 10000);
      obj[c.clave] = v;
      algo = true;
    });
    if (algo) filas.push(obj);
  }
  return { hojaArchivo: nombre, filas };
}
