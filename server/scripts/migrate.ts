import { loadEnvConfig } from '@next/env';
import { createClient } from '@libsql/client';
import { migrateNotionDatabase } from '../lib/db';

loadEnvConfig(process.cwd());
async function main() {
  const url = process.env.TURSO_DATABASE_URL;
  const authToken = process.env.TURSO_AUTH_TOKEN;
  if (!url || (!url.startsWith('file:') && !authToken)) {
    throw new Error('Set TURSO_DATABASE_URL and TURSO_AUTH_TOKEN before migrating.');
  }
  const db = createClient({ url, authToken });
  try {
    await migrateNotionDatabase(db);
    for (const table of ['notion_states', 'notion_tickets', 'notion_limits']) {
      const result = await db.execute(`PRAGMA table_info(${table})`);
      if (!result.rows.length) throw new Error(`Missing table: ${table}`);
      console.log(`Verified ${table}: ${result.rows.map(row => row.name).join(', ')}`);
    }
    console.log('Database migration completed.');
  } finally { db.close(); }
}
main().catch(error => {
  console.error('Migration failed:', error instanceof Error ? error.message : 'Unknown error');
  process.exitCode = 1;
});
