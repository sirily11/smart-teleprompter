import type { Metadata } from 'next';
import Link from 'next/link';
import './globals.css';
export const metadata: Metadata = { title: { default: 'Smart Teleprompter — RxLab', template: '%s · Smart Teleprompter' }, description: 'Privacy, terms, and support for Smart Teleprompter by RxLab.' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body><header><Link href="/" className="brand"><span className="mark">S</span>Smart Teleprompter</Link><nav aria-label="Legal"><Link href="/privacy">Privacy</Link><Link href="/tos">Terms</Link></nav></header><main>{children}</main><footer>© {new Date().getFullYear()} RxLab <span>Speak at your own pace.</span></footer></body></html>;
}
