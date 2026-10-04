/** One committed daily limit. It stays in force until a later change. */

export interface LimitVersion {
  limitMs: number;
  effectiveAtMs: number;
}

/**
 * The limit that governs `cutoffMs`.
 * A change takes effect immediately, including the rest of today.
 * A later change does not rewrite a day that had already ended.
 * Until the next change, this same value keeps governing later days.
 */
export function standingLimit(versions: LimitVersion[], cutoffMs: number): number | null {
  let best: LimitVersion | null = null;
  for (const version of versions) {
    if (version.effectiveAtMs > cutoffMs) continue;
    if (!best || version.effectiveAtMs >= best.effectiveAtMs) best = version;
  }
  return best ? best.limitMs : null;
}

/** Today uses now. A finished day uses its last millisecond, so a midnight change belongs to the new day. */
export function limitCutoff(dayEndMs: number, now: number): number {
  return dayEndMs > now ? now : dayEndMs - 1;
}
