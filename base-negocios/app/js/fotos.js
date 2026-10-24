// Fotos de productos (app 0.11.0, núcleo 0.17.0).
// - Solo si la empresa las tiene encendidas (mi_perfil -> empresa.fotos_productos). Con un núcleo sin la 053 la
//   clave no viene y no se ve nada de fotos.
// - Antes de subir, la foto se REDUCE en el navegador (canvas): una mediana de unos 600 px (~40 KB) y una
//   miniatura de unos 120 px (~8 KB), en WEBP (o JPEG si el navegador no sabe hacer WEBP). Se rechaza lo que no
//   es imagen, los SVG (pueden llevar código) y lo que pesa más de 10 MB.
// - Se sube al bucket PRIVADO "fotos-productos" (<empresa>/<producto>/<huella>.webp) con el token del usuario y
//   después el núcleo guarda la ruta (poner_foto_producto). Las políticas de la base deciden quién sube y quién ve.
// - Para mostrarla: descarga con el token y la guarda en la caché del navegador ("fotos-<empresa>"): una foto ya
//   vista no se vuelve a bajar y se ve sin internet. Al salir se borra esa caché.
// - Nunca innerHTML: <img> con src = blob: (URL.createObjectURL). Lo impreso no lleva fotos.
import { subirArchivo, bajarArchivo, borrarArchivo, escribir, ErrorServidor } from './api.js';
import { perfilActual, empresaId } from './sesion.js';
import { h, burbuja } from './ui.js';

export const BUCKET = 'fotos-productos';
export const MAX_ORIGINAL = 10 * 1024 * 1024;          // 10 MB antes de reducir
const LADO_MEDIANA = 600;
const LADO_MINI = 120;
const META_MEDIANA = 60 * 1024;                         // se busca ~40 KB; nunca más de 60 KB si se puede
const META_MINI = 12 * 1024;                            // ~8 KB
const PREFIJO_CACHE = 'fotos-';
const TIPO_SEGURO = /^image\/(webp|jpeg)(;|$)/i;        // lo único que se muestra (nunca SVG ni HTML)

// Error de la app con texto sencillo (errores.js lo muestra tal cual).
function errorLocal(texto, { clave = 'FOTO_INVALIDA', queHacer = '', sinConexion = false, http = 0 } = {}) {
  const e = new ErrorServidor(texto, { clave, sinConexion, http });
  e.local = true;
  e.queHacer = queHacer;
  return e;
}

// ¿Se muestran fotos? (empresa con fotos encendidas y núcleo 0.17.0 o más nuevo)
export function fotosActivas() {
  const p = perfilActual();
  return Boolean(p && p.empresa && p.empresa.fotos_productos === true);
}
// ¿El núcleo ya sabe de fotos? (0.17.0: mi_perfil trae empresa.fotos_productos)
export function nucleoConFotos() {
  const p = perfilActual();
  return Boolean(p && p.empresa && Object.prototype.hasOwnProperty.call(p.empresa, 'fotos_productos'));
}

// ---------------- Revisar y reducir ----------------
// null si el archivo sirve; si no, el texto del problema.
export function revisarArchivo(archivo) {
  if (!archivo) return 'Elija una foto.';
  const tipo = String(archivo.type || '').toLowerCase();
  const nombre = String(archivo.name || '').toLowerCase();
  if (tipo.includes('svg') || nombre.endsWith('.svg') || nombre.endsWith('.svgz')) return 'No se aceptan dibujos SVG. Use una foto (JPG, PNG o WEBP).';
  if (!tipo.startsWith('image/')) return 'Ese archivo no es una foto. Use una foto JPG, PNG o WEBP.';
  if (!archivo.size) return 'El archivo está vacío.';
  if (archivo.size > MAX_ORIGINAL) return 'La foto pesa más de 10 MB. Tome otra o elija una más liviana.';
  return null;
}

async function decodificar(archivo) {
  // createImageBitmap respeta la orientación de la cámara (EXIF). Si no existe, una <img> con blob:.
  if (window.createImageBitmap) {
    try { return await createImageBitmap(archivo, { imageOrientation: 'from-image' }); } catch { /* se prueba con <img> */ }
  }
  const url = URL.createObjectURL(archivo);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img;
  } catch {
    throw errorLocal('No se pudo leer la foto. Use una foto JPG, PNG o WEBP.');
  } finally {
    URL.revokeObjectURL(url);
  }
}

function dibujar(fuente, lado) {
  const ancho = fuente.width || fuente.naturalWidth;
  const alto = fuente.height || fuente.naturalHeight;
  if (!ancho || !alto) throw errorLocal('No se pudo leer la foto.');
  const escala = Math.min(1, lado / Math.max(ancho, alto));   // nunca se agranda
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(ancho * escala));
  c.height = Math.max(1, Math.round(alto * escala));
  const ctx = c.getContext('2d');
  ctx.fillStyle = '#ffffff';                                    // fondo blanco (PNG transparente -> JPEG)
  ctx.fillRect(0, 0, c.width, c.height);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(fuente, 0, 0, c.width, c.height);
  return c;
}

