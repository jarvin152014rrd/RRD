// PRUEBA: app 0.12.0 (núcleo 0.18.0) en el navegador (Chromium con Playwright) contra la base de demo: precio
// mayorista (ficha del producto y del cliente, Vender con el chip y el precio que cambia solo, comprobante),
// garantías, abonos con cheque (cobrar, depositar y "rebotó") y antigüedad de saldos (tabla, totales, Excel e
// imprimir), en computadora y celular. La corre herramientas/probar_app.sh.
// Variables: URL_APP, BASE_DEMO, CAPTURAS (carpeta), PG* del servidor local.
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
    if (global.paginaActual) await global.paginaActual.screenshot({ path: path.join(CAPTURAS, 'falla_' + total + '.png'), fullPage: true }).catch(() => {}); console.log(`  FALLA  ${nombre}\n           ${paso ? '[' + paso + '] ' : ''}${String(e.message).split('\n')[0]}`); }
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
const codigoCrudo = /\b[A-Z]{3,}_[A-Z_]+\b/;
const emojis = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u;
const id = (clave) => sql(null, `demo.id('${clave}')`);
const calculado = (p) => p.waitForSelector('.vender:not([data-calculando])', { timeout: 10000 });
async function venderCon(p, codigos) {
  await p.goto(URL_APP + '/#/vender/ventas');
  await p.waitForSelector('#t-dia');
  await p.goto(URL_APP + '/#/vender/nueva');
  await p.waitForSelector('#buscar-producto');
  for (const c of codigos) {
    const antes = await p.locator('.linea-carrito').count();
    await p.fill('#buscar-producto', c);
    await p.press('#buscar-producto', 'Enter');
    await p.waitForFunction((n) => document.querySelectorAll('.linea-carrito').length > n, antes);
  }
  await calculado(p);
}

