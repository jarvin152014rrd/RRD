// Compras · "Compras" (app 0.7.0): lista con estado (chips) y filtros por fecha y proveedor; registrar
// una compra (registrar_compra: productos con cantidad y costo; el ISV lo calcula el núcleo con el
// impuesto de cada producto; de contado diciendo de qué caja o banco sale, o al crédito con vencimiento);
// ver el detalle (líneas, pagos) y anular con motivo (anular_compra: nada se borra, el núcleo hace la
// contrapartida, saca los productos del inventario y devuelve el dinero a la misma cuenta).
// Las compras son solo de productos que se guardan en inventario: un servicio se registra como gasto.
import { leer, escribir, nuevoId, rpcSiExiste } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha, cantidad, aCosto, aCantidad, aCentavos, sumarDias } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, pedirMotivo, titulo, filaIcono, chipEstado, monto,
  estadoVacio, mensaje, tabla } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { proveedores, bodegas, cuentasDinero, cuentasQuePagan, filtrar, olvidarDatos, reiniciarAlSalir } from '../datos.js';
import { hoy, selectCuentas, inputFecha, dato, cifraChica, textoMonto } from '../formularios.js';
import { cuentasPorPagar, estadoFactura, formularioPago } from './compras_pagos.js';

// Estado de una compra para su chip: anulada, pagada (contado o sin saldo), vencida o por pagar.
function estadoCompra(c, doc) {
  if (c.anulada_en) return { estado: 'anulada', chip: chipEstado('anulada') };
  if (c.condicion === 'contado') return { estado: 'pagada', chip: chipEstado('pagada', 'Pagada (contado)') };
  if (!doc) return { estado: 'pagada', chip: chipEstado('pagada') };
  const e = estadoFactura(doc);
  return e.estado === 'vencida' ? { estado: 'vencida', chip: e.chip } : { estado: 'por_pagar', chip: chipEstado('por_pagar', `Por pagar · vence ${fecha(doc.fecha_vencimiento)}`) };
}

// Costo por unidad (centavos con decimales) -> "L 12.505" (hasta 4 decimales de lempira). Solo para mostrar.
function costoTexto(c) {
  const n = Number(c) / 100;
  return Number.isFinite(n) ? `L ${n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 4 })}` : '';
}

const LIMITE = 300;
// Si el servidor no deja leer los totales (permiso o fechas), se suman las filas como antes; otro error sí se muestra.
const sinTotales = (e) => (['SIN_PERMISO', 'FECHA_INVALIDA'].includes(e && e.clave) ? null : Promise.reject(e));

// Filtros que se recuerdan mientras la app está abierta (no se guardan en el navegador).
const filtros = { desde: null, hasta: null, proveedor: '' };
reiniciarAlSalir(() => Object.assign(filtros, { desde: null, hasta: null, proveedor: '' }));

