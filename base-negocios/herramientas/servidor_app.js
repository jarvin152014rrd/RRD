#!/usr/bin/env node
// =====================================================================
// servidor_app.js  -  SOLO PARA PROBAR LA APP EN LA COMPUTADORA.
// En producción la app habla con Supabase; esto imita lo mínimo:
//
//   GET  /...                          archivos de base-negocios/app/
//   GET  /config.js                    configuración de la demo (misma URL)
//   POST /auth/v1/token?grant_type=password|refresh_token
//   POST /auth/v1/logout
//   POST /rest/v1/rpc/<funcion>        llama public.<funcion> (emulador.rpc)
//   GET  /rest/v1/<vista>?col=eq.valor&col2=gte.valor&order=col.desc&limit=N  (emulador.leer; eq., in.(a,b), gte., lte.)
//   GET  /auth/v1/user                 quién es el dueño del token (lo usan las Edge Functions)
//   POST /auth/v1/admin/users          crear cuenta  } SOLO con SERVICE_KEY (variable; sin ella
//   DELETE /auth/v1/admin/users/<id>   borrar cuenta } no existen): para probar las Edge Functions
//        reales de supabase/functions/ (app-pruebas/probar_funciones.mjs). Con SERVICE_KEY,
//        /rest/v1 también acepta esa llave como service_role.
//   POST   /storage/v1/object/<bucket>/<ruta>                 } Storage mínimo (app 0.11.0, fotos de
//   GET    /storage/v1/object/authenticated/<bucket>/<ruta>   } productos): subir, bajar con el token y
//   DELETE /storage/v1/object/<bucket>/<ruta>                 } borrar. La fila va a storage.objects COMO el
//        usuario (las políticas de la migración 053 deciden, igual que en Supabase); el tamaño y el tipo se
//        revisan contra storage.buckets; los bytes van a una carpeta (variable ALMACEN).
//   POST /functions/v1/crear-usuario   imita la Edge Function (la real: supabase/functions/):
//        crea el usuario de Auth (si no existe) y llama agregar_usuario_empresa COMO quien
//        llama, en la MISMA transacción: si el núcleo lo rechaza (permiso, límite del contrato)
//        no queda nada creado. En la demo la clave de todos es DEMO_CLAVE (la que se escriba
//        en la pantalla no se guarda: Auth real la guardaría).
//
// Cada llamada corre en su propia transacción con "SET LOCAL ROLE
// authenticated" y request.jwt.claims = el JWT de la sesión, igual que el
// simulador de las pruebas. Los datos viajan a psql dentro de cadenas con
// comillas $etiqueta$ aleatorias (nunca pegados al SQL sin comillas).
//
// Variables: SERVICE_KEY (solo pruebas; ver arriba), PUERTO (8080), BASE (demo_app), ALMACEN (carpeta de los archivos
// de Storage; defecto: <temporal>/demo-storage-<BASE>), DEMO_CLAVE (clave de todos los
// usuarios de la demo), REVISAR_SESION_SEGUNDOS (60), PGHOST/PGPORT/PGUSER,
// CONFIG_CLIENTE (opcional: clientes/<cliente>/app.json que arma el Armador; de ahí
// salen las "palabras" del rubro y el rubro para /config.js, como en la app publicada).
// Sin dependencias: solo Node 22 y psql.
// =====================================================================
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { spawn } = require('node:child_process');

const RAIZ_APP = path.resolve(__dirname, '..', 'app');
const PUERTO = Number(process.env.PUERTO || 8080);
const BASE = process.env.BASE || 'demo_app';
const DEMO_CLAVE = process.env.DEMO_CLAVE || 'demo1234';
const ANON_KEY = 'demo-anon-key';
const SERVICE_KEY = process.env.SERVICE_KEY || ''; // vacío = no hay llave de servicio (la demo normal)
const esServicio = (req) => SERVICE_KEY !== '' && req.headers.apikey === SERVICE_KEY;
const REVISAR_SESION = Number(process.env.REVISAR_SESION_SEGUNDOS || 60);
const DURACION_TOKEN = 3600; // segundos
const SECRETO = crypto.randomBytes(32); // cambia en cada arranque: tokens viejos dejan de valer
const refrescos = new Map(); // refresh_token -> { uid, sid, email }
const ALMACEN = path.resolve(process.env.ALMACEN || path.join(os.tmpdir(), 'demo-storage-' + BASE));

