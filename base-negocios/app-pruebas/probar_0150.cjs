// PRUEBA: app 0.15.0 (lo mejor de RRD en lo visual) en el navegador contra la base de demo: modo oscuro (se guarda,
// se lee bien con contraste AA y lo impreso sigue blanco y negro), buscador general (palabras, productos, clientes,
// permisos, no borra la venta, no se abre encima de otra ventana), filtros rápidos que cuentan como la base,
// cotizaciones (cifras y WhatsApp sin emojis) y celular (encabezado en una línea, barra con el total, Salir en Más).
// La corre herramientas/probar_app.sh. Variables: URL_APP, BASE_DEMO, CAPTURAS, PG* del servidor local.
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
    if (global.paginaActual) await global.paginaActual.screenshot({ path: path.join(CAPTURAS, 'falla150_' + total + '.png'), fullPage: true }).catch(() => {});
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
const EM = () => id('EMPRESA');

(async () => {
  const nav = await chromium.launch();
  const erroresJs = [];
  const nueva = async (op = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, ...op });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => erroresJs.push(e.message));
    global.paginaActual = p;
    return { ctx, p };
  };
  const ir = async (p, ruta, sel) => { await p.goto(URL_APP + '/#/inicio/pendientes'); await p.waitForTimeout(200); await p.goto(URL_APP + '/#/' + ruta); if (sel) await p.waitForSelector(sel, { timeout: 15000 }); };
  console.log('Pruebas de la app 0.15.0 (modo oscuro, buscador, filtros rápidos, cotizaciones y celular):');
  const E = EM();

  await prueba('modo oscuro: se enciende, se guarda en el equipo, se lee bien y lo impreso sigue blanco', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    afirmar(await p.evaluate(() => document.documentElement.dataset.tema) === 'claro', 'no empieza en claro');
    paso = 'botón';
    await p.click('#boton-tema');
    afirmar(await p.evaluate(() => document.documentElement.dataset.tema) === 'oscuro', 'no cambió a oscuro');
    afirmar(await p.evaluate(() => localStorage.getItem('tema-pantalla')) === 'oscuro', 'no se guardó en el equipo');
    await p.reload(); await p.waitForSelector('.saludo', { timeout: 15000 });
    afirmar(await p.evaluate(() => document.documentElement.dataset.tema) === 'oscuro', 'al recargar volvió a claro');
    paso = 'contraste';
    const malos = await p.evaluate(async () => {
      const m = await import('/js/marca.js');
      const hex = (c) => { const x = c.match(/\d+(\.\d+)?/g).slice(0, 3).map((v) => Math.round(Number(v))); return '#' + x.map((v) => v.toString(16).padStart(2, '0')).join(''); };
      const fondo = (el) => { while (el) { const b = getComputedStyle(el).backgroundColor; if (b && !/rgba\(0, 0, 0, 0\)|transparent/.test(b)) return hex(b); el = el.parentElement; } return '#ffffff'; };
      const lista = [...document.querySelectorAll('.contenido h1, .contenido h2, .cifra-valor, .cifra-titulo, .ayuda, .chip-color, .contenido .boton, .vacio')]
        .filter((el) => el.offsetParent && el.textContent.trim());
      return lista.map((el) => [el.className, m.contraste(hex(getComputedStyle(el).color), fondo(el))]).filter(([, c]) => c < 4.5);
    });
    afirmar(malos.length === 0, 'texto que no se lee en oscuro: ' + JSON.stringify(malos.slice(0, 3)));
    afirmar(await p.evaluate(() => { const c = getComputedStyle(document.body).backgroundColor.match(/\d+/g).map(Number); return c[0] + c[1] + c[2] < 150; }), 'el fondo no es oscuro');
    paso = 'comprobante';
    await ir(p, 'vender/ventas', '#t-dia');
    await p.locator('.venta-fila-icono button >> text=Comprobante').first().click();
    await p.waitForSelector('.comprobante');
    const comp = await p.evaluate(() => { const s = getComputedStyle(document.querySelector('.comprobante')); return [s.backgroundColor, s.color]; });
    afirmar(comp[0] === 'rgb(255, 255, 255)' && comp[1] === 'rgb(0, 0, 0)', 'el comprobante no es blanco y negro: ' + comp);
    await p.screenshot({ path: path.join(CAPTURAS, 'v15_oscuro_comprobante.png') });
    await p.click('#boton-tema');
    afirmar(await p.evaluate(() => document.documentElement.dataset.tema) === 'claro', 'no volvió a claro');
    await ctx.close();
  });

  await prueba('buscador general: pantallas por palabra, productos y clientes; no borra la venta; no se abre encima de otra ventana', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    paso = 'arqueo';
    await p.keyboard.press('Control+k');
    await p.waitForSelector('#buscador[open]');
    await p.keyboard.type('arqueo');
    afirmar((await textoDe(p, '.buscador-opcion')).includes('Mi turno'), 'arqueo no lleva a Mi turno');
    await p.keyboard.press('Enter');
    await p.waitForFunction(() => location.hash === '#/caja/turno');
    afirmar(await p.locator('#buscador').count() === 0, 'el buscador no se cerró');
    paso = 'producto';
    await p.click('#boton-buscar');
    await p.keyboard.type('PIN-BLA');
    await p.waitForSelector('.buscador-opcion[data-tipo=producto]');
    afirmar((await textoDe(p, '.buscador-opcion[data-tipo=producto]')).includes(lempiras(Number(sql(DUENO, `(SELECT precio_venta_centavos FROM public.v_producto WHERE producto_id = demo.id('PIN'))`)))), 'el producto no muestra su precio');
    await p.click('.buscador-opcion[data-tipo=producto]');
    await p.waitForFunction(() => location.hash === '#/inventario/productos');
    await p.waitForFunction(() => { const x = document.querySelector('#buscar-producto-inv'); return x && x.value === 'PIN-BLA'; });
    paso = 'cliente';
    const cli = sql(DUENO, `(SELECT nombre FROM public.tercero WHERE empresa_id = '${E}' AND es_cliente AND activo ORDER BY nombre LIMIT 1)`);
    await p.keyboard.press('Control+k');
    await p.keyboard.type(cli.split(' ')[0]);
    await p.waitForSelector('.buscador-opcion[data-tipo=cliente]');
    await p.keyboard.press('Escape');
    paso = 'no borra la venta';
    await ir(p, 'vender/nueva', '#buscar-producto');
    await p.fill('#buscar-producto', 'CEM-425'); await p.press('#buscar-producto', 'Enter');
    await p.waitForSelector('.linea-carrito');
    await p.keyboard.press('Control+k');
    await p.keyboard.type('nueva venta');
    await p.keyboard.press('Enter');
    await p.waitForTimeout(600);
    afirmar(await p.locator('.linea-carrito').count() === 1, 'elegir "Nueva venta" estando en Vender borró el carrito');
    paso = 'otra ventana';
    await p.evaluate(async () => { const u = await import('/js/ui.js'); u.confirmar({ titulo: 'Prueba' }); });
    await p.waitForSelector('dialog[open]');
    await p.keyboard.press('Control+k');
    await p.waitForTimeout(300);
    afirmar(await p.locator('#buscador').count() === 0, 'el buscador se abrió encima de otra ventana');
    await p.keyboard.press('Escape');
    await ctx.close();
    paso = 'permisos';
    const c = await nueva();
    await entrar(c.p, 'cajero@demo.hn');
    await c.p.keyboard.press('Control+k');
    await c.p.keyboard.type('gane perdi');
    await c.p.waitForTimeout(300);
    afirmar(!(await c.p.locator('.buscador-lista').innerText()).includes('¿Gané o perdí?'), 'el cajero encuentra ¿Gané o perdí?');
    await c.ctx.close();
  });

  await prueba('filtros rápidos: Ventas del día, Productos y Clientes cuentan como la base y filtran', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    paso = 'ventas';
    await ir(p, 'vender/ventas', '#t-dia');
    const hoySql = `public.hoy_local('${E}')`;
    const contado = Number(sql(DUENO, `(SELECT count(*) FROM public.v_venta WHERE empresa_id = '${E}' AND fecha_contable = ${hoySql} AND estado = 'emitida' AND condicion <> 'credito')`));
    const anuladas = Number(sql(DUENO, `(SELECT count(*) FROM public.v_venta WHERE empresa_id = '${E}' AND fecha_contable = ${hoySql} AND estado = 'anulada')`));
    if (await p.locator('#filtro-ventas').count()) {
      afirmar(Number(await textoDe(p, '#filtro-ventas [data-filtro=contado] .filtro-numero')) === contado, 'contado distinto a la base');
      if (anuladas) {
        await p.click('#filtro-ventas [data-filtro=anulada]');
        afirmar(await p.locator('[data-venta]').count() === anuladas, 'el filtro Anuladas no filtra');
      }
    }
    paso = 'productos';
    await ir(p, 'inventario/productos', '#buscar-producto-inv');
    await p.waitForSelector('#filtro-productos');
    const suma = (x) => `coalesce((SELECT sum(e.cantidad) FROM public.v_existencia e WHERE e.producto_id = ${x}.producto_id), 0)`;
    const agot = Number(sql(DUENO, `(SELECT count(*) FROM public.v_producto p WHERE p.empresa_id = '${E}' AND p.activo AND p.tipo <> 'servicio' AND ${suma('p')} <= 0)`));
    const bajo = Number(sql(DUENO, `(SELECT count(*) FROM public.v_producto p WHERE p.empresa_id = '${E}' AND p.activo AND p.tipo <> 'servicio' AND ${suma('p')} > 0 AND p.stock_minimo > 0 AND ${suma('p')} < p.stock_minimo)`));
    const n = async (f) => (await p.locator(`#filtro-productos [data-filtro=${f}]`).count()) ? Number(await textoDe(p, `#filtro-productos [data-filtro=${f}] .filtro-numero`)) : 0;
    afirmar(await n('agotado') === agot && await n('bajo') === bajo, `agotados/bajo distintos (${await n('agotado')}/${await n('bajo')} vs ${agot}/${bajo})`);
    if (bajo) {
      await p.click('#filtro-productos [data-filtro=bajo]');
      afirmar(await p.locator('[data-producto]').count() === bajo, 'el filtro Bajo el mínimo no filtra');
    }
    paso = 'clientes';
    await ir(p, 'clientes/lista', '#buscar-cliente');
    if (await p.locator('#filtro-clientes [data-filtro=atraso]').count()) {
      const k = Number(await textoDe(p, '#filtro-clientes [data-filtro=atraso] .filtro-numero'));
      await p.click('#filtro-clientes [data-filtro=atraso]');
      afirmar(await p.locator('[data-cliente]').count() === k, 'el filtro Con atraso no filtra');
      afirmar((await p.locator('.lista [data-cliente]').allInnerTexts()).every((t) => t.includes('Con atraso')), 'sale un cliente sin atraso');
    }
    await ctx.close();
  });

  await prueba('cotizaciones: cifras como la base y WhatsApp sin emojis', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, DUENO);
    const cli = sql(DUENO, `(SELECT id FROM public.tercero WHERE empresa_id = '${E}' AND es_cliente AND activo AND telefono IS NOT NULL ORDER BY nombre LIMIT 1)`);
    await ir(p, 'vender/cotizaciones', '#nueva-cotizacion');
    await p.click('#nueva-cotizacion');
    await p.waitForSelector('#buscar-producto');
    await p.fill('#buscar-producto', 'CEM-425'); await p.press('#buscar-producto', 'Enter');
    await p.waitForSelector('.linea-carrito');
    await p.selectOption('#cliente', cli);
    await p.waitForSelector('.vender:not([data-calculando])');
    await p.waitForTimeout(400);
    await p.click('#cobrar');
    await ir(p, 'vender/cotizaciones', '[data-dato=cot-vigentes]');
    const vig = Number(sql(DUENO, `(SELECT count(*) FROM public.v_cotizacion WHERE empresa_id = '${E}' AND estado = 'vigente')`));
    afirmar(Number(await textoDe(p, '[data-dato=cot-vigentes] .cifra-valor')) === vig, 'vigentes distinto a la base');
    const wa = await p.locator('[data-accion=whatsapp]').first().getAttribute('href');
    const texto = decodeURIComponent(wa.split('text=')[1] || '');
    afirmar(/^https:\/\/wa\.me\/\d+\?text=/.test(wa) && texto.includes('Cotización #') && texto.includes('Total: L '), 'enlace de WhatsApp: ' + wa);
    afirmar(!emojis.test(texto), 'el WhatsApp lleva emojis');
    await p.screenshot({ path: path.join(CAPTURAS, 'v15_cotizaciones.png'), fullPage: true });
    await ctx.close();
  });

  await prueba('celular: encabezado en una línea, barra con el total que lleva al cobro, y Salir en Más', async () => {
    const { ctx, p } = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(p, 'cajero@demo.hn');
    afirmar((await p.locator('.encabezado-fila').boundingBox()).height <= 72, 'el encabezado ocupa más de una línea');
    await ir(p, 'vender/nueva', '#buscar-producto');
    await p.fill('#buscar-producto', 'PIN-BLA'); await p.press('#buscar-producto', 'Enter');
    await p.waitForSelector('.vender:not([data-calculando])');
    await p.waitForSelector('#ir-a-cobrar', { state: 'visible' });
    afirmar((await textoDe(p, '[data-dato=total-celular]')).trim() === (await textoDe(p, '[data-dato=total]')).trim(), 'el total de la barra no es el del ticket');
    await p.screenshot({ path: path.join(CAPTURAS, 'v15_celular_barra.png') });
    await p.click('#ir-a-cobrar');
    await p.waitForFunction(() => document.querySelector('.vender').classList.contains('pie-visible'), null, { timeout: 5000 });
    afirmar(!(await p.locator('#ir-a-cobrar').isVisible()), 'la barra sigue tapando el ticket');
    afirmar(await anchoPagina(p) <= 390, 'se sale a lo ancho');
    await ir(p, 'mas', '.mas-sesion');
    afirmar((await textoDe(p, '.mas-sesion')).includes('Salir'), 'Más no tiene Salir');
    await ctx.close();
  });

  if (erroresJs.length) { fallas++; console.log('  FALLA  errores de JavaScript: ' + erroresJs.slice(0, 3).join(' | ')); }
  await nav.close();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total})` : `RESULTADO: TODO OK (${total} de ${total})`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.log('FALLA: ' + e.message); process.exit(1); });
