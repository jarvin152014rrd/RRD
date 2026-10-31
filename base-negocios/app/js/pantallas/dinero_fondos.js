// Dinero · "Fondos y socios" (app 0.7.0, módulo fondos): cada fondo (reinversión, emergencias…) con su
// saldo, de dónde viene (repartos de la utilidad cobrada), en qué se usó, su meta y en qué cuenta está
// (estado_fondos); los socios con lo que se les debe; los movimientos (v_fondo_movimiento). Acciones del
// núcleo: usar un fondo (usar_fondo, con comprobante; si no lo pide el dueño queda en espera de su
// aprobación), pagar a un socio su parte (pagar_dividendos), repartir la utilidad de un mes cerrado
// (distribuir_utilidades, solo el dueño) y crear un fondo (crear_fondo, solo el dueño).
// app 0.10.0: anular un reparto (anular_distribucion, solo el dueño) y un pago a un socio
// (anular_pago_dividendos), y los aportes de capital de los socios (núcleo 0.16.0: registrar_aporte_socio,
// anular_aporte_socio, aportes_socios). Con un núcleo 0.15.0 la parte de aportes no se muestra.
// app 0.13.0 (núcleo 0.19.0): "Estado de cuenta del socio" (estado_cuenta_socio): aportes, repartos, pagos, total
// invertido y saldo por pagar, con fechas, cuadre con los libros, Excel e Imprimir. Con un núcleo 0.18.0 no se muestra.
import { leer, rpc, rpcSiExiste, escribir, nuevoId, subirComprobante, config } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha, aCentavos } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, titulo, filaIcono, chip, chipEstado, monto,
  estadoVacio, mensaje, pedirMotivo, tabla } from '../ui.js';
import { cuentasDinero, cuentasQuePagan, categoriasGasto, alcance, olvidarDatos, nucleoAlMenos } from '../datos.js';
import { botonesReporte } from '../reportes.js';
import { hoy, selectCuentas, inputMonto, inputFecha, cifraChica, textoMonto } from '../formularios.js';

const TIPO_FONDO = { reinversion: 'Reinversión', emergencias: 'Emergencias', otro: 'Otro' };
const MOV = { aporte: 'Reparto de utilidad', anulacion_aporte: 'Reparto anulado', uso: 'Uso del fondo' };
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const pct = (n) => `${Number(n).toLocaleString('en-US', { maximumFractionDigits: 2 })} %`;

