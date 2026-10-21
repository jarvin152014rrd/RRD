// PRUEBA: el Armador del proveedor en el navegador (Chromium con Playwright).
// La corre herramientas/probar_armador.sh (clave y carpeta de clientes temporales,
// base local demo_pruebas_armador). Variables: URL_ARMADOR, CLAVE_ARMADOR, DIR_CLIENTES,
// CAPTURAS, PGDATABASE y PG* del servidor local.
'use strict';
const path = require('node:path');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
let playwright;
try { playwright = require('playwright'); } catch { playwright = require('/opt/node22/lib/node_modules/playwright'); }
const { chromium } = playwright;

const URL = process.env.URL_ARMADOR || 'http://127.0.0.1:8093';
const CLAVE = process.env.CLAVE_ARMADOR;
const DIR_CLIENTES = process.env.DIR_CLIENTES;
const CAPTURAS = process.env.CAPTURAS || path.join(__dirname, 'capturas');
const VERSION = fs.readFileSync(path.join(__dirname, '..', 'VERSION_NUCLEO'), 'utf8').trim();

let fallas = 0, total = 0;
async function prueba(nombre, fn) {
  total++;
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++; console.log(`  FALLA  ${nombre}\n           ${String(e.message).split('\n')[0]}`); }
}
function afirmar(cond, que) { if (!cond) throw new Error(que); }
// Consulta a la base local de demostración (como postgres, solo lectura).
function sql(consulta) {
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'], { input: `SELECT '@@' || (${consulta})::text;`, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  const l = r.stdout.split('\n').find((x) => x.startsWith('@@'));
  return l ? l.slice(2) : null;
}

