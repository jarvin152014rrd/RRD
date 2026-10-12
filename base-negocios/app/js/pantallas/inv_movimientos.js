// Inventario · Movimientos (kardex por producto, v_kardex; pide inventario.costos).
// Cada fila: fecha, tipo, de dónde vino, entra/sale, saldo de la bodega y su costo.
import { leer } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fecha, cantidad } from '../formato.js';
import { h, campo, cajaError } from '../ui.js';
import { filtrar } from '../datos.js';

const ORIGEN = { compra: 'Compra', anulacion_compra: 'Anulación de compra', ajuste: 'Ajuste (conteo)', traslado: 'Traslado',
  carga_inicial: 'Existencia inicial', venta: 'Venta', anulacion_venta: 'Anulación de venta', devolucion: 'Devolución',
  ajuste_costo: 'Ajuste de costo', anulacion_ajuste: 'Anulación de ajuste', anulacion_traslado: 'Anulación de traslado' };

export async function mostrar(vista, ctx) {
  const productos = (await leer('v_producto', { empresa_id: empresaId(), tipo: 'bien' }, { orden: 'nombre.asc', limite: 1000 }));
  if (!ctx.sigueVigente()) return;
  const buscar = h('input', { id: 'kardex-buscar', type: 'search', placeholder: 'Nombre o código', autocomplete: 'off' });
  const sel = h('select', { id: 'kardex-producto' });
  const zona = h('div', { class: 'tabla-envoltura' });
  const llenar = () => {
    const vistos = filtrar(productos, buscar.value, ['nombre', 'codigo', 'codigo_barras']);
    const antes = sel.value;
    sel.replaceChildren(...vistos.slice(0, 300).map((p) => h('option', { value: p.producto_id }, `${p.nombre} (${p.codigo})`)));
    if (vistos.some((p) => p.producto_id === antes)) sel.value = antes;
  };
  const cargar = async () => {
    if (!sel.value) { zona.replaceChildren(h('p', { class: 'vacio' }, 'Elija un producto.')); return; }
    zona.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
    try {
      const movs = await leer('v_kardex', { empresa_id: empresaId(), producto_id: sel.value }, { orden: 'registrado_en.desc', limite: 300 });
      zona.replaceChildren(movs.length ? h('table', { class: 'tabla tabla-celular', id: 'kardex' },
        h('thead', {}, h('tr', {}, ['Fecha', 'Qué fue', 'Bodega', 'Entra / sale', 'Costo', 'Queda en bodega', 'Valor en bodega'].map((t, i) => h('th', { class: i >= 3 ? 'num' : null }, t)))),
        h('tbody', {}, movs.map((m) => h('tr', {},
          h('td', { 'data-titulo': 'Fecha' }, fecha(m.fecha_contable)),
          h('td', { 'data-titulo': 'Qué fue' }, ORIGEN[m.origen] || m.origen, m.nota ? h('span', { class: 'detalle' }, ' · ' + m.nota) : null),
          h('td', { 'data-titulo': 'Bodega' }, m.bodega_codigo),
          h('td', { class: 'num' + (m.cantidad < 0 ? ' peligro' : ''), 'data-titulo': 'Entra / sale' }, (m.cantidad > 0 ? '+' : '') + cantidad(m.cantidad)),
          h('td', { class: 'num', 'data-titulo': 'Costo' }, dinero(m.valor_centavos)),
          h('td', { class: 'num', 'data-titulo': 'Queda en bodega' }, cantidad(m.saldo_bodega_cantidad)),
          h('td', { class: 'num', 'data-titulo': 'Valor en bodega' }, dinero(m.saldo_bodega_valor_centavos))))))
        : h('p', { class: 'vacio' }, 'Este producto no tiene movimientos.'));
    } catch (err) { zona.replaceChildren(await cajaError(err)); }
  };
  buscar.addEventListener('input', () => { llenar(); cargar(); });
  sel.addEventListener('change', cargar);
  llenar();
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-kardex' },
    h('h1', { id: 't-kardex' }, 'Movimientos por producto (kardex)'),
    h('div', { class: 'dos-columnas' }, campo('Buscar', buscar), campo('Producto', sel)), zona));
  await cargar();
}
