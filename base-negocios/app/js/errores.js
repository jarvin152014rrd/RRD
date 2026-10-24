// Traduce errores del servidor a palabras sencillas con el catálogo de errores
// (tabla error_catalogo: mensaje_usuario + que_hacer). Nunca muestra el código crudo.
import { leer } from './api.js';

let catalogo = null; // Map clave -> fila (se carga una vez por sesión)

const PROPIOS = {
  CLAVE_INCORRECTA: { mensaje_usuario: 'Correo o contraseña incorrectos.', que_hacer: 'Revise que estén bien escritos e intente otra vez.' },
};

async function cargar() {
  if (catalogo) return catalogo;
  try {
    const filas = await leer('error_catalogo', {}, { limite: 1000 });
    catalogo = new Map(filas.map((f) => [f.codigo, f]));
  } catch {
    return new Map(); // sin catálogo: se usa el texto del servidor
  }
  return catalogo;
}

export function olvidarCatalogo() { catalogo = null; }

// -> { mensaje, queHacer }
export async function traducir(err) {
  if (!err) return { mensaje: 'Algo salió mal.', queHacer: 'Intente otra vez.' };
  // Error armado en la app (ej. fotos: "pesa más de 10 MB", "necesita internet"): su texto ya es sencillo.
  if (err.local) return { mensaje: String(err.message || 'Algo salió mal.'), queHacer: err.queHacer || '' };
  if (err.sinConexion) {
    return { mensaje: 'No hay conexión a internet.', queHacer: 'Revise su conexión y vuelva a intentar. No se guardó nada.' };
  }
  if (err.clave && PROPIOS[err.clave]) {
    return { mensaje: PROPIOS[err.clave].mensaje_usuario, queHacer: PROPIOS[err.clave].que_hacer };
  }
  if (err.sqlstate === '42501') {
    return { mensaje: 'No tiene permiso para hacer esto.', queHacer: 'Si lo necesita, pídalo al dueño del negocio.' };
  }
  const texto = String(err.message || '');
  if (err.clave) {
    const fila = (await cargar()).get(err.clave);
    if (fila) return { mensaje: fila.mensaje_usuario, queHacer: fila.que_hacer || '', detalle: texto.slice(err.clave.length + 1).trim() };
    return { mensaje: texto.slice(err.clave.length + 1).trim() || 'El servidor no pudo hacer la operación.', queHacer: '' };
  }
  return { mensaje: texto && !/^[0-9A-Z]{5}$/.test(texto) ? texto : 'El servidor no pudo hacer la operación.', queHacer: 'Intente otra vez en un momento.' };
}
