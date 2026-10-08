import type { NextConfig } from "next";

// No third-party requests: the site loads only its own scripts, styles and images.
const securityHeaders = [
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), browsing-topics=()" },
  ...(process.env.NODE_ENV === "production"
    ? [{
        key: "Content-Security-Policy",
        value: "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'",
      }]
    : []),
];

const nextConfig: NextConfig = {
  poweredByHeader: false,
  images: { formats: ["image/avif", "image/webp"] },
  async headers() {
    return [
      { source: "/(.*)", headers: securityHeaders },
      // Sparkle's update feed: always revalidate so new releases show up promptly.
      { source: "/appcast.xml", headers: [{ key: "Cache-Control", value: "public, max-age=0, s-maxage=300, must-revalidate" }] },
    ];
  },
};

export default nextConfig;
