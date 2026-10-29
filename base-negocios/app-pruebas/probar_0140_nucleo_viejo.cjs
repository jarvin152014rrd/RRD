// PRUEBA: app 0.14.0 con un núcleo 0.19.0 (sin la migración 056): lo nuevo se oculta y la app trabaja como antes.
// Sin "Sin internet" en Ajustes, sin "Sin internet por resolver", "Transferencias por confirmar" ni "Talonario"; Primeros
// pasos con sus 5 pasos de siempre; vender, cerrar el turno y salir como antes; sin conexión, el aviso de siempre y
// Vender no guarda nada; sin errores de JavaScript (computadora y celular). La corre herramientas/probar_app.sh con una
// base de demo armada hasta la 055.
'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');
let playwright;
try { playwright = require('playwright'); } catch { playwright = require('/opt/node22/lib/node_modules/playwright'); }
const { chromium } = playwright;

const URL_APP = process.env.URL_APP || 'http://127.0.0.1:8095';
const BASE = process.env.BASE_DEMO || 'demo_pruebas_app_019';
const CAPTURAS = process.env.CAPTURAS || path.join(__dirname, 'capturas');
const CLAVE = process.env.DEMO_CLAVE || 'demo1234';

let fallas = 0, total = 0;
async function prueba(nombre, fn) {
  total++;
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++; console.log(`  FALLA  ${nombre}\n           ${String(e.message).split('\n')[0]}`); }
}
function afirmar(cond, que) { if (!cond) throw new Error(que); }
function sql(consulta) {
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE], { input: `SELECT '@@' || (${consulta})::text;`, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  const l = r.stdout.split('\n').find((x) => x.startsWith('@@'));
  return l ? l.slice(2) : null;
}
function sqlEscribir(correo, consulta) {
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE],
    { input: `BEGIN; SELECT demo.como('${correo}') \\g /dev/null\n${consulta};\nCOMMIT;`, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
}
async function entrar(p, correo) {
  await p.goto(URL_APP + '/');
  await p.fill('#correo', correo);
  await p.fill('#clave', CLAVE);
  await p.click('button[type=submit]');
  await p.waitForSelector('.saludo', { timeout: 15000 });
}

