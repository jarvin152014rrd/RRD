// Ayudas para armar pantallas sin innerHTML (los datos del servidor van como texto).
import { traducir } from './errores.js';
import { icono } from './iconos.js';

export { icono };

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

// Aviso corto abajo de la pantalla. Se quita solo (dura ms) y también al cambiar de
// pantalla o de estado (limpiarAvisos), para que no quede un aviso viejo como
// "Turno abierto…" después de cerrar el turno.
export function aviso(texto, tipo = 'ok', dura = 4500) {
  const caja = document.getElementById('avisos');
  if (!caja) return;
  const el = h('p', { class: `mensaje mensaje-${tipo} con-icono` }, icono(ICONO_MENSAJE[tipo] || 'info'), h('span', {}, texto));
  caja.append(el);
  setTimeout(() => el.remove(), dura);
  return el;
}
const ICONO_MENSAJE = { ok: 'check_circulo', error: 'alerta', info: 'info' };
export function limpiarAvisos() {
  const caja = document.getElementById('avisos');
  if (caja) caja.replaceChildren();
}

// Confirmación simple (sí / no) antes de guardar un cambio. Devuelve true si confirmó.
export function confirmar({ titulo, texto, textoBoton = 'Sí, guardar', peligro = false }) {
  return new Promise((resolve) => {
    let ok = false;
    const si = h('button', { type: 'button', class: `boton ${peligro ? 'boton-peligro' : 'boton-principal'}`, id: 'confirmar-si',
      onclick: () => { ok = true; cerrar(); } }, textoBoton);
    const { dlg, cerrar } = dialogo(titulo, texto ? h('p', {}, texto) : null,
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => cerrar() }, 'Cancelar'), si));
    dlg.addEventListener('close', () => resolve(ok));
    si.focus();
  });
}

