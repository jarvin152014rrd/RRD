// Pantalla para entrar: cálida, con el logo y el nombre del negocio grandes (los últimos que se
// usaron en este equipo; ver marca.js) y solo dos datos: correo y contraseña.
import * as api from '../api.js';
import { h, cajaError, mensaje as caja } from '../ui.js';
import { marcaGuardada, aplicarMarca, iniciales } from '../marca.js';

export function mostrar(raiz, { mensaje, alEntrar }) {
  // Marca de este equipo (o la de siempre si nunca entró nadie aquí).
  const m = marcaGuardada();
  aplicarMarca(m || {});
  const nombre = (m && m.nombre) || 'Mi Negocio';
  const logo = h('div', { class: 'entrar-logo', 'aria-hidden': 'true' },
    m && m.logo ? h('img', { src: m.logo, alt: '' }) : m && m.nombre ? iniciales(m.nombre)
      : h('img', { src: 'iconos/icono.svg', alt: '' }));

  const zonaMensaje = h('div', { 'aria-live': 'polite' },
    mensaje ? caja(mensaje.tipo || 'info', mensaje.texto) : null);
  const correo = h('input', { id: 'correo', name: 'correo', type: 'email', autocomplete: 'username', required: true,
    inputmode: 'email', autocapitalize: 'none', spellcheck: 'false' });
  const clave = h('input', { id: 'clave', name: 'clave', type: 'password', autocomplete: 'current-password', required: true });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho boton-grande' }, 'Entrar');

  const form = h('form', { class: 'tarjeta entrar-tarjeta', novalidate: true, 'aria-labelledby': 'entrar-titulo' },
    h('h2', { id: 'entrar-titulo' }, 'Entre a su negocio'),
    zonaMensaje,
    h('div', { class: 'campo' }, h('label', { for: 'correo' }, 'Correo'), correo),
    h('div', { class: 'campo' }, h('label', { for: 'clave' }, 'Contraseña'), clave),
    boton,
    h('p', { class: 'ayuda' }, '¿Olvidó su contraseña? Pídale al dueño o al administrador del negocio que se la cambie.'));

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaMensaje.replaceChildren();
    if (!correo.value.trim() || !clave.value) {
      zonaMensaje.append(caja('error', 'Escriba su correo y su contraseña.'));
      (correo.value.trim() ? clave : correo).focus();
      return;
    }
    boton.disabled = true; boton.textContent = 'Entrando…';
    try {
      await api.entrar(correo.value.trim(), clave.value);
      await alEntrar();
    } catch (err) {
      await api.salir();
      zonaMensaje.append(await cajaError(err));
      boton.disabled = false; boton.textContent = 'Entrar';
      clave.select();
    }
  });

  raiz.append(h('main', { class: 'entrar' },
    h('div', { class: 'entrar-marca' }, logo,
      h('h1', { class: 'entrar-nombre', id: 'entrar-nombre' }, nombre),
      h('p', { class: 'entrar-saludo' }, '¡Qué bueno verle! Entre para empezar el día.')),
    form));
  correo.focus();
}
