// Inventario · Productos: lista con búsqueda, crear y editar producto o servicio (código, código
// de barras, nombre, categoría, unidad, impuesto, precio, ¿incluye ISV?, mínimo, campos extra),
// cambiar el precio con motivo (queda en el historial: producto_precio) y activar o desactivar.
// Llama crear_producto / editar_producto / cambiar_precio_producto. El servidor revisa todo.
import { rpc, leer, escribir } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { dinero, fechaHora, aCentavos, paraCampo, cantidad } from '../formato.js';
import { h, icono, aviso, errorSimple, campo, conBoton, pedirMotivo, confirmar } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { filtrar, olvidarDatos } from '../datos.js';

const E = () => empresaId();

async function catalogos() {
  const [cats, unidades, impuestos, extras] = await Promise.all([
    leer('categoria_producto', { empresa_id: E(), activa: true }, { orden: 'nombre.asc', limite: 500 }),
    leer('unidad', { activa: true }, { orden: 'codigo.asc', limite: 500 }),
    leer('impuesto', { empresa_id: E(), activo: true }, { orden: 'orden.asc' }),
    leer('campo_extra', { empresa_id: E(), activo: true }, { orden: 'clave.asc' }).catch(() => []),
  ]);
  return { cats, unidades: unidades.filter((u) => !u.empresa_id || u.empresa_id === E()), impuestos,
    extras: extras.filter((x) => !x.entidad || x.entidad === 'producto') };
}

export async function mostrar(vista, ctx) {
  const lista = await leer('v_producto', { empresa_id: E() }, { orden: 'nombre.asc', limite: 1000 });
  if (!ctx.sigueVigente()) return;
  const buscar = h('input', { id: 'buscar-producto-inv', type: 'search', placeholder: 'Nombre, código o código de barras', autocomplete: 'off' });
  const verInactivos = h('input', { type: 'checkbox', id: 'ver-inactivos' });
  const zona = h('div', { class: 'lista' });
  const pintar = () => {
    const vistos = filtrar(lista.filter((p) => verInactivos.checked || p.activo), buscar.value, ['nombre', 'codigo', 'codigo_barras', 'categoria']);
    zona.replaceChildren(...(vistos.length ? vistos.slice(0, 200).map((p) => h('article', { class: 'venta-fila', dataset: { producto: p.producto_id } },
      h('div', {}, h('strong', {}, p.nombre), !p.activo ? h('span', { class: 'etiqueta' }, ' Inactivo') : null,
        h('span', { class: 'detalle' }, [p.codigo, p.categoria, p.tipo === 'servicio' ? 'Servicio' : p.unidad].filter(Boolean).join(' · '))),
      h('span', { class: 'monto' }, dinero(p.precio_con_isv_centavos)),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => ficha(vista, ctx, p.producto_id) }, 'Ver'))))
      : [h('p', { class: 'vacio' }, 'No hay productos con ese nombre.')]));
  };
  buscar.addEventListener('input', pintar);
  verInactivos.addEventListener('change', pintar);
  pintar();
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-prod' },
    h('div', { class: 'titulo-con-boton' }, h('h1', { id: 't-prod', class: 'titulo-icono' }, icono('etiqueta'), 'Productos y servicios'),
      h('div', { class: 'botones' },
        // Subir muchos productos de una vez: lleva a Ajustes > Excel (si el usuario la ve).
        hayEnMenu(ctx.menu || [], 'ajustes', 'excel') ? h('a', { class: 'boton', href: '#/ajustes/excel', id: 'subir-excel' }, icono('excel'), 'Subir Excel') : null,
        puede('productos.editar') ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nuevo-producto',
          onclick: () => formulario(vista, ctx, null) }, icono('mas'), 'Nuevo producto') : null)),
    campo('Buscar', buscar), h('label', { class: 'opcion-check' }, verInactivos, ' Ver también los inactivos'), zona));
  buscar.focus();
}

async function volverALista(vista, ctx) { vista.replaceChildren(); await mostrar(vista, ctx); }

