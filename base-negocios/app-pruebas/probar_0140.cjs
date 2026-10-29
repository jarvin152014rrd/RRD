// PRUEBA: app 0.14.0 (núcleo 0.20.0), vender SIN INTERNET en el navegador (Chromium con Playwright, context.setOffline)
// contra una base de demo propia con facturación SAR (fiscal_hn, CAI de la caja 001) y el talonario de emergencia:
//   preparar el equipo; vender sin conexión (efectivo y transferencia con referencia; tarjeta no); la transacción que
//   falla no gasta número (G6); recargar SIN internet (la app abre con lo guardado y las ventas siguen ahí); no deja salir
//   con ventas por subir; precio manipulado en IndexedDB -> "por resolver"; corte a mitad de la subida (el servidor
//   guardó y la respuesta se perdió): al reintentar no se duplica; dos pestañas (una sola sube); el supervisor
//   resuelve; transferencias por confirmar (llegó, no llegó -> deuda del cajero, referencia repetida); cerrar el turno
//   devuelve el bloque; otro equipo sigue la numeración CAI sin repetir; equipo desactivado -> bloque por conciliar y
//   conciliar; celular de 390 px (la barra no tapa Cobrar); talonario (registrar, pasar, anular, huecos).
// La corre herramientas/probar_app.sh. Variables: URL_APP, BASE_DEMO, CAPTURAS, PG* del servidor local.
'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');
let playwright;
try { playwright = require('playwright'); } catch { playwright = require('/opt/node22/lib/node_modules/playwright'); }
const { chromium } = playwright;

const URL_APP = process.env.URL_APP || 'http://127.0.0.1:8094';
const BASE = process.env.BASE_DEMO || 'demo_pruebas_app_si';
const CAPTURAS = process.env.CAPTURAS || path.join(__dirname, 'capturas');
const CLAVE = process.env.DEMO_CLAVE || 'demo1234';

let fallas = 0, total = 0;
let paso = '';
async function prueba(nombre, fn) {
  total++;
  paso = '';
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++;
    if (global.paginaActual) await global.paginaActual.screenshot({ path: path.join(CAPTURAS, 'falla140_' + total + '.png'), fullPage: true }).catch(() => {});
    console.log(`  FALLA  ${nombre}\n           ${paso ? '[' + paso + '] ' : ''}${String(e.message).split('\n')[0]}`); }
}
function afirmar(cond, que) { if (!cond) throw new Error(que); }

