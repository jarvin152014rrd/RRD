// Ajustes · "Sin internet" (app 0.14.0, núcleo 0.20.0; docs/SIN_INTERNET.md y docs/SIN_INTERNET_GUIA.md).
//   1. Este equipo: ¿puede guardar ventas? (persist, incógnito, iPhone sin instalar), preparar (registrar el equipo,
//      reservar números de la caja, bajar los precios), números que quedan, subir ahora y el respaldo en archivo.
//   2. Ventas de otros usuarios guardadas en este equipo (M2: solo con ventas.subir_ajenas, con motivo) y subir un
//      respaldo de otro equipo.
//   3. Reglas (solo el dueño): horas, topes y tamaño del bloque; que los cajeros vendan sin internet.
//   4. Equipos y números (dueño y supervisor): desactivar un equipo perdido (G3) y conciliar sus números.
import { rpc, escribir, leer } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { dinero, fechaHora, aCentavos, paraCampo } from '../formato.js';
import { h, aviso, cajaError, campo, conBoton, titulo, mensaje, chip, filaIcono, estadoVacio, pedirMotivo, errorSimple } from '../ui.js';
import * as si from '../sin_internet.js';

// replaceChildren escribe "null" si recibe un vacío y no aplana listas: se limpian antes.
const poner = (el, ...xs) => el.replaceChildren(...xs.flat(Infinity).filter((x) => x !== null && x !== undefined && x !== false));

