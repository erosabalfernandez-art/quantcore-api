// api/desactivar-licencia.js — Vercel Serverless Function
// Desactiva una licencia EA desde el panel admin
// Variables de entorno: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

const { createClient } = require('@supabase/supabase-js');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Content-Type': 'application/json',
};

module.exports = async function handler(req, res) {
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST')   return res.status(405).json({ error: 'Método no permitido' });

  const { licencia_id } = req.body ?? {};
  if (!licencia_id) return res.status(400).json({ error: 'licencia_id requerido' });

  // Verificar que el solicitante es admin via JWT de Supabase
  const authHeader = req.headers['authorization'] ?? '';
  const jwt = authHeader.replace('Bearer ', '').trim();
  if (!jwt) return res.status(401).json({ error: 'Sin autorización. Envía Authorization: Bearer <token>' });

  const sb = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY   // service_role, nunca anon key
  );

  try {
    // 1. Verificar que el JWT pertenece a un usuario real
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt);
    if (authErr || !user) return res.status(401).json({ error: 'Token JWT inválido o expirado' });

    // 2. Verificar que ese usuario es administrador
    const { data: adminRow } = await sb
      .from('admins')
      .select('user_id')
      .eq('user_id', user.id)
      .single();

    if (!adminRow) return res.status(403).json({ error: 'Acceso denegado. Solo administradores.' });

    // 3. Desactivar la licencia
    const { error } = await sb
      .from('licencias_ea')
      .update({ activo: false })
      .eq('id', licencia_id);

    if (error) return res.status(500).json({ error: error.message });

    return res.status(200).json({ ok: true, mensaje: 'Licencia desactivada correctamente' });

  } catch (err) {
    console.error('[desactivar-licencia] Error:', err);
    return res.status(500).json({ error: 'Error interno del servidor' });
  }
};
