// Cliente de datos mínimo, compatible con Supabase:
//   POST {url}/auth/v1/token   (entrar y renovar)     POST {url}/auth/v1/logout
//   POST {url}/rest/v1/rpc/<funcion>                   GET  {url}/rest/v1/<vista>?col=eq.valor
// La app SOLO llama funciones (RPC) para escribir; nunca escribe tablas directo.
// La sesión (tokens) vive en memoria; solo el token de renovación se guarda en el
// navegador (como hace Supabase) para no pedir la clave cada vez que se abre.
import config from '../config.js';

const URL_BASE = String(config.supabaseUrl || '').replace(/\/$/, '');
const CLAVE_ANON = config.supabaseAnonKey;
const LLAVE_GUARDADA = 'negocio.renovar';

let sesion = null;          // { access_token, refresh_token, expires_at, user }
let renovando = null;       // promesa en curso (una sola renovación a la vez)
const oyentes = new Set();  // avisos: 'sin-conexion', 'con-conexion', 'sesion-terminada'

export function escuchar(fn) { oyentes.add(fn); return () => oyentes.delete(fn); }
function avisar(tipo, dato) { for (const fn of oyentes) { try { fn(tipo, dato); } catch (e) { console.error(e); } } }

// Error que entiende la pantalla: clave del catálogo, texto del servidor y si fue por falta de internet.
export class ErrorServidor extends Error {
  constructor(mensaje, { clave = null, sqlstate = null, http = 0, sinConexion = false } = {}) {
    super(mensaje);
    this.clave = clave; this.sqlstate = sqlstate; this.http = http; this.sinConexion = sinConexion;
  }
}

function guardarRenovacion(token) {
  try { token ? localStorage.setItem(LLAVE_GUARDADA, token) : localStorage.removeItem(LLAVE_GUARDADA); } catch { /* sin almacenamiento */ }
}
function leerRenovacion() {
  try { return localStorage.getItem(LLAVE_GUARDADA); } catch { return null; }
}

// tiempo (ms, opcional): si el servidor no contesta en ese tiempo se corta y cuenta como "sin conexión"
// (app 0.14.0: la cola de ventas sin internet usa unos 10 s por llamada).
async function pedir(ruta, opciones, tiempo = 0) {
  let r;
  const corte = tiempo > 0 && typeof AbortController !== 'undefined' ? new AbortController() : null;
  const reloj = corte ? setTimeout(() => corte.abort(), tiempo) : null;
  try {
    r = await fetch(URL_BASE + ruta, corte ? { ...opciones, signal: corte.signal } : opciones);
  } catch {
    avisar('sin-conexion');
    throw new ErrorServidor(corte && corte.signal.aborted ? 'El servidor no contestó a tiempo.' : 'No hay conexión con el servidor.',
      { sinConexion: true });
  } finally {
    if (reloj) clearTimeout(reloj);
  }
  avisar('con-conexion');
  return r;
}

function tomarSesion(datos) {
  sesion = { access_token: datos.access_token, refresh_token: datos.refresh_token,
    expires_at: datos.expires_at || (Date.now() / 1000 + (datos.expires_in || 3600)), user: datos.user };
  guardarRenovacion(sesion.refresh_token);
  return sesion;
}

export function usuarioActual() { return sesion ? sesion.user : null; }

export async function entrar(correo, clave) {
  const r = await pedir('/auth/v1/token?grant_type=password', {
    method: 'POST', headers: { apikey: CLAVE_ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: correo, password: clave }),
  });
  const datos = await r.json().catch(() => ({}));
  if (!r.ok) {
    throw new ErrorServidor('Correo o contraseña incorrectos.', { clave: 'CLAVE_INCORRECTA', http: r.status });
  }
  return tomarSesion(datos);
}

// Vuelve a entrar con el token de renovación guardado (al abrir la app). false si no hay.
export async function restaurar() {
  const token = leerRenovacion();
  if (!token) return false;
  try {
    await renovar(token);
    return true;
  } catch (e) {
    if (!e.sinConexion) guardarRenovacion(null);
    throw e;
  }
}

async function renovar(token = sesion && sesion.refresh_token) {
  if (!token) throw new ErrorServidor('Sesión vencida.', { clave: 'SIN_SESION' });
  if (!renovando) {
    renovando = (async () => {
      const r = await pedir('/auth/v1/token?grant_type=refresh_token', {
        method: 'POST', headers: { apikey: CLAVE_ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: token }),
      });
      if (!r.ok) {
        sesion = null; guardarRenovacion(null);
        throw new ErrorServidor('Su sesión terminó; vuelva a entrar.', { clave: 'SIN_SESION', http: r.status });
      }
      return tomarSesion(await r.json());
    })().finally(() => { renovando = null; });
  }
  return renovando;
}

