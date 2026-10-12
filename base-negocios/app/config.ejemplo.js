// Configuración de UN cliente. Copie este archivo como app/config.js al publicar
// (sale de la carpeta personal/ del cliente; app/config.js no va a git).
// La clave anónima de Supabase es pública por diseño: la seguridad está en la base
// (RLS y funciones). NUNCA ponga aquí la llave service_role.
// La arma sola herramientas/armar_app.sh (docs/SUPABASE.md, paso 10).
export default {
  modo: 'supabase', // 'supabase' = proyecto real (usa las Edge Functions de supabase/functions/)
  supabaseUrl: 'https://SU-PROYECTO.supabase.co',
  supabaseAnonKey: 'SU-CLAVE-ANONIMA',
  revisarSesionSegundos: 60, // cada cuánto se revisa si cerraron la sesión a distancia
  // Bucket de Supabase Storage para fotos de comprobantes (vacío = solo se guarda el nombre de la foto).
  bucketComprobantes: '',
};
