// Dinero · "Depósitos y traslados" (app 0.7.0): mover dinero entre cajas y bancos en UNA operación
// (trasladar_dinero, dinero.trasladar): depositar (queda "en tránsito" hasta confirmar), retirar del banco,
// pasar entre cuentas y reponer la caja chica. Los depósitos en tránsito se confirman cuando el banco ya
// los tiene (confirmar_deposito) y lo que se registró mal se anula con motivo (anular_operacion_dinero).
import { leer, escribir, nuevoId } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha, aCentavos } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, pedirMotivo, dialogo, titulo, filaIcono, chip, chipEstado, monto,
  estadoVacio, mensaje } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { cuentasDinero, cuentasQuePagan, olvidarDatos } from '../datos.js';
import { hoy, inputMonto, inputFecha, textoCuenta, textoMonto } from '../formularios.js';

const ES_CAJA = (c) => c.tipo === 'efectivo_caja' || c.tipo === 'caja_chica';
// Qué se puede elegir en cada tipo (igual que valida trasladar_dinero en el núcleo).
const TIPOS = {
  deposito: { texto: 'Depositar al banco', boton: 'Registrar depósito', origen: ES_CAJA, destino: (c) => c.tipo === 'banco',
    ayuda: 'Efectivo de una caja al banco. Queda "en tránsito" hasta que confirme que el banco ya lo tiene.' },
  retiro: { texto: 'Retirar del banco', boton: 'Registrar retiro', origen: (c) => c.tipo === 'banco', destino: ES_CAJA,
    ayuda: 'Saca dinero del banco y lo pone en una caja.' },
  traslado: { texto: 'Pasar de una cuenta a otra', boton: 'Registrar traslado', origen: (c) => c.tipo !== 'transito', destino: (c) => c.tipo !== 'transito',
    ayuda: 'Por ejemplo, de un banco a otro, o lo de tarjetas (POS) al banco.' },
  reposicion_caja_chica: { texto: 'Reponer la caja chica', boton: 'Reponer caja chica', origen: (c) => c.tipo === 'banco' || c.tipo === 'efectivo_caja',
    destino: (c) => c.tipo === 'caja_chica', ayuda: 'Completa el fondo de la caja chica con lo que se gastó. Deje el monto vacío para reponer todo lo gastado.' },
};
const NOMBRE_TIPO = { deposito: 'Depósito', retiro: 'Retiro', traslado: 'Traslado', reposicion_caja_chica: 'Reposición de caja chica',
  saldo_inicial: 'Saldo inicial', envio_sucursal: 'Envío a otra sucursal' };

