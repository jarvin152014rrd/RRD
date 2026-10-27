// Vender sin internet (app 0.14.0, núcleo 0.20.0; diseño: docs/SIN_INTERNET.md).
//
// Dos bases de IndexedDB (G6):
//   negocio-equipo-<empresa>        la del EQUIPO (no es de un usuario y NUNCA se borra al salir): el registro del
//                                   equipo, sus bloques de números con su contador y la COLA de ventas (cada una dice
//                                   qué usuario la hizo). Las ventas subidas se quedan marcadas "subida" (nada se borra).
//   negocio-<empresa>-<usuario>     la del USUARIO: el perfil sin internet (G1) y el catálogo (la foto, G5). El catálogo
//                                   se borra al salir; el perfil, si no quedan ventas suyas por subir.
// Las versiones de las bases SOLO AGREGAN almacenes o índices (M1); si otra pestaña tiene una versión vieja abierta
// se avisa "Cierre las otras pestañas de la app".
//
// Guardar una venta (G6): en UNA transacción de la base del equipo se toma el siguiente número del bloque, se avanza
// el contador y se guarda la venta en la cola. Solo después se imprime. Si la transacción falla no hay venta.
// Subir (G2, M3): en orden, en tandas de 15, una sola pestaña a la vez (navigator.locks), cada llamada con tiempo
// máximo de 10 s; un error de red DETIENE la cola (se reintenta toda: 5 s, 30 s, 2 min y luego cada 5 min).
import * as api from './api.js';
import { calcularVentaLocal, fechaLocal } from './calculo_local.js';

const VERSION_EQUIPO = 1;
const VERSION_USUARIO = 1;
const TANDA = 15;
const TIEMPO_MAX_MS = 10000;
const RELOJ_MAX_MS = 5 * 60 * 1000;
const LLAVE_ULTIMO = 'negocio.sin_internet.ultimo';   // {empresa_id, usuario_id}: para abrir sin internet (G1)

// ---------------------------------------------------------------- IndexedDB
const abiertas = new Map();
let avisoVersion = null;      // fn(texto): la app muestra el aviso de otras pestañas
export function alAvisoVersion(fn) { avisoVersion = fn; }

function prom(req) {
  return new Promise((ok, mal) => { req.onsuccess = () => ok(req.result); req.onerror = () => mal(req.error); });
}

function abrir(nombre, version, crear) {
  if (abiertas.has(nombre)) return abiertas.get(nombre);
  const p = new Promise((ok, mal) => {
    if (!('indexedDB' in window)) { mal(new Error('Este navegador no guarda datos (sin IndexedDB).')); return; }
    const req = indexedDB.open(nombre, version);
    req.onupgradeneeded = (ev) => crear(req.result, ev.oldVersion);     // solo AGREGA (nunca borra almacenes)
    req.onblocked = () => { if (avisoVersion) avisoVersion('Cierre las otras pestañas de la app para seguir.'); };
    req.onerror = () => { abiertas.delete(nombre); mal(req.error); };
    req.onsuccess = () => {
      const db = req.result;
      db.onversionchange = () => {
        db.close(); abiertas.delete(nombre);
        if (avisoVersion) avisoVersion('Hay una versión nueva de la app abierta en otra pestaña. Cierre esta pestaña y siga en la nueva.');
      };
      ok(db);
    };
  });
  abiertas.set(nombre, p);
  p.catch(() => abiertas.delete(nombre));
  return p;
}

const nombreEquipo = (empresa) => `negocio-equipo-${empresa}`;
const nombreUsuario = (empresa, usuario) => `negocio-${empresa}-${usuario}`;

export function baseEquipo(empresa) {
  return abrir(nombreEquipo(empresa), VERSION_EQUIPO, (db, vieja) => {
    if (vieja < 1) {
      db.createObjectStore('datos');                                       // 'equipo' -> {equipo_id, nombre}
      db.createObjectStore('bloques', { keyPath: 'bloque_id' });
      const cola = db.createObjectStore('cola', { keyPath: 'id_operacion' });
      cola.createIndex('orden', 'orden');
      cola.createIndex('usuario', 'usuario_id');
    }
  });
}

export function baseUsuario(empresa, usuario) {
  return abrir(nombreUsuario(empresa, usuario), VERSION_USUARIO, (db, vieja) => {
    if (vieja < 1) db.createObjectStore('datos');                          // 'perfil', 'catalogo'
  });
}

