-- ================================================================
-- SAMTRADER PRO SUITE — Setup completo de Supabase v3.1
-- Ejecutar TODO en el SQL Editor de Supabase (dashboard.supabase.com)
-- Orden de ejecución: de arriba hacia abajo, una sola vez
-- ================================================================

-- ────────────────────────────────────────────────────────────────
-- 1. TABLA: perfiles
-- ────────────────────────────────────────────────────────────────
create table if not exists public.perfiles (
  id                     uuid primary key references auth.users(id) on delete cascade,
  nombre                 text,
  plan                   text not null default 'gratis' check (plan in ('gratis','premium','elite')),
  bloqueado              boolean not null default false,
  token_licencia         text unique,
  mt5_cuenta             text,
  mt5_servidor           text,
  activos_manuales       text,
  fecha_registro         timestamptz not null default now(),
  fecha_expiracion_plan  timestamptz,
  logros                 text[] default '{}',
  referido_por           uuid references public.perfiles(id),
  -- Campos para el ranking
  compartir_estadisticas boolean not null default false,
  win_rate               numeric(5,2) default 0,
  beneficio_neto         numeric(12,2) default 0,
  total_trades           integer default 0,
  sharpe_ratio           numeric(8,4) default 0,
  -- Preferencias
  notificaciones_push    boolean not null default false,
  widgets_ocultos        text[] default '{}'
);
comment on table public.perfiles is 'Perfiles de usuarios de Samtrader Pro Suite';

-- ────────────────────────────────────────────────────────────────
-- 2. TABLA: admins
-- ────────────────────────────────────────────────────────────────
create table if not exists public.admins (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  creado_en timestamptz not null default now()
);
comment on table public.admins is 'Tabla de administradores de la plataforma';

-- ────────────────────────────────────────────────────────────────
-- 3. TABLA: licencias_ea
-- ────────────────────────────────────────────────────────────────
create table if not exists public.licencias_ea (
  id                bigserial primary key,
  usuario_id        uuid references auth.users(id) on delete cascade,
  ea_tipo           text not null,
  mt5_account       text not null,
  activo            boolean not null default true,
  fecha_activacion  timestamptz not null default now(),
  ultimo_heartbeat  timestamptz,
  intentos_fallidos integer not null default 0,
  bloqueado_hasta   timestamptz
);
comment on table public.licencias_ea is 'Licencias activas de Expert Advisors por usuario';

create index if not exists idx_licencias_ea_usuario_tipo on public.licencias_ea(usuario_id, ea_tipo);

-- ────────────────────────────────────────────────────────────────
-- 4. TABLA: logs_licencias
-- ────────────────────────────────────────────────────────────────
create table if not exists public.logs_licencias (
  id          bigserial primary key,
  usuario_id  uuid,
  token_usado text,
  ea_tipo     text,
  mt5_account text,
  exito       boolean,
  motivo      text,
  ip          text,
  version_ea  text,
  fecha       timestamptz not null default now()
);
comment on table public.logs_licencias is 'Logs de intentos de validación de licencias EA';

create index if not exists idx_logs_licencias_fecha on public.logs_licencias(fecha desc);

-- ────────────────────────────────────────────────────────────────
-- 5. TABLA: pagos
-- ────────────────────────────────────────────────────────────────
create table if not exists public.pagos (
  id            bigserial primary key,
  usuario_id    uuid references auth.users(id) on delete cascade,
  plan          text,
  metodo        text,
  monto         numeric(10,2),
  estado        text not null default 'pendiente' check (estado in ('pendiente','aprobado','rechazado')),
  notas         text,
  creado_en     timestamptz not null default now(),
  verificado_en timestamptz
);
comment on table public.pagos is 'Solicitudes de pago manual para actualización de planes';

create index if not exists idx_pagos_estado on public.pagos(estado);

