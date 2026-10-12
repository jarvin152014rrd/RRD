// Arranque de la app: sesión, menú, rutas (#/pestana/subpestana) y aviso "Sin conexión".
import * as api from './api.js';
import { cargarPerfil, olvidarPerfil, perfilActual, vigilarSesion } from './sesion.js';
import { menuDelUsuario, botonesCelular } from './menu.js';
import { olvidarCatalogo } from './errores.js';
import { cargarMarca, aplicarMarca } from './marca.js';
import { h, icono, cajaError, limpiarAvisos } from './ui.js';

const raiz = document.getElementById('app');
const bandaSinConexion = document.getElementById('sin-conexion');
let menu = [];
let saliendo = false;

// ---------------- Sin conexión ----------------
function marcarConexion(hay) { bandaSinConexion.hidden = hay; }
window.addEventListener('online', () => marcarConexion(true));
window.addEventListener('offline', () => marcarConexion(false));
marcarConexion(navigator.onLine);
api.escuchar((tipo, dato) => {
  if (tipo === 'sin-conexion') marcarConexion(false);
  if (tipo === 'con-conexion') marcarConexion(true);
  if (tipo === 'sesion-terminada') forzarSalida(dato && dato.clave === 'SESION_CERRADA'
    ? 'Su sesión fue cerrada por el administrador. Vuelva a entrar.' : 'Su sesión terminó. Vuelva a entrar.');
});

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('sw.js').catch(() => {}));
}

// ---------------- Entrar y salir ----------------
async function iniciar() {
  try {
    if (await api.restaurar()) {
      await cargarPerfil();
      return mostrarApp();
    }
  } catch (err) {
    return mostrarEntrar(err.sinConexion ? { tipo: 'info', texto: 'Sin conexión. Para entrar necesita internet.' } : null);
  }
  mostrarEntrar();
}

async function mostrarEntrar(mensaje = null) {
  window.removeEventListener('hashchange', alCambiarRuta);
  const { mostrar } = await import('./pantallas/entrar.js');
  document.title = 'Entrar · Mi Negocio';
  raiz.replaceChildren();
  mostrar(raiz, {
    mensaje,
    alEntrar: async () => { await cargarPerfil(); mostrarApp(); },
  });
}

async function salir(texto = 'Cerró su sesión.', tipo = 'ok') {
  aplicarMarca({});
  olvidarPerfil();
  olvidarCatalogo();
  await api.salir();
  if (location.hash) history.replaceState(null, '', location.pathname);
  mostrarEntrar({ tipo, texto });
}

function forzarSalida(texto) {
  if (saliendo || !perfilActual()) return;
  saliendo = true;
  salir(texto, 'info').finally(() => { saliendo = false; });
}

// ---------------- Armazón de la app ----------------
let zonas = null; // { pestanas, subpestanas, contenido, barra }

function iniciales(nombre) {
  const p = String(nombre || '').trim().split(/\s+/).filter(Boolean);
  if (p.length === 0) return 'MN';
  return ((p[0][0] || '') + (p.length > 1 ? p[p.length - 1][0] : '')).toUpperCase();
}

function mostrarApp() {
  const perfil = perfilActual();
  menu = menuDelUsuario();
  const nombre = (perfil.usuario && (perfil.usuario.nombre || perfil.usuario.correo)) || '';
  const pestanas = h('nav', { class: 'pestanas', 'aria-label': 'Menú principal' },
    menu.map((p) => h('a', { class: 'pestana' + (p.final ? ' pestana-final' : ''), href: `#/${p.id}/${p.subs[0].id}`,
      dataset: { pestana: p.id } }, p.titulo)));
  const barra = h('nav', { class: 'barra-inferior', 'aria-label': 'Menú del celular' },
    botonesCelular(menu).map((b) => h('a', { class: 'boton-barra', href: b.ruta, dataset: { pestana: b.pestana } },
      icono(b.icono), h('span', {}, b.titulo))));
  const subpestanas = h('nav', { class: 'subpestanas', 'aria-label': 'Subpestañas' });
  const contenido = h('main', { class: 'contenido', id: 'contenido', tabindex: '-1' });
  raiz.replaceChildren(
    h('header', { class: 'encabezado' },
      h('div', { class: 'encabezado-fila' },
        h('div', { class: 'marca' },
          h('div', { class: 'marca-logo', id: 'marca-logo', 'aria-hidden': 'true', dataset: { iniciales: iniciales(perfil.empresa.nombre) } }, iniciales(perfil.empresa.nombre)),
          h('span', { class: 'marca-nombre', id: 'marca-nombre' }, perfil.empresa.nombre)),
        h('div', { class: 'quien' },
          h('span', {}, nombre, h('span', { class: 'rol-texto' }, ' · ', perfil.rol.nombre || perfil.rol.codigo)),
          h('button', { type: 'button', class: 'boton boton-claro', onclick: () => salir() }, 'Salir'))),
      pestanas),
    contenido, barra);
  zonas = { pestanas, subpestanas, contenido, barra };
  cargarMarca(); // nombre comercial, logo y colores (si no hay, quedan los del tema)
  vigilarSesion((motivo) => forzarSalida(motivo));
  window.addEventListener('hashchange', alCambiarRuta);
  alCambiarRuta();
}

