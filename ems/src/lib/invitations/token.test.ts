import { describe, expect, it } from "vitest";
import { buildInviteUrl, generateInvitationToken, hashToken, invitationExpiry, isExpired, isValidEmail } from "./token";

describe("invitation tokens", () => {
  it("generates unique, long, url-safe tokens", () => {
    const a = generateInvitationToken(), b = generateInvitationToken();
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThanOrEqual(43);
    expect(a).toMatch(/^[A-Za-z0-9_-]+$/);
  });
  it("hash is deterministic, hex, and never equals the token", () => {
    const t = generateInvitationToken();
    expect(hashToken(t)).toBe(hashToken(t));
    expect(hashToken(t)).toMatch(/^[0-9a-f]{64}$/);
    expect(hashToken(t)).not.toBe(t);
    expect(hashToken(t)).not.toBe(hashToken(t + "x"));
  });
  it("expiry", () => {
    const now = new Date("2026-01-01T00:00:00Z");
    const exp = invitationExpiry(72, now);
    expect(exp.toISOString()).toBe("2026-01-04T00:00:00.000Z");
    expect(isExpired(exp, new Date("2026-01-03T23:59:59Z"))).toBe(false);
    expect(isExpired(exp, exp)).toBe(true);
  });
  it("puts the token in the URL fragment so it is not sent to servers or logs", () => {
    expect(buildInviteUrl("https://app.test/", "abc")).toBe("https://app.test/accept-invite#token=abc");
  });
  it("validates emails", () => {
    expect(isValidEmail("a@b.co")).toBe(true);
    expect(isValidEmail("nope")).toBe(false);
    expect(isValidEmail("a b@c.com")).toBe(false);
  });
});
