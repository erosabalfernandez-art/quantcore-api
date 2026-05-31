# Samtrader Pro Suite — v3.0.0

Suite profesional para traders de MetaTrader 5. Diario de trading, calculadora de riesgo, EAs con licencias, ranking, notificaciones y panel de administración completo.

---

## Stack

- **Frontend**: HTML + CSS (Tailwind CDN) + JS vanilla — un solo `index.html`
- **Backend API**: Vercel Serverless Functions (Node.js / CommonJS)
- **Base de datos**: Supabase (PostgreSQL + Auth + Storage)
- **Noticias**: Finnhub API

---

## Estructura de archivos

```
samtrader_pro_suite/
├── index.html                        ← Frontend completo (SPA)
├── vercel.json                       ← Configuración Vercel
├── setup_supabase_completo.sql       ← Script SQL completo para Supabase
├── README.md
├── api/
│   ├── validar-licencia.js           ← POST /api/validar-licencia
│   ├── heartbeat.js                  ← POST /api/heartbeat
│   ├── desactivar-licencia.js        ← POST /api/desactivar-licencia
│   └── health.js                     ← GET  /api/health
├── RiskManager_QuantCore.mq5
├── AutoJournaling_QuantCore.mq5
└── BacktestSimulator_QuantCore.mq5
```

---

## Despliegue

### 1. Supabase — Configurar la base de datos

1. Crea un proyecto en [supabase.com](https://supabase.com)
2. Ve a **SQL Editor** y ejecuta el contenido de `setup_supabase_completo.sql`
3. En **Authentication → Providers**, activa Email
4. Crea tu usuario admin desde la app y luego inserta su ID en la tabla `admins`:
   ```sql
   INSERT INTO admins (user_id) VALUES ('<tu-user-id>');
   ```

### 2. Vercel — Desplegar la API y el frontend

1. Sube esta carpeta a GitHub o usa Vercel CLI: `vercel deploy`
2. En Vercel → **Settings → Environment Variables**, añade:
   - `SUPABASE_URL` = `https://tu-proyecto.supabase.co`
   - `SUPABASE_SERVICE_ROLE_KEY` = `eyJ...` (service role key del proyecto)
3. El `index.html` se sirve automáticamente como página raíz
4. Los endpoints de API estarán en `/api/*`

### Render (alternativa a Vercel)

Si usas Render en lugar de Vercel:
1. Crea un **Static Site** apuntando a `index.html`
2. Crea un **Web Service** Node.js con el siguiente server.js:

```js
const express = require('express');
const app = express();
app.use(express.json());
app.use(require('cors')());
app.post('/api/validar-licencia', require('./api/validar-licencia'));
app.post('/api/heartbeat', require('./api/heartbeat'));
app.post('/api/desactivar-licencia', require('./api/desactivar-licencia'));
app.get('/api/health', require('./api/health'));
app.listen(process.env.PORT || 3000);
```

---

## Credenciales hardcodeadas en index.html

El `index.html` incluye las claves de Supabase directamente (anon key, que es pública por diseño):

```js
const SUPABASE_URL = 'https://raznmwztnucismwjaetc.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...';  // anon key (pública)
```

La **service_role key** solo va en las variables de entorno de Vercel/Render, nunca en el frontend.

---

## Funcionalidades v3.0.0

### Usuario
- 🔐 Auth completo (login, registro, recuperar contraseña, reenvío de confirmación)
- 📊 Dashboard con KPIs, curva de equity, rendimiento por activo, widgets ocultables
- 📖 Diario de trading (IndexedDB local) con paginación, filtros, detalle de trade
- 📁 Import: CSV, HTML MetaTrader, JSON | Export: CSV, JSON, PDF (Elite)
- 📈 Métricas avanzadas: Sharpe ratio, mejor hora, mejor activo, rentabilidad/mes
- 💳 Planes (Gratis / Premium / Elite) con notificación de pago al admin
- 👤 Perfil con token de licencia, preferencias, estadísticas para ranking
- 🧮 Calculadora de riesgo mejorada (SL en pips, fórmula correcta, todos los activos)
- 🗞️ Calendario de noticias económicas (Finnhub) con alertas de alto impacto
- 👥 Referidos con enlace único, tabla de comisiones reales (DB)
- 🏆 Ranking de traders (opt-in, mínimo 10 trades)
- 🎖️ Logros / Gamificación (8 insignias desbloqueables)
- 📥 EAs & Descargas según plan
- 🔔 Centro de notificaciones (campana en nav, badge de no leídas)
- 🔔 Sistema de alertas avanzado: sesiones, drawdown, objetivo, racha, noticias, plan
- 🤖 Chatbot FAQ (botón ? morado, respuestas automáticas)
- 💬 Chat con soporte (tiempo real con polling)
- 🔧 Modal de mantenimiento (con bypass para admin)
- 📄 Modal de Términos de uso

### Admin
- 👥 Lista de usuarios con búsqueda, estado, plan
- 🎖️ Otorgar/cambiar membresías manualmente
- 💳 Gestión de pagos pendientes (con badge de cantidad)
- 💬 Chat con todos los usuarios
- 🔑 Gestión de licencias EA (activar/revocar)
- 📋 Logs de validaciones
- 📊 Estadísticas con Chart.js (ingresos, distribución de planes, EAs)
- 👥 Referidos Admin (árbol con botón "Marcar pagada")
- 🔧 Toggle de modo mantenimiento

---

## EAs de MetaTrader 5

| EA | Plan requerido | Descripción |
|----|---------------|-------------|
| RiskManager_QuantCore.mq5 | Premium+ | Lotaje auto, breakeven, trailing, prop firm |
| AutoJournaling_QuantCore.mq5 | Premium+ | Captura automática de operaciones |
| BacktestSimulator_QuantCore.mq5 | Elite | Simulador histórico vela a vela |

### Instalación del EA
1. Copia tu **Token de Licencia** desde la plataforma
2. En MT5: `Herramientas → Opciones → Expert Advisors` → activa WebRequest y añade la URL de tu API
3. Coloca el `.mq5` en `MQL5/Experts/` y compila con F7
4. Arrastra al gráfico → pega el token en el campo `Licencia_Token`

---

## Endpoints de API

### POST /api/validar-licencia
```json
{ "token": "...", "ea_tipo": "risk_manager", "mt5_account": "12345678" }
```
Respuesta OK:
```json
{ "valido": true, "plan": "premium", "mensaje": "Licencia activa", "heartbeat_interval": 3600 }
```

### POST /api/heartbeat
```json
{ "token": "...", "ea_tipo": "risk_manager", "mt5_account": "12345678" }
```

### POST /api/desactivar-licencia
Requiere header `Authorization: Bearer <supabase-jwt>` de un admin.
```json
{ "licencia_id": 123 }
```

### GET /api/health
```json
{ "ok": true, "service": "Samtrader Pro Suite API", "version": "3.0.0" }
```

---

© 2026 Samtrader Pro Suite