export async function mostrar(vista, ctx) {
  const [e, movs, cuentas, al, repartos, pagos, aportes, con019] = await Promise.all([rpc('estado_fondos', { p_empresa_id: empresaId() }),
    leer('v_fondo_movimiento', { empresa_id: empresaId() }, { orden: 'registrado_en.desc', limite: 30 }),
    puede('dinero.ver') ? cuentasDinero(true) : [], alcance(),
    leer('v_distribucion', { empresa_id: empresaId() }, { orden: 'registrado_en.desc', limite: 12 }).catch(() => []),
    leer('dividendo_pago', { empresa_id: empresaId() }, { orden: 'registrado_en.desc', limite: 30 }).catch(() => []),
    // Núcleo 0.16.0: aportes de capital (null = núcleo viejo, sin esa parte).
    rpcSiExiste('aportes_socios', { p_empresa_id: empresaId() }).catch(() => null), nucleoAlMenos('0.19.0')]);
  if (!ctx.sigueVigente()) return;
  // Los fondos son de toda la empresa (patrimonio). A un usuario limitado no se le muestra el saldo de una
  // cuenta de dinero que no ve (de otra sucursal).
  const veoCuenta = (idc) => !al.limitado || cuentas.some((c) => c.cuenta_dinero_id === idc);
  const fondos = e.fondos || [], socios = e.socios || [];
  const nombreFondo = new Map(fondos.map((f) => [f.fondo_id, f.nombre]));
  const regla = e.regla ? [...(e.regla.fondos || []).map((x) => `${nombreFondo.get(x.fondo_id) || 'Fondo'} ${pct(x.porcentaje)}`),
    ...(e.regla.socios_porcentaje ? [`socios ${pct(e.regla.socios_porcentaje)} (según su participación)`] : []),
    ...((e.regla.socios || []).map((x) => `${(socios.find((s) => s.socio_id === x.socio_id) || {}).nombre || 'Socio'} ${pct(x.porcentaje)}`))].join(', ') : null;
  const pendienteSocios = socios.reduce((s, x) => s + Number(x.dividendos_pendientes_centavos || 0), 0);
  // Estado de cuenta del socio (núcleo 0.19.0): es de toda la empresa (un usuario limitado a su sucursal no lo ve).
  const verEstado = con019 && !al.limitado;

  const filasFondos = fondos.map((f) => filaIcono({
    icono: 'capas', color: f.activo ? 'verde' : 'neutro',
    titulo: [h('strong', {}, f.nombre), ' ', chip(TIPO_FONDO[f.tipo] || f.tipo, 'azul'), !f.activo ? [' ', chipEstado('inactivo')] : null],
    detalle: [`Le entró ${dinero(f.aportes_centavos)} de repartos`, Number(f.usos_centavos) ? `se usó ${dinero(f.usos_centavos)}` : 'no se ha usado',
      f.meta_centavos ? `meta ${dinero(f.meta_centavos)}${f.meta_tipo === 'meses_pagos_fijos' ? ` (${Number(f.meta_meses)} meses de pagos fijos)` : ''} · lleva ${pct(f.meta_porcentaje || 0)}` : 'sin meta',
      f.cuenta_dinero_id ? (veoCuenta(f.cuenta_dinero_id) ? `separado en ${f.cuenta_dinero} (esa cuenta tiene ${dinero(f.saldo_cuenta_dinero_centavos)})` : 'separado en una cuenta de otra sucursal')
        : 'no está separado: el dinero está junto con el resto'].join(' · '),
    derecha: [monto(dinero(f.saldo_centavos), { dato: 'saldo-fondo' }), f.usos_pendientes ? chipEstado('pendiente_aprobacion', `${f.usos_pendientes} uso(s) en espera`) : null],
    props: { dataset: { fondo: f.fondo_id } },
  }));
  const filasSocios = socios.map((s) => filaIcono({
    icono: 'usuario', color: s.activo ? 'azul' : 'neutro',
    titulo: [h('strong', {}, s.nombre), !s.activo ? [' ', chipEstado('inactivo')] : null],
    detalle: `Participación ${pct(s.porcentaje)}`,
    derecha: [monto(dinero(s.dividendos_pendientes_centavos), { sentido: Number(s.dividendos_pendientes_centavos) ? 'sale' : null, dato: 'pendiente-socio' }),
      Number(s.dividendos_pendientes_centavos) ? chip('Se le debe', 'dorado') : chip('Al día', 'verde')],
    abajo: (puede('fondos.pagar_dividendos') && Number(s.dividendos_pendientes_centavos) > 0) || verEstado ? h('div', { class: 'botones' },
      puede('fondos.pagar_dividendos') && Number(s.dividendos_pendientes_centavos) > 0 ? h('button', { type: 'button', class: 'boton boton-principal',
        'aria-label': `Pagar a ${s.nombre}`, onclick: () => formularioDividendos(vista, ctx, s) }, icono('billetes'), 'Pagar su parte') : null,
      verEstado ? h('button', { type: 'button', class: 'boton', 'aria-label': `Estado de cuenta de ${s.nombre}`, dataset: { accion: 'estado-socio' },
        onclick: () => estadoCuentaSocio(vista, ctx, s) }, icono('documento'), 'Estado de cuenta') : null) : null,
    props: { dataset: { socio: s.socio_id } },
  }));
  const filasMov = movs.map((m) => filaIcono({
    icono: m.tipo === 'uso' ? 'baja' : 'sube', color: m.tipo === 'uso' ? 'rojo' : m.tipo === 'aporte' ? 'verde' : 'neutro',
    titulo: h('strong', {}, `${MOV[m.tipo] || m.tipo} · ${m.fondo}`),
    detalle: [fecha(m.fecha_contable), m.descripcion, m.usuario].filter(Boolean).join(' · '),
    derecha: [monto(dinero(Math.abs(m.monto_centavos)), { sentido: m.monto_centavos < 0 ? 'sale' : 'entra', signo: m.monto_centavos < 0 ? '-' : '+' }),
      h('span', { class: 'detalle' }, `queda ${dinero(m.saldo_centavos)}`)],
  }));
  const botones = h('div', { class: 'botones' },
    puede('fondos.usar') && fondos.some((f) => Number(f.saldo_centavos) > 0) ? h('button', { type: 'button', class: 'boton boton-principal', id: 'usar-fondo',
      onclick: () => formularioUso(vista, ctx, fondos) }, icono('baja'), 'Usar un fondo') : null,
    puede('fondos.distribuir') ? h('button', { type: 'button', class: 'boton', id: 'repartir-utilidad', onclick: () => formularioReparto(vista, ctx, regla) },
      icono('capas'), 'Repartir la utilidad de un mes') : null,
    puede('fondos.configurar') ? h('button', { type: 'button', class: 'boton', id: 'nuevo-fondo', onclick: () => formularioFondo(vista, ctx) }, icono('mas'), 'Nuevo fondo') : null,
    aportes && puede('fondos.aportes') && socios.some((s) => s.activo) ? h('button', { type: 'button', class: 'boton', id: 'registrar-aporte',
      onclick: () => formularioAporte(vista, ctx, socios.filter((s) => s.activo)) }, icono('sube'), 'Registrar aporte de un socio') : null);
  const recargar = () => { vista.replaceChildren(); mostrar(vista, ctx); };

  vista.append(
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-fondos' },
      titulo('h1', 'capas', 'Fondos y socios', { id: 't-fondos' }),
      h('p', { class: 'ayuda' }, 'Los fondos se llenan al repartir la utilidad COBRADA de un mes cerrado (nunca lo que todavía le deben). Usarlos pide para qué, de qué cuenta sale y el comprobante.'),
      h('div', { class: 'cifras' }, cifraChica('Guardado en fondos', dinero(e.total_reservas_centavos), { dato: 'total-fondos' }),
        cifraChica('Por pagar a socios', dinero(pendienteSocios), { dato: 'por-pagar-socios', clase: pendienteSocios ? 'monto-sale' : '' })),
      regla ? h('p', { class: 'ayuda', dataset: { info: 'regla' } }, `Regla para repartir: ${regla}.`) : null,
      botones.children.length ? botones : null,
      h('h2', { class: 'titulo-chico' }, 'Fondos'),
      filasFondos.length ? h('div', { class: 'lista-filas', id: 'lista-fondos' }, filasFondos)
        : estadoVacio({ icono: 'capas', chico: true, titulo: 'Aún no tiene fondos', texto: 'Por ejemplo: reinversión (comprar más mercadería) y emergencias (tres meses de pagos fijos).',
          boton: puede('fondos.configurar') ? { texto: 'Crear el primero', onclick: () => formularioFondo(vista, ctx), icono: 'mas' } : null }),
      h('h2', { class: 'titulo-chico' }, 'Socios'),
      filasSocios.length ? h('div', { class: 'lista-filas', id: 'lista-socios' }, filasSocios)
        : estadoVacio({ icono: 'usuarios', chico: true, texto: 'Todavía no hay socios guardados. Los guarda el dueño con el proveedor del programa.' })),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-mov-fondos' },
      titulo('h2', 'movimientos', 'Movimientos de los fondos', { id: 't-mov-fondos' }),
      filasMov.length ? h('div', { class: 'lista-filas', id: 'lista-mov-fondos' }, filasMov)
        : estadoVacio({ icono: 'movimientos', chico: true, texto: 'Todavía no hay movimientos en los fondos.' })),
    tarjetaRepartos(repartos, pagos, socios, recargar),
    aportes ? tarjetaAportes(aportes, recargar) : null);
}

