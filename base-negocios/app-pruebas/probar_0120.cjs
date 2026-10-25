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

  // ===================== 2) Garantías =====================
  await prueba('garantías: el comprobante de la venta dice "Garantía hasta"; buscar, registrar el reclamo y su comprobante sin emojis', async () => {
    const p = usar(dueno.p);
    await venderCon(p, ['TAL-500']);
    await p.click('[data-forma=efectivo]');
    await p.click('#cobrar');
    await p.waitForSelector('.comprobante', { timeout: 15000 });
    const hasta = sql('dueno@demo.hn', `to_char(public.hoy_local(demo.id('EMPRESA')) + 180, 'DD/MM/YYYY')`);
    afirmar((await textoDe(p, '[data-dato=garantia]')).trim() === 'Garantía hasta ' + hasta, 'comprobante: ' + await textoDe(p, '.comprobante'));
    paso = 'menú';
    await p.goto(URL_APP + '/#/vender/garantias');
    await p.waitForSelector('#t-garantias');
    afirmar(await p.locator('a.subpestana[href="#/vender/garantias"] svg').count() === 1, 'subpestaña sin ícono');
    paso = 'buscar';
    await p.fill('#garantia-buscar', 'Pedro Castillo');
    await p.press('#garantia-buscar', 'Enter');
    await p.waitForSelector('#garantia-resultados [data-estado=vigente]');
    afirmar((await textoDe(p, '#garantia-resultados')).includes('Taladro eléctrico 500 W'), 'no encontró el taladro');
    await p.click('#garantia-resultados [data-accion=registrar-reclamo]');
    await p.fill('#reclamo-motivo', 'El cable viene pelado');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('[data-dato=reclamo-numero]', { timeout: 15000 });
    const comp = await textoDe(p, '.comprobante');
    afirmar(comp.includes('RECLAMO DE GARANTÍA') && comp.includes('El cable viene pelado') && comp.includes('Pedro Castillo'), 'comprobante: ' + comp);
    afirmar(!emojis.test(comp) && await p.locator('.comprobante svg').count() === 0, 'emojis o íconos en el comprobante del reclamo');
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM public.garantia_reclamo WHERE motivo = 'El cable viene pelado')`) === '1', 'no se guardó una sola vez');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_garantia_comprobante.png'), fullPage: true });
  });

  await prueba('garantías: reclamos abiertos, pasar a revisión y resolver "reparado" con el costo como gasto', async () => {
    const p = usar(dueno.p);
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    await p.goto(URL_APP + '/#/vender/garantias');
    await p.waitForSelector('#reclamos-abiertos [data-reclamo]');
    const fila = p.locator('#reclamos-abiertos [data-reclamo]', { hasText: 'Se calienta y se apaga' });
    await fila.locator('[data-accion=en-revision]').click();
    await p.waitForSelector('#reclamos-abiertos [data-estado=en_revision]');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_garantias.png'), fullPage: true });
    await p.locator('#reclamos-abiertos [data-reclamo]', { hasText: 'Se calienta y se apaga' }).locator('[data-accion=resolver]').click();
    await p.waitForSelector('#t-resolver');
    await p.fill('#resolver-costo', '150');
    await p.selectOption('#resolver-costo-cuenta', id('BAC'));
    await p.fill('#resolver-nota', 'Se cambió el interruptor');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('[data-dato=reclamo-numero]', { timeout: 15000 });
    afirmar((await textoDe(p, '.comprobante')).includes('Reparado'), 'el comprobante no dice la resolución');
    const g = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT r.estado, r.resolucion, g.monto_centavos, g.estado AS gasto
      FROM public.garantia_reclamo r JOIN public.gasto g ON g.id = r.gasto_id WHERE r.motivo = 'Se calienta y se apaga') x)`));
    afirmar(g.estado === 'resuelto' && g.resolucion === 'reparado' && g.monto_centavos === 15000 && g.gasto === 'aplicado', 'base: ' + JSON.stringify(g));
  });

  await prueba('garantías en el celular (vendedor): registra pero no resuelve; sin salirse de la pantalla', async () => {
    const { ctx, p } = await nueva(celular);
    usar(p);
    await entrar(p, 'vendedor@demo.hn');
    await p.goto(URL_APP + '/#/vender/garantias');
    await p.waitForSelector('#reclamos-abiertos');
    afirmar(await p.locator('[data-accion=resolver], [data-accion=rechazar]').count() === 0, 'el vendedor ve Resolver o Rechazar');
    await p.fill('#garantia-buscar', 'Taladro');
    await p.press('#garantia-buscar', 'Enter');
    await p.waitForSelector('#garantia-resultados [data-accion=registrar-reclamo]');
    afirmar(await anchoPagina(p) <= 390, 'se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_garantias_celular.png'), fullPage: true });
    await ctx.close();
  });

  // ===================== 3) Abonos con cheque =====================
  await prueba('cobrar con cheque desde la ficha del cliente: pide los datos, no deja saldo a favor y queda por depositar', async () => {
    const p = usar(dueno.p);
    await p.goto(URL_APP + '/#/inicio/hoy');
    await p.waitForSelector('[data-dato=ventas_hoy]');
    await p.goto(URL_APP + '/#/clientes/lista');
    await p.waitForSelector('#buscar-cliente');
    await p.getByRole('button', { name: 'Ver a Pedro Castillo' }).click();
    await p.click('#cobrar-abono');
    await p.waitForSelector('#abono-forma');
    await p.selectOption('#abono-forma', 'cheque');
    await p.fill('#abono-monto', '9999');
    await p.click('form.formulario button[type=submit]');
    afirmar((await textoDe(p, '.formulario .mensaje-error')).includes('Con cheque se cobra hasta lo que debe'), 'dejó cobrar de más con cheque');
    await p.fill('#abono-monto', '100');
    await p.click('form.formulario button[type=submit]');
    afirmar((await textoDe(p, '.formulario .mensaje-error')).includes('número del cheque'), 'no pidió los datos del cheque');
    await p.fill('#cheque-numero', '556677');
    await p.fill('#cheque-banco-emisor', 'BAC Credomatic');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#t-cobok', { timeout: 15000 });
    const ch = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT estado, monto_centavos, banco_emisor FROM public.cheque_recibido WHERE numero_cheque = '556677') x)`));
    afirmar(ch.estado === 'por_depositar' && ch.monto_centavos === 10000 && ch.banco_emisor === 'BAC Credomatic', 'cheque: ' + JSON.stringify(ch));
  });

  await prueba('Dinero: cheques por depositar con "Depositar" (queda en tránsito) y "Rebotó" (el cliente vuelve a deber, cargo del banco)', async () => {
    const p = usar(dueno.p);
    await p.goto(URL_APP + '/#/dinero/donde');
    await p.waitForSelector('[data-dato=cheques-detalle]');
    afirmar((await textoDe(p, '[data-dato=cheques-detalle]')).includes('3 cheques por depositar'), 'dónde está mi dinero: ' + await textoDe(p, '[data-dato=cheques-detalle]'));
    await p.goto(URL_APP + '/#/dinero/depositos');
    await p.waitForSelector('#lista-cheques');
    afirmar(await p.locator('#lista-cheques [data-estado=posfechado]').count() === 1, 'no marca el posfechado');
    afirmar(await p.locator('#lista-cheques [data-cheque]', { hasText: '120077' }).locator('[data-accion=depositar-cheque]').count() === 0, 'deja depositar un posfechado');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_cheques.png'), fullPage: true });
    // Depositar el del Taller Mejía al BAC.
    await p.locator('#lista-cheques [data-cheque]', { hasText: '004518' }).locator('[data-accion=depositar-cheque]').click();
    await p.selectOption('#cheque-banco', id('BAC'));
    await p.fill('#cheque-referencia', 'Boleta 7777');
    await p.click('#cheque-depositar-si');
    await p.waitForSelector('#lista-cheques [data-estado=depositado]');
    afirmar(sql('dueno@demo.hn', `(SELECT o.estado FROM public.cheque_recibido c JOIN public.operacion_dinero o ON o.id = c.operacion_deposito_id WHERE c.numero_cheque = '004518')`) === 'en_transito', 'depósito no quedó en tránsito');
    afirmar(await p.locator('#lista-transito [data-transito]').count() >= 1, 'no sale en depósitos en tránsito');
    // Rebotó el de Pedro Castillo (por depositar) con cargo del banco de L 25.00.
    const debeAntes = Number(sql('dueno@demo.hn', `(SELECT coalesce(sum(saldo_centavos), 0) FROM public.v_cxc_documento WHERE cliente_id = demo.id('CLI3'))`));
    await p.locator('#lista-cheques [data-cheque]', { hasText: '556677' }).locator('[data-accion=cheque-reboto]').click();
    await p.fill('#rebote-motivo', 'Fondos insuficientes');
    await p.fill('#rebote-cargo', '25');
    await p.selectOption('#rebote-categoria', id('CAT_MANT'));
    await p.click('#rebote-si');
    await p.waitForFunction(() => !document.querySelector('dialog[open]'));
    await p.waitForSelector('#t-mover');
    const r = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT c.estado, g.monto_centavos AS cargo, cb.anulada_en IS NOT NULL AS cobro_anulado
      FROM public.cheque_recibido c JOIN public.cobro cb ON cb.id = c.cobro_id LEFT JOIN public.gasto g ON g.id = c.cargo_banco_gasto_id WHERE c.numero_cheque = '556677') x)`));
    const debeDespues = Number(sql('dueno@demo.hn', `(SELECT coalesce(sum(saldo_centavos), 0) FROM public.v_cxc_documento WHERE cliente_id = demo.id('CLI3'))`));
    afirmar(r.estado === 'rechazado' && r.cobro_anulado && r.cargo === 2500 && debeDespues === debeAntes + 10000, 'rebote: ' + JSON.stringify([r, debeAntes, debeDespues]));
  });

  await prueba('cheques en el celular: Depósitos y traslados sin salirse; el cajero cobra con cheque pero no ve Depositar', async () => {
    const { ctx, p } = await nueva(celular);
    usar(p);
    await entrar(p, 'dueno@demo.hn');
    await p.goto(URL_APP + '/#/dinero/depositos');
    await p.waitForSelector('#lista-cheques');
    afirmar(await anchoPagina(p) <= 390, 'se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_cheques_celular.png'), fullPage: true });
    await ctx.close();
    const c2 = await nueva(celular);
    usar(c2.p);
    await entrar(c2.p, 'cajero@demo.hn');
    await c2.p.goto(URL_APP + '/#/caja/cobros');
    await c2.p.waitForSelector('#t-deben', { timeout: 15000 });
    await c2.p.getByRole('button', { name: /Cobrar/ }).first().click();
    await c2.p.waitForSelector('#abono-forma');
    afirmar(await c2.p.locator('#abono-forma option[value=cheque]').count() === 1, 'el cajero no tiene la forma cheque');
    await c2.ctx.close();
  });

  // ===================== 4) Antigüedad de saldos =====================
  await prueba('antigüedad de saldos: totales como el servidor y cuadra, chips por tramo, ordenar, clic al estado de cuenta, Excel e imprimir', async () => {
    const p = usar(dueno.p);
    await p.goto(URL_APP + '/#/reportes/antiguedad');
    await p.waitForSelector('#tabla-antiguedad');
    afirmar(await p.locator('a.subpestana[href="#/reportes/antiguedad"] svg').count() === 1, 'subpestaña sin ícono');
    const r = JSON.parse(sql('dueno@demo.hn', `public.antiguedad_saldos(demo.id('EMPRESA'))`));
    afirmar(r.cuadra === true, 'el servidor dice que no cuadra');
    afirmar((await textoDe(p, '[data-dato=antiguedad-total] .cifra-valor, [data-dato=antiguedad-total]')).includes(lempiras(r.totales.saldo_centavos)), 'total');
    for (const k of ['corriente', 'de_1_a_30', 'de_31_a_60', 'de_61_a_90', 'mas_de_90']) {
      afirmar((await textoDe(p, `[data-dato=total-${k}]`)).trim() === lempiras(r.totales[k + '_centavos']), 'total ' + k);
    }
    afirmar(await p.locator('[data-info=cuadra]').count() === 1, 'no dice que cuadra');
    afirmar(await p.locator('#tabla-antiguedad .tramo-4').count() >= 1, 'no hay chips de más de 90 (rojo)');
    // Mayor saldo primero (como el servidor); por nombre cambia el orden.
    const primero = await p.locator('#tabla-antiguedad tbody tr:first-child [data-tercero]').getAttribute('data-tercero');
    afirmar(primero === r.terceros[0].tercero_id, 'no empieza por el mayor saldo');
    await p.selectOption('#antiguedad-orden', 'nombre');
    const nombres = await p.locator('#tabla-antiguedad tbody [data-tercero]').allInnerTexts();
    afirmar(nombres.join('|') === [...nombres].sort((a, b) => a.localeCompare(b, 'es')).join('|'), 'no ordena por nombre');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_antiguedad.png'), fullPage: true });
    // Excel
    const [desc] = await Promise.all([p.waitForEvent('download'), p.click('#antiguedad-excel')]);
    afirmar(/^antiguedad_de_saldos_de_clientes.*\.xlsx$/.test(desc.suggestedFilename()), 'archivo: ' + desc.suggestedFilename());
    // Imprimir: solo la hoja, sin colores ni íconos.
    await p.evaluate(() => { window.print = () => { window.__impreso = document.querySelector('.reporte-impreso'); }; });
    await p.click('#antiguedad-imprimir');
    await p.waitForFunction(() => window.__impreso, null, { timeout: 15000 });
    const imp = await p.evaluate(() => { const x = window.__impreso; return { t: x.textContent, raro: x.querySelectorAll('svg, .icono, .chip-color, .burbuja').length }; });
    afirmar(imp.raro === 0 && !emojis.test(imp.t) && imp.t.includes('Antigüedad de saldos de clientes'), 'impreso: ' + JSON.stringify(imp.raro));
    await p.evaluate(() => { window.dispatchEvent(new Event('afterprint')); window.__impreso = null; });
    // Clic en un cliente: su estado de cuenta.
    await p.locator('#tabla-antiguedad tbody [data-tercero]').first().click();
    await p.waitForSelector('#t-ec', { timeout: 15000 });
    // Proveedores
    await p.goto(URL_APP + '/#/reportes/ventas');
    await p.goto(URL_APP + '/#/reportes/antiguedad');
    await p.waitForSelector('#antiguedad-tipo');
    await p.selectOption('#antiguedad-tipo', 'cxp');
    await p.waitForFunction(() => /Proveedor/.test((document.querySelector('#tabla-antiguedad thead') || {}).innerText || ''));
    const rp = JSON.parse(sql('dueno@demo.hn', `public.antiguedad_saldos(demo.id('EMPRESA'), NULL, 'cxp')`));
    afirmar(rp.cuadra === true && (await textoDe(p, '[data-dato=total-mas_de_90]')).trim() === lempiras(rp.totales.mas_de_90_centavos), 'proveedores');
  });

  await prueba('antigüedad en el celular: la tabla se ve como tarjetas sin salirse de la pantalla', async () => {
    const { ctx, p } = await nueva(celular);
    usar(p);
    await entrar(p, 'dueno@demo.hn');
    await p.goto(URL_APP + '/#/reportes/antiguedad');
    await p.waitForSelector('#tabla-antiguedad');
    afirmar(await anchoPagina(p) <= 390, 'se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'v12_antiguedad_celular.png'), fullPage: true });
    await ctx.close();
  });

  afirmar(true, '');
  if (erroresJs.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + erroresJs.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total})`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
