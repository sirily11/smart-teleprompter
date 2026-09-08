# Smart Teleprompter server

Next.js serves `/`, `/privacy`, `/tos`, and the Notion OAuth endpoints.

## Setup

1. Run `npm ci` and copy `.env.example` to `.env.local` if needed.
2. Set `NOTION_CLIENT_SECRET`, `TURSO_AUTH_TOKEN`, and a stable
   `NOTION_TOKEN_ENCRYPTION_KEY` (32 random bytes encoded as base64).
   Generate the key with `openssl rand -base64 32`. Keep secrets out of Git.
3. Register `https://teleprompter.rxlab.app/api/notion/callback` as the redirect
   URI for the public Notion integration. Enable read content access.
4. Add the same environment settings to the hosting provider and deploy `server`.
   Set `SUPPORT_EMAIL` for the legal pages if desired.

`npm run dev` listens on port 3100. `npm test`, `npm run typecheck`, and
`npm run build` validate the server. Tests use temporary local libSQL storage and
mock only Notion's token response; they do not need production credentials.

## OAuth and storage

- `POST /api/notion/start` validates the configured client, fixed redirect, state,
  and S256 challenge. Transactions expire after ten minutes.
- `GET /api/notion/callback` atomically consumes state and exchanges the code
  server-side. The app receives only a random ticket and its original state.
- `POST /api/notion/exchange` atomically redeems a ticket only with the matching
  verifier. Tickets expire after two minutes; tokens use AES-256-GCM encryption.

Tables are created idempotently on first use. Expired records are removed on
subsequent requests; schedule database cleanup if deletion while idle is needed.
A shared database limit permits 120 requests per endpoint per minute. Configure
additional per-IP limits at the trusted hosting edge for larger deployments.
All instances must share the database and encryption key. No page content or
refresh tokens are stored. The app talks directly to Notion after sign-in.

Disable query-string logging on `/api/notion/callback` at the hosting edge,
and never record OAuth request/response bodies. Responses use `no-store`.
Without the required environment settings, OAuth fails closed with HTTP 503.

Reference: [Notion authorization](https://developers.notion.com/guides/get-started/authorization)
and [Turso TypeScript SDK](https://docs.turso.tech/sdk/ts/reference).
