// Juego de íconos propio (de línea, sin relleno, viewBox 24, trazo 1.8). Todo va aquí
// dentro: no se descarga nada, así funciona sin internet. NO importa nada: lo usan la app
// y el Armador del proveedor.
// Cada ícono es una lista de trazos:
//   'M...'            -> <path d="M...">
//   'c:cx,cy,r'       -> <circle>
//   'r:x,y,ancho,alto,radio' -> <rect>
// Los íconos NUNCA van en lo impreso (comprobante, PDF): solo en pantalla.

export const ICONOS = {
  // Pestañas
  inicio: ['M3 10.5 12 3l9 7.5', 'M5 9.5V21h14V9.5', 'M10 21v-6h4v6'],
  vender: ['c:9,20,1.5', 'c:18,20,1.5', 'M2 3h3l2.7 12.4a2 2 0 0 0 2 1.6h8.6a2 2 0 0 0 2-1.6L22 7H6'],
  caja: ['r:2,6,20,12,2', 'c:12,12,2.5', 'M6 12h.01M18 12h.01'],
  clientes: ['c:9,8,3.5', 'M2.5 20a6.5 6.5 0 0 1 13 0', 'M16 4.5a3.5 3.5 0 0 1 0 7', 'M18 14a6.5 6.5 0 0 1 3.5 6'],
  inventario: ['M21 8 12 3 3 8v8l9 5 9-5z', 'M3 8l9 5 9-5', 'M12 13v8'],
  compras: ['M2 6h12v10H2z', 'M14 9h4l4 4v3h-8z', 'c:6,18,2', 'c:18,18,2'],
  dinero: ['r:2,7,20,14,2', 'M16 7V5a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v4', 'M22 12h-5a2 2 0 0 0 0 4h5'],
  reportes: ['M3 3v18h18', 'M7 15l4-4 3 3 5-6'],
  ajustes: ['c:12,12,3', 'M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z'],

  // Avisos y estados
  campana: ['M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9', 'M10.3 21a1.94 1.94 0 0 0 3.4 0'],
  tarjeta: ['r:2,5,20,14,2', 'M2 10h20', 'M6 15h4'],
  transferencia: ['M4 8h14l-3-3', 'M20 16H6l3 3'],
  luna: ['M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z'],
  sol: ['c:12,12,4', 'M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4'],
  pendientes: ['M9 11l3 3 8-8', 'M20 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11'],
  alerta: ['M12 3 2 21h20z', 'M12 10v5M12 18h.01'],
  info: ['c:12,12,9', 'M12 16v-5M12 8h.01'],
  reloj: ['c:12,12,9', 'M12 7v5l3 2'],
  candado: ['r:4,11,16,10,2', 'M8 11V7a4 4 0 0 1 8 0v4'],
  candado_abierto: ['r:4,11,16,10,2', 'M8 11V7a4 4 0 0 1 7.7-1.5'],
  check: ['M5 12l5 5L20 7'],
  check_circulo: ['c:12,12,9', 'M8 12l3 3 5-6'],
  cerrar: ['M18 6 6 18M6 6l12 12'],
  estrella: ['M12 2l3 6.5 7 .8-5.2 4.8 1.5 7L12 17.6 5.7 21l1.5-7L2 9.3l7-.8z'],
  bandera: ['M4 22V4', 'M4 4h13l-2 4 2 4H4'],
  construccion: ['M2 20h20', 'M5 20 12 4l7 16', 'M8.5 12h7M7 16h10'],

  // Acciones
  mas: ['M12 5v14M5 12h14'],
  menu: ['M4 6h16M4 12h16M4 18h16'],
  buscar: ['c:11,11,7', 'M21 21l-5-5'],
  editar: ['M12 20h9', 'M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z'],
  borrar: ['M3 6h18', 'M8 6V4h8v2', 'M6 6l1 15h10l1-15', 'M10 11v6M14 11v6'],
  anular: ['c:12,12,9', 'M5.6 5.6l12.8 12.8'],
  descargar: ['M12 3v12', 'M7 10l5 5 5-5', 'M5 21h14'],
  subir: ['M12 21V9', 'M7 14l5-5 5 5', 'M5 3h14'],
  flecha: ['M5 12h14', 'M13 6l6 6-6 6'],
  salir: ['M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4', 'M16 17l5-5-5-5', 'M21 12H9'],
  sube: ['M7 17 17 7', 'M9 7h8v8'],
  baja: ['M17 7 7 17', 'M15 17H7V9'],

  // Documentos y cosas del negocio
  recibo: ['M4 2h16v20l-3-2-3 2-2-2-2 2-3-2-3 2z', 'M8 7h8M8 11h8M8 15h5'],
  documento: ['M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z', 'M14 2v6h6', 'M8 13h8M8 17h5'],
  excel: ['M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z', 'M14 2v6h6', 'M8 12h8v7H8z', 'M8 15.5h8M12 12v7'],
  lista: ['M8 6h13M8 12h13M8 18h13', 'M3 6h.01M3 12h.01M3 18h.01'],
  grafica: ['M3 3v18h18', 'M8 17v-5M13 17V8M18 17v-9'],
  proyeccion: ['M3 3v18h18', 'M7 15l4-4 3 2 6-6', 'M15 7h5v5'],
  calendario: ['r:3,4,18,18,2', 'M16 2v4M8 2v4M3 10h18'],
  cierre: ['r:3,4,18,18,2', 'M16 2v4M8 2v4M3 10h18', 'M9 16l2 2 4-4'],
  bitacora: ['M4 19V5a2 2 0 0 1 2-2h14v14H6a2 2 0 0 0-2 2 2 2 0 0 0 2 2h14v-4', 'M8 7h8M8 11h6'],
  impuestos: ['M19 5 5 19', 'c:6.5,6.5,2.5', 'c:17.5,17.5,2.5'],
  reglas: ['M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3', 'M1 14h6M9 8h6M17 16h6'],
  etiqueta: ['M20.6 13.4 13.4 20.6a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8z', 'c:7.5,7.5,1.5'],
  bolsa: ['M6 7h12l1 14H5z', 'M9 7V5a3 3 0 0 1 6 0v2'],
  conteo: ['M9 3h6v3H9z', 'M8 4.5H6a2 2 0 0 0-2 2V20a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V6.5a2 2 0 0 0-2-2h-2', 'M8 13l2 2 4-4', 'M8 18h8'],
  existencias: ['r:3,3,18,18,2', 'M3 9h18M3 15h18', 'M8 6h3M8 12h3M8 18h3'],
  movimientos: ['M7 20V4', 'M3 8l4-4 4 4', 'M17 4v16', 'M21 16l-4 4-4-4'],
  traslado: ['M4 8h14', 'M14 4l4 4-4 4', 'M20 16H6', 'M10 12l-4 4 4 4'],
  devolucion: ['M9 14 4 9l5-5', 'M4 9h11a5 5 0 0 1 0 10h-3'],
  // App 0.12.0: garantías (escudo con visto), cheque y antigüedad de saldos (reloj de arena).
  garantia: ['M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z', 'M9 12l2 2 4-4'],
  cheque: ['r:2,6,20,12,2', 'M6 10h7M6 14h4', 'M15 15c1-2 2-3 3-3s0 2 1 2'],
  antiguedad: ['M6 2h12M6 22h12', 'M7 2c0 5 10 5 10 10S7 17 7 22', 'M17 2c0 5-10 5-10 10s10 5 10 10'],
  servicio: ['M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z'],
  foto: ['r:3,3,18,18,2', 'c:9,9,2', 'M21 15l-5-5L5 21'],

  // Dinero
  billetes: ['r:2,5,16,10,2', 'c:10,10,2', 'M6 19h16V9'],
  cobrar: ['r:2,9,20,12,2', 'c:12,15,2.5', 'M12 2v5', 'M9.5 4.5 12 7l2.5-2.5'],
  banco: ['M3 10h18', 'M12 3l9 5H3z', 'M5 10v8M9.5 10v8M14.5 10v8M19 10v8', 'M3 21h18'],
  conciliar: ['M3 10h18', 'M12 3l9 5H3z', 'M5 10v6M9.5 10v6M14.5 10v5M19 10v3', 'M3 20h9', 'M15 19l2 2 4-4'],
  deposito: ['M12 2v9', 'M8 7l4 4 4-4', 'r:3,14,18,7,2', 'M7 17.5h.01M17 17.5h.01'],
  capas: ['M12 2 2 7l10 5 10-5z', 'M2 17l10 5 10-5', 'M2 12l10 5 10-5'],

  // Personas y lugares
  usuario: ['c:12,8,4', 'M4 21a8 8 0 0 1 16 0'],
  usuarios: ['c:9,8,3.5', 'M2.5 20a6.5 6.5 0 0 1 13 0', 'c:17,9,2.5', 'M16 14.2a5 5 0 0 1 5.5 5.8'],
  cliente_mas: ['c:9,8,3.5', 'M2.5 20a6.5 6.5 0 0 1 13 0', 'M19 8v6M16 11h6'],
  credencial: ['r:3,4,18,16,2', 'c:9,11,2', 'M6 16.5a3 3 0 0 1 6 0', 'M14 10h4M14 14h3'],
  cuenta: ['c:12,12,10', 'c:12,10,3', 'M6.2 18.4a7 7 0 0 1 11.6 0'],
  tienda: ['M4 10v10h16V10', 'M2 10l2-6h16l2 6z', 'M9 20v-5h6v5'],
  proveedor: ['M3 21V10l6 3.5V10l6 3.5V5h6v16z', 'M2 21h20'],
};

