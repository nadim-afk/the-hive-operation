import { describe, expect, it } from "vitest";
import { computeSession, DEFAULT_RULES, formatDuration, zonedToUtc } from "./calc";

const d = (s: string) => new Date(s);
const shift = { shiftStart: d("2026-01-15T09:00:00Z"), shiftEnd: d("2026-01-15T17:00:00Z") };

describe("computeSession", () => {
  it("on time within grace", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T09:04:00Z"), checkOutAt: d("2026-01-15T17:00:00Z"), ...shift });
    expect(r.punctuality).toBe("on_time");
    expect(r.lateMinutes).toBe(0);
  });
  it("late beyond grace", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T09:12:00Z"), checkOutAt: d("2026-01-15T17:00:00Z"), ...shift });
    expect(r.punctuality).toBe("late");
    expect(r.lateMinutes).toBe(12);
  });
  it("early check-in is on time", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T08:50:00Z"), checkOutAt: null, ...shift }, DEFAULT_RULES, d("2026-01-15T09:00:00Z"));
    expect(r.punctuality).toBe("on_time");
    expect(r.state).toBe("in_progress");
  });
  it("no shift", () => {
    expect(computeSession({ checkInAt: d("2026-01-15T09:00:00Z"), checkOutAt: d("2026-01-15T10:00:00Z") }).punctuality).toBe("no_shift");
  });
  it("matches the spec example: 8h10m gross, 30m break, 7h40m net", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T09:02:00Z"), checkOutAt: d("2026-01-15T17:12:00Z"), ...shift });
    expect(r.grossMinutes).toBe(490);
    expect(r.breakMinutes).toBe(30);
    expect(r.netMinutes).toBe(460);
    expect(formatDuration(r.grossMinutes)).toBe("8 hours 10 minutes");
    expect(formatDuration(r.netMinutes)).toBe("7 hours 40 minutes");
  });
  it("no auto break on short sessions", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T09:00:00Z"), checkOutAt: d("2026-01-15T12:00:00Z") });
    expect(r.breakMinutes).toBe(0);
  });
  it("recorded break overrides auto break, including zero", () => {
    const base = { checkInAt: d("2026-01-15T09:00:00Z"), checkOutAt: d("2026-01-15T17:00:00Z") };
    expect(computeSession({ ...base, recordedBreakMinutes: 45 }).breakMinutes).toBe(45);
    expect(computeSession({ ...base, recordedBreakMinutes: 0 }).breakMinutes).toBe(0);
  });
  it("break never exceeds gross", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T09:00:00Z"), checkOutAt: d("2026-01-15T09:10:00Z"), recordedBreakMinutes: 60 });
    expect(r.netMinutes).toBe(0);
  });
  it("overtime past the configured threshold", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T09:00:00Z"), checkOutAt: d("2026-01-15T19:00:00Z"), recordedBreakMinutes: 60 });
    expect(r.netMinutes).toBe(540);
    expect(r.overtimeMinutes).toBe(60);
  });
  it("early departure beyond grace", () => {
    const r = computeSession({ checkInAt: d("2026-01-15T09:00:00Z"), checkOutAt: d("2026-01-15T16:30:00Z"), ...shift });
    expect(r.leftEarly).toBe(true);
    expect(r.earlyDepartureMinutes).toBe(30);
  });
  it("open session flagged missing_checkout after threshold", () => {
    const open = { checkInAt: d("2026-01-15T09:00:00Z"), checkOutAt: null };
    expect(computeSession(open, DEFAULT_RULES, d("2026-01-15T20:00:00Z")).state).toBe("in_progress");
    expect(computeSession(open, DEFAULT_RULES, d("2026-01-16T00:00:00Z")).state).toBe("missing_checkout");
  });
});

describe("zonedToUtc", () => {
  it("Dhaka (UTC+6, no DST)", () => {
    expect(zonedToUtc("2026-01-15", "09:00", "Asia/Dhaka").toISOString()).toBe("2026-01-15T03:00:00.000Z");
  });
  it("New York winter vs summer (DST)", () => {
    expect(zonedToUtc("2026-01-15", "09:00", "America/New_York").toISOString()).toBe("2026-01-15T14:00:00.000Z");
    expect(zonedToUtc("2026-07-15", "09:00", "America/New_York").toISOString()).toBe("2026-07-15T13:00:00.000Z");
  });
  it("day of DST change (2026-03-08, US)", () => {
    expect(zonedToUtc("2026-03-08", "09:00", "America/New_York").toISOString()).toBe("2026-03-08T13:00:00.000Z");
  });
});