// Tocar la pestaña o subpestaña en la que ya está vuelve a empezar esa pantalla
// (por ejemplo, de un comprobante a una venta nueva). Sin cambio de ruta no hay hashchange.
document.addEventListener('click', (ev) => {
  const a = ev.target.closest && ev.target.closest('a.pestana, a.subpestana, a.boton-barra');
  if (a && zonas && a.getAttribute('href') === location.hash) { ev.preventDefault(); alCambiarRuta(); }
});

// ---------------- Rutas ----------------
let rutaAnterior = null;
function alCambiarRuta() {
  if (!zonas) return;
  const [pid, sid] = location.hash.replace(/^#\/?/, '').split('/');
  let pantalla, titulo, actual = pid, sub = null, pestana = null;

  if (pid === 'mas') {
    pantalla = 'mas'; titulo = 'Más';
  } else if (pid === 'buscar') {
    pantalla = 'en_construccion'; titulo = 'Buscar producto';
  } else {
    pestana = menu.find((p) => p.id === pid);
    if (!pestana) { location.replace('#/inicio/hoy'); return; }
    sub = pestana.subs.find((s) => s.id === sid);
    if (!sub) { location.replace(`#/${pestana.id}/${pestana.subs[0].id}`); return; }
    pantalla = sub.pantalla || 'en_construccion'; titulo = sub.titulo;
  }

  for (const a of zonas.pestanas.children) a.toggleAttribute('aria-current', a.dataset.pestana === actual);
  for (const a of zonas.pestanas.children) if (a.hasAttribute('aria-current')) a.setAttribute('aria-current', 'page');
  for (const a of zonas.barra.children) {
    const on = a.dataset.pestana === actual || (a.dataset.pestana === 'mas' && !['inicio', 'vender', 'buscar'].includes(actual));
    if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
  zonas.subpestanas.replaceChildren(...(pestana && pestana.subs.length > 1 ? pestana.subs.map((s) =>
    h('a', { class: 'subpestana', href: `#/${pestana.id}/${s.id}`, 'aria-current': s.id === sub.id ? 'page' : null }, s.titulo)) : []));

  // Avisos viejos fuera al cambiar de pantalla (no al refrescar la misma, p. ej. tras aprobar en Inicio).
  if (location.hash !== rutaAnterior) limpiarAvisos();
  rutaAnterior = location.hash;
  document.title = `${titulo} · ${perfilActual().empresa.nombre}`;
  mostrarPantalla(pantalla, { pestana, sub, titulo, menu });
}

let turno = 0; // evita que una pantalla lenta pinte encima de la siguiente
async function mostrarPantalla(nombre, ctx) {
  const mio = ++turno;
  const lugar = h('div', { class: 'lista' }, h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  zonas.contenido.replaceChildren(...(zonas.subpestanas.children.length ? [zonas.subpestanas] : []), lugar);
  try {
    const mod = await import(`./pantallas/${nombre}.js`);
    if (mio !== turno) return;
    const vista = h('div', { class: 'lista' });
    await mod.mostrar(vista, { ...ctx, sigueVigente: () => mio === turno, salir: () => salir() });
    if (mio !== turno) return;
    lugar.replaceWith(vista);
  } catch (err) {
    if (mio !== turno) return;
    lugar.replaceChildren(await cajaError(err));
  }
}

iniciar();
