// Alertas activas (alertas_activas): cada quien ve solo lo que sus permisos le dejan.
import { rpc } from '../api.js';
import { empresaId } from '../sesion.js';
import { h, cajaError } from '../ui.js';

export function tarjetaAlerta(a) {
  return h('div', { class: `alerta alerta-${a.gravedad || 'media'}`, dataset: { tipo: a.tipo } },
    h('p', {}, h('strong', {}, a.titulo)),
    h('p', {}, a.mensaje),
    a.que_hacer ? h('p', { class: 'que-hacer' }, a.que_hacer) : null);
}

export async function mostrar(vista) {
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-alertas' }, h('h1', { id: 't-alertas' }, 'Alertas'));
  vista.append(tarjeta);
  try {
    const r = await rpc('alertas_activas', { p_empresa_id: empresaId() });
    const lista = (r && r.alertas) || [];
    tarjeta.append(lista.length
      ? h('div', { class: 'lista' }, lista.map(tarjetaAlerta))
      : h('p', { class: 'vacio' }, 'Todo en orden: no hay alertas.'));
  } catch (err) {
    tarjeta.append(await cajaError(err));
  }
}
