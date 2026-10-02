# Receipt Divider API

This is the stateless transaction-ledger backend. It uses Hono, Supabase Auth access tokens, and PostgreSQL as the canonical store. The phone submits reviewed commands and renders snapshots; it does not reconcile balances or race concurrent writes locally.

## Implemented model

- Every participant is an app account; there are no local or placeholder people. Each account has a currency, initially USD.
- Real-name profiles, unique lowercase usernames, exact-username friend requests, and accepted friendships. You can split expenses only with yourself and accepted friends.
- Shared transactions: an expense is visible to its creator, its payer, and everyone allocated a share; a repayment is visible to its sender and recipient. Removing a friend keeps shared history, and you can still record repayments with anyone you've shared an expense with.
- Pairwise balances from the caller's side: everyone on an expense owes their share to its payer, and repayments reduce what the sender owes. `netBalance` is the sum.
- Saved people filters (called groups in the UI) that have no membership, invitation, permission, or balance semantics.
- General expenses with an explicit total, payer, date, and exact allocations. Every saved expense has at least one item, and each item records who owns it (`ownerIds`); ownership never sets amounts, the allocations do.
- Optional evidence assets for receipts, restaurant checks, ticket confirmations, and other image paper trails, visible to everyone on the expense they're attached to.
- Database-backed profile and evidence images (`bytea`), capped at 5 MB and 15 MB respectively.
- Atomic expenses, repayments, audit events, exact-cent validation, idempotent retries, and server-derived balances.
- A saved filter uses **any-person/OR matching**: a transaction is included if its payer, allocation, sender, or recipient overlaps the filter. Returned balances are unchanged; selecting a filter never creates or calculates a separate group pool.

The deliberately unanswered production decisions are edit and deletion policy, image retention, extraction provider, and eventual multi-currency behavior. Supabase Edge Functions are the selected production API runtime.

## Run locally

```powershell
cd apps/api
npm install
$env:ALLOW_INSECURE_DEV_AUTH = "true"
npm run dev
```

This mode is non-persistent. Send a UUID in `x-user-id`, create the profile with `PUT /v1/profile`, set a name and username with `PUT /v1/profile/identity`, then connect accounts with friend requests. Never expose development authentication publicly.

## Supabase PostgreSQL

1. Create a Supabase project and apply the files in `db/migrations/` in order (`001_initial.sql` through `009_slider_unit_percent_default.sql`) in its SQL editor or migration runner.
2. For the local Node test harness, copy Supabase’s **Session pooler** URI into `DATABASE_URL`, set `SUPABASE_URL`, and leave `ALLOW_INSECURE_DEV_AUTH` false. Copy `.env.example` to the Git-ignored `.env.local` and run `npm run dev:local`.
3. Run this API as a trusted backend. Public tables have RLS enabled and direct `anon`/`authenticated` grants revoked; mobile clients use only the API.

The adapter uses one encrypted database connection and disables prepared statements. Local Node uses the Session pooler for IPv4 access. The production Edge Function uses Supabase’s injected `SUPABASE_DB_URL` with a one-connection adapter, so no database URL or service-role key is committed or manually configured for the deployed function.

## HTTP contract

