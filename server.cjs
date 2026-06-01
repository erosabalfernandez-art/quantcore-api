// server.cjs — Render (frontend only)
  // Sirve únicamente el frontend estático (index.html + assets).
  // Toda la lógica de API está en Vercel (api/*.js).
  const express = require('express');
  const cors    = require('cors');
  const path    = require('path');
  const app     = express();

  app.use(cors());
  app.use(express.json({ limit: '4mb' }));

  // Archivos estáticos (SW, imágenes, etc.) — sin restricción de caché
  app.use(express.static(path.join(__dirname), { index: false }));

  // index.html siempre fresco — sin caché en el navegador
  app.get(/.*/, (req, res) => {
    res.set({
      'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
      'Pragma': 'no-cache',
      'Expires': '0',
    });
    res.sendFile(path.join(__dirname, 'index.html'));
  });

  const PORT = process.env.PORT || 3000;
  app.listen(PORT, () =>
    console.log('FlowTrade Suite frontend corriendo en puerto', PORT)
  );
  