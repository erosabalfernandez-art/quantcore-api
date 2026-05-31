// api/recibir-simbolos.js — Vercel Serverless Function
// Recibe especificaciones de símbolos desde el EA DataBridge v2
// Variables de entorno: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

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

  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, motivo: 'Método no permitido' });
  }

  const { token, cuenta, simbolos } = req.body || {};

  if (!token) return res.status(400).json({ ok: false, motivo: 'token requerido' });
  if (!Array.isArray(simbolos) || simbolos.length === 0) {
    return res.status(400).json({ ok: false, motivo: 'simbolos[] requerido y no puede estar vacío' });
  }

  const sb = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  );

  const { data: perfil, error: errPerfil } = await sb
    .from('perfiles')
    .select('id, bloqueado')
    .eq('token_licencia', token)
    .single();

  if (errPerfil || !perfil) return res.status(403).json({ ok: false, motivo: 'Token no válido' });
  if (perfil.bloqueado)     return res.status(403).json({ ok: false, motivo: 'Cuenta bloqueada' });

  const now = new Date().toISOString();
  let insertados = 0;

  for (const s of simbolos) {
    if (!s.simbolo) continue;
    const { error } = await sb
      .from('simbolos_usuario')
      .upsert({
        usuario_id:    perfil.id,
        mt5_cuenta:    String(cuenta || ''),
        simbolo:       String(s.simbolo),
        tick_size:     Number(s.tick_size   || 0),
        tick_value:    Number(s.tick_value  || 0),
        contract_size: Number(s.contract_size || 0),
        point:         Number(s.point       || 0),
        digits:        Number(s.digits      || 0),
        pip_value:     Number(s.pip_value   || 0),
        last_updated:  now,
      }, { onConflict: 'usuario_id,simbolo' });
    if (!error) insertados++;
  }

  return res.status(200).json({ ok: true, insertados, total: simbolos.length });
};
