#!/usr/bin/env node
// =====================================================================
// servidor_armador.js  -  EL ARMADOR: pantalla del PROVEEDOR para armar el
// programa de cada cliente. NUNCA se entrega al cliente ni se publica.
//
//   node herramientas/servidor_armador.js --poner-clave   crea o cambia la clave
//   node herramientas/servidor_armador.js                 abre http://127.0.0.1:8095
//
// Seguridad:
//   * Escucha SOLO en 127.0.0.1 y rechaza otro "Host" (contra páginas ajenas).
//   * Pide la clave del proveedor; se guarda como huella scrypt FUERA de git
//     (~/.config/base-negocios/armador.clave, permisos 600). Sin clave no hace nada.
//   * La conexión a las bases nunca llega al navegador con clave: por dentro usa las
//     herramientas de siempre (ficha.py, nuevo_cliente.sh, aplicar_ficha.sh,
//     lista_clientes.sh, conexion.sh). Las claves de bases reales salen de ~/.pgpass.
//   * Nunca borra datos: aplicar = aplicar_ficha.sh (vista previa, confirmación con
//     el identificador del cliente, respaldo en bases reales, todo o nada).
//
// Por defecto trabaja contra la base LOCAL de demostración (BASE_ARMADOR=demo_armador,
// en base-negocios/.pgdata, sin red). Con "Conexión real" usa la cadena de la ficha.
//
// Variables: PUERTO_ARMADOR (8095), PUERTO_APP_CLIENTE (8096), BASE_ARMADOR (demo_armador),
// DIR_CLIENTES (base-negocios/clientes), ARMADOR_CLAVE_ARCHIVO, DEMO_CLAVE (demo1234).
// Sin dependencias: Node 22, bash, python3 y psql.
// =====================================================================
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const RAIZ = path.resolve(__dirname, '..');
const DIR_ARMADOR = path.join(RAIZ, 'armador');
const DIR_PLANTILLAS = path.join(DIR_ARMADOR, 'plantillas');
const DIR_CLIENTES = path.resolve(process.env.DIR_CLIENTES || path.join(RAIZ, 'clientes'));
const PUERTO = Number(process.env.PUERTO_ARMADOR || 8095);
const PUERTO_APP = Number(process.env.PUERTO_APP_CLIENTE || 8096);
const BASE = process.env.BASE_ARMADOR || 'demo_armador';
const DEMO_CLAVE = process.env.DEMO_CLAVE || 'demo1234';
const ARCHIVO_CLAVE = process.env.ARMADOR_CLAVE_ARCHIVO
  || path.join(os.homedir(), '.config', 'base-negocios', 'armador.clave');
const PGBIN = process.env.PGBIN || '/usr/lib/postgresql/16/bin';
const SOCKET = path.resolve(process.env.PRUEBAS_PGDATA || path.join(RAIZ, '.pgdata'));
const PUERTO_PG = process.env.PRUEBAS_PUERTO || '54329';
const DURACION_SESION = 8 * 3600 * 1000;
const RE_CLIENTE = /^[a-z0-9][a-z0-9_-]{1,40}$/;

if (!/^demo_[a-z0-9_]+$/.test(BASE)) { console.error('FALLA: BASE_ARMADOR debe llamarse demo_algo.'); process.exit(1); }

// ---------------------------------------------------------------------
// Clave del proveedor (huella scrypt; la clave nunca se guarda tal cual)
// ---------------------------------------------------------------------
function huella(clave, sal) { return crypto.scryptSync(clave, sal, 64, { N: 16384 }); }

function leerClaveTerminal(pregunta) {
  return new Promise((resolve) => {
    const entrada = process.stdin;
    if (!entrada.isTTY) { // desde un guion: una línea por la entrada estándar
      let t = ''; entrada.setEncoding('utf8');
      entrada.on('data', (d) => { t += d; });
      entrada.on('end', () => resolve(t.split('\n')[0].replace(/\r$/, '')));
      return;
    }
    process.stdout.write(pregunta);
    entrada.setRawMode(true); entrada.resume(); entrada.setEncoding('utf8');
    let t = '';
    const alTeclear = (c) => {
      if (c === '\r' || c === '\n') { entrada.setRawMode(false); entrada.pause(); entrada.off('data', alTeclear); process.stdout.write('\n'); resolve(t); }
      else if (c === '\u0003') process.exit(1);
      else if (c === '\u007f') t = t.slice(0, -1);
      else t += c;
    };
    entrada.on('data', alTeclear);
  });
}

async function ponerClave() {
  const c1 = await leerClaveTerminal('Clave nueva del Armador (10 letras o más, no se muestra): ');
  if (c1.length < 10) { console.error('FALLA: la clave debe tener al menos 10 letras.'); process.exit(1); }
  if (process.stdin.isTTY) {
    const c2 = await leerClaveTerminal('Repita la clave: ');
    if (c1 !== c2) { console.error('FALLA: las claves no coinciden.'); process.exit(1); }
  }
  const sal = crypto.randomBytes(16);
  fs.mkdirSync(path.dirname(ARCHIVO_CLAVE), { recursive: true, mode: 0o700 });
  fs.writeFileSync(ARCHIVO_CLAVE, `scrypt:${sal.toString('hex')}:${huella(c1, sal).toString('hex')}\n`, { mode: 0o600 });
  fs.chmodSync(ARCHIVO_CLAVE, 0o600);
  console.log(`Clave guardada (solo su huella) en ${ARCHIVO_CLAVE}`);
}