async function leerDe(db, almacen, clave) {
  return prom(db.transaction(almacen).objectStore(almacen).get(clave));
}
async function todos(db, almacen) {
  return prom(db.transaction(almacen).objectStore(almacen).getAll());
}
async function poner(db, almacen, valor, clave) {
  const tx = db.transaction(almacen, 'readwrite');
  if (clave === undefined) tx.objectStore(almacen).put(valor); else tx.objectStore(almacen).put(valor, clave);
  return new Promise((ok, mal) => { tx.oncomplete = () => ok(); tx.onerror = () => mal(tx.error); tx.onabort = () => mal(tx.error); });
}

// ---------------------------------------------------------------- ¿Este equipo puede guardar ventas? (M1)
export async function soporte() {
  const r = { indexeddb: 'indexedDB' in window, persistente: false, incognito: false, ios: false, instalada: false, cuota: null };
  try { r.persistente = navigator.storage && navigator.storage.persisted ? await navigator.storage.persisted() : false; } catch { /* nada */ }
  try {
    if (navigator.storage && navigator.storage.estimate) {
      const e = await navigator.storage.estimate();
      r.cuota = e.quota || null;
      // Modo incógnito (Chrome y Firefox): la cuota es muy chica (alrededor de 100 MB o menos).
      r.incognito = Boolean(e.quota) && e.quota < 120 * 1024 * 1024;
    }
  } catch { /* nada */ }
  r.ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  r.instalada = (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) || navigator.standalone === true;
  r.listo = r.indexeddb && r.persistente && !r.incognito && (!r.ios || r.instalada);
  r.razon = !r.indexeddb ? 'Este navegador no guarda datos: no se puede vender sin internet aquí.'
    : r.incognito ? 'Está en modo incógnito (o privado): no se puede vender sin internet aquí.'
      : r.ios && !r.instalada ? 'En iPhone o iPad instale la app en la pantalla de inicio para vender sin internet.'
        : !r.persistente ? 'Este navegador puede borrar datos: no se puede vender sin internet aquí.' : null;
  return r;
}
export async function pedirPersistencia() {
  try { if (navigator.storage && navigator.storage.persist) await navigator.storage.persist(); } catch { /* nada */ }
  return soporte();
}

// ---------------------------------------------------------------- Equipo, catálogo y perfil
export async function equipoLocal(empresa) {
  try { return (await leerDe(await baseEquipo(empresa), 'datos', 'equipo')) || null; } catch { return null; }
}
export async function bloquesLocales(empresa) {
  try { return await todos(await baseEquipo(empresa), 'bloques'); } catch { return []; }
}
export async function catalogoLocal(empresa, usuario) {
  try { return (await leerDe(await baseUsuario(empresa, usuario), 'datos', 'catalogo')) || null; } catch { return null; }
}
export async function perfilLocal(empresa, usuario) {
  try { return (await leerDe(await baseUsuario(empresa, usuario), 'datos', 'perfil')) || null; } catch { return null; }
}
export function ultimoUsuario() {
  try { return JSON.parse(localStorage.getItem(LLAVE_ULTIMO) || 'null'); } catch { return null; }
}

// Hora corregida del equipo (con la diferencia con el servidor medida al preparar).
export function horaCorregida(cat) { return Date.now() + Number((cat && cat.desfase_ms) || 0); }
export function relojMal(cat) { return Boolean(cat) && Math.abs(Number(cat.desfase_ms || 0)) > RELOJ_MAX_MS; }

