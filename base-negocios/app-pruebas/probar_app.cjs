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

// Emojis y pictogramas (igual que app/js/imprimible.js; escrito con \u{...} para que este archivo no tenga emojis).
const EMOJI_RE = /(?:(?![\u{A9}\u{AE}\u{2122}])\p{Extended_Pictographic}|[\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}\u{FE0E}\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}])/u;

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
    // "Hay en caja ahora" = cajas de efectivo + caja chica (por tipo, de donde_esta_mi_dinero).
    const efectivo = (d.por_tipo.efectivo_caja || 0) + (d.por_tipo.caja_chica || 0);
    const esperado = { ventas_hoy: r.ventas_hoy.total_centavos, en_caja: efectivo, te_deben: r.te_deben.total_centavos, debes: r.debes.total_centavos };
    afirmar(r.ventas_hoy.total_centavos > 0, 'la demo no tiene ventas de hoy');
    for (const [dato, c] of Object.entries(esperado)) {
      const visto = (await textoDe(p, `[data-dato=${dato}] .cifra-valor`)).trim();
      afirmar(visto === lempiras(c), `${dato}: se ve "${visto}", la base dice "${lempiras(c)}"`);
    }
    const vencido = await textoDe(p, '[data-dato=te_deben] .cifra-nota');
    afirmar(vencido.includes(lempiras(r.te_deben.vencido_centavos)) && vencido.includes('vencido'), 'no muestra lo vencido aparte');
    afirmar((await textoDe(p, '[data-dato=ventas_hoy] .cifra-nota')).includes('que ayer'), 'no compara con ayer');
    afirmar((await textoDe(p, '[data-dato=frase]')).trim() === r.frase, 'la frase del día no coincide');
    // ¿Dónde está mi dinero? ahora vive en Dinero (antes estaba en Inicio).
    await p.goto(URL_APP + '/#/dinero/donde');
    await p.waitForSelector('[data-dato=total_dinero]');
    afirmar((await textoDe(p, '[data-dato=total_dinero]')).trim() === lempiras(d.total_centavos), 'total de ¿dónde está mi dinero? distinto');
    await p.goto(URL_APP + '/#/inicio/hoy');
    await p.waitForSelector('[data-dato=ventas_hoy]');
    // Ejemplo a mano: L 5,095.00 = 509500 centavos
    afirmar(lempiras(509500) === 'L 5,095.00' && lempiras(-85917) === '-L 859.17', 'formato de lempiras');
    const pestanas = (await p.locator('.pestanas .pestana').allInnerTexts()).map((t) => t.trim());
    afirmar(pestanas[pestanas.length - 1] === 'Ajustes', 'Ajustes no es la última pestaña: ' + pestanas.join(', '));
    afirmar(['Dinero', 'Compras', 'Reportes'].every((t) => pestanas.includes(t)), 'al dueño le faltan pestañas');
    afirmar(!(await p.locator('body').innerText()).match(/\b[A-Z]{3,}_[A-Z_]+\b/), 'se ve un código de error crudo');
    await p.screenshot({ path: path.join(CAPTURAS, 'duenio_computadora.png'), fullPage: true });
  });

  await prueba('Inicio (0.5.0): saludo, acciones, gráfica de 7 días, lo más vendido, primeros pasos y campanita', async () => {
    const p = dueno.p;
    const r0 = JSON.parse(sql('dueno@demo.hn', `public.resumen_hoy('${EMPRESA}')`));
    const saludo = await textoDe(p, '.saludo h1');
    afirmar(/^Buen(os días|as tardes|as noches), María$/.test(saludo.trim()), 'saludo: ' + saludo);
    afirmar((await textoDe(p, '[data-info=fecha-caja]')).includes('caja'), 'no dice cómo está la caja');
    for (const a of ['accion-vender', 'accion-cobrar', 'accion-gasto', 'accion-turno']) {
      afirmar(await p.locator(`#${a}`).count() === 1, 'falta el botón ' + a);
    }
    afirmar((await textoDe(p, '#accion-turno')).includes('Abrir mi caja'), 'sin turno debe decir "Abrir mi caja"');
    const alturas = await p.locator('.accion').evaluateAll((els) => els.map((e) => e.getBoundingClientRect().height));
    afirmar(alturas.every((x) => x >= 44), 'botones de acción de menos de 44 px');
    // Gráfica: 7 barras, la última es Hoy (dorada) y el total = suma de v_ventas_por_dia de esos 7 días.
    const barras = await p.locator('#grafica-ventas .grafica-col').count();
    afirmar(barras === 7, 'barras: ' + barras);
    afirmar((await textoDe(p, '#grafica-ventas .grafica-col:last-child .grafica-etiqueta')).trim() === 'Hoy', 'la última barra no es Hoy');
    afirmar(await p.locator('#grafica-ventas .grafica-col:last-child.grafica-hoy').count() === 1, 'Hoy no está resaltado');
    const total7 = Number(sql('dueno@demo.hn', `(SELECT coalesce(sum(total_centavos), 0) FROM public.v_ventas_por_dia
      WHERE empresa_id = '${EMPRESA}' AND fecha BETWEEN public.hoy_local('${EMPRESA}') - 6 AND public.hoy_local('${EMPRESA}'))`));
    afirmar((await textoDe(p, '[data-dato=total_7_dias]')).trim() === lempiras(total7), 'total de 7 días: ' + await textoDe(p, '[data-dato=total_7_dias]') + ' / ' + lempiras(total7));
    // Lo más vendido (0.9.0: mas_vendido del núcleo 0.16.0): el primero es el de más dinero en la semana, ya
    // restadas las devoluciones (a mano con SQL).
    const top = sql('dueno@demo.hn', `(SELECT producto_id FROM (
        SELECT l.producto_id, sum(l.total_centavos) AS t FROM public.venta_linea l JOIN public.venta v ON v.id = l.venta_id
         WHERE v.empresa_id = '${EMPRESA}' AND v.estado = 'emitida' AND v.fecha_contable BETWEEN public.hoy_local('${EMPRESA}') - 6 AND public.hoy_local('${EMPRESA}') GROUP BY 1
        UNION ALL
        SELECT l.producto_id, -sum(l.total_centavos) FROM public.devolucion_linea l JOIN public.devolucion x ON x.id = l.devolucion_id
         WHERE x.empresa_id = '${EMPRESA}' AND x.estado = 'aplicada' AND x.fecha_contable BETWEEN public.hoy_local('${EMPRESA}') - 6 AND public.hoy_local('${EMPRESA}') GROUP BY 1) z
      GROUP BY producto_id ORDER BY sum(t) DESC LIMIT 1)`);
    afirmar(await p.locator('#mas-vendido [data-producto-top]').first().getAttribute('data-producto-top') === top, 'lo más vendido no coincide');
    // Primeros pasos: lo hecho sale de los datos (estado_arranque, marca y turnos).
    const ar = JSON.parse(sql('dueno@demo.hn', `public.estado_arranque('${EMPRESA}')`));
    const hecho = (x) => ar.pasos.find((y) => y.paso === x).estado === 'hecho';
    const marca = JSON.parse(sql('dueno@demo.hn', `public.marca_empresa('${EMPRESA}')`)).marca || {};
    const turnos = Number(sql('dueno@demo.hn', `(SELECT count(*) FROM public.v_turno_caja WHERE empresa_id = '${EMPRESA}')`));
    const n = [Boolean(marca.logo || marca.color_principal || marca.color_acento), turnos > 0, hecho('productos'), hecho('primera_venta'), hecho('usuarios')].filter(Boolean).length;
    afirmar((await textoDe(p, '[data-dato=pasos-hechos]')).trim() === `${n} de 5`, 'primeros pasos: ' + await textoDe(p, '[data-dato=pasos-hechos]') + ', esperaba ' + n);
    afirmar(await p.locator('#primeros-pasos [data-hecho=false] a.boton').count() === 5 - n, 'cada paso pendiente debe tener "Hacerlo"');
    // Campanita = alertas (sin la de "aprobaciones", que ya sale con botones) + aprobaciones pendientes.
    const alertas = JSON.parse(sql('dueno@demo.hn', `public.alertas_activas('${EMPRESA}')`)).alertas.filter((a) => a.tipo !== 'aprobaciones').length;
    const aprob = Number(sql('dueno@demo.hn', `(SELECT count(*) FROM public.v_aprobacion WHERE empresa_id = '${EMPRESA}' AND estado = 'pendiente')`));
    await p.waitForFunction((x) => document.getElementById('campana-numero').textContent === String(x), alertas + aprob);
    afirmar((await textoDe(p, '[data-contador=pendientes]')).trim() === String(alertas + aprob), 'la subpestaña Pendientes no tiene el número');
    afirmar(await p.locator('#inicio-pendientes .solicitud').count() >= 1, 'Pendientes no muestra las aprobaciones');
    // 0.5.1: dice "1 vendido" / "13 vendidos" / "8.5 unidades". 0.9.0: avisa que ya resta las devoluciones.
    const top5 = await textoDe(p, '#mas-vendido');
    afirmar(!top5.includes('vendido(s)') && /\d vendidos?\b|unidades/.test(top5), 'plural de vendidos: ' + top5.replace(/\n/g, ' | '));
    afirmar(await p.locator('#mas-vendido [data-info=con-devoluciones]').count() === 1, 'no avisa que resta devoluciones');
    // La fecha de "Hoy" es la del servidor (resumen_hoy), no la del momento de entrar.
    afirmar(await p.evaluate(async () => (await import('/js/sesion.js')).perfilActual().empresa.hoy) === r0.fecha, 'la fecha de hoy no es la del servidor');
    // Próximo pago: la app pide solo lo que vence de una fecha en adelante (filtro gte.), igual que la base.
    const vence = await p.evaluate(async (e) => {
      const api = await import('/js/api.js');
      return (await api.leer('v_cxp_documento', { empresa_id: e, fecha_vencimiento: { gte: '2026-09-20' } }, { limite: 50 })).length;
    }, EMPRESA);
    afirmar(String(vence) === sql('dueno@demo.hn', `(SELECT count(*) FROM public.v_cxp_documento WHERE empresa_id = '${EMPRESA}' AND fecha_vencimiento >= '2026-09-20')`),
      'el filtro "desde" no da lo mismo que la base: ' + vence);
    await p.screenshot({ path: path.join(CAPTURAS, 'inicio_computadora.png'), fullPage: true });
  });

  await prueba('menú: todas las pestañas y subpestañas tienen un ícono que existe', async () => {
    const p = dueno.p;
    const malos = await p.evaluate(async () => {
      const m = await import('/js/menu_datos.js');
      const ic = await import('/js/iconos.js');
      const faltan = [];
      for (const x of m.MENU) {
        if (!ic.existeIcono(x.icono)) faltan.push(x.id);
        for (const s of x.subs) if (!ic.existeIcono(s.icono)) faltan.push(`${x.id}/${s.id}`);
      }
      // Cada ícono: solo trazos simples (path, circle, rect), nada de texto ni enlaces.
      for (const [n, trazos] of Object.entries(ic.ICONOS)) if (!trazos.length || trazos.some((t) => typeof t !== 'string')) faltan.push('ícono ' + n);
      return faltan;
    });
    afirmar(malos.length === 0, 'sin ícono válido: ' + malos.join(', '));
    const sinSvg = await p.locator('.pestanas .pestana:not(:has(svg)), .subpestanas .subpestana:not(:has(svg))').count();
    afirmar(sinSvg === 0, `${sinSvg} pestaña(s) sin ícono en pantalla`);
  });

  await prueba('rutas viejas llevan a las nuevas (Alertas, Aprobaciones, Excel, Mis alertas)', async () => {
    const p = dueno.p;
    for (const [vieja, nueva] of [['inicio/alertas', 'inicio/pendientes'], ['inicio/aprobaciones', 'inicio/pendientes'],
      ['inventario/excel', 'ajustes/excel'], ['ajustes/mis-alertas', 'ajustes/mi-cuenta'], ['buscar', 'inventario/productos']]) {
      await p.goto(URL_APP + '/#/' + vieja);
      await p.waitForURL(new RegExp('#/' + nueva.replace('/', '\\/') + '$'));
    }
    await p.goto(URL_APP + '/#/inventario/productos');
    await p.waitForSelector('#subir-excel');
    await p.click('#subir-excel');
    await p.waitForSelector('#excel-descargar');
    afirmar(await p.locator('#descargar-todo').count() === 1, 'falta la copia de mis datos en Excel');
    // Mi cuenta: si la persona ve la subpestaña de Excel, la copia está allá; si no, aquí (0.5.1).
    await p.goto(URL_APP + '/#/ajustes/mi-cuenta');
    await p.waitForSelector('#mis-alertas');
    afirmar(await p.locator('#copia-datos').count() === 0, 'copia repetida en Mi cuenta');
    const sinExcel = await p.evaluate(async () => {
      const m = await import('/js/pantallas/aj_datos.js');
      const v = document.createElement('div');
      await m.mostrar(v, { menu: [], sigueVigente: () => true });
      return v.querySelectorAll('#copia-datos #descargar-todo').length;
    });
    afirmar(sinExcel === 1, 'sin la subpestaña de Excel, Mi cuenta no ofrece "Descargar todo"');
    await p.goto(URL_APP + '/#/caja/cajas');
    await p.waitForSelector('.en-construccion .estado-vacio');
    await p.goto(URL_APP + '/#/inicio/hoy');
    await p.waitForSelector('#inicio-pendientes .solicitud');
  });

  await prueba('aprobar una solicitud (con motivo; sin motivo no deja)', async () => {
    const p = dueno.p;
    const antes = await p.locator('#inicio-pendientes .solicitud').count();
    afirmar(antes >= 1, 'no hay solicitudes pendientes en Inicio');
    const id = await p.locator('#inicio-pendientes .solicitud').first().getAttribute('data-aprobacion');
    await p.locator('#inicio-pendientes .solicitud').first().getByRole('button', { name: 'Aprobar' }).click();
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
    await p.waitForFunction((n) => document.querySelectorAll('#inicio-pendientes .solicitud').length === n - 1, antes);
    // Error del servidor traducido: otra persona ya resolvió la solicitud mientras estaba en pantalla.
    const otra = p.locator('#inicio-pendientes .solicitud').first();
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
    // 0.6.0: la pantalla de entrar muestra el nombre y las iniciales del negocio que se usó en este equipo.
    afirmar((await textoDe(p, '#entrar-nombre')).trim() === 'Ferretería El Roble', 'entrar sin el nombre del negocio: ' + await textoDe(p, '#entrar-nombre'));
    afirmar((await textoDe(p, '.entrar-logo')).trim() === 'FR', 'entrar sin las iniciales en la burbuja');
    afirmar(!/\b(RPC|JWT|token|Supabase|servidor)\b/i.test(await p.locator('.entrar').innerText()), 'la pantalla de entrar tiene textos técnicos');
    // Puede volver a entrar (sesión nueva).
    await entrar(p, 'vendedor@demo.hn');
  });
  await vend.ctx.close();

  await prueba('celular: barra inferior con 5 botones con ícono y Ajustes dentro de "Más"', async () => {
    const { ctx, p } = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(p, 'dueno@demo.hn');
    await p.waitForSelector('[data-dato=ventas_hoy]');
    afirmar(await p.locator('.barra-inferior').isVisible(), 'no se ve la barra inferior');
    afirmar(!(await p.locator('.pestanas').isVisible()), 'se ven las pestañas de computadora');
    const botones = (await p.locator('.barra-inferior .boton-barra').allInnerTexts()).map((t) => t.trim());
    afirmar(botones.join(',') === 'Inicio,Vender,Caja,Productos,Más', 'botones: ' + botones.join(','));
    afirmar(await p.locator('.barra-inferior .boton-barra svg').count() === 5, 'botones de la barra sin ícono');
    const ancho = await p.evaluate(() => document.documentElement.scrollWidth);
    afirmar(ancho <= 390, 'la página se sale a lo ancho: ' + ancho);
    const alturas = await p.locator('.barra-inferior .boton-barra').evaluateAll((els) => els.map((e) => e.getBoundingClientRect().height));
    afirmar(alturas.every((a) => a >= 44), 'botones de menos de 44 px');
    await p.screenshot({ path: path.join(CAPTURAS, 'celular.png') });
    await p.screenshot({ path: path.join(CAPTURAS, 'inicio_celular.png'), fullPage: true });
    afirmar(await p.locator('#accion-vender').isVisible(), 'en el celular no se ve el botón Vender');
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

  await prueba('cajero: Inicio sin cifras del negocio ni "Primeros pasos", con sus acciones', async () => {
    const p = caj.p;
    await p.waitForSelector('#inicio-pendientes');
    afirmar(await p.locator('[data-dato]').count() === 0, 'el cajero ve cifras del negocio');
    afirmar(await p.locator('#primeros-pasos').count() === 0, 'el cajero ve Primeros pasos');
    afirmar(await p.locator('#accion-vender').count() === 1 && await p.locator('#accion-turno').count() === 1, 'faltan acciones del cajero');
    afirmar(await p.locator('#accion-gasto').count() === 0, 'el cajero ve "Registrar un gasto" sin permiso');
    for (const palabra of ['Ganancia', 'gané', 'Costo', 'Me deben', 'Aprobar']) {
      afirmar(!(await p.locator('#contenido').innerText()).includes(palabra), 'el cajero ve ' + palabra);
    }
    // Quien no tiene el permiso de ese tipo de solicitud la ve sin botones, con "Espera aprobación".
    const sinBotones = await p.evaluate(async () => {
      const m = await import('/js/pantallas/aprobaciones.js');
      const el = m.listaAprobaciones([{ aprobacion_id: 'x', tipo: 'gasto', monto_centavos: 10000, descripcion: 'Prueba',
        solicitante: 'Ana', solicitado_en: '2026-10-20T15:00:00Z' }], () => {});
      return { botones: el.querySelectorAll('button').length, espera: el.querySelectorAll('[data-info=espera-aprobacion]').length,
        gasto: m.puedeResolver('gasto'), raro: m.puedeResolver('otra_cosa') };
    });
    afirmar(sinBotones.botones === 0 && sinBotones.espera === 1 && !sinBotones.gasto && !sinBotones.raro, 'aprobación sin permiso: ' + JSON.stringify(sinBotones));
  });

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
    // 0.6.0: mensaje claro con lo que pasó ("Venta T-... guardada · L 550.00 en efectivo"), con ícono verde.
    const hecho = await textoDe(p, '.venta-lista');
    afirmar(hecho.includes(`Venta ${v.numero_documento} guardada · L 550.00 en efectivo`), 'mensaje de la venta: ' + hecho);
    afirmar(await p.locator('.venta-lista svg.icono').count() === 1, 'el mensaje de la venta no tiene ícono');
    const comp = await textoDe(p, '.comprobante');
    afirmar(comp.includes(v.numero_documento) && comp.includes(lempiras(v.total_centavos)) && comp.includes(lempiras(v.impuesto_centavos)), 'comprobante: ' + comp);
    afirmar(!/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(comp), 'el comprobante tiene emojis');
    afirmar(await p.locator('.comprobante svg, .comprobante img.icono, .comprobante .icono').count() === 0, 'el comprobante tiene íconos');
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
    await p.goto(URL_APP + '/#/inicio/hoy');
    await p.waitForSelector('#accion-turno');
    afirmar((await textoDe(p, '#accion-turno')).includes('Cerrar mi caja'), 'con turno abierto debe decir "Cerrar mi caja"');
    afirmar((await textoDe(p, '[data-info=fecha-caja]')).includes('abierta desde'), 'no dice desde cuándo está abierta la caja');
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
    // 0.6.0: "Turno #N cerrado · faltante L 10.00" con ícono rojo, y la diferencia en rojo.
    afirmar((await textoDe(p, '#avisos .mensaje-error')).includes('faltante L 10.00'), 'aviso del cierre: ' + await p.locator('#avisos').innerText());
    afirmar(await p.locator('[data-dato=diferencia].monto-sale').count() === 1, 'el faltante no está en rojo');
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

  // ---------------- app 0.10.0: cambio de producto (núcleo 0.16.0) ----------------
  // Venta nueva (como dueño) de contado; el admin la cambia. Precios con ISV: cemento CEM L 275.00, varilla VAR L 185.00,
  // tubo PVC L 115.00, pintura PIN L 520.00 (con dos promociones: la sugerida es "Galón L 60 menos").
  const ventaParaCambio = (lineas, cliente) => {
    sqlEscribir('dueno@demo.hn', `SELECT public.registrar_venta(demo.id('EMPRESA'), jsonb_build_object(${cliente ? `'cliente_id', demo.id('${cliente}'), ` : ''}'lineas', jsonb_build_array(${lineas}),
      'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid())`);
    return JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT venta_id, numero_documento, total_centavos FROM public.v_venta
      WHERE empresa_id = '${EMPRESA}' ORDER BY registrado_en DESC LIMIT 1) x)`));
  };
  async function abrirDevolucion(p, numero) {
    await p.goto(URL_APP + '/#/vender/devoluciones');
    await p.waitForSelector('#dev-numero');
    await p.fill('#dev-numero', numero);
    await p.click('form.formulario button[type=submit]');
    await p.waitForSelector('#dev-motivo');
  }
  async function elegirNuevo(p, buscar, codigo) {
    await p.fill('#cambio-buscar', buscar);
    await p.click(`#zona-cambio .resultado-producto[data-producto="${id(codigo)}"]`);
  }

  await prueba('cambio de producto que vale MENOS: el servidor calcula, la diferencia queda como saldo a favor y sale el comprobante sin emojis', async () => {
    const p = adm.p;
    const v = ventaParaCambio(`demo.l('CEM', 1)`, 'CLI3');
    afirmar(Number(v.total_centavos) === 27500, 'venta de 1 cemento: ' + v.total_centavos);
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '1');
    await p.fill('#dev-motivo', 'Prefiere varilla');
    await p.selectOption('#dev-destino', 'cambio');
    await p.waitForSelector('#zona-cambio:not([hidden])');
    await elegirNuevo(p, 'varilla', 'VAR');
    await p.waitForSelector('[data-dato=cambio-a-favor]', { timeout: 15000 });
    // A mano: devuelve 1 cemento = L 275.00; se lleva 1 varilla = L 185.00; a favor L 275.00 - L 185.00 = L 90.00.
    afirmar((await textoDe(p, '[data-dato=cambio-devuelto]')).trim() === 'L 275.00', 'devuelto');
    afirmar((await textoDe(p, '[data-dato=cambio-nuevo]')).trim() === 'L 185.00', 'nuevo');
    afirmar((await textoDe(p, '[data-dato=cambio-a-favor]')).trim() === 'L 90.00', 'a favor');
    await p.check('#cambio-diferencia input[value=saldo_favor]');
    afirmar(await p.locator('#dev-cuenta').isHidden(), 'con saldo a favor no pide la cuenta');
    await p.click('#dev-guardar');
    await p.waitForSelector('[data-resultado=cambio]', { timeout: 20000 });
    afirmar((await textoDe(p, '[data-dato=saldo-favor]')).trim() === 'L 90.00', 'saldo a favor en pantalla');
    afirmar((await textoDe(p, '[data-dato=cambio-usado]')).trim() === 'L 185.00', 'usado para el producto nuevo');
    await p.waitForSelector('article.comprobante');
    const comp = await textoDe(p, 'article.comprobante');
    afirmar(!EMOJI_RE.test(comp) && comp.includes('Varilla') && comp.includes('Saldo a favor'), 'comprobante: ' + comp);
    afirmar(await p.locator('article.comprobante svg').count() === 0, 'el comprobante no lleva íconos');
    const d = JSON.parse(sql('dueno@demo.hn', `(SELECT row_to_json(x) FROM (SELECT d.saldo_favor_centavos, d.cambio_centavos, d.dinero_centavos,
      d.venta_cambio_id IS NOT NULL AS enlazada, (SELECT monto_centavos - coalesce((SELECT sum(u.monto_centavos) FROM public.saldo_favor_uso u WHERE u.saldo_favor_id = f.id AND u.anulado_en IS NULL), 0)
        FROM public.saldo_favor f WHERE f.id = d.saldo_favor_id) AS queda, (SELECT cliente_id FROM public.saldo_favor f WHERE f.id = d.saldo_favor_id) = demo.id('CLI3') AS del_cliente
      FROM public.devolucion d WHERE d.venta_id = '${v.venta_id}') x)`));
    afirmar(d.saldo_favor_centavos === 9000 && d.cambio_centavos === 18500 && d.dinero_centavos === 0 && d.enlazada && d.queda === 9000 && d.del_cliente,
      'base: ' + JSON.stringify(d));
  });

  await prueba('cambio de producto que vale MÁS: cobra la diferencia, con la promoción sugerida (una sola venta nueva aunque se corte el internet)', async () => {
    const p = adm.p;
    const v = ventaParaCambio(`demo.l('PVC', 1)`, null);
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '1');
    await p.fill('#dev-motivo', 'Mejor se lleva pintura');
    await p.selectOption('#dev-destino', 'cambio');
    await elegirNuevo(p, 'pintura', 'PIN');
    await p.waitForSelector('[data-dato=cambio-cobrar]', { timeout: 15000 });
    // A mano: pintura L 520.00 - L 60.00 de la promoción sugerida = L 460.00; devuelve L 115.00: paga L 345.00.
    afirmar((await textoDe(p, '[data-dato=cambio-nuevo]')).trim() === 'L 460.00', 'nuevo con promoción');
    afirmar((await textoDe(p, '[data-dato=cambio-cobrar]')).trim() === 'L 345.00', 'a cobrar');
    let llamadas = 0;
    await p.route('**/rest/v1/rpc/registrar_devolucion', async (rr) => { llamadas++; if (llamadas === 1) await rr.abort('internetdisconnected'); else await rr.continue(); });
    await p.click('#dev-guardar');
    await p.waitForSelector('[data-resultado=cambio]', { timeout: 20000 });
    await p.unroute('**/rest/v1/rpc/registrar_devolucion');
    afirmar((await textoDe(p, '[data-dato=cambio-pagado]')).trim() === 'L 345.00', 'diferencia pagada en pantalla');
    const pagos = sql('dueno@demo.hn', `(SELECT string_agg(g.forma || ':' || g.monto_centavos, ',' ORDER BY g.linea) FROM public.devolucion d
      JOIN public.venta_pago g ON g.venta_id = d.venta_cambio_id WHERE d.venta_id = '${v.venta_id}')`);
    afirmar(pagos === 'saldo_favor:11500,efectivo:34500', 'pagos de la venta nueva: ' + pagos);
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM public.devolucion WHERE venta_id = '${v.venta_id}')`) === '1', 'una sola devolución');
  });

  await prueba('cambio de producto: con un núcleo 0.15.0 (sin calcular_cambio_previo) lo explica sin romper; en el celular no se sale a lo ancho', async () => {
    const { ctx, p } = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(p, 'admin@demo.hn');
    await p.route('**/rest/v1/rpc/calcular_cambio_previo', (rr) => rr.fulfill({ status: 404, contentType: 'application/json',
      body: JSON.stringify({ code: 'PGRST202', message: 'Could not find the function public.calcular_cambio_previo in the schema cache' }) }));
    const v = ventaParaCambio(`demo.l('PVC', 2)`, null);
    await abrirDevolucion(p, v.numero_documento);
    await p.fill('.linea-devolver input[name=devolver] >> nth=0', '1');
    await p.selectOption('#dev-destino', 'cambio');
    await elegirNuevo(p, 'clavo', 'CLA');
    await p.waitForSelector('[data-info=cambio-sin-nucleo]', { timeout: 15000 });
    afirmar(await p.evaluate(() => document.documentElement.scrollWidth) <= 390, 'devolución con cambio se sale a lo ancho');
    await p.screenshot({ path: path.join(CAPTURAS, 'devolucion_cambio_celular.png'), fullPage: true });
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM public.devolucion WHERE venta_id = '${v.venta_id}')`) === '0', 'no guardó nada');
    await ctx.close();
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

  await prueba('usuario limitado a su sucursal: Inicio y ¿Dónde está mi dinero? solo con lo suyo', async () => {
    const admin = sql(null, "(SELECT id FROM auth.users WHERE email = 'admin@demo.hn')");
    const suc = sql('dueno@demo.hn', `(SELECT id FROM public.sucursal WHERE empresa_id = '${EM}' ORDER BY codigo LIMIT 1)`);
    sqlEscribir('dueno@demo.hn', `SELECT public.asignar_sucursales_usuario('${EM}', '${admin}', ARRAY['${suc}']::uuid[], 'Prueba: limitar a su sucursal')`);
    try {
      const { ctx, p } = await nueva();
      await entrar(p, 'admin@demo.hn');
      await p.waitForSelector('[data-dato=en_caja]');
      const r = JSON.parse(sql('admin@demo.hn', `public.resumen_hoy('${EM}')`));
      afirmar(r.solo_mis_sucursales === true, 'el admin no quedó limitado');
      afirmar((await textoDe(p, '[data-dato=en_caja] .cifra-titulo')).includes('mis sucursales'), 'no dice que es de sus sucursales');
      afirmar((await textoDe(p, '[data-dato=en_caja] .cifra-valor')).trim() === lempiras(r.dinero.disponible_centavos), 'el monto no es el de resumen_hoy');
      afirmar(await p.locator('#grafica-ventas').count() === 0, 've la gráfica de toda la empresa');
      // 0.9.0: lo más vendido sí, porque el servidor (mas_vendido) ya cuenta solo su sucursal.
      await p.waitForSelector('#mas-vendido [data-info=con-devoluciones]');
      const mv = JSON.parse(sql('admin@demo.hn', `public.mas_vendido('${EM}', public.hoy_local('${EM}') - 6, public.hoy_local('${EM}'), 5)`));
      afirmar(mv.solo_mis_sucursales === true && await p.locator('#mas-vendido [data-producto-top]').count() === mv.filas.filter((x) => Number(x.total_neto_centavos) > 0 || Number(x.cantidad_neta) > 0).length,
        'lo más vendido del limitado no es el de su sucursal');
      await p.goto(URL_APP + '/#/dinero/donde');
      await p.waitForSelector('[data-info=solo-sucursales]');
      // A mano: cuentas de S1 (100.00), S2 (50.00) y sin sucursal (20.00); limitado a S1 -> ve 2 y total L 120.00.
      const vista = await p.evaluate(async () => {
        const m = await import('/js/pantallas/dinero_donde.js');
        const el = m.tarjetaDinero({ total_centavos: 17000, cuentas: [
          { nombre: 'Caja S1', tipo: 'efectivo_caja', sucursal_id: 'S1', saldo_centavos: 10000 },
          { nombre: 'Caja S2', tipo: 'efectivo_caja', sucursal_id: 'S2', saldo_centavos: 5000 },
          { nombre: 'Banco', tipo: 'banco', sucursal_id: null, saldo_centavos: 2000 }] }, ['S1']);
        return { texto: el.innerText || el.textContent, total: el.querySelector('[data-dato=total_dinero]').textContent };
      });
      afirmar(!vista.texto.includes('Caja S2') && vista.texto.includes('Banco') && vista.total === 'L 120.00', 'filtro por sucursal: ' + JSON.stringify(vista));
      await ctx.close();
    } finally {
      sqlEscribir('dueno@demo.hn', `SELECT public.asignar_sucursales_usuario('${EM}', '${admin}', ARRAY[]::uuid[], 'Prueba: quitar el límite')`);
    }
  });

  await prueba('0.9.0: con un núcleo 0.15.0 (sin mas_vendido) Inicio suma lo más vendido como antes', async () => {
    const { ctx, p } = await nueva();
    await p.route('**/rest/v1/rpc/mas_vendido', (rr) => rr.fulfill({ status: 404, contentType: 'application/json',
      body: JSON.stringify({ code: 'PGRST202', message: 'Could not find the function public.mas_vendido in the schema cache' }) }));
    await entrar(p, 'dueno@demo.hn');
    await p.waitForSelector('#mas-vendido [data-info=sin-devoluciones]');
    const top = sql('dueno@demo.hn', `(SELECT producto_id FROM public.v_venta_linea WHERE empresa_id = '${EM}' AND estado = 'emitida'
      AND fecha_contable >= public.hoy_local('${EM}') - 6 GROUP BY producto_id ORDER BY sum(total_centavos) DESC LIMIT 1)`);
    afirmar(await p.locator('#mas-vendido [data-producto-top]').first().getAttribute('data-producto-top') === top, 'núcleo viejo: lo más vendido no coincide');
    await ctx.close();
  });

  await prueba('ronda 2: subpestañas junto al saludo (computadora) y arriba (celular); tablas como tarjetas', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await p.waitForSelector('.cabeza-pantalla .subpestanas');
    const [s, n] = [await p.locator('.saludo h1').boundingBox(), await p.locator('.cabeza-pantalla .subpestanas').boundingBox()];
    afirmar(n.x > s.x + s.width && Math.abs((n.y + n.height) - (s.y + s.height)) < 80, 'en computadora las subpestañas no están al lado del saludo');
    await ctx.close();
    const cel = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(cel.p, 'dueno@demo.hn');
    await cel.p.waitForSelector('.cabeza-pantalla .subpestanas');
    const [s2, n2] = [await cel.p.locator('.saludo h1').boundingBox(), await cel.p.locator('.cabeza-pantalla .subpestanas').boundingBox()];
    afirmar(n2.y + n2.height <= s2.y, 'en el celular las subpestañas no están arriba del saludo');
    await cel.p.goto(URL_APP + '/#/inventario/existencias');
    await cel.p.waitForSelector('.tabla-celular tbody tr');
    const forma = await cel.p.evaluate(() => {
      const tr = document.querySelector('.tabla-celular tbody tr');
      const td = tr.querySelector('td.celda-principal');
      return { tr: getComputedStyle(tr).display, thead: getComputedStyle(document.querySelector('.tabla-celular thead')).display,
        principalArriba: td === tr.firstElementChild && getComputedStyle(td).display === 'block',
        titulos: [...tr.querySelectorAll('td:not(.celda-principal)')].every((x) => x.dataset.titulo) };
    });
    afirmar(forma.tr === 'block' && forma.thead !== 'none' && forma.principalArriba && forma.titulos, 'la tabla no se ve como tarjetas: ' + JSON.stringify(forma));
    // 0.6.1: sigue siendo una tabla para el lector de pantalla (roles y encabezado escondido solo a la vista).
    const roles = await cel.p.evaluate(() => {
      const t = document.querySelector('.tabla-celular');
      const th = t.querySelector('thead');
      return { tabla: t.getAttribute('role'), fila: t.querySelector('tbody tr').getAttribute('role'), celda: t.querySelector('tbody td').getAttribute('role'),
        cabeza: t.querySelector('th').getAttribute('role'), alto: th.getBoundingClientRect().height, visible: getComputedStyle(th).display };
    });
    afirmar(roles.tabla === 'table' && roles.fila === 'row' && roles.celda === 'cell' && roles.cabeza === 'columnheader' && roles.alto <= 1 && roles.visible !== 'none',
      'roles de la tabla en el celular: ' + JSON.stringify(roles));
    afirmar(await cel.p.evaluate(() => document.documentElement.scrollWidth) <= 390, 'existencias se sale a lo ancho');
    await cel.ctx.close();
  });

  await prueba('ronda 2: pantalla vacía que enseña (ícono, frase y solo los botones permitidos)', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    const r = await p.evaluate(async () => {
      const ui = await import('/js/ui.js');
      const a = ui.estadoVacio({ icono: 'etiqueta', titulo: 'Aún no tiene productos', texto: 'Agregue lo que vende.',
        botones: [{ texto: 'Agregar el primero', onclick: () => {} }, null, { texto: 'Subir mi Excel', href: '#/ajustes/excel' }] });
      return { svg: a.querySelectorAll('.burbuja-grande svg').length, botones: [...a.querySelectorAll('.boton')].map((b) => b.textContent),
        principal: a.querySelector('.boton').classList.contains('boton-principal'), oculto: a.querySelector('svg').getAttribute('aria-hidden') };
    });
    afirmar(r.svg === 1 && r.botones.join('|') === 'Agregar el primero|Subir mi Excel' && r.principal && r.oculto === 'true', 'estado vacío: ' + JSON.stringify(r));
    // Ventas del día sin ventas: con su botón para empezar (el dueño puede vender).
    const v = await p.evaluate(async () => {
      const m = await import('/js/pantallas/ventas_dia.js');
      const { MENU } = await import('/js/menu_datos.js');
      const el = document.createElement('div');
      // Un día sin ventas: se pinta con una lista vacía (no toca la base).
      const sesion = await import('/js/sesion.js');
      const hoy = sesion.perfilActual().empresa.hoy;
      sesion.perfilActual().empresa.hoy = '1999-01-01';
      try { await m.mostrar(el, { menu: MENU, sigueVigente: () => true }); } finally { sesion.perfilActual().empresa.hoy = hoy; }
      return { vacio: el.querySelectorAll('.estado-vacio').length, boton: (el.querySelector('.estado-vacio a.boton') || {}).textContent || '' };
    });
    afirmar(v.vacio === 1 && v.boton.includes('Hacer una venta'), 'ventas del día vacía: ' + JSON.stringify(v));
    await ctx.close();
  });

  await prueba('ronda 2: "Alertas que recibo" guarda las preferencias de cada quien', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await p.goto(URL_APP + '/#/ajustes/mi-cuenta');
    await p.waitForSelector('#mis-alertas input[data-alerta=stock_minimo]');
    const total = await p.locator('#mis-alertas input[data-alerta]').count();
    afirmar(total === JSON.parse(sql('dueno@demo.hn', `public.mis_preferencias_alertas('${EMPRESA}')`)).length, 'no salen todos los tipos que puede ver');
    await p.uncheck('#mis-alertas input[data-alerta=stock_minimo]');
    await p.click('#alertas-guardar');
    await p.waitForSelector('#avisos .mensaje-ok');
    afirmar((await textoDe(p, '#avisos .mensaje-ok')).includes(`recibe ${total - 1} de ${total}`), 'aviso: ' + await textoDe(p, '#avisos'));
    afirmar(sql('dueno@demo.hn', `(SELECT recibir FROM public.alerta_preferencia WHERE tipo = 'stock_minimo' AND user_id = auth.uid())`) === 'false', 'no se guardó en la base');
    afirmar(!JSON.parse(sql('dueno@demo.hn', `public.alertas_activas('${EMPRESA}')`)).alertas.some((a) => a.tipo === 'stock_minimo'), 'la alerta apagada sigue llegando');
    await p.check('#mis-alertas input[data-alerta=stock_minimo]');
    await p.click('#alertas-guardar');
    await p.waitForFunction((n) => document.querySelector('#avisos').innerText.includes(`recibe ${n} de ${n}`), total);
    afirmar(sql('dueno@demo.hn', `(SELECT recibir FROM public.alerta_preferencia WHERE tipo = 'stock_minimo' AND user_id = auth.uid())`) === 'true', 'no se volvió a encender');
    await ctx.close();
  });

  await prueba('marca del cliente: contraste automático (amarillo #f5e663 y azul muy oscuro) y los colores de significado no cambian', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await p.goto(URL_APP + '/#/vender/ventas');
    await p.waitForSelector('#t-dia');
    const r = await p.evaluate(async () => {
      const mk = await import('/js/marca.js');
      const raiz = document.documentElement;
      const SIGNIFICADO = ['--color-verde', '--color-rojo', '--color-dorado', '--color-azul', '--color-verde-fondo', '--color-rojo-fondo',
        '--color-dorado-fondo', '--color-azul-fondo', '--color-peligro', '--color-ok'];
      const fijos = () => SIGNIFICADO.map((v) => getComputedStyle(raiz).getPropertyValue(v).trim()).join(',');
      const hex = (c) => '#' + c.match(/\d+/g).slice(0, 3).map((x) => Number(x).toString(16).padStart(2, '0')).join('');
      const color = (el) => hex(getComputedStyle(el).color);
      const fondo = (el) => hex(getComputedStyle(el).backgroundColor);
      const boton = document.createElement('button'); boton.className = 'boton boton-principal'; boton.textContent = 'Prueba';
      document.getElementById('contenido').append(boton);
      const antes = fijos();
      const medir = (principal, acento) => {
        mk.aplicarMarca({ color_principal: principal, color_acento: acento });
        const enc = document.querySelector('.encabezado');
        return {
          textoSobre: mk.textoSobre(principal),
          nombre: mk.contraste(color(document.getElementById('marca-nombre')), fondo(enc)),
          pestana: mk.contraste(color(document.querySelector('.pestana[aria-current]')), fondo(enc)),
          salir: mk.contraste(color(document.querySelector('.quien .boton-claro')), fondo(enc)),
          boton: mk.contraste(color(boton), fondo(boton)),
          titulo: mk.contraste(color(document.querySelector('#t-dia')), '#ffffff'),
          iniciales: mk.contraste(color(document.getElementById('marca-logo')), fondo(document.getElementById('marca-logo'))),
          fijos: fijos() === antes,
        };
      };
      const claro = medir('#f5e663', '#fff3a0');
      const oscuro = medir('#0b0b2e', '#1d1d5c');
      mk.aplicarMarca({}); boton.remove();
      return { claro, oscuro, vuelve: fijos() === antes };
    });
    for (const [n, x] of Object.entries({ claro: r.claro, oscuro: r.oscuro })) {
      for (const k of ['nombre', 'pestana', 'salir', 'boton', 'titulo', 'iniciales']) afirmar(x[k] >= 4.5, `${n}: ${k} con contraste ${x[k].toFixed(2)} (< 4.5)`);
      afirmar(x.fijos, `${n}: la marca cambió un color de significado`);
    }
    afirmar(r.claro.textoSobre === '#000000' && r.oscuro.textoSobre === '#ffffff', 'texto encima: ' + JSON.stringify([r.claro.textoSobre, r.oscuro.textoSobre]));
    // 0.6.1: colores "del medio" (rojo puro y gris) donde #1a1a1a no llegaba a 4.5: texto encima AA siempre,
    // íconos de títulos con 3 o más sobre blanco y el foco con el acento solo si llega a 3.
    const medio = await p.evaluate(async () => {
      const mk = await import('/js/marca.js');
      return ['#ff0000', '#808080', '#f5e663', '#0b0b2e', '#c8972a', '#ffffff', '#000000'].map((c) => {
        const v = mk.coloresDeMarca({ color_principal: c, color_acento: c });
        return { c, principal: mk.contraste(v['--color-en-principal'], v['--color-principal']), acento: mk.contraste(v['--color-en-acento'], v['--color-acento']),
          suave: mk.contraste(v['--color-en-principal-suave'], v['--color-principal']), icono: mk.contraste(v['--color-acento-icono'], '#ffffff'),
          foco: mk.contraste(v['--color-foco'], '#ffffff'), letra: mk.contraste(v['--color-principal-texto'], '#f4f2ee') };
      });
    });
    for (const x of medio) {
      afirmar(x.principal >= 4.5 && x.acento >= 4.5 && x.suave >= 4.5 && x.letra >= 4.5, `${x.c}: texto con contraste menor que 4.5: ` + JSON.stringify(x));
      afirmar(x.icono >= 3 && x.foco >= 3, `${x.c}: ícono o foco con contraste menor que 3: ` + JSON.stringify(x));
    }
    // Ajustes > Mi negocio: vista previa en vivo antes de guardar (la app no cambia hasta guardar).
    await p.goto(URL_APP + '/#/ajustes/negocio');
    await p.waitForSelector('#marca-previa .encabezado');
    const real = await p.evaluate(() => getComputedStyle(document.querySelector('header.encabezado')).backgroundColor);
    await p.fill('#marca-principal', '#f5e663');
    await p.waitForSelector('[data-info=contraste]');
    const prev = await p.evaluate(() => ({ fondo: getComputedStyle(document.querySelector('#marca-previa .encabezado')).backgroundColor,
      letra: getComputedStyle(document.querySelector('#marca-previa .marca-nombre')).color,
      real: getComputedStyle(document.querySelector('header.encabezado')).backgroundColor,
      iniciales: document.querySelector('#marca-previa .marca-logo').textContent }));
    afirmar(prev.fondo === 'rgb(245, 230, 99)' && prev.letra === 'rgb(0, 0, 0)', 'vista previa: ' + JSON.stringify(prev));
    afirmar(prev.real === real, 'la app cambió de color antes de guardar');
    afirmar(prev.iniciales === 'FR', 'sin logo, la vista previa no muestra las iniciales');
    await p.screenshot({ path: path.join(CAPTURAS, 'marca_vista_previa_amarilla.png') });
    await ctx.close();
  });

  await prueba('impreso: comprobante, WhatsApp y título sin emojis ni íconos (aunque el negocio o el rubro los traigan)', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    // Datos "envenenados" como los podría escribir un cliente: emojis en el negocio, productos, cliente y rubro.
    const E = (n) => String.fromCodePoint(n);
    const r = await p.evaluate(async (emo) => {
      const comp = await import('/js/comprobante.js');
      const imp = await import('/js/imprimible.js');
      const { MENU, conPalabras } = await import('/js/menu_datos.js');
      const doc = { tipo: 'TICKET' + emo[0], numero_documento: 'T-001', fecha: '2026-10-21', anulada: false,
        emisor: { nombre: 'Ferretería ' + emo[1] + ' El Roble', rtn: '0801', sucursal: 'Centro ' + emo[2], caja: 'Caja 1' },
        cliente: { nombre: 'Ana ' + emo[3] + emo[4] }, vendedor: 'Luis ' + emo[5],
        lineas: [{ descripcion: 'Pintura ' + emo[6] + ' blanca', cantidad: 1, precio_unitario_centavos: 1000, total_centavos: 1000 }],
        totales: { subtotal_centavos: 870, impuesto_centavos: 130, total_centavos: 1000, impuestos: [{ nombre: 'ISV ' + emo[7], impuesto_centavos: 130 }] },
        pagos: [{ forma: 'efectivo', monto_centavos: 1000 }], fiscal: { leyendas: ['Gracias ' + emo[8]] } };
      const el = comp.comprobante(doc);
      // Un ícono que se colara (por ejemplo, de una pieza de pantalla) también se quita al limpiar.
      const otro = document.createElement('div');
      otro.innerHTML = '<p>Hola <svg class="icono"><path d="M1 1"/></svg></p>';
      imp.limpiarImprimible(otro);
      // Título con palabras del rubro (las pone el cliente) al imprimir.
      const ven = conPalabras(MENU, { vender: 'Órdenes ' + emo[9] + ' de trabajo' }).find((x) => x.id === 'vender').titulo;
      const antes = document.title;
      document.title = `${ven} · Ferretería ${emo[1]}`;
      const conEmoji = document.title;
      window.dispatchEvent(new Event('beforeprint'));
      const impreso = document.title;
      window.dispatchEvent(new Event('afterprint'));
      const despues = document.title;
      document.title = antes;
      return { texto: el.textContent, svg: el.querySelectorAll('svg, .icono').length, aria: el.getAttribute('aria-label'),
        wa: comp.textoWhatsApp(doc), otro: otro.querySelectorAll('svg').length, conEmoji, impreso, despues,
        cobro: (await import('/js/pantallas/clientes.js')).mensajeCobro('Ana ' + emo[3], 1000, 0),
        nombre: el.querySelector('p').textContent };
    }, [E(0x1F9FE), E(0x1F528), E(0x1F3EA), E(0x1F44B) + E(0x1F3FD), E(0x1F1ED) + E(0x1F1F3), E(0x2B50), E(0x1F3A8),
      E(0x2705) + E(0xFE0F), E(0x2764) + E(0xFE0F), E(0x1F468) + E(0x200D) + E(0x1F527)]);
    // 0.6.1: bandera de una región (con etiquetas U+E0020..U+E007F): se quita completa.
    const region = [0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F].map((n) => String.fromCodePoint(n)).join('');
    const sinRegion = await p.evaluate(async (t) => (await import('/js/imprimible.js')).sinEmojis(t), `Hola ${region} mundo`);
    afirmar(sinRegion === 'Hola mundo' && EMOJI_RE.test(String.fromCodePoint(0xE0067)), 'bandera de región: ' + JSON.stringify(sinRegion));
    afirmar(!EMOJI_RE.test(r.texto) && r.texto.includes('Pintura blanca') && r.nombre === 'Ferretería El Roble', 'comprobante con emojis: ' + r.texto);
    afirmar(r.svg === 0 && r.otro === 0, 'lo impreso tiene íconos');
    afirmar(!EMOJI_RE.test(r.wa) && !EMOJI_RE.test(r.cobro), 'el texto para WhatsApp tiene emojis');
    afirmar(EMOJI_RE.test(r.conEmoji) && !EMOJI_RE.test(r.impreso) && r.impreso.startsWith('Órdenes de trabajo'), 'título al imprimir: ' + r.impreso);
    afirmar(r.despues === r.conEmoji, 'después de imprimir no volvió el título');
    // La regla de la prueba encuentra emojis de verdad (si no, la prueba no probaría nada).
    afirmar(EMOJI_RE.test(String.fromCodePoint(0x1F600)) && EMOJI_RE.test(String.fromCodePoint(0x2705)) && !EMOJI_RE.test('Ñandú © L 1,000.00 → ok'), 'la regla de emojis');
    // 0.8.0: la hoja impresa de los reportes (Reportes y Cierre de mes) tampoco lleva emojis ni íconos.
    const hoja = await p.evaluate(async (emo) => {
      const rep = await import('/js/reportes.js');
      const el = rep.hojaImpresa({ titulo: 'Ventas ' + emo[0], periodo: 'octubre ' + emo[1], notas: ['Nota ' + emo[2]],
        secciones: [{ titulo: 'Por vendedor ' + emo[3], columnas: [{ titulo: 'Vendedor' }, { titulo: 'Total', tipo: 'dinero' }],
          filas: [['Ana ' + emo[4], 150000], ['Luis ' + emo[5], 2500]], total: ['Total', 152500] }] });
      return { texto: el.textContent, svg: el.querySelectorAll('svg, .icono, .chip-color, .burbuja').length };
    }, [E(0x1F4C8), E(0x1F389), E(0x2705) + E(0xFE0F), E(0x1F947), E(0x1F44B) + E(0x1F3FD), E(0x1F468) + E(0x200D) + E(0x1F527)]);
    afirmar(!EMOJI_RE.test(hoja.texto) && hoja.svg === 0 && hoja.texto.includes('Ana') && hoja.texto.includes('L 1,525.00'), 'reporte impreso con emojis: ' + hoja.texto);
    // El código de lo impreso no usa íconos.
    const fs = require('node:fs');
    const fuente = fs.readFileSync(path.join(__dirname, '..', 'app', 'js', 'comprobante.js'), 'utf8');
    afirmar(!/iconos\.js|\bicono\(|<svg/.test(fuente), 'comprobante.js usa íconos');
    await ctx.close();
  });

  await prueba('en pantalla no hay emojis: ni en el código de la app ni en ninguna pantalla (computadora y celular, con capturas)', async () => {
    const fs = require('node:fs');
    const raizApp = path.join(__dirname, '..', 'app');
    const malos = [];
    const andar = (d) => {
      for (const f of fs.readdirSync(d, { withFileTypes: true })) {
        const x = path.join(d, f.name);
        if (f.isDirectory()) { if (f.name !== 'vendor') andar(x); continue; }
        if (!/\.(js|css|html|webmanifest|json)$/.test(f.name)) continue;
        fs.readFileSync(x, 'utf8').split('\n').forEach((l, i) => { if (EMOJI_RE.test(l)) malos.push(`${path.relative(raizApp, x)}:${i + 1}`); });
      }
    };
    andar(raizApp);
    afirmar(malos.length === 0, 'emojis en el código: ' + malos.join(', '));
    const nombre = (r) => r.replace(/[^a-z0-9]+/gi, '_').replace(/^_|_$/g, '');
    const revisar = async (p, que) => p.evaluate(() => {
      const raiz = document.getElementById('app');
      const svgMalos = [...raiz.querySelectorAll('svg')].filter((x) => !x.classList.contains('icono') || x.getAttribute('aria-hidden') !== 'true').length;
      const texto = raiz.innerText;
      return { texto, svgMalos, ancho: document.documentElement.scrollWidth, nulos: /(^|\s)(null|undefined)(\s|$)/.test(texto) };
    });
    for (const [ancho, alto, sufijo] of [[1280, 900, 'computadora'], [390, 844, 'celular']]) {
      const { ctx, p } = await nueva(ancho < 700 ? { viewport: { width: ancho, height: alto }, isMobile: true, hasTouch: true } : { viewport: { width: ancho, height: alto } });
      await p.goto(URL_APP + '/');
      await p.waitForSelector('#correo');
      await p.screenshot({ path: path.join(CAPTURAS, `entrar_${sufijo}.png`) });
      await entrar(p, 'dueno@demo.hn');
      const rutas = await p.evaluate(async () => (await import('/js/menu.js')).menuDelUsuario().flatMap((x) => x.subs.map((s) => `${x.id}/${s.id}`)));
      if (ancho < 700) rutas.push('mas');
      for (const ruta of rutas) {
        await p.goto(URL_APP + '/#/' + ruta);
        await p.waitForFunction((r) => location.hash === '#/' + r && !document.querySelector('#contenido .cargando')
          && [...document.querySelectorAll('#contenido > .lista')].some((x) => x.children.length), ruta, { timeout: 20000 })
          .catch(() => { throw new Error(`${ruta} (${sufijo}) no terminó de cargar`); });
        await p.waitForTimeout(250);
        const x = await revisar(p);
        afirmar(!EMOJI_RE.test(x.texto), `${ruta} (${sufijo}) tiene un emoji en pantalla`);
        afirmar(x.svgMalos === 0, `${ruta} (${sufijo}): ${x.svgMalos} dibujo(s) que no son íconos de línea decorativos`);
        afirmar(!x.nulos, `${ruta} (${sufijo}) muestra "null" o "undefined"`);
        afirmar(x.ancho <= ancho, `${ruta} (${sufijo}) se sale a lo ancho: ${x.ancho}`);
        await p.screenshot({ path: path.join(CAPTURAS, `${nombre(ruta)}_${sufijo}.png`), fullPage: true });
      }
      await ctx.close();
    }
  });

  await prueba('0.6.1: doble aprobación avisa "falta la segunda"; casillas de permisos de 44 px; nombre del negocio en config.js', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    // El servidor responde que falta la segunda aprobación (respuesta simulada; no toca la base).
    await p.route('**/rest/v1/rpc/resolver_aprobacion', (r) => r.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ aprobacion_id: 'x', estado: 'pendiente', falta_segunda_aprobacion: true }) }));
    await p.evaluate(async () => {
      const m = await import('/js/pantallas/aprobaciones.js');
      const el = m.listaAprobaciones([{ aprobacion_id: 'x', tipo: 'gasto', monto_centavos: 900000, descripcion: 'Prueba doble',
        solicitante: 'Ana', solicitado_en: '2026-10-20T15:00:00Z' }], () => {});
      el.id = 'prueba-doble';
      document.getElementById('contenido').append(el);
    });
    await p.locator('#prueba-doble').getByRole('button', { name: 'Aprobar' }).click();
    await dialogoMotivo(p, 'Revisado, primera firma');
    await p.waitForSelector('#avisos .mensaje');
    const msj = await p.locator('#avisos').innerText();
    afirmar(msj.includes('Primera aprobación lista; falta la segunda') && !msj.includes('Solicitud aprobada'), 'aviso de doble aprobación: ' + msj);
    await p.unroute('**/rest/v1/rpc/resolver_aprobacion');
    // Tabla de permisos: cada casilla dentro de un área de 44 px o más.
    await p.goto(URL_APP + '/#/ajustes/usuarios');
    await p.waitForSelector('#tabla-permisos .casilla-toque');
    const chicas = await p.locator('#tabla-permisos .casilla-toque').evaluateAll((els) => els.filter((e) => {
      const b = e.getBoundingClientRect(); return b.width < 44 || b.height < 44 || !e.querySelector('input[type=checkbox]'); }).length);
    afirmar(chicas === 0, `${chicas} casilla(s) de permisos con menos de 44 px`);
    await ctx.close();
    // armar_app.sh pone SOLO el nombre del negocio (validado) en config.js.
    const fs = require('node:fs');
    const raiz = path.join(__dirname, '..');
    const salida = path.join(raiz, 'dist', 'app-ejemplo');
    const r = spawnSync('bash', [path.join(raiz, 'herramientas', 'armar_app.sh'), 'ejemplo', 'https://abcd1234.supabase.co', 'sb_publishable_prueba123'], { encoding: 'utf8' });
    try {
      afirmar(r.status === 0, 'armar_app.sh falló: ' + r.stderr);
      const cfg = fs.readFileSync(path.join(salida, 'config.js'), 'utf8');
      afirmar(/nombreNegocio: "Ferretería Ejemplo S\. de R\.L\.",/.test(cfg), 'config.js sin el nombre del negocio: ' + cfg);
      afirmar(!/08011999000000|rtn|dueno|correo/i.test(cfg), 'config.js trae datos de la ficha que no son el nombre');
    } finally { fs.rmSync(salida, { recursive: true, force: true }); }
  });

  await prueba('sin errores de JavaScript en las páginas', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });

  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de la app pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
