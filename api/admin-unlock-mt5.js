// api/admin-unlock-mt5.js — Vercel Serverless Function
  // Endpoint exclusivo de administrador para desbloquear/cambiar cuenta MT5 de un usuario.

  const { createClient } = require('@supabase/supabase-js');

  const CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Content-Type': 'application/json',
  };

  module.exports = async function handler(req, res) {
    if (req.method === 'OPTIONS') return res.status(200).set(CORS_HEADERS).end();
    Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
    if (req.method !== 'POST') return res.status(405).json({ ok: false });

    // El admin envía su JWT de Supabase en el header Authorization
    const authHeader = req.headers['authorization'] || '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return res.status(401).json({ ok: false, motivo: 'Authorization requerido' });

    const { usuario_id, accion, motivo_admin, nueva_cuenta } = req.body || {};
    if (!usuario_id || !accion) return res.status(400).json({ ok: false, motivo: 'usuario_id y accion requeridos' });

    // Acciones válidas
    const ACCIONES_VALIDAS = ['desbloquear_mt5', 'cambiar_mt5', 'revocar_licencia_ea', 'activar_licencia_ea'];
    if (!ACCIONES_VALIDAS.includes(accion)) {
      return res.status(400).json({ ok: false, motivo: `Accion no válida. Válidas: ${ACCIONES_VALIDAS.join(', ')}` });
    }

    const sbAdmin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
    const sbUser  = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });

    // Verificar que el caller es admin
    const { data: { user }, error: authErr } = await sbUser.auth.getUser();
    if (authErr || !user) return res.status(401).json({ ok: false, motivo: 'JWT inválido' });

    const { data: adminRow } = await sbAdmin.from('admins').select('user_id').eq('user_id', user.id).single();
    if (!adminRow) return res.status(403).json({ ok: false, motivo: 'No eres administrador' });

    try {
      if (accion === 'desbloquear_mt5') {
        // Desvincula la cuenta MT5 para que pueda volver a vincular una nueva
        await sbAdmin.from('perfiles').update({
          mt5_cuenta: null,
          mt5_cuenta_bloqueada: false,
          fecha_registro_mt5: null,
        }).eq('id', usuario_id);

        // Eliminar licencia data_bridge para que pueda re-registrarse
        await sbAdmin.from('licencias_ea')
          .delete()
          .eq('usuario_id', usuario_id)
          .eq('ea_tipo', 'data_bridge');

        // Log de la acción admin
        await sbAdmin.from('admin_mt5_unlocks').insert({
          admin_id: user.id,
          usuario_id,
          accion: 'desbloquear_mt5',
          motivo: motivo_admin || 'Sin motivo especificado',
          fecha: new Date().toISOString(),
        });

        return res.status(200).json({ ok: true, mensaje: 'Cuenta MT5 desbloqueada. El usuario puede vincular una nueva cuenta.' });
      }

      if (accion === 'cambiar_mt5') {
        if (!nueva_cuenta) return res.status(400).json({ ok: false, motivo: 'nueva_cuenta requerida para cambiar_mt5' });

        const { data: perfilActual } = await sbAdmin.from('perfiles').select('mt5_cuenta').eq('id', usuario_id).single();

        await sbAdmin.from('perfiles').update({
          mt5_cuenta: String(nueva_cuenta),
          mt5_cuenta_bloqueada: true,
          fecha_registro_mt5: new Date().toISOString(),
        }).eq('id', usuario_id);

        await sbAdmin.from('licencias_ea').update({
          mt5_account: String(nueva_cuenta),
          hwid: null,
        }).eq('usuario_id', usuario_id).eq('ea_tipo', 'data_bridge');

        await sbAdmin.from('admin_mt5_unlocks').insert({
          admin_id: user.id,
          usuario_id,
          accion: 'cambiar_mt5',
          motivo: motivo_admin || 'Cambio por admin',
          mt5_cuenta_anterior: perfilActual?.mt5_cuenta || null,
          mt5_cuenta_nueva: String(nueva_cuenta),
          fecha: new Date().toISOString(),
        });

        return res.status(200).json({ ok: true, mensaje: `Cuenta MT5 cambiada a ${nueva_cuenta}` });
      }

      if (accion === 'revocar_licencia_ea') {
        const { ea_tipo } = req.body;
        if (!ea_tipo) return res.status(400).json({ ok: false, motivo: 'ea_tipo requerido' });
        await sbAdmin.from('licencias_ea').update({ activo: false }).eq('usuario_id', usuario_id).eq('ea_tipo', ea_tipo);
        return res.status(200).json({ ok: true, mensaje: `Licencia ${ea_tipo} revocada` });
      }

      if (accion === 'activar_licencia_ea') {
        const { ea_tipo } = req.body;
        if (!ea_tipo) return res.status(400).json({ ok: false, motivo: 'ea_tipo requerido' });
        await sbAdmin.from('licencias_ea').update({ activo: true, ultimo_heartbeat: new Date().toISOString() }).eq('usuario_id', usuario_id).eq('ea_tipo', ea_tipo);
        return res.status(200).json({ ok: true, mensaje: `Licencia ${ea_tipo} activada` });
      }

    } catch (err) {
      console.error('[admin-unlock-mt5]', err);
      return res.status(500).json({ ok: false, motivo: 'Error interno' });
    }
  };
  