import { handleNotion } from '../../../../lib/notion';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function POST(request: Request) { return handleNotion('exchange', request); }
