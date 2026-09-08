import { migrateNotionDatabase } from './db';
import { createClient, type Client } from '@libsql/client';
import { createHash, randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';

const redirectURI = 'https://teleprompter.rxlab.app/api/notion/callback';
const appCallback = 'rxlab-smart-teleprompter://notion/callback';
const hash = (value: string) => createHash('sha256').update(value).digest('base64url');
const random = () => randomBytes(32).toString('base64url');
const opaque = (value: unknown): value is string => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);
class HTTPError extends Error { constructor(public status: number) { super('Notion connection failed'); } }

export function createNotionService(db: Client, config: { clientID: string; clientSecret: string; encryptionKey: Buffer }, fetcher: typeof fetch = fetch, now = () => Date.now()) {
  let ready: Promise<unknown> | undefined;
  async function prepare() {
    ready ??= migrateNotionDatabase(db).catch(error => { ready = undefined; throw error; });
    await ready;
    await db.batch(['notion_states', 'notion_tickets', 'notion_limits'].map(table => ({ sql: `DELETE FROM ${table} WHERE expires <= ?`, args: [now()] })), 'write');
  }
  async function limit(endpoint: string) {
    const bucket = Math.floor(now() / 60000);
    const result = await db.execute({ sql: `INSERT INTO notion_limits VALUES (?, 1, ?) ON CONFLICT(id) DO UPDATE SET count = count + 1 RETURNING count`, args: [`${endpoint}:${bucket}`, (bucket + 1) * 60000] });
    if (Number(result.rows[0].count) > 120) throw new HTTPError(429);
  }
  function encrypt(token: string) {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', config.encryptionKey, iv);
    const ciphertext = Buffer.concat([cipher.update(token, 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64');
  }
  function decrypt(token: string) {
    const value = Buffer.from(token, 'base64');
    const cipher = createDecipheriv('aes-256-gcm', config.encryptionKey, value.subarray(0, 12));
    cipher.setAuthTag(value.subarray(12, 28));
    return Buffer.concat([cipher.update(value.subarray(28)), cipher.final()]).toString('utf8');
  }
  function redirect(state: string, key: string, value: string) {
    const url = new URL(appCallback);
    url.searchParams.set('state', state);
    url.searchParams.set(key, value);
    return new Response(null, { status: 302, headers: { Location: url.toString(), 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } });
  }
  return async function handle(endpoint: 'start' | 'callback' | 'exchange', request: Request): Promise<Response> {
    try {
      await prepare();
      await limit(endpoint);
      if (endpoint === 'callback') {
        const query = new URL(request.url).searchParams;
        const state = query.get('state');
        if (!opaque(state) || query.getAll('state').length !== 1 || query.getAll('code').length > 1 || query.getAll('error').length > 1) throw new HTTPError(400);
        const result = await db.execute({ sql: 'DELETE FROM notion_states WHERE id = ? AND expires > ? RETURNING challenge', args: [hash(state), now()] });
        if (!result.rows.length) throw new HTTPError(400);
        if (query.has('error')) return redirect(state, 'error', 'access_denied');
        const code = query.get('code');
        if (!code || code.length > 2048) return redirect(state, 'error', 'connection_failed');
        try {
          const response = await fetcher('https://api.notion.com/v1/oauth/token', {
            method: 'POST', headers: { Authorization: `Basic ${Buffer.from(`${config.clientID}:${config.clientSecret}`).toString('base64')}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ grant_type: 'authorization_code', code, redirect_uri: redirectURI }), signal: AbortSignal.timeout(20000),
          });
          if (!response.ok) throw new HTTPError(502);
          const token = await response.json();
          if (typeof token.access_token !== 'string' || !token.access_token) throw new HTTPError(502);
          const ticket = random();
          await db.execute({ sql: 'INSERT INTO notion_tickets VALUES (?, ?, ?, ?)', args: [hash(ticket), String(result.rows[0].challenge), encrypt(token.access_token), now() + 120000] });
          return redirect(state, 'ticket', ticket);
        } catch { return redirect(state, 'error', 'connection_failed'); }
      }
      // Bound streamed input as well as Content-Length before parsing JSON.
      const reader = request.body?.getReader();
      if (!reader) throw new HTTPError(400);
      const chunks: Uint8Array[] = [];
      let size = 0;
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        size += part.value.length;
        if (size > 4096) { await reader.cancel(); throw new HTTPError(413); }
        chunks.push(part.value);
      }
      let body: Record<string, unknown>;
      try { body = JSON.parse(Buffer.concat(chunks).toString()); } catch { throw new HTTPError(400); }
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HTTPError(400);
      if (endpoint === 'start') {
        if (body.client_id !== config.clientID || body.redirect_uri !== redirectURI || body.code_challenge_method !== 'S256' || !opaque(body.state) || !opaque(body.code_challenge)) throw new HTTPError(400);
        const inserted = await db.execute({ sql: 'INSERT INTO notion_states VALUES (?, ?, ?) ON CONFLICT(id) DO NOTHING', args: [hash(body.state), body.code_challenge, now() + 600000] });
        if (!inserted.rowsAffected) throw new HTTPError(409);
        const url = new URL('https://api.notion.com/v1/oauth/authorize');
        for (const [key, value] of Object.entries({ client_id: config.clientID, redirect_uri: redirectURI, state: body.state, owner: 'user', response_type: 'code' })) url.searchParams.set(key, value);
        return json({ authorization_url: url.toString() });
      }
      if (!opaque(body.ticket) || typeof body.code_verifier !== 'string' || !/^[A-Za-z0-9._~-]{43,128}$/.test(body.code_verifier)) throw new HTTPError(400);
      const result = await db.execute({ sql: 'DELETE FROM notion_tickets WHERE id = ? AND challenge = ? AND expires > ? RETURNING token', args: [hash(body.ticket), hash(body.code_verifier), now()] });
      if (!result.rows.length) throw new HTTPError(400);
      return json({ access_token: decrypt(String(result.rows[0].token)) });
    } catch (error) { return json({ error: 'Unable to complete Notion sign-in. Please try again.' }, error instanceof HTTPError ? error.status : 503); }
  };
}
function json(body: unknown, status = 200) { return Response.json(body, { status, headers: { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } }); }
let service: ReturnType<typeof createNotionService>;
export async function handleNotion(endpoint: 'start' | 'callback' | 'exchange', request: Request) {
  if (!service) {
    const { TURSO_DATABASE_URL, TURSO_AUTH_TOKEN, NOTION_CLIENT_ID, NOTION_CLIENT_SECRET, NOTION_TOKEN_ENCRYPTION_KEY } = process.env;
    const key = Buffer.from(NOTION_TOKEN_ENCRYPTION_KEY ?? '', 'base64');
    if (!TURSO_DATABASE_URL || !NOTION_CLIENT_ID || !NOTION_CLIENT_SECRET || key.length !== 32 || (!TURSO_DATABASE_URL.startsWith('file:') && !TURSO_AUTH_TOKEN)) return json({ error: 'Notion sign-in is not configured yet.' }, 503);
    service = createNotionService(createClient({ url: TURSO_DATABASE_URL, authToken: TURSO_AUTH_TOKEN }), { clientID: NOTION_CLIENT_ID, clientSecret: NOTION_CLIENT_SECRET, encryptionKey: key });
  }
  return service(endpoint, request);
}
