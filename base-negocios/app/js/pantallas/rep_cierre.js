// Reportes · "Cierre de mes" (app 0.8.0). Lo único de Reportes que cambia algo: cerrar y reabrir un mes.
//   Lista de meses con su estado: periodo (abierto / cerrado), historial_cierres (la foto vigente y las
//   superadas) y v_distribucion (reparto de utilidad, módulo fondos).
//   Pre-cierre de un mes abierto: exportar_mes (núcleo 040) da las ADVERTENCIAS de ese mes (lo mismo que
//   revisa cerrar_mes), si los libros cuadran y el resumen; la app agrega el mes anterior y los bancos
//   sin cuadrar (v_conciliacion). Lo que falta lleva un botón a la pantalla donde se arregla.
//   Cerrar: cerrar_mes(empresa, año, mes) (periodos.cerrar). Reabrir: reabrir_periodo(empresa, año, mes,
//   motivo) (periodos.reabrir, solo el dueño, del último cerrado hacia atrás; NUNCA con reparto vigente).
//   Estas dos funciones del núcleo NO reciben id_operacion: el reintento es seguro por sí solo (un mes ya
//   cerrado devuelve su misma foto, "ya_estaba"; uno ya abierto, igual). La app arma la operación UNA vez
//   (mismos datos) y la repite una sola vez si se corta el internet.
//   Libros de ISV del mes: libros_isv (núcleo 044), en pantalla y en Excel.
//   Es de TODA la empresa: a un usuario limitado a su sucursal no se le muestra (ver PENDIENTES).
import { leer, rpc } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha, fechaHora } from '../formato.js';
import { h, icono, aviso, cajaError, titulo, chip, monto, estadoVacio, mensaje, tabla, filaIcono, confirmar, pedirMotivo } from '../ui.js';
import { alcance, cuentasDinero, reiniciarAlSalir } from '../datos.js';
import { hoy, cifraChica } from '../formularios.js';
import { hayEnMenu } from '../menu.js';
import { mesesDeLaEmpresa, nombreMes, rangoMes, mesAnterior, MESES, botonesReporte } from '../reportes.js';

let elegido = null; // 'AAAA-MM'
reiniciarAlSalir(() => { elegido = null; });
const dos = (n) => String(n).padStart(2, '0');
const clave = (a, m) => `${a}-${dos(m)}`;
const mayus = (t) => t[0].toUpperCase() + t.slice(1);

// Llama una función que cambia algo y, si se corta el internet, la repite UNA vez con los mismos datos
// (cerrar_mes y reabrir_periodo reconocen el reintento: "ya_estaba").
export async function conReintento(funcion, args, espera = 1500) {
  const operacion = Object.freeze({ funcion, args: Object.freeze({ ...args }) });
  try {
    return await rpc(operacion.funcion, operacion.args);
  } catch (e) {
    if (!e.sinConexion) throw e;
    await new Promise((ok) => setTimeout(ok, espera));
    return rpc(operacion.funcion, operacion.args);
  }
}

// Estado de cada mes: { anio, mes, cerrado, terminado, estado: 'cerrado'|'revision'|'abierto', cierre, superadas, reparto }
export function estadosMeses(meses, periodos, historial, repartos, hoyIso) {
  return meses.map((m) => {
    const p = periodos.find((x) => Number(x.anio) === m.anio && Number(x.mes) === m.mes);
    const cerrado = Boolean(p && p.estado === 'cerrado');
    const terminado = rangoMes(m.anio, m.mes).hasta < hoyIso;
    const deEste = historial.filter((c) => Number(c.anio) === m.anio && Number(c.mes) === m.mes);
    return { ...m, cerrado, terminado, estado: cerrado ? 'cerrado' : terminado ? 'revision' : 'abierto',
      cierre: deEste.find((c) => c.estado === 'vigente') || null, superadas: deEste.filter((c) => c.estado === 'superada'),
      reparto: repartos.find((r) => Number(r.anio) === m.anio && Number(r.mes) === m.mes && !r.anulada) || null };
  });
}
const CHIP_ESTADO = { cerrado: ['Cerrado', 'verde'], revision: ['En revisión', 'dorado'], abierto: ['Abierto', 'azul'] };

