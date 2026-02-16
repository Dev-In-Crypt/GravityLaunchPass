import "./globals.css";
import { Providers } from "./providers";
import type { ReactNode } from "react";
import { NavBar } from "./NavBar";

export const metadata = {
  title: "Gravity LaunchPass",
  description: "Stage 2 escrow UI",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <NavBar />
          <main>{children}</main>
        </Providers>
      </body>
    </html>
  );
}