(async () => {
  const nav = await chromium.launch();
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1366, height: 900 }, ...opciones });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };
  console.log('Pruebas del Armador:');

  await prueba('sin la clave no entra ni responde datos', async () => {
    const { ctx, p } = await nueva();
    const r = await p.request.get(URL + '/api/clientes');
    afirmar(r.status() === 401, 'la lista respondió sin clave: ' + r.status());
    const c = await p.request.post(URL + '/api/crear', { data: { ficha: { cliente: 'intruso' } } });
    afirmar(c.status() === 401, 'crear respondió sin clave');
    await p.goto(URL + '/');
    await p.fill('#clave-armador', 'clave-equivocada');
    await p.click('button[type=submit]');
    await p.waitForSelector('.mensaje-error');
    afirmar((await p.locator('.mensaje-error').innerText()).includes('Clave incorrecta'), 'no dijo clave incorrecta');
    afirmar(await p.locator('.pestanas').count() === 0, 'entró con clave equivocada');
    const otro = await p.request.get(URL + '/', { headers: { Host: 'otro-sitio.com' } });
    afirmar(otro.status() === 403, 'aceptó otro Host');
    await ctx.close();
  });

  const { ctx, p } = await nueva();
  await prueba('con la clave entra y muestra las pestañas del Armador', async () => {
    await p.goto(URL + '/');
    await p.fill('#clave-armador', CLAVE);
    await p.click('button[type=submit]');
    await p.waitForSelector('#rubro-taller', { timeout: 60000 });
    afirmar((await p.locator('nav[aria-label="Menú del Armador"]').innerText()).includes('Clientes'), 'faltan pestañas');
  });

  await prueba('cuestionario de taller sugiere ventas, inventario, dinero, comisiones y CAI (sin compras ni apartados)', async () => {
    await p.click('#rubro-taller');
    await p.click('#btn-sugerir');
    await p.waitForSelector('#lista-sugerencias');
    const mods = await p.locator('#lista-sugerencias li').evaluateAll((li) => li.map((x) => x.dataset.modulo));
    for (const m of ['contabilidad', 'ventas', 'inventario', 'dinero', 'comisiones']) afirmar(mods.includes(m), `no sugirió ${m}`);
    for (const m of ['compras', 'apartados', 'fondos', 'conciliacion']) afirmar(!mods.includes(m), `sugirió ${m} sin que se pidiera`);
    const txt = await p.locator('#sugerencias').innerText();
    afirmar(txt.includes('Facturas con CAI') && txt.includes('perfil pequeno'), 'no explica CAI y perfil');
    afirmar(/Paga comisiones/.test(txt), 'no explica por qué comisiones');
    // Cambiar una respuesta cambia la sugerencia: compra al crédito -> Compras.
    await p.click('#q-compras-si');
    await p.click('#btn-sugerir');
    afirmar(await p.locator('#lista-sugerencias li[data-modulo="compras"]').count() === 1, 'no sugirió compras al decir que compra al crédito');
    await p.click('#q-compras-no');
    await p.click('#btn-sugerir');
    await p.locator('#paso-cuestionario').scrollIntoViewIfNeeded();
    await p.locator('#paso-cuestionario').locator('..').screenshot({ path: path.join(CAPTURAS, 'p4_cuestionario.png') });
    await p.click('#btn-usar');
    afirmar(await p.isChecked('#mod-comisiones'), 'al usar la sugerencia no se encendió comisiones');
    afirmar(!(await p.isChecked('#mod-compras')), 'compras quedó encendido');
    afirmar(await p.inputValue('#lim-usuarios') === '4', 'límite de usuarios no es 4');
  });

  await prueba('vista previa del menú: palabras del taller y menú por puesto', async () => {
    await p.fill('#nombre', 'Taller Prueba');
    afirmar(await p.inputValue('#cliente') === 'taller-prueba', 'identificador no se armó solo');
    const vp = () => p.locator('#vista-menu').innerText();
    let t = await vp();
    afirmar(t.includes('Órdenes de trabajo') && t.includes('Nueva orden de trabajo') && t.includes('Taller Prueba'), 'la vista previa no usa las palabras del taller');
    afirmar(!t.includes('Compras'), 'muestra Compras apagado');
    const sinIcono = await p.locator('#vista-menu .pestana:not(:has(svg)), #vista-menu .chip:not(:has(svg))').count();
    afirmar(sinIcono === 0, `${sinIcono} pestaña(s) de la vista previa sin ícono`);
    await p.click('#puesto-cajero');
    t = await vp();
    afirmar(!t.includes('Usuarios y permisos'), 'el cajero vería Usuarios y permisos');
    await p.click('#puesto-dueno');
    await p.fill('#dueno-correo', 'dueno@tallerprueba.hn');
    await p.fill('#dueno-nombre', 'Mario Pérez');
    await p.fill('#rtn', '08011999123456');
    await p.screenshot({ path: path.join(CAPTURAS, 'p4_armado_vista_previa.png'), fullPage: true });
  });

  await prueba('crear "Taller Prueba": la empresa existe con sus módulos, límites y ficha', async () => {
    await p.click('#mod-comisiones'); // el proveedor decide: comisiones después (se prueba al aplicar)
    afirmar(!(await p.isChecked('#mod-comisiones')), 'no se apagó comisiones');
    await p.click('#btn-crear');
    await p.waitForSelector('#enlace-app', { timeout: 60000 });
    afirmar(await p.locator('#dato-correo').innerText() === 'dueno@tallerprueba.hn', 'no mostró el correo del dueño');
    const e = sql("(SELECT id FROM public.empresa WHERE nombre = 'Taller Prueba')");
    afirmar(e && e.length === 36, 'la empresa no existe');
    const mods = sql(`(SELECT string_agg(modulo, ',' ORDER BY modulo) FROM public.modulo_activo WHERE empresa_id = '${e}' AND activo)`);
    afirmar(mods === 'contabilidad,dinero,fiscal_hn,inventario,ventas', 'módulos: ' + mods);
    const lim = sql(`(SELECT concat_ws(',', usuarios, cajas, sucursales, bodegas) FROM public.limite_contrato WHERE empresa_id = '${e}')`);
    afirmar(lim === '4,1,1,1', 'límites: ' + lim);
    afirmar(sql(`(SELECT vence_el IS NOT NULL FROM public.licencia WHERE empresa_id = '${e}')`) === 'true', 'sin licencia');
    afirmar(sql(`(SELECT count(*) FROM public.categoria_producto WHERE empresa_id = '${e}')`) === '4', 'no creó las 4 categorías del taller');
    afirmar(sql(`(SELECT marca->>'color_principal' FROM public.empresa WHERE id = '${e}')`) === '#1f2a33', 'no puso los colores');
    const ficha = JSON.parse(fs.readFileSync(path.join(DIR_CLIENTES, 'taller-prueba', 'ficha.json'), 'utf8'));
    afirmar(ficha.negocio.empresa_id === e && ficha.modulos.comisiones === false && ficha.regimen_fiscal === 'fiscal_hn', 'la ficha no quedó bien');
    const app = JSON.parse(fs.readFileSync(path.join(DIR_CLIENTES, 'taller-prueba', 'app.json'), 'utf8'));
    afirmar(app.palabras.vender === 'Órdenes de trabajo', 'app.json sin palabras');
    afirmar(fs.readFileSync(path.join(DIR_CLIENTES, 'taller-prueba', 'config.js'), 'utf8').includes('Órdenes de trabajo'), 'config.js sin palabras');
    // Crear otra vez con el mismo identificador: no pisa nada.
    await p.click('#btn-crear');
    await p.waitForSelector('#resultado .mensaje-error');
    afirmar((await p.locator('#resultado').innerText()).includes('Ya existe'), 'dejó crear dos veces el mismo cliente');
  });

  await prueba('app del cliente taller: el menú dice "Órdenes de trabajo"', async () => {
    const enlace = 'http://127.0.0.1:' + (process.env.PUERTO_APP_CLIENTE || '8094') + '/';
    const a = await nueva();
    await a.p.goto(enlace);
    await a.p.fill('#correo', 'dueno@tallerprueba.hn');
    await a.p.fill('#clave', process.env.DEMO_CLAVE || 'demo1234');
    await a.p.click('button[type=submit]');
    await a.p.waitForSelector('nav.pestanas .pestana', { timeout: 20000 });
    const menu = await a.p.locator('nav.pestanas').innerText();
    afirmar(menu.includes('Órdenes de trabajo'), 'el menú no dice Órdenes de trabajo: ' + menu.replace(/\n/g, ' | '));
    afirmar(!menu.includes('Compras'), 'muestra Compras (apagado)');
    await a.p.goto(enlace + '#/vender/nueva');
    await a.p.waitForSelector('.subpestanas');
    afirmar((await a.p.locator('.subpestanas').innerText()).includes('Nueva orden de trabajo'), 'subpestaña sin palabra del rubro');
    afirmar((await a.p.title()).startsWith('Nueva orden de trabajo'), 'título de la página sin palabra del rubro');
    await a.p.waitForTimeout(800);
    await a.p.screenshot({ path: path.join(CAPTURAS, 'p4_app_cliente_taller.png'), fullPage: false });
    await a.ctx.close();
  });

  await prueba('aplicar cambio (encender comisiones): muestra la diferencia y se aplica', async () => {
    await p.goto(URL + '/#/editar/taller-prueba');
    await p.waitForSelector('#mod-comisiones');
    afirmar(!(await p.isChecked('#mod-comisiones')), 'comisiones ya estaba encendido');
    await p.click('#mod-comisiones');
    await p.click('#btn-ver-cambios');
    await p.waitForSelector('#diferencias', { timeout: 30000 });
    const d = await p.locator('#diferencias').innerText();
    afirmar(/activar:\s+comisiones/.test(d), 'la vista previa no muestra activar comisiones: ' + d);
    afirmar(sql("(SELECT count(*) FROM public.modulo_activo m JOIN public.empresa e ON e.id = m.empresa_id WHERE e.nombre = 'Taller Prueba' AND m.modulo = 'comisiones' AND m.activo)") === '0', 'se aplicó antes de confirmar');
    await p.fill('#confirmar-cliente', 'otro-nombre');
    await p.click('#btn-aplicar');
    await p.waitForSelector('#resultado .mensaje-error');
    afirmar(sql("(SELECT count(*) FROM public.modulo_activo m JOIN public.empresa e ON e.id = m.empresa_id WHERE e.nombre = 'Taller Prueba' AND m.modulo = 'comisiones' AND m.activo)") === '0', 'se aplicó con la confirmación equivocada');
    await p.fill('#confirmar-cliente', 'taller-prueba');
    await p.click('#btn-aplicar');
    await p.waitForSelector('#resultado .mensaje-ok', { timeout: 30000 });
    afirmar(sql("(SELECT count(*) FROM public.modulo_activo m JOIN public.empresa e ON e.id = m.empresa_id WHERE e.nombre = 'Taller Prueba' AND m.modulo = 'comisiones' AND m.activo)") === '1', 'comisiones no quedó encendido');
    const f = JSON.parse(fs.readFileSync(path.join(DIR_CLIENTES, 'taller-prueba', 'ficha.json'), 'utf8'));
    afirmar(f.modulos.comisiones === true, 'la ficha no se actualizó');
    afirmar(fs.readdirSync(path.join(DIR_CLIENTES, 'taller-prueba', 'historial')).length === 1, 'no guardó la ficha anterior en historial/');
  });

  await prueba('apagar un módulo del que otro depende: error explicado y no deja aplicar', async () => {
    await p.goto(URL + '/#/editar/taller-prueba');
    await p.waitForSelector('#mod-ventas');
    await p.click('#mod-ventas');
    await p.waitForSelector('#problemas .mensaje-error');
    const t = await p.locator('#problemas').innerText();
    afirmar(t.includes('"Comisiones" necesita "Ventas, clientes y cobros"') && t.includes('apague primero "Comisiones"'), 'error sin explicar: ' + t);
    afirmar(t.includes('Facturas con CAI'), 'no avisa que el CAI también necesita ventas');
    afirmar(await p.isDisabled('#btn-ver-cambios'), 'deja seguir con el problema');
    await p.click('#mod-ventas');
    afirmar(await p.locator('#problemas .mensaje-error').count() === 0, 'el error no se quitó al corregir');
  });

  await prueba('lista de clientes: muestra el nuevo con su uso y la marca de 80 %', async () => {
    await p.goto(URL + '/#/clientes');
    await p.waitForSelector('#cliente-taller-prueba', { timeout: 30000 });
    const fila = await p.locator('#cliente-taller-prueba').innerText();
    afirmar(fila.includes('Taller mecánico') && fila.includes('completo'), 'faltan rubro o paquete: ' + fila);
    afirmar(fila.includes('Comisiones') && fila.includes(VERSION), 'faltan módulos o versión del núcleo');
    const cerca = await p.locator('#cliente-taller-prueba .uso.cerca[data-limite="cajas"]').innerText();
    afirmar(cerca.includes('1 de 1') && cerca.includes('(!)'), 'no marca cajas al 100 %: ' + cerca);
    afirmar(await p.locator('#cliente-taller-prueba .uso[data-limite="usuarios"].cerca').count() === 0, 'marca usuarios (1 de 4) como cerca');
    await p.screenshot({ path: path.join(CAPTURAS, 'p4_lista_clientes.png'), fullPage: true });
  });

  await prueba('Exportar para Supabase: valida el id y descarga el SQL del primer cliente', async () => {
    await p.click('#cliente-taller-prueba [data-exportar]');
    await p.waitForSelector('#exportar-supabase');
    await p.fill('#exp-id-dueno', 'no-es-un-id');
    await p.click('#btn-exportar-sql');
    await p.waitForSelector('#exp-resultado .mensaje-error');
    afirmar((await p.locator('#exp-resultado').innerText()).includes('User UID'), 'no explica el id malo');
    const id = '6d914f3e-20f7-4526-92ce-a3b6c99ae7b8';
    await p.fill('#exp-id-dueno', id);
    const [descarga] = await Promise.all([p.waitForEvent('download'), p.click('#btn-exportar-sql')]);
    afirmar(descarga.suggestedFilename() === 'instalar_supabase_primer_cliente_taller-prueba.sql', 'nombre: ' + descarga.suggestedFilename());
    const sqlTexto = fs.readFileSync(await descarga.path(), 'utf8');
    afirmar(sqlTexto.includes(`'instalar.id_dueno', '${id}'`) && sqlTexto.includes('crear_empresa_inicial'), 'el SQL no trae el id o la creación');
    afirmar(!/service_role|password|clave_bd/i.test(sqlTexto), 'el SQL trae algo secreto');
    fs.rmSync(path.join(__dirname, '..', 'dist', 'instalar_supabase_primer_cliente_taller-prueba.sql'), { force: true });
  });

  await prueba('modo demostración: "Crear demo de Taller" llena una empresa con datos del rubro', async () => {
    await p.goto(URL + '/#/demo');
    await p.click('#demo-taller');
    await p.waitForSelector('#enlace-demo', { timeout: 60000 });
    const ventas = sql("(SELECT count(*) FROM public.venta v JOIN public.empresa e ON e.id = v.empresa_id WHERE e.nombre = 'Taller El Pistón (demo)')");
    afirmar(Number(ventas) >= 4, 'la demo no tiene ventas: ' + ventas);
    afirmar((await p.locator('#resultado-demo').innerText()).includes('dueno@taller.demo.hn'), 'no muestra los usuarios de la demo');
    await p.click('#demo-taller'); // otra vez: no duplica
    await p.waitForSelector('#resultado-demo :text("ya existía")');
    afirmar(sql("(SELECT count(*) FROM public.empresa WHERE nombre = 'Taller El Pistón (demo)')") === '1', 'duplicó la demo');
  });

  await prueba('celular: el Armador se usa sin salirse a lo ancho', async () => {
    const c = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await c.ctx.addCookies(await ctx.cookies());
    await c.p.goto(URL + '/#/armar');
    await c.p.waitForSelector('#rubro-taller');
    const ancho = await c.p.evaluate(() => document.documentElement.scrollWidth);
    afirmar(ancho <= 390, 'se sale a lo ancho: ' + ancho);
    await c.ctx.close();
  });

  await prueba('sin errores de JavaScript', async () => { afirmar(erroresJs.length === 0, erroresJs.join(' | ')); });
  await ctx.close();
  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas del Armador pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
