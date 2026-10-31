// Vender · "Cotizaciones": crear (mismo carrito de Vender, sin cobro) y convertir en venta
// (convertir_cotizacion_a_venta con la forma de pago). Una cotización vigente respeta lo cotizado.
import { leer, escribir, nuevoId } from '../api.js';
import { empresaId, perfilActual } from '../sesion.js';
import { clientes } from '../datos.js';
import { nombreVisible } from '../marca.js';
import { sinEmojis } from '../imprimible.js';
import { hoy } from '../formularios.js';
import { dinero, fecha, aCentavos, cantidad as fCantidad } from '../formato.js';
import { h, aviso, cajaError, errorSimple, campo, conBoton, titulo, filaIcono, chipEstado, chip, monto, estadoVacio, mensaje, tarjetaCifra, filtrosRapidos, enlaceWhatsApp } from '../ui.js';
import { armarCarrito, puedeCobrar } from './vender.js';
import { vistaComprobante, nombreForma } from '../comprobante.js';

// App 0.15.0 (idea de RRD): cifras arriba (cuántas vigentes, cuántas vencen pronto, convertidas y vencidas este mes y
// cuántas de cada 100 se vuelven venta), filtros rápidos y botón de WhatsApp para mandarla al cliente.
// Solo CUENTA cotizaciones: los montos son los del servidor.
const PRONTO_DIAS = 3;
const diasEntre = (a, b) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86400000);

function textoWhatsApp(c) {
  const lineas = (c.lineas || []).map((l) => `- ${fCantidad(l.cantidad)} ${l.descripcion}`);
  return sinEmojis([`${nombreVisible()}`, `Cotización #${c.numero}${c.cliente_nombre ? ' para ' + c.cliente_nombre : ''}`, '', ...lineas, '',
    `Total: ${dinero(c.total_centavos)}`, `Válida hasta el ${fecha(c.vigente_hasta)}.`].join('\n'));
}

