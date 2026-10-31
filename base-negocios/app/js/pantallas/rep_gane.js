// Reportes · "¿Gané o perdí?" (app 0.8.0). Solo mirar: no mueve nada.
//   Un mes: estado_resultados (núcleo 040; mes cerrado = la foto del cierre; mes abierto = en vivo y
//   "preliminar"). Se compara con el mes anterior (saldo_cuentas, núcleo 011; si el mes está en curso, con los mismos días).
//   Otras fechas: saldo_cuentas (núcleo 011) y la misma cuenta que hace el núcleo para el estado de
//   resultados (resultadosDeSaldos), comparado con los mismos días justo antes.
// Con la contabilidad visible: "Ver en formato contable (NIIF)" con el estado de resultados y el balance
// formales (balance_general), tal como los arma el núcleo.
// Es de TODA la empresa: a un usuario limitado a su sucursal no se le muestra (ver PENDIENTES).
import { rpc } from '../api.js';
import { empresaId, perfilActual } from '../sesion.js';
import { dinero, fecha, sumarDias } from '../formato.js';
import { h, icono, cajaError, titulo, tarjetaCifra, chip, monto, estadoVacio, mensaje, tabla } from '../ui.js';
import { alcance, reiniciarAlSalir } from '../datos.js';
import { hoy } from '../formularios.js';
import { selectorPeriodo, periodoInicial, datosPeriodo, botonesReporte, barraParte, ganoPerdio, nombreMes, mesAnterior, MESES,
  periodoAnterior, hastaHoy, rangoMes } from '../reportes.js';

let periodo = periodoInicial();
reiniciarAlSalir(() => { periodo = periodoInicial(); });

// La misma cuenta que interno.calcular_estado_resultados (núcleo 040) sobre las filas de saldo_cuentas:
// ventas = 4.1 acreedoras; devoluciones y descuentos = 4.1 deudoras; otros ingresos = resto de ingresos;
// costo; gastos de operación = 6.1; otros gastos = el resto. Montos en centavos.
export function resultadosDeSaldos(filas) {
  const r = { ventas_brutas_centavos: 0, devoluciones_descuentos_centavos: 0, costo_ventas_centavos: 0, gastos_operacion_centavos: 0,
    otros_ingresos_centavos: 0, otros_gastos_centavos: 0, gastos_por_categoria: [], otros_ingresos: [], otros_gastos: [] };
  for (const s of filas || []) {
    const mov = Number(s.movimiento_centavos) || 0;
    if (!['ingreso', 'costo', 'gasto'].includes(s.tipo) || mov === 0) continue;
    const venta41 = s.tipo === 'ingreso' && String(s.codigo).startsWith('4.1.');
    const fila = (monto) => ({ codigo: s.codigo, nombre: s.nombre, monto_centavos: monto });
    if (venta41 && s.naturaleza === 'acreedora') r.ventas_brutas_centavos += mov;
    else if (venta41) r.devoluciones_descuentos_centavos += mov;
    else if (s.tipo === 'ingreso') { const m = s.naturaleza === 'acreedora' ? mov : -mov; r.otros_ingresos_centavos += m; r.otros_ingresos.push(fila(m)); }
    else {
      const m = s.naturaleza === 'deudora' ? mov : -mov;
      if (s.tipo === 'costo') r.costo_ventas_centavos += m;
      else if (String(s.codigo).startsWith('6.1.')) { r.gastos_operacion_centavos += m; r.gastos_por_categoria.push(fila(m)); }
      else { r.otros_gastos_centavos += m; r.otros_gastos.push(fila(m)); }
    }
  }
  r.ventas_netas_centavos = r.ventas_brutas_centavos - r.devoluciones_descuentos_centavos;
  r.utilidad_bruta_centavos = r.ventas_netas_centavos - r.costo_ventas_centavos;
  r.utilidad_operativa_centavos = r.utilidad_bruta_centavos - r.gastos_operacion_centavos;
  r.utilidad_neta_centavos = r.utilidad_operativa_centavos + r.otros_ingresos_centavos - r.otros_gastos_centavos;
  return r;
}

