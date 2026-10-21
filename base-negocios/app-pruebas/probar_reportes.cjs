// PRUEBA: Reportes y cierre de mes (app 0.8.0) en el navegador (Chromium con Playwright) contra la base de demo:
// cada pantalla carga, sus cifras cuadran con la base (SQL) y con cuentas hechas a mano, un puesto sin permiso no
// la ve, en el celular no se sale a lo ancho (con capturas), el Excel se descarga con las cifras y lo impreso no
// tiene emojis ni íconos. Cierre: revisión antes de cerrar, cerrar (con un corte de internet a medio camino),
// reabrir con motivo y el rechazo de reabrir un mes con reparto de utilidad.
// La corre herramientas/probar_app.sh después de probar_compras_dinero.cjs (misma base y servidor). Va al final
// porque reabre y vuelve a cerrar el mes pasado.
'use strict';
const path = require('node:path');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
let playwright;
try { playwright = require('playwright'); } catch { playwright = require('/opt/node22/lib/node_modules/playwright'); }
const { chromium } = playwright;

const URL_APP = process.env.URL_APP || 'http://127.0.0.1:8091';
const BASE = process.env.BASE_DEMO || 'demo_pruebas_app';
const CAPTURAS = process.env.CAPTURAS || path.join(__dirname, 'capturas');
const CLAVE = process.env.DEMO_CLAVE || 'demo1234';
// Emojis y pictogramas (igual que app/js/imprimible.js; escrito con \u{...} para que este archivo no tenga emojis).
const EMOJI_RE = /(?:(?![©®™])\p{Extended_Pictographic}|[\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}︎️‍⃣\u{E0020}-\u{E007F}])/u;

let fallas = 0, total = 0;
async function prueba(nombre, fn) {
  total++;
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++; console.log(`  FALLA  ${nombre}\n           ${String(e.message).split('\n')[0]}`); }
}
function afirmar(cond, que) { if (!cond) throw new Error(que); }

// Consulta como el usuario indicado, en una transacción que se deshace (fijo = true: se guarda).
function sql(correo, consulta, fijo = false) {
  const guion = `BEGIN; ${correo ? `SELECT demo.como('${correo}') \\g /dev/null` : ''}
SELECT '@@' || (${consulta})::text; ${fijo ? 'COMMIT' : 'ROLLBACK'};`;
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE], { input: guion, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  const linea = r.stdout.split('\n').find((l) => l.startsWith('@@'));
  return linea ? linea.slice(2) : null;
}
// Error que da el servidor (o null si no falla).
function errorSql(correo, consulta) {
  try { sql(correo, consulta); return null; } catch (e) { return e.message; }
}
const num = (correo, consulta) => Number(sql(correo, consulta));
const id = (clave) => sql(null, `demo.id('${clave}')`);
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
async function ir(p, ruta, esperar) {
  if (await p.evaluate(() => location.hash) === '#/' + ruta) await p.click(`a.subpestana[href="#/${ruta}"]`);
  else await p.goto(URL_APP + '/#/' + ruta);
  if (esperar) await p.waitForSelector(esperar, { timeout: 20000 });
}
async function revisarPantalla(p, que, ancho) {
  const x = await p.evaluate(() => ({ ancho: document.documentElement.scrollWidth, texto: document.getElementById('app').innerText }));
  afirmar(x.ancho <= ancho, `${que} se sale a lo ancho: ${x.ancho}`);
  afirmar(!/(^|\s)(null|undefined|NaN)(\s|$)/.test(x.texto), `${que} muestra null, undefined o NaN`);
  afirmar(!/\b[A-Z]{3,}_[A-Z_]+\b/.test(x.texto), `${que} muestra un código de error crudo`);
  afirmar(!EMOJI_RE.test(x.texto), `${que} tiene un emoji`);
}
// Lee un .xlsx descargado con el SheetJS de la app: { hojas: [nombres], celdas: { hoja: aoa } }.
async function leerExcel(p, descarga) {
  const b64 = fs.readFileSync(await descarga.path()).toString('base64');
  return p.evaluate(async (datos) => {
    const { cargarXLSX } = await import('/js/excel.js');
    const XLSX = await cargarXLSX();
    const wb = XLSX.read(Uint8Array.from(atob(datos), (c) => c.charCodeAt(0)), { type: 'array' });
    const celdas = {};
    for (const n of wb.SheetNames) celdas[n] = XLSX.utils.sheet_to_json(wb.Sheets[n], { header: 1, raw: true, defval: null });
    return { hojas: wb.SheetNames, celdas };
  }, b64);
}

