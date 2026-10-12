// Pantalla para entrar: correo y contraseña.
import * as api from '../api.js';
import { h, cajaError } from '../ui.js';

export function mostrar(raiz, { mensaje, alEntrar }) {
  const zonaMensaje = h('div', { 'aria-live': 'polite' },
    mensaje ? h('p', { class: `mensaje mensaje-${mensaje.tipo || 'info'}`, role: 'status' }, mensaje.texto) : null);
  const correo = h('input', { id: 'correo', name: 'correo', type: 'email', autocomplete: 'username', required: true,
    inputmode: 'email', autocapitalize: 'none', spellcheck: 'false' });
  const clave = h('input', { id: 'clave', name: 'clave', type: 'password', autocomplete: 'current-password', required: true });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Entrar');

  const form = h('form', { class: 'tarjeta', novalidate: true },
    h('div', { class: 'entrar-marca' },
      h('img', { src: 'iconos/icono.svg', alt: '', width: 44, height: 44, style: 'border-radius:10px' }),
      h('h1', {}, 'Entrar')),
    zonaMensaje,
    h('div', { class: 'campo' }, h('label', { for: 'correo' }, 'Correo'), correo),
    h('div', { class: 'campo' }, h('label', { for: 'clave' }, 'Contraseña'), clave),
    boton,
    h('p', { class: 'ayuda' }, '¿Olvidó su contraseña? Pídale al administrador del negocio que se la cambie.'));

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaMensaje.replaceChildren();
    if (!correo.value.trim() || !clave.value) {
      zonaMensaje.append(h('p', { class: 'mensaje mensaje-error', role: 'alert' }, 'Escriba su correo y su contraseña.'));
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

  raiz.append(h('main', { class: 'entrar' }, form));
  correo.focus();
}
