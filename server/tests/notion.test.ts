import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '@libsql/client';
import { createHash, randomBytes } from 'node:crypto';
import { createNotionService } from '../lib/notion';
const random = () => randomBytes(32).toString('base64url');
const hash = (s: string) => createHash('sha256').update(s).digest('base64url');
test('OAuth validates state, encrypts tokens, binds verifier, prevents replay and expires records', async () => {
 const db = createClient({ url: ':memory:' });
 let now = Date.now(), calls = 0;
 const service = createNotionService(db, { clientID: 'client', clientSecret: 'secret', encryptionKey: randomBytes(32) }, (async (_url, options) => {
  calls++;
  assert.equal(JSON.parse(String(options?.body)).redirect_uri, 'https://teleprompter.rxlab.app/api/notion/callback');
  return Response.json({ access_token: 'private-token' });
 }) as typeof fetch, () => now);
 const post = (endpoint: 'start' | 'exchange', body: unknown) => service(endpoint, new Request('https://example.com', { method: 'POST', body: JSON.stringify(body) }));
 const state = random(), verifier = random();
 const body = { client_id: 'client', redirect_uri: 'https://teleprompter.rxlab.app/api/notion/callback', state, code_challenge: hash(verifier), code_challenge_method: 'S256' };
 const callback = (query = `state=${state}&code=code`) => service('callback', new Request(`https://example.com?${query}`));
 try {
  for (const change of [{ client_id: 'wrong' }, { redirect_uri: 'https://evil.example' }, { code_challenge_method: 'plain' }, { state: 'short' }]) assert.equal((await post('start', { ...body, ...change })).status, 400);
  assert.equal((await post('start', null)).status, 400);
  const start = await post('start', body);
  assert.equal(start.status, 200);
  assert.equal(new URL((await start.json()).authorization_url).searchParams.get('state'), state);
  assert.equal((await post('start', body)).status, 409);
  assert.equal((await callback(`state=${state}&state=${state}&code=c`)).status, 400);
  assert.equal((await callback(`state=${random()}&code=c`)).status, 400);
  const location = new URL((await callback()).headers.get('location')!);
  const ticket = location.searchParams.get('ticket');
  assert.equal(location.protocol, 'rxlab-smart-teleprompter:');
  assert.ok(ticket);
  assert.ok(!JSON.stringify((await db.execute('SELECT * FROM notion_tickets')).rows).includes('private-token'));
  assert.equal((await post('exchange', { ticket, code_verifier: random() })).status, 400);
  const results = await Promise.all([1, 2].map(() => post('exchange', { ticket, code_verifier: verifier })));
  assert.deepEqual(results.map(r => r.status).sort(), [200, 400]);
  const success = results.find(r => r.status === 200)!;
  assert.equal(success.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await success.json(), { access_token: 'private-token' });
  assert.equal((await callback()).status, 400);
  assert.equal(calls, 1);
  await post('start', body);
  now += 600001;
  assert.equal((await callback()).status, 400);
  await post('start', body);
  const expiredTicket = new URL((await callback()).headers.get('location')!).searchParams.get('ticket');
  now += 120001;
  assert.equal((await post('exchange', { ticket: expiredTicket, code_verifier: verifier })).status, 400);
  assert.equal((await db.execute('SELECT * FROM notion_tickets')).rows.length, 0);
  await post('start', body);
  const denied = new URL((await callback(`state=${state}&error=access_denied`)).headers.get('location')!);
  assert.equal(denied.searchParams.get('error'), 'access_denied');
  assert.equal(denied.searchParams.get('state'), state);
  assert.equal((await callback()).status, 400);
  now += 60000;
  for (let i = 0; i < 120; i++) assert.equal((await post('start', { ...body, state: random() })).status, 200);
  assert.equal((await post('start', { ...body, state: random() })).status, 429);
 } finally { db.close(); }
});
test('provider failure returns a bound error without creating a ticket', async () => {
 const db = createClient({ url: ':memory:' });
 const state = random();
 const service = createNotionService(db, { clientID: 'client', clientSecret: 'secret', encryptionKey: randomBytes(32) }, (async () => Response.json({ error: 'invalid_grant' }, { status: 400 })) as typeof fetch);
 try {
  await service('start', new Request('https://example.com', { method: 'POST', body: JSON.stringify({ client_id: 'client', redirect_uri: 'https://teleprompter.rxlab.app/api/notion/callback', state, code_challenge: hash(random()), code_challenge_method: 'S256' }) }));
  const response = await service('callback', new Request(`https://example.com?state=${state}&code=bad`));
  const url = new URL(response.headers.get('location')!);
  assert.equal(url.searchParams.get('state'), state);
  assert.equal(url.searchParams.get('error'), 'connection_failed');
  assert.equal((await db.execute('SELECT * FROM notion_tickets')).rows.length, 0);
 } finally { db.close(); }
});
