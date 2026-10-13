# AGENTS.md — Rules for AI agents working in this repo

## What this project is
A mobile-first web app where college students find short paid gigs (focus groups, research
studies, paid donations, user testing, odd jobs) and where people and organizations post gigs.
Free users see ads and get 3 free listings; Plus members ($5/mo) get matching, email alerts,
no ads and 20 listings per billing period.

Source of truth, in this order:
1. `docs/BUILD_PLAN.md`: the spec, conventions and phase-by-phase plan.
2. `docs/schema.sql`: the database (becomes the first migration). `docs/schema_test.sql` proves it works.
3. `docs/PROGRESS.md`: what's done, known issues, what's next. You keep this updated.

If the plan, the schema and an instruction disagree, stop and ask. Don't guess.

## How to work
- Work only on the phase you were asked to do. Read the BUILD_PLAN sections that phase lists first.
- Before writing code, show an implementation plan and task list and wait for approval.
- Work in small steps. After each step run `npm run typecheck` and fix what it finds.
- At the end of a phase:
  1. Run `npm run check` (typecheck, lint, unit tests, build). Everything must pass.
  2. Go through the phase's acceptance checklist and say which items you verified and how.
  3. Check every new page in the browser at 375px and 1280px wide with no console errors.
  4. Update `docs/PROGRESS.md`: done, known issues, next.
  5. Summarize what changed and give me steps to test it by hand.
- Don't add npm packages outside the approved stack without asking. Don't change major versions.
- Never edit a migration that has already run. Schema changes go in a new file in
  `supabase/migrations/`, then run `npm run db:types`, and update BUILD_PLAN if behavior changes.
- The owner is a student who is learning. Add short comments explaining non-obvious code, and
  explain any decision you make that isn't in the plan.
- Never run destructive commands (deleting folders, `git reset --hard`, dropping databases other
  than the local one via `npm run db:reset`) without asking first.

## Approved stack
Next.js 16 (App Router, TypeScript strict) · React 19 · Tailwind CSS v4 · shadcn/ui · lucide-react ·
Supabase (Postgres, Auth, RLS) via `@supabase/supabase-js` + `@supabase/ssr` · Supabase CLI (local,
Docker) · Zod · react-hook-form + @hookform/resolvers · Stripe (Checkout, Customer Portal, webhooks) ·
Resend + React Email · sonner (toasts) · server-only · tsx (runs scripts) · Vitest · Playwright ·
ESLint + Prettier · npm.

## Security rules (non-negotiable)
1. Every table has RLS enabled and explicit grants. A table without RLS is a bug.
2. Users never write protected tables directly. Use the RPC functions in the schema. Never fix a
   "permission denied" error by widening grants, disabling RLS or switching to the secret key. Stop and ask.
3. The secret-key client (`src/lib/supabase/admin.ts`) starts with `import 'server-only'` and is used
   ONLY in: the Stripe webhook, cron routes, event tracking, rate limiting, admin ban/unban in Supabase
   Auth, account deletion, admin email lookup, and seed/zip scripts. Never in client components.
4. On the server, identify the user with `supabase.auth.getUser()` (or `getClaims()`). Never trust
   `getSession()` on the server, and never trust a user id sent from the browser.
5. Validate every Server Action and route input with Zod, using the shared schemas in `src/lib/validation/`.
6. Secrets live only in env vars WITHOUT the `NEXT_PUBLIC_` prefix. `.env.local` is never committed.
7. No third-party scripts of any kind: no analytics, pixels, ad networks, session replay, chat widgets
   or CDN fonts (use `next/font`). Stats come only from our own `listing_events` table.
8. Never log or email: screening answers, birth dates, user emails (in server logs), passwords or tokens.
9. Render user-written text as plain text. No `dangerouslySetInnerHTML`, no markdown rendering of user
   content. Outbound links to a listing's sign-up page go only through `/go/[id]`, never a URL from a
   query string. External links use `rel="noopener noreferrer nofollow"`.
10. Rate-limit signup, posting, applying and reporting with `rate_limit_hit`.
11. Admin pages check admin status on the server in the admin layout, and every admin action goes through
    an `admin_*` RPC (which checks again in the database).
12. Verify the Stripe webhook signature. Cron routes require `Authorization: Bearer ${CRON_SECRET}`.

## Product rules
- Never use "guaranteed", "guarantee" or income promises ("make $500 this week") in any copy or email.
- Show pay exactly as the poster entered it: total pay, plus effective hourly rate and the breakdown.
- No health questions in onboarding, profile or settings. Listing screening answers are never stored;
  only pass/fail is kept.
- 18+ only. The birth date field never states the age cutoff.
- No ad slots on clinical, donation or research listings, screening, onboarding, settings, applications,
  billing or admin pages. Plus members never see ads.
- Sponsored listings are always labeled "Sponsored".
- Clinical study and paid donation listings show the disclaimer from BUILD_PLAN §11.

## Code conventions
- TypeScript strict, no `any`. Database types come from `src/lib/database.types.ts` (`npm run db:types`).
- Server Components by default. `'use client'` only where interactivity needs it.
- Mutations are Server Actions in an `actions.ts` next to the route. They return
  `{ ok: true, data } | { ok: false, error: string }`.
- Map database error codes (like `NO_CREDITS`) to friendly text with `src/lib/errors.ts`. Never show
  raw database errors to users.
- Money is integer cents everywhere. Format only with `formatMoney()`.
- Store times in UTC. Display them in the user's local time.
- shadcn components live in `src/components/ui/`. App components live in `src/components/<area>/`.
- Never `select('*')` from tables in client-facing code. Select the columns you need.
- Mobile-first Tailwind. Every page must work at 375px wide.
- File names are kebab-case. React components are PascalCase.

## Commands
- `npm run dev`: start the app at http://localhost:3000
- `npm run check`: typecheck, lint, unit tests and production build (must pass before a phase is done)
- `npm run db:start` / `npm run db:stop`: start or stop local Supabase (needs Docker running)
- `npm run db:reset`: rebuild the local database from migrations (local only)
- `npm run db:smoke`: run `docs/schema_test.sql` against the local database
- `npm run db:types`: regenerate TypeScript types from the local database
- `npm run zips:load`: load ZIP code coordinates
- `npm run seed`: create local test users and listings (refuses to run against a non-local database)
- `npm run test:db`: database integration tests (needs local Supabase running)
- `npm run test:e2e`: Playwright end-to-end tests
- `npm run stripe:listen`: forward Stripe test webhooks to the local app
