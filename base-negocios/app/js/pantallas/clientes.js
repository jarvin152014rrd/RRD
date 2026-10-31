// Clientes · lista con búsqueda, ficha (estado de cuenta y antigüedad), cobrar abono
// (registrar_cobro: a la más vieja o eligiendo facturas; lo que sobra queda a favor solo si
// se confirma) y crear o editar cliente (límite y plazo solo con terceros.credito).
import { rpc, leer, escribir, nuevoId } from '../api.js';
import { empresaId, perfilActual, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha, aCentavos, paraCampo } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, enlaceWhatsApp, titulo, filaIcono, chip, chipEstado, monto as cifra, estadoVacio, mensaje, filtrosRapidos } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { clientes, filtrar, olvidarDatos, nucleoAlMenos } from '../datos.js';
import { nombreForma } from '../comprobante.js';
import { sinEmojis } from '../imprimible.js';

const verCxc = () => tieneModulo('ventas') && puede('ventas.ver');
// Saldos para cobrar (cxc_para_cobrar, núcleo 0.14.0): también el cajero, sin ventas.ver.
const verSaldos = () => tieneModulo('ventas') && puede('ventas.ver', 'cobros.ver_saldos');
const saldosParaCobrar = (clienteId = null) => rpc('cxc_para_cobrar', { p_empresa_id: empresaId(), p_cliente_id: clienteId });

export async function mostrar(vista, ctx) {
  const [lista, saldos] = await Promise.all([clientes(true),
    verCxc() ? leer('v_cxc_cliente', { empresa_id: empresaId() }, { limite: 1000 })
      : verSaldos() ? saldosParaCobrar().then((r) => r.clientes) : []]);
  if (!ctx.sigueVigente()) return;
  const porId = new Map(saldos.map((s) => [s.cliente_id, s]));
  const buscar = h('input', { id: 'buscar-cliente', type: 'search', placeholder: 'Nombre, RTN o teléfono', autocomplete: 'off' });
  const zona = h('div', { class: 'lista' });
  // App 0.15.0: filtros rápidos (Con atraso, Debe, Al día, Mayoristas). Solo cuentan clientes; los saldos son del servidor.
  // Sin permiso para ver saldos, solo sale "Mayoristas" (si hay).
  const verDeuda = saldos.length > 0 || verCxc() || verSaldos();
  const estadoDe = (c) => { const s = porId.get(c.id); return !s || !s.saldo_centavos ? 'al_dia' : s.vencido_centavos ? 'atraso' : 'debe'; };
  let filtro = 'todos';
  const activos = lista.filter((c) => c.activo);
  const n = (f) => activos.filter((c) => (f === 'mayorista' ? c.es_mayorista : estadoDe(c) === f)).length;
  const filtros = lista.length > 1 ? filtrosRapidos({ id: 'filtro-clientes', etiqueta: 'Ver clientes', actual: filtro,
    alCambiar: (f) => { filtro = f; pintar(); },
    opciones: [{ id: 'todos', texto: 'Todos', n: lista.length, siempre: true, color: 'azul' },
      ...(verDeuda ? [{ id: 'atraso', texto: 'Con atraso', n: n('atraso'), color: 'rojo' }, { id: 'debe', texto: 'Deben', n: n('debe'), color: 'dorado' },
        { id: 'al_dia', texto: 'Al día', n: n('al_dia'), color: 'verde' }] : []),
      { id: 'mayorista', texto: 'Mayoristas', n: n('mayorista'), color: 'azul' }] }) : null;
  const pintar = () => {
    const base = filtro === 'todos' ? lista : filtro === 'mayorista' ? activos.filter((c) => c.es_mayorista) : activos.filter((c) => estadoDe(c) === filtro);
    const vistos = filtrar(base, buscar.value, ['nombre', 'rtn', 'telefono', 'codigo']);
    zona.replaceChildren(...(vistos.length ? vistos.slice(0, 200).map((c) => {
      const s = porId.get(c.id);
      return filaIcono({
        icono: 'usuario', color: c.activo ? 'azul' : 'neutro',
        titulo: [h('strong', {}, c.nombre), c.es_mayorista ? [' ', chip('Mayorista', 'azul')] : null, !c.activo ? [' ', chipEstado('inactivo')] : null],
        detalle: [c.rtn ? 'RTN ' + c.rtn : null, c.telefono].filter(Boolean).join(' · ') || 'Sin RTN ni teléfono',
        derecha: s && s.saldo_centavos ? [cifra(dinero(s.saldo_centavos), { negativo: Boolean(s.vencido_centavos) }),
          chip(s.vencido_centavos ? 'Con atraso' : 'Debe', s.vencido_centavos ? 'rojo' : 'dorado')] : null,
        abajo: h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', 'aria-label': `Ver a ${c.nombre}`, onclick: () => abrirFicha(vista, ctx, c.id) }, 'Ver')),
        props: { dataset: { cliente: c.id } },
      });
    }) : [estadoVacio({ icono: 'buscar', chico: true, texto: 'No hay clientes con ese nombre.' })]));
  };
  buscar.addEventListener('input', pintar);
  pintar();
  const nuevo = () => formularioCliente(vista, ctx, null);
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cli' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'clientes', 'Clientes', { id: 't-cli' }),
      puede('terceros.editar') && lista.length ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nuevo-cliente',
        onclick: nuevo }, icono('mas'), 'Nuevo cliente') : null),
    // Sin clientes: enseña cómo empezar (solo con los botones que puede usar).
    lista.length ? [campo('Buscar', buscar), filtros, zona]
      : estadoVacio({ icono: 'clientes', titulo: 'Aún no tiene clientes',
        texto: 'Guarde a sus clientes para venderles al crédito, cobrarles y mandarles su comprobante por WhatsApp.',
        botones: [puede('terceros.editar') ? { texto: 'Agregar el primero', onclick: nuevo, icono: 'mas', id: 'nuevo-cliente' } : null,
          hayEnMenu(ctx.menu || [], 'ajustes', 'excel') ? { texto: 'Subir mi Excel', href: '#/ajustes/excel', icono: 'excel' } : null] })));
}