-- ────────────────────────────────────────────────────────────────
-- 6. TABLA: conversaciones (chat)
-- ────────────────────────────────────────────────────────────────
create table if not exists public.conversaciones (
  id                bigserial primary key,
  usuario_id        uuid unique references auth.users(id) on delete cascade,
  ultimo_mensaje_en timestamptz,
  estado            text not null default 'abierta' check (estado in ('abierta','cerrada'))
);

-- ────────────────────────────────────────────────────────────────
-- 7. TABLA: mensajes
-- ────────────────────────────────────────────────────────────────
create table if not exists public.mensajes (
  id               bigserial primary key,
  conversacion_id  bigint references public.conversaciones(id) on delete cascade,
  remitente_id     uuid,
  remitente_tipo   text not null check (remitente_tipo in ('user','admin')),
  mensaje          text,
  imagen_url       text,
  leido            boolean not null default false,
  enviado_en       timestamptz not null default now()
);

create index if not exists idx_mensajes_conv_fecha    on public.mensajes(conversacion_id, enviado_en);
create index if not exists idx_mensajes_no_leidos     on public.mensajes(conversacion_id, leido, remitente_tipo);

-- ────────────────────────────────────────────────────────────────
-- 8. TABLA: referidos
-- ────────────────────────────────────────────────────────────────
create table if not exists public.referidos (
  id                  bigserial primary key,
  referente_id        uuid references auth.users(id) on delete cascade,
  referido_id         uuid references auth.users(id) on delete cascade,
  fecha               timestamptz not null default now(),
  plan_adquirido      text,
  monto_pago          numeric(10,2),
  comision_calculada  numeric(10,2),
  pagada              boolean not null default false,
  pagada_en           timestamptz,
  unique(referente_id, referido_id)
);

create index if not exists idx_referidos_referente on public.referidos(referente_id);

-- ────────────────────────────────────────────────────────────────
-- 9. TABLA: descargas_ea
-- ────────────────────────────────────────────────────────────────
create table if not exists public.descargas_ea (
  id         bigserial primary key,
  usuario_id uuid references auth.users(id) on delete cascade,
  ea_tipo    text not null,
  fecha      timestamptz not null default now()
);

create index if not exists idx_descargas_ea_tipo on public.descargas_ea(ea_tipo);

-- ────────────────────────────────────────────────────────────────
-- 10. TABLA: admin_logs
-- ────────────────────────────────────────────────────────────────
create table if not exists public.admin_logs (
  id       bigserial primary key,
  admin_id uuid references auth.users(id),
  accion   text not null,
  detalles jsonb,
  fecha    timestamptz not null default now()
);

create index if not exists idx_admin_logs_fecha on public.admin_logs(fecha desc);

-- ────────────────────────────────────────────────────────────────
-- 11. TABLA: configuracion_plataforma
-- ────────────────────────────────────────────────────────────────
create table if not exists public.configuracion_plataforma (
  clave          text primary key,
  valor          text,
  actualizado_en timestamptz not null default now()
);

insert into public.configuracion_plataforma (clave, valor) values
  ('modo_mantenimiento', 'false'),
  ('max_intentos_login', '3'),
  ('comision_gratis',    '0.05'),
  ('comision_premium',   '0.10'),
  ('comision_elite',     '0.15')
on conflict (clave) do nothing;

-- ────────────────────────────────────────────────────────────────
-- 12. TABLA: trades_recibidos  ← EA DataBridge
-- ────────────────────────────────────────────────────────────────
create table if not exists public.trades_recibidos (
  id              bigserial primary key,
  usuario_id      uuid references auth.users(id) on delete cascade,
  mt5_cuenta      text,
  mt5_servidor    text,
  ticket          text not null,
  position_id     text,
  fecha           text,
  fecha_apertura  text,
  activo          text,
  tipo            text,
  lotes           numeric(10,4),
  precio_entrada  numeric(12,5),
  precio_salida   numeric(12,5),
  resultado_usd   numeric(12,2),
  pips            numeric(10,2),
  recibido_en     timestamptz not null default now(),
  -- Evita duplicados si el EA reenvía el mismo trade
  unique(usuario_id, ticket)
);
comment on table public.trades_recibidos is 'Trades recibidos desde el EA DataBridge (envío automático desde MT5)';

