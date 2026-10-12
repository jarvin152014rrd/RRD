// Vender · "Cotizaciones": crear (mismo carrito de Vender, sin cobro) y convertir en venta
// (convertir_cotizacion_a_venta con la forma de pago). Una cotización vigente respeta lo cotizado.
import { leer, escribir, nuevoId } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fecha, aCentavos, cantidad as fCantidad } from '../formato.js';
import { h, cajaError, errorSimple, campo, conBoton } from '../ui.js';
import { armarCarrito, puedeCobrar } from './vender.js';
import { vistaComprobante, nombreForma } from '../comprobante.js';

export async function mostrar(vista, ctx) {
  const lista = await leer('v_cotizacion', { empresa_id: empresaId(), estado: 'vigente' }, { orden: 'registrado_en.desc', limite: 200 });
  if (!ctx.sigueVigente()) return;
  const nueva = h('button', { type: 'button', class: 'boton boton-principal', id: 'nueva-cotizacion', onclick: () => {
    vista.replaceChildren();
    armarCarrito(vista, ctx, { modo: 'cotizacion', alTerminar: () => { vista.replaceChildren(); mostrar(vista, ctx); } });
  } }, 'Nueva cotización');
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cot' },
    h('div', { class: 'titulo-con-boton' }, h('h1', { id: 't-cot' }, 'Cotizaciones vigentes'), nueva),
    lista.length ? h('div', { class: 'lista' }, lista.map((c) => h('article', { class: 'venta-fila', dataset: { cotizacion: c.cotizacion_id } },
      h('div', {}, h('strong', {}, `Cotización #${c.numero}`),
        h('span', { class: 'detalle' }, `${c.cliente_nombre || 'Consumidor final'} · vence ${fecha(c.vigente_hasta)} · ${c.vendedor || ''}`),
        h('span', { class: 'detalle' }, (c.lineas || []).map((l) => `${fCantidad(l.cantidad)} ${l.descripcion}`).join(', '))),
      h('span', { class: 'monto' }, dinero(c.total_centavos)),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => convertir(vista, ctx, c) }, 'Convertir en venta')))))
      : h('p', { class: 'vacio' }, 'No hay cotizaciones vigentes.')));
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
      vista.replaceChildren(h('p', { class: 'mensaje mensaje-info' }, `La venta #${r.numero} quedó esperando aprobación.`));
      return;
    }
    try { vista.replaceChildren(await vistaComprobante(r.venta_id)); } catch (err) { vista.replaceChildren(await cajaError(err)); }
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-conv' },
    h('h1', { id: 't-conv' }, `Convertir cotización #${c.numero}`),
    h('p', {}, `${c.cliente_nombre || 'Consumidor final'} · Total ${dinero(c.total_centavos)}`), form));
}
