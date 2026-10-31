// Armador del proveedor: rubro -> cuestionario -> armado (módulos, límites, licencia, palabras)
// con vista previa del menú del cliente -> Crear / Aplicar cambios. Lista de clientes y demos.
// Toda escritura la hace el servidor (herramientas/servidor_armador.js) con las herramientas de siempre.
import { PREGUNTAS, NOMBRES, ORDEN_MODULOS, sugerir, problemasDependencias, idCliente } from './reglas.js';
import { MENU, menuPara } from '../app/js/menu_datos.js';
import { icono } from '../app/js/iconos.js';

const raiz = document.getElementById('app');
let catalogo = null;

// ---------------- Utilidades ----------------
function h(tag, attrs = {}, ...hijos) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, v);
  }
  for (const x of hijos.flat(Infinity)) if (x !== null && x !== undefined && x !== false) el.append(x instanceof Node ? x : String(x));
  return el;
}
async function api(ruta, datos) {
  const r = await fetch(ruta, datos === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(datos) });
  let cuerpo = null;
  try { cuerpo = await r.json(); } catch { cuerpo = { mensaje: 'Respuesta inválida del Armador.' }; }
  if (r.status === 401 && ruta !== '/api/entrar') { mostrarEntrar('Su sesión terminó. Escriba la clave otra vez.'); throw new Error(cuerpo.mensaje); }
  if (!r.ok) throw new Error(cuerpo.mensaje || 'Error');
  return cuerpo;
}
const msg = (tipo, texto, id) => h('p', { class: `mensaje mensaje-${tipo}`, role: tipo === 'error' ? 'alert' : 'status', id }, texto);
const nombreModulo = (m) => NOMBRES[m] || (catalogo && catalogo.modulos[m]) || m;
const hoyMas = (dias) => { const d = new Date(); d.setDate(d.getDate() + dias); return d.toISOString().slice(0, 10); };
const inicioMes = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`; };
function ocupar(boton, texto) {
  const antes = boton.textContent; boton.disabled = true; boton.textContent = texto;
  return () => { boton.disabled = false; boton.textContent = antes; };
}

// ---------------- Entrar ----------------
function mostrarEntrar(mensaje) {
  window.removeEventListener('hashchange', ruta);
  const clave = h('input', { id: 'clave-armador', type: 'password', autocomplete: 'current-password', required: true });
  const zona = h('div', { 'aria-live': 'polite' }, mensaje ? msg('info', mensaje) : null);
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Entrar');
  const form = h('form', { class: 'tarjeta', novalidate: true },
    h('div', { class: 'entrar-marca' }, h('img', { src: 'app/iconos/icono.svg', alt: '', width: 44, height: 44 }), h('h1', {}, 'Armador del proveedor')),
    h('p', { class: 'suave' }, 'Solo para el proveedor. El cliente nunca ve esta pantalla.'),
    zona, h('div', { class: 'campo' }, h('label', { for: 'clave-armador' }, 'Clave del proveedor'), clave), boton);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zona.replaceChildren();
    if (!clave.value) { zona.append(msg('error', 'Escriba la clave.')); return; }
    const listo = ocupar(boton, 'Entrando…');
    try { await api('/api/entrar', { clave: clave.value }); await iniciarApp(); } catch (e) { zona.append(msg('error', e.message)); listo(); clave.select(); }
  });
  raiz.replaceChildren(h('div', { class: 'entrar' }, form));
  clave.focus();
}

// ---------------- Armazón ----------------
let zonas = null;
async function iniciarApp() {
  raiz.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Preparando la base de demostración…'));
  catalogo = await api('/api/catalogo');
  const pestanas = h('nav', { class: 'pestanas', 'aria-label': 'Menú del Armador' },
    [['armar', 'Armar cliente'], ['clientes', 'Clientes'], ['demo', 'Demostración']].map(([id, t]) =>
      h('a', { class: 'pestana', href: `#/${id}`, dataset: { pestana: id } }, t)));
  const contenido = h('main', { class: 'contenido', id: 'contenido', tabindex: '-1' });
  raiz.replaceChildren(
    h('header', { class: 'encabezado' },
      h('div', { class: 'encabezado-fila' },
        h('div', { class: 'marca' }, h('div', { class: 'marca-logo', 'aria-hidden': 'true' }, 'A'),
          h('span', { class: 'marca-nombre' }, 'Armador'), h('span', { class: 'armador-sello' }, 'Solo proveedor · núcleo ' + (catalogo.nucleo || '?'))),
        h('div', { class: 'quien' }, h('button', { type: 'button', class: 'boton boton-claro', onclick: async () => { await api('/api/salir', {}); mostrarEntrar('Cerró el Armador.'); } }, 'Salir'))),
      pestanas),
    contenido);
  zonas = { pestanas, contenido };
  window.addEventListener('hashchange', ruta);
  ruta();
}

