// Modo oscuro (app 0.15.0). Se guarda en ESTE equipo (cada persona elige en su equipo); si nunca eligió,
// sigue al equipo (modo oscuro del sistema). Solo pone <html data-tema="oscuro|claro">: los colores están en
// css/tema.css. Lo impreso no cambia nunca (comprobantes y reportes en blanco y negro).
const LLAVE = 'tema-pantalla';
const oyentes = new Set();

function elegido() {
  try { const x = localStorage.getItem(LLAVE); return x === 'oscuro' || x === 'claro' ? x : null; } catch { return null; }
}
function delSistema() {
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'oscuro' : 'claro';
}
export function temaActual() { return elegido() || delSistema(); }

export function aplicarTema(t = temaActual()) {
  document.documentElement.dataset.tema = t;
  for (const fn of oyentes) fn(t);
}

export function cambiarTema() {
  const nuevo = temaActual() === 'oscuro' ? 'claro' : 'oscuro';
  try { localStorage.setItem(LLAVE, nuevo); } catch { /* sin almacenamiento: dura hasta recargar */ }
  aplicarTema(nuevo);
  return nuevo;
}

export function alCambiarTema(fn) { oyentes.add(fn); return () => oyentes.delete(fn); }

// Si la persona nunca eligió, el modo sigue al del equipo aunque cambie con la app abierta.
if (window.matchMedia) {
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const seguir = () => { if (!elegido()) aplicarTema(); };
  if (mq.addEventListener) mq.addEventListener('change', seguir);
}
aplicarTema();
