// Comprobante de venta (lo que da documento_venta): pantalla, impresión de 80 mm
// (css/base.css, @media print) y texto para WhatsApp. Sin íconos, sin emojis y sin colores de
// pantalla: solo texto y líneas. Los nombres que vienen del cliente se limpian con imprimible.js.
import { rpc } from './api.js';
import { perfilActual } from './sesion.js';
import { dinero, cantidad } from './formato.js';
import { h, enlaceWhatsApp } from './ui.js';
import { limpiarImprimible, sinEmojis } from './imprimible.js';
import { montoEnLetras } from './calculo_local.js';

const FORMA = { efectivo: 'Efectivo', tarjeta: 'Tarjeta', transferencia: 'Transferencia', credito: 'Crédito',
  saldo_favor: 'Saldo a favor', anticipo: 'Anticipo', cheque: 'Cheque' };
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
    // App 0.14.0: "Emitida sin conexión" y "Copia: obligado tributario emisor" (solo texto).
    (doc.notas || []).map((x) => h('p', { class: 'comp-centro comp-negrita', dataset: { dato: 'nota-comprobante' } }, x)),
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

// ---------------- Nota de crédito (app 0.13.0) ----------------
// Lo que da documento_nota_credito(devolución). Con el núcleo 0.19.0 trae el "Ajuste por perder precio mayorista".
// Sin íconos, sin emojis y sin colores: solo texto y líneas.
export function notaCredito(doc) {
  const t = doc.totales || {};
  const fiscal = doc.fiscal || {};
  const ajuste = Number(doc.ajuste_mayorista_centavos || 0);
  return limpiarImprimible(h('article', { class: 'comprobante', 'aria-label': 'Comprobante de la devolución' },
    h('p', { class: 'comp-centro comp-negrita' }, doc.emisor.nombre),
    doc.emisor.rtn ? h('p', { class: 'comp-centro' }, 'RTN ' + doc.emisor.rtn) : null,
    fiscal.cai ? h('p', { class: 'comp-centro' }, 'CAI ' + fiscal.cai) : null,
    h('p', { class: 'comp-centro comp-negrita', dataset: { dato: 'numero_nota' } }, `${doc.tipo || 'NOTA DE CRÉDITO'} ${doc.numero_documento || ''}`),
    h('p', {}, 'Fecha: ' + doc.fecha),
    h('p', {}, 'Cliente: ' + (doc.cliente && doc.cliente.nombre ? doc.cliente.nombre : 'Consumidor final'),
      doc.cliente && doc.cliente.rtn ? ' · RTN ' + doc.cliente.rtn : ''),
    h('p', {}, 'Modifica: ' + (doc.documento_que_modifica || '')),
    doc.motivo ? h('p', {}, 'Motivo: ' + doc.motivo) : null,
    h('hr'),
    (doc.lineas || []).map((l) => h('div', { class: 'comp-linea' },
      h('p', {}, `${cantidad(l.cantidad)} x ${l.descripcion}`),
      Number(l.ajuste_mayorista_centavos || 0) ? fila('Valor', dinero(l.valor_centavos)) : null,
      Number(l.ajuste_mayorista_centavos || 0) > 0 ? fila('Ajuste por perder precio mayorista', '-' + dinero(l.ajuste_mayorista_centavos)) : null,
      Number(l.ajuste_mayorista_centavos || 0) < 0 ? fila('Se devuelve el ajuste por precio mayorista', dinero(-l.ajuste_mayorista_centavos)) : null,
      fila('Se devuelve', dinero(l.total_centavos)))),
    h('hr'),
    ajuste ? fila('Valor de lo devuelto', dinero(doc.valor_devuelto_centavos)) : null,
    ajuste ? h('p', { class: 'comp-negrita', dataset: { dato: 'ajuste-mayorista' } }, doc.ajuste_mayorista_texto) : null,
    fila('Subtotal sin ISV', dinero(t.subtotal_centavos)),
    (t.impuestos || []).filter((i) => i.impuesto_centavos).map((i) => fila(i.nombre, dinero(i.impuesto_centavos))),
    fila('TOTAL', dinero(t.total_centavos), 'comp-total'),
    t.total_en_letras ? h('p', { class: 'comp-chico' }, t.total_en_letras) : null,
    fiscal.rango_autorizado ? h('p', { class: 'comp-chico' }, 'Rango autorizado del ' + fiscal.rango_autorizado) : null,
    fiscal.fecha_limite_emision ? h('p', { class: 'comp-chico' }, 'Fecha límite de emisión: ' + fiscal.fecha_limite_emision) : null,
    (fiscal.leyendas || []).map((x) => h('p', { class: 'comp-chico comp-centro' }, x))));
}