const SVG = 'http://www.w3.org/2000/svg';

export function existeIcono(nombre) { return Object.prototype.hasOwnProperty.call(ICONOS, nombre); }

// <svg> del ícono (decorativo: aria-hidden). Un nombre que no existe da un círculo
// vacío (nunca rompe la pantalla). Se arma con createElementNS: nada de innerHTML.
export function icono(nombre, clase = '') {
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor'); svg.setAttribute('stroke-width', '1.8');
  svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('class', ('icono ' + (clase || '')).trim());
  for (const t of existeIcono(nombre) ? ICONOS[nombre] : ['c:12,12,8']) {
    let el;
    if (t.startsWith('c:')) {
      const [cx, cy, r] = t.slice(2).split(',');
      el = document.createElementNS(SVG, 'circle');
      el.setAttribute('cx', cx); el.setAttribute('cy', cy); el.setAttribute('r', r);
    } else if (t.startsWith('r:')) {
      const [x, y, w, alto, rx] = t.slice(2).split(',');
      el = document.createElementNS(SVG, 'rect');
      el.setAttribute('x', x); el.setAttribute('y', y); el.setAttribute('width', w); el.setAttribute('height', alto);
      if (rx) el.setAttribute('rx', rx);
    } else {
      el = document.createElementNS(SVG, 'path');
      el.setAttribute('d', t);
    }
    svg.append(el);
  }
  return svg;
}
