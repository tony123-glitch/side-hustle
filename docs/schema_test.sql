-- =====================================================================
-- Schema smoke test. Proves the security rules in schema.sql work.
--
-- Run it against your LOCAL database right after `npx supabase db reset`
-- and BEFORE seeding (it expects no other listings to exist):
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f docs/schema_test.sql
-- Everything runs inside a transaction that is rolled back at the end,
-- so it leaves no data behind. It stops at the first failure.
-- Never run it against production.
-- =====================================================================
\set ON_ERROR_STOP 1
\pset pager off
begin;
set client_min_messages = warning;

-- ---------- test helpers ----------
create schema t;
grant usage on schema t to anon, authenticated, service_role;
create function t.expect_error(p_sql text, p_expected text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin
    execute p_sql;
    ok := true;
  exception when others then
    if sqlerrm not like '%' || p_expected || '%' then
      raise exception 'Expected error "%" but got "%" (stmt: %)', p_expected, sqlerrm, p_sql;
    end if;
  end;
  if ok then raise exception 'Expected error "%" but it succeeded: %', p_expected, p_sql; end if;
end $$;
create function t.eq(actual text, expected text, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL %: expected %, got %', label, expected, actual;
  end if;
  raise notice 'ok  %', label;
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;
set client_min_messages = notice;

-- ---------- fixtures (as superuser) ----------
insert into public.zip_codes values
  ('10001', 40.7506, -73.9972), ('10002', 40.7157, -73.9863),
  ('11201', 40.6940, -73.9900), ('07030', 40.7451, -74.0279), ('19104', 39.9566, -75.1990)
on conflict (zip) do nothing;

\set admin   '''00000000-0000-0000-0000-0000000000a1'''
\set plus    '''00000000-0000-0000-0000-0000000000b1'''
\set free    '''00000000-0000-0000-0000-0000000000b2'''
\set poster  '''00000000-0000-0000-0000-0000000000c1'''
\set org     '''00000000-0000-0000-0000-0000000000d1'''
\set r1      '''00000000-0000-0000-0000-0000000000e1'''
\set r2      '''00000000-0000-0000-0000-0000000000e2'''

-- Signup backstops
select t.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('kid@smoke.test',
  jsonb_build_object('display_name','Kid','birth_date',(current_date - interval '17 years')::date,'terms_accepted',true))$$, 'MUST_BE_18');
select t.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('noterms@smoke.test',
  '{"display_name":"No Terms","birth_date":"2000-01-01"}')$$, 'TERMS_NOT_ACCEPTED');
select t.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('bad@smoke.test',
  '{"display_name":"Bad","birth_date":"not-a-date","terms_accepted":true}')$$, 'INVALID_BIRTH_DATE');

insert into auth.users (id, email, raw_user_meta_data) values
  (:admin,  'admin@smoke.test',  '{"display_name":"Admin","birth_date":"1999-01-01","terms_accepted":true}'),
  (:plus,   'plus@smoke.test',   '{"display_name":"Paula Plus","birth_date":"2004-05-05","terms_accepted":true}'),
  (:free,   'free@smoke.test',   '{"display_name":"Fred Free","birth_date":"2005-03-03","terms_accepted":true}'),
  (:poster, 'poster@smoke.test', '{"display_name":"Pat Poster","birth_date":"2003-02-02","terms_accepted":true}'),
  (:org,    'lab@smoke.test',    '{"display_name":"Dana","birth_date":"1985-01-01","terms_accepted":true,"account_type":"organization","org_name":"Northside Research Lab"}'),
  (:r1,     'r1@smoke.test',     '{"display_name":"Reporter One","birth_date":"2001-01-01","terms_accepted":true}'),
  (:r2,     'r2@smoke.test',     '{"display_name":"Reporter Two","birth_date":"2001-01-01","terms_accepted":true}');

select t.eq((select count(*) from public.profiles)::text, '7', 'signup creates profiles');
select t.eq(public.credit_balance(:free)::text, '3', 'signup grants 3 free credits');
select t.eq((select account_type::text from public.profiles where id = :org), 'organization', 'org account type stored');

