-- Run against a scratch DB after migrations. Each assertion raises on failure.
create or replace function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if; raise notice 'PASS %', label; end $$;
create or replace function pg_temp.denied(label text, stmt text) returns void language plpgsql as $$
begin begin execute stmt; exception when others then raise notice 'PASS % (%)', label, sqlerrm; return; end; raise exception 'FAIL %: statement was allowed', label; end $$;

insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-0000000000a1','owner@x.co'),('00000000-0000-0000-0000-0000000000b1','mgr@x.co'),
 ('00000000-0000-0000-0000-0000000000c1','emp@x.co'),('00000000-0000-0000-0000-0000000000c2','emp2@x.co'),
 ('00000000-0000-0000-0000-0000000000d1','outsider@x.co');

do $t$
declare r jsonb; cid uuid; t1 uuid; t2 uuid; own uuid := '00000000-0000-0000-0000-0000000000a1';
begin
  r := bootstrap_owner(own,'Acme','Olivia Owner','owner@x.co'); cid := (r->>'company_id')::uuid;
  perform pg_temp.denied('second owner bootstrap rejected', $q$select bootstrap_owner('00000000-0000-0000-0000-0000000000d1','Evil','E','e@x.co')$q$);
  insert into teams(company_id,name) values (cid,'Support') returning id into t1;
  insert into teams(company_id,name) values (cid,'Eng') returning id into t2;

  -- invitations
  insert into invitations(company_id,email,full_name,role,team_id,token_hash,expires_at,invited_by) values
   (cid,'mgr@x.co','Mia Mgr','manager',t1,'h_mgr',now()+interval '1 day',own),
   (cid,'emp@x.co','Eli Emp','employee',t1,'h_emp',now()+interval '1 day',own),
   (cid,'emp2@x.co','Eve Emp','employee',t2,'h_emp2',now()+interval '1 day',own),
   (cid,'old@x.co','Old','employee',null,'h_old',now()-interval '1 day',own),
   (cid,'rev@x.co','Rev','employee',null,'h_rev',now()+interval '1 day',own);
  update invitations set status='revoked' where token_hash='h_rev';
  perform pg_temp.denied('invitation cannot grant owner role', $q$insert into invitations(company_id,email,full_name,role,token_hash,expires_at,invited_by) select company_id,'z@x.co','Z','owner','h_z',now()+interval '1 day',invited_by from invitations limit 1$q$);

  perform pg_temp.eq('accept mgr', accept_invitation('h_mgr','00000000-0000-0000-0000-0000000000b1','mgr@x.co')->>'result','ok');
  perform pg_temp.eq('replay rejected', accept_invitation('h_mgr','00000000-0000-0000-0000-0000000000b1','mgr@x.co')->>'result','already_used');
  perform pg_temp.eq('email mismatch', accept_invitation('h_emp','00000000-0000-0000-0000-0000000000c1','attacker@x.co')->>'result','email_mismatch');
  perform pg_temp.eq('accept emp', accept_invitation('h_emp','00000000-0000-0000-0000-0000000000c1','EMP@x.co')->>'result','ok');
  perform pg_temp.eq('accept emp2', accept_invitation('h_emp2','00000000-0000-0000-0000-0000000000c2','emp2@x.co')->>'result','ok');
  perform pg_temp.eq('expired', accept_invitation('h_old','00000000-0000-0000-0000-0000000000d1','old@x.co')->>'result','expired');
  perform pg_temp.eq('revoked', accept_invitation('h_rev','00000000-0000-0000-0000-0000000000d1','rev@x.co')->>'result','revoked');
  perform pg_temp.eq('unknown token', accept_invitation('nope','00000000-0000-0000-0000-0000000000d1','a@x.co')->>'result','invalid');
  perform pg_temp.eq('role from invitation', (select role::text from profiles where email='emp@x.co'),'employee');
  perform pg_temp.eq('owner notified once per accepted invite', (select count(*)::int from notifications where type='invitation_accepted'),3);

  -- attendance
  perform pg_temp.eq('check-in ok', check_in('00000000-0000-0000-0000-0000000000c1','discord')->>'result','ok');
  perform pg_temp.eq('duplicate check-in', check_in('00000000-0000-0000-0000-0000000000c1','discord')->>'result','already_checked_in');
  perform pg_temp.eq('one open session', (select count(*)::int from attendance_sessions where profile_id='00000000-0000-0000-0000-0000000000c1' and check_out_at is null),1);
  perform pg_temp.eq('break start', start_break('00000000-0000-0000-0000-0000000000c1','discord')->>'result','ok');
  perform pg_temp.eq('double break', start_break('00000000-0000-0000-0000-0000000000c1','discord')->>'result','already_on_break');
  perform pg_temp.eq('break end', end_break('00000000-0000-0000-0000-0000000000c1','discord')->>'result','ok');
  perform pg_temp.eq('check-out ok', check_out('00000000-0000-0000-0000-0000000000c1','discord')->>'result','ok');
  perform pg_temp.eq('check-out w/o session', check_out('00000000-0000-0000-0000-0000000000c1','discord')->>'result','no_active_session');
  perform pg_temp.eq('events logged', (select count(*)::int from attendance_events where profile_id='00000000-0000-0000-0000-0000000000c1'),4);
  perform pg_temp.denied('events are append-only', 'delete from attendance_events');
  perform pg_temp.denied('audit log append-only', 'update audit_logs set action=''x''');

  -- deactivated user cannot check in
  update profiles set status='deactivated' where id='00000000-0000-0000-0000-0000000000c2';
  perform pg_temp.eq('deactivated blocked', check_in('00000000-0000-0000-0000-0000000000c2','web')->>'result','not_allowed');
  update profiles set status='active' where id='00000000-0000-0000-0000-0000000000c2';

  -- shifts overlap
  insert into shifts(company_id,profile_id,starts_at,ends_at) values (cid,'00000000-0000-0000-0000-0000000000c1','2026-02-01 09:00+00','2026-02-01 17:00+00');
  perform pg_temp.denied('overlapping shift rejected', $q$insert into shifts(company_id,profile_id,starts_at,ends_at) select company_id,profile_id,'2026-02-01 16:00+00','2026-02-01 20:00+00' from shifts limit 1$q$);

  -- corrections
  perform pg_temp.eq('correction needs reason', admin_correct_attendance(own,(select id from attendance_sessions limit 1),now()-interval '3h',now()-interval '1h','  ')->>'result','reason_required');
  perform pg_temp.eq('owner corrects', admin_correct_attendance(own,(select id from attendance_sessions limit 1),now()-interval '3h',now()-interval '1h','forgot to clock in')->>'result','ok');
  perform pg_temp.eq('manager of same team corrects', admin_correct_attendance('00000000-0000-0000-0000-0000000000b1',(select id from attendance_sessions limit 1),now()-interval '3h',now()-interval '1h','typo')->>'result','ok');
  perform check_in('00000000-0000-0000-0000-0000000000c2','web');
  perform pg_temp.eq('manager of other team rejected', admin_correct_attendance('00000000-0000-0000-0000-0000000000b1',(select id from attendance_sessions where profile_id='00000000-0000-0000-0000-0000000000c2'),now()-interval '3h',now()-interval '1h','x y z')->>'result','not_allowed');
  perform pg_temp.eq('corrections recorded', (select count(*)::int from attendance_corrections),2);
  perform pg_temp.eq('c2 left open', check_out('00000000-0000-0000-0000-0000000000c2','web')->>'result','ok');

  -- missing checkout flagging is deduped
  update company_settings set missing_checkout_after_hours = 1;
  perform check_in('00000000-0000-0000-0000-0000000000c2','web');
  update attendance_sessions set check_in_at = now() - interval '5 hours' where profile_id='00000000-0000-0000-0000-0000000000c2' and check_out_at is null;
  perform pg_temp.eq('flag first run', flag_missing_checkouts(),1);
  perform pg_temp.eq('flag second run deduped', flag_missing_checkouts(),0);
