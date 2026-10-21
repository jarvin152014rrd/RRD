// Lo IMPRESO (comprobantes, facturas, texto para WhatsApp, título de la página al imprimir) lleva
// solo logo, texto y líneas: nunca íconos, emojis ni colores de pantalla.
// Los nombres que vienen del cliente (negocio, productos, palabras del rubro) pueden traer emojis:
// aquí se quitan AL IMPRIMIR (los datos guardados no se tocan).
// No importa nada: lo usan comprobante.js, app.js y las pruebas.

// Emojis y pictogramas: Extended_Pictographic (menos (c), (R) y TM, que son letras de marca),
// banderas (indicadores regionales y las etiquetas de banderas de regiones, U+E0020 a U+E007F), tonos de piel, selector de variación, unión (ZWJ) y tecla (keycap).
export const EMOJI = /(?:(?![\u00A9\u00AE\u2122])\p{Extended_Pictographic}|[\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}\uFE0E\uFE0F\u200D\u20E3\u{E0020}-\u{E007F}])/gu;

export function tieneEmoji(texto) {
  EMOJI.lastIndex = 0;
  const si = EMOJI.test(String(texto ?? ''));
  EMOJI.lastIndex = 0;
  return si;
}

// "Ordenes (emoji) de trabajo" -> "Ordenes de trabajo" (sin espacios dobles; respeta los saltos de linea).
export function sinEmojis(texto) {
  if (texto === null || texto === undefined) return texto;
  return String(texto).replace(EMOJI, '').split('\n').map((l) => l.replace(/[ \t]{2,}/g, ' ').trim()).join('\n');
}

// Limpia un pedazo de página que se va a imprimir: quita los íconos (<svg>) y los emojis del texto
// y de las etiquetas para lectores. Devuelve el mismo nodo.
export function limpiarImprimible(nodo) {
  for (const s of nodo.querySelectorAll('svg, .icono')) s.remove();
  const andar = document.createTreeWalker(nodo, NodeFilter.SHOW_TEXT);
  const textos = [];
  while (andar.nextNode()) textos.push(andar.currentNode);
  for (const t of textos) if (tieneEmoji(t.nodeValue)) t.nodeValue = sinEmojis(t.nodeValue);
  for (const el of [nodo, ...nodo.querySelectorAll('[aria-label],[title],[alt]')]) {
    for (const a of ['aria-label', 'title', 'alt']) if (el.hasAttribute && el.hasAttribute(a)) el.setAttribute(a, sinEmojis(el.getAttribute(a)));
  }
  return nodo;
}

// El navegador imprime el título de la página arriba de la hoja: si trae un emoji (por las palabras
// del rubro o el nombre del negocio) se quita mientras se imprime y se devuelve después.
let tituloAntes = null;
export function vigilarImpresion(ventana = window) {
  ventana.addEventListener('beforeprint', () => {
    tituloAntes = document.title;
    document.title = sinEmojis(document.title);
  });
  ventana.addEventListener('afterprint', () => {
    if (tituloAntes !== null) document.title = tituloAntes;
    tituloAntes = null;
  });
}