export async function mostrar(vista, ctx) {
  const perfil = perfilActual();
  const E = empresaId();
  const zonaEquipo = h('section', { class: 'tarjeta', id: 'si-equipo', 'aria-labelledby': 't-si-equipo' });
  vista.append(zonaEquipo);
  await pintarEquipo();

  if (puede('ventas.subir_ajenas')) {
    const zona = h('section', { class: 'tarjeta', id: 'si-ajenas', 'aria-labelledby': 't-si-ajenas' });
    vista.append(zona);
    await pintarAjenas(zona);
  }
  if (puede('empresa.configurar')) vista.append(await tarjetaReglas());
  if (puede('equipos.administrar') || puede('ventas.resolver_sin_internet')) {
    const zona = h('section', { class: 'tarjeta', id: 'si-equipos', 'aria-labelledby': 't-si-equipos' });
    vista.append(zona);
    await pintarEquipos(zona);
  }
  if (!ctx.sigueVigente()) return;

  // ---------------- 1. Este equipo ----------------
  async function pintarEquipo() {
    const [sop, eq, cat, bloques, pend] = await Promise.all([si.soporte(), si.equipoLocal(E), si.catalogoLocal(E, perfil.usuario.id),
      si.bloquesLocales(E), si.pendientes(E)]);
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const activos = bloques.filter((b) => b.estado === 'activo');
    const nombre = h('input', { id: 'si-nombre-equipo', type: 'text', maxlength: 60, placeholder: 'Ej.: Caja 1 - computadora' });
    const preparar = h('button', { type: 'button', class: 'boton boton-principal', id: 'si-preparar' },
      cat ? 'Actualizar precios y números' : 'Preparar para trabajar sin internet');
    preparar.addEventListener('click', async () => {
      const r = await conBoton(preparar, zonaError, () => si.preparar(perfil, { nombre: nombre.value.trim() || null }), 'Preparando…');
      if (r) {
        aviso(r.soporte.listo ? 'Equipo preparado para vender sin internet.' : 'Equipo preparado, pero: ' + r.soporte.razon, r.soporte.listo ? 'ok' : 'info', 8000);
        pintarEquipo();
      }
    });
    const subirAhora = h('button', { type: 'button', class: 'boton', id: 'si-subir' }, 'Subir ahora');
    subirAhora.addEventListener('click', async () => {
      const r = await conBoton(subirAhora, zonaError, () => si.subir(E), 'Subiendo…');
      if (r) { aviso(r.sin_conexion ? 'No hay conexión: siguen guardadas en el equipo.' : `Subidas: ${r.subidas + r.ya_estaban}. Por resolver: ${r.por_resolver}.`, r.sin_conexion ? 'error' : 'ok'); pintarEquipo(); }
    });
    const respaldo = h('button', { type: 'button', class: 'boton', id: 'si-respaldo' }, 'Guardar respaldo de las ventas por subir');
    respaldo.addEventListener('click', async () => {
      const datos = await si.respaldo(E);
      const a = h('a', { href: URL.createObjectURL(new Blob([JSON.stringify(datos, null, 1)], { type: 'application/json' })),
        download: `respaldo-ventas-sin-internet-${new Date().toISOString().slice(0, 10)}.json` });
      document.body.append(a); a.click(); a.remove();
      aviso(`Respaldo guardado (${datos.ventas.length} venta(s)). Guárdelo bien: lo sube el dueño en otro equipo.`, 'ok', 8000);
    });
    const relojMal = si.relojMal(cat);
    poner(zonaEquipo, 
      titulo('h1', 'subir', 'Vender sin internet en este equipo', { id: 't-si-equipo' }),
      h('p', { class: 'ayuda' }, 'Cuando se va el internet, la caja sigue vendiendo de contado (efectivo o transferencia). Cada venta se guarda en el equipo y sube sola cuando vuelve el internet.'),
      sop.listo ? mensaje('ok', 'Este equipo guarda las ventas de forma segura.', null, { dataset: { dato: 'soporte' } })
        : mensaje('error', sop.razon, sop.ios ? 'Safari borra los datos de los sitios no instalados después de unos días sin uso.' : null, { dataset: { dato: 'soporte' } }),
      relojMal ? mensaje('error', 'La hora de este equipo está mal.', `Diferencia con el servidor: ${Math.round(Math.abs(cat.desfase_ms) / 60000)} minutos. Corríjala en el equipo para vender sin internet.`, { dataset: { dato: 'reloj' } }) : null,
      eq ? h('div', { class: 'fila' }, h('span', {}, 'Equipo'), h('strong', { dataset: { dato: 'equipo' } }, eq.nombre)) : campo('Nombre de este equipo', nombre, 'Para reconocerlo en la lista de equipos.'),
      cat ? h('div', { class: 'fila' }, h('span', {}, 'Precios guardados'), h('span', { dataset: { dato: 'precios' } },
        `versión ${cat.version} · ${fechaHora(cat.preparado_en)} · sirven hasta ${fechaHora(cat.valido_hasta)}`)) : null,
      activos.length ? activos.map((b) => h('div', { class: 'fila', dataset: { bloque: b.bloque_id } },
        h('span', {}, `${b.tipo === 'factura' ? 'Facturas' : 'Tickets'} · ${b.caja}`),
        h('span', {}, `${b.prefijo}-${String(b.siguiente).padStart(8, '0')} a ${b.hasta_texto} · quedan `,
          h('strong', { dataset: { dato: 'quedan' } }, String(Math.max(0, b.hasta - b.siguiente + 1))))))
        : h('p', { class: 'ayuda', dataset: { dato: 'sin-bloque' } }, 'Este equipo no tiene números reservados. Al prepararlo se reservan los de la caja de su turno.'),
      h('div', { class: 'fila' }, h('span', {}, 'Ventas guardadas por subir'), h('strong', { dataset: { dato: 'por-subir' } }, String(pend.length))),
      puede('ventas.sin_internet') ? null : mensaje('info', 'Su usuario no tiene permiso para vender sin internet.', 'El dueño lo da en Ajustes > Usuarios y permisos.'),
      zonaError,
      h('div', { class: 'botones' }, puede('ventas.sin_internet') ? preparar : null, pend.length ? subirAhora : null, pend.length ? respaldo : null));
  }

  // ---------------- 2. Ventas de otros usuarios (M2) ----------------
  async function pintarAjenas(zona) {
    const ajenas = (await si.pendientes(E)).filter((x) => x.usuario_id !== perfil.usuario.id);
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const porUsuario = new Map();
    for (const x of ajenas) { const l = porUsuario.get(x.usuario_id) || []; l.push(x); porUsuario.set(x.usuario_id, l); }
    const archivo = h('input', { type: 'file', id: 'si-archivo-respaldo', accept: 'application/json,.json' });
    archivo.addEventListener('change', async () => {
      const f = archivo.files && archivo.files[0];
      if (!f) return;
      let datos;
      try { datos = JSON.parse(await f.text()); } catch { zonaError.replaceChildren(errorSimple('El archivo no es un respaldo válido.')); return; }
      if (datos.tipo !== 'respaldo_ventas_sin_internet' || datos.empresa_id !== E || !datos.equipo) {
        zonaError.replaceChildren(errorSimple('El archivo no es un respaldo de ventas sin internet de este negocio.'));
        return;
      }
      await pedirMotivo({ titulo: `Subir ${datos.ventas.length} venta(s) del respaldo de "${datos.equipo.nombre}"`, textoBoton: 'Subir',
        explicacion: 'Quedan a nombre de quien las hizo y "subidas por" usted.',
        accion: async (motivo) => {
          const r = await si.subir(E, { motivo, equipoId: datos.equipo.equipo_id, usuarioId: null,
            registros: datos.ventas.map((v) => ({ id_operacion: v.id_operacion, payload: v.payload })) });
          if (r.sin_conexion) throw new Error('No hay conexión con el servidor.');
          aviso(`Respaldo subido: ${r.subidas + r.ya_estaban} registradas, ${r.por_resolver} por resolver, ${r.rechazadas} rechazadas.`, 'ok', 8000);
        } });
    });
    poner(zona, titulo('h2', 'usuarios', 'Ventas de otros usuarios guardadas en este equipo', { id: 't-si-ajenas' }),
      ajenas.length ? [...porUsuario.entries()].map(([uid, lista]) => {
        const b = h('button', { type: 'button', class: 'boton', dataset: { usuario: uid } }, 'Subirlas');
        b.addEventListener('click', () => pedirMotivo({ titulo: `Subir las ${lista.length} venta(s) de ${lista[0].usuario_nombre}`,
          textoBoton: 'Subir', explicacion: 'Quedan a nombre de quien las hizo y "subidas por" usted, con este motivo.',
          accion: async (motivo) => {
            const r = await si.subir(E, { usuarioId: uid, motivo });
            if (r.sin_conexion) throw new Error('No hay conexión con el servidor.');
            if (r.rechazadas) throw new Error(`${r.rechazadas} venta(s) no se pudieron subir.`);
            aviso(`Subidas: ${r.subidas + r.ya_estaban}. Por resolver: ${r.por_resolver}.`);
            pintarAjenas(zona); pintarEquipo();
          } }));
        return filaIcono({ icono: 'usuario', color: 'dorado', titulo: h('strong', {}, lista[0].usuario_nombre || 'Otro usuario'),
          detalle: `${lista.length} venta(s) · ${dinero(lista.reduce((s, x) => s + x.total_centavos, 0))}`, derecha: b,
          props: { dataset: { ajenas: uid } } });
      }) : h('p', { class: 'ayuda', dataset: { dato: 'sin-ajenas' } }, 'No hay ventas de otros usuarios por subir en este equipo.'),
      campo('Subir un respaldo de otro equipo', archivo, 'El archivo que se guardó con "Guardar respaldo de las ventas por subir".'),
      zonaError);
  }

  // ---------------- 3. Reglas (dueño) ----------------
  async function tarjetaReglas() {
    const datos = await rpc('bloques_sin_internet', { p_empresa_id: E }).catch(() => null);
    const r = (datos && datos.reglas) || {};
    const horas = h('input', { id: 'si-horas', type: 'number', min: '1', max: '168', step: '1', inputmode: 'numeric', value: r.horas || 24 });
    const topeVenta = h('input', { id: 'si-tope-venta', type: 'text', inputmode: 'decimal', value: paraCampo(r.tope_venta_centavos || 1000000) });
    const topeTurno = h('input', { id: 'si-tope-turno', type: 'text', inputmode: 'decimal', value: paraCampo(r.tope_turno_centavos || 5000000) });
    const bloque = h('input', { id: 'si-bloque', type: 'number', min: '10', max: '5000', step: '1', inputmode: 'numeric', value: r.bloque || '', placeholder: 'Sugerido' });
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const guardar = h('button', { type: 'button', class: 'boton boton-principal', id: 'si-guardar-reglas' }, 'Guardar reglas');
    guardar.addEventListener('click', () => {
      const tv = aCentavos(topeVenta.value), tt = aCentavos(topeTurno.value);
      if (tv === null || tt === null || !(Number(horas.value) >= 1)) { zonaError.replaceChildren(errorSimple('Revise las horas y los topes.')); return; }
      pedirMotivo({ titulo: 'Guardar las reglas de vender sin internet', textoBoton: 'Guardar',
        accion: async (motivo) => {
          await rpc('configurar_empresa', { p_empresa_id: E, p_motivo: motivo, p_datos: { sin_internet_horas: Number(horas.value),
            sin_internet_tope_venta_centavos: tv, sin_internet_tope_turno_centavos: tt,
            sin_internet_bloque: bloque.value ? Number(bloque.value) : null } });
          aviso('Reglas guardadas.');
        } });
    });
    const cajeros = h('input', { type: 'checkbox', id: 'si-cajeros' });
    const rp = puede('permisos.editar') ? await leer('rol_permiso', { empresa_id: E, rol: 'cajero', permiso: 'ventas.sin_internet' }).catch(() => []) : [];
    cajeros.checked = rp.length > 0;
    cajeros.addEventListener('change', () => {
      const quiere = cajeros.checked;
      pedirMotivo({ titulo: quiere ? 'Los cajeros podrán vender sin internet' : 'Los cajeros ya no venderán sin internet', textoBoton: 'Guardar',
        accion: async (motivo) => {
          await rpc('cambiar_permiso_rol', { p_empresa_id: E, p_rol: 'cajero', p_permiso: 'ventas.sin_internet', p_otorgar: quiere, p_motivo: motivo });
          aviso('Permiso guardado.');
        } }).then((ok) => { if (!ok) cajeros.checked = !quiere; });
    });
    return h('section', { class: 'tarjeta', id: 'si-reglas', 'aria-labelledby': 't-si-reglas' },
      titulo('h2', 'reglas', 'Reglas de vender sin internet', { id: 't-si-reglas' }),
      h('p', { class: 'ayuda' }, 'Sin internet solo se cobra en efectivo o con transferencia (con su número de referencia; queda por confirmar). Tarjeta, crédito, descuentos a mano, cobros de deudas y gastos necesitan internet.'),
      campo('Los precios sirven por (horas)', horas), campo('Tope de una venta sin internet (L)', topeVenta),
      campo('Tope vendido sin internet en un turno (L)', topeTurno), campo('Números por bloque (vacío = sugerido)', bloque),
      zonaError, h('div', { class: 'botones' }, guardar),
      puede('permisos.editar') ? h('label', { class: 'opcion-check' }, cajeros, ' Los cajeros pueden vender sin internet') : null);
  }

  // ---------------- 4. Equipos y números ----------------
  async function pintarEquipos(zona) {
    let d;
    try { d = await rpc('bloques_sin_internet', { p_empresa_id: E }); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    const admin = puede('equipos.administrar');
    poner(zona, titulo('h2', 'banco', 'Equipos y números reservados', { id: 't-si-equipos' }),
      d.por_resolver ? mensaje('info', `${d.por_resolver} venta(s) sin internet por resolver.`, null) : null,
      d.equipos.length ? d.equipos.map((q) => {
        const bloques = d.bloques.filter((b) => b.equipo_id === q.equipo_id);
        const desactivar = admin && q.activo ? h('button', { type: 'button', class: 'boton boton-peligro', dataset: { desactivar: q.equipo_id } }, 'Desactivar (perdido o dañado)') : null;
        if (desactivar) desactivar.addEventListener('click', () => pedirMotivo({ titulo: `Desactivar "${q.nombre}"`, peligro: true, textoBoton: 'Desactivar',
          explicacion: 'Sus números quedan "por conciliar" (no se anulan): registre lo que falte con las copias en papel y concilie.',
          accion: async (motivo) => { await rpc('desactivar_equipo', { p_empresa_id: E, p_equipo_id: q.equipo_id, p_motivo: motivo }); aviso('Equipo desactivado.'); pintarEquipos(zona); } }));
        return h('div', { class: 'equipo-sin-internet', dataset: { equipo: q.equipo_id } },
          filaIcono({ icono: 'tienda', color: !q.activo ? 'neutro' : q.sin_noticias_48h ? 'rojo' : 'verde', titulo: h('strong', {}, q.nombre),
            detalle: [q.activo ? null : 'Desactivado', q.ultima_noticia ? `última noticia ${fechaHora(q.ultima_noticia)}` : null,
              q.sin_noticias_48h && q.activo ? 'SIN NOTICIAS HACE 48 HORAS' : null].filter(Boolean).join(' · '), derecha: desactivar }),
          bloques.map((b) => {
            const conciliar = admin && b.estado === 'por_conciliar' ? h('button', { type: 'button', class: 'boton', dataset: { conciliar: b.bloque_id } }, 'Conciliar') : null;
            if (conciliar) conciliar.addEventListener('click', () => pedirMotivo({ titulo: `Conciliar ${b.desde_texto} a ${b.hasta_texto}`, textoBoton: 'Conciliar',
              explicacion: 'Primero registre las ventas que falten a partir de las copias en papel. Los números que no se usaron quedan "no usados" para reportarlos como diga el contador.',
              accion: async (motivo) => {
                const r = await escribir('conciliar_bloque', { p_empresa_id: E, p_bloque_id: b.bloque_id, p_motivo: motivo });
                aviso(`Conciliado: ${r.no_usados} número(s) no usados.`, 'ok', 8000); pintarEquipos(zona);
              } }));
            return h('div', { class: 'fila', dataset: { bloque: b.bloque_id, estado: b.estado } },
              h('span', {}, `${b.tipo === 'factura' ? 'Facturas' : 'Tickets'} ${b.desde_texto} a ${b.hasta_texto} · ${b.caja}`),
              h('span', {}, chip({ activo: 'Activo', devuelto: 'Devuelto', por_conciliar: 'Por conciliar', conciliado: 'Conciliado' }[b.estado] || b.estado,
                b.estado === 'por_conciliar' ? 'rojo' : b.estado === 'activo' ? 'verde' : 'neutro'), ` usados ${b.usados}, libres ${b.libres} `, conciliar));
          }));
      }) : estadoVacio({ icono: 'tienda', chico: true, texto: 'Todavía no hay equipos preparados para vender sin internet.' }));
  }
}
