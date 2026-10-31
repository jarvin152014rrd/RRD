// Reportes · "Empleados y comisiones" (app 0.8.0). Solo mirar.
//   Ventas por empleado, descuentos, anulaciones pedidas y diferencias de caja: vigilancia_empleados (núcleo
//   047, bitacora.ver; ventas y turnos solo de las sucursales que ve quien consulta).
//   Comisiones del período (módulo comisiones, comisiones.ver): v_comision (lo ganado en esas fechas, con
//   ajustes) y v_comision_vendedor (lo que se les debe hoy). Se ganan SOLO sobre lo cobrado (decisión del dueño).
//   Faltantes y sobrantes por turno: v_turno_caja (dinero.ver).
import { leer, rpc } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha, fechaHora } from '../formato.js';
import { h, cajaError, titulo, tarjetaCifra, monto, chip, estadoVacio, mensaje, tabla, filaIcono } from '../ui.js';
import { alcance, reiniciarAlSalir, nucleoFiltraSucursal } from '../datos.js';
import { selectorPeriodo, periodoInicial, datosPeriodo, botonesReporte, hastaHoy, TOPE_FILAS, llegoAlTope } from '../reportes.js';

let periodo = periodoInicial();
reiniciarAlSalir(() => { periodo = periodoInicial(); });

const ROL = { dueno: 'Dueño', admin: 'Administrador', cajero: 'Cajero', vendedor: 'Vendedor', contador: 'Contador' };
const DESTINO = { cobrar_al_cajero: 'se le cobra al cajero', gasto: 'se envió a gasto', otros_ingresos: 'pasó a otros ingresos' };
// Qué se decidió con la diferencia de un turno ('' si cuadró).
const resolucion = (t) => (t.diferencia_estado === 'pendiente' ? 'sin decidir' : t.diferencia_estado === 'resuelta' ? DESTINO[t.resolucion_destino] || 'resuelta' : '');

// Suma de comisiones por vendedor: [{ vendedor_id, vendedor, monto_centavos }] -> Map.
export function comisionesPorVendedor(movs) {
  const m = new Map();
  for (const x of movs) {
    const a = m.get(x.vendedor_id) || { vendedor_id: x.vendedor_id, nombre: x.vendedor || 'Sin nombre', ganado: 0, ajustes: 0, ventas: new Set() };
    if (x.tipo === 'devengo') a.ganado += Number(x.monto_centavos) || 0; else a.ajustes += Number(x.monto_centavos) || 0;
    if (x.venta_id) a.ventas.add(x.venta_id);
    m.set(x.vendedor_id, a);
  }
  return m;
}

