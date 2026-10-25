// Comprobante de venta (lo que da documento_venta): pantalla, impresión de 80 mm
// (css/base.css, @media print) y texto para WhatsApp. Sin íconos, sin emojis y sin colores de
// pantalla: solo texto y líneas. Los nombres que vienen del cliente se limpian con imprimible.js.
import { rpc } from './api.js';
import { perfilActual } from './sesion.js';
import { dinero, cantidad } from './formato.js';
import { h, enlaceWhatsApp } from './ui.js';
import { limpiarImprimible, sinEmojis } from './imprimible.js';

const FORMA = { efectivo: 'Efectivo', tarjeta: 'Tarjeta', transferencia: 'Transferencia', credito: 'Crédito',
  saldo_favor: 'Saldo a favor', anticipo: 'Anticipo' };
export function nombreForma(f) { return FORMA[f] || f; }

function fila(izq, der, clase = '') {
  return h('div', { class: 'comp-fila ' + clase }, h('span', {}, izq), h('span', { class: 'monto' }, der));
}

// Arma el comprobante. doc = documento_venta(venta).
export function comprobante(doc) {
  const t = doc.totales || {};
  const fiscal = doc.fiscal || {};
  const titulo = doc.tipo === 'FACTURA' || /factura/i.test(doc.tipo || '') ? 'FACTURA' : (doc.tipo || 'TICKET');
  return limpiarImprimible(h('article', { class: 'comprobante', 'aria-label': 'Comprobante de venta' },
    h('p', { class: 'comp-centro comp-negrita' }, doc.emisor.nombre),
    doc.emisor.rtn ? h('p', { class: 'comp-centro' }, 'RTN ' + doc.emisor.rtn) : null,
    h('p', { class: 'comp-centro' }, [doc.emisor.sucursal, doc.emisor.caja].filter(Boolean).join(' · ')),
    fiscal.cai ? h('p', { class: 'comp-centro' }, 'CAI ' + fiscal.cai) : null,
    h('p', { class: 'comp-centro comp-negrita', dataset: { dato: 'numero_documento' } }, `${titulo} ${doc.numero_documento || ''}`),
    doc.anulada ? h('p', { class: 'comp-centro comp-negrita' }, 'ANULADA') : null,
    h('p', {}, 'Fecha: ' + doc.fecha),
    h('p', {}, 'Cliente: ' + (doc.cliente && doc.cliente.nombre ? doc.cliente.nombre : 'Consumidor final'),
      doc.cliente && doc.cliente.rtn ? ' · RTN ' + doc.cliente.rtn : ''),
    doc.vendedor ? h('p', {}, 'Atendió: ' + doc.vendedor) : null,
    h('hr'),
    (doc.lineas || []).map((l) => h('div', { class: 'comp-linea' },
      h('p', {}, l.descripcion),
      fila(`${cantidad(l.cantidad)} x ${dinero(l.precio_unitario_centavos)}${l.descuento_centavos ? ' (desc. ' + dinero(l.descuento_centavos) + ')' : ''}`,
        dinero(l.total_centavos)),
      // Núcleo 0.18.0: precio mayorista y garantía, en texto (lo impreso va sin íconos).
      l.precio_tipo === 'mayorista' ? h('p', { class: 'comp-chico', dataset: { dato: 'precio-mayorista' } },
        'Precio mayorista' + (l.precio_normal_centavos ? ` (normal ${dinero(l.precio_normal_centavos)})` : '')) : null,
      l.garantia_hasta ? h('p', { class: 'comp-chico', dataset: { dato: 'garantia' } }, 'Garantía hasta ' + l.garantia_hasta) : null)),
    h('hr'),
    fila('Subtotal sin ISV', dinero(t.subtotal_centavos)),
    t.descuento_centavos ? fila('Descuento', '-' + dinero(t.descuento_centavos)) : null,
    (t.impuestos || []).filter((i) => i.impuesto_centavos).map((i) => fila(i.nombre, dinero(i.impuesto_centavos))),
    t.exento_centavos ? fila('Exento', dinero(t.exento_centavos)) : null,
    fila('TOTAL', dinero(t.total_centavos), 'comp-total'),
    t.total_en_letras ? h('p', { class: 'comp-chico' }, t.total_en_letras) : null,
    h('hr'),
    (doc.pagos || []).map((p) => [
      fila(nombreForma(p.forma) + (p.referencia ? ' ' + p.referencia : ''), dinero(p.monto_centavos)),
      p.recibido_centavos ? fila('Recibido', dinero(p.recibido_centavos)) : null,
      p.vuelto_centavos ? fila('Vuelto', dinero(p.vuelto_centavos), 'comp-negrita') : null,
    ]),
    doc.vence_el ? h('p', {}, 'Vence: ' + doc.vence_el) : null,
    fiscal.rango_desde ? h('p', { class: 'comp-chico' }, `Rango autorizado del ${fiscal.rango_desde} al ${fiscal.rango_hasta}`) : null,
    fiscal.fecha_limite_emision ? h('p', { class: 'comp-chico' }, 'Fecha límite de emisión: ' + fiscal.fecha_limite_emision) : null,
    (fiscal.leyendas || []).map((x) => h('p', { class: 'comp-chico comp-centro' }, x)),
    h('p', { class: 'comp-centro' }, 'Gracias por su compra')));
}

// Texto corto para mandar por WhatsApp.
export function textoWhatsApp(doc) {
  const t = doc.totales || {};
  const lineas = (doc.lineas || []).map((l) => `${cantidad(l.cantidad)} x ${l.descripcion}: ${dinero(l.total_centavos)}`
    + (l.precio_tipo === 'mayorista' ? ' (precio mayorista)' : '') + (l.garantia_hasta ? ` · Garantía hasta ${l.garantia_hasta}` : ''));
  return sinEmojis([`${doc.emisor.nombre}`, `${doc.tipo || 'Ticket'} ${doc.numero_documento} · ${doc.fecha}`, '', ...lineas, '',
    `Total: ${dinero(t.total_centavos)} (ISV ${dinero(t.impuesto_centavos)})`,
    doc.vence_el ? `Vence: ${doc.vence_el}` : null, 'Gracias por su compra.'].filter((x) => x !== null).join('\n'));
}

// Comprobante con sus botones (Imprimir, WhatsApp y los que se agreguen).
export async function vistaComprobante(ventaId, { telefono = '', extra = [] } = {}) {
  const doc = await rpc('documento_venta', { p_venta_id: ventaId });
  const empresa = perfilActual().empresa.nombre;
  return h('section', { class: 'tarjeta comprobante-tarjeta', 'aria-label': 'Comprobante' },
    comprobante(doc),
    h('div', { class: 'botones no-imprimir' },
      h('button', { type: 'button', class: 'boton boton-principal', onclick: () => window.print() }, 'Imprimir'),
      h('a', { class: 'boton', href: enlaceWhatsApp(telefono, textoWhatsApp(doc)), target: '_blank', rel: 'noopener',
        dataset: { accion: 'whatsapp' }, title: `Enviar el comprobante de ${empresa}` }, 'Enviar por WhatsApp'),
      ...extra));
}
