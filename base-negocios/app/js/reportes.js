// Piezas que comparten las pantallas de Reportes (app 0.8.0): elegir el período (un mes o un rango de
// fechas), los botones "Descargar Excel" e "Imprimir" y la hoja impresa.
// Cada reporte arma un "documento" sencillo que sirve para las dos cosas:
//   { titulo, periodo, notas: ['...'], secciones: [{ titulo, columnas: [{ titulo, tipo }], filas: [[...]], total: [...] }] }
//   tipo: 'dinero' (centavos), 'numero', 'texto' (lo demás). Las celdas van crudas (centavos, números, texto).
// Lo IMPRESO lleva solo logo, texto y líneas: sin íconos, sin emojis y sin colores (imprimible.js).
import { h, icono, cajaError } from './ui.js';
import { perfilActual } from './sesion.js';
import { dinero, fecha, cantidad, sumarDias, diasEntre } from './formato.js';
import { limpiarImprimible, sinEmojis } from './imprimible.js';
import { marcaActual, nombreVisible } from './marca.js';
import { cargarXLSX } from './excel.js';
import { hoy, inputFecha } from './formularios.js';

export const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
export const nombreMes = (anio, mes) => `${MESES[mes - 1]} de ${anio}`;
const dos = (n) => String(n).padStart(2, '0');

// Primer y último día de un mes ("AAAA-MM-DD").
export function rangoMes(anio, mes) {
  const desde = `${anio}-${dos(mes)}-01`;
  const sig = mes === 12 ? `${anio + 1}-01-01` : `${anio}-${dos(mes + 1)}-01`;
  return { desde, hasta: sumarDias(sig, -1) };
}
export function mesAnterior(anio, mes) { return mes === 1 ? { anio: anio - 1, mes: 12 } : { anio, mes: mes - 1 }; }

// Meses desde que empezó la empresa hasta el de hoy (el más nuevo primero).
export function mesesDeLaEmpresa() {
  const e = perfilActual().empresa;
  const [ai, mi] = String(e.fecha_inicio || hoy()).split('-').map(Number);
  let [a, m] = hoy().split('-').map(Number);
  const lista = [];
  while (a > ai || (a === ai && m >= mi)) {
    lista.push({ anio: a, mes: m, valor: `${a}-${dos(m)}`, texto: nombreMes(a, m) });
    ({ anio: a, mes: m } = mesAnterior(a, m));
    if (lista.length > 240) break;
  }
  return lista;
}

// Período elegido: { modo: 'mes', anio, mes } o { modo: 'rango', desde, hasta }. Las pantallas lo recuerdan
// mientras la app está abierta (y vuelve al mes de hoy al salir: reiniciarAlSalir en cada pantalla).
export function periodoInicial() {
  const [a, m] = hoy().split('-').map(Number);
  return { modo: 'mes', anio: a, mes: m };
}
// Fechas y texto de un período.
export function datosPeriodo(p) {
  if (p.modo === 'mes') {
    const r = rangoMes(p.anio, p.mes);
    return { ...r, texto: nombreMes(p.anio, p.mes), corto: MESES[p.mes - 1] };
  }
  return { desde: p.desde, hasta: p.hasta, texto: `del ${fecha(p.desde)} al ${fecha(p.hasta)}`, corto: `del ${fecha(p.desde)} al ${fecha(p.hasta)}` };
}
// Un mes que todavía no termina se muestra hasta hoy (no hasta el día 31).
export function hastaHoy(hasta) { return hasta > hoy() ? hoy() : hasta; }

// Selector "¿Qué fechas?": una lista con los meses y "Otras fechas…" (aparecen desde y hasta).
// alCambiar(periodo) se llama al elegir. permitirRango = false: solo meses (estados por mes del núcleo).
export function selectorPeriodo({ prefijo, periodo, alCambiar, permitirRango = true, maxDias = null }) {
  const meses = mesesDeLaEmpresa();
  const sel = h('select', { id: `${prefijo}-periodo` },
    meses.map((m) => h('option', { value: m.valor }, m.texto[0].toUpperCase() + m.texto.slice(1))),
    permitirRango ? h('option', { value: 'rango' }, 'Otras fechas…') : null);
  const desde = inputFecha(`${prefijo}-desde`, periodo.desde || datosPeriodo(periodoInicial()).desde, { max: hoy() });
  const hasta = inputFecha(`${prefijo}-hasta`, periodo.hasta || hoy(), { max: hoy() });
  const zonaError = h('div', { 'aria-live': 'polite' });
  const fechas = h('div', { class: 'dos-columnas', hidden: periodo.modo !== 'rango' },
    h('div', { class: 'campo' }, h('label', { for: desde.id }, 'Desde'), desde),
    h('div', { class: 'campo' }, h('label', { for: hasta.id }, 'Hasta'), hasta));
  sel.value = periodo.modo === 'rango' ? 'rango' : `${periodo.anio}-${dos(periodo.mes)}`;
  if (!sel.value) sel.value = meses[0].valor;
  function avisar() {
    zonaError.replaceChildren();
    if (sel.value !== 'rango') {
      const [a, m] = sel.value.split('-').map(Number);
      fechas.hidden = true;
      return alCambiar({ modo: 'mes', anio: a, mes: m });
    }
    fechas.hidden = false;
    if (!desde.value || !hasta.value || desde.value > hasta.value) {
      zonaError.append(h('p', { class: 'ayuda texto-rojo', role: 'alert' }, 'Revise las fechas: "desde" no puede ser después de "hasta".'));
      return null;
    }
    if (maxDias && diasEntre(desde.value, hasta.value) > maxDias) {
      zonaError.append(h('p', { class: 'ayuda texto-rojo', role: 'alert' }, `Elija como máximo ${maxDias + 1} días.`));
      return null;
    }
    return alCambiar({ modo: 'rango', desde: desde.value, hasta: hasta.value });
  }
  sel.addEventListener('change', avisar);
  desde.addEventListener('change', avisar);
  hasta.addEventListener('change', avisar);
  return h('div', { class: 'filtros' },
    h('div', { class: 'dos-columnas' }, h('div', { class: 'campo' }, h('label', { for: sel.id }, '¿Qué fechas?'), sel)),
    fechas, zonaError);
}

