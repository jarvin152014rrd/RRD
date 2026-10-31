// Vender · "Ventas del día": las ventas de hoy (con ventas.ver todas; si no, las propias),
// con su comprobante y el botón para empezar una devolución.
// App 0.14.0: arriba, las ventas guardadas en ESTE equipo (cola sin internet) con su estado: En el equipo (gris),
// Subida (verde) o Con problema (rojo, con la razón). Sin conexión solo salen esas.
import { leer } from '../api.js';
import { empresaId, perfilActual, puede, modoSinInternet } from '../sesion.js';
import * as si from '../sin_internet.js';
import { vistaComprobanteLocal } from '../comprobante.js';
import { fechaLocal } from '../calculo_local.js';
import { dinero, fechaHora } from '../formato.js';
import { h, cajaError, titulo, filaIcono, chipEstado, monto, estadoVacio, filtrosRapidos } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { vistaComprobante } from '../comprobante.js';
import { prepararDevolucion } from './devoluciones.js';

const ESTADOS = { en_equipo: 'En el equipo', subida: 'Subida', por_resolver: 'Con problema', rechazada: 'Con problema' };

export async function mostrar(vista, ctx) {
  const perfil = perfilActual();
  const zona = perfil.empresa.zona_horaria || 'America/Tegucigalpa';
  const hoy = fechaLocal(Date.now(), zona);
  const locales = (await si.cola(empresaId())).filter((x) => x.usuario_id === perfil.usuario.id
    && (x.estado !== 'subida' || fechaLocal(Date.parse(x.creada_en), zona) === hoy)).reverse();
  const ventas = modoSinInternet() ? [] : await leer('v_venta', { empresa_id: empresaId(), fecha_contable: perfil.empresa.hoy },
    { orden: 'registrado_en.desc', limite: 300 });
  if (!ctx.sigueVigente()) return;
  if (locales.length) vista.append(tarjetaEquipo(vista, locales, () => mostrar(vista.replaceChildren() || vista, ctx)));
  if (modoSinInternet()) {
    if (!locales.length) vista.append(estadoVacio({ icono: 'vender', titulo: 'Sin ventas guardadas en este equipo', texto: 'Las ventas que haga sin internet salen aquí.' }));
    return;
  }
  const lista = h('div', { class: 'lista-filas' });
  // Filtros rápidos (app 0.15.0): cuántas de contado, al crédito, en espera y anuladas; tocar uno filtra la lista.
  const clase = (v) => (v.estado === 'emitida' ? (v.condicion === 'credito' ? 'credito' : 'contado') : v.estado === 'anulada' ? 'anulada' : 'otra');
  let filtro = 'todas';
  const cuenta = (c) => ventas.filter((v) => clase(v) === c).length;
  const filtros = ventas.length > 1 ? filtrosRapidos({ id: 'filtro-ventas', etiqueta: 'Ver ventas', actual: filtro, alCambiar: (f) => { filtro = f; pintarLista(); },
    opciones: [{ id: 'todas', texto: 'Todas', n: ventas.length, siempre: true, color: 'azul' }, { id: 'contado', texto: 'Contado', n: cuenta('contado'), color: 'verde' },
      { id: 'credito', texto: 'Crédito', n: cuenta('credito'), color: 'azul' }, { id: 'otra', texto: 'En espera', n: cuenta('otra'), color: 'dorado' },
      { id: 'anulada', texto: 'Anuladas', n: cuenta('anulada'), color: 'rojo' }] }) : null;
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-dia' },
    titulo('h1', 'lista', 'Ventas del día', { id: 't-dia' }),
    puede('ventas.ver') ? null : h('p', { class: 'ayuda' }, 'Aquí salen las ventas que usted hizo hoy.'), filtros, lista);
  const pintarLista = () => {
    const vistas = filtro === 'todas' ? ventas : ventas.filter((v) => clase(v) === filtro);
    lista.replaceChildren(...(vistas.length ? vistas.map((v) => {
      const emitida = v.estado === 'emitida';
      return filaIcono({
        icono: v.estado === 'anulada' ? 'anular' : 'recibo', color: emitida ? 'verde' : v.estado === 'anulada' ? 'rojo' : 'dorado',
        titulo: h('strong', {}, v.numero_documento || `Venta #${v.numero}`),
        detalle: `${fechaHora(v.emitida_en || v.registrado_en)} · ${v.cliente_nombre || 'Consumidor final'}`,
        derecha: [monto(dinero(v.total_centavos), { sentido: emitida ? 'entra' : null }),
          emitida ? chipEstado(v.condicion === 'credito' ? 'credito' : 'contado') : chipEstado(v.estado)],
        abajo: h('div', { class: 'botones' },
          ['emitida', 'anulada'].includes(v.estado) ? h('button', { type: 'button', class: 'boton', 'aria-label': `Comprobante de ${v.numero_documento || 'la venta #' + v.numero}`, onclick: () => verComprobante(v) }, 'Comprobante') : null,
          emitida && puede('ventas.devolver') ? h('button', { type: 'button', class: 'boton', 'aria-label': `Devolver de ${v.numero_documento || 'la venta #' + v.numero}`,
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

// Ventas guardadas en este equipo (la cola) con su estado.
function tarjetaEquipo(vista, locales, volverAPintar) {
  const pend = locales.filter((x) => x.estado === 'en_equipo').length;
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-equipo', id: 'ventas-equipo' },
    titulo('h2', 'subir', 'Guardadas en este equipo', { id: 't-equipo' }),
    pend ? h('p', { class: 'ayuda' }, `${pend} por subir: se suben solas cuando hay internet.`) : null,
    h('div', { class: 'lista-filas' }, locales.map((x) => filaIcono({
      icono: 'recibo', color: x.estado === 'subida' ? 'verde' : x.estado === 'en_equipo' ? 'neutro' : 'rojo',
      titulo: h('strong', {}, x.numero_documento),
      detalle: [fechaHora(x.creada_en), (x.comprobante && x.comprobante.cliente && x.comprobante.cliente.nombre) || 'Consumidor final',
        x.estado === 'por_resolver' && x.resultado ? x.resultado.problema_texto : null, x.estado === 'rechazada' ? x.ultimo_error : null].filter(Boolean).join(' · '),
      derecha: [monto(dinero(x.total_centavos)), h('span', { class: 'estado-equipo', dataset: { estado: x.estado } }, ESTADOS[x.estado] || x.estado)],
      abajo: h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', 'aria-label': `Comprobante de ${x.numero_documento}`,
        onclick: () => {
          const volver = h('button', { type: 'button', class: 'boton', onclick: () => volverAPintar() }, 'Volver');
          vista.replaceChildren(vistaComprobanteLocal(x, { extra: [volver] }));
        } }, 'Comprobante')),
      props: { class: 'venta-fila-icono', dataset: { local: x.id_operacion, estado: x.estado } },
    }))));
  return tarjeta;
}
