# Receipt Divider API

This is the provider-neutral ledger backend. It uses Hono's Web-standard request handler, a PostgreSQL adapter for durable use, and an in-memory adapter for local tests.

## What is implemented

- User profiles and database-backed profile images.
- Groups and direct owner-managed membership (invitations remain open).
- Private database-backed receipt images.
- Atomic expenses, items, allocations, repayments, audit events, and group versions.
- Integer-cent validation, server-recalculated totals, idempotent retries, and derived balances.
- Authorization checks at every group and image boundary.

## Run locally without PostgreSQL

```powershell
cd apps/api
npm install
$env:ALLOW_INSECURE_DEV_AUTH = "true"
npm run dev
```

This mode is intentionally non-persistent. Send a valid UUID in `x-user-id`, create that profile with `PUT /v1/profile`, and then create a group. Never expose this development authentication mode publicly.

## Run with PostgreSQL

1. Create a PostgreSQL database.
2. Apply `db/migrations/001_initial.sql` with the provider's SQL console or migration tool.
3. Copy `.env.example` values into your local environment and set `DATABASE_URL`.
4. Set `SUPABASE_URL`, leave `ALLOW_INSECURE_DEV_AUTH` unset, and use an asymmetric Supabase JWT signing key. The API verifies bearer tokens against the project's cached JWKS.

The PostgreSQL pool is deliberately capped at five connections per function instance. A deployed serverless platform should use a provider pooler or database proxy.

## HTTP contract

Every `/v1` request requires authenticated identity. The local adapter reads `x-user-id`; deployed requests use `Authorization: Bearer <Supabase access token>`. The API verifies the signature, issuer, audience, expiry, authenticated role, and UUID subject before using the identity.

| Method | Path | Purpose |
| --- | --- | --- |
| `PUT` | `/v1/profile` | Create or update the caller's display name. |
| `PUT` | `/v1/profile/avatar` | Store raw image bytes in the caller's profile row. |
| `GET` | `/v1/users/{userId}/avatar` | Read an avatar visible through shared membership. |
| `POST` | `/v1/groups` | Create a group with the caller as owner. |
| `POST` | `/v1/groups/{groupId}/members` | Directly add an existing profile; invitation acceptance is not implemented. |
| `GET` | `/v1/groups/{groupId}/snapshot` | Read the canonical ledger, version, and derived balances. |
| `POST` | `/v1/groups/{groupId}/receipts` | Store raw receipt image bytes in PostgreSQL. |
| `GET` | `/v1/receipts/{receiptId}/image` | Read receipt bytes after membership authorization. |
| `POST` | `/v1/groups/{groupId}/expenses` | Atomically post reviewed items and exact allocations. |
| `POST` | `/v1/groups/{groupId}/payments` | Atomically record a repayment. |

Images use their actual image media type as `Content-Type` and the raw bytes as the request body. JSON ledger operations include a UUID `clientRequestId`; retrying the same operation returns its original record, while reusing that UUID with different data returns `409`.

Example expense body:

```json
{
  "clientRequestId": "10000000-0000-4000-8000-000000000001",
  "description": "Groceries",
  "transactionDate": "2026-09-18",
  "payerId": "00000000-0000-4000-8000-000000000001",
  "currency": "USD",
  "items": [{ "name": "Shared groceries", "amountCents": 6000, "offsetCents": 0 }],
  "allocations": [
    { "userId": "00000000-0000-4000-8000-000000000001", "amountCents": 2000 },
    { "userId": "00000000-0000-4000-8000-000000000002", "amountCents": 4000 }
  ]
}
```

## Tests

```powershell
npm test
npm run typecheck
```

The test suite covers concurrent additive entries, zero-sum balances, retries, conflicting idempotency keys, binary image round-trips, and authorization boundaries. PostgreSQL integration tests require a provisioned database and remain pending.

## Image decision

Avatar bytes (`user_profiles.avatar_data`) and receipt bytes (`receipts.image_data`) live in PostgreSQL. Limits are 5 MB per avatar and 15 MB per receipt. API consumers never depend on that physical choice: they upload and retrieve image bytes through API endpoints, so storage can be migrated later without changing the mobile contract.
