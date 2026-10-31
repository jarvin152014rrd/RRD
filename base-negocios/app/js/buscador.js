// Buscador general (app 0.15.0, idea del "Buscar..." de RRD): desde cualquier pantalla busca
//   * pantallas del programa (por su nombre y por palabras comunes: "arqueo", "cuentas por cobrar"...),
//   * productos (precio a la vista) y clientes,
// SOLO entre lo que el usuario puede ver (el menú ya viene filtrado por módulos y permisos).
// Se abre con el botón de la lupa o con Ctrl+K. Flechas + Enter para elegir.
import { h, icono } from './ui.js';
import { hayEnMenu } from './menu.js';
import { productos, clientes, filtrar } from './datos.js';
import { dinero } from './formato.js';
import { modoSinInternet } from './sesion.js';

// Palabras con que la gente busca una pantalla aunque no sea su nombre (ruta -> palabras).
const CLAVES = {
  'inicio/hoy': 'tablero resumen dashboard hoy',
  'inicio/pendientes': 'alertas avisos aprobar aprobaciones campanita',
  'vender/nueva': 'venta factura cobrar caja registradora pos',
  'vender/ventas': 'historial facturas del dia anular venta reimprimir',
  'vender/cotizaciones': 'presupuesto proforma cotizar',
  'vender/apartados': 'separar reservar abono apartado',
  'vender/devoluciones': 'devolver cambio nota de credito',
  'vender/garantias': 'reclamo garantia',
  'caja/turno': 'arqueo abrir caja cerrar caja fondo de caja cuadrar caja turno',
  'caja/cobros': 'abono cobrar a un cliente pago de cliente',
  'caja/gasto': 'caja chica gasto pagar recibo',
  'caja/depositos': 'meter efectivo sacar efectivo retiro',
  'clientes/lista': 'cliente rtn telefono',
  'clientes/me_deben': 'credito cuentas por cobrar cxc deuda morosos estado de cuenta',
  'inventario/productos': 'producto articulo precio codigo de barras catalogo',
  'inventario/existencias': 'stock bodega cuanto hay agotado bajo minimo',
  'inventario/conteo': 'inventario fisico contar ajuste',
  'inventario/movimientos': 'kardex entradas salidas',
  'inventario/traslados': 'mover entre bodegas sucursales',
  'compras/compras': 'compra factura de proveedor mercaderia',
  'compras/proveedores': 'proveedor',
  'compras/pagos': 'cuentas por pagar cxp deuda proveedor pagar',
  'dinero/donde': 'saldo bancos efectivo cuanto dinero tengo',
  'dinero/gastos': 'gasto egresos salidas',
  'dinero/depositos': 'deposito banco traslado de dinero',
  'dinero/pagos_fijos': 'alquiler luz agua internet planilla recurrente',
  'dinero/fondos': 'socios utilidades reparto aporte capital',
  'dinero/transferencias': 'transferencia por confirmar',
  'dinero/banco': 'conciliacion estado de cuenta bancario cuadrar banco',
  'dinero/proyeccion': 'flujo de caja futuro',
  'reportes/gane': 'utilidad ganancia perdida estado de resultados',
  'reportes/ventas': 'reporte de ventas',
  'reportes/valorizado': 'valor del inventario costo',
  'reportes/empleados': 'comisiones vendedores',
  'reportes/antiguedad': 'saldos vencidos morosidad',
  'reportes/bitacora': 'auditoria quien hizo que historial de cambios',
  'reportes/cierre': 'cierre de mes contabilidad',
  'ajustes/negocio': 'logo colores nombre comercial marca',
  'ajustes/usuarios': 'empleados permisos roles contrasena',
  'ajustes/cajas': 'cajas bancos cuentas',
  'ajustes/impuestos': 'isv cai sar factura impuestos',
  'ajustes/reglas': 'topes limites descuentos aprobacion',
  'ajustes/excel': 'importar exportar respaldo copia descargar mis datos',
  'ajustes/sin_internet': 'offline sin conexion',
};

let menuActual = () => [];
export function usarMenu(fn) { menuActual = fn; }

