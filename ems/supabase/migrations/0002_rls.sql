-- Row Level Security. Writes go through service-role server code or SECURITY DEFINER functions.
create function public.auth_company_id() returns uuid language sql stable security definer set search_path = public as
$$ select company_id from profiles where id = auth.uid() and status <> 'deactivated' $$;

create function public.auth_role() returns app_role language sql stable security definer set search_path = public as
$$ select role from profiles where id = auth.uid() and status <> 'deactivated' $$;

-- Managers see people who share a team with them.
create function public.is_manager_of(target uuid) returns boolean language sql stable security definer set search_path = public as $$
  select auth_role() = 'manager' and exists (
    select 1 from team_members m join team_members e on e.team_id = m.team_id
    where m.profile_id = auth.uid() and e.profile_id = target)
$$;

create function public.can_view_profile(target uuid) returns boolean language sql stable security definer set search_path = public as $$
  select target = auth.uid()
      or (auth_role() = 'owner' and exists (select 1 from profiles p where p.id = target and p.company_id = auth_company_id()))
      or is_manager_of(target)
$$;

-- Lock down default grants: authenticated users can only read (via RLS) and edit a few own columns.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on companies, company_settings, profiles, teams, team_members, shifts,
  attendance_sessions, break_sessions, attendance_events, attendance_corrections,
  audit_logs, notifications, discord_accounts to authenticated;
grant update (full_name, avatar_url, timezone) on profiles to authenticated;   -- no role/status/company edits
grant update (read_at) on notifications to authenticated;
-- invitations, discord_link_codes: no client access at all (service role only).

alter table companies enable row level security;
alter table company_settings enable row level security;
alter table profiles enable row level security;
alter table teams enable row level security;
alter table team_members enable row level security;
alter table invitations enable row level security;
alter table discord_accounts enable row level security;
alter table discord_link_codes enable row level security;
alter table shifts enable row level security;
alter table attendance_sessions enable row level security;
alter table break_sessions enable row level security;
alter table attendance_events enable row level security;
alter table attendance_corrections enable row level security;
alter table audit_logs enable row level security;
alter table notifications enable row level security;

create policy companies_sel on companies for select using (id = auth_company_id());
create policy settings_sel on company_settings for select using (company_id = auth_company_id());
create policy profiles_sel on profiles for select using (can_view_profile(id));
create policy profiles_upd_self on profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy teams_sel on teams for select using (company_id = auth_company_id());
create policy team_members_sel on team_members for select using (can_view_profile(profile_id));
create policy shifts_sel on shifts for select using (can_view_profile(profile_id));
create policy sessions_sel on attendance_sessions for select using (can_view_profile(profile_id));
create policy breaks_sel on break_sessions for select using (exists (select 1 from attendance_sessions s where s.id = session_id and can_view_profile(s.profile_id)));
create policy events_sel on attendance_events for select using (can_view_profile(profile_id));
create policy corrections_sel on attendance_corrections for select using (auth_role() = 'owner' and exists (select 1 from attendance_sessions s where s.id = session_id and s.company_id = auth_company_id()));
create policy audit_sel on audit_logs for select using (auth_role() = 'owner' and company_id = auth_company_id());
create policy notif_sel on notifications for select using (recipient_id = auth.uid());
create policy notif_upd on notifications for update using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
create policy discord_sel on discord_accounts for select using (can_view_profile(profile_id));