// Preparar el equipo (con internet): registrar el equipo (si falta), reservar los números de la caja, bajar la foto
// del catálogo y guardar el perfil sin internet. perfil = mi_perfil completo. nombre = nombre del equipo (la primera vez).
export async function preparar(perfil, { nombre = null, cajaId = null, reservar = true } = {}) {
  const empresa = perfil.empresa.id;
  const usuario = perfil.usuario.id;
  const sop = await pedirPersistencia();
  const be = await baseEquipo(empresa);
  let eq = await leerDe(be, 'datos', 'equipo');
  if (!eq) {
    const r = await api.escribir('registrar_equipo', { p_empresa_id: empresa,
      p_datos: { nombre: (nombre || nombreSugerido()).slice(0, 60) } });
    eq = { equipo_id: r.equipo_id, nombre: r.nombre, registrado_en: r.registrado_en };
    await poner(be, 'datos', eq, 'equipo');
  }
  let avisos = [];
  if (reservar) {
    const r = await api.escribir('reservar_bloque_numeros', { p_empresa_id: empresa, p_equipo_id: eq.equipo_id,
      p_datos: cajaId ? { caja_id: cajaId } : {} });
    avisos = r.avisos || [];
    await guardarBloques(empresa, r.bloques || []);
  }
  const anterior = await catalogoLocal(empresa, usuario);
  const t0 = Date.now();
  const p = await api.rpc('preparar_sin_internet', { p_empresa_id: empresa, p_equipo_id: eq.equipo_id,
    p_datos: { ...(anterior && anterior.version ? { version: anterior.version } : {}), ...(cajaId ? { caja_id: cajaId } : {}) } });
  const t1 = Date.now();
  const desfase = Date.parse(p.hora_servidor) + 500 - Math.round((t0 + t1) / 2);   // la hora del servidor va sin milisegundos
  const cat = { version: p.version, catalogo: p.sin_cambios && anterior ? anterior.catalogo : p.catalogo,
    existencias: p.existencias, existencias_en: p.existencias_en, clientes: p.clientes, reglas: p.reglas, emisor: p.emisor,
    caja: p.caja, turno: p.turno, equipo: p.equipo, hora_servidor: p.hora_servidor, valido_hasta: p.valido_hasta,
    preparado_en: new Date(t1).toISOString(), desfase_ms: desfase };
  const bu = await baseUsuario(empresa, usuario);
  await poner(bu, 'datos', cat, 'catalogo');
  // G1: el perfil sin internet (lo necesario para abrir la app sin conexión).
  await poner(bu, 'datos', { perfil, sin_internet: p.perfil, guardado_en: new Date().toISOString() }, 'perfil');
  if (reservar || !(await bloquesLocales(empresa)).length) await guardarBloques(empresa, p.bloques || []);
  try { localStorage.setItem(LLAVE_ULTIMO, JSON.stringify({ empresa_id: empresa, usuario_id: usuario })); } catch { /* nada */ }
  avisar();
  return { equipo: eq, catalogo: cat, soporte: sop, avisos };
}

function nombreSugerido() {
  const movil = /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent);
  return `${movil ? 'Celular' : 'Computadora'} ${new Date().toISOString().slice(0, 10)}`;
}

// Guarda los bloques del servidor sin bajar nunca el contador local (el equipo puede ir adelante: ventas sin subir).
async function guardarBloques(empresa, lista) {
  const db = await baseEquipo(empresa);
  const tx = db.transaction('bloques', 'readwrite');
  const st = tx.objectStore('bloques');
  for (const b of lista) {
    const ya = await prom(st.get(b.bloque_id));
    st.put({ ...b, siguiente: Math.max(Number(b.siguiente), ya ? Number(ya.siguiente) : 0), estado: 'activo' });
  }
  return new Promise((ok, mal) => { tx.oncomplete = () => ok(); tx.onerror = () => mal(tx.error); });
}

// ¿Este equipo puede vender sin internet ahora? -> { puede, razon, cat, bloque }
export async function estadoVenta(perfil, tipo = null) {
  const empresa = perfil.empresa.id;
  const cat = await catalogoLocal(empresa, perfil.usuario.id);
  if (!cat || !cat.catalogo) return { puede: false, razon: 'Este equipo no está preparado para vender sin internet.' };
  const si = (await perfilLocal(empresa, perfil.usuario.id)) || {};
  const permisos = (si.sin_internet && si.sin_internet.permisos) || [];
  if (!permisos.includes('ventas.sin_internet')) return { puede: false, razon: 'Su usuario no tiene permiso para vender sin internet.', cat };
  if (relojMal(cat)) return { puede: false, razon: 'La hora de este equipo está mal. Corríjala para vender sin internet.', cat };
  if (Date.now() > Date.parse(cat.valido_hasta)) {
    return { puede: false, razon: `Los precios tienen más de ${cat.reglas.horas} horas: conéctese para actualizarlos.`, cat };
  }
  const lic = si.sin_internet && si.sin_internet.licencia_hasta;
  if (lic && fechaLocal(horaCorregida(cat), cat.reglas.zona_horaria) > lic) return { puede: false, razon: 'La licencia del sistema venció.', cat };
  const b = await bloqueDe(empresa, cat, tipo);
  if (!b) return { puede: false, razon: 'Este equipo no tiene números reservados para esta caja.', cat };
  if (b.siguiente > b.hasta) return { puede: false, razon: 'Se acabaron los números reservados en este equipo. Conéctese para reservar más.', cat };
  return { puede: true, cat, bloque: b, quedan: b.hasta - b.siguiente + 1 };
}

