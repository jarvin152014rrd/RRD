// Ajustes · Facturas (CAI) (app 0.16.0). Los rangos de números que autoriza el SAR, por caja: cuántos quedan, cuándo
// vencen, registrar uno nuevo, desactivar o activar. Servidor: v_cai_rango (lectura), registrar_cai, desactivar_cai,
// reactivar_cai (permiso cai.administrar, módulo fiscal_hn). El servidor revisa el formato, que el rango sea de esa
// caja (establecimiento y punto de emisión) y que no esté vencido.
import { rpc, leer } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { h, icono, aviso, campo, conBoton, pedirMotivo, titulo, filaIcono, chip, estadoVacio, dialogo, mensaje } from '../ui.js';

const TIPOS = { factura: 'Facturas', nota_credito: 'Notas de crédito', nota_debito: 'Notas de débito' };
const ESTADO = { vigente: ['Vigente', 'verde'], vencido: ['Vencido', 'rojo'], agotado: ['Agotado', 'rojo'] };
const fecha = (f) => (f ? f.split('-').reverse().join('/') : '');

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const [rangos, cajas, sucursales] = await Promise.all([
    leer('v_cai_rango', { empresa_id: E }, { orden: 'creado_en.desc' }),
    leer('caja', { empresa_id: E, activa: true }, { orden: 'punto_emision.asc' }),
    leer('sucursal', { empresa_id: E, activa: true }, { orden: 'codigo.asc' })]);
  if (!ctx.sigueVigente()) return;
  const admin = puede('cai.administrar');
  const recargar = async () => { vista.replaceChildren(); await mostrar(vista, ctx); };
  const suc = (id) => sucursales.find((s) => s.id === id) || {};
  const prefijo = (c) => `${suc(c.sucursal_id).codigo || '000'}-${c.punto_emision}`;

  const fila = (r) => {
    const [txt, color] = !r.activo ? ['Desactivado', 'neutro'] : ESTADO[r.estado] || [r.estado, 'azul'];
    const alerta = r.activo && (r.alerta_vencimiento || r.alerta_agotamiento);
    return filaIcono({
      icono: 'documento', color: !r.activo ? 'neutro' : r.estado !== 'vigente' ? 'rojo' : alerta ? 'dorado' : 'verde',
      titulo: [h('strong', {}, `${TIPOS[r.tipo_documento] || r.tipo_documento} · ${r.caja}`), ' ', chip(txt, color),
        alerta && r.estado === 'vigente' ? [' ', chip(r.alerta_vencimiento ? 'Vence pronto' : 'Quedan pocos', 'dorado')] : null],
      detalle: [`CAI ${r.cai}`, `${r.rango_desde} a ${r.rango_hasta}`, r.ultimo_emitido ? `último usado ${r.ultimo_emitido}` : 'sin usar',
        `vence ${fecha(r.fecha_limite_emision)}`].join(' · '),
      derecha: h('span', { class: 'monto', dataset: { dato: 'disponibles' } }, `${Number(r.numeros_disponibles).toLocaleString('es-HN')} libres`),
      abajo: admin ? h('div', { class: 'botones' }, h('button', { type: 'button', class: `boton ${r.activo ? 'boton-peligro' : ''}`,
        onclick: () => activar(r) }, r.activo ? 'Desactivar' : 'Activar')) : null,
      props: { dataset: { cai: r.cai_rango_id } },
    });
  };

  async function activar(r) {
    const ok = await pedirMotivo({ titulo: `${r.activo ? 'Desactivar' : 'Activar'} el rango ${r.rango_desde}`, peligro: r.activo,
      textoBoton: r.activo ? 'Desactivar' : 'Activar',
      explicacion: r.activo ? 'La caja deja de usar estos números. Las facturas ya hechas no cambian.' : null,
      accion: (motivo) => rpc(r.activo ? 'desactivar_cai' : 'reactivar_cai', { p_empresa_id: E, p_cai_rango_id: r.cai_rango_id, p_motivo: motivo }) });
    if (ok) { aviso(r.activo ? 'Rango desactivado' : 'Rango activado'); recargar(); }
  }

  function nuevo() {
    const selCaja = h('select', { id: 'cai-caja' }, cajas.map((c) => h('option', { value: c.id }, `${c.nombre} (${prefijo(c)})`)));
    const selTipo = h('select', { id: 'cai-tipo' }, Object.entries(TIPOS).map(([k, v]) => h('option', { value: k }, v)));
    const cai = h('input', { id: 'cai-codigo', type: 'text', maxlength: 40, autocomplete: 'off', placeholder: 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6' });
    const desde = h('input', { id: 'cai-desde', type: 'text', maxlength: 19, autocomplete: 'off' });
    const hasta = h('input', { id: 'cai-hasta', type: 'text', maxlength: 19, autocomplete: 'off' });
    const limite = h('input', { id: 'cai-limite', type: 'date' });
    const ultimo = h('input', { id: 'cai-ultimo', type: 'text', maxlength: 19, autocomplete: 'off' });
    const pista = () => {
      const c = cajas.find((x) => x.id === selCaja.value);
      const p = c ? prefijo(c) : '000-001';
      desde.placeholder = `${p}-01-00000001`; hasta.placeholder = `${p}-01-00005000`; ultimo.placeholder = `${p}-01-00000120`;
    };
    selCaja.addEventListener('change', pista); pista();
    const zona = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal', id: 'cai-guardar' }, 'Registrar');
    const form = h('form', { class: 'formulario', novalidate: true },
      h('p', { class: 'ayuda' }, 'Copie los datos tal como vienen en la autorización del SAR (o en su talonario).'),
      h('div', { class: 'dos-columnas' }, campo('Caja', selCaja), campo('Documento', selTipo)),
      campo('CAI', cai),
      h('div', { class: 'dos-columnas' }, campo('Desde el número', desde), campo('Hasta el número', hasta)),
      h('div', { class: 'dos-columnas' }, campo('Fecha límite de emisión', limite), campo('Último número ya usado (opcional)', ultimo, 'Solo si ya hizo facturas de este rango a mano.')),
      zona, h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => d.cerrar() }, 'Cancelar'), boton));
    const d = dialogo('Registrar CAI', form);
    selCaja.focus();
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const r = await conBoton(boton, zona, () => rpc('registrar_cai', { p_empresa_id: E, p_datos: {
        caja_id: selCaja.value, tipo_documento: selTipo.value, cai: cai.value.trim(), rango_desde: desde.value.trim(),
        rango_hasta: hasta.value.trim(), fecha_limite_emision: limite.value || null, ultimo_usado: ultimo.value.trim() || null } }));
      if (r) { d.cerrar(); aviso('CAI registrado'); recargar(); }
    });
  }

  const activos = rangos.filter((r) => r.activo);
  const sinCai = cajas.filter((c) => !activos.some((r) => r.caja_id === c.id && r.tipo_documento === 'factura' && r.estado === 'vigente'));
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cai' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'documento', 'Facturas (CAI)', { id: 't-cai' }),
      admin && rangos.length && cajas.length ? h('button', { type: 'button', class: 'boton boton-principal', id: 'cai-nuevo', onclick: nuevo }, icono('mas'), 'Registrar CAI') : null),
    h('p', { class: 'ayuda' }, 'El SAR autoriza los números de factura de cada caja. Aquí ve cuántos le quedan y cuándo vencen.'),
    sinCai.length && rangos.length ? mensaje('error', `Sin CAI vigente para facturas: ${sinCai.map((c) => c.nombre).join(', ')}`,
      'Esas cajas no pueden hacer facturas con CAI. Registre el CAI que le dio el SAR.', { dataset: { info: 'cajas-sin-cai' } }) : null,
    rangos.length ? h('div', { class: 'lista-filas' }, rangos.map(fila))
      : estadoVacio({ icono: 'documento', titulo: 'Todavía no hay CAI registrado',
        texto: cajas.length ? 'Registre el CAI y el rango de números que le dio el SAR para facturar.' : 'Primero cree una caja en Ajustes > Sucursales y bodegas.',
        boton: admin && cajas.length ? { texto: 'Registrar CAI', icono: 'mas', onclick: nuevo, id: 'cai-nuevo' } : null })));
}