// Palabras del rubro del cliente (solo títulos del menú). Nada secreto viaja en este archivo.
function configCliente() {
  if (!process.env.CONFIG_CLIENTE) return {};
  try {
    const c = JSON.parse(fs.readFileSync(process.env.CONFIG_CLIENTE, 'utf8'));
    return { palabras: c.palabras && typeof c.palabras === 'object' ? c.palabras : {}, rubro: String(c.rubro || '') };
  } catch (e) {
    console.error('AVISO: no se pudo leer CONFIG_CLIENTE:', e.message);
    return {};
  }
}
const CONFIG_EXTRA = configCliente();

const TIPOS = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.woff2': 'font/woff2',
};

// ---------------------------------------------------------------------
// psql
// ---------------------------------------------------------------------
// Texto SQL literal seguro: $etiqueta$ ... $etiqueta$ con etiqueta aleatoria
// que no aparece en el contenido.
function lit(valor) {
  const texto = String(valor);
  let tag;
  do { tag = 'v' + crypto.randomBytes(6).toString('hex'); } while (texto.includes(tag));
  return `$${tag}$${texto}$${tag}$`;
}

// Corre un guion SQL y devuelve la línea que empieza con @@R@@ (o lanza el error de PostgreSQL).
function psql(guion) {
  return new Promise((resolve, reject) => {
    const p = spawn('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-d', BASE],
      { env: process.env });
    let out = '', err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', reject);
    p.on('close', (codigo) => {
      if (codigo !== 0) {
        const m = err.match(/ERROR:\s+([0-9A-Z]{5}):\s+(.*)/);
        const e = new Error(m ? m[2] : err.trim() || 'error de psql');
        e.sqlstate = m ? m[1] : 'XX000';
        return reject(e);
      }
      const linea = out.split('\n').find((l) => l.startsWith('@@R@@'));
      resolve(linea === undefined ? null : linea.slice(5));
    });
    p.stdin.end(guion);
  });
}

function guionComo(claims, consulta) {
  const rol = ['authenticated', 'service_role'].includes(claims.role) ? claims.role : 'anon';
  return `BEGIN;
SELECT set_config('request.jwt.claims', ${lit(JSON.stringify(claims))}, true) \\g /dev/null
SET LOCAL ROLE ${rol};
SELECT '@@R@@' || coalesce((${consulta})::text, 'null');
COMMIT;
`;
}

// ---------------------------------------------------------------------
// JWT (HS256)
// ---------------------------------------------------------------------
const b64 = (x) => Buffer.from(x).toString('base64url');
function firmar(payload) {
  const cuerpo = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' })) + '.' + b64(JSON.stringify(payload));
  return cuerpo + '.' + crypto.createHmac('sha256', SECRETO).update(cuerpo).digest('base64url');
}
function verificar(token) {
  const partes = String(token || '').split('.');
  if (partes.length !== 3) return null;
  const esperada = crypto.createHmac('sha256', SECRETO).update(partes[0] + '.' + partes[1]).digest();
  const dada = Buffer.from(partes[2], 'base64url');
  if (dada.length !== esperada.length || !crypto.timingSafeEqual(dada, esperada)) return null;
  const p = JSON.parse(Buffer.from(partes[1], 'base64url').toString());
  return p;
}
function emitirSesion(uid, sid, email) {
  const ahora = Math.floor(Date.now() / 1000);
  const access = firmar({ sub: uid, role: 'authenticated', session_id: sid, email, aud: 'authenticated',
    iat: ahora, exp: ahora + DURACION_TOKEN });
  const refresh = crypto.randomBytes(24).toString('base64url');
  refrescos.set(refresh, { uid, sid, email });
  return { access_token: access, token_type: 'bearer', expires_in: DURACION_TOKEN, expires_at: ahora + DURACION_TOKEN,
    refresh_token: refresh, user: { id: uid, email } };
}

