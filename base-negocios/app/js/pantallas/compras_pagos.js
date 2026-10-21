// Compras · "Pagar a proveedores" (app 0.7.0): lo que se debe a proveedores factura por factura
// (v_cxp_documento: compras al crédito y saldos iniciales con saldo), con su vencimiento en chips
// (vencida, por vencer en 7 días, al día) y el pago total o parcial (pagar_proveedor, compras.pagar)
// diciendo de qué caja o banco sale. Un id_operacion fijo por formulario: un doble clic no paga dos veces.
import { leer, escribir, nuevoId } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha, aCentavos, diasEntre } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, titulo, filaIcono, chipEstado, monto, estadoVacio, mensaje } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { cuentasDinero, cuentasQuePagan, alcance, olvidarDatos } from '../datos.js';
import { hoy, selectCuentas, inputMonto, inputFecha, dato, cifraChica, cuandoVence, textoMonto } from '../formularios.js';

// Facturas por pagar que este usuario puede ver. v_cxp_documento ya deja fuera las compras de otras
// sucursales (RLS de compra), pero NO los saldos iniciales: a un usuario limitado se le quitan los de
// otra sucursal aquí (ver PENDIENTES: conviene filtrarlo en el núcleo).
export async function cuentasPorPagar(proveedorId = null) {
  const filtros = { empresa_id: empresaId() };
  if (proveedorId) filtros.proveedor_id = proveedorId;
  const [docs, al] = await Promise.all([leer('v_cxp_documento', filtros, { orden: 'fecha_vencimiento.asc', limite: 1000 }), alcance()]);
  if (!al.limitado || !docs.some((d) => d.origen === 'saldo_inicial')) return docs;
  const iniciales = await leer('cxp_saldo_inicial', { empresa_id: empresaId() }, { limite: 1000 });
  const mios = new Set(iniciales.filter((s) => al.sucursales.includes(s.sucursal_id)).map((s) => s.id));
  return docs.filter((d) => d.origen !== 'saldo_inicial' || mios.has(d.documento_id));
}

// Estado de una factura por pagar según su vencimiento: vencida, por vencer (7 días o menos) o al día.
export function estadoFactura(d) {
  const dias = diasEntre(hoy(), d.fecha_vencimiento);
  if (dias < 0) return { estado: 'vencida', dias, chip: chipEstado('vencida', `Vencida hace ${-dias} ${dias === -1 ? 'día' : 'días'}`) };
  if (dias <= 7) return { estado: 'por_vencer', dias, chip: chipEstado('por_vencer', dias === 0 ? 'Vence hoy' : `Vence en ${dias} ${dias === 1 ? 'día' : 'días'}`) };
  return { estado: 'al_dia', dias, chip: chipEstado('al_dia') };
}

const nombreDoc = (d) => (d.origen === 'saldo_inicial' ? `Saldo inicial · factura ${d.numero_documento}` : `Factura ${d.numero_documento}`);

