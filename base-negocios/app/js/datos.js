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
export function olvidarDatos(clave = null) { if (clave) memoria.delete(clave); else memoria.clear(); }

export const productos = (fresco) => guardado('productos', () =>
  leer('v_producto', { empresa_id: empresaId(), activo: true }, { orden: 'nombre.asc', limite: 1000 }), fresco);

export const clientes = (fresco) => guardado('clientes', () =>
  leer('tercero', { empresa_id: empresaId(), es_cliente: true }, { orden: 'nombre.asc', limite: 1000 }), fresco);

export const cajas = () => guardado('cajas', () => leer('caja', { empresa_id: empresaId(), activa: true }, { orden: 'nombre.asc' }));

export const cuentasDinero = (fresco) => guardado('cuentas', () =>
  leer('v_cuenta_dinero', { empresa_id: empresaId(), activa: true }, { orden: 'nombre.asc' }), fresco);

export const miTurno = () => rpc('mi_turno', { p_empresa_id: empresaId() }).then((r) => (r && r.turno) || null);

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