// ---------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------
function enviar(res, codigo, cuerpo, tipo = 'application/json') {
  const datos = typeof cuerpo === 'string' ? cuerpo : JSON.stringify(cuerpo);
  res.writeHead(codigo, { 'Content-Type': tipo, 'Cache-Control': 'no-store' });
  res.end(datos);
}
function leerCuerpo(req) {
  return new Promise((resolve, reject) => {
    let datos = '';
    req.on('data', (d) => { datos += d; if (datos.length > 5e6) req.destroy(); });
    req.on('end', () => {
      if (!datos) return resolve({});
      try { resolve(JSON.parse(datos)); } catch { reject(new Error('JSON inválido')); }
    });
    req.on('error', reject);
  });
}
function errorPg(res, e) {
  const codigo = e.sqlstate === '42501' ? 403 : /^PGRST20[25]/.test(e.message) ? 404 : 400;
  enviar(res, codigo, { code: e.sqlstate, message: e.message, details: null, hint: null });
}

// Claims de quien llama (anon si no trae token). null = token vencido o falso.
function claimsDe(req) {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  // Llave de servicio (solo pruebas): como las llaves nuevas de Supabase, basta en "apikey".
  if (SERVICE_KEY && (token === SERVICE_KEY || (!token && esServicio(req)))) return { role: 'service_role' };
  if (!token || token === ANON_KEY) return { role: 'anon' };
  const p = verificar(token);
  if (!p || p.exp < Date.now() / 1000) return null;
  return p;
}

async function manejarAuth(req, res, url) {
  if (url.pathname === '/auth/v1/token') {
    const cuerpo = await leerCuerpo(req);
    const tipo = url.searchParams.get('grant_type');
    if (tipo === 'password') {
      if (typeof cuerpo.email !== 'string' || cuerpo.password !== DEMO_CLAVE) {
        return enviar(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials' });
      }
      const fila = await psql(`INSERT INTO auth.sessions (user_id)
        SELECT id FROM auth.users WHERE lower(email) = lower(${lit(cuerpo.email.trim())})
        RETURNING '@@R@@' || json_build_object('uid', user_id, 'sid', id)::text;`);
      if (!fila) return enviar(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials' });
      const { uid, sid } = JSON.parse(fila);
      return enviar(res, 200, emitirSesion(uid, sid, cuerpo.email.trim().toLowerCase()));
    }
    if (tipo === 'refresh_token') {
      const r = refrescos.get(cuerpo.refresh_token);
      if (!r) return enviar(res, 400, { error: 'invalid_grant', error_description: 'Invalid Refresh Token' });
      refrescos.delete(cuerpo.refresh_token);
      return enviar(res, 200, emitirSesion(r.uid, r.sid, r.email));
    }
    return enviar(res, 400, { error: 'unsupported_grant_type' });
  }
  if (url.pathname === '/auth/v1/user' && req.method === 'GET') {
    const c = claimsDe(req);
    if (!c || c.role !== 'authenticated') return enviar(res, 401, { error: 'invalid_token' });
    return enviar(res, 200, { id: c.sub, email: c.email, role: 'authenticated' });
  }
  // Administración de cuentas (como GoTrue /admin): solo con la llave de servicio de las pruebas.
  if (url.pathname.startsWith('/auth/v1/admin/users')) {
    if (!esServicio(req)) return enviar(res, 401, { error: 'not_admin' });
    if (url.pathname === '/auth/v1/admin/users' && req.method === 'POST') {
      const d = await leerCuerpo(req);
      const correo = String(d.email || '').trim().toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)) return enviar(res, 400, { msg: 'invalid email' });
      const fila = await psql(`INSERT INTO auth.users (email) SELECT ${lit(correo)}
        WHERE NOT EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = ${lit(correo)}) RETURNING '@@R@@' || id::text;`);
      if (!fila) return enviar(res, 422, { code: 422, error_code: 'email_exists', msg: 'A user with this email address has already been registered' });
      return enviar(res, 200, { id: fila, email: correo });
    }
    const m = /^\/auth\/v1\/admin\/users\/([0-9a-f-]{36})$/.exec(url.pathname);
    if (m && req.method === 'DELETE') {
      await psql(`DELETE FROM auth.users WHERE id = ${lit(m[1])}::uuid;`);
      return enviar(res, 200, {});
    }
    return enviar(res, 404, { error: 'not_found' });
  }
  if (url.pathname === '/auth/v1/logout') {
    const c = claimsDe(req);
    if (c && c.session_id) {
      for (const [k, v] of refrescos) if (v.sid === c.session_id) refrescos.delete(k);
      await psql(`DELETE FROM auth.sessions WHERE id = ${lit(c.session_id)}::uuid;`);
    }
    res.writeHead(204); return res.end();
  }
  enviar(res, 404, { error: 'not_found' });
}

