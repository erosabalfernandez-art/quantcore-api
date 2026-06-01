// api/heartbeat.js — Vercel Serverless Function v2
  // Heartbeat periódico del EA. Verifica HWID y bloqueo de cuenta.

  const { createClient } = require('@supabase/supabase-js');

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

    if (!token || !ea_tipo || !mt5_account) {
      return res.status(400).json({ ok: false, motivo: 'Campos requeridos: token, ea_tipo, mt5_account' });
    }

    const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

    try {
      const { data: perfil, error: errP } = await sb
        .from('perfiles')
        .select('id, bloqueado, plan, mt5_cuenta, mt5_cuenta_bloqueada, fecha_expiracion_plan')
        .eq('token_licencia', token)
        .single();

      if (errP || !perfil) return res.status(403).json({ ok: false, motivo: 'Token no válido' });
      if (perfil.bloqueado) return res.status(403).json({ ok: false, motivo: 'Cuenta bloqueada' });

      // Membresía expirada
      if (perfil.plan !== 'gratis' && perfil.fecha_expiracion_plan) {
        const expDate = new Date(perfil.fecha_expiracion_plan);
        if (expDate < new Date()) {
          return res.status(403).json({
            ok: false,
            motivo: `Membresía ${perfil.plan} vencida el ${expDate.toLocaleDateString('es-ES')}. Renueva tu plan en FlowTrade Suite.`,
            expirado: true,
          });
        }
      }

      // Verificar cuenta MT5 bloqueada
      if (perfil.mt5_cuenta_bloqueada && perfil.mt5_cuenta &&
          String(perfil.mt5_cuenta).trim() !== String(mt5_account).trim()) {
        // Registrar alerta de fraude
        await sb.from('alertas_fraude').insert({
          usuario_id: perfil.id,
          tipo: 'heartbeat_cuenta_diferente',
          detalle: `Heartbeat desde cuenta ${mt5_account}, vinculada: ${perfil.mt5_cuenta}`,
          ip, fecha: new Date().toISOString(), revisado: false,
        }).catch(() => {});
        return res.status(403).json({
          ok: false,
          motivo: `Este EA está vinculado a la cuenta ${perfil.mt5_cuenta}. No puede usarse en otras cuentas.`,
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
      if (!lic.activo) return res.status(403).json({ ok: false, motivo: 'Licencia desactivada por el administrador' });

      // HWID check
      if (hwid && lic.hwid && lic.hwid !== hwid) {
        await sb.from('alertas_fraude').insert({
          usuario_id: perfil.id,
          tipo: 'hwid_heartbeat_diferente',
          detalle: `HWID registrado: ${lic.hwid} | HWID heartbeat: ${hwid} | Cuenta: ${mt5_account}`,
          ip, fecha: new Date().toISOString(), revisado: false,
        }).catch(() => {});
      }

      if (lic.ultimo_heartbeat) {
        const hours = (Date.now() - new Date(lic.ultimo_heartbeat).getTime()) / 3600000;
        if (hours > INACTIVITY_HOURS) {
          await sb.from('licencias_ea').update({ activo: false }).eq('id', lic.id);
          return res.status(403).json({ ok: false, motivo: `Licencia desactivada por inactividad (>${INACTIVITY_HOURS}h). Reinicia el EA.` });
        }
      }

      await sb.from('licencias_ea').update({
        ultimo_heartbeat: new Date().toISOString(),
        ...(hwid && !lic.hwid ? { hwid } : {}),
      }).eq('id', lic.id);

      return res.status(200).json({ ok: true, mensaje: 'Heartbeat registrado', plan: perfil.plan, next_heartbeat: 3600 });

    } catch (err) {
      console.error('[heartbeat]', err);
      return res.status(500).json({ ok: false, motivo: 'Error interno del servidor' });
    }
  };
  