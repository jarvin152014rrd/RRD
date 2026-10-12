// PRUEBA: las Edge Functions REALES (supabase/functions/*/index.ts) contra el emulador local,
// y la app armada para Netlify (herramientas/armar_app.sh) con sus cabeceras de seguridad.
// La corre herramientas/probar_app.sh después de probar_app.cjs. Variables: URL_APP (emulador con
// SERVICE_KEY), SERVICE_KEY, BASE_DEMO y PG* del servidor local, CAPTURAS.
// Node 22 corre los .ts quitando los tipos (las funciones solo usan fetch y Request/Response).
import { spawnSync, spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const RAIZ = path.resolve(AQUI, '..');
const URL_APP = process.env.URL_APP;
const ANON = 'demo-anon-key';
process.env.SUPABASE_URL = URL_APP;
process.env.SUPABASE_SERVICE_ROLE_KEY = process.env.SERVICE_KEY;
process.env.SUPABASE_ANON_KEY = ANON;
const crear = (await import(path.join(RAIZ, 'supabase/functions/crear-usuario/index.ts'))).manejar;
const cerrar = (await import(path.join(RAIZ, 'supabase/functions/cerrar-sesion-remota/index.ts'))).manejar;

let fallas = 0, total = 0;
async function prueba(nombre, fn) {
  total++;
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++; console.log(`  FALLA  ${nombre}\n           ${String(e.message).split('\n')[0]}`); }
}
function afirmar(c, que) { if (!c) throw new Error(que); }
function sql(consulta) {
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', process.env.BASE_DEMO],
    { input: `SELECT '@@' || coalesce((${consulta})::text, '');`, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  const l = r.stdout.split('\n').find((x) => x.startsWith('@@'));
  return l ? l.slice(2) : null;
}
// SQL tal cual (para cambiar datos de prueba como superusuario).
function sqlCrudo(texto) {
  const r = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', process.env.BASE_DEMO], { input: texto, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
}
async function entrar(correo) {
  const r = await fetch(`${URL_APP}/auth/v1/token?grant_type=password`, { method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: correo, password: 'demo1234' }) });
  afirmar(r.ok, 'no entra ' + correo);
  return (await r.json()).access_token;
}
function pedido(token, cuerpo, metodo = 'POST') {
  const h = { apikey: ANON, 'Content-Type': 'application/json', origin: 'https://negocio.ejemplo' };
  if (token) h.Authorization = 'Bearer ' + token;
  return new Request('http://funcion.local/', { method: metodo, headers: h, body: metodo === 'POST' ? JSON.stringify(cuerpo) : undefined });
}
async function llamar(fn, token, cuerpo) {
  const r = await fn(pedido(token, cuerpo));
  return { estado: r.status, datos: await r.json(), cors: r.headers.get('access-control-allow-origin') };
}
const hay = (correo) => sql(`SELECT count(*) FROM auth.users WHERE email = '${correo}'`) === '1';

const E = sql("SELECT ue.empresa_id FROM public.usuario_empresa ue JOIN auth.users u ON u.id = ue.user_id WHERE u.email = 'dueno@demo.hn' AND ue.rol = 'dueno' LIMIT 1");
const dueno = await entrar('dueno@demo.hn');
const admin = await entrar('admin@demo.hn');
const vendedor = await entrar('vendedor@demo.hn');
// La demo viene con el plan lleno (5 de 5): sin límite para estas pruebas (una lo vuelve a llenar).
sqlCrudo(`UPDATE public.limite_contrato SET usuarios = NULL WHERE empresa_id = '${E}';`);
const nuevo = { empresa_id: E, nombre: 'Prueba Funcion', rol: 'vendedor', clave: 'temporal123' };
const sello = Date.now();

console.log('Edge Functions (supabase/functions) contra el emulador:');
await prueba('crear-usuario: CORS, sin token y token falso no pasan', async () => {
  const o = await crear(pedido(null, null, 'OPTIONS'));
  afirmar(o.status === 200 && o.headers.get('access-control-allow-origin') === '*', 'OPTIONS sin CORS');
  const a = await llamar(crear, null, { ...nuevo, correo: `x${sello}@demo.hn` });
  afirmar(a.estado === 401 && a.datos.message.startsWith('SIN_SESION'), 'sin token: ' + JSON.stringify(a));
  const b = await llamar(crear, 'eyJ.falso.token', { ...nuevo, correo: `x${sello}@demo.hn` });
  afirmar(b.estado === 401, 'token falso: ' + b.estado);
  afirmar(!hay(`x${sello}@demo.hn`), 'creó la cuenta sin sesión');
});