Every `/v1` route requires `Authorization: Bearer <Supabase access token>` in production.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Confirm that the API process is running. |
| `GET` | `/ready` | Confirm that the API can reach its configured datastore. |
| `PUT` | `/v1/profile` | Create the account profile and settings if missing; returns the profile. |
| `GET` | `/v1/profile` | Read the caller's name, username, display name, and `isDeveloper`. |
| `GET` | `/v1/settings` | Read the caller's `currency` and `sliderUnit` (`dollars` or `percent`, default `percent`). |
| `PATCH` | `/v1/settings` | Change `sliderUnit`; returns the updated settings. |
| `PUT` | `/v1/profile/avatar` | Store the account avatar. |
| `GET` | `/v1/users/{userId}/avatar` | Read your own avatar or that of any user who has set a username (and so appears in search). |
| `PUT` | `/v1/profile/identity` | Set the real first/last name and unique username. The display name is always derived as "First Last". |
| `GET` | `/v1/users/search?q=` | Find users whose first name, last name, or username starts with `q` (2–60 characters, up to 20 results), with each one’s relationship to the caller. |
| `GET` | `/v1/friends` | List accepted, incoming, and outgoing friend relationships, each with the person’s current `avatarEtag`. |
| `POST` | `/v1/friend-requests` | Invite an account by exact username. |
| `POST` | `/v1/friend-requests/{id}/accept` | Accept an incoming request and link both participant records. |
| `DELETE` | `/v1/friends/{userId}` | Remove a friend (or withdraw a pending request). Shared expenses and participant records are kept. |
| `POST/GET` | `/v1/saved-filters` | Create/list named filters over yourself and your friends (`userIds`). |
| `POST` | `/v1/evidence?kind=receipt` | Store optional evidence image bytes. |
| `GET` | `/v1/evidence/{evidenceId}/image` | Read evidence you uploaded or that is attached to an expense you're on. |
| `PUT` | `/v1/evidence/{evidenceId}/text` | Store the text your device recognized in evidence you uploaded (`{ "text": … }`), kept in `extracted_data` for troubleshooting. |
| `POST` | `/v1/expenses` | Atomically post a reviewed general expense between you and your friends, with an optional `category` (`groceries`, `restaurant`, `movie`, or `concert`; returned as `null` when absent). |
| `PATCH` | `/v1/expenses/:expenseId` | Payer only: change `description` and/or `transactionDate` (`YYYY-MM-DD`). Records one revision per changed field with the old and new value; amounts and balances are untouched. Other participants get 403; anyone else 404. |
| `POST` | `/v1/payments` | Record a repayment you sent or received (`fromUserId`, `toUserId`). |
| `POST` | `/v1/developer/reset-ledger` | Developer accounts only (`user_profiles.is_developer`; others get 403): with `{ "confirm": "DELETE" }`, deletes every account's expenses, evidence, payments, and revision history. Profiles, settings, friendships, and saved filters are kept. |
| `GET` | `/v1/transactions?filterId={id}` | Read every transaction you're on, the people in them, and your balance with each person, optionally filtered by a saved filter. |

Example manual expense (no image and no itemization):

```json
{
  "clientRequestId": "10000000-0000-4000-8000-000000000001",
  "description": "Weekly groceries",
  "category": "groceries",
  "transactionDate": "2026-09-18",
  "payerId": "00000000-0000-4000-8000-000000000011",
  "currency": "USD",
  "totalCents": 6000,
  "allocations": [
    { "userId": "00000000-0000-4000-8000-000000000011", "amountCents": 2000 },
    { "userId": "00000000-0000-4000-8000-000000000012", "amountCents": 4000 }
  ]
}
```

For receipt-assisted entry, upload evidence first, then add its ID in `evidenceIds` and optionally add reviewed `items`. To split one receipt into several expenses, upload it once and put the same evidence ID on each; the uploaded evidence is the receipt record (image and recognized text), and expenses sharing an ID came from the same receipt. Items record what was bought and need not add up to `totalCents` (an evenly split receipt uses its printed total even when recognition missed a line); allocations must always equal `totalCents`. Each item may list `ownerIds`, who must be the payer or have an allocation; an item without owners belongs to the payer, and an expense sent without items is saved as one item for its total owned by everyone allocated.

## Verification

```powershell
npm test
npm run typecheck
npm run smoke:postgres
```

The unit suite covers shared visibility, mirrored and group balances, friends-only splitting, removing friends, any-person filters, evidence visibility, retry idempotency, exact totals, and Supabase JWT verification. `smoke:postgres` uses `.env.local` to exercise the same API contract against the configured Supabase database with two temporary friends and removes them and their records afterward.

## Deploy as a Supabase Edge Function

The production entry point is `supabase/functions/ledger-api/index.ts`. It reuses these tested handlers and connects through the `SUPABASE_DB_URL` and `SUPABASE_URL` values Supabase injects automatically. See [`supabase/functions/README.md`](../../supabase/functions/README.md) for linking and deployment commands.

The public process check is `/health`; `/ready` also verifies database access. Every `/v1/*` route performs application-level Supabase JWT verification. `verify_jwt` is therefore disabled only at the Edge gateway so the health routes remain public; protected application routes do not permit anonymous requests.

The deployed base URL is `https://lurdfvsnscylvwvvepos.supabase.co/functions/v1/ledger-api`. Redeploy from `apps/api` with `npm run deploy:edge`.
