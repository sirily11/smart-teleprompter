# Smart Teleprompter legal website

Small Next.js App Router app named `server`, with `/`, `/privacy`, and `/tos`.

```sh
npm ci
npm run dev
# Production:
npm run build
npm start
```

The local server uses port 3100. Simulator Settings links point to `http://localhost:3100`.

Before public release:
- Set `SUPPORT_EMAIL` in the build environment, then rebuild (pages are prerendered).
- Deploy this folder to a Node-compatible host with HTTPS.
- Set the iOS `LEGAL_BASE_URL` build setting to that public origin (no trailing page path). `Configuration/AppInfo.plist` passes it to Settings. Device builds intentionally do not link to localhost or an invented domain.
- Review the privacy and terms copy against the final hosting provider and business details. No public deployment is included.

No analytics, accounts, database, or cookie banner are included. The privacy copy reflects the existing Apple server-recognition fallback and device diagnostic logging.
