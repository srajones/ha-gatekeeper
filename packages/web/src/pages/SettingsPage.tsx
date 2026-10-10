import { useEffect, useState } from "react";
import type { ConnectionStatus, GatewaySettings, SettingHelp } from "../api";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";

type SettingsPageProps = {
  settings: GatewaySettings | null;
  defaults: GatewaySettings | null;
  help: SettingHelp[];
  connection: ConnectionStatus | null;
  isLoading: boolean;
  hasError: boolean;
  isSaving: boolean;
  saveError: Error | null;
  onSave: (patch: Partial<GatewaySettings>) => void;
  onReset: () => void;
};

function formatAge(seconds: number | null): string {
  if (seconds === null) return "no change received yet";
  if (seconds < 90) return `${seconds} s ago`;
  if (seconds < 5400) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 172800) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86400)} days ago`;
}

function ConnectionCard({ connection, mode }: { connection: ConnectionStatus | null; mode: GatewaySettings["stateSource"] }) {
  if (!connection) {
    return null;
  }
  const { live, requests } = connection;
  const usingLive = mode === "subscription";
  const badge = !usingLive
    ? { variant: "warning" as const, text: "Live connection not in use" }
    : live.connected
      ? { variant: "success" as const, text: "Live connection is up" }
      : live.running
        ? { variant: "danger" as const, text: "Reconnecting to Home Assistant" }
        : { variant: "warning" as const, text: "Live connection is starting" };

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-center gap-3">
          <CardTitle>Connection to Home Assistant</CardTitle>
          <Badge variant={badge.variant}>{badge.text}</Badge>
        </div>
        <p className="text-sm text-[var(--muted)]">
          {usingLive
            ? "One websocket carries all your keys. Home Assistant only sends changes of the entities your keys may read; API requests are answered from this server's memory."
            : "Reads are answered by asking Home Assistant (see the first option below)."}
        </p>
      </CardHeader>
      <CardContent>
        <dl className="grid gap-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <dt className="text-[var(--muted)]">Entities watched</dt>
            <dd className="text-lg font-semibold">{usingLive ? live.subscribed : "-"}</dd>
          </div>
          <div>
            <dt className="text-[var(--muted)]">Newest change</dt>
            <dd className="text-lg font-semibold">{usingLive ? formatAge(live.newestChangeAgeSeconds) : "-"}</dd>
          </div>
          <div>
            <dt className="text-[var(--muted)]">Reconnects since start</dt>
            <dd className="text-lg font-semibold">{usingLive ? Math.max(0, live.reconnects - 1) : "-"}</dd>
          </div>
          <div>
            <dt className="text-[var(--muted)]">Requests to Home Assistant now</dt>
            <dd className="text-lg font-semibold">
              {requests.inFlight} running, {requests.waiting} waiting
            </dd>
          </div>
        </dl>
        {usingLive && live.lastError && !live.connected ? (
          <p className="mt-4 rounded-md border border-[var(--danger-border)] bg-[var(--danger-soft)] px-3 py-2 text-sm text-[var(--danger)]">
            Last problem: {live.lastError}. It retries by itself (5 s, then 10 s, up to 60 s between attempts).
          </p>
        ) : null}
      </CardContent>
    </Card>
  );
}

function ChoiceField({ help, value, onChange }: { help: SettingHelp; value: string; onChange: (value: string) => void }) {
  return (
    <fieldset className="space-y-2">
      <legend className="text-base font-semibold">{help.label}</legend>
      <p className="text-sm text-[var(--muted)]">{help.summary}</p>
      <p className="text-sm text-[var(--muted)]">{help.detail}</p>
      <div className="mt-2 space-y-2">
        {help.choices?.map((choice) => (
          <label
            key={choice.value}
            className={`flex cursor-pointer gap-3 rounded-md border px-3 py-2 text-sm ${
              value === choice.value ? "border-[var(--primary)] bg-[var(--surface-muted)]" : "border-[var(--border)]"
            }`}
          >
            <input
              type="radio"
              name={help.key}
              value={choice.value}
              checked={value === choice.value}
              onChange={() => onChange(choice.value)}
              className="mt-1"
            />
            <span>
              <span className="block font-medium">{choice.label}</span>
              <span className="block text-[var(--muted)]">{choice.description}</span>
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

function NumberField({
  help,
  value,
  defaultValue,
  onChange
}: {
  help: SettingHelp;
  value: number;
  defaultValue: number | undefined;
  onChange: (value: number) => void;
}) {
  const id = `setting-${help.key}`;
  return (
    <div className="space-y-2">
      <label htmlFor={id} className="block text-base font-semibold">
        {help.label}
      </label>
      <p className="text-sm text-[var(--muted)]">{help.summary}</p>
      <p className="text-sm text-[var(--muted)]">{help.detail}</p>
      <div className="flex flex-wrap items-center gap-3">
        <Input
          id={id}
          type="number"
          className="w-40"
          min={help.min}
          max={help.max}
          value={Number.isFinite(value) ? value : ""}
          onChange={(event) => onChange(Number(event.target.value))}
        />
        <span className="text-sm text-[var(--muted)]">
          {help.unit}
          {help.min !== undefined && help.max !== undefined ? ` (${help.min} to ${help.max})` : ""}
          {defaultValue !== undefined ? `; recommended: ${defaultValue}` : ""}
        </span>
      </div>
    </div>
  );
}

export function SettingsPage({
  settings,
  defaults,
  help,
  connection,
  isLoading,
  hasError,
  isSaving,
  saveError,
  onSave,
  onReset
}: SettingsPageProps) {
  const [draft, setDraft] = useState<GatewaySettings | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  useEffect(() => {
    if (settings) {
      setDraft(settings);
    }
  }, [settings]);

  if (isLoading || !draft || !settings) {
    return (
      <p className="text-sm text-[var(--muted)]">{hasError ? "The settings could not be loaded." : "Loading settings..."}</p>
    );
  }

  const changed = (Object.keys(draft) as Array<keyof GatewaySettings>).filter((key) => draft[key] !== settings[key]);
  const set = <K extends keyof GatewaySettings>(key: K, value: GatewaySettings[K]) => {
    setSavedAt(null);
    setDraft({ ...draft, [key]: value });
  };

  return (
    <div className="space-y-6">
      <section>
        <h2 className="text-2xl font-semibold">Settings</h2>
        <p className="mt-1 text-sm text-[var(--muted)]">
          Decide how ha-gatekeeper talks to Home Assistant on behalf of all your API keys. The recommended choices keep
          Home Assistant calm however many keys you create. Changes apply immediately, no restart. Every option is
          explained in docs/HOME_ASSISTANT_CONNECTION.md.
        </p>
      </section>

      <ConnectionCard connection={connection} mode={settings.stateSource} />

      <Card>
        <CardContent className="space-y-8 p-6">
          {help.map((item) => {
            const value = draft[item.key];
            return item.choices ? (
              <ChoiceField key={item.key} help={item} value={String(value)} onChange={(next) => set(item.key, next as never)} />
            ) : (
              <NumberField
                key={item.key}
                help={item}
                value={Number(value)}
                defaultValue={defaults ? Number(defaults[item.key]) : undefined}
                onChange={(next) => set(item.key, next as never)}
              />
            );
          })}

          <div className="flex flex-wrap items-center gap-3 border-t border-[var(--border)] pt-4">
            <Button
              disabled={isSaving || changed.length === 0}
              onClick={() => {
                const patch: Partial<GatewaySettings> = {};
                for (const key of changed) {
                  (patch as Record<string, unknown>)[key] = draft[key];
                }
                onSave(patch);
                setSavedAt(Date.now());
              }}
            >
              {isSaving ? "Saving..." : changed.length === 0 ? "No changes" : `Save ${changed.length} change${changed.length === 1 ? "" : "s"}`}
            </Button>
            <Button
              variant="secondary"
              disabled={isSaving}
              onClick={() => {
                if (window.confirm("Go back to the recommended settings?")) {
                  onReset();
                  setSavedAt(Date.now());
                }
              }}
            >
              Reset to recommended
            </Button>
            {changed.length > 0 ? (
              <Button variant="ghost" disabled={isSaving} onClick={() => setDraft(settings)}>
                Discard
              </Button>
            ) : null}
            {saveError ? (
              <span className="text-sm text-[var(--danger)]">Could not save ({(saveError as { code?: string }).code ?? "error"}). Check the values above.</span>
            ) : savedAt && changed.length === 0 ? (
              <span className="text-sm text-[var(--muted)]">Saved and applied.</span>
            ) : null}
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
