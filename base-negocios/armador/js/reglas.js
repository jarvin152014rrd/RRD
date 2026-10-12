// Cuestionario de la visita y reglas que SUGIEREN módulos, perfil y límites.
// Datos y funciones puras (sin pantalla): las usa armador.js y se pueden probar solas.
// El proveedor decide al final: todo lo sugerido se puede cambiar en el armado.

export const PREGUNTAS = [
  { id: 'vende', texto: '¿Qué vende el negocio?', tipo: 'opciones',
    opciones: [['productos', 'Productos'], ['servicios', 'Servicios'], ['ambos', 'Productos y servicios']],
    ayuda: 'Servicios: mano de obra, cortes, platillos... no llevan existencias.' },
  { id: 'inventario', texto: '¿Quiere saber cuánto le queda de cada producto (existencias)?', tipo: 'si_no' },
  { id: 'credito', texto: '¿Le quedan debiendo clientes (vende al crédito o fiado)?', tipo: 'si_no' },
  { id: 'cotizaciones', texto: '¿Hace cotizaciones o presupuestos antes de vender?', tipo: 'si_no' },
  { id: 'apartados', texto: '¿Aparta mercadería con un anticipo?', tipo: 'si_no' },
  { id: 'bancos', texto: '¿Recibe tarjeta, transferencias o deposita en bancos?', tipo: 'si_no' },
  { id: 'conciliar', texto: '¿Quiere cuadrar cada mes el banco con el estado de cuenta?', tipo: 'si_no' },
  { id: 'personas', texto: '¿Cuántas personas usarán el programa (contando al dueño)?', tipo: 'numero', min: 1, max: 200 },
  { id: 'cajas', texto: '¿En cuántos puntos se cobra a la vez (cajas)?', tipo: 'numero', min: 1, max: 50 },
  { id: 'sucursales', texto: '¿Cuántas tiendas o sucursales tiene?', tipo: 'numero', min: 1, max: 50 },
  { id: 'bodegas', texto: '¿Cuántas bodegas (lugares donde guarda mercadería)?', tipo: 'numero', min: 1, max: 50 },
  { id: 'compras', texto: '¿Compra a proveedores al crédito y quiere controlar lo que les debe?', tipo: 'si_no' },
  { id: 'comisiones', texto: '¿Paga comisiones a vendedores, estilistas o mecánicos?', tipo: 'si_no' },
  { id: 'cai', texto: '¿Factura con CAI del SAR (factura fiscal)?', tipo: 'si_no' },
  { id: 'socios', texto: '¿Tiene socios o quiere separar ahorro y reparto de ganancias?', tipo: 'si_no' },
];

// Nombres sencillos de los módulos (los de la base se usan si llegan del servidor).
export const NOMBRES = {
  contabilidad: 'Contabilidad (siempre)', ventas: 'Ventas, clientes y cobros', inventario: 'Inventario',
  dinero: 'Cajas, bancos y gastos', compras: 'Compras y proveedores', apartados: 'Apartados',
  comisiones: 'Comisiones', fondos: 'Fondos y socios', conciliacion: 'Cuadrar con el banco', fiscal_hn: 'Facturas con CAI',
};
export const ORDEN_MODULOS = ['contabilidad', 'ventas', 'inventario', 'dinero', 'compras', 'apartados', 'comisiones', 'fondos', 'conciliacion'];

const num = (v, min = 1) => Math.max(min, Math.floor(Number(v) || 0));

