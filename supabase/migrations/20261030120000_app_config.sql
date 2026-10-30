-- Global app configuration (jsonb key/value), reusing the clubs.points_config idiom.
create table if not exists public.app_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;

-- Any authenticated client may READ config; writes are service-role only.
drop policy if exists "app_config readable by authenticated" on public.app_config;
create policy "app_config readable by authenticated"
  on public.app_config for select to authenticated using (true);

-- Background auto-sync global kill switch — ships OFF.
insert into public.app_config (key, value)
values ('auto_sync', '{"enabled": false}'::jsonb)
on conflict (key) do nothing;