function ruta() {
  if (!zonas) return;
  const [pid, arg] = location.hash.replace(/^#\/?/, '').split('/');
  const actual = ['armar', 'clientes', 'demo', 'editar'].includes(pid) ? pid : 'armar';
  for (const a of zonas.pestanas.children) {
    const on = a.dataset.pestana === actual || (actual === 'editar' && a.dataset.pestana === 'clientes');
    if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
  const vista = h('div', { class: 'lista' });
  zonas.contenido.replaceChildren(vista);
  const fn = { armar: () => pantallaArmar(vista, null), editar: () => pantallaArmar(vista, decodeURIComponent(arg || '')),
    clientes: () => pantallaClientes(vista), demo: () => pantallaDemo(vista) }[actual];
  fn().catch((e) => vista.replaceChildren(msg('error', e.message)));
}

// ---------------- Armar (nuevo o editar) ----------------
function estadoInicial() {
  return {
    plantilla: null, respuestas: {}, sugerencia: null,
    cliente: '', clienteManual: false, nombre: '', nombre_comercial: '', rtn: '', fecha_inicio: inicioMes(),
    dueno_correo: '', dueno_nombre: '', color_principal: '#0f1f3d', color_acento: '#c8972a', logo: null,
    modulos: Object.fromEntries(ORDEN_MODULOS.map((m) => [m, ['contabilidad', 'ventas', 'dinero'].includes(m)])),
    regimen_fiscal: 'ninguno', perfil: 'pequeno', paquete: 'esencial',
    limites: { usuarios: 3, cajas: 1, sucursales: 1, bodegas: 1 },
    licencia: { vence_el: hoyMas(31), dias_gracia: 5 },
    palabras: {}, campos_orden: [], puesto: 'dueno', destino: 'demo', conexion: '', confirmacion: '', notas: '',
    // Fotos de productos (núcleo 0.17.0). fotosEnFicha: solo se manda si la ficha ya lo traía o se tocó aquí
    // (así una ficha vieja no apaga lo que el dueño encendió en la app).
    fotos_productos: false, fotosEnFicha: false,
  };
}

function aplicarPlantilla(e, p) {
  e.plantilla = p.id;
  e.respuestas = { ...p.respuestas };
  e.palabras = { ...p.palabras };
  e.campos_orden = (p.campos_extra || []).filter((c) => c.donde === 'orden');
  if (p.colores) { e.color_principal = p.colores.principal; e.color_acento = p.colores.acento; }
  usarSugerencia(e, sugerir(e.respuestas));
}
function usarSugerencia(e, s) {
  e.sugerencia = s;
  e.modulos = { ...s.modulos }; e.regimen_fiscal = s.regimen_fiscal; e.perfil = s.perfil; e.paquete = s.paquete; e.limites = { ...s.limites };
}

function desdeFicha(f, app) {
  const e = estadoInicial();
  const n = f.negocio || {};
  Object.assign(e, { cliente: f.cliente, clienteManual: true, nombre: n.nombre, rtn: n.rtn || '', fecha_inicio: n.fecha_inicio,
    dueno_correo: (f.dueno || {}).correo || '', dueno_nombre: (f.dueno || {}).nombre || '', perfil: f.perfil || 'pequeno',
    paquete: f.paquete, regimen_fiscal: f.regimen_fiscal || 'ninguno', notas: f.notas || '',
    color_principal: (f.tema || {}).color_principal || e.color_principal, color_acento: (f.tema || {}).color_acento || e.color_acento,
    limites: { ...e.limites, ...(f.limites || {}) }, licencia: f.licencia || e.licencia,
    palabras: { ...((app && app.palabras) || {}) }, campos_orden: (app && app.campos_orden) || [] });
  e.modulos = Object.fromEntries(ORDEN_MODULOS.map((m) => [m, Boolean((f.modulos || {})[m])]));
  e.modulos.contabilidad = true;
  if (f.opciones && typeof f.opciones.fotos_productos === 'boolean') { e.fotos_productos = f.opciones.fotos_productos; e.fotosEnFicha = true; }
  const p = catalogo.plantillas.find((x) => x.nombre === n.rubro || x.id === (app && app.plantilla));
  if (p) { e.plantilla = p.id; e.respuestas = { ...p.respuestas }; }
  e.rubro = n.rubro || '';
  return e;
}

function fichaDe(e) {
  return {
    cliente: e.cliente, paquete: e.paquete,
    negocio: { nombre: e.nombre, rtn: e.rtn || null, rubro: e.rubro || null, fecha_inicio: e.fecha_inicio, nombre_comercial: e.nombre_comercial || undefined },
    perfil: e.perfil, modulos: e.modulos, regimen_fiscal: e.regimen_fiscal,
    licencia: { vence_el: e.licencia.vence_el, dias_gracia: Number(e.licencia.dias_gracia) },
    limites: e.limites, dueno: { correo: e.dueno_correo, nombre: e.dueno_nombre },
    tema: { color_principal: e.color_principal, color_acento: e.color_acento }, notas: e.notas || null,
    opciones: e.fotosEnFicha ? { fotos_productos: Boolean(e.fotos_productos) } : undefined,
  };
}

async function pantallaArmar(vista, editar) {
  let e = estadoInicial();
  let original = null;
  if (editar) {
    const c = await api('/api/cliente?id=' + encodeURIComponent(editar));
    e = desdeFicha(c.ficha, c.app);
    original = c.ficha;
  }
  const izquierda = h('div', { class: 'columna-ancha pasos' });
  const derecha = h('aside', { class: 'columna-angosta vista-previa', 'aria-label': 'Vista previa del menú del cliente' });
  vista.append(h('div', { class: 'titulo-con-boton' },
    h('h1', { id: 't-armar' }, editar ? `Cambiar cliente · ${e.nombre}` : 'Armar el programa de un cliente nuevo'),
    editar ? h('a', { class: 'boton', href: '#/clientes' }, 'Volver a clientes') : null),
  h('div', { class: 'columnas' }, izquierda, derecha));

  const pintar = () => { pintarVistaPrevia(derecha, e); pintarProblemas(); };
  let numero = 0; // pasos numerados en orden (el id no cambia: paso-<clave>)
  const paso = (clave, titulo, ...cuerpo) => h('section', { class: 'tarjeta', 'aria-labelledby': `paso-${clave}` },
    h('h2', { class: 'paso-cabeza', id: `paso-${clave}` }, h('span', { class: 'paso-numero' }, String(++numero)), titulo), ...cuerpo);

  // 1) Rubro
  const rubros = h('div', { class: 'rubros', role: 'group', 'aria-label': 'Rubro' });
  const pintarRubros = () => rubros.replaceChildren(...catalogo.plantillas.map((p) => h('button', {
    type: 'button', class: 'rubro', id: `rubro-${p.id}`, 'aria-pressed': String(e.plantilla === p.id),
    onclick: () => { aplicarPlantilla(e, p); e.rubro = p.nombre; pintarRubros(); pintarCuestionario(); pintarDatos(); pintarArmado(); pintar(); },
  }, h('strong', {}, p.nombre), h('span', {}, p.descripcion))));
  pintarRubros();

  // 2) Cuestionario
  const cuestionario = h('div', {});
  const sugerencias = h('div', { id: 'sugerencias', 'aria-live': 'polite' });
  function pintarCuestionario() {
    cuestionario.replaceChildren(...PREGUNTAS.map((q) => {
      const val = e.respuestas[q.id];
      let control;
      if (q.tipo === 'numero') {
        control = h('input', { type: 'number', id: `q-${q.id}`, min: q.min, max: q.max, value: val ?? q.min, inputmode: 'numeric',
          oninput: (ev) => { e.respuestas[q.id] = Number(ev.target.value) || q.min; } });
      } else {
        const opciones = q.tipo === 'si_no' ? [['si', 'Sí'], ['no', 'No']] : q.opciones;
        control = h('div', { class: 'segmentos', role: 'group', 'aria-labelledby': `qt-${q.id}` }, opciones.map(([v, t]) =>
          h('button', { type: 'button', class: 'segmento', id: `q-${q.id}-${v}`, 'aria-pressed': String(val === v),
            onclick: (ev) => { e.respuestas[q.id] = v; for (const b of ev.target.parentNode.children) b.setAttribute('aria-pressed', String(b === ev.target)); } }, t)));
      }
      return h('div', { class: 'pregunta' }, h('span', { class: 'pregunta-texto', id: `qt-${q.id}` }, q.texto), control,
        q.ayuda ? h('p', { class: 'ayuda' }, q.ayuda) : null);
    }));
    sugerencias.replaceChildren();
  }
  pintarCuestionario();
  const btnSugerir = h('button', { type: 'button', class: 'boton boton-principal', id: 'btn-sugerir', onclick: () => {
    const s = sugerir(e.respuestas);
    e.sugerencia = s;
    const activos = ORDEN_MODULOS.filter((m) => s.modulos[m]);
    sugerencias.replaceChildren(h('div', { class: 'mensaje mensaje-info' },
      h('p', {}, h('strong', {}, 'Sugerencia: '), activos.map(nombreModulo).join(', '),
        s.regimen_fiscal === 'fiscal_hn' ? ', Facturas con CAI' : '', ` · perfil ${s.perfil} · paquete ${s.paquete}.`),
      h('p', { class: 'suave' }, 'Usted decide: puede cambiar todo en "Módulos".')),
    h('ul', { class: 'sugerencias', id: 'lista-sugerencias' }, s.razones.map((r) => h('li', { dataset: { modulo: r.que } },
      h('strong', {}, (NOMBRES[r.que] || { perfil: 'Perfil', limites: 'Límites', credito: 'Crédito' }[r.que] || r.que) + ': '), r.por_que))),
    h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-principal', id: 'btn-usar', onclick: () => {
      usarSugerencia(e, s); pintarArmado(); pintar();
      document.getElementById('paso-modulos').scrollIntoView({ behavior: 'smooth' });
    } }, 'Usar esta sugerencia')));
  } }, 'Sugerir módulos');

  // 3) Datos del negocio
  const datos = h('div', { class: 'formulario' });
  function campo(id, etiqueta, valor, alCambiar, { ayuda, ...extra } = {}) {
    const input = h('input', { id, value: valor ?? '', ...extra, oninput: (ev) => alCambiar(ev.target.value) });
    return h('div', { class: 'campo' }, h('label', { for: id }, etiqueta), input, ayuda ? h('p', { class: 'ayuda' }, ayuda) : null);
  }
  function pintarDatos() {
    const idInput = campo('cliente', 'Identificador (carpeta del cliente)', e.cliente, (v) => { e.cliente = v.trim(); e.clienteManual = true; },
      { readonly: editar ? true : null, pattern: '^[a-z0-9][a-z0-9_-]{1,40}$', autocapitalize: 'none', ayuda: 'Minúsculas, números y guiones. Se escribe para confirmar cambios.' });
    const logo = h('input', { type: 'file', id: 'logo', accept: 'image/png,image/jpeg,image/webp', onchange: (ev) => {
      const f = ev.target.files[0];
      if (!f) return;
      if (f.size > 200 * 1024) { alert('El logo debe pesar 200 KB o menos.'); ev.target.value = ''; return; }
      const lector = new FileReader();
      lector.onload = () => { e.logo = lector.result; pintar(); };
      lector.readAsDataURL(f);
    } });
    datos.replaceChildren(
      h('div', { class: 'dos-columnas' },
        campo('nombre', 'Nombre del negocio', e.nombre, (v) => {
          e.nombre = v; if (!e.clienteManual && !editar) { e.cliente = idCliente(v); idInput.querySelector('input').value = e.cliente; } pintar();
        }, { readonly: editar ? true : null, autocomplete: 'off' }),
        idInput,
        campo('rtn', 'RTN (14 dígitos, opcional)', e.rtn, (v) => { e.rtn = v; }, { inputmode: 'numeric', maxlength: 14, readonly: editar ? true : null }),
        editar ? null : campo('nombre-comercial', 'Nombre comercial (opcional)', e.nombre_comercial, (v) => { e.nombre_comercial = v; pintar(); }),
        campo('fecha-inicio', 'Empieza a registrar desde', e.fecha_inicio, (v) => { e.fecha_inicio = v; }, { type: 'date', readonly: editar ? true : null }),
        campo('dueno-correo', 'Correo del dueño (para entrar)', e.dueno_correo, (v) => { e.dueno_correo = v.trim(); }, { type: 'email', readonly: editar ? true : null, autocomplete: 'off' }),
        campo('dueno-nombre', 'Nombre del dueño', e.dueno_nombre, (v) => { e.dueno_nombre = v; }, { readonly: editar ? true : null })),
      h('div', { class: 'colores' },
        h('div', { class: 'campo' }, h('label', { for: 'color-principal' }, 'Color principal'),
          h('input', { type: 'color', id: 'color-principal', value: e.color_principal, oninput: (ev) => { e.color_principal = ev.target.value; pintar(); } })),
        h('div', { class: 'campo' }, h('label', { for: 'color-acento' }, 'Color de acento'),
          h('input', { type: 'color', id: 'color-acento', value: e.color_acento, oninput: (ev) => { e.color_acento = ev.target.value; pintar(); } })),
        editar ? h('p', { class: 'ayuda' }, 'Colores y logo después los cambia el dueño en Ajustes > Mi negocio.')
          : h('div', { class: 'campo' }, h('label', { for: 'logo' }, 'Logo (PNG, JPG o WEBP, hasta 200 KB)'), logo)));
  }
  pintarDatos();

  // 4) Módulos, perfil, régimen  /  5) Límites y licencia  /  palabras
  const armado = h('div', {});
  const problemas = h('div', { class: 'problemas', id: 'problemas', 'aria-live': 'polite' });
  const limites = h('div', {});
  const palabras = h('div', {});
  function pintarArmado() {
    const fila = (m) => {
      const input = h('input', { type: 'checkbox', role: 'switch', id: `mod-${m}`, checked: e.modulos[m] ? true : null,
        disabled: m === 'contabilidad' ? true : null, 'aria-describedby': `mod-${m}-ayuda`,
        onchange: (ev) => { e.modulos[m] = ev.target.checked; estado.textContent = ev.target.checked ? 'Sí' : 'No'; pintar(); } });
      const estado = h('span', { class: 'estado-sino' }, e.modulos[m] ? 'Sí' : 'No');
      const necesita = catalogo.dependencias.filter((d) => d.modulo === m).map((d) => nombreModulo(d.requiere));
      return h('div', { class: 'interruptor', id: `fila-${m}` },
        h('label', { class: 'interruptor-texto', for: `mod-${m}` }, h('strong', {}, nombreModulo(m)),
          h('small', { id: `mod-${m}-ayuda` }, m === 'contabilidad' ? 'Siempre encendido.' : necesita.length ? `Necesita: ${necesita.join(', ')}` : 'No necesita otros.')),
        h('div', { class: 'fila' }, estado, h('span', { class: 'switch' }, input, h('span', {}))));
    };
    const sel = (id, etiqueta, valor, opciones, alCambiar) => h('div', { class: 'campo' }, h('label', { for: id }, etiqueta),
      h('select', { id, onchange: (ev) => { alCambiar(ev.target.value); pintar(); } },
        opciones.map(([v, t]) => h('option', { value: v, selected: v === valor ? true : null }, t))));
    const filaFotos = () => {
      const input = h('input', { type: 'checkbox', role: 'switch', id: 'opc-fotos', checked: e.fotos_productos ? true : null,
        'aria-describedby': 'opc-fotos-ayuda',
        onchange: (ev) => { e.fotos_productos = ev.target.checked; e.fotosEnFicha = true; estado.textContent = ev.target.checked ? 'Sí' : 'No'; pintar(); } });
      const estado = h('span', { class: 'estado-sino' }, e.fotos_productos ? 'Sí' : 'No');
      return h('div', { class: 'interruptor', id: 'fila-fotos' },
        h('label', { class: 'interruptor-texto', for: 'opc-fotos' }, h('strong', {}, 'Fotos de productos'),
          h('small', { id: 'opc-fotos-ayuda' }, 'Fotos livianas en Productos, Vender e Inventario. Necesita Supabase Storage. El dueño también lo cambia en la app.')),
        h('div', { class: 'fila' }, estado, h('span', { class: 'switch' }, input, h('span', {}))));
    };
    armado.replaceChildren(
      h('div', { class: 'interruptores' }, ORDEN_MODULOS.map(fila), filaFotos()),
      h('div', { class: 'dos-columnas' },
        sel('regimen', 'Régimen fiscal', e.regimen_fiscal, [['ninguno', 'Sin CAI (comprobante interno)'], ['fiscal_hn', 'Facturas con CAI (Honduras)']], (v) => { e.regimen_fiscal = v; }),
        sel('perfil', 'Perfil (tamaño)', e.perfil, [['pequeno', 'Pequeño'], ['mediano', 'Mediano'], ['grande', 'Grande']], (v) => { e.perfil = v; }),
        sel('paquete', 'Paquete (solo guía de venta)', e.paquete, [['esencial', 'Esencial'], ['completo', 'Completo']], (v) => { e.paquete = v; })),
      problemas);
    const lim = (k, t) => h('div', { class: 'campo' }, h('label', { for: `lim-${k}` }, t),
      h('input', { type: 'number', id: `lim-${k}`, min: 0, max: 100000, inputmode: 'numeric', value: e.limites[k] ?? '', placeholder: 'sin límite',
        oninput: (ev) => { e.limites[k] = ev.target.value === '' ? null : Math.max(0, Math.floor(Number(ev.target.value))); } }));
    limites.replaceChildren(
      h('div', { class: 'cuatro' }, lim('usuarios', 'Usuarios'), lim('cajas', 'Cajas'), lim('sucursales', 'Sucursales'), lim('bodegas', 'Bodegas')),
      h('p', { class: 'ayuda' }, 'Vacío = sin límite. Bajar un límite nunca desactiva nada: solo impide agregar más.'),
      h('div', { class: 'dos-columnas' },
        h('div', { class: 'campo' }, h('label', { for: 'lic-vence' }, 'Licencia vence el'),
          h('input', { type: 'date', id: 'lic-vence', value: e.licencia.vence_el, oninput: (ev) => { e.licencia.vence_el = ev.target.value; } })),
        h('div', { class: 'campo' }, h('label', { for: 'lic-gracia' }, 'Días de gracia (0 a 60)'),
          h('input', { type: 'number', id: 'lic-gracia', min: 0, max: 60, value: e.licencia.dias_gracia, oninput: (ev) => { e.licencia.dias_gracia = Number(ev.target.value) || 0; } }))));
    // Palabras del rubro: una fila por título que cambia (y se puede agregar otro).
    const titulos = [];
    for (const p of MENU) {
      titulos.push([p.id, `Pestaña "${p.titulo}"`]);
      for (const s of p.subs) titulos.push([`${p.id}/${s.id}`, `${p.titulo} › ${s.titulo}`]);
    }
    titulos.push(['barra/inicio', 'Botón del celular "Inicio"'], ['barra/vender', 'Botón del celular "Vender"'],
      ['barra/caja', 'Botón del celular "Caja"'], ['barra/productos', 'Botón del celular "Productos"']);
    const etiqueta = Object.fromEntries(titulos);
    const filas = Object.keys(e.palabras).map((k) => h('div', { class: 'palabra-fila' },
      h('label', { for: `palabra-${k.replace('/', '-')}` }, etiqueta[k] || k),
      h('input', { id: `palabra-${k.replace('/', '-')}`, value: e.palabras[k], maxlength: 40, placeholder: '(el de siempre)',
        oninput: (ev) => { if (ev.target.value.trim()) e.palabras[k] = ev.target.value; else delete e.palabras[k]; pintar(); } })));
    const otro = h('select', { id: 'palabra-otra', 'aria-label': 'Cambiar otro título' }, h('option', { value: '' }, 'Cambiar otro título…'),
      titulos.filter(([k]) => !(k in e.palabras)).map(([k, t]) => h('option', { value: k }, t)));
    otro.addEventListener('change', () => { if (otro.value) { e.palabras[otro.value] = ''; pintarArmado(); } });
    palabras.replaceChildren(h('div', { class: 'palabras' }, filas.length ? filas : h('p', { class: 'vacio' }, 'Usa las palabras de siempre.'), otro),
      e.campos_orden.length ? h('p', { class: 'ayuda' }, 'Datos de cada ' + (e.palabras['vender/nueva'] || 'venta').toLowerCase().replace(/^nueva? /, '') + ' que pide este rubro: ',
        e.campos_orden.map((c) => c.etiqueta).join(', '), '. (Se guardan en la configuración; la app todavía no los pide: ver app/PENDIENTES.md.)') : null);
  }
  pintarArmado();

  function pintarProblemas() {
    const activos = { ...e.modulos, fiscal_hn: e.regimen_fiscal === 'fiscal_hn' };
    const nombres = { ...NOMBRES };
    const lista = problemasDependencias(activos, catalogo.dependencias, nombres);
    for (const m of ORDEN_MODULOS) document.getElementById(`fila-${m}`)?.classList.toggle('falta', lista.some((p) => p.modulo === m || p.requiere === m));
    problemas.replaceChildren(...lista.map((p) => msg('error', p.texto)));
    for (const b of acciones.querySelectorAll('[data-necesita-ok]')) b.disabled = lista.length > 0;
    return lista;
  }

  // 6) Crear o aplicar
  const acciones = h('div', { class: 'formulario' });
  const resultado = h('div', { id: 'resultado', 'aria-live': 'polite' });
  if (!editar) {
    const conexion = h('div', { class: 'campo', hidden: true },
      h('label', { for: 'conexion' }, 'Conexión real (sin clave): postgresql://postgres@db.REF.supabase.co:5432/postgres'),
      h('input', { id: 'conexion', autocomplete: 'off', oninput: (ev) => { e.conexion = ev.target.value.trim(); } }),
      h('label', { for: 'confirmacion' }, 'Para confirmar, escriba la referencia del proyecto de Supabase'),
      h('input', { id: 'confirmacion', autocomplete: 'off', oninput: (ev) => { e.confirmacion = ev.target.value.trim(); } }),
      h('p', { class: 'ayuda' }, 'La clave de la base sale de ~/.pgpass en esta computadora; nunca se escribe aquí. El dueño debe estar registrado en Supabase antes.'));
    const destino = h('fieldset', { class: 'opciones' }, h('legend', {}, '¿Dónde se crea?'),
      h('label', {}, h('input', { type: 'radio', name: 'destino', value: 'demo', checked: true, onchange: () => { e.destino = 'demo'; conexion.hidden = true; } }), 'Base local de demostración'),
      h('label', {}, h('input', { type: 'radio', name: 'destino', value: 'real', onchange: () => { e.destino = 'real'; conexion.hidden = false; } }), 'Base real del cliente'));
    const crear = h('button', { type: 'button', class: 'boton boton-principal boton-grande', id: 'btn-crear', dataset: { necesitaOk: '1' } }, 'Crear');
    crear.addEventListener('click', async () => {
      resultado.replaceChildren();
      const falta = [];
      if (!e.nombre.trim()) falta.push('el nombre del negocio');
      if (!/^[a-z0-9][a-z0-9_-]{1,40}$/.test(e.cliente)) falta.push('un identificador válido');
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e.dueno_correo)) falta.push('el correo del dueño');
      if (e.rtn && !/^[0-9]{14}$/.test(e.rtn)) falta.push('un RTN de 14 dígitos (o déjelo vacío)');
      if (!e.licencia.vence_el) falta.push('la fecha de la licencia');
      if (e.destino === 'real' && (!e.conexion || !e.confirmacion)) falta.push('la conexión real y su confirmación');
      if (falta.length) { resultado.append(msg('error', 'Falta ' + falta.join(', ') + '.')); return; }
      if (pintarProblemas().length) return;
      const listo = ocupar(crear, 'Creando… (no cierre la página)');
      try {
        const r = await api('/api/crear', { ficha: fichaDe(e), plantilla: e.plantilla, logo: e.logo,
          app: { palabras: e.palabras, campos_orden: e.campos_orden }, conexion: e.destino === 'real' ? e.conexion : null, confirmacion: e.confirmacion });
        resultado.replaceChildren(h('div', { class: 'mensaje mensaje-ok resultado', role: 'status' },
          h('p', {}, h('strong', {}, `Listo: "${e.nombre}" quedó creado.`)),
          h('dl', {}, h('dt', {}, 'Enlace de la app'), h('dd', {}, r.enlace ? h('a', { href: r.enlace, target: '_blank', rel: 'noopener', id: 'enlace-app' }, r.enlace) : 'La app publicada del cliente'),
            h('dt', {}, 'Correo del dueño'), h('dd', { id: 'dato-correo' }, r.dueno.correo),
            h('dt', {}, 'Clave'), h('dd', { id: 'dato-clave' }, r.dueno.clave),
            h('dt', {}, 'Ficha'), h('dd', {}, `clientes/${r.cliente}/ficha.json`)),
          r.avisos.map((a) => h('p', {}, a))));
      } catch (err) {
        resultado.replaceChildren(msg('error', err.message));
      } finally { listo(); pintarProblemas(); }
    });
    acciones.append(destino, conexion, h('div', { class: 'botones' }, crear));
  } else {
    const diferencias = h('div', { id: 'diferencias-zona' });
    const ver = h('button', { type: 'button', class: 'boton boton-principal', id: 'btn-ver-cambios', dataset: { necesitaOk: '1' } }, 'Ver cambios');
    ver.addEventListener('click', async () => {
      resultado.replaceChildren(); diferencias.replaceChildren();
      if (pintarProblemas().length) return;
      const listo = ocupar(ver, 'Revisando…');
      try {
        const r = await api('/api/vista_previa', { cliente: e.cliente, ficha: fichaDe(e), app: { palabras: e.palabras, campos_orden: e.campos_orden } });
        diferencias.append(h('h3', {}, 'Vista previa (todavía no se cambia nada)'), h('pre', { class: 'diferencias', id: 'diferencias' }, r.texto));
        if (!r.ok) { diferencias.append(msg('error', 'Así no se puede aplicar: ' + (r.problemas.join(' ') || 'revise arriba.'))); return; }
        const confirmar = h('input', { id: 'confirmar-cliente', autocomplete: 'off' });
        const aplicar = h('button', { type: 'button', class: 'boton boton-principal', id: 'btn-aplicar' }, 'Aplicar cambios');
        aplicar.addEventListener('click', async () => {
          if (confirmar.value.trim() !== e.cliente) { resultado.replaceChildren(msg('error', `Para aplicar escriba exactamente: ${e.cliente}`)); return; }
          const fin = ocupar(aplicar, 'Aplicando…');
          try {
            const a = await api('/api/aplicar', { cliente: e.cliente, confirmacion: confirmar.value.trim() });
            resultado.replaceChildren(msg('ok', 'Cambios aplicados. ' + (a.texto || '')));
            diferencias.replaceChildren();
          } catch (err) { resultado.replaceChildren(msg('error', err.message)); fin(); }
        });
        diferencias.append(r.hay_cambios ? h('div', { class: 'formulario' },
          h('div', { class: 'campo' }, h('label', { for: 'confirmar-cliente' }, `Para aplicar escriba el identificador del cliente: ${e.cliente}`), confirmar),
          h('p', { class: 'ayuda' }, 'Nunca se borran datos: apagar un módulo solo impide operaciones nuevas.'),
          h('div', { class: 'botones' }, aplicar)) : msg('info', 'No hay cambios en módulos, perfil, licencia, límites ni fotos. Las palabras del rubro se guardan al aplicar.'));
      } catch (err) { resultado.replaceChildren(msg('error', err.message)); } finally { listo(); pintarProblemas(); }
    });
    const abrir = h('button', { type: 'button', class: 'boton', id: 'btn-abrir-app' }, 'Abrir la app del cliente');
    abrir.addEventListener('click', () => abrirApp(e.cliente, resultado, abrir));
    acciones.append(h('div', { class: 'botones' }, ver, original && original.conexion && original.conexion.includes('host=') ? abrir : null), diferencias);
  }

  if (!editar) izquierda.append(paso('rubro', 'Rubro del negocio', rubros), paso('cuestionario', 'Cuestionario de la visita', cuestionario, h('div', { class: 'botones' }, btnSugerir), sugerencias));
  izquierda.append(paso('datos', 'Datos del negocio', datos), paso('modulos', 'Módulos', armado),
    paso('limites', 'Límites del contrato y licencia', limites), paso('palabras', 'Palabras del rubro', palabras),
    paso('final', editar ? 'Aplicar cambios' : 'Crear', acciones, resultado));
  pintar();
}

