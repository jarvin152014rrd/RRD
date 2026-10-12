// Menú de la app como DATOS puros (sin importar nada): lo usan la app (js/menu.js) y la
// vista previa del Armador del proveedor, así los dos muestran exactamente lo mismo.
//   modulos: basta UNO activo   permisos: basta UNO   todos: hacen falta TODOS   pantalla: archivo en js/pantallas/
// Palabras del rubro (config.palabras del cliente): cambian SOLO los títulos, nunca qué se ve.
//   { "vender": "Órdenes de trabajo", "vender/nueva": "Nueva orden de trabajo", "barra/vender": "Orden" }
//   clave "pestana" = título de la pestaña; "pestana/sub" = título de la subpestaña;
//   "barra/<boton>" = botón de la barra del celular.

export const MENU = [
  { id: 'inicio', titulo: 'Inicio', subs: [
    { id: 'hoy', titulo: 'Mi negocio hoy', pantalla: 'inicio' },
    { id: 'alertas', titulo: 'Alertas', pantalla: 'alertas' },
    { id: 'aprobaciones', titulo: 'Aprobaciones', pantalla: 'aprobaciones', permisos: ['aprobaciones.ver'] },
  ] },
  { id: 'vender', titulo: 'Vender', subs: [
    { id: 'nueva', titulo: 'Nueva venta', modulos: ['ventas'], permisos: ['ventas.vender'], pantalla: 'vender' },
    { id: 'ventas', titulo: 'Ventas del día', modulos: ['ventas'], permisos: ['ventas.ver', 'ventas.vender'], pantalla: 'ventas_dia' },
    { id: 'cotizaciones', titulo: 'Cotizaciones', modulos: ['ventas'], permisos: ['ventas.cotizar'], pantalla: 'cotizaciones' },
    { id: 'apartados', titulo: 'Apartados', modulos: ['apartados'], permisos: ['apartados.registrar'] },
    { id: 'devoluciones', titulo: 'Devoluciones', modulos: ['ventas'], permisos: ['ventas.devolver'], pantalla: 'devoluciones' },
  ] },
  { id: 'caja', titulo: 'Caja', subs: [
    { id: 'turno', titulo: 'Mi turno', modulos: ['dinero'], permisos: ['caja.turno'], pantalla: 'caja_turno' },
    { id: 'depositos', titulo: 'Depósito o retiro', modulos: ['dinero'], permisos: ['dinero.trasladar'], pantalla: 'caja_dinero' },
    { id: 'gasto', titulo: 'Gasto de caja chica', modulos: ['dinero'], permisos: ['gastos.registrar'], pantalla: 'caja_gasto' },
    // Cobrar necesita ver lo que deben (cobros.ver_saldos, núcleo 0.14.0; el cajero lo tiene) además de cobrar.
    { id: 'cobros', titulo: 'Cobrar a clientes', modulos: ['ventas'], permisos: ['ventas.cobrar'], todos: ['cobros.ver_saldos'], pantalla: 'me_deben' },
    { id: 'cajas', titulo: 'Cajas abiertas', modulos: ['dinero'], permisos: ['caja.supervisar'] },
  ] },
  { id: 'clientes', titulo: 'Clientes', subs: [
    { id: 'lista', titulo: 'Clientes', permisos: ['terceros.ver'], pantalla: 'clientes' },
    { id: 'me-deben', titulo: 'Quién me debe', modulos: ['ventas'], permisos: ['ventas.ver', 'cobros.ver_saldos'], pantalla: 'me_deben' },
  ] },
  { id: 'inventario', titulo: 'Inventario', subs: [
    { id: 'productos', titulo: 'Productos', modulos: ['inventario', 'ventas'], permisos: ['inventario.ver', 'productos.editar'], pantalla: 'inv_productos' },
    { id: 'existencias', titulo: 'Existencias', modulos: ['inventario'], permisos: ['inventario.ver'], pantalla: 'inv_existencias' },
    // El conteo en pantalla usa la hoja "conteo_fisico" del Excel (crea ajustes pendientes de aprobación).
    { id: 'conteo', titulo: 'Conteo físico', modulos: ['inventario'], permisos: ['inventario.ajustar'], todos: ['excel.importar'], pantalla: 'inv_conteo' },
    { id: 'movimientos', titulo: 'Movimientos', modulos: ['inventario'], permisos: ['inventario.costos'], pantalla: 'inv_movimientos' },
    { id: 'traslados', titulo: 'Traslados', modulos: ['inventario'], permisos: ['inventario.trasladar'], pantalla: 'inv_traslados' },
    { id: 'excel', titulo: 'Excel', modulos: ['inventario', 'ventas'], permisos: ['excel.importar'], pantalla: 'inv_excel' },
  ] },
  { id: 'compras', titulo: 'Compras', subs: [
    { id: 'compras', titulo: 'Compras', modulos: ['compras'], permisos: ['compras.ver'] },
    { id: 'proveedores', titulo: 'Proveedores', modulos: ['compras'], permisos: ['compras.ver'] },
    { id: 'pagos', titulo: 'Pagar a proveedores', modulos: ['compras'], permisos: ['compras.pagar'] },
  ] },
  { id: 'dinero', titulo: 'Dinero', subs: [
    { id: 'donde', titulo: '¿Dónde está mi dinero?', modulos: ['dinero'], permisos: ['dinero.ver'] },
    { id: 'gastos', titulo: 'Gastos', modulos: ['dinero'], permisos: ['gastos.registrar'] },
    { id: 'depositos', titulo: 'Depósitos y traslados', modulos: ['dinero'], permisos: ['dinero.trasladar'] },
    { id: 'pagos-fijos', titulo: 'Pagos fijos', modulos: ['dinero'], permisos: ['dinero.administrar'] },
    { id: 'banco', titulo: 'Cuadrar con el banco', modulos: ['conciliacion'], permisos: ['conciliacion.ver'] },
    { id: 'fondos', titulo: 'Fondos y socios', modulos: ['fondos'], permisos: ['fondos.ver'] },
  ] },
  { id: 'reportes', titulo: 'Reportes', subs: [
    { id: 'gane', titulo: '¿Gané o perdí?', permisos: ['contabilidad.ver'] },
    { id: 'cierre', titulo: 'Cierre de mes', permisos: ['periodos.cerrar'] },
    { id: 'empleados', titulo: 'Empleados', permisos: ['bitacora.ver'] },
    { id: 'bitacora', titulo: 'Quién hizo qué', permisos: ['bitacora.ver'] },
  ] },
  // Siempre la última.
  { id: 'ajustes', titulo: 'Ajustes', final: true, subs: [
    { id: 'negocio', titulo: 'Mi negocio', permisos: ['empresa.marca', 'empresa.configurar'], pantalla: 'aj_negocio' },
    { id: 'usuarios', titulo: 'Usuarios y permisos', permisos: ['usuarios.administrar'], pantalla: 'aj_usuarios' },
    { id: 'cajas', titulo: 'Cajas y bancos', modulos: ['dinero'], permisos: ['dinero.administrar'], pantalla: 'aj_cajas' },
    { id: 'impuestos', titulo: 'Impuestos', permisos: ['impuestos.configurar', 'productos.editar'], pantalla: 'aj_impuestos' },
    { id: 'reglas', titulo: 'Reglas y topes', permisos: ['empresa.configurar'], pantalla: 'aj_reglas' },
    { id: 'mi-cuenta', titulo: 'Mis datos', pantalla: 'aj_datos' },
    { id: 'mis-alertas', titulo: 'Alertas que recibo' },
  ] },
];