// ---------------- Estado de cuenta del socio (núcleo 0.19.0) ----------------
// Lo calcula el servidor (estado_cuenta_socio): la app no suma dinero. Fechas: "desde" vacío = desde el inicio.
const TIPO_MOV_SOCIO = { aporte: 'Aporte', aporte_anulado: 'Aporte anulado', reparto: 'Reparto de utilidad', reparto_anulado: 'Reparto anulado',
  pago: 'Pago recibido', pago_anulado: 'Pago anulado' };
const filtroSocio = { desde: '', hasta: '' };

async function estadoCuentaSocio(vista, ctx, s) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  const desde = h('input', { id: 'socio-desde', type: 'date', value: filtroSocio.desde, max: hoy() });
  const hasta = inputFecha('socio-hasta', filtroSocio.hasta || hoy(), { max: hoy() });
  const zona = h('div', { class: 'lista', 'aria-live': 'polite' });
  let r = null;
  vista.replaceChildren(h('section', { class: 'tarjeta', 'aria-labelledby': 't-estado-socio' },
    titulo('h1', 'documento', `Estado de cuenta de ${s.nombre}`, { id: 't-estado-socio' }),
    h('p', { class: 'ayuda' }, 'Lo que el socio ha metido al negocio (aportes), su parte de las utilidades repartidas y lo que ya se le pagó. Deje "Desde" vacío para ver todo.'),
    h('div', { class: 'dos-columnas filtros' }, campo('Desde', desde), campo('Hasta', hasta)),
    botonesReporte('estado-socio', () => documentoSocio(r)), zona,
    h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', id: 'estado-socio-volver', onclick: volver }, 'Volver a fondos y socios'))));
  let vez = 0;
  async function cargar() {
    const mia = ++vez;
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    if (desde.value && hasta.value && desde.value > hasta.value) { zona.replaceChildren(errorSimple('"Desde" va antes que "Hasta".')); return; }
    try {
      const x = await rpc('estado_cuenta_socio', { p_empresa_id: empresaId(), p_socio_id: s.socio_id, p_desde: desde.value || null, p_hasta: hasta.value || null });
      if (mia !== vez || !ctx.sigueVigente()) return;
      r = x;
      pintar();
    } catch (err) { if (mia === vez) zona.replaceChildren(await cajaError(err)); }
  }
  function pintar() {
    const t = r.totales || {};
    const filas = (r.movimientos || []).map((m) => [fecha(m.fecha),
      h('span', {}, h('strong', {}, m.texto), m.detalle ? h('span', { class: 'detalle' }, ' · ' + m.detalle) : null),
      Number(m.invertido_centavos) ? monto(dinero(Math.abs(m.invertido_centavos)), { sentido: m.invertido_centavos > 0 ? 'entra' : 'sale', signo: m.invertido_centavos > 0 ? '+' : '-' }) : '',
      Number(m.por_pagar_centavos) ? monto(dinero(Math.abs(m.por_pagar_centavos)), { signo: m.por_pagar_centavos > 0 ? '+' : '-' }) : '',
      dinero(m.saldo_invertido_centavos), dinero(m.saldo_por_pagar_centavos)]);
    zona.replaceChildren(...[
      h('div', { class: 'cifras' },
        cifraChica('Total invertido', dinero(r.total_invertido_centavos), { dato: 'socio-invertido' }),
        cifraChica('Saldo por pagar', dinero(r.saldo_por_pagar_centavos), { dato: 'socio-por-pagar', clase: Number(r.saldo_por_pagar_centavos) ? 'monto-sale' : '' }),
        cifraChica('Repartos en las fechas', dinero(t.repartos_centavos), { dato: 'socio-repartos' }),
        cifraChica('Pagos recibidos', dinero(t.pagos_centavos), { dato: 'socio-pagos' })),
      r.cuadre && r.cuadre.cuadra ? h('p', { class: 'ayuda', dataset: { info: 'socio-cuadra' } },
        `Cuadra con la contabilidad al ${fecha(r.hasta)}: aportes de todos los socios = cuenta ${r.cuadre.cuenta_aportes}; lo que se les debe = cuenta ${r.cuadre.cuenta_dividendos}.`)
        : mensaje('error', 'No cuadra con la contabilidad.', 'Avise a su contador o al proveedor del programa.', { dataset: { info: 'socio-no-cuadra' } }),
      r.desde ? h('p', { class: 'detalle', dataset: { dato: 'socio-saldo-inicial' } },
        `Al empezar (${fecha(r.desde)}): invertido ${dinero(r.saldo_inicial.invertido_centavos)} · por pagar ${dinero(r.saldo_inicial.por_pagar_centavos)}`) : null,
      filas.length ? tabla({ props: { id: 'tabla-estado-socio' },
        columnas: [{ titulo: 'Fecha' }, { titulo: 'Movimiento' }, { titulo: 'Invertido', num: true }, { titulo: 'Por pagar', num: true },
          { titulo: 'Saldo invertido', num: true }, { titulo: 'Saldo por pagar', num: true }], filas })
        : estadoVacio({ icono: 'documento', chico: true, texto: 'No hay movimientos en esas fechas.' }),
    ].filter(Boolean));
  }
  desde.addEventListener('change', () => { filtroSocio.desde = desde.value; cargar(); });
  hasta.addEventListener('change', () => { filtroSocio.hasta = hasta.value; cargar(); });
  await cargar();
}

// Documento para Excel e Imprimir (sin íconos ni colores).
function documentoSocio(r) {
  if (!r) return null;
  const t = r.totales || {};
  const periodo = r.desde ? `del ${fecha(r.desde)} al ${fecha(r.hasta)}` : `hasta el ${fecha(r.hasta)}`;
  return { titulo: `Estado de cuenta del socio ${r.socio.nombre}`, periodo,
    notas: [r.nota, r.cuadre && r.cuadre.cuadra ? `Cuadra con la contabilidad (cuentas ${r.cuadre.cuenta_aportes} y ${r.cuadre.cuenta_dividendos}).` : 'No cuadra con la contabilidad.'],
    secciones: [
      { titulo: 'Resumen', columnas: [{ titulo: 'Concepto', tipo: 'texto' }, { titulo: 'Monto (L)', tipo: 'dinero' }],
        filas: [
          ...(r.desde ? [['Invertido al empezar', r.saldo_inicial.invertido_centavos], ['Por pagar al empezar', r.saldo_inicial.por_pagar_centavos]] : []),
          ['Aportes', t.aportes_centavos], ['Aportes anulados', t.aportes_anulados_centavos], ['Repartos de utilidad asignados', t.repartos_centavos],
          ['Repartos anulados', t.repartos_anulados_centavos], ['Pagos recibidos', t.pagos_centavos], ['Pagos anulados', t.pagos_anulados_centavos],
          ['Total invertido', r.total_invertido_centavos], ['Saldo por pagar', r.saldo_por_pagar_centavos]] },
      { titulo: 'Movimientos', columnas: [{ titulo: 'Fecha', tipo: 'texto' }, { titulo: 'Movimiento', tipo: 'texto' }, { titulo: 'Detalle', tipo: 'texto' },
        { titulo: 'Invertido', tipo: 'dinero' }, { titulo: 'Por pagar', tipo: 'dinero' }, { titulo: 'Saldo invertido', tipo: 'dinero' },
        { titulo: 'Saldo por pagar', tipo: 'dinero' }],
        filas: (r.movimientos || []).map((m) => [fecha(m.fecha), `${TIPO_MOV_SOCIO[m.tipo] || m.tipo}: ${m.texto}`, m.detalle || '',
          Number(m.invertido_centavos) || null, Number(m.por_pagar_centavos) || null, m.saldo_invertido_centavos, m.saldo_por_pagar_centavos]) }] };
}

// Repartos de utilidad (con "Anular reparto", solo el dueño) y pagos a socios (con "Anular pago").
// Un reparto con pagos a socios no se anula: primero se anulan esos pagos (el núcleo lo exige).
function tarjetaRepartos(repartos, pagos, socios, recargar) {
  const nombreSocio = new Map(socios.map((s) => [s.socio_id, s.nombre]));
  const vigentes = pagos.filter((p) => !p.anulada_en);
  const filasRep = repartos.map((r) => filaIcono({
    icono: 'capas', color: r.anulada ? 'neutro' : 'azul',
    titulo: [h('strong', {}, `Reparto #${r.numero} de ${MESES[r.mes - 1]} de ${r.anio}`), ' ', r.anulada ? chipEstado('anulado') : chipEstado('vigente')],
    detalle: [`del ${fecha(r.fecha_contable)}`, ...(r.partes || []).map((x) => `${x.nombre} ${dinero(x.monto_centavos)}`),
      r.anulada ? `anulado: ${r.motivo_anulacion}` : null].filter(Boolean).join(' · '),
    derecha: monto(dinero(r.base_centavos)),
    abajo: !r.anulada && puede('fondos.distribuir') ? h('div', { class: 'botones' },
      h('button', { type: 'button', class: 'boton boton-peligro', 'aria-label': `Anular el reparto #${r.numero}`, dataset: { accion: 'anular-reparto' },
        onclick: () => anularReparto(r, recargar) }, icono('anular'), 'Anular reparto')) : null,
    props: { dataset: { reparto: r.distribucion_id } },
  }));
  const filasPag = vigentes.map((p) => filaIcono({
    icono: 'billetes', color: 'rojo',
    titulo: h('strong', {}, `Pago #${p.numero} a ${nombreSocio.get(p.socio_id) || 'socio'}`),
    detalle: [fecha(p.fecha_contable), p.referencia].filter(Boolean).join(' · '),
    derecha: monto(dinero(p.monto_centavos), { sentido: 'sale' }),
    abajo: puede('fondos.pagar_dividendos') ? h('div', { class: 'botones' },
      h('button', { type: 'button', class: 'boton boton-peligro', 'aria-label': `Anular el pago #${p.numero}`, dataset: { accion: 'anular-pago-socio' },
        onclick: () => anularPagoSocio(p, nombreSocio.get(p.socio_id) || 'el socio', recargar) }, icono('anular'), 'Anular pago')) : null,
    props: { dataset: { pagoSocio: p.id } },
  }));
  return h('section', { class: 'tarjeta', 'aria-labelledby': 't-repartos' },
    titulo('h2', 'capas', 'Repartos y pagos a socios', { id: 't-repartos' }),
    h('p', { class: 'ayuda' }, 'Anular un reparto devuelve los fondos y lo que se les debía a los socios a como estaban (nada se borra: queda el movimiento en contra con su motivo). Si ya se le pagó a un socio de ese reparto, primero anule ese pago aquí abajo. Después puede reabrir el mes en Reportes > Cierre de mes.'),
    filasRep.length ? h('div', { class: 'lista-filas', id: 'lista-repartos' }, filasRep)
      : estadoVacio({ icono: 'capas', chico: true, texto: 'Todavía no hay repartos de utilidad.' }),
    h('h3', { class: 'titulo-chico' }, 'Pagos a socios'),
    filasPag.length ? h('div', { class: 'lista-filas', id: 'lista-pagos-socios' }, filasPag)
      : h('p', { class: 'vacio' }, 'No hay pagos a socios vigentes.'));
}

async function anularReparto(r, recargar) {
  const ok = await pedirMotivo({ titulo: `Anular el reparto de ${MESES[r.mes - 1]} de ${r.anio}`, textoBoton: 'Sí, anular', peligro: true,
    explicacion: `Se deshace el reparto #${r.numero} de ${dinero(r.base_centavos)}: los fondos y lo que se les debe a los socios vuelven a como estaban y, si el dinero se separó, vuelve a su cuenta. Si ya se le pagó a un socio, primero anule ese pago.`,
    accion: (motivo) => escribir('anular_distribucion', { p_distribucion_id: r.distribucion_id, p_motivo: motivo }) });
  if (!ok) return;
  olvidarDatos('cuentas');
  aviso(`Reparto de ${MESES[r.mes - 1]} anulado · ya puede reabrir ese mes en Reportes > Cierre de mes`, 'ok', 9000);
  recargar();
}

async function anularPagoSocio(p, nombre, recargar) {
  const ok = await pedirMotivo({ titulo: `Anular el pago a ${nombre}`, textoBoton: 'Sí, anular', peligro: true,
    explicacion: `El pago #${p.numero} de ${dinero(p.monto_centavos)} se deshace: el dinero vuelve a la cuenta de donde salió y a ${nombre} se le vuelve a deber.`,
    accion: (motivo) => escribir('anular_pago_dividendos', { p_pago_id: p.id, p_motivo: motivo }) });
  if (!ok) return;
  olvidarDatos('cuentas');
  aviso(`Pago a ${nombre} anulado · ${dinero(p.monto_centavos)} vuelven a la cuenta`, 'ok', 8000);
  recargar();
}

// Aportes de capital de los socios (núcleo 0.16.0): lo que cada socio metió al negocio. No es ganancia.
function tarjetaAportes(a, recargar) {
  const filasSoc = (a.socios || []).filter((s) => Number(s.aportado_centavos) || Number(s.anulado_centavos)).map((s) => h('div', { class: 'fila', dataset: { aporteSocio: s.socio_id } },
    h('span', {}, s.nombre, Number(s.aportes) ? h('span', { class: 'detalle' }, ` · ${s.aportes} aporte(s)`) : null),
    monto(dinero(s.aportado_centavos), { sentido: 'entra', dato: 'aportado-socio' })));
  const filas = (a.aportes || []).map((x) => filaIcono({
    icono: 'sube', color: x.anulada ? 'neutro' : 'verde',
    titulo: [h('strong', {}, `Aporte #${x.numero} de ${x.socio}`), ' ', x.anulada ? chipEstado('anulado') : null],
    detalle: [fecha(x.fecha), x.cuenta ? `entró a ${x.cuenta}` : null, x.nota, x.referencia, x.anulada ? `anulado: ${x.motivo_anulacion}` : null].filter(Boolean).join(' · '),
    derecha: monto(dinero(x.monto_centavos), { sentido: x.anulada ? null : 'entra', signo: x.anulada ? '' : '+' }),
    abajo: !x.anulada && puede('fondos.aportes') ? h('div', { class: 'botones' },
      h('button', { type: 'button', class: 'boton boton-peligro', 'aria-label': `Anular el aporte #${x.numero}`, dataset: { accion: 'anular-aporte' },
        onclick: () => anularAporte(x, recargar) }, icono('anular'), 'Anular')) : null,
    props: { dataset: { aporte: x.aporte_id } },
  }));
  return h('section', { class: 'tarjeta', 'aria-labelledby': 't-aportes' },
    titulo('h2', 'sube', 'Aportes de los socios', { id: 't-aportes' }),
    h('p', { class: 'ayuda' }, 'Dinero que un socio mete al negocio. Es capital del socio: entra a la caja o al banco, pero NO cuenta como ganancia.'),
    h('div', { class: 'cifras' }, cifraChica('Aportado por los socios', dinero(a.total_centavos), { dato: 'total-aportes' })),
    a.solo_mis_sucursales ? mensaje('info', 'Usted ve solo los aportes que entraron a cuentas de sus sucursales.', null) : null,
    a.cuadra === false ? mensaje('error', 'Los aportes no cuadran con la contabilidad.', 'Avise al proveedor del programa.') : null,
    filasSoc.length ? h('div', { class: 'lista', id: 'aportes-por-socio' }, filasSoc) : null,
    filas.length ? h('div', { class: 'lista-filas', id: 'lista-aportes' }, filas)
      : estadoVacio({ icono: 'sube', chico: true, texto: 'Todavía no hay aportes de socios.' }));
}

async function anularAporte(x, recargar) {
  const ok = await pedirMotivo({ titulo: `Anular el aporte de ${x.socio}`, textoBoton: 'Sí, anular', peligro: true,
    explicacion: `El aporte #${x.numero} de ${dinero(x.monto_centavos)} se deshace: el dinero sale otra vez de ${x.cuenta || 'la cuenta donde entró'} (nada se borra: queda el movimiento en contra con su motivo).`,
    accion: (motivo) => escribir('anular_aporte_socio', { p_aporte_id: x.aporte_id, p_motivo: motivo }) });
  if (!ok) return;
  olvidarDatos('cuentas');
  aviso(`Aporte de ${x.socio} anulado · salen ${dinero(x.monto_centavos)} de ${x.cuenta || 'la cuenta'}`, 'ok', 8000);
  recargar();
}

// Registrar un aporte: socio, monto, a qué caja o banco entra, fecha y nota (núcleo 0.16.0).
async function formularioAporte(vista, ctx, socios) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cuentas;
  try { cuentas = cuentasQuePagan(await cuentasDinero(true)); } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  const id = nuevoId();   // el mismo id en los reintentos: el servidor no duplica el aporte
  const selSocio = h('select', { id: 'aporte-socio' }, h('option', { value: '' }, 'Elija el socio'), socios.map((s) => h('option', { value: s.socio_id }, s.nombre)));
  if (socios.length === 1) selSocio.value = socios[0].socio_id;
  const montoIn = inputMonto('aporte-monto');
  const selCuenta = selectCuentas(cuentas, { id: 'aporte-cuenta' }, { vacio: 'Elija a qué caja o banco entra' });
  const fechaIn = inputFecha('aporte-fecha', hoy(), { max: hoy() });
  const nota = h('input', { id: 'aporte-nota', type: 'text', maxlength: 300, placeholder: 'Ej.: capital para comprar mercadería' });
  const referencia = h('input', { id: 'aporte-referencia', type: 'text', maxlength: 100, placeholder: 'Ej.: depósito 7788' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'aporte-guardar' }, icono('sube'), 'Registrar el aporte');
  const form = h('form', { class: 'formulario', novalidate: true },
    mensaje('info', 'Es dinero del socio que entra al negocio: no es una venta ni una ganancia.', 'En la contabilidad va a "Aportes de socios" (patrimonio).'),
    campo('¿Qué socio aporta?', selSocio), campo('Monto (L)', montoIn), campo('¿A qué caja o banco entra?', selCuenta),
    h('div', { class: 'dos-columnas' }, campo('Fecha', fechaIn), campo('Referencia (opcional)', referencia)),
    campo('Nota (opcional)', nota), zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const falla = (t, foco = null) => { zonaError.append(errorSimple(t)); if (foco) foco.focus(); };
    if (!selSocio.value) return falla('Elija el socio que aporta.', selSocio);
    const m = aCentavos(montoIn.value);
    if (!m) return falla(textoMonto(montoIn, 'Escriba el monto (mayor que cero).'), montoIn);
    if (!selCuenta.value) return falla('Elija a qué caja o banco entra el dinero.', selCuenta);
    const socio = socios.find((s) => s.socio_id === selSocio.value);
    const cuenta = cuentas.find((c) => c.cuenta_dinero_id === selCuenta.value);
    const ok = await confirmar({ titulo: `¿Registrar el aporte de ${socio.nombre}?`, textoBoton: 'Sí, registrar',
      texto: `Aporte de ${dinero(m)} de ${socio.nombre} · entra a ${cuenta.nombre}. No cuenta como ganancia.` });
    if (!ok) return;
    const datos = { socio_id: socio.socio_id, monto_centavos: m, cuenta_dinero_id: cuenta.cuenta_dinero_id, fecha: fechaIn.value || hoy() };
    if (nota.value.trim()) datos.nota = nota.value.trim();
    if (referencia.value.trim()) datos.referencia = referencia.value.trim();
    const r = await conBoton(boton, zonaError, () => escribir('registrar_aporte_socio', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: id }));
    if (!r) return;
    olvidarDatos('cuentas');
    aviso(`Aporte de ${dinero(r.monto_centavos)} de ${r.socio} · entra a ${r.cuenta}`, 'ok', 8000);
    volver();
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-aporte' },
    titulo('h1', 'sube', 'Registrar aporte de un socio', { id: 't-aporte' }), form));
  selSocio.focus();
}