async function abrirApp(cliente, zona, boton) {
  const listo = ocupar(boton, 'Abriendo…');
  try {
    const r = await api('/api/abrir_app', { cliente });
    zona.replaceChildren(h('div', { class: 'mensaje mensaje-info resultado' }, h('dl', {},
      h('dt', {}, 'App del cliente'), h('dd', {}, h('a', { href: r.enlace, target: '_blank', rel: 'noopener', id: 'enlace-app' }, r.enlace)),
      h('dt', {}, 'Correo'), h('dd', {}, r.correo), h('dt', {}, 'Clave (demo)'), h('dd', {}, r.clave))));
  } catch (err) { zona.replaceChildren(msg('error', err.message)); } finally { listo(); }
}

// Vista previa del menú: el mismo MENU de la app, con módulos encendidos, permisos del puesto y palabras del rubro.
function pintarVistaPrevia(caja, e) {
  const modulos = new Set([...ORDEN_MODULOS.filter((m) => e.modulos[m]), ...(e.regimen_fiscal === 'fiscal_hn' ? ['fiscal_hn'] : [])]);
  const permisos = new Set((catalogo.permisos || {})[e.puesto] || []);
  const menu = menuPara(modulos, permisos, e.palabras);
  const nombre = e.nombre_comercial || e.nombre || 'Nombre del negocio';
  const ini = nombre.trim().split(/\s+/).map((x) => x[0]).filter(Boolean);
  const logo = h('div', { class: 'marca-logo', 'aria-hidden': 'true' },
    e.logo ? h('img', { src: e.logo, alt: '' }) : ((ini[0] || 'M') + (ini.length > 1 ? ini[ini.length - 1] : '')).toUpperCase());
  const app = h('div', { class: 'vp-app', id: 'vista-menu' },
    h('header', { class: 'encabezado' },
      h('div', { class: 'encabezado-fila' }, h('div', { class: 'marca' }, logo, h('span', { class: 'marca-nombre' }, nombre))),
      h('nav', { class: 'pestanas', 'aria-label': 'Pestañas que verá el cliente' }, menu.map((p, i) =>
        h('span', { class: 'pestana' + (p.final ? ' pestana-final' : ''), 'aria-current': i === 0 ? 'page' : null }, icono(p.icono), h('span', {}, p.titulo))))),
    h('div', { class: 'vp-cuerpo' }, menu.map((p) => h('div', { class: 'vp-grupo' }, h('h3', { class: 'titulo-icono' }, icono(p.icono), p.titulo),
      h('div', { class: 'chips' }, p.subs.map((s) => h('span', { class: 'chip' }, icono(s.icono), s.titulo)))))));
  app.style.setProperty('--color-principal', e.color_principal);
  app.style.setProperty('--color-acento', e.color_acento);
  const puestos = h('div', { class: 'segmentos', role: 'group', 'aria-label': 'Puesto' },
    [['dueno', 'Dueño'], ['cajero', 'Cajero'], ['vendedor', 'Vendedor']].map(([v, t]) => h('button', {
      type: 'button', class: 'segmento', id: `puesto-${v}`, 'aria-pressed': String(e.puesto === v),
      onclick: () => { e.puesto = v; pintarVistaPrevia(caja, e); } }, t)));
  caja.replaceChildren(h('div', { class: 'tarjeta' }, h('h2', {}, 'Así verá el menú'),
    h('p', { class: 'ayuda' }, 'Solo lo que tendrá encendido; nada gris ni bloqueado.'), puestos), app);
}