function claveCorrecta(clave) {
  let t;
  try { t = fs.readFileSync(ARCHIVO_CLAVE, 'utf8').trim(); } catch { return false; }
  const [tipo, sal, h] = t.split(':');
  if (tipo !== 'scrypt' || !sal || !h) return false;
  const esperada = Buffer.from(h, 'hex');
  const dada = huella(String(clave || ''), Buffer.from(sal, 'hex'));
  return dada.length === esperada.length && crypto.timingSafeEqual(dada, esperada);
}

// ---------------------------------------------------------------------
// Procesos: herramientas existentes y psql
// ---------------------------------------------------------------------
const ENV_BASE = (() => {
  const e = { ...process.env, PATH: `${PGBIN}:${process.env.PATH || ''}` };
  for (const k of ['PGHOST', 'PGPORT', 'PGDATABASE', 'PGUSER', 'PGPASSWORD', 'DATABASE_URL', 'SIN_PREGUNTAR', 'SIN_RESPALDO']) delete e[k];
  return e;
})();
const ENV_LOCAL = { ...ENV_BASE, PGHOST: SOCKET, PGPORT: PUERTO_PG, PGUSER: 'postgres', PGDATABASE: BASE };

function correr(programa, args, { env = ENV_BASE, entrada = '', segundos = 600 } = {}) {
  return new Promise((resolve) => {
    const p = spawn(programa, args, { env, cwd: RAIZ });
    let salida = '', errores = '';
    const reloj = setTimeout(() => { p.kill('SIGTERM'); errores += '\nSe pasó del tiempo.'; }, segundos * 1000);
    p.stdout.on('data', (d) => { salida += d; });
    p.stderr.on('data', (d) => { errores += d; });
    p.on('error', (e) => { errores += e.message; });
    p.on('close', (codigo) => { clearTimeout(reloj); resolve({ codigo, salida, errores }); });
    p.stdin.end(entrada);
  });
}
const herramienta = (nombre, args, opciones) => correr('bash', [path.join(RAIZ, 'herramientas', nombre), ...args], opciones);

// Texto SQL literal seguro: $etiqueta$...$etiqueta$ con etiqueta al azar.
function lit(valor) {
  const t = String(valor);
  let tag;
  do { tag = 'a' + crypto.randomBytes(6).toString('hex'); } while (t.includes(tag));
  return `$${tag}$${t}$${tag}$`;
}

// psql contra la base LOCAL del Armador (nunca contra un cliente real).
async function psqlLocal(guion) {
  const r = await correr('psql', ['-X', '-q', '-tA', '-v', 'ON_ERROR_STOP=1'], { env: ENV_LOCAL, entrada: guion });
  if (r.codigo !== 0) throw new Error(limpiarError(r.errores));
  const linea = r.salida.split('\n').find((l) => l.startsWith('@@R@@'));
  return linea === undefined ? null : linea.slice(5);
}

// Primera línea útil de un error (sin rutas ni contexto de PL/pgSQL).
function limpiarError(texto) {
  const lineas = String(texto || '').split('\n').map((l) => l.trim()).filter(Boolean);
  const e = lineas.find((l) => /ERROR:/.test(l)) || lineas[0] || 'Error desconocido';
  return e.replace(/^.*?ERROR:\s*/, '').replace(/^[0-9A-Z]{5}:\s*/, '');
}

const CADENA_LOCAL = `postgresql://postgres@/${BASE}?host=${SOCKET}&port=${PUERTO_PG}`;
const esLocal = (cadena) => cadena === CADENA_LOCAL;

// ---------------------------------------------------------------------
// Base local de demostración (se prepara al arrancar; nunca se borra)
// ---------------------------------------------------------------------
let baseLista = null;
function prepararBase() {
  if (!baseLista) {
    baseLista = herramienta('armador_base.sh', [], { env: { ...ENV_BASE, BASE_ARMADOR: BASE } }).then((r) => {
      if (r.codigo !== 0) { baseLista = null; throw new Error('No se pudo preparar la base de demostración: ' + limpiarError(r.errores || r.salida)); }
      return true;
    });
  }
  return baseLista;
}

