// Alertas activas (alertas_activas): cada quien ve solo lo que sus permisos le dejan.
// Desde app 0.5.0 se muestran en Inicio > Pendientes (la ruta vieja #/inicio/alertas lleva allí).
import { rpc } from '../api.js';
import { empresaId } from '../sesion.js';
import { h, filaIcono } from '../ui.js';

// Gravedad -> color con significado: alta = problema (rojo), media = importante (dorado), baja = información (azul).
const COLOR = { alta: 'rojo', media: 'dorado', baja: 'azul' };

export function tarjetaAlerta(a) {
  const g = a.gravedad || 'media';
  return filaIcono({
    icono: g === 'baja' ? 'info' : 'alerta', color: COLOR[g] || 'dorado',
    titulo: h('strong', {}, a.titulo),
    detalle: [a.mensaje, a.que_hacer ? h('span', { class: 'que-hacer' }, ' ', a.que_hacer) : null],
    props: { class: `alerta alerta-${g}`, dataset: { tipo: a.tipo } },
  });
}

// Quien ve las aprobaciones ya las tiene en la lista con botones: la alerta "aprobaciones"
// (cuántas hay) sobraría y contaría doble en la campanita.
export function sinRepetir(alertas, conAprobaciones) {
  return conAprobaciones ? alertas.filter((a) => a.tipo !== 'aprobaciones') : alertas;
}

export function leerAlertas(conAprobaciones = false) {
  return rpc('alertas_activas', { p_empresa_id: empresaId() }).then((r) => sinRepetir((r && r.alertas) || [], conAprobaciones));
}

// La pantalla de alertas sola ya no está en el menú: Pendientes la reemplaza.
export async function mostrar(vista, ctx) {
  const { mostrar: pendientes } = await import('./pendientes.js');
  return pendientes(vista, ctx);
}
