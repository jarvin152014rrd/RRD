// Vender · "Devoluciones": desde una venta (botón "Devolver" en Ventas del día o por número),
// elegir líneas y cantidades, el motivo y el destino que el dueño permite
// (devolver dinero, nota de crédito / saldo a favor). Llama registrar_devolucion.
// El cambio de producto se hará después (ver app/PENDIENTES.md).
import { leer, escribir } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, cantidad as fCantidad } from '../formato.js';
import { h, cajaError, errorSimple, campo, conBoton } from '../ui.js';
import { cuentasDinero, miTurno } from '../datos.js';

let ventaElegida = null;
export function prepararDevolucion(ventaId) { ventaElegida = ventaId; }

const DESTINO = { devolver_dinero: ['dinero', 'Devolver el dinero'], nota_credito: ['saldo_favor', 'Nota de crédito (saldo a favor o vale)'] };

export async function mostrar(vista, ctx) {
  const id = ventaElegida;
  ventaElegida = null;
  if (id) return formulario(vista, ctx, id);
  // Buscar la venta por número de documento.
  const numero = h('input', { id: 'dev-numero', type: 'text', placeholder: 'T-001-001-00000012', autocomplete: 'off' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal' }, 'Buscar venta');
  const form = h('form', { class: 'formulario', novalidate: true }, campo('Número del ticket o factura', numero,
    'También puede ir a "Ventas del día" y tocar "Devolver".'), zonaError, boton);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const r = await conBoton(boton, zonaError, () => leer('v_venta', { empresa_id: empresaId(), numero_documento: numero.value.trim().toUpperCase() }), 'Buscando…');
    if (!r) return;
    if (!r.length) { zonaError.append(errorSimple('No se encontró esa venta.', 'Revise el número (con guiones).')); return; }
    vista.replaceChildren();
    formulario(vista, ctx, r[0].venta_id);
  });
  vista.append(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-dev' }, h('h1', { id: 't-dev' }, 'Devolución'), form));
}

async function formulario(vista, ctx, ventaId) {
  const [ventas, lineas, empresas] = await Promise.all([
    leer('v_venta', { venta_id: ventaId }), leer('v_venta_linea', { venta_id: ventaId }, { orden: 'linea.asc' }),
    leer('empresa', { id: empresaId() })]);
  if (!ctx.sigueVigente()) return;
  const v = ventas[0];
  if (!v) { vista.append(errorSimple('No se encontró la venta.')); return; }
  const tipos = (empresas[0] && empresas[0].devolucion_tipos) || ['devolver_dinero', 'nota_credito'];
  const destinos = Object.entries(DESTINO).filter(([k]) => tipos.includes(k));

  // Cuentas de donde puede salir el dinero: la caja de su turno y las que puede ver.
  const cuentas = [];
  try {
    const t = await miTurno();
    if (t) {
      const ft = await leer('v_turno_caja', { turno_id: t.turno_id });
      if (ft[0]) cuentas.push({ id: ft[0].cuenta_dinero_id, nombre: `Mi caja (${t.caja})` });
    }
  } catch { /* sin turno */ }
  if (puede('dinero.ver')) {
    try {
      (await cuentasDinero()).filter((c) => ['efectivo_caja', 'caja_chica', 'banco'].includes(c.tipo) && !cuentas.some((x) => x.id === c.cuenta_dinero_id))
        .forEach((c) => cuentas.push({ id: c.cuenta_dinero_id, nombre: c.nombre }));
    } catch { /* sin permiso */ }
  }

  const filas = lineas.map((l) => {
    const x = h('input', { type: 'number', name: 'devolver', min: '0', max: String(Number(l.cantidad)),
      step: l.permite_fracciones === false ? '1' : 'any', inputmode: 'decimal', placeholder: '0', 'aria-label': `Cantidad a devolver de ${l.descripcion}` });
    return { l, x };
  });
  const motivo = h('textarea', { id: 'dev-motivo', maxlength: 500, minlength: 5 });
  const selDestino = h('select', { id: 'dev-destino' }, destinos.map(([, [val, texto]]) => h('option', { value: val }, texto)));
  const selCuenta = h('select', { id: 'dev-cuenta' }, cuentas.map((c) => h('option', { value: c.id }, c.nombre)));
  const zonaCuenta = campo('¿De dónde sale el dinero?', selCuenta);
  const pintarDestino = () => { zonaCuenta.hidden = selDestino.value !== 'dinero'; };
  selDestino.addEventListener('change', pintarDestino);
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Registrar devolución');
  const form = h('form', { class: 'formulario', novalidate: true },
    h('div', { class: 'lista' }, filas.map(({ l, x }) => h('div', { class: 'linea-devolver' },
      h('span', {}, h('strong', {}, l.descripcion), h('span', { class: 'detalle' }, `Vendido: ${fCantidad(l.cantidad)} · ${dinero(l.total_centavos)}`)),
      campo('Devolver', x)))),
    campo('Motivo', motivo, 'Mínimo 5 letras. Queda en la bitácora.'),
    destinos.length ? campo('¿Qué recibe el cliente?', selDestino,
      v.condicion === 'credito' ? 'Si la venta tiene saldo por cobrar, primero se rebaja lo que debe.' : null) : null,
    zonaCuenta, zonaError, boton);
  pintarDestino();
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const elegidas = filas.filter((f) => Number(f.x.value) > 0).map((f) => ({ linea: f.l.linea, cantidad: Number(f.x.value) }));
    if (!elegidas.length) { zonaError.append(errorSimple('Escriba cuánto se devuelve de al menos una línea.')); return; }
    if (motivo.value.trim().length < 5) { zonaError.append(errorSimple('Escriba el motivo (mínimo 5 letras).')); return; }
    const datos = { lineas: elegidas, motivo: motivo.value.trim() };
    if (destinos.length) datos.destino = selDestino.value;
    if (datos.destino === 'dinero') {
      if (!selCuenta.value) { zonaError.append(errorSimple('No hay una caja o cuenta de donde sacar el dinero.', 'Abra su turno de caja o elija nota de crédito.')); return; }
      datos.cuenta_dinero_id = selCuenta.value;
    }
    const r = await conBoton(boton, zonaError, () => escribir('registrar_devolucion', { p_venta_id: ventaId, p_datos: datos }));
    if (r) listo(r);
  });

  function listo(r) {
    const pend = r.estado === 'pendiente_aprobacion';
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-devok' },
      h('h1', { id: 't-devok' }, pend ? 'Devolución esperando aprobación' : `Devolución ${r.numero_documento}`),
      h('div', { class: 'fila' }, h('span', {}, 'Total devuelto'), h('span', { class: 'monto', dataset: { dato: 'total-devolucion' } }, dinero(r.total_centavos))),
      r.cxc_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Rebaja de lo que debe'), h('span', { class: 'monto' }, dinero(r.cxc_centavos))) : null,
      r.dinero_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Dinero devuelto'), h('span', { class: 'monto' }, dinero(r.dinero_centavos))) : null,
      r.saldo_favor_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Saldo a favor'), h('span', { class: 'monto' }, dinero(r.saldo_favor_centavos))) : null,
      r.saldo_favor && r.saldo_favor.codigo ? h('p', { class: 'mensaje mensaje-ok' }, `Código del vale: ${r.saldo_favor.codigo}. Entrégueselo al cliente.`) : null,
      pend ? h('p', { class: 'mensaje mensaje-info' }, 'No se movió nada todavía: el administrador o el dueño debe aprobarla.') : null,
      h('div', { class: 'botones' }, h('a', { class: 'boton', href: '#/vender/ventas' }, 'Volver a ventas del día'))));
  }

  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-devf' },
    h('h1', { id: 't-devf' }, `Devolución de ${v.numero_documento || 'la venta #' + v.numero}`),
    h('p', { class: 'ayuda' }, `${v.cliente_nombre || 'Consumidor final'} · Total ${dinero(v.total_centavos)}`), form));
}
