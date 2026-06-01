// api/heartbeat.js — Vercel Serverless Function v3 (hardened)
const { createClient } = require('@supabase/supabase-js');
const { checkRateLimit, checkAutoBlock, checkOrigin } = require('./_lib/security');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Content-Type': 'application/json',
};

const INACTIVITY_HOURS = 24;

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(200).set(CORS_HEADERS).end();
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
  if (req.method !== 'POST') return res.status(405).json({ ok: false, motivo: 'Método no permitido' });

  const { token, ea_tipo, mt5_account, hwid } = req.body || {};
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket?.remoteAddress || 'unknown';

  const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

  // Rate limiting
  const rateLimited = await checkRateLimit(sb, ip);
  if (rateLimited) return res.status(429).json({ ok: false, motivo: 'Demasiadas solicitudes. Espera 1 minuto.' });

  // Auto-bloqueo por fallos en token
  if (token) {
    const autoBlocked = await checkAutoBlock(sb, token);
    if (autoBlocked) return res.status(429).json({ ok: false, motivo: 'Token temporalmente suspendido. Espera 5 minutos.' });
  }

  if (!token || !ea_tipo || !mt5_account) {
    return res.status(400).json({ ok: false, motivo: 'Campos requeridos: token, ea_tipo, mt5_account' });
  }

  try {
    const { data: perfil, error: errP } = await sb
      .from('perfiles')
      .select('id, bloqueado, plan, mt5_cuenta, mt5_cuenta_bloqueada, fecha_expiracion_plan')
      .eq('token_licencia', token.trim())
      .single();

    if (errP || !perfil) return res.status(403).json({ ok: false, motivo: 'Token no válido' });
    if (perfil.bloqueado) return res.status(403).json({ ok: false, motivo: 'Cuenta bloqueada' });

    // Membresía expirada
    if (perfil.plan !== 'gratis' && perfil.fecha_expiracion_plan) {
      const expDate = new Date(perfil.fecha_expiracion_plan);
      if (expDate < new Date()) {
        return res.status(403).json({
          ok: false,
          motivo: `Membresía ${perfil.plan} vencida. Renueva en FlowTrade Suite.`,
          expirado: true,
        });
      }
    }

    // Cuenta MT5 bloqueada — mensaje genérico (sin exponer la cuenta registrada)
    if (perfil.mt5_cuenta_bloqueada && perfil.mt5_cuenta &&
        String(perfil.mt5_cuenta).trim() !== String(mt5_account).trim()) {
      await sb.from('alertas_fraude').insert({
        usuario_id: perfil.id,
        tipo: 'heartbeat_cuenta_diferente',
        detalle: `Heartbeat cuenta diferente — ip: ${ip}`,
        ip, fecha: new Date().toISOString(), revisado: false,
      }).catch(() => {});
      return res.status(403).json({
        ok: false,
        motivo: 'Cuenta MT5 no autorizada para este token. Contacta al administrador.',
        bloqueo_cuenta: true,
      });
    }

    const { data: lic, error: errL } = await sb
      .from('licencias_ea')
      .select('id, activo, ultimo_heartbeat, mt5_account, hwid')
      .eq('usuario_id', perfil.id)
      .eq('ea_tipo', ea_tipo)
      .single();

    if (errL || !lic) return res.status(404).json({ ok: false, motivo: 'Licencia no encontrada. Reinicia el EA.' });
    if (!lic.activo) return res.status(403).json({ ok: false, motivo: 'Licencia desactivada. Contacta al administrador.' });

    // HWID check — cambio de dispositivo → BLOQUEO AUTOMÁTICO
    if (hwid && lic.hwid && lic.hwid !== hwid) {
      await sb.from('alertas_fraude').insert({
        usuario_id: perfil.id,
        tipo: 'hwid_heartbeat_diferente',
        detalle: `HWID registrado: ${lic.hwid} | Nuevo: ${hwid} — DESACTIVADO AUTOMÁTICAMENTE`,
        ip, fecha: new Date().toISOString(), revisado: false,
      }).catch(() => {});
      await sb.from('licencias_ea').update({ activo: false }).eq('id', lic.id).catch(() => {});
      return res.status(403).json({
        ok: false,
        motivo: 'Dispositivo no autorizado. La licencia ha sido desactivada automáticamente. Contacta al administrador.',
        hwid_bloqueado: true,
      });
    }

    if (lic.ultimo_heartbeat) {
      const hours = (Date.now() - new Date(lic.ultimo_heartbeat).getTime()) / 3600000;
      if (hours > INACTIVITY_HOURS) {
        await sb.from('licencias_ea').update({ activo: false }).eq('id', lic.id);
        return res.status(403).json({ ok: false, motivo: `Licencia desactivada por inactividad. Reinicia el EA.` });
      }
    }

    await sb.from('licencias_ea').update({
      ultimo_heartbeat: new Date().toISOString(),
      ...(hwid && !lic.hwid ? { hwid } : {}),
    }).eq('id', lic.id);

    // Calcular días restantes
    let diasRestantes = null;
    if (perfil.plan !== 'gratis' && perfil.fecha_expiracion_plan) {
      diasRestantes = Math.ceil((new Date(perfil.fecha_expiracion_plan) - new Date()) / 86400000);
    }

    return res.status(200).json({
      ok: true,
      mensaje: 'Heartbeat registrado',
      plan: perfil.plan,
      dias_restantes: diasRestantes,
      next_heartbeat: 3600,
    });

  } catch (err) {
    console.error('[heartbeat]', err);
    return res.status(500).json({ ok: false, motivo: 'Error interno del servidor' });
  }
};
