// PRUEBA: fotos de productos (app 0.11.0, núcleo 0.17.0) en el navegador (Chromium con Playwright) contra la base
// de demo y el Storage mínimo de herramientas/servidor_app.js. La corre herramientas/probar_app.sh (al final).
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
let paso = '';   // en qué parte va la prueba (sale en el mensaje si falla)
async function prueba(nombre, fn) {
  total++;
  paso = '';
  try { await fn(); console.log(`  OK     ${nombre}`); } catch (e) { fallas++; console.log(`  FALLA  ${nombre}\n           ${paso ? '[' + paso + '] ' : ''}${String(e.message).split('\n')[0]}`); }
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

async function entrar(pagina, correo) {
  await pagina.goto(URL_APP + '/');
  await pagina.fill('#correo', correo);
  await pagina.fill('#clave', CLAVE);
  await pagina.click('button[type=submit]');
  await pagina.waitForSelector('.saludo', { timeout: 15000 });
}
async function abrirProducto(p, nombre) {
  await p.goto(URL_APP + '/#/inventario/productos');
  await p.waitForSelector('#buscar-producto-inv');
  await p.fill('#buscar-producto-inv', nombre);
  await p.getByRole('button', { name: `Ver ${nombre}` }).click();
  await p.waitForSelector('#t-pficha');
}
const anchoPagina = (p) => p.evaluate(() => document.documentElement.scrollWidth);
// ¿La imagen se ve? (cargada desde blob: y con tamaño)
const imagenVisible = (loc) => loc.evaluate((img) => Boolean(img.closest('.con-foto')) && img.complete && img.naturalWidth > 0 && img.src.startsWith('blob:'));

(async () => {
  const nav = await chromium.launch();
  const erroresJs = [];
  const nueva = async (opciones = {}) => {
    const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 }, ...opciones });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => erroresJs.push(e.message));
    return { ctx, p };
  };
  const EMPRESA = sql('dueno@demo.hn', "demo.id('EMPRESA')");
  const PRODUCTO = 'Cemento gris 42.5 kg';
  const PROD_ID = sql('dueno@demo.hn', "demo.id('CEM')");
  // Arranque conocido: fotos apagadas y sin foto (por si la base se reusa).
  sqlEscribir('dueno@demo.hn', `SELECT public.activar_fotos_productos(demo.id('EMPRESA'), false, 'Prueba: empezar apagadas')`);

  // Una foto "real" grande (3000 x 2000, con detalle, JPEG ~2 MB), hecha en el navegador.
  const { ctx: c0, p: p0 } = await nueva();
  await p0.goto(URL_APP + '/');
  // colores y texto distintos = otra foto (otra huella, otro nombre de archivo)
  const hacerFoto = async (c1, c2, c3, texto) => Buffer.from(await p0.evaluate(([c1, c2, c3, texto]) => {
    const c = document.createElement('canvas');
    c.width = 3000; c.height = 2000;
    const x = c.getContext('2d');
    const g = x.createLinearGradient(0, 0, 3000, 2000);
    g.addColorStop(0, c1); g.addColorStop(0.5, c2); g.addColorStop(1, c3);
    x.fillStyle = g; x.fillRect(0, 0, 3000, 2000);
    const d = x.getImageData(0, 0, 3000, 2000);
    let s = 12345;
    for (let i = 0; i < d.data.length; i += 4) { s = (s * 1103515245 + 12345) & 0x7fffffff; const n = (s % 60) - 30; d.data[i] += n; d.data[i + 1] += n; d.data[i + 2] += n; }
    x.putImageData(d, 0, 0);
    x.fillStyle = '#ffffff'; x.font = 'bold 300px sans-serif'; x.fillText(texto, 300, 1100);
    return c.toDataURL('image/jpeg', 0.95).split(',')[1];
  }, [c1, c2, c3, texto]), 'base64');
  const fotoGrande = await hacerFoto('#8a6d3b', '#d9c7a1', '#3b5a8a', 'CEMENTO');
  const fotoOtra = await hacerFoto('#2e7d32', '#a5d6a7', '#1b5e20', 'OTRA');
  const fotoTercera = await hacerFoto('#6a1b9a', '#ce93d8', '#4a148c', 'TERCERA');
  await c0.close();
  const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
  const pesada = Buffer.alloc(11 * 1024 * 1024, 7);

  console.log('Pruebas de fotos de productos:');
  console.log(`  (foto original de prueba: 3000 x 2000, ${Math.round(fotoGrande.length / 1024)} KB)`);

  await prueba('interruptor apagado (como viene): no se ve nada de fotos en Productos, la ficha ni Vender', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await p.goto(URL_APP + '/#/ajustes/negocio');
    await p.waitForSelector('#tarjeta-fotos');
    afirmar((await p.locator('[data-dato=fotos-estado]').innerText()).includes('Apagadas'), 'Mi negocio no dice Apagadas');
    afirmar(!(await p.locator('#fotos-interruptor').isChecked()), 'el interruptor no está apagado');
    await abrirProducto(p, PRODUCTO);
    afirmar(await p.locator('#seccion-foto').count() === 0, 'la ficha muestra la sección de foto con las fotos apagadas');
    afirmar(await p.locator('img').count() === 0, 'hay imágenes en la ficha');
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    await p.fill('#buscar-producto', 'cemento');
    await p.waitForSelector('.resultado-producto');
    afirmar(await p.locator('.resultado-producto .burbuja').count() === 0, 'Vender muestra burbujas con las fotos apagadas');
    await ctx.close();
  });

  await prueba('solo el dueño enciende las fotos (Ajustes > Mi negocio, con motivo); el admin no ve el interruptor', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'admin@demo.hn');
    await p.goto(URL_APP + '/#/ajustes/negocio');
    await p.waitForSelector('#t-neg');
    afirmar(await p.locator('#tarjeta-fotos').count() === 0, 'el admin ve el interruptor de fotos');
    await ctx.close();
    const d = await nueva();
    await entrar(d.p, 'dueno@demo.hn');
    await d.p.goto(URL_APP + '/#/ajustes/negocio');
    await d.p.waitForSelector('#fotos-interruptor');
    await d.p.click('#fotos-interruptor');
    await d.p.waitForSelector('dialog.dialogo[open]');
    await d.p.fill('dialog.dialogo textarea', 'Queremos ver los productos con foto');
    await d.p.click('dialog.dialogo button[type=submit]');
    await d.p.waitForSelector('dialog.dialogo', { state: 'detached' });
    await d.p.waitForSelector('[data-dato=fotos-estado]:has-text("Encendidas")');
    afirmar(sql('dueno@demo.hn', `(SELECT fotos_productos FROM public.empresa WHERE id = '${EMPRESA}')`) === 'true', 'en la base no quedó encendido');
    afirmar(sql(null, `(SELECT count(*) FROM public.bitacora WHERE empresa_id = '${EMPRESA}' AND tabla = 'empresa' AND motivo = 'Queremos ver los productos con foto')`) === '1', 'sin bitácora');
    afirmar(await d.p.locator('[data-info=storage-falta]').count() === 0, 'dice que falta preparar Storage (en la demo está listo)');
    await d.ctx.close();
  });

  let rutaMediana = null;
  let rutaMini = null;
  await prueba('subir una foto real: se reduce en el navegador (600 px ~40 KB y miniatura 120 px ~8 KB) y se ve en la ficha', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await abrirProducto(p, PRODUCTO);
    await p.waitForSelector('#seccion-foto #sin-foto');
    // Rechazos antes de reducir: SVG, algo que no es imagen y más de 10 MB.
    await p.setInputFiles('#foto-archivo', { name: 'dibujo.svg', mimeType: 'image/svg+xml', buffer: svg });
    await p.waitForSelector('#seccion-foto .mensaje-error');
    afirmar((await p.locator('#seccion-foto .mensaje-error').innerText()).includes('SVG'), 'no rechazó el SVG');
    await p.setInputFiles('#foto-archivo', { name: 'notas.txt', mimeType: 'text/plain', buffer: Buffer.from('hola') });
    await p.waitForSelector('#seccion-foto .mensaje-error:has-text("no es una foto")');
    await p.setInputFiles('#foto-archivo', { name: 'enorme.jpg', mimeType: 'image/jpeg', buffer: pesada });
    await p.waitForSelector('#seccion-foto .mensaje-error:has-text("10 MB")');
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos')`) === '0', 'algo se subió con un archivo rechazado');
    // La foto buena.
    await p.setInputFiles('#foto-archivo', { name: 'cemento.jpg', mimeType: 'image/jpeg', buffer: fotoGrande });
    await p.waitForSelector('#avisos .mensaje-ok:has-text("Foto guardada")', { timeout: 20000 });
    await p.waitForSelector('#foto-ficha.con-foto', { timeout: 10000 });
    const dim = await p.locator('#foto-ficha img').evaluate((i) => [i.naturalWidth, i.naturalHeight]);
    afirmar(dim[0] === 600 && dim[1] === 400, 'la foto mediana no quedó de 600 x 400: ' + dim.join(' x '));
    const filas = JSON.parse(sql('dueno@demo.hn', `(SELECT json_agg(json_build_object('n', name, 's', (metadata->>'size')::int, 't', metadata->>'mimetype') ORDER BY name)
      FROM storage.objects WHERE bucket_id = 'fotos-productos')`));
    afirmar(filas.length === 2, 'debían quedar 2 archivos: ' + JSON.stringify(filas));
    const med = filas.find((f) => !f.n.includes('_mini')), mini = filas.find((f) => f.n.includes('_mini'));
    console.log(`           (subidas: mediana ${med.s} bytes, miniatura ${mini.s} bytes, ${med.t})`);
    afirmar(med.n.startsWith(`${EMPRESA}/${PROD_ID}/`) && mini.n.startsWith(`${EMPRESA}/${PROD_ID}/`), 'ruta fuera de <empresa>/<producto>/');
    afirmar(['image/webp', 'image/jpeg'].includes(med.t) && med.t === mini.t, 'tipo: ' + med.t);
    afirmar(med.s > 2000 && med.s <= 60 * 1024, 'la mediana pesa ' + med.s + ' bytes (se esperaba ~40 KB, máximo 60 KB)');
    afirmar(mini.s > 200 && mini.s <= 12 * 1024, 'la miniatura pesa ' + mini.s + ' bytes (se esperaba ~8 KB, máximo 12 KB)');
    afirmar(med.s < fotoGrande.length / 20, 'no se redujo: ' + med.s + ' de ' + fotoGrande.length);
    const prod = JSON.parse(sql('dueno@demo.hn', `(SELECT json_build_object('r', foto_ruta, 'm', foto_miniatura_ruta) FROM public.v_producto WHERE producto_id = '${PROD_ID}')`));
    afirmar(prod.r === med.n && prod.m === mini.n, 'el producto no guardó las rutas: ' + JSON.stringify(prod));
    rutaMediana = med.n;
    rutaMini = mini.n;
    afirmar(sql(null, `(SELECT count(*) FROM public.bitacora WHERE empresa_id = '${EMPRESA}' AND tabla = 'producto' AND registro_id = '${PROD_ID}'
      AND despues->>'foto_ruta' = '${med.n}')`) === '1', 'el cambio de foto no quedó en la bitácora');
    // La miniatura se reduce de verdad (120 px)
    const dimMini = await p.evaluate(async (ruta) => {
      const m = await import('./js/fotos.js');
      const u = await m.urlFoto(ruta);
      const i = new Image(); i.src = u; await i.decode();
      return [i.naturalWidth, i.naturalHeight];
    }, mini.n);
    afirmar(dimMini[0] === 120 && dimMini[1] === 80, 'la miniatura no quedó de 120 x 80: ' + dimMini.join(' x '));
    // Quedó en la caché del navegador (no se vuelve a bajar).
    const enCache = await p.evaluate(async (e) => {
      const c = await caches.open('fotos-' + e);
      return (await c.keys()).map((r) => r.url);
    }, EMPRESA);
    afirmar(enCache.some((u) => u.endsWith(med.n)) && enCache.some((u) => u.endsWith(mini.n)), 'las fotos no quedaron en la caché: ' + enCache.join(', '));
    await p.screenshot({ path: path.join(CAPTURAS, 'fotos-ficha.png'), fullPage: true });
    await ctx.close();
  });

  await prueba('la miniatura se ve en Productos (lista), Vender (buscador y línea), Inicio (lo más vendido) e Inventario', async () => {
    const { ctx, p } = await nueva();
    let bajadas = 0;
    p.on('request', (r) => { if (r.url().includes('/storage/v1/object/authenticated/')) bajadas++; });
    await entrar(p, 'dueno@demo.hn');
    // Productos
    await p.goto(URL_APP + '/#/inventario/productos');
    const filaProd = p.locator(`[data-producto="${PROD_ID}"] img.foto-producto`);
    await filaProd.waitFor({ state: 'attached' });
    await p.waitForFunction((id) => { const i = document.querySelector(`[data-producto="${id}"] img.foto-producto`); return i && i.closest('.con-foto') && i.naturalWidth > 0; }, PROD_ID);
    afirmar(await imagenVisible(filaProd), 'no se ve la miniatura en la lista de productos');
    afirmar(await filaProd.getAttribute('loading') === 'lazy', 'la miniatura no es perezosa');
    afirmar(await p.locator('.burbuja-foto:not([data-con-foto]) .icono').count() > 0, 'los productos sin foto perdieron su ícono');
    // Vender: buscador y línea
    paso = 'vender';
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.fill('#buscar-producto', 'cemento');
    await p.waitForSelector('.resultado-producto .con-foto > img.foto-producto');
    await p.locator('.resultado-producto').first().click();
    await p.waitForSelector(`.linea-carrito[data-producto="${PROD_ID}"] .con-foto > img.foto-producto`);
    afirmar(await imagenVisible(p.locator(`.linea-carrito[data-producto="${PROD_ID}"] img.foto-producto`)), 'no se ve la miniatura en la línea de venta');
    await p.screenshot({ path: path.join(CAPTURAS, 'fotos-vender.png'), fullPage: true });
    // Inventario (existencias)
    paso = 'existencias';
    await p.goto(URL_APP + '/#/inventario/existencias');
    await p.waitForSelector(`tr[data-producto="${PROD_ID}"] .con-foto > img.foto-producto`);
    // Inicio: lo más vendido (si el cemento está entre los 5 de la semana). Perezosa: carga al acercarse a la vista.
    paso = 'inicio';
    await p.goto(URL_APP + '/#/inicio/hoy');
    await p.waitForSelector('#mas-vendido');
    await p.locator('#mas-vendido').scrollIntoViewIfNeeded();
    if (await p.locator(`[data-producto-top="${PROD_ID}"]`).count()) {
      await p.waitForSelector(`[data-producto-top="${PROD_ID}"] .con-foto > img.foto-producto`);
    } else {
      console.log('           (el cemento no está en lo más vendido de la semana: no se revisa Inicio)');
    }
    // Ya vistas: la miniatura se bajó UNA sola vez en toda la visita (caché).
    afirmar(bajadas <= 1, 'la miniatura se bajó ' + bajadas + ' veces');
    await ctx.close();
  });

  await prueba('rol sin productos.editar (vendedor): ve la foto pero no tiene botón de subir, y el servidor no lo deja subir', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'vendedor@demo.hn');
    await abrirProducto(p, PRODUCTO);
    await p.waitForSelector('#foto-ficha.con-foto');
    afirmar(await p.locator('#foto-tomar, #foto-elegir, #foto-quitar, #foto-archivo').count() === 0, 'el vendedor tiene botones para subir o quitar la foto');
    // Directo al Storage con su token: 403. Y no puede borrar la foto del dueño.
    const r = await p.evaluate(async ({ e, prod, ruta }) => {
      const api = await import('./js/api.js');
      const out = {};
      try { await api.subirArchivo('fotos-productos', `${e}/${prod}/aaaaaaaaaaaa.webp`, new Blob([new Uint8Array(100)], { type: 'image/webp' })); out.subir = 'paso'; }
      catch (err) { out.subir = err.http + ' ' + err.clave; }
      try { await api.borrarArchivo('fotos-productos', ruta); out.borrar = 'paso'; } catch (err) { out.borrar = String(err.http); }
      return out;
    }, { e: EMPRESA, prod: PROD_ID, ruta: rutaMediana });
    afirmar(r.subir === '403 SIN_PERMISO', 'el vendedor pudo subir: ' + r.subir);
    afirmar(r.borrar === '404', 'el vendedor pudo borrar: ' + r.borrar);
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos')`) === '2', 'cambió el Storage');
    await ctx.close();
  });

  await prueba('el Storage del emulador revisa tipo y tamaño del bucket y la carpeta de la empresa (SVG, 2 MB, producto ajeno)', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    const r = await p.evaluate(async ({ e, prod }) => {
      const api = await import('./js/api.js');
      const prueba = async (ruta, blob) => { try { await api.subirArchivo('fotos-productos', ruta, blob); return 'paso'; } catch (err) { return String(err.http); } };
      return {
        svg: await prueba(`${e}/${prod}/bbbbbbbbbbbb.webp`, new Blob(['<svg/>'], { type: 'image/svg+xml' })),
        grande: await prueba(`${e}/${prod}/cccccccccccc.webp`, new Blob([new Uint8Array(2 * 1024 * 1024)], { type: 'image/webp' })),
        ajeno: await prueba(`${crypto.randomUUID()}/${prod}/dddddddddddd.webp`, new Blob([new Uint8Array(10)], { type: 'image/webp' })),
        sinProducto: await prueba(`${e}/${crypto.randomUUID()}/eeeeeeeeeeee.webp`, new Blob([new Uint8Array(10)], { type: 'image/webp' })),
      };
    }, { e: EMPRESA, prod: PROD_ID });
    afirmar(r.svg === '415' && r.grande === '413' && r.ajeno === '403' && r.sinProducto === '403', 'respuestas: ' + JSON.stringify(r));
    await ctx.close();
  });

  await prueba('sin internet: la foto ya vista se sigue viendo y subir otra dice "necesita internet"', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await abrirProducto(p, PRODUCTO);
    await p.waitForSelector('#foto-ficha.con-foto');
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.waitForSelector('#buscar-producto');
    await ctx.setOffline(true);
    // Vender sin red: la lista de productos está en memoria y la miniatura sale de la caché.
    await p.fill('#buscar-producto', 'cemento');
    await p.waitForSelector('.resultado-producto .con-foto > img.foto-producto');
    // La caché del navegador también la tiene (sin red).
    const ok = await p.evaluate(async ({ e, ruta }) => {
      const c = await caches.open('fotos-' + e);
      const r = await c.match(new URL('__fotos__/' + ruta, location.href).href);
      return Boolean(r) && (await r.blob()).size > 0;
    }, { e: EMPRESA, ruta: rutaMediana });
    afirmar(ok, 'la foto no está en la caché del navegador');
    await ctx.setOffline(false);
    await abrirProducto(p, PRODUCTO);
    await p.waitForSelector('#foto-elegir');
    await ctx.setOffline(true);
    await p.setInputFiles('#foto-archivo', { name: 'cemento2.jpg', mimeType: 'image/jpeg', buffer: fotoGrande });
    await p.waitForSelector('#seccion-foto .mensaje-error');
    afirmar((await p.locator('#seccion-foto .mensaje-error').innerText()).includes('necesita internet'), 'no dijo que necesita internet');
    await ctx.setOffline(false);
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos')`) === '2', 'se subió algo sin internet');
    await ctx.close();
  });

  await prueba('celular (390 px): Productos, la ficha con foto y Vender sin desbordes', async () => {
    const { ctx, p } = await nueva({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await entrar(p, 'dueno@demo.hn');
    await p.goto(URL_APP + '/#/inventario/productos');
    await p.waitForSelector(`[data-producto="${PROD_ID}"] .con-foto > img.foto-producto`);
    afirmar(await anchoPagina(p) <= 390, 'Productos se sale a lo ancho: ' + await anchoPagina(p));
    await p.getByRole('button', { name: `Ver ${PRODUCTO}` }).click();
    await p.waitForSelector('#foto-ficha.con-foto');
    afirmar(await anchoPagina(p) <= 390, 'la ficha se sale a lo ancho: ' + await anchoPagina(p));
    const caja = await p.locator('#foto-ficha').boundingBox();
    afirmar(caja.width <= 390 - 16, 'la foto no cabe: ' + caja.width);
    for (const b of await p.locator('#seccion-foto .boton').all()) {
      const r = await b.boundingBox();
      afirmar(r.height >= 44, 'botón de foto de menos de 44 px');
    }
    await p.screenshot({ path: path.join(CAPTURAS, 'fotos-celular-ficha.png'), fullPage: true });
    await p.goto(URL_APP + '/#/vender/nueva');
    await p.fill('#buscar-producto', 'cemento');
    await p.waitForSelector('.resultado-producto .con-foto > img.foto-producto');
    await p.locator('.resultado-producto').first().click();
    await p.waitForSelector('.linea-carrito .con-foto > img.foto-producto');
    afirmar(await anchoPagina(p) <= 390, 'Vender se sale a lo ancho: ' + await anchoPagina(p));
    await p.screenshot({ path: path.join(CAPTURAS, 'fotos-celular-vender.png'), fullPage: true });
    await ctx.close();
  });

  await prueba('cambiar y quitar la foto: el historial guarda la anterior; sin foto vuelve el ícono; al salir se borra la caché', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await abrirProducto(p, PRODUCTO);
    paso = 'quitar';
    await p.waitForSelector('#foto-quitar');
    await p.click('#foto-quitar');
    await p.waitForSelector('dialog.dialogo[open]');
    await p.click('#confirmar-si');
    await p.waitForSelector('#avisos .mensaje-ok:has-text("Foto quitada")');
    await p.waitForSelector('#seccion-foto #sin-foto');
    afirmar(sql('dueno@demo.hn', `(SELECT foto_ruta IS NULL FROM public.producto WHERE id = '${PROD_ID}')`) === 'true', 'no se quitó');
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM public.producto_foto WHERE producto_id = '${PROD_ID}' AND foto_ruta IS NULL AND anterior_foto_ruta = '${rutaMediana}')`) === '1',
      'el historial no guardó la foto anterior');
    paso = 'lista sin foto';
    await p.getByRole('button', { name: 'Volver a la lista' }).click();
    await p.waitForSelector(`[data-producto="${PROD_ID}"] .burbuja-foto .icono`);
    afirmar(await p.locator(`[data-producto="${PROD_ID}"] img`).count() === 0, 'sin foto sigue mostrando una imagen');
    // Volver a poner la MISMA foto (mismo nombre: el archivo ya estaba, no da error).
    paso = 'misma foto otra vez';
    await abrirProducto(p, PRODUCTO);
    await p.setInputFiles('#foto-archivo', { name: 'cemento.jpg', mimeType: 'image/jpeg', buffer: fotoGrande });
    await p.waitForSelector('#avisos .mensaje-ok:has-text("Foto guardada")', { timeout: 20000 });
    afirmar(sql('dueno@demo.hn', `(SELECT foto_ruta FROM public.producto WHERE id = '${PROD_ID}')`) === rutaMediana, 'no volvió la misma foto');
    // Salir: la caché de fotos se borra.
    paso = 'salir';
    await p.getByRole('button', { name: 'Salir' }).click();
    await p.waitForSelector('#correo');
    const quedan = await p.evaluate(async () => (await caches.keys()).filter((k) => k.startsWith('fotos-')));
    afirmar(quedan.length === 0, 'quedó caché de fotos al salir: ' + quedan.join(', '));
    await ctx.close();
  });

  await prueba('respuesta perdida al guardar la ruta: la app pregunta al servidor y NO borra lo subido; un error claro sí lo borra', async () => {
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    const objetos = () => Number(sql('dueno@demo.hn', `(SELECT count(*) FROM storage.objects WHERE bucket_id = 'fotos-productos')`));
    const antes = objetos();
    // 1) El servidor guarda, pero la respuesta no llega (dos veces: la app reintenta con el mismo id_operacion).
    paso = 'respuesta perdida';
    let llamadas = 0;
    await p.route('**/rest/v1/rpc/poner_foto_producto', async (route) => { llamadas++; await route.fetch(); await route.abort('connectionreset'); });
    await abrirProducto(p, PRODUCTO);
    await p.setInputFiles('#foto-archivo', { name: 'otra.jpg', mimeType: 'image/jpeg', buffer: fotoOtra });
    await p.waitForSelector('#avisos .mensaje-ok:has-text("Foto guardada")', { timeout: 30000 });
    afirmar(llamadas === 2, 'se esperaban 2 intentos con el mismo id, hubo ' + llamadas);
    const r = JSON.parse(sql('dueno@demo.hn', `(SELECT json_build_object('r', foto_ruta, 'n', (SELECT count(*) FROM public.producto_foto f WHERE f.producto_id = p.id))
      FROM public.producto p WHERE id = '${PROD_ID}')`));
    afirmar(r.r && r.r !== rutaMediana, 'la ruta nueva no quedó en el producto');
    afirmar(objetos() === antes + 2, 'se borraron (o faltan) los archivos subidos: ' + objetos());
    afirmar(sql('dueno@demo.hn', `(SELECT count(*) FROM public.producto_foto WHERE producto_id = '${PROD_ID}' AND foto_ruta = '${r.r}')`) === '1', 'el reintento duplicó el historial');
    await p.unroute('**/rest/v1/rpc/poner_foto_producto');
    // 2) El servidor contesta un error claro: se borran los archivos recién subidos.
    paso = 'error claro';
    await p.route('**/rest/v1/rpc/poner_foto_producto', (route) => route.fulfill({ status: 400, contentType: 'application/json',
      body: JSON.stringify({ code: 'P0001', message: 'FOTO_INVALIDA: prueba de error claro.' }) }));
    await p.waitForSelector('#foto-archivo');   // sigue en la ficha (se volvió a dibujar al guardar)
    await p.setInputFiles('#foto-archivo', { name: 'tercera.jpg', mimeType: 'image/jpeg', buffer: fotoTercera });
    await p.waitForSelector('#seccion-foto .mensaje-error', { timeout: 30000 });
    for (let i = 0; i < 20 && objetos() !== antes + 2; i++) await p.waitForTimeout(200);
    afirmar(objetos() === antes + 2, 'con un error claro no se borraron los archivos recién subidos: ' + objetos());
    afirmar(sql('dueno@demo.hn', `(SELECT foto_ruta FROM public.producto WHERE id = '${PROD_ID}')`) === r.r, 'cambió la foto con un error');
    await p.unroute('**/rest/v1/rpc/poner_foto_producto');
    // Deja la foto de antes (las pruebas de abajo la usan).
    sqlEscribir('dueno@demo.hn', `SELECT public.poner_foto_producto(demo.id('EMPRESA'), demo.id('CEM'),
      jsonb_build_object('ruta', '${rutaMediana}', 'miniatura', '${rutaMini}'), gen_random_uuid())`);
    await ctx.close();
  });

  await prueba('núcleo 0.16.0 (mi_perfil sin "fotos_productos"): la app no se rompe y oculta las fotos', async () => {
    const { ctx, p } = await nueva();
    await p.route('**/rest/v1/rpc/mi_perfil', async (route) => {
      const r = await route.fetch();
      const j = await r.json();
      if (j && j.empresa) delete j.empresa.fotos_productos;
      await route.fulfill({ response: r, json: j });
    });
    await entrar(p, 'dueno@demo.hn');
    await abrirProducto(p, PRODUCTO);
    afirmar(await p.locator('#seccion-foto, img').count() === 0, 'con núcleo viejo se ven fotos');
    await p.goto(URL_APP + '/#/ajustes/negocio');
    await p.waitForSelector('#t-neg');
    afirmar(await p.locator('#tarjeta-fotos').count() === 0, 'con núcleo viejo sale el interruptor');
    await ctx.close();
  });

  await prueba('apagar las fotos: no se ve ninguna aunque el producto tenga foto', async () => {
    sqlEscribir('dueno@demo.hn', `SELECT public.activar_fotos_productos(demo.id('EMPRESA'), false, 'Prueba: apagar al final')`);
    const { ctx, p } = await nueva();
    await entrar(p, 'dueno@demo.hn');
    await p.goto(URL_APP + '/#/inventario/productos');
    await p.waitForSelector(`[data-producto="${PROD_ID}"]`);
    afirmar(await p.locator('img').count() === 0, 'con las fotos apagadas se ve una imagen');
    const r = await p.evaluate(async (ruta) => {
      const api = await import('./js/api.js');
      try { await api.bajarArchivo('fotos-productos', ruta); return 'paso'; } catch (err) { return String(err.http); }
    }, rutaMediana);
    afirmar(r === '404', 'con las fotos apagadas el servidor igual entrega la foto: ' + r);
    await ctx.close();
  });

  await prueba('sin errores de JavaScript en las páginas', async () => {
    afirmar(erroresJs.length === 0, erroresJs.join(' | '));
  });

  await nav.close();
  console.log();
  console.log(fallas ? `RESULTADO: FALLA (${total - fallas} de ${total} pasaron)` : `RESULTADO: TODO OK (${total} de ${total} pruebas de fotos pasaron)`);
  process.exit(fallas ? 1 : 0);
})().catch((e) => { console.error('FALLA:', e); process.exit(1); });
