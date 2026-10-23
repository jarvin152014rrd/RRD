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
    // 0.8.1: el mes en curso se compara con los MISMOS días del mes anterior (saldo_cuentas).
    const ant = await p.evaluate(async ({ e, d, h2 }) => {
      const api = await import('/js/api.js'); const g = await import('/js/pantallas/rep_gane.js');
      return g.resultadosDeSaldos(await api.rpc('saldo_cuentas', { p_empresa_id: e, p_desde: d, p_hasta: h2 }));
    }, { e: EM, d: `${AA}-${String(MA).padStart(2, '0')}-01`, h2: sql(null, `least(('${AA}-${String(MA).padStart(2, '0')}-01'::date + ${Number(HOY.slice(8, 10)) - 1}), ('${AA}-${String(MA).padStart(2, '0')}-01'::date + interval '1 month' - interval '1 day')::date)`) });
    afirmar(Number(await p.getAttribute('#gane-frase', 'data-neta')) === er.utilidad_neta_centavos, 'ganancia neta distinta al núcleo');
    afirmar((await texto(p, '[data-dato=gane-ventas] .cifra-valor')) === lempiras(er.ventas_netas_centavos), 'ventas distintas');
    afirmar((await texto(p, '[data-dato=gane-costo] .cifra-valor')) === lempiras(er.costo_ventas_centavos), 'costo distinto');
    afirmar((await texto(p, '[data-dato=gane-bruta] .cifra-valor')) === lempiras(er.utilidad_bruta_centavos), 'ganancia bruta distinta');
    // Hecho a mano: bruta = ventas - costo; neta = bruta - gastos + otros ingresos - otros gastos.
    afirmar(er.utilidad_bruta_centavos === er.ventas_netas_centavos - er.costo_ventas_centavos, 'bruta a mano');
    afirmar(er.utilidad_neta_centavos === er.utilidad_bruta_centavos - er.gastos_operacion_centavos + er.otros_ingresos_centavos - er.otros_gastos_centavos, 'neta a mano');
    const dif = er.utilidad_neta_centavos - ant.utilidad_neta_centavos;
    const frase = await texto(p, '#gane-frase');
    afirmar(frase.includes(lempiras(Math.abs(er.utilidad_neta_centavos))) && frase.includes(`${lempiras(Math.abs(dif))} ${dif > 0 ? 'más' : 'menos'} que en los mismos días de`), 'frase: ' + frase);
    afirmar(await p.locator('[data-info=preliminar]').count() === 1, 'el mes abierto no dice que es preliminar');
    afirmar(await p.locator('#gane-comparar tr').count() >= 6, 'tabla de comparación');
    // La tarjeta de Gastos (operación + otros gastos) cuadra con la tabla.
    const filasTabla = await p.locator('#gane-comparar tbody tr').allInnerTexts();
    const ahora = (t) => { const f = filasTabla.find((x) => x.startsWith(t)); return f ? Math.round(Number(f.split('\t')[1].replace(/[^0-9.-]/g, '')) * 100) : 0; };
    afirmar(ahora('Gastos de operación') + ahora('Otros gastos') === er.gastos_operacion_centavos + er.otros_gastos_centavos
      && (await texto(p, '[data-dato=gane-gastos] .cifra-valor')) === lempiras(er.gastos_operacion_centavos + er.otros_gastos_centavos), 'la tarjeta de gastos no cuadra con la tabla');
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
    const efectivo = num('dueno@demo.hn', `(SELECT coalesce(sum(g.monto_centavos), 0) FROM public.venta_pago g JOIN public.venta v ON v.id = g.venta_id WHERE v.empresa_id = '${EM}' AND v.estado = 'emitida' AND v.fecha_contable BETWEEN '${desdeMes}' AND '${HOY}' AND g.forma = 'efectivo')`);
    afirmar((await texto(p, '[data-forma=efectivo_centavos] .monto')) === lempiras(efectivo), 'efectivo distinto a la base');
    const credito = num('dueno@demo.hn', `(SELECT coalesce(sum(credito_centavos), 0) FROM public.venta WHERE ${f})`);
    afirmar((await texto(p, '[data-forma=credito_centavos] .monto')) === lempiras(credito), 'crédito distinto');
    afirmar((await texto(p, '[data-info=devoluciones]')).includes('no restan las devoluciones'), 'no aclara las devoluciones');
    const juanId = sql(null, `(SELECT id FROM auth.users WHERE email = 'vendedor@demo.hn')`);
    const juan = num('dueno@demo.hn', `(SELECT coalesce(sum(total_centavos), 0) FROM public.venta WHERE ${f} AND vendedor_id = '${juanId}')`);
    afirmar(juan > 0 && (await texto(p, '#tabla-vendedores')).includes(lempiras(juan)), 'ventas de Juan');
    // Por semana: la suma de las semanas es el total.
    await p.selectOption('#ventas-agrupar', 'semana');
    await p.waitForSelector('#tabla-rventas');
    const semanas = await p.locator('#tabla-rventas [data-dato^=grupo-]').allInnerTexts();
    const suma = semanas.reduce((s, t) => s + Math.round(Number(t.replace(/[^0-9.-]/g, '')) * 100), 0);
    afirmar(suma === tot, `las semanas suman ${suma} y el total es ${tot}`);
    await p.selectOption('#ventas-agrupar', 'dia');
    // 0.9.0: lo más vendido lo suma el servidor (mas_vendido) y resta devoluciones: igual a la base.
    const mv = JSON.parse(sql('dueno@demo.hn', `public.mas_vendido('${EM}', '${desdeMes}', '${HOY}', 10)`));
    await p.waitForSelector('#tabla-rventas');
    await p.waitForSelector('[data-info=top-con-devoluciones]', { timeout: 20000 }).catch(() => {});
    afirmar(await p.locator('[data-info=top-con-devoluciones]').count() === 1, 'no dice que resta devoluciones: ' + (await texto(p, '#contenido')).slice(0, 300));
    const tops = await p.locator('#ventas-top [data-top-total]').evaluateAll((els) => els.map((e) => Number(e.dataset.topTotal)));
    afirmar(JSON.stringify(tops) === JSON.stringify(mv.filas.map((x) => Number(x.total_neto_centavos))), 'lo más vendido distinto a mas_vendido: ' + JSON.stringify(tops));
    // A mano con SQL: lo vendido menos lo devuelto del primero.
    const pid = mv.filas[0].producto_id;
    const neto = num('dueno@demo.hn', `(SELECT coalesce((SELECT sum(l.total_centavos) FROM public.venta_linea l JOIN public.venta v ON v.id = l.venta_id
      WHERE ${f.replace(/estado/g, 'v.estado').replace(/fecha_contable/g, 'v.fecha_contable').replace(/empresa_id/g, 'v.empresa_id')} AND l.producto_id = '${pid}'), 0)
      - coalesce((SELECT sum(l.total_centavos) FROM public.devolucion_linea l JOIN public.devolucion x ON x.id = l.devolucion_id
      WHERE x.empresa_id = '${EM}' AND x.estado = 'aplicada' AND x.fecha_contable BETWEEN '${desdeMes}' AND '${HOY}' AND l.producto_id = '${pid}'), 0))`);
    afirmar(tops[0] === neto, `el primero: ${tops[0]} y a mano ${neto}`);
    // Núcleo 0.15.0 (sin mas_vendido): se suma en el navegador, sin restar devoluciones.
    await p.route('**/rest/v1/rpc/mas_vendido', (rr) => rr.fulfill({ status: 404, contentType: 'application/json',
      body: JSON.stringify({ code: 'PGRST202', message: 'Could not find the function public.mas_vendido without parameters in the schema cache' }) }));
    await ir(p, 'reportes/ventas', '[data-info=top-sin-devoluciones]');
    const viejo = num('dueno@demo.hn', `(SELECT max(s) FROM (SELECT sum(total_centavos) AS s FROM public.v_venta_linea WHERE ${f} GROUP BY producto_id) x)`);
    afirmar(Number(await p.locator('#ventas-top [data-top-total]').first().getAttribute('data-top-total')) === viejo, 'núcleo viejo: el primero no es el de antes');
    await p.unroute('**/rest/v1/rpc/mas_vendido');
    await p.evaluate(async () => (await import('/js/datos.js')).olvidarDatos());   // olvida también "no existe mas_vendido"
  });

  await prueba('Inventario valorizado: valor al costo igual a la base, a precio de venta hecho a mano, bajo el mínimo', async () => {
    const p = d.p;
    await ir(p, 'reportes/valorizado', '[data-dato=valor-costo]');
    const costo = num('dueno@demo.hn', `(SELECT coalesce(sum(v), 0) FROM (SELECT sum(valor_centavos) AS v FROM public.v_existencia WHERE empresa_id = '${EM}' GROUP BY producto_id HAVING sum(cantidad) > 0) x)`);
    afirmar((await texto(p, '[data-dato=valor-costo] .cifra-valor')) === lempiras(costo), 'valor al costo distinto a la base');
    // A mano: cada fila round(cantidad x precio sin ISV).
    const venta = num('dueno@demo.hn', `(SELECT coalesce(sum(v), 0) FROM (SELECT sum(round(e.cantidad * p.precio_sin_isv_centavos)) AS v FROM public.v_existencia e JOIN public.v_producto p ON p.producto_id = e.producto_id WHERE e.empresa_id = '${EM}' GROUP BY e.producto_id HAVING sum(e.cantidad) > 0) x)`);
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
    const faltante = num('dueno@demo.hn', `(SELECT coalesce(-sum(diferencia_centavos), 0) FROM public.v_turno_caja WHERE empresa_id = '${EM}' AND estado <> 'abierto' AND diferencia_centavos < 0 AND fecha_cierre BETWEEN '${desdeMes}' AND '${HOY}')`);
    afirmar(faltante >= 5000 && (await texto(p, '[data-dato=faltantes] .cifra-valor')) === lempiras(faltante), 'total faltante');
  });

  await prueba('Quién hizo qué: cadena íntegra, frases sencillas con motivo y filtros por persona y tipo', async () => {
    const p = d.p;
    await ir(p, 'reportes/bitacora', '#lista-bitacora');
    await p.waitForSelector('#bit-integridad [data-estado=integra]', { timeout: 20000 });
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.verificar_bitacora('${EM}'))`) === 0, 'la base dice que la cadena tiene problemas');
    // La anulación de la demo (con su motivo), entre los cambios de ventas (se piden más de 100 en 100 si hace falta).
    await p.selectOption('#bit-tipo', 'ventas');
    await p.waitForFunction(() => [...document.querySelectorAll('#lista-bitacora [data-tipo]')].every((x) => x.dataset.tipo === 'ventas'), null, { timeout: 15000 });
    const buscada = /anuló una venta #\d+ · motivo: El cliente se arrepintió/;
    for (let i = 0; i < 20 && !buscada.test(await texto(p, '#lista-bitacora')) && await p.locator('#bit-mas').count(); i++) {
      const n = await p.locator('#lista-bitacora [data-secuencia]').count();
      await p.click('#bit-mas');
      await p.waitForFunction((k) => document.querySelectorAll('#lista-bitacora [data-secuencia]').length > k, n, { timeout: 15000 });
    }
    afirmar(buscada.test(await texto(p, '#lista-bitacora')), 'no sale la anulación con su motivo');
    await p.selectOption('#bit-tipo', '');
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
    const costo = num('dueno@demo.hn', `(SELECT coalesce(sum(v), 0) FROM (SELECT sum(valor_centavos) AS v FROM public.v_existencia WHERE empresa_id = '${EM}' GROUP BY producto_id HAVING sum(cantidad) > 0) x)`);
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
      // 0.8.1: la bitácora con más páginas lo dice en lo impreso.
      if (ruta === 'reportes/bitacora' && await p.locator('#bit-mas').count()) afirmar(/Solo las primeras \d+ filas; hay más/.test(r.t), 'lo impreso de la bitácora no avisa que hay más');
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
    // 0.9.0: con el núcleo 0.16.0 el servidor limita v_comision_vendedor a sus sucursales: se pide y se muestra.
    const pedidas = [];
    p.on('request', (q) => pedidas.push(q.url()));
    await ir(p, 'reportes/empleados', '[data-info=deuda-sucursal]');
    afirmar(pedidas.some((u) => u.includes('v_comision_vendedor')) && (await texto(p, '#contenido')).includes('Se le debe hoy'), 'con núcleo 0.16.0 el limitado no ve lo suyo');
    // Núcleo 0.15.0 (simulado): v_comision_vendedor era de toda la empresa: no se pide ni se muestra (como 0.8.1).
    await p.route(/\/rest\/v1\/version_esquema\?/, (rr) => rr.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ version_nucleo: '0.15.0' }]) }));
    await p.evaluate(async () => (await import('/js/datos.js')).olvidarDatos());
    pedidas.length = 0;
    await ir(p, 'reportes/empleados', '[data-info=deuda-limitado]');
    afirmar(!pedidas.some((u) => u.includes('v_comision_vendedor')) && !(await texto(p, '#contenido')).includes('Se le debe hoy'), 'núcleo viejo: el limitado ve lo que se debe a los vendedores');
    await p.unroute(/\/rest\/v1\/version_esquema\?/);
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

  // ============================ Parte 3: comas pendientes ============================
  await prueba('comas: porcentaje de impuestos, topes, mínimo del producto, conteo y traslados rechazan "2,5" (coma solo de miles)', async () => {
    const p = d.p;
    const r = await p.evaluate(async () => {
      const f = await import('/js/formato.js');
      return { n: ['2.5', '0', '1,500', '2,5', '-1', '', 'abc', '1,234.5678', '1.23456', 'l5', 'L5', ' 7 '].map((x) => f.aNumero(x)),
        pct: ['15', '12.5', '12,5', '150', '100', '0', '18 %', '-3'].map((x) => f.aPorcentaje(x)) };
    });
    afirmar(JSON.stringify(r.n) === JSON.stringify([2.5, 0, 1500, null, null, null, null, 1234.5678, null, null, null, 7]), 'aNumero: ' + JSON.stringify(r.n));
    afirmar(JSON.stringify(r.pct) === JSON.stringify([15, 12.5, null, null, 100, 0, 18, null]), 'aPorcentaje: ' + JSON.stringify(r.pct));
    const coma = async (que) => {
      await p.waitForSelector('#contenido .mensaje-error', { timeout: 10000 });
      afirmar((await texto(p, '#contenido .mensaje-error')).includes('Use punto para los decimales'), `${que}: no explica la coma`);
      afirmar(await p.locator('dialog.dialogo[open]').count() === 0, `${que}: siguió adelante con la coma`);
    };
    // Impuestos
    const nImp = num('dueno@demo.hn', `(SELECT count(*) FROM public.impuesto WHERE empresa_id = '${EM}')`);
    await ir(p, 'ajustes/impuestos', '#tabla-impuestos');
    await p.getByRole('button', { name: 'Nuevo impuesto' }).click();
    await p.fill('#imp-codigo', 'PRUEBA'); await p.fill('#imp-nombre', 'Prueba de coma'); await p.fill('#imp-pct', '12,5');
    await p.waitForSelector('#imp-pct + .aviso-coma');
    await p.getByRole('button', { name: 'Siguiente' }).click();
    await coma('impuestos');
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.impuesto WHERE empresa_id = '${EM}')`) === nImp, 'guardó un impuesto');
    // Topes de descuento (Reglas)
    await ir(p, 'ajustes/reglas', '#topes-guardar');
    await p.locator('[data-tope]').first().fill('5,5');
    await p.click('#topes-guardar');
    await coma('topes');
    // Mínimo del producto
    const nProd = num('dueno@demo.hn', `(SELECT count(*) FROM public.producto WHERE empresa_id = '${EM}')`);
    await ir(p, 'inventario/productos', '#nuevo-producto');
    await p.click('#nuevo-producto');
    await p.waitForSelector('#prod-minimo');
    await p.fill('#prod-codigo', 'COMA-1'); await p.fill('#prod-nombre', 'Producto de prueba'); await p.fill('#prod-precio', '10'); await p.fill('#prod-minimo', '2,5');
    await p.getByRole('button', { name: 'Crear producto' }).click();
    await coma('mínimo del producto');
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.producto WHERE empresa_id = '${EM}')`) === nProd, 'guardó el producto');
    // Traslados de inventario
    const nDoc = num('dueno@demo.hn', `(SELECT count(*) FROM public.inventario_documento WHERE empresa_id = '${EM}')`);
    await ir(p, 'inventario/traslados', '#tras-buscar');
    await p.fill('#tras-buscar', 'varilla');
    await p.locator('#tras-buscar').locator('xpath=ancestor::form').locator('button', { hasText: 'Varilla' }).first().click();
    await p.locator('#tras-lineas input').first().fill('2,5');
    await p.locator('#tras-buscar').locator('xpath=ancestor::form').locator('button[type=submit]').click();
    await coma('traslados');
    afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.inventario_documento WHERE empresa_id = '${EM}')`) === nDoc, 'guardó el traslado');
  });

  // ============================ 0.8.1: arreglos de la revisión ============================
  await prueba('0.8.1: empleado sin ventas visibles sale con "—" si tiene diferencias; tope de 1,000 turnos avisado (pantalla y Excel)', async () => {
    const { ctx, p } = await nueva();
    await p.route('**/rest/v1/rpc/vigilancia_empleados', (rr) => rr.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
      desde: desdeMes, hasta: HOY, costos_ocultos: true, empleados: [{ usuario_id: 'u1', nombre: 'Cajera Prueba', rol: 'cajero', activo: true, ventas: null, descuentos: null,
        ganancia_centavos: null, anulaciones_pedidas: { cantidad: 0, aprobadas: 0, monto_centavos: null },
        diferencias_caja: { turnos: 2, turnos_con_diferencia: 1, faltante_centavos: -1000, sobrante_centavos: 0, neto_centavos: -1000 }, horario_uso: [] }] }) }));
    const turno = (i) => ({ turno_id: 't' + i, numero: i, estado: 'cerrado', caja: 'Caja', cajero: 'Ana', fecha_cierre: HOY, cerrado_en: null, diferencia_centavos: -100, diferencia_estado: 'pendiente' });
    await p.route(/\/rest\/v1\/v_turno_caja\?/, (rr) => rr.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(Array.from({ length: 1000 }, (_, i) => turno(i + 1))) }));
    await entrar(p, 'dueno@demo.hn');
    await ir(p, 'reportes/empleados', '[data-info=tope-turnos]');
    const fila = await texto(p, '#tabla-empleados [data-empleado=u1]');
    afirmar(fila.includes('Cajera Prueba') && fila.includes('—') && fila.includes('-L 10.00'), 'fila sin ventas: ' + fila);
    const [desc] = await Promise.all([p.waitForEvent('download'), p.click('#empleados-excel')]);
    const x = await leerExcel(p, desc);
    afirmar(JSON.stringify(x.celdas['Turnos de caja']).includes('Solo los primeros 1000 turnos'), 'el Excel no avisa el tope de turnos');
    await ctx.close();
  });

  await prueba('0.8.1: pre-cierre nombra el mes abierto MÁS VIEJO con movimientos (el intermedio vacío no cuenta)', async () => {
    const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
    const atras = (n) => { let a = A, m = M - n; while (m < 1) { m += 12; a -= 1; } return { a, m, v: `${a}-${String(m).padStart(2, '0')}`, d: `${a}-${String(m).padStart(2, '0')}-01` }; };
    const viejo = atras(3), vacio = atras(2), revisar = atras(1);
    const { ctx, p } = await nueva();
    // Respuestas simuladas: la empresa empezó hace 3 meses, ningún mes cerrado, solo el más viejo tiene asientos.
    await p.route('**/rest/v1/rpc/mi_perfil', async (rr) => {
      const res = await rr.fetch(); const j = await res.json();
      if (j && j.empresa) j.empresa.fecha_inicio = viejo.d;
      await rr.fulfill({ response: res, body: JSON.stringify(j) });
    });
    await p.route(/\/rest\/v1\/periodo\?/, (rr) => rr.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
    await p.route(/\/rest\/v1\/v_distribucion\?/, (rr) => rr.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
    await p.route('**/rest/v1/rpc/historial_cierres', (rr) => rr.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
    const pedidos = [];
    await p.route(/\/rest\/v1\/v_asiento\?/, (rr) => {
      const u = decodeURIComponent(rr.request().url());
      pedidos.push(u);
      rr.fulfill({ status: 200, contentType: 'application/json', body: u.includes(`gte.${viejo.d}`) ? '[{"id":"x"}]' : '[]' });
    });
    await entrar(p, 'dueno@demo.hn');
    await ir(p, 'reportes/cierre', `#cierre-meses [data-mes="${revisar.v}"]`);
    await p.click(`#cierre-meses [data-mes="${revisar.v}"] button`);
    await p.waitForSelector(`#cierre-detalle section[data-mes="${revisar.v}"] [data-revision=anterior]`);
    afirmar(await p.getAttribute('[data-revision=anterior]', 'data-listo') === 'false', 'no ve el mes viejo abierto');
    const t = await texto(p, '[data-revision=anterior]');
    afirmar(t.includes(`Falta: cerrar ${MESES[viejo.m - 1]} de ${viejo.a} primero`) && !t.includes(MESES[vacio.m - 1]), 'no nombra el mes más viejo: ' + t);
    afirmar(pedidos.some((u) => u.includes(`gte.${vacio.d}`)), 'no revisó el mes intermedio');
    afirmar(await p.locator('#cierre-cerrar[disabled]').count() === 1, 'deja cerrar con un mes viejo abierto');
    await ctx.close();
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
    afirmar((await texto(p, '[data-dato=resumen-neta]')) === lempiras(r.utilidad_neta_centavos), 'resumen del cierre distinto a la foto');
    const err = errorSql('dueno@demo.hn', `public.reabrir_periodo('${EM}', ${AA}, ${MA}, 'Probar el rechazo')`);
    afirmar(err && err.includes('MES_CON_REPARTO'), 'el núcleo no rechazó reabrir con reparto: ' + err);
    // Libros de ISV del mes, iguales al núcleo.
    await p.click('#cierre-ver-libros');
    await p.waitForSelector('#libro-ventas');
    const li = JSON.parse(sql('dueno@demo.hn', `public.libros_isv('${EM}', ${AA}, ${MA})`));
    afirmar((await texto(p, '[data-dato=libro-isv-ventas]')) === lempiras(li.libro_ventas.totales.isv_centavos), 'ISV de ventas del libro');
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
    // app 0.10.0: el dueño anula el reparto en Dinero > Fondos y socios para poder reabrir (antes: por SQL).
    const dist = sql('dueno@demo.hn', `(SELECT id FROM public.distribucion WHERE empresa_id = '${EM}' AND anio = ${AA} AND mes = ${MA} AND anulada_en IS NULL)`);
    await ir(p, 'reportes/cierre', `#cierre-meses [data-mes="${mesPasado}"]`);
    await p.click(`#cierre-meses [data-mes="${mesPasado}"] button`);
    await p.waitForSelector('#cierre-ir-anular-reparto');
    afirmar((await texto(p, '[data-info=reabrir-con-reparto]')).includes('anule el reparto'), 'no explica cómo reabrir con reparto');
    await p.click('#cierre-ir-anular-reparto');
    await p.waitForSelector(`[data-reparto="${dist}"] [data-accion=anular-reparto]`, { timeout: 20000 });
    const pagos = num('dueno@demo.hn', `(SELECT count(*) FROM public.dividendo_pago WHERE empresa_id = '${EM}' AND anulada_en IS NULL)`);
    if (pagos) {
      // Con un pago a un socio (la prueba de Dinero le pagó a Carlos): no se anula y lo explica; primero se anula el pago.
      await p.click(`[data-reparto="${dist}"] [data-accion=anular-reparto]`);
      await p.waitForSelector('dialog.dialogo[open] textarea');
      await p.fill('dialog.dialogo[open] textarea', 'Prueba: reabrir el mes');
      await p.click('dialog.dialogo[open] button[type=submit]');
      await p.waitForSelector('dialog.dialogo[open] .mensaje-error', { timeout: 15000 });
      afirmar((await texto(p, 'dialog.dialogo[open] .mensaje-error')).includes('Anule primero los pagos'), 'no explica que primero se anulan los pagos');
      await p.click('dialog.dialogo[open] button[type=button]');
      await p.waitForSelector('dialog.dialogo', { state: 'detached' });
      for (let i = 0; i < pagos; i++) {
        await p.click('#lista-pagos-socios [data-accion=anular-pago-socio] >> nth=0');
        await p.waitForSelector('dialog.dialogo[open] textarea');
        await p.fill('dialog.dialogo[open] textarea', 'Prueba: reabrir el mes');
        await p.click('dialog.dialogo[open] button[type=submit]');
        await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
        await p.waitForSelector('#lista-repartos', { timeout: 15000 });
      }
      afirmar(num('dueno@demo.hn', `(SELECT count(*) FROM public.dividendo_pago WHERE empresa_id = '${EM}' AND anulada_en IS NULL)`) === 0, 'quedaron pagos vigentes');
    }
    const fondosAntes = num('dueno@demo.hn', `(SELECT coalesce(sum(monto_centavos), 0) FROM public.fondo_movimiento WHERE empresa_id = '${EM}')`);
    await p.click(`[data-reparto="${dist}"] [data-accion=anular-reparto]`);
    await p.waitForSelector('dialog.dialogo[open] textarea');
    await p.click('dialog.dialogo[open] button[type=submit]'); // sin motivo: no deja
    afirmar((await texto(p, 'dialog.dialogo[open]')).includes('al menos 5 letras'), 'anular reparto sin motivo');
    await p.fill('dialog.dialogo[open] textarea', 'Prueba: reabrir el mes');
    await p.click('dialog.dialogo[open] button[type=submit]');
    await p.waitForSelector(`[data-reparto="${dist}"] [data-estado=anulado]`, { timeout: 20000 });
    afirmar(sql(null, `(SELECT motivo_anulacion FROM public.distribucion WHERE id = '${dist}')`) === 'Prueba: reabrir el mes', 'la base no quedó anulada');
    // Los fondos vuelven a como estaban antes del reparto (sus aportes se restan) y nada se borra.
    const recibido = num('dueno@demo.hn', `(SELECT coalesce(sum(monto_centavos), 0) FROM public.distribucion_detalle WHERE distribucion_id = '${dist}' AND fondo_id IS NOT NULL)`);
    afirmar(num('dueno@demo.hn', `(SELECT coalesce(sum(monto_centavos), 0) FROM public.fondo_movimiento WHERE empresa_id = '${EM}')`) === fondosAntes - recibido, 'los fondos no volvieron');
    await ir(p, 'reportes/cierre', `#cierre-meses [data-mes="${mesPasado}"]`);
    afirmar(await p.locator(`#cierre-meses [data-mes="${mesPasado}"] [data-reparto=no]`).count() === 1, 'el mes sigue "Con reparto"');
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
    afirmar((await texto(p, '[data-dato=resumen-neta]')) === lempiras(er.utilidad_neta_centavos), 'resumen del mes');
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
