// Marca del negocio (núcleo 0.14.0: marca_empresa / configurar_marca): nombre comercial,
// logo y colores. Se aplica encima de css/tema.css cambiando solo variables de color.
import { rpc } from './api.js';
import { empresaId, perfilActual } from './sesion.js';

let actual = null; // { nombre, rtn, marca: {...}, puede_volver }

export function marcaActual() { return actual; }

export async function cargarMarca() {
  try { actual = await rpc('marca_empresa', { p_empresa_id: empresaId() }); } catch { actual = null; }
  aplicarMarca(actual ? actual.marca : {});
  recordarEnEsteEquipo();
  return actual;
}

export function guardarMarcaLocal(m) { actual = m; aplicarMarca(m ? m.marca : {}); recordarEnEsteEquipo(); }

// La pantalla de entrar muestra el logo, el nombre y los colores del negocio que se usó la última vez
// en ESTE equipo (antes de entrar no se puede leer la base). Es solo para que se vea bonito: si el
// navegador no deja guardar (ventana privada), se usa la marca de siempre.
const LLAVE = 'marca-negocio';
function recordarEnEsteEquipo() {
  const m = (actual && actual.marca) || {};
  const datos = { nombre: nombreVisible(), logo: m.logo || null, color_principal: m.color_principal || null, color_acento: m.color_acento || null };
  try { localStorage.setItem(LLAVE, JSON.stringify(datos)); } catch { /* sin almacenamiento: no pasa nada */ }
}
export function marcaGuardada() {
  try {
    const x = JSON.parse(localStorage.getItem(LLAVE) || 'null');
    return x && typeof x === 'object' ? x : null;
  } catch { return null; }
}

// "Ferretería El Roble" -> "FR" (para la burbuja cuando no hay logo).
export function iniciales(nombre) {
  const p = String(nombre || '').trim().split(/\s+/).filter(Boolean);
  if (p.length === 0) return 'MN';
  return ((p[0][0] || '') + (p.length > 1 ? p[p.length - 1][0] : '')).toUpperCase();
}

export function nombreVisible() {
  const p = perfilActual();
  return (actual && actual.marca && actual.marca.nombre_comercial) || (p && p.empresa ? p.empresa.nombre : '');
}

// ---------------- Colores y contraste (WCAG) ----------------
// La marca SOLO cambia el color principal (encabezado y botones principales) y el de acento.
// Los colores con significado (verde, rojo, dorado y azul de estado, css/tema.css) NUNCA cambian.
const BLANCO = '#ffffff';
const OSCURO = '#000000'; // con negro, blanco o negro siempre llega a 4.5 (el peor caso da ~4.58)
const esColor = (x) => typeof x === 'string' && /^#[0-9a-fA-F]{6}$/.test(x);
const rgb = (hex) => { const n = parseInt(hex.slice(1), 16); return [n >> 16, (n >> 8) & 255, n & 255]; };
const aHex = (c) => '#' + c.map((x) => Math.round(Math.min(255, Math.max(0, x))).toString(16).padStart(2, '0')).join('');

// Mezcla dos colores (t = 0 -> a, t = 1 -> b).
export function mezclar(a, b, t) {
  const x = rgb(a), y = rgb(b);
  return aHex(x.map((v, i) => v + (y[i] - v) * t));
}
function luminancia(hex) {
  const l = rgb(hex).map((x) => { const v = x / 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2];
}
// Contraste WCAG entre dos colores (1 a 21). AA para texto normal = 4.5 o más.
export function contraste(a, b) {
  const [x, y] = [luminancia(a), luminancia(b)].sort((m, n) => n - m);
  return (x + 0.05) / (y + 0.05);
}
export function contrasteConBlanco(hex) { return contraste(hex, BLANCO); }

// Texto encima de un color: blanco o negro, el que más se lea.
export function textoSobre(fondo) { return contraste(fondo, BLANCO) >= contraste(fondo, OSCURO) ? BLANCO : OSCURO; }

// Fondo que SÍ permite texto AA: si con ningún texto llega a 4.5, se oscurece o se aclara (hacia el
// lado que ya estaba más cerca) hasta que llegue. Con negro y blanco no debería hacer falta nunca,
// pero así la regla queda garantizada aunque cambie el color oscuro.
export function fondoLegible(fondo) {
  const llega = (c) => Math.max(contraste(c, BLANCO), contraste(c, OSCURO)) >= 4.5;
  if (llega(fondo)) return fondo;
  const hacia = contraste(fondo, BLANCO) >= contraste(fondo, OSCURO) ? '#000000' : '#ffffff';
  for (let t = 0.05; t <= 1.0001; t += 0.05) { const c = mezclar(fondo, hacia, t); if (llega(c)) return c; }
  return hacia;
}
// Color para ÍCONOS decorativos sobre blanco (títulos): contraste 3 o más (se oscurece si hace falta).
export function iconoSobreBlanco(hex) {
  for (let t = 0; t <= 1.0001; t += 0.05) { const c = mezclar(hex, '#000000', t); if (contraste(c, BLANCO) >= 3) return c; }
  return OSCURO;
}

// Texto "suave" (menos fuerte) encima de un color, sin bajar de AA.
function suaveSobre(fondo, texto) {
  for (const t of [0.3, 0.2, 0.1]) { const c = mezclar(texto, fondo, t); if (contraste(c, fondo) >= 4.5) return c; }
  return texto;
}
// El color de la marca usado como LETRA sobre blanco o crema (títulos, botones de borde): si es muy
// claro se oscurece hasta que se lea (AA sobre el fondo crema, que es un poco más oscuro que el blanco).
function legibleSobreClaro(hex, fondo = '#f4f2ee') {
  for (let t = 0; t <= 1.0001; t += 0.05) { const c = mezclar(hex, '#000000', t); if (contraste(c, fondo) >= 4.5) return c; }
  return OSCURO;
}

// Modo oscuro (app 0.15.0): el fondo de las tarjetas oscuras. Los colores de la marca usados como letra, ícono,
// foco o botón se ACLARAN hasta que se lean encima (letra 4.5, ícono/foco/borde de botón 3).
export const TARJETA_OSCURA = '#1a202b';
// Se aclara subiendo la LUZ del color (HSL) sin perder su tono: el azul marino queda azul, no gris.
function aHsl(hex) {
  const [r, g, b] = rgb(hex).map((x) => x / 255);
  const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min;
  if (!d) return [0, 0, l];
  const s = d / (1 - Math.abs(2 * l - 1));
  const hh = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [hh * 60, s, l];
}
function deHsl(hh, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs(((hh / 60) % 2) - 1)), m = l - c / 2;
  const [r, g, b] = hh < 60 ? [c, x, 0] : hh < 120 ? [x, c, 0] : hh < 180 ? [0, c, x] : hh < 240 ? [0, x, c] : hh < 300 ? [x, 0, c] : [c, 0, x];
  return aHex([r + m, g + m, b + m].map((v) => v * 255));
}
function aclararHasta(hex, minimo, fondo = TARJETA_OSCURA) {
  const [hh, s, l] = aHsl(hex);
  for (let t = l; t <= 1.0001; t += 0.02) { const c = deHsl((hh + 360) % 360, s, Math.min(1, t)); if (contraste(c, fondo) >= minimo) return c; }
  return BLANCO;
}

