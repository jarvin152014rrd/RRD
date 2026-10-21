// Ajustes · Usuarios y permisos: lista con "X de Y usados" (límite del contrato), agregar usuario
// con clave temporal (Edge Function "crear-usuario"; en la demo la imita servidor_app.js),
// desactivar, asignar sucursales, cerrar sesión a distancia (con config.modo "supabase" por la
// Edge Function "cerrar-sesion-remota", que además le quita la renovación del token; en la demo,
// la RPC cerrar_sesion_usuario), "Solicitar ampliación" al proveedor
// y la tabla de permisos por puesto (editable SOLO por el dueño, con motivo: cambiar_permiso_rol).
import { rpc, leer, escribir, funcion, config } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { h, icono, aviso, errorSimple, campo, conBoton, pedirMotivo, dialogo, cajaError, titulo, filaIcono, chip, chipEstado, tabla, mensaje } from '../ui.js';

const PUESTOS = { dueno: 'Dueño', admin: 'Administrador', cajero: 'Cajero', vendedor: 'Vendedor', contador: 'Contador', proveedor: 'Proveedor' };
const EDITABLES = ['admin', 'cajero', 'vendedor', 'contador'];

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const yo = perfilActual();
  const soyDueno = yo.rol.codigo === 'dueno';
  const [perfil, usuarios, sucursales, asignadas] = await Promise.all([
    rpc('mi_perfil', { p_empresa_id: E }),
    leer('usuario_empresa', { empresa_id: E }, { orden: 'creado_en.asc' }),
    leer('sucursal', { empresa_id: E, activa: true }, { orden: 'codigo.asc' }),
    leer('usuario_sucursal', { empresa_id: E, activo: true }).catch(() => [])]);
  if (!ctx.sigueVigente()) return;
  const lim = (perfil.limites && perfil.limites.usuarios) || { uso: usuarios.filter((u) => u.activo).length, limite: null };
  const lleno = lim.limite !== null && lim.uso >= lim.limite;
  const nomSuc = new Map(sucursales.map((s) => [s.id, s.nombre]));
  const recargar = async () => { vista.replaceChildren(); await mostrar(vista, ctx); };
  // Puede tocar a este usuario: no a sí mismo ni al proveedor; dueños solo el dueño; el admin solo cajero y vendedor.
  const puedeTocar = (u) => u.user_id !== yo.usuario.id && u.rol !== 'proveedor' && (soyDueno ? true : ['cajero', 'vendedor'].includes(u.rol));

  const solicitar = h('button', { type: 'button', class: 'boton', id: 'solicitar-ampliacion', onclick: () => pedirAmpliacion(lim) }, 'Solicitar ampliación');
  const cabecera = h('div', { class: 'titulo-con-boton' },
    h('div', {}, titulo('h1', 'usuarios', 'Usuarios', { id: 't-usr' }),
      h('p', { class: 'ayuda' }, h('span', { dataset: { dato: 'uso-usuarios' } }, lim.limite === null ? `${lim.uso} usuario(s) activos (sin límite en su plan).` : `${lim.uso} de ${lim.limite} usados.`),
        lleno ? [' ', chip('Plan lleno', 'dorado')] : null)),
    h('div', { class: 'botones' },
      h('button', { type: 'button', class: 'boton boton-principal', id: 'agregar-usuario', onclick: () => agregar() }, icono('cliente_mas'), 'Agregar usuario'),
      puede('proveedor.solicitar') && lim.limite !== null ? solicitar : null));

  const filas = usuarios.filter((u) => u.rol !== 'proveedor').map((u) => {
    const sucs = asignadas.filter((a) => a.user_id === u.user_id).map((a) => nomSuc.get(a.sucursal_id) || '¿?');
    const tocar = puedeTocar(u) && u.activo;
    return filaIcono({
      icono: u.rol === 'dueno' ? 'estrella' : 'usuario', color: u.activo ? 'azul' : 'neutro',
      titulo: [h('strong', {}, u.nombre || '(sin nombre)'), u.user_id === yo.usuario.id ? [' ', chip('Usted', 'azul')] : null],
      detalle: `${PUESTOS[u.rol] || u.rol} · ${sucs.length ? 'Sucursal: ' + sucs.join(', ') : 'Todas las sucursales'}`,
      derecha: chipEstado(u.activo ? 'activo' : 'inactivo'),
      abajo: tocar ? h('div', { class: 'botones' },
        sucursales.length > 1 ? h('button', { type: 'button', class: 'boton', onclick: () => elegirSucursales(u, sucs) }, 'Sucursales') : null,
        h('button', { type: 'button', class: 'boton', onclick: () => accion(u, 'cerrar') }, 'Cerrar sesión'),
        h('button', { type: 'button', class: 'boton boton-peligro', onclick: () => accion(u, 'desactivar') }, 'Desactivar')) : null,
      props: { dataset: { usuario: u.user_id } },
    });
  });

  async function accion(u, que) {
    const cerrar = que === 'cerrar';
    const ok = await pedirMotivo({ titulo: cerrar ? `Cerrar la sesión de ${u.nombre}` : `Desactivar a ${u.nombre}`, peligro: !cerrar,
      textoBoton: cerrar ? 'Cerrar sesión' : 'Desactivar',
      explicacion: cerrar ? 'Tendrá que volver a entrar con su clave en todos sus equipos.' : 'Ya no podrá entrar. No se borra nada de lo que hizo.',
      accion: (motivo) => (cerrar && config.modo === 'supabase'
        ? funcion('cerrar-sesion-remota', { empresa_id: E, user_id: u.user_id, motivo })
        : rpc(cerrar ? 'cerrar_sesion_usuario' : 'desactivar_usuario_empresa', { p_empresa_id: E, p_user_id: u.user_id, p_motivo: motivo })) });
    if (ok) { aviso(cerrar ? `Sesión cerrada · ${u.nombre} tendrá que volver a entrar` : `Usuario desactivado · ${u.nombre} ya no puede entrar`); recargar(); }
  }

  function elegirSucursales(u, actuales) {
    const marcas = sucursales.map((s) => ({ s, c: h('input', { type: 'checkbox', checked: actuales.includes(s.nombre) }) }));
    const zona = h('div', { 'aria-live': 'assertive' });
    const { cerrar } = dialogo(`Sucursales de ${u.nombre}`,
      h('p', { class: 'ayuda' }, 'Sin marcar ninguna = trabaja en todas.'),
      marcas.map(({ s, c }) => h('label', { class: 'opcion-check' }, c, ` ${s.codigo} · ${s.nombre}`)), zona,
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => cerrar() }, 'Cancelar'),
        h('button', { type: 'button', class: 'boton boton-principal', onclick: async () => {
          const ids = marcas.filter((x) => x.c.checked).map((x) => x.s.id);
          cerrar();
          const ok = await pedirMotivo({ titulo: 'Cambiar sucursales', textoBoton: 'Guardar',
            accion: (motivo) => rpc('asignar_sucursales_usuario', { p_empresa_id: E, p_user_id: u.user_id, p_sucursales: ids, p_motivo: motivo }) });
          if (ok) { aviso(`Sucursales guardadas · ${u.nombre}`); recargar(); }
        } }, 'Siguiente')));
  }

  function pedirAmpliacion(l) {
    const detalle = h('textarea', { id: 'ampliacion-detalle', maxlength: 1000 });
    detalle.value = `Necesitamos más usuarios: hoy usamos ${l.uso} de ${l.limite}.`;
    const zona = h('div', { 'aria-live': 'assertive' });
    const enviar = h('button', { type: 'button', class: 'boton boton-principal', id: 'ampliacion-enviar' }, 'Enviar solicitud');
    const { cerrar } = dialogo('Solicitar ampliación', h('p', { class: 'ayuda' }, 'Le llega a su proveedor. Él le responde.'),
      campo('¿Qué necesita?', detalle), zona,
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => cerrar() }, 'Cancelar'), enviar));
    enviar.addEventListener('click', async () => {
      if (detalle.value.trim().length < 5) { zona.replaceChildren(errorSimple('Escriba qué necesita (5 letras o más).')); return; }
      const r = await conBoton(enviar, zona, () => escribir('solicitar_al_proveedor', { p_empresa_id: E, p_tipo: 'ampliacion', p_detalle: detalle.value.trim() }), 'Enviando…');
      if (r) { cerrar(); aviso('Solicitud enviada · su proveedor le responde'); }
    });
  }

  function agregar() {
    const correo = h('input', { id: 'nuevo-correo', type: 'email', autocomplete: 'off' });
    const nombre = h('input', { id: 'nuevo-nombre', type: 'text', maxlength: 120 });
    const puestos = soyDueno ? EDITABLES : ['cajero', 'vendedor'];
    const rol = h('select', { id: 'nuevo-rol' }, puestos.map((p) => h('option', { value: p }, PUESTOS[p])));
    rol.value = 'vendedor';
    const clave = h('input', { id: 'nuevo-clave', type: 'text', autocomplete: 'off', minlength: 8 });
    const zona = h('div', { 'aria-live': 'assertive', id: 'agregar-error' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Agregar');
    const form = h('form', { class: 'formulario', novalidate: true },
      lleno ? mensaje('info', `Ya usa ${lim.uso} de ${lim.limite} usuarios de su plan.`) : null,
      campo('Correo', correo), campo('Nombre', nombre), campo('Puesto', rol),
      campo('Clave temporal', clave, 'Mínimo 8 letras o números. Désela en persona; la cambia al entrar.'), zona, boton,
      h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => recargar() }, 'Cancelar'));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      zona.replaceChildren();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo.value.trim())) { zona.append(errorSimple('Escriba un correo válido.')); return; }
      if (nombre.value.trim().length < 2) { zona.append(errorSimple('Escriba el nombre.')); return; }
      if (clave.value.length < 8) { zona.append(errorSimple('La clave temporal lleva 8 letras o más.')); return; }
      let error = null;
      const r = await conBoton(boton, null, () => funcion('crear-usuario', { empresa_id: E, correo: correo.value.trim(), nombre: nombre.value.trim(),
        rol: rol.value, clave: clave.value }).catch((e) => { error = e; return null; }), 'Agregando…');
      if (r) {
        aviso(r.ya_tenia_cuenta ? `Usuario agregado · ${nombre.value.trim()} ya tenía cuenta: entra con la clave que ya usaba`
          : `Usuario agregado · ${nombre.value.trim()} ya puede entrar`);
        recargar(); return;
      }
      if (error) {
        zona.append(await cajaError(error));
        if (error.clave === 'LIMITE_CONTRATO' && puede('proveedor.solicitar')) {
          zona.append(h('button', { type: 'button', class: 'boton boton-ancho', id: 'solicitar-desde-error', onclick: () => pedirAmpliacion(lim) }, 'Solicitar ampliación'));
        }
      }
    });
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-nuevo-usr' },
      titulo('h1', 'cliente_mas', 'Agregar usuario', { id: 't-nuevo-usr' }), form));
    correo.focus();
  }

  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-usr' }, cabecera, h('div', { class: 'lista-filas', id: 'lista-usuarios' }, filas)));
  if (soyDueno) vista.append(await tablaPermisos(E, recargar));
}