function psql(guion) {
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE], { input: guion, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  return r.stdout;
}
function sql(correo, consulta) {
  const salida = psql(`BEGIN; ${correo ? `SELECT demo.como('${correo}') \\g /dev/null` : ''}\nSELECT '@@' || (${consulta})::text; ROLLBACK;`);
  const linea = salida.split('\n').find((l) => l.startsWith('@@'));
  return linea ? linea.slice(2) : null;
}
function sqlEscribir(correo, consulta) {
  psql(`BEGIN; ${correo ? `SELECT demo.como('${correo}') \\g /dev/null` : ''}\n${consulta};\nCOMMIT;`);
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
const DUENO = 'dueno@demo.hn';
const CAJERO = 'cajero@demo.hn';
const E = () => sql(null, `demo.id('EMPRESA')`);

// Chromium de Playwright no concede el almacenamiento persistente: se simula (lo que hace un navegador instalado).
const SIMULAR_PERSISTENTE = () => {
  if (navigator.storage) {
    navigator.storage.persist = async () => true;
    navigator.storage.persisted = async () => true;
    navigator.storage.estimate = async () => ({ quota: 8 * 1024 ** 3, usage: 1024 });
  }
};

// Ir a una ruta sin recargar (sin internet una recarga necesita el service worker).
async function ir(p, ruta) {
  await p.evaluate((r) => { location.hash = r; }, '#/' + ruta);
}
// Llama una función de js/sin_internet.js en la página (el mismo módulo que usa la app).
// Sube todo lo del equipo; si otra subida (la automática) tiene el turno, espera y vuelve a intentar.
async function subirTodo(p, empresa) {
  let r = null;
  for (let i = 0; i < 40; i++) {
    r = await enEquipo(p, (m, e) => m.subir(e), empresa);
    if (!r.ocupado && !r.sin_conexion && r.quedan === 0) return r;
    await p.waitForTimeout(500);
  }
  return r;
}
const enEquipo = (p, fn, arg) => p.evaluate(async ([f, a]) => {
  const m = await import('/js/sin_internet.js');
  return (new Function('m', 'a', `return (${f})(m, a);`))(m, a);
}, [fn.toString(), arg]);

async function venderEnPantalla(p, { codigo, cantidad = null, forma = 'efectivo', referencia = null, banco = null }) {
  await p.waitForSelector('#buscar-producto', { timeout: 15000 });
  await p.fill('#buscar-producto', codigo);
  await p.locator('.resultado-producto').first().click();
  if (cantidad) await p.fill('.linea-carrito input[name=cantidad] >> nth=0', String(cantidad)).catch(() => {});
  await p.waitForFunction(() => /L\s?[0-9]/.test((document.querySelector('[data-dato=total]') || {}).textContent || ''), null, { timeout: 15000 });
  await p.click(`[data-forma=${forma}]`);
  if (referencia !== null) await p.fill('#referencia', referencia);
  if (banco !== null) await p.fill('#banco-transferencia', banco);
  await p.click('#cobrar');
}

(async () => {
  const nav = await chromium.launch();
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true, serviceWorkers: 'allow', ...opciones });
    await ctx.addInitScript(SIMULAR_PERSISTENTE);
    const p = await ctx.newPage();
    global.paginaActual = p;
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };
  const usar = (x) => { global.paginaActual = x; return x; };
  console.log('Pruebas de la app 0.14.0 (vender sin internet, transferencias por confirmar, talonario de emergencia):');
  afirmar(sql(null, '(SELECT version_nucleo FROM public.version_esquema)') === '0.20.0', 'la base de demo no es 0.20.0');

  // ---- Base: facturación SAR con CAI en la caja 001, talonario encendido, cajera con permiso y turno abierto.
  const empresa = E();
  psql(`
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES ('${empresa}', 'fiscal_hn'), ('${empresa}', 'facturas_emergencia')
ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
BEGIN;
SELECT demo.como('${DUENO}') \\g /dev/null
SELECT public.registrar_cai('${empresa}', jsonb_build_object('caja_id', (SELECT id FROM public.caja WHERE empresa_id = '${empresa}' AND punto_emision = '001'),
  'tipo_documento', 'factura', 'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000001',
  'rango_hasta', '001-001-01-00005000', 'fecha_limite_emision', to_char(public.hoy_local('${empresa}') + 180, 'YYYY-MM-DD'))) \\g /dev/null
SELECT public.cambiar_permiso_rol('${empresa}', 'cajero', 'ventas.sin_internet', true, 'Prueba 0.14.0: la cajera vende sin internet') \\g /dev/null
SELECT public.configurar_empresa('${empresa}', '{"sin_internet_bloque": 20}', 'Prueba 0.14.0: bloques de 20') \\g /dev/null
COMMIT;`);
  const cajaId = sql(null, `(SELECT id FROM public.caja WHERE empresa_id = '${empresa}' AND punto_emision = '001')`);
  // Abre el turno de la caja 001 contando lo que tiene (el saldo se lee como superusuario).
  const abrirTurno = (correo) => sqlEscribir(correo, `SELECT public.abrir_turno('${empresa}', '${cajaId}',
    ${sql(null, `(SELECT coalesce(saldo_centavos, 0) FROM public.v_cuenta_dinero WHERE caja_id = '${cajaId}')`)}, gen_random_uuid())`);
  abrirTurno(CAJERO);
  const ventasCaja = () => JSON.parse(sql(null, `(SELECT coalesce(jsonb_agg(numero_documento ORDER BY numero_documento), '[]') FROM public.venta
    WHERE empresa_id = '${empresa}' AND numero_documento LIKE '001-001-01-%')`));

  const a = await nueva();
  let porSubir = 0;

  await prueba('preparar el equipo: registra el equipo, reserva los números de la caja y guarda los precios', async () => {
    const p = usar(a.p);
    await entrar(p, CAJERO);
    paso = 'service worker';
    await p.evaluate(() => navigator.serviceWorker.ready.then(() => true));
    await ir(p, 'ajustes/sin_internet');
    await p.waitForSelector('#si-preparar', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=soporte]')).includes('guarda las ventas de forma segura'), 'soporte: ' + await textoDe(p, '[data-dato=soporte]'));
    await p.fill('#si-nombre-equipo', 'Caja 1 - computadora');
    await p.click('#si-preparar');
    await p.waitForSelector('[data-dato=quedan]', { timeout: 20000 });
    afirmar((await textoDe(p, '[data-dato=quedan]')).trim() === '20', 'números que quedan: ' + await textoDe(p, '[data-dato=quedan]'));
    afirmar((await textoDe(p, '[data-dato=equipo]')).includes('Caja 1 - computadora'), 'nombre del equipo');
    const b = JSON.parse(sql(null, `(SELECT row_to_json(x) FROM (SELECT estado, desde, hasta FROM public.numero_bloque WHERE empresa_id = '${empresa}') x)`));
    afirmar(b.estado === 'activo' && b.hasta - b.desde === 19, 'bloque en el servidor: ' + JSON.stringify(b));
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_preparar.png'), fullPage: true });
  });

  let primerNumero = null;
  await prueba('sin conexión: vende en efectivo, la barra cuenta la venta, el comprobante dice "Emitida sin conexión" con la copia del emisor', async () => {
    const p = usar(a.p);
    await ir(p, 'vender/nueva');
    await p.waitForSelector('[data-dato=caja-con-bloque]', { timeout: 15000 });
    await a.ctx.setOffline(true);
    await venderEnPantalla(p, { codigo: 'CEM-425' });
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    porSubir++;
    await p.waitForFunction(() => (document.getElementById('sin-conexion').textContent || '').includes('Sin conexión: 1 venta guardada en este equipo'), null, { timeout: 5000 });
    const comp = await textoDe(p, '[data-local=si]');
    afirmar(comp.includes('Emitida sin conexión') && comp.includes('Copia: obligado tributario emisor') && comp.includes('Original: cliente'), 'comprobante: ' + comp.slice(0, 300));
    afirmar(comp.includes('A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6'), 'el comprobante no tiene el CAI');
    afirmar(!emojis.test(comp) && await p.locator('[data-local=si] svg').count() === 0, 'el comprobante lleva emojis o íconos');
    const m = /001-001-01-(\d{8})/.exec(comp);
    primerNumero = Number(m[1]);
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_venta_sin_conexion.png'), fullPage: true });
  });

  await prueba('sin conexión: tarjeta no; la transacción que falla no gasta número; transferencia exige referencia', async () => {
    const p = usar(a.p);
    await p.click('text=Nueva venta');
    paso = 'tarjeta';
    // La pantalla se abrió con internet: el botón de tarjeta está, pero sin conexión no deja cobrar con tarjeta.
    await venderEnPantalla(p, { codigo: 'VAR-038', forma: 'tarjeta' });
    await p.waitForSelector('#contenido .mensaje-error', { timeout: 10000 });
    afirmar((await textoDe(p, '#contenido .mensaje-error')).includes('no se cobra con tarjeta'), 'tarjeta: ' + await textoDe(p, '#contenido .mensaje-error'));
    afirmar(await p.locator('.venta-lista').count() === 0, 'cobró con tarjeta sin conexión');
    paso = 'falla';
    await p.evaluate(() => { window.__fallarGuardarVenta = true; });
    await p.click('[data-forma=efectivo]');
    await p.click('#cobrar');
    await p.waitForSelector('.vender .mensaje-error', { timeout: 10000 });
    await p.evaluate(() => { window.__fallarGuardarVenta = false; });
    afirmar((await enEquipo(p, (m, e) => m.pendientes(e), empresa)).length === porSubir, 'la venta que falló quedó en la cola');
    paso = 'transferencia sin referencia';
    await p.click('[data-forma=transferencia]');
    await p.fill('#referencia', '');
    await p.click('#cobrar');
    await p.waitForSelector('.vender .mensaje-error', { timeout: 10000 });
    afirmar((await textoDe(p, '.vender .mensaje-error')).includes('referencia'), 'transferencia sin referencia');
    paso = 'transferencia';
    await p.fill('#referencia', 'REF-777');
    await p.fill('#banco-transferencia', 'BAC');
    await p.click('#cobrar');
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    porSubir++;
    const comp = await textoDe(p, '[data-local=si]');
    const n = Number(/001-001-01-(\d{8})/.exec(comp)[1]);
    afirmar(n === primerNumero + 1, `la venta que falló gastó número: ${n} después de ${primerNumero}`);
    paso = 'otra transferencia con la misma referencia';
    await p.click('text=Nueva venta');
    await venderEnPantalla(p, { codigo: 'VAR-038', forma: 'transferencia', referencia: 'ref-777', banco: '' });
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    porSubir++;
    afirmar((await textoDe(p, '#sin-conexion')).includes(`${porSubir} ventas guardadas`), 'barra: ' + await textoDe(p, '#sin-conexion'));
  });

  await prueba('sin conexión: precio cambiado a mano en IndexedDB (se manda tal cual y el servidor lo deja por resolver)', async () => {
    const p = usar(a.p);
    await p.click('text=Nueva venta');
    await venderEnPantalla(p, { codigo: 'CEM-425' });
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    porSubir++;
    const cambiada = await p.evaluate(async (empresaId) => {
      const m = await import('/js/sin_internet.js');
      const lista = await m.pendientes(empresaId);
      const r = lista[lista.length - 1];
      r.payload.lineas[0].precio_unitario_centavos -= 1000;
      r.payload.lineas[0].total_centavos -= 1000;
      r.payload.total_centavos -= 1000;
      r.payload.pagos[0].monto_centavos -= 1000;
      r.total_centavos -= 1000;
      await m._pruebas.poner(await m._pruebas.baseEquipo(empresaId), 'cola', r);
      return r.numero_documento;
    }, empresa);
    afirmar(/^001-001-01-/.test(cambiada), 'no se cambió');
    global.numeroManipulado = cambiada;
  });

  await prueba('recargar SIN internet: la app abre con lo guardado, las ventas siguen ahí y no deja salir', async () => {
    const p = usar(a.p);
    await p.reload();
    await p.waitForSelector('.saludo, #buscar-producto, .pestanas', { timeout: 20000 });
    await p.waitForFunction((n) => (document.getElementById('sin-conexion').textContent || '').includes(`Sin conexión: ${n} ventas guardadas en este equipo`), porSubir, { timeout: 10000 });
    await ir(p, 'vender/ventas');
    await p.waitForSelector('[data-local][data-estado=en_equipo]', { timeout: 15000 });
    afirmar(await p.locator('[data-local][data-estado=en_equipo]').count() === porSubir, 'ventas del equipo en la lista');
    paso = 'salir';
    await p.click('header button:has-text("Salir")');
    await p.waitForSelector('#avisos .mensaje-error', { timeout: 5000 });
    afirmar((await textoDe(p, '#avisos .mensaje-error')).includes('Conéctese para subir'), 'salir con ventas');
    afirmar(await p.locator('.pestanas').count() === 1, 'salió con ventas sin subir');
    paso = 'vender otra sin internet tras recargar';
    await ir(p, 'vender/nueva');
    await venderEnPantalla(p, { codigo: 'VAR-038' });
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    porSubir++;
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_recargar_sin_internet.png'), fullPage: true });
  });

  await prueba('vuelve el internet con corte a mitad de la subida: el servidor guardó, se reintenta y nada se duplica', async () => {
    const p = usar(a.p);
    let cortes = 0;
    // La primera subida llega al servidor pero la respuesta se pierde (como un corte justo después de guardar).
    await a.ctx.route('**/rest/v1/rpc/subir_ventas_sin_internet', async (route) => {
      if (cortes === 0) { cortes++; await route.fetch().catch(() => {}); await route.abort('connectionreset'); } else await route.continue();
    });
    await a.ctx.setOffline(false);
    await p.waitForFunction(() => true);
    paso = 'primer intento';
    for (let i = 0; i < 60 && cortes === 0; i++) await p.waitForTimeout(250);
    afirmar(cortes === 1, 'no intentó subir al volver la conexión');
    await p.waitForTimeout(800);
    const enServidor = Number(sql(null, `(SELECT count(*) FROM public.venta_sin_internet WHERE empresa_id = '${empresa}')`));
    afirmar(enServidor > 0, 'el primer envío no llegó al servidor');
    paso = 'reintento';
    const r = await subirTodo(p, empresa);
    afirmar(r.quedan === 0, 'quedan por subir: ' + JSON.stringify(r));
    const vsi = Number(sql(null, `(SELECT count(*) FROM public.venta_sin_internet WHERE empresa_id = '${empresa}')`));
    afirmar(vsi === porSubir, `ventas sin internet en el servidor: ${vsi}, esperaba ${porSubir}`);
    const nums = ventasCaja();
    afirmar(new Set(nums).size === nums.length, 'números repetidos: ' + nums.join(', '));
    const manip = JSON.parse(sql(null, `(SELECT row_to_json(x) FROM (SELECT estado, problema FROM public.venta_sin_internet WHERE numero_documento = '${global.numeroManipulado}') x)`));
    afirmar(manip.estado === 'por_resolver', 'el precio manipulado no quedó por resolver: ' + JSON.stringify(manip));
    await p.waitForFunction(() => /Todo subido|^$/.test((document.getElementById('sin-conexion').textContent || '')), null, { timeout: 10000 });
    await a.ctx.unroute('**/rest/v1/rpc/subir_ventas_sin_internet');
  });

  await prueba('dos pestañas: solo una sube a la vez (navigator.locks) y la venta sube una sola vez', async () => {
    const p = usar(a.p);
    await a.ctx.setOffline(true);
    await ir(p, 'vender/nueva');
    await venderEnPantalla(p, { codigo: 'VAR-038' });
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    porSubir++;
    const p2 = await a.ctx.newPage();
    p2.on('pageerror', (e) => erroresJs.push(e.message));
    await a.ctx.setOffline(false);
    await p2.goto(URL_APP + '/#/inicio/hoy');
    await p2.waitForSelector('.pestanas', { timeout: 20000 });
    const [r1, r2] = await Promise.all([enEquipo(p, (m, e) => m.subir(e), empresa), enEquipo(p2, (m, e) => m.subir(e), empresa)]);
    const vsi = Number(sql(null, `(SELECT count(*) FROM public.venta_sin_internet WHERE empresa_id = '${empresa}')`));
    afirmar(vsi === porSubir, `ventas sin internet: ${vsi}, esperaba ${porSubir} (${JSON.stringify([r1, r2])})`);
    afirmar((await enEquipo(p, (m, e) => m.pendientes(e), empresa)).length === 0, 'quedaron pendientes');
    await p2.close();
  });

  const b = await nueva();
  await prueba('supervisor: "Ventas sin internet por resolver" registra la del precio cambiado con motivo', async () => {
    const p = usar(b.p);
    await entrar(p, DUENO);
    await ir(p, 'vender/por_resolver');
    await p.waitForSelector('.venta-por-resolver', { timeout: 15000 });
    const fila = p.locator('.venta-por-resolver', { hasText: global.numeroManipulado });
    afirmar(await fila.count() === 1, 'no aparece la venta por resolver');
    afirmar((await fila.innerText()).includes('precio'), 'sin explicación del problema: ' + await fila.innerText());
    await fila.locator('[data-registrar]').click();
    await p.fill('dialog.dialogo textarea', 'El cliente pagó ese precio, lo autorizó la dueña');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
    const est = sql(null, `(SELECT estado FROM public.venta_sin_internet WHERE numero_documento = '${global.numeroManipulado}')`);
    afirmar(est === 'resuelta', 'estado: ' + est);
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_por_resolver.png'), fullPage: true });
  });

  await prueba('transferencias por confirmar: referencia repetida avisa, "Llegó" pasa al banco y "No llegó" la deja como deuda del cajero', async () => {
    const p = usar(b.p);
    await ir(p, 'dinero/transferencias');
    await p.waitForSelector('#lista-transferencias [data-pago]', { timeout: 15000 });
    const filas = p.locator('#lista-transferencias [data-pago][data-estado=por_confirmar]');
    afirmar(await filas.count() === 2, 'transferencias por confirmar: ' + await filas.count());
    afirmar(await p.locator('[data-dato=referencia-repetida]').count() === 2, 'falta el aviso de referencia repetida');
    const pagos = await filas.evaluateAll((xs) => xs.map((x) => x.dataset.pago));
    paso = 'llegó';
    await p.locator(`[data-confirmar="${pagos[0]}"]`).click();
    await p.selectOption('#trf-banco', sql(null, `demo.id('BAC')`));
    await p.click('#trf-guardar');
    await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
    paso = 'no llegó';
    await p.waitForSelector(`[data-no-llego="${pagos[1]}"]`, { timeout: 15000 });
    await p.locator(`[data-no-llego="${pagos[1]}"]`).click();
    afirmar((await textoDe(p, 'dialog.dialogo')).includes('deuda del cajero'), 'explicación de no llegó: ' + await textoDe(p, 'dialog.dialogo'));
    await p.fill('dialog.dialogo textarea', 'El banco no muestra el depósito después de tres días');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
    const est = JSON.parse(sql(null, `(SELECT jsonb_object_agg(id, jsonb_build_object('e', estado_transferencia, 'd', deuda_de)) FROM public.venta_pago WHERE id IN ('${pagos[0]}', '${pagos[1]}'))`));
    afirmar(est[pagos[0]].e === 'confirmada' && est[pagos[1]].e === 'no_llego' && est[pagos[1]].d === 'cajero', 'estados: ' + JSON.stringify(est));
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_transferencias.png'), fullPage: true });
  });

  let ultimoA = null;
  await prueba('cerrar el turno devuelve los números del equipo (bloque devuelto) y la caja cierra', async () => {
    const p = usar(a.p);
    await ir(p, 'caja/turno');
    await p.waitForSelector('#cerrar-turno', { timeout: 15000 });
    await p.click('#cerrar-turno');
    await p.fill('#cierre-total', '0');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#t-res', { timeout: 20000 });
    const est = sql(null, `(SELECT string_agg(estado, ',') FROM public.numero_bloque WHERE empresa_id = '${empresa}')`);
    afirmar(est === 'devuelto', 'bloque: ' + est);
    const local = await enEquipo(p, (m, e) => m.bloquesLocales(e), empresa);
    afirmar(local.every((x) => x.estado === 'devuelto'), 'el equipo no marcó el bloque devuelto');
    ultimoA = Math.max(...ventasCaja().map((x) => Number(x.slice(-8))));
  });

  const c = await nueva();
  await prueba('otro equipo: la numeración CAI sigue correlativa, sin repetir ni saltar', async () => {
    const p = usar(c.p);
    abrirTurno(CAJERO);
    await entrar(p, CAJERO);
    await p.evaluate(() => navigator.serviceWorker.ready.then(() => true));
    await ir(p, 'ajustes/sin_internet');
    await p.waitForSelector('#si-preparar', { timeout: 15000 });
    await p.fill('#si-nombre-equipo', 'Celular de Ana');
    await p.click('#si-preparar');
    await p.waitForSelector('[data-dato=quedan]', { timeout: 20000 });
    await ir(p, 'vender/nueva');
    await p.waitForSelector('[data-dato=caja-con-bloque]', { timeout: 15000 });
    await c.ctx.setOffline(true);
    await venderEnPantalla(p, { codigo: 'CEM-425' });
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    const n = Number(/001-001-01-(\d{8})/.exec(await textoDe(p, '[data-local=si]'))[1]);
    await c.ctx.setOffline(false);
    const r = await subirTodo(p, empresa);
    afirmar(r.quedan === 0, 'no subió: ' + JSON.stringify(r));
    const nums = ventasCaja().map((x) => Number(x.slice(-8)));
    afirmar(new Set(nums).size === nums.length, 'números repetidos');
    afirmar(n === ultimoA + 1, `el otro equipo empezó en ${n}; el último del primero fue ${ultimoA}`);
    for (let i = 1; i <= Math.max(...nums); i++) afirmar(nums.includes(i), `falta el número ${i} (salto)`);
  });

  await prueba('equipo desactivado: su bloque queda "por conciliar" y se concilia con motivo', async () => {
    const p = usar(b.p);
    await ir(p, 'ajustes/sin_internet');
    await p.waitForSelector('#si-equipos [data-desactivar]', { timeout: 15000 });
    const eq = sql(null, `(SELECT id FROM public.equipo WHERE nombre = 'Celular de Ana')`);
    await p.locator(`[data-desactivar="${eq}"]`).click();
    await p.fill('dialog.dialogo textarea', 'Se perdió el celular de la caja');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
    await p.waitForSelector('[data-estado=por_conciliar] [data-conciliar]', { timeout: 15000 });
    afirmar(sql(null, `(SELECT estado FROM public.numero_bloque WHERE equipo_id = '${eq}')`) === 'por_conciliar', 'no quedó por conciliar');
    await p.locator('[data-conciliar]').first().click();
    await p.fill('dialog.dialogo textarea', 'Revisadas las copias en papel: no hay más ventas');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
    afirmar(sql(null, `(SELECT estado FROM public.numero_bloque WHERE equipo_id = '${eq}')`) === 'conciliado', 'no quedó conciliado');
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_equipos.png'), fullPage: true });
  });

  await prueba('celular de 390 px sin internet: la barra no tapa Cobrar y nada se sale a lo ancho', async () => {
    const d = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const p = usar(d.p);
    // Cierra el turno de Ana del otro equipo (su bloque ya se concilió) y abre el de la dueña.
    sqlEscribir(CAJERO, `SELECT public.cerrar_turno((SELECT id FROM public.turno_caja WHERE caja_id = '${cajaId}' AND estado = 'abierto'),
      ${sql(null, `(SELECT coalesce(saldo_centavos, 0) FROM public.v_cuenta_dinero WHERE caja_id = '${cajaId}')`)}, gen_random_uuid())`);
    abrirTurno(DUENO);
    await entrar(p, DUENO);
    await p.evaluate(() => navigator.serviceWorker.ready.then(() => true));
    await ir(p, 'ajustes/sin_internet');
    await p.waitForSelector('#si-preparar', { timeout: 15000 });
    afirmar(await anchoPagina(p) <= 390, 'Ajustes > Sin internet se sale a lo ancho');
    await p.click('#si-preparar');
    await p.waitForSelector('[data-dato=quedan]', { timeout: 20000 });
    await d.ctx.setOffline(true);
    await p.reload();
    await p.waitForSelector('.barra-inferior', { state: 'attached', timeout: 20000 });
    await ir(p, 'vender/nueva');
    await p.waitForSelector('#buscar-producto', { timeout: 15000 });
    await p.fill('#buscar-producto', 'CEM-425');
    await p.locator('.resultado-producto').first().click();
    await p.waitForFunction(() => /L\s?[0-9]/.test((document.querySelector('[data-dato=total]') || {}).textContent || ''), null, { timeout: 15000 });
    await p.locator('#cobrar').scrollIntoViewIfNeeded();
    const choca = await p.evaluate(() => {
      const r1 = document.getElementById('sin-conexion').getBoundingClientRect(), r2 = document.getElementById('cobrar').getBoundingClientRect();
      return !(r1.bottom <= r2.top || r2.bottom <= r1.top || r1.right <= r2.left || r2.right <= r1.left);
    });
    afirmar(!choca, 'la barra tapa Cobrar');
    afirmar(await anchoPagina(p) <= 390, 'vender sin internet se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_celular_sin_internet.png'), fullPage: true });
    await p.click('#cobrar');
    await p.waitForSelector('.venta-lista[data-estado=en_equipo]', { timeout: 20000 });
    afirmar(await anchoPagina(p) <= 390, 'el comprobante se sale a lo ancho');
    await d.ctx.setOffline(false);
    await subirTodo(p, empresa);
    await d.ctx.close();
  });

  await prueba('talonario de emergencia: registrar el rango, pasar una factura, anular un número y ver el hueco', async () => {
    const p = usar(b.p);
    await ir(p, 'vender/talonario');
    await p.waitForSelector('#tal-nuevo', { timeout: 15000 });
    await p.click('#tal-nuevo');
    await p.fill('#tal-cai', 'B1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D7');
    await p.fill('#tal-desde', '001-901-01-00000001');
    await p.fill('#tal-hasta', '001-901-01-00000050');
    const lim = sql(null, `to_char(public.hoy_local('${empresa}') + 90, 'YYYY-MM-DD')`);
    await p.fill('#tal-limite', lim);
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#tal-pasar', { timeout: 15000 });
    paso = 'pasar';
    await p.click('#tal-pasar');
    await p.fill('#tal-numero', '3');
    await p.fill('#tal-buscar', 'CEM-425');
    await p.locator('.resultados-busqueda button').first().click();
    await p.waitForSelector('#tal-total [data-dato=total]', { timeout: 15000 });
    await p.click('#tal-guardar');
    await p.waitForSelector('[data-talonario] [data-numero="3"][data-estado=usado]', { timeout: 15000 });
    paso = 'repetido';
    await p.click('#tal-pasar');
    await p.fill('#tal-numero', '3');
    await p.fill('#tal-buscar', 'CEM-425');
    await p.locator('.resultados-busqueda button').first().click();
    await p.waitForSelector('#tal-total [data-dato=total]', { timeout: 15000 });
    await p.click('#tal-guardar');
    await p.waitForSelector('form .mensaje-error', { timeout: 15000 });
    afirmar((await textoDe(p, 'form .mensaje-error')).length > 5, 'sin error del número repetido');
    await p.click('text=Cancelar');
    paso = 'anular';
    await p.waitForSelector('[data-anular-en]', { timeout: 15000 });
    await p.locator('[data-anular-en]').first().click();
    await p.fill('#tal-anular-numero', '1');
    await p.click('text=Anular este número');
    await p.fill('dialog.dialogo textarea', 'Se arruinó al escribirla');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('[data-talonario] [data-numero="1"][data-estado=anulado]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=huecos]')).includes('00000002'), 'no se ve el hueco del 2');
    afirmar((await textoDe(p, '[data-dato=usados]')).trim() === '1' && (await textoDe(p, '[data-dato=anulados]')).trim() === '1'
      && (await textoDe(p, '[data-dato=libres]')).trim() === '48', 'cuentas del talonario');
    const v = JSON.parse(sql(null, `(SELECT row_to_json(x) FROM (SELECT numero_documento, estado FROM public.venta WHERE numero_documento = '001-901-01-00000003') x)`));
    afirmar(v.estado === 'emitida', 'venta del talonario: ' + JSON.stringify(v));
    await p.screenshot({ path: path.join(CAPTURAS, 'v14_talonario.png'), fullPage: true });
  });

  if (erroresJs.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + erroresJs.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total})`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
