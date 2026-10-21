// Menú de la app como DATOS puros (sin importar nada): lo usan la app (js/menu.js) y la
// vista previa del Armador del proveedor, así los dos muestran exactamente lo mismo.
//   modulos: basta UNO activo   permisos: basta UNO   todos: hacen falta TODOS   pantalla: archivo en js/pantallas/
// Palabras del rubro (config.palabras del cliente): cambian SOLO los títulos, nunca qué se ve.
//   { "vender": "Órdenes de trabajo", "vender/nueva": "Nueva orden de trabajo", "barra/vender": "Orden" }
//   clave "pestana" = título de la pestaña; "pestana/sub" = título de la subpestaña;
//   "barra/<boton>" = botón de la barra del celular (inicio, vender, caja, productos).
//   icono: nombre de un ícono de js/iconos.js (todas las pestañas y subpestañas llevan uno).
//   contador: "pendientes" = la subpestaña muestra el número de pendientes.

export const MENU = [
  // Cada pestaña responde UNA pregunta. icono: nombre de js/iconos.js (lo revisa la prueba de la app).
  // Inicio: ¿cómo voy hoy?
  { id: 'inicio', titulo: 'Inicio', icono: 'inicio', subs: [
    { id: 'hoy', titulo: 'Mi negocio hoy', icono: 'sol', pantalla: 'inicio' },
    // Une las alertas y las aprobaciones (las aprobaciones solo salen con aprobaciones.ver).
    { id: 'pendientes', titulo: 'Pendientes', icono: 'pendientes', pantalla: 'pendientes', contador: 'pendientes' },
  ] },
  { id: 'vender', titulo: 'Vender', icono: 'vender', subs: [
    { id: 'nueva', titulo: 'Nueva venta', icono: 'mas', modulos: ['ventas'], permisos: ['ventas.vender'], pantalla: 'vender' },
    { id: 'ventas', titulo: 'Ventas del día', icono: 'lista', modulos: ['ventas'], permisos: ['ventas.ver', 'ventas.vender'], pantalla: 'ventas_dia' },
    { id: 'cotizaciones', titulo: 'Cotizaciones', icono: 'documento', modulos: ['ventas'], permisos: ['ventas.cotizar'], pantalla: 'cotizaciones' },
    { id: 'apartados', titulo: 'Apartados', icono: 'bolsa', modulos: ['apartados'], permisos: ['apartados.registrar'] },
    { id: 'devoluciones', titulo: 'Devoluciones', icono: 'devolucion', modulos: ['ventas'], permisos: ['ventas.devolver'], pantalla: 'devoluciones' },
  ] },
  // Caja: mi turno (para el cajero).
  { id: 'caja', titulo: 'Caja', icono: 'caja', subs: [
    { id: 'turno', titulo: 'Mi turno', icono: 'reloj', modulos: ['dinero'], permisos: ['caja.turno'], pantalla: 'caja_turno' },
    // Cobrar necesita ver lo que deben (cobros.ver_saldos, núcleo 0.14.0; el cajero lo tiene) además de cobrar.
    { id: 'cobros', titulo: 'Cobrar', icono: 'cobrar', modulos: ['ventas'], permisos: ['ventas.cobrar'], todos: ['cobros.ver_saldos'], pantalla: 'me_deben' },
    { id: 'gasto', titulo: 'Gasto pagado de esta caja', icono: 'recibo', modulos: ['dinero'], permisos: ['gastos.registrar'], pantalla: 'caja_gasto' },
    { id: 'depositos', titulo: 'Meter o sacar efectivo', icono: 'billetes', modulos: ['dinero'], permisos: ['dinero.trasladar'], pantalla: 'caja_dinero' },
    { id: 'cajas', titulo: 'Cajas abiertas', icono: 'candado_abierto', modulos: ['dinero'], permisos: ['caja.supervisar'] },
  ] },
  { id: 'clientes', titulo: 'Clientes', icono: 'clientes', subs: [
    { id: 'lista', titulo: 'Clientes', icono: 'usuario', permisos: ['terceros.ver'], pantalla: 'clientes' },
    { id: 'me-deben', titulo: 'Quién me debe', icono: 'cobrar', modulos: ['ventas'], permisos: ['ventas.ver', 'cobros.ver_saldos'], pantalla: 'me_deben' },
  ] },
  { id: 'inventario', titulo: 'Inventario', icono: 'inventario', subs: [
    { id: 'productos', titulo: 'Productos', icono: 'etiqueta', modulos: ['inventario', 'ventas'], permisos: ['inventario.ver', 'productos.editar'], pantalla: 'inv_productos' },
    { id: 'existencias', titulo: 'Existencias', icono: 'existencias', modulos: ['inventario'], permisos: ['inventario.ver'], pantalla: 'inv_existencias' },
    // El conteo en pantalla usa la hoja "conteo_fisico" del Excel (crea ajustes pendientes de aprobación).
    { id: 'conteo', titulo: 'Conteo físico', icono: 'conteo', modulos: ['inventario'], permisos: ['inventario.ajustar'], todos: ['excel.importar'], pantalla: 'inv_conteo' },
    { id: 'movimientos', titulo: 'Movimientos', icono: 'movimientos', modulos: ['inventario'], permisos: ['inventario.costos'], pantalla: 'inv_movimientos' },
    { id: 'traslados', titulo: 'Traslados', icono: 'traslado', modulos: ['inventario'], permisos: ['inventario.trasladar'], pantalla: 'inv_traslados' },
  ] },
  { id: 'compras', titulo: 'Compras', icono: 'compras', subs: [
    { id: 'compras', titulo: 'Compras', icono: 'documento', modulos: ['compras'], permisos: ['compras.ver'], pantalla: 'compras' },
    { id: 'proveedores', titulo: 'Proveedores', icono: 'proveedor', modulos: ['compras'], permisos: ['compras.ver'], pantalla: 'compras_proveedores' },
    // Pagar necesita ver lo que se debe (v_cxp_documento pide compras.ver) además de pagar.
    { id: 'pagos', titulo: 'Pagar a proveedores', icono: 'billetes', modulos: ['compras'], permisos: ['compras.pagar'], todos: ['compras.ver'], pantalla: 'compras_pagos' },
  ] },
  // Dinero: todo el dinero (para el dueño).
  { id: 'dinero', titulo: 'Dinero', icono: 'dinero', subs: [
    { id: 'donde', titulo: '¿Dónde está mi dinero?', icono: 'banco', modulos: ['dinero'], permisos: ['dinero.ver'], pantalla: 'dinero_donde' },
    // La lista pide dinero.ver; quien solo registra ve por qué no puede (le falta ver las cajas).
    { id: 'gastos', titulo: 'Todos los gastos', icono: 'recibo', modulos: ['dinero'], permisos: ['gastos.registrar', 'dinero.ver'], pantalla: 'dinero_gastos' },
    { id: 'depositos', titulo: 'Depósitos y traslados', icono: 'deposito', modulos: ['dinero'], permisos: ['dinero.trasladar'], todos: ['dinero.ver'], pantalla: 'dinero_depositos' },
    { id: 'pagos-fijos', titulo: 'Pagos fijos', icono: 'calendario', modulos: ['dinero'], permisos: ['dinero.administrar'], todos: ['dinero.ver'], pantalla: 'dinero_pagos_fijos' },
    { id: 'fondos', titulo: 'Fondos y socios', icono: 'capas', modulos: ['fondos'], permisos: ['fondos.ver'], pantalla: 'dinero_fondos' },
    { id: 'banco', titulo: 'Cuadrar con el banco', icono: 'conciliar', modulos: ['conciliacion'], permisos: ['conciliacion.ver'], todos: ['dinero.ver'], pantalla: 'dinero_banco' },
    // proyeccion_flujo (núcleo 042) pide contabilidad.ver.
    { id: 'proyeccion', titulo: 'Proyección', icono: 'proyeccion', modulos: ['dinero'], permisos: ['contabilidad.ver'], pantalla: 'dinero_proyeccion' },
  ] },
  // Reportes: solo mirar (salvo cerrar y reabrir el mes). app 0.8.0: todas funcionando.
  { id: 'reportes', titulo: 'Reportes', icono: 'reportes', subs: [
    // estado_resultados / saldo_cuentas / balance_general piden contabilidad.ver.
    { id: 'gane', titulo: '¿Gané o perdí?', icono: 'sube', permisos: ['contabilidad.ver'], pantalla: 'rep_gane' },
    { id: 'ventas', titulo: 'Ventas', icono: 'grafica', modulos: ['ventas'], permisos: ['ventas.ver'], pantalla: 'rep_ventas' },
    // v_existencia pide inventario.ver; los valores y v_kardex, inventario.costos.
    { id: 'valorizado', titulo: 'Inventario valorizado', icono: 'inventario', modulos: ['inventario'], permisos: ['inventario.costos'], todos: ['inventario.ver'], pantalla: 'rep_valorizado' },
    // vigilancia_empleados pide bitacora.ver; v_comision, comisiones.ver (cada parte sale solo con su permiso).
    { id: 'empleados', titulo: 'Empleados y comisiones', icono: 'credencial', permisos: ['bitacora.ver', 'comisiones.ver'], pantalla: 'rep_empleados' },
    { id: 'bitacora', titulo: 'Quién hizo qué', icono: 'bitacora', permisos: ['bitacora.ver'], pantalla: 'rep_bitacora' },
    // cerrar_mes pide periodos.cerrar; leer los meses (historial_cierres, exportar_mes, libros_isv), contabilidad.ver.
    { id: 'cierre', titulo: 'Cierre de mes', icono: 'cierre', permisos: ['periodos.cerrar'], todos: ['contabilidad.ver'], pantalla: 'rep_cierre' },
  ] },
  // Siempre la última.
  { id: 'ajustes', titulo: 'Ajustes', icono: 'ajustes', final: true, subs: [
    { id: 'negocio', titulo: 'Mi negocio', icono: 'tienda', permisos: ['empresa.marca', 'empresa.configurar'], pantalla: 'aj_negocio' },
    { id: 'usuarios', titulo: 'Usuarios y permisos', icono: 'usuarios', permisos: ['usuarios.administrar'], pantalla: 'aj_usuarios' },
    { id: 'cajas', titulo: 'Cajas y bancos', icono: 'banco', modulos: ['dinero'], permisos: ['dinero.administrar'], pantalla: 'aj_cajas' },
    { id: 'impuestos', titulo: 'Impuestos', icono: 'impuestos', permisos: ['impuestos.configurar', 'productos.editar'], pantalla: 'aj_impuestos' },
    { id: 'reglas', titulo: 'Reglas y topes', icono: 'reglas', permisos: ['empresa.configurar'], pantalla: 'aj_reglas' },
    // Antes era Inventario > Excel (mismos módulos y permisos).
    { id: 'excel', titulo: 'Excel y copia de mis datos', icono: 'excel', modulos: ['inventario', 'ventas'], permisos: ['excel.importar'], pantalla: 'inv_excel' },
    // Antes "Mis datos"; "Alertas que recibo" va dentro.
    { id: 'mi-cuenta', titulo: 'Mi cuenta', icono: 'cuenta', pantalla: 'aj_datos' },
  ] },
];