// Usar un fondo: para qué (motivo), de qué cuenta sale, en qué se usa (categoría de gasto) y el comprobante.
async function formularioUso(vista, ctx, fondos) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cuentas, cats, codigos;
  try {
    [cuentas, cats] = await Promise.all([cuentasDinero(true).then(cuentasQuePagan), categoriasGasto(true)]);
    codigos = new Map((await Promise.all([...new Set(cats.map((c) => c.cuenta_id))].map((idc) => leer('cuenta', { id: idc })))).flat().map((c) => [c.id, c.codigo]));
  } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  const conSaldo = fondos.filter((f) => Number(f.saldo_centavos) > 0);
  const id = nuevoId();
  const selFondo = h('select', { id: 'uso-fondo' }, conSaldo.map((f) => h('option', { value: f.fondo_id }, `${f.nombre} · tiene ${dinero(f.saldo_centavos)}`)));
  const montoIn = inputMonto('uso-monto');
  const para = h('input', { id: 'uso-para', type: 'text', maxlength: 300, placeholder: 'Ej.: comprar una vitrina nueva' });
  const selCuenta = selectCuentas(cuentas, { id: 'uso-cuenta' }, { vacio: 'Elija de dónde sale el dinero', elegida: conSaldo[0] && conSaldo[0].cuenta_dinero_id });
  selFondo.addEventListener('change', () => { const f = conSaldo.find((x) => x.fondo_id === selFondo.value); if (f && f.cuenta_dinero_id) selCuenta.value = f.cuenta_dinero_id; });
  const selCat = h('select', { id: 'uso-categoria' }, h('option', { value: '' }, 'Elija en qué se usa'), cats.map((c) => h('option', { value: c.id }, c.nombre)));
  const foto = h('input', { id: 'uso-foto', type: 'file', accept: 'image/*,application/pdf', capture: 'environment' });
  const fechaIn = inputFecha('uso-fecha', hoy(), { max: hoy() });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const hayStorage = Boolean(config.bucketComprobantes);
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'uso-guardar', disabled: !hayStorage }, 'Usar el fondo');
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('¿Qué fondo?', selFondo), campo('Monto (L)', montoIn), campo('¿Para qué se usa?', para, 'Queda en la bitácora.'),
    campo('¿De dónde sale el dinero?', selCuenta), campo('¿En qué se usa?', selCat, 'La categoría de gasto dice a qué cuenta va.'),
    campo('Fecha', fechaIn), campo('Foto del comprobante (obligatoria)', foto),
    hayStorage ? null : mensaje('info', 'Para usar un fondo hace falta guardar la foto del comprobante en internet.',
      'Este programa todavía no tiene activado ese almacenamiento. Pídalo al proveedor del programa.', { dataset: { info: 'sin-almacenamiento' } }),
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const falla = (t, q = '', foco = null) => { zonaError.append(errorSimple(t, q)); if (foco) foco.focus(); };
    const f = conSaldo.find((x) => x.fondo_id === selFondo.value);
    const m = aCentavos(montoIn.value);
    if (!m) return falla(textoMonto(montoIn, 'Escriba el monto.'), '', montoIn);
    if (m > Number(f.saldo_centavos)) return falla(`El fondo ${f.nombre} solo tiene ${dinero(f.saldo_centavos)}.`, 'Baje el monto.', montoIn);
    if (para.value.trim().length < 5) return falla('Escriba para qué se usa (mínimo 5 letras).', '', para);
    if (!selCuenta.value) return falla('Elija de qué caja o banco sale el dinero.', '', selCuenta);
    if (!selCat.value) return falla('Elija en qué se usa.', '', selCat);
    const archivo = foto.files && foto.files[0];
    if (!archivo) return falla('Tome o elija la foto del comprobante.', 'Es obligatoria para usar un fondo.', foto);
    const cuenta = cuentas.find((c) => c.cuenta_dinero_id === selCuenta.value);
    const ok = await confirmar({ titulo: '¿Usar el fondo?', textoBoton: 'Sí, usar',
      texto: `${dinero(m)} del fondo ${f.nombre} para "${para.value.trim()}" · sale de ${cuenta.nombre}.` });
    if (!ok) return;
    const r = await conBoton(boton, zonaError, async () => {
      const comp = await subirComprobante(empresaId(), 'fondos', archivo);
      return escribir('usar_fondo', { p_fondo_id: f.fondo_id, p_motivo: para.value.trim(), p_id_operacion: id,
        p_datos: { monto_centavos: m, cuenta_dinero_id: selCuenta.value, cuenta_destino: codigos.get(cats.find((c) => c.id === selCat.value).cuenta_id),
          fecha: fechaIn.value || hoy(), comprobante: comp } });
    });
    if (!r) return;
    olvidarDatos('cuentas');
    const espera = r.estado === 'pendiente_aprobacion';
    if (espera) window.dispatchEvent(new Event('pendientes-cambiaron'));
    aviso(espera ? `Uso del fondo ${f.nombre} por ${dinero(m)} en espera de aprobación del dueño · todavía no sale dinero`
      : `Uso del fondo ${f.nombre} por ${dinero(m)} guardado · sale de ${cuenta.nombre} · al fondo le quedan ${dinero(r.saldo_fondo_centavos)}`, espera ? 'info' : 'ok', 8000);
    volver();
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-uso' },
    titulo('h1', 'baja', 'Usar un fondo', { id: 't-uso' }), form));
}

