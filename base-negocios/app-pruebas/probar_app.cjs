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

  await prueba('sin errores de JavaScript en las páginas', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });

  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de la app pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