const aBlob = (canvas, tipo, calidad) => new Promise((ok) => canvas.toBlob((b) => ok(b), tipo, calidad));

// Prueba calidades de mayor a menor hasta quedar bajo la meta (la más chica si ninguna llega).
async function codificar(canvas, tipos, meta) {
  for (const tipo of tipos) {
    let mejor = null;
    for (const q of [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]) {
      const b = await aBlob(canvas, tipo, q);
      if (!b || b.type !== tipo) break;                     // el navegador no sabe hacer este tipo
      if (!mejor || b.size < mejor.size) mejor = b;
      if (b.size <= meta) return b;
    }
    if (mejor) return mejor;
  }
  throw errorLocal('Este navegador no pudo preparar la foto. Pruebe con otro navegador (Chrome o Safari al día).');
}

// -> { mediana: Blob, mini: Blob, ext: 'webp' | 'jpg', ancho, alto }
export async function reducirFoto(archivo) {
  const problema = revisarArchivo(archivo);
  if (problema) throw errorLocal(problema);
  const fuente = await decodificar(archivo);
  const lienzo = dibujar(fuente, LADO_MEDIANA);
  if (fuente.close) fuente.close();
  const mediana = await codificar(lienzo, ['image/webp', 'image/jpeg'], META_MEDIANA);
  // La miniatura sale de la mediana (mejor calidad que achicar de golpe la foto original), del mismo tipo.
  const mini = await codificar(dibujar(lienzo, LADO_MINI), [mediana.type], META_MINI);
  return { mediana, mini, ext: mediana.type === 'image/webp' ? 'webp' : 'jpg', ancho: lienzo.width, alto: lienzo.height };
}

async function huella(blob) {
  const datos = await blob.arrayBuffer();
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', datos));
  return [...d].map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 32);
}

// ---------------- Subir, poner y quitar ----------------
function sinInternet() {
  return errorLocal('Subir una foto necesita internet.', { clave: 'SIN_INTERNET', sinConexion: true,
    queHacer: 'Conéctese y vuelva a intentar. No se cambió nada.' });
}

// Reduce, sube las dos imágenes y guarda la ruta en el producto. -> respuesta de poner_foto_producto + tamaños.
export async function subirFotoProducto(producto, archivo) {
  if (navigator.onLine === false) throw sinInternet();
  const r = await reducirFoto(archivo);
  const e = empresaId();
  const base = `${e}/${producto.producto_id}/${await huella(r.mediana)}`;
  const ruta = `${base}.${r.ext}`;
  const mini = `${base}_mini.${r.ext}`;
  const creados = [];
  try {
    for (const [nombre, blob] of [[ruta, r.mediana], [mini, r.mini]]) {
      const s = await subirArchivo(BUCKET, nombre, blob);
      if (s.creado) creados.push(nombre);
    }
    const res = await escribir('poner_foto_producto', { p_empresa_id: e, p_producto_id: producto.producto_id, p_foto: { ruta, miniatura: mini } });
    await guardarCache(ruta, r.mediana);
    await guardarCache(mini, r.mini);
    return { ...res, bytes_mediana: r.mediana.size, bytes_mini: r.mini.size, ancho: r.ancho, alto: r.alto };
  } catch (err) {
    // No quedó puesta: se borran los archivos que ESTA vez se subieron (los de antes pueden estar en el historial).
    for (const nombre of creados) borrarArchivo(BUCKET, nombre).catch(() => {});
    if (err.sinConexion) throw sinInternet();
    if (err.clave === 'SIN_PERMISO' && !err.sqlstate) {
      throw errorLocal('Su usuario no puede subir fotos de productos (o las fotos están apagadas).', { clave: 'SIN_PERMISO', http: err.http,
        queHacer: 'Pídale al dueño el permiso de editar productos.' });
    }
    throw err;
  }
}

export function quitarFotoProducto(producto) {
  if (navigator.onLine === false) {
    throw errorLocal('Quitar la foto necesita internet.', { clave: 'SIN_INTERNET', sinConexion: true, queHacer: 'Conéctese y vuelva a intentar.' });
  }
  return escribir('poner_foto_producto', { p_empresa_id: empresaId(), p_producto_id: producto.producto_id, p_foto: null });
}

// ---------------- Mostrar (con caché) ----------------
const memoria = new Map();   // ruta -> Promise<objectURL | null>
const nombreCache = () => PREFIJO_CACHE + (empresaId() || 'sin-empresa');
// Llave de la caché: una dirección que nunca se pide a la red (solo identifica la foto).
const llave = (ruta) => new URL('__fotos__/' + ruta, location.href).href;

