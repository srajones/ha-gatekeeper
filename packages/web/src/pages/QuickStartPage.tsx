import { useMemo, useState } from "react";
import type { HaEntity, HaServiceCatalog, QuickSetupPayload, QuickSetupResult, TokenPermission } from "../api";
import { AccessSummary } from "../components/AccessSummary";
import { DomainPermissionEditor } from "../components/DomainPermissionEditor";
import { HomeAssistantTokenHelp } from "../components/HomeAssistantTokenHelp";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { downloadAgentBundle, getDefaultGatekeeperBaseUrl } from "../lib/agentBundle";
import { createDefaultGroups, groupsAreComplete, groupsToPermissions } from "../lib/permissionGroups";

function makeCurl(permissions: TokenPermission[]): string {
  const servicePermission = permissions.find(
    (permission): permission is Extract<TokenPermission, { kind: "service" }> =>
      permission.kind === "service"
  );
  if (servicePermission) {
    const entityId = servicePermission.entityIds[0] ?? "light.living_room";
    return [
      `curl -X POST /api/services/${servicePermission.domain}/${servicePermission.services[0]}`,
      `  -H "Authorization: Bearer <TOKEN>"`,
      `  -H "Content-Type: application/json"`,
      `  -d '{"entity_id":"${entityId}"}'`
    ].join(" \\\n");
  }

  const statePermission = permissions.find(
    (permission): permission is Extract<TokenPermission, { kind: "state" }> =>
      permission.kind === "state"
  );
  if (!statePermission) {
    return "";
  }
  return [
    `curl /api/states/${statePermission.entityIds[0]}`,
    `  -H "Authorization: Bearer <TOKEN>"`
  ].join(" \\\n");
}