// Ficha: datos, precio, historial de precios y botones.
async function ficha(vista, ctx, id) {
  vista.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
  const [[p], hist] = await Promise.all([leer('v_producto', { producto_id: id }),
    leer('producto_precio', { producto_id: id }, { orden: 'cambiado_en.desc', limite: 20 }).catch(() => [])]);
  if (!ctx.sigueVigente()) return;
  const dato = (t, v) => (v || v === 0 ? h('div', { class: 'fila' }, h('span', {}, t), h('span', {}, String(v))) : null);
  const editar = puede('productos.editar');
  vista.replaceChildren(
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-pficha' },
      h('h1', { id: 't-pficha' }, p.nombre, !p.activo ? h('span', { class: 'etiqueta' }, ' Inactivo') : null),
      dato('Código', p.codigo), dato('Código de barras', p.codigo_barras), dato('Tipo', p.tipo === 'servicio' ? 'Servicio' : 'Bien'),
      dato('Categoría', p.categoria), dato('Unidad', p.unidad), dato('Impuesto', p.impuesto || p.tipo_impuesto),
      h('div', { class: 'fila' }, h('span', {}, 'Precio'), h('span', { class: 'monto', dataset: { dato: 'precio' } },
        `${dinero(p.precio_venta_centavos)} ${p.precio_incluye_isv ? '(incluye ISV)' : '(sin ISV)'}`)),
      dato('Precio con ISV', dinero(p.precio_con_isv_centavos)),
      p.tipo !== 'servicio' ? dato('Mínimo en existencia', cantidad(p.stock_minimo || 0)) : null,
      p.costo_estimado_centavos !== null && p.costo_estimado_centavos !== undefined && puede('inventario.costos') ? dato('Costo estimado', dinero(p.costo_estimado_centavos)) : null,
      Object.entries(p.campos_extra || {}).map(([k, v]) => dato(k, v)),
      h('div', { class: 'botones' },
        editar ? h('button', { type: 'button', class: 'boton boton-principal', id: 'editar-producto', onclick: () => formulario(vista, ctx, p) }, 'Editar') : null,
        puede('productos.precios') ? h('button', { type: 'button', class: 'boton', id: 'cambiar-precio', onclick: () => cambiarPrecio(vista, ctx, p) }, 'Cambiar precio') : null,
        editar ? h('button', { type: 'button', class: `boton ${p.activo ? 'boton-peligro' : ''}`, id: 'activar-producto',
          onclick: () => activar(vista, ctx, p) }, p.activo ? 'Desactivar' : 'Activar') : null,
        h('button', { type: 'button', class: 'boton', onclick: () => volverALista(vista, ctx) }, 'Volver a la lista'))),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-hist' },
      h('h2', { id: 't-hist' }, 'Historial de precios'),
      hist.length ? h('div', { class: 'lista', id: 'historial-precios' }, hist.map((x) => h('div', { class: 'fila' },
        h('span', {}, `${x.precio_anterior_centavos === null ? 'Precio inicial' : dinero(x.precio_anterior_centavos) + ' → '}${dinero(x.precio_nuevo_centavos)}`,
          h('span', { class: 'detalle' }, `${fechaHora(x.cambiado_en)}${x.motivo ? ' · ' + x.motivo : ''}`)))))
        : h('p', { class: 'vacio' }, 'Sin cambios de precio.')));
}

// Cambiar precio: pide el nuevo precio y el motivo (queda en el historial).
async function cambiarPrecio(vista, ctx, p) {
  const nuevo = h('input', { id: 'precio-nuevo', type: 'text', inputmode: 'decimal', value: paraCampo(p.precio_venta_centavos) });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const sigue = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Siguiente');
  const form = h('form', { class: 'formulario', novalidate: true },
    h('p', {}, `Precio actual: ${dinero(p.precio_venta_centavos)} ${p.precio_incluye_isv ? '(incluye ISV)' : '(sin ISV)'}.`),
    campo('Precio nuevo (L)', nuevo, p.precio_incluye_isv ? 'Con ISV incluido, como lo cobra.' : 'Sin ISV.'), zonaError, sigue,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => ficha(vista, ctx, p.producto_id) }, 'Volver'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const c = aCentavos(nuevo.value);
    if (c === null || c < 0) { zonaError.append(errorSimple('Escriba un precio válido (por ejemplo 125.50).')); return; }
    if (c === p.precio_venta_centavos) { zonaError.append(errorSimple('Es el mismo precio.')); return; }
    const ok = await pedirMotivo({ titulo: 'Cambiar precio', textoBoton: 'Cambiar precio',
      explicacion: `${p.nombre}: de ${dinero(p.precio_venta_centavos)} a ${dinero(c)}.`,
      accion: (motivo) => rpc('cambiar_precio_producto', { p_empresa_id: E(), p_producto_id: p.producto_id, p_precio_centavos: c, p_motivo: motivo }) });
    if (ok) { olvidarDatos('productos'); aviso('Precio cambiado. Quedó en el historial.'); ficha(vista, ctx, p.producto_id); }
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-cprecio' },
    h('h1', { id: 't-cprecio' }, `Cambiar precio · ${p.nombre}`), form));
  nuevo.focus();
}

