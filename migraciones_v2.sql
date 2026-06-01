-- ================================================================
  -- MIGRACIÓN v2 — FlowTrade Suite
  -- Ejecutar en: Supabase Dashboard → SQL Editor
  -- Solo necesitas correr este archivo UNA VEZ
  -- ================================================================

  -- ────────────────────────────────────────────────────────────────
  -- TABLA: diario_trades
  -- Almacena el journal de trades de cada usuario en la nube.
  -- Antes estos datos vivían en el navegador (IndexedDB) y se
  -- perdían al cambiar de dispositivo o limpiar el cache.
  -- ────────────────────────────────────────────────────────────────
  create table if not exists public.diario_trades (
    id         text primary key,
    usuario_id uuid not null references auth.users(id) on delete cascade,
    fecha      timestamptz,
    data       jsonb not null,
    creado_en  timestamptz not null default now()
  );

  create index if not exists idx_diario_trades_usuario_fecha
    on public.diario_trades(usuario_id, fecha desc);

  alter table public.diario_trades enable row level security;

  create policy "diario_own_all" on public.diario_trades
    for all using (usuario_id = auth.uid())
    with check (usuario_id = auth.uid());

  create policy "diario_admin_select" on public.diario_trades
    for select using (
      exists (select 1 from public.admins where user_id = auth.uid())
    );

  -- ────────────────────────────────────────────────────────────────
  -- TABLA: push_subscriptions
  -- Almacena las suscripciones de notificaciones push por usuario.
  -- ────────────────────────────────────────────────────────────────
  create table if not exists public.push_subscriptions (
    id         bigserial primary key,
    user_id    uuid not null references auth.users(id) on delete cascade,
    endpoint   text not null,
    p256dh     text,
    auth       text,
    updated_at timestamptz,
    creado_en  timestamptz not null default now(),
    unique(user_id)
  );

  alter table public.push_subscriptions enable row level security;

  create policy "push_own_all" on public.push_subscriptions
    for all using (user_id = auth.uid())
    with check (user_id = auth.uid());

  -- ================================================================
  -- FIN DE LA MIGRACIÓN v2
  -- ================================================================
  