create extension if not exists pgcrypto;

create table public.keyboard_installations (
    id uuid primary key default gen_random_uuid(),
    auth_user_id uuid not null unique references auth.users(id) on delete cascade,
    app_installation_id uuid not null unique,
    consent_version integer not null check (consent_version > 0),
    created_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now()
);

create table public.keyboard_events (
    event_id uuid primary key,
    installation_id uuid not null references public.keyboard_installations(id) on delete cascade,
    auth_user_id uuid not null references auth.users(id) on delete cascade,
    session_id uuid,
    event_timestamp timestamptz not null,
    schema_version integer not null check (schema_version > 0),
    event_kind text not null check (length(event_kind) between 1 and 80),
    payload jsonb not null check (jsonb_typeof(payload) = 'object'),
    received_at timestamptz not null default now()
);

create index keyboard_events_installation_timestamp_idx
    on public.keyboard_events (installation_id, event_timestamp);
create index keyboard_events_session_idx
    on public.keyboard_events (session_id)
    where session_id is not null;
create index keyboard_events_schema_version_idx
    on public.keyboard_events (schema_version);

create table public.keyboard_upload_receipts (
    batch_id uuid primary key,
    installation_id uuid not null references public.keyboard_installations(id) on delete cascade,
    auth_user_id uuid not null references auth.users(id) on delete cascade,
    submitted_count integer not null check (submitted_count >= 0),
    acknowledged_count integer not null check (acknowledged_count >= 0),
    received_at timestamptz not null default now()
);

alter table public.keyboard_installations enable row level security;
alter table public.keyboard_events enable row level security;
alter table public.keyboard_upload_receipts enable row level security;

-- There are intentionally no client policies. The Edge Function validates the
-- anonymous JWT and writes with its server-only service-role client. Researchers
-- use the Supabase dashboard or a separately provisioned server-side role.
revoke all on public.keyboard_installations from anon, authenticated;
revoke all on public.keyboard_events from anon, authenticated;
revoke all on public.keyboard_upload_receipts from anon, authenticated;