// Ficha del cliente. Con opciones.cobrar abre directo el cobro.
export async function abrirFicha(vista, ctx, clienteId, opciones = {}) {
  vista.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
  try {
    const [cli] = await leer('tercero', { id: clienteId });
    const [s] = verCxc() ? await leer('v_cxc_cliente', { empresa_id: empresaId(), cliente_id: clienteId }) : [];
    const ec = verCxc() ? await rpc('estado_cuenta_cliente', { p_empresa_id: empresaId(), p_cliente_id: clienteId }) : null;
    const cxc = verSaldos() && puede('ventas.cobrar') ? await saldosParaCobrar(clienteId) : null;
    const pendiente = cxc && cxc.clientes[0] ? cxc.clientes[0] : null; // lo que este usuario puede cobrar
    if (!ctx.sigueVigente()) return;
    if (opciones.cobrar) return formularioCobro(vista, ctx, cli, cxc);
    const volver = h('button', { type: 'button', class: 'boton', onclick: () => { vista.replaceChildren(); mostrar(vista, ctx); } }, 'Volver a la lista');
    const dato = (t, v) => (v || v === 0 ? h('div', { class: 'fila' }, h('span', {}, t), h('span', { class: 'dato-valor' }, v)) : null);
    const saldo = ec ? ec.saldo_actual_centavos : 0;
    vista.replaceChildren(...[
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-ficha' },
        h('div', { class: 'titulo-con-total' }, titulo('h1', 'usuario', cli.nombre, { id: 't-ficha' }),
          cli.es_mayorista ? chip('Mayorista', 'azul', { dataset: { dato: 'cliente-mayorista' } }) : null, cli.activo === false ? chipEstado('inactivo') : null),
        dato('Código', cli.codigo), dato('RTN', cli.rtn), dato('Teléfono', cli.telefono), dato('Correo', cli.correo), dato('Dirección', cli.direccion),
        dato('Límite de crédito', dinero(cli.limite_credito_centavos)), dato('Plazo', `${cli.plazo_dias || 0} días`),
        h('div', { class: 'botones' },
          puede('terceros.editar') ? h('button', { type: 'button', class: 'boton', onclick: () => formularioCliente(vista, ctx, cli) }, 'Editar') : null,
          pendiente ? h('button', { type: 'button', class: 'boton boton-principal', id: 'cobrar-abono',
            onclick: () => formularioCobro(vista, ctx, cli, cxc) }, icono('cobrar'), 'Cobrar abono') : null,
          volver)),
      // Sin ventas.ver (cajero): solo lo que debe, factura por factura, para cobrar.
      !ec && cxc ? h('section', { class: 'tarjeta', 'aria-labelledby': 't-pend' },
        titulo('h2', 'cobrar', 'Lo que debe', { id: 't-pend' }),
        h('div', { class: 'fila fila-total' }, h('span', {}, 'Debe'), cifra(dinero(pendiente ? pendiente.saldo_centavos : 0), { dato: 'saldo-cliente' })),
        pendiente ? pendiente.facturas.map((p) => filaFactura(p.numero_documento, p.fecha_documento, p.vence_el, p.dias_vencido, p.saldo_centavos))
          : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'No debe nada.' }),
        cxc.todas_las_sucursales ? null : h('p', { class: 'ayuda' }, 'Solo se ven las facturas de su sucursal.')) : null,
      ec ? h('section', { class: 'tarjeta', 'aria-labelledby': 't-ec' },
        titulo('h2', 'documento', 'Estado de cuenta', { id: 't-ec' }),
        h('div', { class: 'cifras' },
          h('div', { class: 'cifra-chica' }, h('p', { class: 'cifra-titulo' }, 'Debe'), h('p', { class: 'cifra-valor', dataset: { dato: 'saldo-cliente' } }, dinero(saldo))),
          h('div', { class: 'cifra-chica' }, h('p', { class: 'cifra-titulo' }, 'Vencido'), h('p', { class: 'cifra-valor' + (s && s.vencido_centavos ? ' monto-sale' : '') }, dinero(s ? s.vencido_centavos : 0))),
          h('div', { class: 'cifra-chica' }, h('p', { class: 'cifra-titulo' }, 'Saldo a favor'), h('p', { class: 'cifra-valor' + (ec.saldo_favor_centavos ? ' monto-entra' : ''), dataset: { dato: 'saldo-favor' } }, dinero(ec.saldo_favor_centavos)))),
        s ? h('div', { class: 'antiguedad' }, [['0 a 30 días', s.de_0_a_30], ['31 a 60', s.de_31_a_60], ['61 a 90', s.de_61_a_90], ['Más de 90', s.mas_de_90]]
          .map(([t, v]) => h('div', {}, h('span', { class: 'detalle' }, t), h('span', { class: 'monto' }, dinero(v))))) : null,
        h('h3', { class: 'titulo-chico' }, 'Facturas pendientes'),
        ec.pendientes.length ? ec.pendientes.map((p) => filaFactura(p.documento, p.fecha, p.vence_el, p.dias_vencido, p.saldo_centavos))
          : estadoVacio({ icono: 'check_circulo', color: 'verde', chico: true, texto: 'No debe nada.' }),
        h('h3', { class: 'titulo-chico' }, 'Movimientos'),
        // Abono = entra dinero (verde). Cargo = vendió al crédito (lo que debe sube).
        ec.movimientos.length ? ec.movimientos.slice(-30).reverse().map((m) => h('div', { class: 'fila' },
          h('span', {}, `${m.documento || ''} ${m.referencia ? '· ' + m.referencia : ''}`, h('span', { class: 'detalle' }, fecha(m.fecha))),
          m.cargo_centavos ? cifra(dinero(m.cargo_centavos), { signo: '+' }) : cifra(dinero(m.abono_centavos), { signo: '-', sentido: 'entra' })))
          : h('p', { class: 'vacio' }, 'Sin movimientos todavía.')) : null].filter(Boolean));
  } catch (err) {
    vista.replaceChildren(await cajaError(err));
  }
}

