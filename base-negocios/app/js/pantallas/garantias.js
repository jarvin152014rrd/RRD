// Vender · Garantías (app 0.12.0, núcleo 0.18.0). Buscar una venta por número de factura, cliente o producto y ver
// si la garantía está vigente; registrar el reclamo; ver los reclamos abiertos con su estado, pasarlos a revisión,
// resolverlos (reparado, cambiado o devuelto) o rechazarlos; imprimir el comprobante del reclamo (sin íconos ni emojis).
// El servidor decide todo (buscar_garantia, registrar_reclamo_garantia, cambiar_estado_reclamo,
// resolver_reclamo_garantia, documento_reclamo_garantia); la app solo pide y muestra.
import { rpc, leer, escribir, nuevoId } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha, cantidad, aCentavos, aNumero } from '../formato.js';
import { h, aviso, cajaError, errorSimple, campo, conBoton, titulo, filaIcono, chip, chipEstado, estadoVacio, mensaje, pedirMotivo } from '../ui.js';
import { cuentasDinero, cuentasQuePagan, categoriasGasto } from '../datos.js';
import { limpiarImprimible } from '../imprimible.js';

const E = () => empresaId();
const RESOLUCION = { reparado: 'Reparado', cambiado: 'Cambiado por otro igual', devuelto: 'Devuelto (se regresa el dinero o queda a favor)' };

export async function mostrar(vista, ctx) {
  const registrar = puede('garantias.registrar');
  const resolver = puede('garantias.resolver');
  const buscar = h('input', { id: 'garantia-buscar', type: 'search', autocomplete: 'off', placeholder: 'Número de factura, cliente o producto' });
  const soloVigentes = h('input', { type: 'checkbox', id: 'garantia-vigentes' });
  const resultados = h('div', { class: 'lista', id: 'garantia-resultados', 'aria-live': 'polite' });
  const zonaReclamos = h('div', { class: 'lista', id: 'reclamos-abiertos' });
  let reloj = null;
  let vez = 0;

  async function hacerBusqueda() {
    const q = buscar.value.trim();
    const mia = ++vez;
    if (q.length < 2) { resultados.replaceChildren(h('p', { class: 'ayuda' }, 'Escriba al menos 2 letras o números.')); return; }
    resultados.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Buscando…'));
    try {
      const r = await rpc('buscar_garantia', { p_empresa_id: E(), p_texto: q, p_solo_vigentes: soloVigentes.checked });
      if (mia !== vez || !ctx.sigueVigente()) return;
      resultados.replaceChildren(...(r.lineas.length ? r.lineas.map((l) => filaIcono({
        icono: 'garantia', color: l.vigente ? 'verde' : 'neutro',
        titulo: [h('strong', {}, l.producto), ' ', l.vigente ? chip(`Vigente · ${l.dias_restantes} días`, 'verde', { dataset: { estado: 'vigente' } })
          : chip('Vencida', 'rojo', { dataset: { estado: 'vencida' } }),
        l.reclamos_abiertos ? [' ', chip(`${l.reclamos_abiertos} reclamo abierto`, 'dorado')] : null],
        detalle: [`${l.numero_documento} · ${fecha(l.fecha_venta)}`, l.cliente, `${cantidad(l.cantidad)} und`,
          `garantía hasta ${fecha(l.garantia_hasta)}`].join(' · '),
        abajo: registrar && (l.vigente || resolver) && Number(l.cantidad) > Number(l.devuelta || 0)
          ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton' + (l.vigente ? ' boton-principal' : ''),
            dataset: { accion: 'registrar-reclamo' }, onclick: () => formularioReclamo(vista, ctx, l) },
            l.vigente ? 'Registrar reclamo' : 'Registrar fuera de plazo')) : null,
        props: { dataset: { venta: l.venta_id, linea: String(l.linea) } },
      })) : [estadoVacio({ icono: 'buscar', chico: true, texto: 'No hay ventas con garantía que coincidan.' })]));
    } catch (err) {
      if (mia === vez) resultados.replaceChildren(await cajaError(err));
    }
  }
  buscar.addEventListener('input', () => { clearTimeout(reloj); reloj = setTimeout(hacerBusqueda, 300); });
  buscar.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); clearTimeout(reloj); hacerBusqueda(); } });
  soloVigentes.addEventListener('change', () => { if (buscar.value.trim()) hacerBusqueda(); });

  async function pintarReclamos() {
    try {
      // Los últimos 300 reclamos; aquí solo los abiertos (recibido o en revisión).
      const lista = (await leer('v_garantia_reclamo', { empresa_id: E() }, { orden: 'numero.desc', limite: 300 }))
        .filter((r) => r.estado === 'recibido' || r.estado === 'en_revision');
      if (!ctx.sigueVigente()) return;
      zonaReclamos.replaceChildren(...(lista.length ? lista.map((r) => filaReclamo(vista, ctx, r, { registrar, resolver }))
        : [estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'No hay reclamos abiertos.' })]));
    } catch (err) {
      zonaReclamos.replaceChildren(await cajaError(err));
    }
  }

  vista.append(
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-garantias' },
      titulo('h1', 'garantia', 'Garantías', { id: 't-garantias' }),
      campo('Buscar la venta', buscar, 'Por número de factura, nombre del cliente o del producto.'),
      h('label', { class: 'opcion-check' }, soloVigentes, ' Solo garantías vigentes'),
      resultados),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-reclamos' },
      titulo('h2', 'pendientes', 'Reclamos abiertos', { id: 't-reclamos' }), zonaReclamos));
  await pintarReclamos();
  buscar.focus();
}

