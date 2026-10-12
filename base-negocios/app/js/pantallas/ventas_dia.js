// Vender · "Ventas del día": las ventas de hoy (con ventas.ver todas; si no, las propias),
// con su comprobante y el botón para empezar una devolución.
import { leer } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { dinero, fechaHora } from '../formato.js';
import { h, cajaError } from '../ui.js';
import { vistaComprobante } from '../comprobante.js';
import { prepararDevolucion } from './devoluciones.js';

const ESTADO = { emitida: 'Emitida', pendiente_aprobacion: 'Esperando aprobación', anulada: 'Anulada', cancelada: 'Cancelada',
  rechazada: 'Rechazada', por_emitir: 'Por emitir' };

export async function mostrar(vista, ctx) {
  const ventas = await leer('v_venta', { empresa_id: empresaId(), fecha_contable: perfilActual().empresa.hoy },
    { orden: 'registrado_en.desc', limite: 300 });
  if (!ctx.sigueVigente()) return;
  const lista = h('div', { class: 'lista' });
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-dia' },
    h('h1', { id: 't-dia' }, 'Ventas del día'),
    puede('ventas.ver') ? null : h('p', { class: 'ayuda' }, 'Aquí salen las ventas que usted hizo hoy.'), lista);
  const pintarLista = () => {
    lista.replaceChildren(...(ventas.length ? ventas.map((v) => h('article', { class: 'venta-fila', dataset: { venta: v.venta_id } },
      h('div', {},
        h('strong', {}, v.numero_documento || `Venta #${v.numero}`),
        h('span', { class: 'detalle' }, `${fechaHora(v.emitida_en || v.registrado_en)} · ${v.cliente_nombre || 'Consumidor final'} · ${v.condicion === 'credito' ? 'Crédito' : 'Contado'}`),
        v.estado !== 'emitida' ? h('span', { class: 'etiqueta' }, ESTADO[v.estado] || v.estado) : null),
      h('span', { class: 'monto' }, dinero(v.total_centavos)),
      h('div', { class: 'botones' },
        ['emitida', 'anulada'].includes(v.estado) ? h('button', { type: 'button', class: 'boton', onclick: () => verComprobante(v) }, 'Comprobante') : null,
        v.estado === 'emitida' && puede('ventas.devolver') ? h('button', { type: 'button', class: 'boton',
          onclick: () => { prepararDevolucion(v.venta_id); location.hash = '#/vender/devoluciones'; } }, 'Devolver') : null)))
      : [h('p', { class: 'vacio' }, 'Todavía no hay ventas hoy.')]));
  };
  async function verComprobante(v) {
    const volver = h('button', { type: 'button', class: 'boton', onclick: () => { vista.replaceChildren(tarjeta); } }, 'Volver');
    try {
      vista.replaceChildren(await vistaComprobante(v.venta_id, { extra: [volver] }));
    } catch (err) {
      vista.replaceChildren(await cajaError(err), volver);
    }
  }
  pintarLista();
  vista.append(tarjeta);
}
