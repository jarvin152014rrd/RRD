// PRUEBA: app 0.12.0 con un núcleo 0.17.0 (sin la migración 054): lo nuevo se oculta y nada se rompe. Sin
// "Garantías" ni "Antigüedad de saldos" en el menú (y su ruta lleva a otra pantalla), Vender cobra como antes
// (la venta previa no manda el cliente), sin precio mayorista en la ficha del producto ni del cliente, cobrar sin
// "cheque" y "Depósitos y traslados" sin la parte de cheques; sin errores de JavaScript (computadora y celular).
// La corre herramientas/probar_app.sh con una base de demo armada hasta la 053.
'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');
let playwright;
try { playwright = require('playwright'); } catch { playwright = require('/opt/node22/lib/node_modules/playwright'); }
const { chromium } = playwright;

const URL_APP = process.env.URL_APP || 'http://127.0.0.1:8092';
const BASE = process.env.BASE_DEMO || 'demo_pruebas_app_017';
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
  console.log('Pruebas de la app 0.12.0 con un núcleo 0.17.0 (sin la 054):');
  afirmar(sql('(SELECT version_nucleo FROM public.version_esquema)') === '0.17.0', 'la base no es 0.17.0');
  const { p } = await nueva();
  await entrar(p, 'dueno@demo.hn');

  await prueba('menú sin Garantías ni Antigüedad de saldos (y sus rutas llevan a otra pantalla)', async () => {
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    afirmar(await p.locator('a.subpestana[href="#/vender/garantias"]').count() === 0, 'sale Garantías');
    await p.goto(URL_APP + '/#/reportes/gane');
    await p.waitForSelector('a.subpestana');
    afirmar(await p.locator('a.subpestana[href="#/reportes/antiguedad"]').count() === 0, 'sale Antigüedad');
    await p.goto(URL_APP + '/#/vender/garantias');
    await p.waitForFunction(() => location.hash !== '#/vender/garantias');
  });

  await prueba('Vender cobra como antes (con cliente, sin chip mayorista) y el comprobante sale', async () => {
    await p.goto(URL_APP + '/#/vender/ventas');
    await p.waitForSelector('#t-dia');
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    await p.fill('#buscar-producto', 'PVC-012');
    await p.press('#buscar-producto', 'Enter');
    await p.waitForSelector('.linea-carrito');
    await p.selectOption('#cliente', sql(`(SELECT id FROM public.tercero WHERE nombre = 'Constructora Ríos')`));
    await p.waitForSelector('.vender:not([data-calculando])');
    afirmar((await p.locator('[data-dato=total]').innerText()).trim() === 'L 115.00', 'total');
    afirmar(await p.locator('[data-dato=chip-mayorista], [data-accion=cambiar-precio-tipo]').count() === 0, 'sale lo de mayorista');
    afirmar(await p.locator('.vender .mensaje-error').count() === 0, 'error en la previa');
    await p.click('[data-forma=efectivo]');
    await p.click('#cobrar');
    await p.waitForSelector('.comprobante', { timeout: 15000 });
  });

  await prueba('fichas sin precio mayorista ni garantía; cobrar sin cheque; Depósitos sin cheques', async () => {
    await p.goto(URL_APP + '/#/inventario/productos');
    await p.fill('#buscar-producto-inv', 'Cemento');
    await p.getByRole('button', { name: 'Ver Cemento gris 42.5 kg' }).click();
    await p.waitForSelector('#t-pficha');
    afirmar(await p.locator('#precio-mayorista, [data-dato=mayorista]').count() === 0, 'sale el precio mayorista');
    await p.click('#editar-producto');
    await p.waitForSelector('#prod-nombre');
    afirmar(await p.locator('#prod-garantia').count() === 0, 'sale la garantía');
    await p.goto(URL_APP + '/#/clientes/lista');
    await p.waitForSelector('#buscar-cliente');
    await p.getByRole('button', { name: 'Ver a Taller Mejía' }).click();
    await p.getByRole('button', { name: 'Editar' }).click();
    await p.waitForSelector('#cli-nombre');
    afirmar(await p.locator('#cli-mayorista').count() === 0, 'sale el cliente mayorista');
    await p.goto(URL_APP + '/#/caja/cobros');
    await p.waitForSelector('#t-deben');
    await p.getByRole('button', { name: /Cobrar/ }).first().click();
    await p.waitForSelector('#abono-forma');
    afirmar(await p.locator('#abono-forma option[value=cheque]').count() === 0, 'sale la forma cheque');
    await p.goto(URL_APP + '/#/dinero/depositos');
    await p.waitForSelector('#t-mover');
    afirmar(await p.locator('#t-cheques, #lista-cheques').count() === 0, 'sale la parte de cheques');
    await p.goto(URL_APP + '/#/dinero/donde');
    await p.waitForSelector('[data-dato=total_dinero]');
  });

  await prueba('celular: Vender y Reportes sin errores ni salirse a lo ancho', async () => {
    const c = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(c.p, 'cajero@demo.hn');
    await c.p.goto(URL_APP + '/#/vender/nueva');
    await c.p.waitForSelector('#buscar-producto');
    afirmar(await c.p.evaluate(() => document.documentElement.scrollWidth) <= 390, 'se sale a lo ancho');
    await c.p.screenshot({ path: path.join(CAPTURAS, 'v12_nucleo_017_celular.png'), fullPage: true });
    await c.ctx.close();
  });

  if (errores.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + errores.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total} pruebas con el núcleo 0.17.0 pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