// ---------------------------------------------------------------------
// Excel
// ---------------------------------------------------------------------
const FORMATO_DINERO = '#,##0.00';
// Nombre de archivo sin tildes ni símbolos: "Gane o perdi - octubre de 2026.xlsx" -> "gane_o_perdi_octubre_de_2026.xlsx"
export function nombreArchivo(titulo, periodo) {
  const base = `${titulo} ${periodo}`.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 80);
  return `${base || 'reporte'}.xlsx`;
}
// Valor de una celda para el Excel: el dinero en lempiras (número con 2 decimales), lo demás tal cual.
function celdaExcel(v, tipo) {
  if (v === null || v === undefined || v === '') return '';
  if (tipo === 'dinero') return Math.round(Number(v)) / 100;
  if (tipo === 'numero') return Number(v);
  return typeof v === 'object' ? '' : String(v);
}
// Arma el libro (una hoja por sección). Se exporta para la prueba.
export function libroExcel(XLSX, doc) {
  const wb = XLSX.utils.book_new();
  const negocio = nombreVisible();
  const usados = new Set();
  (doc.secciones || []).forEach((s, i) => {
    const cols = s.columnas;
    const aoa = [[negocio], [`${doc.titulo} · ${doc.periodo}`], [s.titulo || doc.titulo], [],
      cols.map((c) => c.titulo),
      ...(s.filas || []).map((f) => cols.map((c, j) => celdaExcel(f[j], c.tipo))),
      ...(s.total ? [cols.map((c, j) => celdaExcel(s.total[j], c.tipo))] : []),
      ...((s.notas || []).length ? [[], ...s.notas.map((n) => [n])] : [])];
    if (i === 0 && (doc.notas || []).length) aoa.push([], ...doc.notas.map((n) => [n]));
    const ws = XLSX.utils.aoa_to_sheet(aoa);
    const primera = 5, ultima = 4 + (s.filas || []).length + (s.total ? 1 : 0);
    cols.forEach((c, j) => {
      const dir = XLSX.utils.encode_cell({ r: 4, c: j });
      if (ws[dir]) ws[dir].s = { font: { bold: true } };
      if (c.tipo !== 'dinero') return;
      for (let r = primera; r <= ultima; r++) {
        const d = XLSX.utils.encode_cell({ r, c: j });
        if (ws[d] && typeof ws[d].v === 'number') ws[d].z = FORMATO_DINERO;
      }
    });
    for (const r of [0, 1]) { const d = XLSX.utils.encode_cell({ r, c: 0 }); if (ws[d]) ws[d].s = { font: { bold: true } }; }
    ws['!cols'] = cols.map((c) => ({ wch: Math.max(12, Math.min(45, String(c.titulo).length + 6, c.tipo === 'texto' ? 45 : 18)) }));
    // Nombre de hoja: máximo 31 letras, sin / \ ? * [ ] : y sin repetir.
    let nombre = String(s.titulo || doc.titulo).replace(/[\\/?*[\]:]/g, ' ').slice(0, 31).trim() || `Hoja ${i + 1}`;
    for (let k = 2; usados.has(nombre.toLowerCase()); k++) nombre = `${nombre.slice(0, 27)} ${k}`;
    usados.add(nombre.toLowerCase());
    XLSX.utils.book_append_sheet(wb, ws, nombre);
  });
  return wb;
}
export async function descargarReporte(doc) {
  const XLSX = await cargarXLSX();
  XLSX.writeFile(libroExcel(XLSX, doc), nombreArchivo(doc.titulo, doc.periodo));
}

