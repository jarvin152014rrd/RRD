// Dinero · "Todos los gastos" (app 0.7.0): lista de los gastos de la empresa (v_gasto: con dinero.ver
// todos; si no, los que uno pidió) con filtros por fecha, categoría y cuenta, y registrar un gasto
// pagado desde CUALQUIER caja o banco (registrar_gasto). Respeta los topes del núcleo: si el gasto pasa
// el tope del puesto queda "en espera de aprobación" y el dinero no sale hasta que lo aprueben.
// (Caja > "Gasto pagado de esta caja" es el atajo del cajero para la caja chica.)
import { leer, escribir, nuevoId, subirComprobante, usuarioActual, config } from '../api.js';
import { empresaId, puede, perfilActual } from '../sesion.js';
import { dinero, fecha, aCentavos, sumarDias } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, conBoton, confirmar, pedirMotivo, titulo, filaIcono, chipEstado, monto,
  estadoVacio, mensaje } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { cuentasDinero, cuentasQuePagan, categoriasGasto, proveedores, olvidarDatos, reiniciarAlSalir } from '../datos.js';
import { hoy, selectCuentas, inputMonto, inputFecha, cifraChica, textoMonto } from '../formularios.js';

const filtros = { desde: null, hasta: null, categoria: '', cuenta: '' };
reiniciarAlSalir(() => Object.assign(filtros, { desde: null, hasta: null, categoria: '', cuenta: '' }));
const LIMITE = 300;
// Registrar pide gastos.registrar Y poder ver las cajas (dinero.ver): sin eso no hay de dónde elegir.
const puedeRegistrar = () => puede('gastos.registrar') && puede('dinero.ver');
const ESTADO = { aplicado: ['aplicado', 'Pagado'], pendiente_aprobacion: ['pendiente_aprobacion', null], rechazado: ['rechazado', null], anulado: ['anulado', null] };

