// "Más" (celular): todas las pestañas y subpestañas del usuario, Ajustes al final.
import { h, icono, burbuja } from '../ui.js';
import { perfilActual } from '../sesion.js';

export async function mostrar(vista, { menu, salir }) {
  // App 0.15.0: en el celular el encabezado ya no muestra quién entró: va aquí arriba, con su botón Salir.
  const p0 = perfilActual();
  const nombre = (p0 && p0.usuario && (p0.usuario.nombre || p0.usuario.correo)) || '';
  vista.append(h('section', { class: 'tarjeta mas-sesion', 'aria-label': 'Su sesión' },
    burbuja('usuario', 'azul'),
    h('div', { class: 'mas-sesion-texto' }, h('strong', {}, nombre), h('span', { class: 'ayuda' }, (p0 && p0.rol && (p0.rol.nombre || p0.rol.codigo)) || '')),
    h('button', { type: 'button', class: 'boton boton-peligro', onclick: () => salir() }, icono('salir'), h('span', {}, 'Salir'))));
  for (const p of menu) {
    vista.append(h('section', { class: 'tarjeta mas-grupo', 'aria-labelledby': `mas-${p.id}` },
      h('h2', { id: `mas-${p.id}`, class: 'titulo-icono' }, icono(p.icono), p.titulo),
      h('div', { class: 'mas-lista' }, p.subs.map((s) =>
        h('a', { class: 'boton boton-ancho', href: `#/${p.id}/${s.id}` }, icono(s.icono), h('span', {}, s.titulo))))));
  }
  vista.append(h('button', { type: 'button', class: 'boton boton-peligro boton-ancho', onclick: () => salir() }, icono('salir'), h('span', {}, 'Salir')));
}
