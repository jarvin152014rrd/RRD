# Administración y perfil (010_administracion)

**`mi_perfil(empresa?)`** — para armar el menú: `usuario` (id, correo,
nombre), `empresas` (todas las del usuario), `empresa` (datos, `hoy`),
`rol`, `permisos` (los que tiene de verdad), `modulos`, `licencia`
(`estado`: activa / en_gracia / solo_lectura, `dias`, `motivo`),
`soporte_vigente_hasta`, `hora_servidor`. Si el usuario tiene varias
empresas y no indica una, `empresa` viene vacía: la app pide elegir.

**Usuarios** (`usuarios.administrar`: dueño y admin desde 0.3.0; ver `usuarios.md`):
`agregar_usuario_empresa` (agrega, reactiva o cambia rol; el usuario debe
estar registrado) y `desactivar_usuario_empresa` (con motivo; nunca borra).
Nadie se cambia a sí mismo; solo un dueño toca a otro dueño; el rol
proveedor solo se da al instalar. Quien no es dueño no da un rol con
permisos que él no tiene. Desactivar funciona en solo lectura.

**Sucursales y cajas** (`sucursales.administrar`): `crear_sucursal`
(código SAR de 3 dígitos), `desactivar_sucursal` (también sus cajas; no la
última activa; tampoco si alguna de sus bodegas tiene existencias o valor),
`reactivar_sucursal` (sus cajas se reactivan una por una), `crear_caja`
(punto de emisión de 3 dígitos, en sucursal activa), `desactivar_caja`,
`reactivar_caja` (con su sucursal activa). Todo con motivo y en bitácora.

**Subcuentas** (`catalogo.editar`): `crear_subcuenta`.

**Configuración** (`empresa.configurar`, solo dueño, 012):
`configurar_empresa(empresa, datos, motivo)` con
`{"tope_credito_centavos": 500000, "permite_existencia_negativa": false,
"precio_incluye_isv_defecto": true}` (0.4.0: si los precios nuevos traen ISV).