export async function mostrar(vista, ctx) {
  const [cuentas, transito, ops] = await Promise.all([cuentasDinero(true),
    leer('v_deposito_transito', { empresa_id: empresaId() }, { orden: 'fecha_contable.asc', limite: 200 }),
    leer('operacion_dinero', { empresa_id: empresaId() }, { orden: 'numero.desc', limite: 30 })]);
  if (!ctx.sigueVigente()) return;
  const nombre = (idc) => (cuentas.find((c) => c.cuenta_dinero_id === idc) || {}).nombre || 'otra cuenta';
  const recargar = () => { vista.replaceChildren(); mostrar(vista, ctx); };

  // ---- Depósitos en tránsito ----
  const confirmarDeposito = (t) => {
    const idOp = nuevoId();
    const f = inputFecha('confirmar-fecha', hoy(), { min: t.fecha_contable, max: hoy() });
    const ref = h('input', { id: 'confirmar-referencia', type: 'text', maxlength: 100, value: t.referencia || '' });
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const si = h('button', { type: 'button', class: 'boton boton-principal', id: 'confirmar-deposito-si' }, 'Sí, ya está en el banco');
    const { cerrar } = dialogo(`Confirmar el depósito #${t.numero}`,
      h('p', {}, `${dinero(t.monto_centavos)} de ${t.origen} a ${t.banco}. Confírmelo cuando lo vea en el estado de cuenta o en la banca en línea.`),
      campo('Fecha en que el banco lo acreditó', f), campo('Referencia (opcional)', ref), zonaError,
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => cerrar() }, 'Cancelar'), si));
    si.addEventListener('click', async () => {
      const r = await conBoton(si, zonaError, () => escribir('confirmar_deposito', { p_operacion_id: t.operacion_id, p_id_operacion: idOp,
        p_fecha: f.value || null, p_referencia: ref.value.trim() || null }), 'Confirmando…');
      if (!r) return;
      cerrar();
      olvidarDatos('cuentas');
      aviso(`Depósito #${t.numero} confirmado · ${dinero(t.monto_centavos)} ya están en ${t.banco}`, 'ok', 7000);
      recargar();
    });
  };
  const anular = (o, texto) => {
    const idOp = nuevoId();
    pedirMotivo({ titulo: `Anular ${texto}`, peligro: true, textoBoton: 'Sí, anular',
      explicacion: `Nada se borra: se hace la contrapartida y los ${dinero(o.monto_centavos)} vuelven a ${nombre(o.origen_id)}.`,
      accion: (motivo) => escribir('anular_operacion_dinero', { p_operacion_id: o.operacion_id || o.id, p_motivo: motivo, p_id_operacion: idOp }),
    }).then((ok) => {
      if (!ok) return;
      olvidarDatos('cuentas');
      aviso(`${texto[0].toUpperCase() + texto.slice(1)} anulado · ${dinero(o.monto_centavos)} volvieron a ${nombre(o.origen_id)}`, 'ok', 7000);
      recargar();
    });
  };
  const filasTransito = transito.map((t) => filaIcono({
    icono: 'deposito', color: t.alerta ? 'rojo' : 'dorado',
    titulo: h('strong', {}, `Depósito #${t.numero} · ${t.origen} a ${t.banco}`),
    detalle: `${fecha(t.fecha_contable)}${t.referencia ? ' · ' + t.referencia : ''}`,
    derecha: [monto(dinero(t.monto_centavos)), t.alerta ? chip(`${t.dias_en_transito} días sin confirmar`, 'rojo') : chipEstado('en_transito', t.dias_en_transito ? `En tránsito · ${t.dias_en_transito} ${t.dias_en_transito === 1 ? 'día' : 'días'}` : 'En tránsito · hoy')],
    abajo: h('div', { class: 'botones' },
      puede('dinero.trasladar') ? h('button', { type: 'button', class: 'boton boton-principal', 'aria-label': `Confirmar el depósito #${t.numero}`,
        onclick: () => confirmarDeposito(t) }, icono('check'), 'Confirmar depósito') : null,
      puede('dinero.anular') ? h('button', { type: 'button', class: 'boton boton-peligro', 'aria-label': `Anular el depósito #${t.numero}`,
        onclick: () => anular({ ...t, origen_id: t.origen_id }, `el depósito #${t.numero}`) }, 'Anular') : null),
    props: { dataset: { transito: t.operacion_id } },
  }));

  // ---- Últimos movimientos ----
  const filasOps = ops.map((o) => {
    const est = o.anulada_en ? 'anulada' : o.estado === 'en_transito' ? 'en_transito' : 'confirmada';
    const sePuedeAnular = !o.anulada_en && puede('dinero.anular') && o.tipo !== 'saldo_inicial' && o.tipo !== 'envio_sucursal' && o.estado !== 'confirmada';
    return filaIcono({
      icono: o.tipo === 'deposito' ? 'deposito' : 'traslado', color: o.anulada_en ? 'neutro' : 'azul',
      titulo: h('strong', {}, `${NOMBRE_TIPO[o.tipo] || o.tipo} #${o.numero}`),
      detalle: `${fecha(o.fecha_contable)} · ${o.origen_id ? nombre(o.origen_id) + ' → ' : ''}${nombre(o.destino_id)}${o.referencia ? ' · ' + o.referencia : ''}`,
      derecha: [monto(dinero(o.monto_centavos)), est === 'confirmada' ? chipEstado('confirmada', o.tipo === 'deposito' ? 'Confirmado' : 'Hecho') : chipEstado(est)],
      abajo: sePuedeAnular && o.estado !== 'en_transito' ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-peligro',
        'aria-label': `Anular ${NOMBRE_TIPO[o.tipo] || ''} #${o.numero}`, onclick: () => anular(o, `${(NOMBRE_TIPO[o.tipo] || 'la operación').toLowerCase()} #${o.numero}`) }, 'Anular')) : null,
      props: { dataset: { operacion: o.id } },
    });
  });

  const pagan = cuentasQuePagan(cuentas);
  vista.append(
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-mover' },
      h('div', { class: 'titulo-con-boton' }, titulo('h1', 'deposito', 'Depósitos y traslados', { id: 't-mover' }),
        puede('dinero.trasladar') && pagan.length >= 2 ? h('button', { type: 'button', class: 'boton boton-principal', id: 'mover-dinero',
          onclick: () => formularioMover(vista, ctx, cuentas) }, icono('traslado'), 'Mover dinero') : null),
      pagan.length < 2 ? estadoVacio({ icono: 'banco', titulo: 'Primero guarde sus cajas y bancos',
        texto: 'Para mover dinero necesita al menos dos cuentas, por ejemplo la caja y el banco.',
        boton: hayEnMenu(ctx.menu || [], 'ajustes', 'cajas') ? { texto: 'Agregar caja o banco', href: '#/ajustes/cajas', icono: 'mas' } : null })
        : h('p', { class: 'ayuda' }, 'Cada movimiento sale de una cuenta y entra a otra: el total de su dinero no cambia.'),
      h('h2', { class: 'titulo-chico' }, 'Depósitos en tránsito'),
      filasTransito.length ? h('div', { class: 'lista-filas', id: 'lista-transito' }, filasTransito)
        : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'No hay depósitos esperando confirmación.' })),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-ult-mov' },
      titulo('h2', 'lista', 'Últimos movimientos entre cuentas', { id: 't-ult-mov' }),
      filasOps.length ? h('div', { class: 'lista-filas', id: 'lista-operaciones' }, filasOps)
        : estadoVacio({ icono: 'traslado', chico: true, texto: 'Todavía no ha movido dinero entre cuentas.' })));
}

