import type { ApiError } from "../api";
import { Button } from "./ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "./ui/card";
import { Input } from "./ui/input";

function loginErrorMessage(error: ApiError | null): string | null {
  if (!error) {
    return null;
  }
  if (error.code === "rate_limited") {
    return "Too many login attempts. Wait a moment and try again.";
  }
  return "Login failed. Check your password.";
}

export function codeErrorMessage(error: ApiError | null): string | null {
  if (!error) {
    return null;
  }
  switch (error.code) {
    case "invalid_code":
      return "That code is not right. Codes change every 30 seconds, and each one works once.";
    case "too_many_attempts":
      return "Too many wrong codes. Start again with your password.";
    case "login_expired":
      return "That sign-in took too long. Start again with your password.";
    case "2fa_locked":
    case "rate_limited":
      return "Too many attempts. Wait a minute and try again.";
    case "2fa_unreadable":
      return "The saved two-factor secret cannot be read. On the server run: gatekeeper 2fa-reset";
    default:
      return "Could not check the code. Try again.";
  }
}

export function LoginCard({
  password,
  onPasswordChange,
  onSubmit,
  isSubmitting,
  error
}: {
  password: string;
  onPasswordChange: (value: string) => void;
  onSubmit: () => void;
  isSubmitting: boolean;
  error: ApiError | null;
}) {
  const errorMessage = loginErrorMessage(error);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-2xl">ha-gatekeeper</CardTitle>
        <p className="text-sm text-[var(--muted)]">Session-based admin console login</p>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2">
          <label htmlFor="admin-password" className="text-xs font-semibold uppercase text-[var(--muted)]">
            Admin password
          </label>
          <Input
            id="admin-password"
            type="password"
            placeholder="Admin password"
            value={password}
            onChange={(event) => onPasswordChange(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                onSubmit();
              }
            }}
          />
        </div>
        <Button className="w-full" onClick={onSubmit} disabled={isSubmitting}>
          {isSubmitting ? "Logging in..." : "Log in"}
        </Button>
        {errorMessage ? (
          <p className="rounded-md border border-[var(--danger-border)] bg-[var(--danger-soft)] p-3 text-sm text-[var(--danger)]">
            {errorMessage}
          </p>
        ) : null}
      </CardContent>
    </Card>
  );
}

// Second step when two-factor login is on: the password was accepted, now the code from the
// authenticator app (or one of the saved recovery codes).
export function TwoFactorCard({
  code,
  onCodeChange,
  onSubmit,
  onCancel,
  isSubmitting,
  error
}: {
  code: string;
  onCodeChange: (value: string) => void;
  onSubmit: () => void;
  onCancel: () => void;
  isSubmitting: boolean;
  error: ApiError | null;
}) {
  const errorMessage = codeErrorMessage(error);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-2xl">Two-factor code</CardTitle>
        <p className="text-sm text-[var(--muted)]">
          Open your authenticator app and enter the 6-digit code for ha-gatekeeper. Lost your phone? Use one of your
          recovery codes (like K7QF-2M9X-ABCD) instead.
        </p>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2">
          <label htmlFor="admin-code" className="text-xs font-semibold uppercase text-[var(--muted)]">
            Code
          </label>
          <Input
            id="admin-code"
            type="text"
            inputMode="text"
            autoComplete="one-time-code"
            autoFocus
            placeholder="123456"
            value={code}
            onChange={(event) => onCodeChange(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                onSubmit();
              }
            }}
          />
        </div>
        <div className="flex gap-2">
          <Button className="flex-1" onClick={onSubmit} disabled={isSubmitting || code.trim().length < 6}>
            {isSubmitting ? "Checking..." : "Continue"}
          </Button>
          <Button variant="secondary" onClick={onCancel}>
            Start over
          </Button>
        </div>
        {errorMessage ? (
          <p className="rounded-md border border-[var(--danger-border)] bg-[var(--danger-soft)] p-3 text-sm text-[var(--danger)]">
            {errorMessage}
          </p>
        ) : null}
      </CardContent>
    </Card>
  );
}
