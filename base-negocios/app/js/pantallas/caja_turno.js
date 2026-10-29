// Caja · "Mi turno": abrir turno (fondo contado), ver entradas y salidas, y cerrar con
// CONTEO A CIEGAS: primero se cuenta (sin ver cuánto debería haber) y DESPUÉS el servidor
// dice lo esperado y la diferencia. La app solo suma el conteo de billetes para ayudar a contar.
import { rpc, escribir, leer } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { dinero, fechaHora, aCentavos } from '../formato.js';
import { h, aviso, limpiarAvisos, cajaError, errorSimple, campo, dialogo, conBoton, titulo, mensaje, monto, chip, estadoVacio, filaIcono } from '../ui.js';
import { cajas, cuentasDinero, miTurno, olvidarDatos } from '../datos.js';
import * as si from '../sin_internet.js';

// Billetes y monedas de Honduras (centavos).
const DENOMINACIONES = { HNL: [50000, 20000, 10000, 5000, 2000, 1000, 500, 200, 100, 50, 20, 10, 5] };

// Conteo: total escrito o por billetes. valor() -> { contado, conteo } o lanza un mensaje.
export function conteoDinero(prefijo) {
  const moneda = perfilActual().empresa.moneda || 'HNL';
  const dens = DENOMINACIONES[moneda] || [];
  const total = h('input', { id: `${prefijo}-total`, type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: '0.00' });
  const filas = dens.map((d) => {
    const x = h('input', { type: 'number', min: '0', step: '1', inputmode: 'numeric', name: `den-${d}`, placeholder: '0',
      'aria-label': `Cantidad de ${dinero(d)}` });
    return { d, x };
  });
  const suma = h('p', { class: 'suma suma-total', 'aria-live': 'polite' });
  const sumar = () => filas.reduce((s, f) => s + d2(f), 0);
  const d2 = (f) => (Number(f.x.value) > 0 ? Math.round(Number(f.x.value)) * f.d : 0);
  const pintarSuma = () => { suma.replaceChildren(h('span', {}, 'Total contado'), h('span', { class: 'monto', dataset: { dato: 'suma-conteo' } }, dinero(sumar()))); };
  filas.forEach((f) => f.x.addEventListener('input', pintarSuma));
  pintarSuma();
  const grupo = `${prefijo}-modo`;
  const porTotal = h('input', { type: 'radio', name: grupo, value: 'total', checked: true });
  const porBilletes = h('input', { type: 'radio', name: grupo, value: 'billetes' });
  const zonaTotal = campo('Total contado (L)', total);
  const zonaBilletes = h('div', { class: 'billetes', hidden: true },
    h('div', { class: 'billetes-lista' }, filas.map((f) => h('label', { class: 'billete' },
      h('span', { class: 'monto' }, dinero(f.d)), f.x))), suma);
  const alternar = () => { zonaTotal.hidden = !porTotal.checked; zonaBilletes.hidden = porTotal.checked; };
  porTotal.addEventListener('change', alternar);
  porBilletes.addEventListener('change', alternar);
  const nodo = h('div', { class: 'conteo' },
    dens.length ? h('fieldset', { class: 'opciones' }, h('legend', {}, '¿Cómo quiere contar?'),
      h('label', {}, porTotal, ' Escribir el total'), h('label', {}, porBilletes, ' Contar billetes y monedas')) : null,
    zonaTotal, zonaBilletes);
  return {
    nodo,
    enfocar: () => total.focus(),
    valor() {
      if (porBilletes.checked) {
        const conteo = filas.filter((f) => Number(f.x.value) > 0).map((f) => ({ denominacion_centavos: f.d, cantidad: Math.round(Number(f.x.value)) }));
        return { contado: sumar(), conteo };
      }
      const c = aCentavos(total.value);
      if (c === null) throw errorSimple('Escriba el total contado.', 'Solo números, por ejemplo 1500 o 1500.50. Si no hay nada, escriba 0.');
      return { contado: c, conteo: null };
    },
  };
}

