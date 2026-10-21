// Vender · "Ventas del día": las ventas de hoy (con ventas.ver todas; si no, las propias),
// con su comprobante y el botón para empezar una devolución.
import { leer } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { dinero, fechaHora } from '../formato.js';
import { h, cajaError, titulo, filaIcono, chipEstado, monto, estadoVacio } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { vistaComprobante } from '../comprobante.js';
import { prepararDevolucion } from './devoluciones.js';

export async function mostrar(vista, ctx) {
  const ventas = await leer('v_venta', { empresa_id: empresaId(), fecha_contable: perfilActual().empresa.hoy },
    { orden: 'registrado_en.desc', limite: 300 });
  if (!ctx.sigueVigente()) return;
  const lista = h('div', { class: 'lista-filas' });
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-dia' },
    titulo('h1', 'lista', 'Ventas del día', { id: 't-dia' }),
    puede('ventas.ver') ? null : h('p', { class: 'ayuda' }, 'Aquí salen las ventas que usted hizo hoy.'), lista);
  const pintarLista = () => {
    lista.replaceChildren(...(ventas.length ? ventas.map((v) => {
      const emitida = v.estado === 'emitida';
      return filaIcono({
        icono: v.estado === 'anulada' ? 'anular' : 'recibo', color: emitida ? 'verde' : v.estado === 'anulada' ? 'rojo' : 'dorado',
        titulo: h('strong', {}, v.numero_documento || `Venta #${v.numero}`),
        detalle: `${fechaHora(v.emitida_en || v.registrado_en)} · ${v.cliente_nombre || 'Consumidor final'}`,
        derecha: [monto(dinero(v.total_centavos), { sentido: emitida ? 'entra' : null }),
          emitida ? chipEstado(v.condicion === 'credito' ? 'credito' : 'contado') : chipEstado(v.estado)],
        abajo: h('div', { class: 'botones' },
          ['emitida', 'anulada'].includes(v.estado) ? h('button', { type: 'button', class: 'boton', onclick: () => verComprobante(v) }, 'Comprobante') : null,
          emitida && puede('ventas.devolver') ? h('button', { type: 'button', class: 'boton',
            onclick: () => { prepararDevolucion(v.venta_id); location.hash = '#/vender/devoluciones'; } }, 'Devolver') : null),
        props: { class: 'venta-fila-icono', dataset: { venta: v.venta_id } },
      });
    })
      : [estadoVacio({ icono: 'vender', color: 'verde', titulo: 'Todavía no hay ventas hoy',
        texto: 'Cuando venda algo, aquí lo verá con su comprobante.',
        boton: hayEnMenu(ctx.menu || [], 'vender', 'nueva') ? { texto: 'Hacer una venta', href: '#/vender/nueva', icono: 'vender' } : null })]));
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