// Pagar a un socio lo que se le debe de los repartos (retiro de utilidades).
async function formularioDividendos(vista, ctx, s) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cuentas;
  try { cuentas = cuentasQuePagan(await cuentasDinero(true)); } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  const id = nuevoId();
  const pend = Number(s.dividendos_pendientes_centavos);
  const montoIn = inputMonto('socio-monto', pend);
  const selCuenta = selectCuentas(cuentas, { id: 'socio-cuenta' }, { vacio: 'Elija de dónde sale el dinero' });
  const fechaIn = inputFecha('socio-fecha', hoy(), { max: hoy() });
  const referencia = h('input', { id: 'socio-referencia', type: 'text', maxlength: 100 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'socio-pagar' }, icono('billetes'), 'Registrar el pago');
  const form = h('form', { class: 'formulario', novalidate: true },
    h('div', { class: 'fila fila-total' }, h('span', {}, 'Se le debe'), monto(dinero(pend), { sentido: 'sale' })),
    campo('Monto que se le paga (L)', montoIn), campo('¿De dónde sale el dinero?', selCuenta),
    h('div', { class: 'dos-columnas' }, campo('Fecha', fechaIn), campo('Referencia (opcional)', referencia)),
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const m = aCentavos(montoIn.value);
    if (!m) { zonaError.append(errorSimple(textoMonto(montoIn, 'Escriba el monto.'))); montoIn.focus(); return; }
    if (m > pend) { zonaError.append(errorSimple(`A ${s.nombre} se le deben ${dinero(pend)}; no puede pagarle más.`)); montoIn.focus(); return; }
    if (!selCuenta.value) { zonaError.append(errorSimple('Elija de qué caja o banco sale el dinero.')); selCuenta.focus(); return; }
    const cuenta = cuentas.find((c) => c.cuenta_dinero_id === selCuenta.value);
    const ok = await confirmar({ titulo: `¿Pagar a ${s.nombre}?`, textoBoton: 'Sí, pagar', texto: `Pago de ${dinero(m)} a ${s.nombre} · sale de ${cuenta.nombre}.` });
    if (!ok) return;
    const datos = { socio_id: s.socio_id, monto_centavos: m, cuenta_dinero_id: selCuenta.value, fecha: fechaIn.value || hoy() };
    if (referencia.value.trim()) datos.referencia = referencia.value.trim();
    const r = await conBoton(boton, zonaError, () => escribir('pagar_dividendos', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: id }), 'Pagando…');
    if (!r) return;
    olvidarDatos('cuentas');
    aviso(`Pago de ${dinero(r.monto_centavos)} a ${s.nombre} · sale de ${cuenta.nombre}${r.pendiente_centavos ? ` · todavía se le deben ${dinero(r.pendiente_centavos)}` : ''}`, 'ok', 8000);
    volver();
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-socio' },
    titulo('h1', 'billetes', `Pagar a ${s.nombre}`, { id: 't-socio' }), form));
  montoIn.focus();
}

