// Pantalla provisional para lo que aún no está hecho.
import { h } from '../ui.js';

export async function mostrar(vista, { titulo }) {
  vista.append(h('section', { class: 'tarjeta en-construccion' },
    h('h1', {}, titulo),
    h('p', { class: 'suave' }, 'Esta pantalla está en construcción. Muy pronto podrá usarla desde aquí.')));
}