await prueba('crear-usuario: el vendedor no tiene permiso y no se crea nada', async () => {
  const r = await llamar(crear, vendedor, { ...nuevo, correo: `v${sello}@demo.hn` });
  afirmar(r.estado === 403 && r.datos.message.startsWith('SIN_PERMISO'), JSON.stringify(r));
  afirmar(!hay(`v${sello}@demo.hn`), 'creó la cuenta sin permiso');
});

await prueba('crear-usuario: el dueño crea la cuenta y la agrega a la empresa (CORS en la respuesta)', async () => {
  const correo = `n${sello}@demo.hn`;
  const r = await llamar(crear, dueno, { ...nuevo, correo });
  afirmar(r.estado === 200 && r.datos.ya_tenia_cuenta === false, JSON.stringify(r));
  afirmar(r.cors === '*', 'falta CORS en la respuesta');
  afirmar(hay(correo), 'no está en auth.users');
  afirmar(sql(`SELECT ue.rol FROM public.usuario_empresa ue JOIN auth.users u ON u.id = ue.user_id WHERE u.email = '${correo}' AND ue.empresa_id = '${E}'`) === 'vendedor', 'no quedó en la empresa');
  afirmar(!JSON.stringify(r.datos).includes(process.env.SERVICE_KEY), 'la respuesta trae la llave');
});

await prueba('crear-usuario: datos malos se rechazan antes de crear nada', async () => {
  const r = await llamar(crear, dueno, { ...nuevo, correo: `c${sello}@demo.hn`, clave: 'corta' });
  afirmar(r.estado === 400 && r.datos.message.startsWith('DATO_INVALIDO'), JSON.stringify(r));
  const p = await llamar(crear, dueno, { ...nuevo, correo: `c${sello}@demo.hn`, rol: 'dueno' });
  afirmar(p.estado === 400, 'aceptó crear un dueño');
  afirmar(!hay(`c${sello}@demo.hn`), 'creó la cuenta con datos malos');
});

await prueba('crear-usuario: si el núcleo dice que no (admin no crea contador), la cuenta recién creada se borra', async () => {
  const correo = `k${sello}@demo.hn`;
  const r = await llamar(crear, admin, { ...nuevo, correo, rol: 'contador' });
  afirmar(r.estado === 400 && /PROHIBIDO|SIN_PERMISO/.test(r.datos.message), JSON.stringify(r));
  afirmar(!hay(correo), 'quedó una cuenta suelta en auth.users');
});

await prueba('crear-usuario: límite del contrato lleno = LIMITE_CONTRATO y no crea la cuenta', async () => {
  sqlCrudo(`INSERT INTO public.limite_contrato (empresa_id, usuarios)
        SELECT '${E}', count(*) FROM public.usuario_empresa WHERE empresa_id = '${E}' AND activo AND rol <> 'proveedor'
        ON CONFLICT (empresa_id) DO UPDATE SET usuarios = excluded.usuarios;`);
  const correo = `l${sello}@demo.hn`;
  const r = await llamar(crear, dueno, { ...nuevo, correo });
  afirmar(r.estado === 409 && r.datos.message.startsWith('LIMITE_CONTRATO'), JSON.stringify(r));
  afirmar(!hay(correo), 'creó la cuenta pasado el límite');
  sqlCrudo(`UPDATE public.limite_contrato SET usuarios = NULL WHERE empresa_id = '${E}';`);
});

await prueba('crear-usuario: correo que ya tenía cuenta no se borra ni se le cambia la clave', async () => {
  const correo = `n${sello}@demo.hn`;   // creado arriba
  const id = sql(`SELECT id FROM auth.users WHERE email = '${correo}'`);
  const r = await llamar(crear, dueno, { ...nuevo, correo });
  afirmar(sql(`SELECT id FROM auth.users WHERE email = '${correo}'`) === id, 'la cuenta cambió o se borró');
  afirmar(r.estado !== 200 || r.datos.ya_tenia_cuenta === true, 'no avisa que ya tenía cuenta: ' + JSON.stringify(r));
});

await prueba('cerrar-sesion-remota: el vendedor no puede; motivo corto se rechaza', async () => {
  const cajeroId = sql("SELECT id FROM auth.users WHERE email = 'cajero@demo.hn'");
  const r = await llamar(cerrar, vendedor, { empresa_id: E, user_id: cajeroId, motivo: 'Celular perdido' });
  afirmar(r.estado === 400 && /SIN_PERMISO/.test(r.datos.message), JSON.stringify(r));
  const m = await llamar(cerrar, dueno, { empresa_id: E, user_id: cajeroId, motivo: 'x' });
  afirmar(m.estado === 400 && /FALTA_MOTIVO/.test(m.datos.message), JSON.stringify(m));
});

