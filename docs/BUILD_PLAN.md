# Build Plan: Side Hustle App (working name)

Prototype spec for an AI coding agent working in Antigravity. Read `AGENTS.md` first; its rules
apply everywhere. Build only the phase you're asked to build (§15).

App name: read from `NEXT_PUBLIC_APP_NAME` (default `"Side Hustle App"`). Never hard-code it.

---

## 1. Product summary

College students open the app when they have a few free hours and want to earn money. They find
paid focus groups, research studies, paid donations (like plasma), online user testing and odd
jobs near them or remote. Anyone 18+ can also post a gig ("help me move a couch"). Organizations
(research labs, plasma centers, market research firms) post studies and recruiting listings.

**Who uses it**

| Role | What they do |
|---|---|
| Seeker (free) | Browses and searches, applies, saves, reviews. Sees ads. 3 free listings (one time). |
| Seeker (Plus, $5/mo) | Everything free does, plus the For You matched feed, email alerts, no ads, and 20 listings each billing period. |
| Individual poster | Any signed-in user. Posts odd jobs. Manages applicants. |
| Organization poster | Account type "organization" with an org name. The only accounts that can post clinical studies and paid donations. Can be marked verified. |
| Founding partner | Organization that posts free (set by an admin). |
| Admin | The three founders. Moderates listings, reports and users. Posts curated listings that link out. |

