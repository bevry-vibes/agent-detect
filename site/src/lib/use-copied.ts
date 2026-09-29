import { useCallback, useEffect, useRef, useState } from "react";

/** clipboard copy with a transient "copied" flag — the shared pattern behind
 * every copy button on the site. The flag clears itself `resetMs` after the
 * last successful copy (and on unmount); when the clipboard is unavailable
 * (insecure context) `copy` resolves without flipping the flag — the content
 * stays selectable. */
export function useCopied(resetMs = 1500): { copied: boolean; copy: (text: string) => Promise<void> } {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );

  const copy = useCallback(
    async (text: string) => {
      try {
        await navigator.clipboard.writeText(text);
        setCopied(true);
        if (timer.current) clearTimeout(timer.current);
        timer.current = setTimeout(() => setCopied(false), resetMs);
      } catch {
        // clipboard unavailable — handled by the caller's UI staying unchanged
      }
    },
    [resetMs],
  );

  return { copied, copy };
}
