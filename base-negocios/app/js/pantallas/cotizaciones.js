// Vender · "Cotizaciones": crear (mismo carrito de Vender, sin cobro) y convertir en venta
// (convertir_cotizacion_a_venta con la forma de pago). Una cotización vigente respeta lo cotizado.
import { leer, escribir, nuevoId } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fecha, aCentavos, cantidad as fCantidad } from '../formato.js';
import { h, aviso, cajaError, errorSimple, campo, conBoton, titulo, filaIcono, chipEstado, monto, estadoVacio, mensaje } from '../ui.js';
import { armarCarrito, puedeCobrar } from './vender.js';
import { vistaComprobante, nombreForma } from '../comprobante.js';

export async function mostrar(vista, ctx) {
  const lista = await leer('v_cotizacion', { empresa_id: empresaId(), estado: 'vigente' }, { orden: 'registrado_en.desc', limite: 200 });
  if (!ctx.sigueVigente()) return;
  const empezar = () => {
    vista.replaceChildren();
    armarCarrito(vista, ctx, { modo: 'cotizacion', alTerminar: () => { vista.replaceChildren(); mostrar(vista, ctx); } });
  };
  const nueva = h('button', { type: 'button', class: 'boton boton-principal', id: 'nueva-cotizacion', onclick: empezar }, 'Nueva cotización');
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cot' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'documento', 'Cotizaciones vigentes', { id: 't-cot' }), lista.length ? nueva : null),
    lista.length ? h('div', { class: 'lista-filas' }, lista.map((c) => filaIcono({
      icono: 'documento', color: 'azul',
      titulo: h('strong', {}, `Cotización #${c.numero}`),
      detalle: [`${c.cliente_nombre || 'Consumidor final'} · vence ${fecha(c.vigente_hasta)}${c.vendedor ? ' · ' + c.vendedor : ''}`, h('br'),
        (c.lineas || []).map((l) => `${fCantidad(l.cantidad)} ${l.descripcion}`).join(', ')],
      derecha: [monto(dinero(c.total_centavos)), chipEstado('vigente')],
      abajo: h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-principal', onclick: () => convertir(vista, ctx, c) }, 'Convertir en venta')),
      props: { dataset: { cotizacion: c.cotizacion_id } },
    })))
      : estadoVacio({ icono: 'documento', titulo: 'No hay cotizaciones vigentes',
        texto: 'Una cotización le dice al cliente cuánto le sale, sin cobrar ni sacar mercadería. Luego la convierte en venta con un toque.',
        boton: { texto: 'Hacer la primera', onclick: empezar, icono: 'mas', id: 'nueva-cotizacion' } })));
}

function convertir(vista, ctx, c) {
  const formas = puedeCobrar() ? ['efectivo', 'tarjeta', 'transferencia', 'credito'] : ['credito'];
  const sel = h('select', { id: 'conv-forma' }, formas.map((f) => h('option', { value: f }, nombreForma(f))));
  const recibido = h('input', { id: 'conv-recibido', type: 'text', inputmode: 'decimal', placeholder: '0.00' });
  const zonaRec = campo('Recibido del cliente (L)', recibido, 'Déjelo vacío si le pagan exacto.');
  sel.addEventListener('change', () => { zonaRec.hidden = sel.value !== 'efectivo'; });
  zonaRec.hidden = sel.value !== 'efectivo';
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, `Cobrar ${dinero(c.total_centavos)}`);
  const id = nuevoId(); // el mismo si se vuelve a tocar (no duplica)
  const form = h('form', { class: 'formulario', novalidate: true }, campo('Forma de pago', sel), zonaRec, zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => { vista.replaceChildren(); mostrar(vista, ctx); } }, 'Volver'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const pago = { forma: sel.value, monto_centavos: c.total_centavos };
    if (sel.value === 'efectivo' && recibido.value.trim()) {
      const r = aCentavos(recibido.value);
      if (r === null || r < c.total_centavos) { zonaError.append(errorSimple('Lo recibido no alcanza o no es un monto válido.')); return; }
      pago.recibido_centavos = r;
    }
    if (sel.value === 'credito' && !c.cliente_id) { zonaError.append(errorSimple('Para vender al crédito la cotización necesita cliente.')); return; }
    const r = await conBoton(boton, zonaError, () => escribir('convertir_cotizacion_a_venta', { p_cotizacion_id: c.cotizacion_id,
      p_datos: { pagos: [pago] }, p_id_operacion: id }), 'Cobrando…');
    if (!r) return;
    if (r.estado === 'pendiente_aprobacion') {
      aviso(`Venta #${r.numero} en espera de aprobación · ${dinero(c.total_centavos)}`, 'info');
      vista.replaceChildren(mensaje('info', `La venta #${r.numero} quedó esperando aprobación.`, 'Todavía no se cobró ni salió mercadería.'));
      return;
    }
    const hecho = `Venta ${r.numero_documento || '#' + r.numero} guardada · ${dinero(c.total_centavos)} ${sel.value === 'credito' ? 'al crédito' : 'en ' + nombreForma(sel.value).toLowerCase()}`;
    aviso(hecho);
    const cabeza = mensaje('ok', hecho, r.vuelto_centavos ? `Vuelto: ${dinero(r.vuelto_centavos)}` : null, { class: 'resultado' });
    try { vista.replaceChildren(cabeza, await vistaComprobante(r.venta_id)); } catch (err) { vista.replaceChildren(cabeza, await cajaError(err)); }
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-conv' },
    titulo('h1', 'vender', `Convertir cotización #${c.numero}`, { id: 't-conv' }),
    h('p', {}, `${c.cliente_nombre || 'Consumidor final'} · Total ${dinero(c.total_centavos)}`), form));
}
