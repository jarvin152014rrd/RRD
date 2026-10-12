// Menú por pestañas y subpestañas. Se arma SOLO con lo que el usuario puede usar:
// módulos activos + permisos de mi_perfil. Nada gris ni bloqueado: lo que no puede, no sale.
// Ajustes siempre al final. Para agregar una pantalla: una línea aquí (ver app/LEEME.md).
//   modulos: basta UNO activo   permisos: basta UNO   pantalla: archivo en js/pantallas/
import { puede, tieneModulo } from './sesion.js';

export const MENU = [
  { id: 'inicio', titulo: 'Inicio', subs: [
    { id: 'hoy', titulo: 'Mi negocio hoy', pantalla: 'inicio' },
    { id: 'alertas', titulo: 'Alertas', pantalla: 'alertas' },
    { id: 'aprobaciones', titulo: 'Aprobaciones', pantalla: 'aprobaciones', permisos: ['aprobaciones.ver'] },
  ] },
  { id: 'vender', titulo: 'Vender', subs: [
    { id: 'nueva', titulo: 'Nueva venta', modulos: ['ventas'], permisos: ['ventas.vender'] },
    { id: 'cotizaciones', titulo: 'Cotizaciones', modulos: ['ventas'], permisos: ['ventas.cotizar'] },
    { id: 'apartados', titulo: 'Apartados', modulos: ['apartados'], permisos: ['apartados.registrar'] },
    { id: 'devoluciones', titulo: 'Devoluciones', modulos: ['ventas'], permisos: ['ventas.devolver'] },
    { id: 'ventas', titulo: 'Ventas hechas', modulos: ['ventas'], permisos: ['ventas.ver'] },
  ] },
  { id: 'caja', titulo: 'Caja', subs: [
    { id: 'turno', titulo: 'Mi turno', modulos: ['dinero'], permisos: ['caja.turno'] },
    { id: 'conteo', titulo: 'Conteo de caja', modulos: ['dinero'], permisos: ['caja.turno'] },
    { id: 'cobros', titulo: 'Cobrar a clientes', modulos: ['ventas'], permisos: ['ventas.cobrar'] },
    { id: 'cajas', titulo: 'Cajas abiertas', modulos: ['dinero'], permisos: ['caja.supervisar'] },
  ] },
  { id: 'clientes', titulo: 'Clientes', subs: [
    { id: 'lista', titulo: 'Clientes', permisos: ['terceros.ver'] },
    { id: 'me-deben', titulo: 'Quién me debe', modulos: ['ventas'], permisos: ['ventas.ver'] },
  ] },
  { id: 'inventario', titulo: 'Inventario', subs: [
    { id: 'productos', titulo: 'Productos y precios', modulos: ['inventario', 'ventas'], permisos: ['inventario.ver', 'productos.editar'] },
    { id: 'existencias', titulo: 'Existencias', modulos: ['inventario'], permisos: ['inventario.ver'] },
    { id: 'conteo', titulo: 'Conteo de mercadería', modulos: ['inventario'], permisos: ['inventario.ajustar'] },
    { id: 'traslados', titulo: 'Traslados', modulos: ['inventario'], permisos: ['inventario.trasladar'] },
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
    { id: 'mi-cuenta', titulo: 'Mi cuenta' },
    { id: 'usuarios', titulo: 'Usuarios', permisos: ['usuarios.administrar'] },
    { id: 'negocio', titulo: 'Mi negocio', permisos: ['empresa.configurar'] },
    { id: 'mis-alertas', titulo: 'Alertas que recibo' },
    { id: 'plan', titulo: 'Plan y límites', permisos: ['proveedor.solicitar'] },
  ] },
];

function visible(item) {
  return (!item.modulos || tieneModulo(...item.modulos)) && (!item.permisos || puede(...item.permisos));
}

// Menú del usuario actual: solo pestañas con al menos una subpestaña permitida.
export function menuDelUsuario() {
  return MENU.map((p) => ({ ...p, subs: p.subs.filter(visible) })).filter((p) => p.subs.length > 0);
}

// Botones de la barra inferior del celular (solo los permitidos; "Más" siempre).
export function botonesCelular(menu) {
  const hay = (pid, sid) => menu.some((p) => p.id === pid && p.subs.some((s) => s.id === sid));
  const lista = [{ id: 'resumen', titulo: 'Resumen', ruta: '#/inicio/hoy', icono: 'resumen', pestana: 'inicio' }];
  if (hay('vender', 'nueva')) lista.push({ id: 'vender', titulo: 'Vender', ruta: '#/vender/nueva', icono: 'vender', pestana: 'vender' });
  if (hay('inventario', 'productos')) lista.push({ id: 'buscar', titulo: 'Buscar', ruta: '#/buscar', icono: 'buscar', pestana: 'buscar' });
  lista.push({ id: 'mas', titulo: 'Más', ruta: '#/mas', icono: 'mas', pestana: 'mas' });
  return lista;
}