export function QuickStartPage({
  entities,
  services,
  isLoadingEntities,
  hasEntityError,
  onRetryEntities,
  onCreate,
  result,
  onClearResult,
  isSubmitting
}: {
  entities: HaEntity[];
  services: HaServiceCatalog[];
  isLoadingEntities: boolean;
  hasEntityError: boolean;
  onRetryEntities: () => void;
  onCreate: (payload: QuickSetupPayload) => void;
  result: QuickSetupResult | null;
  onClearResult: () => void;
  isSubmitting: boolean;
}) {
  const [name, setName] = useState("Mom access");
  const [groups, setGroups] = useState(createDefaultGroups);
  const [helpOpen, setHelpOpen] = useState(false);
  const [includeBearerTokenInBundle, setIncludeBearerTokenInBundle] = useState(false);
  const [bundleBaseUrl, setBundleBaseUrl] = useState(() => getDefaultGatekeeperBaseUrl());
  const [bundleError, setBundleError] = useState<string | null>(null);

  const permissions = useMemo(() => groupsToPermissions(groups), [groups]);
  const canSubmit =
    Boolean(name.trim()) &&
    permissions.length > 0 &&
    groupsAreComplete(groups) &&
    !isLoadingEntities &&
    !hasEntityError;

  if (result) {
    const curl = makeCurl(result.client.permissions);
    const handleDownloadBundle = () => {
      setBundleError(null);
      try {
        downloadAgentBundle({
          clientName: result.client.name,
          baseUrl: bundleBaseUrl.trim(),
          permissions: result.client.permissions,
          tokenMode: includeBearerTokenInBundle ? "included" : "placeholder",
          liveToken: includeBearerTokenInBundle ? result.apiKey : undefined
        });
      } catch (error) {
        setBundleError(error instanceof Error ? error.message : String(error));
      }
    };
    const handleCreateAnotherToken = () => {
      setIncludeBearerTokenInBundle(false);
      setBundleError(null);
      onClearResult();
    };

    return (
      <div className="space-y-6">
        <section>
          <h2 className="text-2xl font-semibold">Token issued</h2>
          <p className="text-sm text-[var(--muted)]">Copy this token now. It will not be shown again.</p>
        </section>

        <Card>
          <CardHeader>
            <CardTitle>{result.client.name}</CardTitle>
            <p className="text-sm text-[var(--muted)]">Bearer token</p>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="break-all rounded-md border border-[var(--primary-border)] bg-[var(--primary-soft)] p-4 font-mono text-sm text-[var(--primary)]">
              {result.apiKey}
            </div>
            {curl ? (
              <pre className="overflow-auto rounded-md border border-[var(--border)] bg-[var(--surface-muted)] p-4 text-xs text-[var(--foreground)]">
                {curl}
              </pre>
            ) : null}
            <div className="flex flex-wrap gap-2">
              <Button onClick={() => navigator.clipboard.writeText(result.apiKey)}>Copy token</Button>
              {curl ? (
                <Button variant="secondary" onClick={() => navigator.clipboard.writeText(curl)}>
                  Copy curl
                </Button>
              ) : null}
              <Button variant="ghost" onClick={handleCreateAnotherToken}>
                Create another token
              </Button>
            </div>

            <div className="space-y-3 rounded-md border border-[var(--border)] bg-[var(--surface-muted)] p-4">
              <div className="space-y-1">
                <h3 className="text-sm font-semibold text-[var(--foreground)]">Agent setup bundle</h3>
                <p className="text-sm text-[var(--muted)]">
                  Downloads instructions, OpenAPI metadata, OpenClaw skill notes, and curl examples
                  for this scoped token.
                </p>
              </div>

              <div className="space-y-2">
                <label
                  htmlFor="quickstart-bundle-base-url"
                  className="text-xs font-semibold uppercase text-[var(--muted)]"
                >
                  Gatekeeper API base URL
                </label>
                <Input
                  id="quickstart-bundle-base-url"
                  value={bundleBaseUrl}
                  onChange={(event) => setBundleBaseUrl(event.target.value)}
                  placeholder="http://homeassistant.local:4283"
                />
              </div>

              <Button variant="secondary" onClick={handleDownloadBundle}>
                Download agent setup bundle
              </Button>

              <label className="flex items-start gap-3 text-sm text-[var(--foreground)]">
                <input
                  type="checkbox"
                  checked={includeBearerTokenInBundle}
                  onChange={(event) => setIncludeBearerTokenInBundle(event.target.checked)}
                  className="mt-1"
                />
                <span>
                  Include bearer token in bundle
                  <span className="block text-xs text-[var(--muted)]">
                    Unchecked generates placeholder-only bundle.
                  </span>
                </span>
              </label>

              {includeBearerTokenInBundle ? (
                <p className="rounded-md border border-[var(--danger-border)] bg-[var(--danger-soft)] p-3 text-sm text-[var(--danger)]">
                  This bundle contains a live bearer token. Anyone with the zip can use the allowed
                  gateway actions until the token is rotated, disabled, or deleted.
                </p>
              ) : null}

              {bundleError ? (
                <p className="text-sm text-[var(--danger)]">
                  Could not create the bundle. Try the download again while this token is still
                  visible.
                </p>
              ) : null}
            </div>
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <section>
        <h2 className="text-2xl font-semibold">Create scoped access</h2>
        <p className="mt-1 text-sm text-[var(--muted)]">
          Issue a Gatekeeper token that only allows selected Home Assistant domains, services, and
          entities.
        </p>
      </section>

      {hasEntityError ? (
        <div className="rounded-lg border border-[var(--danger-border)] bg-[var(--danger-soft)] p-4 text-sm text-[var(--danger)]">
          <p className="font-medium">Cannot load Home Assistant data</p>
          <p className="mt-1">
            Check that Home Assistant is reachable from this server and that HA_BASE_URL and the Home Assistant token in .env are right (on a server install: sudo gatekeeper verify shows which). Then retry.
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button variant="secondary" onClick={onRetryEntities}>
              Retry
            </Button>
            <Button variant="ghost" onClick={() => setHelpOpen(true)}>
              Open token guide
            </Button>
          </div>
        </div>
      ) : null}

      <div className="grid gap-5 xl:grid-cols-[1fr_360px]">
        <Card>
          <CardHeader>
            <CardTitle>Permission composer</CardTitle>
            <p className="text-sm text-[var(--muted)]">
              Group access by Home Assistant domain, then choose services and entities.
            </p>
          </CardHeader>
          <CardContent className="space-y-5">
            <div className="space-y-2">
              <label htmlFor="token-name" className="text-xs font-semibold uppercase text-[var(--muted)]">
                Token name
              </label>
              <Input
                id="token-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="Mom access"
              />
            </div>

            <DomainPermissionEditor
              groups={groups}
              onChange={setGroups}
              entities={entities}
              services={services}
              disabled={isSubmitting || isLoadingEntities || hasEntityError}
            />
          </CardContent>
        </Card>

        <AccessSummary
          groups={groups}
          canSubmit={canSubmit}
          isSubmitting={isSubmitting}
          submitLabel="Issue token"
          onSubmit={() => onCreate({ name, permissions })}
        />
      </div>

      {helpOpen ? (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/55 p-4 backdrop-blur-sm"
          role="dialog"
          aria-modal="true"
          aria-label="Connect Home Assistant"
          onClick={() => setHelpOpen(false)}
        >
          <div className="max-h-[90vh] w-full max-w-xl overflow-auto" onClick={(event) => event.stopPropagation()}>
            <div className="mb-3 flex justify-end">
              <Button variant="secondary" onClick={() => setHelpOpen(false)}>
                Close
              </Button>
            </div>
            <HomeAssistantTokenHelp />
          </div>
        </div>
      ) : null}
    </div>
  );
}
