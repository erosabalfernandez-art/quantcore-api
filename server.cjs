// server.cjs — Render (frontend only)
// Sirve únicamente el frontend estático (index.html + assets).
// Toda la lógica de API está en Vercel (api/*.js).
const express = require('express');
const cors    = require('cors');
const path    = require('path');
const app     = express();

app.use(cors());
app.use(express.json({ limit: '4mb' }));
app.use(express.static(path.join(__dirname)));

// SPA catch-all — index.html para todas las rutas no estáticas
app.get(/.*/, (req, res) => res.sendFile(path.join(__dirname, 'index.html')));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () =>
  console.log('FlowTrade Suite frontend corriendo en puerto', PORT)
);