export async function mostrar(vista, ctx) {
  const e = empresaId();
  const hoyEmp = (perfilActual().empresa && perfilActual().empresa.hoy) || hoy();
  const inicioMes = hoyEmp.slice(0, 8) + '01';
  const [lista, delMes, listaClientes] = await Promise.all([
    leer('v_cotizacion', { empresa_id: e, estado: 'vigente' }, { orden: 'registrado_en.desc', limite: 200 }),
    leer('v_cotizacion', { empresa_id: e, fecha: { gte: inicioMes } }, { orden: 'registrado_en.desc', limite: 1000 }).catch(() => []),
    clientes().catch(() => []),
  ]);
  if (!ctx.sigueVigente()) return;
  const telefonos = new Map(listaClientes.map((c) => [c.id, c.telefono]));
  const empezar = () => {
    vista.replaceChildren();
    armarCarrito(vista, ctx, { modo: 'cotizacion', alTerminar: () => { vista.replaceChildren(); mostrar(vista, ctx); } });
  };
  const nueva = h('button', { type: 'button', class: 'boton boton-principal', id: 'nueva-cotizacion', onclick: empezar }, 'Nueva cotización');

  const vence = (c) => diasEntre(hoyEmp, c.vigente_hasta);
  const pronto = lista.filter((c) => vence(c) <= PRONTO_DIAS);
  const mes = delMes.filter((c) => c.estado !== 'anulada');
  const convertidas = mes.filter((c) => c.estado === 'convertida').length;
  const vencidas = delMes.filter((c) => c.estado === 'vencida');
  // Solo las que ya se decidieron (se vendieron o se vencieron): las vigentes todavía pueden venderse.
  const decididas = convertidas + vencidas.length;
  const tasa = decididas ? Math.round((convertidas * 100) / decididas) : null;
  const cifra = (dato, ic, color, etiqueta, valor, nota) => tarjetaCifra({ dato, icono: ic, color, etiqueta, valor: String(valor), nota });
  const cifras = h('div', { class: 'cifras cifras-cotizacion' },
    cifra('cot-vigentes', 'documento', 'azul', 'Vigentes', lista.length, 'esperando respuesta del cliente'),
    cifra('cot-pronto', 'reloj', pronto.length ? 'dorado' : 'azul', 'Vencen pronto', pronto.length, `en ${PRONTO_DIAS} días o menos`),
    cifra('cot-convertidas', 'check_circulo', 'verde', 'Se volvieron venta', convertidas, 'este mes'),
    cifra('cot-tasa', 'grafica', tasa === null ? 'azul' : tasa >= 50 ? 'verde' : 'dorado', 'Se cierran', tasa === null ? '—' : `${tasa} %`,
      tasa === null ? 'ninguna se ha decidido este mes' : `de las decididas este mes (${vencidas.length} ${vencidas.length === 1 ? 'vencida' : 'vencidas'})`));

  let filtro = 'vigentes';
  const zona = h('div', { class: 'lista-filas' });
  const fila = (c) => {
    const d = vence(c);
    const vencida = c.estado === 'vencida';
    const tel = telefonos.get(c.cliente_id);
    return filaIcono({
      icono: 'documento', color: vencida ? 'rojo' : d <= PRONTO_DIAS ? 'dorado' : 'azul',
      titulo: h('strong', {}, `Cotización #${c.numero}`),
      detalle: [`${c.cliente_nombre || 'Consumidor final'} · ${vencida ? 'venció' : 'vence'} ${fecha(c.vigente_hasta)}${c.vendedor ? ' · ' + c.vendedor : ''}`, h('br'),
        (c.lineas || []).map((l) => `${fCantidad(l.cantidad)} ${l.descripcion}`).join(', ')],
      derecha: [monto(dinero(c.total_centavos)),
        vencida ? chipEstado('vencida') : d <= 0 ? chip('Vence hoy', 'dorado') : d <= PRONTO_DIAS ? chip(`Vence en ${d} ${d === 1 ? 'día' : 'días'}`, 'dorado') : chipEstado('vigente')],
      abajo: vencida ? null : h('div', { class: 'botones' },
        tel ? h('a', { class: 'boton', href: enlaceWhatsApp(tel, textoWhatsApp(c)), target: '_blank', rel: 'noopener',
          'aria-label': `Mandar por WhatsApp la cotización #${c.numero}`, dataset: { accion: 'whatsapp' } }, 'WhatsApp') : null,
        h('button', { type: 'button', class: 'boton boton-principal', 'aria-label': `Convertir en venta la cotización #${c.numero}`, onclick: () => convertir(vista, ctx, c) }, 'Convertir en venta')),
      props: { dataset: { cotizacion: c.cotizacion_id } },
    });
  };
  const pintar = () => {
    const vistos = filtro === 'pronto' ? pronto : filtro === 'vencidas' ? vencidas : lista;
    zona.replaceChildren(...(vistos.length ? vistos.map(fila)
      : [estadoVacio({ icono: 'documento', chico: true, texto: filtro === 'vencidas' ? 'Ninguna se venció este mes.' : 'No hay cotizaciones aquí.' })]));
  };
  const filtros = lista.length || vencidas.length ? filtrosRapidos({ id: 'filtro-cotizaciones', etiqueta: 'Ver cotizaciones', actual: filtro,
    alCambiar: (f) => { filtro = f; pintar(); },
    opciones: [{ id: 'vigentes', texto: 'Vigentes', n: lista.length, siempre: true, color: 'azul' },
      { id: 'pronto', texto: 'Vencen pronto', n: pronto.length, color: 'dorado' },
      { id: 'vencidas', texto: 'Vencidas este mes', n: vencidas.length, color: 'rojo' }] }) : null;
  pintar();

  const hayAlgo = lista.length || delMes.length;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cot' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'documento', 'Cotizaciones vigentes', { id: 't-cot' }), hayAlgo ? nueva : null),
    hayAlgo ? [cifras, filtros, zona]
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