// Tipo de documento de una venta sin internet según la regla de la empresa.
export function tipoDocumento(cat, pedido = null) {
  const r = cat.reglas || {};
  if (!r.regimen_fiscal || r.documento_venta_modo === 'solo_ticket') return 'ticket';
  if (r.documento_venta_modo === 'factura_o_ticket' && pedido === 'ticket') return 'ticket';
  return 'factura';
}

async function bloqueDe(empresa, cat, tipo) {
  const t = tipoDocumento(cat, tipo);
  const cajaId = cat.caja && cat.caja.caja_id;
  return (await bloquesLocales(empresa)).find((b) => b.estado === 'activo' && b.tipo === t && b.caja_id === cajaId) || null;
}

// ¿La caja de este usuario tiene un bloque activo EN ESTE EQUIPO? (G2: entonces toda venta de contado va por la cola)
export async function cajaConBloque(perfil) {
  try {
    const cat = await catalogoLocal(perfil.empresa.id, perfil.usuario.id);
    if (!cat) return null;
    const b = await bloqueDe(perfil.empresa.id, cat, null);
    return b ? { bloque: b, cat } : null;
  } catch { return null; }
}

// Calcula con la foto del equipo.
export function calcular(cat, { lineas, cliente_id }) {
  return calcularVentaLocal(cat.catalogo, { lineas, cliente_id, fecha: fechaLocal(horaCorregida(cat), cat.reglas.zona_horaria), sugerir: true });
}

// ---------------------------------------------------------------- Guardar una venta (G6)
// datos: { usuario: {id, nombre}, calculo (de calcular o de la previa del servidor), cliente_id, pagos, en_linea, tipo, nota }
// -> la venta guardada (con su número). Lanza el error si no se pudo: entonces NO hay venta ni número usado.
export async function guardarVenta(perfil, datos, { fallar = false } = {}) {
  const empresa = perfil.empresa.id;
  const cat = await catalogoLocal(empresa, perfil.usuario.id);
  const t = tipoDocumento(cat, datos.tipo);
  const db = await baseEquipo(empresa);
  const id = api.nuevoId();
  const hora = new Date(horaCorregida(cat)).toISOString();
  const tx = db.transaction(['bloques', 'cola'], 'readwrite');
  const resultado = new Promise((ok, mal) => {
    tx.oncomplete = () => ok();
    tx.onerror = () => mal(tx.error || new Error('No se pudo guardar la venta en este equipo.'));
    tx.onabort = () => mal(tx.error || new Error('No se pudo guardar la venta en este equipo.'));
  });
  let registro = null;
  const bloques = tx.objectStore('bloques');
  const lista = await prom(bloques.getAll());
  const b = lista.find((x) => x.estado === 'activo' && x.tipo === t && x.caja_id === cat.caja.caja_id);
  if (!b || b.siguiente > b.hasta) {
    tx.abort();
    await resultado.catch(() => {});
    throw new Error(!b ? 'Este equipo no tiene números reservados para esta caja.' : 'Se acabaron los números reservados en este equipo.');
  }
  const numero = Number(b.siguiente);
  const numeroDocumento = `${b.prefijo}-${String(numero).padStart(8, '0')}`;
  const calc = datos.calculo;
  const payload = {
    id_operacion: id, usuario_id: datos.usuario.id, caja_id: b.caja_id, bloque_id: b.bloque_id, numero, numero_documento: numeroDocumento,
    tipo_documento: t, foto_version: cat.version, hora_equipo: hora, ...(datos.cliente_id ? { cliente_id: datos.cliente_id } : {}),
    lineas: calc.lineas.map((l) => ({ producto_id: l.producto_id, cantidad: l.cantidad, precio_tipo: l.precio_tipo,
      ...(l.promocion_id ? { promocion_id: l.promocion_id } : {}),
      precio_unitario_centavos: l.precio_unitario_centavos, total_centavos: l.total_centavos })),
    pagos: datos.pagos, total_centavos: calc.total_centavos, en_linea: Boolean(datos.en_linea),
    ...(datos.nota ? { nota: datos.nota } : {}),
  };
  registro = { id_operacion: id, orden: Date.now() * 1000 + (numero % 1000), usuario_id: datos.usuario.id, usuario_nombre: datos.usuario.nombre,
    payload, estado: 'en_equipo', creada_en: hora, numero_documento: numeroDocumento, total_centavos: calc.total_centavos,
    comprobante: { calculo: calc, cai: b.cai || null, emisor: cat.emisor, caja: cat.caja && cat.caja.nombre, cliente: clienteDe(cat, datos.cliente_id),
      vendedor: datos.usuario.nombre, moneda: cat.reglas.moneda, en_linea: Boolean(datos.en_linea), zona: cat.reglas.zona_horaria } };
  bloques.put({ ...b, siguiente: numero + 1 });
  if (fallar) { tx.abort(); }          // solo pruebas (G6): la transacción falla a propósito
  else tx.objectStore('cola').put(registro);
  await resultado;
  avisar();
  return registro;
}