export async function mostrar(vista, ctx) {
  // La lista es de toda la empresa: pide dinero.ver. Quien solo puede registrar no tiene de dónde elegir la caja.
  if (!puede('dinero.ver')) {
    vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-gastos' }, titulo('h1', 'recibo', 'Todos los gastos', { id: 't-gastos' }),
      mensaje('info', 'Le falta el permiso para ver las cajas y bancos.', 'Para ver los gastos y registrar uno desde cualquier caja o banco, pídale al dueño el permiso de ver el dinero.', { dataset: { info: 'sin-dinero-ver' } })));
    return;
  }
  const [cats, cuentas] = await Promise.all([categoriasGasto(true), cuentasDinero(true)]);
  if (!ctx.sigueVigente()) return;
  if (!filtros.desde) { filtros.desde = sumarDias(hoy(), -30); filtros.hasta = hoy(); }
  const desde = inputFecha('gastos-desde', filtros.desde);
  const hasta = inputFecha('gastos-hasta', filtros.hasta);
  const selCat = h('select', { id: 'gastos-categoria' }, h('option', { value: '' }, 'Todas las categorías'), cats.map((c) => h('option', { value: c.id }, c.nombre)));
  const selCta = h('select', { id: 'gastos-cuenta' }, h('option', { value: '' }, 'Todas las cajas y bancos'),
    cuentasQuePagan(cuentas).map((c) => h('option', { value: c.cuenta_dinero_id }, c.nombre)));
  selCat.value = filtros.categoria; selCta.value = filtros.cuenta;
  const resumen = h('div', { class: 'cifras' });
  const tope = h('div', {});
  const zona = h('div', {});
  const yo = (usuarioActual() || {}).id;

  async function cargar() {
    Object.assign(filtros, { desde: desde.value, hasta: hasta.value, categoria: selCat.value, cuenta: selCta.value });
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    const f = { empresa_id: empresaId(), fecha_contable: { gte: filtros.desde || '2000-01-01', lte: filtros.hasta || '2100-12-31' } };
    if (filtros.categoria) f.categoria_id = filtros.categoria;
    if (filtros.cuenta) f.cuenta_dinero_id = filtros.cuenta;
    let gastos;
    try { gastos = await leer('v_gasto', f, { orden: 'numero.desc', limite: LIMITE }); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    tope.replaceChildren(gastos.length >= LIMITE ? mensaje('info', `Se muestran los últimos ${LIMITE} gastos y las cifras suman solo esos.`, 'Acorte las fechas para ver el total exacto.', { dataset: { info: 'tope-filas' } }) : '');
    const suma = (e) => gastos.filter((g) => g.estado === e).reduce((s, g) => s + Number(g.monto_centavos), 0);
    resumen.replaceChildren(cifraChica('Gastado en estas fechas', dinero(suma('aplicado')), { dato: 'gastos-total', clase: 'monto-sale' }),
      cifraChica('En espera de aprobación', dinero(suma('pendiente_aprobacion')), { dato: 'gastos-espera' }),
      cifraChica('Gastos', String(gastos.length)));
    zona.replaceChildren(gastos.length ? h('div', { class: 'lista-filas', id: 'lista-gastos' }, gastos.map((g) => {
      const [est, txt] = ESTADO[g.estado] || [g.estado, null];
      const puedeAnular = (g.estado === 'aplicado' && puede('gastos.anular'))
        || (g.estado === 'pendiente_aprobacion' && (puede('gastos.anular') || g.creado_por === yo));
      return filaIcono({
        icono: 'recibo', color: g.estado === 'aplicado' ? 'azul' : g.estado === 'pendiente_aprobacion' ? 'dorado' : 'neutro',
        titulo: h('strong', {}, `Gasto #${g.numero} · ${g.descripcion}`),
        detalle: [fecha(g.fecha_contable), g.categoria, g.cuenta_dinero ? `sale de ${g.cuenta_dinero}` : null,
          g.numero_documento ? `factura ${g.numero_documento}` : null, g.registrado_por ? `por ${g.registrado_por}` : null].filter(Boolean).join(' · '),
        derecha: [monto(dinero(g.monto_centavos), { sentido: g.estado === 'aplicado' ? 'sale' : null }), chipEstado(est, txt)],
        abajo: puedeAnular ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-peligro',
          'aria-label': `${g.estado === 'aplicado' ? 'Anular' : 'Cancelar'} el gasto #${g.numero}`, onclick: () => anular(g) },
        g.estado === 'aplicado' ? 'Anular' : 'Cancelar solicitud')) : null,
        props: { dataset: { gasto: g.gasto_id, estado: g.estado } },
      });
    })) : estadoVacio({ icono: 'buscar', chico: true, texto: 'No hay gastos con esos filtros. Pruebe con otras fechas o con "Todas".' }));
  }
  function anular(g) {
    const idOp = nuevoId();
    const aplicado = g.estado === 'aplicado';
    pedirMotivo({ titulo: aplicado ? `Anular el gasto #${g.numero}` : `Cancelar la solicitud del gasto #${g.numero}`, peligro: true,
      textoBoton: aplicado ? 'Sí, anular' : 'Sí, cancelar',
      explicacion: aplicado ? `Nada se borra: los ${dinero(g.monto_centavos)} vuelven a ${g.cuenta_dinero || 'su cuenta'}.` : 'Todavía no salió dinero; la solicitud queda cancelada.',
      accion: (motivo) => escribir('anular_gasto', { p_gasto_id: g.gasto_id, p_motivo: motivo, p_id_operacion: idOp }),
    }).then((ok) => {
      if (!ok) return;
      olvidarDatos('cuentas');
      window.dispatchEvent(new Event('pendientes-cambiaron'));
      aviso(aplicado ? `Gasto #${g.numero} anulado · ${dinero(g.monto_centavos)} volvieron a ${g.cuenta_dinero || 'su cuenta'}` : `Solicitud del gasto #${g.numero} cancelada`, 'ok', 7000);
      cargar();
    });
  }
  for (const x of [desde, hasta, selCat, selCta]) x.addEventListener('change', cargar);
  const nuevo = () => formularioGasto(vista, ctx);
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-gastos' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'recibo', 'Todos los gastos', { id: 't-gastos' }),
      puedeRegistrar() && cats.length ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nuevo-gasto', onclick: nuevo }, icono('mas'), 'Registrar un gasto') : null),
    !cats.length ? estadoVacio({ icono: 'recibo', titulo: 'Primero cree sus categorías de gasto',
      texto: 'Las categorías dicen en qué se gasta (alquiler, luz, planilla, papelería). Se crean una vez en Ajustes.',
      boton: hayEnMenu(ctx.menu || [], 'ajustes', 'cajas') ? { texto: 'Ir a Ajustes', href: '#/ajustes/cajas', icono: 'ajustes' } : null })
      : [h('div', { class: 'dos-columnas filtros' }, campo('Desde', desde), campo('Hasta', hasta), campo('Categoría', selCat),
        cuentas.length ? campo('Caja o banco', selCta) : null), tope, resumen, zona]));
  if (cats.length) await cargar();
}

