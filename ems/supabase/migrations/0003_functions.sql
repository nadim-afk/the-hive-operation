-- Business-rule functions. Callable ONLY by the service role (your server / Discord bot backend),
-- which must first authenticate the caller and map them to a profile id.

create function bootstrap_owner(p_user_id uuid, p_company_name text, p_full_name text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_company uuid;
begin
  if exists (select 1 from profiles where role = 'owner') then
    raise exception 'owner already exists';
  end if;
  insert into companies(name) values (p_company_name) returning id into v_company;
  insert into company_settings(company_id) values (v_company);
  insert into profiles(id, company_id, email, full_name, role) values (p_user_id, v_company, p_email, p_full_name, 'owner');
  insert into audit_logs(company_id, actor_id, action, entity_type, entity_id) values (v_company, p_user_id, 'owner.bootstrap', 'company', v_company::text);
  return jsonb_build_object('company_id', v_company);
end $$;

create function check_in(p_profile uuid, p_source attendance_source) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prof profiles; v_now timestamptz := clock_timestamp(); v_shift shifts; v_sess attendance_sessions;
begin
  perform pg_advisory_xact_lock(hashtext(p_profile::text));   -- serialize concurrent requests per employee
  select * into v_prof from profiles where id = p_profile;
  if not found or v_prof.status <> 'active' then return jsonb_build_object('result','not_allowed'); end if;

  select * into v_sess from attendance_sessions where profile_id = p_profile and check_out_at is null;
  if found then
    return jsonb_build_object('result','already_checked_in','session_id',v_sess.id,'check_in_at',v_sess.check_in_at);
  end if;

  select * into v_shift from shifts
   where profile_id = p_profile and v_now between starts_at - interval '2 hours' and ends_at
   order by abs(extract(epoch from (starts_at - v_now))) limit 1;

  insert into attendance_sessions(company_id, profile_id, shift_id, check_in_at, check_in_source)
  values (v_prof.company_id, p_profile, v_shift.id, v_now, p_source) returning * into v_sess;
  insert into attendance_events(company_id, session_id, profile_id, type, source, occurred_at)
  values (v_prof.company_id, v_sess.id, p_profile, 'check_in', p_source, v_now);

  return jsonb_build_object('result','ok','session_id',v_sess.id,'check_in_at',v_now,
    'shift_id',v_shift.id,'shift_starts_at',v_shift.starts_at,'shift_ends_at',v_shift.ends_at);
end $$;

create function check_out(p_profile uuid, p_source attendance_source) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_now timestamptz := clock_timestamp(); v_sess attendance_sessions; v_break int;
begin
  perform pg_advisory_xact_lock(hashtext(p_profile::text));
  select * into v_sess from attendance_sessions where profile_id = p_profile and check_out_at is null for update;
  if not found then return jsonb_build_object('result','no_active_session'); end if;

  update break_sessions set ended_at = v_now where session_id = v_sess.id and ended_at is null;
  select coalesce(sum(floor(extract(epoch from (ended_at - started_at)) / 60)), 0)::int into v_break
    from break_sessions where session_id = v_sess.id;
  update attendance_sessions set check_out_at = v_now, check_out_source = p_source where id = v_sess.id;
  insert into attendance_events(company_id, session_id, profile_id, type, source, occurred_at)
  values (v_sess.company_id, v_sess.id, p_profile, 'check_out', p_source, v_now);

  return jsonb_build_object('result','ok','session_id',v_sess.id,'check_in_at',v_sess.check_in_at,
    'check_out_at',v_now,'shift_id',v_sess.shift_id,'recorded_break_minutes',v_break);
end $$;

create function start_break(p_profile uuid, p_source attendance_source) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_sess attendance_sessions;
begin
  perform pg_advisory_xact_lock(hashtext(p_profile::text));
  select * into v_sess from attendance_sessions where profile_id = p_profile and check_out_at is null;
  if not found then return jsonb_build_object('result','no_active_session'); end if;
  if exists (select 1 from break_sessions where session_id = v_sess.id and ended_at is null) then
    return jsonb_build_object('result','already_on_break'); end if;
  insert into break_sessions(session_id) values (v_sess.id);
  insert into attendance_events(company_id, session_id, profile_id, type, source) values (v_sess.company_id, v_sess.id, p_profile, 'break_start', p_source);
  return jsonb_build_object('result','ok');
end $$;

create function end_break(p_profile uuid, p_source attendance_source) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_sess attendance_sessions; v_n int;
begin
  perform pg_advisory_xact_lock(hashtext(p_profile::text));
  select * into v_sess from attendance_sessions where profile_id = p_profile and check_out_at is null;
  if not found then return jsonb_build_object('result','no_active_session'); end if;
  update break_sessions set ended_at = clock_timestamp() where session_id = v_sess.id and ended_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('result','not_on_break'); end if;
  insert into attendance_events(company_id, session_id, profile_id, type, source) values (v_sess.company_id, v_sess.id, p_profile, 'break_end', p_source);
  return jsonb_build_object('result','ok');
end $$;

create function admin_correct_attendance(p_actor uuid, p_session uuid, p_check_in timestamptz, p_check_out timestamptz, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor profiles; v_sess attendance_sessions;
begin
  select * into v_actor from profiles where id = p_actor and status = 'active';
  select * into v_sess from attendance_sessions where id = p_session for update;
  if v_actor.id is null or v_sess.id is null or v_actor.company_id <> v_sess.company_id then
    return jsonb_build_object('result','not_allowed'); end if;
  if v_actor.role <> 'owner' and not (v_actor.role = 'manager' and exists (
      select 1 from team_members m join team_members e on e.team_id = m.team_id
      where m.profile_id = p_actor and e.profile_id = v_sess.profile_id)) then
    return jsonb_build_object('result','not_allowed'); end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then return jsonb_build_object('result','reason_required'); end if;

  insert into attendance_corrections(session_id, corrected_by, reason, before, after)
  values (p_session, p_actor, p_reason,
    jsonb_build_object('check_in_at', v_sess.check_in_at, 'check_out_at', v_sess.check_out_at),
    jsonb_build_object('check_in_at', p_check_in, 'check_out_at', p_check_out));
  update attendance_sessions set check_in_at = p_check_in, check_out_at = p_check_out,
    check_out_source = case when p_check_out is null then null else 'admin_correction'::attendance_source end where id = p_session;
  insert into attendance_events(company_id, session_id, profile_id, type, source, meta)
  values (v_sess.company_id, p_session, v_sess.profile_id, 'correction', 'admin_correction', jsonb_build_object('by', p_actor, 'reason', p_reason));
  insert into audit_logs(company_id, actor_id, action, entity_type, entity_id, meta)
  values (v_sess.company_id, p_actor, 'attendance.correct', 'attendance_session', p_session::text, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('result','ok');
end $$;

-- Atomic, single-use invitation acceptance. p_email must be the VERIFIED email of the auth user.
create function accept_invitation(p_token_hash text, p_user_id uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_inv invitations;
begin
  select * into v_inv from invitations where token_hash = p_token_hash for update;
  if not found then return jsonb_build_object('result','invalid'); end if;
  if v_inv.status = 'revoked' then return jsonb_build_object('result','revoked'); end if;
  if v_inv.status = 'accepted' then return jsonb_build_object('result','already_used'); end if;
  if v_inv.expires_at <= now() then
    update invitations set status = 'expired' where id = v_inv.id;
    return jsonb_build_object('result','expired'); end if;
  if lower(v_inv.email) <> lower(p_email) then return jsonb_build_object('result','email_mismatch'); end if;

  insert into profiles(id, company_id, email, full_name, job_title, role, start_date)
  values (p_user_id, v_inv.company_id, v_inv.email, v_inv.full_name, v_inv.job_title, v_inv.role, current_date);
  if v_inv.team_id is not null then insert into team_members(team_id, profile_id) values (v_inv.team_id, p_user_id); end if;
  update invitations set status = 'accepted', accepted_by = p_user_id, accepted_at = now() where id = v_inv.id;
  insert into notifications(company_id, recipient_id, type, title, body, link, dedupe_key)
  values (v_inv.company_id, v_inv.invited_by, 'invitation_accepted', v_inv.full_name || ' joined', v_inv.email || ' accepted the invitation.', '/admin/employees', 'invite_accepted:' || v_inv.id);
  insert into audit_logs(company_id, actor_id, action, entity_type, entity_id, meta)
  values (v_inv.company_id, p_user_id, 'invitation.accept', 'invitation', v_inv.id::text, jsonb_build_object('role', v_inv.role));
  return jsonb_build_object('result','ok','profile_id',p_user_id,'role',v_inv.role);
end $$;

-- Run on a schedule (e.g. pg_cron every 15 min). Notifies owners once per open session.
create function flag_missing_checkouts() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select s.id, s.company_id, s.profile_id, p.full_name
    from attendance_sessions s join profiles p on p.id = s.profile_id
    join company_settings cs on cs.company_id = s.company_id
    where s.check_out_at is null and s.check_in_at < now() - make_interval(hours => cs.missing_checkout_after_hours)
  loop
    insert into notifications(company_id, recipient_id, type, title, body, link, dedupe_key)
    select r.company_id, o.id, 'missing_checkout', 'Missing check-out: ' || r.full_name, 'An attendance session is still open.', '/admin/attendance', 'missing_checkout:' || r.id
    from profiles o where o.company_id = r.company_id and o.role = 'owner'
    on conflict (recipient_id, dedupe_key) do nothing;
    if found then
      insert into attendance_events(company_id, session_id, profile_id, type, meta) values (r.company_id, r.id, r.profile_id, 'auto_flag', '{"reason":"missing_checkout"}');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.auth_company_id(), public.auth_role(), public.is_manager_of(uuid), public.can_view_profile(uuid) to authenticated;
grant execute on function bootstrap_owner, check_in, check_out, start_break, end_break, admin_correct_attendance, accept_invitation, flag_missing_checkouts to service_role;