end $t$;

-- ===== RLS as a logged-in employee =====
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000c1';
select pg_temp.eq('employee sees only self', (select count(*)::int from profiles), 1);
select pg_temp.eq('employee sees only own attendance', (select count(distinct profile_id)::int from attendance_sessions), 1);
select pg_temp.denied('employee cannot self-promote', $q$update profiles set role='owner' where id=auth.uid()$q$);
select pg_temp.denied('employee cannot read invitations', 'select * from invitations');
select pg_temp.eq('employee sees zero audit rows', (select count(*)::int from audit_logs), 0);
select pg_temp.denied('employee cannot call check_in directly for others', $q$select check_in('00000000-0000-0000-0000-0000000000c2','web')$q$);
select pg_temp.denied('employee cannot forge attendance row', $q$insert into attendance_sessions(company_id,profile_id,check_in_source) select company_id,id,'web' from profiles$q$);
select pg_temp.denied('employee cannot read discord link codes', 'select * from discord_link_codes');
update profiles set full_name='Eli Renamed' where id = auth.uid();
select pg_temp.eq('employee can edit own name', (select full_name from profiles where id=auth.uid()),'Eli Renamed');
reset role;

set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b1';
select pg_temp.eq('manager sees self + same-team employee only', (select count(*)::int from profiles), 2);
reset role;

set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.eq('owner sees everyone', (select count(*)::int from profiles), 4);
select pg_temp.eq('owner sees audit log', (select count(*)::int from audit_logs) > 0, true);
reset role;
