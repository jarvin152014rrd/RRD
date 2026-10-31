// Inventario · Movimientos (kardex por producto, v_kardex; pide inventario.costos).
// Cada fila: fecha, tipo, de dónde vino, entra/sale, saldo de la bodega y su costo.
import { leer } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fecha, cantidad } from '../formato.js';
import { h, campo, cajaError, titulo, tabla, monto, estadoVacio } from '../ui.js';
import { filtrar } from '../datos.js';

const ORIGEN = { compra: 'Compra', anulacion_compra: 'Anulación de compra', ajuste: 'Ajuste (conteo)', traslado: 'Traslado',
  carga_inicial: 'Existencia inicial', venta: 'Venta', anulacion_venta: 'Anulación de venta', devolucion: 'Devolución',
  ajuste_costo: 'Ajuste de costo', anulacion_ajuste: 'Anulación de ajuste', anulacion_traslado: 'Anulación de traslado' };

export async function mostrar(vista, ctx) {
  const productos = (await leer('v_producto', { empresa_id: empresaId(), tipo: 'bien' }, { orden: 'nombre.asc', limite: 1000 }));
  if (!ctx.sigueVigente()) return;
  const buscar = h('input', { id: 'kardex-buscar', type: 'search', placeholder: 'Nombre o código', autocomplete: 'off' });
  const sel = h('select', { id: 'kardex-producto' });
  const zona = h('div', {});
  const llenar = () => {
    const vistos = filtrar(productos, buscar.value, ['nombre', 'codigo', 'codigo_barras']);
    const antes = sel.value;
    sel.replaceChildren(...vistos.slice(0, 300).map((p) => h('option', { value: p.producto_id }, `${p.nombre} (${p.codigo})`)));
    if (vistos.some((p) => p.producto_id === antes)) sel.value = antes;
  };
  const cargar = async () => {
    if (!sel.value) { zona.replaceChildren(estadoVacio({ icono: 'buscar', chico: true, texto: productos.length ? 'Elija un producto.' : 'Aún no tiene productos con existencia.' })); return; }
    zona.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
    try {
      const movs = await leer('v_kardex', { empresa_id: empresaId(), producto_id: sel.value }, { orden: 'registrado_en.desc', limite: 300 });
      // Lo principal arriba (en el celular): qué fue y cuánto entró (verde) o salió (rojo).
      zona.replaceChildren(movs.length ? tabla({ props: { id: 'kardex' },
        columnas: [{ titulo: 'Qué fue' }, { titulo: 'Fecha' }, { titulo: 'Bodega' }, { titulo: 'Entra / sale', num: true }, { titulo: 'Costo', num: true },
          { titulo: 'Queda en bodega', num: true }, { titulo: 'Valor en bodega', num: true }],
        filas: movs.map((m) => [
          h('span', {}, h('strong', {}, ORIGEN[m.origen] || m.origen), m.nota ? h('span', { class: 'detalle' }, ' · ' + m.nota) : null),
          fecha(m.fecha_contable), m.bodega_codigo,
          monto(cantidad(m.cantidad), { sentido: m.cantidad < 0 ? 'sale' : 'entra', signo: m.cantidad > 0 ? '+' : '' }),
          dinero(m.valor_centavos), cantidad(m.saldo_bodega_cantidad), dinero(m.saldo_bodega_valor_centavos)]) })
        : estadoVacio({ icono: 'movimientos', chico: true, texto: 'Este producto no tiene movimientos.' }));
    } catch (err) { zona.replaceChildren(await cajaError(err)); }
  };
  buscar.addEventListener('input', () => { llenar(); cargar(); });
  sel.addEventListener('change', cargar);
  llenar();
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-kardex' },
    titulo('h1', 'movimientos', 'Movimientos por producto (kardex)', { id: 't-kardex' }),
    h('div', { class: 'dos-columnas' }, campo('Buscar', buscar), campo('Producto', sel)), zona));
  await cargar();
}
