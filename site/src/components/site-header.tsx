import { useState } from "react";
import { Github, Moon, Sun } from "lucide-react";

import { Button } from "@/components/ui/button";

function ThemeToggle() {
  const [dark, setDark] = useState(() => document.documentElement.classList.contains("dark"));

  const toggle = () => {
    const next = !dark;
    setDark(next);
    document.documentElement.classList.toggle("dark", next);
    try {
      localStorage.setItem("ad-theme", next ? "dark" : "light");
    } catch {
      // storage unavailable — the toggle still works for the session
    }
  };

  return (
    <Button variant="ghost" size="icon" onClick={toggle} aria-label="toggle theme">
      {dark ? <Sun /> : <Moon />}
    </Button>
  );
}

export interface AnchorLink {
  label: string;
  /** absent = a plain label, not a link (the result-type indicator) */
  href?: string;
}

export function SiteHeader({
  onHome,
  centerNav,
  onNavClick,
}: {
  onHome?: () => void;
  centerNav?: AnchorLink[];
  /** return true when the click was handled (e.g. leaving the agent page) so
   * the native anchor jump is suppressed */
  onNavClick?: (href: string) => boolean;
}) {
  return (
    <header className="bg-background/80 sticky top-0 z-40 border-b backdrop-blur">
      <div className="relative mx-auto flex h-14 max-w-7xl items-center justify-between gap-3 px-4">
        <a
          href="/"
          className="flex shrink-0 items-center gap-2 whitespace-nowrap font-semibold tracking-tight"
          onClick={(e) => {
            if (onHome) {
              e.preventDefault();
              onHome();
            }
          }}
          title={onHome ? "back to the results index" : undefined}
        >
          <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
            <circle cx="12" cy="12" r="9" className="opacity-40" />
            <circle cx="12" cy="12" r="4.5" className="opacity-70" />
            <circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none" />
            <path d="M12 3v2.5M21 12h-2.5M12 21v-2.5M3 12h2.5" className="opacity-40" />
          </svg>
          <span className="hidden min-[420px]:flex items-center">agent-detect</span>
        </a>
        {centerNav && centerNav.length > 0 && (
          <nav
            aria-label="page sections"
            className="absolute left-1/2 -translate-x-1/2 flex items-center gap-0.5 md:gap-1"
          >
            {centerNav.map((link) =>
              link.href ? (
                <a
                  key={link.href}
                  href={link.href}
                  className="text-muted-foreground hover:text-foreground inline-flex h-9 items-center rounded-md px-1.5 text-xs md:px-3 md:text-sm"
                  onClick={(e) => {
                    if (link.href && onNavClick?.(link.href)) e.preventDefault();
                  }}
                >
                  {link.label}
                </a>
              ) : (
                <span
                  key={link.label}
                  className="text-foreground inline-flex h-9 items-center rounded-md px-1.5 text-xs font-medium md:px-3 md:text-sm"
                >
                  {link.label}
                </span>
              ),
            )}
          </nav>
        )}
        <nav className="flex items-center gap-1 text-sm">
          <a
            href="https://github.com/bevry-vibes/agent-detect"
            target="_blank"
            rel="noreferrer"
            className="text-muted-foreground hover:text-foreground inline-flex h-9 items-center gap-1.5 rounded-md px-2"
          >
            <Github className="size-4" />
            <span className="hidden sm:inline">GitHub</span>
          </a>
          <ThemeToggle />
        </nav>
      </div>
    </header>
  );
}
