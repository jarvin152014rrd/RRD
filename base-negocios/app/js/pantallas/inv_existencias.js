// Inventario · Existencias por bodega (v_existencia). Alerta de bajo mínimo. Costo y valor solo
// con inventario.costos (el servidor los manda vacíos a quien no lo tiene).
import { leer } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, cantidad } from '../formato.js';
import { h, campo } from '../ui.js';
import { filtrar } from '../datos.js';

export async function mostrar(vista, ctx) {
  const filas = await leer('v_existencia', { empresa_id: empresaId() }, { orden: 'nombre.asc', limite: 1000 });
  if (!ctx.sigueVigente()) return;
  const costos = puede('inventario.costos');
  const bodegas = [...new Map(filas.map((f) => [f.bodega_id, `${f.bodega_codigo} · ${f.bodega_nombre}`])).entries()];
  const selBodega = h('select', { id: 'exist-bodega' }, h('option', { value: '' }, 'Todas las bodegas'), bodegas.map(([id, n]) => h('option', { value: id }, n)));
  const buscar = h('input', { id: 'exist-buscar', type: 'search', placeholder: 'Nombre o código', autocomplete: 'off' });
  const soloBajos = h('input', { type: 'checkbox', id: 'exist-bajos' });
  const zona = h('div', { class: 'tabla-envoltura' });
  const resumen = h('p', { class: 'ayuda', 'aria-live': 'polite' });
  const pintar = () => {
    const vistas = filtrar(filas.filter((f) => (!selBodega.value || f.bodega_id === selBodega.value) && (!soloBajos.checked || f.bajo_minimo)),
      buscar.value, ['nombre', 'codigo', 'codigo_barras']);
    const bajos = vistas.filter((f) => f.bajo_minimo).length;
    resumen.textContent = `${vistas.length} producto(s)` + (bajos ? ` · ${bajos} bajo el mínimo` : '') +
      (costos ? ` · valor ${dinero(vistas.reduce((s, f) => s + (f.valor_centavos || 0), 0))}` : '');
    zona.replaceChildren(vistas.length ? h('table', { class: 'tabla tabla-celular' },
      h('thead', {}, h('tr', {}, h('th', {}, 'Producto'), h('th', {}, 'Bodega'), h('th', { class: 'num' }, 'Hay'), h('th', { class: 'num' }, 'Mínimo'),
        costos ? h('th', { class: 'num' }, 'Costo promedio') : null, costos ? h('th', { class: 'num' }, 'Valor') : null)),
      h('tbody', {}, vistas.map((f) => h('tr', { dataset: { producto: f.producto_id } },
        h('td', { 'data-titulo': 'Producto' }, h('span', {}, h('strong', {}, f.nombre), h('span', { class: 'detalle' }, ` ${f.codigo}`))),
        h('td', { 'data-titulo': 'Bodega' }, f.bodega_codigo),
        h('td', { class: 'num', 'data-titulo': 'Hay' }, `${cantidad(f.cantidad)} ${f.unidad || ''}`,
          f.bajo_minimo ? h('span', { class: 'etiqueta etiqueta-peligro', dataset: { dato: 'bajo-minimo' } }, ' Bajo el mínimo') : null),
        h('td', { class: 'num', 'data-titulo': 'Mínimo' }, cantidad(f.stock_minimo || 0)),
        costos ? h('td', { class: 'num', 'data-titulo': 'Costo promedio' }, f.costo_promedio === null ? '—' : dinero(Math.round(f.costo_promedio))) : null,
        costos ? h('td', { class: 'num', 'data-titulo': 'Valor' }, dinero(f.valor_centavos || 0)) : null))))
      : h('p', { class: 'vacio' }, 'No hay existencias con ese filtro.'));
  };
  for (const c of [selBodega, soloBajos]) c.addEventListener('change', pintar);
  buscar.addEventListener('input', pintar);
  pintar();
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-exist' },
    h('h1', { id: 't-exist' }, 'Existencias por bodega'),
    h('div', { class: 'dos-columnas' }, campo('Bodega', selBodega), campo('Buscar', buscar)),
    h('label', { class: 'opcion-check' }, soloBajos, ' Solo los que están bajo el mínimo'), resumen, zona));
}
