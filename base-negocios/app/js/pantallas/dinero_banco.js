// Dinero · "Cuadrar con el banco" (app 0.7.0, módulo conciliacion): el flujo del núcleo en simple.
//   1) Elegir el banco y el mes.  2) Cargar el estado de cuenta (archivo CSV del banco o escribiendo los
//   movimientos) -> importar_estado_cuenta (lo que coincide se empareja solo).  3) Ver la diferencia
//   (ver_conciliacion) y marcar a mano lo que es el mismo movimiento (emparejar_manual), crear lo que falta
//   (comisión o intereses del banco: registrar_diferencia_banco) o deshacer (deshacer_emparejamiento).
//   4) Cerrar el mes cuando cuadra (cerrar_conciliacion). Nada se borra.
import { leer, rpc, escribir, nuevoId } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha, aCentavos } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, pedirMotivo, titulo, filaIcono, chip, chipEstado, monto,
  estadoVacio, mensaje } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { cuentasDinero, olvidarDatos } from '../datos.js';
import { hoy, cifraChica } from '../formularios.js';

const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const OPERACION = { gasto: 'Gasto', compra: 'Compra de contado', pago_proveedor: 'Pago a proveedor', venta: 'Venta', cobro: 'Cobro',
  dinero_deposito: 'Depósito', confirmacion_deposito: 'Depósito confirmado', dinero_retiro: 'Retiro', dinero_traslado: 'Traslado',
  dinero_reposicion_caja_chica: 'Reposición de caja chica', diferencia_banco: 'Creado al cuadrar', pago_dividendos: 'Pago a socio',
  uso_fondo: 'Uso de fondo', anulacion_compra: 'Compra anulada', anulacion_pago_proveedor: 'Pago anulado', anulacion_gasto: 'Gasto anulado' };
const nombreOp = (o) => OPERACION[o] || String(o || '').replace(/_/g, ' ');
const textoMes = (anio, mes) => `${MESES[mes - 1]} de ${anio}`;
const firmado = (c) => monto(dinero(Math.abs(c)), { sentido: c < 0 ? 'sale' : 'entra', signo: c < 0 ? '-' : '+' });

// Lo elegido se recuerda mientras la app está abierta.
const eleccion = { banco: null, mes: null };

