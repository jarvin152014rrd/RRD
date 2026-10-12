// Configuración de UN cliente. Copie este archivo como app/config.js al publicar
// (sale de la carpeta personal/ del cliente; app/config.js no va a git).
// La clave anónima de Supabase es pública por diseño: la seguridad está en la base
// (RLS y funciones). NUNCA ponga aquí la llave service_role.
export default {
  supabaseUrl: 'https://SU-PROYECTO.supabase.co',
  supabaseAnonKey: 'SU-CLAVE-ANONIMA',
  revisarSesionSegundos: 60, // cada cuánto se revisa si cerraron la sesión a distancia
  // Bucket de Supabase Storage para fotos de comprobantes (vacío = solo se guarda el nombre de la foto).
  bucketComprobantes: '',
};