// ---------------------------------------------------------------------
// Archivos de clientes
// ---------------------------------------------------------------------
const dirCliente = (id) => {
  if (!RE_CLIENTE.test(String(id || ''))) throw falla(400, 'El identificador del cliente va en minúsculas, números y guiones (ej. taller-perez).');
  return path.join(DIR_CLIENTES, id);
};
function falla(codigo, mensaje) { const e = new Error(mensaje); e.codigo = codigo; return e; }
function leerJson(archivo) { return JSON.parse(fs.readFileSync(archivo, 'utf8')); }
function escribirJson(archivo, datos) {
  // Escribe a un temporal y lo renombra: si algo falla a medias, el archivo anterior queda intacto.
  const tmp = `${archivo}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(datos, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, archivo);
}
function plantillas() {
  return fs.readdirSync(DIR_PLANTILLAS).filter((f) => f.endsWith('.json')).sort()
    .map((f) => leerJson(path.join(DIR_PLANTILLAS, f)));
}
function plantilla(id) {
  const p = plantillas().find((x) => x.id === id);
  if (!p) throw falla(400, 'No existe esa plantilla de rubro.');
  return p;
}

// Lo que la app del cliente lee de su configuración (nada secreto).
function datosApp(cliente, app) {
  const palabras = {};
  for (const [k, v] of Object.entries((app && app.palabras) || {})) {
    if (/^[a-z-]+(\/[a-z-]+)?$/.test(k) && typeof v === 'string' && v.trim() && v.trim().length <= 40) palabras[k] = v.trim();
  }
  const campos = Array.isArray(app && app.campos_orden) ? app.campos_orden.slice(0, 20) : [];
  return { cliente, rubro: String((app && app.rubro) || '').slice(0, 80), plantilla: String((app && app.plantilla) || ''),
    palabras, campos_orden: campos };
}
function escribirApp(dir, app) {
  escribirJson(path.join(dir, 'app.json'), app);
  fs.writeFileSync(path.join(dir, 'config.js'), `// Configuración de la app de ${app.cliente} (la generó el Armador).
// Copie este archivo como app/config.js al publicar y ponga la URL y la clave ANÓNIMA
// del Supabase del cliente. NUNCA la llave service_role. Más fácil: herramientas/armar_app.sh.
export default {
  modo: 'supabase',
  supabaseUrl: 'https://SU-PROYECTO.supabase.co',
  supabaseAnonKey: 'SU-CLAVE-ANONIMA',
  revisarSesionSegundos: 60,
  bucketComprobantes: '',
  rubro: ${JSON.stringify(app.rubro)},
  // Palabras del rubro: solo cambian títulos del menú (ver app/js/menu_datos.js).
  palabras: ${JSON.stringify(app.palabras, null, 2).replace(/\n/g, '\n  ')},
};
`, { mode: 0o600 });
}

// Ficha formato 2 armada con lo que manda la pantalla (lo demás no se acepta).
function armarFicha(d, extra = {}) {
  const f = d && typeof d === 'object' ? d : {};
  const n = f.negocio || {};
  const ficha = {
    $schema: '../../personal/ficha.schema.json',
    cliente: String(f.cliente || ''),
    paquete: f.paquete === 'completo' ? 'completo' : 'esencial',
    negocio: {
      nombre: String(n.nombre || '').trim(),
      rtn: n.rtn ? String(n.rtn).replace(/[^0-9]/g, '') : null,
      rubro: n.rubro ? String(n.rubro) : null,
      moneda: 'HNL', pais: 'HN', zona_horaria: 'America/Tegucigalpa',
      fecha_inicio: String(n.fecha_inicio || ''),
      dias_futuro_max: 3,
    },
    perfil: ['pequeno', 'mediano', 'grande'].includes(f.perfil) ? f.perfil : 'pequeno',
    modulos: {},
    regimen_fiscal: f.regimen_fiscal === 'fiscal_hn' ? 'fiscal_hn' : 'ninguno',
    licencia: f.licencia ? { vence_el: String(f.licencia.vence_el || ''), dias_gracia: Number(f.licencia.dias_gracia) } : null,
    limites: {},
    conexion: extra.conexion,
    dueno: { correo: String((f.dueno || {}).correo || '').trim().toLowerCase(), nombre: String((f.dueno || {}).nombre || '').trim() },
    tema: { color_principal: (f.tema || {}).color_principal, color_acento: (f.tema || {}).color_acento },
    notas: f.notas ? String(f.notas).slice(0, 4000) : null,
  };
  if (!ficha.negocio.rtn) delete ficha.negocio.rtn;
  if (extra.empresa_id) ficha.negocio.empresa_id = extra.empresa_id;
  for (const m of ['contabilidad', 'ventas', 'inventario', 'dinero', 'compras', 'apartados', 'comisiones', 'fondos', 'conciliacion']) {
    if (f.modulos && typeof f.modulos[m] === 'boolean') ficha.modulos[m] = f.modulos[m];
  }
  ficha.modulos.contabilidad = true;
  for (const k of ['usuarios', 'cajas', 'sucursales', 'bodegas']) {
    const v = f.limites ? f.limites[k] : undefined;
    if (v === null || v === '') ficha.limites[k] = null;
    else if (v !== undefined) ficha.limites[k] = Math.floor(Number(v));
  }
  if (extra.logo) ficha.tema.logo = 'logo' + extra.logo;
  if (f.proveedor && f.proveedor.correo) ficha.proveedor = { correo: String(f.proveedor.correo).trim().toLowerCase(), nombre: 'Soporte' };
  return ficha;
}

async function validarFicha(archivo) {
  const r = await correr('python3', [path.join(RAIZ, 'herramientas', 'ficha.py'), 'validar', archivo]);
  if (r.codigo !== 0) throw falla(400, 'La ficha no es válida: ' + (r.errores.trim().split('\n').slice(0, 4).join(' ') || r.salida));
}

// Logo: imagen PNG, JPG o WEBP de hasta 200 KB (lo mismo que acepta configurar_marca).
function leerLogo(dataUrl) {
  if (!dataUrl) return null;
  const m = /^data:image\/(png|jpeg|webp);base64,([A-Za-z0-9+/=]+)$/.exec(String(dataUrl));
  if (!m || dataUrl.length > 300000) throw falla(400, 'El logo debe ser una imagen PNG, JPG o WEBP de hasta 200 KB.');
  return { ext: m[1] === 'jpeg' ? '.jpg' : '.' + m[1], datos: Buffer.from(m[2], 'base64'), url: dataUrl };
}

// Marca, categorías, unidades y campos de la plantilla, COMO el dueño (sus permisos y su bitácora,
// con el motivo "Armador"), en una sola transacción.
function guionPlantilla(empresa, p, tema, logoUrl, nombreComercial) {
  const E = `${lit(empresa)}::uuid`;
  const marca = {};
  if (nombreComercial && nombreComercial.length >= 2 && nombreComercial.length <= 80) marca.nombre_comercial = nombreComercial;
  if (/^#[0-9a-fA-F]{6}$/.test(tema.color_principal || '')) marca.color_principal = tema.color_principal;
  if (/^#[0-9a-fA-F]{6}$/.test(tema.color_acento || '')) marca.color_acento = tema.color_acento;
  if (logoUrl) marca.logo = logoUrl;
  const l = ['BEGIN;',
    `SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT user_id FROM public.usuario_empresa WHERE empresa_id = ${E} AND rol = 'dueno' LIMIT 1), 'role', 'authenticated')::text, true);`,
    'SET LOCAL ROLE authenticated;'];
  if (Object.keys(marca).length) l.push(`SELECT public.configurar_marca(${E}, ${lit(JSON.stringify(marca))}::jsonb, 'Marca inicial puesta por el proveedor con el Armador');`);
  if (p) {
    for (const c of p.categorias || []) l.push(`SELECT public.crear_categoria(${E}, ${lit(c)});`);
    for (const u of p.unidades || []) {
      l.push(`SELECT CASE WHEN EXISTS (SELECT 1 FROM public.unidad u WHERE u.codigo = upper(${lit(u.codigo)}) AND (u.empresa_id IS NULL OR u.empresa_id = ${E}))
        THEN NULL ELSE public.crear_unidad(${E}, ${lit(u.codigo)}, ${lit(u.nombre)}) END;`);
    }
    for (const c of (p.campos_extra || []).filter((x) => x.donde === 'producto')) {
      l.push(`SELECT public.crear_campo_extra(${E}, ${lit(c.clave)}, ${lit(c.etiqueta)}, ${lit(c.tipo)}, ${c.opciones ? lit(JSON.stringify(c.opciones)) + '::jsonb' : 'NULL'}, false);`);
    }
  }
  l.push('COMMIT;', "SELECT '@@R@@ok';");
  return l.join('\n');
}

// ---------------------------------------------------------------------
// App del cliente (servidor_app.js aparte, solo para la base local de demostración)
// ---------------------------------------------------------------------
let appHijo = null;
async function abrirApp(configCliente) {
  if (appHijo) { appHijo.kill('SIGTERM'); await new Promise((r) => setTimeout(r, 300)); appHijo = null; }
  const env = { ...ENV_LOCAL, BASE, PUERTO: String(PUERTO_APP), DEMO_CLAVE, CONFIG_CLIENTE: configCliente || '' };
  appHijo = spawn('node', [path.join(RAIZ, 'herramientas', 'servidor_app.js')], { env, stdio: 'ignore' });
  const url = `http://127.0.0.1:${PUERTO_APP}/`;
  for (let i = 0; i < 50; i++) {
    try { const r = await fetch(url); if (r.ok) return url; } catch { /* todavía arrancando */ }
    await new Promise((r) => setTimeout(r, 150));
  }
  throw falla(500, 'No arrancó la app del cliente.');
}

