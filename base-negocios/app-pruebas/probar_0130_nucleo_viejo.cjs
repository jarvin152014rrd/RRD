// PRUEBA: app 0.13.0 con un núcleo 0.18.0 (sin la migración 055): lo nuevo se oculta y nada se rompe. Fondos y socios
// sin "Estado de cuenta"; Devoluciones sin la vista previa del ajuste mayorista ni el comprobante de la devolución, y el
// cambio de producto con diferencia de siempre (sin contador Falta / Sobra); sin errores de JavaScript (computadora y
// celular). La corre herramientas/probar_app.sh con una base de demo armada hasta la 054.
'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');
let playwright;
try { playwright = require('playwright'); } catch { playwright = require('/opt/node22/lib/node_modules/playwright'); }
const { chromium } = playwright;

const URL_APP = process.env.URL_APP || 'http://127.0.0.1:8093';
const BASE = process.env.BASE_DEMO || 'demo_pruebas_app_018';
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
  console.log('Pruebas de la app 0.13.0 con un núcleo 0.18.0 (sin la 055):');
  afirmar(sql('(SELECT version_nucleo FROM public.version_esquema)') === '0.18.0', 'la base no es 0.18.0');
  const { p } = await nueva();
  await entrar(p, 'dueno@demo.hn');

  await prueba('Fondos y socios sin "Estado de cuenta" (la función no existe en 0.18.0)', async () => {
    await p.goto(URL_APP + '/#/dinero/fondos');
    await p.waitForSelector('#lista-socios');
    afirmar(await p.locator('[data-accion=estado-socio]').count() === 0, 'sale el botón de estado de cuenta');
  });

  await prueba('Devoluciones como antes: sin vista previa del ajuste, cambio con diferencia (sin contador)', async () => {
    sqlEscribir('dueno@demo.hn', `SELECT public.registrar_venta(demo.id('EMPRESA'), jsonb_build_object('lineas', jsonb_build_array(demo.l('CEM', 1)),
      'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid())`);
    const numero = sql(`(SELECT numero_documento FROM public.v_venta WHERE empresa_id = demo.id('EMPRESA') ORDER BY registrado_en DESC LIMIT 1)`);
    await p.goto(URL_APP + '/#/vender/devoluciones');
    await p.waitForSelector('#dev-numero');
    await p.fill('#dev-numero', numero);
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#dev-motivo');
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '1');
    await p.selectOption('#dev-destino', 'dinero');
    await p.waitForTimeout(800);
    afirmar(await p.locator('#dev-previa *').count() === 0, 'sale la vista previa (la función no existe)');
    afirmar((await p.locator('#dev-destino option[value=cambio]').innerText()).trim() === 'Cambiarlo por otro producto', 'texto del cambio');
    await p.selectOption('#dev-destino', 'cambio');
    afirmar(await p.locator('[data-info=regla-exacto]').count() === 0 && await p.locator('#dev-devolver-todo').isHidden(), 'sale la regla del cambio exacto');
    await p.fill('#cambio-buscar', 'varilla');
    await p.locator('#zona-cambio .resultado-producto').first().click();
    await p.waitForSelector('[data-dato=cambio-a-favor]', { timeout: 15000 });
    afirmar(await p.locator('#cambio-contador').count() === 0 && !(await p.locator('#dev-guardar').isDisabled()), 'cambio como antes');
  });

  await prueba('celular: Fondos y Devoluciones sin errores ni salirse a lo ancho', async () => {
    const c = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(c.p, 'dueno@demo.hn');
    await c.p.goto(URL_APP + '/#/dinero/fondos');
    await c.p.waitForSelector('#lista-socios');
    afirmar(await c.p.evaluate(() => document.documentElement.scrollWidth) <= 390, 'se sale a lo ancho');
    await c.p.screenshot({ path: path.join(CAPTURAS, 'v13_nucleo_018_celular.png'), fullPage: true });
    await c.ctx.close();
  });

  if (errores.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + errores.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total} pruebas con el núcleo 0.18.0 pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