// Rutas de antes (enlaces guardados, pruebas, costumbre) -> ruta nueva.
export const RUTAS_VIEJAS = {
  'inicio/alertas': 'inicio/pendientes',
  'inicio/aprobaciones': 'inicio/pendientes',
  'inventario/excel': 'ajustes/excel',
  'ajustes/mis-alertas': 'ajustes/mi-cuenta',
  'buscar': 'inventario/productos',
};

// Texto válido para un título: de 1 a 40 letras (lo demás se ignora y queda el de siempre).
function palabra(palabras, clave) {
  const v = palabras && Object.prototype.hasOwnProperty.call(palabras, clave) ? palabras[clave] : null;
  return typeof v === 'string' && v.trim().length > 0 && v.trim().length <= 40 ? v.trim() : null;
}

// Una palabra guardada con la ruta de antes (ej. "inventario/excel") sigue sirviendo en la nueva.
function palabraVieja(palabras, clave) {
  for (const [vieja, nueva] of Object.entries(RUTAS_VIEJAS)) if (nueva === clave && palabra(palabras, vieja)) return palabra(palabras, vieja);
  return null;
}

// Copia del menú con los títulos del rubro. Nunca agrega ni quita pestañas.
export function conPalabras(menu, palabras) {
  return menu.map((p) => ({
    ...p,
    titulo: palabra(palabras, p.id) || p.titulo,
    subs: p.subs.map((s) => ({ ...s, titulo: palabra(palabras, `${p.id}/${s.id}`) || palabraVieja(palabras, `${p.id}/${s.id}`) || s.titulo })),
  }));
}

// Título de un botón de la barra del celular (o el de siempre). Botones de antes: "resumen" ahora es
// "inicio" y "buscar" ahora es "productos" (sus palabras siguen sirviendo).
const BARRA_VIEJA = { inicio: 'resumen', productos: 'buscar' };
export function tituloBarra(palabras, id, normal) {
  return palabra(palabras, `barra/${id}`) || (BARRA_VIEJA[id] && palabra(palabras, `barra/${BARRA_VIEJA[id]}`)) || normal;
}

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
