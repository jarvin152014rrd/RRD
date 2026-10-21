// Compras · "Proveedores" (app 0.7.0): lista con lo que se le debe a cada uno (v_cxp_documento),
// crear y editar (crear_tercero / editar_tercero del núcleo, con "es_proveedor"), y la ficha con lo que
// se le debe factura por factura y su historial de compras y pagos.
import { leer, rpc, escribir, nuevoId } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, titulo, filaIcono, chip, chipEstado, monto, estadoVacio } from '../ui.js';
import { proveedores, filtrar, alcance, olvidarDatos } from '../datos.js';
import { dato, cifraChica, cuandoVence } from '../formularios.js';
import { cuentasPorPagar, estadoFactura, formularioPago } from './compras_pagos.js';
import { verCompra, formularioCompra } from './compras.js';

export async function mostrar(vista, ctx) {
  const [lista, docs] = await Promise.all([proveedores(true), cuentasPorPagar()]);
  if (!ctx.sigueVigente()) return;
  // Lo que se debe a cada proveedor (solo de las facturas que este usuario ve).
  const deuda = new Map();
  for (const d of docs) {
    const x = deuda.get(d.proveedor_id) || { saldo: 0, vencido: 0, facturas: 0 };
    x.saldo += Number(d.saldo_centavos); x.facturas += 1;
    if (estadoFactura(d).estado === 'vencida') x.vencido += Number(d.saldo_centavos);
    deuda.set(d.proveedor_id, x);
  }
  const buscar = h('input', { id: 'buscar-proveedor', type: 'search', placeholder: 'Nombre, RTN o teléfono', autocomplete: 'off' });
  const zona = h('div', { class: 'lista-filas', id: 'lista-proveedores' });
  const pintar = () => {
    const vistos = filtrar(lista, buscar.value, ['nombre', 'rtn', 'telefono', 'codigo']);
    zona.replaceChildren(...(vistos.length ? vistos.slice(0, 300).map((p) => {
      const x = deuda.get(p.id);
      return filaIcono({
        icono: 'proveedor', color: p.activo ? (x && x.vencido ? 'rojo' : 'azul') : 'neutro',
        titulo: [h('strong', {}, p.nombre), !p.activo ? [' ', chipEstado('inactivo')] : null],
        detalle: [p.rtn ? 'RTN ' + p.rtn : null, p.telefono, p.plazo_dias ? `${p.plazo_dias} días de plazo` : 'Sin plazo'].filter(Boolean).join(' · '),
        derecha: x ? [monto(dinero(x.saldo), { sentido: 'sale', dato: 'debo-proveedor' }), x.vencido ? chip(`Vencido ${dinero(x.vencido)}`, 'rojo') : chip('Al día', 'verde')]
          : [chip('No le debo', 'verde')],
        abajo: h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', 'aria-label': `Ver a ${p.nombre}`, onclick: () => abrirFicha(vista, ctx, p.id) }, 'Ver')),
        props: { dataset: { proveedor: p.id } },
      });
    }) : [estadoVacio({ icono: 'buscar', chico: true, texto: 'No hay proveedores con ese nombre.' })]));
  };
  buscar.addEventListener('input', pintar);
  pintar();
  const nuevo = () => formularioProveedor(vista, ctx, null);
  const total = docs.reduce((s, d) => s + Number(d.saldo_centavos), 0);
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-prov' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'proveedor', 'Proveedores', { id: 't-prov' }),
      puede('terceros.editar') && lista.length ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nuevo-proveedor', onclick: nuevo },
        icono('mas'), 'Nuevo proveedor') : null),
    lista.length ? [h('div', { class: 'cifras' }, cifraChica('Proveedores', String(lista.filter((p) => p.activo).length)),
      cifraChica('Les debo en total', dinero(total), { dato: 'debo-total', clase: total ? 'monto-sale' : '' })), campo('Buscar', buscar), zona]
      : estadoVacio({ icono: 'proveedor', titulo: 'Aún no tiene proveedores',
        texto: 'Guarde a quienes le venden mercadería: así registra sus compras, sabe cuánto les debe y cuándo vence cada factura.',
        boton: puede('terceros.editar') ? { texto: 'Agregar el primero', onclick: nuevo, icono: 'mas', id: 'nuevo-proveedor' } : null })));
}

