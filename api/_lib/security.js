// api/_lib/security.js — módulo de seguridad compartido
// Rate limiting, validación de origen, auto-bloqueo

const ALLOWED_ORIGINS = [
  'https://flowtradesuite.com',
  'https://www.flowtradesuite.com',
  // Agrega tu dominio de Render aquí:
];

// ─── Rate Limit ─────────────────────────────────────────────────────────────
// Cuenta intentos recientes por IP usando logs_licencias.
// Máximo MAX_ATTEMPTS en WINDOW_SECONDS. Usa Supabase (sin estado extra).
const MAX_ATTEMPTS    = 15;   // requests por ventana
const WINDOW_SECONDS  = 60;   // ventana en segundos

async function checkRateLimit(sb, ip) {
  try {
    const since = new Date(Date.now() - WINDOW_SECONDS * 1000).toISOString();
    const { count } = await sb
      .from('logs_licencias')
      .select('id', { count: 'exact', head: true })
      .eq('ip', ip)
      .gte('fecha', since);
    return (count || 0) >= MAX_ATTEMPTS;
  } catch (_) { return false; }
}

// ─── Bloqueo automático por fallos consecutivos ───────────────────────────
// Si un token acumula >= MAX_FAILURES fallos en FAIL_WINDOW_MIN → bloquearlo
const MAX_FAILURES      = 10;
const FAIL_WINDOW_MIN   = 5;

async function checkAutoBlock(sb, token) {
  try {
    const since = new Date(Date.now() - FAIL_WINDOW_MIN * 60 * 1000).toISOString();
    const { count } = await sb
      .from('logs_licencias')
      .select('id', { count: 'exact', head: true })
      .eq('token_usado', token)
      .eq('exito', false)
      .gte('fecha', since);
    return (count || 0) >= MAX_FAILURES;
  } catch (_) { return false; }
}

// ─── Validación de origen para requests de navegador ─────────────────────
function checkOrigin(req) {
  const origin = req.headers['origin'] || req.headers['referer'] || '';
  // Los EAs (MT5 WebRequest) no envían Origin — se permiten siempre.
  // Los navegadores siempre envían Origin. Si viene de uno, validar dominio.
  if (!origin) return true; // petición de EA → permitir
  return ALLOWED_ORIGINS.some(o => origin.startsWith(o));
}

// ─── Errores genéricos (no exponer datos internos) ───────────────────────
function genericError(code) {
  const msgs = {
    'cuenta_diferente': 'Cuenta MT5 no autorizada para este token. Contacta al administrador.',
    'cuenta_bloqueada': 'Cuenta no autorizada para este token. Contacta al administrador.',
    'mt5_no_coincide':  'Cuenta MT5 no coincide con el registro. Contacta al administrador.',
  };
  return msgs[code] || 'Solicitud rechazada. Contacta al administrador.';
}

module.exports = { checkRateLimit, checkAutoBlock, checkOrigin, genericError };