export async function mostrar(vista, ctx) {
  const al = await alcance();
  if (!ctx.sigueVigente()) return;
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-cierre' }, titulo('h1', 'cierre', 'Cierre de mes', { id: 't-cierre' }));
  vista.append(tarjeta);
  if (al.limitado) {
    tarjeta.append(estadoVacio({ icono: 'cierre', titulo: 'El cierre es de toda la empresa',
      texto: 'Usted trabaja solo con sus sucursales, por eso no lo ve. El dueño cierra el mes.' }));
    return;
  }
  const conFondos = tieneModulo('fondos') && puede('fondos.ver');
  const zonaLista = h('div', { class: 'lista', id: 'cierre-meses' });
  const zonaDetalle = h('div', { class: 'lista', id: 'cierre-detalle' });
  tarjeta.append(h('p', { class: 'ayuda' }, 'Al cerrar un mes sus números quedan firmes: nadie puede registrar, cambiar ni anular nada con fecha de ese mes. Elija un mes para revisarlo.'),
    zonaLista);
  vista.append(zonaDetalle);
  let meses = [];

  async function cargarLista() {
    zonaLista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    let periodos, historial, repartos;
    try {
      [periodos, historial, repartos] = await Promise.all([leer('periodo', { empresa_id: empresaId() }, { limite: 1000 }),
        rpc('historial_cierres', { p_empresa_id: empresaId() }), conFondos ? leer('v_distribucion', { empresa_id: empresaId() }, { limite: 1000 }) : []]);
    } catch (err) { zonaLista.replaceChildren(await cajaError(err)); return false; }
    if (!ctx.sigueVigente()) return false;
    meses = estadosMeses(mesesDeLaEmpresa(), periodos, historial || [], repartos || [], hoy());
    if (!elegido || !meses.some((m) => m.valor === elegido)) {
      // El más viejo que falta cerrar; si no, el último cerrado; si no, el de hoy.
      const revisar = [...meses].reverse().find((m) => m.estado === 'revision');
      elegido = (revisar || meses.find((m) => m.cerrado) || meses[0]).valor;
    }
    zonaLista.replaceChildren(h('div', { class: 'lista-filas' }, meses.map((m) => {
      const [t, c] = CHIP_ESTADO[m.estado];
      return filaIcono({ icono: m.cerrado ? 'candado' : 'candado_abierto', color: c,
        titulo: h('strong', {}, mayus(m.texto)),
        detalle: m.cerrado ? (m.cierre ? `Cerrado el ${fechaHora(m.cierre.cerrado_en)} por ${m.cierre.cerrado_por || 'alguien'}${m.cierre.version > 1 ? ` · versión ${m.cierre.version}` : ''}` : 'Cerrado sin foto del cierre')
          : m.terminado ? 'Ya terminó: toca revisarlo y cerrarlo' : 'Es el mes en curso',
        derecha: [chip(t, c, { dataset: { estado: m.estado } }), m.cerrado && conFondos ? [' ', m.reparto ? chip('Con reparto', 'azul', { dataset: { reparto: 'si' } }) : chip('Sin reparto', 'neutro', { dataset: { reparto: 'no' } })] : null],
        abajo: h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton' + (m.valor === elegido ? ' boton-principal' : ''), 'aria-label': `Ver ${m.texto}`,
          'aria-pressed': m.valor === elegido ? 'true' : 'false', onclick: () => { elegido = m.valor; pintarLista(); verMes(); } }, icono('flecha'), m.valor === elegido ? 'Viendo' : 'Ver')),
        props: { dataset: { mes: m.valor, estado: m.estado } } });
    })));
    return true;
  }
  function pintarLista() {
    for (const f of zonaLista.querySelectorAll('[data-mes]')) {
      const b = f.querySelector('button');
      const si = f.dataset.mes === elegido;
      b.className = 'boton' + (si ? ' boton-principal' : '');
      b.setAttribute('aria-pressed', si ? 'true' : 'false');
      b.lastChild.textContent = si ? 'Viendo' : 'Ver';
    }
  }

  async function verMes() {
    const m = meses.find((x) => x.valor === elegido);
    if (!m) return;
    zonaDetalle.replaceChildren(h('section', { class: 'tarjeta' }, h('p', { class: 'cargando', role: 'status' }, 'Cargando…')));
    const sec = await (m.cerrado ? detalleCerrado(m) : detalleAbierto(m)).catch(async (err) => h('section', { class: 'tarjeta' }, await cajaError(err)));
    if (!ctx.sigueVigente() || elegido !== m.valor) return;
    zonaDetalle.replaceChildren(sec, libros(m));
  }

  // ---------------- Mes cerrado ----------------
  async function detalleCerrado(m) {
    const c = m.cierre;
    const r = (c && c.resumen) || {};
    const posterior = meses.find((x) => x.cerrado && (x.anio > m.anio || (x.anio === m.anio && x.mes > m.mes)));
    let reabrir;
    if (!puede('periodos.reabrir')) reabrir = h('p', { class: 'ayuda' }, 'Solo el dueño puede reabrir un mes cerrado.');
    else if (m.reparto) {
      reabrir = mensaje('info', 'Este mes no se puede reabrir: ya se repartió su utilidad.',
        `Tiene el reparto #${m.reparto.numero} por ${dinero(m.reparto.base_centavos)} hecho a fondos y socios. Para reabrirlo primero hay que anular ese reparto (hoy lo hace el proveedor del programa); así nadie reparte una utilidad que después cambia.`,
        { dataset: { info: 'reabrir-con-reparto' } });
    } else if (posterior) {
      reabrir = mensaje('info', `Para reabrir ${m.texto}, primero reabra ${posterior.texto}.`, 'Los meses se reabren del último cerrado hacia atrás.', { dataset: { info: 'reabrir-en-orden' } });
    } else {
      reabrir = h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-peligro', id: 'cierre-reabrir', onclick: () => reabrirMes(m) }, icono('candado_abierto'), 'Reabrir el mes'));
    }
    const repartir = tieneModulo('fondos') && !m.reparto && Number(r.utilidad_cobrada_centavos) > 0
      ? (puede('fondos.distribuir') && hayEnMenu(ctx.menu, 'dinero', 'fondos')
        ? h('div', { class: 'botones' }, h('a', { class: 'boton boton-principal', href: '#/dinero/fondos', id: 'cierre-repartir' }, icono('capas'), 'Repartir la utilidad (Fondos y socios)'))
        : h('p', { class: 'ayuda' }, 'El dueño reparte la utilidad cobrada en Dinero > Fondos y socios.'))
      : null;
    return h('section', { class: 'tarjeta', 'aria-labelledby': 't-mes', dataset: { mes: m.valor, estado: 'cerrado' } },
      titulo('h2', 'candado', mayus(m.texto), { id: 't-mes' }),
      h('p', {}, chip('Cerrado', 'verde'), ' ', c ? `el ${fechaHora(c.cerrado_en)} por ${c.cerrado_por || 'alguien'}${c.version > 1 ? ` (versión ${c.version})` : ''}.` : 'sin foto del cierre.'),
      c ? h('div', { class: 'cifras' },
        cifraChica('Vendí', dinero(r.ventas_netas_centavos), { dato: 'resumen-ventas' }),
        cifraChica(Number(r.utilidad_neta_centavos) >= 0 ? 'Gané' : 'Perdí', dinero(r.utilidad_neta_centavos), { dato: 'resumen-neta', clase: Number(r.utilidad_neta_centavos) >= 0 ? 'monto-entra' : 'monto-sale' }),
        cifraChica('Ganancia cobrada', dinero(r.utilidad_cobrada_centavos), { dato: 'resumen-cobrada' }),
        cifraChica('Dinero al final del mes', dinero(r.dinero_final_centavos), { dato: 'resumen-dinero' }),
        cifraChica(Number(r.isv_a_pagar_centavos) >= 0 ? 'ISV a pagar' : 'ISV a favor', dinero(Math.abs(Number(r.isv_a_pagar_centavos) || 0)), { dato: 'resumen-isv' }))
        : mensaje('info', 'Este mes se cerró sin guardar su foto (antes de la versión 0.10.0, o solo porque no tenía movimientos).',
          puede('periodos.cerrar') ? 'Puede guardarla ahora: no cambia ningún número.' : null),
      !c && puede('periodos.cerrar') ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', id: 'cierre-foto', onclick: () => cerrarMes(m, true) }, icono('documento'), 'Guardar la foto del cierre')) : null,
      c && (c.advertencias || []).length ? [h('h3', { class: 'titulo-chico' }, 'Avisos que había al cerrar'),
        h('ul', { class: 'lista-avisos' }, c.advertencias.map((a) => h('li', {}, a.mensaje)))] : null,
      c && c.motivo ? h('p', { class: 'ayuda' }, `Nota del cierre: ${c.motivo}`) : null,
      tieneModulo('fondos') ? [h('h3', { class: 'titulo-chico' }, 'Reparto de la utilidad'),
        m.reparto ? h('p', { dataset: { info: 'reparto' } }, `Repartido: ${dinero(m.reparto.base_centavos)} de ganancia cobrada (reparto #${m.reparto.numero}, el ${fecha(m.reparto.fecha_contable)}).`)
          : !conFondos ? h('p', { class: 'ayuda' }, 'El reparto se ve en Dinero > Fondos y socios.')
            : Number(r.utilidad_cobrada_centavos) > 0 ? h('p', { dataset: { info: 'reparto' } }, `Falta repartir ${dinero(r.utilidad_cobrada_centavos)} de ganancia cobrada.`)
              : h('p', { class: 'ayuda' }, 'No hay ganancia cobrada para repartir en este mes.'), repartir] : null,
      h('h3', { class: 'titulo-chico' }, 'Reabrir'),
      reabrir,
      m.superadas.length ? [h('h3', { class: 'titulo-chico' }, 'Veces que se reabrió'),
        h('ul', { class: 'lista-avisos' }, m.superadas.map((s) => h('li', {}, `Versión ${s.version}: reabierto el ${fechaHora(s.superada_en)} por ${s.superada_por || 'alguien'}${s.motivo_superada ? ` · motivo: ${s.motivo_superada}` : ''}`)))] : null,
      botonesReporte('cierre', () => documentoMes(m)));
  }

  // ---------------- Mes abierto: pre-cierre ----------------
  async function detalleAbierto(m) {
    const ant = mesAnterior(m.anio, m.mes);
    const mAnt = meses.find((x) => x.anio === ant.anio && x.mes === ant.mes);
    // Como cerrar_periodo (núcleo 004): el mes abierto MÁS VIEJO antes de este que tenga asientos impide cerrar
    // (los meses vacíos se cierran solos). Se revisa cada mes abierto anterior (meses viene del más nuevo al más viejo).
    const abiertosAntes = meses.filter((x) => !x.cerrado && (x.anio < m.anio || (x.anio === m.anio && x.mes < m.mes))).reverse();
    const conBanco = tieneModulo('conciliacion') && puede('conciliacion.ver') && puede('dinero.ver');
    const [x, movAnt, concs, cuentas] = await Promise.all([
      rpc('exportar_mes', { p_empresa_id: empresaId(), p_anio: m.anio, p_mes: m.mes }),
      Promise.all(abiertosAntes.map((x) => leer('v_asiento', { empresa_id: empresaId(), fecha_contable: { gte: rangoMes(x.anio, x.mes).desde, lte: rangoMes(x.anio, x.mes).hasta } }, { limite: 1 })
        .then((l) => (l.length ? x : null)))).then((l) => l.find(Boolean) || null),
      conBanco ? leer('v_conciliacion', { empresa_id: empresaId(), anio: m.anio, mes: m.mes }) : [],
      conBanco ? cuentasDinero(true) : [],
    ]);
    const s = x.secciones || {};
    const er = s.estado_resultados || {}, bg = s.balance_general || {};
    const adv = x.advertencias || [];
    const de = (tipo, filtro = () => true) => adv.filter((a) => a.tipo === tipo && filtro(a));
    const ir = (pid, sid, texto) => (hayEnMenu(ctx.menu, pid, sid) ? { href: `#/${pid}/${sid}`, texto } : null);
    const arqueo = (a) => /arqueo/i.test(a.mensaje || '');
    const bancos = cuentas.filter((c) => c.tipo === 'banco' && c.activa !== false);
    const bancosSinCuadrar = bancos.filter((b) => !concs.some((c) => c.cuenta_dinero_id === b.cuenta_dinero_id && c.estado === 'cerrada'));
    const sig = m.mes === 12 ? { anio: m.anio + 1, mes: 1 } : { anio: m.anio, mes: m.mes + 1 };
    const items = [
      { clave: 'terminado', bloquea: true, listo: m.terminado, texto: 'El mes ya terminó',
        falta: `El mes todavía no termina: se puede cerrar desde el 1 de ${MESES[sig.mes - 1]}.` },
      ...(mAnt ? [{ clave: 'anterior', bloquea: true, listo: !movAnt, texto: 'Los meses anteriores están cerrados',
        falta: movAnt ? `Falta: cerrar ${movAnt.texto} primero (tiene movimientos y sigue abierto).` : '',
        accion: movAnt ? { texto: `Ir a ${movAnt.texto}`, onclick: () => { elegido = movAnt.valor; pintarLista(); verMes(); } } : null }] : []),
      { clave: 'cuadra', bloquea: true, listo: bg.cuadra !== false, texto: 'Los libros cuadran (lo que se debe y lo que se tiene)',
        falta: `Los libros no cuadran por ${dinero(bg.diferencia_centavos)}. Avise a su proveedor del programa.` },
      { clave: 'turnos', listo: !de('turnos_abiertos').length, texto: 'Las cajas están cerradas', falta: de('turnos_abiertos').map((a) => a.mensaje).join(' '),
        enlace: ir('caja', 'turno', 'Ir a Caja') },
      { clave: 'arqueo', listo: !de('alerta_cuadre', arqueo).length, texto: 'Las diferencias de caja están decididas', falta: de('alerta_cuadre', arqueo).map((a) => a.mensaje).join(' '),
        enlace: ir('inicio', 'pendientes', 'Ir a Pendientes') },
      { clave: 'depositos', listo: !de('depositos_en_transito').length, texto: 'Los depósitos al banco están confirmados', falta: de('depositos_en_transito').map((a) => a.mensaje).join(' '),
        enlace: ir('dinero', 'depositos', 'Confirmar depósitos') },
      { clave: 'transferencias', listo: !de('transferencias_por_confirmar').length, texto: 'Las transferencias de clientes están confirmadas',
        falta: de('transferencias_por_confirmar').map((a) => a.mensaje).join(' '), enlace: ir('dinero', 'donde', 'Ver dónde está mi dinero') },
      { clave: 'aprobaciones', listo: !de('aprobaciones_pendientes').length, texto: 'No hay solicitudes pendientes (gastos, conteos, anulaciones…)',
        falta: de('aprobaciones_pendientes').map((a) => a.mensaje).join(' '), enlace: ir('inicio', 'pendientes', 'Ir a Pendientes') },
      { clave: 'negativo', listo: !de('cuentas_en_negativo').length, texto: 'Ninguna cuenta de dinero queda en negativo', falta: de('cuentas_en_negativo').map((a) => a.mensaje).join(' '),
        enlace: ir('dinero', 'donde', 'Ver las cuentas') },
      { clave: 'modulos', listo: !de('alerta_cuadre', (a) => !arqueo(a)).length, texto: 'Inventario, clientes, proveedores y dinero cuadran con los libros',
        falta: de('alerta_cuadre', (a) => !arqueo(a)).map((a) => a.mensaje).join(' ') },
      ...(conBanco && bancos.length ? [{ clave: 'banco', listo: !bancosSinCuadrar.length, texto: 'Los bancos están cuadrados con su estado de cuenta',
        falta: `Falta cuadrar: ${bancosSinCuadrar.map((b) => b.nombre).join(', ')}. Recomendado, no obligatorio.`, enlace: ir('dinero', 'banco', 'Cuadrar con el banco') }] : []),
      ...(de('reparto_version_anterior').length ? [{ clave: 'reparto', listo: false, texto: 'Reparto de utilidad al día', falta: de('reparto_version_anterior').map((a) => a.mensaje).join(' '),
        enlace: ir('dinero', 'fondos', 'Ir a Fondos y socios') }] : []),
    ];
    const bloqueos = items.filter((i) => i.bloquea && !i.listo);
    const faltan = items.filter((i) => !i.listo);
    const lista = h('ul', { class: 'lista-comprobacion', id: 'cierre-revision' }, items.map((i) => h('li', { class: i.listo ? 'comprobacion-lista' : 'comprobacion-falta', dataset: { revision: i.clave, listo: String(i.listo) } },
      h('span', { class: `burbuja burbuja-chica burbuja-${i.listo ? 'verde' : i.bloquea ? 'rojo' : 'dorado'}` }, icono(i.listo ? 'check' : 'alerta')),
      h('div', { class: 'comprobacion-texto' },
        h('p', {}, h('strong', {}, i.texto), ' ', i.listo ? chip('Listo', 'verde') : chip(i.bloquea ? 'Falta (impide cerrar)' : 'Falta', i.bloquea ? 'rojo' : 'dorado')),
        !i.listo && i.falta ? h('p', { class: 'ayuda' }, i.falta) : null,
        !i.listo && i.enlace ? h('a', { class: 'boton', href: i.enlace.href, dataset: { arreglar: i.clave } }, icono('flecha'), i.enlace.texto) : null,
        !i.listo && i.accion ? h('button', { type: 'button', class: 'boton', onclick: i.accion.onclick, dataset: { arreglar: i.clave } }, icono('flecha'), i.accion.texto) : null))));
    const neta = Number(er.utilidad_neta_centavos) || 0;
    const botonCerrar = puede('periodos.cerrar') ? h('button', { type: 'button', class: 'boton boton-principal boton-grande', id: 'cierre-cerrar',
      disabled: bloqueos.length > 0, onclick: () => cerrarMes(m, false, faltan) }, icono('candado'), `Cerrar ${m.texto}`) : null;
    return h('section', { class: 'tarjeta', 'aria-labelledby': 't-mes', dataset: { mes: m.valor, estado: m.estado } },
      titulo('h2', 'candado_abierto', mayus(m.texto), { id: 't-mes' }),
      h('p', {}, chip(...CHIP_ESTADO[m.estado]), ' ', m.terminado ? 'Ya terminó y sigue abierto: revíselo y ciérrelo.' : 'Es el mes en curso: esta revisión es una vista previa.'),
      h('h3', { class: 'titulo-chico' }, 'Revisión antes de cerrar'),
      h('p', { class: 'ayuda' }, faltan.length ? `${items.length - faltan.length} de ${items.length} listos. Lo que dice "Falta" en dorado no impide cerrar, pero conviene arreglarlo antes: después los números del mes quedan firmes.`
        : 'Todo listo para cerrar.'),
      lista,
      h('h3', { class: 'titulo-chico' }, 'Resumen del mes (preliminar)'),
      h('div', { class: 'cifras' },
        cifraChica('Vendí', dinero(er.ventas_netas_centavos), { dato: 'resumen-ventas' }),
        cifraChica(neta >= 0 ? 'Gané' : 'Perdí', dinero(neta), { dato: 'resumen-neta', clase: neta >= 0 ? 'monto-entra' : 'monto-sale' }),
        cifraChica('Ganancia cobrada', dinero(er.utilidad_cobrada_centavos), { dato: 'resumen-cobrada' }),
        cifraChica('Dinero al final del mes', dinero((s.flujo_efectivo || {}).saldo_final_centavos), { dato: 'resumen-dinero' }),
        cifraChica(Number((s.isv || {}).a_pagar_centavos) >= 0 ? 'ISV a pagar' : 'ISV a favor', dinero(Math.abs(Number((s.isv || {}).a_pagar_centavos) || 0)), { dato: 'resumen-isv' })),
      botonCerrar ? h('div', { class: 'botones' }, botonCerrar) : h('p', { class: 'ayuda' }, 'El dueño o el administrador cierran el mes.'),
      bloqueos.length && botonCerrar ? h('p', { class: 'ayuda texto-rojo', dataset: { info: 'no-se-puede-cerrar' } }, `Todavía no se puede cerrar: ${bloqueos.map((b) => b.falta).join(' ')}`) : null,
      botonesReporte('cierre', () => documentoMes(m, x)));
  }

  // Cerrar (o guardar la foto de un mes ya cerrado): confirmación clara y cerrar_mes.
  async function cerrarMes(m, soloFoto, faltan = []) {
    const ok = await confirmar({ titulo: soloFoto ? `¿Guardar la foto de ${m.texto}?` : `¿Cerrar ${m.texto}?`, textoBoton: soloFoto ? 'Sí, guardar la foto' : 'Sí, cerrar el mes',
      texto: soloFoto ? 'Se guardan los estados del mes tal como están. No cambia ningún número.'
        : `Después de cerrar, los números de ${m.texto} quedan firmes: nadie podrá registrar, cambiar ni anular nada con fecha de ese mes. Si luego encuentra un error, se corrige con un movimiento en contra (una contrapartida) en un mes abierto. Solo el dueño puede reabrirlo, con motivo.${faltan.length ? ` Ojo: quedan ${faltan.length} cosa(s) por revisar.` : ''}` });
    if (!ok) return;
    const boton = document.getElementById(soloFoto ? 'cierre-foto' : 'cierre-cerrar');
    if (boton) { boton.disabled = true; boton.lastChild.textContent = 'Cerrando…'; }
    let r;
    try {
      r = await conReintento('cerrar_mes', { p_empresa_id: empresaId(), p_anio: m.anio, p_mes: m.mes });
    } catch (err) {
      if (boton) { boton.disabled = false; boton.lastChild.textContent = `Cerrar ${m.texto}`; }
      const sec = zonaDetalle.querySelector('section');
      if (sec) sec.prepend(await cajaError(err));
      return;
    }
    aviso(r.ya_estaba ? `${mayus(m.texto)} ya estaba cerrado.` : `${mayus(m.texto)} quedó cerrado (versión ${r.version}).`, 'ok', 6000);
    await cargarLista();
    await verMes();
    const sec = zonaDetalle.querySelector('section');
    if (sec) {
      sec.prepend(mensaje('ok', `${mayus(m.texto)} quedó cerrado. Sus números ya están firmes.`,
        [(r.advertencias || []).length ? `Avisos al cerrar: ${r.advertencias.map((a) => a.mensaje).join(' ')}` : null,
          Number(r.meses_vacios_cerrados) ? `También se cerraron ${r.meses_vacios_cerrados} mes(es) anteriores sin movimientos.` : null,
          tieneModulo('fondos') && Number((r.resumen || {}).utilidad_cobrada_centavos) > 0 ? 'Ya puede repartir la utilidad cobrada en Dinero > Fondos y socios.' : null].filter(Boolean).join(' ') || null,
        { dataset: { info: 'cerrado' } }));
    }
  }

  async function reabrirMes(m) {
    const ok = await pedirMotivo({ titulo: `Reabrir ${m.texto}`, textoBoton: 'Sí, reabrir', peligro: true,
      explicacion: `Al reabrir, ${m.texto} vuelve a aceptar movimientos y su foto actual queda guardada como versión anterior. Escriba por qué lo reabre.`,
      accion: (motivo) => conReintento('reabrir_periodo', { p_empresa_id: empresaId(), p_anio: m.anio, p_mes: m.mes, p_motivo: motivo }) });
    if (!ok) return;
    aviso(`${mayus(m.texto)} quedó abierto otra vez.`, 'ok', 6000);
    await cargarLista();
    await verMes();
  }

  // ---------------- Libros de ISV del mes ----------------
  function libros(m) {
    const zona = h('div', { class: 'lista' });
    const sec = h('section', { class: 'tarjeta', 'aria-labelledby': 't-libros' }, titulo('h2', 'impuestos', `Libros de ISV de ${m.texto}`, { id: 't-libros' }),
      h('p', { class: 'ayuda' }, 'Libro de ventas y libro de compras del mes (facturas, notas de crédito y anulaciones). Un contador debe validar el formato antes de presentarlo a la SAR.'),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', id: 'cierre-ver-libros', onclick: async (ev) => {
        ev.currentTarget.disabled = true;
        zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
        try { zona.replaceChildren(...pintarLibros(m, await rpc('libros_isv', { p_empresa_id: empresaId(), p_anio: m.anio, p_mes: m.mes }))); } catch (err) { zona.replaceChildren(await cajaError(err)); }
      } }, icono('impuestos'), 'Ver libros de ISV')), zona);
    return sec;
  }
  function pintarLibros(m, li) {
    const lv = li.libro_ventas || {}, lc = li.libro_compras || {};
    const tv = lv.totales || {}, tc = lc.totales || {};
    const aPagar = Number(li.isv_a_pagar_centavos) || 0;
    const corta = (lib, quien) => tabla({ props: { id: `libro-${quien}` }, columnas: [{ titulo: 'Fecha' }, { titulo: 'Documento' }, { titulo: quien === 'ventas' ? 'Cliente' : 'Proveedor' }, { titulo: 'ISV', num: true }, { titulo: 'Total', num: true }],
      filas: (lib.filas || []).map((f) => [fecha(f.fecha), [f.numero_documento || '', f.estado && f.estado !== 'vigente' ? [' ', chip(String(f.estado).toUpperCase() === 'ANULADA' ? 'Anulada' : f.estado, 'rojo')] : null],
        f.nombre || 'Consumidor final', dinero(f.isv_centavos), monto(dinero(f.total_centavos), { negativo: Number(f.total_centavos) < 0 })]) });
    const docLibros = () => {
      const seccion = (lib, t) => ({ titulo: t, columnas: (lib.columnas || []).map((c) => ({ titulo: c.titulo, tipo: /_centavos$/.test(c.clave) ? 'dinero' : 'texto' })),
        filas: (lib.filas || []).map((f) => (lib.columnas || []).map((c) => f[c.clave])),
        total: (lib.columnas || []).map((c, i) => (i === 0 ? 'Total' : /_centavos$/.test(c.clave) ? (lib.totales || {})[c.clave] ?? null : null)) });
      return { titulo: 'Libros de ISV', periodo: nombreMes(m.anio, m.mes), notas: [li.nota, `ISV a pagar: ${dinero(aPagar)} (negativo = crédito a favor).`].filter(Boolean),
        secciones: [seccion(lv, 'Libro de ventas'), seccion(lc, 'Libro de compras')] };
    };
    return [
      h('div', { class: 'cifras' },
        cifraChica('ISV de ventas', dinero(tv.isv_centavos), { dato: 'libro-isv-ventas' }),
        cifraChica('ISV de compras', dinero(tc.isv_centavos), { dato: 'libro-isv-compras' }),
        cifraChica(aPagar >= 0 ? 'ISV a pagar' : 'Crédito a favor', dinero(Math.abs(aPagar)), { dato: 'libro-isv-pagar', clase: aPagar > 0 ? 'monto-sale' : 'monto-entra' })),
      li.cuadra ? h('p', {}, chip('Los libros cuadran con la contabilidad', 'verde', { dataset: { dato: 'libros-cuadran' } }))
        : mensaje('error', 'Los libros no cuadran con la contabilidad.', 'Puede haber asientos manuales sobre las cuentas de ISV. Revíselo con su contador.'),
      h('h3', { class: 'titulo-chico' }, `Libro de ventas (${(lv.filas || []).length})`),
      (lv.filas || []).length ? corta(lv, 'ventas') : estadoVacio({ icono: 'documento', chico: true, texto: 'No hay ventas en este mes.' }),
      h('h3', { class: 'titulo-chico' }, `Libro de compras (${(lc.filas || []).length})`),
      (lc.filas || []).length ? corta(lc, 'compras') : estadoVacio({ icono: 'documento', chico: true, texto: 'No hay compras ni gastos con factura en este mes.' }),
      botonesReporte('libros', docLibros),
    ];
  }

  // Documento del mes para Excel e impresión: estado de resultados, balance, flujo e ISV (líneas del núcleo).
  async function documentoMes(m, x = null) {
    const d = x || await rpc('exportar_mes', { p_empresa_id: empresaId(), p_anio: m.anio, p_mes: m.mes });
    const s = d.secciones || {};
    const sec = (t, k) => ({ titulo: t, columnas: [{ titulo: 'Concepto' }, { titulo: 'Monto', tipo: 'dinero' }],
      filas: ((s[k] || {}).lineas || []).map((l) => [`${'   '.repeat(l.nivel || 0)}${l.concepto}`, l.monto_centavos]) });
    return { titulo: `Cierre de mes${d.preliminar ? ' (PRELIMINAR)' : ''}`, periodo: nombreMes(m.anio, m.mes),
      notas: [d.nota, ...(d.advertencias || []).map((a) => `Aviso: ${a.mensaje}`)].filter(Boolean),
      secciones: [sec('Estado de resultados', 'estado_resultados'), sec('Balance general', 'balance_general'), sec('Flujo de efectivo', 'flujo_efectivo'),
        { titulo: 'ISV del mes', columnas: [{ titulo: 'Concepto' }, { titulo: 'Monto', tipo: 'dinero' }],
          filas: [['ISV de ventas (débito)', (s.isv || {}).debito_fiscal_centavos], ['ISV de compras y gastos (crédito)', (s.isv || {}).credito_fiscal_centavos],
            ['ISV a pagar (negativo = a favor)', (s.isv || {}).a_pagar_centavos]] }] };
  }

  if (await cargarLista()) await verMes();
}
