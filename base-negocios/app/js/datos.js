// Listas que varias pantallas usan (productos, clientes, cajas, cuentas de dinero).
// Se leen del servidor (RLS decide qué filas) y se guardan SOLO en memoria un rato.
import { leer, rpc } from './api.js';
import { empresaId } from './sesion.js';
import { sinTildes } from './formato.js';

const memoria = new Map(); // clave -> { cuando, promesa }
const DURA_MS = 60 * 1000;

function guardado(clave, cargar, fresco = false) {
  const x = memoria.get(clave);
  if (!fresco && x && Date.now() - x.cuando < DURA_MS) return x.promesa;
  const promesa = cargar().catch((e) => { memoria.delete(clave); throw e; });
  memoria.set(clave, { cuando: Date.now(), promesa });
  return promesa;
}
// Filtros que las pantallas recuerdan mientras la app está abierta: al salir vuelven a los de siempre.
const reinicios = new Set();
export function reiniciarAlSalir(fn) { reinicios.add(fn); }
export function reiniciarTodo() { for (const fn of reinicios) { try { fn(); } catch { /* nada */ } } }

export function olvidarDatos(clave = null) { if (clave) memoria.delete(clave); else memoria.clear(); }

export const productos = (fresco) => guardado('productos', () =>
  leer('v_producto', { empresa_id: empresaId(), activo: true }, { orden: 'nombre.asc', limite: 1000 }), fresco);

export const clientes = (fresco) => guardado('clientes', () =>
  leer('tercero', { empresa_id: empresaId(), es_cliente: true }, { orden: 'nombre.asc', limite: 1000 }), fresco);

export const cajas = () => guardado('cajas', () => leer('caja', { empresa_id: empresaId(), activa: true }, { orden: 'nombre.asc' }));

export const cuentasDinero = (fresco) => guardado('cuentas', () =>
  leer('v_cuenta_dinero', { empresa_id: empresaId(), activa: true }, { orden: 'nombre.asc' }), fresco);

export const miTurno = () => rpc('mi_turno', { p_empresa_id: empresaId() }).then((r) => (r && r.turno) || null);

// ---- app 0.7.0 (Compras y Dinero) ----
export const proveedores = (fresco) => guardado('proveedores', () =>
  leer('tercero', { empresa_id: empresaId(), es_proveedor: true }, { orden: 'nombre.asc', limite: 1000 }), fresco);

export const categoriasGasto = (fresco) => guardado('categorias_gasto', () =>
  leer('categoria_gasto', { empresa_id: empresaId(), activa: true }, { orden: 'nombre.asc' }), fresco);

// Bodegas activas (RLS: un usuario limitado solo ve las de sus sucursales).
export const bodegas = () => guardado('bodegas', () => leer('bodega', { empresa_id: empresaId(), activa: true }, { orden: 'codigo.asc' }));

// ¿El usuario está limitado a unas sucursales? { limitado, sucursales: [ids] } (mi_estado_sesion).
export const alcance = () => guardado('alcance', () => rpc('mi_estado_sesion', { p_empresa_id: empresaId() }).then((e) => ({
  limitado: Boolean(e && e.todas_las_sucursales === false),
  sucursales: ((e && e.sucursales) || []).map((x) => x.sucursal_id),
})));

// Cuentas de las que se puede pagar (caja de efectivo, caja chica o banco), ya leídas con cuentasDinero.
export const TIPOS_QUE_PAGAN = ['efectivo_caja', 'caja_chica', 'banco'];
export const cuentasQuePagan = (lista) => lista.filter((c) => TIPOS_QUE_PAGAN.includes(c.tipo));

// Busca por nombre, código o código de barras (sin importar tildes ni mayúsculas).
export function filtrar(lista, texto, campos) {
  const q = sinTildes(texto).trim();
  if (!q) return lista;
  const partes = q.split(/\s+/);
  return lista.filter((x) => {
    const todo = sinTildes(campos.map((c) => x[c] || '').join(' '));
    return partes.every((p) => todo.includes(p));
  });
}
