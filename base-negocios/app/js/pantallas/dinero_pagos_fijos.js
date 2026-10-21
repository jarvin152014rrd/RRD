// Dinero · "Pagos fijos" (app 0.7.0): alquiler, luz, planilla… con su próxima fecha y estado
// (pagos_fijos_proximos: vencido, próximo en 7 días, al día). Crear y editar (crear_pago_fijo /
// editar_pago_fijo, dinero.administrar), desactivar o activar con motivo, y "Pagar ahora"
// (registrar_pago_fijo, gastos.registrar): genera un gasto con el monto REAL y respeta los topes (si pasa
// el tope queda en espera de aprobación).
import { leer, rpc, escribir, nuevoId } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha, aCentavos } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, pedirMotivo, titulo, filaIcono, chipEstado, monto,
  estadoVacio, mensaje } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { cuentasDinero, cuentasQuePagan, categoriasGasto, alcance, olvidarDatos } from '../datos.js';
import { hoy, selectCuentas, inputMonto, inputFecha, dato, cifraChica, cuandoVence, textoMonto } from '../formularios.js';

const DIAS = ['', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
function cada(p) {
  if (p.frecuencia === 'semanal') return `${p.cada > 1 ? `Cada ${p.cada} semanas` : 'Cada semana'}, el ${DIAS[p.dia]}`;
  return `${p.cada > 1 ? `Cada ${p.cada} meses` : 'Cada mes'}, el día ${p.dia}`;
}

export async function mostrar(vista, ctx) {
  const [proximos, todos, cuentas, al] = await Promise.all([rpc('pagos_fijos_proximos', { p_empresa_id: empresaId() }),
    leer('pago_fijo', { empresa_id: empresaId() }, { orden: 'nombre.asc', limite: 500 }), cuentasDinero(true), alcance()]);
  if (!ctx.sigueVigente()) return;
  // Los pagos fijos son de toda la empresa. A un usuario limitado a su sucursal no se le muestran los que se
  // pagan desde una cuenta que no ve (de otra sucursal). Ver PENDIENTES.
  const veo = (p) => !al.limitado || !p.cuenta_dinero_id || cuentas.some((c) => c.cuenta_dinero_id === p.cuenta_dinero_id);
  const activos = proximos.filter(veo);
  const inactivos = todos.filter((p) => !p.activo && veo(p));
  const porId = new Map(todos.map((p) => [p.id, p]));
  const nombreCuenta = (idc) => (cuentas.find((c) => c.cuenta_dinero_id === idc) || {}).nombre;
  const recargar = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  const mensual = activos.reduce((s, p) => s + Number(p.monto_mensual_estimado_centavos || 0), 0);
  const atrasados = activos.filter((p) => p.estado === 'vencido');

  const desactivar = (p, activar) => pedirMotivo({ titulo: `${activar ? 'Activar' : 'Desactivar'} "${p.nombre}"`, peligro: !activar,
    textoBoton: activar ? 'Sí, activar' : 'Sí, desactivar',
    explicacion: activar ? 'Vuelve a salir en la lista y en la proyección.' : 'Deja de salir en la lista y en la proyección. No se borra nada: lo puede activar después.',
    accion: (motivo) => rpc('editar_pago_fijo', { p_empresa_id: empresaId(), p_pago_fijo_id: p.pago_fijo_id || p.id, p_datos: { activo: activar }, p_motivo: motivo }),
  }).then((ok) => { if (ok) { aviso(`"${p.nombre}" ${activar ? 'activado' : 'desactivado'}`); recargar(); } });

  const filas = activos.map((p) => {
    const chipP = p.estado === 'vencido' ? chipEstado('vencido', p.vencidos > 1 ? `Atrasado · ${p.vencidos} sin pagar` : 'Atrasado')
      : p.estado === 'proximo' ? chipEstado('proximo', p.dias === 0 ? 'Vence hoy' : `Vence en ${p.dias} ${p.dias === 1 ? 'día' : 'días'}`) : chipEstado('al_dia');
    return filaIcono({
      icono: 'calendario', color: p.estado === 'vencido' ? 'rojo' : p.estado === 'proximo' ? 'dorado' : 'verde',
      titulo: h('strong', {}, p.nombre),
      detalle: [`${cada(p)}`, p.categoria, p.proximo_vence_el ? `próximo: ${fecha(p.proximo_vence_el)} (${cuandoVence(p.dias)})` : 'sin próximas fechas',
        nombreCuenta(p.cuenta_dinero_id) ? `se paga de ${nombreCuenta(p.cuenta_dinero_id)}` : null].filter(Boolean).join(' · '),
      derecha: [monto(dinero(p.monto_estimado_centavos), { sentido: 'sale' }), chipP],
      abajo: h('div', { class: 'botones' },
        puede('gastos.registrar') && p.proximo_vence_el ? h('button', { type: 'button', class: 'boton boton-principal', 'aria-label': `Pagar ahora ${p.nombre}`,
          onclick: () => formularioPagar(vista, ctx, p) }, icono('billetes'), 'Pagar ahora') : null,
        puede('dinero.administrar') ? h('button', { type: 'button', class: 'boton', 'aria-label': `Editar ${p.nombre}`,
          onclick: () => formularioPagoFijo(vista, ctx, porId.get(p.pago_fijo_id)) }, 'Editar') : null,
        puede('dinero.administrar') ? h('button', { type: 'button', class: 'boton boton-peligro', 'aria-label': `Desactivar ${p.nombre}`,
          onclick: () => desactivar(p, false) }, 'Desactivar') : null),
      props: { dataset: { pagoFijo: p.pago_fijo_id, estado: p.estado } },
    });
  });
  const nuevo = () => formularioPagoFijo(vista, ctx, null);
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-fijos' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'calendario', 'Pagos fijos', { id: 't-fijos' }),
      puede('dinero.administrar') && (activos.length || inactivos.length) ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nuevo-pago-fijo', onclick: nuevo },
        icono('mas'), 'Nuevo pago fijo') : null),
    activos.length ? [
      h('div', { class: 'cifras' }, cifraChica('Al mes, más o menos', dinero(mensual), { dato: 'fijos-mensual', clase: 'monto-sale' }),
        cifraChica('Atrasados', String(atrasados.length), { dato: 'fijos-atrasados', clase: atrasados.length ? 'monto-sale' : '' })),
      h('p', { class: 'ayuda' }, 'El monto es el estimado: al pagar escriba el monto real del recibo. Nunca se descuenta solo.'),
      h('div', { class: 'lista-filas', id: 'lista-fijos' }, filas)]
      : estadoVacio({ icono: 'calendario', titulo: 'Aún no tiene pagos fijos',
        texto: 'Anote lo que paga cada mes o cada semana (alquiler, luz, agua, planilla, internet). Así el sistema le avisa cuándo toca y lo cuenta en la proyección.',
        boton: puede('dinero.administrar') ? { texto: 'Agregar el primero', onclick: nuevo, icono: 'mas', id: 'nuevo-pago-fijo' } : null }),
    inactivos.length ? [h('h2', { class: 'titulo-chico' }, 'Desactivados'), h('div', { class: 'lista-filas', id: 'lista-fijos-inactivos' }, inactivos.map((p) => filaIcono({
      icono: 'calendario', color: 'neutro', titulo: h('strong', {}, p.nombre), detalle: cada(p),
      derecha: [monto(dinero(p.monto_estimado_centavos)), chipEstado('inactivo')],
      abajo: puede('dinero.administrar') ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', 'aria-label': `Activar ${p.nombre}`,
        onclick: () => desactivar(p, true) }, 'Activar')) : null,
      props: { dataset: { pagoFijo: p.id, estado: 'inactivo' } } })))] : null));
}