function formularioMover(vista, ctx, cuentas) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  const id = nuevoId();
  const tipo = { valor: 'deposito' };
  const lista = cuentas.filter((c) => c.tipo !== 'transito');
  const selOrigen = h('select', { id: 'mover-origen' });
  const selDestino = h('select', { id: 'mover-destino' });
  const montoIn = inputMonto('mover-monto');
  const fechaIn = inputFecha('mover-fecha', hoy(), { max: hoy() });
  const referencia = h('input', { id: 'mover-referencia', type: 'text', maxlength: 100, placeholder: 'Número de boleta, cheque o transferencia' });
  const ayuda = h('p', { class: 'ayuda', id: 'mover-ayuda' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'mover-guardar' });
  const lblMonto = campo('Monto (L)', montoIn);
  function pintar() {
    const t = TIPOS[tipo.valor];
    const llenar = (sel, f, vacio) => {
      const antes = sel.value;
      const opciones = lista.filter(f);
      sel.replaceChildren(h('option', { value: '' }, vacio), ...opciones.map((c) => h('option', { value: c.cuenta_dinero_id }, textoCuenta(c))));
      if (opciones.some((c) => c.cuenta_dinero_id === antes)) sel.value = antes;
    };
    llenar(selOrigen, t.origen, '¿De dónde sale?');
    llenar(selDestino, t.destino, '¿A dónde entra?');
    ayuda.textContent = t.ayuda;
    boton.textContent = t.boton;
    lblMonto.querySelector('label').textContent = tipo.valor === 'reposicion_caja_chica' ? 'Monto (L, opcional)' : 'Monto (L)';
  }
  const radio = (v) => {
    const r = h('input', { type: 'radio', name: 'mover-tipo', value: v, checked: v === tipo.valor });
    r.addEventListener('change', () => { tipo.valor = v; pintar(); });
    return h('label', {}, r, ' ' + TIPOS[v].texto);
  };
  const form = h('form', { class: 'formulario', novalidate: true },
    h('fieldset', { class: 'opciones' }, h('legend', {}, '¿Qué va a hacer?'), Object.keys(TIPOS).map(radio)), ayuda,
    campo('Sale de', selOrigen), campo('Entra a', selDestino), lblMonto,
    h('div', { class: 'dos-columnas' }, campo('Fecha', fechaIn), campo('Referencia (opcional)', referencia)),
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const falla = (t, q = '', foco = null) => { zonaError.append(errorSimple(t, q)); if (foco) foco.focus(); };
    if (!selOrigen.value) return falla('Elija de dónde sale el dinero.', '', selOrigen);
    if (!selDestino.value) return falla('Elija a dónde entra el dinero.', '', selDestino);
    if (selOrigen.value === selDestino.value) return falla('El dinero debe salir de una cuenta y entrar a OTRA.', '', selDestino);
    const repone = tipo.valor === 'reposicion_caja_chica';
    const m = montoIn.value.trim() === '' && repone ? null : aCentavos(montoIn.value);
    if (!m && !(repone && montoIn.value.trim() === '')) return falla(textoMonto(montoIn, 'Escriba el monto.'), 'Solo números, por ejemplo 2500 o 2500.50', montoIn);
    const o = lista.find((c) => c.cuenta_dinero_id === selOrigen.value), dst = lista.find((c) => c.cuenta_dinero_id === selDestino.value);
    if (m && m > Number(o.saldo_centavos) && (o.politica_saldo_negativo || 'no_permitir') === 'no_permitir') {
      return falla(`${o.nombre} solo tiene ${dinero(o.saldo_centavos)}.`, 'Baje el monto o elija otra cuenta.', montoIn);
    }
    const datos = { tipo: tipo.valor, origen_id: o.cuenta_dinero_id, destino_id: dst.cuenta_dinero_id, fecha: fechaIn.value || hoy() };
    if (m) datos.monto_centavos = m;
    if (referencia.value.trim()) datos.referencia = referencia.value.trim();
    const cuanto = m ? dinero(m) : 'lo gastado';
    const ok = await confirmar({ titulo: '¿Registrar este movimiento?', textoBoton: 'Sí, registrar',
      texto: `${NOMBRE_TIPO[tipo.valor]} de ${cuanto} · sale de ${o.nombre} y entra a ${dst.nombre}.${tipo.valor === 'deposito' ? ' Queda en tránsito hasta confirmarlo.' : ''}` });
    if (!ok) return;
    const r = await conBoton(boton, zonaError, () => escribir('trasladar_dinero', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: id }));
    if (!r) return;
    olvidarDatos('cuentas');
    const hecho = `${NOMBRE_TIPO[tipo.valor]} #${r.numero} de ${dinero(r.monto_centavos)} registrado · sale de ${o.nombre}`
      + (tipo.valor === 'deposito' ? ` · queda en tránsito hasta confirmarlo en ${dst.nombre}` : ` · entra a ${dst.nombre}`);
    aviso(hecho, 'ok', 8000);
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-movok' },
      titulo('h1', 'traslado', `${NOMBRE_TIPO[tipo.valor]} #${r.numero}`, { id: 't-movok' }),
      mensaje('ok', hecho, `${o.nombre} queda con ${dinero(r.saldo_origen_centavos)}.${tipo.valor === 'deposito' ? '' : ` ${dst.nombre} queda con ${dinero(r.saldo_destino_centavos)}.`}`,
        { class: 'resultado', dataset: { info: 'movimiento-guardado' } }),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: volver }, 'Volver'))));
  });
  pintar();
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-fmover' },
    titulo('h1', 'traslado', 'Mover dinero', { id: 't-fmover' }), form));
}

