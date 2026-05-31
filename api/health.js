// api/health.js — Vercel Serverless Function
// Health check endpoint para monitorear la API

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json');
  if (req.method === 'OPTIONS') return res.status(200).end();
  return res.status(200).json({
    ok: true,
    service: 'FlowTrade Suite API',
    version: '3.0.0',
    timestamp: new Date().toISOString(),
  });
};