export async function salir() {
  const s = sesion;
  sesion = null;
  guardarRenovacion(null);
  if (s) {
    try {
      await fetch(URL_BASE + '/auth/v1/logout', { method: 'POST',
        headers: { apikey: CLAVE_ANON, Authorization: 'Bearer ' + s.access_token } });
    } catch { /* sin internet: el token igual se borró de aquí */ }
  }
}

// Pide con el token de la sesión (lo renueva si está por vencer o si el servidor dice 401). Devuelve la respuesta cruda.
async function pedirConToken(ruta, opciones, reintento = true, tiempo = 0) {
  if (!sesion) throw new ErrorServidor('Debe iniciar sesión.', { clave: 'SIN_SESION' });
  if (sesion.expires_at - 30 < Date.now() / 1000) await renovar();
  const r = await pedir(ruta, { ...opciones, headers: { ...opciones.headers, apikey: CLAVE_ANON,
    Authorization: 'Bearer ' + sesion.access_token } }, tiempo);
  if (r.status === 401 && reintento) {
    await renovar();
    return pedirConToken(ruta, opciones, false, tiempo);
  }
  return r;
}

async function conToken(ruta, opciones, tiempo = 0) {
  const r = await pedirConToken(ruta, opciones, true, tiempo);
  const texto = await r.text();
  let datos = null;
  try { datos = texto ? JSON.parse(texto) : null; } catch { datos = texto; }
  if (!r.ok) {
    const mensaje = (datos && datos.message) || 'El servidor no pudo hacer la operación.';
    const m = /^([A-Z][A-Z0-9_]{2,}):/.exec(mensaje);
    const err = new ErrorServidor(mensaje, { clave: m ? m[1] : null, sqlstate: datos && datos.code, http: r.status });
    if (err.clave === 'SESION_CERRADA' || err.clave === 'SIN_SESION') avisar('sesion-terminada', err);
    throw err;
  }
  return datos;
}

// Llama una función de lectura. { tiempo }: corte en ms (sin respuesta = sin conexión).
export function rpc(funcion, args = {}, { tiempo = 0 } = {}) {
  return conToken('/rest/v1/rpc/' + encodeURIComponent(funcion), {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(args),
  }, tiempo);
}

// ¿Hay sesión en memoria? (app 0.14.0: en "modo sin internet" la app abre sin sesión del servidor)
export function haySesion() { return Boolean(sesion); }
// ¿Hay un token de renovación guardado? (para volver a entrar solo al volver el internet)
export function hayRenovacion() { return Boolean(leerRenovacion()); }

// Lectura que solo existe en un núcleo más nuevo (app 0.9.0: totales de 0.16.0). Si el servidor no tiene
// esa función (núcleo viejo: PostgREST responde 404 / PGRST202) devuelve null y la pantalla usa el método
// de antes. Se recuerda en memoria para no volver a preguntar en cada pantalla.
const sinFuncion = new Set();
export function olvidarFuncionesFaltantes() { sinFuncion.clear(); }
export async function rpcSiExiste(funcion, args = {}) {
  if (sinFuncion.has(funcion)) return null;
  try {
    return await rpc(funcion, args);
  } catch (e) {
    if (e.http === 404 && (e.sqlstate === 'PGRST202' || /PGRST202|Could not find the function/i.test(e.message))) {
      sinFuncion.add(funcion);
      return null;
    }
    throw e;
  }
}

// Llama una función que ESCRIBE: siempre con id_operacion (uuid). Si se corta el internet a
// medio camino, reintenta UNA vez con el MISMO id: el servidor reconoce el reintento y no duplica.
export async function escribir(funcion, args = {}) {
  const datos = { p_id_operacion: nuevoId(), ...args };
  try {
    return await rpc(funcion, datos);
  } catch (e) {
    if (!e.sinConexion) throw e;
    await new Promise((ok) => setTimeout(ok, 1500));
    return rpc(funcion, datos);
  }
}

