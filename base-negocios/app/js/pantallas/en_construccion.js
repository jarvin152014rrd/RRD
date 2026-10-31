// Pantalla provisional para lo que aún no está hecho (estado vacío con el ícono de la subpestaña).
import { h, icono, estadoVacio } from '../ui.js';

export async function mostrar(vista, { titulo, sub }) {
  const ic = (sub && sub.icono) || 'construccion';
  vista.append(h('section', { class: 'tarjeta en-construccion' },
    h('h1', { class: 'titulo-icono' }, icono(ic), titulo),
    estadoVacio({ icono: 'construccion', color: 'dorado', titulo: 'Esta parte se está construyendo',
      texto: 'Muy pronto podrá usarla desde aquí. Mientras tanto, lo demás del programa funciona normal.',
      boton: { texto: 'Volver a Inicio', href: '#/inicio/hoy' } })));
}