async function formularioCobro(vista, ctx, cli, cxc) {
  // Núcleo 0.18.0: también con cheque (número, banco que lo emitió y fecha; puede ser posfechado).
  const conCheque = await nucleoAlMenos('0.18.0');
  const pend = (cxc && cxc.clientes[0]) || { saldo_centavos: 0, facturas: [] };
  const deuda = pend.saldo_centavos;
  // Restringido por sucursal: el cobro se aplica solo a las facturas que ve (la más vieja primero).
  const soloLasMias = cxc && !cxc.todas_las_sucursales;
  const formas = ['efectivo', 'tarjeta', 'transferencia', ...(conCheque ? ['cheque'] : [])];
  const monto = h('input', { id: 'abono-monto', type: 'text', inputmode: 'decimal', autocomplete: 'off', value: paraCampo(deuda) });
  const selForma = h('select', { id: 'abono-forma' }, formas.map((f) => h('option', { value: f }, nombreForma(f))));
  const referencia = h('input', { id: 'abono-referencia', type: 'text', maxlength: 100 });
  const chNumero = h('input', { id: 'cheque-numero', type: 'text', maxlength: 30, inputmode: 'numeric' });
  const chBanco = h('input', { id: 'cheque-banco-emisor', type: 'text', maxlength: 100, placeholder: 'Ej.: Banco Atlántida' });
  const chFecha = h('input', { id: 'cheque-fecha', type: 'date', value: perfilActual().empresa.hoy || '' });
  const zonaCheque = h('fieldset', { class: 'grupo-campos', hidden: true }, h('legend', {}, 'Datos del cheque'),
    campo('Número del cheque', chNumero), campo('Banco que lo emitió', chBanco),
    campo('Fecha del cheque', chFecha, 'Si es posfechado, ponga la fecha escrita en el cheque: se deposita desde ese día.'),
    h('p', { class: 'ayuda' }, 'El cheque no es efectivo: queda en "Cheques por depositar" hasta que se deposita. Si rebota, el cliente vuelve a deber.'));
  selForma.addEventListener('change', () => { zonaCheque.hidden = selForma.value !== 'cheque'; revisar(); });
  const elegir = h('input', { type: 'checkbox', id: 'abono-elegir' });
  const zonaFacturas = h('div', { class: 'lista', hidden: true });
  const excedente = h('input', { type: 'checkbox', id: 'abono-excedente' });
  const zonaExcedente = h('label', { class: 'mensaje mensaje-info confirmar-excedente', hidden: true }, excedente, h('span', {}));
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Cobrar');
  const id = nuevoId();
  // Facturas pendientes (la más vieja primero) con el monto a aplicar.
  const docs = pend.facturas.map((d) => ({ d, si: h('input', { type: 'checkbox' }),
    x: h('input', { type: 'text', inputmode: 'decimal', value: paraCampo(d.saldo_centavos), 'aria-label': `Monto para ${d.numero_documento}` }) }));
  zonaFacturas.replaceChildren(...docs.map(({ d, si, x }) => h('div', { class: 'linea-devolver' },
    h('label', {}, si, ` ${d.numero_documento} · ${fecha(d.fecha_documento)}`, h('span', { class: 'detalle' }, `Saldo ${dinero(d.saldo_centavos)}`)), x)));
  elegir.addEventListener('change', () => { zonaFacturas.hidden = !elegir.checked; revisar(); });
  monto.addEventListener('input', revisar);
  // ¿Sobra? Se pide confirmar que lo que sobra quede a favor del cliente.
  function aplicarElegido() {
    return docs.filter((x) => x.si.checked).reduce((s, x) => s + (aCentavos(x.x.value) || 0), 0);
  }
  function revisar() {
    const m = aCentavos(monto.value) || 0;
    const tope = elegir.checked ? aplicarElegido() : deuda;
    const sobra = m - tope;
    zonaExcedente.hidden = !(sobra > 0) || selForma.value === 'cheque';
    zonaExcedente.lastChild.textContent = ` Recibe ${dinero(m)} y debe ${dinero(tope)}: los ${dinero(Math.max(sobra, 0))} que sobran quedan como saldo a favor de ${cli.nombre}.`;
  }
  zonaFacturas.addEventListener('input', revisar);
  zonaFacturas.addEventListener('change', revisar);
  const form = h('form', { class: 'formulario', novalidate: true },
    h('p', {}, `Debe ${dinero(deuda)}.`),
    campo('Monto que paga (L)', monto), campo('Forma de pago', selForma), zonaCheque, campo('Referencia (opcional)', referencia),
    h('label', { class: 'opcion-check' }, elegir, ' Elegir a qué facturas va (si no, a la más vieja primero)'),
    zonaFacturas, zonaExcedente, zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => abrirFicha(vista, ctx, cli.id) }, 'Volver'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const m = aCentavos(monto.value);
    if (!m) { zonaError.append(errorSimple('Escriba el monto que paga.')); return; }
    const pago = { forma: selForma.value, monto_centavos: m };
    if (selForma.value === 'cheque') {
      const tope = elegir.checked ? aplicarElegido() : deuda;
      if (m > tope) { zonaError.append(errorSimple(`Con cheque se cobra hasta lo que debe (${dinero(tope)}).`, 'Un cheque no deja saldo a favor: si rebota no habría con qué devolverlo.')); return; }
      if (!chNumero.value.trim() || chBanco.value.trim().length < 2 || !chFecha.value) {
        zonaError.append(errorSimple('Escriba el número del cheque, el banco que lo emitió y la fecha del cheque.')); return;
      }
      Object.assign(pago, { numero_cheque: chNumero.value.trim(), banco_emisor: chBanco.value.trim(), fecha_cheque: chFecha.value });
    }
    if (referencia.value.trim()) pago.referencia = referencia.value.trim();
    const datos = { cliente_id: cli.id, pagos: [pago] };
    if (elegir.checked) {
      const ap = docs.filter((x) => x.si.checked).map((x) => ({ ...(x.d.origen === 'saldo_inicial' ? { saldo_inicial_id: x.d.documento_id } : { venta_id: x.d.venta_id }),
        monto_centavos: aCentavos(x.x.value) }));
      if (!ap.length || ap.some((a) => !a.monto_centavos)) { zonaError.append(errorSimple('Marque las facturas y escriba cuánto va a cada una.')); return; }
      datos.aplicar = ap;
    } else if (soloLasMias) {
      // A la más vieja primero, pero solo entre las facturas de su sucursal.
      let resta = Math.min(m, deuda);
      datos.aplicar = [];
      for (const { d } of docs) {
        if (resta <= 0) break;
        const va = Math.min(resta, d.saldo_centavos);
        datos.aplicar.push({ ...(d.origen === 'saldo_inicial' ? { saldo_inicial_id: d.documento_id } : { venta_id: d.venta_id }), monto_centavos: va });
        resta -= va;
      }
    }
    if (!zonaExcedente.hidden) {
      if (!excedente.checked) { zonaError.append(errorSimple('Lo que paga es más de lo que debe.', 'Marque la casilla si lo que sobra queda a su favor, o baje el monto.')); return; }
      datos.excedente = 'saldo_favor';
    }
    const r = await conBoton(boton, zonaError, () => escribir('registrar_cobro', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: id }), 'Cobrando…');
    if (!r) return;
    const hecho = `Cobro #${r.numero} guardado · ${dinero(r.monto_centavos)} en ${nombreForma(selForma.value).toLowerCase()}`;
    // saldo_cliente_centavos es de TODA la empresa: a quien solo ve su sucursal se le muestra lo que
    // queda de lo que él ve (lo que debía en su sucursal menos lo aplicado ahora).
    const queda = soloLasMias ? Math.max(0, deuda - (r.aplicado_centavos || 0)) : r.saldo_cliente_centavos;
    const textoQueda = soloLasMias ? 'Todavía debe en su sucursal' : 'Todavía debe';
    aviso(hecho);
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-cobok' },
      titulo('h1', 'cobrar', `Cobro #${r.numero} de ${cli.nombre}`, { id: 't-cobok' }),
      mensaje('ok', hecho, queda ? `${textoQueda} ${dinero(queda)}.` : soloLasMias ? 'Ya no debe nada en su sucursal.' : 'Ya no debe nada.', { class: 'resultado' }),
      h('div', { class: 'fila' }, h('span', {}, 'Recibido'), cifra(dinero(r.monto_centavos), { sentido: 'entra' })),
      h('div', { class: 'fila' }, h('span', {}, 'Aplicado a facturas'), h('span', { class: 'monto', dataset: { dato: 'aplicado' } }, dinero(r.aplicado_centavos))),
      (r.aplicaciones || []).map((a) => h('div', { class: 'fila' }, h('span', { class: 'detalle' }, a.documento), h('span', { class: 'monto' }, dinero(a.monto_centavos)))),
      r.excedente_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Queda a su favor'), h('span', { class: 'monto', dataset: { dato: 'excedente' } }, dinero(r.excedente_centavos))) : null,
      r.vuelto_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Vuelto'), h('span', { class: 'monto' }, dinero(r.vuelto_centavos))) : null,
      h('div', { class: 'fila fila-total' }, h('span', {}, textoQueda), h('span', { class: 'monto', dataset: { dato: 'saldo-restante' } }, dinero(queda))),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => abrirFicha(vista, ctx, cli.id) }, 'Ver la ficha'))));
  });
  revisar();
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-abono' },
    titulo('h1', 'cobrar', `Cobrar a ${cli.nombre}`, { id: 't-abono' }), form));
}