// "En octubre ganó L 12,400.00, L 1,800.00 más que en septiembre."
export function frase(texto, actual, anterior, textoAnterior) {
  const base = `${texto[0].toUpperCase()}${texto.slice(1)} ${ganoPerdio(actual)}`;
  if (anterior === null || anterior === undefined) return `${base}.`;
  const dif = Number(actual) - Number(anterior);
  if (dif === 0) return `${base}, lo mismo que ${textoAnterior}.`;
  return `${base}, ${dinero(Math.abs(dif))} ${dif > 0 ? 'más' : 'menos'} que ${textoAnterior}.`;
}

export async function mostrar(vista, ctx) {
  const al = await alcance();
  if (!ctx.sigueVigente()) return;
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-gane' }, titulo('h1', 'sube', '¿Gané o perdí?', { id: 't-gane' }));
  vista.append(tarjeta);
  if (al.limitado) {
    tarjeta.append(estadoVacio({ icono: 'sube', titulo: 'Este reporte es de toda la empresa',
      texto: 'Usted trabaja solo con sus sucursales, por eso no lo ve. Pídaselo al dueño.' }));
    return;
  }
  const zona = h('div', { class: 'lista' });
  let doc = null;
  tarjeta.append(selectorPeriodo({ prefijo: 'gane', periodo, alCambiar: (p) => { periodo = p; cargar(); } }),
    botonesReporte('gane', () => doc), zona);

  async function cargar() {
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    doc = null;
    const dp = datosPeriodo(periodo);
    let r, ant = null, textoAnt, er = null;
    try {
      if (periodo.modo === 'mes') {
        er = await rpc('estado_resultados', { p_empresa_id: empresaId(), p_anio: periodo.anio, p_mes: periodo.mes });
        r = er;
        // Mes anterior con saldo_cuentas (la misma cuenta del núcleo, con "otros gastos"). Si el mes está en curso,
        // se compara con los MISMOS días del mes anterior (del 1 al día de hoy), no con el mes completo.
        const ma = mesAnterior(periodo.anio, periodo.mes);
        const rm = rangoMes(ma.anio, ma.mes);
        const enCurso = hastaHoy(dp.hasta) !== dp.hasta;
        const dia = Number(hoy().slice(8, 10));
        const hastaAnt = enCurso ? (sumarDias(rm.desde, dia - 1) < rm.hasta ? sumarDias(rm.desde, dia - 1) : rm.hasta) : rm.hasta;
        const inicio = perfilActual().empresa.fecha_inicio;
        if (rm.hasta >= inicio) ant = resultadosDeSaldos(await rpc('saldo_cuentas', { p_empresa_id: empresaId(), p_desde: rm.desde, p_hasta: hastaAnt }));
        textoAnt = enCurso ? `en los mismos días de ${MESES[ma.mes - 1]} (del 1 al ${Number(hastaAnt.slice(8, 10))})` : `en ${MESES[ma.mes - 1]}`;
      } else {
        const pa = periodoAnterior(dp.desde, dp.hasta);
        const inicio = perfilActual().empresa.fecha_inicio;
        const [a, b] = await Promise.all([rpc('saldo_cuentas', { p_empresa_id: empresaId(), p_desde: dp.desde, p_hasta: dp.hasta }),
          pa.hasta >= inicio ? rpc('saldo_cuentas', { p_empresa_id: empresaId(), p_desde: pa.desde, p_hasta: pa.hasta }) : null]);
        r = resultadosDeSaldos(a);
        ant = b ? resultadosDeSaldos(b) : null;
        textoAnt = `del ${fecha(pa.desde)} al ${fecha(pa.hasta)}`;
      }
    } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;

    const neta = Number(r.utilidad_neta_centavos);
    const abierto = periodo.modo === 'mes' && er.preliminar;
    const textoPeriodo = periodo.modo === 'mes' ? `en ${dp.corto}${hastaHoy(dp.hasta) !== dp.hasta ? ' (hasta hoy)' : ''}` : dp.texto;
    const gastos = Number(r.gastos_operacion_centavos), otrosI = Number(r.otros_ingresos_centavos), otrosG = Number(r.otros_gastos_centavos);
    const filasGasto = [...(r.gastos_por_categoria || []), ...(r.otros_gastos || [])].sort((x, y) => y.monto_centavos - x.monto_centavos);
    const totalGastos = gastos + otrosG;

    const comparar = [
      ['Ventas (ya restan devoluciones y descuentos)', 'ventas_netas_centavos', 'entra'],
      ['Costo de lo vendido', 'costo_ventas_centavos', 'sale'],
      ['Ganancia bruta', 'utilidad_bruta_centavos', null],
      ['Gastos de operación', 'gastos_operacion_centavos', 'sale'],
      // Con "otros gastos" la tarjeta de Gastos cuadra con la tabla (salen solo si hay algo).
      ...(Number(r.otros_gastos_centavos) || (ant && Number(ant.otros_gastos_centavos)) ? [['Otros gastos', 'otros_gastos_centavos', 'sale']] : []),
      ...(Number(r.otros_ingresos_centavos) || (ant && Number(ant.otros_ingresos_centavos)) ? [['Otros ingresos', 'otros_ingresos_centavos', 'entra']] : []),
      ['Ganancia neta', 'utilidad_neta_centavos', null],
    ];
    const vacio = !Number(r.ventas_netas_centavos) && !Number(r.costo_ventas_centavos) && !totalGastos && !otrosI;

    zona.replaceChildren(...[
      h('p', { class: 'frase-grande ' + (neta >= 0 ? 'texto-verde' : 'texto-rojo'), id: 'gane-frase', dataset: { neta: String(neta) } },
        icono(neta >= 0 ? 'sube' : 'baja'), h('span', {}, frase(textoPeriodo, neta, ant ? ant.utilidad_neta_centavos : null, textoAnt))),
      abierto ? mensaje('info', 'El mes sigue abierto: estas cifras pueden cambiar.', 'Quedan firmes cuando se cierra el mes (Reportes > Cierre de mes).', { dataset: { info: 'preliminar' } }) : null,
      vacio ? estadoVacio({ icono: 'grafica', chico: true, texto: 'No hay ventas ni gastos en estas fechas.' }) : null,
      h('div', { class: 'cifras' },
        tarjetaCifra({ dato: 'gane-ventas', icono: 'sube', color: 'verde', etiqueta: 'Vendí', valor: dinero(r.ventas_netas_centavos),
          nota: Number(r.devoluciones_descuentos_centavos) ? `ya restadas devoluciones y descuentos por ${dinero(r.devoluciones_descuentos_centavos)}` : 'ventas sin ISV' }),
        tarjetaCifra({ dato: 'gane-costo', icono: 'etiqueta', color: 'rojo', etiqueta: 'Me costó lo vendido', valor: dinero(r.costo_ventas_centavos) }),
        tarjetaCifra({ dato: 'gane-bruta', icono: 'grafica', color: Number(r.utilidad_bruta_centavos) >= 0 ? 'verde' : 'rojo', etiqueta: 'Ganancia bruta',
          valor: dinero(r.utilidad_bruta_centavos), nota: Number(r.ventas_netas_centavos) ? `${Math.round(Number(r.utilidad_bruta_centavos) * 1000 / Number(r.ventas_netas_centavos)) / 10} % de lo vendido` : null }),
        tarjetaCifra({ dato: 'gane-gastos', icono: 'recibo', color: 'rojo', etiqueta: 'Gastos', valor: dinero(totalGastos) }),
        tarjetaCifra({ dato: 'gane-neta', icono: neta >= 0 ? 'check_circulo' : 'alerta', color: neta >= 0 ? 'verde' : 'rojo',
          etiqueta: neta >= 0 ? 'Ganancia neta' : 'Pérdida', valor: dinero(neta),
          chip: periodo.modo === 'mes' && r.utilidad_cobrada_centavos !== undefined ? chip(`cobrada ${dinero(r.utilidad_cobrada_centavos)}`, 'azul', { dataset: { dato: 'gane-cobrada' } }) : null })),
      periodo.modo === 'mes' ? h('p', { class: 'ayuda' }, `Ganancia cobrada = la parte de la ganancia que ya entró como dinero (lo vendido al crédito cuenta cuando se cobra). Es la que se reparte entre fondos y socios.`) : null,
      otrosI ? h('p', { class: 'ayuda' }, `Además entraron ${dinero(otrosI)} de otros ingresos (por ejemplo, intereses o sobrantes); ya están sumados en la ganancia neta.`) : null,
      h('h2', { class: 'titulo-chico' }, 'Gastos por categoría'),
      filasGasto.length ? h('div', { class: 'lista-filas', id: 'gane-gastos-lista' }, filasGasto.map((g) => h('div', { class: 'fila-parte' },
        h('div', { class: 'fila' }, h('span', {}, g.nombre), monto(dinero(g.monto_centavos), { sentido: 'sale' })),
        barraParte(g.monto_centavos, totalGastos)))) : estadoVacio({ icono: 'recibo', chico: true, texto: 'No hubo gastos en estas fechas.' }),
      h('h2', { class: 'titulo-chico' }, ant ? (periodo.modo === 'mes' ? `Comparado con ${textoAnt.replace(/^en (los )?/, (x, y) => (y ? 'los ' : ''))}` : `Comparado con los días anteriores (${textoAnt})`) : 'Comparado con antes'),
      ant ? tabla({ props: { id: 'gane-comparar' }, columnas: [{ titulo: 'Concepto' }, { titulo: 'Ahora', num: true }, { titulo: 'Antes', num: true }, { titulo: 'Diferencia', num: true }],
        filas: comparar.map(([t, k, s]) => {
          const dif = Number(r[k]) - Number(ant[k]);
          const buena = s === 'sale' ? dif <= 0 : dif >= 0;
          return [t, monto(dinero(r[k]), { sentido: s, negativo: Number(r[k]) < 0 }), monto(dinero(ant[k])),
            monto(`${dif > 0 ? '+' : ''}${dinero(dif)}`, { sentido: dif === 0 ? null : buena ? 'entra' : 'sale' })];
        }) }) : h('p', { class: 'ayuda' }, 'No hay un período anterior para comparar (el negocio empezó después).'),
      perfilActual().empresa.contabilidad_visible && periodo.modo === 'mes' ? h('div', { class: 'botones' },
        h('button', { type: 'button', class: 'boton', id: 'gane-niif', onclick: () => verNiif(er) }, icono('documento'), 'Ver en formato contable (NIIF)')) : null,
      perfilActual().empresa.contabilidad_visible && periodo.modo !== 'mes' ? h('p', { class: 'ayuda' }, 'El formato contable (NIIF) se ve por mes: elija un mes arriba.') : null,
      h('div', { id: 'gane-niif-zona' }),
    ].filter(Boolean));

    doc = { titulo: '¿Gané o perdí?', periodo: dp.texto, notas: [frase(textoPeriodo, neta, ant ? ant.utilidad_neta_centavos : null, textoAnt),
      ...(abierto ? ['PRELIMINAR: el mes sigue abierto y las cifras pueden cambiar.'] : [])],
      secciones: [
        { titulo: 'Resumen', columnas: [{ titulo: 'Concepto' }, { titulo: 'Monto', tipo: 'dinero' }],
          filas: [['Ventas (sin ISV, ya restan devoluciones y descuentos)', r.ventas_netas_centavos], ['Costo de lo vendido', r.costo_ventas_centavos],
            ['Ganancia bruta', r.utilidad_bruta_centavos], ['Gastos', totalGastos], ...(otrosI ? [['Otros ingresos', otrosI]] : []),
            ['Ganancia neta', neta], ...(periodo.modo === 'mes' ? [['Ganancia cobrada', r.utilidad_cobrada_centavos]] : [])] },
        { titulo: 'Gastos por categoría', columnas: [{ titulo: 'Categoría' }, { titulo: 'Monto', tipo: 'dinero' }],
          filas: filasGasto.map((g) => [g.nombre, g.monto_centavos]), total: ['Total', totalGastos] },
        ...(ant ? [{ titulo: 'Comparado', columnas: [{ titulo: 'Concepto' }, { titulo: 'Ahora', tipo: 'dinero' }, { titulo: 'Antes', tipo: 'dinero' }, { titulo: 'Diferencia', tipo: 'dinero' }],
          filas: comparar.map(([t, k]) => [t, r[k], ant[k], Number(r[k]) - Number(ant[k])]) }] : []),
      ] };
  }

  // Estado de resultados y balance formales (NIIF para PYMES), con las líneas que arma el núcleo.
  async function verNiif(er) {
    const z = document.getElementById('gane-niif-zona');
    if (!z) return;
    z.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    let bg;
    try { bg = await rpc('balance_general', { p_empresa_id: empresaId(), p_anio: periodo.anio, p_mes: periodo.mes }); } catch (err) { z.replaceChildren(await cajaError(err)); return; }
    const titulo2 = `${nombreMes(periodo.anio, periodo.mes)}`;
    const docNiif = { titulo: 'Estados financieros (NIIF para PYMES)', periodo: titulo2, notas: [er.nota].filter(Boolean),
      secciones: [
        { titulo: 'Estado de resultados', columnas: [{ titulo: 'Concepto' }, { titulo: 'Monto', tipo: 'dinero' }], filas: (er.lineas || []).map((l) => [`${'   '.repeat(l.nivel || 0)}${l.concepto}`, l.monto_centavos]) },
        { titulo: `Balance general al ${fecha(bg.al)}`, columnas: [{ titulo: 'Concepto' }, { titulo: 'Monto', tipo: 'dinero' }], filas: (bg.lineas || []).map((l) => [`${'   '.repeat(l.nivel || 0)}${l.concepto}`, l.monto_centavos]) },
      ] };
    const lineas = (ls) => h('div', { class: 'estado-formal' }, (ls || []).map((l) => h('div', { class: `linea-formal linea-${l.tipo} nivel-${Math.min(3, l.nivel || 0)}` },
      h('span', {}, l.concepto), h('span', { class: 'monto' }, l.monto_centavos === null ? '' : dinero(l.monto_centavos)))));
    z.replaceChildren(h('section', { class: 'tarjeta-interna', id: 'gane-niif-ver', 'aria-labelledby': 't-niif' },
      titulo('h2', 'documento', 'Formato contable (NIIF para PYMES)', { id: 't-niif' }),
      er.preliminar ? mensaje('info', 'PRELIMINAR: el mes está abierto y las cifras pueden cambiar.') : null,
      h('h3', { class: 'titulo-chico' }, 'Estado de resultados'), lineas(er.lineas),
      h('h3', { class: 'titulo-chico' }, `Balance general al ${fecha(bg.al)}`),
      bg.cuadra ? chip('El balance cuadra', 'verde', { dataset: { dato: 'balance-cuadra' } }) : chip(`No cuadra por ${dinero(bg.diferencia_centavos)}`, 'rojo'),
      lineas(bg.lineas),
      h('p', { class: 'ayuda' }, er.nota || 'Formato según NIIF para PYMES, pendiente de validación por un contador hondureño.'),
      botonesReporte('niif', () => docNiif)));
    z.scrollIntoView({ block: 'start' });
  }

  await cargar();
}
