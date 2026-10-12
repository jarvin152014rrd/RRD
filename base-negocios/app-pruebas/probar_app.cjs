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

  await prueba('sin errores de JavaScript en las páginas', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });

  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de la app pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
