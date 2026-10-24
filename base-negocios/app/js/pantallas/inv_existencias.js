// Inventario · Existencias por bodega (v_existencia). Alerta de bajo mínimo. Costo y valor solo
// con inventario.costos (el servidor los manda vacíos a quien no lo tiene).
import { leer } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, cantidad } from '../formato.js';
import { h, campo, titulo, tabla, chipEstado, chip, estadoVacio } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { filtrar, productos } from '../datos.js';
import { fotosActivas, miniatura, porProducto } from '../fotos.js';

export async function mostrar(vista, ctx) {
  const [filas, fotos] = await Promise.all([leer('v_existencia', { empresa_id: empresaId() }, { orden: 'nombre.asc', limite: 1000 }),
    // Fotos encendidas (app 0.11.0): la miniatura sale de la lista de productos.
    fotosActivas() ? productos().then(porProducto).catch(() => new Map()) : new Map()]);
  if (!ctx.sigueVigente()) return;
  const costos = puede('inventario.costos');
  const bodegas = [...new Map(filas.map((f) => [f.bodega_id, `${f.bodega_codigo} · ${f.bodega_nombre}`])).entries()];
  const selBodega = h('select', { id: 'exist-bodega' }, h('option', { value: '' }, 'Todas las bodegas'), bodegas.map(([id, n]) => h('option', { value: id }, n)));
  const buscar = h('input', { id: 'exist-buscar', type: 'search', placeholder: 'Nombre o código', autocomplete: 'off' });
  const soloBajos = h('input', { type: 'checkbox', id: 'exist-bajos' });
  const zona = h('div', {});
  const resumen = h('p', { class: 'ayuda', 'aria-live': 'polite' });
  const pintar = () => {
    const vistas = filtrar(filas.filter((f) => (!selBodega.value || f.bodega_id === selBodega.value) && (!soloBajos.checked || f.bajo_minimo)),
      buscar.value, ['nombre', 'codigo', 'codigo_barras']);
    const bajos = vistas.filter((f) => f.bajo_minimo).length;
    resumen.replaceChildren(h('span', {}, `${vistas.length} producto(s)`, bajos ? [' · ', chip(`${bajos} bajo el mínimo`, 'rojo')] : null,
      costos ? ` · valor ${dinero(vistas.reduce((s, f) => s + (f.valor_centavos || 0), 0))}` : ''));
    const columnas = [{ titulo: 'Producto' }, { titulo: 'Bodega' }, { titulo: 'Hay', num: true }, { titulo: 'Mínimo', num: true }]
      .concat(costos ? [{ titulo: 'Costo promedio', num: true }, { titulo: 'Valor', num: true }] : []);
    zona.replaceChildren(vistas.length ? tabla({ columnas, filaProps: (i) => ({ dataset: { producto: vistas[i].producto_id } }),
      filas: vistas.map((f) => [
        fotosActivas() ? h('span', { class: 'producto-con-foto' }, miniatura(fotos.get(f.producto_id) || null, { props: { class: 'burbuja-chica' } }),
          h('span', {}, h('strong', {}, f.nombre), h('span', { class: 'detalle' }, ` ${f.codigo}`)))
          : h('span', {}, h('strong', {}, f.nombre), h('span', { class: 'detalle' }, ` ${f.codigo}`)),
        f.bodega_codigo,
        h('span', {}, `${cantidad(f.cantidad)} ${f.unidad || ''}`, f.bajo_minimo ? [' ', chipEstado('bajo_minimo', 'Bajo el mínimo')] : null),
        cantidad(f.stock_minimo || 0),
      ].concat(costos ? [f.costo_promedio === null ? '—' : dinero(Math.round(f.costo_promedio)), dinero(f.valor_centavos || 0)] : [])) })
      : estadoVacio({ icono: 'buscar', chico: true, texto: 'No hay existencias con ese filtro.' }));
    // El chip de "bajo el mínimo" lo buscan las pruebas como antes.
    for (const c of zona.querySelectorAll('[data-estado=bajo_minimo]')) c.dataset.dato = 'bajo-minimo';
  };
  for (const c of [selBodega, soloBajos]) c.addEventListener('change', pintar);
  buscar.addEventListener('input', pintar);
  pintar();
  if (!filas.length) {
    vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-exist' },
      titulo('h1', 'existencias', 'Existencias por bodega', { id: 't-exist' }),
      estadoVacio({ icono: 'existencias', titulo: 'Aún no hay mercadería en sus bodegas',
        texto: 'Cuando agregue productos y cargue cuánto tiene de cada uno, aquí verá lo que hay en cada bodega.',
        botones: [hayEnMenu(ctx.menu || [], 'inventario', 'productos') ? { texto: 'Ver mis productos', href: '#/inventario/productos', icono: 'etiqueta' } : null,
          hayEnMenu(ctx.menu || [], 'ajustes', 'excel') ? { texto: 'Subir mi Excel', href: '#/ajustes/excel', icono: 'excel' } : null] })));
    return;
  }
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-exist' },
    titulo('h1', 'existencias', 'Existencias por bodega', { id: 't-exist' }),
    h('div', { class: 'dos-columnas' }, campo('Bodega', selBodega), campo('Buscar', buscar)),
    h('label', { class: 'opcion-check' }, soloBajos, ' Solo los que están bajo el mínimo'), resumen, zona));
}