// "Pagar ahora": el monto real (empieza en el estimado) y de qué caja o banco sale (empieza en la sugerida).
async function formularioPagar(vista, ctx, p) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cuentas;
  try { cuentas = cuentasQuePagan(await cuentasDinero(true)); } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  const id = nuevoId();
  const montoIn = inputMonto('fijo-monto', p.monto_estimado_centavos || null);
  const selCuenta = selectCuentas(cuentas, { id: 'fijo-cuenta' }, { vacio: 'Elija de dónde sale el dinero', elegida: p.cuenta_dinero_id });
  const fechaIn = inputFecha('fijo-fecha', hoy(), { max: hoy() });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'fijo-pagar' }, icono('billetes'), 'Registrar el pago');
  const form = h('form', { class: 'formulario', novalidate: true },
    dato('Pago fijo', p.nombre), dato('Corresponde al vencimiento del', fecha(p.proximo_vence_el)), dato('Monto estimado', dinero(p.monto_estimado_centavos)),
    campo('Monto real que paga (L)', montoIn, 'El que dice el recibo o la factura.'),
    campo('¿De dónde sale el dinero?', selCuenta), campo('Fecha del pago', fechaIn),
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const m = aCentavos(montoIn.value);
    if (!m) { zonaError.append(errorSimple(textoMonto(montoIn, 'Escriba el monto real que paga.'), 'Solo números, por ejemplo 12000 o 2380.50')); montoIn.focus(); return; }
    if (!selCuenta.value) { zonaError.append(errorSimple('Elija de qué caja o banco sale el dinero.')); selCuenta.focus(); return; }
    const cuenta = cuentas.find((c) => c.cuenta_dinero_id === selCuenta.value);
    const ok = await confirmar({ titulo: `¿Pagar "${p.nombre}"?`, textoBoton: 'Sí, pagar',
      texto: `Pago de ${dinero(m)} (${p.nombre}, vencimiento del ${fecha(p.proximo_vence_el)}) · sale de ${cuenta.nombre}.` });
    if (!ok) return;
    const r = await conBoton(boton, zonaError, () => escribir('registrar_pago_fijo', { p_pago_fijo_id: p.pago_fijo_id,
      p_datos: { monto_centavos: m, cuenta_dinero_id: selCuenta.value, fecha: fechaIn.value || hoy(), vence_el: p.proximo_vence_el }, p_id_operacion: id }), 'Pagando…');
    if (!r) return;
    olvidarDatos('cuentas');
    const espera = r.estado === 'pendiente_aprobacion';
    const hecho = espera ? `${p.nombre}: gasto #${r.numero} de ${dinero(r.monto_centavos)} en espera de aprobación · pasa su tope, todavía no sale dinero`
      : `${p.nombre} pagado · ${dinero(r.monto_centavos)} · sale de ${cuenta.nombre}`;
    if (espera) window.dispatchEvent(new Event('pendientes-cambiaron'));
    aviso(hecho, espera ? 'info' : 'ok', 8000);
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-fijook' },
      titulo('h1', 'calendario', p.nombre, { id: 't-fijook' }),
      mensaje(espera ? 'info' : 'ok', hecho, espera ? 'Lo verá en Inicio > Pendientes hasta que lo aprueben.'
        : `Quedó como gasto #${r.numero} del vencimiento del ${fecha(r.vence_el)}. En ${cuenta.nombre} quedan ${dinero(r.saldo_cuenta_centavos)}.`,
      { class: 'resultado', dataset: { info: espera ? 'fijo-en-espera' : 'fijo-pagado' } }),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: volver }, 'Volver a pagos fijos'))));
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-pagar-fijo' },
    titulo('h1', 'billetes', `Pagar ${p.nombre}`, { id: 't-pagar-fijo' }), form));
  montoIn.focus();
}