async function abrirCache() {
  if (!('caches' in window)) return null;
  try { return await caches.open(nombreCache()); } catch { return null; }
}
async function guardarCache(ruta, blob) {
  const c = await abrirCache();
  if (!c) return;
  try { await c.put(llave(ruta), new Response(blob, { headers: { 'Content-Type': blob.type } })); } catch { /* sin espacio: se baja otra vez */ }
}
async function leerCache(ruta) {
  const c = await abrirCache();
  if (!c) return null;
  try { const r = await c.match(llave(ruta)); return r ? await r.blob() : null; } catch { return null; }
}

// Dirección local (blob:) de la foto, o null si no se pudo (sin internet y sin caché, o sin permiso).
export function urlFoto(ruta) {
  if (!ruta) return Promise.resolve(null);
  if (!memoria.has(ruta)) {
    memoria.set(ruta, (async () => {
      let blob = await leerCache(ruta);
      if (!blob) {
        blob = await bajarArchivo(BUCKET, ruta);
        if (!TIPO_SEGURO.test(blob.type || '')) return null;
        await guardarCache(ruta, blob);
      }
      if (!TIPO_SEGURO.test(blob.type || '')) return null;
      return URL.createObjectURL(blob);
    })().catch(() => { memoria.delete(ruta); return null; }));
  }
  return memoria.get(ruta);
}

// Carga perezosa: la foto se pide cuando su burbuja está por verse en la pantalla.
let observador = null;
const pendientes = new WeakMap();
function cuandoSeVea(el, cargar) {
  if (!('IntersectionObserver' in window)) { cargar(); return; }
  if (!observador) {
    observador = new IntersectionObserver((entradas) => {
      for (const en of entradas) {
        if (!en.isIntersecting) continue;
        observador.unobserve(en.target);
        const f = pendientes.get(en.target);
        pendientes.delete(en.target);
        if (f) f();
      }
    }, { rootMargin: '200px' });
  }
  pendientes.set(el, cargar);
  observador.observe(el);
}

function ponerImagen(contenedor, img, ruta) {
  cuandoSeVea(contenedor, async () => {
    const u = await urlFoto(ruta);
    if (!u) return;                                          // queda el ícono
    img.addEventListener('load', () => contenedor.classList.add('con-foto'), { once: true });
    img.src = u;
  });
}

// Burbuja del producto: la miniatura si hay foto (y fotos encendidas); si no, el ícono de siempre.
// p: fila de v_producto (o { foto_miniatura_ruta }).
export function miniatura(p, { icono = 'etiqueta', color = 'neutro', props = {} } = {}) {
  const b = burbuja(icono, color, { ...props, class: 'burbuja-foto' + (props.class ? ' ' + props.class : '') });
  const ruta = p && p.foto_miniatura_ruta;
  if (!fotosActivas() || !ruta) return b;
  // Sin "hidden": una imagen perezosa que no se dibuja nunca carga. Se ve transparente hasta que carga (css).
  const img = h('img', { class: 'foto-producto', alt: '', loading: 'lazy', decoding: 'async', width: 120, height: 120,
    dataset: { foto: 'mini' } });
  b.dataset.conFoto = '1';
  b.append(img);
  ponerImagen(b, img, ruta);
  return b;
}

// Foto mediana para la ficha del producto (null si no hay o están apagadas).
export function fotoGrande(p) {
  if (!fotosActivas() || !p || !p.foto_ruta) return null;
  const img = h('img', { class: 'foto-ficha-img', alt: `Foto de ${p.nombre}`, loading: 'lazy', decoding: 'async',
    dataset: { foto: 'mediana' } });
  const caja = h('figure', { class: 'foto-ficha', id: 'foto-ficha' }, img);
  cuandoSeVea(caja, async () => {
    const u = await urlFoto(p.foto_ruta);
    if (!u) { caja.append(h('figcaption', { class: 'ayuda' }, navigator.onLine === false ? 'La foto se verá cuando tenga internet.' : 'No se pudo cargar la foto.')); return; }
    img.addEventListener('load', () => caja.classList.add('con-foto'), { once: true });
    img.src = u;
  });
  return caja;
}

// Mapa producto_id -> fila (para pantallas que solo traen el id: Inicio, Existencias).
export function porProducto(lista) {
  return new Map((lista || []).map((p) => [p.producto_id, p]));
}

// ---------------- Al entrar y al salir ----------------
// Al entrar: se borran las cachés de fotos de OTRAS empresas (este equipo pudo usarse con otro negocio).
export async function prepararFotos() {
  if (!('caches' in window)) return;
  try {
    const mia = nombreCache();
    for (const k of await caches.keys()) if (k.startsWith(PREFIJO_CACHE) && k !== mia) await caches.delete(k);
  } catch { /* nada */ }
}

// Al salir: se olvidan las fotos en memoria y se borra su caché (el siguiente usuario no las hereda).
export async function olvidarFotos() {
  for (const p of memoria.values()) p.then((u) => { if (u) URL.revokeObjectURL(u); }).catch(() => {});
  memoria.clear();
  if (!('caches' in window)) return;
  try {
    for (const k of await caches.keys()) if (k.startsWith(PREFIJO_CACHE)) await caches.delete(k);
  } catch { /* nada */ }
}
