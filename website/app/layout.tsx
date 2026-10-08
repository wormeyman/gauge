import type { Metadata, Viewport } from "next";
import "./globals.css";

const title = "Gauge · A precise, private system monitor for macOS";
const description =
  "Gauge is a native SwiftUI system monitor for macOS 26. Live CPU, memory pressure, GPU, disk, network and battery readings, charts you can hover, and history that never leaves your Mac.";

export const metadata: Metadata = {
  metadataBase: new URL("https://gauge.alex.codes"),
  title,
  description,
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    url: "/",
    siteName: "Gauge",
    title,
    description: "Native SwiftUI. Live readings. History stays on your Mac.",
  },
  twitter: { card: "summary_large_image", title, description: "Native SwiftUI. Live readings. History stays on your Mac." },
};

export const viewport: Viewport = { themeColor: "#fbfaf8" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
