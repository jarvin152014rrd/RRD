// Reportes · "Inventario valorizado" (app 0.8.0). Solo mirar.
//   Cuánto vale lo que tengo HOY: v_existencia (núcleo 015/017: cantidad y valor al costo promedio por
//   bodega; un usuario limitado a su sucursal ve solo sus bodegas) con el precio de venta sin ISV de
//   v_producto; por categoría; lo que está bajo el mínimo; y lo que no se vende hace N días (salidas por
//   venta de v_kardex). Los servicios no tienen inventario.
import { leer } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, cantidad, sumarDias, fecha } from '../formato.js';
import { h, cajaError, titulo, tarjetaCifra, monto, chip, estadoVacio, mensaje, tabla, filaIcono } from '../ui.js';
import { bodegas, reiniciarAlSalir } from '../datos.js';
import { hoy } from '../formularios.js';
import { botonesReporte, barraParte, llegoAlTope, TOPE_FILAS } from '../reportes.js';

let bodega = '';
let dias = 30;
reiniciarAlSalir(() => { bodega = ''; dias = 30; });

// Suma por producto (en las bodegas elegidas) con el valor al costo y a precio de venta sin ISV.
// valor de venta por fila = round(cantidad x precio sin ISV) (centavos enteros).
export function valorizar(existencias, productos) {
  const prod = new Map(productos.map((p) => [p.producto_id, p]));
  const porProducto = new Map();
  for (const x of existencias) {
    const p = prod.get(x.producto_id) || {};
    const a = porProducto.get(x.producto_id) || { producto_id: x.producto_id, nombre: x.nombre, codigo: x.codigo, unidad: x.unidad,
      categoria: p.categoria || 'Sin categoría', minimo: Number(p.stock_minimo ?? x.stock_minimo) || 0, cantidad: 0, costo: 0, venta: 0 };
    const q = Number(x.cantidad) || 0;
    a.cantidad += q;
    a.costo += Number(x.valor_centavos) || 0;
    a.venta += Math.round(q * (Number(p.precio_sin_isv_centavos) || 0));
    porProducto.set(x.producto_id, a);
  }
  return [...porProducto.values()];
}