function clienteDe(cat, id) {
  const c = id ? (cat.clientes || []).find((x) => x.id === id) : null;
  return c ? { nombre: c.nombre, rtn: c.rtn } : null;
}

// ---------------------------------------------------------------- La cola
export async function cola(empresa) {
  try { return (await todos(await baseEquipo(empresa), 'cola')).sort((a, b) => a.orden - b.orden); } catch { return []; }
}
export async function pendientes(empresa, usuarioId = null) {
  return (await cola(empresa)).filter((x) => x.estado === 'en_equipo' && (!usuarioId || x.usuario_id === usuarioId));
}

// Avisos para la barra: fn({ pendientes, subiendo: {hecho, total} | null, error })
const oyentes = new Set();
let ultimoEstado = { pendientes: 0, subiendo: null, error: null };
export function escuchar(fn) { oyentes.add(fn); fn(ultimoEstado); return () => oyentes.delete(fn); }
let empresaActiva = null;
let usuarioActivo = null;
export function activar(empresa, usuario) { empresaActiva = empresa; usuarioActivo = usuario; avisar(); }
async function avisar(extra = {}) {
  if (!empresaActiva) { ultimoEstado = { pendientes: 0, subiendo: null, error: null }; }
  else {
    const n = (await pendientes(empresaActiva)).length;
    ultimoEstado = { ...ultimoEstado, subiendo: null, ...extra, pendientes: n };
  }
  for (const fn of oyentes) { try { fn(ultimoEstado); } catch (e) { console.error(e); } }
}

// Sube las ventas del usuario conectado (o las de otro, con motivo: M2). Una sola pestaña a la vez.
// -> { subidas, por_resolver, rechazadas, quedan, sin_conexion }
export async function subir(empresa, { usuarioId = usuarioActivo, motivo = null, equipoId = null, registros = null } = {}) {
  const tarea = async () => {
    const eq = equipoId ? { equipo_id: equipoId } : await equipoLocal(empresa);
    const res = { subidas: 0, por_resolver: 0, rechazadas: 0, ya_estaban: 0, quedan: 0, sin_conexion: false, resultados: [] };
    if (!eq) return res;
    let lista = registros || (await pendientes(empresa)).filter((x) => !usuarioId || x.usuario_id === usuarioId);
    const total = lista.length;
    let hecho = 0;
    while (lista.length) {
      const tanda = lista.slice(0, TANDA);
      avisar({ subiendo: { hecho, total } });
      let r;
      try {
        r = await api.rpc('subir_ventas_sin_internet', { p_empresa_id: empresa, p_equipo_id: eq.equipo_id,
          p_ventas: tanda.map((x) => x.payload), ...(motivo ? { p_motivo: motivo } : {}) }, { tiempo: TIEMPO_MAX_MS });
      } catch (e) {
        if (e.sinConexion || e.http === 0) { res.sin_conexion = true; break; }      // M3: un error de red DETIENE la cola
        throw e;
      }
      for (const x of r.resultados || []) {
        const reg = tanda.find((y) => y.id_operacion === x.id_operacion);
        if (!reg) continue;
        res.resultados.push(x);
        if (x.estado === 'rechazada') { res.rechazadas++; reg.ultimo_error = x.error; }
        else {
          const est = x.estado === 'ya_estaba' ? (x.estado_venta === 'registrada' || x.estado_venta === 'resuelta' ? 'subida' : 'por_resolver')
            : x.estado === 'registrada' ? 'subida' : 'por_resolver';
          if (x.estado === 'ya_estaba') res.ya_estaban++; else if (est === 'subida') res.subidas++; else res.por_resolver++;
          reg.estado = est;
          reg.resultado = x;
          reg.subida_en = new Date().toISOString();
        }
        if (!registros) await poner(await baseEquipo(empresa), 'cola', reg);
      }
      hecho += tanda.length;
      // Una rechazada (no se guardó en el servidor) se queda en el equipo y no se vuelve a mandar en esta vuelta.
      lista = lista.slice(TANDA);
    }
    res.quedan = (await pendientes(empresa, usuarioId)).length;
    await avisar({ error: res.sin_conexion ? 'sin_conexion' : null });
    return res;
  };
  if (navigator.locks && navigator.locks.request) {
    return navigator.locks.request(`negocio-subir-${empresa}`, { ifAvailable: true }, async (lock) => {
      if (!lock) return { ocupado: true, subidas: 0, por_resolver: 0, rechazadas: 0, quedan: (await pendientes(empresa)).length };
      return tarea();
    });
  }
  return tarea();
}

