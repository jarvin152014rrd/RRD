// PRUEBA: Compras y Dinero (app 0.7.0) en el navegador (Chromium con Playwright) contra la base de demo:
// cada pantalla nueva carga, crea, paga, muestra mensajes claros, respeta permisos y no se desborda en el
// celular. Las cifras se comparan con la base (SQL) y con ejemplos hechos a mano.
// La corre herramientas/probar_app.sh después de probar_app.cjs (misma base y servidor).
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
async function prueba(nombre, fn) {
  total++;
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++; console.log(`  FALLA  ${nombre}\n           ${String(e.message).split('\n')[0]}`); }
}
function afirmar(cond, que) { if (!cond) throw new Error(que); }

// Consulta a la base como el usuario indicado (en una transacción que se deshace).
function sql(correo, consulta) {
  const guion = `BEGIN; ${correo ? `SELECT demo.como('${correo}') \\g /dev/null` : ''}
SELECT '@@' || (${consulta})::text; ROLLBACK;`;
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE], { input: guion, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  const linea = r.stdout.split('\n').find((l) => l.startsWith('@@'));
  return linea ? linea.slice(2) : null;
}
const num = (correo, consulta) => Number(sql(correo, consulta));
const id = (clave) => sql(null, `demo.id('${clave}')`);

// Formato esperado, hecho aparte del de la app: 123456 -> "L 1,234.56"
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
const texto = (p, sel) => p.locator(sel).first().innerText();
// Va a una ruta aunque ya esté en ella (tocar la subpestaña vuelve a empezar la pantalla).
async function ir(p, ruta, esperar) {
  if (await p.evaluate(() => location.hash) === '#/' + ruta) await p.click(`a.subpestana[href="#/${ruta}"]`);
  else await p.goto(URL_APP + '/#/' + ruta);
  if (esperar) await p.waitForSelector(esperar, { timeout: 20000 });
}
async function confirmarDialogo(p) {
  await p.waitForSelector('#confirmar-si');
  const t = await p.locator('dialog.dialogo[open]').innerText();
  await p.click('#confirmar-si');
  return t;
}
async function dialogoMotivo(p, motivo) {
  await p.waitForSelector('dialog.dialogo[open] textarea');
  await p.fill('dialog.dialogo[open] textarea', motivo);
  await p.click('dialog.dialogo[open] button[type=submit]');
  await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
}
// Sin desbordes a lo ancho y sin "null"/"undefined" en pantalla.
async function revisarPantalla(p, que, ancho) {
  const x = await p.evaluate(() => ({ ancho: document.documentElement.scrollWidth, texto: document.getElementById('app').innerText }));
  afirmar(x.ancho <= ancho, `${que} se sale a lo ancho: ${x.ancho}`);
  afirmar(!/(^|\s)(null|undefined|NaN)(\s|$)/.test(x.texto), `${que} muestra null, undefined o NaN`);
  afirmar(!/\b[A-Z]{3,}_[A-Z_]+\b/.test(x.texto), `${que} muestra un código de error crudo`);
}
const saldoCuenta = (clave) => num('dueno@demo.hn', `(SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE cuenta_dinero_id = demo.id('${clave}'))`);
const existencia = (prod, bod = 'B1') => num('dueno@demo.hn', `(SELECT coalesce(sum(cantidad), 0) FROM public.v_existencia WHERE producto_id = demo.id('${prod}') AND bodega_id = demo.id('${bod}'))`);