async function manejarRest(req, res, url) {
  if (req.headers.apikey !== ANON_KEY && !esServicio(req)) return enviar(res, 401, { message: 'Falta la clave anónima (apikey).' });
  const claims = claimsDe(req);
  if (!claims) return enviar(res, 401, { code: 'PGRST301', message: 'JWT expired' });
  const ruta = url.pathname.slice('/rest/v1/'.length);
  try {
    if (req.method === 'POST' && ruta.startsWith('rpc/')) {
      const fn = ruta.slice(4);
      const args = await leerCuerpo(req);
      const r = await psql(guionComo(claims, `SELECT emulador.rpc(${lit(fn)}, ${lit(JSON.stringify(args))}::jsonb)`));
      return enviar(res, 200, r === null ? 'null' : r);
    }
    if (req.method === 'GET' && /^[a-z_][a-z0-9_]*$/.test(ruta)) {
      const filtros = {};
      let orden = null, limite = null;
      for (const [k, v] of url.searchParams) {
        if (k === 'select') { if (v !== '*') return enviar(res, 400, { message: 'Solo select=*' }); continue; }
        if (k === 'order') { orden = v; continue; }
        if (k === 'limit') { limite = Number(v) || null; continue; }
        if (v.startsWith('eq.')) { filtros[k] = v.slice(3); continue; }
        const lista = /^in\.\((.*)\)$/.exec(v);
        if (lista) { filtros[k] = { ...(typeof filtros[k] === 'object' ? filtros[k] : {}), in: lista[1].split(',') }; continue; }
        const op = /^(gte|lte)\.(.*)$/.exec(v);
        if (!op) return enviar(res, 400, { message: 'Solo filtros eq., in., gte. y lte.' });
        filtros[k] = { ...(typeof filtros[k] === 'object' ? filtros[k] : {}), [op[1]]: op[2] };
      }
      const r = await psql(guionComo(claims, `SELECT emulador.leer(${lit(ruta)}, ${lit(JSON.stringify(filtros))}::jsonb, ${orden ? lit(orden) : 'NULL'}, ${limite ? Number(limite) : 'NULL'})`));
      return enviar(res, 200, r);
    }
    enviar(res, 404, { message: 'Ruta no emulada' });
  } catch (e) {
    errorPg(res, e);
  }
}