// Respuestas -> { modulos: {codigo: bool}, regimen_fiscal, perfil, paquete, limites, razones: [{que, por_que}] }
export function sugerir(r) {
  const m = Object.fromEntries(ORDEN_MODULOS.map((x) => [x, false]));
  const razones = [];
  const pon = (mod, por) => { m[mod] = true; razones.push({ que: mod, por_que: por }); };
  pon('contabilidad', 'Siempre: lleva los libros por dentro aunque el cliente no los vea.');
  pon('ventas', 'Todo negocio que vende: incluye clientes, cobros, devoluciones'
    + (r.cotizaciones === 'si' ? ' y cotizaciones (usted dijo que cotiza).' : '.'));
  if (r.vende !== 'servicios') pon('inventario', 'Vende productos: cada producto lleva existencias y costo (sin inventario solo se venden servicios).');
  else if (r.inventario === 'si') pon('inventario', 'Quiere ver las existencias de lo que usa o vende.');
  pon('dinero', 'Cobra de contado' + (r.bancos === 'si' ? ' y usa bancos o tarjeta' : '')
    + ': cajas, bancos, gastos y turnos (sin este módulo solo se vendería al crédito).');
  if (r.compras === 'si') pon('compras', 'Compra al crédito: controla lo que debe a cada proveedor (necesita inventario).');
  if (r.apartados === 'si') pon('apartados', 'Aparta mercadería con anticipo (necesita inventario).');
  if (r.comisiones === 'si') pon('comisiones', 'Paga comisiones: se calculan al cobrar y se pagan por período.');
  if (r.socios === 'si') pon('fondos', 'Tiene socios o quiere separar ahorro: fondos y reparto de la ganancia cobrada.');
  if (r.conciliar === 'si' && r.bancos === 'si') pon('conciliacion', 'Quiere cuadrar el banco con su estado de cuenta.');
  const regimen = r.cai === 'si' ? 'fiscal_hn' : 'ninguno';
  razones.push({ que: 'fiscal_hn', por_que: regimen === 'fiscal_hn' ? 'Factura con CAI: facturas fiscales numeradas.' : 'No usa CAI: comprobante interno (se puede activar después).' });
  if (r.credito === 'si') razones.push({ que: 'credito', por_que: 'Vende al crédito: "Quién me debe" y cobros ya vienen con Ventas.' });

  const personas = num(r.personas), cajas = num(r.cajas), sucursales = num(r.sucursales), bodegas = num(r.bodegas);
  let perfil = 'mediano';
  if (personas <= 5 && cajas <= 1 && sucursales <= 1) perfil = 'pequeno';
  else if (sucursales >= 3 || personas > 15) perfil = 'grande';
  razones.push({ que: 'perfil', por_que: perfil === 'pequeno' ? 'Pocas personas y una caja: perfil pequeño (sin turnos obligatorios).'
    : perfil === 'grande' ? 'Varias sucursales o muchas personas: perfil grande (doble aprobación).'
      : 'Varias cajas o más personas: perfil mediano (turnos por cajero).' });
  const limites = { usuarios: personas + 1, cajas, sucursales, bodegas: Math.max(bodegas, sucursales) };
  razones.push({ que: 'limites', por_que: `Usuarios: ${personas} personas + 1 de margen. Cajas, sucursales y bodegas: lo que tiene hoy.` });
  const extra = ['compras', 'apartados', 'comisiones', 'fondos', 'conciliacion'].some((x) => m[x]);
  const paquete = extra || perfil !== 'pequeno' ? 'completo' : 'esencial';
  return { modulos: m, regimen_fiscal: regimen, perfil, paquete, limites, razones };
}

// Revisa dependencias (lista de la base: [{modulo, requiere, motivo}]).
// activos: {codigo: bool} (incluye fiscal_hn según el régimen). Devuelve mensajes claros.
export function problemasDependencias(activos, dependencias, nombres = NOMBRES) {
  const n = (x) => nombres[x] || x;
  const lista = [];
  for (const d of dependencias) {
    if (activos[d.modulo] && !activos[d.requiere]) {
      lista.push({ modulo: d.modulo, requiere: d.requiere,
        texto: `No se puede: "${n(d.modulo)}" necesita "${n(d.requiere)}" (${d.motivo}). `
          + `Encienda "${n(d.requiere)}" o apague primero "${n(d.modulo)}".` });
    }
  }
  return lista;
}

// Identificador de carpeta a partir del nombre: "Taller Prueba" -> "taller-prueba".
export function idCliente(nombre) {
  return String(nombre || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/s\.? de r\.?l\.?/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
}
