// api/recibir-trades.js — Vercel Serverless Function v2
  // Recibe trades del EA DataBridge. Valida y registra la cuenta MT5 de forma permanente.

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

    const { token, cuenta, servidor, trades } = req.body || {};
    const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || 'unknown';

    if (!token) return res.status(400).json({ ok: false, motivo: 'token requerido' });
    if (!Array.isArray(trades) || trades.length === 0) {
      return res.status(400).json({ ok: false, motivo: 'trades[] requerido y no puede estar vacío' });
    }

    const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

    const { data: perfil, error: errP } = await sb
      .from('perfiles')
      .select('id, bloqueado, plan, mt5_cuenta, mt5_cuenta_bloqueada')
      .eq('token_licencia', token)
      .single();

    if (errP || !perfil) return res.status(403).json({ ok: false, motivo: 'Token no válido' });
    if (perfil.bloqueado) return res.status(403).json({ ok: false, motivo: 'Cuenta bloqueada por nuestro equipo' });

    // Validar/registrar cuenta MT5
    const cuentaStr = String(cuenta || '').trim();
    if (cuentaStr) {
      if (perfil.mt5_cuenta_bloqueada && perfil.mt5_cuenta) {
        if (perfil.mt5_cuenta !== cuentaStr) {
          await sb.from('alertas_fraude').insert({
            usuario_id: perfil.id,
            tipo: 'trades_cuenta_diferente',
            detalle: `Trades desde cuenta ${cuentaStr}, vinculada: ${perfil.mt5_cuenta}`,
            ip, fecha: new Date().toISOString(), revisado: false,
          }).catch(() => {});
          return res.status(403).json({
            ok: false,
            motivo: `Este token está vinculado a la cuenta ${perfil.mt5_cuenta}. No se pueden recibir trades de la cuenta ${cuentaStr}.`,
          });
        }
      } else if (!perfil.mt5_cuenta) {
        // Primera vez — vincular y bloquear
        await sb.from('perfiles').update({
          mt5_cuenta: cuentaStr,
          mt5_servidor: String(servidor || ''),
          mt5_cuenta_bloqueada: true,
          fecha_registro_mt5: new Date().toISOString(),
        }).eq('id', perfil.id);
      }
    }

    const usuarioId = perfil.id;
    let insertados = 0, omitidos = 0;

    for (const t of trades) {
      const { ticket, position_id, fecha, fecha_apertura, activo, tipo,
              lotes, precio_entrada, precio_salida, resultado_usd, pips } = t;
      if (!ticket || !activo) { omitidos++; continue; }

      const { error } = await sb.from('trades_recibidos').upsert({
        usuario_id: usuarioId,
        mt5_cuenta: cuentaStr,
        mt5_servidor: String(servidor || ''),
        ticket: String(ticket),
        position_id: String(position_id || ticket),
        fecha: fecha || null,
        fecha_apertura: fecha_apertura || null,
        activo: String(activo).toUpperCase(),
        tipo: String(tipo || ''),
        lotes: parseFloat(lotes) || 0,
        precio_entrada: parseFloat(precio_entrada) || 0,
        precio_salida: parseFloat(precio_salida) || 0,
        resultado_usd: parseFloat(resultado_usd) || 0,
        pips: parseFloat(pips) || 0,
        recibido_en: new Date().toISOString(),
      }, { onConflict: 'usuario_id,ticket' });

      if (error) { console.error('[recibir-trades]', error.message, ticket); omitidos++; }
      else insertados++;
    }

    return res.status(200).json({ ok: true, insertados, omitidos, mensaje: `${insertados} trades procesados` });
  };
  