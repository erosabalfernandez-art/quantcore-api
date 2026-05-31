# QuantCore Pro Suite — Parte 3: Sistema de Licencias EA

Entrega completa con todos los archivos corregidos y listos para usar.

## Estructura del paquete

```
output/
├── index.html                        ← Panel web (con sección Licencias EA completa)
├── setup_supabase_corregido.sql      ← Script SQL corregido para Supabase
├── api/
│   ├── validar-licencia.js           ← Vercel serverless: valida token + plan
│   ├── heartbeat.js                  ← Vercel serverless: actualiza último heartbeat
│   └── desactivar-licencia.js        ← Vercel serverless: revoca licencia (admin)
├── ea_modificados/
│   ├── RiskManager_QuantCore.mq5     ← v13.5 con licencias (corregido)
│   ├── AutoJournaling_QuantCore.mq5  ← v2.13 con licencias (corregido)
│   └── BacktestSimulator_QuantCore.mq5 ← v4.2 con licencias (sin cambios adicionales)
└── README.md                         ← Este archivo
```

## Bugs corregidos

### setup_supabase_corregido.sql
| # | Bug original | Corrección |
|---|---|---|
| 1 | `CREATE POLICY IF NOT EXISTS` (PostgreSQL no soporta esta sintaxis) | `DROP POLICY IF EXISTS` + `CREATE POLICY` |
| 2 | `p.email` en `vista_licencias_admin` (columna inexistente en `perfiles`) | Subconsulta `(SELECT email FROM auth.users WHERE id = p.id)` |
| 3 | `admins WHERE id = auth.uid()` (la tabla `admins` usa `user_id` como PK) | `admins WHERE user_id = auth.uid()` |

### AutoJournaling_QuantCore.mq5
| # | Bug original | Corrección |
|---|---|---|
| 1 | `input string Licencia_Token` declarado dos veces (duplicado antes del bloque de licencias) | Eliminada la declaración duplicada |
| 2 | `input string InpServerURL = ApiUrl + "journal"` referencia `ApiUrl` antes de que exista | Línea eliminada |
| 3 | `EventSetTimer(LIC_TIMER_SECS)` — constante `LIC_TIMER_SECS` nunca definida | Cambiado a `EventSetTimer(1)` |
| 4 | `if(now - lastCheck >= LIC_TIMER_SECS)` en OnTimer — misma constante indefinida | Cambiado a `HeartbeatInterval` |
| 5 | `if(!g_license_ok)` en `OnTradeTransaction` (nombre incorrecto de variable) | Corregido a `if(!g_licencia_ok)` |
| 6 | `}` extra/suelto al final del bloque de licencias en `OnInit` | Eliminado |

### RiskManager_QuantCore.mq5
| # | Bug original | Corrección |
|---|---|---|
| 1 | `}` suelto en `OnInit` después del bloque de licencias (cierre falso de función) | Eliminado |
| 2 | `}` suelto en `OnTimer` después del bloque de heartbeat | Eliminado |

### index.html
| # | Bug original | Corrección |
|---|---|---|
| 1 | `<div id="adminContent-chats">` nunca se cerraba — las pestañas Licencias y Logs quedaban anidadas dentro | Añadido `</div>` correcto antes de la pestaña Licencias |
| 2 | Funciones `loadLicencias()`, `loadLogsLic()` y `toggleLicencia()` referenciadas en el HTML pero no implementadas | Implementadas completamente en JS |
| 3 | `showAdminTab()` no disparaba carga de datos para pestañas 'licencias' y 'logslic' | Añadidos los triggers correspondientes |

## Instrucciones de despliegue

### 1. Supabase — ejecutar el SQL
1. Abre tu proyecto Supabase → **SQL Editor → New Query**
2. Pega el contenido de `setup_supabase_corregido.sql` y haz clic en **Run**

### 2. Vercel — subir las funciones API
Coloca los tres archivos de `api/` en la carpeta `api/` de tu proyecto Vercel.  
Configura estas variables de entorno en Vercel:
- `SUPABASE_URL` — URL de tu proyecto Supabase
- `SUPABASE_SERVICE_KEY` — Service Role Key (nunca la anon key)

### 3. EAs MT5
1. Copia los `.mq5` a `MQL5/Experts/`
2. Compila en MetaEditor (F7)
3. En MT5: **Herramientas → Opciones → Expert Advisors → WebRequest**  
   Añade: `https://TU-PROYECTO.vercel.app`
4. Arrastra el EA al gráfico, ingresa tu token de licencia en `Licencia_Token`

### 4. Panel web
Sube el `index.html` corregido a tu hosting (reemplaza el actual).  
Si usas el mismo `index.html` local, no es necesario ningún cambio adicional de configuración — las credenciales Supabase ya están incrustadas.

---
*Generado automáticamente — QuantCore Pro Suite Parte 3*
