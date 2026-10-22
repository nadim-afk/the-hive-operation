export interface EmailEnv { RESEND_API_KEY?: string; EMAIL_FROM?: string }
export interface SendResult { sent: boolean; reason?: "not_configured" | "provider_error"; status?: number }

export const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

export function invitationEmail(p: { name: string; companyName: string; acceptUrl: string; expiresAt: Date }) {
  const name = escapeHtml(p.name), company = escapeHtml(p.companyName), url = escapeHtml(p.acceptUrl);
  return {
    subject: `You're invited to join ${p.companyName}`,
    html: `<p>Hi ${name},</p><p>${company} invited you to its employee portal.</p>` +
      `<p><a href="${url}">Accept invitation</a></p>` +
      `<p>This single-use link expires on ${p.expiresAt.toUTCString()}. If you weren't expecting it, ignore this email.</p>`,
  };
}

/** Resend REST adapter. Returns not_configured (does not throw) when keys are missing. */
export async function sendEmail(
  msg: { to: string; subject: string; html: string },
  env: EmailEnv,
  fetchImpl: typeof fetch = fetch,
): Promise<SendResult> {
  if (!env.RESEND_API_KEY || !env.EMAIL_FROM) return { sent: false, reason: "not_configured" };
  const res = await fetchImpl("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: env.EMAIL_FROM, to: [msg.to], subject: msg.subject, html: msg.html }),
  });
  return res.ok ? { sent: true, status: res.status } : { sent: false, reason: "provider_error", status: res.status };
}