update public.profiles set role = 'admin' where id = :admin;
update public.profiles set org_verified = true, is_founding_partner = true where id = :org;
insert into public.subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_start, current_period_end)
values (:plus, 'cus_test1', 'sub_test1', 'active', now() - interval '1 day', now() + interval '29 days');
update public.seeker_preferences set zip = '10001', interested_categories = '{focus_group,research_study}',
  location_pref = 'either', radius_miles = 10, onboarding_completed = true, notify_frequency = 'instant',
  available_slots = '{sat_morning,sat_afternoon}'
where user_id in (:plus, :free);
select t.eq((select round(lat::numeric,2)::text from public.seeker_preferences where user_id = :plus), '40.75', 'zip trigger sets lat');

-- ---------- untrusted individual poster ----------
reset role; select set_config('request.jwt.claims', json_build_object('sub', :poster, 'role', 'authenticated')::text, false); set role authenticated;

select t.eq((public.submit_listing('{
  "title":"Help me move a couch Saturday","description":"Need one person to help carry a couch down two flights of stairs. Paid via direct deposit or cash same day.",
  "category":"moving_labor","pay_amount_cents":6000,"pay_type":"flat","pay_method":"cash","pay_timing":"same_day",
  "time_commitment":"single_session","estimated_hours":2,"location_type":"in_person","zip":"10001",
  "time_slots":["sat_morning"]}'::jsonb) ->> 'status'), 'pending', 'untrusted poster -> pending');
select t.eq((public.my_account_summary() ->> 'credit_balance'), '2', 'posting charges one credit');

select t.eq((public.submit_listing('{
  "title":"Easy package job from home","description":"Receive packages at your place and reship them. Must buy gift cards for supplies first. Text 555-123-4567.",
  "category":"errands_delivery","pay_amount_cents":50000,"pay_type":"flat","pay_method":"gift_card","pay_timing":"within_week",
  "time_commitment":"single_session","estimated_hours":1,"location_type":"remote"}'::jsonb) ->> 'status'), 'pending', 'scam listing -> pending');
select t.eq((select count(*)::text from public.listing_flags), '0', 'poster cannot read listing_flags');
select t.expect_error($$insert into public.listings (poster_id, title, description, category, pay_amount_cents, pay_type, pay_method, pay_timing, time_commitment, estimated_hours, location_type, status)
  values (auth.uid(), 'Sneaky direct insert', 'Trying to skip moderation by writing straight to the table.', 'other', 1000, 'flat', 'cash', 'same_day', 'single_session', 1, 'remote', 'approved')$$, 'permission denied');
select t.expect_error($$update public.listings set status = 'approved' where poster_id = auth.uid()$$, 'permission denied');
select t.expect_error($$update public.profiles set role = 'admin' where id = auth.uid()$$, 'permission denied');
select t.expect_error($$update public.profiles set trusted_poster = true where id = auth.uid()$$, 'permission denied');
update public.profiles set display_name = 'Pat P.' where id = auth.uid();
select t.eq((select display_name from public.profiles where id = auth.uid()), 'Pat P.', 'user can rename self');
select t.expect_error($$insert into public.credit_ledger (user_id, delta, reason) values (auth.uid(), 100, 'refund')$$, 'permission denied');

select public.submit_listing('{
  "title":"Rake leaves in my backyard","description":"Small backyard, rakes and bags provided. About two hours of work on a weekend morning.",
  "category":"yard_work","pay_amount_cents":4000,"pay_type":"flat","pay_method":"payment_app","pay_timing":"same_day",
  "time_commitment":"single_session","estimated_hours":2,"location_type":"in_person","zip":"10002"}'::jsonb);
select t.eq((public.my_account_summary() ->> 'credit_balance'), '0', 'credits drained');
select t.expect_error($$select public.submit_listing('{"title":"One more listing here","description":"This should fail because there are no credits left on the account.","category":"cleaning","pay_amount_cents":3000,"pay_type":"flat","pay_method":"cash","pay_timing":"same_day","time_commitment":"single_session","estimated_hours":1,"location_type":"remote"}'::jsonb)$$, 'NO_CREDITS');
select t.eq((public.my_account_summary() ->> 'credit_balance'), '0', 'account summary balance');

-- ---------- trusted org (founding partner) ----------
reset role; select set_config('request.jwt.claims', json_build_object('sub', :org, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((public.submit_listing('{
  "title":"60-minute focus group on campus dining","description":"Share your opinions about campus dining in a moderated group discussion with 8 other students. Snacks provided.",
  "category":"focus_group","pay_amount_cents":7500,"pay_type":"flat","pay_method":"gift_card","pay_timing":"same_day",
  "time_commitment":"single_session","estimated_hours":1,"location_type":"in_person","zip":"10002",
  "time_slots":["sat_afternoon"]}'::jsonb) ->> 'status'), 'approved', 'trusted org clean listing -> auto-approved');
select t.eq((public.submit_listing('{
  "title":"Remote memory study (45 min)","description":"Complete a series of short memory tasks online from home. Must be a native English speaker with normal or corrected vision.",
  "category":"research_study","pay_amount_cents":2000,"pay_type":"flat","pay_method":"gift_card","pay_timing":"within_week",
  "time_commitment":"single_session","estimated_hours":0.75,"location_type":"remote",
  "screening_questions":[{"id":"q1","text":"Are you a native English speaker?","required_answer":true},
                         {"id":"q2","text":"Have you been diagnosed with a memory disorder?","required_answer":false}]}'::jsonb) ->> 'charged_to'), 'partner', 'founding partner posts free');
select t.eq((public.my_account_summary() ->> 'credit_balance'), '3', 'partner credits untouched');

-- ---------- alerts ----------
reset role;
select t.eq((select count(*)::text from public.notifications n join public.listings l on l.id = n.listing_id where n.user_id = :plus and l.category = 'focus_group'), '1', 'plus member alerted for match');
select t.eq((select count(*)::text from public.notifications where user_id = :free), '0', 'free member not alerted');

-- ---------- anonymous visitor ----------
select set_config('request.jwt.claims', '', false); set role anon;
select t.eq((select count(*)::text from public.listings), '2', 'anon sees only approved listings');
select t.eq((select count(*)::text from public.search_listings()), '2', 'search returns approved');
select t.eq((select count(*)::text from public.search_listings(p_lat => 40.7506, p_lng => -73.9972, p_radius_miles => 5)), '2', 'search near 10001 keeps nearby + remote');
select t.eq((select count(*)::text from public.search_listings(p_lat => 39.9566, p_lng => -75.1990, p_radius_miles => 10)), '1', 'search in Philly keeps only remote');
select t.eq((select max(total_count)::text from public.search_listings()), '2', 'total_count window');
select t.eq((select count(*)::text from public.search_listings(p_categories => '{focus_group}')), '1', 'category filter');
select t.eq((select count(*)::text from public.search_listings(p_location => 'remote')), '1', 'remote filter');
select t.eq((select count(*)::text from public.search_listings(p_query => 'dining')), '1', 'text search');
select t.expect_error($$select * from public.profile_private$$, 'permission denied');
select t.expect_error($$select public.submit_listing('{}'::jsonb)$$, 'permission denied');
select t.expect_error($$select public.track_listing_event(gen_random_uuid(), 'view', 'x')$$, 'permission denied');

-- ---------- free seeker ----------
reset role; select id as pending_id from public.listings where title like 'Rake leaves%' \gset
 select set_config('request.jwt.claims', json_build_object('sub', :free, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((select count(*)::text from public.profile_private), '1', 'seeker sees only own private row');
select t.eq((select count(*)::text from public.get_for_you_feed()), '0', 'free user gets empty For You feed');
select t.expect_error($$select public.submit_listing('{"title":"My own clinical study","description":"Individuals should not be able to post clinical studies on the platform at all.","category":"clinical_study","pay_amount_cents":3000,"pay_type":"flat","pay_method":"cash","pay_timing":"same_day","time_commitment":"single_session","estimated_hours":1,"location_type":"remote"}'::jsonb)$$, 'ORG_ONLY_CATEGORY');
select t.eq((public.my_account_summary() ->> 'credit_balance'), '3', 'blocked post costs nothing');
select t.eq(public.count_my_matches()::text, '2', 'free user can see match count');
select t.expect_error($$update public.seeker_preferences set zip = '99999' where user_id = auth.uid()$$, 'UNKNOWN_ZIP');
select t.expect_error($$update public.seeker_preferences set lat = 1 where user_id = auth.uid()$$, 'permission denied');
select t.expect_error($$update public.seeker_preferences set available_slots = '{funday_morning}' where user_id = auth.uid()$$, 'available_slots_check');

-- screening + apply
\set study '(select id from public.listings where title like ''Remote memory%'')'
\set group '(select id from public.listings where title like ''60-minute%'')'
select t.expect_error(format('select public.apply_to_listing(%L)', (select id from public.listings where title like 'Remote memory%')), 'SCREENING_REQUIRED');
select t.expect_error(format('select public.submit_screening(%L, %L)', (select id from public.listings where title like 'Remote memory%'), '{"q1":true}'), 'INCOMPLETE_ANSWERS');
select t.eq(public.submit_screening(:study, '{"q1":true,"q2":true}')::text, 'false', 'screening fail');
select t.expect_error(format('select public.apply_to_listing(%L)', (select id from public.listings where title like 'Remote memory%')), 'NOT_ELIGIBLE');
select t.eq(public.submit_screening(:study, '{"q1":true,"q2":false}')::text, 'true', 'screening pass');
select public.apply_to_listing(:study, 'Happy to help!');
select t.expect_error(format('select public.apply_to_listing(%L)', (select id from public.listings where title like 'Remote memory%')), 'ALREADY_APPLIED');
select public.apply_to_listing(:group, null);
select t.eq((select count(*)::text from public.get_applicants(:study)), '0', 'seeker cannot list applicants');
insert into public.saved_listings (user_id, listing_id) values (auth.uid(), :group);
select t.expect_error(format('insert into public.saved_listings (user_id, listing_id) values (auth.uid(), %L)', :'pending_id'), 'row-level security');

-- ---------- org reviews applicants ----------
reset role; select set_config('request.jwt.claims', json_build_object('sub', :org, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((select count(*)::text from public.get_applicants(:study)), '1', 'poster sees applicant');
select t.eq((select coalesce(email, 'hidden') from public.get_applicants(:study)), 'hidden', 'email hidden before accept');
select t.eq((select prescreen_passed::text from public.get_applicants(:study)), 'true', 'prescreen result visible');
select public.set_application_status((select application_id from public.get_applicants(:study)), 'accepted');
select t.eq((select email from public.get_applicants(:study)), 'free@smoke.test', 'email revealed after accept');
select t.expect_error(format('select public.set_application_status(%L, %L)', (select application_id from public.get_applicants((select id from public.listings where title like 'Remote memory%'))), 'sent'), 'INVALID_TRANSITION');
select public.set_application_status((select application_id from public.get_applicants(:study)), 'completed');
select public.leave_review((select application_id from public.get_applicants(:study)), 5, 'On time and helpful');
select t.eq((select views::text || '/' || applications::text from public.get_listing_stats(:study)), '0/1', 'listing stats');

reset role; select set_config('request.jwt.claims', json_build_object('sub', :free, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((select poster_email from public.get_my_applications() where listing_title like 'Remote memory%'), 'lab@smoke.test', 'seeker sees poster email after accept');
select t.eq((select can_review::text from public.get_my_applications() where listing_title like 'Remote memory%'), 'true', 'seeker can review');
select public.leave_review((select application_id from public.get_my_applications() where listing_title like 'Remote memory%'), 4, null);
select t.expect_error(format('select public.leave_review(%L, 5)', (select application_id from public.get_my_applications() where listing_title like 'Remote memory%')), 'ALREADY_REVIEWED');
select t.expect_error(format('select public.leave_review(%L, 5)', (select application_id from public.get_my_applications() where listing_title like '60-minute%')), 'REVIEW_NOT_ALLOWED');
select t.eq((select rating_count::text from public.profile_ratings where user_id = :org), '1', 'rating view');
delete from public.screening_results where user_id = auth.uid();
select t.eq((select count(*)::text from public.screening_results), '0', 'user can delete own screening result');

-- ---------- plus member ----------
reset role; select set_config('request.jwt.claims', json_build_object('sub', :plus, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((select count(*)::text from public.get_for_you_feed()), '2', 'plus feed returns matches');
select t.eq((select title from public.get_for_you_feed() limit 1), '60-minute focus group on campus dining', 'best match first');
select t.eq((public.submit_listing('{
  "title":"Need a tutor for statistics","description":"Looking for help with intro statistics homework, two one-hour sessions next week at the library.",
  "category":"tutoring","pay_amount_cents":2500,"pay_type":"hourly","pay_method":"payment_app","pay_timing":"same_day",
  "time_commitment":"multiple_visits","estimated_hours":2,"session_count":2,"location_type":"in_person","zip":"10001"}'::jsonb) ->> 'charged_to'), 'subscription', 'plus member uses monthly allowance');
select t.eq((public.my_account_summary() ->> 'credit_balance'), '3', 'plus credits untouched');
select t.eq((public.my_account_summary() ->> 'plus_listings_used'), '1', 'plus usage counted');

-- ---------- reports & autohide ----------
reset role; select set_config('request.jwt.claims', json_build_object('sub', :r1, 'role', 'authenticated')::text, false); set role authenticated;
select public.submit_report(:group, null, 'scam', 'Looks fake');
select t.expect_error(format('select public.submit_report(%L, null, %L)', (select id from public.listings where title like '60-minute%'), 'spam'), 'ALREADY_REPORTED');
reset role; select set_config('request.jwt.claims', json_build_object('sub', :r2, 'role', 'authenticated')::text, false); set role authenticated;
select public.submit_report(:group, null, 'spam', null);
reset role; select set_config('request.jwt.claims', json_build_object('sub', :plus, 'role', 'authenticated')::text, false); set role authenticated;
select public.submit_report((select id from public.listings where title like '60-minute%'), null, 'unsafe', null);
reset role;
select t.eq((select status::text from public.listings where title like '60-minute%'), 'pending', '3 reports hide listing');
select t.eq((select ('reported' = any(flags))::text from public.listing_flags f join public.listings l on l.id = f.listing_id where l.title like '60-minute%'), 'true', 'reported flag added');

-- ---------- admin ----------
select set_config('request.jwt.claims', json_build_object('sub', :poster, 'role', 'authenticated')::text, false); set role authenticated;
select t.expect_error(format('select public.admin_review_listing(%L, %L)', (select id from public.listings where title like '60-minute%' ), 'approve'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claims', json_build_object('sub', :admin, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((select count(*)::text from public.listing_flags), '6', 'admin reads all flags');
select t.eq((select array_to_string(flags, ',') from public.listing_flags f join public.listings l on l.id = f.listing_id where l.title like 'Easy package%'),
  'gift_card_scam,reshipping,contact_phone,high_pay', 'scam flags detected');
select t.eq((select array_to_string(flags, ',') from public.listing_flags f join public.listings l on l.id = f.listing_id where l.title like 'Help me move%'),
  '', 'direct deposit does not trip upfront rule');
select public.admin_review_listing((select id from public.listings where title like '60-minute%'), 'approve');
select t.eq((select status::text from public.listings where title like '60-minute%'), 'approved', 'admin re-approves');
select t.eq((select count(*)::text from public.reports where status = 'open'), '0', 'approve clears open reports');
select t.expect_error(format('select public.admin_review_listing(%L, %L)', (select id from public.listings where title like 'Easy package%'), 'reject'), 'REASON_REQUIRED');
select public.admin_review_listing((select id from public.listings where title like 'Easy package%'), 'reject', 'Asks workers to buy gift cards and reship packages.');
select public.admin_review_listing((select id from public.listings where title like 'Help me move%'), 'reject', 'Please remove the payment details from the description.');
select public.admin_set_sponsored((select id from public.listings where title like 'Remote memory%'), true);
select t.expect_error($$insert into public.moderation_keywords (pattern, flag) values ('(unclosed', 'bad')$$, 'INVALID_PATTERN');
insert into public.moderation_keywords (pattern, flag) values ('\mwire me\M', 'payment_scam');
select t.eq((select count(*)::text from public.moderation_actions), '4', 'audit log written');

-- poster fixes a rejected listing (no charge)
reset role; select set_config('request.jwt.claims', json_build_object('sub', :poster, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((select rejection_reason from public.listings where title like 'Help me move%'), 'Please remove the payment details from the description.', 'poster sees rejection reason');
select t.eq((public.update_listing((select id from public.listings where title like 'Help me move%'), '{
  "title":"Help me move a couch Saturday","description":"Need one person to help carry a couch down two flights of stairs on Saturday morning.",
  "category":"moving_labor","pay_amount_cents":6000,"pay_type":"flat","pay_method":"cash","pay_timing":"same_day",
  "time_commitment":"single_session","estimated_hours":2,"location_type":"in_person","zip":"10001","time_slots":["sat_morning"]}'::jsonb) ->> 'status'), 'pending', 'edit resubmits to pending');
select t.eq((public.my_account_summary() ->> 'credit_balance'), '0', 'edit is free');

-- high pay odd job gets flagged
reset role; insert into public.credit_ledger (user_id, delta, reason) values (:poster, 1, 'refund');
select set_config('request.jwt.claims', json_build_object('sub', :poster, 'role', 'authenticated')::text, false); set role authenticated;
select public.submit_listing('{"title":"Clean my apartment today","description":"Two bedroom apartment needs a deep clean, supplies provided, should take about an hour.",
  "category":"cleaning","pay_amount_cents":30000,"pay_type":"flat","pay_method":"cash","pay_timing":"same_day",
  "time_commitment":"single_session","estimated_hours":1,"location_type":"in_person","zip":"10001"}'::jsonb);
reset role;
select t.eq((select array_to_string(flags, ',') from public.listing_flags f join public.listings l on l.id = f.listing_id where l.title like 'Clean my%'), 'high_pay', 'high hourly pay flagged');

-- ban
select set_config('request.jwt.claims', json_build_object('sub', :admin, 'role', 'authenticated')::text, false); set role authenticated;
select t.expect_error(format('select public.admin_update_user(%L, %L)', '00000000-0000-0000-0000-0000000000a1', '{"banned":true}'), 'CANNOT_BAN_SELF');
select public.admin_update_user(:poster, '{"banned":true,"reason":"Repeated scam listings"}');
reset role;
select t.eq((select count(*)::text from public.listings where poster_id = :poster and status in ('pending','approved')), '0', 'ban removes live listings');
select t.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('POSTER@smoke.test', '{"display_name":"Again","birth_date":"2000-01-01","terms_accepted":true}')$$, 'SIGNUP_BLOCKED');
select set_config('request.jwt.claims', json_build_object('sub', :poster, 'role', 'authenticated')::text, false); set role authenticated;
select t.expect_error($$select public.submit_listing('{}'::jsonb)$$, 'ACCOUNT_RESTRICTED');
select t.eq((public.my_account_summary() ->> 'banned'), 'true', 'summary shows banned');

-- ---------- curated listing by admin ----------
reset role; select set_config('request.jwt.claims', json_build_object('sub', :admin, 'role', 'authenticated')::text, false); set role authenticated;
select t.eq((public.submit_listing('{"source":"curated","source_org_name":"Example Plasma Center","external_url":"https://example.com/new-donors",
  "title":"New plasma donors: first visit bonus","description":"First visit takes about two hours including a health screening. Later visits take about an hour.",
  "category":"paid_donation","pay_amount_cents":10000,"pay_type":"flat","pay_method":"prepaid_card","pay_timing":"same_day",
  "time_commitment":"single_session","estimated_hours":2,"location_type":"in_person","zip":"11201"}'::jsonb) ->> 'status'), 'approved', 'curated listing goes live');
select t.eq((select poster_name from public.search_listings(p_query => 'plasma')), 'Example Plasma Center', 'curated shows source org name');

-- ---------- server-side jobs ----------
reset role; set role service_role;
select public.track_listing_event((select id from public.listings where title like 'Remote memory%'), 'view', 'anon-abc');
select public.track_listing_event((select id from public.listings where title like 'Remote memory%'), 'view', 'anon-abc');
select t.eq((select count(*)::text from public.listing_events where event_type = 'view'), '1', 'views deduped per day');
select t.eq((select count(*)::text from public.claim_notifications('instant', 10)), '2', 'claim queued alerts');
select t.eq((select count(*)::text from public.claim_notifications('instant', 10)), '0', 'claimed alerts not re-claimed');
select t.eq(public.rate_limit_hit('post:x', 2, 60)::text, 'true', 'rate limit 1');
select t.eq(public.rate_limit_hit('post:x', 2, 60)::text, 'true', 'rate limit 2');
select t.eq(public.rate_limit_hit('post:x', 2, 60)::text, 'false', 'rate limit 3 blocked');
reset role;
update public.listings set expires_at = now() - interval '1 minute' where title like 'Remote memory%';
set role service_role;
select t.eq(public.expire_listings()::text, '1', 'expire job');
reset role;

rollback;
\echo ALL TESTS PASSED (changes rolled back)