export async function mostrar(vista, ctx) {
  const [cuentas, concs] = await Promise.all([cuentasDinero(true), leer('v_conciliacion', { empresa_id: empresaId() }, { orden: 'anio.desc', limite: 500 })]);
  if (!ctx.sigueVigente()) return;
  // Solo los bancos que este usuario ve (un usuario limitado: los de su sucursal y los de toda la empresa).
  const bancos = cuentas.filter((c) => c.tipo === 'banco');
  const misConcs = concs.filter((c) => bancos.some((b) => b.cuenta_dinero_id === c.cuenta_dinero_id));
  if (!bancos.length) {
    vista.append(h('section', { class: 'tarjeta' }, titulo('h1', 'conciliar', 'Cuadrar con el banco'),
      estadoVacio({ icono: 'banco', titulo: 'Primero guarde sus cuentas de banco', texto: 'Aquí compara lo que dice el banco con lo que dice el programa, mes por mes.',
        boton: hayEnMenu(ctx.menu || [], 'ajustes', 'cajas') ? { texto: 'Agregar banco', href: '#/ajustes/cajas', icono: 'mas' } : null })));
    return;
  }
  const [ha, hm] = hoy().split('-').map(Number);
  const meses = Array.from({ length: 13 }, (_, i) => { const d = new Date(Date.UTC(ha, hm - 1 - i, 1)); return `${d.getUTCFullYear()}-${d.getUTCMonth() + 1}`; });
  if (!eleccion.banco || !bancos.some((b) => b.cuenta_dinero_id === eleccion.banco)) eleccion.banco = bancos[0].cuenta_dinero_id;
  if (!eleccion.mes) eleccion.mes = meses[1];
  const selBanco = h('select', { id: 'banco-cuenta' }, bancos.map((b) => h('option', { value: b.cuenta_dinero_id }, `${b.nombre}${b.numero_enmascarado ? ' ' + b.numero_enmascarado : ''}`)));
  const selMes = h('select', { id: 'banco-mes' }, meses.map((m) => { const [a, n] = m.split('-').map(Number); return h('option', { value: m }, textoMes(a, n) + (m === meses[0] ? ' (este mes)' : '')); }));
  selBanco.value = eleccion.banco; selMes.value = eleccion.mes;
  const trabajados = h('div', { class: 'chips', id: 'meses-trabajados' });
  const zona = h('div', { class: 'lista', id: 'zona-banco' });
  async function cargar() {
    eleccion.banco = selBanco.value; eleccion.mes = selMes.value;
    const [a, m] = eleccion.mes.split('-').map(Number);
    const deEste = misConcs.filter((c) => c.cuenta_dinero_id === eleccion.banco).sort((x, y) => y.anio - x.anio || y.mes - x.mes);
    trabajados.replaceChildren(...(deEste.length ? [h('span', { class: 'ayuda' }, 'Meses ya trabajados:'), ...deEste.slice(0, 12).map((c) =>
      h('button', { type: 'button', class: 'boton', 'aria-label': `Ver ${textoMes(c.anio, c.mes)}`,
        onclick: () => { selMes.value = `${c.anio}-${c.mes}`; if (selMes.value) cargar(); } },
      `${textoMes(c.anio, c.mes)} `, chipEstado(c.estado === 'cerrada' ? 'cerrada' : 'abierta')))] : []));
    const c = deEste.find((x) => x.anio === a && x.mes === m);
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    const banco = bancos.find((b) => b.cuenta_dinero_id === eleccion.banco);
    if (c) await verConciliacion(zona, ctx, c.conciliacion_id, { banco, recargar: () => { vista.replaceChildren(); mostrar(vista, ctx); } });
    else formularioCarga(zona, ctx, { banco, anio: a, mes: m, recargar: () => { vista.replaceChildren(); mostrar(vista, ctx); } });
  }
  selBanco.addEventListener('change', cargar);
  selMes.addEventListener('change', cargar);
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-banco' },
    titulo('h1', 'conciliar', 'Cuadrar con el banco', { id: 't-banco' }),
    h('p', { class: 'ayuda' }, 'Compare lo que dice su estado de cuenta con lo que dice el programa. Lo que coincide se marca solo; lo demás usted lo revisa.'),
    h('div', { class: 'dos-columnas filtros' }, campo('Banco', selBanco), campo('Mes', selMes)), trabajados), zona);
  await cargar();
}

