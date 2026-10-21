// Arranque de la app: sesión, menú, rutas (#/pestana/subpestana) y aviso "Sin conexión".
import * as api from './api.js';
import { cargarPerfil, olvidarPerfil, perfilActual, vigilarSesion, empresaId, puede } from './sesion.js';
import { menuDelUsuario, botonesCelular, RUTAS_VIEJAS } from './menu.js';
import { olvidarCatalogo } from './errores.js';
import { cargarMarca, aplicarMarca, iniciales } from './marca.js';
import { h, icono, chip, cajaError, limpiarAvisos } from './ui.js';
import { vigilarImpresion } from './imprimible.js';
import { olvidarDatos, reiniciarTodo } from './datos.js';
import { comaInvalida, MENSAJE_COMA } from './formato.js';

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

// Al imprimir, el título de la hoja va sin emojis (palabras del rubro o nombre del negocio).
vigilarImpresion();

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
  reiniciarTodo(); // filtros de las pantallas (fechas, proveedor, banco...) vuelven a los de siempre
  olvidarDatos(); // listas en memoria (productos, cuentas, alcance...): el próximo usuario no ve las del anterior
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

function mostrarApp() {
  const perfil = perfilActual();
  menu = menuDelUsuario();
  const nombre = (perfil.usuario && (perfil.usuario.nombre || perfil.usuario.correo)) || '';
  const pestanas = h('nav', { class: 'pestanas', 'aria-label': 'Menú principal' },
    menu.map((p) => h('a', { class: 'pestana' + (p.final ? ' pestana-final' : ''), href: `#/${p.id}/${p.subs[0].id}`,
      dataset: { pestana: p.id } }, icono(p.icono), h('span', {}, p.titulo))));
  const barra = h('nav', { class: 'barra-inferior', 'aria-label': 'Menú del celular' },
    botonesCelular(menu).map((b) => h('a', { class: 'boton-barra', href: b.ruta, dataset: { pestana: b.pestana } },
      icono(b.icono), h('span', {}, b.titulo))));
  // Campanita: número de pendientes (alertas + aprobaciones); lleva a Inicio > Pendientes.
  const campana = h('a', { class: 'campana', href: '#/inicio/pendientes', id: 'campana', 'aria-label': 'Pendientes' },
    icono('campana'), h('span', { class: 'campana-numero', id: 'campana-numero', hidden: true }, '0'));
  const subpestanas = h('nav', { class: 'subpestanas', 'aria-label': 'Subpestañas' });
  const contenido = h('main', { class: 'contenido', id: 'contenido', tabindex: '-1' });
  raiz.replaceChildren(
    h('header', { class: 'encabezado' },
      h('div', { class: 'encabezado-fila' },
        h('div', { class: 'marca' },
          h('div', { class: 'marca-logo', id: 'marca-logo', 'aria-hidden': 'true', dataset: { iniciales: iniciales(perfil.empresa.nombre) } }, iniciales(perfil.empresa.nombre)),
          h('span', { class: 'marca-nombre', id: 'marca-nombre' }, perfil.empresa.nombre)),
        h('div', { class: 'quien' }, campana,
          h('span', {}, nombre, h('span', { class: 'rol-texto' }, ' · ', perfil.rol.nombre || perfil.rol.codigo)),
          h('button', { type: 'button', class: 'boton boton-claro', onclick: () => salir() }, 'Salir'))),
      pestanas),
    contenido, barra);
  zonas = { pestanas, subpestanas, contenido, barra, campana };
  numeroPendientes = 0;
  cargarMarca(); // nombre comercial, logo y colores (si no hay, quedan los del tema)
  contarPendientes();
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

// Campos de dinero o cantidad (inputmode="decimal"): una coma que no es de miles ("150,50") no se acepta;
// se avisa debajo del campo, en todas las pantallas, con el mismo texto (app 0.7.1).
document.addEventListener('input', (ev) => {
  const el = ev.target;
  if (!(el instanceof HTMLInputElement) || el.getAttribute('inputmode') !== 'decimal') return;
  const mal = comaInvalida(el.value);
  let nota = el.nextElementSibling && el.nextElementSibling.classList.contains('aviso-coma') ? el.nextElementSibling : null;
  if (mal && !nota) { nota = h('p', { class: 'ayuda aviso-coma texto-rojo', role: 'alert' }, MENSAJE_COMA); el.after(nota); }
  if (!mal && nota) nota.remove();
  el.setAttribute('aria-invalid', mal ? 'true' : 'false');
});

// ---------------- Pendientes (campanita y subpestaña) ----------------
// Las pantallas avisan con eventos: "pendientes-conteo" (ya contaron) o "pendientes-cambiaron"
// (aprobaron o rechazaron algo: hay que volver a contar). Sin internet se deja el número de antes.
let numeroPendientes = 0;
function ponerPendientes(n) {
  if (!zonas || !Number.isFinite(n)) return;
  numeroPendientes = n;
  const num = document.getElementById('campana-numero');
  if (num) { num.textContent = String(n); num.hidden = n === 0; }
  zonas.campana.setAttribute('aria-label', n ? `Pendientes: ${n}` : 'Pendientes: ninguno');
  for (const c of document.querySelectorAll('[data-contador=pendientes]')) { c.textContent = String(n); c.hidden = n === 0; }
}
async function contarPendientes() {
  const e = empresaId();
  if (!e) return;
  const [alertas, aprob] = await Promise.all([
    api.rpc('alertas_activas', { p_empresa_id: e }).then((r) => ((r && r.alertas) || [])
      .filter((a) => !(puede('aprobaciones.ver') && a.tipo === 'aprobaciones')).length).catch(() => null),
    puede('aprobaciones.ver') ? api.leer('v_aprobacion', { empresa_id: e, estado: 'pendiente' }, { limite: 100 }).then((x) => x.length).catch(() => null) : 0,
  ]);
  if (alertas === null || aprob === null) return;
  ponerPendientes(alertas + aprob);
}
window.addEventListener('pendientes-cambiaron', () => contarPendientes());
window.addEventListener('pendientes-conteo', (ev) => ponerPendientes(Number(ev.detail)));

// ---------------- Rutas ----------------
let rutaAnterior = null;
function alCambiarRuta() {
  if (!zonas) return;
  const ruta = location.hash.replace(/^#\/?/, '');
  // Rutas de antes (ej. #/inventario/excel) -> la nueva, sin dejar la vieja en el historial.
  if (Object.prototype.hasOwnProperty.call(RUTAS_VIEJAS, ruta)) { location.replace('#/' + RUTAS_VIEJAS[ruta]); return; }
  const [pid, sid] = ruta.split('/');
  let pantalla, titulo, actual = pid, sub = null, pestana = null;

  if (pid === 'mas') {
    pantalla = 'mas'; titulo = 'Más';
  } else {
    pestana = menu.find((p) => p.id === pid);
    if (!pestana) { location.replace('#/inicio/hoy'); return; }
    sub = pestana.subs.find((s) => s.id === sid);
    if (!sub) { location.replace(`#/${pestana.id}/${pestana.subs[0].id}`); return; }
    pantalla = sub.pantalla || 'en_construccion'; titulo = sub.titulo;
  }

  for (const a of zonas.pestanas.children) a.toggleAttribute('aria-current', a.dataset.pestana === actual);
  for (const a of zonas.pestanas.children) if (a.hasAttribute('aria-current')) a.setAttribute('aria-current', 'page');
  const enBarra = [...zonas.barra.children].map((a) => a.dataset.pestana);
  for (const a of zonas.barra.children) {
    const on = a.dataset.pestana === actual || (a.dataset.pestana === 'mas' && !enBarra.includes(actual));
    if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
  zonas.subpestanas.replaceChildren(...(pestana && pestana.subs.length > 1 ? pestana.subs.map((s) =>
    h('a', { class: 'subpestana', href: `#/${pestana.id}/${s.id}`, 'aria-current': s.id === sub.id ? 'page' : null },
      icono(s.icono), h('span', {}, s.titulo),
      s.contador ? chip(String(numeroPendientes), 'dorado', { dataset: { contador: s.contador }, hidden: numeroPendientes === 0 }) : null)) : []));

  // Avisos viejos fuera al cambiar de pantalla (no al refrescar la misma, p. ej. tras aprobar en Inicio).
  if (location.hash !== rutaAnterior) limpiarAvisos();
  rutaAnterior = location.hash;
  document.title = `${titulo} · ${perfilActual().empresa.nombre}`;
  // subpestanas: las pantallas que quieren (Inicio) las ponen al lado de su título (ui.cabezaPantalla).
  mostrarPantalla(pantalla, { pestana, sub, titulo, menu, subpestanas: zonas.subpestanas });
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