export async function mostrar(vista, ctx) {
  const al = await alcance();
  // v_comision_vendedor (lo que se debe hoy): desde el núcleo 0.16.0 el servidor la limita a las sucursales del
  // usuario; con un núcleo anterior era de toda la empresa y a un usuario limitado no se le pide.
  const filtra = al.limitado ? await nucleoFiltraSucursal() : true;
  if (!ctx.sigueVigente()) return;
  const veoDeuda = !al.limitado || filtra;
  const veoVigilancia = puede('bitacora.ver');
  const veoComisiones = tieneModulo('comisiones') && puede('comisiones.ver');
  const veoTurnos = tieneModulo('dinero') && puede('dinero.ver');
  const zona = h('div', { class: 'lista' });
  let doc = null;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-empleados' },
    titulo('h1', 'credencial', 'Empleados y comisiones', { id: 't-empleados' }),
    selectorPeriodo({ prefijo: 'empleados', periodo, alCambiar: (p) => { periodo = p; cargar(); }, maxDias: 366 }),
    botonesReporte('empleados', () => doc), zona));

  async function cargar() {
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    doc = null;
    const dp = datosPeriodo(periodo);
    const hasta = hastaHoy(dp.hasta);
    let vig = null, movs = [], porPagar = [], turnos = [];
    try {
      [vig, movs, porPagar, turnos] = await Promise.all([
        veoVigilancia ? rpc('vigilancia_empleados', { p_empresa_id: empresaId(), p_desde: dp.desde, p_hasta: hasta }) : null,
        veoComisiones ? leer('v_comision', { empresa_id: empresaId(), fecha_contable: { gte: dp.desde, lte: hasta } }, { orden: 'fecha_contable.asc', limite: TOPE_FILAS }) : [],
        veoComisiones && veoDeuda ? leer('v_comision_vendedor', { empresa_id: empresaId() }, { orden: 'vendedor.asc' }) : [],
        veoTurnos ? leer('v_turno_caja', { empresa_id: empresaId(), fecha_cierre: { gte: dp.desde, lte: hasta } }, { orden: 'cerrado_en.desc', limite: TOPE_FILAS }) : [],
      ]);
    } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;

    const empleados = vig ? (vig.empleados || []) : [];
    // Sin permiso de ver ventas, el núcleo manda ventas y descuentos en null: la persona sale igual si tiene
    // diferencias de caja o anulaciones, con "—" en las columnas de ventas.
    const conVentas = empleados.filter((e) => (e.ventas && (e.ventas.cantidad || (e.descuentos && e.descuentos.ventas_con_descuento)))
      || (e.anulaciones_pedidas && e.anulaciones_pedidas.cantidad) || (e.diferencias_caja && e.diferencias_caja.turnos));
    const raya = '—';
    const costosOcultos = !vig || vig.costos_ocultos;
    const com = comisionesPorVendedor(movs);
    for (const p of porPagar) if (!com.has(p.vendedor_id) && Number(p.por_pagar_centavos)) com.set(p.vendedor_id, { vendedor_id: p.vendedor_id, nombre: p.vendedor, ganado: 0, ajustes: 0, ventas: new Set() });
    const comisiones = [...com.values()].map((c) => ({ ...c, porPagar: Number((porPagar.find((p) => p.vendedor_id === c.vendedor_id) || {}).por_pagar_centavos) || 0 }))
      .sort((a, b) => (b.ganado + b.ajustes) - (a.ganado + a.ajustes));
    const cerrados = turnos.filter((t) => t.estado !== 'abierto');
    const topeTurnos = llegoAlTope(turnos);
    const faltante = cerrados.reduce((s, t) => s + Math.min(0, Number(t.diferencia_centavos) || 0), 0);
    const sobrante = cerrados.reduce((s, t) => s + Math.max(0, Number(t.diferencia_centavos) || 0), 0);

    zona.replaceChildren(...[
      veoVigilancia ? [
        h('h2', { class: 'titulo-chico' }, 'Ventas por empleado'),
        h('p', { class: 'ayuda' }, 'Ventas emitidas por quien las registró (con ISV). Descuentos = los que dio a mano (las promociones no cuentan).'),
        conVentas.length ? tabla({ props: { id: 'tabla-empleados' },
          columnas: [{ titulo: 'Empleado' }, { titulo: 'Ventas', num: true }, { titulo: 'Vendió', num: true }, ...(costosOcultos ? [] : [{ titulo: 'Ganancia', num: true }]),
            { titulo: 'Descuentos dados', num: true }, { titulo: 'Anulaciones pedidas', num: true }, { titulo: 'Diferencia de caja', num: true }],
          filas: conVentas.map((e) => [h('span', {}, h('strong', {}, e.nombre), ' ', h('span', { class: 'detalle' }, ROL[e.rol] || e.rol)),
            e.ventas ? String(e.ventas.cantidad) : raya, e.ventas ? monto(dinero(e.ventas.total_centavos), { dato: `vendio-${e.usuario_id}` }) : raya,
            ...(costosOcultos ? [] : [monto(dinero(e.ganancia_centavos), { negativo: Number(e.ganancia_centavos) < 0 })]),
            e.descuentos ? `${dinero(e.descuentos.total_centavos)} (${e.descuentos.ventas_con_descuento})` : raya,
            `${e.anulaciones_pedidas.cantidad}${e.anulaciones_pedidas.aprobadas ? ` (${e.anulaciones_pedidas.aprobadas} aprobadas)` : ''}`,
            monto(dinero(e.diferencias_caja.neto_centavos), { negativo: Number(e.diferencias_caja.neto_centavos) < 0 })]),
          filaProps: (i) => ({ dataset: { empleado: conVentas[i].usuario_id } }) })
          : estadoVacio({ icono: 'usuarios', chico: true, texto: 'Nadie vendió ni cerró caja en estas fechas.' }),
      ] : null,

      veoComisiones ? [
        h('h2', { class: 'titulo-chico' }, 'Comisiones'),
        h('p', { class: 'ayuda', dataset: { info: 'comision-cobrado' } }, 'Se ganan solo sobre lo cobrado: una venta al crédito da comisión cuando se termina de cobrar, y lo que se perdonó al cliente no cuenta. Las devoluciones las rebajan, aunque ya se hayan pagado.'),
        comisiones.length ? tabla({ props: { id: 'tabla-comisiones' }, columnas: [{ titulo: 'Vendedor' }, { titulo: 'Ganó en estas fechas', num: true }, { titulo: 'Ajustes', num: true }, ...(veoDeuda ? [{ titulo: 'Se le debe hoy', num: true }] : [])],
          filas: comisiones.map((c) => [h('strong', {}, c.nombre), monto(dinero(c.ganado), { sentido: c.ganado ? 'entra' : null, dato: `comision-${c.vendedor_id}` }),
            c.ajustes ? monto(dinero(c.ajustes), { negativo: c.ajustes < 0 }) : dinero(0), ...(veoDeuda ? [monto(dinero(c.porPagar), { dato: `por-pagar-${c.vendedor_id}` })] : [])]) })
          : estadoVacio({ icono: 'credencial', chico: true, texto: 'No hay comisiones en estas fechas.' }),
        !veoDeuda ? h('p', { class: 'ayuda', dataset: { info: 'deuda-limitado' } }, 'Lo que se le debe hoy a cada vendedor es de toda la empresa; usted trabaja solo con sus sucursales, por eso no lo ve.')
          : al.limitado ? h('p', { class: 'ayuda', dataset: { info: 'deuda-sucursal' } }, 'Lo que se le debe hoy cuenta solo las ventas de sus sucursales.') : null,
        llegoAlTope(movs) ? mensaje('info', `Se leyeron los primeros ${TOPE_FILAS.toLocaleString('en-US')} movimientos de comisiones.`, 'Acorte las fechas para ver todo.') : null,
      ] : null,

      veoTurnos ? [
        h('h2', { class: 'titulo-chico' }, 'Faltantes y sobrantes de caja'),
        h('div', { class: 'cifras-dos' },
          tarjetaCifra({ dato: 'faltantes', icono: 'baja', color: faltante ? 'rojo' : 'neutro', etiqueta: 'Faltó', valor: dinero(Math.abs(faltante)) }),
          tarjetaCifra({ dato: 'sobrantes', icono: 'sube', color: sobrante ? 'dorado' : 'neutro', etiqueta: 'Sobró', valor: dinero(sobrante) })),
        topeTurnos ? mensaje('info', `Se leyeron los primeros ${TOPE_FILAS.toLocaleString('en-US')} turnos: lo que faltó y sobró puede ser más.`, 'Acorte las fechas para ver todo.', { dataset: { info: 'tope-turnos' } }) : null,
        cerrados.length ? h('div', { class: 'lista-filas', id: 'lista-turnos' }, cerrados.map((t) => {
          const dif = Number(t.diferencia_centavos) || 0;
          return filaIcono({ icono: 'caja', color: dif < 0 ? 'rojo' : dif > 0 ? 'dorado' : 'verde',
            titulo: h('strong', {}, `Turno #${t.numero} · ${t.cajero || ''}`),
            detalle: [t.caja, t.cerrado_en ? `cerró el ${fechaHora(t.cerrado_en)}` : fecha(t.fecha_cierre), resolucion(t) || null].filter(Boolean).join(' · '),
            derecha: [dif ? monto(dinero(Math.abs(dif)), { sentido: dif < 0 ? 'sale' : null, signo: dif < 0 ? '-' : '+' }) : null,
              dif < 0 ? chip('Faltante', 'rojo') : dif > 0 ? chip('Sobrante', 'dorado') : chip('Cuadró', 'verde')],
            props: { dataset: { turno: t.turno_id, diferencia: String(dif) } } });
        })) : estadoVacio({ icono: 'caja', chico: true, texto: 'No se cerraron turnos de caja en estas fechas.' }),
      ] : null,
      !veoVigilancia && !veoComisiones && !veoTurnos ? estadoVacio({ icono: 'credencial', texto: 'No hay nada que mostrar con sus permisos.' }) : null,
    ].flat().filter(Boolean));

    doc = { titulo: 'Empleados y comisiones', periodo: dp.texto, notas: ['Comisiones: solo sobre lo cobrado.'],
      secciones: [
        ...(veoVigilancia ? [{ titulo: 'Ventas por empleado', columnas: [{ titulo: 'Empleado' }, { titulo: 'Puesto' }, { titulo: 'Ventas', tipo: 'numero' }, { titulo: 'Vendió', tipo: 'dinero' },
          ...(costosOcultos ? [] : [{ titulo: 'Ganancia', tipo: 'dinero' }]), { titulo: 'Descuentos dados', tipo: 'dinero' }, { titulo: 'Anulaciones pedidas', tipo: 'numero' },
          { titulo: 'Faltante', tipo: 'dinero' }, { titulo: 'Sobrante', tipo: 'dinero' }],
          filas: conVentas.map((e) => [e.nombre, ROL[e.rol] || e.rol, e.ventas ? e.ventas.cantidad : null, e.ventas ? e.ventas.total_centavos : null, ...(costosOcultos ? [] : [e.ganancia_centavos]),
            e.descuentos ? e.descuentos.total_centavos : null, e.anulaciones_pedidas.cantidad, e.diferencias_caja.faltante_centavos, e.diferencias_caja.sobrante_centavos]) }] : []),
        ...(veoComisiones ? [{ titulo: 'Comisiones', columnas: [{ titulo: 'Vendedor' }, { titulo: 'Ganó en estas fechas', tipo: 'dinero' }, { titulo: 'Ajustes', tipo: 'dinero' }, ...(veoDeuda ? [{ titulo: 'Se le debe hoy', tipo: 'dinero' }] : [])],
          filas: comisiones.map((c) => [c.nombre, c.ganado, c.ajustes, ...(veoDeuda ? [c.porPagar] : [])]) }] : []),
        ...(veoTurnos ? [{ titulo: 'Turnos de caja', columnas: [{ titulo: 'Turno', tipo: 'numero' }, { titulo: 'Caja' }, { titulo: 'Cajero' }, { titulo: 'Cerró' }, { titulo: 'Diferencia', tipo: 'dinero' }, { titulo: 'Qué se decidió' }],
          filas: cerrados.map((t) => [t.numero, t.caja, t.cajero, fecha(t.fecha_cierre), t.diferencia_centavos, resolucion(t)]),
          notas: topeTurnos ? [`Solo los primeros ${TOPE_FILAS} turnos; hay más en estas fechas.`] : [] }] : []),
      ] };
    const seccionCom = doc.secciones.find((s) => s.titulo === 'Comisiones');
    if (seccionCom) seccionCom.total = ['Total', comisiones.reduce((s, c) => s + c.ganado, 0), comisiones.reduce((s, c) => s + c.ajustes, 0), ...(veoDeuda ? [comisiones.reduce((s, c) => s + c.porPagar, 0)] : [])];
  }
  await cargar();
}
