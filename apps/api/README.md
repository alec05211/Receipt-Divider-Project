# Receipt Divider API

This is the stateless transaction-ledger backend. It uses Hono, Supabase Auth access tokens, and PostgreSQL as the canonical store. The phone submits reviewed commands and renders snapshots; it does not reconcile balances or race concurrent writes locally.

## Implemented model

- One private ledger per authenticated account, initially in USD.
- Local `people` records; a person can optionally link to a future app account but does not need one.
- Real-name profiles, unique lowercase usernames, exact-username friend requests, and accepted account relationships. Accepting a request creates linked participant records in both ledgers.
- Saved people filters (called groups in the UI) that have no membership, invitation, permission, or balance semantics.
- General expenses with an explicit total, payer, date, and exact allocations. Item rows are optional.
- Optional evidence assets for receipts, restaurant checks, ticket confirmations, and other image paper trails.
- Database-backed profile and evidence images (`bytea`), capped at 5 MB and 15 MB respectively.
- Atomic expenses, repayments, ledger versions, audit events, exact-cent validation, idempotent retries, and server-derived balances.
- A saved filter uses **any-person/OR matching**: a transaction is included if its payer, allocation, sender, or recipient overlaps the filter. Returned balances remain account-ledger-wide; selecting a filter never creates or calculates a separate group pool.

The deliberately unanswered production decisions are multi-account sharing/invitations, edit and deletion policy, image retention, extraction provider, and eventual multi-currency behavior. Supabase Edge Functions are the selected production API runtime.

## Run locally

```powershell
cd apps/api
npm install
$env:ALLOW_INSECURE_DEV_AUTH = "true"
npm run dev
```

This mode is non-persistent. Send a UUID in `x-user-id`, create the profile with `PUT /v1/profile`, then create local people. Never expose development authentication publicly.

## Supabase PostgreSQL

1. Create a Supabase project and apply `db/migrations/001_initial.sql` in its SQL editor or migration runner.
2. For the local Node test harness, copy Supabase’s **Session pooler** URI into `DATABASE_URL`, set `SUPABASE_URL`, and leave `ALLOW_INSECURE_DEV_AUTH` false. Copy `.env.example` to the Git-ignored `.env.local` and run `npm run dev:local`.
3. Run this API as a trusted backend. Public tables have RLS enabled and direct `anon`/`authenticated` grants revoked; mobile clients use only the API.

The adapter uses one encrypted database connection and disables prepared statements. Local Node uses the Session pooler for IPv4 access. The production Edge Function uses Supabase’s injected `SUPABASE_DB_URL` with a one-connection adapter, so no database URL or service-role key is committed or manually configured for the deployed function.

## HTTP contract

Every `/v1` route requires `Authorization: Bearer <Supabase access token>` in production.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Confirm that the API process is running. |
| `GET` | `/ready` | Confirm that the API can reach its configured datastore. |
| `PUT` | `/v1/profile` | Create/update the account profile and ledger. |
| `PUT` | `/v1/profile/avatar` | Store the account avatar. |
| `GET` | `/v1/users/{userId}/avatar` | Read self or a linked local person’s avatar. |
| `POST/GET` | `/v1/people` | Create/list local people. |
| `PUT` | `/v1/profile/identity` | Set the real first/last name and unique username. |
| `GET` | `/v1/friends` | List accepted, incoming, and outgoing friend relationships. |
| `POST` | `/v1/friend-requests` | Invite an account by exact username. |
| `POST` | `/v1/friend-requests/{id}/accept` | Accept an incoming request and link both participant records. |
| `POST/GET` | `/v1/saved-filters` | Create/list named people filters. |
| `POST` | `/v1/evidence?kind=receipt` | Store optional evidence image bytes. |
| `GET` | `/v1/evidence/{evidenceId}/image` | Read caller-owned evidence bytes. |
| `POST` | `/v1/expenses` | Atomically post a reviewed general expense. |
| `POST` | `/v1/payments` | Record a repayment between local people. |
| `GET` | `/v1/transactions?filterId={id}` | Read the ledger, optionally filtered by saved people. |

Example manual expense (no image and no itemization):

```json
{
  "clientRequestId": "10000000-0000-4000-8000-000000000001",
  "description": "Utilities",
  "transactionDate": "2026-09-18",
  "payerPersonId": "00000000-0000-4000-8000-000000000011",
  "currency": "USD",
  "totalCents": 6000,
  "allocations": [
    { "personId": "00000000-0000-4000-8000-000000000011", "amountCents": 2000 },
    { "personId": "00000000-0000-4000-8000-000000000012", "amountCents": 4000 }
  ]
}
```

For receipt-assisted entry, upload evidence first, then add its ID in `evidenceIds` and optionally add reviewed `items`. When items exist, their adjusted sum must equal `totalCents`; allocations must always equal `totalCents`.

## Verification

```powershell
npm test
npm run typecheck
npm run smoke:postgres
```

The unit suite covers concurrent additive writes, zero-sum balances, manual and itemized expenses, any-person filters, evidence privacy, retry idempotency, exact totals, and Supabase JWT verification. `smoke:postgres` uses `.env.local` to exercise the same API contract against the configured Supabase database and removes its temporary account and all cascaded records afterward.

## Deploy as a Supabase Edge Function

The production entry point is `supabase/functions/ledger-api/index.ts`. It reuses these tested handlers and connects through the `SUPABASE_DB_URL` and `SUPABASE_URL` values Supabase injects automatically. See [`supabase/functions/README.md`](../../supabase/functions/README.md) for linking and deployment commands.

The public process check is `/health`; `/ready` also verifies database access. Every `/v1/*` route performs application-level Supabase JWT verification. `verify_jwt` is therefore disabled only at the Edge gateway so the health routes remain public; protected application routes do not permit anonymous requests.

The deployed base URL is `https://lurdfvsnscylvwvvepos.supabase.co/functions/v1/ledger-api`. Redeploy from `apps/api` with `npm run deploy:edge`.