// ---------------------------------------------------------------------
// Acciones
// ---------------------------------------------------------------------
let ocupado = Promise.resolve(); // una acción que escribe a la vez (dos clics seguidos no chocan)
function enFila(fn) { const p = ocupado.then(fn, fn); ocupado = p.catch(() => {}); return p; }

async function catalogo() {
  await prepararBase();
  const r = await psqlLocal(`SELECT '@@R@@' || json_build_object(
    'modulos', (SELECT json_object_agg(codigo, nombre) FROM public.modulo),
    'dependencias', (SELECT json_agg(json_build_object('modulo', modulo, 'requiere', requiere, 'motivo', motivo) ORDER BY modulo, requiere) FROM public.modulo_dependencia),
    'permisos', (SELECT json_object_agg(rol, ps) FROM (SELECT rol, json_agg(permiso ORDER BY permiso) ps FROM interno.plantilla_rol_permiso GROUP BY rol) x),
    'nucleo', (SELECT version_nucleo FROM public.version_esquema))::text;`);
  return { ...JSON.parse(r), plantillas: plantillas(), base: BASE, demo_clave: DEMO_CLAVE };
}

async function listaClientes() {
  await prepararBase();
  const r = await herramienta('lista_clientes.sh', ['--json'], { env: { ...ENV_BASE, DIR_CLIENTES } });
  if (r.codigo !== 0) throw falla(500, 'No se pudo leer la lista de clientes: ' + limpiarError(r.errores));
  return JSON.parse(r.salida.trim().split('\n').pop() || '[]');
}

