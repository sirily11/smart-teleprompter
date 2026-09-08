import { handleNotion } from '../../../../lib/notion';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) { return handleNotion('callback', request); }