export async function mostrar(vista, ctx) {
  const [provs, docs] = await Promise.all([proveedores(true), cuentasPorPagar()]);
  if (!ctx.sigueVigente()) return;
  if (!filtros.desde) { filtros.desde = sumarDias(hoy(), -60); filtros.hasta = hoy(); }
  const porDoc = new Map(docs.map((d) => [d.documento_id, d]));
  const nombreProv = new Map(provs.map((p) => [p.id, p.nombre]));
  const desde = inputFecha('compras-desde', filtros.desde);
  const hasta = inputFecha('compras-hasta', filtros.hasta);
  const selProv = h('select', { id: 'compras-proveedor' }, h('option', { value: '' }, 'Todos los proveedores'),
    provs.map((p) => h('option', { value: p.id }, p.nombre)));
  selProv.value = filtros.proveedor;
  const zona = h('div', {});
  const resumen = h('div', { class: 'cifras' });
  const tope = h('div', {});

  let vez = 0;   // app 0.12.0: una respuesta vieja (filtros de antes) no pinta encima de la nueva
  async function cargar() {
    const mia = ++vez;
    Object.assign(filtros, { desde: desde.value, hasta: hasta.value, proveedor: selProv.value });
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    const f = { empresa_id: empresaId(), fecha_contable: { gte: filtros.desde || '2000-01-01', lte: filtros.hasta || '2100-12-31' } };
    if (filtros.proveedor) f.proveedor_id = filtros.proveedor;
    if (filtros.desde && filtros.hasta && filtros.desde > filtros.hasta) {
      resumen.replaceChildren(); tope.replaceChildren();
      zona.replaceChildren(mensaje('error', "La fecha 'desde' va antes que 'hasta'.", 'Corrija las fechas de arriba.', { dataset: { info: 'fechas-al-reves' } }));
      return;
    }
    let compras, tot;
    try {
      // Núcleo 0.16.0: los totales los suma el servidor (todas las compras del rango, no solo las que llegan).
      [compras, tot] = await Promise.all([leer('compra', f, { orden: 'numero.desc', limite: LIMITE }),
        puede('compras.ver') ? rpcSiExiste('totales_compras', { p_empresa_id: empresaId(), p_desde: filtros.desde || '2000-01-01', p_hasta: filtros.hasta || '2100-12-31',
          p_proveedor_id: filtros.proveedor || null }).catch(sinTotales) : null]);
    } catch (err) { if (mia === vez) zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente() || mia !== vez) return;
    let total, porPagar, cuantas;
    if (tot) {
      total = Number(tot.total_centavos); porPagar = Number(tot.por_pagar_centavos); cuantas = Number(tot.cantidad);
      tope.replaceChildren(compras.length >= LIMITE ? mensaje('info', `Se muestran las últimas ${LIMITE} compras; las cifras de arriba son de todas las del rango.`, '', { dataset: { info: 'tope-filas' } }) : '');
    } else {
      // Núcleo viejo (sin totales_compras): se suma lo que llegó; con LIMITE filas puede haber más.
      tope.replaceChildren(compras.length >= LIMITE ? mensaje('info', `Se muestran las últimas ${LIMITE} compras y las cifras suman solo esas.`, 'Acorte las fechas para ver el total exacto.', { dataset: { info: 'tope-filas' } }) : '');
      const vigentes = compras.filter((c) => !c.anulada_en);
      total = vigentes.reduce((s, c) => s + Number(c.total_centavos), 0);
      porPagar = vigentes.reduce((s, c) => s + Number((porDoc.get(c.id) || {}).saldo_centavos || 0), 0);
      cuantas = compras.length;
    }
    resumen.dataset.fuente = tot ? 'servidor' : 'navegador';
    resumen.replaceChildren(
      cifraChica('Compré en estas fechas', dinero(total), { dato: 'compras-total' }),
      cifraChica('De eso, debo todavía', dinero(porPagar), { dato: 'compras-debo', clase: porPagar ? 'monto-sale' : '' }),
      cifraChica('Compras', String(cuantas), { dato: 'compras-cuantas' }));
    zona.replaceChildren(compras.length ? h('div', { class: 'lista-filas', id: 'lista-compras' }, compras.map((c) => {
      const e = estadoCompra(c, porDoc.get(c.id));
      return filaIcono({
        icono: 'documento', color: e.estado === 'anulada' || e.estado === 'vencida' ? 'rojo' : e.estado === 'por_pagar' ? 'dorado' : 'verde',
        titulo: h('strong', {}, `Compra #${c.numero} · factura ${c.numero_documento}`),
        detalle: `${fecha(c.fecha_contable)} · ${nombreProv.get(c.proveedor_id) || 'Proveedor'} · ${c.condicion === 'contado' ? 'de contado' : 'al crédito'}`,
        derecha: [monto(dinero(c.total_centavos), { sentido: c.anulada_en ? null : 'sale' }), e.chip],
        abajo: h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', 'aria-label': `Ver la compra #${c.numero}`,
          onclick: () => verCompra(vista, ctx, c.id) }, 'Ver')),
        props: { dataset: { compra: c.id, estado: e.estado } },
      });
    })) : estadoVacio({ icono: 'buscar', chico: true, texto: 'No hay compras con esos filtros. Pruebe con otras fechas o con "Todos los proveedores".' }));
  }
  for (const x of [desde, hasta, selProv]) x.addEventListener('change', cargar);

  const nueva = () => formularioCompra(vista, ctx);
  const sinNada = !provs.length && !docs.length;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-compras' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'compras', 'Compras', { id: 't-compras' }),
      puede('compras.registrar') && !sinNada ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nueva-compra', onclick: nueva },
        icono('mas'), 'Nueva compra') : null),
    sinNada ? estadoVacio({ icono: 'compras', titulo: 'Aún no ha registrado compras',
      texto: 'Anote aquí lo que le compra a sus proveedores: los productos entran al inventario con su costo y el sistema lleva lo que debe.',
      botones: [puede('compras.registrar') ? { texto: 'Registrar la primera compra', onclick: nueva, icono: 'mas', id: 'nueva-compra' } : null,
        hayEnMenu(ctx.menu || [], 'compras', 'proveedores') && puede('terceros.editar') ? { texto: 'Agregar un proveedor', href: '#/compras/proveedores', icono: 'proveedor' } : null] })
      : [h('div', { class: 'dos-columnas filtros' }, campo('Desde', desde), campo('Hasta', hasta), campo('Proveedor', selProv)), tope, resumen, zona]));
  if (!sinNada) await cargar();
}

