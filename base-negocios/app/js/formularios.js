// Piezas de formulario que comparten Compras y Dinero (app 0.7.0). Sin innerHTML: todo con ui.h.
import { h } from './ui.js';
import { dinero, paraCampo } from './formato.js';
import { perfilActual } from './sesion.js';

// "Hoy" del negocio: la fecha que trae el servidor en el perfil (zona del negocio, America/Tegucigalpa).
export const hoy = () => perfilActual().empresa.hoy;

// Texto de una cuenta de dinero en una lista: "BAC cheques ****6789 · L 9,840.00".
export function textoCuenta(c, { saldo = true } = {}) {
  return `${c.nombre}${c.numero_enmascarado ? ' ' + c.numero_enmascarado : ''}${saldo ? ' · ' + dinero(c.saldo_centavos) : ''}`;
}

// Lista para elegir una cuenta de dinero (value = cuenta_dinero_id). vacio: primera opción sin valor.
export function selectCuentas(cuentas, props = {}, { vacio = null, elegida = null, saldo = true } = {}) {
  const sel = h('select', props,
    vacio ? h('option', { value: '' }, vacio) : null,
    cuentas.map((c) => h('option', { value: c.cuenta_dinero_id }, textoCuenta(c, { saldo }))));
  if (elegida && cuentas.some((c) => c.cuenta_dinero_id === elegida)) sel.value = elegida;
  return sel;
}

// Campo de dinero en lempiras (texto con teclado numérico; se convierte con aCentavos).
export function inputMonto(id, centavos = null) {
  return h('input', { id, type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: '0.00',
    value: centavos === null || centavos === undefined ? '' : paraCampo(centavos) });
}

// Campo de fecha (AAAA-MM-DD).
export function inputFecha(id, valor = null, { min = null, max = null } = {}) {
  return h('input', { id, type: 'date', value: valor || hoy(), min, max });
}

// Fila "dato: valor" para fichas y detalles (no pinta nada si no hay valor).
export function dato(titulo, valor, props = {}) {
  return valor || valor === 0 ? h('div', { ...props, class: 'fila' }, h('span', {}, titulo), h('span', { class: 'dato-valor' }, valor)) : null;
}

// Cifra chica (título arriba, valor grande abajo) para un resumen de 2 o 3 cifras.
export function cifraChica(titulo, valor, { dato: d = null, clase = '' } = {}) {
  return h('div', { class: 'cifra-chica' }, h('p', { class: 'cifra-titulo' }, titulo),
    h('p', { class: 'cifra-valor' + (clase ? ' ' + clase : ''), dataset: d ? { dato: d } : null }, valor));
}

// Nombre de una cuenta de dinero por su id (o el texto de respaldo).
export function nombreCuenta(cuentas, id, respaldo = 'la cuenta') {
  const c = cuentas.find((x) => x.cuenta_dinero_id === id);
  return c ? c.nombre : respaldo;
}

// "en 3 días" / "hoy" / "hace 5 días"
export function cuandoVence(dias) {
  if (dias === 0) return 'vence hoy';
  if (dias > 0) return `vence en ${dias} ${dias === 1 ? 'día' : 'días'}`;
  return `venció hace ${-dias} ${dias === -1 ? 'día' : 'días'}`;
}
