-- ══════════════════════════════════════════════════════════════════
-- setup_supabase_completo.sql
-- Samtrader Pro Suite — Script SQL COMPLETO
-- Ejecuta esto en: Supabase → SQL Editor → New Query → Run
-- IMPORTANTE: Ejecuta este script ANTES de registrar cualquier usuario
-- ══════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- 1. TABLA PRINCIPAL: perfiles
--    Se crea una fila automáticamente cuando un usuario se registra
--    gracias al trigger handle_new_user (ver sección 3)
-- ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.perfiles (
  id                        UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre                    TEXT,
  plan                      TEXT NOT NULL DEFAULT 'gratis' CHECK (plan IN ('gratis','premium','elite')),
  bloqueado                 BOOLEAN NOT NULL DEFAULT false,
  mt5_cuenta                TEXT,
  mt5_servidor              TEXT,
  activos_manuales          TEXT,
  token_licencia            TEXT UNIQUE,
  fecha_registro            TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_expiracion_plan     TIMESTAMPTZ,
  referidos_clics           INTEGER NOT NULL DEFAULT 0,
  referidos_conversiones    INTEGER NOT NULL DEFAULT 0,
  referidos_comisiones      NUMERIC(10,2) NOT NULL DEFAULT 0,
  referido_por              UUID REFERENCES public.perfiles(id),
  logros                    JSONB NOT NULL DEFAULT '[]'::jsonb
);