// ---------------- Detalle ----------------
export async function verCompra(vista, ctx, compraId, { arriba = null } = {}) {
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  try {
    const [[c], lineas, pagos, prods, bods] = await Promise.all([
      leer('compra', { id: compraId }), leer('compra_linea', { compra_id: compraId }, { orden: 'linea.asc' }),
      leer('pago_proveedor', { compra_id: compraId }, { orden: 'numero.asc' }),
      leer('v_producto', { empresa_id: empresaId() }, { limite: 1000 }), bodegas()]);
    if (!c) { vista.replaceChildren(errorSimple('No se encontró la compra.')); return; }
    const [anulados, cuentasLibro, provs, docs] = await Promise.all([
      Promise.all(pagos.map((p) => leer('pago_proveedor_anulacion', { pago_id: p.id }))).then((x) => new Set(x.flat().map((a) => a.pago_id))),
      Promise.all([...new Set([c.cuenta_pago_id, ...pagos.map((p) => p.cuenta_pago_id)].filter(Boolean))].map((id) => leer('cuenta', { id })))
        .then((x) => new Map(x.flat().map((k) => [k.id, k.nombre]))),
      proveedores(), c.condicion === 'credito' && !c.anulada_en ? cuentasPorPagar(c.proveedor_id) : []]);
    if (!ctx.sigueVigente()) return;
    const prov = provs.find((p) => p.id === c.proveedor_id);
    const nombreProd = new Map(prods.map((p) => [p.producto_id, p.nombre]));
    const bodega = bods.find((b) => b.id === c.bodega_id);
    const doc = docs.find((d) => d.documento_id === c.id);
    const e = estadoCompra(c, doc);
    const vigentes = pagos.filter((p) => !anulados.has(p.id));
    const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
    const recargar = (msj) => verCompra(vista, ctx, compraId, { arriba: msj });

    const anularCompra = () => {
      const idOp = nuevoId();
      pedirMotivo({ titulo: `Anular la compra #${c.numero}`, peligro: true, textoBoton: 'Sí, anular la compra',
        explicacion: `Nada se borra: el sistema hace la contrapartida. Los productos salen de ${bodega ? bodega.nombre : 'la bodega'} a lo que costaron`
          + (c.condicion === 'contado' ? ` y los ${dinero(c.total_centavos)} vuelven a ${cuentasLibro.get(c.cuenta_pago_id) || 'la cuenta de donde salieron'}.` : ' y la deuda con el proveedor se cancela.'),
        accion: (motivo) => escribir('anular_compra', { p_compra_id: c.id, p_motivo: motivo, p_id_operacion: idOp }),
      }).then((ok) => {
        if (!ok) return;
        olvidarDatos('cuentas');
        const t = `Compra #${c.numero} anulada · los productos salieron del inventario`
          + (c.condicion === 'contado' ? ` · ${dinero(c.total_centavos)} volvieron a ${cuentasLibro.get(c.cuenta_pago_id) || 'su cuenta'}` : '');
        aviso(t, 'ok', 7000);
        recargar(mensaje('ok', t));
      });
    };
    const anularPago = (p) => {
      const idOp = nuevoId();
      pedirMotivo({ titulo: `Anular el pago #${p.numero}`, peligro: true, textoBoton: 'Sí, anular el pago',
        explicacion: `Los ${dinero(p.monto_centavos)} vuelven a ${cuentasLibro.get(p.cuenta_pago_id) || 'la cuenta de donde salieron'} y la factura vuelve a deber ese monto.`,
        accion: (motivo) => escribir('anular_pago_proveedor', { p_pago_id: p.id, p_motivo: motivo, p_id_operacion: idOp }),
      }).then((ok) => {
        if (!ok) return;
        olvidarDatos('cuentas');
        const t = `Pago #${p.numero} anulado · ${dinero(p.monto_centavos)} volvieron a ${cuentasLibro.get(p.cuenta_pago_id) || 'su cuenta'}`;
        aviso(t, 'ok', 7000);
        recargar(mensaje('ok', t));
      });
    };

    vista.replaceChildren(...[
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-compra' },
        arriba,
        h('div', { class: 'titulo-con-total' }, titulo('h1', 'documento', `Compra #${c.numero}`, { id: 't-compra' }), e.chip),
        dato('Proveedor', prov ? prov.nombre : 'Proveedor'), dato('Factura del proveedor', c.numero_documento),
        dato('Fecha', fecha(c.fecha_contable)), dato('Entró a', bodega ? bodega.nombre : null),
        dato('Forma', c.condicion === 'contado' ? `De contado · salió de ${cuentasLibro.get(c.cuenta_pago_id) || 'caja o banco'}` : `Al crédito · vence ${fecha(c.fecha_vencimiento)}`),
        c.notas ? dato('Notas', c.notas) : null,
        c.anulada_en ? mensaje('error', 'Compra anulada', `Motivo: ${c.motivo_anulacion}${c.fecha_anulacion ? ' · ' + fecha(c.fecha_anulacion) : ''}`) : null,
        tabla({ props: { id: 'lineas-compra' },
          columnas: [{ titulo: 'Producto' }, { titulo: 'Cantidad', num: true }, { titulo: 'Costo por unidad', num: true }, { titulo: 'Subtotal', num: true }, { titulo: 'ISV', num: true }],
          filas: lineas.map((l) => [nombreProd.get(l.producto_id) || 'Producto', cantidad(l.cantidad),
            costoTexto(l.costo_unitario), dinero(l.subtotal_centavos), dinero(l.isv_centavos)]) }),
        h('div', { class: 'totales' },
          h('div', { class: 'fila' }, h('span', {}, 'Subtotal'), h('span', { class: 'monto', dataset: { dato: 'compra-subtotal' } }, dinero(c.subtotal_centavos))),
          h('div', { class: 'fila' }, h('span', {}, 'ISV (crédito fiscal)'), h('span', { class: 'monto', dataset: { dato: 'compra-isv' } }, dinero(c.isv_centavos))),
          h('div', { class: 'fila fila-total' }, h('span', {}, 'Total'), monto(dinero(c.total_centavos), { sentido: c.anulada_en ? null : 'sale', dato: 'compra-total' }))),
        doc ? h('div', { class: 'fila fila-total' }, h('span', {}, 'Todavía debe'), monto(dinero(doc.saldo_centavos), { sentido: 'sale', dato: 'compra-saldo' })) : null,
        h('div', { class: 'botones' },
          doc && puede('compras.pagar') ? h('button', { type: 'button', class: 'boton boton-principal', id: 'compra-pagar',
            onclick: () => formularioPago(vista, ctx, doc, { alVolver: () => verCompra(vista, ctx, compraId) }) }, icono('billetes'), 'Pagar') : null,
          !c.anulada_en && puede('compras.anular') && !vigentes.length ? h('button', { type: 'button', class: 'boton boton-peligro', id: 'compra-anular', onclick: anularCompra },
            icono('anular'), 'Anular compra') : null,
          h('button', { type: 'button', class: 'boton', onclick: volver }, 'Volver a la lista')),
        !c.anulada_en && puede('compras.anular') && vigentes.length ? h('p', { class: 'ayuda' }, 'Para anular esta compra, primero anule sus pagos (abajo).') : null),
      c.condicion === 'credito' ? h('section', { class: 'tarjeta', 'aria-labelledby': 't-pagos-compra' },
        titulo('h2', 'billetes', 'Pagos de esta compra', { id: 't-pagos-compra' }),
        pagos.length ? h('div', { class: 'lista-filas' }, pagos.map((p) => {
          const anulado = anulados.has(p.id);
          return filaIcono({ icono: 'billetes', color: anulado ? 'neutro' : 'verde',
            titulo: h('strong', {}, `Pago #${p.numero} · ${fecha(p.fecha_contable)}`),
            detalle: `Salió de ${cuentasLibro.get(p.cuenta_pago_id) || (p.forma_pago === 'banco' ? 'banco' : 'caja')}${p.referencia ? ' · ' + p.referencia : ''}`,
            derecha: [monto(dinero(p.monto_centavos), { sentido: anulado ? null : 'sale' }), anulado ? chipEstado('anulado') : chipEstado('aplicado')],
            abajo: !anulado && puede('compras.anular') ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-peligro',
              'aria-label': `Anular el pago #${p.numero}`, onclick: () => anularPago(p) }, 'Anular pago')) : null,
            props: { dataset: { pago: p.id } } });
        })) : estadoVacio({ icono: 'billetes', chico: true, texto: 'Todavía no tiene pagos.' })) : null].filter(Boolean));
  } catch (err) {
    vista.replaceChildren(await cajaError(err));
  }
}

