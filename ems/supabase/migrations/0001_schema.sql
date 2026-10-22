-- EMS Phase 1 schema. All timestamps are timestamptz (stored as UTC).
create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create type app_role as enum ('owner','manager','employee');
create type employment_status as enum ('active','on_leave','deactivated');
create type invitation_status as enum ('pending','accepted','revoked','expired');
create type attendance_source as enum ('discord','web','admin_correction');
create type attendance_event_type as enum ('check_in','check_out','break_start','break_end','correction','auto_flag');

create table companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table company_settings (
  company_id uuid primary key references companies(id) on delete cascade,
  timezone text not null default 'UTC',
  grace_minutes int not null default 5 check (grace_minutes >= 0),
  auto_break_minutes int not null default 30 check (auto_break_minutes >= 0),
  auto_break_after_minutes int not null default 360 check (auto_break_after_minutes >= 0),
  overtime_after_minutes int not null default 480 check (overtime_after_minutes > 0),
  missing_checkout_after_hours int not null default 14 check (missing_checkout_after_hours > 0),
  invitation_ttl_hours int not null default 72 check (invitation_ttl_hours > 0)
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  email text not null,
  full_name text not null,
  avatar_url text,
  job_title text,
  role app_role not null default 'employee',
  status employment_status not null default 'active',
  timezone text,
  start_date date,
  created_at timestamptz not null default now()
);
create unique index profiles_company_email_uq on profiles (company_id, lower(email));
create unique index profiles_one_owner_uq on profiles (company_id) where role = 'owner';
create index profiles_company_idx on profiles (company_id);

create table teams (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  name text not null,
  unique (company_id, name)
);

create table team_members (
  team_id uuid not null references teams(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  is_lead boolean not null default false,
  primary key (team_id, profile_id)
);
create index team_members_profile_idx on team_members (profile_id);

create table invitations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  email text not null,
  full_name text not null,
  role app_role not null default 'employee' check (role <> 'owner'),
  team_id uuid references teams(id) on delete set null,
  job_title text,
  token_hash text not null unique,          -- sha256 hex of the token; raw token is never stored
  status invitation_status not null default 'pending',
  expires_at timestamptz not null,
  invited_by uuid not null references profiles(id),
  accepted_by uuid references profiles(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index invitations_pending_email_uq on invitations (company_id, lower(email)) where status = 'pending';

create table discord_accounts (
  profile_id uuid primary key references profiles(id) on delete cascade,
  discord_user_id text not null unique,
  linked_at timestamptz not null default now()
);

create table discord_link_codes (
  code_hash text primary key,
  profile_id uuid not null references profiles(id) on delete cascade,
  expires_at timestamptz not null,
  used_at timestamptz
);

create table shifts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  break_minutes int not null default 0 check (break_minutes >= 0),
  timezone text not null default 'UTC',
  role_label text,
  notes text,
  check (ends_at > starts_at),
  -- DB-level overlap protection per employee
  constraint shifts_no_overlap exclude using gist (profile_id with =, tstzrange(starts_at, ends_at) with &&)
);
create index shifts_company_start_idx on shifts (company_id, starts_at);

create table attendance_sessions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  shift_id uuid references shifts(id) on delete set null,
  check_in_at timestamptz not null default now(),
  check_out_at timestamptz,
  check_in_source attendance_source not null,
  check_out_source attendance_source,
  created_at timestamptz not null default now(),
  check (check_out_at is null or check_out_at > check_in_at)
);
-- The core duplicate-prevention guarantee: at most one open session per employee.
create unique index attendance_one_open_uq on attendance_sessions (profile_id) where check_out_at is null;
create index attendance_company_in_idx on attendance_sessions (company_id, check_in_at);
create index attendance_profile_in_idx on attendance_sessions (profile_id, check_in_at);

create table break_sessions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references attendance_sessions(id) on delete cascade,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  check (ended_at is null or ended_at > started_at)
);
create unique index break_one_open_uq on break_sessions (session_id) where ended_at is null;

create table attendance_events (
  id bigserial primary key,
  company_id uuid not null references companies(id) on delete cascade,
  session_id uuid references attendance_sessions(id) on delete set null,
  profile_id uuid not null references profiles(id) on delete cascade,
  type attendance_event_type not null,
  source attendance_source,
  occurred_at timestamptz not null default now(),
  meta jsonb not null default '{}'::jsonb
);
create index attendance_events_profile_idx on attendance_events (profile_id, occurred_at);

create table attendance_corrections (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references attendance_sessions(id) on delete cascade,
  corrected_by uuid not null references profiles(id),
  reason text not null check (length(btrim(reason)) >= 3),
  before jsonb not null,
  after jsonb not null,
  created_at timestamptz not null default now()
);

create table audit_logs (
  id bigserial primary key,
  company_id uuid not null references companies(id) on delete cascade,
  actor_id uuid,
  action text not null,
  entity_type text,
  entity_id text,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_company_idx on audit_logs (company_id, created_at desc);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  recipient_id uuid not null references profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  link text,
  dedupe_key text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  unique (recipient_id, dedupe_key)         -- prevents duplicate notifications for the same event
);
create index notifications_recipient_idx on notifications (recipient_id, read_at, created_at desc);

-- Append-only protection for audit/event history
create function forbid_mutation() returns trigger language plpgsql as $$
begin raise exception '% is append-only', tg_table_name; end $$;
create trigger audit_logs_append_only before update or delete on audit_logs for each row execute function forbid_mutation();
create trigger attendance_events_append_only before update or delete on attendance_events for each row execute function forbid_mutation();
create trigger attendance_corrections_append_only before update or delete on attendance_corrections for each row execute function forbid_mutation();
