// api/ai-proxy.js — Vercel Serverless Function
// Proxy reverso para peticiones de IA desde el frontend.
// Evita exponer API keys en el cliente y soluciona CORS con proveedores externos.

const https   = require('https');
const http    = require('http');
const { URL } = require('url');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

const AI_ALLOWED_HOSTS = [
  'api.openai.com',
  'api.anthropic.com',
  'generativelanguage.googleapis.com',
  'openrouter.ai',
];

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
    return res.status(200).end();
  }
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Método no permitido' });
  }

  const { targetUrl, headers: fwdHeaders, body } = req.body || {};
  if (!targetUrl) return res.status(400).json({ error: 'targetUrl requerido' });

  let parsed;
  try { parsed = new URL(targetUrl); }
  catch { return res.status(400).json({ error: 'targetUrl inválida' }); }

  if (!AI_ALLOWED_HOSTS.includes(parsed.hostname)) {
    return res.status(403).json({ error: 'Host no permitido: ' + parsed.hostname });
  }

  const bodyStr = JSON.stringify(body);
  const reqHeaders = {
    'Content-Type':   'application/json',
    'Content-Length': Buffer.byteLength(bodyStr),
    ...fwdHeaders,
  };

  const options = {
    hostname: parsed.hostname,
    path:     parsed.pathname + parsed.search,
    method:   'POST',
    headers:  reqHeaders,
  };

  return new Promise((resolve) => {
    const proto = parsed.protocol === 'https:' ? https : http;
    const proxyReq = proto.request(options, (proxyRes) => {
      res.status(proxyRes.statusCode);
      Object.entries(proxyRes.headers).forEach(([k, v]) => {
        if (!['transfer-encoding', 'connection'].includes(k)) res.setHeader(k, v);
      });
      proxyRes.pipe(res);
      resolve();
    });
    proxyReq.on('error', (e) => {
      res.status(502).json({ error: e.message });
      resolve();
    });
    proxyReq.write(bodyStr);
    proxyReq.end();
  });
};