// ---------------- Paso 2: cargar el estado de cuenta ----------------
function formularioCarga(zona, ctx, { banco, anio, mes, recargar, conciliacionId = null }) {
  if (!puede('conciliacion.conciliar')) {
    zona.replaceChildren(h('section', { class: 'tarjeta' }, estadoVacio({ icono: 'conciliar', chico: true,
      texto: `Todavía no se ha cargado el estado de cuenta de ${textoMes(anio, mes)}. Lo carga el dueño o un administrador.` })));
    return;
  }
  const id = nuevoId();
  const archivo = h('input', { id: 'banco-archivo', type: 'file', accept: '.csv,text/csv,text/plain' });
  const saldoIni = h('input', { id: 'banco-saldo-inicial', type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: '0.00' });
  const saldoFin = h('input', { id: 'banco-saldo-final', type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: '0.00' });
  const filas = h('div', { class: 'lista', id: 'banco-filas' });
  const lineas = [];
  const zonaArchivo = h('div', { 'aria-live': 'polite' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'banco-cargar' }, icono('subir'), 'Cargar estado de cuenta');
  const desde = `${anio}-${String(mes).padStart(2, '0')}-01`;
  function agregar(x = {}) {
    const f = h('input', { type: 'date', value: x.fecha || desde, 'aria-label': 'Fecha', dataset: { campo: 'fecha' } });
    const d = h('input', { type: 'text', maxlength: 200, value: x.descripcion || '', placeholder: 'Ej.: COMISION MANEJO', 'aria-label': 'Descripción', dataset: { campo: 'descripcion' } });
    const r = h('input', { type: 'text', maxlength: 100, value: x.referencia || '', 'aria-label': 'Referencia', dataset: { campo: 'referencia' } });
    const m = h('input', { type: 'text', inputmode: 'decimal', value: x.monto_centavos ? (Math.abs(x.monto_centavos) / 100).toFixed(2) : '', placeholder: '0.00', 'aria-label': 'Monto', dataset: { campo: 'monto' } });
    const s = h('select', { 'aria-label': 'Entra o sale', dataset: { campo: 'signo' } }, h('option', { value: '-' }, 'Sale del banco'), h('option', { value: '+' }, 'Entra al banco'));
    if (x.monto_centavos > 0) s.value = '+';
    const l = { f, d, r, m, s };
    l.nodo = h('div', { class: 'grupo-campos fila-banco' },
      h('div', { class: 'dos-columnas' }, campo('Fecha', f), campo('Descripción', d), campo('Referencia (opcional)', r), campo('Monto (L)', m), campo('¿Entra o sale?', s)),
      h('button', { type: 'button', class: 'boton', 'aria-label': 'Quitar esta fila', onclick: () => { lineas.splice(lineas.indexOf(l), 1); l.nodo.remove(); } }, icono('cerrar'), 'Quitar'));
    lineas.push(l);
    filas.append(l.nodo);
  }
  archivo.addEventListener('change', async () => {
    zonaArchivo.replaceChildren();
    const a = archivo.files && archivo.files[0];
    if (!a) return;
    const r = leerCsvBanco(await a.text());
    if (!r.filas.length) { zonaArchivo.append(errorSimple('No se encontraron movimientos en el archivo.', r.errores[0] || 'Revise que sea el CSV del estado de cuenta (con fecha, descripción y monto).')); return; }
    for (const l of [...lineas]) l.nodo.remove();
    lineas.length = 0;
    for (const x of r.filas) agregar(x);
    zonaArchivo.append(mensaje(r.errores.length ? 'info' : 'ok', `Se leyeron ${r.filas.length} movimientos del archivo.`,
      r.errores.length ? `${r.errores.length} línea(s) no se entendieron y se dejaron fuera: ${r.errores.slice(0, 3).join('; ')}` : 'Revíselos abajo antes de cargar.'));
  });
  const form = h('form', { class: 'formulario', novalidate: true },
    h('p', {}, `Estado de cuenta de ${banco.nombre} de ${textoMes(anio, mes)}.`),
    h('ol', { class: 'pasos-simples' }, h('li', {}, 'Descargue el estado de cuenta del mes de su banca en línea (archivo CSV).'),
      h('li', {}, 'Súbalo aquí o escriba los movimientos uno por uno.'), h('li', {}, 'Escriba el saldo con que empieza y termina el mes según el banco.')),
    campo('Archivo CSV del banco (opcional)', archivo, 'Columnas: fecha, descripción, referencia y monto (o débito y crédito).'), zonaArchivo,
    h('div', { class: 'dos-columnas' }, campo('Saldo al empezar el mes, según el banco (L)', saldoIni), campo('Saldo al terminar el mes, según el banco (L)', saldoFin)),
    h('h3', { class: 'titulo-chico' }, 'Movimientos del banco'), filas,
    h('button', { type: 'button', class: 'boton', id: 'banco-agregar-fila', onclick: () => agregar() }, icono('mas'), 'Agregar un movimiento'),
    zonaError, boton);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const falla = (t, q = '', foco = null) => { zonaError.append(errorSimple(t, q)); if (foco) foco.focus(); };
    const ini = conSigno(saldoIni.value), fin = conSigno(saldoFin.value);
    if (saldoIni.value.trim() && ini === null) return falla('El saldo inicial no es un monto válido.', '', saldoIni);
    if (fin === null) return falla('Escriba el saldo con que termina el mes según el banco.', 'Lo dice al final del estado de cuenta.', saldoFin);
    if (!lineas.length) return falla('Agregue los movimientos del banco.', 'Suba el archivo CSV o toque "Agregar un movimiento".');
    const datos = { archivo: (archivo.files && archivo.files[0] && archivo.files[0].name.slice(0, 200)) || 'escrito a mano', saldo_final_centavos: fin, filas: [] };
    if (ini !== null) datos.saldo_inicial_centavos = ini;
    for (const [i, l] of lineas.entries()) {
      const m = aCentavos(l.m.value);
      if (!l.f.value) return falla(`Fila ${i + 1}: escriba la fecha.`, '', l.f);
      if (l.d.value.trim().length < 2) return falla(`Fila ${i + 1}: escriba la descripción.`, '', l.d);
      if (!m) return falla(`Fila ${i + 1}: escriba el monto.`, 'Solo números, mayor que cero.', l.m);
      const x = { fecha: l.f.value, descripcion: l.d.value.trim(), monto_centavos: l.s.value === '-' ? -m : m };
      if (l.r.value.trim()) x.referencia = l.r.value.trim();
      datos.filas.push(x);
    }
    const ok = await confirmar({ titulo: '¿Cargar el estado de cuenta?', textoBoton: 'Sí, cargar',
      texto: `${datos.filas.length} movimientos de ${banco.nombre} de ${textoMes(anio, mes)}. Lo que coincida con el programa se marca solo. Si carga el mismo archivo otra vez, no se repite.` });
    if (!ok) return;
    const r = await conBoton(boton, zonaError, () => escribir('importar_estado_cuenta', { p_empresa_id: empresaId(), p_cuenta_dinero_id: banco.cuenta_dinero_id,
      p_anio: anio, p_mes: mes, p_datos: datos, p_id_operacion: id }), 'Cargando…');
    if (!r) return;
    aviso(`Estado de cuenta cargado · ${r.filas_nuevas} movimientos nuevos${r.filas_repetidas ? `, ${r.filas_repetidas} ya estaban` : ''} · ${r.emparejadas_automaticamente} se marcaron solos`, 'ok', 8000);
    recargar();
  });
  agregar();
  zona.replaceChildren(h('section', { class: 'tarjeta', 'aria-labelledby': 't-carga' },
    titulo('h2', 'subir', conciliacionId ? 'Cargar más movimientos' : 'Cargar el estado de cuenta', { id: 't-carga' }), form));
}