// Ficha del proveedor: datos, lo que se le debe y su historial (compras y pagos).
export async function abrirFicha(vista, ctx, proveedorId) {
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  try {
    const [[p], docs, compras, pagos, al] = await Promise.all([leer('tercero', { id: proveedorId }), cuentasPorPagar(proveedorId),
      leer('compra', { empresa_id: empresaId(), proveedor_id: proveedorId }, { orden: 'fecha_contable.desc', limite: 1000 }),
      leer('pago_proveedor', { empresa_id: empresaId(), proveedor_id: proveedorId }, { orden: 'fecha_contable.desc', limite: 300 }), alcance()]);
    if (!ctx.sigueVigente()) return;
    if (!p) { vista.replaceChildren(errorSimple('No se encontró el proveedor.')); return; }
    // Pagos: la tabla de pagos no se limita por sucursal; a un usuario limitado se le muestran solo los de
    // compras que ve (RLS) o de saldos iniciales que ve (cuentasPorPagar ya los filtró).
    const comprasVistas = new Set(compras.map((c) => c.id));
    const iniciales = al.limitado ? new Set((await leer('cxp_saldo_inicial', { empresa_id: empresaId(), proveedor_id: proveedorId }))
      .filter((s) => al.sucursales.includes(s.sucursal_id)).map((s) => s.id)) : null;
    const misPagos = pagos.filter((x) => (x.compra_id ? comprasVistas.has(x.compra_id) : !iniciales || iniciales.has(x.saldo_inicial_id)));
    const anulados = new Set((await Promise.all(misPagos.slice(0, 100).map((x) => leer('pago_proveedor_anulacion', { pago_id: x.id })))).flat().map((a) => a.pago_id));
    const saldo = docs.reduce((s, d) => s + Number(d.saldo_centavos), 0);
    const vencido = docs.filter((d) => estadoFactura(d).estado === 'vencida').reduce((s, d) => s + Number(d.saldo_centavos), 0);
    const historial = [
      ...compras.slice(0, 100).map((c) => ({ f: c.fecha_contable, n: c.numero, nodo: filaIcono({ icono: 'documento', color: c.anulada_en ? 'neutro' : 'azul',
        titulo: h('strong', {}, `Compra #${c.numero} · factura ${c.numero_documento}`),
        detalle: `${fecha(c.fecha_contable)} · ${c.condicion === 'contado' ? 'de contado' : 'al crédito'}`,
        derecha: [monto(dinero(c.total_centavos)), c.anulada_en ? chipEstado('anulada') : chipEstado(c.condicion === 'contado' ? 'contado' : 'credito')],
        abajo: h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', 'aria-label': `Ver la compra #${c.numero}`,
          onclick: () => verCompra(vista, ctx, c.id) }, 'Ver')), props: { dataset: { historial: 'compra' } } }) })),
      ...misPagos.slice(0, 100).map((x) => ({ f: x.fecha_contable, n: x.numero, nodo: filaIcono({ icono: 'billetes', color: anulados.has(x.id) ? 'neutro' : 'verde',
        titulo: h('strong', {}, `Pago #${x.numero}`), detalle: `${fecha(x.fecha_contable)}${x.referencia ? ' · ' + x.referencia : ''}`,
        derecha: [monto(dinero(x.monto_centavos), { sentido: anulados.has(x.id) ? null : 'sale' }), anulados.has(x.id) ? chipEstado('anulado') : chipEstado('aplicado', 'Pagado')],
        props: { dataset: { historial: 'pago' } } }) }))]
      .sort((a, b) => (a.f < b.f ? 1 : a.f > b.f ? -1 : b.n - a.n));
    const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
    vista.replaceChildren(
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-fprov' },
        h('div', { class: 'titulo-con-total' }, titulo('h1', 'proveedor', p.nombre, { id: 't-fprov' }), p.activo === false ? chipEstado('inactivo') : null),
        dato('Código', p.codigo), dato('RTN', p.rtn), dato('Teléfono', p.telefono), dato('Correo', p.correo), dato('Dirección', p.direccion),
        dato('Plazo para pagarle', `${p.plazo_dias || 0} días`),
        h('div', { class: 'botones' },
          puede('terceros.editar') ? h('button', { type: 'button', class: 'boton', id: 'editar-proveedor', onclick: () => formularioProveedor(vista, ctx, p) }, icono('editar'), 'Editar') : null,
          puede('compras.registrar') && p.activo ? h('button', { type: 'button', class: 'boton', onclick: () => formularioCompra(vista, ctx, { proveedorId: p.id }) }, icono('mas'), 'Nueva compra') : null,
          h('button', { type: 'button', class: 'boton', onclick: volver }, 'Volver a la lista'))),
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-le-debo' },
        titulo('h2', 'billetes', 'Lo que le debo', { id: 't-le-debo' }),
        h('div', { class: 'cifras' }, cifraChica('Le debo', dinero(saldo), { dato: 'saldo-proveedor', clase: saldo ? 'monto-sale' : '' }),
          cifraChica('Ya vencido', dinero(vencido), { clase: vencido ? 'monto-sale' : '' })),
        docs.length ? h('div', { class: 'lista-filas' }, docs.map((d) => {
          const e = estadoFactura(d);
          return filaIcono({ icono: 'documento', color: e.estado === 'vencida' ? 'rojo' : e.estado === 'por_vencer' ? 'dorado' : 'verde',
            titulo: h('strong', {}, `${d.origen === 'saldo_inicial' ? 'Saldo inicial · ' : ''}Factura ${d.numero_documento}`),
            detalle: `del ${fecha(d.fecha_documento)} · ${cuandoVence(e.dias)}`,
            derecha: [monto(dinero(d.saldo_centavos), { sentido: 'sale' }), e.chip],
            abajo: puede('compras.pagar') ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-principal',
              'aria-label': `Pagar factura ${d.numero_documento}`, onclick: () => formularioPago(vista, ctx, d, { alVolver: () => abrirFicha(vista, ctx, proveedorId) }) },
            icono('billetes'), 'Pagar')) : null });
        })) : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'No le debe nada a este proveedor.' })),
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-hist-prov' },
        titulo('h2', 'lista', 'Historial de compras y pagos', { id: 't-hist-prov' }),
        historial.length ? h('div', { class: 'lista-filas', id: 'historial-proveedor' }, historial.map((x) => x.nodo))
          : estadoVacio({ icono: 'compras', chico: true, texto: 'Todavía no hay compras ni pagos con este proveedor.' })));
  } catch (err) {
    vista.replaceChildren(await cajaError(err));
  }
}

