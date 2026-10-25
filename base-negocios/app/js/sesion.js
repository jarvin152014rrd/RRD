// Perfil del usuario (mi_perfil) en MEMORIA: permisos, módulos, empresa y rol.
// No se guarda en el navegador; se vuelve a pedir al servidor cada vez que se entra.
// El servidor siempre vuelve a revisar los permisos: esto solo arma el menú.
import { rpc, leer, config } from './api.js';
import { configurarFormato } from './formato.js';

let perfil = null;
let permisos = new Set();
let modulos = new Set();
let reloj = null;
const LLAVE_EMPRESA = 'negocio.empresa';

export function perfilActual() { return perfil; }
export function empresaId() { return perfil && perfil.empresa ? perfil.empresa.id : null; }
export function puede(...lista) { return lista.some((p) => permisos.has(p)); }
export function tieneModulo(...lista) { return lista.some((m) => modulos.has(m)); }

export async function cargarPerfil() {
  const general = await rpc('mi_perfil', {});
  const empresas = general.empresas || [];
  if (empresas.length === 0) {
    const e = new Error('Su usuario no tiene un negocio asignado.');
    e.clave = 'NO_PERTENECE';
    throw e;
  }
  let elegida = null;
  try { elegida = localStorage.getItem(LLAVE_EMPRESA); } catch { /* nada */ }
  const id = (empresas.find((x) => x.id === elegida) || empresas[0]).id;
  const [p, version] = await Promise.all([rpc('mi_perfil', { p_empresa_id: id }),
    // Versión del núcleo (app 0.12.0): lo nuevo del menú se oculta con un núcleo anterior.
    leer('version_esquema', {}, { limite: 1 }).then((x) => String((x && x[0] && x[0].version_nucleo) || '')).catch(() => '')]);
  perfil = p;
  perfil.version_nucleo = version;
  permisos = new Set(perfil.permisos || []);
  modulos = new Set(perfil.modulos || []);
  configurarFormato(perfil.empresa || {});
  return perfil;
}

export function olvidarPerfil() {
  perfil = null; permisos = new Set(); modulos = new Set();
  detenerVigilancia();
}

// Revisa cada N segundos si la sesión sigue viva (cerrada a distancia, usuario
// desactivado o fuera de horario). alSalir(motivo) saca al usuario.
export function vigilarSesion(alSalir) {
  detenerVigilancia();
  const cada = Math.max(2, Number(config.revisarSesionSegundos) || 60) * 1000;
  const revisar = async () => {
    if (!empresaId()) return;
    try {
      const e = await rpc('mi_estado_sesion', { p_empresa_id: empresaId() });
      if (!e) return;
      if (e.activo === false) alSalir(e.motivo || 'Su usuario fue desactivado.');
      else if (e.debe_salir) alSalir('Su sesión fue cerrada por el administrador. Vuelva a entrar.');
      else if (e.dentro_de_horario === false) alSalir('Su puesto no tiene acceso a esta hora.');
    } catch (err) {
      if (err.clave === 'SESION_CERRADA' || err.clave === 'SIN_SESION') alSalir('Su sesión terminó. Vuelva a entrar.');
      // sin internet u otro error: se intenta en la próxima vuelta
    }
  };
  reloj = setInterval(revisar, cada);
  document.addEventListener('visibilitychange', alVolver);
  function alVolver() { if (document.visibilityState === 'visible') revisar(); }
  detenerVigilancia.quitar = () => document.removeEventListener('visibilitychange', alVolver);
}

function detenerVigilancia() {
  if (reloj) clearInterval(reloj);
  reloj = null;
  if (detenerVigilancia.quitar) detenerVigilancia.quitar();
  detenerVigilancia.quitar = null;
}