(async () => {
  const nav = await chromium.launch();
  const errores = [];
  const nueva = async (op = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, ...op });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => errores.push(e.message));
    return { ctx, p };
  };
  console.log('Pruebas de la app 0.14.0 con un núcleo 0.19.0 (sin la 056):');
  afirmar(sql('(SELECT version_nucleo FROM public.version_esquema)') === '0.19.0', 'la base no es 0.19.0');
  const { ctx, p } = await nueva();
  await entrar(p, 'dueno@demo.hn');

  await prueba('el menú no tiene lo de sin internet, transferencias por confirmar ni talonario', async () => {
    for (const r of ['ajustes/sin_internet', 'vender/por_resolver', 'dinero/transferencias', 'vender/talonario']) {
      await p.goto(URL_APP + '/#/' + r);
      await p.waitForFunction((x) => location.hash !== '#/' + x, r, { timeout: 5000 });
    }
    await p.goto(URL_APP + '/#/ajustes/negocio');
    await p.waitForSelector('a.subpestana');
    afirmar(await p.locator('a.subpestana[href="#/ajustes/sin_internet"]').count() === 0, 'sale Ajustes > Sin internet');
  });

  await prueba('Primeros pasos con los 5 pasos de siempre (sin "Preparar este equipo")', async () => {
    await p.goto(URL_APP + '/#/inicio/hoy');
    await p.waitForSelector('.saludo');
    await p.waitForTimeout(800);
    if (await p.locator('#primeros-pasos').count()) {
      afirmar(/ de 5$/.test((await p.locator('[data-dato=pasos-hechos]').innerText()).trim()), 'pasos: ' + await p.locator('[data-dato=pasos-hechos]').innerText());
      afirmar(await p.locator('[data-paso=sin_internet]').count() === 0, 'sale el paso de sin internet');
    }
  });

  await prueba('vender y cerrar el turno como antes (sin números en el equipo)', async () => {
    const caja = sql(`(SELECT id FROM public.caja WHERE empresa_id = demo.id('EMPRESA') AND punto_emision = '001')`);
    const saldo = sql(`(SELECT coalesce(saldo_centavos, 0) FROM public.v_cuenta_dinero WHERE caja_id = '${caja}')`);
    sqlEscribir('dueno@demo.hn', `SELECT public.abrir_turno(demo.id('EMPRESA'), '${caja}', ${saldo}, gen_random_uuid())`);
    const antes = Number(sql(`(SELECT count(*) FROM public.venta WHERE empresa_id = demo.id('EMPRESA'))`));
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    afirmar(await p.locator('[data-dato=caja-con-bloque]').count() === 0, 'sale el aviso de números en el equipo');
    await p.fill('#buscar-producto', 'CEM-425');
    await p.locator('.resultado-producto').first().click();
    await p.waitForFunction(() => /L\s?[0-9]/.test((document.querySelector('[data-dato=total]') || {}).textContent || ''), null, { timeout: 15000 });
    afirmar(await p.locator('[data-forma=credito]').count() === 1 && await p.locator('[data-forma=tarjeta]').count() === 1, 'faltan formas de pago');
    await p.click('#cobrar');
    await p.waitForSelector('article.comprobante', { timeout: 20000 });
    afirmar(!(await p.locator('article.comprobante').innerText()).includes('sin conexión'), 'el comprobante dice "sin conexión"');
    afirmar(Number(sql(`(SELECT count(*) FROM public.venta WHERE empresa_id = demo.id('EMPRESA'))`)) === antes + 1, 'no se registró la venta');
    await p.goto(URL_APP + '/#/caja/turno');
    await p.waitForSelector('#cerrar-turno', { timeout: 15000 });
    await p.click('#cerrar-turno');
    await p.fill('#cierre-total', '0');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#t-res', { timeout: 20000 });
  });

  await prueba('sin conexión: el aviso de siempre y Vender no guarda nada en el equipo', async () => {
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    // Sin pedidos en camino: una respuesta que llega después del corte marca "volvió la conexión" (como siempre).
    await p.waitForLoadState('networkidle');
    await p.waitForTimeout(1000);
    await ctx.setOffline(true);
    await p.waitForSelector('#sin-conexion:not([hidden])', { timeout: 5000 });
    afirmar((await p.locator('#sin-conexion').innerText()).includes('para guardar necesita internet'), 'aviso: ' + await p.locator('#sin-conexion').innerText());
    const n = await p.evaluate(async () => { const m = await import('/js/sin_internet.js'); const per = (await import('/js/sesion.js')).perfilActual(); return (await m.cola(per.empresa.id)).length; });
    afirmar(n === 0, 'hay ventas en la cola del equipo');
    await ctx.setOffline(false);
    await p.waitForSelector('#sin-conexion[hidden]', { state: 'attached', timeout: 5000 });
  });

  await prueba('salir y celular: sin errores ni salirse a lo ancho', async () => {
    await p.click('.quien button');
    await p.waitForSelector('#correo', { timeout: 10000 });
    const c = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(c.p, 'dueno@demo.hn');
    await c.p.goto(URL_APP + '/#/vender/nueva');
    await c.p.waitForSelector('#buscar-producto');
    afirmar(await c.p.evaluate(() => document.documentElement.scrollWidth) <= 390, 'se sale a lo ancho');
    await c.p.screenshot({ path: path.join(CAPTURAS, 'v14_nucleo_019_celular.png'), fullPage: true });
    await c.ctx.close();
  });

  if (errores.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + errores.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total} pruebas con el núcleo 0.19.0 pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
