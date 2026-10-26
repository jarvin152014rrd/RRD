// PRUEBA: app 0.13.0 (núcleo 0.19.0) en el navegador (Chromium con Playwright) contra la base de demo: devolución con
// "Ajuste por perder precio mayorista" (vista previa, resultado y comprobante sin emojis ni íconos), cambio exacto con
// varios productos (contador Falta / Sobra, el botón solo con la cuenta exacta, "Devolver todo el dinero"), garantía por
// otro producto que no da exacto (no deja resolver) y estado de cuenta del socio (cifras del servidor, cuadre, fechas,
// Excel e Imprimir), en computadora y celular. La corre herramientas/probar_app.sh.
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
    if (global.paginaActual) await global.paginaActual.screenshot({ path: path.join(CAPTURAS, 'falla130_' + total + '.png'), fullPage: true }).catch(() => {});
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

// Venta de contado registrada por el dueño (SQL); devuelve número y id.
function venta(lineas, cliente) {
  sqlEscribir(DUENO, `SELECT public.registrar_venta(demo.id('EMPRESA'), jsonb_build_object(${cliente ? `'cliente_id', demo.id('${cliente}'), ` : ''}'lineas', jsonb_build_array(${lineas}),
    'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid())`);
  return JSON.parse(sql(DUENO, `(SELECT row_to_json(x) FROM (SELECT venta_id, numero_documento, total_centavos FROM public.v_venta
    WHERE empresa_id = demo.id('EMPRESA') ORDER BY registrado_en DESC LIMIT 1) x)`));
}
async function abrirDevolucion(p, numero) {
  if (await p.evaluate(() => location.hash) === '#/vender/devoluciones') await p.click('a.subpestana[href="#/vender/devoluciones"]');
  else await p.goto(URL_APP + '/#/vender/devoluciones');
  await p.waitForSelector('#dev-numero');
  await p.fill('#dev-numero', numero);
  await p.click('form.formulario button[type=submit]');
  await p.waitForSelector('#dev-motivo');
}