function filaReclamo(vista, ctx, r, { registrar, resolver }) {
  const recargar = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  const enRevision = h('button', { type: 'button', class: 'boton', dataset: { accion: 'en-revision' } }, 'Pasar a revisión');
  enRevision.addEventListener('click', async () => {
    const id = nuevoId();
    const x = await conBoton(enRevision, null, () => escribir('cambiar_estado_reclamo', { p_reclamo_id: r.reclamo_id, p_estado: 'en_revision',
      p_nota: 'En revisión', p_id_operacion: id }).catch(async (e) => { aviso((await cajaError(e)).innerText, 'error'); return null; }));
    if (x) { aviso(`Reclamo #${r.numero} en revisión`); recargar(); }
  });
  const rechazar = h('button', { type: 'button', class: 'boton boton-peligro', dataset: { accion: 'rechazar' } }, 'Rechazar');
  rechazar.addEventListener('click', async () => {
    const id = nuevoId();
    const ok = await pedirMotivo({ titulo: `Rechazar reclamo #${r.numero}`, textoBoton: 'Rechazar', peligro: true,
      explicacion: `${r.descripcion_producto} de ${r.cliente_nombre}. El cliente debe saber por qué.`,
      accion: (motivo) => rpc('cambiar_estado_reclamo', { p_reclamo_id: r.reclamo_id, p_estado: 'rechazado', p_nota: motivo, p_id_operacion: id }) });
    if (ok) { aviso(`Reclamo #${r.numero} rechazado`); recargar(); }
  });
  return filaIcono({
    icono: 'garantia', color: r.estado === 'recibido' ? 'dorado' : 'azul',
    titulo: [h('strong', {}, `#${r.numero} · ${r.descripcion_producto}`), ' ', chipEstado(r.estado), r.fuera_de_plazo ? [' ', chip('Fuera de plazo', 'rojo')] : null],
    detalle: [r.cliente_nombre, `${r.numero_documento || ''} · ${fecha(r.fecha)}`, r.motivo].filter(Boolean).join(' · '),
    abajo: h('div', { class: 'botones' },
      r.estado === 'recibido' && (registrar || resolver) ? enRevision : null,
      resolver ? h('button', { type: 'button', class: 'boton boton-principal', dataset: { accion: 'resolver' },
        onclick: () => formularioResolver(vista, ctx, r) }, 'Resolver') : null,
      resolver ? rechazar : null,
      h('button', { type: 'button', class: 'boton', dataset: { accion: 'comprobante-reclamo' }, onclick: () => comprobanteReclamo(vista, ctx, r.reclamo_id) }, 'Comprobante')),
    props: { dataset: { reclamo: r.reclamo_id, estado: r.estado } },
  });
}

