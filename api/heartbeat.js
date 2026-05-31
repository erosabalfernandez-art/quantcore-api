// api/heartbeat.js — Vercel Serverless Function
// Recibe heartbeat periódico de un EA activo y actualiza ultimo_heartbeat
// Si no hay heartbeat en 24h la licencia se desactiva automáticamente
// Variables de entorno: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

const { createClient } = require('@supabase/supabase-js');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Content-Type': 'application/json',
};

const INACTIVITY_HOURS = 24; // horas sin heartbeat antes de desactivar

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    return res.status(200).set(CORS_HEADERS).end();
  }
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, motivo: 'Método no permitido' });
  }

  const { token, ea_tipo, mt5_account } = req.body || {};

  if (!token || !ea_tipo || !mt5_account) {
    return res.status(400).json({ ok: false, motivo: 'Campos requeridos: token, ea_tipo, mt5_account' });
  }

  const supabase = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  );

  try {
    // 1. Verificar token y estado del usuario
    const { data: perfil, error: errPerfil } = await supabase
      .from('perfiles')
      .select('id, bloqueado, plan')
      .eq('token_licencia', token)
      .single();

    if (errPerfil || !perfil) {
      return res.status(403).json({ ok: false, motivo: 'Token no válido' });
    }

    if (perfil.bloqueado) {
      return res.status(403).json({ ok: false, motivo: 'Cuenta bloqueada' });
    }

    // 2. Buscar licencia activa
    const { data: lic, error: errLic } = await supabase
      .from('licencias_ea')
      .select('id, activo, ultimo_heartbeat, mt5_account')
      .eq('usuario_id', perfil.id)
      .eq('ea_tipo', ea_tipo)
      .single();

    if (errLic || !lic) {
      return res.status(404).json({ ok: false, motivo: 'Licencia no encontrada. Reinicia el EA para validar.' });
    }

    if (!lic.activo) {
      return res.status(403).json({ ok: false, motivo: 'Licencia desactivada por nuestro equipo' });
    }

    // 3. Verificar cuenta MT5
    if (lic.mt5_account && String(lic.mt5_account) !== String(mt5_account)) {
      return res.status(403).json({ ok: false, motivo: 'Cuenta MT5 no coincide con la registrada' });
    }

    // 4. Verificar si llevas más de INACTIVITY_HOURS sin heartbeat
    if (lic.ultimo_heartbeat) {
      const lastHB = new Date(lic.ultimo_heartbeat);
      const horasTranscurridas = (Date.now() - lastHB.getTime()) / (1000 * 60 * 60);
      if (horasTranscurridas > INACTIVITY_HOURS) {
        // Desactivar por inactividad
        await supabase
          .from('licencias_ea')
          .update({ activo: false })
          .eq('id', lic.id);
        return res.status(403).json({ ok: false, motivo: `Licencia desactivada por inactividad (>${INACTIVITY_HOURS}h sin heartbeat). Reinicia el EA.` });
      }
    }

    // 5. Actualizar heartbeat
    await supabase
      .from('licencias_ea')
      .update({ ultimo_heartbeat: new Date().toISOString() })
      .eq('id', lic.id);

    return res.status(200).json({
      ok: true,
      mensaje: 'Heartbeat registrado',
      plan: perfil.plan,
      next_heartbeat: 3600,
    });

  } catch (err) {
    console.error('[heartbeat] Error:', err);
    return res.status(500).json({ ok: false, motivo: 'Error interno del servidor' });
  }
};