// Caja de error con el mensaje sencillo y qué hacer.
export async function cajaError(err) {
  const t = await traducir(err);
  return h('div', { class: 'mensaje mensaje-error con-icono', role: 'alert' }, icono('alerta'),
    h('div', {}, h('p', {}, h('strong', {}, t.mensaje)), t.queHacer ? h('p', {}, t.queHacer) : null));
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
  return h('div', { class: 'mensaje mensaje-error con-icono', role: 'alert' }, icono('alerta'),
    h('div', {}, h('p', {}, h('strong', {}, texto)), queHacer ? h('p', {}, queHacer) : null));
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

// ---------------- Piezas visuales (app 0.5.0) ----------------
// Colores con significado fijo (css/tema.css):
//   verde = entra dinero / todo bien · rojo = sale dinero / problema
//   dorado = importante / hoy · azul = información · neutro = sin significado

// Chip de color: chip('L 2,400 vencido', 'rojo')
export function chip(texto, color = 'neutro', props = {}) {
  return h('span', { ...props, class: `chip-color chip-${color}${props.class ? ' ' + props.class : ''}` }, texto);
}

// Burbuja de ícono: cuadrito redondeado de color suave con el ícono adentro.
export function burbuja(nombre, color = 'azul', props = {}) {
  return h('span', { ...props, class: `burbuja burbuja-${color}${props.class ? ' ' + props.class : ''}` }, icono(nombre));
}

// Tarjeta de cifra: ícono + etiqueta, monto grande y abajo un chip y una nota.
// tarjetaCifra({ dato: 'ventas_hoy', icono: 'sube', color: 'verde', etiqueta: 'Vendí hoy',
//                valor: 'L 8,450.00', chip: chip(...), nota: '14 ventas' })
export function tarjetaCifra({ dato, icono: ic, color = 'azul', etiqueta, valor, chip: c = null, nota = null }) {
  return h('div', { class: 'tarjeta tarjeta-cifra', dataset: dato ? { dato } : null },
    h('div', { class: `cifra-cabeza texto-${color}` }, icono(ic), h('p', { class: 'cifra-titulo' }, etiqueta)),
    h('p', { class: 'cifra-valor' }, valor),
    c || nota ? h('p', { class: 'cifra-nota' }, c, c && nota ? ' ' : null, nota) : null);
}

// Botón grande de acción (enlace): burbuja de ícono + texto. principal = fondo del color del negocio.
export function botonAccion({ href, icono: ic, texto, color = 'azul', principal = false, id = null }) {
  return h('a', { class: 'accion' + (principal ? ' accion-principal' : ''), href, id, dataset: { accion: id || ic } },
    burbuja(ic, principal ? 'acento' : color), h('span', {}, texto));
}

// Fila con burbuja de ícono: filaIcono({ icono, color, titulo, detalle, derecha, abajo })
export function filaIcono({ icono: ic, color = 'azul', burbuja: b = null, titulo, detalle = null, derecha = null, abajo = null, props = {} }) {
  // abajo (botones) va en su propia línea, debajo del texto y del monto: así en el celular el
  // nombre y el monto no quedan apretados (css: .fila-icono-abajo).
  return h('div', { ...props, class: 'fila-icono' + (abajo ? ' con-abajo' : '') + (props.class ? ' ' + props.class : '') },
    b || burbuja(ic, color),
    h('div', { class: 'fila-icono-texto' }, h('div', { class: 'fila-icono-titulo' }, titulo),
      detalle ? h('div', { class: 'fila-icono-detalle' }, detalle) : null),
    derecha ? h('div', { class: 'fila-icono-derecha' }, derecha) : null,
    abajo ? h('div', { class: 'fila-icono-abajo' }, abajo) : null);
}

// Gráfica de barras simple (sin librería): barras = [{ etiqueta, valor, texto, textoCorto, destacado }].
// textoCorto: el número que se ve en el celular (más angosto).
// Cada barra lleva su número escrito arriba (no depende solo del color ni del alto).
export function graficaBarras(barras, { titulo = 'Gráfica', alto = 150 } = {}) {
  const max = Math.max(1, ...barras.map((b) => Number(b.valor) || 0));
  // Alturas con el.style (CSSOM): sirve aunque la página prohíba estilos escritos en el HTML.
  const caja = h('div', { class: 'grafica', role: 'list', 'aria-label': titulo },
    barras.map((b) => {
      const barra = h('div', { class: 'grafica-barra' });
      barra.style.height = `${Math.max(2, Math.round(((Number(b.valor) || 0) / max) * 100))}%`;
      return h('div', { class: 'grafica-col' + (b.destacado ? ' grafica-hoy' : ''), role: 'listitem', dataset: b.dato ? { barra: b.dato } : null },
        h('span', { class: 'grafica-valor' }, h('span', { class: 'valor-largo' }, b.texto),
          h('span', { class: 'valor-corto', 'aria-hidden': 'true' }, b.textoCorto || b.texto)),
        h('div', { class: 'grafica-zona' }, barra),
        h('span', { class: 'grafica-etiqueta' }, b.etiqueta));
    }));
  caja.style.setProperty('--alto-grafica', `${alto}px`);
  return caja;
}

// Estado vacío que enseña: ícono grande + frase sencilla + botones para empezar (solo los que el
// usuario puede usar; null se ignora). boton / botones = { texto, href | onclick, icono, id }.
// El primero va como botón principal. chico: para dentro de una tarjeta con más cosas.
export function estadoVacio({ icono: ic = 'info', titulo = null, texto, boton = null, botones = [], color = 'azul', chico = false, props = {} }) {
  const lista = [boton, ...botones].filter(Boolean);
  const hacer = (b, i) => {
    const clase = 'boton' + (i === 0 ? ' boton-principal' : '');
    const hijos = [b.icono ? icono(b.icono) : null, h('span', {}, b.texto)];
    return b.href ? h('a', { class: clase, href: b.href, id: b.id || null }, hijos)
      : h('button', { type: 'button', class: clase, id: b.id || null, onclick: b.onclick }, hijos);
  };
  return h('div', { ...props, class: 'estado-vacio' + (chico ? ' estado-vacio-chico' : '') + (props.class ? ' ' + props.class : '') },
    burbuja(ic, color, { class: chico ? '' : 'burbuja-grande' }),
    titulo ? h('p', { class: 'estado-vacio-titulo' }, titulo) : null,
    texto ? h('p', { class: 'vacio' }, texto) : null,
    lista.length ? h('div', { class: 'botones estado-vacio-botones' }, lista.map(hacer)) : null);
}

// Mensaje de éxito, información o error con ícono (dentro de la pantalla, no se quita solo).
export function mensaje(tipo, texto, detalle = null, props = {}) {
  return h('div', { ...props, class: `mensaje mensaje-${tipo} con-icono${props.class ? ' ' + props.class : ''}`, role: tipo === 'error' ? 'alert' : 'status' },
    icono(ICONO_MENSAJE[tipo] || 'info'), h('div', {}, h('p', {}, h('strong', {}, texto)), detalle ? h('p', {}, detalle) : null));
}

// ---------------- Piezas de la ronda 2 (app 0.6.0) ----------------

// Título con su ícono dorado: titulo('h1', 'etiqueta', 'Productos', { id: 't-prod' }).
export function titulo(nivel, ic, texto, props = {}) {
  return h(nivel, { ...props, class: 'titulo-icono' + (props.class ? ' ' + props.class : '') }, icono(ic), texto);
}

// Chip de estado con color fijo: verde = bien / pagado; dorado = espera; rojo = problema; azul = información.
const ESTADOS = {
  emitida: ['Emitida', 'verde'], pagada: ['Pagada', 'verde'], aplicada: ['Aplicada', 'verde'], cobrado: ['Cobrado', 'verde'],
  activo: ['Activo', 'verde'], activa: ['Activa', 'verde'], al_dia: ['Al día', 'verde'],
  vigente: ['Vigente', 'azul'], credito: ['Crédito', 'azul'], contado: ['Contado', 'neutro'],
  pendiente: ['Pendiente', 'dorado'], pendiente_aprobacion: ['En espera de aprobación', 'dorado'], por_emitir: ['Por emitir', 'dorado'],
  vencida: ['Vencida', 'rojo'], anulada: ['Anulada', 'rojo'], rechazada: ['Rechazada', 'rojo'], bajo_minimo: ['Bajo el mínimo', 'rojo'],
  cancelada: ['Cancelada', 'neutro'], inactivo: ['Inactivo', 'neutro'], inactiva: ['Inactiva', 'neutro'],
  // app 0.7.0 (Compras y Dinero)
  aplicado: ['Aplicado', 'verde'], confirmada: ['Confirmado', 'verde'], conciliado: ['Cuadrado', 'verde'], cerrada: ['Cerrada', 'verde'],
  por_vencer: ['Por vencer', 'dorado'], por_pagar: ['Por pagar', 'dorado'], en_transito: ['En tránsito', 'dorado'], proximo: ['Próximo', 'dorado'],
  abierta: ['Abierta', 'dorado'],
  vencido: ['Vencido', 'rojo'], anulado: ['Anulado', 'rojo'], rechazado: ['Rechazado', 'rojo'],
  // app 0.12.0 (garantías y cheques)
  recibido: ['Recibido', 'dorado'], en_revision: ['En revisión', 'azul'], resuelto: ['Resuelto', 'verde'],
  por_depositar: ['Por depositar', 'dorado'], depositado: ['Depositado', 'azul'],
};
export function chipEstado(estado, texto = null) {
  const [t, c] = ESTADOS[estado] || [String(estado || ''), 'neutro'];
  return chip(texto || t, c, { dataset: { estado: String(estado || '') } });
}

// Monto con color con significado: sentido 'entra' = verde, 'sale' = rojo; sin sentido = color normal
// (y rojo si es negativo). signo: antepone + o - al texto. dato: data-dato para las pruebas.
export function monto(texto, { sentido = null, negativo = false, dato = null, signo = '' } = {}) {
  const color = sentido === 'entra' ? ' monto-entra' : sentido === 'sale' || negativo ? ' monto-sale' : '';
  return h('span', { class: 'monto' + color, dataset: dato ? { dato } : null }, signo + texto);
}

// Tabla que en el celular (menos de 700 px) se ve como tarjetas: la primera columna arriba (lo
// principal) y cada dato con su título; los botones (columna con acciones: true) grandes y a lo ancho.
// columnas = [{ titulo, num, acciones }]; filas = [[celda, ...]] (celda = texto, nodo o { contenido, props });
// filaProps(i) = props de cada <tr>.
export function tabla({ columnas, filas, props = {}, filaProps = () => ({}) }) {
  const celda = (x) => (x && typeof x === 'object' && !(x instanceof Node) && !Array.isArray(x) && 'contenido' in x ? x : { contenido: x });
  // role="table/row/cell/columnheader": en el celular la tabla se pinta como bloques (CSS) y sin los
  // roles el lector de pantalla dejaría de anunciarla como tabla.
  return h('div', { class: 'tabla-envoltura' }, h('table', { role: 'table', ...props, class: 'tabla tabla-celular' + (props.class ? ' ' + props.class : '') },
    h('thead', { role: 'rowgroup' }, h('tr', { role: 'row' }, columnas.map((c) => h('th', { scope: 'col', role: 'columnheader', class: c.num ? 'num' : null }, c.titulo)))),
    h('tbody', { role: 'rowgroup' }, filas.map((f, i) => h('tr', { role: 'row', ...(filaProps(i) || {}) }, f.map((x, j) => {
      const c = columnas[j] || {};
      const { contenido, props: p = {} } = celda(x);
      const clase = [c.num ? 'num' : null, j === 0 ? 'celda-principal' : null, c.acciones ? 'celda-acciones' : null, p.class || null].filter(Boolean).join(' ');
      return h('td', { role: 'cell', ...p, class: clase || null, 'data-titulo': c.titulo || null }, contenido);
    }))))));
}

// Encabezado de pantalla: el título (o el saludo) y, al lado, las subpestañas de la pestaña
// (en la computadora, como en el dibujo de Inicio; en el celular quedan arriba, por CSS).
export function cabezaPantalla(ctx, ...izquierda) {
  const nav = ctx && ctx.subpestanas && ctx.subpestanas.children.length ? ctx.subpestanas : null;
  return h('div', { class: 'cabeza-pantalla' }, h('div', { class: 'cabeza-texto' }, ...izquierda), nav);
}

// ---------------- App 0.15.0 ----------------
// Filtros rápidos en botones con su número (idea de RRD: "Agotados", "Bajo mín."): solo CUENTAN, no suman dinero.
// opciones = [{ id, texto, n, color }]; alCambiar(id). Devuelve el elemento (role radiogroup).
export function filtrosRapidos({ opciones, actual, alCambiar, etiqueta = 'Filtrar', id = null }) {
  const caja = h('div', { class: 'filtros-rapidos', role: 'radiogroup', 'aria-label': etiqueta, id });
  const pintar = (sel) => caja.replaceChildren(...opciones.filter((o) => o.siempre || o.n > 0 || o.id === sel).map((o) =>
    h('button', { type: 'button', role: 'radio', class: `filtro-rapido filtro-${o.color || 'neutro'}`, 'aria-checked': o.id === sel ? 'true' : 'false',
      dataset: { filtro: o.id }, onclick: () => { pintar(o.id); alCambiar(o.id); } },
    h('span', {}, o.texto), h('span', { class: 'filtro-numero' }, String(o.n)))));
  pintar(actual);
  return caja;
}