// Registrar el reclamo de una línea (l = fila de buscar_garantia).
function formularioReclamo(vista, ctx, l) {
  const queda = Number(l.cantidad) - Number(l.devuelta || 0);
  const cant = h('input', { id: 'reclamo-cantidad', type: 'text', inputmode: 'decimal', value: '1' });
  const motivo = h('input', { id: 'reclamo-motivo', type: 'text', maxlength: 200, placeholder: 'Qué falla. Ej.: no enciende' });
  const desc = h('textarea', { id: 'reclamo-descripcion', maxlength: 1000, rows: 3 });
  const autorizar = h('input', { id: 'reclamo-autorizar', type: 'text', maxlength: 300 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Registrar reclamo');
  const id = nuevoId();
  const form = h('form', { class: 'formulario', novalidate: true },
    mensaje(l.vigente ? 'ok' : 'error', l.vigente ? `Garantía vigente hasta ${fecha(l.garantia_hasta)} (${l.dias_restantes} días).`
      : `La garantía venció el ${fecha(l.garantia_hasta)}.`, l.vigente ? '' : 'Solo entra si usted la autoriza con un motivo (queda en la bitácora).'),
    h('p', {}, `${l.producto} · ${l.numero_documento} · ${l.cliente}`),
    queda > 1 ? campo(`Cantidad (de ${cantidad(queda)})`, cant) : null,
    campo('Motivo', motivo), campo('Descripción (opcional)', desc, 'Lo que cuenta el cliente y cómo viene el producto.'),
    l.vigente ? null : campo('Motivo de la autorización', autorizar, 'Mínimo 5 letras.'),
    zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => { vista.replaceChildren(); mostrar(vista, ctx); } }, 'Volver'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const q = queda > 1 ? aNumero(cant.value) : 1;
    if (q === null || q <= 0 || q > queda) { zonaError.append(errorSimple(`La cantidad va de 1 a ${cantidad(queda)}.`)); return; }
    if (motivo.value.trim().length < 3) { zonaError.append(errorSimple('Escriba el motivo del reclamo.')); return; }
    const datos = { venta_id: l.venta_id, linea: Number(l.linea), cantidad: q, motivo: motivo.value.trim() };
    if (desc.value.trim()) datos.descripcion = desc.value.trim();
    if (!l.vigente) {
      if (autorizar.value.trim().length < 5) { zonaError.append(errorSimple('Escriba por qué autoriza el reclamo fuera de plazo (mínimo 5 letras).')); return; }
      datos.autorizar_fuera_de_plazo = autorizar.value.trim();
    }
    const r = await conBoton(boton, zonaError, () => escribir('registrar_reclamo_garantia', { p_empresa_id: E(), p_datos: datos, p_id_operacion: id }));
    if (!r) return;
    aviso(`Reclamo #${r.numero} registrado · ${l.producto}`);
    comprobanteReclamo(vista, ctx, r.reclamo_id);
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-reclamo' },
    titulo('h1', 'garantia', 'Reclamo de garantía', { id: 't-reclamo' }), form));
  motivo.focus();
}