// Formulario para abrir turno. alAbrir(turno) al terminar bien.
function formularioAbrir(alAbrir) {
  const selCaja = h('select', { id: 'turno-caja' });
  const conteo = conteoDinero('fondo');
  const selOrigen = h('select', { id: 'turno-origen' }, h('option', { value: '' }, 'No traer ni llevar nada'));
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Abrir turno');
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Caja', selCaja),
    h('p', { class: 'ayuda' }, 'Cuente el dinero que hay en la gaveta antes de empezar (el fondo).'),
    conteo.nodo,
    puede('dinero.trasladar') ? campo('Si el fondo no cuadra con el sistema, traer o llevar la diferencia de', selOrigen,
      'Por ejemplo la caja fuerte. Queda como un traslado aparte.') : null,
    zonaError, boton);
  cajas().then((lista) => {
    selCaja.replaceChildren(...lista.map((c) => h('option', { value: c.id }, `${c.nombre} (${c.punto_emision})`)));
  }).catch(async (err) => zonaError.append(await cajaError(err)));
  if (puede('dinero.trasladar')) {
    cuentasDinero().then((cs) => cs.filter((c) => c.tipo === 'efectivo_caja' && !c.caja_id).forEach((c) =>
      selOrigen.append(h('option', { value: c.cuenta_dinero_id }, c.nombre)))).catch(() => {});
  }
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    let v;
    try { v = conteo.valor(); } catch (m) { zonaError.append(m); return; }
    if (!selCaja.value) { zonaError.append(errorSimple('Elija la caja.')); return; }
    const datos = {};
    if (v.conteo) datos.conteo = v.conteo;
    if (selOrigen.value) datos.cuenta_origen_id = selOrigen.value;
    const r = await conBoton(boton, zonaError, () => escribir('abrir_turno', { p_empresa_id: empresaId(), p_caja_id: selCaja.value,
      p_fondo_centavos: v.contado, p_datos: datos }), 'Abriendo…');
    if (r) { olvidarDatos('cuentas'); limpiarAvisos(); aviso(`Turno #${r.numero} abierto · fondo de ${dinero(r.fondo_inicial_centavos)}`); alAbrir(r); }
  });
  return form;
}

// Diálogo "Abrir turno" (desde Vender). Devuelve true si se abrió.
export function abrirTurnoDialogo() {
  return new Promise((resolve) => {
    let ok = false;
    const { dlg, cerrar } = dialogo('Abrir turno', formularioAbrir(() => { ok = true; cerrar(); }),
      h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => cerrar() }, 'Cancelar'));
    dlg.addEventListener('close', () => resolve(ok));
  });
}

async function movimientosDelTurno(t) {
  // Con dinero.ver: el rastro de la caja (entradas y salidas de ese turno). Si no: sus ventas cobradas en el turno.
  if (puede('dinero.ver')) {
    const ec = await rpc('estado_cuenta_dinero', { p_cuenta_dinero_id: t.cuenta_dinero_id, p_desde: t.fecha_apertura,
      p_hasta: perfilActual().empresa.hoy });
    return (ec.movimientos || []).filter((m) => m.turno_id === t.turno_id).map((m) => ({
      texto: m.descripcion || m.operacion, hora: m.registrado_en, entra: m.entrada_centavos, sale: m.salida_centavos }));
  }
  const pagos = await leer('v_venta_pago', { turno_id: t.turno_id }, { orden: 'linea.asc', limite: 500 });
  return pagos.map((p) => ({ texto: `Venta ${p.numero_documento} (${p.forma})`, hora: null, entra: p.monto_centavos, sale: 0 }));
}