(async () => {
  const nav = await chromium.launch();
  const EM = id('EMPRESA');
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, ...opciones });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };
  const celular = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true };

  console.log('Pruebas de Compras y Dinero (app 0.7.0):');
  const d = await nueva();
  await entrar(d.p, 'dueno@demo.hn');

  // ============================ PARTE 1: COMPRAS ============================
  await prueba('compras: lista con estado (chips), filtros por fecha y proveedor y cifras iguales a la base', async () => {
    const p = d.p;
    await ir(p, 'compras/compras', '#lista-compras');
    const hoy = sql('dueno@demo.hn', `public.hoy_local('${EM}')`);
    const filtro = `empresa_id = '${EM}' AND fecha_contable BETWEEN '${hoy}'::date - 60 AND '${hoy}'`;
    const n = num('dueno@demo.hn', `(SELECT count(*) FROM public.compra WHERE ${filtro})`);
    afirmar(await p.locator('#lista-compras [data-compra]').count() === n, 'cantidad de compras distinta a la base: ' + n);
    const totalBase = num('dueno@demo.hn', `(SELECT coalesce(sum(total_centavos), 0) FROM public.compra WHERE ${filtro} AND anulada_en IS NULL)`);
    afirmar((await texto(p, '[data-dato=compras-total]')).trim() === lempiras(totalBase), 'total comprado distinto a la base');
    // 0.9.0: las cifras las suma el servidor (totales_compras) y cuadran con la base.
    afirmar(await p.locator('.cifras[data-fuente=servidor] [data-dato=compras-total]').count() === 1, 'las cifras no salen de totales_compras');
    const debe = num('dueno@demo.hn', `(SELECT coalesce(sum(d.saldo_centavos), 0) FROM public.v_cxp_documento d JOIN public.compra c ON c.id = d.compra_id WHERE c.${filtro.replace(/ AND fecha/, ' AND c.fecha')})`);
    afirmar((await texto(p, '[data-dato=compras-debo]')).trim() === lempiras(debe), 'lo que se debe distinto a la base');
    // CN-552 (Cementos del Norte, al crédito, 15 días) ya venció: chip rojo "Vencida".
    const cn = sql('dueno@demo.hn', `(SELECT id FROM public.compra WHERE numero_documento = 'CN-552')`);
    afirmar(await p.locator(`[data-compra="${cn}"]`).getAttribute('data-estado') === 'vencida', 'CN-552 no sale vencida');
    afirmar((await p.locator(`[data-compra="${cn}"] .chip-rojo`).count()) === 1, 'el chip de vencida no es rojo');
    // FL-1088 (de contado) sale pagada.
    const fl = sql('dueno@demo.hn', `(SELECT id FROM public.compra WHERE numero_documento = 'FL-1088')`);
    afirmar(await p.locator(`[data-compra="${fl}"]`).getAttribute('data-estado') === 'pagada', 'la compra de contado no sale pagada');
    // Filtro por proveedor.
    await p.selectOption('#compras-proveedor', id('PROV2'));
    await p.waitForFunction(() => document.querySelectorAll('#lista-compras [data-compra]').length === 1);
    afirmar((await texto(p, '#lista-compras')).includes('Cementos del Norte'), 'el filtro por proveedor no funciona');
    // Filtro por fecha: un rango sin compras enseña qué hacer.
    await p.fill('#compras-desde', '2001-01-01'); await p.fill('#compras-hasta', '2001-01-31');
    await p.dispatchEvent('#compras-hasta', 'change');
    await p.waitForSelector('#contenido .estado-vacio');
    afirmar((await texto(p, '#contenido')).includes('No hay compras con esos filtros'), 'sin compras no lo dice');
    await p.selectOption('#compras-proveedor', '');
    await p.fill('#compras-desde', sql('dueno@demo.hn', `('${hoy}'::date - 60)`)); await p.fill('#compras-hasta', hoy);
    await p.dispatchEvent('#compras-hasta', 'change');
    await p.waitForSelector('#lista-compras');
  });

  await prueba('compras: nueva de contado (ISV del núcleo, a mano), entra al inventario, sale de la caja; un reintento no duplica; anular devuelve todo', async () => {
    const p = d.p;
    const cajaAntes = saldoCuenta('FUERTE'), varAntes = existencia('VAR');
    await ir(p, 'compras/compras', '#nueva-compra');
    await p.click('#nueva-compra');
    await p.waitForSelector('#compra-proveedor');
    await p.selectOption('#compra-proveedor', id('PROV1'));
    await p.fill('#compra-factura', 'FL-7001');
    await p.fill('#compra-buscar', 'varilla');
    await p.click('#compra-resultados [data-producto]');
    // A mano: 3 x L 120.50 = L 361.50; ISV 15 % = 54.225 -> L 54.23 (mitad hacia arriba); total L 415.73.
    await p.fill('[data-campo=cantidad]', '3');
    await p.fill('[data-campo=costo]', '120.50');
    afirmar((await texto(p, '[data-dato=compra-total-aprox]')).trim() === 'L 415.73', 'total aproximado: ' + await texto(p, '[data-dato=compra-total-aprox]'));
    await p.check('input[name=compra-condicion][value=contado]');
    await p.selectOption('#compra-cuenta', id('FUERTE'));
    // La primera respuesta se "pierde" (el servidor sí la guardó): la app reintenta con el MISMO id_operacion.
    let veces = 0;
    await p.route('**/rest/v1/rpc/registrar_compra', async (r) => {
      veces++;
      if (veces === 1) { await r.fetch(); await r.abort('failed'); } else await r.continue();
    });
    await p.click('#compra-guardar');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('Sale de Caja fuerte') && conf.includes('L 415.73'), 'la confirmación no dice de dónde sale ni el total: ' + conf);
    await p.waitForSelector('[data-info=compra-guardada]', { timeout: 20000 });
    await p.unroute('**/rest/v1/rpc/registrar_compra');
    const msj = await texto(p, '[data-info=compra-guardada]');
    afirmar(veces === 2 && msj.includes('L 415.73') && msj.includes('sale de Caja fuerte'), `mensaje (${veces} envíos): ${msj}`);
    afirmar(msj.includes('ISV L 54.23'), 'no muestra el ISV que calculó el núcleo: ' + msj);
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.compra WHERE numero_documento = 'FL-7001')`) === 1, 'el reintento duplicó la compra');
    afirmar(num('dueno@demo.hn', `(SELECT total_centavos FROM public.compra WHERE numero_documento = 'FL-7001')`) === 41573, 'total en la base distinto de 41573');
    afirmar(saldoCuenta('FUERTE') === cajaAntes - 41573, 'la caja fuerte no bajó L 415.73');
    afirmar(existencia('VAR') === varAntes + 3, 'no entraron 3 varillas al inventario');
    afirmar((await texto(p, '#lineas-compra')).includes('L 120.50'), 'el detalle no muestra el costo por unidad');
    await p.screenshot({ path: path.join(CAPTURAS, 'compras_detalle_computadora.png'), fullPage: true });
    // Anular: motivo, contrapartida, la caja recupera y el inventario vuelve.
    await p.click('#compra-anular');
    await dialogoMotivo(p, 'Factura equivocada de prueba');
    await p.waitForSelector('#contenido .chip-color[data-estado=anulada]');
    afirmar((await texto(p, '#contenido')).includes('L 415.73 volvieron a Caja fuerte'), 'el mensaje de anulación no dice a dónde volvió el dinero');
    afirmar(saldoCuenta('FUERTE') === cajaAntes && existencia('VAR') === varAntes, 'anular no devolvió el dinero o el inventario');
    afirmar(sql('dueno@demo.hn', `(SELECT motivo_anulacion FROM public.compra WHERE numero_documento = 'FL-7001')`) === 'Factura equivocada de prueba', 'no guardó el motivo');
  });

  await prueba('compras: al crédito con vencimiento por el plazo del proveedor y chip "Por pagar"; campos vacíos con mensaje claro', async () => {
    const p = d.p;
    await ir(p, 'compras/compras', '#nueva-compra');
    await p.click('#nueva-compra');
    await p.waitForSelector('#compra-proveedor');
    // Vacío: dice qué falta, sin llamar al servidor.
    await p.click('#compra-guardar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('Elija el proveedor'), 'vacío: no pide el proveedor');
    await p.selectOption('#compra-proveedor', id('PROV2'));
    await p.fill('#compra-factura', 'CN-7002');
    await p.click('#compra-guardar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('Agregue al menos un producto'), 'sin productos no lo dice');
    await p.fill('#compra-buscar', 'CEM-425');
    await p.click('#compra-resultados [data-producto]');
    await p.fill('[data-campo=cantidad]', '-2');
    await p.click('#compra-guardar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('Escriba la cantidad'), 'cantidad rara no se rechaza');
    // A mano: 2 x L 190.00 = L 380.00 + ISV 57.00 = L 437.00. Plazo de Cementos del Norte: 15 días.
    await p.fill('[data-campo=cantidad]', '2');
    await p.fill('[data-campo=costo]', '190');
    const hoy = sql('dueno@demo.hn', `public.hoy_local('${EM}')`);
    const vence = sql('dueno@demo.hn', `('${hoy}'::date + 15)`);
    afirmar(await p.inputValue('#compra-vence') === vence, 'el vencimiento no usa el plazo del proveedor');
    await p.click('#compra-guardar');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('Al crédito') && conf.includes('L 437.00'), 'confirmación al crédito: ' + conf);
    await p.waitForSelector('[data-info=compra-guardada]');
    afirmar(num('dueno@demo.hn', `(SELECT total_centavos FROM public.compra WHERE numero_documento = 'CN-7002')`) === 43700, 'total al crédito distinto de 43700');
    afirmar(await p.locator('[data-dato=compra-saldo]').count() === 1 && (await texto(p, '[data-dato=compra-saldo]')).trim() === 'L 437.00', 'no dice cuánto se debe');
    await ir(p, 'compras/compras', '#lista-compras');
    const c = sql('dueno@demo.hn', `(SELECT id FROM public.compra WHERE numero_documento = 'CN-7002')`);
    afirmar(await p.locator(`[data-compra="${c}"]`).getAttribute('data-estado') === 'por_pagar', 'la compra al crédito no sale "Por pagar"');
  });

  await prueba('pagar a proveedores: chips (vencida, por vencer, al día), pago parcial con mensaje claro, no deja pagar de más', async () => {
    const p = d.p;
    await ir(p, 'compras/pagos', '#lista-cxp');
    const totalBase = num('dueno@demo.hn', `(SELECT coalesce(sum(saldo_centavos), 0) FROM public.v_cxp_documento WHERE empresa_id = '${EM}')`);
    afirmar((await texto(p, '[data-dato=cxp-total]')).trim() === lempiras(totalBase), 'total por pagar distinto a la base');
    const vencidas = num('dueno@demo.hn', `(SELECT count(*) FROM public.v_cxp_documento WHERE empresa_id = '${EM}' AND fecha_vencimiento < public.hoy_local('${EM}'))`);
    afirmar(await p.locator('#lista-cxp [data-documento][data-estado=vencida]').count() === vencidas, 'cantidad de vencidas distinta');
    const doc = sql('dueno@demo.hn', `(SELECT documento_id FROM public.v_cxp_documento WHERE numero_documento = 'CN-7002')`);
    afirmar(await p.locator(`[data-documento="${doc}"]`).getAttribute('data-estado') === 'al_dia', 'la de 15 días no sale al día');
    // Lo vencido va primero.
    afirmar(await p.locator('#lista-cxp [data-documento]').first().getAttribute('data-estado') === 'vencida', 'lo vencido no va primero');
    await p.locator(`[data-documento="${doc}"] button`).click();
    await p.waitForSelector('#pago-monto');
    afirmar(await p.inputValue('#pago-monto') === '437.00', 'el monto no empieza en lo que se debe');
    await p.fill('#pago-monto', '500');
    await p.selectOption('#pago-cuenta', id('BAC'));
    await p.click('#pagar-guardar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('No puede pagar más de lo que debe: L 437.00'), 'deja pagar de más');
    const bacAntes = saldoCuenta('BAC');
    await p.fill('#pago-monto', '100');
    afirmar((await texto(p, '#pago-tipo')).includes('Pago parcial: quedará debiendo L 337.00'), 'no explica que es parcial');
    await p.click('#pagar-guardar');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('Pago de L 100.00 a Cementos del Norte · sale de BAC cheques'), 'confirmación del pago: ' + conf);
    await p.waitForSelector('#t-pagook');
    const msj = await texto(p, '#contenido .mensaje-ok');
    afirmar(msj.includes('Pago de L 100.00 a Cementos del Norte · sale de BAC cheques') && msj.includes('Todavía le debe L 337.00'), 'mensaje del pago: ' + msj);
    afirmar(saldoCuenta('BAC') === bacAntes - 10000, 'el BAC no bajó L 100.00');
    afirmar(num('dueno@demo.hn', `(SELECT saldo_centavos FROM public.v_cxp_documento WHERE documento_id = '${doc}')`) === 33700, 'el saldo en la base no es 33700');
    // El pago sale en el detalle de la compra y se puede anular (vuelve al BAC).
    await ir(p, 'compras/compras', '#lista-compras');
    await p.locator(`[data-compra="${doc}"] button`).click();
    await p.waitForSelector('[data-pago]');
    afirmar(await p.locator('#compra-anular').count() === 0 && (await texto(p, '#contenido')).includes('primero anule sus pagos'), 'deja anular una compra con pagos');
    await p.locator('[data-pago] button', { hasText: 'Anular pago' }).click();
    await dialogoMotivo(p, 'Pago duplicado de prueba');
    await p.waitForSelector('[data-pago] [data-estado=anulado]');
    afirmar(saldoCuenta('BAC') === bacAntes, 'anular el pago no devolvió el dinero al BAC');
  });

  await prueba('proveedores: crear, editar y ficha con lo que se le debe y su historial', async () => {
    const p = d.p;
    await ir(p, 'compras/proveedores', '#lista-proveedores');
    const deuda = num('dueno@demo.hn', `(SELECT coalesce(sum(saldo_centavos), 0) FROM public.v_cxp_documento WHERE empresa_id = '${EM}')`);
    afirmar((await texto(p, '[data-dato=debo-total]')).trim() === lempiras(deuda), 'total que debo distinto');
    await p.click('#nuevo-proveedor');
    await p.fill('#prov-nombre', 'Importadora Santa Rosa');
    await p.fill('#prov-rtn', '0801-1985-77712');
    await p.click('#prov-guardar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('14 números'), 'RTN corto no se rechaza');
    await p.fill('#prov-rtn', '0801-1985-777123');
    await p.fill('#prov-plazo', '45');
    await p.click('#prov-guardar');
    await p.waitForSelector('#t-fprov');
    afirmar(sql('dueno@demo.hn', `(SELECT es_proveedor || '|' || plazo_dias || '|' || rtn FROM public.tercero WHERE nombre = 'Importadora Santa Rosa')`) === 'true|45|08011985777123', 'no quedó como proveedor con su plazo y RTN');
    await p.click('#editar-proveedor');
    await p.fill('#prov-telefono', '2222-3333');
    await p.fill('#prov-motivo', 'Teléfono nuevo');
    await p.click('#prov-guardar');
    await p.waitForFunction(() => document.querySelector('#t-fprov') && document.getElementById('contenido').innerText.includes('22223333'));
    // Ficha de Cementos del Norte: lo que se le debe (igual a la base) y el historial de compras y pagos.
    await ir(p, 'compras/proveedores', '#lista-proveedores');
    await p.locator(`[data-proveedor="${id('PROV2')}"] button`).click();
    await p.waitForSelector('#historial-proveedor');
    const debe = num('dueno@demo.hn', `(SELECT coalesce(sum(saldo_centavos), 0) FROM public.v_cxp_documento WHERE proveedor_id = demo.id('PROV2'))`);
    afirmar((await texto(p, '[data-dato=saldo-proveedor]')).trim() === lempiras(debe), 'lo que se le debe al proveedor no coincide');
    afirmar(await p.locator('#historial-proveedor [data-historial=compra]').count() >= 2 && await p.locator('#historial-proveedor [data-historial=pago]').count() >= 1, 'historial sin compras o pagos');
    await p.screenshot({ path: path.join(CAPTURAS, 'compras_ficha_proveedor_computadora.png'), fullPage: true });
  });

  await prueba('compras: permisos (cajero y vendedor no ven Compras; la ruta los lleva a Inicio)', async () => {
    for (const correo of ['cajero@demo.hn', 'vendedor@demo.hn']) {
      const { ctx, p } = await nueva();
      await entrar(p, correo);
      const pestanas = (await p.locator('.pestanas .pestana').allInnerTexts()).map((t) => t.trim());
      afirmar(!pestanas.includes('Compras'), `${correo} ve la pestaña Compras`);
      for (const r of ['compras/compras', 'compras/proveedores', 'compras/pagos']) {
        await p.goto(URL_APP + '/#/' + r);
        await p.waitForFunction(() => location.hash === '#/inicio/hoy');
      }
      await ctx.close();
    }
  });

  await prueba('compras en el celular: lista, nueva compra, pago y ficha sin desbordes (con capturas)', async () => {
    const { ctx, p } = await nueva(celular);
    await entrar(p, 'dueno@demo.hn');
    await ir(p, 'compras/compras', '#lista-compras');
    await revisarPantalla(p, 'compras (celular)', 390);
    await p.click('#nueva-compra');
    await p.waitForSelector('#compra-proveedor');
    await p.fill('#compra-buscar', 'pintura');
    await p.click('#compra-resultados [data-producto]');
    await p.fill('[data-campo=cantidad]', '4'); await p.fill('[data-campo=costo]', '360');
    await revisarPantalla(p, 'nueva compra (celular)', 390);
    await p.screenshot({ path: path.join(CAPTURAS, 'compras_nueva_celular.png'), fullPage: true });
    await ir(p, 'compras/pagos', '#lista-cxp');
    await revisarPantalla(p, 'pagar a proveedores (celular)', 390);
    await p.locator('#lista-cxp [data-documento] button').first().click();
    await p.waitForSelector('#pago-monto');
    await revisarPantalla(p, 'formulario de pago (celular)', 390);
    await p.screenshot({ path: path.join(CAPTURAS, 'compras_pagar_celular.png'), fullPage: true });
    await ir(p, 'compras/proveedores', '#lista-proveedores');
    await p.locator('[data-proveedor] button').first().click();
    await p.waitForSelector('#t-fprov');
    await revisarPantalla(p, 'ficha de proveedor (celular)', 390);
    await ctx.close();
  });

  await prueba('arreglo: editar un cliente guarda (antes la app mandaba un id_operacion que editar_tercero no recibe)', async () => {
    const p = d.p;
    await ir(p, 'clientes/lista', '#buscar-cliente');
    await p.locator(`[data-cliente="${id('CLI3')}"] button`).click();
    await p.waitForSelector('#t-ficha');
    await p.getByRole('button', { name: 'Editar' }).click();
    await p.fill('#cli-telefono', '3333-4444');
    await p.click('form button[type=submit]');
    await p.waitForSelector('#t-ficha');
    afirmar(sql('dueno@demo.hn', `(SELECT telefono FROM public.tercero WHERE id = demo.id('CLI3'))`) === '33334444', 'el cambio del cliente no se guardó');
  });

  // ============================ PARTE 2: DINERO ============================
  await prueba('todos los gastos: filtros, gasto desde el banco (sale de BAC, monto a mano) y del admin sobre su tope queda en espera', async () => {
    const p = d.p;
    await ir(p, 'dinero/gastos', '#lista-gastos');
    const hoy = sql('dueno@demo.hn', `public.hoy_local('${EM}')`);
    const n = num('dueno@demo.hn', `(SELECT count(*) FROM public.v_gasto WHERE empresa_id = '${EM}' AND fecha_contable BETWEEN '${hoy}'::date - 30 AND '${hoy}')`);
    afirmar(await p.locator('#lista-gastos [data-gasto]').count() === n, 'cantidad de gastos distinta a la base');
    // 0.9.0: gastado y en espera los suma el servidor (totales_gastos) y cuadran con la base.
    const g = (e) => num('dueno@demo.hn', `(SELECT coalesce(sum(monto_centavos), 0) FROM public.v_gasto WHERE empresa_id = '${EM}' AND estado = '${e}' AND fecha_contable BETWEEN '${hoy}'::date - 30 AND '${hoy}')`);
    afirmar(await p.locator('.cifras[data-fuente=servidor]').count() === 1 && (await texto(p, '[data-dato=gastos-total]')).trim() === lempiras(g('aplicado'))
      && (await texto(p, '[data-dato=gastos-espera]')).trim() === lempiras(g('pendiente_aprobacion')), 'cifras de gastos distintas a la base');
    await p.selectOption('#gastos-categoria', id('CAT_LUZ'));
    await p.waitForFunction(() => [...document.querySelectorAll('#lista-gastos [data-gasto]')].every((x) => x.innerText.includes('Energía')));
    await p.selectOption('#gastos-categoria', '');
    const bac = saldoCuenta('BAC');
    await p.click('#nuevo-gasto');
    await p.waitForSelector('#gasto-cuenta');
    await p.click('#gasto-guardar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('de qué caja o banco'), 'vacío no pide la cuenta');
    await p.selectOption('#gasto-cuenta', id('BAC'));
    await p.selectOption('#gasto-categoria', id('CAT_MANT'));
    await p.fill('#gasto-monto', '1,150.00');
    await p.fill('#gasto-descripcion', 'Papel y tinta para la oficina');
    await p.check('#gasto-con-factura');
    await p.fill('#gasto-factura', 'F-9001');
    await p.fill('#gasto-rtn', '0801-1999-000333');
    await p.click('#gasto-guardar');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('Gasto de L 1,150.00') && conf.includes('sale de BAC cheques'), 'confirmación del gasto: ' + conf);
    await p.waitForSelector('[data-info=gasto-guardado]');
    // A mano: 115,000 con ISV 15 % incluido -> ISV 15,000 (L 150.00).
    afirmar((await texto(p, '[data-info=gasto-guardado]')).includes('L 150.00 es ISV'), 'no separa el ISV: ' + await texto(p, '[data-info=gasto-guardado]'));
    afirmar(saldoCuenta('BAC') === bac - 115000, 'el BAC no bajó L 1,150.00');
    // Admin con tope de L 5,000: un gasto de L 6,000 queda en espera, sin mover dinero.
    const { ctx, p: pa } = await nueva();
    await entrar(pa, 'admin@demo.hn');
    await ir(pa, 'dinero/gastos', '#nuevo-gasto');
    await pa.click('#nuevo-gasto');
    await pa.waitForSelector('#gasto-cuenta');
    afirmar((await texto(pa, '#contenido')).includes('queda en espera de aprobación'), 'no avisa del tope antes de guardar');
    await pa.selectOption('#gasto-cuenta', id('BAC'));
    await pa.selectOption('#gasto-categoria', id('CAT_MANT'));
    await pa.fill('#gasto-monto', '6000');
    await pa.fill('#gasto-descripcion', 'Estantes para la bodega');
    await pa.click('#gasto-guardar');
    await confirmarDialogo(pa);
    await pa.waitForSelector('[data-info=gasto-en-espera]');
    afirmar((await texto(pa, '[data-info=gasto-en-espera]')).includes('en espera de aprobación'), 'no dice que queda en espera');
    afirmar(saldoCuenta('BAC') === bac - 115000, 'el gasto en espera movió dinero');
    await ctx.close();
  });

  await prueba('depósitos y traslados: depósito queda en tránsito, confirmar lo pasa al banco; traslado entre bancos', async () => {
    const p = d.p;
    await ir(p, 'dinero/depositos', '#mover-dinero');
    const fuerte = saldoCuenta('FUERTE'), bac = saldoCuenta('BAC'), atl = saldoCuenta('ATL');
    await p.click('#mover-dinero');
    await p.waitForSelector('#mover-origen');
    await p.selectOption('#mover-origen', id('FUERTE'));
    await p.selectOption('#mover-destino', id('BAC'));
    await p.fill('#mover-monto', '500');
    await p.fill('#mover-referencia', 'Boleta 7777');
    await p.click('#mover-guardar');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('sale de Caja fuerte y entra a BAC cheques') && conf.includes('tránsito'), 'confirmación del depósito: ' + conf);
    await p.waitForSelector('[data-info=movimiento-guardado]');
    afirmar(saldoCuenta('FUERTE') === fuerte - 50000 && saldoCuenta('BAC') === bac, 'el depósito no quedó en tránsito');
    await ir(p, 'dinero/depositos', '#lista-transito');
    const op = sql('dueno@demo.hn', `(SELECT operacion_id FROM public.v_deposito_transito WHERE referencia = 'Boleta 7777')`);
    await p.locator(`[data-transito="${op}"] button`, { hasText: 'Confirmar depósito' }).click();
    await p.click('#confirmar-deposito-si');
    await p.waitForFunction((x) => !document.querySelector(`[data-transito="${x}"]`) && document.getElementById('lista-operaciones'), op);
    afirmar(saldoCuenta('BAC') === bac + 50000, 'confirmar no pasó el dinero al BAC');
    // Traslado BAC -> Atlántida (un banco a otro).
    await p.click('#mover-dinero');
    await p.check('input[name=mover-tipo][value=traslado]');
    await p.selectOption('#mover-origen', id('BAC'));
    await p.selectOption('#mover-destino', id('ATL'));
    await p.fill('#mover-monto', '250.50');
    await p.click('#mover-guardar');
    await confirmarDialogo(p);
    await p.waitForSelector('[data-info=movimiento-guardado]');
    afirmar(saldoCuenta('ATL') === atl + 25050 && saldoCuenta('BAC') === bac + 50000 - 25050, 'el traslado no cuadra');
  });

  await prueba('pagos fijos: lista con próxima fecha, crear, pagar ahora con el monto real y desactivar', async () => {
    const p = d.p;
    await ir(p, 'dinero/pagos-fijos', '#lista-fijos');
    const n = num('dueno@demo.hn', `(SELECT count(*) FROM public.pagos_fijos_proximos('${EM}'))`);
    afirmar(await p.locator('#lista-fijos [data-pago-fijo]').count() === n, 'cantidad de pagos fijos distinta');
    afirmar(await p.locator(`[data-pago-fijo="${id('PF_ALQ')}"]`).getAttribute('data-estado') === 'vencido', 'el alquiler atrasado no sale vencido');
    await p.click('#nuevo-pago-fijo');
    await p.fill('#fijo-nombre', 'Internet de la tienda');
    await p.selectOption('#fijo-categoria', id('CAT_MANT'));
    await p.fill('#fijo-estimado', '950');
    await p.fill('#fijo-dia', '10');
    await p.click('#fijo-guardar');
    await p.waitForSelector('#lista-fijos');
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.pago_fijo WHERE nombre = 'Internet de la tienda' AND activo)`) === 1, 'no se creó el pago fijo');
    // Pagar ahora el alquiler con el monto real (L 12,350.00), sale de BAC.
    const bac = saldoCuenta('BAC');
    const vence = sql('dueno@demo.hn', `(SELECT proximo_vence_el FROM public.pagos_fijos_proximos('${EM}') WHERE pago_fijo_id = demo.id('PF_ALQ'))`);
    await p.locator(`[data-pago-fijo="${id('PF_ALQ')}"] button`, { hasText: 'Pagar ahora' }).click();
    await p.waitForSelector('#fijo-monto');
    afirmar(await p.inputValue('#fijo-monto') === '12000.00', 'no empieza con el monto estimado');
    await p.fill('#fijo-monto', '12350');
    await p.click('#fijo-pagar');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('L 12,350.00') && conf.includes('sale de BAC cheques'), 'confirmación del pago fijo: ' + conf);
    await p.waitForSelector('[data-info=fijo-pagado]');
    afirmar(saldoCuenta('BAC') === bac - 1235000, 'el BAC no bajó el monto real');
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.gasto WHERE pago_fijo_id = demo.id('PF_ALQ') AND pago_fijo_vence_el = '${vence}' AND monto_centavos = 1235000)`) === 1, 'no quedó el gasto del vencimiento más viejo');
    await ir(p, 'dinero/pagos-fijos', '#lista-fijos');
    const internet = sql('dueno@demo.hn', `(SELECT id FROM public.pago_fijo WHERE nombre = 'Internet de la tienda')`);
    await p.locator(`[data-pago-fijo="${internet}"] button`, { hasText: 'Desactivar' }).click();
    await dialogoMotivo(p, 'Ya no se usa este servicio');
    await p.waitForSelector(`#lista-fijos-inactivos [data-pago-fijo="${internet}"]`);
  });

  await prueba('fondos y socios: saldos como la base, de dónde vienen y en qué cuenta están; pagar a un socio; usar un fondo pide el comprobante', async () => {
    const p = d.p;
    await ir(p, 'dinero/fondos', '#lista-fondos');
    const e = JSON.parse(sql('dueno@demo.hn', `public.estado_fondos('${EM}')`));
    afirmar((await texto(p, '[data-dato=total-fondos]')).trim() === lempiras(e.total_reservas_centavos), 'total de fondos distinto');
    for (const f of e.fondos) afirmar((await texto(p, `[data-fondo="${f.fondo_id}"] [data-dato=saldo-fondo]`)).trim() === lempiras(f.saldo_centavos), 'saldo del fondo ' + f.nombre);
    afirmar((await texto(p, `[data-fondo="${id('F_REINV')}"]`)).includes('separado en Atlántida ahorro'), 'no dice en qué cuenta está');
    afirmar((await texto(p, '[data-info=regla]')).includes('Reinversión 40 %'), 'no muestra la regla');
    // Reparto del demo, a mano: Reinversión 40 % + Emergencias 30 % + socios 30 % (María 60 %, Carlos 40 %) suman la base.
    const base = num('dueno@demo.hn', `(SELECT base_centavos FROM public.v_distribucion WHERE empresa_id = '${EM}' AND NOT anulada LIMIT 1)`);
    const partes = e.fondos.reduce((s, f) => s + Number(f.aportes_centavos), 0) + e.socios.reduce((s, x) => s + Number(x.dividendos_pendientes_centavos), 0);
    afirmar(partes === base, `las partes (${partes}) no suman la base (${base})`);
    const socio = e.socios.find((x) => x.nombre === 'Carlos Mejía');
    const atl = saldoCuenta('ATL');
    await p.locator(`[data-socio="${socio.socio_id}"] button`).click();
    await p.fill('#socio-monto', '100');
    await p.selectOption('#socio-cuenta', id('ATL'));
    await p.click('#socio-pagar');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('Pago de L 100.00 a Carlos Mejía · sale de Atlántida ahorro'), 'confirmación a socio: ' + conf);
    await p.waitForSelector('#lista-fondos');
    afirmar(saldoCuenta('ATL') === atl - 10000, 'el pago al socio no salió de Atlántida');
    afirmar((await texto(p, `[data-socio="${socio.socio_id}"] [data-dato=pendiente-socio]`)).trim() === lempiras(socio.dividendos_pendientes_centavos - 10000), 'pendiente del socio');
    await p.click('#usar-fondo');
    await p.waitForSelector('#uso-fondo');
    afirmar(await p.locator('[data-info=sin-almacenamiento]').count() === 1 && await p.locator('#uso-guardar').isDisabled(), 'sin almacenamiento debería explicar y no dejar guardar');
  });

  await prueba('cuadrar con el banco: marcar el cheque a mano, crear comisión e intereses, cuadra y se cierra; CSV del banco', async () => {
    const p = d.p;
    await ir(p, 'dinero/banco', '#solo-banco');
    afirmar(await p.inputValue('#banco-cuenta') === id('BAC'), 'no abre el banco con meses trabajados');
    const r0 = JSON.parse(sql('dueno@demo.hn', `public.ver_conciliacion(demo.id('CONC1'))`));
    afirmar((await texto(p, '[data-dato=saldo-sistema]')).trim() === lempiras(r0.saldo_sistema_centavos), 'saldo del sistema distinto');
    afirmar((await texto(p, '[data-info=formula]')).includes('saldo del banco'), 'sin la fórmula explicada');
    // Montos distintos: no deja marcar.
    const com = r0.en_banco_no_en_sistema.find((x) => x.descripcion.startsWith('COMISION'));
    const che = r0.en_banco_no_en_sistema.find((x) => x.descripcion.startsWith('CHEQUE'));
    const sis = r0.en_sistema_no_en_banco[0];
    await p.check(`[data-banco="${com.banco_movimiento_id}"] input[type=radio]`);
    await p.check(`[data-sistema="${sis.dinero_movimiento_id}"] input[type=radio]`);
    await p.click('#banco-marcar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('Los montos no son iguales'), 'deja marcar montos distintos');
    await p.check(`[data-banco="${che.banco_movimiento_id}"] input[type=radio]`);
    await p.click('#banco-marcar');
    await p.waitForFunction((x) => !document.querySelector(`[data-banco="${x}"]`), che.banco_movimiento_id);
    // Comisión (sale) e intereses (entra): el mes pasado está cerrado, van con fecha de hoy.
    await p.locator(`[data-banco="${com.banco_movimiento_id}"] button`, { hasText: 'comisión' }).click();
    afirmar((await confirmarDialogo(p)).includes('fecha de hoy'), 'no explica que el mes está cerrado');
    // Ya creada: no se ofrece crearla otra vez y dice que se marca sola en el mes de su fecha.
    await p.waitForSelector(`[data-banco="${com.banco_movimiento_id}"][data-creado=si]`);
    afirmar(await p.locator(`[data-banco="${com.banco_movimiento_id}"] button`).count() === 0, 'ofrece crear otra vez la comisión');
    await p.locator('#solo-banco [data-banco] button', { hasText: 'paga el banco' }).click();
    await confirmarDialogo(p);
    await p.waitForFunction(() => document.querySelectorAll('#solo-banco [data-creado=si]').length === 2);
    await p.waitForSelector('#contenido [data-info=cuadra]');
    const r1 = JSON.parse(sql('dueno@demo.hn', `public.ver_conciliacion(demo.id('CONC1'))`));
    afirmar(r1.cuadra && r1.diferencia_centavos === 0 && !r1.en_sistema_no_en_banco.length, 'no cuadra después de marcar');
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.banco_diferencia WHERE empresa_id = '${EM}')`) === 2, 'no se crearon la comisión y los intereses');
    await p.screenshot({ path: path.join(CAPTURAS, 'dinero_banco_cuadrado_computadora.png'), fullPage: true });
    await p.click('#banco-cerrar');
    await confirmarDialogo(p);
    await p.waitForFunction(() => document.querySelector('#meses-trabajados') && document.querySelector('#meses-trabajados').innerText.includes('Cerrada'));
    afirmar(sql('dueno@demo.hn', `(SELECT estado FROM public.conciliacion WHERE id = demo.id('CONC1'))`) === 'cerrada', 'no se cerró');
    // CSV del banco (sin red ni servidor): punto y coma, fechas DD/MM/AAAA, débito y crédito por separado.
    const csv = await p.evaluate(async () => (await import('/js/pantallas/dinero_banco.js')).leerCsvBanco(
      'Fecha;Descripción;Referencia;Débito;Crédito\n02/09/2026;PAGO ENEE;E-1;1,150.00;\n05/09/2026;DEPOSITO;D-9;;2.500,50\nmal;x;;;\n'));
    afirmar(csv.filas.length === 2 && csv.filas[0].monto_centavos === -115000 && csv.filas[1].monto_centavos === 250050 && csv.filas[0].fecha === '2026-09-02' && csv.errores.length === 1,
      'lectura del CSV: ' + JSON.stringify(csv));
  });

  await prueba('proyección: cifras como la base, fórmula en una línea, gráfica por semana y detalle de lo que entra y sale', async () => {
    const p = d.p;
    await ir(p, 'dinero/proyeccion', '#grafica-proyeccion');
    const r = JSON.parse(sql('dueno@demo.hn', `public.proyeccion_flujo('${EM}', 30, 'semana')`));
    afirmar((await texto(p, '[data-dato=disponible-hoy]')).trim() === lempiras(r.disponible_hoy_centavos), 'disponible hoy distinto');
    afirmar((await texto(p, '[data-dato=saldo-final]')).trim() === lempiras(r.saldo_final_proyectado_centavos), 'saldo final distinto');
    afirmar(await p.locator('#grafica-proyeccion .grafica-col').count() === r.semanas.length, 'barras distintas a las semanas');
    // A mano, semana 1: empieza + entra - sale = termina.
    const s1 = r.semanas[0];
    afirmar(s1.saldo_inicial_centavos + s1.entradas_centavos - s1.salidas_centavos === s1.saldo_final_centavos, 'semana 1 no cuadra');
    afirmar((await texto(p, '[data-dato=final-1]')).trim() === lempiras(s1.saldo_final_centavos), 'semana 1 en la tabla');
    afirmar((await texto(p, '[data-info=formula]')).includes('cobros que vencen'), 'sin la fórmula');
    afirmar(await p.locator('#detalle-proyeccion [data-tipo]').count() === r.detalle.length, 'detalle incompleto');
    await p.selectOption('#proy-dias', '90');
    await p.waitForFunction((n) => document.querySelectorAll('#grafica-proyeccion .grafica-col').length === n, Math.ceil(91 / 7));
  });

  await prueba('dinero: permisos (cajero y vendedor no ven Dinero; admin no reparte utilidades) y usuario limitado no ve la proyección', async () => {
    for (const correo of ['cajero@demo.hn', 'vendedor@demo.hn']) {
      const { ctx, p } = await nueva();
      await entrar(p, correo);
      for (const r of ['dinero/gastos', 'dinero/depositos', 'dinero/pagos-fijos', 'dinero/fondos', 'dinero/banco', 'dinero/proyeccion']) {
        await p.goto(URL_APP + '/#/' + r);
        await p.waitForFunction(() => !location.hash.startsWith('#/dinero/') || location.hash === '#/dinero/donde');
      }
      await ctx.close();
    }
    const { ctx, p } = await nueva();
    await entrar(p, 'admin@demo.hn');
    await ir(p, 'dinero/fondos', '#lista-fondos');
    afirmar(await p.locator('#repartir-utilidad, #nuevo-fondo, #usar-fondo').count() === 0, 'el admin ve acciones solo del dueño');
    // Limitado a su sucursal (respuesta simulada de mi_estado_sesion). Núcleo 0.16.0: el servidor la limita y se muestra.
    await p.route('**/rest/v1/rpc/mi_estado_sesion', (r) => r.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ activo: true, todas_las_sucursales: false, sucursales: [{ sucursal_id: 'S1' }] }) }));
    await p.evaluate(async () => (await import('/js/datos.js')).olvidarDatos());
    await ir(p, 'dinero/proyeccion', '#grafica-proyeccion');
    // Núcleo 0.15.0 (simulado): era de toda la empresa y no se muestra.
    await p.route(/\/rest\/v1\/version_esquema\?/, (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ version_nucleo: '0.15.0' }]) }));
    await p.evaluate(async () => (await import('/js/datos.js')).olvidarDatos());
    await ir(p, 'dinero/gastos', null);
    await ir(p, 'dinero/proyeccion', '#contenido .estado-vacio');
    afirmar((await texto(p, '#contenido')).includes('La proyección es de toda la empresa') && await p.locator('#grafica-proyeccion').count() === 0, 'núcleo viejo: el limitado ve la proyección');
    await ctx.close();
  });

  await prueba('dinero en el celular: formularios sin desbordes (con capturas)', async () => {
    const { ctx, p } = await nueva(celular);
    await entrar(p, 'dueno@demo.hn');
    const pasos = [['dinero/gastos', '#nuevo-gasto', '#gasto-cuenta', 'dinero_gasto_nuevo'], ['dinero/depositos', '#mover-dinero', '#mover-origen', 'dinero_mover'],
      ['dinero/pagos-fijos', '#nuevo-pago-fijo', '#fijo-nombre', 'dinero_pago_fijo_nuevo'], ['dinero/banco', null, '#zona-banco section', 'dinero_banco'],
      ['dinero/proyeccion', null, '#grafica-proyeccion', 'dinero_proyeccion'], ['dinero/fondos', null, '#lista-fondos', 'dinero_fondos']];
    for (const [ruta, boton, espera, nombre] of pasos) {
      await ir(p, ruta, boton || espera);
      if (boton) { await p.click(boton); await p.waitForSelector(espera); }
      await revisarPantalla(p, nombre + ' (celular)', 390);
      await p.screenshot({ path: path.join(CAPTURAS, `${nombre}_celular.png`), fullPage: true });
    }
    await ctx.close();
  });


  // ============================ 0.7.1: arreglos de la revisión ============================
  await prueba('0.7.1: la coma solo vale como separador de miles ("150,50" se rechaza; "1,500" = 1500)', async () => {
    const r = await d.p.evaluate(async () => {
      const f = await import('/js/formato.js');
      const casos = ['150,50', '1,500', '1,500.75', '12,50', '2,5', '1,234,567.89', '0.5', '', '-5', '  150.50  ', '1,50,000', 'L 1,500'];
      return { c: casos.map((x) => f.aCentavos(x)), costo: [f.aCosto('1,250.5'), f.aCosto('120,50'), f.aCosto('12.505')],
        cant: [f.aCantidad('2,5'), f.aCantidad('1,500'), f.aCantidad('2.5'), f.aCantidad('-5'), f.aCantidad('')],
        coma: [f.comaInvalida('150,50'), f.comaInvalida('1,500'), f.comaInvalida('150.50')], msj: f.MENSAJE_COMA };
    });
    const esperado = [null, 150000, 150075, null, null, 123456789, 50, null, null, 15050, null, 150000];
    afirmar(JSON.stringify(r.c) === JSON.stringify(esperado), 'aCentavos: ' + JSON.stringify(r.c));
    afirmar(JSON.stringify(r.costo) === JSON.stringify([125050, null, 1250.5]), 'aCosto: ' + JSON.stringify(r.costo));
    afirmar(JSON.stringify(r.cant) === JSON.stringify([null, 1500, 2.5, null, null]), 'aCantidad: ' + JSON.stringify(r.cant));
    afirmar(JSON.stringify(r.coma) === JSON.stringify([true, false, false]) && r.msj === 'Use punto para los decimales, por ejemplo 150.50', 'comaInvalida');
    // En pantalla: aviso debajo del campo y el formulario no guarda.
    const p = d.p;
    const antes = num('dueno@demo.hn', `(SELECT count(*) FROM public.gasto WHERE empresa_id = '${EM}')`);
    await ir(p, 'dinero/gastos', '#nuevo-gasto');
    await p.click('#nuevo-gasto');
    await p.waitForSelector('#gasto-monto');
    await p.fill('#gasto-monto', '150,50');
    await p.waitForSelector('#gasto-monto + .aviso-coma');
    await p.selectOption('#gasto-cuenta', id('BAC'));
    await p.selectOption('#gasto-categoria', id('CAT_MANT'));
    await p.fill('#gasto-descripcion', 'Prueba de la coma');
    await p.click('#gasto-guardar');
    afirmar((await texto(p, '#contenido .mensaje-error')).includes('Use punto para los decimales'), 'el error no explica la coma');
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.gasto WHERE empresa_id = '${EM}')`) === antes, 'guardó un gasto con coma');
    await p.fill('#gasto-monto', '150.50');
    afirmar(await p.locator('.aviso-coma').count() === 0, 'el aviso no se quita al corregir');
    // Vender y caja usan la misma función: un depósito de "1,500" es L 1,500.00.
    afirmar(await p.evaluate(async () => (await import('/js/formato.js')).aCentavos('1,500')) === 150000, 'miles en caja');
  });

  await prueba('0.7.1: CSV del banco (columnas de más o de menos, "Fecha valor", hora, comillas con salto de línea, tope) y fuera del mes', async () => {
    const r = await d.p.evaluate(async () => {
      const m = await import('/js/pantallas/dinero_banco.js');
      const a = m.leerCsvBanco('Fecha,Fecha valor,Descripción,Monto\n2026-09-02 08:15,2026-09-03,"PAGO ENEE\nRECIBO 9",-1150.00\n2026-09-05,2026-09-05,DEPOSITO,2500.50,extra\n05/09/2026 14:00,x,"COMISION, MANEJO",-57.50\n');
      const muchas = 'Fecha;Descripcion;Monto\n' + Array.from({ length: m.MAX_FILAS + 3 }, () => '2026-09-01;X;1.00').join('\n');
      const b = m.leerCsvBanco(muchas);
      return { a, nb: b.filas.length, eb: b.errores };
    });
    afirmar(r.a.filas.length === 2 && r.a.filas[0].monto_centavos === -115000 && r.a.filas[0].fecha === '2026-09-02' && r.a.filas[0].descripcion.includes('RECIBO 9')
      && r.a.filas[1].fecha === '2026-09-05' && r.a.filas[1].monto_centavos === -5750 && r.a.filas[1].descripcion === 'COMISION, MANEJO', 'CSV: ' + JSON.stringify(r.a));
    afirmar(r.a.errores.length === 1 && r.a.errores[0].startsWith('fila 4:') && r.a.errores[0].includes('columnas'), 'fila con columnas de más: ' + JSON.stringify(r.a.errores));
    afirmar(r.nb === 5000 && r.eb.some((e) => e.includes('5000')), 'tope de filas');
    // Fuera del mes: se quita con aviso antes de enviar; un reintento dice "ya estaba cargado" (respuesta simulada).
    const p = d.p;
    await ir(p, 'dinero/banco', '#banco-cuenta');
    await p.selectOption('#banco-cuenta', id('ATL'));
    const mes = await p.locator('#banco-mes option').nth(1).getAttribute('value');
    await p.selectOption('#banco-mes', mes);
    await p.waitForSelector('#banco-filas');
    const [a, n] = mes.split('-').map(Number);
    const dia = (x) => `${a}-${String(n).padStart(2, '0')}-${x}`;
    await p.locator('#banco-filas [data-campo=fecha]').fill(dia('10'));
    await p.locator('#banco-filas [data-campo=descripcion]').fill('DEPOSITO');
    await p.locator('#banco-filas [data-campo=monto]').fill('100');
    await p.click('#banco-agregar-fila');
    await p.locator('#banco-filas [data-campo=fecha]').nth(1).fill(`${a + 1}-01-15`);
    await p.locator('#banco-filas [data-campo=descripcion]').nth(1).fill('OTRO MES');
    await p.locator('#banco-filas [data-campo=monto]').nth(1).fill('5');
    afirmar((await p.locator('#banco-filas [data-info=numero-fila]').allInnerTexts()).join('|') === 'Movimiento 1|Movimiento 2', 'las filas no van numeradas');
    await p.fill('#banco-saldo-final', '100');
    await p.route('**/rest/v1/rpc/importar_estado_cuenta', (rr) => rr.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ conciliacion_id: 'x', importacion_id: 'y', duplicado: true }) }));
    await p.click('#banco-cargar');
    await p.waitForSelector('[data-info=fuera-del-mes]');
    afirmar(await p.locator('#banco-filas .fila-banco').count() === 1, 'no quitó la fila de otro mes');
    const conf = await confirmarDialogo(p);
    afirmar(conf.includes('1 movimientos'), 'la confirmación cuenta mal: ' + conf);
    await p.waitForSelector('#avisos .mensaje');
    const av = await p.locator('#avisos').innerText();
    afirmar(av.includes('ya estaba cargado') && !av.includes('undefined'), 'aviso de reintento: ' + av);
    await p.unroute('**/rest/v1/rpc/importar_estado_cuenta');
  });

  await prueba('0.7.1: con 300 compras o gastos avisa que las cifras suman solo esas; el pago no se fecha antes de la compra', async () => {
    const p = d.p;
    const falsa = (i) => ({ id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`, numero: i, numero_documento: 'X-' + i, proveedor_id: id('PROV1'),
      fecha_contable: '2026-09-01', condicion: 'contado', total_centavos: 100, anulada_en: null });
    await p.route(/\/rest\/v1\/compra\?/, (rr) => rr.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(Array.from({ length: 300 }, (_, i) => falsa(i + 1))) }));
    await ir(p, 'compras/compras', '[data-info=tope-filas]');
    afirmar((await texto(p, '[data-info=tope-filas]')).includes('últimas 300'), 'sin aviso de 300 compras');
    await p.unroute(/\/rest\/v1\/compra\?/);
    await p.route(/\/rest\/v1\/v_gasto\?/, (rr) => rr.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify(Array.from({ length: 300 }, (_, i) => ({ gasto_id: 'g' + i, numero: i, descripcion: 'x', estado: 'aplicado', monto_centavos: 100, fecha_contable: '2026-09-01' }))) }));
    await ir(p, 'dinero/gastos', '[data-info=tope-filas]');
    await p.unroute(/\/rest\/v1\/v_gasto\?/);
    // Fecha mínima del pago = la mayor entre la fecha de la factura y la de los libros.
    await ir(p, 'compras/pagos', '#lista-cxp');
    const doc = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT documento_id, greatest(fecha_documento, fecha_contable) AS minimo FROM public.v_cxp_documento WHERE empresa_id = '${EM}' LIMIT 1) x)`));
    await p.locator(`[data-documento="${doc.documento_id}"] button`).click();
    await p.waitForSelector('#pago-fecha');
    afirmar(await p.getAttribute('#pago-fecha', 'min') === doc.minimo, 'fecha mínima del pago');
  });

  await prueba('0.9.0: con un núcleo 0.15.0 (sin totales_compras ni totales_gastos) las cifras se suman como antes', async () => {
    const { ctx, p } = await nueva();
    for (const f of ['totales_compras', 'totales_gastos']) {
      await p.route(`**/rest/v1/rpc/${f}`, (rr) => rr.fulfill({ status: 404, contentType: 'application/json',
        body: JSON.stringify({ code: 'PGRST202', message: `Could not find the function public.${f} in the schema cache` }) }));
    }
    await entrar(p, 'dueno@demo.hn');
    const hoy = sql('dueno@demo.hn', `public.hoy_local('${EM}')`);
    await ir(p, 'compras/compras', '.cifras[data-fuente=navegador]');
    const totalBase = num('dueno@demo.hn', `(SELECT coalesce(sum(total_centavos), 0) FROM public.compra WHERE empresa_id = '${EM}'
      AND fecha_contable BETWEEN '${hoy}'::date - 60 AND '${hoy}' AND anulada_en IS NULL)`);
    afirmar((await texto(p, '[data-dato=compras-total]')).trim() === lempiras(totalBase), 'núcleo viejo: total comprado distinto');
    await ir(p, 'dinero/gastos', '.cifras[data-fuente=navegador]');
    const gastado = num('dueno@demo.hn', `(SELECT coalesce(sum(monto_centavos), 0) FROM public.v_gasto WHERE empresa_id = '${EM}' AND estado = 'aplicado'
      AND fecha_contable BETWEEN '${hoy}'::date - 30 AND '${hoy}')`);
    afirmar((await texto(p, '[data-dato=gastos-total]')).trim() === lempiras(gastado), 'núcleo viejo: gastado distinto');
    await ctx.close();
  });

  await prueba('0.9.1: si el servidor niega los totales (SIN_PERMISO) se suman las filas sin romper; fechas al revés se avisan antes de pedir', async () => {
    const { ctx, p } = await nueva();
    for (const f of ['totales_compras', 'totales_gastos']) {
      await p.route(`**/rest/v1/rpc/${f}`, (rr) => rr.fulfill({ status: 400, contentType: 'application/json',
        body: JSON.stringify({ code: 'P0001', message: 'SIN_PERMISO: su rol no tiene el permiso "compras.ver".' }) }));
    }
    const pedidas = [];
    p.on('request', (q) => pedidas.push(q.url()));
    await entrar(p, 'dueno@demo.hn');
    await ir(p, 'compras/compras', '.cifras[data-fuente=navegador]');
    afirmar(await p.locator('#contenido .mensaje-error').count() === 0 && await p.locator('#lista-compras').count() === 1, 'compras: la pantalla se rompió con SIN_PERMISO');
    await ir(p, 'dinero/gastos', '.cifras[data-fuente=navegador]');
    afirmar(await p.locator('#contenido .mensaje-error').count() === 0, 'gastos: la pantalla se rompió con SIN_PERMISO');
    // Desde después de hasta: aviso en la app y no se pide nada al servidor.
    pedidas.length = 0;
    await p.fill('#gastos-desde', '2026-09-30');
    await p.fill('#gastos-hasta', '2026-09-01');
    await p.dispatchEvent('#gastos-hasta', 'change');
    await p.waitForSelector('[data-info=fechas-al-reves]');
    afirmar((await texto(p, '[data-info=fechas-al-reves]')).includes("La fecha 'desde' va antes que 'hasta'"), 'no avisa las fechas al revés');
    afirmar(!pedidas.some((u) => u.includes('totales_gastos') || u.includes('v_gasto')), 'pidió al servidor con las fechas al revés');
    await ir(p, 'compras/compras', '#compras-desde');
    await p.fill('#compras-desde', '2026-09-30');
    await p.fill('#compras-hasta', '2026-09-01');
    await p.dispatchEvent('#compras-hasta', 'change');
    await p.waitForSelector('[data-info=fechas-al-reves]');
    await ctx.close();
  });

  await prueba('0.7.1: al salir los filtros vuelven a los de siempre; "Todos los gastos" sin dinero.ver explica el permiso', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await ir(p, 'compras/compras', '#compras-proveedor');
    await p.selectOption('#compras-proveedor', id('PROV2'));
    await p.waitForFunction(() => document.querySelectorAll('#lista-compras [data-compra]').length >= 1);
    await p.click('.quien button');
    await entrar(p, 'dueno@demo.hn');
    await ir(p, 'compras/compras', '#compras-proveedor');
    afirmar(await p.inputValue('#compras-proveedor') === '', 'el filtro de proveedor quedó del usuario anterior');
    await ctx.close();
    // Menú: basta registrar o ver; la pantalla sin dinero.ver no lista y explica (perfil simulado sin dinero.ver).
    const m = await d.p.evaluate(async () => {
      const md = await import('/js/menu_datos.js');
      const g = md.MENU.find((x) => x.id === 'dinero').subs.find((x) => x.id === 'gastos');
      return [md.visibleCon(g, new Set(['dinero']), new Set(['gastos.registrar'])), md.visibleCon(g, new Set(['dinero']), new Set(['dinero.ver'])),
        md.visibleCon(g, new Set(['dinero']), new Set(['ventas.ver']))];
    });
    afirmar(JSON.stringify(m) === '[true,true,false]', 'permisos del menú de gastos: ' + JSON.stringify(m));
    const x = await nueva();
    await x.p.route('**/rest/v1/rpc/mi_perfil', async (rr) => {
      const res = await rr.fetch(); const j = await res.json();
      if (j && j.permisos) j.permisos = j.permisos.filter((q) => q !== 'dinero.ver');
      await rr.fulfill({ response: res, body: JSON.stringify(j) });
    });
    await entrar(x.p, 'admin@demo.hn');
    await ir(x.p, 'dinero/gastos', '[data-info=sin-dinero-ver]');
    afirmar(await x.p.locator('#nuevo-gasto').count() === 0 && !(await texto(x.p, '#contenido')).includes('Primero guarde sus cajas'), 'sin dinero.ver no debe ofrecer registrar');
    await x.ctx.close();
  });

  await d.ctx.close();
  await prueba('sin errores de JavaScript en Compras y Dinero', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });
  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de Compras y Dinero pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