// Resolver: reparado (con costo opcional como gasto), cambiado o devuelto.
async function formularioResolver(vista, ctx, r) {
  vista.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
  const [cuentas, cats] = await Promise.all([cuentasDinero().catch(() => []), categoriasGasto().catch(() => [])]);
  if (!ctx.sigueVigente()) return;
  const pagan = cuentasQuePagan(cuentas);
  const radios = Object.entries(RESOLUCION).map(([v, t], i) => {
    const x = h('input', { type: 'radio', name: 'resolucion', value: v, checked: i === 0 });
    return h('label', { class: 'opcion-check' }, x, ' ' + t);
  });
  const nota = h('input', { id: 'resolver-nota', type: 'text', maxlength: 500 });
  const costo = h('input', { id: 'resolver-costo', type: 'text', inputmode: 'decimal', placeholder: '0.00' });
  const ctaCosto = h('select', { id: 'resolver-costo-cuenta' }, pagan.map((c) => h('option', { value: c.cuenta_dinero_id }, c.nombre)));
  const catCosto = h('select', { id: 'resolver-costo-categoria' }, cats.map((c) => h('option', { value: c.id }, c.nombre)));
  const destino = h('select', { id: 'resolver-destino' }, h('option', { value: 'dinero' }, 'Se le devuelve el dinero'), h('option', { value: 'saldo_favor' }, 'Queda como saldo a favor'));
  const ctaDev = h('select', { id: 'resolver-cuenta' }, pagan.map((c) => h('option', { value: c.cuenta_dinero_id }, c.nombre)));
  const zonaReparado = h('fieldset', { class: 'grupo-campos' }, h('legend', {}, 'Costo de la reparación (opcional)'),
    campo('Monto (L)', costo, 'Si la reparación costó dinero, se registra como un gasto.'), campo('Sale de', ctaCosto), campo('Categoría del gasto', catCosto));
  const zonaDevuelto = h('fieldset', { class: 'grupo-campos', hidden: true }, h('legend', {}, 'Devolución'), campo('¿Qué se hace con el valor?', destino), campo('Sale de', ctaDev));
  const zonaCambio = h('p', { class: 'ayuda', hidden: true }, `Se le entrega otro "${r.descripcion_producto}" igual (cantidad ${cantidad(r.cantidad)}). Queda como un cambio de producto con su nota de crédito.`);
  const elegido = () => (radios.map((x) => x.querySelector('input')).find((x) => x.checked) || {}).value;
  const pintar = () => { const v = elegido(); zonaReparado.hidden = v !== 'reparado'; zonaDevuelto.hidden = v !== 'devuelto'; zonaCambio.hidden = v !== 'cambiado'; ctaDev.disabled = destino.value !== 'dinero'; };
  radios.forEach((x) => x.addEventListener('change', pintar));
  destino.addEventListener('change', pintar);
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Resolver reclamo');
  const id = nuevoId();
  const form = h('form', { class: 'formulario', novalidate: true },
    h('p', {}, `#${r.numero} · ${r.descripcion_producto} · ${r.cliente_nombre} · ${r.motivo}`),
    h('fieldset', { class: 'grupo-campos' }, h('legend', {}, '¿Cómo se resolvió?'), radios),
    zonaReparado, zonaCambio, zonaDevuelto, campo('Nota (opcional)', nota), zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => { vista.replaceChildren(); mostrar(vista, ctx); } }, 'Volver'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const v = elegido();
    const datos = { resolucion: v };
    if (nota.value.trim()) datos.nota = nota.value.trim();
    if (v === 'reparado' && costo.value.trim()) {
      const c = aCentavos(costo.value);
      if (!c) { zonaError.append(errorSimple('El costo de la reparación no es un monto válido (o déjelo vacío).')); return; }
      if (!ctaCosto.value || !catCosto.value) { zonaError.append(errorSimple('Elija de dónde sale el dinero y la categoría del gasto.')); return; }
      datos.costo_reparacion = { cuenta_dinero_id: ctaCosto.value, categoria_id: catCosto.value, monto_centavos: c };
    }
    if (v === 'devuelto') {
      datos.destino = destino.value;
      if (destino.value === 'dinero') {
        if (!ctaDev.value) { zonaError.append(errorSimple('Elija de dónde sale el dinero.')); return; }
        datos.cuenta_dinero_id = ctaDev.value;
      }
    }
    const x = await conBoton(boton, zonaError, () => escribir('resolver_reclamo_garantia', { p_reclamo_id: r.reclamo_id, p_datos: datos, p_id_operacion: id }));
    if (!x) return;
    aviso(`Reclamo #${r.numero} resuelto · ${RESOLUCION[v].split(' (')[0]}` + (x.gasto ? ` · gasto de ${dinero(x.gasto.monto_centavos || datos.costo_reparacion.monto_centavos)}` : ''));
    comprobanteReclamo(vista, ctx, r.reclamo_id);
  });
  pintar();
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-resolver' },
    titulo('h1', 'garantia', `Resolver reclamo #${r.numero}`, { id: 't-resolver' }), form));
}