// Todas las variables de color que salen de la marca. null = usar las del tema (css/tema.css).
export function coloresDeMarca(m = {}) {
  const v = {};
  if (esColor(m.color_principal)) {
    const p = fondoLegible(m.color_principal.toLowerCase());
    const en = textoSobre(p);
    Object.assign(v, { '--color-principal': p, '--color-principal-2': mezclar(p, BLANCO, 0.12), '--color-en-principal': en,
      '--color-en-principal-suave': suaveSobre(p, en), '--color-principal-texto': legibleSobreClaro(p) });
    const boton = fondoLegible(aclararHasta(p, 3));
    Object.assign(v, { '--color-principal-texto-oscuro': aclararHasta(p, 7), '--color-boton-oscuro': boton, '--color-en-boton-oscuro': textoSobre(boton) });
  }
  if (esColor(m.color_acento)) {
    const a = fondoLegible(m.color_acento.toLowerCase());
    // Foco: el acento solo si se ve sobre blanco (3 o más); si no, el principal legible.
    // Íconos de los títulos: el acento oscurecido hasta 3 o más sobre blanco.
    Object.assign(v, { '--color-acento': a, '--color-en-acento': textoSobre(a), '--color-acento-icono': iconoSobreBlanco(a),
      '--color-foco': contraste(a, BLANCO) >= 3 ? a : (v['--color-principal-texto'] || '#0f1f3d'),
      '--color-acento-icono-oscuro': aclararHasta(a, 3), '--color-foco-oscuro': aclararHasta(a, 3) });
  }
  return v;
}
const VARIABLES = ['--color-principal', '--color-principal-2', '--color-en-principal', '--color-en-principal-suave',
  '--color-principal-texto', '--color-acento', '--color-en-acento', '--color-acento-icono', '--color-foco',
  '--color-principal-texto-oscuro', '--color-boton-oscuro', '--color-en-boton-oscuro', '--color-acento-icono-oscuro', '--color-foco-oscuro'];

// Pone los colores (o vuelve a los del tema si no hay) y el logo y nombre del encabezado.
// raiz puede ser otro elemento (la vista previa de Ajustes > Mi negocio): ahí solo cambian los colores.
export function aplicarMarca(m = {}, raiz = document.documentElement) {
  const v = coloresDeMarca(m || {});
  for (const k of VARIABLES) {
    if (v[k]) raiz.style.setProperty(k, v[k]); else raiz.style.removeProperty(k);
  }
  if (raiz !== document.documentElement) return;
  const meta = document.querySelector('meta[name=theme-color]');
  if (meta) meta.setAttribute('content', v['--color-principal'] || '#0f1f3d');
  const nombre = document.getElementById('marca-nombre');
  if (nombre) nombre.textContent = nombreVisible();
  const logo = document.getElementById('marca-logo');
  if (logo && perfilActual()) logo.dataset.iniciales = iniciales(nombreVisible());
  if (logo) {
    if (m && m.logo) {
      const img = document.createElement('img');
      img.src = m.logo; img.alt = ''; img.className = 'marca-logo-img';
      logo.replaceChildren(img);
    } else {
      logo.textContent = logo.dataset.iniciales || '';
    }
  }
}
