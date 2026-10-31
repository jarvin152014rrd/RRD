// Inventario · "¿Qué comprar?" (núcleo 0.21.0, que_comprar; idea de RRD "Rotación: qué comprar más").
// Por producto: lo vendido (neto de devoluciones) en los últimos días, cuánto sale por día, lo que hay, para cuántos días
// alcanza y cuánto conviene pedir (para cubrir los días elegidos o llegar al mínimo). TODO lo calcula el servidor:
// la app solo muestra. Costo aproximado del pedido solo con inventario.costos.
import { rpc } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, cantidad, fecha } from '../formato.js';
import { h, cajaError, titulo, tarjetaCifra, chip, estadoVacio, mensaje, tabla, filtrosRapidos } from '../ui.js';
import { botonesReporte } from '../reportes.js';

const ESTADO = { agotado: ['Agotado', 'rojo'], urgente: ['Se acaba en días', 'rojo'], bajo_minimo: ['Bajo el mínimo', 'dorado'], pedir: ['Conviene pedir', 'azul'], alcanza: ['Alcanza', 'verde'] };
let dias = 30, cubrir = 30;

export async function mostrar(vista, ctx) {
  const opciones = (sel, valores) => valores.forEach((d) => sel.append(h('option', { value: String(d) }, `${d} días`)));
  const selDias = h('select', { id: 'qc-dias' }); opciones(selDias, [15, 30, 60, 90]); selDias.value = String(dias);
  const selCubrir = h('select', { id: 'qc-cubrir' }); opciones(selCubrir, [15, 30, 45, 60, 90]); selCubrir.value = String(cubrir);
  const zona = h('div', { class: 'lista' });
  let doc = null;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-qc' },
    titulo('h1', 'compras', '¿Qué comprar?', { id: 't-qc' }),
    h('p', { class: 'ayuda' }, 'Lo que más se vende y lo que se va a acabar, con cuánto conviene pedir. Es una sugerencia: usted decide.'),
    h('div', { class: 'dos-columnas filtros' },
      h('div', { class: 'campo' }, h('label', { for: 'qc-dias' }, 'Mirar las ventas de los últimos'), selDias),
      h('div', { class: 'campo' }, h('label', { for: 'qc-cubrir' }, 'Comprar para que alcance'), selCubrir)),
    botonesReporte('qc', () => doc), zona));
  selDias.addEventListener('change', () => { dias = Number(selDias.value); cargar(); });
  selCubrir.addEventListener('change', () => { cubrir = Number(selCubrir.value); cargar(); });

  async function cargar() {
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    doc = null;
    let r;
    try { r = await rpc('que_comprar', { p_empresa_id: empresaId(), p_dias: dias, p_cubrir_dias: cubrir }); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;
    const filas = r.filas || [];
    const t = r.total || {};
    const conCosto = !r.costos_ocultos;
    let filtro = 'pedir';
    const n = (f) => (f === 'pedir' ? filas.filter((x) => Number(x.pedir) > 0) : f === 'todos' ? filas : filas.filter((x) => x.estado === f)).length;
    const tablaZona = h('div', {});
    const pintar = () => {
      const vistos = filtro === 'todos' ? filas : filtro === 'pedir' ? filas.filter((x) => Number(x.pedir) > 0) : filas.filter((x) => x.estado === filtro);
      tablaZona.replaceChildren(vistos.length ? tabla({ props: { id: 'qc-tabla' },
        columnas: [{ titulo: 'Producto' }, { titulo: `Vendido (${dias} días)`, num: true }, { titulo: 'Por día', num: true }, { titulo: 'Hay', num: true },
          { titulo: 'Alcanza', num: true }, { titulo: 'Pedir', num: true }, ...(conCosto ? [{ titulo: 'Costo aprox.', num: true }] : [])],
        filas: vistos.map((x) => {
          const [et, c] = ESTADO[x.estado] || [x.estado, 'neutro'];
          return [h('span', {}, h('strong', {}, x.nombre), ' ', h('span', { class: 'detalle' }, x.codigo || ''), ' ', chip(et, c)),
            `${cantidad(x.vendido)} ${x.unidad}`, cantidad(x.por_dia), `${cantidad(x.hay)} ${x.unidad}`,
            x.dias_alcanza === null || x.dias_alcanza === undefined ? '—' : `${x.dias_alcanza} ${x.dias_alcanza === 1 ? 'día' : 'días'}`,
            { contenido: h('strong', {}, Number(x.pedir) > 0 ? `${cantidad(x.pedir)} ${x.unidad}` : '—'), props: { dataset: { dato: 'pedir' } } },
            ...(conCosto ? [x.costo_aprox_centavos ? dinero(x.costo_aprox_centavos) : '—'] : [])];
        }),
        filaProps: (i) => ({ dataset: { producto: vistos[i].producto_id } }) })
        : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: filtro === 'pedir' ? 'Por ahora no hace falta pedir nada.' : 'No hay productos aquí.' }));
    };
    zona.replaceChildren(...[
      r.solo_mis_sucursales ? mensaje('info', 'Usted ve solo lo de sus sucursales.') : null,
      h('div', { class: 'cifras' },
        tarjetaCifra({ dato: 'qc-pedir', icono: 'compras', color: t.por_pedir ? 'dorado' : 'verde', etiqueta: 'Conviene pedir', valor: String(t.por_pedir || 0), nota: 'productos' }),
        tarjetaCifra({ dato: 'qc-agotados', icono: 'alerta', color: t.agotados ? 'rojo' : 'verde', etiqueta: 'Agotados que se venden', valor: String(t.agotados || 0) }),
        tarjetaCifra({ dato: 'qc-urgentes', icono: 'reloj', color: t.urgentes ? 'rojo' : 'verde', etiqueta: 'Se acaban en menos de 7 días', valor: String(t.urgentes || 0) }),
        conCosto ? tarjetaCifra({ dato: 'qc-costo', icono: 'billetes', color: 'azul', etiqueta: 'Costo aproximado del pedido', valor: dinero(t.costo_aprox_centavos || 0), nota: 'al costo promedio de hoy' }) : null),
      filas.length ? filtrosRapidos({ id: 'filtro-qc', etiqueta: 'Ver', actual: filtro, alCambiar: (f) => { filtro = f; pintar(); },
        opciones: [{ id: 'pedir', texto: 'Conviene pedir', n: n('pedir'), siempre: true, color: 'dorado' }, { id: 'agotado', texto: 'Agotados', n: n('agotado'), color: 'rojo' },
          { id: 'urgente', texto: 'Se acaban pronto', n: n('urgente'), color: 'rojo' }, { id: 'todos', texto: 'Todos los que se venden', n: n('todos'), siempre: true, color: 'azul' }] }) : null,
      tablaZona,
      h('p', { class: 'ayuda' }, r.nota || '')].filter(Boolean));
    pintar();
    doc = { titulo: '¿Qué comprar?', periodo: `Ventas del ${fecha(r.desde)} al ${fecha(r.hasta)} · para ${cubrir} días`, notas: [r.nota].filter(Boolean),
      secciones: [{ titulo: 'Productos', columnas: [{ titulo: 'Producto' }, { titulo: 'Código' }, { titulo: 'Vendido', tipo: 'numero' }, { titulo: 'Por día', tipo: 'numero' },
        { titulo: 'Hay', tipo: 'numero' }, { titulo: 'Días que alcanza', tipo: 'numero' }, { titulo: 'Pedir', tipo: 'numero' }, ...(conCosto ? [{ titulo: 'Costo aprox.', tipo: 'dinero' }] : [])],
      filas: filas.map((x) => [x.nombre, x.codigo || '', x.vendido, x.por_dia, x.hay, x.dias_alcanza, x.pedir, ...(conCosto ? [x.costo_aprox_centavos] : [])]),
      ...(conCosto ? { total: ['Total', '', null, null, null, null, null, t.costo_aprox_centavos] } : {}) }] };
  }
  await cargar();
}
