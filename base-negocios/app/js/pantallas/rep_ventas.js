// Reportes · "Ventas" (app 0.8.0). Solo mirar.
//   Por día, semana o mes con su gráfica y por forma de pago: v_ventas_por_caja (núcleo 029; un usuario
//   limitado a su sucursal ve solo sus cajas). Por vendedor: v_ventas_por_vendedor (de toda la empresa: a un
//   usuario limitado no se le muestra). Lo más vendido: mas_vendido (núcleo 0.16.0: suma el servidor y resta
//   devoluciones); con un núcleo anterior, v_venta_linea (hasta 1,000 líneas, sin restar devoluciones).
//   Las cifras son lo FACTURADO (ventas emitidas, con ISV): NO restan devoluciones; las devoluciones del
//   período (v_devolucion, aplicadas) se muestran aparte. Las anuladas no cuentan.
import { leer, rpcSiExiste } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fecha, cantidad, sumarDias } from '../formato.js';
import { h, cajaError, titulo, tarjetaCifra, monto, estadoVacio, mensaje, tabla, graficaBarras, filaIcono } from '../ui.js';
import { alcance, reiniciarAlSalir } from '../datos.js';
import { hoy } from '../formularios.js';
import { selectorPeriodo, periodoInicial, datosPeriodo, botonesReporte, barraParte, hastaHoy, llegoAlTope, TOPE_FILAS, MESES } from '../reportes.js';

let periodo = periodoInicial();
let agrupar = 'dia';
reiniciarAlSalir(() => { periodo = periodoInicial(); agrupar = 'dia'; });

const AGRUPAR = { dia: 'Por día', semana: 'Por semana', mes: 'Por mes' };
const FORMAS = [['efectivo_centavos', 'Efectivo', 'billetes'], ['tarjeta_centavos', 'Tarjeta', 'cuenta'], ['transferencia_centavos', 'Transferencia', 'banco'],
  ['credito_centavos', 'Al crédito (por cobrar)', 'cobrar']];

// Lunes de la semana de una fecha "AAAA-MM-DD".
export function lunesDe(iso) {
  const [a, m, d] = iso.split('-').map(Number);
  const dia = new Date(Date.UTC(a, m - 1, d, 12)).getUTCDay(); // 0 = domingo
  return sumarDias(iso, dia === 0 ? -6 : 1 - dia);
}
// Clave y texto del grupo de una fecha.
export function grupoDe(iso, como) {
  if (como === 'mes') return { clave: iso.slice(0, 7), texto: `${MESES[Number(iso.slice(5, 7)) - 1].slice(0, 3)} ${iso.slice(0, 4)}` };
  if (como === 'semana') { const l = lunesDe(iso); return { clave: l, texto: `Semana del ${fecha(l).slice(0, 5)}` }; }
  return { clave: iso, texto: fecha(iso).slice(0, 5) };
}
// Suma las filas de v_ventas_por_caja por grupo (todas las fechas del rango, aunque no haya ventas).
export function agruparVentas(filas, desde, hasta, como) {
  const grupos = new Map();
  for (let f = desde; f <= hasta; f = sumarDias(f, 1)) {
    const g = grupoDe(f, como);
    if (!grupos.has(g.clave)) grupos.set(g.clave, { ...g, ventas: 0, total_centavos: 0 });
  }
  for (const x of filas) {
    const g = grupos.get(grupoDe(x.fecha, como).clave);
    if (!g) continue;
    g.ventas += Number(x.ventas) || 0;
    g.total_centavos += Number(x.total_centavos) || 0;
  }
  return [...grupos.values()];
}
const corto = (c) => { const n = Math.round(Number(c) / 100); return `L ${n >= 1000 ? Math.round(n / 100) / 10 + 'k' : n}`; };