export async function vistaNotaCredito(devolucionId) {
  const doc = await rpc('documento_nota_credito', { p_devolucion_id: devolucionId });
  return h('section', { class: 'tarjeta comprobante-tarjeta', 'aria-label': 'Comprobante de la devolución' },
    notaCredito(doc),
    h('div', { class: 'botones no-imprimir' },
      h('button', { type: 'button', class: 'boton boton-principal', onclick: () => window.print() }, 'Imprimir')));
}

// ---------------- Comprobante de una venta SIN INTERNET (app 0.14.0) ----------------
// Se arma en el equipo con lo guardado en la cola (el número es el definitivo). Se imprime el ORIGINAL y la
// "Copia: obligado tributario emisor" (G3: la copia se guarda en la caja; sirve si el equipo se pierde).
const fechaHoraLocal = (iso, zona) => new Intl.DateTimeFormat('es-HN', { timeZone: zona || 'America/Tegucigalpa',
  day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso));
const fechaCorta = (aaaammdd) => (aaaammdd ? aaaammdd.split('-').reverse().join('/') : '');

export function documentoLocal(reg, copia = false) {
  const c = reg.comprobante || {};
  const calc = c.calculo || {};
  const p = reg.payload;
  const factura = p.tipo_documento === 'factura';
  const cai = c.cai || {};
  const pagos = (p.pagos || []).map((x) => ({ forma: x.forma, referencia: [x.referencia, x.banco].filter(Boolean).join(' · ') || null,
    monto_centavos: x.monto_centavos, recibido_centavos: x.recibido_centavos || null,
    vuelto_centavos: x.recibido_centavos ? x.recibido_centavos - x.monto_centavos : null }));
  return {
    tipo: factura ? 'FACTURA' : 'TICKET', numero_documento: reg.numero_documento,
    emisor: { nombre: (c.emisor && c.emisor.nombre) || '', rtn: c.emisor && c.emisor.rtn, caja: c.caja },
    fecha: fechaHoraLocal(p.hora_equipo, c.zona), cliente: c.cliente, vendedor: c.vendedor,
    lineas: (calc.lineas || []).map((l) => ({ descripcion: l.descripcion, cantidad: l.cantidad, precio_unitario_centavos: l.precio_unitario_centavos,
      descuento_centavos: l.descuento_con_isv_centavos || 0, total_centavos: l.total_centavos, precio_tipo: l.precio_tipo,
      precio_normal_centavos: l.precio_normal_centavos })),
    totales: { subtotal_centavos: calc.subtotal_centavos, descuento_centavos: calc.descuento_centavos,
      impuestos: (calc.desglose_impuestos || []).filter((d) => d.clase === 'gravado').map((d) => ({ nombre: `${d.nombre}`, impuesto_centavos: d.impuesto_centavos })),
      exento_centavos: calc.exento_centavos, total_centavos: calc.total_centavos, impuesto_centavos: calc.impuesto_centavos,
      total_en_letras: montoEnLetras(calc.total_centavos, c.moneda || 'HNL') },
    pagos,
    fiscal: factura ? { cai: cai.cai, rango_desde: cai.rango_desde, rango_hasta: cai.rango_hasta,
      fecha_limite_emision: fechaCorta(cai.fecha_limite_emision),
      leyendas: ['La factura es beneficio de todos. ¡Exíjala!', 'Original: Cliente. Copia: Obligado tributario emisor.',
        !(c.cliente && c.cliente.rtn) ? 'Consumidor final' : null, c.emisor && c.emisor.leyenda_factura].filter(Boolean) }
      : { leyendas: ['Documento interno (ticket), sin valor fiscal.', c.emisor && c.emisor.leyenda_factura].filter(Boolean) },
    notas: [c.en_linea ? null : 'Emitida sin conexión', copia ? 'Copia: obligado tributario emisor' : 'Original: cliente'].filter(Boolean),
  };
}

// Original y copia, con Imprimir (y los botones que se agreguen).
export function vistaComprobanteLocal(reg, { extra = [] } = {}) {
  return h('section', { class: 'tarjeta comprobante-tarjeta', 'aria-label': 'Comprobante', dataset: { local: 'si' } },
    comprobante(documentoLocal(reg, false)),
    h('div', { class: 'comprobante-copia' }, comprobante(documentoLocal(reg, true))),
    h('div', { class: 'botones no-imprimir' },
      h('button', { type: 'button', class: 'boton boton-principal', onclick: () => window.print() }, 'Imprimir original y copia'),
      ...extra));
}