// Crear (p = null) o editar un proveedor. El plazo pide terceros.credito (como en clientes).
function formularioProveedor(vista, ctx, p) {
  const credito = puede('terceros.credito');
  const v = (k) => (p && p[k] !== null && p[k] !== undefined ? String(p[k]) : '');
  const f = {
    nombre: h('input', { id: 'prov-nombre', type: 'text', maxlength: 200, required: true, value: v('nombre') }),
    rtn: h('input', { id: 'prov-rtn', type: 'text', inputmode: 'numeric', maxlength: 20, value: v('rtn') }),
    telefono: h('input', { id: 'prov-telefono', type: 'tel', maxlength: 20, value: v('telefono') }),
    correo: h('input', { id: 'prov-correo', type: 'email', maxlength: 200, value: v('correo') }),
    direccion: h('input', { id: 'prov-direccion', type: 'text', maxlength: 300, value: v('direccion') }),
    plazo: h('input', { id: 'prov-plazo', type: 'number', min: '0', max: '365', step: '1', inputmode: 'numeric', value: v('plazo_dias') }),
  };
  const motivo = h('input', { id: 'prov-motivo', type: 'text', maxlength: 300 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'prov-guardar' }, p ? 'Guardar cambios' : 'Crear proveedor');
  const id = nuevoId();
  const cancelar = () => (p ? abrirFicha(vista, ctx, p.id) : (vista.replaceChildren(), mostrar(vista, ctx)));
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Nombre', f.nombre), campo('RTN (opcional)', f.rtn, '14 números. Puede escribirlo con guiones.'),
    campo('Teléfono (opcional)', f.telefono), campo('Correo (opcional)', f.correo), campo('Dirección (opcional)', f.direccion),
    credito ? campo('Días de plazo que le da para pagar', f.plazo, 'Con esto se calcula cuándo vence cada compra al crédito. 0 = paga al recibir.') : null,
    p ? campo('Motivo del cambio (opcional)', motivo, 'Queda en la bitácora.') : null,
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: cancelar }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const datos = {};
    const nombre = f.nombre.value.trim();
    if (nombre.length < 2) { zonaError.append(errorSimple('Escriba el nombre del proveedor.')); f.nombre.focus(); return; }
    const rtn = f.rtn.value.replace(/\D/g, '');
    if (rtn && rtn.length !== 14) { zonaError.append(errorSimple('El RTN debe tener 14 números.', `Tiene ${rtn.length}. Revíselo.`)); f.rtn.focus(); return; }
    const tel = f.telefono.value.replace(/\D/g, '');
    if (tel && (tel.length < 8 || tel.length > 15)) { zonaError.append(errorSimple('El teléfono debe tener de 8 a 15 números.')); f.telefono.focus(); return; }
    const pon = (k, val, antes) => {
      if (!p) { if (val !== '') datos[k] = val; return; }
      if (String(val ?? '') !== String(antes ?? '')) datos[k] = val === '' ? null : val;
    };
    pon('nombre', nombre, p && p.nombre);
    pon('rtn', rtn, p && p.rtn);
    pon('telefono', tel, p && p.telefono);
    pon('correo', f.correo.value.trim(), p && p.correo);
    pon('direccion', f.direccion.value.trim(), p && p.direccion);
    if (credito) {
      const plazo = f.plazo.value === '' ? 0 : Number(f.plazo.value);
      if (!Number.isInteger(plazo) || plazo < 0 || plazo > 365) { zonaError.append(errorSimple('El plazo va de 0 a 365 días.')); f.plazo.focus(); return; }
      if (!p || plazo !== Number(p.plazo_dias || 0)) datos.plazo_dias = plazo;
    }
    if (p && !Object.keys(datos).length) { abrirFicha(vista, ctx, p.id); return; }
    const r = await conBoton(boton, zonaError, () => (p
      ? rpc('editar_tercero', { p_empresa_id: empresaId(), p_tercero_id: p.id, p_datos: datos, p_motivo: motivo.value.trim() || null })
      : escribir('crear_tercero', { p_empresa_id: empresaId(), p_datos: { ...datos, es_proveedor: true }, p_id_operacion: id })));
    if (!r) return;
    olvidarDatos('proveedores');
    aviso(p ? `Proveedor guardado · ${nombre}` : `Proveedor creado · ${nombre}`);
    abrirFicha(vista, ctx, p ? p.id : r.tercero_id);
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-fp' },
    titulo('h1', p ? 'editar' : 'proveedor', p ? `Editar ${p.nombre}` : 'Nuevo proveedor', { id: 't-fp' }), form));
  f.nombre.focus();
}