// Reintentos: a los 5 s, 30 s, 2 min y luego cada 5 min mientras haya ventas; también al volver la conexión.
let reloj = null;
let intento = 0;
const ESPERAS = [5000, 30000, 120000, 300000];
export function programarSubida(inmediato = false) {
  clearTimeout(reloj);
  if (!empresaActiva || !usuarioActivo) return;
  const espera = inmediato ? 0 : ESPERAS[Math.min(intento, ESPERAS.length - 1)];
  reloj = setTimeout(async () => {
    if (!(await pendientes(empresaActiva, usuarioActivo)).length) { intento = 0; return; }
    try {
      const r = await subir(empresaActiva);
      if (r && (r.sin_conexion || r.ocupado || r.quedan)) { intento++; programarSubida(); } else intento = 0;
    } catch { intento++; programarSubida(); }
  }, espera);
}
export function detener() { clearTimeout(reloj); reloj = null; intento = 0; empresaActiva = null; usuarioActivo = null; avisar(); }

// Devolver los números del equipo (al cerrar el turno): primero sube todo lo propio.
export async function devolverBloques(empresa, cajaId = null) {
  const r = await subir(empresa);
  if (r.sin_conexion) throw new api.ErrorServidor('No hay conexión: no se pueden subir las ventas guardadas.', { sinConexion: true });
  const quedan = (await pendientes(empresa)).filter((x) => !cajaId || x.payload.caja_id === cajaId);
  if (quedan.length) {
    throw new api.ErrorServidor(`FALTAN_VENTAS_POR_SUBIR: quedan ${quedan.length} venta(s) en este equipo (de este u otro usuario); súbalas primero.`,
      { clave: 'FALTAN_VENTAS_POR_SUBIR' });
  }
  const eq = await equipoLocal(empresa);
  const db = await baseEquipo(empresa);
  const devueltos = [];
  for (const b of await bloquesLocales(empresa)) {
    if (b.estado !== 'activo' || (cajaId && b.caja_id !== cajaId)) continue;
    await api.escribir('devolver_bloque', { p_empresa_id: empresa, p_equipo_id: eq.equipo_id, p_bloque_id: b.bloque_id, p_siguiente: b.siguiente });
    await poner(db, 'bloques', { ...b, estado: 'devuelto' });
    devueltos.push(b);
  }
  avisar();
  return devueltos;
}

// ---------------------------------------------------------------- Salir y respaldo
// Al salir: se borra el catálogo; el perfil sin internet solo si no quedan ventas suyas. La base del equipo y la
// cola NUNCA se borran.
export async function alSalir(empresa, usuario) {
  try {
    const bu = await baseUsuario(empresa, usuario);
    const tx = bu.transaction('datos', 'readwrite');
    tx.objectStore('datos').delete('catalogo');
    if (!(await pendientes(empresa, usuario)).length) tx.objectStore('datos').delete('perfil');
    await new Promise((ok) => { tx.oncomplete = ok; tx.onerror = ok; });
  } catch { /* nada */ }
  detener();
}

// Respaldo en archivo de las ventas por subir (para un equipo que se va a dañar o formatear).
export async function respaldo(empresa) {
  const eq = await equipoLocal(empresa);
  const lista = await pendientes(empresa);
  return { tipo: 'respaldo_ventas_sin_internet', version: 1, empresa_id: empresa, equipo: eq, creado_en: new Date().toISOString(),
    ventas: lista.map((x) => ({ id_operacion: x.id_operacion, usuario_id: x.usuario_id, usuario_nombre: x.usuario_nombre,
      numero_documento: x.numero_documento, total_centavos: x.total_centavos, payload: x.payload })) };
}

// Para las pruebas (Playwright): acceso a la base sin pasar por la pantalla.
export const _pruebas = { baseEquipo, baseUsuario, poner, todos };
