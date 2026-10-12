// Menú por pestañas y subpestañas. Se arma SOLO con lo que el usuario puede usar:
// módulos activos + permisos de mi_perfil. Nada gris ni bloqueado: lo que no puede, no sale.
// La lista vive en js/menu_datos.js (datos puros que también usa el Armador del proveedor).
// Los títulos usan las palabras del rubro del cliente (config.palabras), si las hay.
import { puede, tieneModulo } from './sesion.js';
import { config } from './api.js';
import { MENU, conPalabras, tituloBarra } from './menu_datos.js';

export { MENU };
const PALABRAS = (config && typeof config.palabras === 'object' && config.palabras) || {};

function visible(item) {
  return (!item.modulos || tieneModulo(...item.modulos)) && (!item.permisos || puede(...item.permisos))
    && (!item.todos || item.todos.every((p) => puede(p)));
}

// Menú del usuario actual: solo pestañas con al menos una subpestaña permitida.
export function menuDelUsuario() {
  return conPalabras(MENU, PALABRAS).map((p) => ({ ...p, subs: p.subs.filter(visible) })).filter((p) => p.subs.length > 0);
}

// Botones de la barra inferior del celular (solo los permitidos; "Más" siempre).
export function botonesCelular(menu) {
  const hay = (pid, sid) => menu.some((p) => p.id === pid && p.subs.some((s) => s.id === sid));
  const lista = [{ id: 'resumen', titulo: tituloBarra(PALABRAS, 'resumen', 'Resumen'), ruta: '#/inicio/hoy', icono: 'resumen', pestana: 'inicio' }];
  if (hay('vender', 'nueva')) lista.push({ id: 'vender', titulo: tituloBarra(PALABRAS, 'vender', 'Vender'), ruta: '#/vender/nueva', icono: 'vender', pestana: 'vender' });
  if (hay('inventario', 'productos')) lista.push({ id: 'buscar', titulo: tituloBarra(PALABRAS, 'buscar', 'Buscar'), ruta: '#/buscar', icono: 'buscar', pestana: 'buscar' });
  lista.push({ id: 'mas', titulo: 'Más', ruta: '#/mas', icono: 'mas', pestana: 'mas' });
  return lista;
}