// ---------------- Nueva compra ----------------
const TASAS = { ISV15: 15, ISV18: 18 };
const tasaDe = (p) => (p.impuesto_porcentaje !== null && p.impuesto_porcentaje !== undefined ? Number(p.impuesto_porcentaje) : TASAS[p.tipo_impuesto] || 0);

export async function formularioCompra(vista, ctx, { proveedorId = null } = {}) {
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let provs, bods, prods, cuentas;
  try {
    [provs, bods, prods, cuentas] = await Promise.all([proveedores(true), bodegas(),
      leer('v_producto', { empresa_id: empresaId(), activo: true, tipo: 'bien' }, { orden: 'nombre.asc', limite: 1000 }),
      tieneModulo('dinero') && puede('dinero.ver') ? cuentasDinero(true).then(cuentasQuePagan) : []]);
  } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  if (!ctx.sigueVigente()) return;
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  provs = provs.filter((p) => p.activo);
  if (!provs.length || !bods.length || !prods.length) {
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta' }, titulo('h1', 'compras', 'Nueva compra'),
      estadoVacio({ icono: !provs.length ? 'proveedor' : 'etiqueta', titulo: !provs.length ? 'Primero agregue un proveedor' : !bods.length ? 'Primero cree una bodega' : 'Primero cree sus productos',
        texto: !provs.length ? 'Cada compra es de un proveedor. Agréguelo una vez y luego solo lo elige.'
          : !bods.length ? 'Las compras entran a una bodega. Pídale al dueño que cree una.' : 'Las compras son de productos que se guardan en inventario.',
        botones: [!provs.length && hayEnMenu(ctx.menu || [], 'compras', 'proveedores') ? { texto: 'Agregar proveedor', href: '#/compras/proveedores', icono: 'mas' } : null,
          provs.length && !prods.length && hayEnMenu(ctx.menu || [], 'inventario', 'productos') ? { texto: 'Crear productos', href: '#/inventario/productos', icono: 'mas' } : null,
          { texto: 'Volver', onclick: volver }] })));
    return;
  }
  const id = nuevoId();
  const selProv = h('select', { id: 'compra-proveedor' }, h('option', { value: '' }, 'Elija el proveedor'), provs.map((p) => h('option', { value: p.id }, p.nombre)));
  if (proveedorId) selProv.value = proveedorId;
  const factura = h('input', { id: 'compra-factura', type: 'text', maxlength: 50, autocomplete: 'off', placeholder: 'Ej.: 000-001-01-00001234' });
  const fechaIn = inputFecha('compra-fecha', hoy(), { max: hoy() });
  const selBod = h('select', { id: 'compra-bodega' }, bods.map((b) => h('option', { value: b.id }, b.nombre)));
  // Líneas: se agregan buscando el producto (como en Vender).
  const lineas = [];
  const zonaLineas = h('div', { class: 'lista', id: 'compra-lineas' });
  const totales = h('div', { class: 'totales', id: 'compra-totales' });
  const buscar = h('input', { id: 'compra-buscar', type: 'search', placeholder: 'Nombre o código del producto', autocomplete: 'off' });
  const resultados = h('div', { class: 'resultados', id: 'compra-resultados' });
  const pintarResultados = () => {
    const q = buscar.value.trim();
    resultados.replaceChildren(...(q ? filtrar(prods, q, ['nombre', 'codigo', 'codigo_barras']).slice(0, 8).map((p) => h('button', { type: 'button',
      class: 'resultado-producto', dataset: { producto: p.producto_id }, onclick: () => { agregar(p); buscar.value = ''; pintarResultados(); buscar.focus(); } },
      h('span', {}, h('strong', {}, p.nombre), h('span', { class: 'detalle' }, ` · ${p.codigo} · ${p.impuesto || p.tipo_impuesto}`)))) : []));
    if (q && !resultados.children.length) resultados.append(h('p', { class: 'vacio' }, 'No hay productos con ese nombre.'));
  };
  buscar.addEventListener('input', pintarResultados);
  function agregar(p) {
    const ya = lineas.find((l) => l.p.producto_id === p.producto_id);
    if (ya) { ya.cant.focus(); return; }
    const n = lineas.length + 1;
    const l = { p,
      cant: h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', 'aria-label': `Cantidad de ${p.nombre}`, dataset: { campo: 'cantidad' } }),
      costo: h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: '0.00', 'aria-label': `Costo por unidad de ${p.nombre}`, dataset: { campo: 'costo' } }),
      isv: h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: 'Como lo calcula el sistema', 'aria-label': `ISV de la factura para ${p.nombre}`, dataset: { campo: 'isv' } }),
      sub: h('span', { class: 'monto', dataset: { dato: 'linea-subtotal' } }, dinero(0)) };
    l.nodo = h('div', { class: 'linea-carrito', dataset: { producto: p.producto_id } },
      h('div', { class: 'linea-nombre' }, h('strong', {}, p.nombre), h('span', { class: 'detalle' }, ` Código ${p.codigo} · ISV ${tasaDe(p)} %`)),
      h('div', { class: 'linea-datos' },
        campo(`Cantidad${p.unidad ? ' (' + p.unidad + ')' : ''}`, l.cant), campo('Costo por unidad sin ISV (L)', l.costo),
        h('div', { class: 'campo' }, h('span', { class: 'etiqueta-campo' }, 'Subtotal'), l.sub),
        h('button', { type: 'button', class: 'boton boton-quitar', 'aria-label': `Quitar ${p.nombre}`, onclick: () => quitar(l) }, icono('cerrar'))),
      h('details', { class: 'linea-isv' }, h('summary', {}, 'El ISV de la factura es distinto'),
        campo('ISV de esta línea según la factura (L)', l.isv, 'Solo si no cuadra con el papel por redondeo. Si lo deja vacío, lo calcula el sistema.')));
    for (const x of [l.cant, l.costo, l.isv]) x.addEventListener('input', recalcular);
    lineas.push(l);
    zonaLineas.append(l.nodo);
    recalcular();
    l.cant.focus();
    return n;
  }
  function quitar(l) { lineas.splice(lineas.indexOf(l), 1); l.nodo.remove(); recalcular(); }
  // Cuenta aproximada en pantalla (el núcleo hace la cuenta oficial al guardar y se muestra después).
  function cuenta() {
    let sub = 0, isv = 0;
    for (const l of lineas) {
      const q = aCantidad(l.cant.value), c = aCosto(l.costo.value);
      const s = q && c ? Math.round(q * c) : 0;
      const manual = l.isv.value.trim() === '' ? null : aCentavos(l.isv.value);
      l.sub.textContent = dinero(s);
      sub += s;
      isv += manual !== null && l.isv.value.trim() !== '' ? manual : Math.round((s * tasaDe(l.p)) / 100);
    }
    return { sub, isv, total: sub + isv };
  }
  function recalcular() {
    const t = cuenta();
    totales.replaceChildren(
      h('div', { class: 'fila' }, h('span', {}, 'Subtotal'), h('span', { class: 'monto' }, dinero(t.sub))),
      h('div', { class: 'fila' }, h('span', {}, 'ISV (aproximado)'), h('span', { class: 'monto' }, dinero(t.isv))),
      h('div', { class: 'fila fila-total' }, h('span', {}, 'Total aproximado'), h('span', { class: 'monto', dataset: { dato: 'compra-total-aprox' } }, dinero(t.total))),
      h('p', { class: 'ayuda' }, lineas.length ? 'El sistema confirma el ISV de cada producto al guardar.' : 'Busque y agregue los productos de la factura.'));
  }
  // Contado o crédito.
  const cond = { valor: 'credito' };
  const selCuenta = cuentas.length ? selectCuentas(cuentas, { id: 'compra-cuenta' }, { vacio: 'Elija de dónde sale el dinero' })
    : h('select', { id: 'compra-cuenta' }, h('option', { value: 'forma:caja' }, 'Caja general'), h('option', { value: 'forma:banco' }, 'Banco'));
  const vence = h('input', { id: 'compra-vence', type: 'date' });
  const zonaCond = h('div', {});
  const ayudaVence = h('p', { class: 'ayuda' });
  const plazo = () => { const p = provs.find((x) => x.id === selProv.value); return p ? Number(p.plazo_dias || 0) : 0; };
  const ponerVence = () => {
    vence.min = fechaIn.value;
    if (fechaIn.value) vence.value = sumarDias(fechaIn.value, plazo());
    ayudaVence.textContent = plazo() ? `Este proveedor le da ${plazo()} días de plazo.` : 'Este proveedor no tiene plazo guardado: escriba cuándo vence.';
  };
  selProv.addEventListener('change', ponerVence);
  fechaIn.addEventListener('change', ponerVence);
  const radio = (v, texto) => {
    const r = h('input', { type: 'radio', name: 'compra-condicion', value: v, checked: v === cond.valor });
    r.addEventListener('change', () => { cond.valor = v; pintarCond(); });
    return h('label', {}, r, ' ' + texto);
  };
  const lblCuenta = campo('¿De dónde sale el dinero?', selCuenta, cuentas.length ? 'El saldo de cada caja o banco sale al lado.' : null);
  const lblVence = h('div', {}, campo('¿Cuándo vence?', vence), ayudaVence);
  function pintarCond() { zonaCond.replaceChildren(cond.valor === 'contado' ? lblCuenta : lblVence); }
  const notas = h('input', { id: 'compra-notas', type: 'text', maxlength: 500 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'compra-guardar' }, 'Guardar compra');

  const form = h('form', { class: 'formulario', novalidate: true },
    h('div', { class: 'dos-columnas' }, campo('Proveedor', selProv), campo('Número de la factura', factura)),
    h('div', { class: 'dos-columnas' }, campo('Fecha de la factura', fechaIn), campo('¿A qué bodega entra?', selBod)),
    h('h2', { class: 'titulo-chico' }, 'Productos'),
    campo('Buscar producto', buscar), resultados, zonaLineas, totales,
    h('fieldset', { class: 'opciones' }, h('legend', {}, '¿Cómo la paga?'), radio('credito', 'Al crédito (pago después)'), radio('contado', 'De contado (pago ahora)')),
    zonaCond, campo('Notas (opcional)', notas), zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const falla = (t, q = '', foco = null) => { zonaError.append(errorSimple(t, q)); if (foco) foco.focus(); };
    if (!selProv.value) return falla('Elija el proveedor.', '', selProv);
    if (!factura.value.trim()) return falla('Escriba el número de la factura del proveedor.', 'Así no se registra dos veces la misma factura.', factura);
    if (!fechaIn.value) return falla('Escriba la fecha de la factura.', '', fechaIn);
    if (!lineas.length) return falla('Agregue al menos un producto.', 'Búsquelo por nombre o código.', buscar);
    const datosLineas = [];
    for (const l of lineas) {
      const q = aCantidad(l.cant.value), c = aCosto(l.costo.value);
      if (!q) return falla(textoMonto(l.cant, `Escriba la cantidad de ${l.p.nombre}.`), 'Un número mayor que cero.', l.cant);
      if (!l.p.permite_fracciones && !Number.isInteger(q)) return falla(`${l.p.nombre} se compra en unidades enteras.`, 'Quite los decimales.', l.cant);
      if (!c) return falla(textoMonto(l.costo, `Escriba el costo por unidad de ${l.p.nombre}.`), 'En lempiras, sin ISV. Ej.: 120 o 120.50', l.costo);
      const x = { producto_id: l.p.producto_id, cantidad: q, costo_unitario: c };
      if (l.isv.value.trim() !== '') {
        const isv = aCentavos(l.isv.value);
        if (isv === null) return falla(textoMonto(l.isv, `El ISV de ${l.p.nombre} no es un monto válido.`), 'Déjelo vacío para que lo calcule el sistema.', l.isv);
        x.isv_centavos = isv;
      }
      datosLineas.push(x);
    }
    const datos = { proveedor_id: selProv.value, bodega_id: selBod.value, numero_documento: factura.value.trim(), fecha: fechaIn.value,
      condicion: cond.valor, lineas: datosLineas };
    if (notas.value.trim()) datos.notas = notas.value.trim();
    let sale = '';
    if (cond.valor === 'contado') {
      if (!selCuenta.value) return falla('Elija de qué caja o banco sale el dinero.', '', selCuenta);
      if (selCuenta.value.startsWith('forma:')) { datos.forma_pago = selCuenta.value.slice(6); sale = datos.forma_pago === 'banco' ? 'el banco' : 'la caja general'; }
      else { datos.cuenta_dinero_id = selCuenta.value; sale = cuentas.find((c) => c.cuenta_dinero_id === selCuenta.value).nombre; }
    } else {
      if (!vence.value) return falla('Escriba cuándo vence la factura.', '', vence);
      if (vence.value < fechaIn.value) return falla('El vencimiento no puede ser antes de la fecha de la factura.', '', vence);
      datos.fecha_vencimiento = vence.value;
    }
    const prov = provs.find((p) => p.id === selProv.value);
    const t = cuenta();
    const ok = await confirmar({ titulo: '¿Guardar esta compra?', textoBoton: 'Sí, guardar compra',
      texto: `Compra a ${prov.nombre}, factura ${datos.numero_documento}: ${lineas.length} ${lineas.length === 1 ? 'producto' : 'productos'}. Total: ${dinero(t.total)} (subtotal ${dinero(t.sub)} + ISV ${dinero(t.isv)}; el sistema confirma el ISV al guardar). `
        + (cond.valor === 'contado' ? `Sale de ${sale}.` : `Al crédito: vence el ${fecha(vence.value)}.`)
        + ` Los productos entran a ${selBod.selectedOptions[0].textContent}.` });
    if (!ok) return;
    const r = await conBoton(boton, zonaError, () => escribir('registrar_compra', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: id }));
    if (!r) return;
    olvidarDatos('cuentas');
    const hecho = `Compra #${r.numero} guardada · ${dinero(r.total_centavos)} · ${cond.valor === 'contado' ? 'sale de ' + sale : 'al crédito, vence ' + fecha(datos.fecha_vencimiento)}`;
    aviso(hecho, 'ok', 7000);
    verCompra(vista, ctx, r.compra_id, { arriba: mensaje('ok', hecho,
      `Revise que cuadre con la factura de papel: subtotal ${dinero(r.subtotal_centavos)}, ISV ${dinero(r.isv_centavos)}, total ${dinero(r.total_centavos)}. Los productos ya entraron al inventario.`,
      { class: 'resultado', dataset: { info: 'compra-guardada' } }) });
  });

  pintarCond();
  ponerVence();
  recalcular();
  vista.replaceChildren(h('section', { class: 'tarjeta', 'aria-labelledby': 't-nueva-compra' },
    titulo('h1', 'compras', 'Nueva compra', { id: 't-nueva-compra' }),
    h('p', { class: 'ayuda' }, 'Copie los datos de la factura del proveedor. El costo va sin ISV; el sistema calcula el ISV de cada producto.'), form));
  (proveedorId ? factura : selProv).focus();
}