create index if not exists idx_trades_recibidos_usuario   on public.trades_recibidos(usuario_id);
create index if not exists idx_trades_recibidos_fecha     on public.trades_recibidos(recibido_en desc);
create index if not exists idx_trades_recibidos_activo    on public.trades_recibidos(activo);

-- ────────────────────────────────────────────────────────────────
-- 13. TRIGGER: crear perfil automáticamente al registrarse
-- ────────────────────────────────────────────────────────────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfiles (
    id,
    nombre,
    plan,
    bloqueado,
    token_licencia,
    fecha_registro
  ) values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'nombre',
      split_part(new.email, '@', 1)
    ),
    'gratis',
    false,
    replace(gen_random_uuid()::text, '-', ''),
    now()
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();

-- ────────────────────────────────────────────────────────────────
-- 14. ROW LEVEL SECURITY (RLS)
-- ────────────────────────────────────────────────────────────────
alter table public.perfiles                enable row level security;
alter table public.admins                  enable row level security;
alter table public.licencias_ea            enable row level security;
alter table public.logs_licencias          enable row level security;
alter table public.pagos                   enable row level security;
alter table public.conversaciones          enable row level security;
alter table public.mensajes                enable row level security;
alter table public.referidos               enable row level security;
alter table public.descargas_ea            enable row level security;
alter table public.admin_logs              enable row level security;
alter table public.configuracion_plataforma enable row level security;
alter table public.trades_recibidos        enable row level security;

-- ── Perfiles ──
create policy "perfiles_select_own" on public.perfiles
  for select using (auth.uid() = id);

create policy "perfiles_select_ranking" on public.perfiles
  for select using (compartir_estadisticas = true);

create policy "perfiles_select_admin" on public.perfiles
  for select using (exists (select 1 from public.admins where user_id = auth.uid()));

create policy "perfiles_update_own" on public.perfiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

create policy "perfiles_update_admin" on public.perfiles
  for update using (exists (select 1 from public.admins where user_id = auth.uid()));

create policy "perfiles_insert_own" on public.perfiles
  for insert with check (auth.uid() = id);

-- ── Admins ──
create policy "admins_select_all" on public.admins
  for select using (auth.uid() is not null);

-- ── Licencias EA ──
create policy "licencias_select_own" on public.licencias_ea
  for select using (
    usuario_id = auth.uid() or
    exists (select 1 from public.admins where user_id = auth.uid())
  );

-- ── Logs licencias ──
create policy "logs_select_admin" on public.logs_licencias
  for select using (exists (select 1 from public.admins where user_id = auth.uid()));

-- ── Pagos ──
create policy "pagos_select_own" on public.pagos
  for select using (
    usuario_id = auth.uid() or
    exists (select 1 from public.admins where user_id = auth.uid())
  );

create policy "pagos_insert_own" on public.pagos
  for insert with check (usuario_id = auth.uid());

create policy "pagos_update_admin" on public.pagos
  for update using (exists (select 1 from public.admins where user_id = auth.uid()));

-- ── Conversaciones ──
create policy "conv_select_own" on public.conversaciones
  for select using (
    usuario_id = auth.uid() or
    exists (select 1 from public.admins where user_id = auth.uid())
  );

create policy "conv_insert_own" on public.conversaciones
  for insert with check (usuario_id = auth.uid());

create policy "conv_update_own" on public.conversaciones
  for update using (
    usuario_id = auth.uid() or
    exists (select 1 from public.admins where user_id = auth.uid())
  );

-- ── Mensajes ──
create policy "mensajes_select_own" on public.mensajes
  for select using (
    remitente_id = auth.uid() or
    exists (
      select 1 from public.conversaciones c
      where c.id = conversacion_id
      and (c.usuario_id = auth.uid() or exists (select 1 from public.admins where user_id = auth.uid()))
    )
  );

create policy "mensajes_insert" on public.mensajes
  for insert with check (remitente_id = auth.uid());

