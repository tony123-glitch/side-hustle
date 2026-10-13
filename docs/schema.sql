-- =====================================================================
-- Side Hustle App: initial database schema (Supabase / Postgres 15+)
--
-- This file is the source of truth for Phase 1. Copy it unchanged into
-- supabase/migrations/<timestamp>_init.sql. Later changes go in NEW
-- migration files; never edit a migration that has already run.
--
-- Security model (read this before touching anything):
--   * Every table has Row Level Security (RLS) turned on.
--   * Users can write directly to only three things: their own profile
--     name, their own seeker preferences, and their saved listings.
--     Everything else (posting, applying, reviewing, reporting, admin
--     actions) goes through the SECURITY DEFINER functions in section 6,
--     which check who the caller is before doing anything.
--   * Tables with no policies (events, stripe_events, blocked_identifiers,
--     rate_limits) are reachable only with the server-side secret key.
--   * Moderation flags live in listing_flags, which only admins can read,
--     so posters can't learn what tripped the filter.
--   * Screening answers (which can be health information) are NEVER
--     stored. Only pass/fail is kept, and the user can delete it.
--
-- Regex note: Postgres regexes use \m and \M (or \y) for word boundaries.
-- \b means "backspace" in Postgres, not "word boundary".
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Types
-- ---------------------------------------------------------------------
create type public.user_role as enum ('user', 'admin');
create type public.account_type as enum ('individual', 'organization');
create type public.listing_category as enum (
  'focus_group', 'research_study', 'clinical_study', 'paid_donation', 'user_testing',
  'event_staffing', 'moving_labor', 'tutoring', 'pet_care', 'yard_work', 'cleaning',
  'errands_delivery', 'tech_help', 'creative', 'brand_ambassador', 'other'
);
create type public.listing_status as enum ('pending', 'approved', 'rejected', 'filled', 'expired', 'removed');
create type public.listing_source as enum ('user', 'curated');
create type public.charge_source as enum ('credit', 'subscription', 'partner', 'admin');
create type public.location_type as enum ('in_person', 'remote', 'hybrid');
create type public.time_commitment as enum ('single_session', 'multiple_visits', 'overnight', 'ongoing');
create type public.pay_type as enum ('flat', 'hourly', 'per_session');
create type public.pay_method as enum ('cash', 'check', 'direct_deposit', 'payment_app', 'gift_card', 'prepaid_card', 'other');
create type public.pay_timing as enum ('same_day', 'within_week', 'within_30_days', 'after_completion');
create type public.location_pref as enum ('in_person', 'remote', 'either');
create type public.notify_frequency as enum ('instant', 'daily', 'off');
create type public.application_status as enum ('sent', 'viewed', 'accepted', 'declined', 'completed', 'no_show', 'withdrawn');
create type public.report_reason as enum ('scam', 'illegal', 'nonpayment', 'unsafe', 'inappropriate', 'spam', 'other');
create type public.report_status as enum ('open', 'actioned', 'dismissed');
create type public.credit_reason as enum ('signup_bonus', 'pack_purchase', 'listing_post', 'refund', 'admin_adjust');
create type public.subscription_status as enum (
  'active', 'trialing', 'past_due', 'canceled', 'incomplete', 'incomplete_expired', 'unpaid', 'paused'
);
create type public.notification_status as enum ('queued', 'sending', 'sent', 'failed', 'skipped');
create type public.listing_event_type as enum ('view', 'click', 'save', 'apply');

-- One row per listing card in search results and the For You feed.
create type public.listing_card as (
  id uuid,
  title text,
  category public.listing_category,
  pay_amount_cents integer,
  pay_type public.pay_type,
  total_pay_cents integer,
  estimated_hours numeric,
  session_count integer,
  time_commitment public.time_commitment,
  location_type public.location_type,
  zip text,
  time_slots text[],
  is_sponsored boolean,
  created_at timestamptz,
  expires_at timestamptz,
  poster_id uuid,
  poster_name text,
  poster_is_org boolean,
  poster_verified boolean,
  distance_miles double precision,
  match_score numeric,
  total_count bigint
);


-- ---------------------------------------------------------------------
-- 1. Pure helper functions (used by CHECK constraints)
-- ---------------------------------------------------------------------

-- Time slots look like 'mon_morning' ... 'sun_night', or 'flexible'.
create function public.valid_time_slots(slots text[])
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(bool_and(
    s ~ '^((mon|tue|wed|thu|fri|sat|sun)_(morning|afternoon|evening|night)|flexible)$'
  ), true)
  from unnest(slots) as s
$$;

-- Screening questions: [{"id":"q1","text":"...","required_answer":true}, ...], max 10.
create function public.valid_screening_questions(q jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when q is null or jsonb_typeof(q) <> 'array' then false
    when jsonb_array_length(q) > 10 then false
    else coalesce((
      select bool_and(
        jsonb_typeof(e) = 'object'
        and coalesce(jsonb_typeof(e -> 'id'), '') = 'string'
        and coalesce(jsonb_typeof(e -> 'text'), '') = 'string'
        and char_length(e ->> 'text') between 5 and 200
        and coalesce(jsonb_typeof(e -> 'required_answer'), '') = 'boolean'
      )
      from jsonb_array_elements(q) as e
    ), true)
  end
$$;

-- Great-circle distance in miles. Returns null if any input is null.
create function public.distance_miles(lat1 double precision, lng1 double precision,
                                      lat2 double precision, lng2 double precision)
returns double precision language sql immutable strict set search_path = '' as $$
  select 3958.8 * 2 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )))
$$;


-- ---------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------

-- Single-row settings table. The database enforces these numbers, and the
-- app reads them for display, so this is the one place to change them.
create table public.app_config (
  id boolean primary key default true check (id),
  free_listing_credits integer not null default 3 check (free_listing_credits >= 0),
  plus_monthly_listings integer not null default 20 check (plus_monthly_listings >= 0),
  listing_default_days integer not null default 30 check (listing_default_days between 1 and 180),
  report_autohide_threshold integer not null default 3 check (report_autohide_threshold >= 1),
  -- Odd jobs paying more than this per hour get flagged for review.
  -- Studies, focus groups, donations and user testing are exempt.
  high_pay_hourly_flag_cents integer not null default 7500 check (high_pay_hourly_flag_cents > 0),
  -- false = only Plus members get alerts, even for sponsored listings.
  sponsored_alerts_all_users boolean not null default false,
  updated_at timestamptz not null default now()
);

-- ZIP code centroids, loaded from the Census ZCTA gazetteer (public domain).
create table public.zip_codes (
  zip text primary key check (zip ~ '^\d{5}$'),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180)
);

-- Public-safe profile fields. Everyone can read these.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 60),
  account_type public.account_type not null default 'individual',
  org_name text check (org_name is null or char_length(btrim(org_name)) between 2 and 100),
  org_verified boolean not null default false,
  is_founding_partner boolean not null default false,
  trusted_poster boolean not null default false,
  role public.user_role not null default 'user',
  banned_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint org_needs_name check (account_type = 'individual' or org_name is not null)
);