// "Exportar para Supabase": SQL del primer cliente (crear la empresa con su ficha) para pegar en el
// SQL Editor del proyecto real. Lo arma herramientas/exportar_supabase.sh (queda también en dist/).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function exportarSupabase(d) {
  const dir = dirCliente(d.cliente);
  const ficha = path.join(dir, 'ficha.json');
  if (!fs.existsSync(ficha)) throw falla(404, 'No existe ese cliente.');
  const dueno = String(d.id_dueno || '').trim();
  const prov = String(d.id_proveedor || '').trim();
  if (dueno && !UUID.test(dueno)) throw falla(400, 'El id del dueño no es válido: cópielo de Supabase > Authentication > Users > User UID (o déjelo vacío y péguelo después en el archivo).');
  if (prov && !UUID.test(prov)) throw falla(400, 'El id del proveedor no es válido (o déjelo vacío).');
  const r = await herramienta('exportar_supabase.sh', [ficha, dueno, prov]);
  if (r.codigo !== 0) throw falla(400, 'No se pudo exportar: ' + limpiarError(r.errores || r.salida));
  const ficheroSql = (r.salida.match(/Listo: (.+\.sql)/) || [])[1];
  if (!ficheroSql || !fs.existsSync(ficheroSql)) throw falla(500, 'No se encontró el archivo exportado.');
  return { nombre: path.basename(ficheroSql), archivo: path.relative(RAIZ, ficheroSql), sql: fs.readFileSync(ficheroSql, 'utf8'), falta_id: !dueno };
}

function verCliente(id) {
  const dir = dirCliente(id);
  if (!fs.existsSync(path.join(dir, 'ficha.json'))) throw falla(404, 'No existe ese cliente.');
  const app = fs.existsSync(path.join(dir, 'app.json')) ? leerJson(path.join(dir, 'app.json')) : { palabras: {} };
  return { ficha: leerJson(path.join(dir, 'ficha.json')), app };
}

async function solicitudes(id) {
  const { ficha } = verCliente(id);
  if (!ficha.negocio.empresa_id || !ficha.conexion) return [];
  const r = await herramienta('armador_sql.sh', [ficha.conexion], { entrada: `SELECT '@@R@@' || coalesce(json_agg(json_build_object(
      'numero', numero, 'tipo', tipo, 'detalle', detalle, 'fecha', to_char(solicitado_en, 'YYYY-MM-DD')) ORDER BY numero), '[]')::text
    FROM public.solicitud_proveedor WHERE empresa_id = ${lit(ficha.negocio.empresa_id)}::uuid AND estado = 'pendiente';` });
  if (r.codigo !== 0) throw falla(500, 'No se pudo consultar: ' + limpiarError(r.errores));
  return JSON.parse((r.salida.split('\n').find((l) => l.startsWith('@@R@@')) || '@@R@@[]').slice(5));
}