(async () => {
  const nav = await chromium.launch();
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, ...opciones });
    const p = await ctx.newPage();
    global.paginaActual = p;
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };
  const EMPRESA = sql('dueno@demo.hn', "demo.id('EMPRESA')");
  const celular = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true };
  console.log('Pruebas de la app 0.12.0 (precio mayorista, garantías, cheques, antigüedad):');

  const dueno = await nueva();
  await entrar(dueno.p, 'dueno@demo.hn');
  const usar = (x) => { global.paginaActual = x; return x; };

  // ===================== 1) Precio mayorista =====================
  await prueba('precio mayorista: la ficha lo muestra y se cambia con motivo', async () => {
    const p = usar(dueno.p);
    await p.goto(URL_APP + '/#/inventario/productos');
    await p.fill('#buscar-producto-inv', 'Cemento');
    await p.getByRole('button', { name: 'Ver Cemento gris 42.5 kg' }).click();
    await p.waitForSelector('[data-dato=mayorista]');
    afirmar((await textoDe(p, '[data-dato=mayorista]')).includes('L 250.00 · desde 20'), 'ficha: ' + await textoDe(p, '[data-dato=mayorista]'));
    await p.click('#precio-mayorista');
    await p.fill('#mayorista-precio', '300');
    await p.click('form.formulario button[type=submit]');
    afirmar((await textoDe(p, '.formulario .mensaje-error')).includes('no puede ser mayor'), 'no avisó mayorista > normal');
    await p.fill('#mayorista-precio', '245');
    await p.click('form.formulario button[type=submit]');
    await p.fill('dialog textarea[name=motivo]', 'Nuevo precio de mayoreo');
    await p.click('dialog button[type=submit]');
    await p.waitForSelector('#t-pficha');
    await p.waitForFunction(() => (document.querySelector('[data-dato=mayorista]') || {}).innerText?.includes('L 245.00'));
    afirmar(sql('dueno@demo.hn', `(SELECT precio_mayorista_centavos FROM public.producto WHERE id = demo.id('CEM'))`) === '24500', 'no se guardó');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_producto_mayorista.png'), fullPage: true });
  });

  await prueba('Vender: al elegir un cliente mayorista o subir la cantidad el precio cambia solo, con chip "Mayorista"', async () => {
    const p = usar(dueno.p);
    paso = 'abrir vender';
    // Precio normal de la varilla de la base (otras pruebas pueden haberlo cambiado); mayorista L 170.00 desde 30.
    const pn = Number(sql('dueno@demo.hn', `(SELECT precio_con_isv_centavos FROM public.v_producto WHERE producto_id = demo.id('VAR'))`));
    await venderCon(p, ['VAR-038']);
    paso = 'precio normal';
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === lempiras(pn), 'sin cliente: precio normal');
    afirmar(await p.locator('[data-dato=chip-mayorista]').count() === 0, 'chip sin ser mayorista');
    // Subir la cantidad a 30: 30 x 170.00 = 5,100.00
    await p.fill('.linea-carrito input[name=cantidad]', '30');
    await p.press('.linea-carrito input[name=cantidad]', 'Tab');
    await calculado(p);
    paso = 'chip por cantidad';
    await p.waitForSelector('[data-dato=chip-mayorista]');
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 5,100.00', 'por cantidad: ' + await textoDe(p, '[data-dato=total]'));
    await p.fill('.linea-carrito input[name=cantidad]', '2');
    await p.press('.linea-carrito input[name=cantidad]', 'Tab');
    await calculado(p);
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === lempiras(2 * pn), 'vuelve al normal con 2');
    // Cliente mayorista: 2 x 170.00 = 340.00
    await p.selectOption('#cliente', id('CLI1'));
    await calculado(p);
    await p.waitForSelector('[data-dato=chip-mayorista]');
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 340.00', 'cliente mayorista: ' + await textoDe(p, '[data-dato=total]'));
    afirmar((await textoDe(p, '[data-dato=precio-linea]')).trim() === 'L 170.00', 'precio de la línea');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_vender_mayorista.png'), fullPage: true });
    // Elegir el precio normal y volver al mayorista.
    await p.click('[data-accion=cambiar-precio-tipo]');
    await calculado(p);
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === lempiras(2 * pn), 'precio normal elegido');
    await p.click('[data-accion=cambiar-precio-tipo]');
    await calculado(p);
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 340.00', 'de vuelta al mayorista');
    await p.click('[data-forma=efectivo]');
    await p.click('#cobrar');
    await p.waitForSelector('.comprobante', { timeout: 15000 });
    const comp = await textoDe(p, '.comprobante');
    afirmar(comp.includes(`Precio mayorista (normal ${lempiras(pn)})`), 'el comprobante no lo dice: ' + comp);
    afirmar(!emojis.test(comp), 'emojis en el comprobante');
    const v = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT v.total_centavos, l.precio_tipo FROM public.venta v
      JOIN public.venta_linea l ON l.venta_id = v.id WHERE v.empresa_id = '${EMPRESA}' ORDER BY v.numero DESC LIMIT 1) x)`));
    afirmar(v.total_centavos === 34000 && v.precio_tipo === 'mayorista', 'venta guardada: ' + JSON.stringify(v));
  });

  await prueba('celular: Vender con cliente mayorista sin salirse de la pantalla; ficha del cliente con "Mayorista"', async () => {
    const { ctx, p } = await nueva(celular);
    await entrar(p, 'cajero@demo.hn');
    await venderCon(p, ['VAR-038']);
    await p.selectOption('#cliente', id('CLI1'));
    await calculado(p);
    await p.waitForSelector('[data-dato=chip-mayorista]');
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 170.00', 'varilla mayorista: ' + await textoDe(p, '[data-dato=total]'));
    afirmar(await anchoPagina(p) <= 390, 'se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_vender_mayorista_celular.png'), fullPage: true });
    await ctx.close();
    const p2 = usar(dueno.p);
    await p2.goto(URL_APP + '/#/clientes/lista');
    await p2.waitForSelector('#buscar-cliente');
    await p2.getByRole('button', { name: 'Ver a Constructora Ríos' }).click();
    await p2.waitForSelector('[data-dato=cliente-mayorista]');
    // Marcar a otro cliente como mayorista desde su ficha.
    await p2.goto(URL_APP + '/#/inicio/hoy');
    await p2.waitForSelector('[data-dato=ventas_hoy]');
    await p2.goto(URL_APP + '/#/clientes/lista');
    await p2.waitForSelector('#buscar-cliente');
    await p2.getByRole('button', { name: 'Ver a Taller Mejía' }).click();
    await p2.getByRole('button', { name: 'Editar' }).click();
    await p2.check('#cli-mayorista');
    await p2.click('form.formulario button[type=submit]');
    await p2.waitForSelector('[data-dato=cliente-mayorista]');
    afirmar(sql('dueno@demo.hn', `(SELECT es_mayorista FROM public.tercero WHERE id = demo.id('CLI2'))`) === 'true', 'no se marcó');
    sqlEscribir('dueno@demo.hn', `SELECT public.editar_tercero(demo.id('EMPRESA'), demo.id('CLI2'), '{"es_mayorista": false}', 'Prueba: volver')`);
  });

  // [PARTES SIGUIENTES]

  afirmar(true, '');
  if (erroresJs.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + erroresJs.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total})`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