// Tras ir a Productos o Clientes, escribe lo buscado en su cuadro de búsqueda (cuando la pantalla aparece).
function llenarCuando(selector, texto) {
  const fin = Date.now() + 8000;
  const probar = () => {
    const el = document.querySelector(selector);
    if (el) { el.value = texto; el.dispatchEvent(new Event('input', { bubbles: true })); el.focus(); return; }
    if (Date.now() < fin) setTimeout(probar, 120);
  };
  setTimeout(probar, 60);
}
// Si ya está en esa pantalla NO se vuelve a abrir (en Vender se perdería la venta que está armando): solo se escribe
// lo buscado en su cuadro de búsqueda.
function ir(ruta, selector = null, texto = '') {
  if (location.hash !== ruta) location.hash = ruta;
  if (selector) llenarCuando(selector, texto);
}

function pantallas(menu) {
  const lista = [];
  for (const p of menu) for (const s of p.subs) {
    const ruta = `${p.id}/${s.id}`;
    lista.push({ ruta, titulo: s.titulo, grupo: p.titulo, icono: s.icono || p.icono, buscar: `${s.titulo} ${p.titulo} ${CLAVES[ruta] || ''}` });
  }
  return lista;
}

export function abrirBuscador() {
  if (document.getElementById('buscador')) return;
  const menu = menuActual();
  const verProductos = !modoSinInternet() && (hayEnMenu(menu, 'inventario', 'productos') || hayEnMenu(menu, 'vender', 'nueva'));
  const verClientes = !modoSinInternet() && hayEnMenu(menu, 'clientes', 'lista');
  const fuentes = { pantallas: pantallas(menu), productos: null, clientes: null };
  if (verProductos) productos().then((x) => { fuentes.productos = x; pintar(); }).catch(() => { fuentes.productos = []; });
  if (verClientes) clientes().then((x) => { fuentes.clientes = (x || []).filter((c) => c.activo !== false); pintar(); }).catch(() => { fuentes.clientes = []; });

  // type text (no search): en un cuadro de búsqueda, Esc solo borra lo escrito y no cerraría la ventana.
  const campo = h('input', { type: 'text', id: 'buscador-campo', autocomplete: 'off', enterkeyhint: 'search', role: 'combobox',
    'aria-expanded': 'true', 'aria-controls': 'buscador-lista', 'aria-autocomplete': 'list',
    placeholder: verProductos || verClientes ? 'Pantalla, producto o cliente…' : 'Buscar una pantalla…', 'aria-label': 'Buscar en el programa' });
  const listaEl = h('div', { id: 'buscador-lista', class: 'buscador-lista', role: 'listbox', 'aria-label': 'Resultados' });
  let opciones = [];
  let activa = 0;

  function opcion(o, i) {
    return h('div', { class: 'buscador-opcion', role: 'option', id: `buscador-op-${i}`, 'aria-selected': i === activa ? 'true' : 'false',
      dataset: { tipo: o.tipo }, onclick: () => elegir(o), onmousemove: () => { if (activa !== i) { activa = i; marcar(); } } },
    h('span', { class: `burbuja burbuja-chica burbuja-${o.color}` }, icono(o.icono)),
    h('span', { class: 'buscador-texto' }, h('span', { class: 'buscador-titulo' }, o.titulo), o.detalle ? h('span', { class: 'buscador-detalle' }, o.detalle) : null),
    o.derecha || null);
  }
  function marcar() {
    [...listaEl.querySelectorAll('.buscador-opcion')].forEach((el, i) => el.setAttribute('aria-selected', i === activa ? 'true' : 'false'));
    const el = document.getElementById(`buscador-op-${activa}`);
    if (el) { campo.setAttribute('aria-activedescendant', el.id); el.scrollIntoView({ block: 'nearest' }); }
  }
  function pintar() {
    const q = campo.value.trim();
    const pant = (q ? filtrar(fuentes.pantallas, q, ['buscar']) : fuentes.pantallas.slice(0, 8)).slice(0, 8)
      .map((x) => ({ tipo: 'pantalla', icono: x.icono, color: 'azul', titulo: x.titulo, detalle: x.grupo, ruta: x.ruta }));
    const prods = q && fuentes.productos ? filtrar(fuentes.productos, q, ['nombre', 'codigo', 'codigo_barras']).slice(0, 6)
      .map((p) => ({ tipo: 'producto', icono: p.tipo === 'servicio' ? 'servicio' : 'etiqueta', color: 'dorado', titulo: p.nombre,
        detalle: [p.codigo, p.categoria].filter(Boolean).join(' · '), derecha: h('span', { class: 'monto buscador-precio' }, dinero(p.precio_venta_centavos)), dato: p })) : [];
    const clis = q && fuentes.clientes ? filtrar(fuentes.clientes, q, ['nombre', 'rtn', 'telefono', 'codigo']).slice(0, 6)
      .map((c) => ({ tipo: 'cliente', icono: 'usuario', color: 'verde', titulo: c.nombre,
        detalle: [c.rtn ? `RTN ${c.rtn}` : null, c.telefono].filter(Boolean).join(' · ') || 'Cliente', dato: c })) : [];
    const grupos = [['Pantallas', pant], ['Productos', prods], ['Clientes', clis]].filter(([, x]) => x.length);
    opciones = grupos.flatMap(([, x]) => x);
    if (activa >= opciones.length) activa = 0;
    let i = 0;
    listaEl.replaceChildren(...grupos.map(([nombre, x]) => h('div', { class: 'buscador-grupo', role: 'group', 'aria-label': nombre },
      h('p', { class: 'buscador-grupo-titulo', 'aria-hidden': 'true' }, nombre), x.map((o) => opcion(o, i++)))));
    if (!opciones.length) listaEl.append(h('p', { class: 'vacio buscador-vacio' }, `No hay nada con "${q}".`));
    else if (q && ((verProductos && !fuentes.productos) || (verClientes && !fuentes.clientes))) listaEl.append(h('p', { class: 'ayuda buscador-vacio' }, 'Buscando también en productos y clientes…'));
    marcar();
  }
  function elegir(o) {
    cerrar();
    if (o.tipo === 'pantalla') ir(`#/${o.ruta}`);
    else if (o.tipo === 'producto') {
      if (hayEnMenu(menu, 'inventario', 'productos')) ir('#/inventario/productos', '#buscar-producto-inv', o.dato.codigo || o.dato.nombre);
      else ir('#/vender/nueva', '#buscar-producto', o.dato.codigo || o.dato.nombre);
    } else if (o.tipo === 'cliente') ir('#/clientes/lista', '#buscar-cliente', o.dato.nombre);
  }
  campo.addEventListener('input', () => { activa = 0; pintar(); });
  campo.addEventListener('keydown', (ev) => {
    if (ev.key === 'ArrowDown') { ev.preventDefault(); if (opciones.length) { activa = (activa + 1) % opciones.length; marcar(); } }
    else if (ev.key === 'ArrowUp') { ev.preventDefault(); if (opciones.length) { activa = (activa - 1 + opciones.length) % opciones.length; marcar(); } }
    else if (ev.key === 'Enter') { ev.preventDefault(); if (opciones[activa]) elegir(opciones[activa]); }
    else if (ev.key === 'Escape') { ev.preventDefault(); cerrar(); }
  });
  const dlg = h('dialog', { class: 'dialogo dialogo-buscador', id: 'buscador', 'aria-label': 'Buscar en el programa' },
    h('div', { class: 'buscador-cabeza' }, icono('buscar'), campo,
      h('button', { type: 'button', class: 'boton buscador-cerrar', 'aria-label': 'Cerrar', onclick: () => cerrar() }, icono('cerrar'))),
    listaEl,
    h('p', { class: 'buscador-pie' }, 'Flechas para moverse · Enter para abrir · Esc para cerrar'));
  dlg.addEventListener('close', () => dlg.remove());
  dlg.addEventListener('click', (ev) => { if (ev.target === dlg) cerrar(); });   // clic fuera
  function cerrar() { if (dlg.open) dlg.close(); }
  document.body.append(dlg);
  dlg.showModal();
  pintar();
  campo.focus();
}

// Botón de la lupa para el encabezado.
export function botonBuscador() {
  return h('button', { type: 'button', class: 'boton-buscar', id: 'boton-buscar', 'aria-label': 'Buscar en el programa (Ctrl+K)', onclick: () => abrirBuscador() },
    icono('buscar'), h('span', { class: 'boton-buscar-texto' }, 'Buscar…'), h('kbd', { class: 'boton-buscar-tecla' }, 'Ctrl K'));
}

// Atajo: Ctrl+K (o Cmd+K). Sin "/" a propósito: un lector de códigos puede mandar "/" y abriría el buscador.
// No se abre encima de otra ventana (pedir motivo, confirmar...): primero se termina o cierra esa.
document.addEventListener('keydown', (ev) => {
  if (!document.getElementById('boton-buscar')) return;   // sin sesión (pantalla de entrar)
  if ((ev.ctrlKey || ev.metaKey) && (ev.key === 'k' || ev.key === 'K')) {
    ev.preventDefault();
    if (!document.querySelector('dialog[open]')) abrirBuscador();
  }
});