create policy "mensajes_update_leido" on public.mensajes
  for update using (
    exists (
      select 1 from public.conversaciones c
      where c.id = conversacion_id
      and (c.usuario_id = auth.uid() or exists (select 1 from public.admins where user_id = auth.uid()))
    )
  );

-- ── Referidos ──
create policy "referidos_select_own" on public.referidos
  for select using (
    referente_id = auth.uid() or referido_id = auth.uid() or
    exists (select 1 from public.admins where user_id = auth.uid())
  );

create policy "referidos_insert_admin" on public.referidos
  for insert with check (exists (select 1 from public.admins where user_id = auth.uid()));

create policy "referidos_update_admin" on public.referidos
  for update using (exists (select 1 from public.admins where user_id = auth.uid()));

-- ── Descargas EA ──
create policy "descargas_select_own" on public.descargas_ea
  for select using (
    usuario_id = auth.uid() or
    exists (select 1 from public.admins where user_id = auth.uid())
  );

create policy "descargas_insert_own" on public.descargas_ea
  for insert with check (usuario_id = auth.uid());

-- ── Admin logs ──
create policy "admin_logs_select_admin" on public.admin_logs
  for select using (exists (select 1 from public.admins where user_id = auth.uid()));

create policy "admin_logs_insert_admin" on public.admin_logs
  for insert with check (exists (select 1 from public.admins where user_id = auth.uid()));

-- ── Configuración plataforma ──
create policy "config_select_all" on public.configuracion_plataforma
  for select using (auth.uid() is not null);

create policy "config_update_admin" on public.configuracion_plataforma
  for update using (exists (select 1 from public.admins where user_id = auth.uid()));

create policy "config_upsert_admin" on public.configuracion_plataforma
  for insert with check (exists (select 1 from public.admins where user_id = auth.uid()));

-- ── Trades Recibidos ──
create policy "trades_recibidos_select_own" on public.trades_recibidos
  for select using (
    usuario_id = auth.uid() or
    exists (select 1 from public.admins where user_id = auth.uid())
  );

-- La API de DataBridge usa service_role key, no necesita policy de INSERT
-- pero la añadimos para usos futuros vía cliente:
create policy "trades_recibidos_insert_own" on public.trades_recibidos
  for insert with check (usuario_id = auth.uid());

-- ────────────────────────────────────────────────────────────────
-- 15. STORAGE: Bucket para imágenes del chat
-- ────────────────────────────────────────────────────────────────
-- Crear desde Supabase Dashboard → Storage → New Bucket
-- Nombre: chat-images  |  Public: true
-- O con este SQL (puede requerir permisos de superusuario):
-- insert into storage.buckets (id, name, public)
--   values ('chat-images', 'chat-images', true)
--   on conflict do nothing;

-- ────────────────────────────────────────────────────────────────
-- 16. INSERTAR USUARIO ADMINISTRADOR
-- ────────────────────────────────────────────────────────────────
-- 1. Regístrate en la plataforma con tu email de admin.
-- 2. Ve a Supabase Dashboard → Authentication → Users.
-- 3. Copia el UUID del usuario recién creado.
-- 4. Descomenta y ejecuta la línea siguiente con ese UUID:
--
-- insert into public.admins (user_id) values ('PEGA-TU-UUID-AQUI')
-- on conflict (user_id) do nothing;

-- ────────────────────────────────────────────────────────────────
-- 17. VERIFICACIÓN FINAL
-- ────────────────────────────────────────────────────────────────
select
  table_name,
  (
    select count(*)
    from information_schema.columns c
    where c.table_name = t.table_name
      and c.table_schema = 'public'
  ) as columnas
from information_schema.tables t
where table_schema = 'public'
  and table_name in (
    'perfiles','admins','licencias_ea','logs_licencias',
    'pagos','conversaciones','mensajes','referidos',
    'descargas_ea','admin_logs','configuracion_plataforma',
    'trades_recibidos'
  )
order by table_name;
-- Resultado esperado: 12 filas con nombres y número de columnas de cada tabla.
