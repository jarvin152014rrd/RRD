// Dinero · "Transferencias por confirmar" (app 0.14.0, núcleo 0.20.0; decisión del dueño, docs/SIN_INTERNET.md).
// Cada venta cobrada con transferencia queda "por confirmar" hasta ver el dinero en el banco:
//   Confirmar  = llegó: pasa al banco elegido (confirmar_transferencia_venta, como siempre).
//   No llegó   = la venta queda como deuda del cliente o, si fue a Consumidor final, del cajero que la cobró
//                (marcar_transferencia_no_llego, con motivo y bitácora).
// "Referencia repetida": otra transferencia tiene el mismo número de referencia (puede ser un engaño).
import { rpc, escribir } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha } from '../formato.js';
import { cuentasDinero } from '../datos.js';
import { h, aviso, cajaError, campo, titulo, chip, filaIcono, estadoVacio, pedirMotivo, dialogo, errorSimple } from '../ui.js';

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const mover = puede('dinero.trasladar');
  let todas = false;
  const zona = h('div', { id: 'lista-transferencias' });
  const verTodas = h('input', { type: 'checkbox', id: 'trf-todas' });
  verTodas.addEventListener('change', () => { todas = verTodas.checked; cargar(); });
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-trf' },
    titulo('h1', 'reloj', 'Transferencias por confirmar', { id: 't-trf' }),
    h('p', { class: 'ayuda' }, 'Revise en el banco que cada transferencia llegó. Si no llegó, la venta queda como deuda del cliente (o del cajero, si fue a Consumidor final).'),
    h('label', { class: 'opcion-check' }, verTodas, ' Ver también las de los últimos 60 días ya revisadas'), zona));
  const bancos = mover ? (await cuentasDinero().catch(() => [])).filter((c) => c.tipo === 'banco') : [];
  await cargar();

  async function cargar() {
    let d;
    try { d = await rpc('transferencias_por_confirmar', { p_empresa_id: E, p_todas: todas }); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;
    const lista = d.transferencias;
    if (!lista.length) {
      zona.replaceChildren(estadoVacio({ icono: 'check_circulo', color: 'verde', titulo: 'Nada por confirmar', texto: 'Todas las transferencias están revisadas.' }));
      return;
    }
    const total = lista.filter((t) => t.estado === 'por_confirmar').reduce((s, t) => s + Number(t.monto_centavos), 0);
    zona.replaceChildren(h('p', {}, 'Por confirmar: ', h('strong', { dataset: { dato: 'total-por-confirmar' } }, dinero(total))), ...lista.map(fila));
  }

  function fila(t) {
    const pendiente = t.estado === 'por_confirmar';
    const chips = [
      pendiente ? chip(t.dias > 2 ? `Hace ${t.dias} días` : 'Por confirmar', t.dias > 2 ? 'rojo' : 'dorado')
        : t.estado === 'confirmada' ? chip('Llegó', 'verde') : chip('No llegó', 'rojo'),
      t.sin_internet ? chip('Sin internet', 'azul') : null,
      t.referencia_repetida ? chip('Referencia repetida', 'rojo', { dataset: { dato: 'referencia-repetida' } }) : null,
    ];
    const abajo = pendiente && mover ? h('div', { class: 'botones' },
      h('button', { type: 'button', class: 'boton boton-principal', dataset: { confirmar: t.venta_pago_id }, onclick: () => confirmarLlego(t) }, 'Llegó'),
      h('button', { type: 'button', class: 'boton boton-peligro', dataset: { noLlego: t.venta_pago_id }, onclick: () => noLlego(t) }, 'No llegó')) : null;
    return filaIcono({ icono: 'banco', color: pendiente ? 'dorado' : t.estado === 'confirmada' ? 'verde' : 'rojo',
      titulo: h('strong', {}, `${t.numero_documento} · ${dinero(t.monto_centavos)}`),
      detalle: `${fecha(t.fecha)} · ${t.cliente || 'Consumidor final'} · Ref. ${t.referencia || 'sin referencia'} · ${t.cajero || ''}`
        + (t.no_llego ? ` · Deuda de ${t.no_llego.deuda_de === 'cliente' ? 'el cliente' : 'el cajero'}` : ''),
      derecha: h('span', {}, ...chips), abajo, props: { dataset: { pago: t.venta_pago_id, estado: t.estado } } });
  }

  function confirmarLlego(t) {
    if (!bancos.length) { aviso('Primero registre la cuenta del banco en Dinero.', 'error', 6000); return; }
    const banco = h('select', { id: 'trf-banco' }, bancos.map((b) => h('option', { value: b.cuenta_dinero_id || b.id }, b.nombre)));
    const ref = h('input', { id: 'trf-ref', type: 'text', maxlength: 100, value: t.referencia || '' });
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'button', class: 'boton boton-principal', id: 'trf-guardar' }, 'Confirmar que llegó');
    const { cerrar } = dialogo(`Llegó ${dinero(t.monto_centavos)} (${t.numero_documento})`,
      t.referencia_repetida ? errorSimple('Otra transferencia tiene la misma referencia.', 'Revise en el banco que sean dos depósitos distintos.') : null,
      campo('Banco donde llegó', banco), campo('Referencia en el estado de cuenta', ref), zonaError,
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => cerrar() }, 'Cancelar'), boton));
    boton.addEventListener('click', async () => {
      const r = await (async () => {
        const btn = boton; if (btn.disabled) return null;
        btn.disabled = true; zonaError.replaceChildren();
        try {
          return await escribir('confirmar_transferencia_venta', { p_venta_pago_id: t.venta_pago_id,
            p_datos: { banco_id: banco.value, ...(ref.value.trim() ? { referencia: ref.value.trim() } : {}) } });
        } catch (err) { zonaError.append(await cajaError(err)); return null; } finally { btn.disabled = false; }
      })();
      if (r) { cerrar(); aviso('Transferencia confirmada.'); cargar(); }
    });
  }

  async function noLlego(t) {
    const ok = await pedirMotivo({ titulo: `La transferencia de ${t.numero_documento} no llegó`, peligro: true, textoBoton: 'Marcar que no llegó',
      explicacion: t.cliente_id
        ? `La venta queda como deuda de ${t.cliente} (${dinero(t.monto_centavos)}). Se cobra en "Me deben".`
        : `Fue a Consumidor final: queda como deuda del cajero ${t.cajero || ''} (${dinero(t.monto_centavos)}).`,
      accion: (motivo) => escribir('marcar_transferencia_no_llego', { p_venta_pago_id: t.venta_pago_id, p_motivo: motivo }) });
    if (ok) { aviso('Marcada: no llegó. Quedó como deuda.', 'ok', 6000); cargar(); }
  }
}
