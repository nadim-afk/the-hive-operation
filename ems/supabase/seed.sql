-- DEVELOPMENT ONLY. Do not run in production.
-- Owner creation is intentionally done via bootstrap_owner() after you sign up through Supabase Auth:
--   select bootstrap_owner('<auth-user-uuid>', 'Acme Inc', 'Your Name', 'you@example.com');
-- Then optionally create sample teams for that company:
-- insert into teams(company_id, name) select id, t from companies, unnest(array['Support','Engineering']) t;
select 'seed placeholder: see comments' as note;
