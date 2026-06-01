// api/send-push.js — Vercel serverless function
// Sends Web Push notifications to all subscribers
// Requires: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type,Authorization',
};

module.exports = async (req, res) => {
  if (req.method === 'OPTIONS') { return res.status(200).set(CORS_HEADERS).end(); }
  Object.entries(CORS_HEADERS).forEach(([k,v]) => res.setHeader(k,v));

  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  // Verify admin via Supabase JWT
  const token = req.headers.authorization?.replace('Bearer ','');
  if (!token) return res.status(401).json({ error: 'Unauthorized' });

  const SUPABASE_URL  = process.env.SUPABASE_URL;
  const SERVICE_KEY   = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const VAPID_PUB     = process.env.VAPID_PUBLIC_KEY;
  const VAPID_PRIV    = process.env.VAPID_PRIVATE_KEY;
  const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:admin@flowtrade.app';

  if (!VAPID_PUB || !VAPID_PRIV) return res.status(500).json({ error: 'VAPID keys not configured' });

  const { title, body, url } = req.body || {};
  if (!title || !body) return res.status(400).json({ error: 'title and body required' });

  // Verify caller is admin
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: SERVICE_KEY }
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid token' });
  const { id: userId } = await userRes.json();

  const profileRes = await fetch(`${SUPABASE_URL}/rest/v1/perfiles?id=eq.${userId}&select=rol`, {
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY }
  });
  const [profile] = await profileRes.json();
  if (profile?.rol !== 'admin') return res.status(403).json({ error: 'Forbidden' });

  // Fetch all push subscriptions
  const subsRes = await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?select=endpoint,p256dh,auth`, {
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY }
  });
  const subscriptions = await subsRes.json();
  if (!subscriptions?.length) return res.json({ sent: 0 });

  // Dynamic import of web-push
  const webpush = require('web-push');
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUB, VAPID_PRIV);

  const payload = JSON.stringify({ title, body, url: url || '/' });
  let sent = 0, failed = 0;

  await Promise.allSettled(subscriptions.map(async (sub) => {
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload
      );
      sent++;
    } catch(e) {
      failed++;
      // Remove invalid subscriptions (410 Gone)
      if (e.statusCode === 410) {
        await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?endpoint=eq.${encodeURIComponent(sub.endpoint)}`, {
          method: 'DELETE',
          headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY }
        });
      }
    }
  }));

  return res.json({ sent, failed });
};