export async function mostrar(vista, ctx) {
  const docs = await cuentasPorPagar();
  if (!ctx.sigueVigente()) return;
  const lista = docs.map((d) => ({ d, e: estadoFactura(d) }))
    .sort((a, b) => a.e.dias - b.e.dias || a.d.proveedor_nombre.localeCompare(b.d.proveedor_nombre));
  const suma = (f) => lista.filter(f).reduce((s, x) => s + Number(x.d.saldo_centavos), 0);
  const total = suma(() => true), vencido = suma((x) => x.e.estado === 'vencida'), pronto = suma((x) => x.e.estado === 'por_vencer');
  const filas = lista.map(({ d, e }) => filaIcono({
    icono: 'proveedor', color: e.estado === 'vencida' ? 'rojo' : e.estado === 'por_vencer' ? 'dorado' : 'verde',
    titulo: h('strong', {}, d.proveedor_nombre),
    detalle: `${nombreDoc(d)} · del ${fecha(d.fecha_documento)} · ${cuandoVence(e.dias)} (${fecha(d.fecha_vencimiento)})`
      + (Number(d.pagado_centavos) ? ` · ya pagó ${dinero(d.pagado_centavos)} de ${dinero(d.total_centavos)}` : ''),
    derecha: [monto(dinero(d.saldo_centavos), { sentido: 'sale', dato: 'saldo-factura' }), e.chip],
    abajo: puede('compras.pagar') ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-principal',
      'aria-label': `Pagar ${nombreDoc(d)} a ${d.proveedor_nombre}`, onclick: () => formularioPago(vista, ctx, d) }, icono('billetes'), 'Pagar')) : null,
    props: { dataset: { documento: d.documento_id, estado: e.estado } },
  }));
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cxp' },
    titulo('h1', 'billetes', 'Pagar a proveedores', { id: 't-cxp' }),
    lista.length ? [
      h('div', { class: 'cifras' },
        cifraChica('Debo en total', dinero(total), { dato: 'cxp-total', clase: 'monto-sale' }),
        cifraChica('Ya vencido', dinero(vencido), { dato: 'cxp-vencido', clase: vencido ? 'monto-sale' : '' }),
        cifraChica('Vence en 7 días', dinero(pronto), { dato: 'cxp-pronto' })),
      h('p', { class: 'ayuda' }, 'Primero lo más atrasado. Puede pagar todo o una parte; el resto sigue pendiente.'),
      h('div', { class: 'lista-filas', id: 'lista-cxp' }, filas)]
      : estadoVacio({ icono: 'check_circulo', color: 'verde', titulo: 'No le debe nada a sus proveedores',
        texto: 'Cuando compre al crédito, aquí verá cuánto debe, a quién y cuándo vence cada factura.',
        boton: hayEnMenu(ctx.menu || [], 'compras', 'compras') && puede('compras.registrar')
          ? { texto: 'Registrar una compra', href: '#/compras/compras', icono: 'mas' } : null })));
}

