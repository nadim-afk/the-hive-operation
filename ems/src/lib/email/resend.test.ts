import { describe, expect, it, vi } from "vitest";
import { escapeHtml, invitationEmail, sendEmail } from "./resend";

describe("email", () => {
  it("is a safe no-op without credentials", async () => {
    const f = vi.fn();
    expect(await sendEmail({ to: "a@b.co", subject: "s", html: "h" }, {}, f as any)).toEqual({ sent: false, reason: "not_configured" });
    expect(f).not.toHaveBeenCalled();
  });
  it("calls Resend with bearer auth when configured", async () => {
    const f = vi.fn().mockResolvedValue({ ok: true, status: 200 });
    const r = await sendEmail({ to: "a@b.co", subject: "s", html: "h" }, { RESEND_API_KEY: "k", EMAIL_FROM: "x@y.co" }, f as any);
    expect(r.sent).toBe(true);
    expect(f.mock.calls[0]![1].headers.Authorization).toBe("Bearer k");
  });
  it("reports provider errors", async () => {
    const f = vi.fn().mockResolvedValue({ ok: false, status: 422 });
    expect((await sendEmail({ to: "a@b.co", subject: "s", html: "h" }, { RESEND_API_KEY: "k", EMAIL_FROM: "x@y.co" }, f as any)).reason).toBe("provider_error");
  });
  it("escapes user-controlled values in the template", () => {
    const m = invitationEmail({ name: "<script>x</script>", companyName: "A&B", acceptUrl: "https://a.test/?a=1&b=2", expiresAt: new Date(0) });
    expect(m.html).not.toContain("<script>");
    expect(m.html).toContain("A&amp;B");
    expect(escapeHtml(`"'`)).toBe("&quot;&#39;");
  });
});