**The core loop:** sign up → quick preferences → browse or see matches → open listing → apply in-app
(or continue to the organization's sign-up page) → poster accepts → both get each other's email →
gig happens → both leave reviews.

---

## 2. Decisions already made (don't change without asking)

- Web app only (mobile-first responsive). No native app.
- No money moves between posters and workers through the app. Posters pay workers directly. The
  listing must say how and when.
- In-app contact flow: apply with a short message. Emails are revealed to both sides only after
  the poster accepts. No in-app chat.
- Listings with an `external_url` (organizations and curated listings) send people to the
  organization's own sign-up page through `/go/[id]` instead of applying in-app.
- Every new listing goes to a moderation queue unless the poster is trusted, verified or a
  founding partner AND the listing trips zero flags.
- Clinical studies and paid donations can only be posted by organization accounts (enforced in the database).
- No health questions at signup or in preferences. Listing-specific yes/no screening questions keep only pass/fail.
- Childcare and babysitting are not offered as a category at launch (child safety risk; some states
  regulate babysitting placement services).
- 18+ only, enforced at signup with a neutral birth-date question and again in the database.
- Alerts are email only in the prototype (SMS later, if ever).
- Ads are placeholder "house ads" only in the prototype. No ad network scripts.
- Pricing numbers the database enforces (3 free listings, 20 per Plus period) live in the
  `app_config` table. Prices live in Stripe.

---

## 3. Stack

| Layer | Choice | Notes |
|---|---|---|
| Framework | Next.js 16, App Router, TypeScript strict | `npx create-next-app@latest` with `src/` dir, Tailwind, ESLint, App Router, Turbopack |
| UI | Tailwind CSS v4, shadcn/ui, lucide-react icons, sonner toasts | `next/font` for fonts (self-hosted) |
| Database and auth | Supabase: Postgres, Auth (email + password), Row Level Security | `@supabase/supabase-js`, `@supabase/ssr` |
| Local database | Supabase CLI + Docker Desktop | `npx supabase init`, `npx supabase start` |
| Forms and validation | Zod, react-hook-form, @hookform/resolvers | One shared Zod schema per form, used on client and server |
| Payments | Stripe Checkout (hosted), Customer Portal, webhooks | Test mode only in the prototype. Stripe CLI for local webhooks |
| Email | Resend + React Email | `EMAIL_MODE=log` in dev writes emails to the console and `.emails/` |
| Tests | Vitest (unit + database integration), Playwright (end-to-end) | |
| Runtime | Node.js 22 LTS, npm | |

**Environment variables** (`.env.example` is committed, `.env.local` is not):

```bash
NEXT_PUBLIC_APP_NAME="Side Hustle App"
NEXT_PUBLIC_SITE_URL=http://localhost:3000

# From `npx supabase status`. Newer Supabase versions call these the "publishable" and
# "secret" keys; older versions call them the "anon" and "service_role" keys.
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=
SUPABASE_SECRET_KEY=                # server only, never NEXT_PUBLIC_

STRIPE_SECRET_KEY=                  # sk_test_...
STRIPE_WEBHOOK_SECRET=              # whsec_... printed by `stripe listen`

RESEND_API_KEY=                     # only needed when EMAIL_MODE=resend
EMAIL_FROM="Side Hustle App <alerts@example.com>"
EMAIL_MODE=log                      # log | resend

CRON_SECRET=                        # long random string
UNSUBSCRIBE_SECRET=                 # long random string, signs one-click unsubscribe links
SEED_CENTER_ZIP=10001               # seed listings are placed around this ZIP
```

Validate env vars at startup in `src/lib/env.ts` with Zod (separate server and client schemas) so
a missing key fails loudly.

---

## 4. Project structure and conventions

```
.
├── AGENTS.md
├── docs/  BUILD_PLAN.md · schema.sql · schema_test.sql · PROGRESS.md
├── supabase/  config.toml · migrations/
├── scripts/   seed.ts · load-zips.ts · stripe-setup.ts
├── data/      (gitignored) Census ZIP file
├── tests/     db/*.test.ts · e2e/*.spec.ts
└── src/
    ├── proxy.ts               session refresh + route guards (Next 16's name for middleware.ts)
    ├── app/
    │   ├── (public)/          landing, listings, listing detail, profiles, pricing, safety, rules, legal
    │   ├── (auth)/            login, signup, check-email, forgot/reset password, suspended
    │   ├── auth/confirm/route.ts
    │   ├── (app)/             onboarding, for-you, saved, applications, settings, post, dashboard
    │   ├── admin/             admin panel (own layout with server-side admin check)
    │   ├── go/[id]/route.ts   tracked outbound link
    │   ├── unsubscribe/route.ts
    │   └── api/  stripe/webhook/route.ts · cron/alerts/route.ts · cron/daily/route.ts
    ├── components/  ui/ (shadcn) · listings/ · forms/ · layout/ · admin/ · billing/
    ├── emails/      React Email templates
    └── lib/
        ├── supabase/  client.ts · server.ts · admin.ts
        ├── validation/  listing.ts · auth.ts · preferences.ts · report.ts · review.ts
        ├── constants.ts   categories, time slots, labels, flag explanations
        ├── pricing.ts     plan names, prices for display, Stripe lookup keys
        ├── format.ts      formatMoney, formatHours, effectiveHourly, payBreakdown, distance
        ├── errors.ts      database error code -> friendly message
        ├── auth.ts        requireUser(), requireAdmin(), getAccountSummary()
        ├── rate-limit.ts  wraps rate_limit_hit
        ├── events.ts      trackListingEvent()
        ├── email.ts       sendEmail() honoring EMAIL_MODE
        ├── stripe.ts
        ├── env.ts
        └── database.types.ts (generated)
```

**The three Supabase clients**

| File | Key | Who it acts as | Use it for |
|---|---|---|---|
| `lib/supabase/client.ts` | publishable | the signed-in user (browser) | rare: client-only interactions |
| `lib/supabase/server.ts` | publishable + cookies | the signed-in user | all Server Components, Server Actions, route handlers by default |
| `lib/supabase/admin.ts` | secret | bypasses RLS | only the cases in AGENTS.md security rule 3 |

Follow Supabase's current "server-side auth for Next.js" guide for `@supabase/ssr` cookie handling
and the session refresh in `src/proxy.ts`. If the installed Next.js version still expects
`middleware.ts`, use that name instead.

**Route guards in `src/proxy.ts`**
- Refresh the Supabase session on every request.
- Set a `vid` cookie (random UUID, httpOnly, sameSite=lax, 1 year) if missing. It's the anonymous
  viewer key for listing view counts.
- Signed-out users hitting `/onboarding`, `/for-you`, `/saved`, `/applications`, `/settings/**`,
  `/post/**`, `/dashboard/**` or `/admin/**` go to `/login?next=<path>`.
- Admin and banned checks happen in layouts (they need the database), not in the proxy.

**Server Action pattern** (every mutation)
1. Parse input with the shared Zod schema. On failure, return field errors.
2. `const user = await requireUser()`, which redirects to login if signed out.
3. Rate-limit where §9 says to.
4. Call the RPC with the user's server client.
5. On error, map the code with `errors.ts`.
6. `revalidatePath(...)` and return `{ ok: true, data }`.

**Database error codes → messages** (`src/lib/errors.ts`). Match on the error message text.

| Code | Message shown |
|---|---|
| NOT_AUTHENTICATED | Please log in to continue. |
| ACCOUNT_RESTRICTED | Your account can't do this right now. Contact support if you think this is a mistake. |
| NO_CREDITS | You're out of listings. Buy a pack or go Plus to post more. |
| ORG_ONLY_CATEGORY | Only organization accounts can post clinical studies and paid donations. |
| NOT_FOUND | We couldn't find that. It may have been removed. |
| NOT_EDITABLE | This listing can't be edited anymore. |
| LISTING_UNAVAILABLE | This listing isn't available anymore. |
| EXTERNAL_LISTING | Sign up for this one on the organization's site. |
| OWN_LISTING | You can't apply to your own listing. |
| NOT_ELIGIBLE | Based on the requirements, this one isn't a match for you. |
| SCREENING_REQUIRED | Answer the quick eligibility questions first. |
| ALREADY_APPLIED | You've already applied to this one. |
| INVALID_TRANSITION | That change isn't possible right now. Refresh and try again. |
| REVIEW_NOT_ALLOWED | You can leave a review once the gig is marked completed. |
| ALREADY_REVIEWED | You've already reviewed this gig. |
| ALREADY_REPORTED | Thanks, we already have your report for this listing. |
| CANNOT_REPORT_SELF | You can't report yourself. |
| UNKNOWN_ZIP | We don't recognize that ZIP code. |
| INCOMPLETE_ANSWERS / INVALID_ANSWERS / NO_SCREENING | Please answer every question. |
| FORBIDDEN | You don't have access to that. |
| REASON_REQUIRED | Please add a reason. |
| INVALID_PATTERN | That pattern isn't a valid regular expression. |
| CANNOT_BAN_SELF | You can't ban your own account. |
| RATE_LIMITED (app-side) | You're doing that too fast. Try again in a few minutes. |
| anything else | Something went wrong. Please try again. (Log the code server-side, without user data.) |

Signup errors from the auth trigger (MUST_BE_18, TERMS_NOT_ACCEPTED, SIGNUP_BLOCKED) surface from
Supabase as a generic "Database error saving new user". The signup action validates everything
first, so users should never reach that. If it happens, show "We couldn't create an account with
these details."

---

## 5. Data model and business rules

`docs/schema.sql` is complete and tested. Copy it unchanged as the first migration. Summary:

| Table | Holds | Who can read | Who can write |
|---|---|---|---|
| app_config | numbers the DB enforces (free credits, Plus allowance, expiry days, report threshold, high-pay flag, sponsored alert setting) | everyone | admins (update) |
| zip_codes | ZIP → lat/lng | everyone | scripts (secret key) |
| profiles | public profile (name, account type, org name, badges, role, banned_at) | everyone | owner: display_name, org_name only |
| profile_private | birth date, terms accepted time | owner | nobody (signup trigger) |
| seeker_preferences | interests, exclusions, availability, pay floor, location, alert settings | owner | owner (lat/lng set by trigger) |
| listings | the gigs | live ones: everyone. Own: poster. All: admin | RPCs only |
| listing_flags | moderation flags | admins | RPCs/triggers |
| screening_results | pass/fail per user per listing | owner | RPC; owner can delete |
| applications | seeker → listing | seeker, listing owner, admin | RPCs |
| reviews | ratings 1–5 with optional comment | everyone | RPC |
| reports | reports on listings/users | reporter, admins | RPC |
| saved_listings | bookmarks | owner | owner |
| listing_events | daily-unique views, clicks, saves, applies | nobody directly (stats RPC) | server only |
| credit_ledger | +/- listing credits | owner, admins | RPCs, webhook |
| subscriptions | Stripe customer and subscription state | owner | webhook only |
| stripe_events | processed webhook ids | nobody | webhook |
| notifications | alert email queue | owner | triggers, cron |
| moderation_keywords | regex → flag rules | admins | admins |
| moderation_actions | audit log | admins | admin RPCs |
| blocked_identifiers | hashed banned emails | nobody | admin RPC |
| rate_limits | counters | nobody | server only |

**RPC functions** (call with `supabase.rpc(name, args)`)

| Function | Caller | Purpose |
|---|---|---|
| search_listings(...) | anyone | filtered and paginated search, returns `listing_card` rows with `total_count` |
| submit_listing(p jsonb) | signed in | create a listing; returns `{id, status, charged_to}` |
| update_listing(id, p jsonb) | owner | edit (free); re-moderates |
| mark_listing_filled(id) | owner | |
| submit_screening(listing_id, answers jsonb) | signed in | returns pass/fail; answers not stored |
| apply_to_listing(listing_id, message) | signed in | |
| get_applicants(listing_id) | owner/admin | email only after accept |
| get_my_applications() | signed in | includes poster email after accept |
| set_application_status(app_id, status) | owner or seeker | see transitions in schema |
| leave_review(app_id, rating, comment) | parties | |
| submit_report(listing_id, user_id, reason, details) | signed in | |
| get_listing_stats(listing_id) | owner/admin | views, clicks, saves, applications |
| get_for_you_feed(limit, offset) | Plus | scored matches (empty for non-Plus) |
| count_my_matches() | signed in | number for the upsell |
| my_account_summary() | signed in | credits, plan, Plus usage, partner, admin, banned |
| admin_review_listing / admin_set_sponsored / admin_resolve_report / admin_update_user / admin_adjust_credits | admin | moderation, all audited |
| track_listing_event / claim_notifications / expire_listings / rate_limit_hit / enqueue_alerts | server (secret key) | jobs |

**Business rules the database already enforces** (the UI must match them, not reimplement them):
- **Charging a listing:** a founding partner posts free. Otherwise, a Plus member uses the period
  allowance (`plus_monthly_listings`). Otherwise it costs 1 credit, and with 0 credits → `NO_CREDITS`.
  Signup grants `free_listing_credits` (3). Edits are free. Rejected listings can be fixed and
  resubmitted for free.
- **Moderation:** `compute_listing_flags` checks admin-editable keyword regexes, phone numbers,
  emails and links in the text, the creative/other categories, and unusually high hourly pay for odd
  jobs. It also flags external links from untrusted posters. Auto-approve only if the poster is
  trusted, verified or a founding partner (or it's an admin curated listing) and there are zero flags.
- **Visibility:** the public sees `approved` listings that haven't expired.
- **Expiry:** listings expire after `listing_default_days` (30). The daily job marks them `expired`.
- **Reports:** once `report_autohide_threshold` (3) different people have open reports on a listing,
  it goes back to `pending` with a `reported` flag. Approving it again dismisses those reports.
- **Bans** remove the user's live listings and block their email from signing up again.
- **Alerts:** when a listing becomes approved, matching Plus members (onboarded, alerts on) are
  queued in `notifications`. Sponsored listings alert free members too only if
  `app_config.sponsored_alerts_all_users` is true.
- **Matching** (`listing_matches_prefs`): interested categories (empty = all), never excluded ones,
  total pay ≥ floor, hours ≤ max, location (remote preference vs. distance within radius), time slot
  overlap (empty or `flexible` = always), and age within the listing's range.
- **Pay math:** `total_pay_cents` is computed. Flat = amount. Hourly = amount × estimated_hours.
  Per session = amount × session_count. `estimated_hours` is the TOTAL time across all sessions.

---

## 6. Constants and display formats (`src/lib/constants.ts`, `src/lib/format.ts`)

**Categories** (enum value → label → group). Group "Studies & research" = first five.

| value | label | notes |
|---|---|---|
| focus_group | Focus groups | |
| research_study | Research studies | no ads on detail page |
| clinical_study | Clinical studies | org-only, disclaimer, no ads |
| paid_donation | Plasma & paid donations | org-only, disclaimer, no ads |
| user_testing | Online user testing | |
| event_staffing | Event staffing | |
| moving_labor | Moving & lifting | |
| tutoring | Tutoring | |
| pet_care | Pet care | |
| yard_work | Yard work | |
| cleaning | Cleaning | |
| errands_delivery | Errands & delivery | |
| tech_help | Tech help | |
| creative | Photo, video & design | always reviewed |
| brand_ambassador | Promo & brand ambassador | |
| other | Other | always reviewed |

**Time slots:** `{mon..sun}_{morning|afternoon|evening|night}` plus `flexible`.
Morning 6am–12pm · Afternoon 12–5pm · Evening 5–10pm · Night 10pm–6am. UI: a 7×4 toggle grid
with presets (Weekdays, Weekends, Evenings, Any time).

**Labels:**
- Pay types: Flat "for the whole gig" · Hourly "/hr" · Per session "per session".
- Pay methods: Cash · Check · Direct deposit · Venmo/PayPal/Zelle-type app · Gift card · Prepaid card · Other.
- Pay timing: Same day · Within a week · Within 30 days · After the study ends.
- Commitment: One session · Multiple visits (n) · Overnight stay · Ongoing.

**Formats:**
- `formatMoney(cents)` → `$75` (no cents when whole), `$12.50`.
- Pay block: big total (`$75`), then `≈ $25/hr`, then the breakdown (`$25/hr × 3 hrs`,
  `$20 × 5 sessions`).
- Time: `~3 hrs total · 1 session`.
- Distance: `2.4 mi away` (one decimal under 10 miles, whole number above). Remote: "Remote".

**Pricing** (`src/lib/pricing.ts`, for display. Stripe is the source of truth for prices.)

| Product | Price | Stripe lookup key | Grants |
|---|---|---|---|
| Plus | $5/month | `plus_monthly` | For You, alerts, no ads, 20 listings per period |
| Listing pack | 5 listings for $6 | `pack_5` | +5 credits (anyone) |
| Plus listing pack | 10 listings for $5 | `plus_pack_10` | +10 credits (Plus members only) |

**Flag explanations for admins:**

| flag | admin sees |
|---|---|
| sales | Mentions selling something |
| upfront_payment | Asks the worker to pay a fee or deposit |
| gift_card_scam | Asks the worker to buy gift cards |
| payment_scam | Mentions checks, money orders or wires (common fake-check scam) |
| crypto | Mentions crypto |
| reshipping | Receiving or forwarding packages (reshipping scam) |
| companionship | Companionship, dating or "sugar" language |
| massage | Massage or body rub |
| off_platform_contact | Pushes contact to other apps |
| too_good | "Easy money" language |
| contact_phone / contact_email / link_in_text | Contact details or links in the text |
| external_link | Untrusted poster added a sign-up link |
| category_needs_review | Category always gets reviewed |
| high_pay | Unusually high hourly pay for this kind of job |
| reported | Hidden after multiple user reports |

---

## 7. Pages and routes

| Route | Access | Purpose |
|---|---|---|
| `/` | public | landing: value prop, how it works, category tiles, latest listings, CTA |
| `/listings` | public | browse and search with filters |
| `/listings/[id]` | public (live) / owner / admin | listing detail |
| `/u/[id]` | public | public profile with badges, rating, reviews, active listings |
| `/pricing` | public | Free vs Plus vs packs |
| `/safety` | public | safety tips and how we moderate |
| `/rules` | public | listing rules (§12) |
| `/how-it-works` | public | for seekers and for posters |
| `/terms`, `/privacy` | public | placeholders with a DRAFT banner |
| `/login`, `/signup`, `/check-email`, `/forgot-password`, `/reset-password` | public | auth |
| `/auth/confirm` | route | email-link token exchange |
| `/suspended` | public | shown to banned users |
| `/onboarding` | signed in | 4-step preferences |
| `/for-you` | signed in | Plus feed, or the upsell with match count |
| `/saved` | signed in | saved listings |
| `/applications` | signed in | my applications |
| `/post/new` | signed in | posting wizard |
| `/dashboard/listings` | signed in | my listings by status |
| `/dashboard/listings/[id]` | owner | applicants and stats |
| `/dashboard/listings/[id]/edit` | owner | edit |
| `/settings` | signed in | profile, preferences, notifications, privacy, delete account |
| `/settings/billing` | signed in | plan, credits, history, buy, manage |
| `/admin` | admin | overview + job buttons |
| `/admin/queue` | admin | pending listings |
| `/admin/reports` | admin | open reports |
| `/admin/users`, `/admin/users/[id]` | admin | user search and actions |
| `/admin/curated/new` | admin | post a curated link-out listing |
| `/admin/keywords` | admin | moderation keyword rules |
| `/admin/settings` | admin | app_config |
| `/admin/audit` | admin | moderation log |
| `/go/[id]` | route | log click, 302 to the listing's stored external_url |
| `/unsubscribe` | route | one-click alert unsubscribe (signed token) |
| `/api/stripe/webhook` | Stripe | billing events |
| `/api/cron/alerts?frequency=instant\|daily` | cron | send alert emails |
| `/api/cron/daily` | cron | expire listings, clean rate limits |

Navigation: on mobile, signed-in users get a bottom tab bar (Browse, For You, Post, Activity,
Account). On desktop, a top bar. "Activity" covers My applications, Saved and My listings.

---

## 8. Feature specs

### 8.1 Signup, login and the age gate
- **Signup fields:** display name; email; password (min 10 chars); birth date as three selects
  (month, day, year), with no mention of an age limit; account type ("I'm here for gigs or posting
  my own" = individual / "I'm posting for an organization" = organization + org name); checkbox
  "I agree to the Terms and Listing Rules" (links).
- **Server action:**
  1. Rate-limit by a sha256 of IP (`signup:<hash>`, 5/hour). Don't store the raw IP.
  2. If the `age_gate` cookie is set, return the blocked state.
  3. Compute age from birth date. Under 18: set `age_gate=blocked` (httpOnly, 30 days) and show
     "Sorry, we can't create an account for you right now." Don't call Supabase and don't store
     anything. The signup page also checks the cookie on load and shows that same message instead of the form.
  4. `supabase.auth.signUp({ email, password, options: { emailRedirectTo: SITE_URL + '/auth/confirm', data: { display_name, birth_date: 'YYYY-MM-DD', account_type, org_name, terms_accepted: true } } })`.
  5. Redirect to `/check-email`.
- **Email confirmation:** turn on email confirmations in `supabase/config.toml` for local
  (`[auth.email] enable_confirmations = true`) and set `site_url` and `additional_redirect_urls` to
  localhost:3000. Follow Supabase's Next.js server-side auth guide: the email link hits
  `/auth/confirm?token_hash=...&type=...`, the route calls `verifyOtp`, then redirects to
  `/onboarding`. Local emails show up in the local inbox URL from `npx supabase status`.
- Login with email and password; `?next=` redirect (only same-site relative paths). Logout. Forgot
  password: `resetPasswordForEmail` with redirect through `/auth/confirm` to `/reset-password`.
- The `(app)` layout calls `my_account_summary()`. If `banned`, sign the user out and redirect to `/suspended`.

### 8.2 Onboarding (`/onboarding`, 4 steps, save after each step)
1. **What are you up for?** Two chip groups: "Interested in" and "Never show me" (categories).
2. **When are you free?** Time slot grid with presets.
3. **Where?** In person / Remote / Either; ZIP (validated against `zip_codes`); radius slider 1–50
   mi (default 15); "I have a car or reliable transit" toggle.
4. **Pay and alerts:** minimum total pay (Any, $25, $50, $100+); max time (Any, 2 hrs, 4 hrs, 8 hrs);
   email alerts on/off with frequency (Instant / Daily digest). Show a note: "Alerts are a Plus perk.
   Your settings are saved for when you upgrade."
- Finish sets `onboarding_completed = true`, then goes to `/for-you` for Plus members or to
  `/listings?mine=1` for free members (filters pre-filled from preferences) with a banner showing
  `count_my_matches()`.
- "Skip for now" is allowed. Prompt again on `/for-you`.
- The same step components are reused in `/settings`.

### 8.3 Browse and search (`/listings`)
- Filters (sheet on mobile, sidebar on desktop) map 1:1 to `search_listings` params: text query,
  categories, Remote / In person / Any, ZIP + radius (defaults to the user's saved ZIP), minimum total
  pay, commitment types, max hours, time slots, sort (Newest, Highest pay, Closest). The state lives
  in the URL query string so results are shareable and survive back/forward.
- Results: listing cards, 20 per page with "Load more" (offset). Show "N results".
- **Card:** category icon and label · title · big total pay + effective hourly · time (`~2 hrs · 1
  session`) · commitment badge · Remote or distance · poster name + verified badge · "Sponsored"
  label when sponsored · Save button (signed in).
- Escape `%` and `_` in the text query before sending.
- Empty state: suggest widening the radius or removing filters, and link to Plus alerts.
- Free users: an `<AdSlot />` after every 8th card (§8.13).

### 8.4 Listing detail (`/listings/[id]`)
- **Sections:** header (title, badges) · pay block (total, hourly, breakdown, **How you get paid**:
  method and timing) · time and place (hours, sessions, slots, start date, Remote or ZIP area +
  distance + area note; "Exact address is shared after you're accepted") · who can do it (age range,
  requirements) · description (plain text, line breaks preserved) · poster card (name, badges,
  member since, rating, link to profile) · safety tips box · Report link.
- **Disclaimers:** the clinical/donation disclaimer (§11) for those categories. For all listings:
  "Pay is set and paid by the poster."
- **Primary action:**
  - Listing has `external_url` → "Continue to sign-up" opens an interstitial ("You're leaving
    {App} for {poster}'s site. Their privacy policy applies.") → `/go/[id]`.
  - Has screening questions → "Check if you qualify" opens the screening dialog (§8.7), then Apply.
  - Otherwise → Apply dialog (optional message, max 1000 chars) → `apply_to_listing`.
  - Signed out → "Log in to apply".
- Owner sees "This is your listing" with Edit / Stats instead. Admin sees status and an
  admin link.
- Log a `view` event server-side (§8.15).
- No ad slot on research, clinical or donation listings.
- `generateMetadata` uses the title, category and pay. Non-public listings return 404 for everyone
  except the owner and admins (RLS handles this).

### 8.5 Posting (`/post/new`, `/dashboard/listings/[id]/edit`)
Five-step wizard with one shared Zod schema (`listingInputSchema`) that mirrors the database
constraints. Draft autosaves to localStorage (wrapped in try/catch).
1. **Basics:** title (8–100), category (individuals don't see clinical/donation; link to /rules),
   description (30–4000) with inline hints: "Don't include phone numbers, emails or links. Applicants
   can contact you after you accept them."
2. **Pay:** amount, pay type, pay method, pay timing (all required). Live preview of total and hourly.
3. **Time and place:** commitment, total estimated hours, number of sessions, time slots or
   Flexible, optional start date, Remote / In person / Hybrid, ZIP (required unless remote), area
   note (max 200, e.g. "Near the student union").
4. **Who can do it:** min age (≥18), optional max age, requirements, optional spots. Organizations
   also get: up to 10 yes/no screening questions with the required answer (label it "This is a
   pre-check. You still confirm eligibility yourself.") and an optional external sign-up link (https
   only).
5. **Review and post:** preview card + detail preview exactly as seekers will see them; cost line
   from `my_account_summary()`:
   - "Free (founding partner)"
   - "Included in Plus (4 of 20 used this period)"
   - "Uses 1 listing credit (2 left)"
   - "You're out of listings": button to `/settings/billing` (until Phase 7, show "Coming soon")
   Checkbox: "This listing follows the Listing Rules." Submit → `submit_listing`.
- **Result screen:** `approved` → "Your listing is live" + link. `pending` → "Submitted for review.
  We usually review within 12 hours."
- **Edit** uses the same wizard and `update_listing`. Warn: "Edits may send your listing back to review."
- Rate limit: 10 submissions per hour per user.

### 8.6 Poster dashboard
- `/dashboard/listings`: tabs Live · In review · Needs changes (rejected, showing
  `rejection_reason`) · Filled/Expired. Each row: status chip, views/clicks/saves/applications
  (`get_listing_stats`), Edit, Mark filled, Applicants.
- `/dashboard/listings/[id]`: stats + applicants from `get_applicants`: name, rating, pre-check
  passed badge, message, status, date. Actions follow the allowed transitions (Mark viewed, Accept,
  Decline; then Completed or No-show). After accepting, show the email with "Reach out to arrange
  details. Never ask applicants for payment or bank logins."
- **Emails:** new applicant → poster; accepted → seeker, including the poster's email; declined →
  seeker (short and kind).

### 8.7 Seeker activity
- **Screening dialog:** consent line first ("Your answers are only used to check this listing's
  requirements and are not saved. We keep only whether you passed."), then yes/no questions →
  `submit_screening`. If they pass, go straight to Apply. If not, show "This one isn't a match. Here
  are similar gigs" with 3 search results in the same category.
- `/applications`: from `get_my_applications()`, grouped Active / Past. Shows status, poster
  contact after acceptance, Withdraw, "Leave a review" when `can_review`, and "Report a problem" (for
  example, "I didn't get paid" opens the report dialog with reason `nonpayment`).
- `/saved`: saved listings that are still live. Save and unsave from cards and detail pages (log a
  `save` event).
- **Reviews:** 1–5 stars + optional comment (max 500) → `leave_review`. Posters review seekers
  from the applicants page.

### 8.8 Reports and safety
- Report dialog on listings and profiles. Reasons with one-line descriptions: Scam or suspicious ·
  Illegal or against the rules · Didn't get paid · Felt unsafe · Inappropriate · Spam · Other.
  Optional details. → `submit_report`. Confirmation: "Thanks. Our team reviews reports within 12
  hours. If you're in danger, call 911."
- Rate limit: 10 reports per hour per user.
- **Safety tips box** (listing pages and `/safety`): Never pay to get a gig · Never buy gift cards or
  forward packages or money for anyone · Don't share bank logins or your SSN before you're hired, and
  only with a real employer · Meet in a public place the first time · Tell a friend where you're going.

### 8.9 Public profile (`/u/[id]`)
Name (org name for organizations), badges (Verified organization, Founding partner, Trusted
poster), member since, average rating and count, latest 20 reviews, active listings. No birth
date, email or account details.

### 8.10 Admin panel (`/admin`)
- The layout requires `my_account_summary().is_admin`, otherwise 404. Every page is server-rendered.
- **Overview:** counts (pending listings, open reports, listings live, new users in 7 days) and job
  buttons: "Send instant alerts", "Send daily digest", "Expire old listings". These call the same
  functions as the cron routes, through admin-only server actions.
- **Queue:** pending listings sorted by number of flags (most first), then oldest. Each item shows the
  full listing preview, flags in plain English (§6), and poster context (account age, account type,
  verified/trusted/partner, approved and rejected counts, open reports against them). Actions:
  Approve · Approve and trust this poster · Reject (reason templates + custom text, which the poster
  sees). Templates: "Includes contact info or links in the text" · "Missing clear pay details" ·
  "Against the Listing Rules" · "Looks like a scam" · "Wrong category".
- **Reports:** open reports grouped by listing or user, with reporter count and reasons. Actions:
  Dismiss · Remove listing (reason) · Ban user.
- **Users:** search by display or org name. Exact email lookup through an admin-only server action
  that uses the secret key after the admin check. User page: badges toggles (trusted, org verified,
  founding partner), ban/unban with reason, credit adjustment with note, listings, reports.
  - **Ban** = `admin_update_user(id, {banned:true, reason})`, then
    `auth.admin.updateUserById(id, { ban_duration: '876000h' })` so their session stops working.
  - **Unban** = the reverse with `ban_duration: 'none'`.
- **Curated listing form:** the posting form plus required `source_org_name` and `external_url`,
  sent as `submit_listing({...payload, source: 'curated'})`.
- **Keywords:** list, add, toggle active, delete. Explain that Postgres uses `\m` and `\M` for word
  boundaries, not `\b`.
- **Settings:** edit `app_config` fields. **Audit log:** latest 200 `moderation_actions`.

### 8.11 Billing (Phase 7)
- `scripts/stripe-setup.ts` (test mode, idempotent): creates the three products and prices with the
  lookup keys from §6 and a Customer Portal configuration that allows cancelling. It prints what it
  created. The app finds prices with `stripe.prices.list({ lookup_keys })`.
- **Server action `startCheckout(kind)`:**
  - `kind` is `plus`, `pack_5` or `plus_pack_10`.
  - Find or create the Stripe customer (metadata `user_id`); upsert `subscriptions.stripe_customer_id`
    with the admin client.
  - `plus` when already Plus → redirect to the Customer Portal. `plus_pack_10` requires Plus.
  - Create a Checkout Session (`mode` subscription or payment) with `client_reference_id = user.id`,
    `metadata { user_id, kind }`, success URL `/settings/billing?success=1`, cancel URL
    `/settings/billing`.
- **Webhook** (`/api/stripe/webhook`, Node runtime):
  1. Read the raw body with `await req.text()` and verify with `stripe.webhooks.constructEvent`.
  2. Insert the event id into `stripe_events`. If it already exists, return 200.
  3. `checkout.session.completed` + payment mode: insert `credit_ledger` (+5 or +10,
     `pack_purchase`, `stripe_checkout_session_id`). Subscription mode: fetch the subscription and upsert.
  4. `customer.subscription.created|updated|deleted`: upsert `subscriptions` by customer (status,
     price_id, period start/end, cancel_at_period_end). In recent Stripe API versions the period dates
     are on the subscription item (`items.data[0].current_period_start/end`). Read them there and fall
     back to the subscription object.
  5. If handling throws, delete the `stripe_events` row and return 500 so Stripe retries.
- **`/settings/billing`:** plan status and renewal or end date, Manage subscription (Portal), credit
  balance, ledger history, buy buttons.
- **`/pricing`:** Free vs Plus cards and the packs. Copy follows §11.
- **Account deletion** cancels any active subscription first (§8.14).

### 8.12 For You and alerts (Phase 8)
- `/for-you`: Plus members get `get_for_you_feed` with a "why this matches" line (category,
  distance, time slot). Non-Plus members get the upsell: "{count_my_matches()} gigs match your
  preferences right now", 2 blurred example cards, and a Go Plus button. Not onboarded → prompt to
  finish onboarding.
- **Sending:** `/api/cron/alerts?frequency=instant|daily` (Bearer `CRON_SECRET`) → claim a batch
  with `claim_notifications` → for each, re-check that the listing is approved and the user is still
  Plus with alerts on (otherwise mark `skipped`) → send → mark `sent` or `failed` with the error.
  - Instant: one email per listing.
  - Daily: group by user, max 10 listings per digest.
- **Email content:** subject "New gig that matches you: {title}". For clinical and donation
  categories, use the generic subject "A new study matches your preferences". Body has the card info
  and a View button, and a footer with why they got it, Manage alerts (`/settings`) and a one-click
  unsubscribe link. Send `List-Unsubscribe` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click`
  headers.
- **`/unsubscribe?u=<user_id>&t=<hmac>`:** verify the HMAC with `UNSUBSCRIBE_SECRET`, set
  `notify_email=false` with the admin client, and show a confirmation (also accept POST for one-click).
- Locally, trigger alerts from the admin job buttons. In production, a scheduler calls the cron
  routes (decided at deploy time).

### 8.13 Ads (placeholder)
`<AdSlot placement="..." />` renders a clearly labeled "Ad" box with a house promo ("Go Plus: no ads
+ instant alerts"). It renders nothing for Plus members and on the pages AGENTS.md lists. No
third-party code. Real ads come later and must be non-personalized/contextual only (pre-launch checklist).

### 8.14 Settings and account deletion (`/settings`)
- **Sections:** Profile (display name, org name; changing org name removes the verified badge) ·
  Preferences (onboarding components) · Notifications · Privacy ("Delete my eligibility check
  results" → delete own `screening_results`) · Danger zone.
- **Delete account:** type DELETE to confirm → server action: cancel any active Stripe
  subscription → `auth.admin.deleteUser(user.id)` (cascades all data) → sign out → goodbye page.
  Birth date is not editable. Show "Contact support to correct your birth date."

### 8.15 Event tracking
- `trackListingEvent(listingId, type)` in `lib/events.ts` calls `track_listing_event` with the admin
  client. `viewer_key` = user id if signed in, otherwise the `vid` cookie. The database dedupes per
  day.
- `view`: on the listing detail server render (skip owner and admins). `click`: in `/go/[id]`.
  `save`: after a save. `apply`: logged by the RPC.
- `/go/[id]`: load the listing with the user's client (respects RLS). If it's missing or has no
  `external_url`, 404. Track the click, then `redirect(listing.external_url)`. Never redirect to
  anything else.

### 8.16 Email sending (`lib/email.ts`)
`sendEmail({ to, subject, react, headers })`:
- `EMAIL_MODE=log`: render to HTML, write `.emails/<timestamp>-<slug>.html` (gitignored), and log
  the subject and recipient domain only.
- `EMAIL_MODE=resend`: send with Resend.

Templates: NewApplicant, ApplicationAccepted, ApplicationDeclined, ListingApproved, ListingRejected
(with reason), AlertInstant, AlertDigest. Auth emails (confirm, reset) are sent by Supabase itself.

---

## 9. Security requirements (checklist, verified in Phase 9)

- [ ] `docs/schema_test.sql` passes on a fresh local database.
- [ ] `tests/db` integration tests pass through the real API. At minimum:
  - anon can't read pending listings, profile_private, flags or events
  - user A can't read B's preferences, private profile, screening results or ledger
  - direct insert/update on listings is denied, as are profile role/badge updates
  - `submit_listing` charges correctly and returns `NO_CREDITS` at zero
  - non-admins get `FORBIDDEN` from admin RPCs
  - applicant email is hidden until accept
- [ ] The secret key appears only in the allowed files (grep for `SUPABASE_SECRET_KEY` and `admin.ts` imports).
- [ ] No `NEXT_PUBLIC_` variable holds a secret. `.env.local` is in `.gitignore`.
- [ ] Every Server Action validates with Zod and calls `requireUser()` (or is intentionally public).
- [ ] Rate limits: signup 5/hr/IP-hash · post 10/hr/user · apply 30/hr/user · report 10/hr/user ·
  checkout 10/hr/user.
- [ ] No `dangerouslySetInnerHTML` anywhere (grep).
- [ ] `/go/[id]` only redirects to the stored URL. `?next=` only accepts relative paths starting
  with `/` and not `//`.
- [ ] The webhook rejects bad signatures. Cron routes reject a missing or wrong secret.
- [ ] Security headers in `next.config` (`headers()`): `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: DENY`,
  `Permissions-Policy: camera=(), microphone=(), geolocation=()`, and a basic Content-Security-Policy
  that allows only self + Supabase + Stripe Checkout redirects (test it doesn't break the app).
- [ ] Logs contain no emails, birth dates, screening answers, tokens or Stripe payloads.
- [ ] `npm audit` has no high or critical issues (or each is documented).
- [ ] Admin accounts use strong passwords. Turn on MFA when deploying.

---

## 10. Design guidelines

- Mobile-first. Most users are on phones between classes. Thumb-reachable primary actions; sticky
  Apply bar on listing detail on mobile.
- Trustworthy and calm, not hype. Plenty of white space, one accent color, neutral grays, a clear
  type scale. Light and dark mode via CSS variables (shadcn theming).
- The card's most important facts, in order: pay, time, where, what. Pay is the largest text.
- Badges are consistent: Verified (check icon), Founding partner, Sponsored (muted label, never
  disguised), Remote, commitment type.
- Every list has loading skeletons, empty states with a next step, and error states with retry.
- Accessibility: real labels on inputs, visible focus rings, 4.5:1 text contrast, everything usable
  by keyboard, dialogs trap focus (shadcn does this), and toasts don't carry essential information alone.

---

## 11. Copy and content rules

- Tagline direction: "Paid gigs that fit between classes." Supporting: "Studies, focus groups and
  quick jobs near you. Many take just a few hours."
- Never: "guaranteed", "guarantee", "make $X this week", "easy money".
- Pay is always "set by the poster". The app "doesn't employ workers or handle gig payments".
- **Clinical/donation disclaimer** (on those listing pages): "We list this opportunity but don't run
  it. The study team or center decides who qualifies and handles your health information under
  their own policies. Ask them anything you're unsure about, and talk to a doctor if you have health
  questions."
- **Screening consent:** see §8.7.
- **External link interstitial:** see §8.4.
- **Plus upsell:** factual ("Get matched automatically and alerted when new gigs fit your
  schedule"), no countdown timers or fake scarcity.
- Terms and Privacy pages: generate a plain-English placeholder outline with a banner: "DRAFT:
  not legal advice. Must be reviewed by a lawyer before launch."

---

## 12. Listing rules (draft for `/rules`, also linked from posting)

**Allowed:** short paid tasks and odd jobs; focus groups and market research; research studies run
by universities or research companies; clinical studies and paid donations posted by organizations;
online user testing; event staffing and promo work.

**Not allowed:**
1. Selling items, or listings that are really ads for a product or service.
2. Anything that requires the worker to pay, buy, deposit or "invest" anything, including starter
   kits and training fees.
3. Receiving, cashing or forwarding money, checks, gift cards or packages for someone else.
4. Crypto payments or crypto "tasks".
5. Companionship, dating, "sugar" arrangements, escorting, massage or body rubs, or any adult content.
6. Childcare and babysitting (not offered at launch).
7. Anything illegal, including drugs, weapons and gambling.
8. Recruiting for MLMs or "build your team" schemes.
9. Asking for SSNs, bank logins or ID photos before hiring.
10. Unpaid "trials" or "tests".
11. Phone numbers, emails or links in the listing text (use the app's contact flow).
12. Listings aimed at anyone under 18.
13. Discrimination based on protected characteristics. Legitimate study eligibility criteria
    posted by research organizations are allowed.

**Posters must:** describe the work and pay truthfully, pay on time as stated, verify age and
eligibility in person, and follow the law.

**What happens:** listings that break the rules are removed. Repeat or serious violations get the
account banned.

---

## 13. Seed data and ZIP codes

**ZIPs (`scripts/load-zips.ts`, `npm run zips:load`)**
- The human downloads the national "ZIP Code Tabulation Areas" Gazetteer file from the Census
  Bureau's Gazetteer Files page into `data/` and unzips it.
- The script reads the tab-delimited file (GEOID, ..., INTPTLAT, INTPTLONG), **trims header names**
  (the last header has trailing spaces), and upserts `zip, lat, lng` in batches of 1000 with the
  admin client.
- Refuse to run if `NEXT_PUBLIC_SUPABASE_URL` isn't localhost/127.0.0.1, unless `--allow-remote` is passed.

**Seed (`scripts/seed.ts`, `npm run seed`)**
- Local only, same guard. Run `zips:load` first (listing and preference ZIPs must exist).
  Idempotent: deletes the seed users by email first (cascades), then recreates everything.
- **Users** (password `Password123!`, local only, created with `auth.admin.createUser` + `email_confirm: true` + user_metadata):

| email | setup |
|---|---|
| admin@example.com | role admin |
| plus@example.com | onboarded, ZIP = SEED_CENTER_ZIP, interests focus_group/research_study/user_testing, instant alerts, active subscription row (fake Stripe ids, period now → +30 days) |
| free@example.com | onboarded, same ZIP, daily alerts |
| newbie@example.com | not onboarded |
| poster@example.com | individual |
| lab@example.com | organization "Northside Psychology Lab", org_verified, founding partner |
| plasma@example.com | organization "Riverbend Plasma Center", org_verified |
| scammer@example.com | individual |

- **Listings** (~40), using ZIPs within 15 miles of SEED_CENTER_ZIP (query `zip_codes` with
  `distance_miles`):
  - 30 approved: direct insert with the admin client (`status='approved'`, `approved_at=now()`, an
    empty `listing_flags` row, `charged_to='admin'`). Mix of categories and pays from $15 to $300,
    6 remote, 3 sponsored, 4 with screening questions, 3 with external URLs (use
    `https://example.com/...`).
  - 5 pending through the real path: sign in as `poster@` and `scammer@` with the publishable key and
    call `submit_listing`, so flags are computed for real. Two normal, three scammy (gift cards,
    reshipping, "text me" + phone number).
  - 2 rejected with reasons, 2 expired, 1 filled.
- **Activity:** free@ applied to 3 listings (one completed with reviews both ways, one accepted, one
  sent), 4 saved, 1 open report from plus@ on a scammy pending listing.
- **Example titles to set the tone:** "60-min focus group: campus dining" ($75 gift card) ·
  "Online memory study, 45 min" ($20) · "New plasma donors: first visit" ($100, ~2 hrs) · "Test a
  banking app prototype on Zoom" ($60, 1 hr) · "Help move a couch, 2 flights" ($60) · "Set up chairs
  for Saturday career fair" ($18/hr × 4) · "Walk my dog, weekday evenings" ($20 × 5 sessions) ·
  "Rake leaves, small backyard" ($40) · "Intro stats tutoring, 2 sessions" ($25/hr) · "Photograph
  a club event" ($80) · "Sleep study, one overnight stay" ($250, overnight) · "Taste-test new
  snack flavors" ($40).

---

## 14. Testing strategy

| Layer | Tool | What |
|---|---|---|
| Unit | Vitest | Zod schemas (valid/invalid cases), format helpers, error mapping, slot helpers, pricing display, unsubscribe HMAC |
| Database (SQL) | `npm run db:smoke` | `docs/schema_test.sql` on a fresh DB |
| Database (API) | Vitest `tests/db` | §9 cases through supabase-js with real test users (created and deleted per run) |
| End-to-end | Playwright | the golden paths below, against seeded local data |
| Manual | checklist in each phase | the human clicks through on a phone-sized window |

`npm run db:smoke` runs `scripts/db-smoke.ts`, a small Node script so it works on Windows, macOS and
Linux. It finds the local database container (`docker ps --filter name=supabase_db -q`) and pipes
`docs/schema_test.sql` into `docker exec -i <id> psql -U postgres -d postgres -v ON_ERROR_STOP=1`. It
exits non-zero unless the output contains `ALL TESTS PASSED`. Run it right after `npm run db:reset`,
before seeding.

Scripts in `scripts/` run with `tsx --env-file=.env.local`.

**E2E golden paths:**
1. Anon browses, filters by category and remote, opens a listing.
2. Signup shows "check email". The under-18 birth date shows the blocked message, and reloading still shows it.
3. free@ logs in, passes screening, applies, and sees it in Applications.
4. poster@ posts a listing → it's in review. admin@ approves it → it appears in search.
5. Three users report a listing → it disappears from search.
6. plus@ sees For You results. free@ sees the upsell with a count.
7. Banned user is sent to `/suspended`.

---

## 15. Phases

Every phase ends with the AGENTS.md end-of-phase routine. "Done" means every acceptance item is
checked and `npm run check` passes.

### Phase 0: Project setup
**Read:** §3, §4, §10.
1. Create the Next.js app (TypeScript, Tailwind, ESLint, App Router, `src/`), add Prettier, init
   shadcn/ui, add the base components (button, card, badge, input, label, select, checkbox, dialog,
   sheet, tabs, toggle-group, slider, textarea, skeleton, sonner, dropdown-menu, avatar, separator, form).
2. Add Vitest and Playwright with one sample test each. Add the npm scripts from AGENTS.md
   (`check` = typecheck && lint && test && build).
3. `npx supabase init`. Set `site_url`/redirect URLs to localhost:3000 and turn on email
   confirmations in `supabase/config.toml`.
4. Create `.env.example`, `src/lib/env.ts`, and the folder structure from §4 with stub files.
5. Root layout: font, theme tokens (one accent), header/footer, mobile bottom-nav shell, and a
   placeholder home page using `NEXT_PUBLIC_APP_NAME`.
6. Create `docs/PROGRESS.md`.

**Acceptance:**
- [ ] `npm run dev` shows the placeholder home at 375px and 1280px.
- [ ] `npm run check` passes.
- [ ] `.env.local` and `data/` are gitignored.
- [ ] The env validation fails with a clear message when a required var is missing.

### Phase 1: Database and security foundation
**Read:** §5, §9, §13, §14, `docs/schema.sql`.
1. `npx supabase start`. Copy `docs/schema.sql` unchanged to
   `supabase/migrations/<timestamp>_init.sql`. `npm run db:reset`.
2. `npm run db:smoke` must print `ALL TESTS PASSED`.
3. `npm run db:types` → `src/lib/database.types.ts`.
4. Build the three Supabase clients and `src/proxy.ts` (session refresh, `vid` cookie, route guards).
5. Write `scripts/load-zips.ts` and `scripts/seed.ts` (§13), plus `lib/errors.ts`,
   `lib/rate-limit.ts`, `lib/events.ts` and `lib/auth.ts`.
6. Write the `tests/db` integration tests (§9).

**Acceptance:**
- [ ] Smoke test passes on a fresh reset.
- [ ] `npm run zips:load` loads more than 30,000 ZIPs.
- [ ] `npm run seed` runs twice in a row without errors, and the counts match §13.
- [ ] `npm run test:db` passes.
- [ ] Seeded pending scam listings have the expected flags (check in Supabase Studio).
- [ ] No migration other than the init file exists.

### Phase 2: Auth, age gate, onboarding, settings
**Read:** §8.1, §8.2, §8.14 (except billing and deletion), §11.
Build signup/login/logout/confirm/forgot/reset, `/check-email`, `/suspended`, onboarding,
`/settings` (profile, preferences, notifications, privacy). Add the banned check in the `(app)` layout.

**Acceptance:**
- [ ] A new signup gets a confirmation email in the local inbox. The link logs in and lands on `/onboarding`.
- [ ] An under-18 birth date shows the blocked message, nothing is created in Supabase, and reloading `/signup` still shows the block.
- [ ] Onboarding saves after each step, and an unknown ZIP shows a friendly error.
- [ ] `?next=https://evil.com` is ignored.
- [ ] A banned seed user is redirected to `/suspended`.

### Phase 3: Browse, search, listing detail, public pages
**Read:** §6, §7, §8.3, §8.4, §8.9, §8.13, §8.15, §10, §11, §12.
Build `/`, `/listings`, `/listings/[id]`, `/u/[id]`, `/go/[id]`, `/how-it-works`, `/safety`,
`/rules`, `/pricing` (static for now), and `/terms` and `/privacy` placeholders. Add the listing
card, filters, AdSlot, Save button and Report dialog (the report dialog can call the RPC already).

**Acceptance:**
- [ ] Filters match the database results (spot-check 3 combinations against Supabase Studio).
- [ ] Sort by Closest works with the user's ZIP. Remote listings are always included.
- [ ] Pay shows the total, hourly and breakdown correctly for flat, hourly and per-session pay.
- [ ] Views are counted once per viewer per day.
- [ ] `/go/[id]` redirects only for listings with an external URL.
- [ ] No ad slots on clinical, donation or research listings, or for plus@.
- [ ] The clinical disclaimer shows on clinical and donation listings.
- [ ] Lighthouse mobile accessibility score of 90 or higher on `/listings`.

### Phase 4: Posting and the poster dashboard
**Read:** §8.5, §8.6, §12.
Build the posting wizard, edit, dashboard tabs, applicants page and stats. Send the NewApplicant,
Accepted and Declined emails (EMAIL_MODE=log is fine).

**Acceptance:**
- [ ] poster@ (individual) can't see clinical or donation categories, and the database rejects them anyway.
- [ ] A posting by poster@ goes to review and uses a credit. Once credits hit 0, the next attempt shows the out-of-listings state.
- [ ] lab@ posts → live immediately, charged as partner.
- [ ] A description containing a phone number goes to review even for lab@.
- [ ] Editing a rejected listing resubmits it without charging.
- [ ] The applicant email only appears after Accept.
- [ ] The draft survives a page reload.

### Phase 5: Applications, screening, saved, reviews, reports
**Read:** §8.7, §8.8.
Build the screening dialog, apply dialog, `/applications`, `/saved`, reviews both ways, and the
report flows (including "didn't get paid").

**Acceptance:**
- [ ] Failing screening shows similar gigs.
- [ ] Passing screening allows applying.
- [ ] No screening answers exist anywhere in the database (check `screening_results` columns).
- [ ] Withdraw works.
- [ ] Reviews show on the public profile, and duplicate reviews are blocked.
- [ ] 3 reports from different users hide a listing.

### Phase 6: Admin panel
**Read:** §8.10, §6 (flag explanations).
Build every admin page and the job buttons (the alert buttons can be stubs until Phase 8).

**Acceptance:**
- [ ] Non-admins get a 404 on every `/admin` route.
- [ ] Approve, reject (poster sees the reason), remove, sponsor, and approve-and-trust all work and appear in the audit log.
- [ ] Banning removes listings, ends the user's session, and blocks re-signup with the same email.
- [ ] A curated listing goes live and shows the source org name.
- [ ] An invalid keyword regex shows a friendly error.

### Phase 7: Payments (Stripe test mode)
**Read:** §8.11, §6 (pricing).
Add `scripts/stripe-setup.ts`, checkout actions, the webhook, `/settings/billing`, the real
`/pricing` buttons, and subscription cancellation in account deletion.

**Acceptance:**
- [ ] Test card 4242… buys a 5-pack → +5 credits exactly once, even when Stripe resends the event (`stripe events resend`).
- [ ] Subscribing to Plus updates `subscriptions`, the app shows Plus, and the next posting is charged to the subscription.
- [ ] The Plus pack is blocked for non-Plus users.
- [ ] Cancelling in the Portal shows "Ends on {date}".
- [ ] A bad webhook signature returns 400.
- [ ] Deleting an account with Plus cancels the subscription in Stripe.

### Phase 8: For You, alerts, email
**Read:** §8.12, §8.16.
Build `/for-you`, the upsell, the cron routes, the email templates, the unsubscribe route, and wire
the admin job buttons.

**Acceptance:**
- [ ] plus@ sees scored matches with a "why" line. free@ sees the upsell with the correct count.
- [ ] Approving a matching listing queues an alert. "Send instant alerts" writes one email file per alert.
- [ ] The daily digest groups by user.
- [ ] An unsubscribe link with a tampered token fails. A valid one turns alerts off.
- [ ] Cron routes return 401 without the secret.
- [ ] Clinical alerts use the generic subject.

### Phase 9: Hardening, polish, demo
**Read:** §9, §10, §14.
Complete the §9 checklist, write the Playwright golden paths, add loading/empty/error states
everywhere, `not-found` and `error` pages, metadata, and favicon. Write a README with setup steps,
and a "demo script" in PROGRESS.md (which seed account to use for which feature).

**Acceptance:**
- [ ] Every §9 item is checked with evidence.
- [ ] `npm run test:e2e` passes.
- [ ] No console errors on any page.
- [ ] A fresh clone → README steps → working app in under 30 minutes.

---

## 16. Out of scope for the prototype

SMS alerts and phone verification · in-app chat · payments or escrow between users · ID
verification · real ad networks · native apps · map view · social login · data export · push
notifications · referral program · multiple languages · production deployment and scheduling (see §17).

---

## 17. Before real launch (for the founders, not the agent)

- [ ] Lawyer review of Terms, Privacy Policy and Listing Rules, including:
  - whether charging seekers for Plus triggers job-listing-service laws (for example, California's)
  - health-data rules for consumer apps (FTC Health Breach Notification Rule; Washington's My Health My Data Act)
  - text-message consent rules before adding SMS
- [ ] LLC formed, founders' agreement signed, business bank account opened.
- [ ] Hosting plan that allows commercial use (Vercel's free Hobby plan does not).
- [ ] Supabase production project:
  - email confirmations on, Site URL and redirect URLs set
  - custom SMTP (Resend) for auth emails, because the built-in sender is for testing
  - MFA on every team account
  - backups reviewed
  - run the Supabase security and performance advisors
- [ ] Resend: sending domain verified (SPF, DKIM, DMARC).
- [ ] Stripe:
  - account activated, live products created with `stripe-setup.ts`
  - Customer Portal configured, live webhook endpoint set up
  - decide on sales tax collection (Stripe Tax)
- [ ] Scheduler set up for `/api/cron/alerts` (instant every 15 minutes, daily once) and `/api/cron/daily`.
- [ ] ZIPs loaded in production. Seed users never created in production.
- [ ] Real admin accounts with MFA. Moderation rota (who checks the queue, and when).
- [ ] Any real ad network configured for non-personalized ads only, and only on allowed pages.
