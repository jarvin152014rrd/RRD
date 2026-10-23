// Service worker: guarda SOLO el "cascarón" (HTML, CSS, JS, íconos) para instalar
// y abrir rápido. Los datos (/rest/, /auth/) SIEMPRE van al servidor, nunca se guardan.
// Al cambiar cualquier archivo del cascarón, suba VERSION.
const VERSION = 'cascaron-0.10.0';
const CASCARON = [
  './', 'index.html', 'manifest.webmanifest', 'config.js',
  'css/tema.css', 'css/base.css', 'css/controles.css',
  'js/app.js', 'js/api.js', 'js/iconos.js', 'js/sesion.js', 'js/menu.js', 'js/menu_datos.js', 'js/formato.js', 'js/errores.js', 'js/ui.js',
  'js/datos.js', 'js/formularios.js', 'js/comprobante.js', 'js/imprimible.js', 'js/marca.js', 'js/excel.js', 'js/reportes.js', 'vendor/xlsx.bundle.js',
  'js/pantallas/entrar.js', 'js/pantallas/inicio.js', 'js/pantallas/alertas.js',
  'js/pantallas/aprobaciones.js', 'js/pantallas/pendientes.js', 'js/pantallas/en_construccion.js', 'js/pantallas/mas.js',
  'js/pantallas/dinero_donde.js', 'js/pantallas/dinero_gastos.js', 'js/pantallas/dinero_depositos.js', 'js/pantallas/dinero_pagos_fijos.js',
  'js/pantallas/dinero_fondos.js', 'js/pantallas/dinero_banco.js', 'js/pantallas/dinero_proyeccion.js',
  'js/pantallas/vender.js', 'js/pantallas/ventas_dia.js', 'js/pantallas/cotizaciones.js', 'js/pantallas/devoluciones.js',
  'js/pantallas/caja_turno.js', 'js/pantallas/caja_dinero.js', 'js/pantallas/caja_gasto.js',
  'js/pantallas/clientes.js', 'js/pantallas/me_deben.js',
  'js/pantallas/compras.js', 'js/pantallas/compras_proveedores.js', 'js/pantallas/compras_pagos.js',
  'js/pantallas/inv_productos.js', 'js/pantallas/inv_existencias.js', 'js/pantallas/inv_conteo.js', 'js/pantallas/inv_movimientos.js',
  'js/pantallas/inv_traslados.js', 'js/pantallas/inv_excel.js',
  'js/pantallas/aj_negocio.js', 'js/pantallas/aj_usuarios.js', 'js/pantallas/aj_cajas.js', 'js/pantallas/aj_impuestos.js',
  'js/pantallas/aj_reglas.js', 'js/pantallas/aj_datos.js',
  'js/pantallas/rep_gane.js', 'js/pantallas/rep_ventas.js', 'js/pantallas/rep_valorizado.js', 'js/pantallas/rep_empleados.js',
  'js/pantallas/rep_bitacora.js', 'js/pantallas/rep_cierre.js',
  'iconos/icono.svg', 'iconos/icono-192.png', 'iconos/icono-512.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(CASCARON)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;     // POST y otros sitios: directo
  if (url.pathname.includes('/rest/') || url.pathname.includes('/auth/')) return; // datos: nunca en caché
  // Cascarón: responde de la caché al instante y la actualiza por detrás.
  e.respondWith(caches.open(VERSION).then(async (cache) => {
    const guardado = await cache.match(e.request, { ignoreSearch: true });
    const deRed = fetch(e.request).then((r) => {
      if (r.ok) cache.put(e.request, r.clone());
      return r;
    }).catch(() => guardado);
    return guardado || deRed;
  }));
});
