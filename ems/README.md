# Employee Management System: Phase 1 (backend core)

Status: **Phase 1 of 9.** Database, security model, attendance/invitation logic, and tests. The Next.js UI, Discord bot, scheduling UI, tasks, leave, and reports are **not built yet**.

## What's in this phase
| Area | Where | Notes |
|---|---|---|
| Schema | `supabase/migrations/0001_schema.sql` | companies, settings, profiles, teams, invitations, discord_accounts, shifts, attendance, breaks, events, corrections, audit_logs, notifications |
| RLS + grants | `0002_rls.sql` | Clients are read-only via RLS; only `full_name/avatar_url/timezone` (profile) and `read_at` (notification) are client-writable |
| Business functions | `0003_functions.sql` | `check_in`, `check_out`, breaks, `admin_correct_attendance`, `accept_invitation`, `bootstrap_owner`, `flag_missing_checkouts`. **service_role only** |
| Attendance math | `src/lib/attendance/calc.ts` | lateness, grace, auto/recorded breaks, overtime, early leave, missing check-out, DST-safe timezone conversion |
| Invitation tokens | `src/lib/invitations/token.ts` | 256-bit token, SHA-256 stored, expiry, URL-fragment link |
| Email | `src/lib/email/resend.ts` | Resend adapter; safe no-op when keys are missing |

## Key guarantees (and how they're enforced)
- **No duplicate active sessions:** partial unique index + per-employee advisory lock.
- **Server-only timestamps:** functions use `clock_timestamp()`; callers cannot pass a time.
- **No privilege escalation:** column-level grants, no client INSERT/UPDATE on roles; invitations cannot carry `owner`; one owner per company; `bootstrap_owner` works only once.
- **Invitations:** raw token never stored; atomic single-use acceptance; email must match the verified auth email.
- **Append-only** audit log, attendance events, and corrections.
- **Shift overlaps** blocked by a DB exclusion constraint.

## Run the tests
```bash
npm install && npm test && npm run typecheck     # unit tests (23)
# DB tests need local Postgres 16 + superuser psql:
supabase/tests/run.sh
```
> `npm install` fails on filesystems that don't support symlinks (some mounted drives). Install on a normal disk.

## Test results (run in the build sandbox)
- **Automated, passing:** 23 TypeScript unit tests; 44 SQL assertions (invitations, attendance, RLS, privilege escalation, overlaps, corrections, notification dedupe); a 30-way concurrent check-in test (1 success, 29 `already_checked_in`, 1 open session).
- **Bugs the tests caught and fixed:** an enum cast error in `admin_correct_attendance`.
- **Not tested (needs your credentials):** real Supabase Auth flow, Resend delivery, Discord, deployment. SQL was verified on vanilla Postgres 16 with a stub `auth` schema, not on Supabase itself.

## Setup (once the app layer exists)
1. Create a Supabase project; run the three migrations in order (`supabase db push`).
2. Copy `.env.example` → `.env.local` and fill in values. **Service-role key and bot token must stay server-side.**
3. Sign up your own user in Supabase Auth, then run:
   `select bootstrap_owner('<your-auth-user-id>', 'Company', 'Your Name', 'you@example.com');`
4. Schedule `select flag_missing_checkouts();` every 15 min (pg_cron).

## Metric definitions
- **Gross** = check-out − check-in (floored minutes). **Break** = recorded breaks, else auto-deduction if gross ≥ threshold. **Net** = gross − break. **Overtime** = net above the daily threshold. **Late** = minutes after shift start, only if beyond grace.

## Roadmap
2. Next.js shell, auth, owner/employee dashboards, invite API routes (token → email → accept page)
3. Employee management UI · 4. Scheduling · 5. Discord bot (signature-verified, account linking) · 6. Tasks, leave, notifications · 7. Reports/CSV · 8. Hardening · 9. Deployment docs
