// api/validar-licencia.js — Vercel Serverless Function
// Valida el token de licencia de un EA de MetaTrader 5
// Variables de entorno requeridas: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

const { createClient } = require('@supabase/supabase-js');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Content-Type': 'application/json',
};

// Planes que dan acceso a cada EA
const PLAN_EA = {
  risk_manager:       ['premium', 'elite'],
  auto_journaling:    ['premium', 'elite'],
  backtest_simulator: ['elite'],
  data_bridge:        ['elite'],
};

module.exports = async function handler(req, res) {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return res.status(200).set(CORS_HEADERS).end();
  }
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method !== 'POST') {
    return res.status(405).json({ valido: false, motivo: 'Método no permitido', codigo: 405 });
  }

  const { token, ea_tipo, mt5_account, version_ea } = req.body || {};
  const ip = req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown';

  // Validar campos requeridos
  if (!token || !ea_tipo || !mt5_account) {
    return res.status(400).json({ valido: false, motivo: 'Campos requeridos: token, ea_tipo, mt5_account', codigo: 400 });
  }

  if (!PLAN_EA[ea_tipo]) {
    return res.status(400).json({ valido: false, motivo: `EA tipo desconocido: ${ea_tipo}`, codigo: 400 });
  }

  const supabase = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  );

  let motivo = null;
  let exito = false;
  let usuarioId = null;
  let plan = null;

  try {
    // 1. Buscar usuario por token_licencia
    const { data: perfil, error: errPerfil } = await supabase
      .from('perfiles')
      .select('id, nombre, plan, mt5_cuenta, bloqueado, token_licencia')
      .eq('token_licencia', token)
      .single();

    if (errPerfil || !perfil) {
      motivo = 'Token no encontrado';
      await logIntento(supabase, { token, ea_tipo, mt5_account, exito: false, motivo, ip });
      return res.status(403).json({ valido: false, motivo, codigo: 403 });
    }

    usuarioId = perfil.id;
    plan = perfil.plan || 'gratis';

    // 2. Comprobar si el usuario está bloqueado
    if (perfil.bloqueado) {
      motivo = 'Cuenta bloqueada por administrador';
      await logIntento(supabase, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip });
      return res.status(403).json({ valido: false, motivo, codigo: 403 });
    }

    // 3. Comprobar plan
    const planesPermitidos = PLAN_EA[ea_tipo];
    if (!planesPermitidos.includes(plan)) {
      motivo = `Plan "${plan}" no incluye el EA "${ea_tipo}". Requerido: ${planesPermitidos.join(' o ')}`;
      await logIntento(supabase, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip });
      return res.status(403).json({ valido: false, motivo, codigo: 403 });
    }

    // 4. Verificar que la cuenta MT5 coincide (si ya tiene una asignada)
    if (perfil.mt5_cuenta && String(perfil.mt5_cuenta).trim() !== String(mt5_account).trim()) {
      motivo = `Cuenta MT5 no coincide. Esperada: ${perfil.mt5_cuenta}. Solo el administrador puede cambiarla.`;
      await logIntento(supabase, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip });
      return res.status(403).json({ valido: false, motivo, codigo: 403 });
    }

    // 5. Verificar que no hay otra cuenta MT5 activa con el mismo token (antifraude)
    const { data: licExistente } = await supabase
      .from('licencias_ea')
      .select('id, mt5_account, activo')
      .eq('usuario_id', usuarioId)
      .eq('ea_tipo', ea_tipo)
      .single();

    if (licExistente && licExistente.activo && licExistente.mt5_account !== String(mt5_account)) {
      motivo = `Token ya activo en otra cuenta MT5 (${licExistente.mt5_account}). Contacta al admin para cambiarla.`;
      await logIntento(supabase, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip });
      return res.status(403).json({ valido: false, motivo, codigo: 403 });
    }

    // 6. Registrar/actualizar licencia
    if (licExistente) {
      await supabase
        .from('licencias_ea')
        .update({ activo: true, ultimo_heartbeat: new Date().toISOString(), mt5_account: String(mt5_account) })
        .eq('id', licExistente.id);
    } else {
      await supabase.from('licencias_ea').insert({
        usuario_id: usuarioId,
        ea_tipo,
        mt5_account: String(mt5_account),
        activo: true,
        fecha_activacion: new Date().toISOString(),
        ultimo_heartbeat: new Date().toISOString(),
      });
    }

    // 7. Log de éxito
    exito = true;
    await logIntento(supabase, { usuarioId, token, ea_tipo, mt5_account, exito: true, motivo: 'OK', ip });

    return res.status(200).json({
      valido: true,
      plan,
      mensaje: `Licencia activa para ${ea_tipo} — Plan ${plan}`,
      heartbeat_interval: 3600,
      usuario: perfil.nombre,
    });

  } catch (err) {
    console.error('[validar-licencia] Error interno:', err);
    return res.status(500).json({ valido: false, motivo: 'Error interno del servidor', codigo: 500 });
  }
};

async function logIntento(supabase, { usuarioId, token, ea_tipo, mt5_account, exito, motivo, ip }) {
  try {
    await supabase.from('logs_licencias').insert({
      usuario_id: usuarioId || null,
      token_usado: token,
      ea_tipo,
      mt5_account: String(mt5_account),
      exito,
      motivo,
      ip,
      fecha: new Date().toISOString(),
    });
  } catch (e) {
    console.error('[logIntento] Error al guardar log:', e);
  }
}
