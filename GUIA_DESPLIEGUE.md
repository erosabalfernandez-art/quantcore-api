# Guía de Despliegue — Samtrader Pro Suite

Esta guía te lleva desde cero hasta tener la plataforma funcionando en producción.  
Tiempo estimado: **30-45 minutos**.

---

## Índice

1. [Crear proyecto en Supabase](#1-supabase)
2. [Desplegar en Vercel](#2-vercel) ← opción recomendada
3. [Desplegar en Render](#3-render) ← alternativa
4. [Configurar el dominio y la URL en el index.html](#4-configurar-url)
5. [Configurar el primer admin](#5-primer-admin)
6. [Instalar el EA DataBridge en MetaTrader 5](#6-ea-databridge)
7. [Checklist final](#7-checklist)

---

## 1. Supabase

### 1.1 Crear el proyecto

1. Ve a [supabase.com](https://supabase.com) → **Start your project** → **New project**.
2. Elige un nombre (ej: `samtrader-pro`) y una contraseña segura para la base de datos.
3. Selecciona la región más cercana a tus usuarios (ej: Europa para España).
4. Espera ~2 minutos a que el proyecto se inicialice.

### 1.2 Ejecutar el SQL

1. En el menú izquierdo: **SQL Editor** → **New query**.
2. Pega **todo el contenido** del archivo `setup_supabase_completo.sql`.
3. Haz clic en **Run** (▶).
4. Al final verás una tabla con 12 filas, una por cada tabla creada. Si aparecen, todo está correcto.

### 1.3 Crear el bucket de Storage

1. Menú izquierdo: **Storage** → **New bucket**.
2. Nombre: `chat-images` | Marca **Public bucket** → **Create bucket**.

### 1.4 Obtener tus claves

Ve a **Settings → API** y copia:

| Clave | Para qué se usa |
|---|---|
| **Project URL** | Va en `index.html` y en la variable de entorno `SUPABASE_URL` |
| **anon / public key** | Va en `index.html` (ya está, solo cámbiala si usas tu propio proyecto) |
| **service_role key** ⚠️ | Va SOLO en Vercel/Render como variable de entorno. Nunca en el frontend |

> ⚠️ La `service_role key` tiene acceso total a tu base de datos. Trátala como una contraseña. Nunca la pongas en el HTML.

---

## 2. Vercel

### 2.1 Preparar el repositorio

1. Crea una cuenta en [github.com](https://github.com) si no tienes.
2. Crea un nuevo repositorio privado (ej: `samtrader-pro`).
3. Sube todos los archivos de esta carpeta al repositorio:
   ```
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/samtrader-pro.git
   git push -u origin main
   ```

### 2.2 Conectar con Vercel

1. Ve a [vercel.com](https://vercel.com) → **Add New Project**.
2. Elige **Import from GitHub** y selecciona tu repositorio.
3. En la sección **Configure Project**:
   - Framework Preset: **Other**
   - Root Directory: `/` (raíz, como está)
   - No cambies nada más. El `vercel.json` ya configura todo.
4. Antes de hacer Deploy, haz clic en **Environment Variables** y añade:

| Nombre | Valor |
|---|---|
| `SUPABASE_URL` | `https://XXXXXXXX.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | `eyJ...` (service role key de Supabase Settings → API) |

5. Haz clic en **Deploy** y espera ~1 minuto.
6. Vercel te dará una URL del tipo `https://samtrader-pro-XXXX.vercel.app`. ¡Tu web ya está en línea!

### 2.3 Dominio personalizado (opcional)

1. En tu proyecto Vercel → **Settings → Domains** → **Add Domain**.
2. Escribe tu dominio (ej: `app.samtrader.pro`).
3. Sigue las instrucciones para añadir el registro DNS en tu proveedor de dominio.

---

## 3. Render

Usa Render si prefieres no usar Vercel o ya tienes cuenta allí.

### 3.1 Crear el Web Service (API)

1. Ve a [render.com](https://render.com) → **New → Web Service**.
2. Conecta tu repositorio de GitHub.
3. Configura:
   - **Name**: `samtrader-api`
   - **Environment**: `Node`
   - **Build Command**: `npm install`
   - **Start Command**: `node server.js`
   - **Plan**: Free (funciona para empezar)
4. En **Environment Variables**, añade:
   - `SUPABASE_URL` = tu Project URL de Supabase
   - `SUPABASE_SERVICE_ROLE_KEY` = tu service role key

5. Crea el archivo `server.js` en la raíz del proyecto con este contenido:
   ```js
   const express = require('express');
   const cors    = require('cors');
   const app     = express();

   app.use(cors());
   app.use(express.json());
   app.use(express.static('.'));  // sirve index.html

   app.post('/api/validar-licencia',    require('./api/validar-licencia'));
   app.post('/api/heartbeat',           require('./api/heartbeat'));
   app.post('/api/desactivar-licencia', require('./api/desactivar-licencia'));
   app.post('/api/recibir-trades',      require('./api/recibir-trades'));
   app.get('/api/health',               require('./api/health'));

   // SPA fallback
   const path = require('path');
   app.get('*', (req, res) => res.sendFile(path.join(__dirname, 'index.html')));

   app.listen(process.env.PORT || 3000, () =>
     console.log('Samtrader API corriendo en puerto', process.env.PORT || 3000)
   );
   ```

6. Crea el `package.json` (si no lo tienes):
   ```json
   {
     "name": "samtrader-pro-suite",
     "version": "3.0.0",
     "main": "server.js",
     "scripts": { "start": "node server.js" },
     "dependencies": {
       "@supabase/supabase-js": "^2.39.0",
       "cors": "^2.8.5",
       "express": "^4.18.2"
     }
   }
   ```

### 3.2 Crear el Static Site (frontend)

Opcionalmente puedes separar el frontend:

1. **New → Static Site** → mismo repositorio.
2. **Publish directory**: `/` (raíz).
3. Render servirá el `index.html` automáticamente.

> Con Render Free, el servicio se "duerme" tras 15 min de inactividad y tarda ~30 segundos en despertar la primera petición. Para producción usa el plan Starter ($7/mes).

---

## 4. Configurar URL en index.html

El `index.html` ya tiene las claves de Supabase del proyecto de desarrollo. **Si usas tu propio proyecto Supabase**, debes cambiarlas:

Abre `index.html` y busca estas líneas (aproximadamente línea 1241):

```js
const SUPABASE_URL = 'https://raznmwztnucismwjaetc.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...';
const FINNHUB_KEY  = 'd8dq7fpr01qhm4agkptg...';
```

Cámbialas por las tuyas:
- `SUPABASE_URL` → tu Project URL de Supabase Settings → API
- `SUPABASE_KEY` → tu **anon / public** key (NO la service role)
- `FINNHUB_KEY` → obtén una gratuita en [finnhub.io](https://finnhub.io/register)

---

## 5. Primer Admin

Una vez que tu web esté en línea:

1. Abre la URL de tu plataforma y **regístrate con tu email de admin**.
2. Confirma el email (revisa la bandeja de entrada).
3. Ve a **Supabase Dashboard → Authentication → Users**.
4. Copia el **UUID** de tu usuario (columna "UID").
5. Ve a **SQL Editor → New Query** y ejecuta:
   ```sql
   insert into public.admins (user_id)
   values ('PEGA-AQUI-TU-UUID')
   on conflict (user_id) do nothing;
   ```
6. Recarga la plataforma. Verás aparecer el menú **Admin Panel** en la barra lateral.

---

## 6. EA DataBridge en MetaTrader 5

El EA `DataBridge.mq5` envía automáticamente tu historial de trades a la plataforma.

### 6.1 Instalación

1. Abre MetaTrader 5.
2. Menú: **Archivo → Abrir carpeta de datos**.
3. Copia `DataBridge.mq5` en: `MQL5 → Experts`.
4. En MT5: menú **Herramientas → MetaEditor** (o F4) → abre el archivo → compila con **F7**.
   - Debes ver: `0 errors, 0 warnings`.

### 6.2 Permitir WebRequest

1. En MT5: **Herramientas → Opciones → Expert Advisors**.
2. Marca **"Permitir WebRequest para las siguientes URL"**.
3. Añade tu URL de API:
   - Vercel: `https://samtrader-pro-XXXX.vercel.app`
   - Render: `https://samtrader-api.onrender.com`
4. Haz clic en **Aceptar**.

### 6.3 Configurar y ejecutar

1. Abre un **gráfico nuevo** en MT5 (cualquier par, cualquier temporalidad — úsalo solo para el DataBridge).
2. En el panel **Navegador** (Ctrl+N) → **Expert Advisors** → doble clic en **DataBridge**.
3. En la pestaña **Inputs**, configura:
   - `LicenseToken`: pega tu token de licencia (lo encuentras en **Mi Perfil → Token de Licencia**).
   - `ApiUrl`: la URL de tu API (ej: `https://samtrader-pro-XXXX.vercel.app/api/`).
   - `SendIntervalSeconds`: 3600 (envía cada hora, no lo bajes de 300).
4. Haz clic en **Aceptar**.
5. Asegúrate de que el botón **EA** en la barra de MT5 esté en verde (activo).

### 6.4 Verificar que funciona

En MT5 → pestaña **Diario** (parte inferior) debes ver algo como:

```
DataBridge v1.0 iniciado
API URL: https://tu-url.vercel.app/api/recibir-trades
DataBridge: Enviando lote #1 (20 trades)...
DataBridge: ✓ HTTP 200 — {"ok":true,"insertados":20,"omitidos":0}
```

En la plataforma web → sección **Conectar MT5** → el punto pasa a verde: **"Conectado — datos recibidos"**.

---

## 7. Checklist final

Marca cada punto antes de considerar tu plataforma lista:

### Supabase
- [ ] Proyecto creado y SQL ejecutado sin errores
- [ ] Verificación final muestra 12 tablas
- [ ] Bucket `chat-images` creado como público
- [ ] Mi usuario admin está en la tabla `admins`

### Web (Vercel o Render)
- [ ] Variables de entorno `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` configuradas
- [ ] Deploy exitoso (sin errores en los logs)
- [ ] La URL de producción abre la pantalla de login correctamente
- [ ] Me puedo registrar y hacer login

### index.html
- [ ] `SUPABASE_URL` apunta a mi proyecto Supabase
- [ ] `SUPABASE_KEY` es la anon key de mi proyecto
- [ ] `FINNHUB_KEY` es mi propia clave (o la del proyecto base)

### Admin
- [ ] Mi usuario aparece en la tabla `admins`
- [ ] Al entrar veo la sección **Admin Panel** en el menú
- [ ] Puedo ver la lista de usuarios en el panel admin

### EA DataBridge (opcional pero recomendado)
- [ ] `DataBridge.mq5` compilado sin errores en MetaEditor
- [ ] WebRequest permitido para la URL de la API en MT5
- [ ] EA corriendo en un gráfico separado con mi token de licencia
- [ ] En la pestaña Diario de MT5 aparece "✓ HTTP 200"
- [ ] En la web, sección "Conectar MT5" muestra punto verde

---

## Problemas frecuentes

| Síntoma | Causa probable | Solución |
|---|---|---|
| "Token no válido" en el EA | Token incorrecto o usuario no existe | Copia el token exactamente desde Mi Perfil |
| "URL no permitida" en MT5 | WebRequest no configurado | Herramientas → Opciones → Expert Advisors → añade la URL |
| La web muestra página en blanco | Claves Supabase incorrectas en index.html | Revisa SUPABASE_URL y SUPABASE_KEY |
| "Error 500" en la API | Variables de entorno no configuradas | Verifica SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY en Vercel/Render |
| No recibo email de confirmación | Supabase no tiene SMTP configurado | Settings → Auth → Email Templates → usa el SMTP de Gmail o Resend |
| El admin panel no aparece | Usuario no está en tabla admins | Ejecuta el INSERT en el SQL Editor de Supabase |
| DataBridge no envía trades | Cuenta sin historial o EA pausado | Comprueba el botón EA verde y que hay deals en el historial de MT5 |

---

## Configurar SMTP (para emails de confirmación)

Por defecto Supabase tiene límite de 2 emails/hora en el plan gratuito. Para producción:

1. Supabase Dashboard → **Settings → Auth → SMTP Settings**.
2. Activa "Enable Custom SMTP".
3. Opciones gratuitas recomendadas:
   - **Resend** (resend.com) — 100 emails/día gratis
   - **Brevo** (brevo.com) — 300 emails/día gratis
4. Introduce los datos SMTP que te dan (host, puerto, usuario, contraseña).

---

## Estructura de archivos entregados

```
samtrader_pro_suite/
├── index.html                     ← Frontend completo (SPA, ~3700 líneas)
├── vercel.json                    ← Configuración de rutas para Vercel
├── setup_supabase_completo.sql    ← 12 tablas + RLS + trigger + datos iniciales
├── GUIA_DESPLIEGUE.md             ← Esta guía
├── README.md                      ← Referencia técnica rápida
├── api/
│   ├── validar-licencia.js        ← POST /api/validar-licencia
│   ├── heartbeat.js               ← POST /api/heartbeat
│   ├── desactivar-licencia.js     ← POST /api/desactivar-licencia (solo admin)
│   ├── recibir-trades.js          ← POST /api/recibir-trades (DataBridge)
│   └── health.js                  ← GET  /api/health
└── ea_modificados/
    ├── DataBridge.mq5             ← EA gratuito, sincroniza historial con la web
    ├── RiskManager_QuantCore.mq5  ← EA gestión de riesgo (Premium+)
    ├── AutoJournaling_QuantCore.mq5 ← EA diario automático (Premium+)
    └── BacktestSimulator_QuantCore.mq5 ← EA simulador (Elite)
```

---

*Samtrader Pro Suite v3.1 — © 2026*
