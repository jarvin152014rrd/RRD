// Ajustes · Sucursales y bodegas (app 0.16.0, núcleo 0.22.0).
// Cada sucursal tiene UNA tienda (de ahí salen las ventas de sus cajas) y las bodegas que quiera (solo guardan;
// la mercadería pasa a la tienda con Inventario > Traslados). Aquí se crean tiendas, bodegas, sucursales y cajas,
// se cambia cuál vende, el nombre, y se desactivan (vacías) o activan.
// Servidor: guardar_bodega, desactivar_bodega / reactivar_bodega, crear_sucursal, crear_caja. Los límites del plan
// los revisa el servidor (LIMITE_CONTRATO).
import { rpc, leer } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { h, icono, aviso, campo, conBoton, pedirMotivo, titulo, filaIcono, chip, mensaje, estadoVacio, dialogo } from '../ui.js';
import { olvidarDatos } from '../datos.js';

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const [sucursales, bodegas, cajas] = await Promise.all([
    leer('sucursal', { empresa_id: E }, { orden: 'codigo.asc' }),
    leer('bodega', { empresa_id: E }, { orden: 'codigo.asc' }),
    leer('caja', { empresa_id: E, activa: true }, { orden: 'punto_emision.asc' })]);
  if (!ctx.sigueVigente()) return;
  const conInventario = tieneModulo('inventario');
  const adminBodegas = conInventario && puede('bodegas.administrar');
  const adminSucursales = puede('sucursales.administrar');
  const recargar = async () => { olvidarDatos('bodegas'); olvidarDatos('cajas'); vista.replaceChildren(); await mostrar(vista, ctx); };
  const activas = sucursales.filter((s) => s.activa);

  // ---------- Una bodega ----------
  function filaBodega(b) {
    const tienda = b.activa && b.vende;
    return filaIcono({
      icono: tienda ? 'tienda' : 'existencias', color: !b.activa ? 'neutro' : tienda ? 'verde' : 'azul',
      titulo: [h('strong', {}, b.nombre), ' ', !b.activa ? chip('Inactiva', 'neutro') : tienda ? chip('Tienda', 'verde') : chip('Bodega', 'azul')],
      detalle: tienda ? 'Aquí se vende: las ventas de esta sucursal salen de aquí.' : b.activa ? 'Solo guarda mercadería.' : 'Desactivada (no se usa).',
      abajo: adminBodegas ? h('div', { class: 'botones' },
        b.activa && !b.vende ? h('button', { type: 'button', class: 'boton', 'aria-label': `Vender desde ${b.nombre}`, onclick: () => hacerTienda(b) },
          icono('tienda'), 'Vender desde aquí') : null,
        h('button', { type: 'button', class: 'boton', 'aria-label': `Cambiar el nombre de ${b.nombre}`, onclick: () => renombrar(b) }, icono('editar'), 'Nombre'),
        h('button', { type: 'button', class: `boton ${b.activa ? 'boton-peligro' : ''}`, 'aria-label': `${b.activa ? 'Desactivar' : 'Activar'} ${b.nombre}`,
          onclick: () => activar(b) }, b.activa ? 'Desactivar' : 'Activar')) : null,
      props: { dataset: { bodega: b.id, codigo: b.codigo } },
    });
  }

  async function hacerTienda(b) {
    const ok = await pedirMotivo({ titulo: `Vender desde ${b.nombre}`, textoBoton: 'Guardar',
      explicacion: 'Las ventas de esta sucursal saldrán de aquí. La tienda de antes queda como bodega (no se mueve mercadería).',
      accion: (motivo) => rpc('guardar_bodega', { p_empresa_id: E, p_datos: { bodega_id: b.id, vende: true }, p_motivo: motivo }) });
    if (ok) { aviso(`${b.nombre} es ahora la tienda`); recargar(); }
  }

  function renombrar(b) {
    const nombre = h('input', { type: 'text', maxlength: 60, value: b.nombre, id: 'bodega-nombre-nuevo' });
    const zona = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal' }, 'Siguiente');
    const form = h('form', { class: 'formulario', novalidate: true }, campo('Nombre', nombre), zona,
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => d.cerrar() }, 'Cancelar'), boton));
    const d = dialogo(`Nombre de ${b.nombre}`, form);
    nombre.focus();
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      d.cerrar();
      const ok = await pedirMotivo({ titulo: `Cambiar el nombre a "${nombre.value.trim()}"`, textoBoton: 'Guardar',
        accion: (motivo) => rpc('guardar_bodega', { p_empresa_id: E, p_datos: { bodega_id: b.id, nombre: nombre.value.trim() }, p_motivo: motivo }) });
      if (ok) { aviso('Nombre guardado'); recargar(); }
    });
  }

  async function activar(b) {
    const ok = await pedirMotivo({ titulo: b.activa ? `Desactivar ${b.nombre}` : `Activar ${b.nombre}`, peligro: b.activa,
      textoBoton: b.activa ? 'Desactivar' : 'Activar',
      explicacion: b.activa ? 'Solo se puede si está vacía (pase lo que tenga con Traslados). Si es la tienda, vende la siguiente bodega de la sucursal. No se borra nada.' : null,
      accion: (motivo) => rpc(b.activa ? 'desactivar_bodega' : 'reactivar_bodega', { p_empresa_id: E, p_bodega_id: b.id, p_motivo: motivo }) });
    if (ok) { aviso(b.activa ? `Desactivada · ${b.nombre}` : `Activada · ${b.nombre}`); recargar(); }
  }

  // ---------- Agregar bodega o tienda ----------
  function agregarBodega(s, tieneTienda) {
    const nombre = h('input', { type: 'text', maxlength: 60, id: 'bodega-nombre', placeholder: tieneTienda ? 'Ej. Bodega de atrás' : 'Ej. Tienda' });
    const radio = (valor, texto, ayuda, marcado) => h('label', { class: 'opcion-check' },
      h('input', { type: 'radio', name: 'bodega-tipo', value: valor, checked: marcado }), ' ', h('strong', {}, texto), ' · ', ayuda);
    const zona = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal', id: 'bodega-crear' }, 'Agregar');
    const form = h('form', { class: 'formulario', novalidate: true },
      campo('Nombre', nombre),
      h('fieldset', { class: 'campo' }, h('legend', {}, '¿Para qué es?'),
        radio('tienda', 'Tienda', 'se vende desde aquí', !tieneTienda),
        radio('bodega', 'Bodega', 'solo guarda mercadería', tieneTienda)),
      tieneTienda ? h('p', { class: 'ayuda' }, 'Si elige Tienda, la tienda de ahora pasa a ser bodega.') : null,
      zona, h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => d.cerrar() }, 'Cancelar'), boton));
    const d = dialogo(`Agregar en ${s.nombre}`, form);
    nombre.focus();
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const tienda = form.querySelector('input[name="bodega-tipo"]:checked').value === 'tienda';
      const r = await conBoton(boton, zona, () => rpc('guardar_bodega', { p_empresa_id: E,
        p_datos: { sucursal_id: s.id, nombre: nombre.value.trim(), vende: tienda }, p_motivo: tieneTienda && tienda ? 'Nueva tienda de la sucursal' : null }));
      if (r) { d.cerrar(); aviso(`${tienda ? 'Tienda' : 'Bodega'} agregada · ${r.nombre}`); recargar(); }
    });
  }

  // ---------- Caja y sucursal ----------
  const siguiente = (lista) => {
    const usados = new Set(lista.map((x) => Number(x)));
    let n = 1; while (usados.has(n)) n++;
    return String(n).padStart(3, '0');
  };

  async function agregarCaja(s, boton) {
    const punto = siguiente(cajas.filter((c) => c.sucursal_id === s.id).map((c) => c.punto_emision));
    const r = await conBoton(boton, zonaGeneral, () => rpc('crear_caja', { p_empresa_id: E, p_sucursal_id: s.id,
      p_nombre: punto === '001' ? 'Caja principal' : `Caja ${Number(punto)}`, p_punto_emision: punto }));
    if (r) { aviso(`Caja agregada en ${s.nombre}`); recargar(); }
  }

  function nuevaSucursal() {
    const nombre = h('input', { type: 'text', maxlength: 60, id: 'sucursal-nombre', placeholder: 'Ej. Centro, Colonia Kennedy' });
    const completa = h('input', { type: 'checkbox', id: 'sucursal-completa', checked: true });
    const zona = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal', id: 'sucursal-crear' }, 'Crear sucursal');
    const codigo = siguiente(sucursales.map((s) => s.codigo));
    const form = h('form', { class: 'formulario', novalidate: true },
      campo('Nombre de la sucursal', nombre, `Número de establecimiento para el SAR: ${codigo}.`),
      conInventario ? h('label', { class: 'opcion-check' }, completa, ' Lista para vender: con su tienda y su caja') : null,
      zona, h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => d.cerrar() }, 'Cancelar'), boton));
    const d = dialogo('Nueva sucursal', form);
    nombre.focus();
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const r = await conBoton(boton, zona, async () => {
        const s = await rpc('crear_sucursal', { p_empresa_id: E, p_codigo: codigo, p_nombre: nombre.value.trim() });
        // Lo demás va aparte: si el plan no da para otra tienda o caja, la sucursal queda creada y aquí se ve lo que falta.
        if (conInventario && completa.checked) {
          await rpc('guardar_bodega', { p_empresa_id: E, p_datos: { sucursal_id: s.sucursal_id, nombre: 'Tienda ' + nombre.value.trim(), vende: true }, p_motivo: null })
            .catch(() => null);
          await rpc('crear_caja', { p_empresa_id: E, p_sucursal_id: s.sucursal_id, p_nombre: 'Caja principal', p_punto_emision: '001' }).catch(() => null);
        }
        return s;
      });
      if (r) { d.cerrar(); aviso(`Sucursal ${codigo} creada`); recargar(); }
    });
  }

  // ---------- Pantalla ----------
  const zonaGeneral = h('div', { 'aria-live': 'assertive' });
  const tarjetas = activas.map((s) => {
    // La tienda primero, luego las bodegas activas y al final las desactivadas.
    const orden = (b) => (b.activa ? (b.vende ? 0 : 1) : 2);
    const suyas = bodegas.filter((b) => b.sucursal_id === s.id).sort((a, b) => orden(a) - orden(b) || a.nombre.localeCompare(b.nombre));
    const tieneTienda = suyas.some((b) => b.activa && b.vende);
    const susCajas = cajas.filter((c) => c.sucursal_id === s.id);
    const botonCaja = h('button', { type: 'button', class: 'boton', onclick: () => agregarCaja(s, botonCaja) }, icono('caja'), 'Agregar caja');
    return h('section', { class: 'tarjeta', 'aria-labelledby': `t-suc-${s.codigo}`, dataset: { sucursal: s.codigo } },
      titulo('h2', 'tienda', `${s.nombre} · sucursal ${s.codigo}`, { id: `t-suc-${s.codigo}` }),
      h('p', { class: 'ayuda' }, susCajas.length ? `Cajas: ${susCajas.map((c) => c.nombre).join(', ')}.` : 'Sin cajas: aquí no se vende.'),
      conInventario && !tieneTienda && susCajas.length ? mensaje('error', 'Esta sucursal no tiene tienda', 'Sus cajas no pueden vender productos. Agregue una tienda o marque una bodega con "Vender desde aquí".',
        { dataset: { info: 'sin-tienda' } }) : null,
      conInventario ? (suyas.length ? h('div', { class: 'lista-filas' }, suyas.map(filaBodega))
        : estadoVacio({ icono: 'existencias', chico: true, texto: 'Todavía no tiene dónde guardar productos.' })) : null,
      h('div', { class: 'botones' },
        adminBodegas ? h('button', { type: 'button', class: 'boton boton-principal', dataset: { accion: 'agregar-bodega' }, onclick: () => agregarBodega(s, tieneTienda) },
          icono('mas'), tieneTienda ? 'Agregar bodega o tienda' : 'Agregar tienda') : null,
        adminSucursales && !susCajas.length ? botonCaja : null));
  });

  vista.append(
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-bodegas' },
      h('div', { class: 'titulo-con-boton' }, titulo('h1', 'tienda', 'Sucursales y bodegas', { id: 't-bodegas' }),
        adminSucursales ? h('button', { type: 'button', class: 'boton', id: 'sucursal-nueva', onclick: nuevaSucursal }, icono('mas'), 'Nueva sucursal') : null),
      h('p', { class: 'ayuda' }, 'Tienda: de aquí salen las ventas de la sucursal. Bodega: solo guarda; para pasar mercadería a la tienda use Inventario > Traslados.'),
      zonaGeneral),
    ...tarjetas);
}