// ---------------------------------------------------------------------
// Lo impreso: logo, nombre, título, período y tablas con líneas. Nada de íconos, emojis ni colores.
// ---------------------------------------------------------------------
function textoImpreso(v, tipo) {
  if (v === null || v === undefined || v === '') return '';
  if (tipo === 'dinero') return dinero(v);
  if (tipo === 'numero') return cantidad(v);
  return String(v);
}
export function hojaImpresa(doc) {
  const m = (marcaActual() && marcaActual().marca) || {};
  const e = perfilActual().empresa;
  const logo = m.logo ? h('img', { class: 'impreso-logo', src: m.logo, alt: '' }) : null;
  const hoja = h('article', { class: 'reporte-impreso', 'aria-hidden': 'true' },
    h('header', { class: 'impreso-cabeza' }, logo,
      h('div', {}, h('p', { class: 'impreso-negocio' }, nombreVisible()), e.rtn ? h('p', {}, `RTN ${e.rtn}`) : null)),
    h('h1', {}, doc.titulo),
    h('p', {}, doc.periodo),
    (doc.secciones || []).map((s) => h('section', {},
      s.titulo && s.titulo !== doc.titulo ? h('h2', {}, s.titulo) : null,
      h('table', {},
        h('thead', {}, h('tr', {}, s.columnas.map((c) => h('th', { class: c.tipo === 'dinero' || c.tipo === 'numero' ? 'num' : null }, c.titulo)))),
        h('tbody', {}, (s.filas || []).map((f) => h('tr', {}, s.columnas.map((c, j) =>
          h('td', { class: c.tipo === 'dinero' || c.tipo === 'numero' ? 'num' : null }, textoImpreso(f[j], c.tipo)))))),
        s.total ? h('tfoot', {}, h('tr', {}, s.columnas.map((c, j) =>
          h('td', { class: c.tipo === 'dinero' || c.tipo === 'numero' ? 'num' : null }, textoImpreso(s.total[j], c.tipo))))) : null),
      (s.notas || []).map((n) => h('p', { class: 'impreso-nota' }, n)))),
    (doc.notas || []).map((n) => h('p', { class: 'impreso-nota' }, n)),
    h('p', { class: 'impreso-nota' }, `Impreso el ${fecha(hoy())} por ${sinEmojis((perfilActual().usuario || {}).nombre || '')}`.trim()));
  return limpiarImprimible(hoja);
}
export function imprimirReporte(doc) {
  for (const x of document.querySelectorAll('.reporte-impreso')) x.remove();
  const hoja = hojaImpresa(doc);
  document.body.append(hoja);
  document.body.classList.add('imprimiendo-reporte');
  const quitar = () => { hoja.remove(); document.body.classList.remove('imprimiendo-reporte'); };
  window.addEventListener('afterprint', quitar, { once: true });
  window.print();
}

// Botones "Descargar Excel" e "Imprimir". dameDoc() devuelve (o promete) el documento del reporte que se ve (o null).
export function botonesReporte(prefijo, dameDoc) {
  const zonaError = h('div', { 'aria-live': 'polite' });
  async function hacer(boton, accion) {
    zonaError.replaceChildren();
    boton.disabled = true;
    try { const doc = await dameDoc(); if (doc) await accion(doc); } catch (err) { zonaError.append(await cajaError(err)); } finally { boton.disabled = false; }
  }
  const excel = h('button', { type: 'button', class: 'boton', id: `${prefijo}-excel`, onclick: () => hacer(excel, descargarReporte) }, icono('excel'), 'Descargar Excel');
  const imprimir = h('button', { type: 'button', class: 'boton', id: `${prefijo}-imprimir`, onclick: () => hacer(imprimir, imprimirReporte) }, icono('documento'), 'Imprimir');
  return h('div', { class: 'no-imprimir' }, h('div', { class: 'botones botones-reporte' }, excel, imprimir), zonaError);
}

// Barra de progreso simple para "cuánto pesa cada parte" (gastos por categoría, formas de pago).
export function barraParte(valor, total) {
  const p = total > 0 ? Math.max(0, Math.min(100, Math.round((Number(valor) / total) * 100))) : 0;
  const relleno = h('div', { class: 'progreso-relleno' });
  relleno.style.width = `${p}%`;
  return h('div', { class: 'progreso', role: 'img', 'aria-label': `${p} %` }, relleno);
}

// "Ganó" / "Perdió" con el monto en positivo.
export function ganoPerdio(centavos) { return Number(centavos) >= 0 ? `ganó ${dinero(centavos)}` : `perdió ${dinero(Math.abs(Number(centavos)))}`; }

// Lee hasta "limite" filas; dice si llegó al tope (para avisar que las cifras pueden estar incompletas).
export const TOPE_FILAS = 1000;
export const llegoAlTope = (lista) => lista.length >= TOPE_FILAS;

// Fecha "hasta" para un rango de "los N días anteriores" del mismo largo (para comparar).
export function periodoAnterior(desde, hasta) {
  const dias = diasEntre(desde, hasta) + 1;
  return { desde: sumarDias(desde, -dias), hasta: sumarDias(desde, -1) };
}