// Crear (cli = null) o editar un cliente.
async function formularioCliente(vista, ctx, cli) {
  const credito = puede('terceros.credito');
  // Cliente mayorista (núcleo 0.18.0): lo marca quien cambia precios (productos.precios).
  const marcaMayorista = puede('productos.precios') && await nucleoAlMenos('0.18.0');
  const mayorista = h('input', { type: 'checkbox', id: 'cli-mayorista', checked: Boolean(cli && cli.es_mayorista) });
  const v = (k) => (cli && cli[k] !== null && cli[k] !== undefined ? String(cli[k]) : '');
  const f = {
    nombre: h('input', { id: 'cli-nombre', type: 'text', maxlength: 200, required: true, value: v('nombre') }),
    rtn: h('input', { id: 'cli-rtn', type: 'text', inputmode: 'numeric', maxlength: 20, value: v('rtn') }),
    telefono: h('input', { id: 'cli-telefono', type: 'tel', maxlength: 20, value: v('telefono') }),
    correo: h('input', { id: 'cli-correo', type: 'email', maxlength: 200, value: v('correo') }),
    direccion: h('input', { id: 'cli-direccion', type: 'text', maxlength: 300, value: v('direccion') }),
    limite: h('input', { id: 'cli-limite', type: 'text', inputmode: 'decimal', value: cli ? paraCampo(cli.limite_credito_centavos) : '' }),
    plazo: h('input', { id: 'cli-plazo', type: 'number', min: '0', max: '365', step: '1', value: v('plazo_dias') }),
  };
  const motivo = h('input', { id: 'cli-motivo', type: 'text', maxlength: 300 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, cli ? 'Guardar cambios' : 'Crear cliente');
  const id = nuevoId();
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Nombre', f.nombre), campo('RTN (opcional)', f.rtn, '14 números. Puede escribirlo con guiones.'),
    campo('Teléfono (opcional)', f.telefono), campo('Correo (opcional)', f.correo), campo('Dirección (opcional)', f.direccion),
    credito ? campo('Límite de crédito (L)', f.limite, '0 = sin crédito directo (cada venta al crédito pide aprobación).') : null,
    credito ? campo('Plazo para pagar (días)', f.plazo) : null,
    marcaMayorista ? h('label', { class: 'opcion-check' }, mayorista, ' Cliente mayorista (paga el precio mayorista de los productos que lo tienen)') : null,
    cli ? campo('Motivo del cambio', motivo, 'Pídalo si cambia el crédito. Queda en la bitácora.') : null,
    zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => (cli ? abrirFicha(vista, ctx, cli.id) : (vista.replaceChildren(), mostrar(vista, ctx))) }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const datos = {};
    const nombre = f.nombre.value.trim();
    if (nombre.length < 2) { zonaError.append(errorSimple('Escriba el nombre del cliente.')); return; }
    const rtn = f.rtn.value.replace(/\D/g, '');
    if (rtn && rtn.length !== 14) { zonaError.append(errorSimple('El RTN debe tener 14 números.', `Tiene ${rtn.length}. Revíselo.`)); return; }
    const tel = f.telefono.value.replace(/\D/g, '');
    if (tel && (tel.length < 8 || tel.length > 15)) { zonaError.append(errorSimple('El teléfono debe tener de 8 a 15 números.')); return; }
    const pon = (k, val, antes) => {
      if (!cli) { if (val !== '') datos[k] = val; return; }
      if (String(val ?? '') !== String(antes ?? '')) datos[k] = val === '' ? null : val;
    };
    pon('nombre', nombre, cli && cli.nombre);
    pon('rtn', rtn, cli && cli.rtn);
    pon('telefono', tel, cli && cli.telefono);
    pon('correo', f.correo.value.trim(), cli && cli.correo);
    pon('direccion', f.direccion.value.trim(), cli && cli.direccion);
    if (credito) {
      const lim = f.limite.value.trim() === '' ? 0 : aCentavos(f.limite.value);
      if (lim === null) { zonaError.append(errorSimple('El límite de crédito no es un monto válido.')); return; }
      const plazo = f.plazo.value === '' ? 0 : Number(f.plazo.value);
      if (!Number.isInteger(plazo) || plazo < 0 || plazo > 365) { zonaError.append(errorSimple('El plazo va de 0 a 365 días.')); return; }
      if (!cli || lim !== Number(cli.limite_credito_centavos)) datos.limite_credito_centavos = lim;
      if (!cli || plazo !== Number(cli.plazo_dias || 0)) datos.plazo_dias = plazo;
    }
    if (marcaMayorista && mayorista.checked !== Boolean(cli && cli.es_mayorista)) datos.es_mayorista = mayorista.checked;
    if (cli && !Object.keys(datos).length) { abrirFicha(vista, ctx, cli.id); return; }
    const r = await conBoton(boton, zonaError, () => (cli
      ? rpc('editar_tercero', { p_empresa_id: empresaId(), p_tercero_id: cli.id, p_datos: datos, p_motivo: motivo.value.trim() || null })
      : escribir('crear_tercero', { p_empresa_id: empresaId(), p_datos: { ...datos, es_cliente: true }, p_id_operacion: id })));
    if (!r) return;
    olvidarDatos('clientes');
    aviso(cli ? `Cliente guardado · ${nombre}` : `Cliente creado · ${nombre}`);
    abrirFicha(vista, ctx, cli ? cli.id : r.tercero_id);
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-fcli' },
    titulo('h1', cli ? 'editar' : 'cliente_mas', cli ? `Editar ${cli.nombre}` : 'Nuevo cliente', { id: 't-fcli' }), form));
  f.nombre.focus();
}

// Una factura pendiente: número, fechas, chip "Vencida" (rojo) o "Pendiente" (dorado) y su saldo.
function filaFactura(numero, fechaDoc, vence, diasVencido, saldo) {
  const vencida = diasVencido > 0;
  return h('div', { class: 'fila' },
    h('span', {}, numero, ' ', vencida ? chipEstado('vencida', `Vencida hace ${diasVencido} días`) : chipEstado('pendiente'),
      h('span', { class: 'detalle' }, `${fecha(fechaDoc)} · vence ${fecha(vence)}`)),
    cifra(dinero(saldo), { negativo: vencida }));
}

// Mensaje amable para cobrar por WhatsApp.
export function mensajeCobro(nombre, saldo, vencido) {
  const negocio = perfilActual().empresa.nombre;
  return sinEmojis(`Hola ${nombre}, le saluda ${negocio}. Le recordamos con cariño que tiene un saldo pendiente de ${dinero(saldo)}`
    + (vencido > 0 ? ` (de eso, ${dinero(vencido)} ya venció)` : '')
    + '. Puede pasar a pagar o responder este mensaje para coordinar. ¡Muchas gracias por su preferencia!');
}
export { enlaceWhatsApp };
