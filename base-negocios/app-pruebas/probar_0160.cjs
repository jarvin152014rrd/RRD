// PRUEBA: app 0.16.0 (núcleo 0.22.0) en el navegador contra la base de demo: Ajustes > Sucursales y bodegas (la tienda
// marcada, agregar una bodega que solo guarda, cambiar cuál vende con motivo), Facturas (CAI) abre, el dueño cambia el
// nombre legal en Mi negocio (con motivo) y el admin solo lo ve, y Vender cuenta solo lo que hay en la tienda.
// La corre herramientas/probar_app.sh. Variables: URL_APP, BASE_DEMO, CAPTURAS, PG* del servidor local.
// La corre herramientas/probar_app.sh. Variables: URL_APP, BASE_DEMO, CAPTURAS, PG* del servidor local.
'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');
let playwright;
try { playwright = require('playwright'); } catch { playwright = require('/opt/node22/lib/node_modules/playwright'); }
const { chromium } = playwright;

const URL_APP = process.env.URL_APP || 'http://127.0.0.1:8091';
const BASE = process.env.BASE_DEMO || 'demo_pruebas_app';
const CAPTURAS = process.env.CAPTURAS || path.join(__dirname, 'capturas');
const CLAVE = process.env.DEMO_CLAVE || 'demo1234';

let fallas = 0, total = 0;
let paso = '';
async function prueba(nombre, fn) {
  total++;
  paso = '';
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++;
    if (global.paginaActual) await global.paginaActual.screenshot({ path: path.join(CAPTURAS, 'falla160_' + total + '.png'), fullPage: true }).catch(() => {});
    console.log(`  FALLA  ${nombre}\n           ${paso ? '[' + paso + '] ' : ''}${String(e.message).split('\n')[0]}`); }
}
function afirmar(cond, que) { if (!cond) throw new Error(que); }

