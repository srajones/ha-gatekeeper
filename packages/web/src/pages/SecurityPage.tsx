import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type ApiError, type TwoFactorSetup } from "../api";
import { codeErrorMessage } from "../components/LoginCard";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";

function errorText(error: ApiError | null): string | null {
  if (!error) return null;
  if (error.code === "invalid_credentials") return "The password is not right.";
  if (error.code === "setup_expired") return "The setup took too long. Start again.";
  if (error.code === "already_enabled") return "Two-factor login is already on.";
  return codeErrorMessage(error);
}

function ErrorLine({ error }: { error: ApiError | null }) {
  const text = errorText(error);
  if (!text) return null;
  return (
    <p className="rounded-md border border-[var(--danger-border)] bg-[var(--danger-soft)] p-3 text-sm text-[var(--danger)]">
      {text}
    </p>
  );
}

function RecoveryCodes({ codes, onDone }: { codes: string[]; onDone: () => void }) {
  const [saved, setSaved] = useState(false);
  const text = codes.join("\n");
  return (
    <div className="space-y-3">
      <p className="rounded-md border border-[var(--warning-border,var(--border))] bg-[var(--surface-muted)] p-3 text-sm">
        <strong>Save these recovery codes now.</strong> They are shown only once. Each works one time if you lose your
        phone. Store them somewhere safe (a password manager, or printed).
      </p>
      <ul className="grid grid-cols-2 gap-2 font-mono text-sm sm:grid-cols-3" aria-label="Recovery codes">
        {codes.map((code) => (
          <li key={code} className="rounded-md border border-[var(--border)] px-2 py-1">
            {code}
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-2">
        <Button variant="secondary" size="sm" onClick={() => void navigator.clipboard?.writeText(text)}>
          Copy
        </Button>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => {
            const url = URL.createObjectURL(new Blob([`ha-gatekeeper recovery codes\n\n${text}\n`], { type: "text/plain" }));
            const a = document.createElement("a");
            a.href = url;
            a.download = "ha-gatekeeper-recovery-codes.txt";
            a.click();
            URL.revokeObjectURL(url);
          }}
        >
          Download
        </Button>
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={saved} onChange={(event) => setSaved(event.target.checked)} />
        I have saved my recovery codes
      </label>
      <Button onClick={onDone} disabled={!saved}>
        Done
      </Button>
    </div>
  );
}

function EnableFlow({ onCodes }: { onCodes: (codes: string[]) => void }) {
  const queryClient = useQueryClient();
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [setup, setSetup] = useState<TwoFactorSetup | null>(null);

  const setupMutation = useMutation<TwoFactorSetup, ApiError, string>({
    mutationFn: (pwd) => api.twoFactorSetup(pwd),
    onSuccess: (data) => {
      setSetup(data);
      setPassword("");
    }
  });
  const enableMutation = useMutation<{ recoveryCodes: string[] }, ApiError, string>({
    mutationFn: (value) => api.twoFactorEnable(value),
    onSuccess: (data) => {
      // The codes are handed to the page first: refreshing the status flips this screen to "on", which
      // would otherwise unmount it and lose the one and only display of the codes.
      onCodes(data.recoveryCodes);
      setSetup(null);
      setCode("");
      queryClient.invalidateQueries({ queryKey: ["two-factor"] });
    }
  });

  if (!setup) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-[var(--muted)]">
          You will need an authenticator app on your phone (Google Authenticator, Aegis, 1Password, Bitwarden, Authy...).
          Confirm your password to begin.
        </p>
        <label htmlFor="tf-password" className="block text-xs font-semibold uppercase text-[var(--muted)]">
          Admin password
        </label>
        <Input id="tf-password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
        <Button onClick={() => setupMutation.mutate(password)} disabled={!password || setupMutation.isPending}>
          {setupMutation.isPending ? "Working..." : "Start setup"}
        </Button>
        <ErrorLine error={setupMutation.error} />
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <ol className="list-decimal space-y-2 pl-5 text-sm">
        <li>
          In your authenticator app choose <em>add account</em> and <em>enter a setup key</em> (or open the link below on
          your phone), then enter this key:
          <div className="mt-2 break-all rounded-md border border-[var(--border)] bg-[var(--surface-muted)] px-3 py-2 font-mono text-base tracking-wider" data-testid="totp-secret">
            {setup.secret}
          </div>
          <a className="mt-1 inline-block text-[var(--primary)] underline" href={setup.otpauthUri}>
            Open in authenticator app
          </a>
          <p className="mt-1 text-[var(--muted)]">Type: time-based. Anyone with this key can generate your codes, so do not share it.</p>
        </li>
        <li>Type the 6-digit code the app now shows to confirm it works:</li>
      </ol>
      <Input
        aria-label="6-digit code"
        inputMode="numeric"
        autoComplete="one-time-code"
        placeholder="123456"
        value={code}
        onChange={(e) => setCode(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && code.trim().length >= 6) enableMutation.mutate(code);
        }}
      />
      <div className="flex gap-2">
        <Button onClick={() => enableMutation.mutate(code)} disabled={code.trim().length < 6 || enableMutation.isPending}>
          {enableMutation.isPending ? "Checking..." : "Turn on two-factor login"}
        </Button>
        <Button variant="secondary" onClick={() => { setSetup(null); setCode(""); }}>
          Cancel
        </Button>
      </div>
      <ErrorLine error={enableMutation.error} />
    </div>
  );
}

