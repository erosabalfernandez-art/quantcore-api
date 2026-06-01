// api/validar-licencia.js — Vercel Serverless Function v3
  // Valida el token de licencia de un EA. DataBridge disponible para todos los planes.
  // Registra y vincula la cuenta MT5 de forma permanente (solo admin puede desbloquear).

  const { createClient } = require('@supabase/supabase-js');
const { checkRateLimit, checkAutoBlock, checkOrigin, genericError } = require('./_lib/security');

  const CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Content-Type': 'application/json',
  };

  // data_bridge disponible para TODOS los planes (es el único método de conexión)
  const PLAN_EA = {
    risk_manager:       ['premium', 'elite'],
    auto_journaling:    ['premium', 'elite'],
    backtest_simulator: ['elite'],
    data_bridge:        ['gratis', 'premium', 'elite'],
  };

  module.exports = async function handler(req, res) {
    if (req.method === 'OPTIONS') return res.status(200).set(CORS_HEADERS).end();
    Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
    if (req.method !== 'POST') return res.status(405).json({ valido: false, motivo: 'Método no permitido', codigo: 405 });

    const { token: _tok, ea_tipo: _ea, mt5_account: _mt5, version_ea, hwid } = req.body || {};
  const token = (_tok||''). trim();
  const ea_tipo = (_ea||''). trim();
  const mt5_account = (_mt5||''). trim();
    const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket?.remoteAddress || 'unknown';

    const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

    // Validación de origen (bloquea navegadores de orígenes desconocidos)
    if (!checkOrigin(req)) {
      return res.status(403).json({ valido: false, motivo: 'Origen no permitido', codigo: 403 });
    }

    // Rate limiting por IP
    const rateLimited = await checkRateLimit(sb, ip);
    if (rateLimited) {
      return res.status(429).json({ valido: false, motivo: 'Demasiadas solicitudes. Espera 1 minuto.', codigo: 429 });
    }

    // Auto-bloqueo por fallos consecutivos del mismo token
    if (token) {
      const autoBlocked = await checkAutoBlock(sb, token);
      if (autoBlocked) {
        return res.status(429).json({ valido: false, motivo: 'Token temporalmente bloqueado por múltiples fallos. Espera 5 minutos.', codigo: 429 });
      }
    }

    if (!token || !ea_tipo || !mt5_account) {
      return res.status(400).json({ valido: false, motivo: 'Campos requeridos: token, ea_tipo, mt5_account', codigo: 400 });
    }
    if (!PLAN_EA[ea_tipo]) {
      return res.status(400).json({ valido: false, motivo: `EA tipo desconocido: ${ea_tipo}`, codigo: 400 });
    }

    let motivo = null, usuarioId = null, plan = null;

    try {
      // 1. Buscar usuario por token
      const { data: perfil, error: errP } = await sb
        .from('perfiles')
        .select('id, nombre, plan, mt5_cuenta, mt5_cuenta_bloqueada, bloqueado, token_licencia, fecha_expiracion_plan')
        .eq('token_licencia', token)
        .single();

      if (errP || !perfil) {
        motivo = 'Token no encontrado';
        await logIntento(sb, { token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
        return res.status(403).json({ valido: false, motivo, codigo: 403 });
      }

      usuarioId = perfil.id;
      plan = perfil.plan || 'gratis';

      // 2. Bloqueado
      if (perfil.bloqueado) {
        motivo = 'Cuenta bloqueada por nuestro equipo';
        await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
        return res.status(403).json({ valido: false, motivo, codigo: 403 });
      }

      // 3. Plan
      if (!PLAN_EA[ea_tipo].includes(plan)) {
        motivo = `Plan "${plan}" no incluye el EA "${ea_tipo}". Requerido: ${PLAN_EA[ea_tipo].join(' o ')}`;
        await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
        return res.status(403).json({ valido: false, motivo, codigo: 403 });
      }

      // 3b. Membresía expirada (excepto plan gratis que no expira)
      if (plan !== 'gratis' && perfil.fecha_expiracion_plan) {
        const expDate = new Date(perfil.fecha_expiracion_plan);
        if (expDate < new Date()) {
          motivo = `Membresía ${plan} vencida el ${expDate.toLocaleDateString('es-ES')}. Renueva tu plan en FlowTrade Suite.`;
          await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
          return res.status(403).json({ valido: false, motivo, expirado: true, codigo: 403 });
        }
      }

      // 4. Verificar o vincular cuenta MT5 (SOLO para data_bridge)
      if (ea_tipo === 'data_bridge') {
        if (perfil.mt5_cuenta && perfil.mt5_cuenta_bloqueada) {
          // Cuenta ya vinculada y bloqueada — verificar que coincide
          if (String(perfil.mt5_cuenta).trim() !== String(mt5_account).trim()) {
            motivo = genericError('cuenta_bloqueada');
            await logAlertaFraude(sb, { usuarioId, tipo: 'cuenta_diferente', detalle: `Cuenta diferente detectada — ip: ${ip}`, ip });
            await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
            return res.status(403).json({ valido: false, motivo, bloqueo_cuenta: true, codigo: 403 });
          }
        } else if (!perfil.mt5_cuenta) {
          // Primera vez — vincular cuenta MT5 permanentemente
          await sb.from('perfiles').update({
            mt5_cuenta: String(mt5_account),
            mt5_cuenta_bloqueada: true,
            fecha_registro_mt5: new Date().toISOString(),
          }).eq('id', usuarioId);
        }
      } else {
        // Para otros EAs: verificar que la cuenta coincide si ya está asignada
        if (perfil.mt5_cuenta && String(perfil.mt5_cuenta).trim() !== String(mt5_account).trim()) {
          motivo = genericError('mt5_no_coincide');
          await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
          return res.status(403).json({ valido: false, motivo, codigo: 403 });
        }
      }

      // 5. Verificar licencia existente y HWID
      const { data: licExistente } = await sb
        .from('licencias_ea')
        .select('id, mt5_account, activo, hwid, ip_registro')
        .eq('usuario_id', usuarioId)
        .eq('ea_tipo', ea_tipo)
        .single();

      if (licExistente) {
        if (!licExistente.activo) {
          motivo = 'Licencia desactivada por el administrador. Contacta al soporte.';
          await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
          return res.status(403).json({ valido: false, motivo, codigo: 403 });
        }
        // HWID check: si el HWID difiere → BLOQUEO AUTOMÁTICO + alerta de fraude
        if (hwid && licExistente.hwid && licExistente.hwid !== hwid) {
          await logAlertaFraude(sb, {
            usuarioId, tipo: 'hwid_diferente',
            detalle: `HWID registrado: ${licExistente.hwid} | Nuevo HWID: ${hwid} | Cuenta: ${mt5_account} — LICENCIA DESACTIVADA AUTOMÁTICAMENTE`,
            ip,
          });
          // BLOQUEO AUTOMÁTICO: segundo dispositivo detectado → desactivar licencia inmediatamente
          await sb.from('licencias_ea').update({ activo: false }).eq('id', licExistente.id);
          motivo = 'Este EA está registrado en otro dispositivo. La licencia ha sido desactivada automáticamente por seguridad. Contacta al administrador para reactivarla.';
          await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: false, motivo, ip, version_ea, hwid });
          return res.status(403).json({ valido: false, motivo, hwid_bloqueado: true, codigo: 403 });
        }
        // Actualizar heartbeat y HWID si es nuevo
        await sb.from('licencias_ea').update({
          activo: true,
          ultimo_heartbeat: new Date().toISOString(),
          mt5_account: String(mt5_account),
          ...(hwid && !licExistente.hwid ? { hwid, ip_registro: ip } : {}),
        }).eq('id', licExistente.id);
      } else {
        // Primera activación
        await sb.from('licencias_ea').insert({
          usuario_id: usuarioId,
          ea_tipo,
          mt5_account: String(mt5_account),
          activo: true,
          fecha_activacion: new Date().toISOString(),
          ultimo_heartbeat: new Date().toISOString(),
          hwid: hwid || null,
          ip_registro: ip,
        });
      }

      await logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito: true, motivo: 'OK', ip, version_ea, hwid });

      // Calcular días restantes
      let diasRestantes = null;
      if (plan !== 'gratis' && perfil.fecha_expiracion_plan) {
        diasRestantes = Math.ceil((new Date(perfil.fecha_expiracion_plan) - new Date()) / 86400000);
      }

      return res.status(200).json({
        valido: true,
        plan,
        mensaje: `Licencia activa para ${ea_tipo} — Plan ${plan}${diasRestantes !== null ? ' — vence en ' + diasRestantes + ' días' : ''}`,
        heartbeat_interval: 3600,
        usuario: perfil.nombre,
        cuenta_vinculada: String(mt5_account),
        dias_restantes: diasRestantes,
      });

    } catch (err) {
      console.error('[validar-licencia] Error interno:', err);
      return res.status(500).json({ valido: false, motivo: 'Error interno del servidor', codigo: 500 });
    }
  };

  async function logIntento(sb, { usuarioId, token, ea_tipo, mt5_account, exito, motivo, ip, version_ea, hwid }) {
    try {
      await sb.from('logs_licencias').insert({
        usuario_id: usuarioId || null,
        token_usado: token,
        ea_tipo,
        mt5_account: String(mt5_account),
        exito, motivo, ip,
        version_ea: version_ea || null,
        fecha: new Date().toISOString(),
      });
    } catch (e) { console.error('[logIntento]', e); }
  }

  async function logAlertaFraude(sb, { usuarioId, tipo, detalle, ip }) {
    try {
      await sb.from('alertas_fraude').insert({
        usuario_id: usuarioId || null,
        tipo, detalle, ip,
        fecha: new Date().toISOString(),
        revisado: false,
      });
    } catch (e) { console.error('[logAlertaFraude]', e); }
  }
  