// ---------------- Paso 3 y 4: ver, marcar, crear lo que falta y cerrar ----------------
async function verConciliacion(zona, ctx, conciliacionId, { banco, recargar }) {
  let r, periodo;
  try {
    r = await rpc('ver_conciliacion', { p_conciliacion_id: conciliacionId });
    [periodo] = await leer('periodo', { empresa_id: empresaId(), anio: r.anio, mes: r.mes });
  } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
  if (!ctx.sigueVigente()) return;
  const abierta = r.estado !== 'cerrada';
  const conciliar = abierta && puede('conciliacion.conciliar');
  const registrar = abierta && puede('conciliacion.registrar');
  const mesCerrado = periodo && periodo.estado === 'cerrado';
  const recargarAqui = () => verConciliacion(zona, ctx, conciliacionId, { banco, recargar });
  const sel = { banco: null, sistema: null };
  const radios = [];
  const radio = (grupo, valor, etiqueta, extra) => {
    const x = h('input', { type: 'radio', name: `marcar-${grupo}`, value: valor, 'aria-label': etiqueta });
    x.addEventListener('change', () => { sel[grupo] = extra; });
    radios.push(x);
    return x;
  };
  const crearFalta = (b, tipo) => {
    const idOp = nuevoId();
    const fechaUsar = mesCerrado ? hoy() : b.fecha;
    const que = tipo === 'comision_bancaria' ? 'la comisión del banco' : 'los intereses';
    confirmar({ titulo: `¿Crear ${que}?`, textoBoton: 'Sí, crear',
      texto: `${dinero(Math.abs(b.monto_centavos))} (${b.descripcion}) ${b.monto_centavos < 0 ? 'sale de' : 'entra a'} ${r.cuenta} con fecha ${fecha(fechaUsar)}`
        + (mesCerrado ? ` (el mes de ${textoMes(r.anio, r.mes)} ya está cerrado: va con fecha de hoy).` : '.') }).then(async (ok) => {
      if (!ok) return;
      try {
        await escribir('registrar_diferencia_banco', { p_conciliacion_id: conciliacionId, p_banco_movimiento_id: b.banco_movimiento_id,
          p_datos: { tipo, descripcion: b.descripcion.slice(0, 200), fecha: fechaUsar }, p_id_operacion: idOp });
        olvidarDatos('cuentas');
        aviso(`${tipo === 'comision_bancaria' ? 'Comisión' : 'Intereses'} de ${dinero(Math.abs(b.monto_centavos))} creados en ${r.cuenta} y marcados`, 'ok', 7000);
        recargarAqui();
      } catch (err) { zonaAcciones.replaceChildren(await cajaError(err)); }
    });
  };
  const filasBanco = (r.en_banco_no_en_sistema || []).map((b) => filaIcono({
    icono: 'banco', color: 'dorado',
    burbuja: conciliar ? h('label', { class: 'casilla-toque' }, radio('banco', b.banco_movimiento_id, `Elegir ${b.descripcion} del ${fecha(b.fecha)}`, b)) : null,
    titulo: h('strong', {}, b.descripcion), detalle: [fecha(b.fecha), b.referencia].filter(Boolean).join(' · '),
    derecha: firmado(b.monto_centavos),
    abajo: registrar ? h('div', { class: 'botones' },
      b.monto_centavos < 0 ? h('button', { type: 'button', class: 'boton', 'aria-label': `Crear comisión ${b.descripcion}`, onclick: () => crearFalta(b, 'comision_bancaria') }, 'Es comisión del banco') : null,
      h('button', { type: 'button', class: 'boton', 'aria-label': `Crear intereses ${b.descripcion}`, onclick: () => crearFalta(b, 'interes') }, b.monto_centavos < 0 ? 'Son intereses que cobra el banco' : 'Son intereses que paga el banco')) : null,
    props: { dataset: { banco: b.banco_movimiento_id } },
  }));
  const filasSistema = (r.en_sistema_no_en_banco || []).map((m) => filaIcono({
    icono: 'documento', color: 'azul',
    burbuja: conciliar ? h('label', { class: 'casilla-toque' }, radio('sistema', String(m.dinero_movimiento_id), `Elegir ${nombreOp(m.operacion)} del ${fecha(m.fecha)}`, m)) : null,
    titulo: h('strong', {}, nombreOp(m.operacion)), detalle: [fecha(m.fecha), m.detalle, m.referencia].filter(Boolean).join(' · '),
    derecha: firmado(m.monto_centavos),
    props: { dataset: { sistema: String(m.dinero_movimiento_id) } },
  }));
  const zonaAcciones = h('div', { 'aria-live': 'assertive' });
  const marcar = h('button', { type: 'button', class: 'boton boton-principal', id: 'banco-marcar' }, icono('check'), 'Marcar como el mismo movimiento');
  marcar.addEventListener('click', async () => {
    zonaAcciones.replaceChildren();
    if (!sel.banco || !sel.sistema) { zonaAcciones.append(errorSimple('Elija uno del banco y uno del programa.', 'Toque el círculo de cada uno.')); return; }
    if (Number(sel.banco.monto_centavos) !== Number(sel.sistema.monto_centavos)) {
      zonaAcciones.append(errorSimple('Los montos no son iguales.', `El banco dice ${dinero(sel.banco.monto_centavos)} y el programa ${dinero(sel.sistema.monto_centavos)}. Solo se marcan movimientos del mismo monto.`));
      return;
    }
    const x = await conBoton(marcar, zonaAcciones, () => rpc('emparejar_manual', { p_conciliacion_id: conciliacionId, p_banco_movimiento_id: sel.banco.banco_movimiento_id,
      p_dinero_movimiento_id: sel.sistema.dinero_movimiento_id, p_motivo: 'Marcado a mano en la app' }), 'Marcando…');
    if (!x) return;
    aviso(`Marcados como el mismo movimiento · ${dinero(sel.banco.monto_centavos)}`);
    recargarAqui();
  });
  const deshacer = (p) => pedirMotivo({ titulo: 'Deshacer esta marca', textoBoton: 'Sí, deshacer',
    explicacion: `${p.descripcion} (${dinero(p.monto_centavos)}) vuelve a quedar pendiente. Queda anotado, no se borra.`,
    accion: (motivo) => rpc('deshacer_emparejamiento', { p_pareja_id: p.pareja_id, p_motivo: motivo }) }).then((ok) => { if (ok) { aviso('Marca deshecha'); recargarAqui(); } });
  const cerrar = h('button', { type: 'button', class: 'boton boton-principal', id: 'banco-cerrar', disabled: !r.cuadra }, icono('candado'), 'Cerrar este mes');
  cerrar.addEventListener('click', async () => {
    const ok = await confirmar({ titulo: `¿Cerrar ${textoMes(r.anio, r.mes)}?`, textoBoton: 'Sí, cerrar',
      texto: 'Se guarda una foto de cómo quedó. Ya no se podrá cargar ni marcar nada de este mes; lo pendiente pasa solo al mes siguiente.' });
    if (!ok) return;
    const x = await conBoton(cerrar, zonaAcciones, () => rpc('cerrar_conciliacion', { p_conciliacion_id: conciliacionId, p_saldo_banco_final_centavos: null }), 'Cerrando…');
    if (!x) return;
    aviso(`${r.cuenta}: ${textoMes(r.anio, r.mes)} cuadrado y cerrado`, 'ok', 7000);
    recargar();
  });
  const formula = `${dinero(r.saldo_sistema_centavos)} − ${dinero(r.en_sistema_no_en_banco_centavos)} + ${dinero(r.en_banco_no_en_sistema_centavos)} = ${dinero(r.saldo_banco_calculado_centavos)}`;
  zona.replaceChildren(...[
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-conc' },
      h('div', { class: 'titulo-con-total' }, titulo('h2', 'conciliar', `${r.cuenta} · ${textoMes(r.anio, r.mes)}`, { id: 't-conc' }),
        abierta ? chipEstado('abierta') : chipEstado('cerrada')),
      h('div', { class: 'cifras' },
        cifraChica('Según el programa', dinero(r.saldo_sistema_centavos), { dato: 'saldo-sistema' }),
        cifraChica('Según el banco', dinero(r.saldo_banco_final_centavos), { dato: 'saldo-banco' }),
        cifraChica('Diferencia', dinero(r.diferencia_centavos), { dato: 'diferencia', clase: r.cuadra ? 'monto-entra' : 'monto-sale' })),
      r.cuadra ? mensaje('ok', abierta ? 'Cuadra: lo pendiente explica la diferencia.' : 'Este mes quedó cuadrado y cerrado.', null, { dataset: { info: 'cuadra' } })
        : mensaje('error', `No cuadra: faltan ${dinero(Math.abs(r.diferencia_centavos))} por explicar.`, 'Marque lo que es igual o cree lo que falta (comisiones, intereses).', { dataset: { info: 'no-cuadra' } }),
      h('p', { class: 'ayuda', dataset: { info: 'formula' } }, `Cómo se cuenta: saldo del programa − lo que está en el programa y no en el banco + lo que está en el banco y no en el programa = saldo del banco (${formula}).`),
      r.estado_cuenta_completo === false ? mensaje('info', 'El saldo inicial más los movimientos cargados no da el saldo final del banco.', 'Revise que cargó todos los movimientos del estado de cuenta.') : null),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-solo-banco' },
      titulo('h2', 'banco', 'Está en el banco y no en el programa', { id: 't-solo-banco' }),
      filasBanco.length ? h('div', { class: 'lista-filas', id: 'solo-banco' }, filasBanco)
        : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'Nada: todo lo del banco está en el programa.' }),
      titulo('h2', 'documento', 'Está en el programa y no en el banco', { id: 't-solo-sistema' }),
      filasSistema.length ? h('div', { class: 'lista-filas', id: 'solo-sistema' }, filasSistema)
        : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'Nada: todo lo del programa ya salió en el banco.' }),
      conciliar && filasBanco.length && filasSistema.length ? h('p', { class: 'ayuda' }, 'Si un movimiento del banco es el mismo que uno del programa (por ejemplo, el banco cobró el cheque días después), elija los dos y toque el botón.') : null,
      zonaAcciones,
      h('div', { class: 'botones' }, conciliar && filasBanco.length && filasSistema.length ? marcar : null,
        conciliar ? h('button', { type: 'button', class: 'boton', id: 'banco-mas', onclick: () => formularioCarga(zona, ctx, { banco, anio: r.anio, mes: r.mes, recargar, conciliacionId }) },
          icono('subir'), 'Cargar más movimientos') : null,
        conciliar ? cerrar : null)),
    (r.conciliados || []).length ? h('section', { class: 'tarjeta', 'aria-labelledby': 't-ya' },
      h('details', {}, h('summary', { id: 't-ya', class: 'titulo-chico' }, `Ya cuadrados (${r.conciliados.length})`),
        h('div', { class: 'lista-filas', id: 'ya-cuadrados' }, r.conciliados.map((p) => filaIcono({
          icono: 'check_circulo', color: 'verde', titulo: h('strong', {}, p.descripcion),
          detalle: `Banco ${fecha(p.fecha_banco)} · programa ${fecha(p.fecha_sistema)} · ${nombreOp(p.operacion)}${p.tipo === 'automatico' ? ' · marcado solo' : ''}`,
          derecha: [firmado(p.monto_centavos), chipEstado('conciliado')],
          abajo: conciliar && p.pareja_id ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', 'aria-label': `Deshacer ${p.descripcion}`,
            onclick: () => deshacer(p) }, 'Deshacer')) : null }))))) : null].filter(Boolean));
}