// Texto válido para un título: de 1 a 40 letras (lo demás se ignora y queda el de siempre).
function palabra(palabras, clave) {
  const v = palabras && Object.prototype.hasOwnProperty.call(palabras, clave) ? palabras[clave] : null;
  return typeof v === 'string' && v.trim().length > 0 && v.trim().length <= 40 ? v.trim() : null;
}

// Copia del menú con los títulos del rubro. Nunca agrega ni quita pestañas.
export function conPalabras(menu, palabras) {
  return menu.map((p) => ({
    ...p,
    titulo: palabra(palabras, p.id) || p.titulo,
    subs: p.subs.map((s) => ({ ...s, titulo: palabra(palabras, `${p.id}/${s.id}`) || s.titulo })),
  }));
}

// Título de un botón de la barra del celular (o el de siempre).
export function tituloBarra(palabras, id, normal) { return palabra(palabras, `barra/${id}`) || normal; }

// ¿Se ve este elemento con estos módulos y permisos? (Sets de texto)
export function visibleCon(item, modulos, permisos) {
  const algun = (lista, conjunto) => lista.some((x) => conjunto.has(x));
  return (!item.modulos || algun(item.modulos, modulos)) && (!item.permisos || algun(item.permisos, permisos))
    && (!item.todos || item.todos.every((x) => permisos.has(x)));
}

// Menú para unos módulos y permisos: solo pestañas con al menos una subpestaña permitida.
export function menuPara(modulos, permisos, palabras) {
  return conPalabras(MENU, palabras).map((p) => ({ ...p, subs: p.subs.filter((s) => visibleCon(s, modulos, permisos)) }))
    .filter((p) => p.subs.length > 0);
}
