import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type AlertResult, type ApiError } from "../api";
import { Badge } from "./ui/badge";
import { Button } from "./ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "./ui/card";

const LABELS: Record<string, string> = { email: "E-mail", webhook: "Webhook (Slack, Discord, ...)", ntfy: "ntfy (phone push)", telegram: "Telegram" };
const KIND: Record<string, string> = { down: "Down", reminder: "Reminder", recovered: "Back up", test: "Test" };

function when(iso: string): string {
  return new Date(iso).toLocaleString();
}

// Where "Home Assistant is unreachable" messages go, and a button to prove they arrive.
export function AlertsCard({ downAfterSeconds }: { downAfterSeconds: number | undefined }) {
  const queryClient = useQueryClient();
  const query = useQuery({ queryKey: ["alerts"], queryFn: api.alerts, refetchInterval: 10_000 });
  const test = useMutation<{ results: AlertResult[] }, ApiError, void>({
    mutationFn: () => api.testAlert(),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ["alerts"] })
  });
  const view = query.data;
  const active = view?.channels.filter((c) => c.configured).length ?? 0;
  const problems = view?.channels.filter((c) => c.problem) ?? [];

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-center gap-3">
          <CardTitle>Alerts</CardTitle>
          {view ? (
            <Badge variant={active > 0 ? "success" : "warning"}>{active > 0 ? `${active} channel${active === 1 ? "" : "s"} on` : "No alert channel set up"}</Badge>
          ) : null}
          {view?.state.haDown ? <Badge variant="danger">Home Assistant is unreachable now</Badge> : null}
        </div>
        <p className="text-sm text-[var(--muted)]">
          If Home Assistant stays unreachable{downAfterSeconds ? ` for ${Math.round(downAfterSeconds / 60) >= 1 ? `${Math.round(downAfterSeconds / 60)} min` : `${downAfterSeconds} s`}` : ""}, you are
          told on every channel below, and again when it is back. (If the whole server or this app goes down, the
          server's watchdog sends its own alert through the same channels.)
        </p>
      </CardHeader>
      <CardContent className="space-y-4">
        {query.isError ? <p className="text-sm text-[var(--danger)]">Could not load the alert status.</p> : null}
        {view ? (
          <ul className="space-y-2 text-sm">
            {view.channels.map((c) => (
              <li key={c.name} className="flex flex-wrap items-center gap-2 rounded-md border border-[var(--border)] px-3 py-2">
                <span className="font-medium">{LABELS[c.name]}</span>
                <Badge variant={c.configured ? "success" : c.problem ? "danger" : "warning"}>{c.configured ? "On" : c.problem ? "Needs fixing" : "Off"}</Badge>
                <span className="text-[var(--muted)]">{c.target}</span>
                {c.problem ? <span className="w-full text-[var(--danger)]">{c.problem}</span> : null}
              </li>
            ))}
          </ul>
        ) : null}
        {view && active === 0 && problems.length === 0 ? (
          <p className="rounded-md border border-[var(--border)] bg-[var(--surface-muted)] p-3 text-sm">
            Nothing is set up yet, so nobody would be told. On the server run <code className="font-mono">sudo gatekeeper alerts</code> and
            choose e-mail, a webhook, ntfy or Telegram. Secrets stay on the server, not in this page.
          </p>
        ) : null}
        <div className="flex flex-wrap items-center gap-3">
          <Button variant="secondary" onClick={() => test.mutate()} disabled={test.isPending || active === 0}>
            {test.isPending ? "Sending..." : "Send a test alert"}
          </Button>
          {active === 0 ? <span className="text-sm text-[var(--muted)]">Set up a channel first.</span> : null}
        </div>
        {test.data ? (
          <ul className="space-y-1 text-sm" aria-label="Test results">
            {test.data.results.map((r) => (
              <li key={r.channel} className={r.ok ? "text-[var(--success,inherit)]" : "text-[var(--danger)]"}>
                {LABELS[r.channel]}: {r.ok ? "delivered" : `failed (${r.error})`}
              </li>
            ))}
          </ul>
        ) : null}
        {test.error ? <p className="text-sm text-[var(--danger)]">Could not send the test ({test.error.code}).</p> : null}
        {view && view.history.length > 0 ? (
          <div>
            <h3 className="mb-1 text-sm font-semibold">Recent alerts</h3>
            <ul className="space-y-1 text-sm text-[var(--muted)]">
              {view.history.slice(0, 8).map((h, i) => (
                <li key={`${h.at}-${i}`}>
                  {when(h.at)} - {KIND[h.kind]}: {h.results.filter((r) => r.ok).length}/{h.results.length} delivered
                  {h.results.some((r) => !r.ok) ? ` (failed: ${h.results.filter((r) => !r.ok).map((r) => r.channel).join(", ")})` : ""}
                </li>
              ))}
            </ul>
          </div>
        ) : null}
      </CardContent>
    </Card>
  );
}
