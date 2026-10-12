// PRUEBA: la app en el navegador (Chromium con Playwright) contra la base de demo.
// La corre herramientas/probar_app.sh (que levanta la base y el servidor).
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
async function prueba(nombre, fn) {
  total++;
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++; console.log(`  FALLA  ${nombre}\n           ${String(e.message).split('\n')[0]}`); }
}
function afirmar(cond, que) { if (!cond) throw new Error(que); }

// Consulta directa a la base (como el usuario indicado) para comparar con lo que muestra la app.
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
const textoDe = (pagina, sel) => pagina.locator(sel).first().innerText();

(async () => {
  const nav = await chromium.launch();
  const EMPRESA = sql('dueno@demo.hn', "demo.id('EMPRESA')");
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, ...opciones });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };

  console.log('Pruebas de la app:');

  await prueba('clave equivocada: mensaje claro y no entra', async () => {
    const { ctx, p } = await nueva();
    await p.goto(URL_APP + '/');
    await p.fill('#correo', 'dueno@demo.hn');
    await p.fill('#clave', 'otra-clave');
    await p.click('button[type=submit]');
    await p.waitForSelector('.mensaje-error');
    afirmar((await textoDe(p, '.mensaje-error')).includes('Correo o contraseña incorrectos'), 'no salió el mensaje de clave incorrecta');
    afirmar(await p.locator('.saludo').count() === 0, 'entró con clave equivocada');
    await ctx.close();
  });

  const dueno = await nueva();
  await prueba('dueño: Inicio con las cifras correctas (comparadas con la base)', async () => {
    const p = dueno.p;
    await entrar(p, 'dueno@demo.hn');
    await p.waitForSelector('[data-dato=ventas_hoy]');
    const r = JSON.parse(sql('dueno@demo.hn', `public.resumen_hoy('${EMPRESA}')`));
    const d = JSON.parse(sql('dueno@demo.hn', `public.donde_esta_mi_dinero('${EMPRESA}')`));
    const esperado = {
      ventas_hoy: r.ventas_hoy.total_centavos, ganancia_hoy: r.ganancia_hoy.ganancia_bruta_centavos,
      ganancia_mes: r.ganancia_mes.ganancia_centavos, dinero: r.dinero.disponible_centavos,
      te_deben: r.te_deben.total_centavos, debes: r.debes.total_centavos,
    };
    afirmar(r.ventas_hoy.total_centavos > 0, 'la demo no tiene ventas de hoy');
    for (const [dato, c] of Object.entries(esperado)) {
      const visto = (await textoDe(p, `[data-dato=${dato}] .cifra-valor`)).trim();
      afirmar(visto === lempiras(c), `${dato}: se ve "${visto}", la base dice "${lempiras(c)}"`);
    }
    const vencido = await textoDe(p, '[data-dato=te_deben] .cifra-nota');
    afirmar(vencido.includes(lempiras(r.te_deben.vencido_centavos)) && vencido.includes('vencido'), 'no muestra lo vencido aparte');
    afirmar((await textoDe(p, '[data-dato=total_dinero]')).trim() === lempiras(d.total_centavos), 'total de ¿dónde está mi dinero? distinto');
    afirmar((await textoDe(p, '[data-dato=frase]')).trim() === r.frase, 'la frase del día no coincide');
    // Ejemplo a mano: L 5,095.00 = 509500 centavos
    afirmar(lempiras(509500) === 'L 5,095.00' && lempiras(-85917) === '-L 859.17', 'formato de lempiras');
    const pestanas = await p.locator('.pestanas .pestana').allInnerTexts();
    afirmar(pestanas[pestanas.length - 1] === 'Ajustes', 'Ajustes no es la última pestaña: ' + pestanas.join(', '));
    afirmar(['Dinero', 'Compras', 'Reportes'].every((t) => pestanas.includes(t)), 'al dueño le faltan pestañas');
    afirmar(!(await p.locator('body').innerText()).match(/\b[A-Z]{3,}_[A-Z_]+\b/), 'se ve un código de error crudo');
    await p.screenshot({ path: path.join(CAPTURAS, 'duenio_computadora.png'), fullPage: true });
  });

  await prueba('aprobar una solicitud (con motivo; sin motivo no deja)', async () => {
    const p = dueno.p;
    const antes = await p.locator('.columna-angosta .solicitud').count();
    afirmar(antes >= 1, 'no hay solicitudes pendientes en Inicio');
    const id = await p.locator('.columna-angosta .solicitud').first().getAttribute('data-aprobacion');
    await p.locator('.columna-angosta .solicitud').first().getByRole('button', { name: 'Aprobar' }).click();
    await p.waitForSelector('dialog.dialogo[open]');
    await p.fill('dialog.dialogo textarea', 'ok');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('dialog.dialogo .mensaje-error');
    await p.fill('dialog.dialogo textarea', 'Reparación urgente, ya revisé la cotización');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('dialog.dialogo', { state: 'detached' });
    await p.waitForSelector('#avisos .mensaje-ok');
    afirmar((await textoDe(p, '#avisos .mensaje-ok')).includes('aprobada'), 'no avisó que se aprobó');
    const estado = sql('dueno@demo.hn', `(SELECT estado FROM public.aprobacion WHERE id = '${id}')`);
    afirmar(estado === 'aprobada', 'en la base quedó: ' + estado);
    await p.waitForFunction((n) => document.querySelectorAll('.columna-angosta .solicitud').length === n - 1, antes);
    // Error del servidor traducido: otra persona ya resolvió la solicitud mientras estaba en pantalla.
    const otra = p.locator('.columna-angosta .solicitud').first();
    const id2 = await otra.getAttribute('data-aprobacion');
    sqlEscribir('dueno@demo.hn', `SELECT public.resolver_aprobacion('${id2}', false, 'Rechazada desde otro equipo', gen_random_uuid())`);
    await otra.getByRole('button', { name: 'Aprobar' }).click();
    await p.fill('dialog.dialogo textarea', 'Aprobada desde la prueba');
    await p.click('dialog.dialogo button[type=submit]');
    await p.waitForSelector('dialog.dialogo .mensaje-error');
    const msj = await textoDe(p, 'dialog.dialogo .mensaje-error');
    afirmar(msj.length > 10 && !/\b[A-Z]{2,}_[A-Z_]+\b/.test(msj), 'error del servidor sin traducir: ' + msj);
    await p.click('dialog.dialogo >> text=Cancelar');
    console.log('           (mensaje mostrado: ' + msj.replace(/\n/g, ' / ') + ')');
  });

  await prueba('sin conexión: se ve el aviso', async () => {
    await dueno.ctx.setOffline(true);
    await dueno.p.waitForSelector('#sin-conexion:not([hidden])', { timeout: 5000 });
    await dueno.ctx.setOffline(false);
    await dueno.p.waitForSelector('#sin-conexion[hidden]', { state: 'attached', timeout: 5000 });
  });
  await dueno.ctx.close();

  const vend = await nueva();
  await prueba('vendedor: no ve costos, ganancia ni pestañas de administración', async () => {
    const p = vend.p;
    await entrar(p, 'vendedor@demo.hn');
    await p.waitForSelector('.alerta, .vacio');
    const pestanas = await p.locator('.pestanas .pestana').allInnerTexts();
    for (const prohibida of ['Dinero', 'Compras', 'Reportes', 'Caja']) afirmar(!pestanas.includes(prohibida), `ve la pestaña ${prohibida}`);
    afirmar(pestanas[pestanas.length - 1] === 'Ajustes', 'Ajustes no es la última');
    const texto = await p.locator('body').innerText();
    for (const palabra of ['Ganancia', 'gané', 'Costo', 'Dinero disponible', 'Te deben', 'Aprobaciones']) {
      afirmar(!texto.includes(palabra), `el vendedor ve "${palabra}"`);
    }
    afirmar(await p.locator('[data-dato]').count() === 0, 'el vendedor ve cifras del negocio');
    await p.goto(URL_APP + '/#/reportes/gane');
    await p.waitForURL(/#\/inicio\/hoy/);
    await p.goto(URL_APP + '/#/ajustes/usuarios');
    await p.waitForURL(/#\/ajustes\/mi-cuenta/);
    await p.goto(URL_APP + '/#/inicio/hoy');
    await p.waitForSelector('.saludo');
    await p.screenshot({ path: path.join(CAPTURAS, 'vendedor_computadora.png'), fullPage: true });
  });

  await prueba('sesión cerrada a distancia: saca al vendedor', async () => {
    const p = vend.p;
    const uid = sql(null, "(SELECT id FROM auth.users WHERE email = 'vendedor@demo.hn')");
    sqlEscribir('dueno@demo.hn', `SELECT public.cerrar_sesion_usuario('${EMPRESA}', '${uid}', 'Prueba: cerrar a distancia')`);
    await p.waitForSelector('#correo', { timeout: 15000 });
    afirmar((await textoDe(p, '.entrar .mensaje')).includes('cerrada por el administrador'), 'no explicó por qué salió');
    // Puede volver a entrar (sesión nueva).
    await entrar(p, 'vendedor@demo.hn');
  });
  await vend.ctx.close();

  await prueba('celular: barra inferior con 4 botones y Ajustes dentro de "Más"', async () => {
    const { ctx, p } = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(p, 'dueno@demo.hn');
    await p.waitForSelector('[data-dato=ventas_hoy]');
    afirmar(await p.locator('.barra-inferior').isVisible(), 'no se ve la barra inferior');
    afirmar(!(await p.locator('.pestanas').isVisible()), 'se ven las pestañas de computadora');
    const botones = (await p.locator('.barra-inferior .boton-barra').allInnerTexts()).map((t) => t.trim());
    afirmar(botones.join(',') === 'Resumen,Vender,Buscar,Más', 'botones: ' + botones.join(','));
    const ancho = await p.evaluate(() => document.documentElement.scrollWidth);
    afirmar(ancho <= 390, 'la página se sale a lo ancho: ' + ancho);
    const alturas = await p.locator('.barra-inferior .boton-barra').evaluateAll((els) => els.map((e) => e.getBoundingClientRect().height));
    afirmar(alturas.every((a) => a >= 44), 'botones de menos de 44 px');
    await p.screenshot({ path: path.join(CAPTURAS, 'celular.png') });
    await p.click('.barra-inferior >> text=Más');
    await p.waitForSelector('.mas-grupo');
    const grupos = await p.locator('.mas-grupo h2').allInnerTexts();
    afirmar(grupos[grupos.length - 1] === 'Ajustes', 'Ajustes no está al final de Más');
    await p.screenshot({ path: path.join(CAPTURAS, 'celular_mas.png'), fullPage: true });
    await ctx.close();
  });

  // ===================== Etapa 4, parte 2: Vender, Caja y Clientes =====================
  const EM = EMPRESA;
  const id = (clave) => sql(null, `demo.id('${clave}')`);
  const codigoCrudo = /\b[A-Z]{3,}_[A-Z_]+\b/;
  // Abre Nueva venta y agrega productos por código (como un lector USB: código + Enter).
  async function venderCon(p, codigos) {
    await p.goto(URL_APP + '/#/vender/ventas'); // otra ruta primero: la misma ruta no vuelve a pintar
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
  const calculado = (p) => p.waitForSelector('.vender:not([data-calculando])', { timeout: 10000 });
  const ultimaVenta = () => JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT v.venta_id, v.numero_documento, v.estado,
    v.total_centavos, v.impuesto_centavos, v.condicion, v.cliente_id FROM public.v_venta v WHERE v.empresa_id = '${EM}' ORDER BY v.numero DESC LIMIT 1) x)`));
  const contarVentas = () => Number(sql('dueno@demo.hn', `(SELECT count(*) FROM public.v_venta WHERE empresa_id = '${EM}')`));

  const caj = await nueva();
  await entrar(caj.p, 'cajero@demo.hn');

  await prueba('vender en efectivo: vuelto correcto, comprobante = base, doble clic no duplica', async () => {
    const p = caj.p;
    await venderCon(p, ['CEM-425']);
    await p.fill('.linea-carrito input[name=cantidad]', '2');
    await p.press('.linea-carrito input[name=cantidad]', 'Tab');
    await calculado(p);
    // A mano: 2 x L 275.00 (ISV incluido) = L 550.00; sin ISV round(55,000 / 1.15) = 47,826; ISV 7,174.
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 550.00', 'total: ' + await textoDe(p, '[data-dato=total]'));
    afirmar((await textoDe(p, '[data-dato="isv-ISV15"]')).trim() === 'L 71.74', 'ISV desglosado');
    await p.click('[data-forma=efectivo]');
    await p.fill('#recibido', '600');
    afirmar((await textoDe(p, '[data-dato=vuelto]')).trim() === 'L 50.00', 'vuelto antes de cobrar');
    const antes = contarVentas();
    await p.dblclick('#cobrar');
    await p.waitForSelector('.comprobante', { timeout: 15000 });
    await p.waitForTimeout(500);
    afirmar(contarVentas() === antes + 1, 'el doble clic hizo ' + (contarVentas() - antes) + ' ventas');
    const v = ultimaVenta();
    const pago = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT recibido_centavos, vuelto_centavos FROM public.v_venta_pago WHERE venta_id = '${v.venta_id}') x)`));
    afirmar(v.total_centavos === 55000 && v.impuesto_centavos === 7174 && pago.vuelto_centavos === 5000, 'base: ' + JSON.stringify([v, pago]));
    afirmar((await textoDe(p, '[data-dato=vuelto-final]')).trim() === lempiras(pago.vuelto_centavos), 'vuelto final');
    const comp = await textoDe(p, '.comprobante');
    afirmar(comp.includes(v.numero_documento) && comp.includes(lempiras(v.total_centavos)) && comp.includes(lempiras(v.impuesto_centavos)), 'comprobante: ' + comp);
    afirmar(!/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(comp), 'el comprobante tiene emojis');
    const wa = await p.getAttribute('[data-accion=whatsapp]', 'href');
    afirmar(wa.startsWith('https://wa.me/') && decodeURIComponent(wa).includes(v.numero_documento), 'enlace de WhatsApp: ' + wa);
    await p.emulateMedia({ media: 'print' });
    afirmar(!(await p.locator('.pestanas').isVisible()) && await p.locator('.comprobante').isVisible(), 'al imprimir solo sale el comprobante');
    await p.screenshot({ path: path.join(CAPTURAS, 'p2_comprobante_impreso.png') });
    await p.emulateMedia({ media: 'screen' });
    await p.screenshot({ path: path.join(CAPTURAS, 'p2_comprobante.png'), fullPage: true });
  });

  await prueba('promoción: sugiere la que más descuenta y se puede cambiar (nunca se suman)', async () => {
    const p = caj.p;
    await venderCon(p, ['PIN-BLA']);
    // Galón L 520.00: "L 60 menos" = 6,000; "10 %" = 5,200 -> sugiere la de L 60: L 460.00.
    afirmar(await p.isChecked(`.promos input[value="${id('PROMO60')}"]`), 'no sugirió la de L 60');
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 460.00', 'total con la sugerida');
    await p.screenshot({ path: path.join(CAPTURAS, 'p2_vender_computadora.png'), fullPage: true });
    await p.check(`.promos input[value="${id('PROMO10')}"]`);
    await calculado(p);
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 468.00', 'total con la cambiada: ' + await textoDe(p, '[data-dato=total]'));
    afirmar(await p.locator('.linea-carrito input[name=descuento]').count() === 0, 'una línea con promoción no admite otro descuento');
    await p.click('#cobrar');
    await p.waitForSelector('.comprobante', { timeout: 15000 });
    const v = ultimaVenta();
    const promo = sql('dueno@demo.hn', `(SELECT promocion_id FROM public.v_venta_linea WHERE venta_id = '${v.venta_id}')`);
    afirmar(promo === id('PROMO10') && v.total_centavos === 46800, 'la venta quedó con ' + promo + ' / ' + v.total_centavos);
  });

  await prueba('descuento sobre el tope: avisa y la venta queda pendiente de aprobación', async () => {
    const p = caj.p;
    await venderCon(p, ['CEM-425']);
    await p.fill('.linea-carrito input[name=descuento]', '10');
    await p.press('.linea-carrito input[name=descuento]', 'Tab');
    await calculado(p);
    await p.waitForSelector('.aviso-tope');
    afirmar((await textoDe(p, '.aviso-tope')).includes('5 %'), 'el aviso no dice el tope');
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 247.50', 'total con 10 % (27,500 - 2,750)');
    await p.click('#cobrar');
    await p.waitForSelector('[data-dato=pendiente]', { timeout: 15000 });
    const v = ultimaVenta();
    afirmar(v.estado === 'pendiente_aprobacion', 'estado: ' + v.estado);
    afirmar(!codigoCrudo.test(await p.locator('body').innerText()), 'se ve un código crudo');
  });

  await prueba('venta al crédito exige cliente', async () => {
    const p = caj.p;
    await venderCon(p, ['VAR-038']);
    await p.click('[data-forma=credito]');
    const antes = contarVentas();
    await p.click('#cobrar');
    await p.waitForSelector('.vender .mensaje-error');
    afirmar((await textoDe(p, '.vender .mensaje-error')).includes('elija el cliente'), 'no pidió el cliente');
    afirmar(contarVentas() === antes, 'guardó una venta al crédito sin cliente');
    await p.selectOption('#cliente', id('CLI1'));
    await p.click('#cobrar');
    await p.waitForSelector('.comprobante', { timeout: 15000 });
    const v = ultimaVenta();
    afirmar(v.condicion === 'credito' && v.cliente_id === id('CLI1') && v.estado === 'emitida', 'venta: ' + JSON.stringify(v));
  });

  await prueba('abrir turno, vender y cerrar con conteo a ciegas: diferencia correcta', async () => {
    const p = caj.p;
    const saldo = Number(sql('dueno@demo.hn', `(SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE cuenta_dinero_id = '${id('CAJA1')}')`));
    await p.goto(URL_APP + '/#/caja/turno');
    await p.waitForSelector('#fondo-total');
    await p.fill('#fondo-total', (saldo / 100).toFixed(2));
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#cerrar-turno', { timeout: 15000 });
    await venderCon(p, ['CEM-425']);
    afirmar((await textoDe(p, '[data-dato=turno]')).includes('Turno'), 'Vender no muestra el turno');
    await p.click('#cobrar');
    await p.waitForSelector('.comprobante', { timeout: 15000 });
    await p.goto(URL_APP + '/#/caja/turno');
    await p.waitForSelector('#cerrar-turno');
    afirmar(!(await p.locator('#contenido').innerText()).includes('Debía haber'), 'muestra lo esperado antes de contar');
    await p.click('#cerrar-turno');
    // Cuenta L 10.00 menos de lo que hay (fondo + 275.00), por billetes.
    let falta = saldo + 27500 - 1000;
    await p.check('input[name="cierre-modo"][value=billetes]');
    for (const d of [50000, 20000, 10000, 5000, 2000, 1000, 500, 200, 100, 50, 20, 10, 5]) {
      const n = Math.floor(falta / d);
      if (n > 0) { await p.fill(`input[name="den-${d}"]`, String(n)); falta -= n * d; }
    }
    afirmar(falta === 0, 'no se pudo contar en billetes');
    afirmar((await textoDe(p, '[data-dato=suma-conteo]')).trim() === lempiras(saldo + 26500), 'suma del conteo');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('[data-dato=diferencia]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=diferencia]')).trim() === '-L 10.00', 'diferencia: ' + await textoDe(p, '[data-dato=diferencia]'));
    afirmar((await textoDe(p, '[data-dato=esperado]')).trim() === lempiras(saldo + 27500), 'esperado');
    const t = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT esperado_centavos, contado_centavos, diferencia_centavos
      FROM public.v_turno_caja WHERE empresa_id = '${EM}' ORDER BY numero DESC LIMIT 1) x)`));
    afirmar(t.diferencia_centavos === -1000 && t.esperado_centavos === saldo + 27500, 'base: ' + JSON.stringify(t));
    await p.screenshot({ path: path.join(CAPTURAS, 'p2_caja_cierre.png'), fullPage: true });
  });
  await caj.ctx.close();

  const adm = await nueva();
  await entrar(adm.p, 'admin@demo.hn');

  await prueba('devolución parcial desde Ventas del día (nota de crédito)', async () => {
    const p = adm.p;
    const ventaId = sql('dueno@demo.hn', `(SELECT v.venta_id FROM public.v_venta v JOIN public.v_venta_linea l ON l.venta_id = v.venta_id
      WHERE v.empresa_id = '${EM}' AND v.estado = 'emitida' AND l.codigo = 'CEM-425' AND l.cantidad = 5 AND v.fecha_contable = public.hoy_local('${EM}') LIMIT 1)`);
    await p.goto(URL_APP + '/#/vender/ventas');
    await p.click(`[data-venta="${ventaId}"] >> text=Devolver`);
    await p.waitForSelector('#dev-motivo');
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '2');
    await p.fill('#dev-motivo', 'El cliente compró de más');
    await p.selectOption('#dev-destino', 'saldo_favor');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('[data-dato=total-devolucion]', { timeout: 15000 });
    // A mano: 2 de 5 sacos de L 275.00 = L 550.00.
    afirmar((await textoDe(p, '[data-dato=total-devolucion]')).trim() === 'L 550.00', 'total devuelto');
    const d = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT total_centavos, estado FROM public.v_devolucion WHERE venta_id = '${ventaId}') x)`));
    afirmar(d.total_centavos === 55000 && d.estado === 'aplicada', 'base: ' + JSON.stringify(d));
  });

  await prueba('depósito al banco con referencia', async () => {
    const p = adm.p;
    await p.goto(URL_APP + '/#/caja/depositos');
    await p.waitForSelector('#mov-monto');
    await p.selectOption('#mov-caja', id('FUERTE'));
    await p.selectOption('#mov-banco', id('BAC'));
    await p.fill('#mov-monto', '1,000');
    await p.fill('#mov-referencia', 'Boleta 5555');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#avisos .mensaje-ok');
    afirmar((await textoDe(p, '#avisos .mensaje-ok')).includes('L 1,000.00'), 'aviso del depósito');
    const n = sql('dueno@demo.hn', `(SELECT count(*) FROM public.v_deposito_transito WHERE referencia = 'Boleta 5555' AND monto_centavos = 100000
      AND origen_id = '${id('FUERTE')}' AND destino_id = '${id('BAC')}')`);
    afirmar(n === '1', 'el depósito no está en tránsito en la base');
  });

  await prueba('cobrar abono con excedente a saldo a favor (con confirmación)', async () => {
    const p = adm.p;
    const debe = Number(sql('dueno@demo.hn', `(SELECT saldo_centavos FROM public.v_cxc_cliente WHERE cliente_id = '${id('CLI2')}')`));
    await p.goto(URL_APP + '/#/clientes/me-deben');
    await p.click(`[data-cliente="${id('CLI2')}"] >> text=Cobrar`);
    await p.waitForSelector('#abono-monto');
    await p.fill('#abono-monto', ((debe + 7000) / 100).toFixed(2));
    await p.selectOption('#abono-forma', 'tarjeta');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('form.formulario .mensaje-error');
    afirmar((await textoDe(p, 'form.formulario .mensaje-error')).includes('más de lo que debe'), 'no pidió confirmar el excedente');
    await p.check('#abono-excedente');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('[data-dato=excedente]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=excedente]')).trim() === 'L 70.00', 'excedente');
    afirmar((await textoDe(p, '[data-dato=saldo-restante]')).trim() === 'L 0.00', 'saldo restante');
    const favor = sql('dueno@demo.hn', `(SELECT sum(saldo_centavos) FROM public.v_saldo_favor WHERE cliente_id = '${id('CLI2')}')`);
    afirmar(favor === '7000', 'saldo a favor en la base: ' + favor);
    await p.click('text=Ver la ficha');
    await p.waitForSelector('[data-dato=saldo-favor]');
    afirmar((await textoDe(p, '[data-dato=saldo-favor]')).trim() === 'L 70.00', 'ficha: saldo a favor');
    await p.click('.subpestana >> text=Quién me debe'); // la misma pestaña vuelve a empezar la pantalla
    await p.waitForSelector('[data-accion=whatsapp]');
    const wa = decodeURIComponent(await p.getAttribute(`[data-cliente="${id('CLI1')}"] [data-accion=whatsapp]`, 'href'));
    afirmar(wa.startsWith('https://wa.me/50499887766?text=') && wa.includes('saldo pendiente'), 'WhatsApp de cobro: ' + wa);
    await p.goto(URL_APP + '/#/clientes/lista');
    await p.click(`[data-cliente="${id('CLI1')}"] >> text=Ver`);
    await p.waitForSelector('[data-dato=saldo-cliente]');
    await p.screenshot({ path: path.join(CAPTURAS, 'p2_clientes.png'), fullPage: true });
  });

  await prueba('crear cliente: RTN validado', async () => {
    const p = adm.p;
    await p.click('.subpestana >> text=Clientes');
    await p.click('#nuevo-cliente');
    await p.fill('#cli-nombre', 'Ferretería La Prueba');
    await p.fill('#cli-rtn', '0801-1999');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('form.formulario .mensaje-error');
    afirmar((await textoDe(p, 'form.formulario .mensaje-error')).includes('14 números'), 'no validó el RTN');
    await p.fill('#cli-rtn', '0801-1999-012345');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#t-ficha');
    const rtn = sql('dueno@demo.hn', `(SELECT rtn FROM public.tercero WHERE nombre = 'Ferretería La Prueba')`);
    afirmar(rtn === '08011999012345', 'RTN guardado: ' + rtn);
  });
  await adm.ctx.close();

  await prueba('vendedor no cobra si "vendedor que cobra" está apagado', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'vendedor@demo.hn');
    await venderCon(p, ['VAR-038']);
    afirmar(await p.locator('[data-forma=efectivo]').count() === 0, 'el vendedor ve Efectivo');
    afirmar(await p.locator('[data-forma=credito]').count() === 1, 'el vendedor no ve Crédito');
    afirmar((await p.locator('.vender').innerText()).includes('lo hace el cajero'), 'no explica quién cobra');
    // Aunque intente por fuera de la pantalla, el servidor no deja (y el error sale traducido).
    const msj = await p.evaluate(async ([e, prod]) => {
      const api = await import('./js/api.js');
      const { traducir } = await import('./js/errores.js');
      try { await api.escribir('registrar_venta', { p_empresa_id: e, p_datos: { lineas: [{ producto_id: prod, cantidad: 1 }], pagos: [{ forma: 'efectivo' }] } }); return 'pasó'; }
      catch (err) { return (await traducir(err)).mensaje; }
    }, [EM, id('VAR')]);
    afirmar(msj !== 'pasó' && !codigoCrudo.test(msj), 'el servidor dejó cobrar o el error no se tradujo: ' + msj);
    // Con "vendedor que cobra" encendido sí ve Efectivo.
    sqlEscribir('dueno@demo.hn', `SELECT public.configurar_empresa('${EM}', '{"vendedor_cobra": true}', 'Prueba de la app')`);
    await p.click('.quien button');
    await p.waitForSelector('#correo');
    await entrar(p, 'vendedor@demo.hn');
    await venderCon(p, ['VAR-038']);
    afirmar(await p.locator('[data-forma=efectivo]').count() === 1, 'con vendedor_cobra no ve Efectivo');
    sqlEscribir('dueno@demo.hn', `SELECT public.configurar_empresa('${EM}', '{"vendedor_cobra": false}', 'Prueba de la app')`);
    await ctx.close();
  });

  await prueba('celular: Vender se puede usar sin salirse a lo ancho', async () => {
    const { ctx, p } = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(p, 'cajero@demo.hn');
    await venderCon(p, ['PIN-BLA', 'CLA-250']);
    await p.fill('.linea-carrito >> nth=1 >> input[name=cantidad]', '2.5');
    await p.press('.linea-carrito >> nth=1 >> input[name=cantidad]', 'Tab');
    await calculado(p);
    // A mano: pintura con la sugerida L 460.00 + 2.5 lb de clavos x L 40.00 = L 100.00 -> L 560.00.
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 560.00', 'total en celular: ' + await textoDe(p, '[data-dato=total]'));
    const ancho = await p.evaluate(() => document.documentElement.scrollWidth);
    afirmar(ancho <= 390, 'la página se sale a lo ancho: ' + ancho);
    const cobrar = await p.locator('#cobrar').boundingBox();
    afirmar(cobrar && cobrar.height >= 44 && cobrar.width >= 300, 'botón Cobrar chico');
    const letras = await p.locator('.vender').evaluate((el) => [...el.querySelectorAll('*')].filter((x) => x.childElementCount === 0 && x.tagName !== 'OPTION' && x.textContent.trim())
      .map((x) => parseFloat(getComputedStyle(x).fontSize)).filter((t) => t < 15));
    afirmar(letras.length === 0, 'letra menor de 15 px: ' + letras.join(','));
    await p.screenshot({ path: path.join(CAPTURAS, 'p2_vender_celular.png'), fullPage: true });
    await ctx.close();
  });

  // ===================== Etapa 4, parte 3a: Inventario, Ajustes y arreglos =====================
  const dialogoMotivo = async (p, motivo) => {
    await p.waitForSelector('dialog.dialogo[open] textarea');
    await p.fill('dialog.dialogo[open] textarea', motivo);
    await p.click('dialog.dialogo[open] button[type=submit]');
    await p.waitForSelector('dialog.dialogo', { state: 'detached', timeout: 15000 });
  };
  const sigueAbierto = (p) => p.locator('dialog.dialogo[open]').count();

  const caj3 = await nueva();
  await entrar(caj3.p, 'cajero@demo.hn');

  await prueba('descuento con ISV: Subtotal - Descuento = Total y "ISV incluido"', async () => {
    const p = caj3.p;
    await venderCon(p, ['PIN-BLA']);
    // A mano: galón L 520.00 con ISV, promoción L 60 -> 520.00 - 60.00 = 460.00; ISV incluido 460 - round(460/1.15) = 60.00.
    afirmar((await textoDe(p, '[data-dato=subtotal]')).trim() === 'L 520.00', 'subtotal: ' + await textoDe(p, '[data-dato=subtotal]'));
    afirmar((await textoDe(p, '[data-dato=descuento]')).trim() === '−L 60.00', 'descuento: ' + await textoDe(p, '[data-dato=descuento]'));
    afirmar((await textoDe(p, '[data-dato=total]')).trim() === 'L 460.00', 'total');
    afirmar((await textoDe(p, '[data-dato=isv-ISV15]')).trim() === 'L 60.00', 'ISV incluido');
    afirmar((await p.locator('.vender').innerText()).includes('incluido'), 'no dice "ISV incluido"');
  });

  await prueba('cajero cobra un abono (ve lo que debe por factura, sin costos)', async () => {
    const p = caj3.p;
    const debe = Number(sql('dueno@demo.hn', `(SELECT saldo_centavos FROM public.v_cxc_cliente WHERE cliente_id = '${id('CLI1')}')`));
    await p.goto(URL_APP + '/#/caja/cobros');
    await p.click(`[data-cliente="${id('CLI1')}"] >> text=Cobrar`);
    await p.waitForSelector('#abono-monto');
    await p.fill('#abono-monto', '100.00');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('[data-dato=saldo-restante]', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=aplicado]')).trim() === 'L 100.00', 'aplicado');
    afirmar((await textoDe(p, '[data-dato=saldo-restante]')).trim() === lempiras(debe - 10000), 'saldo restante');
    const quien = sql(null, `(SELECT u.email FROM public.cobro c JOIN auth.users u ON u.id = c.creado_por WHERE c.empresa_id = '${EM}' ORDER BY c.numero DESC LIMIT 1)`);
    afirmar(quien === 'cajero@demo.hn', 'el cobro no quedó a nombre del cajero: ' + quien);
    await p.click('text=Ver la ficha');
    await p.waitForSelector('#t-pend');
    const texto = await p.locator('body').innerText();
    for (const palabra of ['Costo', 'Ganancia', 'gané']) afirmar(!texto.includes(palabra), 'el cajero ve ' + palabra);
    await p.goto(URL_APP + '/#/inventario/movimientos');
    await p.waitForURL(/#\/inventario\/productos/);
  });

  await prueba('Caja: el aviso "Turno abierto" se limpia al cerrar el turno', async () => {
    const p = caj3.p;
    await p.goto(URL_APP + '/#/caja/turno');
    await p.waitForSelector('#fondo-total');
    const saldoCaja = Number(sql('dueno@demo.hn', `(SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE cuenta_dinero_id = '${id('CAJA1')}')`));
    await p.fill('#fondo-total', (saldoCaja / 100).toFixed(2));
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#cerrar-turno', { timeout: 15000 });
    afirmar((await p.locator('#avisos').innerText()).includes('abierto'), 'no avisó que abrió');
    await p.click('#cerrar-turno');
    await p.fill('#cierre-total', '100.00');
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('[data-dato=diferencia]', { timeout: 15000 });
    const avisos = await p.locator('#avisos').innerText();
    afirmar(!avisos.includes('abierto'), 'quedó el aviso viejo: ' + avisos);
  });
  await caj3.ctx.close();

  const adm3 = await nueva();
  await entrar(adm3.p, 'admin@demo.hn');

  await prueba('crear producto y cambiar precio con motivo (queda en el historial)', async () => {
    const p = adm3.p;
    await p.goto(URL_APP + '/#/inventario/productos');
    await p.click('#nuevo-producto');
    await p.fill('#prod-codigo', 'brocha-3');
    await p.fill('#prod-nombre', 'Brocha 3 pulgadas');
    await p.fill('#prod-precio', '85.00');
    await p.click('form.formulario button[type=submit]');
    await p.click('#confirmar-si');
    await p.waitForSelector('#t-pficha', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=precio]')).includes('L 85.00'), 'precio inicial');
    await p.click('#cambiar-precio');
    await p.fill('#precio-nuevo', '92.50');
    await p.click('form.formulario button[type=submit]');
    await dialogoMotivo(p, 'Subió el costo del proveedor');
    await p.waitForSelector('#historial-precios');
    afirmar((await textoDe(p, '#historial-precios')).includes('L 85.00 → L 92.50'), 'historial: ' + await textoDe(p, '#historial-precios'));
    const r = sql('dueno@demo.hn', `(SELECT p.precio_venta_centavos || '|' || pp.motivo FROM public.producto p JOIN public.producto_precio pp ON pp.producto_id = p.id
      WHERE p.codigo = 'BROCHA-3' AND pp.precio_anterior_centavos = 8500)`);
    afirmar(r === '9250|Subió el costo del proveedor', 'base: ' + r);
    await p.goto(URL_APP + '/#/inventario/existencias');
    await p.waitForSelector('#t-exist');
    await p.goto(URL_APP + '/#/inventario/productos');
    await p.waitForSelector('[data-producto]');
    await p.screenshot({ path: path.join(CAPTURAS, 'p3_inventario.png'), fullPage: true });
  });

  await prueba('admin no ve la tabla de permisos editable', async () => {
    const p = adm3.p;
    await p.goto(URL_APP + '/#/ajustes/usuarios');
    await p.waitForSelector('#lista-usuarios');
    afirmar(await p.locator('#tabla-permisos').count() === 0, 'el admin ve la tabla de permisos');
    // Solo agrega cajero y vendedor.
    await p.click('#agregar-usuario');
    const puestos = await p.locator('#nuevo-rol option').allInnerTexts();
    afirmar(puestos.join(',') === 'Cajero,Vendedor', 'puestos del admin: ' + puestos);
  });

  const due3 = await nueva();
  await entrar(due3.p, 'dueno@demo.hn');

  await prueba('conteo físico crea un ajuste pendiente y el admin lo aprueba', async () => {
    const p = due3.p;
    const hay = Number(sql('dueno@demo.hn', `(SELECT cantidad FROM public.v_existencia WHERE producto_id = '${id('PVC')}' AND bodega_id = '${id('B1')}')`));
    await p.goto(URL_APP + '/#/inventario/conteo');
    await p.waitForSelector('#conteo-lista');
    afirmar(!(await p.locator('#contenido').innerText()).includes(String(hay) + ' '), '¿muestra la existencia? (debe ser a ciegas)');
    await p.selectOption('#conteo-bodega', 'B1');
    await p.fill('#conteo-buscar', 'PVC-012');
    await p.fill('input[data-codigo="PVC-012"]', String(hay - 2));
    await p.click('#conteo-guardar');
    await dialogoMotivo(p, 'Conteo de fin de mes');
    await p.waitForSelector('[data-dato=conteo-enviado]');
    afirmar(Number(sql('dueno@demo.hn', `(SELECT cantidad FROM public.v_existencia WHERE producto_id = '${id('PVC')}' AND bodega_id = '${id('B1')}')`)) === hay, 'cambió la existencia antes de aprobar');
    const apr = sql('dueno@demo.hn', `(SELECT id FROM public.aprobacion WHERE empresa_id = '${EM}' AND tipo = 'conteo_fisico' AND estado = 'pendiente' ORDER BY numero DESC LIMIT 1)`);
    afirmar(apr, 'no quedó la solicitud de aprobación');
    const a = adm3.p;
    await a.goto(URL_APP + '/#/inicio/hoy');
    await a.goto(URL_APP + '/#/inicio/aprobaciones');
    await a.locator(`[data-aprobacion="${apr}"]`).getByRole('button', { name: 'Aprobar' }).click();
    await dialogoMotivo(a, 'Revisado en bodega');
    const despues = Number(sql('dueno@demo.hn', `(SELECT cantidad FROM public.v_existencia WHERE producto_id = '${id('PVC')}' AND bodega_id = '${id('B1')}')`));
    afirmar(despues === hay - 2, `existencia ${hay} -> ${despues} (debía ${hay - 2})`);
  });

  await prueba('Excel: descargar, subir con un error (Guardar deshabilitado), corregir y guardar', async () => {
    const p = due3.p;
    await p.goto(URL_APP + '/#/inventario/excel');
    await p.waitForSelector('#excel-descargar');
    const [descarga] = await Promise.all([p.waitForEvent('download'), p.click('#excel-descargar')]);
    const archivo = path.join(CAPTURAS, 'productos_prueba.xlsx');
    await descarga.saveAs(archivo);
    const fs = require('node:fs');
    // Cambia el precio de la varilla en el archivo (con SheetJS de la misma página).
    const cambiar = (precio) => p.evaluate(([b64, precio]) => {
      const X = window.XLSX;
      const wb = X.read(b64, { type: 'base64' });
      const ws = wb.Sheets[wb.SheetNames[0]];
      const filas = X.utils.sheet_to_json(ws, { header: 1 });
      const col = filas[0].findIndex((t) => String(t).startsWith('Precio de venta'));
      const fila = filas.findIndex((f) => f[0] === 'VAR-038');
      ws[X.utils.encode_cell({ r: fila, c: col })] = { t: 'n', v: precio };
      return X.write(wb, { type: 'base64', bookType: 'xlsx' });
    }, [fs.readFileSync(archivo).toString('base64'), precio]);
    const malo = path.join(CAPTURAS, 'productos_error.xlsx');
    fs.writeFileSync(malo, Buffer.from(await cambiar(189.999), 'base64'));
    await p.setInputFiles('#excel-archivo', malo);
    await p.waitForSelector('#excel-resumen', { timeout: 15000 });
    afirmar((await textoDe(p, '[data-dato=errores]')).startsWith('1 error'), 'resumen: ' + await textoDe(p, '#excel-resumen'));
    afirmar(await p.isDisabled('#excel-guardar'), 'Guardar habilitado con errores');
    afirmar((await textoDe(p, 'tr.fila-error')).includes('decimales'), 'no dice el error de la fila');
    await p.screenshot({ path: path.join(CAPTURAS, 'p3_excel_vista_previa.png'), fullPage: true });
    const bueno = path.join(CAPTURAS, 'productos_bien.xlsx');
    fs.writeFileSync(bueno, Buffer.from(await cambiar(189.5), 'base64'));
    await p.setInputFiles('#excel-archivo', bueno);
    await p.waitForFunction(() => !document.querySelector('#excel-guardar').disabled, null, { timeout: 15000 });
    await p.click('#excel-guardar');
    await dialogoMotivo(p, 'Lista de precios nueva');
    await p.waitForSelector('[data-dato=excel-guardado]');
    const precio = sql('dueno@demo.hn', `(SELECT precio_venta_centavos FROM public.producto WHERE id = '${id('VAR')}')`);
    afirmar(precio === '18950', 'precio en la base: ' + precio);
  });

  await prueba('Ajustes: el dueño agrega un vendedor dentro del límite; al pasarse ve el límite y "Solicitar ampliación"', async () => {
    const p = due3.p;
    await p.goto(URL_APP + '/#/ajustes/usuarios');
    await p.waitForSelector('[data-dato=uso-usuarios]');
    afirmar((await textoDe(p, '[data-dato=uso-usuarios]')).includes('4 de 5'), 'uso: ' + await textoDe(p, '[data-dato=uso-usuarios]'));
    const alta = async (correo, nombre) => {
      await p.click('#agregar-usuario');
      await p.fill('#nuevo-correo', correo); await p.fill('#nuevo-nombre', nombre);
      await p.selectOption('#nuevo-rol', 'vendedor'); await p.fill('#nuevo-clave', 'temporal123');
      await p.click('form.formulario button[type=submit]');
    };
    await alta('vendedor2@demo.hn', 'Rosa Díaz');
    await p.waitForSelector('[data-dato=uso-usuarios]', { timeout: 15000 });
    await p.waitForFunction(() => document.querySelector('[data-dato=uso-usuarios]').textContent.includes('5 de 5'));
    await p.screenshot({ path: path.join(CAPTURAS, 'p3_ajustes_usuarios.png'), fullPage: false });
    await alta('vendedor3@demo.hn', 'Luis Paz');
    await p.waitForSelector('#agregar-error .mensaje-error', { timeout: 15000 });
    const msj = await textoDe(p, '#agregar-error .mensaje-error');
    afirmar(/máximo|plan|ampliaci/i.test(msj) && !codigoCrudo.test(msj), 'mensaje del límite: ' + msj);
    afirmar(await p.locator('#solicitar-desde-error').count() === 1, 'no ofrece "Solicitar ampliación"');
    afirmar(sql(null, "(SELECT count(*) FROM auth.users WHERE email = 'vendedor3@demo.hn')") === '0', 'quedó un usuario a medias');
    await p.click('#solicitar-desde-error');
    await p.click('#ampliacion-enviar');
    await p.waitForSelector('dialog.dialogo', { state: 'detached' });
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM public.solicitud_proveedor WHERE empresa_id = '${EM}' AND tipo = 'ampliacion')`) === '1', 'no llegó la solicitud');
    // La vendedora nueva entra.
    const { ctx, p: p2 } = await nueva();
    await entrar(p2, 'vendedor2@demo.hn');
    await ctx.close();
  });

  await prueba('cambiar el color del tema y volver al anterior', async () => {
    const p = due3.p;
    const color = () => p.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--color-principal').trim().toLowerCase());
    const antes = await color();
    await p.goto(URL_APP + '/#/ajustes/negocio');
    await p.waitForSelector('#marca-principal');
    await p.fill('#marca-principal', '#2b4a1e');
    await p.fill('#marca-nombre-com', 'El Roble Ferretería');
    await p.click('#marca-guardar');
    await dialogoMotivo(p, 'Colores de la marca nueva');
    await p.waitForSelector('#marca-volver');
    afirmar(await color() === '#2b4a1e', 'no cambió el color: ' + await color());
    afirmar((await textoDe(p, '#marca-nombre')).trim() === 'El Roble Ferretería', 'no cambió el nombre del encabezado');
    await p.click('#marca-volver');
    await dialogoMotivo(p, 'Mejor como estaba');
    await p.waitForFunction((a) => getComputedStyle(document.documentElement).getPropertyValue('--color-principal').trim().toLowerCase() === a, antes);
    afirmar((await textoDe(p, '#marca-nombre')).trim() === 'Ferretería El Roble', 'no volvió el nombre');
  });

  await prueba('Cajas y bancos: banco nuevo guarda solo los 4 últimos números', async () => {
    const p = due3.p;
    await p.goto(URL_APP + '/#/ajustes/cajas');
    await p.click('#nueva-cuenta');
    await p.selectOption('#cuenta-tipo', 'banco');
    await p.fill('#cuenta-nombre', 'Ficohsa planilla');
    await p.fill('#cuenta-banco', 'Ficohsa');
    await p.fill('#cuenta-numero', '2001-4455-9876');
    await p.selectOption('#cuenta-inicio', 'saldo');
    await p.fill('#cuenta-saldo', '1,500.00');
    await p.click('form.formulario button[type=submit]');
    await p.click('#confirmar-si');
    await p.waitForSelector('#nueva-cuenta', { timeout: 15000 });
    const c = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT numero_enmascarado, saldo_centavos FROM public.v_cuenta_dinero WHERE nombre = 'Ficohsa planilla') x)`));
    afirmar(c.numero_enmascarado === '****9876' && c.saldo_centavos === 150000, 'cuenta: ' + JSON.stringify(c));
    afirmar(!(await p.locator('body').innerText()).includes('2001-4455'), 'se ve el número completo');
    await p.screenshot({ path: path.join(CAPTURAS, 'p3_ajustes_cajas.png'), fullPage: true });
  });
  await due3.ctx.close();
  await adm3.ctx.close();

  await prueba('celular: Inventario (conteo) se usa sin salirse a lo ancho', async () => {
    const { ctx, p } = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(p, 'dueno@demo.hn');
    for (const r of ['inventario/productos', 'inventario/existencias', 'inventario/conteo']) {
      await p.goto(URL_APP + '/#/' + r);
      await p.waitForSelector('#contenido h1');
      const ancho = await p.evaluate(() => document.documentElement.scrollWidth);
      afirmar(ancho <= 390, `${r} se sale a lo ancho: ${ancho}`);
    }
    await p.waitForSelector('#conteo-lista input');
    const alto = await p.locator('#conteo-lista input').first().boundingBox();
    afirmar(alto && alto.height >= 44, 'campo de conteo chico');
    await p.screenshot({ path: path.join(CAPTURAS, 'p3_celular_conteo.png'), fullPage: false });
    await ctx.close();
  });

  await prueba('palabras del rubro: sin palabras queda "Vender"; con palabras cambian solo los títulos', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    afirmar((await p.locator('nav.pestanas').innerText()).includes('Vender'), 'sin palabras debe decir Vender');
    const r = await p.evaluate(async () => {
      const m = await import('/js/menu_datos.js');
      const con = m.conPalabras(m.MENU, { vender: 'Órdenes de trabajo', 'vender/nueva': 'Nueva orden', caja: '', clientes: 'x'.repeat(41) });
      const ven = con.find((x) => x.id === 'vender');
      return { pest: ven.titulo, sub: ven.subs.find((s) => s.id === 'nueva').titulo, caja: con.find((x) => x.id === 'caja').titulo,
        cli: con.find((x) => x.id === 'clientes').titulo, mismas: con.length === m.MENU.length && con.every((x, i) => x.subs.length === m.MENU[i].subs.length),
        intacto: m.MENU.find((x) => x.id === 'vender').titulo, barra: m.tituloBarra({ 'barra/vender': 'Orden' }, 'vender', 'Vender') };
    });
    afirmar(r.pest === 'Órdenes de trabajo' && r.sub === 'Nueva orden' && r.barra === 'Orden', 'no aplica las palabras');
    afirmar(r.caja === 'Caja' && r.cli === 'Clientes', 'acepta palabras vacías o muy largas');
    afirmar(r.mismas && r.intacto === 'Vender', 'las palabras cambiaron qué se ve o el menú original');
    await ctx.close();
  });

  await prueba('sin errores de JavaScript en las páginas', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });

  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de la app pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