// Monto con signo escrito por la persona: "-1,234.50" -> -123450; vacío -> null.
function conSigno(t) {
  const s = String(t || '').trim();
  if (!s) return null;
  const neg = s.startsWith('-');
  const c = aCentavos(neg ? s.slice(1) : s);
  return c === null ? null : neg ? -c : c;
}

// ---------------- Leer el CSV del banco ----------------
// Acepta coma, punto y coma o tabulador; fechas AAAA-MM-DD o DD/MM/AAAA; montos con o sin "L", con
// signo, entre paréntesis (= negativo) y con coma de miles. Columnas por su título: fecha, descripción
// (o concepto, detalle), referencia, monto (o importe, valor) o débito y crédito por separado.
// -> { filas: [{ fecha, descripcion, referencia, monto_centavos }], errores: [texto] }
export function leerCsvBanco(texto) {
  const lineas = String(texto || '').replace(/^﻿/, '').split(/\r?\n/).filter((l) => l.trim());
  const errores = [], filas = [];
  if (lineas.length < 2) return { filas, errores: ['El archivo no tiene títulos y movimientos.'] };
  const sep = [';', '\t', ','].sort((a, b) => lineas[0].split(b).length - lineas[0].split(a).length)[0];
  const partir = (l) => {
    const out = []; let cur = '', q = false;
    for (let i = 0; i < l.length; i++) {
      const ch = l[i];
      if (ch === '"') { if (q && l[i + 1] === '"') { cur += '"'; i++; } else q = !q; } else if (ch === sep && !q) { out.push(cur.trim()); cur = ''; } else cur += ch;
    }
    out.push(cur.trim());
    return out;
  };
  const sinT = (x) => x.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const tit = partir(lineas[0]).map(sinT);
  const col = (re) => tit.findIndex((t) => re.test(t));
  const iF = col(/fecha|date/), iD = col(/desc|concepto|detalle|transac|movimiento/), iR = col(/ref|document|cheque|numero|no\./);
  const iDeb = col(/debito|cargo|retiro|salida|debe/), iCred = col(/credito|abono|deposito|entrada|haber/), iM = col(/monto|importe|valor|amount|cantidad/);
  if (iF < 0 || (iM < 0 && iDeb < 0 && iCred < 0)) return { filas, errores: ['No se encontraron las columnas de fecha y monto (o débito y crédito).'] };
  const aFecha = (t) => {
    let m = /^(\d{4})-(\d{2})-(\d{2})/.exec(t);
    if (m) return `${m[1]}-${m[2]}-${m[3]}`;
    m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/.exec(t);
    return m ? `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}` : null;
  };
  const aMonto = (t) => {
    let s = String(t || '').replace(/\s|L|HNL/gi, '');
    if (!s) return 0;
    let neg = false;
    if (/^\(.*\)$/.test(s)) { neg = true; s = s.slice(1, -1); }
    if (s.startsWith('-')) { neg = !neg; s = s.slice(1); }
    if (/,\d{1,2}$/.test(s) && !/\./.test(s)) s = s.replace(',', '.');
    s = s.replace(/,/g, '');
    const c = aCentavos(s);
    return c === null ? null : neg ? -c : c;
  };
  for (const [n, l] of lineas.slice(1).entries()) {
    const x = partir(l);
    const f = aFecha(x[iF] || '');
    let m;
    if (iDeb >= 0 || iCred >= 0) {
      const deb = iDeb >= 0 ? aMonto(x[iDeb]) : 0, cred = iCred >= 0 ? aMonto(x[iCred]) : 0;
      m = deb === null || cred === null ? null : Math.abs(cred) - Math.abs(deb);
    } else m = aMonto(x[iM]);
    if (!f || m === null || m === 0) { errores.push(`línea ${n + 2}`); continue; }
    filas.push({ fecha: f, descripcion: (iD >= 0 && x[iD]) || 'Movimiento del banco', referencia: iR >= 0 ? x[iR] || '' : '', monto_centavos: m });
  }
  return { filas, errores };
}