// Registrar un gasto pagado desde cualquier caja o banco.
export async function formularioGasto(vista, ctx) {
  vista.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
  let cats, cuentas, provs, impuestos;
  try {
    [cats, cuentas, provs, impuestos] = await Promise.all([categoriasGasto(true), cuentasDinero(true).then(cuentasQuePagan),
      puede('terceros.ver') ? proveedores() : [], leer('impuesto', { empresa_id: empresaId(), activo: true, clase: 'gravado' }, { orden: 'orden.asc' })]);
  } catch (err) { vista.replaceChildren(await cajaError(err)); return; }
  if (!ctx.sigueVigente()) return;
  const volver = () => { vista.replaceChildren(); mostrar(vista, ctx); };
  if (!cuentas.length) {
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta' }, titulo('h1', 'recibo', 'Registrar un gasto'),
      estadoVacio({ icono: 'banco', titulo: 'Primero guarde sus cajas y bancos', texto: 'Todo gasto dice de qué caja o banco sale.',
        botones: [hayEnMenu(ctx.menu || [], 'ajustes', 'cajas') ? { texto: 'Agregar caja o banco', href: '#/ajustes/cajas', icono: 'mas' } : null,
          { texto: 'Volver', onclick: volver }] })));
    return;
  }
  const id = nuevoId();
  const selCuenta = selectCuentas(cuentas, { id: 'gasto-cuenta' }, { vacio: 'Elija de dónde sale el dinero' });
  const selCat = h('select', { id: 'gasto-categoria' }, h('option', { value: '' }, 'Elija la categoría'), cats.map((c) => h('option', { value: c.id }, c.nombre)));
  const montoIn = inputMonto('gasto-monto');
  const desc = h('input', { id: 'gasto-descripcion', type: 'text', maxlength: 300, placeholder: 'Ej.: Energía eléctrica de octubre' });
  const fechaIn = inputFecha('gasto-fecha', hoy(), { max: hoy() });
  const selProv = h('select', { id: 'gasto-proveedor' }, h('option', { value: '' }, 'Sin proveedor'),
    provs.filter((p) => p.activo).map((p) => h('option', { value: p.id }, p.nombre)));
  const conFactura = h('input', { type: 'checkbox', id: 'gasto-con-factura' });
  const numFactura = h('input', { id: 'gasto-factura', type: 'text', maxlength: 50 });
  const rtn = h('input', { id: 'gasto-rtn', type: 'text', inputmode: 'numeric', maxlength: 20 });
  const selImp = h('select', { id: 'gasto-impuesto' }, impuestos.map((i) => h('option', { value: i.codigo }, `${i.nombre} (incluido en el total)`)));
  const zonaFactura = h('div', { class: 'grupo-campos', hidden: true },
    campo('Número de la factura', numFactura), campo('RTN de quien la emitió', rtn, 'Si eligió un proveedor con RTN, puede dejarlo vacío.'),
    impuestos.length ? campo('Impuesto de la factura', selImp, 'El sistema separa el ISV del total (crédito fiscal).') : null);
  conFactura.addEventListener('change', () => { zonaFactura.hidden = !conFactura.checked; });
  const foto = h('input', { id: 'gasto-foto', type: 'file', accept: 'image/*,application/pdf', capture: 'environment' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'gasto-guardar' }, 'Guardar gasto');
  const dueno = perfilActual().rol && perfilActual().rol.codigo === 'dueno';
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('¿De dónde sale el dinero?', selCuenta, 'Caja, caja chica o banco. El saldo de cada una sale al lado.'),
    campo('¿En qué se gastó?', selCat), campo('Monto total pagado (L)', montoIn), campo('Descripción', desc),
    h('div', { class: 'dos-columnas' }, campo('Fecha', fechaIn), provs.length ? campo('Proveedor (opcional)', selProv) : null),
    h('label', { class: 'opcion-check' }, conFactura, ' Tengo factura con ISV (para el crédito fiscal)'), zonaFactura,
    campo('Foto del comprobante (opcional)', foto, config.bucketComprobantes ? null : 'Por ahora se guarda solo el nombre de la foto como referencia.'),
    dueno ? null : mensaje('info', 'Si el gasto pasa su tope, queda en espera de aprobación.', 'El dinero no sale hasta que el dueño o un administrador lo apruebe.'),
    zonaError, boton, h('button', { type: 'button', class: 'boton boton-ancho', onclick: volver }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const falla = (t, q = '', foco = null) => { zonaError.append(errorSimple(t, q)); if (foco) foco.focus(); };
    if (!selCuenta.value) return falla('Elija de qué caja o banco sale el dinero.', '', selCuenta);
    if (!selCat.value) return falla('Elija en qué se gastó (categoría).', '', selCat);
    const m = aCentavos(montoIn.value);
    if (!m) return falla(textoMonto(montoIn, 'Escriba el monto.'), 'Solo números, por ejemplo 1150 o 1150.50', montoIn);
    if (desc.value.trim().length < 3) return falla('Escriba de qué es el gasto (descripción).', '', desc);
    if (!fechaIn.value) return falla('Escriba la fecha del gasto.', '', fechaIn);
    const datos = { cuenta_dinero_id: selCuenta.value, categoria_id: selCat.value, monto_centavos: m, descripcion: desc.value.trim(), fecha: fechaIn.value };
    if (selProv.value) datos.proveedor_id = selProv.value;
    if (conFactura.checked) {
      if (!numFactura.value.trim()) return falla('Escriba el número de la factura.', 'Sin número no se puede tomar el ISV.', numFactura);
      const r = rtn.value.replace(/\D/g, '');
      const prov = provs.find((p) => p.id === selProv.value);
      if (r && r.length !== 14) return falla('El RTN debe tener 14 números.', `Tiene ${r.length}.`, rtn);
      if (!r && !(prov && prov.rtn)) return falla('Escriba el RTN de quien emitió la factura.', 'O elija un proveedor que tenga RTN.', rtn);
      datos.documento = { numero: numFactura.value.trim() };
      if (r) datos.documento.rtn = r;
      if (impuestos.length) datos.impuesto = selImp.value;
    }
    const cuenta = cuentas.find((c) => c.cuenta_dinero_id === selCuenta.value);
    const cat = cats.find((c) => c.id === selCat.value);
    const ok = await confirmar({ titulo: '¿Guardar este gasto?', textoBoton: 'Sí, guardar gasto',
      texto: `Gasto de ${dinero(m)} en ${cat.nombre} · sale de ${cuenta.nombre}.` });
    if (!ok) return;
    const r = await conBoton(boton, zonaError, async () => {
      const archivo = foto.files && foto.files[0];
      if (archivo) {
        const comp = await subirComprobante(empresaId(), 'gastos', archivo);
        if (comp) datos.comprobante = comp;
        else datos.descripcion = `${datos.descripcion} (foto: ${archivo.name.slice(0, 60)}, sin subir)`.slice(0, 300);
      }
      return escribir('registrar_gasto', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: id });
    });
    if (!r) return;
    olvidarDatos('cuentas');
    const espera = r.estado === 'pendiente_aprobacion';
    const hecho = espera ? `Gasto #${r.numero} de ${dinero(r.monto_centavos)} en espera de aprobación · pasa su tope, todavía no sale dinero de ${cuenta.nombre}`
      : `Gasto #${r.numero} de ${dinero(r.monto_centavos)} guardado · sale de ${cuenta.nombre}`;
    if (espera) window.dispatchEvent(new Event('pendientes-cambiaron'));
    aviso(hecho, espera ? 'info' : 'ok', 8000);
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-gastook' },
      titulo('h1', 'recibo', `Gasto #${r.numero}`, { id: 't-gastook' }),
      mensaje(espera ? 'info' : 'ok', hecho, espera ? 'Lo verá en Inicio > Pendientes hasta que lo aprueben o rechacen.'
        : r.isv_centavos ? `De eso, ${dinero(r.isv_centavos)} es ISV (crédito fiscal). En ${cuenta.nombre} quedan ${dinero(r.saldo_cuenta_centavos)}.`
          : `En ${cuenta.nombre} quedan ${dinero(r.saldo_cuenta_centavos)}.`, { class: 'resultado', dataset: { info: espera ? 'gasto-en-espera' : 'gasto-guardado' } }),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-principal', onclick: () => formularioGasto(vista, ctx) }, icono('mas'), 'Otro gasto'),
        h('button', { type: 'button', class: 'boton', onclick: volver }, 'Ver todos los gastos'))));
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-ngasto' },
    titulo('h1', 'recibo', 'Registrar un gasto', { id: 't-ngasto' }), form));
  selCuenta.focus();
}