// Llama una Edge Function de Supabase (POST /functions/v1/<nombre>) con el token del usuario.
// Hoy: "crear-usuario" (alta con clave temporal). En la demo la imita servidor_app.js; en
// Supabase real está PENDIENTE de publicar (ver nucleo/docs/usuarios.md).
export function funcion(nombre, datos = {}) {
  return conToken('/functions/v1/' + encodeURIComponent(nombre), {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(datos),
  });
}

// Lee una vista o tabla permitida (RLS decide qué filas). Filtros "igual a" ({ col: valor }) y,
// desde 0.5.1, "desde / hasta" ({ col: { gte: valor } }, { col: { lte: valor } }; PostgREST gte. y lte.).
export function leer(vista, filtros = {}, { orden = null, limite = null } = {}) {
  const q = new URLSearchParams({ select: '*' });
  for (const [k, v] of Object.entries(filtros)) {
    if (v && typeof v === 'object') {
      if (v.gte !== undefined) q.append(k, 'gte.' + v.gte);
      if (v.lte !== undefined) q.append(k, 'lte.' + v.lte);
      if (v.in !== undefined) q.append(k, 'in.(' + v.in.join(',') + ')');   // uno de varios valores (sin comas ni paréntesis)
    } else q.set(k, 'eq.' + v);
  }
  if (orden) q.set('order', orden);
  if (limite) q.set('limit', String(limite));
  return conToken('/rest/v1/' + encodeURIComponent(vista) + '?' + q, { method: 'GET', headers: {} });
}

export function nuevoId() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// Sube la foto de un comprobante a Supabase Storage (bucket de config.bucketComprobantes) en la
// carpeta de la empresa. Sin bucket configurado (demo local) devuelve null: no se sube nada.
// -> { ruta, tipo, sha256 } para mandar como "comprobante".
export async function subirComprobante(empresa, carpeta, archivo) {
  const bucket = config.bucketComprobantes;
  if (!bucket) return null;
  const datos = await archivo.arrayBuffer();
  const huella = [...new Uint8Array(await crypto.subtle.digest('SHA-256', datos))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const ext = (archivo.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) || 'jpg';
  const ruta = `${empresa}/${carpeta}/${huella}.${ext}`;
  await conToken(`/storage/v1/object/${encodeURIComponent(bucket)}/${ruta}`, {
    method: 'POST', headers: { 'Content-Type': archivo.type || 'application/octet-stream', 'x-upsert': 'true' }, body: datos });
  return { ruta, tipo: archivo.type || 'image/jpeg', sha256: huella };
}

// ---------------- Storage (app 0.11.0: fotos de productos) ----------------
// El bucket es PRIVADO: todo va con el token del usuario y las políticas de la base deciden.
const rutaStorage = (bucket, ruta) => `${encodeURIComponent(bucket)}/${String(ruta).split('/').map(encodeURIComponent).join('/')}`;
async function errorStorage(r) {
  const datos = await r.json().catch(() => ({}));
  const codigo = String(datos.statusCode || r.status);
  const texto = datos.message || datos.error || 'El servidor de archivos no pudo hacer la operación.';
  return new ErrorServidor(texto, { http: Number(codigo) || r.status, clave: codigo === '403' || /row-level security|Unauthorized/i.test(texto) ? 'SIN_PERMISO' : null });
}

// Sube un archivo. Devuelve { creado: true } o { creado: false } si ese archivo ya estaba (mismo nombre = misma
// huella = mismo contenido): no es un error.
export async function subirArchivo(bucket, ruta, blob) {
  const r = await pedirConToken('/storage/v1/object/' + rutaStorage(bucket, ruta), {
    method: 'POST', headers: { 'Content-Type': blob.type || 'application/octet-stream', 'Cache-Control': 'max-age=31536000' }, body: blob });
  if (r.ok) return { creado: true };
  const err = await errorStorage(r);
  if (err.http === 409 || /Duplicate|already exists/i.test(err.message)) return { creado: false };
  throw err;
}

// Baja un archivo con el token (descarga autenticada). -> Blob
export async function bajarArchivo(bucket, ruta) {
  const r = await pedirConToken('/storage/v1/object/authenticated/' + rutaStorage(bucket, ruta), { method: 'GET', headers: {} });
  if (!r.ok) throw await errorStorage(r);
  return r.blob();
}

export async function borrarArchivo(bucket, ruta) {
  const r = await pedirConToken('/storage/v1/object/' + rutaStorage(bucket, ruta), { method: 'DELETE', headers: {} });
  if (!r.ok) throw await errorStorage(r);
}

export { config };