-- Private profile fields. Only the owner can read them; nobody can edit
-- birth_date through the API (age can't be changed after signup).
create table public.profile_private (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  birth_date date not null,
  terms_accepted_at timestamptz not null default now(),
  constraint adult_only check (birth_date <= (current_date - interval '18 years')::date)
);

-- What a seeker wants. Created automatically at signup.
create table public.seeker_preferences (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  interested_categories public.listing_category[] not null default '{}',
  excluded_categories public.listing_category[] not null default '{}',
  available_slots text[] not null default '{}' check (public.valid_time_slots(available_slots)),
  min_total_pay_cents integer not null default 0 check (min_total_pay_cents between 0 and 1000000),
  max_hours numeric(5, 2) check (max_hours is null or max_hours > 0),
  location_pref public.location_pref not null default 'either',
  zip text check (zip is null or zip ~ '^\d{5}$'),
  lat double precision,          -- set by trigger from zip; users can't write it
  lng double precision,          -- set by trigger from zip; users can't write it
  radius_miles integer not null default 15 check (radius_miles between 1 and 100),
  has_transport boolean not null default false,
  notify_email boolean not null default true,
  notify_frequency public.notify_frequency not null default 'daily',
  onboarding_completed boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.listings (
  id uuid primary key default gen_random_uuid(),
  poster_id uuid not null references public.profiles (id) on delete cascade,
  source public.listing_source not null default 'user',
  source_org_name text check (source_org_name is null or char_length(source_org_name) <= 100),
  title text not null check (char_length(title) between 8 and 100),
  description text not null check (char_length(description) between 30 and 4000),
  category public.listing_category not null,
  pay_amount_cents integer not null check (pay_amount_cents between 100 and 1000000),
  pay_type public.pay_type not null,
  pay_method public.pay_method not null,
  pay_timing public.pay_timing not null,
  time_commitment public.time_commitment not null,
  -- TOTAL hours across all sessions/visits, not hours per session.
  estimated_hours numeric(5, 2) not null check (estimated_hours > 0 and estimated_hours <= 200),
  session_count integer not null default 1 check (session_count between 1 and 100),
  total_pay_cents integer generated always as (
    case pay_type
      when 'flat' then pay_amount_cents
      when 'hourly' then round(pay_amount_cents * estimated_hours)::integer
      when 'per_session' then pay_amount_cents * session_count
    end
  ) stored,
  location_type public.location_type not null,
  zip text check (zip is null or zip ~ '^\d{5}$'),
  lat double precision,          -- set by trigger from zip
  lng double precision,          -- set by trigger from zip
  address_note text check (address_note is null or char_length(address_note) <= 200),
  time_slots text[] not null default '{}' check (public.valid_time_slots(time_slots)),
  starts_on date,
  min_age integer not null default 18 check (min_age between 18 and 120),
  max_age integer check (max_age is null or max_age >= min_age),
  requirements text check (requirements is null or char_length(requirements) <= 1000),
  screening_questions jsonb not null default '[]'::jsonb
    check (public.valid_screening_questions(screening_questions)),
  spots_available integer check (spots_available is null or spots_available > 0),
  external_url text check (external_url is null or (external_url ~ '^https://' and char_length(external_url) <= 500)),
  status public.listing_status not null default 'pending',
  charged_to public.charge_source not null default 'credit',
  rejection_reason text check (rejection_reason is null or char_length(rejection_reason) <= 500),
  is_sponsored boolean not null default false,
  approved_at timestamptz,
  approved_by uuid references public.profiles (id) on delete set null,
  expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint in_person_needs_zip check (location_type = 'remote' or zip is not null),
  constraint curated_needs_link check (
    source = 'user' or (external_url is not null and source_org_name is not null)
  )
);
create index listings_public_idx on public.listings (status, expires_at);
create index listings_poster_idx on public.listings (poster_id, created_at desc);
create index listings_category_idx on public.listings (category);
create index listings_geo_idx on public.listings (lat, lng);

-- Admin-only. Kept apart from listings so posters can't read them.
create table public.listing_flags (
  listing_id uuid primary key references public.listings (id) on delete cascade,
  flags text[] not null default '{}',
  updated_at timestamptz not null default now()
);

-- Only pass/fail is stored. The answers themselves are thrown away.
create table public.screening_results (
  user_id uuid not null references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  passed boolean not null,
  answered_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

create table public.applications (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  seeker_id uuid not null references public.profiles (id) on delete cascade,
  message text check (message is null or char_length(message) <= 1000),
  status public.application_status not null default 'sent',
  prescreen_passed boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (listing_id, seeker_id)
);
create index applications_seeker_idx on public.applications (seeker_id, created_at desc);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications (id) on delete cascade,
  reviewer_id uuid not null references public.profiles (id) on delete cascade,
  reviewee_id uuid not null references public.profiles (id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text check (comment is null or char_length(comment) <= 500),
  created_at timestamptz not null default now(),
  unique (application_id, reviewer_id),
  constraint no_self_review check (reviewer_id <> reviewee_id)
);
create index reviews_reviewee_idx on public.reviews (reviewee_id);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  listing_id uuid references public.listings (id) on delete cascade,
  reported_user_id uuid references public.profiles (id) on delete cascade,
  reason public.report_reason not null,
  details text check (details is null or char_length(details) <= 1000),
  status public.report_status not null default 'open',
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  resolution_note text,
  created_at timestamptz not null default now(),
  constraint report_has_target check (listing_id is not null or reported_user_id is not null),
  constraint no_self_report check (reported_user_id is null or reported_user_id <> reporter_id)
);
create unique index reports_one_open_per_listing
  on public.reports (reporter_id, listing_id) where listing_id is not null and status = 'open';
create index reports_status_idx on public.reports (status, created_at);

create table public.saved_listings (
  user_id uuid not null references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

-- First-party stats only. viewer_key is a user id or a random anonymous
-- cookie id. Never store IP addresses or emails here.
create table public.listing_events (
  id bigint generated always as identity primary key,
  listing_id uuid not null references public.listings (id) on delete cascade,
  event_type public.listing_event_type not null,
  viewer_key text not null check (char_length(viewer_key) <= 64),
  event_date date not null default current_date,
  created_at timestamptz not null default now(),
  unique (listing_id, event_type, viewer_key, event_date)
);

create table public.credit_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  delta integer not null check (delta <> 0),
  reason public.credit_reason not null,
  listing_id uuid references public.listings (id) on delete set null,
  stripe_checkout_session_id text unique,   -- makes webhook retries harmless
  note text,
  created_at timestamptz not null default now()
);
create index credit_ledger_user_idx on public.credit_ledger (user_id);

-- One row per user who has ever started a checkout. status is null
-- for people who bought credit packs but never subscribed.
create table public.subscriptions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  stripe_customer_id text not null unique,
  stripe_subscription_id text unique,
  status public.subscription_status,
  price_id text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  updated_at timestamptz not null default now()
);

-- Stripe webhook idempotency: insert the event id first; if it already
-- exists, the event was handled and can be skipped.
create table public.stripe_events (
  id text primary key,
  type text not null,
  received_at timestamptz not null default now()
);

create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  frequency public.notify_frequency not null,
  status public.notification_status not null default 'queued',
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique (user_id, listing_id)
);
create index notifications_queue_idx on public.notifications (status, frequency, created_at);

