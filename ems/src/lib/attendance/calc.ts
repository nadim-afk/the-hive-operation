export interface Rules {
  graceMinutes: number;
  autoBreakMinutes: number;
  autoBreakAfterMinutes: number;
  overtimeAfterMinutes: number;
  missingCheckoutAfterHours: number;
}

export const DEFAULT_RULES: Rules = {
  graceMinutes: 5,
  autoBreakMinutes: 30,
  autoBreakAfterMinutes: 360,
  overtimeAfterMinutes: 480,
  missingCheckoutAfterHours: 14,
};

export interface SessionInput {
  checkInAt: Date;
  checkOutAt: Date | null;
  shiftStart?: Date | null;
  shiftEnd?: Date | null;
  /** Minutes of breaks actually recorded. If null/undefined, the auto-break rule applies. */
  recordedBreakMinutes?: number | null;
}

export type PunctualityStatus = "on_time" | "late" | "no_shift";
export type SessionState = "in_progress" | "completed" | "missing_checkout";

export interface SessionResult {
  state: SessionState;
  punctuality: PunctualityStatus;
  lateMinutes: number;
  leftEarly: boolean;
  earlyDepartureMinutes: number;
  grossMinutes: number;
  breakMinutes: number;
  netMinutes: number;
  overtimeMinutes: number;
}

const minutesBetween = (a: Date, b: Date) => Math.floor((b.getTime() - a.getTime()) / 60000);

/**
 * Pure attendance calculation. `now` is only used for open sessions.
 * Whole minutes, floored. Late = minutes after shift start beyond the grace period.
 */
export function computeSession(input: SessionInput, rules: Rules = DEFAULT_RULES, now: Date = new Date()): SessionResult {
  const { checkInAt, checkOutAt, shiftStart, shiftEnd } = input;
  const end = checkOutAt ?? now;
  const gross = Math.max(0, minutesBetween(checkInAt, end));

  let breakMinutes: number;
  if (input.recordedBreakMinutes != null) breakMinutes = input.recordedBreakMinutes;
  else breakMinutes = gross >= rules.autoBreakAfterMinutes ? rules.autoBreakMinutes : 0;
  breakMinutes = Math.min(Math.max(0, breakMinutes), gross);

  const net = gross - breakMinutes;
  const overtime = checkOutAt ? Math.max(0, net - rules.overtimeAfterMinutes) : 0;

  let punctuality: PunctualityStatus = "no_shift";
  let lateMinutes = 0;
  if (shiftStart) {
    lateMinutes = Math.max(0, minutesBetween(shiftStart, checkInAt));
    punctuality = lateMinutes > rules.graceMinutes ? "late" : "on_time";
    if (punctuality === "on_time") lateMinutes = 0;
  }

  let earlyDepartureMinutes = 0;
  if (checkOutAt && shiftEnd) earlyDepartureMinutes = Math.max(0, minutesBetween(checkOutAt, shiftEnd));

  let state: SessionState = "completed";
  if (!checkOutAt) {
    state = gross > rules.missingCheckoutAfterHours * 60 ? "missing_checkout" : "in_progress";
  }

  return {
    state, punctuality, lateMinutes,
    leftEarly: earlyDepartureMinutes > rules.graceMinutes,
    earlyDepartureMinutes, grossMinutes: gross, breakMinutes, netMinutes: net, overtimeMinutes: overtime,
  };
}

/** Offset (ms) of `tz` from UTC at the given instant. */
function tzOffsetMs(utcMs: number, tz: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(utcMs));
  const g = (t: string) => Number(parts.find((p) => p.type === t)!.value);
  const asUtc = Date.UTC(g("year"), g("month") - 1, g("day"), g("hour"), g("minute"), g("second"));
  return asUtc - Math.floor(utcMs / 1000) * 1000;
}

/** Convert a local wall-clock date/time in `tz` to a UTC Date (DST-safe). */
export function zonedToUtc(date: string, time: string, tz: string): Date {
  const [y, mo, d] = date.split("-").map(Number) as [number, number, number];
  const [h, mi] = time.split(":").map(Number) as [number, number];
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  let utc = guess - tzOffsetMs(guess, tz);
  utc = guess - tzOffsetMs(utc, tz); // second pass handles DST boundaries
  return new Date(utc);
}

export function formatDuration(minutes: number): string {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return `${h} hour${h === 1 ? "" : "s"} ${m} minute${m === 1 ? "" : "s"}`;
}
