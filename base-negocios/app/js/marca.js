// Marca del negocio (núcleo 0.14.0: marca_empresa / configurar_marca): nombre comercial,
// logo y colores. Se aplica encima de css/tema.css cambiando solo variables de color.
import { rpc } from './api.js';
import { empresaId, perfilActual } from './sesion.js';

let actual = null; // { nombre, rtn, marca: {...}, puede_volver }

export function marcaActual() { return actual; }

export async function cargarMarca() {
  try { actual = await rpc('marca_empresa', { p_empresa_id: empresaId() }); } catch { actual = null; }
  aplicarMarca(actual ? actual.marca : {});
  return actual;
}

export function guardarMarcaLocal(m) { actual = m; aplicarMarca(m ? m.marca : {}); }

export function nombreVisible() {
  const p = perfilActual();
  return (actual && actual.marca && actual.marca.nombre_comercial) || (p && p.empresa ? p.empresa.nombre : '');
}

// Aclara un color #rrggbb mezclándolo con blanco (0..1).
function aclarar(hex, cuanto) {
  const n = parseInt(hex.slice(1), 16);
  const c = [n >> 16, (n >> 8) & 255, n & 255].map((x) => Math.round(x + (255 - x) * cuanto));
  return '#' + c.map((x) => x.toString(16).padStart(2, '0')).join('');
}

// Contraste WCAG entre un color y el blanco (para avisar si las letras blancas no se leen).
export function contrasteConBlanco(hex) {
  const n = parseInt(hex.slice(1), 16);
  const l = [n >> 16, (n >> 8) & 255, n & 255].map((x) => { const v = x / 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  const lum = 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2];
  return 1.05 / (lum + 0.05);
}

// Pone los colores (o vuelve a los del tema si no hay) y el logo y nombre del encabezado.
export function aplicarMarca(m = {}, raiz = document.documentElement) {
  const ok = (x) => typeof x === 'string' && /^#[0-9a-fA-F]{6}$/.test(x);
  if (ok(m.color_principal)) {
    raiz.style.setProperty('--color-principal', m.color_principal);
    raiz.style.setProperty('--color-principal-2', aclarar(m.color_principal, 0.12));
  } else {
    raiz.style.removeProperty('--color-principal'); raiz.style.removeProperty('--color-principal-2');
  }
  if (ok(m.color_acento)) raiz.style.setProperty('--color-acento', m.color_acento);
  else raiz.style.removeProperty('--color-acento');
  if (raiz !== document.documentElement) return;
  const nombre = document.getElementById('marca-nombre');
  if (nombre) nombre.textContent = nombreVisible();
  const logo = document.getElementById('marca-logo');
  if (logo) {
    if (m.logo) {
      const img = document.createElement('img');
      img.src = m.logo; img.alt = ''; img.className = 'marca-logo-img';
      logo.replaceChildren(img);
    } else {
      logo.textContent = logo.dataset.iniciales || '';
    }
  }
}