export async function mostrar(vista, ctx) {
  const al = await alcance();
  if (!ctx.sigueVigente()) return;
  const selAgrupar = h('select', { id: 'ventas-agrupar' }, Object.entries(AGRUPAR).map(([v, t]) => h('option', { value: v }, t)));
  selAgrupar.value = agrupar;
  const zona = h('div', { class: 'lista' });
  let doc = null;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-rventas' },
    titulo('h1', 'grafica', 'Ventas', { id: 't-rventas' }),
    selectorPeriodo({ prefijo: 'ventas', periodo, alCambiar: (p) => { periodo = p; cargar(); }, maxDias: 366 }),
    h('div', { class: 'dos-columnas filtros' }, h('div', { class: 'campo' }, h('label', { for: 'ventas-agrupar' }, '¿Cómo agrupar?'), selAgrupar)),
    botonesReporte('ventas', () => doc), zona));
  selAgrupar.addEventListener('change', () => { agrupar = selAgrupar.value; cargar(); });

  async function cargar() {
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    doc = null;
    const dp = datosPeriodo(periodo);
    const hasta = hastaHoy(dp.hasta);
    const f = { empresa_id: empresaId(), fecha: { gte: dp.desde, lte: hasta } };
    let porCaja, porVendedor, mv, lineas = [], devs;
    try {
      [porCaja, porVendedor, mv, devs] = await Promise.all([
        leer('v_ventas_por_caja', f, { orden: 'fecha.asc', limite: TOPE_FILAS }),
        al.limitado ? null : leer('v_ventas_por_vendedor', f, { orden: 'fecha.asc', limite: TOPE_FILAS }),
        desdeHasta(dp.desde, hasta) ? rpcSiExiste('mas_vendido', { p_empresa_id: empresaId(), p_desde: dp.desde, p_hasta: hasta, p_limite: 10 }) : { filas: [] },
        leer('v_devolucion', { empresa_id: empresaId(), estado: 'aplicada', fecha_contable: { gte: dp.desde, lte: hasta } }, { limite: TOPE_FILAS }),
      ]);
      // Núcleo anterior a 0.16.0 (sin mas_vendido): se suman las líneas en el navegador.
      if (!mv) lineas = await leer('v_venta_linea', { empresa_id: empresaId(), estado: 'emitida', fecha_contable: { gte: dp.desde, lte: hasta } }, { orden: 'fecha_contable.desc', limite: TOPE_FILAS });
    } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;

    const suma = (lista, k) => lista.reduce((s, x) => s + (Number(x[k]) || 0), 0);
    const total = suma(porCaja, 'total_centavos'), nVentas = suma(porCaja, 'ventas');
    const formas = FORMAS.map(([k, t, ic]) => ({ k, t, ic, v: suma(porCaja, k) }));
    const otras = total - formas.reduce((s, x) => s + x.v, 0);
    if (otras) formas.push({ k: 'otras', t: 'Saldo a favor o anticipo', ic: 'capas', v: otras });
    const grupos = desdeHasta(dp.desde, hasta) ? agruparVentas(porCaja, dp.desde, hasta, agrupar) : [];
    const totalDev = suma(devs, 'total_centavos');

    // Por vendedor
    const vend = new Map();
    for (const x of porVendedor || []) {
      const v = vend.get(x.vendedor_id) || { nombre: x.vendedor || 'Sin nombre', ventas: 0, total: 0, credito: 0 };
      v.ventas += Number(x.ventas) || 0; v.total += Number(x.total_centavos) || 0; v.credito += Number(x.credito_centavos) || 0;
      vend.set(x.vendedor_id, v);
    }
    const vendedores = [...vend.values()].sort((a, b) => b.total - a.total);
    // Lo más vendido (por producto): del servidor, ya restadas las devoluciones; o sumado aquí (núcleo viejo).
    let top;
    if (mv) {
      top = (mv.filas || []).map((x) => ({ nombre: x.nombre, codigo: x.codigo, cantidad: Number(x.cantidad_neta) || 0, total: Number(x.total_neto_centavos) || 0,
        devuelto: Number(x.cantidad_devuelta) || 0 }));
    } else {
      const prods = new Map();
      for (const l of lineas) {
        const p = prods.get(l.producto_id) || { nombre: l.descripcion, codigo: l.codigo, cantidad: 0, total: 0, devuelto: 0 };
        p.cantidad += Number(l.cantidad) || 0; p.total += Number(l.total_centavos) || 0;
        prods.set(l.producto_id, p);
      }
      top = [...prods.values()].sort((a, b) => b.total - a.total).slice(0, 10);
    }

    const muchas = grupos.length > 16;
    const graf = graficaBarras(grupos.map((g, i) => ({ etiqueta: muchas && i % Math.ceil(grupos.length / 8) !== 0 ? '' : g.texto, valor: g.total_centavos,
      texto: dinero(g.total_centavos), textoCorto: corto(g.total_centavos), dato: g.clave, destacado: g.clave === grupoDe(hoy(), agrupar).clave })),
    { titulo: `Ventas ${AGRUPAR[agrupar].toLowerCase()}` });
    graf.id = 'grafica-rventas';
    if (muchas) graf.classList.add('grafica-densa');

    const avisoTope = [porCaja, porVendedor || [], lineas, devs].some(llegoAlTope);
    zona.replaceChildren(...[
      mensaje('info', 'Estas cifras son lo facturado (con ISV): no restan las devoluciones.',
        totalDev ? `En estas fechas hubo devoluciones por ${dinero(totalDev)}. Las ventas sin devoluciones están en "¿Gané o perdí?".` : 'En estas fechas no hubo devoluciones. Las ventas anuladas no se cuentan.',
        { dataset: { info: 'devoluciones' } }),
      avisoTope ? mensaje('info', `Hay muchas ventas en estas fechas: se leyeron las primeras ${TOPE_FILAS.toLocaleString('en-US')} filas.`, 'Acorte las fechas para ver las cifras completas.', { dataset: { info: 'tope-filas' } }) : null,
      h('div', { class: 'cifras' },
        tarjetaCifra({ dato: 'ventas-total', icono: 'sube', color: 'verde', etiqueta: 'Vendí', valor: dinero(total), nota: `${nVentas} ${nVentas === 1 ? 'venta' : 'ventas'}` }),
        tarjetaCifra({ dato: 'ventas-promedio', icono: 'recibo', color: 'azul', etiqueta: 'Promedio por venta', valor: dinero(nVentas ? Math.round(total / nVentas) : 0) }),
        tarjetaCifra({ dato: 'ventas-devoluciones', icono: 'devolucion', color: totalDev ? 'rojo' : 'neutro', etiqueta: 'Devoluciones (aparte)', valor: dinero(totalDev),
          nota: `${devs.length} ${devs.length === 1 ? 'devolución' : 'devoluciones'}` })),
      nVentas ? graf : estadoVacio({ icono: 'grafica', chico: true, texto: 'No hay ventas en estas fechas.' }),
      nVentas ? tabla({ props: { id: 'tabla-rventas' }, columnas: [{ titulo: AGRUPAR[agrupar].replace('Por ', '').replace(/^./, (x) => x.toUpperCase()) }, { titulo: 'Ventas', num: true }, { titulo: 'Total', num: true }],
        filas: grupos.filter((g) => g.ventas).map((g) => [g.texto, String(g.ventas), monto(dinero(g.total_centavos), { dato: `grupo-${g.clave}` })]) }) : null,
      h('h2', { class: 'titulo-chico' }, 'Por forma de pago'),
      h('div', { class: 'lista-filas', id: 'ventas-formas' }, formas.map((x) => h('div', { class: 'fila-parte', dataset: { forma: x.k } },
        h('div', { class: 'fila' }, h('span', {}, x.t), monto(dinero(x.v), { sentido: x.v && x.k !== 'credito_centavos' ? 'entra' : null })),
        barraParte(x.v, total)))),
      h('h2', { class: 'titulo-chico' }, 'Por vendedor'),
      al.limitado ? h('p', { class: 'ayuda', dataset: { info: 'vendedor-limitado' } }, 'Las ventas por vendedor son de toda la empresa; usted trabaja solo con sus sucursales, por eso no las ve.')
        : vendedores.length ? tabla({ props: { id: 'tabla-vendedores' }, columnas: [{ titulo: 'Vendedor' }, { titulo: 'Ventas', num: true }, { titulo: 'Total', num: true }, { titulo: 'Al crédito', num: true }],
          filas: vendedores.map((v) => [v.nombre, String(v.ventas), monto(dinero(v.total)), dinero(v.credito)]) })
          : estadoVacio({ icono: 'usuarios', chico: true, texto: 'No hay ventas en estas fechas.' }),
      h('h2', { class: 'titulo-chico' }, 'Lo más vendido'),
      h('p', { class: 'ayuda', dataset: { info: mv ? 'top-con-devoluciones' : 'top-sin-devoluciones' } },
        mv ? 'Ya restadas las devoluciones de estas fechas.' : 'Sin restar devoluciones.'),
      top.length ? h('div', { class: 'lista-filas', id: 'ventas-top' }, top.map((p, i) => filaIcono({ icono: 'etiqueta', color: i === 0 ? 'dorado' : 'azul',
        titulo: h('strong', {}, p.nombre), detalle: `${cantidad(p.cantidad)} ${p.cantidad === 1 ? 'vendido' : 'vendidos'}${p.devuelto ? ` (${cantidad(p.devuelto)} devuelto${p.devuelto === 1 ? '' : 's'})` : ''}${p.codigo ? ' · ' + p.codigo : ''}`,
        derecha: monto(dinero(p.total)), props: { dataset: { topTotal: String(p.total) } } }))) : estadoVacio({ icono: 'etiqueta', chico: true, texto: 'No hay productos vendidos en estas fechas.' }),
    ].filter(Boolean));

    doc = { titulo: 'Ventas', periodo: dp.texto, notas: ['Lo facturado con ISV: no resta devoluciones. Las ventas anuladas no se cuentan.',
      `Devoluciones del período (aparte): ${dinero(totalDev)}.`, mv ? 'Lo más vendido: ya restadas las devoluciones.' : 'Lo más vendido: sin restar devoluciones.'],
      secciones: [
        { titulo: `Ventas ${AGRUPAR[agrupar].toLowerCase()}`, columnas: [{ titulo: 'Fecha' }, { titulo: 'Ventas', tipo: 'numero' }, { titulo: 'Total', tipo: 'dinero' }],
          filas: grupos.map((g) => [agrupar === 'dia' ? fecha(g.clave) : g.texto, g.ventas, g.total_centavos]), total: ['Total', nVentas, total] },
        { titulo: 'Por forma de pago', columnas: [{ titulo: 'Forma de pago' }, { titulo: 'Total', tipo: 'dinero' }], filas: formas.map((x) => [x.t, x.v]), total: ['Total', total] },
        ...(al.limitado ? [] : [{ titulo: 'Por vendedor', columnas: [{ titulo: 'Vendedor' }, { titulo: 'Ventas', tipo: 'numero' }, { titulo: 'Total', tipo: 'dinero' }, { titulo: 'Al crédito', tipo: 'dinero' }],
          filas: vendedores.map((v) => [v.nombre, v.ventas, v.total, v.credito]) }]),
        { titulo: 'Lo más vendido', columnas: [{ titulo: 'Producto' }, { titulo: 'Código' }, { titulo: 'Cantidad', tipo: 'numero' }, { titulo: 'Total', tipo: 'dinero' }],
          filas: top.map((p) => [p.nombre, p.codigo || '', p.cantidad, p.total]) },
      ] };
  }
  await cargar();
}

function desdeHasta(d, h2) { return d && h2 && d <= h2; }