(async () => {
  const nav = await chromium.launch();
  const EM = id('EMPRESA');
  const HOY = sql(null, `public.hoy_local('${EM}')`);
  const [A, M] = HOY.split('-').map(Number);
  const MA = M === 1 ? 12 : M - 1, AA = M === 1 ? A - 1 : A; // mes pasado (cerrado y con reparto en la demo)
  const desdeMes = `${A}-${String(M).padStart(2, '0')}-01`;
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true, ...opciones });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };
  const celular = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true };

  console.log('Pruebas de Reportes y cierre de mes (app 0.8.0):');
  const d = await nueva();
  await entrar(d.p, 'dueno@demo.hn');

  await prueba('¿Gané o perdí?: cifras del mes iguales al estado de resultados del núcleo, frase sencilla y comparación', async () => {
    const p = d.p;
    await ir(p, 'reportes/gane', '#gane-frase');
    const er = JSON.parse(sql('dueno@demo.hn', `public.estado_resultados('${EM}', ${A}, ${M})`));
    const ant = er.comparativo.mes_anterior;
    afirmar(Number(await p.getAttribute('#gane-frase', 'data-neta')) === er.utilidad_neta_centavos, 'ganancia neta distinta al núcleo');
    afirmar((await texto(p, '[data-dato=gane-ventas] .cifra-valor')) === lempiras(er.ventas_netas_centavos), 'ventas distintas');
    afirmar((await texto(p, '[data-dato=gane-costo] .cifra-valor')) === lempiras(er.costo_ventas_centavos), 'costo distinto');
    afirmar((await texto(p, '[data-dato=gane-bruta] .cifra-valor')) === lempiras(er.utilidad_bruta_centavos), 'ganancia bruta distinta');
    // Hecho a mano: bruta = ventas - costo; neta = bruta - gastos + otros ingresos - otros gastos.
    afirmar(er.utilidad_bruta_centavos === er.ventas_netas_centavos - er.costo_ventas_centavos, 'bruta a mano');
    afirmar(er.utilidad_neta_centavos === er.utilidad_bruta_centavos - er.gastos_operacion_centavos + er.otros_ingresos_centavos - er.otros_gastos_centavos, 'neta a mano');
    const dif = er.utilidad_neta_centavos - ant.utilidad_neta_centavos;
    const frase = await texto(p, '#gane-frase');
    afirmar(frase.includes(lempiras(Math.abs(er.utilidad_neta_centavos))) && frase.includes(`${lempiras(Math.abs(dif))} ${dif > 0 ? 'más' : 'menos'} que en`), 'frase: ' + frase);
    afirmar(await p.locator('[data-info=preliminar]').count() === 1, 'el mes abierto no dice que es preliminar');
    afirmar(await p.locator('#gane-comparar tr').count() === 6, 'tabla de comparación');
  });

  await prueba('¿Gané o perdí?: "Otras fechas" (saldo_cuentas) da lo mismo que el núcleo para el mes pasado; formato NIIF con balance que cuadra', async () => {
    const p = d.p;
    const er = JSON.parse(sql('dueno@demo.hn', `public.estado_resultados('${EM}', ${AA}, ${MA})`));
    await p.selectOption('#gane-periodo', 'rango');
    await p.fill('#gane-desde', er.desde); await p.fill('#gane-hasta', er.hasta);
    await p.dispatchEvent('#gane-hasta', 'change');
    await p.waitForFunction((n) => document.querySelector('#gane-frase') && document.querySelector('#gane-frase').dataset.neta === String(n), er.utilidad_neta_centavos, { timeout: 15000 })
      .catch(() => { throw new Error('el rango no da la misma ganancia neta que el núcleo'); });
    afirmar((await texto(p, '[data-dato=gane-ventas] .cifra-valor')) === lempiras(er.ventas_netas_centavos), 'ventas del rango');
    afirmar(await p.locator('#gane-niif').count() === 0, 'el NIIF se ofrece por rango');
    await p.selectOption('#gane-periodo', `${AA}-${String(MA).padStart(2, '0')}`);
    await p.waitForSelector('#gane-niif');
    await p.click('#gane-niif');
    await p.waitForSelector('#gane-niif-ver [data-dato=balance-cuadra]');
    afirmar((await texto(p, '#gane-niif-ver')).includes('Utilidad cobrada'), 'falta la utilidad cobrada en el formato contable');
    await p.selectOption('#gane-periodo', `${A}-${String(M).padStart(2, '0')}`);
    await p.waitForSelector('[data-info=preliminar]');
  });

  await prueba('Ventas: total, formas de pago y vendedores iguales a la base; aclara que no resta devoluciones', async () => {
    const p = d.p;
    await ir(p, 'reportes/ventas', '#ventas-formas');
    const f = `empresa_id = '${EM}' AND estado = 'emitida' AND fecha_contable BETWEEN '${desdeMes}' AND '${HOY}'`;
    const tot = num('dueno@demo.hn', `(SELECT coalesce(sum(total_centavos), 0) FROM public.venta WHERE ${f})`);
    const n = num('dueno@demo.hn', `(SELECT count(*) FROM public.venta WHERE ${f})`);
    afirmar((await texto(p, '[data-dato=ventas-total] .cifra-valor')) === lempiras(tot), 'total vendido distinto a la base');
    afirmar((await texto(p, '[data-dato=ventas-total] .cifra-nota')).startsWith(`${n} venta`), 'cantidad de ventas');
    const efectivo = num('dueno@demo.hn', `(SELECT coalesce(sum(g.monto_centavos), 0) FROM public.venta_pago g JOIN public.venta v ON v.id = g.venta_id WHERE v.${f.replace(/AND /g, 'AND v.')} AND g.forma = 'efectivo')`);
    afirmar((await texto(p, '[data-forma=efectivo_centavos] .monto')) === lempiras(efectivo), 'efectivo distinto a la base');
    const credito = num('dueno@demo.hn', `(SELECT coalesce(sum(credito_centavos), 0) FROM public.venta WHERE ${f})`);
    afirmar((await texto(p, '[data-forma=credito_centavos] .monto')) === lempiras(credito), 'crédito distinto');
    afirmar((await texto(p, '[data-info=devoluciones]')).includes('no restan las devoluciones'), 'no aclara las devoluciones');
    const juan = num('dueno@demo.hn', `(SELECT coalesce(sum(total_centavos), 0) FROM public.venta WHERE ${f} AND vendedor_id = (SELECT id FROM auth.users WHERE email = 'vendedor@demo.hn'))`);
    afirmar(juan > 0 && (await texto(p, '#tabla-vendedores')).includes(lempiras(juan)), 'ventas de Juan');
    // Por semana: la suma de las semanas es el total.
    await p.selectOption('#ventas-agrupar', 'semana');
    await p.waitForSelector('#tabla-rventas');
    const semanas = await p.locator('#tabla-rventas [data-dato^=grupo-]').allInnerTexts();
    const suma = semanas.reduce((s, t) => s + Math.round(Number(t.replace(/[^0-9.-]/g, '')) * 100), 0);
    afirmar(suma === tot, `las semanas suman ${suma} y el total es ${tot}`);
    await p.selectOption('#ventas-agrupar', 'dia');
  });

  await prueba('Inventario valorizado: valor al costo igual a la base, a precio de venta hecho a mano, bajo el mínimo', async () => {
    const p = d.p;
    await ir(p, 'reportes/valorizado', '[data-dato=valor-costo]');
    const costo = num('dueno@demo.hn', `(SELECT coalesce(sum(valor_centavos), 0) FROM public.v_existencia WHERE empresa_id = '${EM}')`);
    afirmar((await texto(p, '[data-dato=valor-costo] .cifra-valor')) === lempiras(costo), 'valor al costo distinto a la base');
    // A mano: cada fila round(cantidad x precio sin ISV).
    const venta = num('dueno@demo.hn', `(SELECT coalesce(sum(round(e.cantidad * p.precio_sin_isv_centavos)), 0) FROM public.v_existencia e JOIN public.v_producto p ON p.producto_id = e.producto_id WHERE e.empresa_id = '${EM}')`);
    afirmar((await texto(p, '[data-dato=valor-venta] .cifra-valor')) === lempiras(venta), 'valor a precio de venta');
    const bajos = num('dueno@demo.hn', `(SELECT count(*) FROM (SELECT p.producto_id FROM public.v_producto p LEFT JOIN public.v_existencia e ON e.producto_id = p.producto_id
      WHERE p.empresa_id = '${EM}' AND p.activo AND p.tipo <> 'servicio' AND p.stock_minimo > 0 GROUP BY p.producto_id, p.stock_minimo HAVING coalesce(sum(e.cantidad), 0) < p.stock_minimo) x)`);
    afirmar(await p.locator('#valor-bajos [data-producto]').count() === bajos, 'bajo el mínimo: ' + bajos);
    afirmar(await p.locator(`#valor-bajos [data-producto="${id('CEM')}"]`).count() === 1, 'el cemento debería estar bajo el mínimo');
  });

  await prueba('Empleados y comisiones: ventas por empleado, comisiones solo sobre lo cobrado y el faltante del turno', async () => {
    const p = d.p;
    await ir(p, 'reportes/empleados', '#tabla-comisiones');
    const juanId = sql(null, `(SELECT id FROM auth.users WHERE email = 'vendedor@demo.hn')`);
    const comJuan = num('dueno@demo.hn', `(SELECT coalesce(sum(monto_centavos), 0) FROM public.v_comision WHERE vendedor_id = '${juanId}' AND fecha_contable >= '${desdeMes}')`);
    afirmar(comJuan > 0 && (await texto(p, `[data-dato=comision-${juanId}]`)) === lempiras(comJuan), 'comisión de Juan distinta a la base');
    // A mano (5 % sobre la ganancia de lo cobrado): taladro 2,173.91 - 1,000 + 5 varillas 804.35 - 600 = 1,378.26 -> 68.91.
    // La venta al crédito de Juan (tubos) todavía no le da comisión.
    afirmar(comJuan === 6891, 'comisión de Juan a mano: ' + comJuan);
    afirmar((await texto(p, '[data-info=comision-cobrado]')).includes('solo sobre lo cobrado'), 'no explica que es sobre lo cobrado');
    const anaId = sql(null, `(SELECT id FROM auth.users WHERE email = 'cajero@demo.hn')`);
    const vendio = num('dueno@demo.hn', `(SELECT coalesce(sum(total_centavos), 0) FROM public.venta WHERE emitida_por = '${anaId}' AND estado = 'emitida' AND fecha_contable >= '${desdeMes}')`);
    afirmar((await texto(p, `[data-dato=vendio-${anaId}]`)) === lempiras(vendio), 'lo que vendió Ana');
    afirmar(await p.locator('#lista-turnos [data-diferencia="-5000"]').count() === 1, 'no sale el turno con faltante de L 50.00');
    afirmar((await texto(p, '[data-dato=faltantes] .cifra-valor')) === 'L 50.00', 'total faltante');
  });

  await prueba('Quién hizo qué: cadena íntegra, frases sencillas con motivo y filtros por persona y tipo', async () => {
    const p = d.p;
    await ir(p, 'reportes/bitacora', '#lista-bitacora');
    await p.waitForSelector('#bit-integridad [data-estado=integra]', { timeout: 20000 });
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.verificar_bitacora('${EM}'))`) === 0, 'la base dice que la cadena tiene problemas');
    const t = await texto(p, '#lista-bitacora');
    afirmar(/anuló una venta #\d+ · motivo: El cliente se arrepintió/.test(t), 'no sale la anulación con su motivo');
    const anaId = sql(null, `(SELECT id FROM auth.users WHERE email = 'cajero@demo.hn')`);
    await p.selectOption('#bit-persona', anaId);
    await p.waitForFunction(() => document.querySelectorAll('#lista-bitacora [data-secuencia]').length > 0
      && [...document.querySelectorAll('#lista-bitacora .fila-icono-titulo')].every((x) => x.textContent.startsWith('Ana Sosa')), null, { timeout: 15000 })
      .catch(() => { throw new Error('el filtro por persona deja filas de otros'); });
    await p.selectOption('#bit-tipo', 'dinero');
    await p.waitForFunction(() => [...document.querySelectorAll('#lista-bitacora [data-tipo]')].every((x) => x.dataset.tipo === 'dinero')
      && document.querySelectorAll('#lista-bitacora [data-tipo]').length > 0, null, { timeout: 15000 });
    await p.selectOption('#bit-persona', ''); await p.selectOption('#bit-tipo', '');
  });

  await prueba('Excel: "Descargar Excel" baja un .xlsx con las cifras del reporte (en lempiras)', async () => {
    const p = d.p;
    await ir(p, 'reportes/gane', '#gane-frase');
    const neta = Number(await p.getAttribute('#gane-frase', 'data-neta'));
    const [desc] = await Promise.all([p.waitForEvent('download'), p.click('#gane-excel')]);
    afirmar(/^gane_o_perdi_.*\.xlsx$/.test(desc.suggestedFilename()), 'nombre del archivo: ' + desc.suggestedFilename());
    const x = await leerExcel(p, desc);
    afirmar(x.hojas.includes('Resumen') && x.hojas.includes('Gastos por categoría'), 'hojas: ' + x.hojas.join(', '));
    const fila = x.celdas.Resumen.find((f) => f[0] === 'Ganancia neta');
    afirmar(fila && Math.round(fila[1] * 100) === neta, 'ganancia neta en el Excel: ' + JSON.stringify(fila));
    afirmar(x.celdas.Resumen[0][0] === 'Ferretería El Roble', 'el Excel no dice el negocio');
    // Ventas y valorizado también.
    await ir(p, 'reportes/valorizado', '[data-dato=valor-costo]');
    const [d2] = await Promise.all([p.waitForEvent('download'), p.click('#valor-excel')]);
    const x2 = await leerExcel(p, d2);
    const costo = num('dueno@demo.hn', `(SELECT coalesce(sum(valor_centavos), 0) FROM public.v_existencia WHERE empresa_id = '${EM}')`);
    const tot = x2.celdas.Productos.find((f) => f[1] === 'Total');
    afirmar(tot && Math.round(tot[5] * 100) === costo, 'total al costo en el Excel');
  });

  await prueba('Impreso: cada reporte imprime solo la hoja (logo, texto y líneas) sin emojis, íconos ni colores', async () => {
    const p = d.p;
    for (const [ruta, listo, boton] of [['reportes/gane', '#gane-frase', '#gane-imprimir'], ['reportes/ventas', '#ventas-formas', '#ventas-imprimir'],
      ['reportes/valorizado', '[data-dato=valor-costo]', '#valor-imprimir'], ['reportes/empleados', '#tabla-comisiones', '#empleados-imprimir'],
      ['reportes/bitacora', '#lista-bitacora', '#bitacora-imprimir'], ['reportes/cierre', '#cierre-detalle section[data-mes]', '#cierre-imprimir']]) {
      await ir(p, ruta, listo);
      await p.evaluate(() => { window.print = () => { window.__impreso = document.querySelector('.reporte-impreso'); }; });
      await p.click(boton);
      await p.waitForFunction(() => window.__impreso, null, { timeout: 15000 });
      const r = await p.evaluate(() => { const x = window.__impreso; return { t: x.textContent, svg: x.querySelectorAll('svg, .icono, .chip-color, .burbuja').length, tablas: x.querySelectorAll('table').length }; });
      afirmar(!EMOJI_RE.test(r.t) && r.svg === 0 && r.tablas > 0 && r.t.includes('Ferretería El Roble'), `${ruta}: lo impreso ${JSON.stringify({ svg: r.svg, tablas: r.tablas })}`);
      await p.emulateMedia({ media: 'print' });
      const vis = await p.evaluate(() => ({ hoja: getComputedStyle(document.querySelector('.reporte-impreso')).display, app: getComputedStyle(document.getElementById('app')).display }));
      await p.emulateMedia({ media: 'screen' });
      afirmar(vis.hoja === 'block' && vis.app === 'none', `${ruta}: al imprimir se ve la pantalla: ${JSON.stringify(vis)}`);
      await p.evaluate(() => { window.dispatchEvent(new Event('afterprint')); window.__impreso = null; });
      afirmar(await p.locator('.reporte-impreso').count() === 0, 'la hoja no se quita después de imprimir');
    }
  });

  await prueba('Permisos: cajero y vendedor no ven Reportes; menú pide lo que exige el núcleo; limitado a su sucursal no ve lo de toda la empresa', async () => {
    for (const correo of ['cajero@demo.hn', 'vendedor@demo.hn']) {
      const { ctx, p } = await nueva();
      await entrar(p, correo);
      afirmar(await p.locator('a.pestana[data-pestana=reportes]').count() === 0, `${correo} ve la pestaña Reportes`);
      await p.goto(URL_APP + '/#/reportes/gane');
      await p.waitForFunction(() => !location.hash.startsWith('#/reportes'));
      await ctx.close();
    }
    const m = await d.p.evaluate(async () => {
      const md = await import('/js/menu_datos.js');
      const r = md.MENU.find((x) => x.id === 'reportes').subs;
      const s = (x) => r.find((y) => y.id === x);
      return [md.visibleCon(s('cierre'), new Set(), new Set(['periodos.cerrar'])), md.visibleCon(s('cierre'), new Set(), new Set(['periodos.cerrar', 'contabilidad.ver'])),
        md.visibleCon(s('valorizado'), new Set(['inventario']), new Set(['inventario.costos'])), md.visibleCon(s('valorizado'), new Set(['inventario']), new Set(['inventario.costos', 'inventario.ver'])),
        r.every((x) => x.pantalla)];
    });
    afirmar(JSON.stringify(m) === '[false,true,false,true,true]', 'permisos del menú: ' + JSON.stringify(m));
    // Usuario limitado a su sucursal (respuesta simulada de mi_estado_sesion).
    const { ctx, p } = await nueva();
    await p.route('**/rest/v1/rpc/mi_estado_sesion', (rr) => rr.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ activo: true, debe_salir: false, dentro_de_horario: true, todas_las_sucursales: false, sucursales: [] }) }));
    await entrar(p, 'admin@demo.hn');
    for (const ruta of ['reportes/gane', 'reportes/bitacora', 'reportes/cierre']) {
      await ir(p, ruta, '#contenido .estado-vacio');
      afirmar((await texto(p, '#contenido')).includes('toda la empresa'), `${ruta} no explica que es de toda la empresa`);
    }
    await ir(p, 'reportes/ventas', '[data-info=vendedor-limitado]');
    afirmar(await p.locator('#tabla-vendedores').count() === 0, 'el limitado ve las ventas por vendedor');
    await ctx.close();
  });

  await prueba('Celular: las seis pantallas no se salen a lo ancho (capturas en computadora y celular)', async () => {
    const pantallas = [['reportes/gane', '#gane-frase'], ['reportes/ventas', '#ventas-formas'], ['reportes/valorizado', '[data-dato=valor-costo]'],
      ['reportes/empleados', '#tabla-comisiones'], ['reportes/bitacora', '#lista-bitacora'], ['reportes/cierre', '#cierre-detalle section[data-mes]']];
    for (const [opc, ancho, suf] of [[{}, 1280, 'computadora'], [celular, 390, 'celular']]) {
      const { ctx, p } = await nueva(opc);
      await entrar(p, 'dueno@demo.hn');
      for (const [ruta, espera] of pantallas) {
        await ir(p, ruta, espera);
        await p.waitForTimeout(200);
        await revisarPantalla(p, `${ruta} (${suf})`, ancho);
        await p.screenshot({ path: path.join(CAPTURAS, `${ruta.replace('/', '_')}_${suf}.png`), fullPage: true });
      }
      await ctx.close();
    }
  });

  // ============================ Cierre de mes (cambia la base: va al final) ============================
  const mesPasado = `${AA}-${String(MA).padStart(2, '0')}`;
  await prueba('cierre: lista de meses con chips; el mes con reparto no se reabre (lo explica y el núcleo lo rechaza)', async () => {
    const p = d.p;
    await ir(p, 'reportes/cierre', `#cierre-meses [data-mes="${mesPasado}"]`);
    afirmar(await p.locator(`#cierre-meses [data-mes="${mesPasado}"] [data-estado=cerrado]`).count() === 1, 'el mes pasado no sale cerrado');
    afirmar(await p.locator(`#cierre-meses [data-mes="${mesPasado}"] [data-reparto=si]`).count() === 1, 'no dice "Con reparto"');
    afirmar(await p.locator(`#cierre-meses [data-mes="${A}-${String(M).padStart(2, '0')}"] [data-estado=abierto]`).count() === 1, 'el mes en curso no sale abierto');
    await p.click(`#cierre-meses [data-mes="${mesPasado}"] button`);
    await p.waitForSelector('[data-info=reabrir-con-reparto]');
    afirmar(await p.locator('#cierre-reabrir').count() === 0, 'ofrece reabrir un mes con reparto');
    const r = JSON.parse(sql('dueno@demo.hn', `(SELECT resumen FROM public.cierre WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA} AND estado = 'vigente')`));
    afirmar((await texto(p, '[data-dato=resumen-neta] .cifra-valor')) === lempiras(r.utilidad_neta_centavos), 'resumen del cierre distinto a la foto');
    const err = errorSql('dueno@demo.hn', `public.reabrir_periodo('${EM}', ${AA}, ${MA}, 'Probar el rechazo')`);
    afirmar(err && err.includes('MES_CON_REPARTO'), 'el núcleo no rechazó reabrir con reparto: ' + err);
    // Libros de ISV del mes, iguales al núcleo.
    await p.click('#cierre-ver-libros');
    await p.waitForSelector('#libro-ventas');
    const li = JSON.parse(sql('dueno@demo.hn', `public.libros_isv('${EM}', ${AA}, ${MA})`));
    afirmar((await texto(p, '[data-dato=libro-isv-ventas] .cifra-valor')) === lempiras(li.libro_ventas.totales.isv_centavos), 'ISV de ventas del libro');
    afirmar(await p.locator('#libro-ventas tbody tr').count() === li.libro_ventas.filas.length, 'filas del libro de ventas');
    const [desc] = await Promise.all([p.waitForEvent('download'), p.click('#libros-excel')]);
    const x = await leerExcel(p, desc);
    afirmar(x.hojas.includes('Libro de ventas') && x.hojas.includes('Libro de compras'), 'hojas de los libros: ' + x.hojas.join(', '));
  });

  await prueba('cierre: el admin ve el cierre pero no puede reabrir (solo el dueño)', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'admin@demo.hn');
    await ir(p, 'reportes/cierre', '#cierre-detalle section[data-mes]');
    await p.click(`#cierre-meses [data-mes="${mesPasado}"] button`);
    await p.waitForSelector(`#cierre-detalle section[data-mes="${mesPasado}"]`);
    afirmar((await texto(p, '#cierre-detalle')).includes('Solo el dueño puede reabrir'), 'al admin no le explica que no reabre');
    await ctx.close();
  });

  await prueba('cierre: reabrir con motivo, revisión antes de cerrar (listo / falta con su botón) y cerrar con un corte de internet (un solo cierre)', async () => {
    const p = d.p;
    // El dueño anula el reparto (lo hace el proveedor; aquí por SQL) para poder reabrir.
    const dist = sql('dueno@demo.hn', `(SELECT id FROM public.distribucion WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA} AND anulada_en IS NULL)`);
    sql('dueno@demo.hn', `public.anular_distribucion('${dist}', 'Prueba: reabrir el mes', gen_random_uuid())`, true);
    await ir(p, 'reportes/cierre', `#cierre-meses [data-mes="${mesPasado}"]`);
    await p.click(`#cierre-meses [data-mes="${mesPasado}"] button`);
    await p.waitForSelector('#cierre-reabrir');
    await p.click('#cierre-reabrir');
    await p.waitForSelector('dialog.dialogo[open] textarea');
    await p.click('dialog.dialogo[open] button[type=submit]'); // sin motivo: no deja
    afirmar((await texto(p, 'dialog.dialogo[open]')).includes('al menos 5 letras'), 'reabrir sin motivo');
    await p.fill('dialog.dialogo[open] textarea', 'Falta registrar una factura del proveedor');
    await p.click('dialog.dialogo[open] button[type=submit]');
    await p.waitForSelector(`#cierre-detalle section[data-mes="${mesPasado}"][data-estado=revision]`, { timeout: 20000 });
    afirmar(sql(null, `(SELECT estado FROM public.periodo WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA})`) === 'abierto', 'la base no quedó abierta');
    afirmar(sql(null, `(SELECT motivo_superada FROM public.cierre WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA} AND version = 1)`) === 'Falta registrar una factura del proveedor', 'el motivo no quedó en la foto superada');
    afirmar(await p.locator(`#cierre-meses [data-mes="${mesPasado}"] [data-estado=revision]`).count() === 1, 'el chip no dice "En revisión"');
    // Revisión: terminado, libros cuadran = listo; aprobaciones pendientes = falta con botón a Pendientes.
    afirmar(await p.getAttribute('[data-revision=terminado]', 'data-listo') === 'true' && await p.getAttribute('[data-revision=cuadra]', 'data-listo') === 'true', 'revisión básica');
    const pend = num('dueno@demo.hn', `(SELECT count(*) FROM public.aprobacion WHERE empresa_id = '${EM}' AND estado = 'pendiente')`);
    afirmar(await p.getAttribute('[data-revision=aprobaciones]', 'data-listo') === String(pend === 0), 'aprobaciones pendientes');
    if (pend) afirmar(await p.getAttribute('[data-revision=aprobaciones] [data-arreglar]', 'href') === '#/inicio/pendientes', 'el botón no lleva a Pendientes');
    afirmar(await p.locator('[data-revision=banco]').count() === 1, 'falta la revisión del banco');
    const er = JSON.parse(sql('dueno@demo.hn', `public.estado_resultados('${EM}', ${AA}, ${MA})`));
    afirmar((await texto(p, '[data-dato=resumen-neta] .cifra-valor')) === lempiras(er.utilidad_neta_centavos), 'resumen del mes');
    // Cerrar: la confirmación explica que queda firme; el primer envío se corta y la app reintenta UNA vez.
    let llamadas = 0;
    await p.route('**/rest/v1/rpc/cerrar_mes', async (rr) => { llamadas++; if (llamadas === 1) await rr.abort('internetdisconnected'); else await rr.continue(); });
    await p.click('#cierre-cerrar');
    await p.waitForSelector('#confirmar-si');
    const conf = await texto(p, 'dialog.dialogo[open]');
    afirmar(conf.includes('quedan firmes') && conf.includes('contrapartida'), 'la confirmación no explica: ' + conf);
    await p.click('#confirmar-si');
    await p.waitForSelector('[data-info=cerrado]', { timeout: 20000 });
    await p.unroute('**/rest/v1/rpc/cerrar_mes');
    afirmar(llamadas === 2, 'llamadas a cerrar_mes: ' + llamadas);
    afirmar(sql(null, `(SELECT estado FROM public.periodo WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA})`) === 'cerrado', 'la base no quedó cerrada');
    afirmar(num(null, `(SELECT count(*) FROM public.cierre WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA} AND estado = 'vigente')`) === 1
      && num(null, `(SELECT max(version) FROM public.cierre WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA})`) === 2, 'debe haber una sola foto vigente (versión 2)');
    // Sin reparto: lleva a Fondos y socios para repartir.
    afirmar(await p.getAttribute('#cierre-repartir', 'href') === '#/dinero/fondos', 'no ofrece repartir la utilidad');
    afirmar(await p.locator('#cierre-reabrir').count() === 1, 'sin reparto debería poder reabrirse');
    await revisarPantalla(p, 'cierre después de cerrar', 1280);
  });

  await prueba('cierre en el celular: revisión del mes en curso sin salirse a lo ancho (captura)', async () => {
    const { ctx, p } = await nueva(celular);
    await entrar(p, 'dueno@demo.hn');
    await ir(p, 'reportes/cierre', '#cierre-meses');
    await p.click(`#cierre-meses [data-mes="${A}-${String(M).padStart(2, '0')}"] button`);
    await p.waitForSelector('#cierre-revision');
    afirmar(await p.getAttribute('[data-revision=terminado]', 'data-listo') === 'false' && await p.locator('#cierre-cerrar[disabled]').count() === 1, 'el mes en curso no debe poder cerrarse');
    await revisarPantalla(p, 'cierre (celular)', 390);
    await p.screenshot({ path: path.join(CAPTURAS, 'reportes_cierre_revision_celular.png'), fullPage: true });
    await ctx.close();
  });

  await d.ctx.close();
  await prueba('sin errores de JavaScript en Reportes', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });
  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de Reportes pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
