import { useEffect, useState } from "react";
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

export function SiteHeader({ jsonHref, onHome }: { jsonHref: string; onHome?: () => void }) {
  const [gh, setGh] = useState(false);
  useEffect(() => setGh(true), []); // lucide's Github is fine client-side; keeps SSR-safe habit out of the way

  return (
    <header className="bg-background/80 sticky top-0 z-40 border-b backdrop-blur">
      <div className="mx-auto flex h-14 max-w-7xl items-center justify-between gap-3 px-4">
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
          <span className="flex items-baseline gap-1.5">
            agent-detect
            <span className="text-muted-foreground hidden text-xs font-normal sm:inline">registry</span>
          </span>
        </a>
        <nav className="flex items-center gap-1 text-sm">
          <a
            href="https://github.com/bevry-vibes/agent-detect"
            target="_blank"
            rel="noreferrer"
            className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1.5 rounded-md px-2 py-1.5"
          >
            {gh ? <Github className="size-4" /> : null}
            <span className="hidden sm:inline">GitHub</span>
          </a>
          <a href="/llms.txt" className="text-muted-foreground hover:text-foreground rounded-md px-2 py-1.5">
            llms.txt
          </a>
          <a href={jsonHref} className="text-muted-foreground hover:text-foreground hidden sm:inline rounded-md px-2 py-1.5 font-mono text-xs">
            index.json
          </a>
          <ThemeToggle />
        </nav>
      </div>
    </header>
  );
}