-- Admin-editable keyword rules. pattern is a case-insensitive Postgres regex.
create table public.moderation_keywords (
  id bigint generated always as identity primary key,
  pattern text not null check (char_length(pattern) between 2 and 500),
  flag text not null check (flag ~ '^[a-z_]{2,40}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Audit log of every admin action.
create table public.moderation_actions (
  id bigint generated always as identity primary key,
  admin_id uuid references public.profiles (id) on delete set null,
  target_type text not null check (target_type in ('listing', 'user', 'report', 'credits')),
  target_id text not null,
  action text not null,
  reason text,
  created_at timestamptz not null default now()
);

-- Banned emails (stored as sha256 hashes, never plain text).
create table public.blocked_identifiers (
  kind text not null check (kind in ('email')),
  value_hash text not null,
  reason text,
  created_at timestamptz not null default now(),
  primary key (kind, value_hash)
);

create table public.rate_limits (
  key text not null,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (key, window_start)
);


-- ---------------------------------------------------------------------
-- 3. Views
-- ---------------------------------------------------------------------
create view public.profile_ratings with (security_invoker = true) as
  select r.reviewee_id as user_id,
         round(avg(r.rating)::numeric, 2) as rating_avg,
         count(*) as rating_count
  from public.reviews r
  group by r.reviewee_id;


-- ---------------------------------------------------------------------
-- 4. Internal helper functions
-- ---------------------------------------------------------------------

create function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'admin' and p.banned_at is null
  )
$$;

-- Used by the applications policy. SECURITY DEFINER avoids RLS recursion.
create function public.owns_listing(p_listing_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.listings l
    where l.id = p_listing_id and l.poster_id = (select auth.uid())
  )
$$;

create function public.has_active_plus(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.subscriptions s
    where s.user_id = p_user_id
      and s.status in ('active', 'trialing')
      and s.current_period_end > now()
  )
$$;

create function public.credit_balance(p_user_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(sum(c.delta), 0)::integer from public.credit_ledger c where c.user_id = p_user_id
$$;

-- The single definition of "this listing fits this seeker". Used by the
-- For You feed, the match counter and alert matching.
create function public.listing_matches_prefs(l public.listings, s public.seeker_preferences, dob date)
returns boolean language sql stable set search_path = '' as $$
  select
    (cardinality(s.interested_categories) = 0 or l.category = any (s.interested_categories))
    and not (l.category = any (s.excluded_categories))
    and l.total_pay_cents >= s.min_total_pay_cents
    and (s.max_hours is null or l.estimated_hours <= s.max_hours)
    and (
      (l.location_type in ('remote', 'hybrid') and s.location_pref in ('remote', 'either'))
      or (
        l.location_type in ('in_person', 'hybrid')
        and s.location_pref in ('in_person', 'either')
        and s.lat is not null and l.lat is not null
        and public.distance_miles(s.lat, s.lng, l.lat, l.lng) <= s.radius_miles
      )
    )
    and (
      cardinality(l.time_slots) = 0
      or 'flexible' = any (l.time_slots)
      or cardinality(s.available_slots) = 0
      or l.time_slots && s.available_slots
    )
    and extract(year from age(dob)) between l.min_age and coalesce(l.max_age, 200)
$$;

-- Returns the risk flags for a listing. Any flag sends it to manual review.
create function public.compute_listing_flags(l public.listings)
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare
  v_flags text[] := '{}';
  v_text text := coalesce(l.title, '') || ' ' || coalesce(l.description, '') || ' '
                 || coalesce(l.requirements, '') || ' ' || coalesce(l.address_note, '');
  v_kw record;
  v_hourly numeric;
  v_cfg public.app_config;
begin
  select * into v_cfg from public.app_config where id;

  for v_kw in select k.pattern, k.flag from public.moderation_keywords k where k.active loop
    if v_text ~* v_kw.pattern and not (v_kw.flag = any (v_flags)) then
      v_flags := array_append(v_flags, v_kw.flag);
    end if;
  end loop;

  -- Contact details belong in the app's contact flow, not in the text.
  if v_text ~ '\(?\d{3}\)?[\s.-]*\d{3}[\s.-]*\d{4}' then
    v_flags := array_append(v_flags, 'contact_phone');
  end if;
  if v_text ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' then
    v_flags := array_append(v_flags, 'contact_email');
  end if;
  if v_text ~* '(https?://|www\.)' then
    v_flags := array_append(v_flags, 'link_in_text');
  end if;

  if l.category in ('creative', 'other') then
    v_flags := array_append(v_flags, 'category_needs_review');
  end if;

  if l.category not in ('focus_group', 'research_study', 'clinical_study', 'paid_donation', 'user_testing') then
    v_hourly := l.total_pay_cents / nullif(l.estimated_hours, 0);
    if v_hourly > v_cfg.high_pay_hourly_flag_cents then
      v_flags := array_append(v_flags, 'high_pay');
    end if;
  end if;

  return v_flags;
end;
$$;


-- ---------------------------------------------------------------------
-- 5. Triggers
-- ---------------------------------------------------------------------

create function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger listings_updated_at before update on public.listings
  for each row execute function public.set_updated_at();
create trigger applications_updated_at before update on public.applications
  for each row execute function public.set_updated_at();
create trigger subscriptions_updated_at before update on public.subscriptions
  for each row execute function public.set_updated_at();
create trigger app_config_updated_at before update on public.app_config
  for each row execute function public.set_updated_at();

-- Fills lat/lng from zip on seeker_preferences and listings.
create function public.set_coords_from_zip()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.zip is null then
    new.lat := null;
    new.lng := null;
  else
    select z.lat, z.lng into new.lat, new.lng from public.zip_codes z where z.zip = new.zip;
    if not found then
      raise exception 'UNKNOWN_ZIP' using errcode = 'P0001';
    end if;
  end if;
  if tg_table_name = 'seeker_preferences' then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create trigger seeker_preferences_coords before insert or update on public.seeker_preferences
  for each row execute function public.set_coords_from_zip();
create trigger listings_coords before insert or update of zip on public.listings
  for each row execute function public.set_coords_from_zip();

-- Changing an organization name removes its verified badge.
create function public.profiles_reset_verification()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.org_name is distinct from old.org_name then
    new.org_verified := false;
  end if;
  return new;
end;
$$;

create trigger profiles_reset_verification before update on public.profiles
  for each row execute function public.profiles_reset_verification();

-- Runs when Supabase Auth creates a user. The app validates the same
-- things first; this is the backstop if someone calls the Auth API directly.
-- Expected user_metadata: display_name, birth_date (YYYY-MM-DD),
-- account_type ('individual' | 'organization'), org_name, terms_accepted (true).
create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_dob date;
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  if exists (
    select 1 from public.blocked_identifiers b
    where b.kind = 'email'
      and b.value_hash = encode(sha256(convert_to(lower(coalesce(new.email, '')), 'UTF8')), 'hex')
  ) then
    raise exception 'SIGNUP_BLOCKED' using errcode = '42501';
  end if;

  begin
    v_dob := (v_meta ->> 'birth_date')::date;
  exception when others then
    raise exception 'INVALID_BIRTH_DATE' using errcode = 'P0001';
  end;
  if v_dob is null or v_dob > (current_date - interval '18 years')::date then
    raise exception 'MUST_BE_18' using errcode = 'P0001';
  end if;
  if coalesce((v_meta ->> 'terms_accepted')::boolean, false) is not true then
    raise exception 'TERMS_NOT_ACCEPTED' using errcode = 'P0001';
  end if;

  insert into public.profiles (id, display_name, account_type, org_name)
  values (
    new.id,
    coalesce(nullif(btrim(v_meta ->> 'display_name'), ''), 'New user'),
    coalesce(nullif(v_meta ->> 'account_type', '')::public.account_type, 'individual'),
    nullif(btrim(v_meta ->> 'org_name'), '')
  );
  insert into public.profile_private (user_id, birth_date) values (new.id, v_dob);
  insert into public.seeker_preferences (user_id) values (new.id);
  insert into public.credit_ledger (user_id, delta, reason, note)
  select new.id, c.free_listing_credits, 'signup_bonus', 'Free listings on signup'
  from public.app_config c where c.id and c.free_listing_credits > 0;
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Queues alert emails for matching seekers when a listing goes live.
create function public.enqueue_alerts(p_listing_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
  v_all boolean;
begin
  select c.sponsored_alerts_all_users into v_all from public.app_config c where c.id;

  insert into public.notifications (user_id, listing_id, frequency)
  select s.user_id, l.id, s.notify_frequency
  from public.listings l
  join public.seeker_preferences s
    on s.onboarding_completed and s.notify_email and s.notify_frequency <> 'off'
  join public.profiles p on p.id = s.user_id and p.banned_at is null
  join public.profile_private pp on pp.user_id = s.user_id
  where l.id = p_listing_id
    and l.status = 'approved'
    and l.expires_at > now()
    and s.user_id <> l.poster_id
    and (public.has_active_plus(s.user_id) or (l.is_sponsored and v_all))
    and public.listing_matches_prefs(l, s, pp.birth_date)
  on conflict (user_id, listing_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create function public.listings_after_status_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    perform public.enqueue_alerts(new.id);
  end if;
  return null;
end;
$$;

create trigger listings_enqueue_alerts after insert or update of status on public.listings
  for each row execute function public.listings_after_status_change();

-- Hides a listing (back to pending) once enough different people report it.
create function public.reports_autohide()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_threshold integer;
  v_count integer;
begin
  if new.listing_id is null then
    return new;
  end if;
  select c.report_autohide_threshold into v_threshold from public.app_config c where c.id;
  select count(distinct r.reporter_id) into v_count
  from public.reports r
  where r.listing_id = new.listing_id and r.status = 'open';

  if v_count >= v_threshold then
    update public.listings l set status = 'pending'
    where l.id = new.listing_id and l.status = 'approved';

    insert into public.listing_flags (listing_id, flags) values (new.listing_id, array['reported'])
    on conflict (listing_id) do update
      set flags = case when 'reported' = any (public.listing_flags.flags)
                       then public.listing_flags.flags
                       else array_append(public.listing_flags.flags, 'reported') end,
          updated_at = now();
  end if;
  return new;
end;
$$;

create trigger reports_autohide after insert on public.reports
  for each row execute function public.reports_autohide();

-- Rejects invalid regex patterns before they can break listing submission.
create function public.moderation_keywords_validate()
returns trigger language plpgsql set search_path = '' as $$
begin
  perform '' ~* new.pattern;
  return new;
exception when others then
  raise exception 'INVALID_PATTERN: %', sqlerrm using errcode = 'P0001';
end;
$$;

create trigger moderation_keywords_validate before insert or update on public.moderation_keywords
  for each row execute function public.moderation_keywords_validate();


-- ---------------------------------------------------------------------
-- 6. API functions (called from the app with supabase.rpc)
--    Error messages are stable codes like 'NO_CREDITS'. The app maps
--    them to friendly text in src/lib/errors.ts.
-- ---------------------------------------------------------------------

-- Create a listing. Charges a credit (or uses the Plus allowance, or is free
-- for founding partners), runs moderation, and auto-approves only trusted
-- posters with zero flags. Admins can pass "source":"curated" to post an
-- opportunity found elsewhere (needs external_url and source_org_name).
create function public.submit_listing(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_cfg public.app_config;
  v_sub public.subscriptions;
  v_charge public.charge_source;
  v_source public.listing_source := 'user';
  v_used integer;
  v_row public.listings;
  v_flags text[];
  v_trusted boolean;
  v_live boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.id is null or v_profile.banned_at is not null then
    raise exception 'ACCOUNT_RESTRICTED' using errcode = '42501';
  end if;
  select * into v_cfg from public.app_config where id;

  -- Clinical studies and paid donations come from organizations only.
  if p ->> 'category' in ('clinical_study', 'paid_donation')
     and v_profile.account_type <> 'organization'
     and not (v_profile.role = 'admin' and p ->> 'source' = 'curated') then
    raise exception 'ORG_ONLY_CATEGORY' using errcode = 'P0001';
  end if;

  -- One submission at a time per user, so credits can't be double-spent.
  perform pg_advisory_xact_lock(hashtext('listing_charge:' || v_uid::text));

  if v_profile.role = 'admin' and p ->> 'source' = 'curated' then
    v_source := 'curated';
    v_charge := 'admin';
  elsif v_profile.is_founding_partner then
    v_charge := 'partner';
  else
    select * into v_sub from public.subscriptions s where s.user_id = v_uid;
    if v_sub.status in ('active', 'trialing') and v_sub.current_period_end > now() then
      select count(*) into v_used from public.listings l
      where l.poster_id = v_uid and l.charged_to = 'subscription'
        and l.created_at >= v_sub.current_period_start;
      if v_used < v_cfg.plus_monthly_listings then
        v_charge := 'subscription';
      end if;
    end if;
    if v_charge is null then
      if public.credit_balance(v_uid) >= 1 then
        v_charge := 'credit';
      else
        raise exception 'NO_CREDITS' using errcode = 'P0001';
      end if;
    end if;
  end if;

  insert into public.listings (
    poster_id, source, source_org_name, title, description, category,
    pay_amount_cents, pay_type, pay_method, pay_timing, time_commitment,
    estimated_hours, session_count, location_type, zip, address_note, time_slots,
    starts_on, min_age, max_age, requirements, screening_questions, spots_available,
    external_url, status, charged_to, expires_at
  ) values (
    v_uid,
    v_source,
    case when v_source = 'curated' then nullif(btrim(p ->> 'source_org_name'), '') end,
    btrim(p ->> 'title'),
    btrim(p ->> 'description'),
    (p ->> 'category')::public.listing_category,
    (p ->> 'pay_amount_cents')::integer,
    (p ->> 'pay_type')::public.pay_type,
    (p ->> 'pay_method')::public.pay_method,
    (p ->> 'pay_timing')::public.pay_timing,
    (p ->> 'time_commitment')::public.time_commitment,
    (p ->> 'estimated_hours')::numeric,
    coalesce((p ->> 'session_count')::integer, 1),
    (p ->> 'location_type')::public.location_type,
    nullif(btrim(p ->> 'zip'), ''),
    nullif(btrim(p ->> 'address_note'), ''),
    coalesce(array(select jsonb_array_elements_text(p -> 'time_slots')), '{}'),
    nullif(p ->> 'starts_on', '')::date,
    coalesce((p ->> 'min_age')::integer, 18),
    (p ->> 'max_age')::integer,
    nullif(btrim(p ->> 'requirements'), ''),
    coalesce(p -> 'screening_questions', '[]'::jsonb),
    (p ->> 'spots_available')::integer,
    nullif(btrim(p ->> 'external_url'), ''),
    'pending',
    v_charge,
    now() + make_interval(days => v_cfg.listing_default_days)
  )
  returning * into v_row;

  if v_charge = 'credit' then
    insert into public.credit_ledger (user_id, delta, reason, listing_id)
    values (v_uid, -1, 'listing_post', v_row.id);
  end if;

  v_trusted := v_source = 'curated' or v_profile.trusted_poster
               or v_profile.org_verified or v_profile.is_founding_partner;
  v_flags := public.compute_listing_flags(v_row);
  if v_row.external_url is not null and not v_trusted then
    v_flags := array_append(v_flags, 'external_link');
  end if;
  insert into public.listing_flags (listing_id, flags) values (v_row.id, v_flags);

  v_live := v_trusted and cardinality(v_flags) = 0;
  if v_live then
    update public.listings l set status = 'approved', approved_at = now()
    where l.id = v_row.id;
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'status', case when v_live then 'approved' else 'pending' end,
    'charged_to', v_charge
  );
end;
$$;

-- Edit a listing. Editing never costs a credit. Anything not trusted and
-- clean goes back to pending; a rejected listing can be fixed and resubmitted.
create function public.update_listing(p_listing_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_old public.listings;
  v_row public.listings;
  v_flags text[];
  v_trusted boolean;
  v_live boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.banned_at is not null then
    raise exception 'ACCOUNT_RESTRICTED' using errcode = '42501';
  end if;
  select * into v_old from public.listings where id = p_listing_id for update;
  if v_old.id is null or v_old.poster_id <> v_uid then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_old.status not in ('pending', 'approved', 'rejected') then
    raise exception 'NOT_EDITABLE' using errcode = 'P0001';
  end if;
  if p ->> 'category' in ('clinical_study', 'paid_donation')
     and v_profile.account_type <> 'organization' and v_old.source <> 'curated' then
    raise exception 'ORG_ONLY_CATEGORY' using errcode = 'P0001';
  end if;

  update public.listings l set
    source_org_name = case when l.source = 'curated'
                           then coalesce(nullif(btrim(p ->> 'source_org_name'), ''), l.source_org_name) end,
    title = btrim(p ->> 'title'),
    description = btrim(p ->> 'description'),
    category = (p ->> 'category')::public.listing_category,
    pay_amount_cents = (p ->> 'pay_amount_cents')::integer,
    pay_type = (p ->> 'pay_type')::public.pay_type,
    pay_method = (p ->> 'pay_method')::public.pay_method,
    pay_timing = (p ->> 'pay_timing')::public.pay_timing,
    time_commitment = (p ->> 'time_commitment')::public.time_commitment,
    estimated_hours = (p ->> 'estimated_hours')::numeric,
    session_count = coalesce((p ->> 'session_count')::integer, 1),
    location_type = (p ->> 'location_type')::public.location_type,
    zip = nullif(btrim(p ->> 'zip'), ''),
    address_note = nullif(btrim(p ->> 'address_note'), ''),
    time_slots = coalesce(array(select jsonb_array_elements_text(p -> 'time_slots')), '{}'),
    starts_on = nullif(p ->> 'starts_on', '')::date,
    min_age = coalesce((p ->> 'min_age')::integer, 18),
    max_age = (p ->> 'max_age')::integer,
    requirements = nullif(btrim(p ->> 'requirements'), ''),
    screening_questions = coalesce(p -> 'screening_questions', '[]'::jsonb),
    spots_available = (p ->> 'spots_available')::integer,
    external_url = nullif(btrim(p ->> 'external_url'), ''),
    rejection_reason = null
  where l.id = p_listing_id
  returning * into v_row;

  v_trusted := v_row.source = 'curated' or v_profile.trusted_poster
               or v_profile.org_verified or v_profile.is_founding_partner;
  v_flags := public.compute_listing_flags(v_row);
  if v_row.external_url is not null and not v_trusted then
    v_flags := array_append(v_flags, 'external_link');
  end if;
  insert into public.listing_flags (listing_id, flags) values (v_row.id, v_flags)
  on conflict (listing_id) do update set flags = excluded.flags, updated_at = now();

  v_live := v_trusted and cardinality(v_flags) = 0;
  update public.listings l set
    status = case when v_live then 'approved'::public.listing_status else 'pending'::public.listing_status end,
    approved_at = case when v_live then coalesce(l.approved_at, now()) else null end
  where l.id = p_listing_id;

  return jsonb_build_object('id', p_listing_id, 'status', case when v_live then 'approved' else 'pending' end);
end;
$$;

create function public.mark_listing_filled(p_listing_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.listings l set status = 'filled'
  where l.id = p_listing_id and l.poster_id = auth.uid() and l.status in ('pending', 'approved');
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

-- Checks a seeker's answers against the listing's required answers.
-- The answers are never saved. Only pass/fail is kept.
-- p_answers looks like {"q1": true, "q2": false}.
create function public.submit_screening(p_listing_id uuid, p_answers jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_questions jsonb;
  v_item jsonb;
  v_passed boolean := true;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  select l.screening_questions into v_questions
  from public.listings l
  where l.id = p_listing_id and l.status = 'approved' and l.expires_at > now();
  if v_questions is null then
    raise exception 'LISTING_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if jsonb_array_length(v_questions) = 0 then
    raise exception 'NO_SCREENING' using errcode = 'P0001';
  end if;
  if coalesce(jsonb_typeof(p_answers), '') <> 'object' then
    raise exception 'INVALID_ANSWERS' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(v_questions) loop
    if coalesce(jsonb_typeof(p_answers -> (v_item ->> 'id')), '') <> 'boolean' then
      raise exception 'INCOMPLETE_ANSWERS' using errcode = 'P0001';
    end if;
    if (p_answers ->> (v_item ->> 'id'))::boolean <> (v_item ->> 'required_answer')::boolean then
      v_passed := false;
    end if;
  end loop;

  insert into public.screening_results (user_id, listing_id, passed) values (v_uid, p_listing_id, v_passed)
  on conflict (user_id, listing_id) do update set passed = excluded.passed, answered_at = now();
  return v_passed;
end;
$$;

-- In-app application. Listings with an external_url use the tracked
-- outbound link instead and can't be applied to here.
create function public.apply_to_listing(p_listing_id uuid, p_message text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings;
  v_dob date;
  v_age integer;
  v_passed boolean;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if exists (select 1 from public.profiles p where p.id = v_uid and p.banned_at is not null) then
    raise exception 'ACCOUNT_RESTRICTED' using errcode = '42501';
  end if;
  select * into v_listing from public.listings l
  where l.id = p_listing_id and l.status = 'approved' and l.expires_at > now();
  if v_listing.id is null then
    raise exception 'LISTING_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if v_listing.external_url is not null then
    raise exception 'EXTERNAL_LISTING' using errcode = 'P0001';
  end if;
  if v_listing.poster_id = v_uid then
    raise exception 'OWN_LISTING' using errcode = 'P0001';
  end if;

  select pp.birth_date into v_dob from public.profile_private pp where pp.user_id = v_uid;
  v_age := extract(year from age(v_dob))::integer;
  if v_age < v_listing.min_age or (v_listing.max_age is not null and v_age > v_listing.max_age) then
    raise exception 'NOT_ELIGIBLE' using errcode = 'P0001';
  end if;

  if jsonb_array_length(v_listing.screening_questions) > 0 then
    select sr.passed into v_passed from public.screening_results sr
    where sr.user_id = v_uid and sr.listing_id = p_listing_id;
    if v_passed is null then
      raise exception 'SCREENING_REQUIRED' using errcode = 'P0001';
    end if;
    if not v_passed then
      raise exception 'NOT_ELIGIBLE' using errcode = 'P0001';
    end if;
  end if;

  begin
    insert into public.applications (listing_id, seeker_id, message, prescreen_passed)
    values (p_listing_id, v_uid, nullif(btrim(p_message), ''), v_passed)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'ALREADY_APPLIED' using errcode = 'P0001';
  end;

  insert into public.listing_events (listing_id, event_type, viewer_key)
  values (p_listing_id, 'apply', v_uid::text)
  on conflict do nothing;

  return v_id;
end;
$$;

-- Poster's view of applicants. Email is revealed only after the poster
-- accepts, so a fake listing can't harvest applicant emails.
create function public.get_applicants(p_listing_id uuid)
returns table (
  application_id uuid, seeker_id uuid, seeker_name text, message text,
  status public.application_status, prescreen_passed boolean, email text,
  rating_avg numeric, rating_count bigint, created_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select a.id, a.seeker_id, p.display_name, a.message, a.status, a.prescreen_passed,
         case when a.status in ('accepted', 'completed', 'no_show') then u.email::text end,
         r.rating_avg, coalesce(r.rating_count, 0), a.created_at
  from public.applications a
  join public.listings l on l.id = a.listing_id
  join public.profiles p on p.id = a.seeker_id
  join auth.users u on u.id = a.seeker_id
  left join public.profile_ratings r on r.user_id = a.seeker_id
  where a.listing_id = p_listing_id
    and (l.poster_id = (select auth.uid()) or public.is_admin())
  order by a.created_at
$$;

-- Seeker's view of their applications, including filled or expired
-- listings. The poster's email appears once the seeker is accepted.
create function public.get_my_applications()
returns table (
  application_id uuid, listing_id uuid, listing_title text,
  listing_status public.listing_status, category public.listing_category,
  poster_id uuid, poster_name text, poster_email text,
  status public.application_status, prescreen_passed boolean,
  created_at timestamptz, updated_at timestamptz, can_review boolean
)
language sql stable security definer set search_path = '' as $$
  select a.id, l.id, l.title, l.status, l.category,
         l.poster_id, coalesce(l.source_org_name, p.org_name, p.display_name),
         case when a.status in ('accepted', 'completed') then u.email::text end,
         a.status, a.prescreen_passed, a.created_at, a.updated_at,
         a.status = 'completed' and not exists (
           select 1 from public.reviews rv
           where rv.application_id = a.id and rv.reviewer_id = (select auth.uid())
         )
  from public.applications a
  join public.listings l on l.id = a.listing_id
  join public.profiles p on p.id = l.poster_id
  join auth.users u on u.id = l.poster_id
  where a.seeker_id = (select auth.uid())
  order by a.created_at desc
$$;

-- Allowed moves:
--   poster: sent -> viewed | accepted | declined
--           viewed -> accepted | declined
--           accepted -> completed | no_show
--   seeker: sent | viewed | accepted -> withdrawn
create function public.set_application_status(p_application_id uuid, p_status public.application_status)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_app public.applications;
  v_poster uuid;
  v_ok boolean := false;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_app from public.applications where id = p_application_id for update;
  if v_app.id is null then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  select l.poster_id into v_poster from public.listings l where l.id = v_app.listing_id;

  if v_uid = v_poster then
    v_ok := (v_app.status = 'sent' and p_status in ('viewed', 'accepted', 'declined'))
         or (v_app.status = 'viewed' and p_status in ('accepted', 'declined'))
         or (v_app.status = 'accepted' and p_status in ('completed', 'no_show'));
  elsif v_uid = v_app.seeker_id then
    v_ok := v_app.status in ('sent', 'viewed', 'accepted') and p_status = 'withdrawn';
  else
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;

  if not v_ok then
    raise exception 'INVALID_TRANSITION' using errcode = 'P0001';
  end if;
  update public.applications set status = p_status where id = p_application_id;
end;
$$;

-- Seekers review posters after "completed". Posters review seekers after
-- "completed" or "no_show".
create function public.leave_review(p_application_id uuid, p_rating integer, p_comment text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_app public.applications;
  v_poster uuid;
  v_reviewee uuid;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_app from public.applications where id = p_application_id;
  if v_app.id is null then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  select l.poster_id into v_poster from public.listings l where l.id = v_app.listing_id;

  if v_uid = v_app.seeker_id and v_app.status = 'completed' then
    v_reviewee := v_poster;
  elsif v_uid = v_poster and v_app.status in ('completed', 'no_show') then
    v_reviewee := v_app.seeker_id;
  else
    raise exception 'REVIEW_NOT_ALLOWED' using errcode = 'P0001';
  end if;

  begin
    insert into public.reviews (application_id, reviewer_id, reviewee_id, rating, comment)
    values (p_application_id, v_uid, v_reviewee, p_rating, nullif(btrim(p_comment), ''))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'ALREADY_REVIEWED' using errcode = 'P0001';
  end;
  return v_id;
end;
$$;

-- Report a listing (the poster is attached automatically) or a user.
create function public.submit_report(
  p_listing_id uuid, p_user_id uuid, p_reason public.report_reason, p_details text default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_target_user uuid := p_user_id;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if exists (select 1 from public.profiles p where p.id = v_uid and p.banned_at is not null) then
    raise exception 'ACCOUNT_RESTRICTED' using errcode = '42501';
  end if;
  if p_listing_id is null and p_user_id is null then
    raise exception 'NO_TARGET' using errcode = 'P0001';
  end if;
  if p_listing_id is not null then
    select l.poster_id into v_target_user from public.listings l where l.id = p_listing_id;
    if not found then
      raise exception 'NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  if v_target_user = v_uid then
    raise exception 'CANNOT_REPORT_SELF' using errcode = 'P0001';
  end if;

  begin
    insert into public.reports (reporter_id, listing_id, reported_user_id, reason, details)
    values (v_uid, p_listing_id, v_target_user, p_reason, nullif(btrim(p_details), ''))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'ALREADY_REPORTED' using errcode = 'P0001';
  end;
  return v_id;
end;
$$;

-- Daily-unique views, clicks and saves for the poster's dashboard.
create function public.get_listing_stats(p_listing_id uuid)
returns table (views bigint, clicks bigint, saves bigint, applications bigint)
language sql stable security definer set search_path = '' as $$
  select
    count(e.id) filter (where e.event_type = 'view'),
    count(e.id) filter (where e.event_type = 'click'),
    count(e.id) filter (where e.event_type = 'save'),
    (select count(*) from public.applications a where a.listing_id = l.id)
  from public.listings l
  left join public.listing_events e on e.listing_id = l.id
  where l.id = p_listing_id
    and (l.poster_id = (select auth.uid()) or public.is_admin())
  group by l.id
$$;

-- Public search. Only approved, unexpired listings. Sponsored listings sort
-- first. p_location: null (any) | 'remote' | 'in_person'.
-- p_sort: 'newest' | 'pay' | 'distance'. Remote listings ignore the radius.
create function public.search_listings(
  p_query text default null,
  p_categories public.listing_category[] default null,
  p_location text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_radius_miles integer default 25,
  p_min_total_pay_cents integer default 0,
  p_commitments public.time_commitment[] default null,
  p_max_hours numeric default null,
  p_slots text[] default null,
  p_sort text default 'newest',
  p_limit integer default 20,
  p_offset integer default 0
)
returns setof public.listing_card
language sql stable set search_path = '' as $$
  with base as (
    select l.*, p.display_name, p.org_name, p.account_type, p.org_verified, p.is_founding_partner,
           case when p_lat is not null and p_lng is not null and l.lat is not null
                then public.distance_miles(p_lat, p_lng, l.lat, l.lng) end as dist
    from public.listings l
    join public.profiles p on p.id = l.poster_id
    where l.status = 'approved'
      and l.expires_at > now()
      and (p_query is null or btrim(p_query) = ''
           or l.title ilike '%' || p_query || '%' or l.description ilike '%' || p_query || '%')
      and (p_categories is null or cardinality(p_categories) = 0 or l.category = any (p_categories))
      and (p_location is null
           or (p_location = 'remote' and l.location_type in ('remote', 'hybrid'))
           or (p_location = 'in_person' and l.location_type in ('in_person', 'hybrid')))
      and l.total_pay_cents >= coalesce(p_min_total_pay_cents, 0)
      and (p_commitments is null or cardinality(p_commitments) = 0 or l.time_commitment = any (p_commitments))
      and (p_max_hours is null or l.estimated_hours <= p_max_hours)
      and (p_slots is null or cardinality(p_slots) = 0 or cardinality(l.time_slots) = 0
           or 'flexible' = any (l.time_slots) or l.time_slots && p_slots)
  ),
  filtered as (
    select * from base b
    where p_lat is null or p_lng is null
       or b.location_type = 'remote'
       or b.dist <= least(greatest(coalesce(p_radius_miles, 25), 1), 100)
  )
  select f.id, f.title, f.category, f.pay_amount_cents, f.pay_type, f.total_pay_cents,
         f.estimated_hours, f.session_count, f.time_commitment, f.location_type, f.zip,
         f.time_slots, f.is_sponsored, f.created_at, f.expires_at, f.poster_id,
         coalesce(f.source_org_name, f.org_name, f.display_name),
         f.account_type = 'organization' or f.source = 'curated',
         f.org_verified or f.is_founding_partner or f.source = 'curated',
         f.dist, null::numeric, count(*) over ()
  from filtered f
  order by f.is_sponsored desc,
           case when p_sort = 'pay' then f.total_pay_cents end desc nulls last,
           case when p_sort = 'distance' then f.dist end asc nulls last,
           f.created_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50)
  offset greatest(coalesce(p_offset, 0), 0)
$$;

-- Plus members only: listings matching the caller's preferences, best
-- matches first. Returns nothing for non-members (the app shows an upsell).
create function public.get_for_you_feed(p_limit integer default 20, p_offset integer default 0)
returns setof public.listing_card
language sql stable security definer set search_path = '' as $$
  with me as (
    select s.*, pp.birth_date
    from public.seeker_preferences s
    join public.profile_private pp on pp.user_id = s.user_id
    where s.user_id = (select auth.uid())
      and (public.has_active_plus(s.user_id) or public.is_admin())
  ),
  matched as (
    select l.*, p.display_name, p.org_name, p.account_type, p.org_verified, p.is_founding_partner,
           case when me.lat is not null and l.lat is not null
                then public.distance_miles(me.lat, me.lng, l.lat, l.lng) end as dist,
           me.interested_categories as my_interests,
           me.available_slots as my_slots
    from me
    join public.listings l on l.status = 'approved' and l.expires_at > now() and l.poster_id <> me.user_id
    join public.profiles p on p.id = l.poster_id
    join public.seeker_preferences s on s.user_id = me.user_id
    where public.listing_matches_prefs(l, s, me.birth_date)
  ),
  scored as (
    select m.*,
           (case when m.category = any (m.my_interests) then 3 else 0 end)
           + (case when m.is_sponsored then 2 else 0 end)
           + (case when m.time_slots && m.my_slots then 1 else 0 end)
           + least(m.total_pay_cents / 5000.0, 4)
           - coalesce(m.dist / 10.0, 0) as score
    from matched m
  )
  select sc.id, sc.title, sc.category, sc.pay_amount_cents, sc.pay_type, sc.total_pay_cents,
         sc.estimated_hours, sc.session_count, sc.time_commitment, sc.location_type, sc.zip,
         sc.time_slots, sc.is_sponsored, sc.created_at, sc.expires_at, sc.poster_id,
         coalesce(sc.source_org_name, sc.org_name, sc.display_name),
         sc.account_type = 'organization' or sc.source = 'curated',
         sc.org_verified or sc.is_founding_partner or sc.source = 'curated',
         sc.dist, round(sc.score::numeric, 2), count(*) over ()
  from scored sc
  order by sc.score desc, sc.created_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50)
  offset greatest(coalesce(p_offset, 0), 0)
$$;

-- How many live listings match the caller (any plan). Powers the
-- "12 gigs match you" upsell for free users.
create function public.count_my_matches()
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer
  from public.seeker_preferences s
  join public.profile_private pp on pp.user_id = s.user_id
  join public.listings l on l.status = 'approved' and l.expires_at > now() and l.poster_id <> s.user_id
  where s.user_id = (select auth.uid())
    and public.listing_matches_prefs(l, s, pp.birth_date)
$$;

create function public.my_account_summary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'credit_balance', public.credit_balance(p.id),
    'has_plus', public.has_active_plus(p.id),
    'plan_status', s.status,
    'current_period_end', s.current_period_end,
    'cancel_at_period_end', coalesce(s.cancel_at_period_end, false),
    'plus_listings_used', (
      select count(*) from public.listings l
      where l.poster_id = p.id and l.charged_to = 'subscription'
        and s.current_period_start is not null and l.created_at >= s.current_period_start
    ),
    'plus_listings_limit', c.plus_monthly_listings,
    'is_founding_partner', p.is_founding_partner,
    'is_admin', p.role = 'admin',
    'banned', p.banned_at is not null
  )
  from public.profiles p
  cross join public.app_config c
  left join public.subscriptions s on s.user_id = p.id
  where p.id = (select auth.uid()) and c.id
$$;

-- ---- Admin functions (each checks is_admin() and writes the audit log) ----

-- p_decision: 'approve' | 'reject' | 'remove'. A reason is required for
-- reject and remove, and the poster sees it.
create function public.admin_review_listing(p_listing_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_decision in ('reject', 'remove') and nullif(btrim(p_reason), '') is null then
    raise exception 'REASON_REQUIRED' using errcode = 'P0001';
  end if;

  if p_decision = 'approve' then
    update public.listings set status = 'approved', approved_at = now(), approved_by = v_uid,
                               rejection_reason = null
    where id = p_listing_id and status in ('pending', 'rejected', 'removed');
    -- Clear open reports so the listing isn't instantly re-hidden.
    update public.reports set status = 'dismissed', resolved_by = v_uid, resolved_at = now(),
                              resolution_note = 'Listing approved after review'
    where listing_id = p_listing_id and status = 'open';
  elsif p_decision = 'reject' then
    update public.listings set status = 'rejected', rejection_reason = btrim(p_reason)
    where id = p_listing_id and status = 'pending';
  elsif p_decision = 'remove' then
    update public.listings set status = 'removed', rejection_reason = btrim(p_reason)
    where id = p_listing_id and status in ('pending', 'approved', 'filled');
  else
    raise exception 'INVALID_DECISION' using errcode = 'P0001';
  end if;

  if not found then
    raise exception 'INVALID_TRANSITION' using errcode = 'P0001';
  end if;

  insert into public.moderation_actions (admin_id, target_type, target_id, action, reason)
  values (v_uid, 'listing', p_listing_id::text, p_decision, p_reason);
end;
$$;

create function public.admin_set_sponsored(p_listing_id uuid, p_value boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.listings set is_sponsored = p_value where id = p_listing_id;
  insert into public.moderation_actions (admin_id, target_type, target_id, action)
  values (auth.uid(), 'listing', p_listing_id::text, case when p_value then 'sponsor' else 'unsponsor' end);
end;
$$;

-- p_status: 'actioned' | 'dismissed'
create function public.admin_resolve_report(p_report_id uuid, p_status public.report_status, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status = 'open' then
    raise exception 'INVALID_DECISION' using errcode = 'P0001';
  end if;
  update public.reports set status = p_status, resolved_by = auth.uid(), resolved_at = now(),
                            resolution_note = p_note
  where id = p_report_id and status = 'open';
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'report', p_report_id::text, p_status::text, p_note);
end;
$$;

-- p_changes keys (all optional): banned, trusted_poster, org_verified,
-- is_founding_partner (booleans), reason (text).
-- Banning removes the user's live listings and blocks their email from
-- signing up again. The app ALSO bans them in Supabase Auth so their
-- session stops working (see BUILD_PLAN Phase 6).
create function public.admin_update_user(p_user_id uuid, p_changes jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_user_id = v_uid and p_changes ? 'banned' then
    raise exception 'CANNOT_BAN_SELF' using errcode = 'P0001';
  end if;

  if p_changes ? 'trusted_poster' then
    update public.profiles set trusted_poster = (p_changes ->> 'trusted_poster')::boolean where id = p_user_id;
  end if;
  if p_changes ? 'org_verified' then
    update public.profiles set org_verified = (p_changes ->> 'org_verified')::boolean where id = p_user_id;
  end if;
  if p_changes ? 'is_founding_partner' then
    update public.profiles set is_founding_partner = (p_changes ->> 'is_founding_partner')::boolean
    where id = p_user_id;
  end if;

  if p_changes ? 'banned' then
    select encode(sha256(convert_to(lower(u.email), 'UTF8')), 'hex') into v_hash
    from auth.users u where u.id = p_user_id;

    if (p_changes ->> 'banned')::boolean then
      update public.profiles set banned_at = now(), trusted_poster = false where id = p_user_id;
      update public.listings set status = 'removed', rejection_reason = 'Account suspended'
      where poster_id = p_user_id and status in ('pending', 'approved');
      if v_hash is not null then
        insert into public.blocked_identifiers (kind, value_hash, reason)
        values ('email', v_hash, p_changes ->> 'reason')
        on conflict do nothing;
      end if;
    else
      update public.profiles set banned_at = null where id = p_user_id;
      if v_hash is not null then
        delete from public.blocked_identifiers where kind = 'email' and value_hash = v_hash;
      end if;
    end if;
  end if;

  insert into public.moderation_actions (admin_id, target_type, target_id, action, reason)
  values (v_uid, 'user', p_user_id::text, (p_changes - 'reason')::text, p_changes ->> 'reason');
end;
$$;

create function public.admin_adjust_credits(p_user_id uuid, p_delta integer, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if nullif(btrim(p_note), '') is null then
    raise exception 'REASON_REQUIRED' using errcode = 'P0001';
  end if;
  insert into public.credit_ledger (user_id, delta, reason, note)
  values (p_user_id, p_delta, case when p_delta > 0 then 'refund' else 'admin_adjust' end, p_note);
  insert into public.moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'credits', p_user_id::text, 'adjust ' || p_delta, p_note);
end;
$$;

-- ---- Server-only functions (secret key only; never callable by users) ----

create function public.track_listing_event(p_listing_id uuid, p_type public.listing_event_type, p_viewer_key text)
returns void language sql security definer set search_path = '' as $$
  insert into public.listing_events (listing_id, event_type, viewer_key)
  values (p_listing_id, p_type, left(p_viewer_key, 64))
  on conflict do nothing
$$;

-- Atomically claims a batch of queued alerts for sending.
create function public.claim_notifications(p_frequency public.notify_frequency, p_limit integer default 100)
returns setof public.notifications language sql security definer set search_path = '' as $$
  update public.notifications n set status = 'sending'
  where n.id in (
    select q.id from public.notifications q
    where q.status = 'queued' and q.frequency = p_frequency
    order by q.created_at
    limit p_limit
    for update skip locked
  )
  returning n.*
$$;

create function public.expire_listings()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  update public.listings set status = 'expired'
  where status in ('approved', 'pending') and expires_at <= now();
  get diagnostics v_count = row_count;
  delete from public.rate_limits where window_start < now() - interval '1 day';
  return v_count;
end;
$$;

-- Returns true if the action is allowed, false if the limit is hit.
-- Example: rate_limit_hit('post:' || user_id, 5, 3600) = 5 posts per hour.
create function public.rate_limit_hit(p_key text, p_max integer, p_window_seconds integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_count integer;
begin
  insert into public.rate_limits as r (key, window_start, count)
  values (p_key, v_window, 1)
  on conflict (key, window_start) do update set count = r.count + 1
  returning r.count into v_count;
  return v_count <= p_max;
end;
$$;


-- ---------------------------------------------------------------------
-- 7. Row Level Security
-- ---------------------------------------------------------------------
alter table public.app_config enable row level security;
alter table public.zip_codes enable row level security;
alter table public.profiles enable row level security;
alter table public.profile_private enable row level security;
alter table public.seeker_preferences enable row level security;
alter table public.listings enable row level security;
alter table public.listing_flags enable row level security;
alter table public.screening_results enable row level security;
alter table public.applications enable row level security;
alter table public.reviews enable row level security;
alter table public.reports enable row level security;
alter table public.saved_listings enable row level security;
alter table public.listing_events enable row level security;
alter table public.credit_ledger enable row level security;
alter table public.subscriptions enable row level security;
alter table public.stripe_events enable row level security;
alter table public.notifications enable row level security;
alter table public.moderation_keywords enable row level security;
alter table public.moderation_actions enable row level security;
alter table public.blocked_identifiers enable row level security;
alter table public.rate_limits enable row level security;

create policy "config is public" on public.app_config for select using (true);
create policy "admins edit config" on public.app_config for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy "zips are public" on public.zip_codes for select using (true);

create policy "profiles are public" on public.profiles for select using (true);
create policy "users edit own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "users read own private profile" on public.profile_private for select to authenticated
  using (user_id = (select auth.uid()));

create policy "users read own prefs" on public.seeker_preferences for select to authenticated
  using (user_id = (select auth.uid()));
create policy "users edit own prefs" on public.seeker_preferences for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "live listings are public; posters and admins see their own" on public.listings for select
  using (
    (status = 'approved' and expires_at > now())
    or poster_id = (select auth.uid())
    or public.is_admin()
  );

create policy "admins read flags" on public.listing_flags for select to authenticated
  using (public.is_admin());

create policy "users read own screening results" on public.screening_results for select to authenticated
  using (user_id = (select auth.uid()));
create policy "users delete own screening results" on public.screening_results for delete to authenticated
  using (user_id = (select auth.uid()));

create policy "seekers, posters and admins read applications" on public.applications for select to authenticated
  using (seeker_id = (select auth.uid()) or public.owns_listing(listing_id) or public.is_admin());

create policy "reviews are public" on public.reviews for select using (true);

create policy "users read own reports; admins read all" on public.reports for select to authenticated
  using (reporter_id = (select auth.uid()) or public.is_admin());

create policy "users read own saved" on public.saved_listings for select to authenticated
  using (user_id = (select auth.uid()));
create policy "users save visible listings" on public.saved_listings for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.listings l where l.id = listing_id)
  );
create policy "users unsave" on public.saved_listings for delete to authenticated
  using (user_id = (select auth.uid()));

create policy "users read own credits; admins read all" on public.credit_ledger for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());

create policy "users read own subscription" on public.subscriptions for select to authenticated
  using (user_id = (select auth.uid()));

create policy "users read own notifications" on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

create policy "admins manage keywords" on public.moderation_keywords for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy "admins read audit log" on public.moderation_actions for select to authenticated
  using (public.is_admin());

-- listing_events, stripe_events, blocked_identifiers, rate_limits:
-- RLS on with no policies = no access except the server's secret key.


-- ---------------------------------------------------------------------
-- 8. Privileges
--    Start from nothing, then grant exactly what the app needs.
--    New tables and functions in later migrations need explicit grants too.
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- Reads (RLS still decides which rows)
grant select on public.app_config, public.zip_codes, public.profiles, public.listings,
                public.reviews, public.profile_ratings
  to anon, authenticated;
grant select on public.profile_private, public.seeker_preferences, public.listing_flags,
                public.screening_results, public.applications, public.reports,
                public.saved_listings, public.credit_ledger, public.subscriptions,
                public.notifications, public.moderation_keywords, public.moderation_actions
  to authenticated;

-- Direct writes users are allowed to make
grant update (display_name, org_name) on public.profiles to authenticated;
grant update (interested_categories, excluded_categories, available_slots, min_total_pay_cents,
              max_hours, location_pref, zip, radius_miles, has_transport, notify_email,
              notify_frequency, onboarding_completed)
  on public.seeker_preferences to authenticated;
grant insert, delete on public.saved_listings to authenticated;
grant delete on public.screening_results to authenticated;

-- Admin-only writes (RLS limits these to admins)
grant insert, update, delete on public.moderation_keywords to authenticated;
grant update (free_listing_credits, plus_monthly_listings, listing_default_days,
              report_autohide_threshold, high_pay_hourly_flag_cents, sponsored_alerts_all_users)
  on public.app_config to authenticated;

-- Functions referenced by policies and CHECK constraints
grant execute on function public.is_admin(), public.owns_listing(uuid),
                          public.valid_time_slots(text[]), public.valid_screening_questions(jsonb),
                          public.distance_miles(double precision, double precision, double precision, double precision)
  to anon, authenticated;

-- Public API
grant execute on function public.search_listings(text, public.listing_category[], text, double precision,
  double precision, integer, integer, public.time_commitment[], numeric, text[], text, integer, integer)
  to anon, authenticated;

-- Signed-in API
grant execute on function
  public.submit_listing(jsonb),
  public.update_listing(uuid, jsonb),
  public.mark_listing_filled(uuid),
  public.submit_screening(uuid, jsonb),
  public.apply_to_listing(uuid, text),
  public.get_applicants(uuid),
  public.get_my_applications(),
  public.set_application_status(uuid, public.application_status),
  public.leave_review(uuid, integer, text),
  public.submit_report(uuid, uuid, public.report_reason, text),
  public.get_listing_stats(uuid),
  public.get_for_you_feed(integer, integer),
  public.count_my_matches(),
  public.my_account_summary(),
  public.admin_review_listing(uuid, text, text),
  public.admin_set_sponsored(uuid, boolean),
  public.admin_resolve_report(uuid, public.report_status, text),
  public.admin_update_user(uuid, jsonb),
  public.admin_adjust_credits(uuid, integer, text)
  to authenticated;

-- Server-only (secret key)
grant execute on function
  public.track_listing_event(uuid, public.listing_event_type, text),
  public.claim_notifications(public.notify_frequency, integer),
  public.expire_listings(),
  public.rate_limit_hit(text, integer, integer),
  public.enqueue_alerts(uuid)
  to service_role;


-- ---------------------------------------------------------------------
-- 9. Starting data
-- ---------------------------------------------------------------------
insert into public.app_config default values;

-- Starter moderation rules. Admins can edit these in the admin panel.
-- A match never auto-rejects; it only sends the listing to manual review.
insert into public.moderation_keywords (pattern, flag) values
  ('\m(for sale|selling|sell my|obo)\M', 'sales'),
  ('\m(security deposit|deposit (is )?required|pay (a|an|the) (deposit|fee)|upfront (fee|payment|cost)|starter kit|registration fee|training fee)\M', 'upfront_payment'),
  ('\m(buy|purchase)\M.{0,30}\mgift ?cards?\M', 'gift_card_scam'),
  ('\m(cashier''?s check|money order|wire transfer|western union|moneygram|mobile deposit)\M', 'payment_scam'),
  ('\m(crypto|bitcoin|btc|usdt|ethereum|wallet address)\M', 'crypto'),
  ('\m(reship|re-ship|forward(ing)? (the |your )?packages?|receive packages?|package handler|parcel)\M', 'reshipping'),
  ('\m(sugar (daddy|baby|mommy|momma)|companionship|escort|date night|girlfriend experience)\M', 'companionship'),
  ('\m(massage|body rub)\M', 'massage'),
  ('\m(telegram|whatsapp|kik|signal me|text me|dm me)\M', 'off_platform_contact'),
  ('\m(easy money|quick cash|get rich)\M', 'too_good');