// Formulario de pago de UNA factura. alVolver(): a dónde regresar (por defecto, la lista de pagos).
export async function formularioPago(vista, ctx, d, { alVolver = null } = {}) {
  const volver = alVolver || (() => { vista.replaceChildren(); mostrar(vista, ctx); });
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cuentas = [];
  try {
    cuentas = tieneModulo('dinero') && puede('dinero.ver') ? cuentasQuePagan(await cuentasDinero(true)) : [];
  } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  // Sin cuentas de dinero (módulo apagado o sin permiso de verlas): caja o banco "de la plantilla" (sin rastro por cuenta).
  const selCuenta = cuentas.length ? selectCuentas(cuentas, { id: 'pago-cuenta' }, { vacio: 'Elija de dónde sale el dinero' })
    : h('select', { id: 'pago-cuenta' }, h('option', { value: 'forma:caja' }, 'Caja general'), h('option', { value: 'forma:banco' }, 'Banco'));
  const montoIn = inputMonto('pago-monto', d.saldo_centavos);
  // El pago no puede ser antes de la factura ni antes de su fecha en los libros (la mayor de las dos).
  const minimo = [d.fecha_documento, d.fecha_contable].filter(Boolean).sort().pop();
  const fechaIn = inputFecha('pago-fecha', hoy(), { min: minimo });
  const referencia = h('input', { id: 'pago-referencia', type: 'text', maxlength: 100, placeholder: 'Ej.: cheque 451 o transferencia 9988' });
  const tipoPago = h('p', { class: 'ayuda', id: 'pago-tipo', 'aria-live': 'polite' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'pagar-guardar' }, icono('billetes'), 'Registrar el pago');
  const id = nuevoId();
  const pintarTipo = () => {
    const m = aCentavos(montoIn.value);
    tipoPago.textContent = !m ? '' : m >= Number(d.saldo_centavos) ? 'Pago total: la factura queda pagada.'
      : `Pago parcial: quedará debiendo ${dinero(Number(d.saldo_centavos) - m)} de esta factura.`;
  };
  montoIn.addEventListener('input', pintarTipo);
  const form = h('form', { class: 'formulario', novalidate: true },
    dato('Proveedor', d.proveedor_nombre), dato('Documento', nombreDoc(d)), dato('Total de la factura', dinero(d.total_centavos)),
    Number(d.pagado_centavos) ? dato('Ya pagado', dinero(d.pagado_centavos)) : null,
    h('div', { class: 'fila fila-total' }, h('span', {}, 'Debe'), monto(dinero(d.saldo_centavos), { sentido: 'sale', dato: 'debe-factura' })),
    campo('Monto que paga (L)', montoIn), tipoPago,
    campo('¿De dónde sale el dinero?', selCuenta, cuentas.length ? 'Caja o banco. El saldo de cada una sale al lado.' : null),
    campo('Fecha del pago', fechaIn), campo('Referencia (opcional)', referencia),
    zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const m = aCentavos(montoIn.value);
    if (!m) { zonaError.append(errorSimple(textoMonto(montoIn, 'Escriba el monto que paga.'), 'Solo números, por ejemplo 4500 o 4500.50')); montoIn.focus(); return; }
    if (m > Number(d.saldo_centavos)) {
      zonaError.append(errorSimple(`No puede pagar más de lo que debe: ${dinero(d.saldo_centavos)}.`, 'Baje el monto.')); montoIn.focus(); return;
    }
    if (!selCuenta.value) { zonaError.append(errorSimple('Elija de qué caja o banco sale el dinero.')); selCuenta.focus(); return; }
    if (!fechaIn.value) { zonaError.append(errorSimple('Escriba la fecha del pago.')); return; }
    const deCuenta = !selCuenta.value.startsWith('forma:');
    const cuenta = deCuenta ? cuentas.find((c) => c.cuenta_dinero_id === selCuenta.value) : null;
    const sale = cuenta ? cuenta.nombre : selCuenta.value === 'forma:banco' ? 'el banco' : 'la caja general';
    if (cuenta && m > Number(cuenta.saldo_centavos) && cuenta.politica_saldo_negativo !== 'permitir_con_alerta' && cuenta.politica_saldo_negativo !== 'sobregiro_hasta') {
      zonaError.append(errorSimple(`${cuenta.nombre} solo tiene ${dinero(cuenta.saldo_centavos)}.`, 'Elija otra cuenta o pague una parte.')); return;
    }
    const ok = await confirmar({ titulo: '¿Registrar este pago?', textoBoton: 'Sí, pagar',
      texto: `Pago de ${dinero(m)} a ${d.proveedor_nombre} · sale de ${sale}. ${m >= Number(d.saldo_centavos) ? 'La factura queda pagada.' : `Quedará debiendo ${dinero(Number(d.saldo_centavos) - m)}.`}` });
    if (!ok) return;
    const r = await conBoton(boton, zonaError, () => escribir('pagar_proveedor', { p_empresa_id: empresaId(), p_compra_id: d.documento_id,
      p_monto_centavos: m, p_fecha: fechaIn.value, p_forma_pago: deCuenta ? null : selCuenta.value.slice(6), p_id_operacion: id,
      p_referencia: referencia.value.trim() || null, p_cuenta_pago: null, p_cuenta_dinero_id: deCuenta ? selCuenta.value : null }), 'Pagando…');
    if (!r) return;
    olvidarDatos('cuentas');
    const hecho = `Pago de ${dinero(m)} a ${d.proveedor_nombre} · sale de ${sale}`;
    const queda = r.saldo_restante_centavos ?? Math.max(0, Number(d.saldo_centavos) - m);
    aviso(hecho, 'ok', 7000);
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-pagook' },
      titulo('h1', 'billetes', `Pago #${r.numero} registrado`, { id: 't-pagook' }),
      mensaje('ok', hecho, queda ? `Todavía le debe ${dinero(queda)} por esta factura.` : 'Esta factura ya quedó pagada.', { class: 'resultado' }),
      dato('Documento', nombreDoc(d)), dato('Fecha', fecha(fechaIn.value)),
      h('div', { class: 'fila' }, h('span', {}, 'Pagado'), monto(dinero(m), { sentido: 'sale', dato: 'pagado' })),
      h('div', { class: 'fila fila-total' }, h('span', {}, 'Todavía debe'), h('span', { class: 'monto', dataset: { dato: 'saldo-restante' } }, dinero(queda))),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: volver }, 'Volver'))));
  });
  pintarTipo();
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-pagar' },
    titulo('h1', 'billetes', `Pagar a ${d.proveedor_nombre}`, { id: 't-pagar' }),
    !cuentas.length && tieneModulo('dinero') ? mensaje('info', 'No ve sus cajas y bancos.', 'Elija caja general o banco, o pida el permiso para ver el dinero.') : null,
    form));
  montoIn.focus();
}

