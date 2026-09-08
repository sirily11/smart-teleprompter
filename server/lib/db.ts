import type { Client } from '@libsql/client';

export async function migrateNotionDatabase(db: Client) {
  await db.batch([
      `CREATE TABLE IF NOT EXISTS notion_states (id TEXT PRIMARY KEY, challenge TEXT NOT NULL, expires INTEGER NOT NULL)`,
      `CREATE TABLE IF NOT EXISTS notion_tickets (id TEXT PRIMARY KEY, challenge TEXT NOT NULL, token TEXT NOT NULL, expires INTEGER NOT NULL)`,
      `CREATE TABLE IF NOT EXISTS notion_limits (id TEXT PRIMARY KEY, count INTEGER NOT NULL, expires INTEGER NOT NULL)`,
    ], 'write');
}