// Tabla de casillas: permisos x puestos. Solo el dueño la ve y la cambia (con motivo).
async function tablaPermisos(E) {
  const [permisos, rp] = await Promise.all([leer('permiso', {}, { orden: 'codigo.asc', limite: 500 }),
    leer('rol_permiso', { empresa_id: E }, { limite: 1000 })]);
  const tiene = new Set(rp.map((x) => `${x.rol}|${x.permiso}`));
  const SOLO_DUENO = ['permisos.editar', 'periodos.reabrir', 'soporte.otorgar', 'empresa.configurar'];
  // En el celular cada permiso es una tarjeta con una casilla por puesto (ui.tabla).
  const lista = permisos.filter((p) => !SOLO_DUENO.includes(p.codigo));
  const tablaPerm = tabla({ props: { id: 'tabla-permisos', class: 'permisos-tabla' },
    columnas: [{ titulo: 'Permiso' }, ...EDITABLES.map((r) => ({ titulo: PUESTOS[r] }))],
    filas: lista.map((p) => [
      h('span', {}, p.descripcion || p.codigo, h('span', { class: 'detalle' }, ` (${p.codigo})`)),
      ...EDITABLES.map((r) => {
        const c = h('input', { type: 'checkbox', checked: tiene.has(`${r}|${p.codigo}`), 'aria-label': `${PUESTOS[r]}: ${p.descripcion || p.codigo}`,
          dataset: { rol: r, permiso: p.codigo } });
        c.addEventListener('change', async () => {
          const otorgar = c.checked;
          const ok = await pedirMotivo({ titulo: otorgar ? 'Dar permiso' : 'Quitar permiso', textoBoton: otorgar ? 'Dar permiso' : 'Quitar permiso',
            explicacion: `${PUESTOS[r]}: ${p.descripcion || p.codigo}. Vale para todos los usuarios de ese puesto.`,
            accion: (motivo) => rpc('cambiar_permiso_rol', { p_empresa_id: E, p_rol: r, p_permiso: p.codigo, p_otorgar: otorgar, p_motivo: motivo }) });
          if (ok) aviso(`Permiso guardado · ${PUESTOS[r]}: ${otorgar ? 'ahora puede' : 'ya no puede'} ${(p.descripcion || p.codigo).toLowerCase()}`); else c.checked = !otorgar;
        });
        return c;
      })]) });
  return h('section', { class: 'tarjeta', 'aria-labelledby': 't-perm' },
    titulo('h2', 'candado', 'Qué puede hacer cada puesto', { id: 't-perm' }),
    h('p', { class: 'ayuda' }, 'Solo el dueño cambia esta tabla. Cada cambio pide motivo y queda en la bitácora.'),
    tablaPerm);
}