export async function mostrar(vista, ctx) {
  const bods = await bodegas();
  if (!ctx.sigueVigente()) return;
  const selBodega = h('select', { id: 'valor-bodega' }, h('option', { value: '' }, 'Todas las bodegas'), bods.map((b) => h('option', { value: b.id }, b.nombre)));
  selBodega.value = bods.some((b) => b.id === bodega) ? bodega : '';
  const selDias = h('select', { id: 'valor-dias' }, [30, 60, 90].map((d) => h('option', { value: String(d) }, `${d} días`)));
  selDias.value = String(dias);
  const zona = h('div', { class: 'lista' });
  let doc = null;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-valor' },
    titulo('h1', 'inventario', 'Inventario valorizado', { id: 't-valor' }),
    h('p', { class: 'ayuda' }, `Lo que hay hoy (${fecha(hoy())}) en sus bodegas: al costo (lo que le costó) y a precio de venta sin ISV.`),
    h('div', { class: 'dos-columnas filtros' },
      h('div', { class: 'campo' }, h('label', { for: 'valor-bodega' }, '¿Qué bodega?'), selBodega),
      h('div', { class: 'campo' }, h('label', { for: 'valor-dias' }, 'Sin ventas hace'), selDias)),
    botonesReporte('valor', () => doc), zona));
  selBodega.addEventListener('change', () => { bodega = selBodega.value; cargar(); });
  selDias.addEventListener('change', () => { dias = Number(selDias.value); cargar(); });

  async function cargar() {
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    doc = null;
    const filtro = { empresa_id: empresaId(), ...(bodega ? { bodega_id: bodega } : {}) };
    const desde = sumarDias(hoy(), -dias);
    let exis, productos, salidas;
    try {
      [exis, productos, salidas] = await Promise.all([
        leer('v_existencia', filtro, { orden: 'nombre.asc', limite: TOPE_FILAS }),
        leer('v_producto', { empresa_id: empresaId() }, { orden: 'nombre.asc', limite: TOPE_FILAS }),
        leer('v_kardex', { ...filtro, tipo: 'salida', fecha_contable: { gte: desde } }, { orden: 'fecha_contable.desc', limite: TOPE_FILAS }),
      ]);
    } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;

    const bienes = productos.filter((p) => p.tipo !== 'servicio');
    const lista = valorizar(exis, bienes);
    // Productos que nunca entraron a estas bodegas también cuentan para "bajo el mínimo" (tienen 0).
    for (const p of bienes) {
      if (p.activo && !lista.some((x) => x.producto_id === p.producto_id)) {
        lista.push({ producto_id: p.producto_id, nombre: p.nombre, codigo: p.codigo, unidad: p.unidad, categoria: p.categoria || 'Sin categoría',
          minimo: Number(p.stock_minimo) || 0, cantidad: 0, costo: 0, venta: 0 });
      }
    }
    const conExistencia = lista.filter((x) => x.cantidad > 0);
    const costo = lista.reduce((s, x) => s + x.costo, 0), venta = lista.reduce((s, x) => s + x.venta, 0);
    const cats = new Map();
    for (const x of conExistencia) {
      const c = cats.get(x.categoria) || { nombre: x.categoria, productos: 0, costo: 0, venta: 0 };
      c.productos += 1; c.costo += x.costo; c.venta += x.venta;
      cats.set(x.categoria, c);
    }
    const categorias = [...cats.values()].sort((a, b) => b.costo - a.costo);
    const bajos = lista.filter((x) => x.minimo > 0 && x.cantidad < x.minimo).sort((a, b) => a.cantidad / a.minimo - b.cantidad / b.minimo);
    const vendidos = new Set(salidas.map((m) => m.producto_id));
    const kardexCompleto = !llegoAlTope(salidas);
    const quietos = kardexCompleto ? conExistencia.filter((x) => !vendidos.has(x.producto_id)).sort((a, b) => b.costo - a.costo) : [];
    const valorQuieto = quietos.reduce((s, x) => s + x.costo, 0);
    const masValen = [...conExistencia].sort((a, b) => b.costo - a.costo);

    zona.replaceChildren(...[
      llegoAlTope(exis) || llegoAlTope(productos) ? mensaje('info', `Se leyeron las primeras ${TOPE_FILAS.toLocaleString('en-US')} filas: las cifras pueden estar incompletas.`, 'Elija una bodega para ver menos productos.', { dataset: { info: 'tope-filas' } }) : null,
      h('div', { class: 'cifras' },
        tarjetaCifra({ dato: 'valor-costo', icono: 'inventario', color: 'azul', etiqueta: 'Vale al costo', valor: dinero(costo),
          nota: `${conExistencia.length} ${conExistencia.length === 1 ? 'producto' : 'productos'} con existencia` }),
        tarjetaCifra({ dato: 'valor-venta', icono: 'etiqueta', color: 'verde', etiqueta: 'Vale a precio de venta', valor: dinero(venta), nota: 'sin ISV' }),
        tarjetaCifra({ dato: 'valor-ganancia', icono: 'sube', color: venta - costo >= 0 ? 'verde' : 'rojo', etiqueta: 'Ganaría si vende todo', valor: dinero(venta - costo) })),
      h('h2', { class: 'titulo-chico' }, 'Por categoría'),
      categorias.length ? tabla({ props: { id: 'tabla-categorias' }, columnas: [{ titulo: 'Categoría' }, { titulo: 'Productos', num: true }, { titulo: 'Al costo', num: true }, { titulo: 'A precio de venta', num: true }],
        filas: categorias.map((c) => [c.nombre, String(c.productos), monto(dinero(c.costo)), dinero(c.venta)]) })
        : estadoVacio({ icono: 'inventario', chico: true, texto: 'No hay existencias en estas bodegas.', boton: { texto: 'Ver compras', href: '#/compras/compras', icono: 'compras' } }),
      h('h2', { class: 'titulo-chico' }, 'Bajo el mínimo'),
      bajos.length ? h('div', { class: 'lista-filas', id: 'valor-bajos' }, bajos.map((x) => filaIcono({ icono: 'alerta', color: 'rojo',
        titulo: h('strong', {}, x.nombre), detalle: `Tiene ${cantidad(x.cantidad)} ${x.unidad || ''} · el mínimo es ${cantidad(x.minimo)}`,
        derecha: chip('Bajo el mínimo', 'rojo'), props: { dataset: { producto: x.producto_id } } })))
        : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'Ningún producto está bajo su mínimo.' }),
      h('h2', { class: 'titulo-chico' }, `Sin ventas en ${dias} días`),
      !kardexCompleto ? mensaje('info', 'Hubo muchas ventas en estos días y no se pudo revisar todo.', 'Elija menos días o una bodega.', { dataset: { info: 'tope-kardex' } })
        : quietos.length ? [h('p', { class: 'ayuda' }, `${quietos.length} ${quietos.length === 1 ? 'producto tiene' : 'productos tienen'} existencia y no se ${quietos.length === 1 ? 'ha' : 'han'} vendido desde el ${fecha(desde)}: ${dinero(valorQuieto)} al costo, quieto.`),
          h('div', { class: 'lista-filas', id: 'valor-quietos' }, quietos.slice(0, 20).map((x) => filaIcono({ icono: 'reloj', color: 'dorado',
            titulo: h('strong', {}, x.nombre), detalle: `${cantidad(x.cantidad)} ${x.unidad || ''} · ${x.categoria}`, derecha: monto(dinero(x.costo)),
            props: { dataset: { producto: x.producto_id } } })))]
          : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: `Todo lo que tiene se vendió alguna vez en los últimos ${dias} días.` }),
      h('h2', { class: 'titulo-chico' }, 'Lo que más vale'),
      masValen.length ? h('div', { class: 'lista-filas', id: 'valor-top' }, masValen.slice(0, 10).map((x) => h('div', { class: 'fila-parte' },
        h('div', { class: 'fila' }, h('span', {}, `${x.nombre} · ${cantidad(x.cantidad)} ${x.unidad || ''}`), monto(dinero(x.costo))), barraParte(x.costo, costo)))) : null,
    ].flat().filter(Boolean));

    const nombreBodega = bodega ? (bods.find((b) => b.id === bodega) || {}).nombre : 'Todas las bodegas';
    doc = { titulo: 'Inventario valorizado', periodo: `Al ${fecha(hoy())} · ${nombreBodega}`, notas: ['Al costo = costo promedio del inventario. A precio de venta = sin ISV.'],
      secciones: [
        { titulo: 'Productos', columnas: [{ titulo: 'Código' }, { titulo: 'Producto' }, { titulo: 'Categoría' }, { titulo: 'Cantidad', tipo: 'numero' }, { titulo: 'Mínimo', tipo: 'numero' },
          { titulo: 'Al costo', tipo: 'dinero' }, { titulo: 'A precio de venta', tipo: 'dinero' }],
          filas: masValen.map((x) => [x.codigo || '', x.nombre, x.categoria, x.cantidad, x.minimo, x.costo, x.venta]), total: ['', 'Total', '', null, null, costo, venta] },
        { titulo: 'Por categoría', columnas: [{ titulo: 'Categoría' }, { titulo: 'Productos', tipo: 'numero' }, { titulo: 'Al costo', tipo: 'dinero' }, { titulo: 'A precio de venta', tipo: 'dinero' }],
          filas: categorias.map((c) => [c.nombre, c.productos, c.costo, c.venta]), total: ['Total', conExistencia.length, costo, venta] },
        { titulo: 'Bajo el mínimo', columnas: [{ titulo: 'Producto' }, { titulo: 'Tiene', tipo: 'numero' }, { titulo: 'Mínimo', tipo: 'numero' }],
          filas: bajos.map((x) => [x.nombre, x.cantidad, x.minimo]) },
        ...(kardexCompleto ? [{ titulo: `Sin ventas en ${dias} días`, columnas: [{ titulo: 'Producto' }, { titulo: 'Cantidad', tipo: 'numero' }, { titulo: 'Al costo', tipo: 'dinero' }],
          filas: quietos.map((x) => [x.nombre, x.cantidad, x.costo]), total: ['Total', null, valorQuieto] }] : []),
      ] };
  }
  await cargar();
}
