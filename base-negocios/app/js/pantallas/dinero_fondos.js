// Dinero · "Fondos y socios" (app 0.7.0, módulo fondos): cada fondo (reinversión, emergencias…) con su
// saldo, de dónde viene (repartos de la utilidad cobrada), en qué se usó, su meta y en qué cuenta está
// (estado_fondos); los socios con lo que se les debe; los movimientos (v_fondo_movimiento). Acciones del
// núcleo: usar un fondo (usar_fondo, con comprobante; si no lo pide el dueño queda en espera de su
// aprobación), pagar a un socio su parte (pagar_dividendos), repartir la utilidad de un mes cerrado
// (distribuir_utilidades, solo el dueño) y crear un fondo (crear_fondo, solo el dueño).
import { leer, rpc, escribir, nuevoId, subirComprobante, config } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha, aCentavos } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, titulo, filaIcono, chip, chipEstado, monto,
  estadoVacio, mensaje } from '../ui.js';
import { cuentasDinero, cuentasQuePagan, categoriasGasto, alcance, olvidarDatos } from '../datos.js';
import { hoy, selectCuentas, inputMonto, inputFecha, cifraChica, textoMonto } from '../formularios.js';

const TIPO_FONDO = { reinversion: 'Reinversión', emergencias: 'Emergencias', otro: 'Otro' };
const MOV = { aporte: 'Reparto de utilidad', anulacion_aporte: 'Reparto anulado', uso: 'Uso del fondo' };
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const pct = (n) => `${Number(n).toLocaleString('en-US', { maximumFractionDigits: 2 })} %`;

export async function mostrar(vista, ctx) {
  const [e, movs, cuentas, al] = await Promise.all([rpc('estado_fondos', { p_empresa_id: empresaId() }),
    leer('v_fondo_movimiento', { empresa_id: empresaId() }, { orden: 'registrado_en.desc', limite: 30 }),
    puede('dinero.ver') ? cuentasDinero(true) : [], alcance()]);
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
    abajo: puede('fondos.pagar_dividendos') && Number(s.dividendos_pendientes_centavos) > 0 ? h('div', { class: 'botones' },
      h('button', { type: 'button', class: 'boton boton-principal', 'aria-label': `Pagar a ${s.nombre}`, onclick: () => formularioDividendos(vista, ctx, s) },
        icono('billetes'), 'Pagar su parte')) : null,
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
    puede('fondos.configurar') ? h('button', { type: 'button', class: 'boton', id: 'nuevo-fondo', onclick: () => formularioFondo(vista, ctx) }, icono('mas'), 'Nuevo fondo') : null);

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
        : estadoVacio({ icono: 'movimientos', chico: true, texto: 'Todavía no hay movimientos en los fondos.' })));
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
