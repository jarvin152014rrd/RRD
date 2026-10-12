// Ayudas para armar pantallas sin innerHTML (los datos del servidor van como texto).
import { traducir } from './errores.js';

// h('p', {class: 'x', onclick: fn}, 'texto', otroNodo)
export function h(etiqueta, props = {}, ...hijos) {
  const el = document.createElement(etiqueta);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const hijo of hijos.flat(Infinity)) {
    if (hijo === null || hijo === undefined || hijo === false) continue;
    el.append(hijo instanceof Node ? hijo : document.createTextNode(String(hijo)));
  }
  return el;
}

// Aviso corto abajo de la pantalla (se quita solo).
export function aviso(texto, tipo = 'ok') {
  const caja = document.getElementById('avisos');
  if (!caja) return;
  const el = h('p', { class: `mensaje mensaje-${tipo}` }, texto);
  caja.append(el);
  setTimeout(() => el.remove(), 4500);
}

// Caja de error con el mensaje sencillo y qué hacer.
export async function cajaError(err) {
  const t = await traducir(err);
  return h('div', { class: 'mensaje mensaje-error', role: 'alert' },
    h('p', {}, h('strong', {}, t.mensaje)), t.queHacer ? h('p', {}, t.queHacer) : null);
}

// Diálogo para pedir un motivo y confirmar. accion(motivo) puede lanzar error: se muestra
// dentro del diálogo y no se cierra. Devuelve true si se confirmó con éxito.
export function pedirMotivo({ titulo, explicacion, textoBoton, peligro = false, accion }) {
  return new Promise((resolve) => {
    const idCampo = 'motivo-' + Math.random().toString(36).slice(2);
    const campo = h('textarea', { id: idCampo, name: 'motivo', required: true, minlength: 5, maxlength: 500,
      'aria-describedby': idCampo + '-ayuda' });
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const confirmar = h('button', { type: 'submit', class: `boton ${peligro ? 'boton-peligro' : 'boton-principal'}` }, textoBoton);
    const cancelar = h('button', { type: 'button', class: 'boton', onclick: () => cerrar(false) }, 'Cancelar');
    const form = h('form', { method: 'dialog', novalidate: true },
      h('h2', {}, titulo),
      explicacion ? h('p', { class: 'ayuda' }, explicacion) : null,
      h('div', { class: 'campo' }, h('label', { for: idCampo }, 'Motivo'), campo,
        h('p', { class: 'ayuda', id: idCampo + '-ayuda' }, 'Escriba por qué (mínimo 5 letras). Queda en la bitácora.')),
      zonaError,
      h('div', { class: 'botones' }, cancelar, confirmar));
    const dlg = h('dialog', { class: 'dialogo', 'aria-label': titulo }, form);
    let hecho = false;
    function cerrar(ok) { hecho = ok; dlg.close(); }
    dlg.addEventListener('close', () => { dlg.remove(); resolve(hecho); });
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const motivo = campo.value.trim();
      zonaError.replaceChildren();
      if (motivo.length < 5) {
        zonaError.append(h('p', { class: 'mensaje mensaje-error', role: 'alert' }, 'Escriba un motivo de al menos 5 letras.'));
        campo.focus();
        return;
      }
      confirmar.disabled = true; cancelar.disabled = true;
      confirmar.textContent = 'Guardando…';
      try {
        await accion(motivo);
        cerrar(true);
      } catch (err) {
        zonaError.append(await cajaError(err));
        confirmar.disabled = false; cancelar.disabled = false;
        confirmar.textContent = textoBoton;
      }
    });
    document.body.append(dlg);
    dlg.showModal();
    campo.focus();
  });
}

// Íconos simples (trazos) para la barra del celular.
const TRAZOS = {
  resumen: 'M4 13h6V4H4zM14 20h6V11h-6zM4 20h6v-4H4zM14 7h6V4h-6z',
  vender: 'M3 5h2l2.5 11h11L21 8H7M10 20a1 1 0 1 0 0 .1M18 20a1 1 0 1 0 0 .1',
  buscar: 'M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14zM21 21l-5-5',
  mas: 'M4 6h16M4 12h16M4 18h16',
};
export function icono(nombre) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2'); svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round');
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  p.setAttribute('d', TRAZOS[nombre] || '');
  svg.append(p);
  return svg;
}

// Campo con etiqueta: campo('Nombre', h('input', {...}), 'ayuda opcional')
let cuentaCampos = 0;
export function campo(etiqueta, control, ayuda = null) {
  const id = control.id || `c${++cuentaCampos}`;
  control.id = id;
  return h('div', { class: 'campo' }, h('label', { for: id }, etiqueta), control,
    ayuda ? h('p', { class: 'ayuda' }, ayuda) : null);
}

// Corre accion() con el botón deshabilitado y "Guardando…" (un doble clic no manda dos veces).
// El error se muestra en zonaError (traducido). Devuelve el resultado o null si falló.
export async function conBoton(boton, zonaError, accion, texto = 'Guardando…') {
  if (boton.disabled) return null;
  const antes = boton.textContent;
  boton.disabled = true;
  boton.textContent = texto;
  if (zonaError) zonaError.replaceChildren();
  try {
    return await accion();
  } catch (err) {
    if (zonaError) zonaError.append(await cajaError(err));
    return null;
  } finally {
    boton.disabled = false;
    boton.textContent = antes;
  }
}

// Mensaje de error propio (validación antes de llamar al servidor).
export function errorSimple(texto, queHacer = '') {
  return h('div', { class: 'mensaje mensaje-error', role: 'alert' }, h('p', {}, h('strong', {}, texto)),
    queHacer ? h('p', {}, queHacer) : null);
}

// Enlace de WhatsApp (wa.me). Teléfono de 8 dígitos = Honduras (504).
export function enlaceWhatsApp(telefono, texto) {
  let t = String(telefono || '').replace(/\D/g, '');
  if (t.length === 8) t = '504' + t;
  return `https://wa.me/${t}?text=${encodeURIComponent(texto)}`;
}

// Diálogo simple con contenido propio. Devuelve { dlg, cerrar }.
export function dialogo(titulo, ...contenido) {
  const dlg = h('dialog', { class: 'dialogo', 'aria-label': titulo },
    h('div', { class: 'dialogo-cuerpo' }, h('h2', {}, titulo), ...contenido));
  dlg.addEventListener('close', () => dlg.remove());
  document.body.append(dlg);
  dlg.showModal();
  return { dlg, cerrar: () => dlg.close() };
}