// Repartir la utilidad cobrada de un mes cerrado con la regla guardada (solo el dueño).
async function formularioReparto(vista, ctx, regla) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cerrados, hechos, cuentas;
  try {
    [cerrados, hechos, cuentas] = await Promise.all([leer('periodo', { empresa_id: empresaId(), estado: 'cerrado' }, { orden: 'anio.desc', limite: 60 }),
      leer('v_distribucion', { empresa_id: empresaId(), anulada: false }, { limite: 200 }), cuentasDinero(true).then(cuentasQuePagan)]);
  } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  const ya = new Set(hechos.map((x) => `${x.anio}-${x.mes}`));
  const meses = cerrados.filter((x) => !ya.has(`${x.anio}-${x.mes}`)).sort((a, b) => b.anio - a.anio || b.mes - a.mes).slice(0, 24);
  const id = nuevoId();
  const selMes = h('select', { id: 'reparto-mes' }, meses.map((x) => h('option', { value: `${x.anio}-${x.mes}` }, `${MESES[x.mes - 1]} de ${x.anio}`)));
  const separar = h('input', { type: 'checkbox', id: 'reparto-separar' });
  const selDesde = selectCuentas(cuentas, { id: 'reparto-desde' }, { vacio: 'Elija de dónde sale' });
  const zonaSeparar = h('div', { hidden: true }, campo('¿De dónde se pasa el dinero a la cuenta de cada fondo?', selDesde));
  separar.addEventListener('change', () => { zonaSeparar.hidden = !separar.checked; });
  const motivo = h('input', { id: 'reparto-motivo', type: 'text', maxlength: 300, value: '' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'reparto-guardar', disabled: !meses.length || !regla }, 'Repartir');
  const form = h('form', { class: 'formulario', novalidate: true },
    regla ? h('p', {}, `Se reparte con su regla: ${regla}.`) : mensaje('info', 'Todavía no hay una regla para repartir.', 'La guarda el dueño con el proveedor del programa.'),
    meses.length ? campo('¿Qué mes?', selMes, 'Solo meses cerrados que todavía no se repartieron. Se reparte la utilidad COBRADA de ese mes.')
      : mensaje('info', 'No hay meses cerrados sin repartir.', 'Primero cierre el mes (Reportes > Cierre de mes).'),
    h('label', { class: 'opcion-check' }, separar, ' Separar también el dinero en la cuenta de cada fondo (traslado)'), zonaSeparar,
    campo('Motivo', motivo, 'Ej.: Reparto de septiembre (mínimo 5 letras).'),
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    if (!selMes.value) { zonaError.append(errorSimple('Elija el mes.')); return; }
    if (motivo.value.trim().length < 5) { zonaError.append(errorSimple('Escriba el motivo (mínimo 5 letras).')); motivo.focus(); return; }
    if (separar.checked && !selDesde.value) { zonaError.append(errorSimple('Elija de dónde sale el dinero para separarlo.')); return; }
    const [anio, mes] = selMes.value.split('-').map(Number);
    const ok = await confirmar({ titulo: `¿Repartir ${MESES[mes - 1]} de ${anio}?`, textoBoton: 'Sí, repartir',
      texto: 'La utilidad cobrada de ese mes pasa a los fondos y a los socios según la regla. Se hace una sola vez por mes (se puede anular si nadie lo ha usado).' });
    if (!ok) return;
    const datos = { fecha: hoy() };
    if (separar.checked) datos.separar_desde = selDesde.value;
    const r = await conBoton(boton, zonaError, () => escribir('distribuir_utilidades', { p_empresa_id: empresaId(), p_anio: anio, p_mes: mes,
      p_datos: datos, p_motivo: motivo.value.trim(), p_id_operacion: id }), 'Repartiendo…');
    if (!r) return;
    olvidarDatos('cuentas');
    aviso(`Reparto de ${MESES[mes - 1]} hecho · ${dinero(r.base_centavos)} de utilidad cobrada`, 'ok', 8000);
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-repok' },
      titulo('h1', 'capas', `Reparto de ${MESES[mes - 1]} de ${anio}`, { id: 't-repok' }),
      mensaje('ok', `Se repartieron ${dinero(r.base_centavos)} de utilidad cobrada.`, null, { class: 'resultado', dataset: { info: 'reparto-hecho' } }),
      (r.partes || []).map((x) => h('div', { class: 'fila' }, h('span', {}, `${x.nombre} (${pct(x.porcentaje)})`), h('span', { class: 'monto' }, dinero(x.monto_centavos)))),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: volver }, 'Volver a fondos'))));
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-reparto' },
    titulo('h1', 'capas', 'Repartir la utilidad de un mes', { id: 't-reparto' }), form));
}