function ManageFlow({ recoveryCodesLeft, onCodes }: { recoveryCodesLeft: number; onCodes: (codes: string[]) => void }) {
  const queryClient = useQueryClient();
  const [mode, setMode] = useState<"idle" | "disable" | "codes">("idle");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");

  const reset = () => { setMode("idle"); setPassword(""); setCode(""); };
  const disableMutation = useMutation<{}, ApiError, void>({
    mutationFn: () => api.twoFactorDisable(password, code),
    onSuccess: () => { reset(); queryClient.invalidateQueries({ queryKey: ["two-factor"] }); }
  });
  const codesMutation = useMutation<{ recoveryCodes: string[] }, ApiError, void>({
    mutationFn: () => api.twoFactorRecoveryCodes(password, code),
    onSuccess: (data) => { onCodes(data.recoveryCodes); reset(); queryClient.invalidateQueries({ queryKey: ["two-factor"] }); }
  });

  if (mode === "idle") {
    return (
      <div className="space-y-3">
        <p className="text-sm">
          Recovery codes left: <strong>{recoveryCodesLeft}</strong>
          {recoveryCodesLeft <= 2 ? " - running low, make new ones." : ""}
        </p>
        <div className="flex flex-wrap gap-2">
          <Button variant="secondary" onClick={() => setMode("codes")}>Make new recovery codes</Button>
          <Button variant="danger" onClick={() => setMode("disable")}>Turn off two-factor login</Button>
        </div>
      </div>
    );
  }

  const mutation = mode === "disable" ? disableMutation : codesMutation;
  return (
    <div className="space-y-3">
      <p className="text-sm text-[var(--muted)]">
        {mode === "disable"
          ? "Turning it off makes the password the only protection again."
          : "The old recovery codes stop working as soon as you make new ones."}{" "}
        Enter your password and a current code (or a recovery code).
      </p>
      <label htmlFor="tf-pw2" className="block text-xs font-semibold uppercase text-[var(--muted)]">Admin password</label>
      <Input id="tf-pw2" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <label htmlFor="tf-code2" className="block text-xs font-semibold uppercase text-[var(--muted)]">Code</label>
      <Input id="tf-code2" autoComplete="one-time-code" value={code} onChange={(e) => setCode(e.target.value)} />
      <div className="flex gap-2">
        <Button
          variant={mode === "disable" ? "danger" : "default"}
          onClick={() => mutation.mutate()}
          disabled={!password || code.trim().length < 6 || mutation.isPending}
        >
          {mutation.isPending ? "Working..." : mode === "disable" ? "Turn off" : "Make new codes"}
        </Button>
        <Button variant="secondary" onClick={reset}>Cancel</Button>
      </div>
      <ErrorLine error={mutation.error} />
    </div>
  );
}

export function SecurityPage() {
  const query = useQuery({ queryKey: ["two-factor"], queryFn: api.twoFactor });
  const [enabling, setEnabling] = useState(false);
  const [shownCodes, setShownCodes] = useState<string[] | null>(null);
  const status = query.data;

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <div className="flex flex-wrap items-center gap-3">
            <CardTitle>Two-factor login</CardTitle>
            {status ? (
              <Badge variant={status.enabled ? "success" : "warning"}>{status.enabled ? "On" : "Off"}</Badge>
            ) : null}
          </div>
          <p className="text-sm text-[var(--muted)]">
            Adds a code from your phone to the admin login, so a stolen or guessed password is not enough. It protects the
            dashboard only; API keys are separate and unaffected.
          </p>
        </CardHeader>
        <CardContent className="space-y-4">
          {query.isLoading ? <p className="text-sm text-[var(--muted)]">Loading...</p> : null}
          {query.isError ? <p className="text-sm text-[var(--danger)]">Could not load the two-factor status.</p> : null}
          {status && !status.available ? (
            <p className="text-sm text-[var(--muted)]">
              Not used here: in the Home Assistant add-on, sign-in is handled by Home Assistant itself. Turn on two-factor
              (multi-factor) authentication in your Home Assistant profile instead.
            </p>
          ) : null}
          {shownCodes ? (
            <RecoveryCodes codes={shownCodes} onDone={() => { setShownCodes(null); setEnabling(false); }} />
          ) : (
            <>
              {status?.available && status.enabled ? (
                <ManageFlow recoveryCodesLeft={status.recoveryCodesLeft} onCodes={setShownCodes} />
              ) : null}
              {status?.available && !status.enabled ? (
                enabling ? (
                  <EnableFlow onCodes={setShownCodes} />
                ) : (
                  <Button onClick={() => setEnabling(true)}>Set up two-factor login</Button>
                )
              ) : null}
            </>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Lost your phone and your recovery codes?</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm text-[var(--muted)]">
          <p>
            Someone with command-line access to the server can switch two-factor login off (the password still applies). On
            the server run:
          </p>
          <pre className="overflow-x-auto rounded-md border border-[var(--border)] bg-[var(--surface-muted)] px-3 py-2 font-mono text-[var(--foreground)]">sudo gatekeeper 2fa-reset</pre>
          <p>
            Two-factor secrets are encrypted with the server's session secret. If that secret is ever changed, the saved
            second factor can no longer be read and login stays closed until you run the command above.
          </p>
        </CardContent>
      </Card>
    </div>
  );
}
