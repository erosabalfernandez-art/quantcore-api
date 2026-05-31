const express = require('express');
const cors    = require('cors');
const path    = require('path');
const https   = require('https');
const http    = require('http');
const { URL }  = require('url');
const app     = express();

app.use(cors());
app.use(express.json({ limit: '4mb' }));
app.use(express.static(path.join(__dirname)));

app.post('/api/validar-licencia',    require('./api/validar-licencia'));
app.post('/api/heartbeat',           require('./api/heartbeat'));
app.post('/api/desactivar-licencia', require('./api/desactivar-licencia'));
app.post('/api/recibir-trades',      require('./api/recibir-trades'));
app.post('/api/recibir-simbolos',    require('./api/recibir-simbolos'));
app.get('/api/health',               require('./api/health'));

// ─── AI Proxy ────────────────────────────────────────────────────────────────
// Forwards browser AI requests to external providers, bypassing CORS issues.
const AI_ALLOWED_HOSTS = [
  'api.openai.com',
  'api.anthropic.com',
  'generativelanguage.googleapis.com',
  'openrouter.ai',
];

app.post('/api/ai-proxy', (req, res) => {
  const { targetUrl, headers: fwdHeaders, body } = req.body || {};
  if (!targetUrl) return res.status(400).json({ error: 'targetUrl required' });

  let parsed;
  try { parsed = new URL(targetUrl); } catch { return res.status(400).json({ error: 'Invalid targetUrl' }); }

  if (!AI_ALLOWED_HOSTS.includes(parsed.hostname)) {
    return res.status(403).json({ error: 'Host not allowed: ' + parsed.hostname });
  }

  const bodyStr = JSON.stringify(body);
  const reqHeaders = {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(bodyStr),
    ...fwdHeaders,
  };

  const options = {
    hostname: parsed.hostname,
    path: parsed.pathname + parsed.search,
    method: 'POST',
    headers: reqHeaders,
  };

  const proto = parsed.protocol === 'https:' ? https : http;
  const proxyReq = proto.request(options, (proxyRes) => {
    res.status(proxyRes.statusCode);
    Object.entries(proxyRes.headers).forEach(([k, v]) => {
      if (!['transfer-encoding','connection'].includes(k)) res.setHeader(k, v);
    });
    proxyRes.pipe(res);
  });
  proxyReq.on('error', (e) => res.status(502).json({ error: e.message }));
  proxyReq.write(bodyStr);
  proxyReq.end();
});

app.get(/.*/, (req, res) => res.sendFile(path.join(__dirname, 'index.html')));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () =>
  console.log('FlowTrade Suite corriendo en puerto', PORT)
);