// Imita la Edge Function "crear-usuario" (ver arriba). La real usará la llave service_role
// SOLO dentro de la función y nunca en la app (nucleo/docs/usuarios.md).
async function manejarFuncion(req, res, url) {
  if (req.headers.apikey !== ANON_KEY) return enviar(res, 401, { message: 'Falta la clave anónima (apikey).' });
  const claims = claimsDe(req);
  if (!claims || claims.role !== 'authenticated') return enviar(res, 401, { code: 'PGRST301', message: 'SIN_SESION: debe iniciar sesión.' });
  if (url.pathname !== '/functions/v1/crear-usuario' || req.method !== 'POST') return enviar(res, 404, { message: 'Función no emulada' });
  const d = await leerCuerpo(req);
  const correo = String(d.correo || '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)) return enviar(res, 400, { message: 'DATO_INVALIDO: escriba un correo válido.' });
  if (String(d.clave || '').length < 8) return enviar(res, 400, { message: 'DATO_INVALIDO: la clave temporal lleva 8 letras o más.' });
  if (!/^[0-9a-f-]{36}$/.test(String(d.empresa_id || ''))) return enviar(res, 400, { message: 'DATO_INVALIDO: falta la empresa.' });
  try {
    const r = await psql(`BEGIN;
INSERT INTO auth.users (email) SELECT ${lit(correo)} WHERE NOT EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = ${lit(correo)});
SELECT set_config('request.jwt.claims', ${lit(JSON.stringify(claims))}, true) \\g /dev/null
SET LOCAL ROLE authenticated;
SELECT '@@R@@' || coalesce(to_jsonb(public.agregar_usuario_empresa(${lit(d.empresa_id)}::uuid, ${lit(correo)}, ${lit(String(d.rol || ''))},
  ${d.nombre ? lit(String(d.nombre).slice(0, 120)) : 'NULL'}))::text, 'null');
COMMIT;
`);
    return enviar(res, 200, r === null ? 'null' : r);
  } catch (e) {
    errorPg(res, e);
  }
}

// ---------------------------------------------------------------------
// Storage (lo mínimo de Supabase Storage). Ver arriba.
// ---------------------------------------------------------------------
function leerCrudo(req, limite) {
  return new Promise((resolve, reject) => {
    const partes = [];
    let total = 0;
    // Si pasa del límite se sigue leyendo (sin guardar) para poder contestar 413 como Supabase.
    req.on('data', (d) => { total += d.length; if (total <= limite) partes.push(d); });
    req.on('end', () => (total > limite ? reject(Object.assign(new Error('grande'), { grande: true })) : resolve(Buffer.concat(partes))));
    req.on('error', reject);
  });
}
function errorStorage(res, http, error, message) {
  enviar(res, http, { statusCode: String(http), error, message });
}
// bucket y ruta de /storage/v1/object/[authenticated/]<bucket>/<ruta> (null si no son válidos)
function rutaStorage(resto) {
  const partes = resto.split('/').map((x) => { try { return decodeURIComponent(x); } catch { return ''; } });
  const bucket = partes.shift();
  if (!/^[a-z0-9][a-z0-9_-]{0,62}$/.test(bucket || '') || !partes.length) return null;
  if (partes.some((x) => !/^[A-Za-z0-9._-]{1,120}$/.test(x) || x === '.' || x === '..')) return null;
  const nombre = partes.join('/');
  const archivo = path.resolve(ALMACEN, bucket, ...partes);
  if (!archivo.startsWith(ALMACEN + path.sep)) return null;
  return { bucket, nombre, archivo };
}
function guionStorage(claims, sql) {
  const rol = ['authenticated', 'service_role'].includes(claims.role) ? claims.role : 'anon';
  return `BEGIN;
SELECT set_config('request.jwt.claims', ${lit(JSON.stringify(claims))}, true) \\g /dev/null
SET LOCAL ROLE ${rol};
${sql};
COMMIT;
`;
}

async function manejarStorage(req, res, url) {
  if (req.headers.apikey !== ANON_KEY && !esServicio(req)) return errorStorage(res, 401, 'Unauthorized', 'Falta la clave anónima (apikey).');
  const claims = claimsDe(req);
  if (!claims) return errorStorage(res, 401, 'Unauthorized', 'JWT expired');
  let resto = url.pathname.slice('/storage/v1/object/'.length);
  const bajar = req.method === 'GET' && resto.startsWith('authenticated/');
  if (bajar) resto = resto.slice('authenticated/'.length);
  const r = rutaStorage(resto);
  if (!r) return errorStorage(res, 400, 'InvalidKey', 'Ruta no válida');
  const quien = claims.sub ? `${lit(claims.sub)}::uuid` : 'NULL';
  try {
    if (req.method === 'POST') {
      const conf = await psql(`SELECT '@@R@@' || coalesce((SELECT json_build_object('limite', file_size_limit, 'tipos', allowed_mime_types)::text
        FROM storage.buckets WHERE id = ${lit(r.bucket)}), 'null');`);
      const b = JSON.parse(conf || 'null');
      if (!b) return errorStorage(res, 404, 'Bucket not found', 'Bucket not found');
      const tipo = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
      if (b.tipos && b.tipos.length && !b.tipos.includes(tipo)) return errorStorage(res, 415, 'invalid_mime_type', `mime type ${tipo} is not supported`);
      let datos;
      try { datos = await leerCrudo(req, (b.limite || 50 * 1024 * 1024)); } catch (e) {
        if (e.grande) return errorStorage(res, 413, 'Payload too large', 'The object exceeded the maximum allowed size');
        throw e;
      }
      const meta = JSON.stringify({ mimetype: tipo, size: datos.length });
      const fila = await psql(guionStorage(claims, `INSERT INTO storage.objects (bucket_id, name, owner, metadata)
        VALUES (${lit(r.bucket)}, ${lit(r.nombre)}, ${quien}, ${lit(meta)}::jsonb) RETURNING '@@R@@' || id::text`));
      fs.mkdirSync(path.dirname(r.archivo), { recursive: true });
      fs.writeFileSync(r.archivo, datos);
      return enviar(res, 200, { Key: `${r.bucket}/${r.nombre}`, Id: fila });
    }
    if (bajar) {
      const tipo = await psql(guionComo(claims, `SELECT metadata->>'mimetype' FROM storage.objects WHERE bucket_id = ${lit(r.bucket)} AND name = ${lit(r.nombre)}`));
      if (!tipo || tipo === 'null' || !fs.existsSync(r.archivo)) return errorStorage(res, 404, 'not_found', 'Object not found');
      res.writeHead(200, { 'Content-Type': tipo, 'Cache-Control': 'private, max-age=3600', 'X-Content-Type-Options': 'nosniff' });
      return fs.createReadStream(r.archivo).pipe(res);
    }
    if (req.method === 'DELETE') {
      const fila = await psql(guionStorage(claims, `DELETE FROM storage.objects WHERE bucket_id = ${lit(r.bucket)} AND name = ${lit(r.nombre)}
        RETURNING '@@R@@' || id::text`));
      if (!fila) return errorStorage(res, 404, 'not_found', 'Object not found');
      fs.rmSync(r.archivo, { force: true });
      return enviar(res, 200, { message: 'Successfully deleted' });
    }
    return errorStorage(res, 404, 'not_found', 'Ruta no emulada');
  } catch (e) {
    if (e.sqlstate === '42501') return errorStorage(res, 403, 'Unauthorized', 'new row violates row-level security policy');
    if (e.sqlstate === '23505') return errorStorage(res, 409, 'Duplicate', 'The resource already exists');
    return errorStorage(res, 400, 'Error', e.message);
  }
}

function servirArchivo(req, res, url) {
  if (url.pathname === '/config.js') {
    return enviar(res, 200, `// Configuración de la DEMO local (generada por servidor_app.js)
export default {
  supabaseUrl: location.origin,
  supabaseAnonKey: ${JSON.stringify(ANON_KEY)},
  revisarSesionSegundos: ${REVISAR_SESION},${CONFIG_EXTRA.palabras ? `
  rubro: ${JSON.stringify(CONFIG_EXTRA.rubro)},
  palabras: ${JSON.stringify(CONFIG_EXTRA.palabras)},` : ''}
};
`, TIPOS['.js']);
  }
  let rel = decodeURIComponent(url.pathname);
  if (rel === '/' || rel === '') rel = '/index.html';
  const archivo = path.resolve(RAIZ_APP, '.' + rel);
  if (!archivo.startsWith(RAIZ_APP + path.sep)) return enviar(res, 403, 'No', 'text/plain');
  fs.stat(archivo, (err, st) => {
    if (err || !st.isFile()) return enviar(res, 404, 'No existe', 'text/plain; charset=utf-8');
    res.writeHead(200, { 'Content-Type': TIPOS[path.extname(archivo)] || 'application/octet-stream',
      'Cache-Control': 'no-cache' });
    fs.createReadStream(archivo).pipe(res);
  });
}

const servidor = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname.startsWith('/auth/v1/')) return await manejarAuth(req, res, url);
    if (url.pathname.startsWith('/rest/v1/')) return await manejarRest(req, res, url);
    if (url.pathname.startsWith('/functions/v1/')) return await manejarFuncion(req, res, url);
    if (url.pathname.startsWith('/storage/v1/object/')) return await manejarStorage(req, res, url);
    if (req.method !== 'GET' && req.method !== 'HEAD') return enviar(res, 405, { message: 'Método no permitido' });
    servirArchivo(req, res, url);
  } catch (e) {
    console.error(e);
    enviar(res, 500, { message: 'Error del servidor de demo' });
  }
});

servidor.listen(PUERTO, '127.0.0.1', () => {
  console.log(`App de demo en http://127.0.0.1:${PUERTO}  (base: ${BASE})`);
});