// Comprobante del reclamo: solo texto (se imprime igual que el de la venta, sin íconos ni emojis).
async function comprobanteReclamo(vista, ctx, reclamoId) {
  vista.replaceChildren(h('p', { class: 'cargando' }, 'Preparando el comprobante…'));
  try {
    const d = await rpc('documento_reclamo_garantia', { p_reclamo_id: reclamoId });
    if (!ctx.sigueVigente()) return;
    const fila = (a, b) => (b || b === 0 ? h('div', { class: 'comp-fila' }, h('span', {}, a), h('span', {}, String(b))) : null);
    const estado = { recibido: 'Recibido', en_revision: 'En revisión', resuelto: 'Resuelto', rechazado: 'Rechazado' };
    const comp = limpiarImprimible(h('article', { class: 'comprobante', 'aria-label': 'Comprobante del reclamo' },
      h('p', { class: 'comp-centro comp-negrita' }, d.emisor.nombre),
      d.emisor.rtn ? h('p', { class: 'comp-centro' }, 'RTN ' + d.emisor.rtn) : null,
      d.emisor.sucursal ? h('p', { class: 'comp-centro' }, d.emisor.sucursal) : null,
      h('p', { class: 'comp-centro comp-negrita', dataset: { dato: 'reclamo-numero' } }, `${d.titulo} #${d.numero}`),
      h('hr'),
      fila('Fecha', d.fecha), fila('Cliente', d.cliente), fila('Factura', `${d.factura || ''} del ${d.fecha_venta}`),
      fila('Producto', `${cantidad(d.cantidad)} x ${d.producto}`), fila('Garantía hasta', d.garantia_hasta),
      d.fuera_de_plazo ? h('p', { class: 'comp-chico' }, 'Fuera de plazo, autorizado: ' + (d.autorizacion || '')) : null,
      fila('Motivo', d.motivo), d.descripcion ? h('p', { class: 'comp-chico' }, d.descripcion) : null,
      fila('Estado', estado[d.estado] || d.estado),
      d.resolucion ? fila('Resolución', RESOLUCION[d.resolucion].split(' (')[0]) : null,
      d.resolucion_nota ? h('p', { class: 'comp-chico' }, d.resolucion_nota) : null,
      d.rechazo_motivo ? fila('Rechazado por', d.rechazo_motivo) : null,
      h('hr'), fila('Recibió', d.registrado_por),
      h('p', { class: 'comp-centro comp-chico' }, 'Conserve este comprobante para dar seguimiento a su reclamo.')));
    vista.replaceChildren(h('section', { class: 'tarjeta comprobante-tarjeta', 'aria-label': 'Comprobante' }, comp,
      h('div', { class: 'botones no-imprimir' },
        h('button', { type: 'button', class: 'boton boton-principal', onclick: () => window.print() }, 'Imprimir'),
        h('button', { type: 'button', class: 'boton', onclick: () => { vista.replaceChildren(); mostrar(vista, ctx); } }, 'Volver a garantías'))));
  } catch (err) {
    vista.replaceChildren(await cajaError(err));
  }
}