export async function mostrar(vista, ctx) {
  const pintar = async () => {
    vista.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
    let turno;
    try { turno = await miTurno(); } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;
    if (!turno) {
      vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-abrir' },
        titulo('h1', 'candado_abierto', 'Abrir mi caja', { id: 't-abrir' }),
        mensaje('info', 'Su caja está cerrada.', 'Para empezar a cobrar, cuente el dinero de la gaveta y abra su turno.'),
        formularioAbrir(() => pintar())));
      return;
    }
    const filas = await leer('v_turno_caja', { turno_id: turno.turno_id });
    const t = filas[0] || { ...turno };
    const lista = h('div', { class: 'lista' }, h('p', { class: 'cargando' }, 'Cargando movimientos…'));
    vista.replaceChildren(
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-turno' },
        h('div', { class: 'titulo-con-total' }, titulo('h1', 'reloj', `Mi turno · ${turno.caja}`, { id: 't-turno' }), chip('Caja abierta', 'verde')),
        h('div', { class: 'fila' }, h('span', {}, 'Turno'), h('span', {}, `#${turno.numero}`)),
        h('div', { class: 'fila' }, h('span', {}, 'Abierto'), h('span', {}, fechaHora(turno.abierto_en))),
        h('div', { class: 'fila' }, h('span', {}, 'Fondo inicial'), h('span', { class: 'monto' }, dinero(turno.fondo_inicial_centavos))),
        h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-principal', id: 'cerrar-turno',
          onclick: () => cierre(turno) }, 'Cerrar turno'))),
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-mov' },
        titulo('h2', 'movimientos', 'Entradas y salidas del turno', { id: 't-mov' }),
        h('p', { class: 'ayuda' }, 'Para que el conteo sea a ciegas, aquí no se muestra cuánto debería haber.'), lista));
    try {
      const movs = t.cuenta_dinero_id ? await movimientosDelTurno(t) : [];
      // Verde = entra dinero a la caja; rojo = sale.
      lista.replaceChildren(...(movs.length ? movs.map((m) => filaIcono({
        icono: m.sale ? 'baja' : 'sube', color: m.sale ? 'rojo' : 'verde', burbuja: null,
        titulo: m.texto, detalle: m.hora ? fechaHora(m.hora) : null,
        derecha: m.sale ? monto(dinero(m.sale), { sentido: 'sale', signo: '-' }) : monto(dinero(m.entra), { sentido: 'entra', signo: '+' }),
      }))
        : [estadoVacio({ icono: 'billetes', chico: true, texto: 'Todavía no hay movimientos en este turno.' })]));
    } catch (err) { lista.replaceChildren(await cajaError(err)); }
  };

  function cierre(turno) {
    const conteo = conteoDinero('cierre');
    const nota = h('textarea', { id: 'cierre-nota', maxlength: 500 });
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Cerrar turno');
    const form = h('form', { class: 'formulario', novalidate: true },
      h('p', {}, 'Cuente todo el efectivo de la gaveta. Después de cerrar verá cuánto debía haber y si hay diferencia.'),
      conteo.nodo, campo('Nota (opcional)', nota), zonaError,
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => pintar() }, 'Volver'), boton));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      zonaError.replaceChildren();
      let v;
      try { v = conteo.valor(); } catch (m) { zonaError.append(m); return; }
      const datos = {};
      if (v.conteo) datos.conteo = v.conteo;
      if (nota.value.trim()) datos.nota = nota.value.trim();
      const r = await conBoton(boton, zonaError, async () => {
        // App 0.14.0: si este equipo tiene números reservados de esta caja (vender sin internet), primero sube las
        // ventas guardadas y devuelve los números; el servidor no deja cerrar el turno con un bloque activo.
        if ((await si.bloquesLocales(empresaId())).some((b) => b.estado === 'activo' && b.caja_id === turno.caja_id)) await si.devolverBloques(empresaId(), turno.caja_id);
        return escribir('cerrar_turno', { p_turno_id: turno.turno_id, p_contado_centavos: v.contado, p_datos: datos });
      }, 'Cerrando…');
      if (r) {
        olvidarDatos('cuentas'); limpiarAvisos();
        // "Turno cerrado · faltante L 50.00": rojo si falta dinero, verde si cuadra o sobra.
        const d = r.diferencia_centavos;
        aviso(`Turno #${r.numero} cerrado · ${d === 0 ? 'la caja cuadra' : d < 0 ? 'faltante ' + dinero(-d) : 'sobrante ' + dinero(d)}`, d < 0 ? 'error' : 'ok', 8000);
        resultado(r);
      }
    });
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-cierre' },
      titulo('h1', 'candado', `Cerrar turno #${turno.numero}`, { id: 't-cierre' }), form));
    conteo.enfocar();
  }

  function resultado(r) {
    const d = r.diferencia_centavos;
    const texto = d === 0 ? 'La caja cuadra.' : d < 0 ? `Faltan ${dinero(-d)}.` : `Sobran ${dinero(d)}.`;
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-res' },
      h('div', { class: 'titulo-con-total' }, titulo('h1', 'candado', `Turno #${r.numero} cerrado`, { id: 't-res' }),
        chip(d === 0 ? 'Cuadra' : d < 0 ? 'Faltante' : 'Sobrante', d < 0 ? 'rojo' : d === 0 ? 'verde' : 'dorado')),
      h('div', { class: 'fila' }, h('span', {}, 'Usted contó'), monto(dinero(r.contado_centavos), { dato: 'contado' })),
      h('div', { class: 'fila' }, h('span', {}, 'Debía haber'), monto(dinero(r.esperado_centavos), { dato: 'esperado' })),
      h('div', { class: 'fila fila-total' }, h('span', {}, 'Diferencia'),
        monto(dinero(d), { dato: 'diferencia', sentido: d < 0 ? 'sale' : d > 0 ? 'entra' : null })),
      mensaje(d < 0 ? 'error' : d === 0 ? 'ok' : 'info', texto,
        d !== 0 ? 'La diferencia queda pendiente: el administrador o el dueño decide qué hacer con ella.' : null),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => pintar() }, 'Listo'))));
  }

  await pintar();
}
