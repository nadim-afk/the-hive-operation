import { createHash, randomBytes } from "node:crypto";

/** 256-bit URL-safe token. Send this in the email link; store ONLY hashToken(token). */
export function generateInvitationToken(): string {
  return randomBytes(32).toString("base64url");
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export function invitationExpiry(ttlHours: number, now: Date = new Date()): Date {
  return new Date(now.getTime() + ttlHours * 3_600_000);
}

export function isExpired(expiresAt: Date, now: Date = new Date()): boolean {
  return expiresAt.getTime() <= now.getTime();
}

export function buildInviteUrl(appUrl: string, token: string): string {
  return `${appUrl.replace(/\/+$/, "")}/accept-invite#token=${encodeURIComponent(token)}`;
}

export const isValidEmail = (e: string) => e.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e);
