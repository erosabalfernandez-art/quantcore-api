// api/desactivar-licencia.js — Vercel Serverless Function
// Desactiva una licencia EA (solo admins) vía el panel web

import { createClient } from '@supabase/supabase-js';

const sb = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY   // service_role key — nunca la anon key aquí
);

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST')   return res.status(405).json({ error: 'Method not allowed' });

  const { licencia_id, admin_token } = req.body ?? {};

  if (!licencia_id) return res.status(400).json({ error: 'licencia_id requerido' });

  // Verificar que el solicitante es admin (via JWT de Supabase)
  const authHeader = req.headers.authorization ?? '';
  const jwt = authHeader.replace('Bearer ', '').trim();
  if (!jwt) return res.status(401).json({ error: 'Sin autorización' });

  const { data: { user }, error: authErr } = await sb.auth.getUser(jwt);
  if (authErr || !user) return res.status(401).json({ error: 'Token inválido' });

  const { data: adminRow } = await sb
    .from('admins')
    .select('user_id')
    .eq('user_id', user.id)
    .single();

  if (!adminRow) return res.status(403).json({ error: 'Solo administradores' });

  const { error } = await sb
    .from('licencias_ea')
    .update({ activo: false })
    .eq('id', licencia_id);

  if (error) return res.status(500).json({ error: error.message });
  return res.status(200).json({ ok: true, mensaje: 'Licencia desactivada' });
}