// Crear un fondo (solo el dueño): nombre, tipo, meta y la cuenta donde se separa (opcional).
async function formularioFondo(vista, ctx) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cuentas;
  try { cuentas = cuentasQuePagan(await cuentasDinero(true)); } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  const nombre = h('input', { id: 'fondo-nombre', type: 'text', maxlength: 100, placeholder: 'Ej.: Aguinaldos' });
  const selTipo = h('select', { id: 'fondo-tipo' }, Object.entries(TIPO_FONDO).map(([v, t]) => h('option', { value: v }, t)));
  const selMeta = h('select', { id: 'fondo-meta' }, h('option', { value: 'ninguna' }, 'Sin meta'), h('option', { value: 'monto' }, 'Juntar un monto'),
    h('option', { value: 'meses_pagos_fijos' }, 'Juntar varios meses de pagos fijos'));
  const metaMonto = inputMonto('fondo-meta-monto');
  const metaMeses = h('input', { id: 'fondo-meta-meses', type: 'number', min: '1', max: '24', step: '1', inputmode: 'numeric', value: '3' });
  const zonaMeta = h('div', {});
  const pintarMeta = () => zonaMeta.replaceChildren(selMeta.value === 'monto' ? campo('Monto de la meta (L)', metaMonto)
    : selMeta.value === 'meses_pagos_fijos' ? campo('¿Cuántos meses?', metaMeses) : '');
  selMeta.addEventListener('change', pintarMeta);
  const selCuenta = selectCuentas(cuentas, { id: 'fondo-cuenta' }, { vacio: 'No separar (queda junto con el resto)', saldo: false });
  const motivo = h('input', { id: 'fondo-motivo', type: 'text', maxlength: 300 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'fondo-guardar' }, 'Crear fondo');
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Nombre', nombre), campo('Tipo', selTipo), campo('Meta', selMeta), zonaMeta,
    campo('¿En qué cuenta se separa el dinero? (opcional)', selCuenta), campo('Motivo', motivo, 'Mínimo 5 letras. Queda en la bitácora.'),
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    if (nombre.value.trim().length < 3) { zonaError.append(errorSimple('Escriba el nombre del fondo.')); nombre.focus(); return; }
    const datos = { nombre: nombre.value.trim(), tipo: selTipo.value, meta_tipo: selMeta.value };
    if (selMeta.value === 'monto') {
      const m = aCentavos(metaMonto.value);
      if (!m) { zonaError.append(errorSimple('Escriba el monto de la meta.')); metaMonto.focus(); return; }
      datos.meta_monto_centavos = m;
    }
    if (selMeta.value === 'meses_pagos_fijos') {
      const n = Number(metaMeses.value);
      if (!Number.isInteger(n) || n < 1 || n > 24) { zonaError.append(errorSimple('Los meses van de 1 a 24.')); metaMeses.focus(); return; }
      datos.meta_meses = n;
    }
    if (selCuenta.value) datos.cuenta_dinero_id = selCuenta.value;
    if (motivo.value.trim().length < 5) { zonaError.append(errorSimple('Escriba el motivo (mínimo 5 letras).')); motivo.focus(); return; }
    const r = await conBoton(boton, zonaError, () => rpc('crear_fondo', { p_empresa_id: empresaId(), p_datos: datos, p_motivo: motivo.value.trim() }));
    if (!r) return;
    aviso(`Fondo ${r.nombre} creado${r.meta_centavos ? ` · meta ${dinero(r.meta_centavos)}` : ''}`, 'ok', 7000);
    volver();
  });
  pintarMeta();
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-nfondo' },
    titulo('h1', 'capas', 'Nuevo fondo', { id: 't-nfondo' }), form));
  nombre.focus();
}