function sql(correo, consulta) {
  const guion = `BEGIN; ${correo ? `SELECT demo.como('${correo}') \\g /dev/null` : ''}
SELECT '@@' || (${consulta})::text; ROLLBACK;`;
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE], { input: guion, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  const linea = r.stdout.split('\n').find((l) => l.startsWith('@@'));
  return linea ? linea.slice(2) : null;
}
function sqlEscribir(correo, consulta) {
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE],
    { input: `BEGIN; SELECT demo.como('${correo}') \\g /dev/null\n${consulta};\nCOMMIT;`, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
}
function lempiras(c) {
  const n = Number(c), a = Math.abs(n);
  const ent = String(Math.floor(a / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${n < 0 ? '-' : ''}L ${ent}.${String(a % 100).padStart(2, '0')}`;
}
async function entrar(pagina, correo) {
  await pagina.goto(URL_APP + '/');
  await pagina.fill('#correo', correo);
  await pagina.fill('#clave', CLAVE);
  await pagina.click('button[type=submit]');
  await pagina.waitForSelector('.saludo', { timeout: 15000 });
}
const textoDe = (pagina, sel) => pagina.locator(sel).first().innerText();
const anchoPagina = (p) => p.evaluate(() => document.documentElement.scrollWidth);
const emojis = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u;
const id = (clave) => sql(null, `demo.id('${clave}')`);
const DUENO = 'dueno@demo.hn';
const EM = () => id('EMPRESA');
const ADMIN = 'admin@demo.hn';

(async () => {
  const nav = await chromium.launch();
  const erroresJs = [];
  const nueva = async (op = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, ...op });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => erroresJs.push(e.message));
    global.paginaActual = p;
    return { ctx, p };
  };
  const ir = async (p, ruta, sel) => { await p.goto(URL_APP + '/#/inicio/pendientes'); await p.waitForTimeout(200); await p.goto(URL_APP + '/#/' + ruta); if (sel) await p.waitForSelector(sel, { timeout: 15000 }); };
  const motivo = async (p, texto) => { await p.fill('dialog textarea[name=motivo]', texto); await p.click('dialog button[type=submit]'); };
  console.log('Pruebas de la app 0.16.0 (tienda y bodegas, CAI, datos fiscales):');
  const E = EM();
  const tiendas = () => sql(null, `(SELECT string_agg(codigo, ',' ORDER BY codigo) FROM public.bodega WHERE empresa_id = '${E}' AND activa AND vende)`);

  await prueba('Sucursales y bodegas: tienda marcada, bodega nueva que solo guarda, cambiar cuál vende', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    await ir(p, 'ajustes/bodegas', '#t-bodegas');
    const antes = tiendas();
    afirmar(antes === 'B1', 'la tienda de la demo debía ser B1: ' + antes);
    afirmar((await textoDe(p, '[data-codigo=B1]')).includes('Tienda'), 'B1 no dice Tienda');
    afirmar((await textoDe(p, '[data-codigo=B2]')).includes('Bodega'), 'B2 no dice Bodega');
    paso = 'agregar';
    await p.click('[data-sucursal="001"] [data-accion=agregar-bodega]');
    await p.fill('#bodega-nombre', 'Bodega del fondo');
    afirmar(await p.locator('input[name=bodega-tipo][value=bodega]').isChecked(), 'con tienda, lo nuevo debía ser bodega');
    await p.click('#bodega-crear');
    await p.waitForSelector('text=Bodega del fondo');
    afirmar(sql(null, `(SELECT vende::text FROM public.bodega WHERE empresa_id = '${E}' AND nombre = 'Bodega del fondo')`) === 'false', 'la nueva vende');
    paso = 'vender desde B2';
    await p.click('[data-codigo=B2] button:has-text("Vender desde aquí")');
    await motivo(p, 'Prueba: vender desde atrás');
    await p.waitForFunction(() => (document.querySelector('[data-codigo=B2]') || {}).innerText?.includes('Tienda'));
    afirmar(tiendas() === 'B2', 'B2 no quedó como tienda');
    await p.screenshot({ path: path.join(CAPTURAS, 'v16_bodegas.png'), fullPage: true });
    paso = 'volver a B1';
    await p.click('[data-codigo=B1] button:has-text("Vender desde aquí")');
    await motivo(p, 'Prueba: volver al mostrador');
    await p.waitForFunction(() => (document.querySelector('[data-codigo=B1]') || {}).innerText?.includes('Tienda'));
    afirmar(tiendas() === 'B1', 'B1 no volvió a ser la tienda');
    await ctx.close();
  });

  await prueba('Facturas (CAI) abre y el buscador la encuentra', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    await p.keyboard.press('Control+k');
    await p.waitForSelector('#buscador[open]');
    await p.keyboard.type('crear bodega');
    afirmar((await textoDe(p, '.buscador-opcion')).includes('Sucursales y bodegas'), 'el buscador no encuentra Sucursales y bodegas');
    await p.keyboard.press('Escape');
    const conFiscal = sql(null, `(SELECT count(*) FROM public.modulo_activo WHERE empresa_id = '${E}' AND modulo = 'fiscal_hn' AND activo)`) !== '0';
    if (conFiscal) {
      await ir(p, 'ajustes/cai', '#t-cai');
      const n = Number(sql(null, `(SELECT count(*) FROM public.cai_rango WHERE empresa_id = '${E}')`));
      afirmar(await p.locator('[data-cai]').count() === n, 'no salen todos los rangos de CAI');
    }
    await ctx.close();
  });

  await prueba('Mi negocio: el dueño cambia el nombre legal con motivo; el admin solo lo ve', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    await ir(p, 'ajustes/negocio', '#fiscal-nombre');
    const antes = await p.inputValue('#fiscal-nombre');
    paso = 'RTN malo';
    await p.fill('#fiscal-rtn', '0801-12');
    await p.click('#fiscal-guardar');
    afirmar((await textoDe(p, '#t-fis + form .mensaje-error, form .mensaje-error')).includes('14 números'), 'no avisó del RTN corto');
    paso = 'guardar';
    await p.fill('#fiscal-rtn', sql(null, `(SELECT coalesce(rtn, '') FROM public.empresa WHERE id = '${E}')`));
    await p.fill('#fiscal-nombre', antes + ' S. de R.L.');
    await p.click('#fiscal-guardar');
    await motivo(p, 'Prueba: nombre legal completo');
    await p.waitForSelector('text=Datos fiscales guardados', { timeout: 15000 });
    afirmar(sql(null, `(SELECT nombre FROM public.empresa WHERE id = '${E}')`) === antes + ' S. de R.L.', 'no se guardó el nombre legal');
    sqlEscribir(DUENO, `SELECT public.configurar_datos_fiscales('${E}', jsonb_build_object('nombre', '${antes.replace(/'/g, "''")}'), 'Prueba: dejarlo como estaba')`);
    await ctx.close();
    const otra = await nueva();
    await entrar(otra.p, ADMIN);
    await ir(otra.p, 'ajustes/negocio', '#t-neg');
    afirmar(await otra.p.locator('#fiscal-nombre').count() === 0, 'el admin puede editar los datos fiscales');
    await otra.ctx.close();
  });

  await prueba('Vender: las existencias del buscador son solo las de la tienda', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    const m = await p.evaluate(async () => {
      const d = await import('/js/datos.js');
      const todas = await d.existenciasPorProducto();
      const tienda = await d.existenciasPorProducto({ soloTiendas: true });
      return [[...todas.entries()], [...tienda.entries()]];
    });
    const todas = new Map(m[0]), tienda = new Map(m[1]);
    const esperado = sql(null, `(SELECT coalesce(jsonb_object_agg(producto_id, c), '{}')::text FROM (SELECT s.producto_id, sum(s.cantidad) c
      FROM public.inventario_saldo s JOIN public.bodega b ON b.id = s.bodega_id WHERE b.empresa_id = '${E}' AND b.vende AND b.activa GROUP BY 1) x)`);
    const ok = Object.entries(JSON.parse(esperado)).every(([k, v]) => Number(tienda.get(k) || 0) === Number(v));
    afirmar(ok, 'las existencias de la tienda no cuadran con la base');
    afirmar([...todas.values()].reduce((a, b) => a + b, 0) >= [...tienda.values()].reduce((a, b) => a + b, 0), 'la tienda suma más que todo');
    await ctx.close();
  });

  if (erroresJs.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + erroresJs.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total})`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