// ---------------- Clientes ----------------
async function pantallaClientes(vista) {
  vista.append(h('div', { class: 'titulo-con-boton' }, h('h1', {}, 'Clientes'), h('a', { class: 'boton boton-principal', href: '#/armar' }, 'Cliente nuevo')),
    h('p', { class: 'cargando', role: 'status' }, 'Consultando las bases…'));
  const lista = await api('/api/clientes');
  const detalle = h('div', { id: 'detalle-cliente', 'aria-live': 'polite' });
  const uso = (c) => Object.entries(c.limites || {}).map(([k, d]) => {
    const cerca = c.cerca_del_limite.includes(k);
    return h('div', { class: 'uso' + (cerca ? ' cerca' : ''), dataset: { limite: k } },
      `${k}: ${d.uso ?? '?'} de ${d.limite ?? 'sin límite'}${cerca ? ' (!) 80 % o más' : ''}`);
  });
  const filas = lista.map((c) => h('tr', { id: `cliente-${c.cliente}` },
    h('td', { 'data-titulo': 'Cliente' }, h('strong', {}, c.nombre || c.cliente), h('div', { class: 'suave' }, c.cliente)),
    h('td', { 'data-titulo': 'Rubro' }, c.rubro || '-'),
    h('td', { 'data-titulo': 'Paquete' }, c.paquete || '-'),
    h('td', { 'data-titulo': 'Módulos' }, c.modulos.map(nombreModulo).join(', ')),
    h('td', { 'data-titulo': 'Uso / límite' }, uso(c)),
    h('td', { 'data-titulo': 'Licencia' }, c.vence || 'sin licencia'),
    h('td', { 'data-titulo': 'Núcleo' }, c.nucleo || '?'),
    h('td', { 'data-titulo': 'Solicitudes' }, c.solicitudes ? h('button', { type: 'button', class: 'boton', onclick: async () => {
      const s = await api('/api/solicitudes?id=' + encodeURIComponent(c.cliente));
      detalle.replaceChildren(h('div', { class: 'tarjeta' }, h('h2', {}, `Solicitudes pendientes · ${c.nombre}`),
        s.map((x) => h('div', { class: 'solicitud' }, h('p', {}, h('strong', {}, `#${x.numero} ${x.tipo}`), ` · ${x.fecha}`), h('p', {}, x.detalle)))));
    } }, `${c.solicitudes} pendiente(s)`) : 'ninguna'),
    h('td', { 'data-titulo': '' }, h('div', { class: 'botones' },
      h('a', { class: 'boton', href: `#/editar/${encodeURIComponent(c.cliente)}` }, 'Cambiar'),
      h('button', { type: 'button', class: 'boton', dataset: { exportar: c.cliente }, onclick: () => exportarSupabase(c, detalle) }, 'Exportar para Supabase')))));
  vista.replaceChildren(h('div', { class: 'titulo-con-boton' }, h('h1', {}, 'Clientes'), h('a', { class: 'boton boton-principal', href: '#/armar' }, 'Cliente nuevo')),
    h('div', { class: 'tarjeta' }, lista.length === 0 ? h('p', { class: 'vacio' }, 'Todavía no hay clientes.') : h('div', { class: 'tabla-envoltura' },
      h('table', { class: 'tabla', id: 'tabla-clientes' }, h('thead', {}, h('tr', {}, ['Cliente', 'Rubro', 'Paquete', 'Módulos', 'Uso / límite', 'Licencia vence', 'Núcleo', 'Solicitudes', ''].map((t) => h('th', {}, t)))),
        h('tbody', {}, filas))),
    h('p', { class: 'ayuda' }, '(!) = usa el 80 % o más de algún límite: ofrézcale una ampliación.')), detalle);
}