await prueba('cerrar-sesion-remota: el dueño cierra al cajero: sesiones borradas y su token ya no sirve', async () => {
  const cajero = await entrar('cajero@demo.hn');
  const cajeroId = sql("SELECT id FROM auth.users WHERE email = 'cajero@demo.hn'");
  afirmar(Number(sql(`SELECT count(*) FROM auth.sessions WHERE user_id = '${cajeroId}'`)) >= 1, 'el cajero no tiene sesión');
  const r = await llamar(cerrar, dueno, { empresa_id: E, user_id: cajeroId, motivo: 'Celular perdido' });
  afirmar(r.estado === 200 && r.datos.sesiones_revocadas >= 1 && !r.datos.aviso, JSON.stringify(r));
  afirmar(sql(`SELECT count(*) FROM auth.sessions WHERE user_id = '${cajeroId}'`) === '0', 'quedaron sesiones');
  const x = await fetch(`${URL_APP}/rest/v1/rpc/resumen_hoy`, { method: 'POST',
    headers: { apikey: ANON, Authorization: 'Bearer ' + cajero, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_empresa_id: E }) });
  const t = await x.json();
  afirmar(!x.ok && /SESION_CERRADA/.test(t.message), 'el token viejo sigue sirviendo: ' + JSON.stringify(t));
});

// ---------------------------------------------------------------------
// La app armada para Netlify: abre sin errores de seguridad (CSP) ni de JavaScript.
// ---------------------------------------------------------------------
console.log('App para Netlify (armar_app.sh + _headers):');
await prueba('dist/app-<cliente> abre con sus cabeceras sin bloqueos de CSP ni errores', async () => {
  const anon = [{ alg: 'HS256', typ: 'JWT' }, { role: 'anon', ref: 'prueba' }].map((x) => Buffer.from(JSON.stringify(x)).toString('base64url')).join('.') + '.firma';
  const cliente = 'prueba-netlify';
  const arm = spawnSync('bash', [path.join(RAIZ, 'herramientas/armar_app.sh'), cliente, 'https://prueba.supabase.co', anon], { encoding: 'utf8' });
  afirmar(arm.status === 0, 'armar_app.sh falló: ' + arm.stderr);
  const dir = path.join(RAIZ, 'dist', 'app-' + cliente);
  try {
    // Servidor estático que aplica _headers como Netlify (reglas que coinciden, en orden).
    const reglas = [];
    let actual = null;
    for (const l of fs.readFileSync(path.join(dir, '_headers'), 'utf8').split('\n')) {
      if (!l.trim() || l.startsWith('#')) continue;
      if (!l.startsWith(' ')) { actual = { patron: l.trim(), cab: {} }; reglas.push(actual); continue; }
      const i = l.indexOf(':'); actual.cab[l.slice(0, i).trim()] = l.slice(i + 1).trim();
    }
    const tipos = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
    const srv = http.createServer((req, res) => {
      let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
      if (p === '/') p = '/index.html';
      const f = path.join(dir, p);
      if (!f.startsWith(dir) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end(); }
      const cab = { 'Content-Type': tipos[path.extname(f)] || 'application/octet-stream' };
      for (const r of reglas) if (r.patron === p || (r.patron.endsWith('*') && p.startsWith(r.patron.slice(0, -1)))) Object.assign(cab, r.cab);
      res.writeHead(200, cab); fs.createReadStream(f).pipe(res);
    });
    await new Promise((ok) => srv.listen(0, '127.0.0.1', ok));
    const require = createRequire(import.meta.url);
    let pw; try { pw = require('playwright'); } catch { pw = require('/opt/node22/lib/node_modules/playwright'); }
    const nav = await pw.chromium.launch();
    const pag = await nav.newPage();
    const problemas = [];
    pag.on('console', (m) => { if (/Content Security Policy|Refused to/i.test(m.text())) problemas.push(m.text()); });
    pag.on('pageerror', (e) => problemas.push(e.message));
    const resp = await pag.goto(`http://127.0.0.1:${srv.address().port}/`);
    afirmar((resp.headers()['content-security-policy'] || '').includes("connect-src 'self' https://prueba.supabase.co"), 'sin CSP');
    afirmar(resp.headers()['x-frame-options'] === 'DENY', 'sin X-Frame-Options');
    await pag.waitForSelector('input[type="email"]', { timeout: 15000 });
    await pag.waitForTimeout(800);
    const sw = await fetch(`http://127.0.0.1:${srv.address().port}/sw.js`);
    afirmar(/no-store/.test(sw.headers.get('cache-control') || ''), 'sw.js con caché');
    await nav.close(); srv.close();
    afirmar(problemas.length === 0, problemas.join(' | '));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

console.log();
console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de funciones y publicación pasaron)`);
process.exit(fallas ? 1 : 0);
