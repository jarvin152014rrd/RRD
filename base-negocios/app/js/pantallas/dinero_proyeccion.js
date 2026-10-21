// Dinero · "Proyección" (app 0.7.0): las próximas semanas con proyeccion_flujo (contabilidad.ver):
// gráfica del saldo de cada semana, tabla con lo que entra (cobros por vencer) y lo que sale (pagos a
// proveedores, pagos fijos, comisiones y dividendos), lo vencido aparte y las alertas de semanas en negativo.
// Es de TODA la empresa: a un usuario limitado a su sucursal no se le muestra (ver PENDIENTES).
import { rpc } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fecha } from '../formato.js';
import { h, cajaError, titulo, filaIcono, monto, estadoVacio, mensaje, tabla, graficaBarras } from '../ui.js';
import { alcance, reiniciarAlSalir } from '../datos.js';
import { cifraChica } from '../formularios.js';

const TIPO = { cobro: ['Cobro a cliente', 'cobrar'], pago_proveedor: ['Pago a proveedor', 'proveedor'], pago_fijo: ['Pago fijo', 'calendario'],
  comisiones: ['Comisiones', 'credencial'], dividendos: ['Dividendos a socios', 'usuarios'] };
let dias = 30;
reiniciarAlSalir(() => { dias = 30; });

// "L 12,500" sin centavos para la etiqueta corta de la barra en el celular.
const corto = (c) => { const n = Math.round(Number(c) / 100); return `${n < 0 ? '-' : ''}L ${Math.abs(n) >= 1000 ? Math.round(Math.abs(n) / 1000) + 'k' : Math.abs(n)}`; };

export async function mostrar(vista, ctx) {
  const al = await alcance();
  if (!ctx.sigueVigente()) return;
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-proy' }, titulo('h1', 'proyeccion', 'Proyección', { id: 't-proy' }));
  vista.append(tarjeta);
  if (al.limitado) {
    tarjeta.append(estadoVacio({ icono: 'proyeccion', titulo: 'La proyección es de toda la empresa',
      texto: 'Usted trabaja solo con sus sucursales, por eso no la ve. Pídasela al dueño.' }));
    return;
  }
  const selDias = h('select', { id: 'proy-dias' }, [30, 60, 90].map((d) => h('option', { value: String(d) }, `Próximos ${d} días`)));
  selDias.value = String(dias);
  const zona = h('div', { class: 'lista' });
  tarjeta.append(h('div', { class: 'dos-columnas filtros' }, h('div', { class: 'campo' }, h('label', { for: 'proy-dias' }, '¿Cuántos días?'), selDias)), zona);
  async function cargar() {
    dias = Number(selDias.value);
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    let r;
    try { r = await rpc('proyeccion_flujo', { p_empresa_id: empresaId(), p_dias: dias, p_agrupar: 'semana' }); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    const sem = r.semanas || [];
    const graf = graficaBarras(sem.map((s) => ({ etiqueta: `Sem ${s.semana}`, valor: Math.max(0, Number(s.saldo_final_centavos)),
      texto: dinero(s.saldo_final_centavos), textoCorto: corto(s.saldo_final_centavos), dato: `semana-${s.semana}` })), { titulo: 'Dinero al final de cada semana' });
    graf.id = 'grafica-proyeccion';
    for (const s of sem) if (s.negativo) { const c = graf.querySelector(`[data-barra="semana-${s.semana}"]`); if (c) c.classList.add('grafica-negativa'); }
    const detalle = r.detalle || [];
    zona.replaceChildren(...[
      h('div', { class: 'cifras' },
        cifraChica('Disponible hoy', dinero(r.disponible_hoy_centavos), { dato: 'disponible-hoy' }),
        cifraChica(`Al final (${dias} días)`, dinero(r.saldo_final_proyectado_centavos), { dato: 'saldo-final', clase: r.saldo_final_proyectado_centavos < 0 ? 'monto-sale' : 'monto-entra' }),
        cifraChica('Cobros vencidos (aparte)', dinero(r.cobros_vencidos_centavos), { dato: 'cobros-vencidos' })),
      h('p', { class: 'ayuda', dataset: { info: 'formula' } }, 'Cada semana: lo que había + cobros que vencen − pagos a proveedores − pagos fijos − comisiones y dividendos = lo que queda. Los cobros vencidos no se cuentan (no se sabe si entran).'),
      ...(r.alertas || []).map((a) => mensaje('error', a.mensaje, null, { dataset: { info: 'alerta-negativa' } })),
      Number(r.no_disponible_aun_centavos) ? mensaje('info', `${dinero(r.no_disponible_aun_centavos)} todavía no están disponibles`, 'Depósitos en tránsito, tarjetas por liquidar o transferencias por confirmar: no se suman.') : null,
      graf,
      tabla({ props: { id: 'tabla-proyeccion' },
        columnas: [{ titulo: 'Semana' }, { titulo: 'Empieza con', num: true }, { titulo: 'Entra (cobros)', num: true }, { titulo: 'Proveedores', num: true },
          { titulo: 'Pagos fijos', num: true }, { titulo: 'Otros', num: true }, { titulo: 'Termina con', num: true }],
        filas: sem.map((s) => [`Semana ${s.semana} · ${fecha(s.desde)} al ${fecha(s.hasta)}`, dinero(s.saldo_inicial_centavos),
          monto(dinero(s.cobros_centavos), { sentido: 'entra', signo: '+' }), monto(dinero(s.pagos_proveedores_centavos), { sentido: 'sale', signo: '-' }),
          monto(dinero(s.pagos_fijos_centavos), { sentido: 'sale', signo: '-' }), monto(dinero(Number(s.comisiones_centavos) + Number(s.dividendos_centavos)), { sentido: 'sale', signo: '-' }),
          monto(dinero(s.saldo_final_centavos), { negativo: s.negativo, dato: `final-${s.semana}` })]) }),
      h('h2', { class: 'titulo-chico' }, 'Lo que entra y sale, uno por uno'),
      detalle.length ? h('div', { class: 'lista-filas', id: 'detalle-proyeccion' }, detalle.map((m) => {
        const [t, ic] = TIPO[m.tipo] || [m.tipo, 'dinero'];
        return filaIcono({ icono: ic, color: m.monto > 0 ? 'verde' : 'rojo', titulo: h('strong', {}, `${t} · ${m.detalle}`),
          detalle: `Semana ${m.semana} · ${fecha(m.fecha)}`,
          derecha: monto(dinero(Math.abs(m.monto)), { sentido: m.monto > 0 ? 'entra' : 'sale', signo: m.monto > 0 ? '+' : '-' }), props: { dataset: { tipo: m.tipo } } });
      })) : estadoVacio({ icono: 'check_circulo', chico: true, texto: 'No hay cobros ni pagos por vencer en estos días.' }),
      (r.cobros_vencidos || []).length ? [h('h2', { class: 'titulo-chico' }, 'Cobros vencidos (no se cuentan)'),
        h('div', { class: 'lista-filas' }, r.cobros_vencidos.map((c) => filaIcono({ icono: 'cobrar', color: 'dorado', titulo: h('strong', {}, `${c.cliente} · ${c.numero_documento || ''}`),
          detalle: `venció el ${fecha(c.vence_el)}`, derecha: monto(dinero(c.saldo_centavos)) })))] : null,
    ].flat().filter(Boolean));
  }
  selDias.addEventListener('change', cargar);
  await cargar();
}