// Crear (p = null) o editar un pago fijo (editar pide motivo: queda en la bitácora).
async function formularioPagoFijo(vista, ctx, p) {
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cats, cuentas;
  try { [cats, cuentas] = await Promise.all([categoriasGasto(true), cuentasDinero(true).then(cuentasQuePagan)]); } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  if (!cats.length) {
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta' }, titulo('h1', 'calendario', 'Nuevo pago fijo'),
      estadoVacio({ icono: 'recibo', titulo: 'Primero cree sus categorías de gasto', texto: 'Cada pago fijo va a una categoría (alquiler, luz, planilla).',
        botones: [hayEnMenu(ctx.menu || [], 'ajustes', 'cajas') ? { texto: 'Ir a Ajustes', href: '#/ajustes/cajas', icono: 'ajustes' } : null, { texto: 'Volver', onclick: volver }] })));
    return;
  }
  const nombre = h('input', { id: 'fijo-nombre', type: 'text', maxlength: 100, value: p ? p.nombre : '', placeholder: 'Ej.: Alquiler del local' });
  const selCat = h('select', { id: 'fijo-categoria' }, h('option', { value: '' }, 'Elija la categoría'), cats.map((c) => h('option', { value: c.id }, c.nombre)));
  if (p) selCat.value = p.categoria_id;
  const montoIn = inputMonto('fijo-estimado', p ? p.monto_estimado_centavos : null);
  const selFrec = h('select', { id: 'fijo-frecuencia' }, h('option', { value: 'mensual' }, 'Cada mes'), h('option', { value: 'semanal' }, 'Cada semana'));
  if (p) selFrec.value = p.frecuencia;
  const cadaIn = h('input', { id: 'fijo-cada', type: 'number', min: '1', max: '52', step: '1', inputmode: 'numeric', value: p ? String(p.cada) : '1' });
  const diaMes = h('input', { id: 'fijo-dia', type: 'number', min: '1', max: '31', step: '1', inputmode: 'numeric', value: p && p.frecuencia === 'mensual' ? String(p.dia) : '1' });
  const diaSem = h('select', { id: 'fijo-dia-semana' }, DIAS.slice(1).map((d, i) => h('option', { value: String(i + 1) }, d[0].toUpperCase() + d.slice(1))));
  if (p && p.frecuencia === 'semanal') diaSem.value = String(p.dia);
  const inicio = inputFecha('fijo-inicio', p ? p.fecha_inicio : hoy());
  const selCuenta = selectCuentas(cuentas, { id: 'fijo-cuenta-sugerida' }, { vacio: 'Sin cuenta sugerida', elegida: p ? p.cuenta_dinero_id : null, saldo: false });
  const motivo = h('input', { id: 'fijo-motivo', type: 'text', maxlength: 300 });
  const zonaDia = h('div', {});
  const lblCada = campo('Cada cuántos meses', cadaIn);
  const pintarFrec = () => {
    const mensual = selFrec.value === 'mensual';
    lblCada.querySelector('label').textContent = mensual ? 'Cada cuántos meses' : 'Cada cuántas semanas';
    cadaIn.max = mensual ? '12' : '52';
    zonaDia.replaceChildren(mensual ? campo('Día del mes', diaMes, 'Si el mes es más corto, toca el último día.') : campo('Día de la semana', diaSem));
  };
  selFrec.addEventListener('change', pintarFrec);
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'fijo-guardar' }, p ? 'Guardar cambios' : 'Crear pago fijo');
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Nombre', nombre), campo('Categoría de gasto', selCat), campo('Monto aproximado (L)', montoIn, 'Sirve para avisarle y para la proyección. Al pagar escribe el real.'),
    h('div', { class: 'dos-columnas' }, campo('¿Cada cuánto?', selFrec), lblCada), zonaDia, campo('Desde', inicio),
    campo('¿De dónde se paga normalmente? (opcional)', selCuenta),
    p ? campo('Motivo del cambio', motivo, 'Queda en la bitácora (mínimo 5 letras).') : null,
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const falla = (t, q = '', foco = null) => { zonaError.append(errorSimple(t, q)); if (foco) foco.focus(); };
    if (nombre.value.trim().length < 3) return falla('Escriba el nombre del pago fijo.', 'Ej.: Alquiler del local', nombre);
    if (!selCat.value) return falla('Elija la categoría de gasto.', '', selCat);
    const m = montoIn.value.trim() === '' ? 0 : aCentavos(montoIn.value);
    if (m === null) return falla(textoMonto(montoIn, 'El monto no es válido.'), 'Solo números, por ejemplo 12000', montoIn);
    const mensual = selFrec.value === 'mensual';
    const c = Number(cadaIn.value);
    if (!Number.isInteger(c) || c < 1 || c > (mensual ? 12 : 52)) return falla(mensual ? 'Cada cuántos meses: de 1 a 12.' : 'Cada cuántas semanas: de 1 a 52.', '', cadaIn);
    const dia = mensual ? Number(diaMes.value) : Number(diaSem.value);
    if (mensual && (!Number.isInteger(dia) || dia < 1 || dia > 31)) return falla('El día del mes va de 1 a 31.', '', diaMes);
    if (!inicio.value) return falla('Escriba desde cuándo cuenta.', '', inicio);
    if (p && motivo.value.trim().length < 5) return falla('Escriba el motivo del cambio (mínimo 5 letras).', '', motivo);
    const datos = { nombre: nombre.value.trim(), categoria_id: selCat.value, monto_estimado_centavos: m, frecuencia: selFrec.value,
      cada: c, dia, fecha_inicio: inicio.value, cuenta_dinero_id: selCuenta.value || null };
    const r = await conBoton(boton, zonaError, () => (p
      ? rpc('editar_pago_fijo', { p_empresa_id: empresaId(), p_pago_fijo_id: p.id, p_datos: datos, p_motivo: motivo.value.trim() })
      : rpc('crear_pago_fijo', { p_empresa_id: empresaId(), p_datos: datos })));
    if (!r) return;
    aviso(`${p ? 'Pago fijo guardado' : 'Pago fijo creado'} · ${datos.nombre} · unos ${dinero(r.monto_mensual_estimado_centavos)} al mes`, 'ok', 7000);
    volver();
  });
  pintarFrec();
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-ffijo' },
    titulo('h1', p ? 'editar' : 'calendario', p ? `Editar ${p.nombre}` : 'Nuevo pago fijo', { id: 't-ffijo' }), form));
  nombre.focus();
}
