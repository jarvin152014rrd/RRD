// "Más" (celular): todas las pestañas y subpestañas del usuario, Ajustes al final.
import { h } from '../ui.js';

export async function mostrar(vista, { menu, salir }) {
  for (const p of menu) {
    vista.append(h('section', { class: 'tarjeta mas-grupo', 'aria-labelledby': `mas-${p.id}` },
      h('h2', { id: `mas-${p.id}` }, p.titulo),
      h('div', { class: 'mas-lista' }, p.subs.map((s) =>
        h('a', { class: 'boton boton-ancho', href: `#/${p.id}/${s.id}` }, s.titulo)))));
  }
  vista.append(h('button', { type: 'button', class: 'boton boton-peligro boton-ancho', onclick: () => salir() }, 'Salir'));
}
