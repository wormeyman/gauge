"use client";

import { useEffect, useState, type ReactNode } from "react";

/** Sticky nav that gains a hairline once the page scrolls. */
export function Nav({ children }: { children: ReactNode }) {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);
  return <header className={`nav${scrolled ? " scrolled" : ""}`}>{children}</header>;
}

/** Copies the build commands, without the prompt characters. */
export function CopyButton({ text }: { text: string }) {
  const [label, setLabel] = useState("Copy");
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setLabel("Copied");
    } catch {
      setLabel("Select and copy");
    }
    setTimeout(() => setLabel("Copy"), 1600);
  }
  return <button className="copy" type="button" onClick={copy}>{label}</button>;
}

/** Fades sections in as they scroll into view. Added after hydration so the page reads fine without JS. */
export function RevealOnScroll() {
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) return;
    const targets = document.querySelectorAll<HTMLElement>(
      ".section-head, .split-copy, .split-media, .demo, .card, .privacy-grid, .path, .native-grid, .cta-card, .strip",
    );
    const io = new IntersectionObserver(entries => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    let card = 0;
    targets.forEach(el => {
      const box = el.getBoundingClientRect();
      if (box.top < window.innerHeight) return; // already on screen: leave it visible
      el.classList.add("reveal");
      if (el.classList.contains("card")) el.style.transitionDelay = `${(card++ % 2) * 70}ms`;
      io.observe(el);
    });
    return () => io.disconnect();
  }, []);
  return null;
}
