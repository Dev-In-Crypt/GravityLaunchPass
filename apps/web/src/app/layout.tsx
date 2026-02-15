import "./globals.css";
import Link from "next/link";
import { Providers } from "./providers";
import type { ReactNode } from "react";

export const metadata = {
  title: "Gravity LaunchPass",
  description: "Stage 2 escrow UI",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <nav>
            <strong>Gravity LaunchPass</strong>
            <Link href="/">Create Job</Link>
            <Link href="/jobs">Jobs</Link>
            <Link href="/withdraw">Withdraw</Link>
          </nav>
          <main>{children}</main>
        </Providers>
      </body>
    </html>
  );
}