// "Exportar para Supabase": descarga el SQL que crea la empresa del cliente en su proyecto real.
function exportarSupabase(c, detalle) {
  const dueno = h('input', { id: 'exp-id-dueno', autocomplete: 'off', placeholder: '00000000-0000-0000-0000-000000000000' });
  const prov = h('input', { id: 'exp-id-proveedor', autocomplete: 'off' });
  const zona = h('div', { 'aria-live': 'polite', id: 'exp-resultado' });
  const boton = h('button', { type: 'button', class: 'boton boton-principal', id: 'btn-exportar-sql' }, 'Descargar SQL');
  boton.addEventListener('click', async () => {
    zona.replaceChildren();
    const listo = ocupar(boton, 'Armando…');
    try {
      const r = await api('/api/exportar_supabase', { cliente: c.cliente, id_dueno: dueno.value.trim(), id_proveedor: prov.value.trim() });
      const enlace = h('a', { href: URL.createObjectURL(new Blob([r.sql], { type: 'application/sql' })), download: r.nombre, id: 'exp-descargar' }, r.nombre);
      zona.replaceChildren(h('div', { class: 'mensaje mensaje-ok resultado', role: 'status' },
        h('p', {}, h('strong', {}, 'Listo. '), 'Descargue: ', enlace, ` (también quedó en ${r.archivo}).`),
        r.falta_id ? h('p', {}, 'Falta el id del dueño: ábralo y cambie PEGUE-AQUI-EL-ID-DEL-DUENO por su User UID.') : null,
        h('p', {}, 'Péguelo en Supabase > SQL Editor después de instalar todas las partes (docs/SUPABASE.md, paso 8).')));
      enlace.click();
    } catch (err) { zona.replaceChildren(msg('error', err.message)); } finally { listo(); }
  });
  detalle.replaceChildren(h('div', { class: 'tarjeta', id: 'exportar-supabase' }, h('h2', {}, `Exportar para Supabase · ${c.nombre || c.cliente}`),
    h('p', { class: 'ayuda' }, 'Arma el SQL que crea esta empresa en el proyecto real de Supabase. Primero cree al dueño en Authentication > Users > Add user y copie su User UID.'),
    h('div', { class: 'campo' }, h('label', { for: 'exp-id-dueno' }, 'User UID del dueño (puede dejarlo vacío y pegarlo después en el archivo)'), dueno),
    h('div', { class: 'campo' }, h('label', { for: 'exp-id-proveedor' }, 'User UID de su usuario de soporte en ese proyecto (opcional)'), prov),
    h('div', { class: 'botones' }, boton), zona));
  dueno.focus();
}

