# Supabase Edge Functions

`ledger-api` is the production HTTP backend. Supabase injects `SUPABASE_URL` and `SUPABASE_DB_URL`; no application secret needs to be committed or manually copied into the function.

The function verifies Supabase access tokens itself so `/health` can remain public while every `/v1/*` route stays authenticated. For that reason `verify_jwt` is disabled at the gateway in `config.toml`; do not remove the application authenticator when changing this setting.

Production base URL:

```text
https://<project-ref>.supabase.co/functions/v1/ledger-api
```

Deploy with the project-local CLI:

```powershell
cd apps/api
npm run deploy:edge
```

The Node entry point under `apps/api` remains a local test harness and temporary behavior reference. It is not required in production after the Edge Function is deployed and verified.
