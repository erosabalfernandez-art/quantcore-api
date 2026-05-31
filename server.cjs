const express = require('express');
const cors    = require('cors');
const path    = require('path');
const app     = express();

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname)));

app.post('/api/validar-licencia',    require('./api/validar-licencia'));
app.post('/api/heartbeat',           require('./api/heartbeat'));
app.post('/api/desactivar-licencia', require('./api/desactivar-licencia'));
app.post('/api/recibir-trades',      require('./api/recibir-trades'));
app.get('/api/health',               require('./api/health'));

app.get(/.*/, (req, res) => res.sendFile(path.join(__dirname, 'index.html')));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () =>
  console.log('FlowTrade Suite corriendo en puerto', PORT)
);
