// Menú por pestañas y subpestañas. Se arma SOLO con lo que el usuario puede usar:
// módulos activos + permisos de mi_perfil. Nada gris ni bloqueado: lo que no puede, no sale.
// La lista vive en js/menu_datos.js (datos puros que también usa el Armador del proveedor).
// Los títulos usan las palabras del rubro del cliente (config.palabras), si las hay.
import { puede, tieneModulo } from './sesion.js';
import { config } from './api.js';
import { MENU, RUTAS_VIEJAS, conPalabras, tituloBarra } from './menu_datos.js';

export { MENU, RUTAS_VIEJAS };
const PALABRAS = (config && typeof config.palabras === 'object' && config.palabras) || {};

function visible(item) {
  return (!item.modulos || tieneModulo(...item.modulos)) && (!item.permisos || puede(...item.permisos))
    && (!item.todos || item.todos.every((p) => puede(p)));
}

// Menú del usuario actual: solo pestañas con al menos una subpestaña permitida.
export function menuDelUsuario() {
  return conPalabras(MENU, PALABRAS).map((p) => ({ ...p, subs: p.subs.filter(visible) })).filter((p) => p.subs.length > 0);
}

// ¿El usuario ve esta subpestaña? (para botones que llevan a otra pantalla)
export function hayEnMenu(menu, pid, sid) {
  return menu.some((p) => p.id === pid && p.subs.some((s) => s.id === sid));
}

// Botones de la barra inferior del celular: Inicio, Vender, Caja, Productos y "Más" (solo los permitidos).
export function botonesCelular(menu) {
  const lista = [{ id: 'inicio', titulo: tituloBarra(PALABRAS, 'inicio', 'Inicio'), ruta: '#/inicio/hoy', icono: 'inicio', pestana: 'inicio' }];
  if (hayEnMenu(menu, 'vender', 'nueva')) lista.push({ id: 'vender', titulo: tituloBarra(PALABRAS, 'vender', 'Vender'), ruta: '#/vender/nueva', icono: 'vender', pestana: 'vender' });
  const caja = menu.find((p) => p.id === 'caja');
  if (caja) lista.push({ id: 'caja', titulo: tituloBarra(PALABRAS, 'caja', 'Caja'), ruta: `#/caja/${caja.subs[0].id}`, icono: 'caja', pestana: 'caja' });
  if (hayEnMenu(menu, 'inventario', 'productos')) lista.push({ id: 'productos', titulo: tituloBarra(PALABRAS, 'productos', 'Productos'), ruta: '#/inventario/productos', icono: 'etiqueta', pestana: 'inventario' });
  lista.push({ id: 'mas', titulo: 'Más', ruta: '#/mas', icono: 'menu', pestana: 'mas' });
  return lista;
}
