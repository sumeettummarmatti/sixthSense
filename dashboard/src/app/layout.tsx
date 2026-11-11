import type { Metadata } from "next";

import "./globals.css";

export const metadata: Metadata = {
  title: "SixthSense Dashboard",
  description: "Campus safety clusters: aggregates only, never individuals.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