async function activar(vista, ctx, p) {
  const ok = await pedirMotivo({ titulo: p.activo ? 'Desactivar producto' : 'Activar producto', peligro: p.activo,
    textoBoton: p.activo ? 'Desactivar' : 'Activar',
    explicacion: p.activo ? `${p.nombre} ya no saldrá para vender. No se borra nada.` : `${p.nombre} vuelve a salir para vender.`,
    accion: (motivo) => rpc('editar_producto', { p_empresa_id: E(), p_producto_id: p.producto_id, p_datos: { activo: !p.activo }, p_motivo: motivo }) });
  if (ok) { olvidarDatos('productos'); aviso(p.activo ? 'Producto desactivado.' : 'Producto activado.'); ficha(vista, ctx, p.producto_id); }
}

// Crear (p = null) o editar. El precio de un producto que ya existe se cambia con "Cambiar precio".
async function formulario(vista, ctx, p) {
  vista.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
  const cat = await catalogos();
  if (!ctx.sigueVigente()) return;
  const nuevo = !p;
  const v = (k, d = '') => (p && p[k] !== null && p[k] !== undefined ? p[k] : d);
  const codigo = h('input', { id: 'prod-codigo', type: 'text', maxlength: 30, value: v('codigo'), autocapitalize: 'characters' });
  const barras = h('input', { id: 'prod-barras', type: 'text', maxlength: 40, inputmode: 'numeric', value: v('codigo_barras') });
  const nombre = h('input', { id: 'prod-nombre', type: 'text', maxlength: 150, value: v('nombre') });
  const tipo = h('select', { id: 'prod-tipo', disabled: !nuevo }, h('option', { value: 'bien' }, 'Bien (lleva existencia)'),
    tieneModulo('inventario') || true ? h('option', { value: 'servicio' }, 'Servicio (sin existencia)') : null);
  tipo.value = v('tipo', 'bien');
  const categoria = h('select', { id: 'prod-categoria' }, h('option', { value: '' }, 'Sin categoría'),
    cat.cats.map((c) => h('option', { value: c.id }, '— '.repeat(Math.max(0, (c.nivel || 1) - 1)) + c.nombre)));
  categoria.value = v('categoria_id');
  const unidad = h('select', { id: 'prod-unidad' }, cat.unidades.map((u) => h('option', { value: u.id }, `${u.codigo} · ${u.nombre}`)));
  if (p) unidad.value = p.unidad_id; else { const und = cat.unidades.find((u) => u.codigo === 'UND'); if (und) unidad.value = und.id; }
  const impuesto = h('select', { id: 'prod-impuesto' }, cat.impuestos.map((i) => h('option', { value: i.codigo }, i.nombre)));
  impuesto.value = v('tipo_impuesto', (cat.impuestos.find((i) => i.predeterminado) || cat.impuestos[0] || {}).codigo);
  const precio = h('input', { id: 'prod-precio', type: 'text', inputmode: 'decimal', placeholder: '0.00' });
  const incluye = h('input', { id: 'prod-incluye', type: 'checkbox', checked: p ? p.precio_incluye_isv : true });
  const minimo = h('input', { id: 'prod-minimo', type: 'text', inputmode: 'decimal', value: p ? cantidad(p.stock_minimo || 0) : '' });
  const fracciones = h('input', { id: 'prod-fracciones', type: 'checkbox', checked: p ? p.permite_fracciones : false });
  const extras = cat.extras.map((x) => {
    const actual = p && p.campos_extra ? p.campos_extra[x.clave] : null;
    let ctl;
    if (x.tipo === 'lista') ctl = h('select', {}, h('option', { value: '' }, '—'), (x.opciones || []).map((o) => h('option', { value: o }, o)));
    else if (x.tipo === 'si_no') ctl = h('select', {}, h('option', { value: '' }, '—'), h('option', { value: 'true' }, 'Sí'), h('option', { value: 'false' }, 'No'));
    else ctl = h('input', { type: x.tipo === 'fecha' ? 'date' : 'text', inputmode: ['numero', 'entero'].includes(x.tipo) ? 'decimal' : null });
    ctl.value = actual === null || actual === undefined ? '' : String(actual);
    return { x, ctl };
  });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, nuevo ? 'Crear producto' : 'Guardar cambios');
  const form = h('form', { class: 'formulario', novalidate: true },
    h('div', { class: 'dos-columnas' }, campo('Código', codigo, 'Único. Se guarda en mayúsculas.'), campo('Código de barras (opcional)', barras)),
    campo('Nombre', nombre),
    h('div', { class: 'dos-columnas' }, campo('Tipo', tipo, nuevo ? null : 'No se cambia después de crearlo.'), campo('Categoría', categoria)),
    h('div', { class: 'dos-columnas' }, campo('Unidad', unidad), campo('Impuesto', impuesto)),
    nuevo ? campo('Precio de venta (L)', precio) : null,
    h('label', { class: 'opcion-check' }, incluye, ' El precio ya incluye el ISV'),
    h('div', { class: 'dos-columnas' }, campo('Mínimo en existencia (alerta)', minimo), h('label', { class: 'opcion-check' }, fracciones, ' Se vende con decimales (por libra, por metro…)')),
    extras.length ? h('fieldset', { class: 'grupo-campos' }, h('legend', {}, 'Campos extra'), extras.map(({ x, ctl }) => campo(x.etiqueta + (x.obligatorio ? ' (obligatorio)' : ''), ctl))) : null,
    zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => (p ? ficha(vista, ctx, p.producto_id) : volverALista(vista, ctx)) }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    if (!codigo.value.trim() || !nombre.value.trim()) { zonaError.append(errorSimple('Escriba el código y el nombre.')); return; }
    const datos = { codigo: codigo.value.trim().toUpperCase(), codigo_barras: barras.value.trim() || null, nombre: nombre.value.trim(),
      categoria_id: categoria.value || null, unidad_id: unidad.value, tipo_impuesto: impuesto.value,
      permite_fracciones: fracciones.checked };
    const min = minimo.value.trim() ? Number(minimo.value.replace(',', '.')) : 0;
    if (!Number.isFinite(min) || min < 0) { zonaError.append(errorSimple('El mínimo debe ser un número de 0 o más.')); return; }
    datos.stock_minimo = min;
    const ce = {};
    for (const { x, ctl } of extras) {
      const t = ctl.value.trim();
      if (!t) { if (p && p.campos_extra && x.clave in p.campos_extra) ce[x.clave] = null; continue; }
      ce[x.clave] = x.tipo === 'si_no' ? t === 'true' : ['numero', 'entero'].includes(x.tipo) ? Number(t) : t;
    }
    if (Object.keys(ce).length) datos.campos_extra = ce;
    let r;
    if (nuevo) {
      const c = aCentavos(precio.value);
      if (c === null || c < 0) { zonaError.append(errorSimple('Escriba el precio (por ejemplo 125.50).')); return; }
      datos.tipo = tipo.value; datos.precio_venta_centavos = c; datos.precio_incluye_isv = incluye.checked;
      if (!await confirmar({ titulo: 'Crear producto', texto: `${datos.nombre} (${datos.codigo}) a ${dinero(c)} ${incluye.checked ? 'con' : 'sin'} ISV.`, textoBoton: 'Sí, crear' })) return;
      r = await conBoton(boton, zonaError, () => escribir('crear_producto', { p_empresa_id: E(), p_datos: datos }));
      if (!r) return;
      olvidarDatos('productos'); aviso('Producto creado.');
      return ficha(vista, ctx, r.producto_id);
    }
    // Editar: cambiar "incluye ISV" pide motivo (queda en el historial de precios).
    const cambiaIsv = incluye.checked !== p.precio_incluye_isv;
    if (cambiaIsv) datos.precio_incluye_isv = incluye.checked;
    const guardar = (motivo) => rpc('editar_producto', { p_empresa_id: E(), p_producto_id: p.producto_id, p_datos: datos, p_motivo: motivo || null });
    if (cambiaIsv) {
      if (!await pedirMotivo({ titulo: 'Guardar cambios', textoBoton: 'Guardar', explicacion: 'Cambia si el precio incluye ISV: queda en el historial de precios.', accion: guardar })) return;
    } else {
      if (!await confirmar({ titulo: 'Guardar cambios', texto: `¿Guardar los cambios de ${datos.nombre}?` })) return;
      if (!await conBoton(boton, zonaError, () => guardar(null).then(() => true))) return;
    }
    olvidarDatos('productos'); aviso('Cambios guardados.');
    ficha(vista, ctx, p.producto_id);
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-pform' },
    h('h1', { id: 't-pform' }, nuevo ? 'Nuevo producto o servicio' : `Editar · ${p.nombre}`), form));
  (nuevo ? codigo : nombre).focus();
}