async function crear(d) {
  await prepararBase();
  const cliente = String((d.ficha || {}).cliente || '');
  const dir = dirCliente(cliente);
  const real = Boolean(d.conexion);
  if (real && !/^postgres(ql)?:\/\/[^:@/]+@[^/]+\/[^?]+/.test(d.conexion)) throw falla(400, 'La conexión real va como postgresql://usuario@servidor:5432/base (sin clave).');
  const logo = leerLogo(d.logo);
  const p = d.plantilla ? plantilla(d.plantilla) : null;
  fs.mkdirSync(DIR_CLIENTES, { recursive: true });
  try { fs.mkdirSync(dir, { mode: 0o700 }); } catch { throw falla(409, `Ya existe un cliente "${cliente}". Use otro identificador o ábralo en "Clientes".`); }
  const conexion = real ? String(d.conexion) : CADENA_LOCAL;
  const archivo = path.join(dir, 'ficha.json');
  let creada = false;
  try {
    const ficha = armarFicha(d.ficha, { conexion, logo: logo && logo.ext });
    if (logo) fs.writeFileSync(path.join(dir, ficha.tema.logo), logo.datos, { mode: 0o600 });
    escribirJson(archivo, ficha);
    await validarFicha(archivo);
    if (!real) { // en la demo local el dueño se registra solo (en Supabase real lo registra el proveedor antes)
      const correos = [ficha.dueno.correo, ficha.proveedor && ficha.proveedor.correo].filter(Boolean);
      await psqlLocal(correos.map((c) => `INSERT INTO auth.users (email) SELECT ${lit(c)} WHERE NOT EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = lower(${lit(c)}));`).join('\n'));
    }
    const env = real ? { ...ENV_BASE, CONEX_SIN_PEDIR_CLAVE: '1' } : { ...ENV_BASE, SIN_PREGUNTAR: '1' };
    const r = await herramienta('nuevo_cliente.sh', [archivo, conexion], { env, entrada: real ? String(d.confirmacion || '') + '\n' : '' });
    const m = /Empresa creada\. id: ([0-9a-f-]{36})/.exec(r.salida);
    if (r.codigo !== 0 || !m) throw falla(400, 'No se creó la empresa: ' + limpiarError(r.errores || r.salida));
    creada = true;
    ficha.negocio.empresa_id = m[1];
    escribirJson(archivo, ficha);
    const app = datosApp(cliente, { ...d.app, rubro: ficha.negocio.rubro, plantilla: p ? p.id : '' });
    escribirApp(dir, app);
    const avisos = [];
    const g = await herramienta('armador_sql.sh', [conexion], { entrada: guionPlantilla(m[1], p, ficha.tema, logo && logo.url, (d.ficha.negocio || {}).nombre_comercial) });
    if (g.codigo !== 0) avisos.push('La empresa quedó creada, pero no se pudo poner la marca o las categorías del rubro: ' + limpiarError(g.errores) + ' El dueño puede hacerlo en Ajustes.');
    const enlace = real ? null : await abrirApp(path.join(dir, 'app.json'));
    return { cliente, empresa_id: m[1], enlace, real, avisos,
      dueno: { correo: ficha.dueno.correo, clave: real ? '(la que el dueño registró en Supabase)' : DEMO_CLAVE } };
  } catch (e) {
    // Si la empresa NO se creó, se quita la carpeta nueva (solo tiene lo que acabamos de escribir).
    if (!creada) fs.rmSync(dir, { recursive: true, force: true });
    throw e;
  }
}

// Vista previa de cambios de un cliente existente (aplicar_ficha.sh --solo-mostrar).
async function vistaPrevia(d) {
  await prepararBase();
  const { ficha: actual } = verCliente(String(d.cliente || ''));
  const dir = dirCliente(actual.cliente);
  const nueva = armarFicha({ ...d.ficha, cliente: actual.cliente }, { conexion: actual.conexion, empresa_id: actual.negocio.empresa_id });
  nueva.negocio.nombre = actual.negocio.nombre; // el nombre identifica a la empresa: no se cambia aquí
  nueva.dueno = actual.dueno;
  if (actual.proveedor) nueva.proveedor = actual.proveedor; else delete nueva.proveedor;
  if (actual.tema && actual.tema.logo) nueva.tema.logo = actual.tema.logo;
  const propuesta = path.join(dir, 'ficha.propuesta.json');
  escribirJson(propuesta, nueva);
  escribirJson(path.join(dir, 'app.propuesta.json'), datosApp(actual.cliente, { ...d.app, rubro: nueva.negocio.rubro }));
  await validarFicha(propuesta);
  const env = esLocal(actual.conexion) ? ENV_BASE : { ...ENV_BASE, CONEX_SIN_PEDIR_CLAVE: '1' };
  const r = await herramienta('aplicar_ficha.sh', ['--solo-mostrar', propuesta], { env });
  const texto = (r.salida + (r.codigo !== 0 ? '\n' + r.errores : '')).split('\n')
    .filter((l) => !/^(Destino:|  Cadena:|Conectado:|Empresas en esa base|  - |Ficha revisada|AVISO: python3)/.test(l)).join('\n').trim();
  return { texto, ok: r.codigo === 0, hay_cambios: r.codigo === 0 && !/No hay cambios/.test(r.salida),
    problemas: texto.split('\n').filter((l) => /PROBLEMA|ERROR/.test(l)).map((l) => l.replace(/^\s*(PROBLEMA|ERROR):\s*/, '')) };
}

