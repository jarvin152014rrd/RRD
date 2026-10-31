// Inventario · "Capital muerto" (núcleo 0.21.0, capital_muerto; idea de RRD "Repuestos sin movimiento").
// Productos con existencias que no se venden desde hace X días: cuánto hay, la última venta y cuánto dinero hay parado
// (al costo; solo con inventario.costos). Lo calcula el servidor; la app solo muestra.
import { rpc } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, cantidad, fecha } from '../formato.js';
import { h, cajaError, titulo, tarjetaCifra, estadoVacio, mensaje, tabla } from '../ui.js';
import { botonesReporte, barraParte } from '../reportes.js';

let dias = 90;

export async function mostrar(vista, ctx) {
  const selDias = h('select', { id: 'cm-dias' }, [30, 60, 90, 180, 365].map((d) => h('option', { value: String(d) }, `${d} días`)));
  selDias.value = String(dias);
  const zona = h('div', { class: 'lista' });
  let doc = null;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cm' },
    titulo('h1', 'reloj', 'Capital muerto', { id: 't-cm' }),
    h('p', { class: 'ayuda' }, 'Productos que tiene guardados y no se venden. Es dinero parado: puede hacerles una promoción, cambiarlos con el proveedor o dejar de comprarlos.'),
    h('div', { class: 'dos-columnas filtros' }, h('div', { class: 'campo' }, h('label', { for: 'cm-dias' }, 'Sin venderse desde hace'), selDias)),
    botonesReporte('cm', () => doc), zona));
  selDias.addEventListener('change', () => { dias = Number(selDias.value); cargar(); });

  async function cargar() {
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    doc = null;
    let r;
    try { r = await rpc('capital_muerto', { p_empresa_id: empresaId(), p_dias: dias }); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;
    const filas = r.filas || [];
    const t = r.total || {};
    const conCosto = !r.costos_ocultos;
    const totalValor = Number(t.valor_centavos) || 0;
    zona.replaceChildren(...[
      r.solo_mis_sucursales ? mensaje('info', 'Usted ve solo lo de sus sucursales.') : null,
      h('div', { class: 'cifras' },
        tarjetaCifra({ dato: 'cm-productos', icono: 'etiqueta', color: filas.length ? 'dorado' : 'verde', etiqueta: 'Productos sin venderse', valor: String(t.productos || 0), nota: `en ${dias} días o más` }),
        conCosto ? tarjetaCifra({ dato: 'cm-valor', icono: 'billetes', color: totalValor ? 'rojo' : 'verde', etiqueta: 'Dinero parado', valor: dinero(totalValor), nota: 'a lo que le costó' }) : null),
      filas.length ? tabla({ props: { id: 'cm-tabla' },
        columnas: [{ titulo: 'Producto' }, { titulo: 'Hay', num: true }, { titulo: 'Última venta' }, { titulo: 'Días sin vender', num: true }, ...(conCosto ? [{ titulo: 'Dinero parado', num: true }] : [])],
        filas: filas.map((x) => [h('div', {}, h('strong', {}, x.nombre), ' ', h('span', { class: 'detalle' }, x.codigo || ''),
            conCosto && totalValor ? barraParte(x.valor_centavos, totalValor) : null),
          `${cantidad(x.hay)} ${x.unidad}`, x.ultima_venta ? fecha(x.ultima_venta) : 'Nunca', String(x.dias_sin_vender),
          ...(conCosto ? [{ contenido: dinero(x.valor_centavos), props: { dataset: { dato: 'valor' } } }] : [])]),
        filaProps: (i) => ({ dataset: { producto: filas[i].producto_id } }) })
        : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: `Ningún producto lleva ${dias} días o más sin venderse.` }),
      h('p', { class: 'ayuda' }, r.nota || '')].filter(Boolean));
    doc = { titulo: 'Capital muerto', periodo: `Sin venderse en ${dias} días o más, al ${fecha(r.al)}`, notas: [r.nota].filter(Boolean),
      secciones: [{ titulo: 'Productos', columnas: [{ titulo: 'Producto' }, { titulo: 'Código' }, { titulo: 'Hay', tipo: 'numero' }, { titulo: 'Última venta' },
        { titulo: 'Días sin vender', tipo: 'numero' }, ...(conCosto ? [{ titulo: 'Dinero parado', tipo: 'dinero' }] : [])],
      filas: filas.map((x) => [x.nombre, x.codigo || '', x.hay, x.ultima_venta ? fecha(x.ultima_venta) : 'Nunca', x.dias_sin_vender, ...(conCosto ? [x.valor_centavos] : [])]),
      ...(conCosto ? { total: ['Total', '', null, '', null, totalValor] } : {}) }] };
  }
  await cargar();
}
