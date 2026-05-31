// api/recibir-trades.js — Vercel Serverless Function
// Recibe trades cerrados desde el EA DataBridge y los guarda en Supabase
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

  const { token, cuenta, servidor, trades } = req.body || {};

  if (!token) {
    return res.status(400).json({ ok: false, motivo: 'token requerido' });
  }
  if (!Array.isArray(trades) || trades.length === 0) {
    return res.status(400).json({ ok: false, motivo: 'trades[] requerido y no puede estar vacío' });
  }

  const sb = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  );

  // Verificar token y estado de la cuenta
  const { data: perfil, error: errPerfil } = await sb
    .from('perfiles')
    .select('id, bloqueado, plan')
    .eq('token_licencia', token)
    .single();

  if (errPerfil || !perfil) {
    return res.status(403).json({ ok: false, motivo: 'Token no válido' });
  }
  if (perfil.bloqueado) {
    return res.status(403).json({ ok: false, motivo: 'Cuenta bloqueada por nuestro equipo' });
  }

  const usuarioId = perfil.id;
  let insertados = 0;
  let omitidos   = 0;

  for (const t of trades) {
    const {
      ticket, position_id,
      fecha, fecha_apertura,
      activo, tipo,
      lotes, precio_entrada, precio_salida,
      resultado_usd, pips,
    } = t;

    if (!ticket || !activo) { omitidos++; continue; }

    const row = {
      usuario_id:      usuarioId,
      mt5_cuenta:      String(cuenta || ''),
      mt5_servidor:    String(servidor || ''),
      ticket:          String(ticket),
      position_id:     String(position_id || ticket),
      fecha:           fecha          || null,
      fecha_apertura:  fecha_apertura || null,
      activo:          String(activo).toUpperCase(),
      tipo:            String(tipo || ''),
      lotes:           parseFloat(lotes)          || 0,
      precio_entrada:  parseFloat(precio_entrada)  || 0,
      precio_salida:   parseFloat(precio_salida)   || 0,
      resultado_usd:   parseFloat(resultado_usd)   || 0,
      pips:            parseFloat(pips)            || 0,
      recibido_en:     new Date().toISOString(),
    };

    // Upsert por (usuario_id, ticket) para evitar duplicados en reenvíos
    const { error: upsertErr } = await sb
      .from('trades_recibidos')
      .upsert(row, { onConflict: 'usuario_id,ticket' });

    if (upsertErr) {
      console.error('[recibir-trades] upsert error:', upsertErr.message, '| ticket:', ticket);
      omitidos++;
    } else {
      insertados++;
    }
  }

  return res.status(200).json({
    ok: true,
    insertados,
    omitidos,
    mensaje: `${insertados} trades procesados, ${omitidos} omitidos`,
  });
};