async function aplicar(d) {
  const { ficha: actual } = verCliente(String(d.cliente || ''));
  const dir = dirCliente(actual.cliente);
  const propuesta = path.join(dir, 'ficha.propuesta.json');
  if (!fs.existsSync(propuesta)) throw falla(400, 'Primero vea los cambios (vista previa).');
  if (String(d.confirmacion || '').trim() !== actual.cliente) throw falla(400, `Para aplicar escriba exactamente: ${actual.cliente}`);
  const local = esLocal(actual.conexion);
  const env = local ? { ...ENV_BASE, SIN_RESPALDO: '1' } : { ...ENV_BASE, CONEX_SIN_PEDIR_CLAVE: '1' };
  const r = await herramienta('aplicar_ficha.sh', [propuesta], { env, entrada: actual.cliente + '\n' });
  if (r.codigo !== 0) throw falla(400, 'No se aplicó nada: ' + limpiarError(r.errores || r.salida));
  // La ficha anterior queda en historial/ (nunca se pierde).
  fs.mkdirSync(path.join(dir, 'historial'), { recursive: true, mode: 0o700 });
  const sello = new Date().toISOString().replace(/[:.]/g, '-');
  fs.copyFileSync(path.join(dir, 'ficha.json'), path.join(dir, 'historial', `ficha_${sello}.json`));
  fs.renameSync(propuesta, path.join(dir, 'ficha.json'));
  const appProp = path.join(dir, 'app.propuesta.json');
  if (fs.existsSync(appProp)) { escribirApp(dir, leerJson(appProp)); fs.rmSync(appProp); }
  const texto = r.salida.split('\n').map((l) => l.replace(/^Para aplicar .*?: /, ''))
    .filter((l) => /aplicada|Respaldo listo|AVISO: sin respaldo/.test(l)).join('\n');
  return { ok: true, texto };
}

async function crearDemo(d) {
  await prepararBase();
  const p = plantilla(String(d.rubro || ''));
  const nombre = p.demo.negocio;
  const dominio = `${p.id}.demo.hn`;
  const ya = await psqlLocal(`SELECT '@@R@@' || coalesce((SELECT id::text FROM public.empresa WHERE nombre = ${lit(nombre)} LIMIT 1), '');`);
  let empresa = ya;
  if (!ya) {
    const datos = { ...p.demo, nombre, rubro: p.nombre, dominio, perfil: p.perfil, colores: p.colores,
      modulos: p.modulos_sugeridos.filter((m) => m !== 'fiscal_hn'), categorias: p.categorias, unidades: p.unidades, campos_extra: p.campos_extra };
    empresa = await psqlLocal(`SELECT set_config('armador.demo', ${lit(JSON.stringify(datos))}, false) \\g /dev/null
\\i ${path.join(RAIZ, 'herramientas', 'demo_rubro.sql')}`);
  }
  const conf = path.join(os.tmpdir(), `armador_demo_${p.id}.json`);
  fs.writeFileSync(conf, JSON.stringify(datosApp('demo-' + p.id, { rubro: p.nombre, palabras: p.palabras, plantilla: p.id })));
  const enlace = await abrirApp(conf);
  return { empresa_id: empresa, nombre, enlace, ya_existia: Boolean(ya), clave: DEMO_CLAVE,
    usuarios: [{ correo: `dueno@${dominio}`, puesto: 'Dueño' }, ...(p.demo.usuarios || []).map((u) => ({ correo: `${u.rol}@${dominio}`, puesto: u.nombre }))] };
}

async function abrirAppCliente(d) {
  const { ficha } = verCliente(String(d.cliente || ''));
  if (!esLocal(ficha.conexion)) throw falla(400, 'Este cliente está en su propia base: abra su app publicada.');
  return { enlace: await abrirApp(path.join(dirCliente(ficha.cliente), 'app.json')), correo: ficha.dueno.correo, clave: DEMO_CLAVE };
}

// ---------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------
const sesiones = new Map(); // token -> vence (ms)
let fallos = 0, bloqueadoHasta = 0;

const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png' };
const CABECERAS = {
  'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY', 'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src 'self'; frame-ancestors 'none'",
};

function enviar(res, codigo, cuerpo, extra = {}) {
  res.writeHead(codigo, { ...CABECERAS, 'Content-Type': 'application/json; charset=utf-8', ...extra });
  res.end(JSON.stringify(cuerpo));
}
function leerCuerpo(req) {
  return new Promise((resolve, reject) => {
    let t = '';
    req.on('data', (d) => { t += d; if (t.length > 2e6) { reject(falla(413, 'Demasiado grande.')); req.destroy(); } });
    req.on('end', () => { try { resolve(t ? JSON.parse(t) : {}); } catch { reject(falla(400, 'JSON inválido.')); } });
    req.on('error', reject);
  });
}
function tokenDe(req) {
  const m = /(?:^|;\s*)armador=([A-Za-z0-9_-]{20,})/.exec(req.headers.cookie || '');
  return m ? m[1] : null;
}
function conSesion(req) {
  const t = tokenDe(req);
  const vence = t && sesiones.get(t);
  if (!vence || vence < Date.now()) { if (t) sesiones.delete(t); return false; }
  return true;
}
const HOSTS = new Set([`127.0.0.1:${PUERTO}`, `localhost:${PUERTO}`]);
const ORIGENES = new Set([...HOSTS].map((h) => 'http://' + h));