-- Añadir columnas que puedan faltar si la tabla ya existía
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS nombre                  TEXT;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS bloqueado               BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS mt5_cuenta              TEXT;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS mt5_servidor            TEXT;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS activos_manuales        TEXT;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS token_licencia          TEXT UNIQUE;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS fecha_registro          TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS fecha_expiracion_plan   TIMESTAMPTZ;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS referidos_clics         INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS referidos_conversiones  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS referidos_comisiones    NUMERIC(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS referido_por            UUID REFERENCES public.perfiles(id);
ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS logros                  JSONB NOT NULL DEFAULT '[]'::jsonb;

-- ──────────────────────────────────────────────────────────────────
-- 2. TABLA ADMINS
-- ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admins (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE
);

-- ──────────────────────────────────────────────────────────────────
-- 3. TRIGGER: crear perfil automáticamente al registrarse
--    SIN ESTE TRIGGER el registro da error 422
-- ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.perfiles (
    id,
    nombre,
    plan,
    bloqueado,
    token_licencia,
    fecha_registro
  )
  VALUES (
    NEW.id,
    COALESCE(
      NEW.raw_user_meta_data->>'nombre',
      split_part(NEW.email, '@', 1)
    ),
    'gratis',
    false,
    replace(gen_random_uuid()::text, '-', ''),
    now()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Eliminar trigger anterior si existe y recrear
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- Crear perfiles para usuarios auth.users que no tengan perfil todavía
INSERT INTO public.perfiles (id, nombre, plan, bloqueado, token_licencia, fecha_registro)
SELECT
  u.id,
  COALESCE(u.raw_user_meta_data->>'nombre', split_part(u.email, '@', 1)),
  'gratis',
  false,
  replace(gen_random_uuid()::text, '-', ''),
  COALESCE(u.created_at, now())
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM public.perfiles p WHERE p.id = u.id)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────────────────────────────────────────
-- 4. RLS (Row Level Security) para perfiles
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.perfiles ENABLE ROW LEVEL SECURITY;

-- El usuario puede leer su propio perfil
DROP POLICY IF EXISTS "perfiles_select_own" ON public.perfiles;
CREATE POLICY "perfiles_select_own"
  ON public.perfiles FOR SELECT
  USING (auth.uid() = id);

-- El usuario puede actualizar su propio perfil
DROP POLICY IF EXISTS "perfiles_update_own" ON public.perfiles;
CREATE POLICY "perfiles_update_own"
  ON public.perfiles FOR UPDATE
  USING (auth.uid() = id);

-- El trigger (SECURITY DEFINER) puede insertar
DROP POLICY IF EXISTS "perfiles_insert_trigger" ON public.perfiles;
CREATE POLICY "perfiles_insert_trigger"
  ON public.perfiles FOR INSERT
  WITH CHECK (true);

-- Los admins pueden leer todos los perfiles
DROP POLICY IF EXISTS "perfiles_admin_select" ON public.perfiles;
CREATE POLICY "perfiles_admin_select"
  ON public.perfiles FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

-- Los admins pueden actualizar cualquier perfil
DROP POLICY IF EXISTS "perfiles_admin_update" ON public.perfiles;
CREATE POLICY "perfiles_admin_update"
  ON public.perfiles FOR UPDATE
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

-- ──────────────────────────────────────────────────────────────────
-- 5. RLS para admins
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_select_own" ON public.admins;
CREATE POLICY "admins_select_own"
  ON public.admins FOR SELECT
  USING (true);

-- ──────────────────────────────────────────────────────────────────
-- 6. TABLA licencias_ea
-- ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.licencias_ea (
  id               SERIAL PRIMARY KEY,
  usuario_id       UUID REFERENCES public.perfiles(id) ON DELETE CASCADE NOT NULL,
  ea_tipo          TEXT NOT NULL CHECK (ea_tipo IN ('risk_manager','auto_journaling','backtest_simulator','data_bridge')),
  mt5_account      TEXT NOT NULL,
  activo           BOOLEAN NOT NULL DEFAULT true,
  fecha_activacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  ultimo_heartbeat TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(usuario_id, ea_tipo)
);

ALTER TABLE public.licencias_ea ADD COLUMN IF NOT EXISTS activo           BOOLEAN     NOT NULL DEFAULT true;
ALTER TABLE public.licencias_ea ADD COLUMN IF NOT EXISTS fecha_activacion TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE public.licencias_ea ADD COLUMN IF NOT EXISTS ultimo_heartbeat TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_licencias_usuario ON public.licencias_ea(usuario_id);
CREATE INDEX IF NOT EXISTS idx_licencias_activo  ON public.licencias_ea(activo);

ALTER TABLE public.licencias_ea ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "licencias_select_own"      ON public.licencias_ea;
CREATE POLICY "licencias_select_own"
  ON public.licencias_ea FOR SELECT
  USING (usuario_id = auth.uid());

DROP POLICY IF EXISTS "licencias_service_role_all" ON public.licencias_ea;
CREATE POLICY "licencias_service_role_all"
  ON public.licencias_ea FOR ALL
  USING (auth.role() = 'service_role');

DROP POLICY IF EXISTS "licencias_admin_select"    ON public.licencias_ea;
CREATE POLICY "licencias_admin_select"
  ON public.licencias_ea FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "licencias_admin_update"    ON public.licencias_ea;
CREATE POLICY "licencias_admin_update"
  ON public.licencias_ea FOR UPDATE
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

-- ──────────────────────────────────────────────────────────────────
-- 7. TABLA logs_licencias
-- ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.logs_licencias (
  id          SERIAL PRIMARY KEY,
  usuario_id  UUID REFERENCES public.perfiles(id) ON DELETE SET NULL,
  token_usado TEXT,
  ea_tipo     TEXT,
  mt5_account TEXT,
  exito       BOOLEAN NOT NULL DEFAULT false,
  motivo      TEXT,
  ip          TEXT,
  fecha       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_logs_fecha   ON public.logs_licencias(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_logs_token   ON public.logs_licencias(token_usado);
CREATE INDEX IF NOT EXISTS idx_logs_usuario ON public.logs_licencias(usuario_id);

ALTER TABLE public.logs_licencias ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "logs_service_role_all" ON public.logs_licencias;
CREATE POLICY "logs_service_role_all"
  ON public.logs_licencias FOR ALL
  USING (auth.role() = 'service_role');

DROP POLICY IF EXISTS "logs_admin_select" ON public.logs_licencias;
CREATE POLICY "logs_admin_select"
  ON public.logs_licencias FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

-- ──────────────────────────────────────────────────────────────────
-- 8. TABLAS CHAT
-- ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.conversaciones (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id      UUID NOT NULL REFERENCES public.perfiles(id) ON DELETE CASCADE,
  ultimo_mensaje_en TIMESTAMPTZ,
  creado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.conversaciones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "conv_user_own" ON public.conversaciones;
CREATE POLICY "conv_user_own"
  ON public.conversaciones FOR ALL
  USING (usuario_id = auth.uid());

DROP POLICY IF EXISTS "conv_admin_all" ON public.conversaciones;
CREATE POLICY "conv_admin_all"
  ON public.conversaciones FOR ALL
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

CREATE TABLE IF NOT EXISTS public.mensajes (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversacion_id  UUID NOT NULL REFERENCES public.conversaciones(id) ON DELETE CASCADE,
  remitente_id     UUID NOT NULL REFERENCES auth.users(id),
  remitente_tipo   TEXT NOT NULL CHECK (remitente_tipo IN ('user','admin')),
  mensaje          TEXT,
  imagen_url       TEXT,
  leido            BOOLEAN NOT NULL DEFAULT false,
  enviado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mensajes_conv ON public.mensajes(conversacion_id, enviado_en DESC);

ALTER TABLE public.mensajes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "mensajes_user_own_conv" ON public.mensajes;
CREATE POLICY "mensajes_user_own_conv"
  ON public.mensajes FOR ALL
  USING (
    conversacion_id IN (
      SELECT id FROM public.conversaciones WHERE usuario_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "mensajes_admin_all" ON public.mensajes;
CREATE POLICY "mensajes_admin_all"
  ON public.mensajes FOR ALL
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

-- ──────────────────────────────────────────────────────────────────
-- 9. TABLA pagos (para el panel admin)
-- ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pagos (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id    UUID REFERENCES public.perfiles(id) ON DELETE SET NULL,
  plan          TEXT NOT NULL,
  monto         NUMERIC(10,2),
  metodo        TEXT,
  estado        TEXT NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','aprobado','rechazado')),
  comprobante   TEXT,
  notas         TEXT,
  creado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.pagos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pagos_user_insert" ON public.pagos;
CREATE POLICY "pagos_user_insert"
  ON public.pagos FOR INSERT
  WITH CHECK (usuario_id = auth.uid());

DROP POLICY IF EXISTS "pagos_user_select" ON public.pagos;
CREATE POLICY "pagos_user_select"
  ON public.pagos FOR SELECT
  USING (usuario_id = auth.uid());

DROP POLICY IF EXISTS "pagos_admin_all" ON public.pagos;
CREATE POLICY "pagos_admin_all"
  ON public.pagos FOR ALL
  USING (EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()));

-- ──────────────────────────────────────────────────────────────────
-- 10. FUNCIÓN: verificar_licencia (helper interno)
-- ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.verificar_licencia(
  p_token      TEXT,
  p_ea_tipo    TEXT,
  p_mt5_account TEXT
) RETURNS JSONB AS $$
DECLARE
  v_perfil  public.perfiles%ROWTYPE;
BEGIN
  SELECT * INTO v_perfil FROM public.perfiles WHERE token_licencia = p_token LIMIT 1;
  IF NOT FOUND THEN
    RETURN '{"valido":false,"motivo":"Token no encontrado"}'::jsonb;
  END IF;
  IF v_perfil.bloqueado THEN
    RETURN '{"valido":false,"motivo":"Cuenta bloqueada"}'::jsonb;
  END IF;
  IF p_ea_tipo IN ('risk_manager','auto_journaling') AND v_perfil.plan NOT IN ('premium','elite') THEN
    RETURN jsonb_build_object('valido',false,'motivo','Plan insuficiente');
  END IF;
  IF p_ea_tipo = 'backtest_simulator' AND v_perfil.plan <> 'elite' THEN
    RETURN jsonb_build_object('valido',false,'motivo','Solo disponible para Elite');
  END IF;
  RETURN jsonb_build_object('valido',true,'plan',v_perfil.plan,'usuario',v_perfil.nombre);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ──────────────────────────────────────────────────────────────────
-- 11. VISTA admin para licencias
-- ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.vista_licencias_admin AS
SELECT
  l.id,
  p.nombre,
  (SELECT email FROM auth.users WHERE id = p.id) AS email,
  p.plan,
  l.ea_tipo,
  l.mt5_account,
  l.activo,
  l.fecha_activacion,
  l.ultimo_heartbeat,
  EXTRACT(EPOCH FROM (now() - l.ultimo_heartbeat))/3600 AS horas_sin_hb
FROM public.licencias_ea l
JOIN public.perfiles p ON p.id = l.usuario_id
ORDER BY l.ultimo_heartbeat DESC;

GRANT SELECT ON public.vista_licencias_admin TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- STORAGE bucket para imágenes del chat (ejecutar si no existe)
-- ──────────────────────────────────────────────────────────────────
-- Ir a Supabase → Storage → New Bucket → nombre: "chat-images" → Public: ON
-- O ejecutar:
-- INSERT INTO storage.buckets (id, name, public) VALUES ('chat-images','chat-images',true) ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════════
-- FIN DEL SCRIPT COMPLETO
-- ══════════════════════════════════════════════════════════════════