// ---------------- Demostración ----------------
async function pantallaDemo(vista) {
  const zona = h('div', { id: 'resultado-demo', 'aria-live': 'polite' });
  vista.append(h('h1', {}, 'Demostración para la visita'),
    h('p', { class: 'suave' }, 'Crea un negocio de prueba con datos falsos del rubro (en la base local) y abre su app para enseñarla.'),
    h('div', { class: 'tarjeta' }, h('div', { class: 'rubros' }, catalogo.plantillas.map((p) => {
      const b = h('button', { type: 'button', class: 'rubro', id: `demo-${p.id}` }, h('strong', {}, `Crear demo de ${p.nombre}`), h('span', {}, p.descripcion));
      b.addEventListener('click', async () => {
        zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Creando la demostración…'));
        try {
          const r = await api('/api/demo', { rubro: p.id });
          zona.replaceChildren(h('div', { class: 'mensaje mensaje-ok resultado' },
            h('p', {}, h('strong', {}, r.ya_existia ? `La demo "${r.nombre}" ya existía: se abre la misma.` : `Demo "${r.nombre}" lista.`)),
            h('dl', {}, h('dt', {}, 'Enlace'), h('dd', {}, h('a', { href: r.enlace, target: '_blank', rel: 'noopener', id: 'enlace-demo' }, r.enlace)),
              h('dt', {}, 'Clave de todos'), h('dd', {}, r.clave),
              ...r.usuarios.flatMap((u) => [h('dt', {}, u.puesto), h('dd', {}, u.correo)]))));
        } catch (err) { zona.replaceChildren(msg('error', err.message)); }
      });
      return b;
    }))), zona);
}

// ---------------- Arranque ----------------
(async () => {
  try {
    const s = await api('/api/estado');
    if (s.sesion) await iniciarApp(); else mostrarEntrar();
  } catch (e) { raiz.replaceChildren(msg('error', e.message)); }
})();
