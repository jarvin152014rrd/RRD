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

  await d.ctx.close();
  await prueba('sin errores de JavaScript en Compras y Dinero', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });
  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de Compras y Dinero pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
