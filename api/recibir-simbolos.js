// api/recibir-simbolos.js — Vercel Serverless Function v2
  // Recibe specs de símbolos del EA DataBridge. Valida la cuenta MT5 bloqueada.

  const { createClient } = require('@supabase/supabase-js');

  const CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Content-Type': 'application/json',
  };

  module.exports = async function handler(req, res) {
    if (req.method === 'OPTIONS') return res.status(200).set(CORS_HEADERS).end();
    Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
    if (req.method !== 'POST') return res.status(405).json({ ok: false, motivo: 'Método no permitido' });

    const { token, cuenta, simbolos } = req.body || {};
    if (!token) return res.status(400).json({ ok: false, motivo: 'token requerido' });
    if (!Array.isArray(simbolos) || simbolos.length === 0) {
      return res.status(400).json({ ok: false, motivo: 'simbolos[] requerido' });
    }

    const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

    const { data: perfil, error: errP } = await sb
      .from('perfiles')
      .select('id, bloqueado, mt5_cuenta, mt5_cuenta_bloqueada')
      .eq('token_licencia', token)
      .single();

    if (errP || !perfil) return res.status(403).json({ ok: false, motivo: 'Token no válido' });
    if (perfil.bloqueado) return res.status(403).json({ ok: false, motivo: 'Cuenta bloqueada' });

    const cuentaStr = String(cuenta || '').trim();
    if (cuentaStr && perfil.mt5_cuenta_bloqueada && perfil.mt5_cuenta && perfil.mt5_cuenta !== cuentaStr) {
      return res.status(403).json({
        ok: false,
        motivo: `Token vinculado a cuenta ${perfil.mt5_cuenta}. No puede enviar datos desde ${cuentaStr}.`,
      });
    }

    const now = new Date().toISOString();
    let insertados = 0;
    for (const s of simbolos) {
      if (!s.simbolo) continue;
      const { error } = await sb.from('simbolos_usuario').upsert({
        usuario_id: perfil.id,
        mt5_cuenta: cuentaStr,
        simbolo: String(s.simbolo),
        tick_size: Number(s.tick_size || 0),
        tick_value: Number(s.tick_value || 0),
        contract_size: Number(s.contract_size || 0),
        point: Number(s.point || 0),
        digits: Number(s.digits || 0),
        pip_value: Number(s.pip_value || 0),
        last_updated: now,
      }, { onConflict: 'usuario_id,simbolo' });
      if (!error) insertados++;
    }

    return res.status(200).json({ ok: true, insertados, total: simbolos.length });
  };
  