function servirArchivo(res, ruta) {
  // armador/ completo; de la app solo el estilo, los íconos y el menú (para que la vista previa sea igual).
  let archivo;
  if (ruta === '/' || ruta === '/index.html') archivo = path.join(DIR_ARMADOR, 'index.html');
  else if (/^\/app\/(css\/[a-z_]+\.css|iconos\/[a-z0-9_-]+\.(svg|png)|js\/(menu_datos|iconos)\.js)$/.test(ruta)) archivo = path.join(RAIZ, ruta);
  else if (/^\/(css|js)\/[a-z_]+\.(css|js)$/.test(ruta)) archivo = path.join(DIR_ARMADOR, ruta);
  if (!archivo || !fs.existsSync(archivo)) { res.writeHead(404, CABECERAS); return res.end('No existe'); }
  res.writeHead(200, { ...CABECERAS, 'Content-Type': TIPOS[path.extname(archivo)] || 'application/octet-stream' });
  fs.createReadStream(archivo).pipe(res);
}

const RUTAS = {
  'GET /api/catalogo': () => catalogo(),
  'GET /api/clientes': () => listaClientes(),
  'GET /api/cliente': (d, url) => verCliente(url.searchParams.get('id')),
  'GET /api/solicitudes': (d, url) => solicitudes(url.searchParams.get('id')),
  'POST /api/crear': (d) => enFila(() => crear(d)),
  'POST /api/vista_previa': (d) => enFila(() => vistaPrevia(d)),
  'POST /api/aplicar': (d) => enFila(() => aplicar(d)),
  'POST /api/demo': (d) => enFila(() => crearDemo(d)),
  'POST /api/abrir_app': (d) => enFila(() => abrirAppCliente(d)),
  'POST /api/exportar_supabase': (d) => exportarSupabase(d),
};

const servidor = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  try {
    if (!HOSTS.has(req.headers.host || '')) { res.writeHead(403, CABECERAS); return res.end('No'); }
    if (req.method === 'POST' && req.headers.origin && !ORIGENES.has(req.headers.origin)) return enviar(res, 403, { mensaje: 'Origen no permitido.' });
    if (!url.pathname.startsWith('/api/')) {
      if (req.method !== 'GET') { res.writeHead(405, CABECERAS); return res.end(); }
      return servirArchivo(res, url.pathname);
    }
    if (url.pathname === '/api/entrar' && req.method === 'POST') {
      if (Date.now() < bloqueadoHasta) return enviar(res, 429, { mensaje: 'Demasiados intentos. Espere un minuto.' });
      const d = await leerCuerpo(req);
      if (!claveCorrecta(d.clave)) {
        if (++fallos >= 5) { fallos = 0; bloqueadoHasta = Date.now() + 60000; }
        await new Promise((r) => setTimeout(r, 400));
        return enviar(res, 401, { mensaje: 'Clave incorrecta.' });
      }
      fallos = 0;
      const t = crypto.randomBytes(32).toString('base64url');
      sesiones.set(t, Date.now() + DURACION_SESION);
      return enviar(res, 200, { ok: true }, { 'Set-Cookie': `armador=${t}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${DURACION_SESION / 1000}` });
    }
    if (url.pathname === '/api/salir' && req.method === 'POST') {
      const t = tokenDe(req); if (t) sesiones.delete(t);
      return enviar(res, 200, { ok: true }, { 'Set-Cookie': 'armador=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0' });
    }
    if (url.pathname === '/api/estado') return enviar(res, 200, { sesion: conSesion(req) });
    if (!conSesion(req)) return enviar(res, 401, { mensaje: 'Escriba la clave del proveedor.' });
    const fn = RUTAS[`${req.method} ${url.pathname}`];
    if (!fn) return enviar(res, 404, { mensaje: 'No existe.' });
    const d = req.method === 'POST' ? await leerCuerpo(req) : {};
    return enviar(res, 200, await fn(d, url));
  } catch (e) {
    if (!e.codigo) console.error(e);
    enviar(res, e.codigo || 500, { mensaje: e.codigo ? e.message : 'Error del Armador: ' + e.message });
  }
});

async function arrancar() {
  if (process.argv.includes('--poner-clave')) return ponerClave();
  if (!fs.existsSync(ARCHIVO_CLAVE)) {
    console.error(`Falta la clave del Armador. Créela una vez con:\n  node herramientas/servidor_armador.js --poner-clave`);
    process.exit(1);
  }
  const permisos = fs.statSync(ARCHIVO_CLAVE).mode & 0o777;
  if (permisos & 0o077) console.error(`AVISO: ${ARCHIVO_CLAVE} tiene permisos ${permisos.toString(8)}; deberían ser 600 (chmod 600).`);
  const cerrar = () => { if (appHijo) appHijo.kill('SIGTERM'); process.exit(0); };
  process.on('SIGINT', cerrar); process.on('SIGTERM', cerrar);
  servidor.listen(PUERTO, '127.0.0.1', () => {
    console.log(`Armador en http://127.0.0.1:${PUERTO}  (solo esta computadora; Ctrl+C para salir)`);
    console.log(`Base de demostración: ${BASE}   Clientes: ${DIR_CLIENTES}`);
  });
  prepararBase().then(() => console.log('Base de demostración lista.'), (e) => console.error(e.message));
}
arrancar();