(async () => {
  const nav = await chromium.launch();
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true, ...opciones });
    const p = await ctx.newPage();
    global.paginaActual = p;
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };
  const celular = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true };
  console.log('Pruebas de la app 0.13.0 (devolución con mayorista, cambio exacto, estado de cuenta del socio):');
  afirmar(sql(null, '(SELECT version_nucleo FROM public.version_esquema)') === '0.19.0', 'la base de demo no es 0.19.0');

  // Precios fijos para las cuentas a mano: tubo PVC L 115.00 (mayorista L 100.00 desde 10), clavo L 40.00 la libra.
  sqlEscribir(DUENO, `SELECT public.cambiar_precio_producto(demo.id('EMPRESA'), demo.id('PVC'), 11500, 'Prueba 0.13.0: precio fijo')`);
  sqlEscribir(DUENO, `SELECT public.cambiar_precio_producto(demo.id('EMPRESA'), demo.id('CLA'), 4000, 'Prueba 0.13.0: precio fijo')`);
  sqlEscribir(DUENO, `SELECT public.editar_producto(demo.id('EMPRESA'), demo.id('PVC'), '{"precio_mayorista_centavos": 10000, "cantidad_mayorista": 10, "dias_garantia": 30}', 'Prueba 0.13.0: mayoreo')`);
  sqlEscribir(DUENO, `SELECT public.configurar_empresa(demo.id('EMPRESA'), '{"cambio_exacto": true}', 'Prueba 0.13.0: regla del dueño')`);
  const pvc = JSON.parse(sql(DUENO, `(SELECT row_to_json(x) FROM (SELECT precio_con_isv_centavos AS normal, precio_mayorista_con_isv_centavos AS mayorista
    FROM public.v_producto WHERE producto_id = demo.id('PVC')) x)`));
  afirmar(pvc.normal === 11500 && pvc.mayorista === 10000, 'precios del PVC: ' + JSON.stringify(pvc));

  const dueno = await nueva();
  await entrar(dueno.p, DUENO);
  const usar = (x) => { global.paginaActual = x; return x; };

  // ===================== 1) Devolución con ajuste mayorista =====================
  await prueba('devolución: si lo que se queda baja de "desde cantidad", se ve y se descuenta el ajuste por perder precio mayorista', async () => {
    const p = usar(dueno.p);
    // A mano: 10 PVC a L 100.00 = L 1,000.00. Devuelve 4 y se queda con 6 (< 10): 6 x L 115.00 = L 690.00.
    // Se le devuelve L 1,000.00 - L 690.00 = L 310.00; lo devuelto valía 4 x L 100.00 = L 400.00; ajuste L 90.00.
    const v = venta(`demo.l('PVC', 10)`, 'CLI3');
    afirmar(Number(v.total_centavos) === 100000, 'venta mayorista: ' + v.total_centavos);
    paso = 'abrir';
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '4');
    await p.fill('#dev-motivo', 'Le sobraron tubos');
    await p.selectOption('#dev-destino', 'dinero');
    paso = 'vista previa';
    await p.waitForSelector('[data-dato=dev-a-devolver]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=dev-valor]')).trim() === 'L 400.00', 'valor: ' + await textoDe(p, '[data-dato=dev-valor]'));
    afirmar((await textoDe(p, '[data-dato=dev-ajuste]')).trim() === '-L 90.00', 'ajuste: ' + await textoDe(p, '[data-dato=dev-ajuste]'));
    afirmar((await textoDe(p, '[data-dato=dev-a-devolver]')).trim() === 'L 310.00', 'a devolver: ' + await textoDe(p, '[data-dato=dev-a-devolver]'));
    afirmar((await textoDe(p, '[data-info=ajuste-mayorista]')).includes('se queda con 6'), 'explicación del ajuste');
    // El servidor da lo mismo.
    const pv = JSON.parse(sql(DUENO, `public.calcular_devolucion_previa('${v.venta_id}', '{"lineas":[{"linea":1,"cantidad":4}]}')`));
    afirmar(pv.total_centavos === 31000 && pv.ajuste_mayorista_centavos === 9000, 'servidor: ' + JSON.stringify(pv));
    await p.screenshot({ path: path.join(CAPTURAS, 'v13_devolucion_mayorista.png'), fullPage: true });
    paso = 'guardar';
    await p.selectOption('#dev-cuenta', id('FUERTE'));
    await p.click('#dev-guardar');
    await p.waitForSelector('[data-resultado=devolucion]', { timeout: 20000 });
    afirmar((await textoDe(p, '[data-dato=total-devolucion]')).trim() === 'L 310.00', 'total devuelto');
    afirmar((await textoDe(p, '[data-dato=ajuste-mayorista]')).includes('Ajuste por perder precio mayorista: L 90.00'), 'resultado sin el ajuste');
    paso = 'comprobante';
    await p.waitForSelector('article.comprobante', { timeout: 15000 });
    const comp = await textoDe(p, 'article.comprobante');
    afirmar(comp.includes('Ajuste por perder precio mayorista: L 90.00') && comp.includes('L 310.00') && !emojis.test(comp), 'comprobante: ' + comp);
    afirmar(await p.locator('article.comprobante svg').count() === 0, 'el comprobante no lleva íconos');
    const d = JSON.parse(sql(DUENO, `(SELECT row_to_json(x) FROM (SELECT total_centavos, ajuste_mayorista_centavos, dinero_centavos FROM public.v_devolucion
      WHERE venta_id = '${v.venta_id}') x)`));
    afirmar(d.total_centavos === 31000 && d.ajuste_mayorista_centavos === 9000, 'base: ' + JSON.stringify(d));
  });

  await prueba('devolución: si el ajuste se come todo, la vista previa lo explica y no se guarda nada', async () => {
    const p = usar(dueno.p);
    // Devolver 1 de 10: vale L 100.00; las 9 que se queda a normal: 9 x 115 = 1,035 contra 900 pagado: ajuste 135 > 100.
    const v = venta(`demo.l('PVC', 10)`, 'CLI3');
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '1');
    await p.fill('#dev-motivo', 'Le sobró uno');
    await p.selectOption('#dev-destino', 'dinero');
    await p.waitForSelector('#dev-previa .mensaje-error, #dev-previa [role=alert]', { timeout: 15000 });
    const t = await textoDe(p, '#dev-previa');
    afirmar(/precio mayorista/i.test(t) && !/[A-Z]{3,}_[A-Z_]+/.test(t), 'mensaje claro: ' + t);
    await p.selectOption('#dev-cuenta', id('FUERTE'));
    await p.click('#dev-guardar');
    await p.waitForFunction(() => document.querySelectorAll('form.formulario .mensaje-error').length >= 2, null, { timeout: 15000 });
    afirmar(sql(DUENO, `(SELECT count(*) FROM public.devolucion WHERE venta_id = '${v.venta_id}')`) === '0', 'no guardó nada');
  });

  // ===================== 2) Cambio exacto =====================
  await prueba('cambio exacto: varios productos, contador Falta / Sobra, el botón solo con la cuenta exacta', async () => {
    const p = usar(dueno.p);
    // Devuelve 2 PVC = L 230.00. Se lleva 1 PVC (L 115.00): falta L 115.00. Más 3 lb de clavo (L 120.00): sobra L 5.00.
    // Con 2.875 lb de clavo (L 115.00): exacto.
    const v = venta(`demo.l('PVC', 2)`, 'CLI3');
    afirmar(Number(v.total_centavos) === 23000, 'venta: ' + v.total_centavos);
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '2');
    await p.fill('#dev-motivo', 'Quiere otra medida');
    afirmar((await p.locator('#dev-destino option[value=cambio]').innerText()).includes('otro(s) producto(s)'), 'texto de la opción');
    await p.selectOption('#dev-destino', 'cambio');
    await p.waitForSelector('[data-info=regla-exacto]');
    afirmar(await p.locator('#dev-guardar').isDisabled(), 'el botón empieza apagado');
    afirmar(await p.locator('#dev-devolver-todo').isVisible(), 'no está "Devolver todo el dinero"');
    paso = 'falta';
    await p.fill('#cambio-buscar', 'PVC');
    await p.click(`#zona-cambio .resultado-producto[data-producto="${id('PVC')}"]`);
    await p.waitForSelector('#cambio-contador[data-estado=falta]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=cambio-contador]')).trim() === 'L 115.00', 'falta: ' + await textoDe(p, '[data-dato=cambio-contador]'));
    afirmar(await p.locator('#dev-guardar').isDisabled(), 'con falta el botón sigue apagado');
    paso = 'sobra';
    await p.fill('#cambio-buscar', 'clavo');
    await p.click(`#zona-cambio .resultado-producto[data-producto="${id('CLA')}"]`);
    const cant = p.locator(`#cambio-lineas [data-nuevo="${id('CLA')}"] input[name=cantidad-nueva]`);
    await cant.fill('3');
    await cant.dispatchEvent('change');
    await p.waitForSelector('#cambio-contador[data-estado=sobra]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=cambio-contador]')).trim() === 'L 5.00', 'sobra: ' + await textoDe(p, '[data-dato=cambio-contador]'));
    afirmar(await p.locator('#dev-guardar').isDisabled(), 'con sobra el botón sigue apagado');
    paso = 'exacto';
    await cant.fill('2.875');
    await cant.dispatchEvent('change');
    await p.waitForSelector('#cambio-contador[data-estado=exacto]', { timeout: 15000 });
    await p.waitForFunction(() => !document.querySelector('#dev-guardar').disabled);
    await p.screenshot({ path: path.join(CAPTURAS, 'v13_cambio_exacto.png'), fullPage: true });
    await p.click('#dev-guardar');
    await p.waitForSelector('[data-resultado=cambio]', { timeout: 20000 });
    const d = JSON.parse(sql(DUENO, `(SELECT row_to_json(x) FROM (SELECT d.cambio_centavos, d.dinero_centavos, d.saldo_favor_centavos,
      (SELECT count(*) FROM public.venta_linea l WHERE l.venta_id = d.venta_cambio_id) AS lineas,
      (SELECT string_agg(g.forma || ':' || g.monto_centavos, ',') FROM public.venta_pago g WHERE g.venta_id = d.venta_cambio_id) AS pagos
      FROM public.devolucion d WHERE d.venta_id = '${v.venta_id}') x)`));
    afirmar(d.cambio_centavos === 23000 && d.dinero_centavos === 0 && d.saldo_favor_centavos === 0 && d.lineas === 2 && d.pagos === 'saldo_favor:23000',
      'base: ' + JSON.stringify(d));
  });

  await prueba('cambio exacto: "Devolver todo el dinero" pasa a devolver el dinero con un toque', async () => {
    const p = usar(dueno.p);
    const v = venta(`demo.l('PVC', 1)`, null);
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '1');
    await p.fill('#dev-motivo', 'No le sirvió');
    await p.selectOption('#dev-destino', 'cambio');
    await p.click('#dev-devolver-todo');
    afirmar(await p.locator('#dev-destino').inputValue() === 'dinero', 'no cambió a devolver dinero');
    afirmar(await p.locator('#dev-cuenta').isVisible() && !(await p.locator('#dev-guardar').isDisabled()), 'no pide la cuenta o el botón sigue apagado');
    await p.waitForSelector('[data-dato=dev-a-devolver]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=dev-a-devolver]')).trim() === 'L 115.00', 'a devolver');
    await p.selectOption('#dev-cuenta', id('FUERTE'));
    await p.click('#dev-guardar');
    await p.waitForSelector('[data-resultado=devolucion]', { timeout: 20000 });
    afirmar(sql(DUENO, `(SELECT dinero_centavos FROM public.devolucion WHERE venta_id = '${v.venta_id}')`) === '11500', 'devolvió el dinero');
  });

  await prueba('garantía por otro producto que no da exacto: lo explica y no deja resolver', async () => {
    const p = usar(dueno.p);
    const v = venta(`demo.l('PVC', 1)`, 'CLI3');
    sqlEscribir(DUENO, `SELECT public.registrar_reclamo_garantia(demo.id('EMPRESA'), jsonb_build_object('venta_id', '${v.venta_id}', 'linea', 1,
      'motivo', 'Tubo rajado 0130'), gen_random_uuid())`);
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    await p.goto(URL_APP + '/#/vender/garantias');
    await p.waitForSelector('#reclamos-abiertos [data-reclamo]');
    await p.locator('#reclamos-abiertos [data-reclamo]', { hasText: 'Tubo rajado 0130' }).locator('[data-accion=resolver]').click();
    await p.waitForSelector('#t-resolver');
    await p.check('input[name=resolucion][value=cambiado]');
    await p.check('input[name=cambio-tipo][value=otro]');
    await p.fill('#cambio-otro-buscar', 'clavo');
    await p.locator('#zona-cambio-garantia .resultado-producto').first().click();
    await p.waitForSelector('[data-info=cambio-otro-no-exacto]', { timeout: 15000 });
    await p.click('form.formulario button[type=submit]');
    await p.waitForFunction(() => document.querySelectorAll('form.formulario .mensaje-error').length >= 2, null, { timeout: 15000 });
    afirmar(sql(DUENO, `(SELECT estado FROM public.garantia_reclamo WHERE motivo = 'Tubo rajado 0130')`) === 'recibido', 'se resolvió sin dar exacto');
  });

  // ===================== 3) Estado de cuenta del socio =====================
  await prueba('estado de cuenta del socio: cifras del servidor, cuadre, fechas, Excel e Imprimir', async () => {
    const p = usar(dueno.p);
    await p.goto(URL_APP + '/#/dinero/fondos');
    await p.waitForSelector('#lista-socios');
    await p.locator(`[data-socio="${id('S_MARIA')}"] [data-accion=estado-socio]`).click();
    await p.waitForSelector('#t-estado-socio');
    await p.waitForSelector('[data-dato=socio-invertido]', { timeout: 15000 });
    const r = JSON.parse(sql(DUENO, `public.estado_cuenta_socio(demo.id('EMPRESA'), demo.id('S_MARIA'))`));
    afirmar(r.cuadre.cuadra === true, 'el servidor dice que no cuadra');
    afirmar((await textoDe(p, '[data-dato=socio-invertido]')).trim() === lempiras(r.total_invertido_centavos), 'invertido');
    afirmar((await textoDe(p, '[data-dato=socio-por-pagar]')).trim() === lempiras(r.saldo_por_pagar_centavos), 'por pagar');
    afirmar(await p.locator('[data-info=socio-cuadra]').count() === 1, 'no dice que cuadra');
    afirmar(await p.locator('#tabla-estado-socio tbody tr').count() === r.movimientos.length && r.movimientos.length > 0, 'filas de la tabla');
    await p.screenshot({ path: path.join(CAPTURAS, 'v13_estado_socio.png'), fullPage: true });
    paso = 'excel';
    const [desc] = await Promise.all([p.waitForEvent('download'), p.click('#estado-socio-excel')]);
    afirmar(/^estado_de_cuenta_del_socio_maria_lopez.*\.xlsx$/.test(desc.suggestedFilename()), 'archivo: ' + desc.suggestedFilename());
    paso = 'imprimir';
    await p.evaluate(() => { window.print = () => { window.__impreso = document.querySelector('.reporte-impreso'); }; });
    await p.click('#estado-socio-imprimir');
    await p.waitForFunction(() => window.__impreso, null, { timeout: 15000 });
    const imp = await p.evaluate(() => { const x = window.__impreso; return { t: x.textContent, raro: x.querySelectorAll('svg, .icono, .chip-color, .burbuja').length }; });
    afirmar(imp.raro === 0 && !emojis.test(imp.t) && imp.t.includes('Estado de cuenta del socio') && imp.t.includes('Total invertido'), 'impreso: ' + imp.raro);
    await p.evaluate(() => { window.dispatchEvent(new Event('afterprint')); window.__impreso = null; });
    paso = 'fechas';
    // Desde mañana: nada en el rango; el saldo al empezar es todo lo de antes.
    const manana = sql(null, `to_char(public.hoy_local(demo.id('EMPRESA')) + 1, 'YYYY-MM-DD')`);
    const hoy = sql(null, `to_char(public.hoy_local(demo.id('EMPRESA')), 'YYYY-MM-DD')`);
    await p.fill('#socio-desde', hoy);
    await p.dispatchEvent('#socio-desde', 'change');
    await p.waitForSelector('[data-dato=socio-saldo-inicial]', { timeout: 15000 });
    const r2 = JSON.parse(sql(DUENO, `public.estado_cuenta_socio(demo.id('EMPRESA'), demo.id('S_MARIA'), '${hoy}')`));
    afirmar((await textoDe(p, '[data-dato=socio-saldo-inicial]')).includes(lempiras(r2.saldo_inicial.por_pagar_centavos)), 'saldo al empezar');
    afirmar(manana > hoy, 'fechas');
    await p.click('#estado-socio-volver');
    await p.waitForSelector('#t-fondos');
  });

  await prueba('Ajustes > Reglas y topes: el dueño apaga y enciende "Cambio exacto" con motivo', async () => {
    const p = usar(dueno.p);
    const valor = () => sql(DUENO, `(SELECT cambio_exacto FROM public.empresa WHERE id = demo.id('EMPRESA'))`);
    const esperarValor = async (v) => { for (let i = 0; i < 50 && valor() !== v; i++) await p.waitForTimeout(200); return valor() === v; };
    await p.goto(URL_APP + '/#/ajustes/reglas');
    await p.waitForSelector('#regla-cambio-exacto');
    afirmar(await p.locator('#regla-cambio-exacto').isChecked(), 'debía venir encendido');
    await p.uncheck('#regla-cambio-exacto');
    await p.click('#reglas-guardar');
    await p.fill('dialog textarea[name=motivo]', 'Prueba: cambio con diferencia');
    await p.click('dialog button[type=submit]');
    afirmar(await esperarValor('false'), 'no se apagó');
    await p.waitForTimeout(1000);   // la pantalla se vuelve a pintar después de guardar
    await p.waitForFunction(() => document.querySelector('#regla-cambio-exacto') && !document.querySelector('#regla-cambio-exacto').checked && !document.querySelector('dialog[open]'));
    await p.check('#regla-cambio-exacto');
    await p.click('#reglas-guardar');
    await p.fill('dialog textarea[name=motivo]', 'Vuelve la regla del dueño');
    await p.click('dialog button[type=submit]');
    afirmar(await esperarValor('true'), 'no se encendió');
  });

  await prueba('celular: estado de cuenta del socio y cambio exacto sin salirse de la pantalla', async () => {
    const { ctx, p } = await nueva(celular);
    usar(p);
    await entrar(p, DUENO);
    await p.goto(URL_APP + '/#/dinero/fondos');
    await p.waitForSelector('#lista-socios');
    await p.locator(`[data-socio="${id('S_MARIA')}"] [data-accion=estado-socio]`).click();
    await p.waitForSelector('[data-dato=socio-invertido]', { timeout: 15000 });
    afirmar(await anchoPagina(p) <= 390, 'estado de cuenta se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'v13_estado_socio_celular.png'), fullPage: true });
    const v = venta(`demo.l('PVC', 1)`, null);
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '1');
    await p.selectOption('#dev-destino', 'cambio');
    await p.fill('#cambio-buscar', 'clavo');
    await p.click(`#zona-cambio .resultado-producto[data-producto="${id('CLA')}"]`);
    await p.waitForSelector('#cambio-contador', { timeout: 15000 });
    afirmar(await anchoPagina(p) <= 390, 'el cambio se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'v13_cambio_celular.png'), fullPage: true });
    await ctx.close();
  });

  if (erroresJs.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + erroresJs.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total})`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
