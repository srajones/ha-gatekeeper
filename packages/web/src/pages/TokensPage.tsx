import { Fragment, useState } from "react";
import type { Client, HaEntity, HaServiceCatalog, TokenPermission } from "../api";
import { DomainPermissionEditor } from "../components/DomainPermissionEditor";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "../components/ui/table";
import { downloadAgentBundle, getDefaultGatekeeperBaseUrl } from "../lib/agentBundle";
import {
  buildAccessSummary,
  groupsAreComplete,
  groupsToPermissions,
  permissionsToGroups,
  type PermissionGroup
} from "../lib/permissionGroups";

function formatDate(value: string): string {
  return new Date(value).toLocaleString();
}

function summarizeClient(client: Client): string {
  const groups = permissionsToGroups(client.permissions);
  const summary = buildAccessSummary(groups);
  if (summary.serviceCount === 0 && summary.entityCount === 0) {
    return "No permissions";
  }
  return `${summary.domainCount} domains, ${summary.serviceCount} services, ${summary.entityCount} entities`;
}

export function TokensPage({
  clients,
  entities,
  services,
  issuedKey,
  onRotate,
  onDelete,
  onSavePermissions
}: {
  clients: Client[];
  entities: HaEntity[];
  services: HaServiceCatalog[];
  issuedKey: string | null;
  onRotate: (id: string) => void;
  onDelete: (id: string) => void;
  onSavePermissions: (id: string, permissions: TokenPermission[]) => void;
}) {
  const [editingClientId, setEditingClientId] = useState<string | null>(null);
  const [draftGroups, setDraftGroups] = useState<PermissionGroup[]>([]);
  const [bundleBaseUrl, setBundleBaseUrl] = useState(() => getDefaultGatekeeperBaseUrl());
  const [bundleErrorClientId, setBundleErrorClientId] = useState<string | null>(null);

  function handleDownloadBundle(client: Client): void {
    setBundleErrorClientId(null);

    try {
      downloadAgentBundle({
        clientName: client.name,
        baseUrl: bundleBaseUrl.trim(),
        permissions: client.permissions,
        tokenMode: "placeholder"
      });
    } catch (error) {
      setBundleErrorClientId(client.id);
    }
  }

  return (
    <div className="space-y-6">
      <section>
        <h2 className="text-2xl font-semibold">Tokens</h2>
        <p className="mt-1 text-sm text-[var(--muted)]">
          Edit token permissions, rotate bearer tokens, or remove access.
        </p>
      </section>

      {issuedKey ? (
        <div className="rounded-lg border border-[var(--primary-border)] bg-[var(--primary-soft)] p-4 text-sm text-[var(--primary)]">
          New bearer token: <span className="font-mono">{issuedKey}</span>
        </div>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Issued tokens</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="mb-4 max-w-xl space-y-2">
            <label
              htmlFor="tokens-bundle-base-url"
              className="text-xs font-semibold uppercase text-[var(--muted)]"
            >
              Gatekeeper API base URL
            </label>
            <Input
              id="tokens-bundle-base-url"
              value={bundleBaseUrl}
              onChange={(event) => setBundleBaseUrl(event.target.value)}
              placeholder="http://homeassistant.local:4283"
            />
          </div>

          <Table>
            <TableHeader className="max-sm:hidden">
              <TableRow>
                <TableHead>Token</TableHead>
                <TableHead>Access</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Prefix</TableHead>
                <TableHead className="text-right">Manage</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {clients.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} className="py-8 text-center text-sm text-[var(--muted)]">
                    No tokens yet. Create one from Quick Start.
                  </TableCell>
                </TableRow>
              ) : null}
              {clients.map((client) => (
                <Fragment key={client.id}>
                  <TableRow className="max-sm:block max-sm:py-2">
                    <TableCell className="max-sm:block max-sm:py-1">
                      <div className="font-medium">{client.name}</div>
                      <div className="text-xs text-[var(--muted)]">Created {formatDate(client.createdAt)}</div>
                    </TableCell>
                    <TableCell className="text-sm text-[var(--muted)] max-sm:block max-sm:py-1">{summarizeClient(client)}</TableCell>
                    <TableCell className="max-sm:block max-sm:py-1">
                      <Badge variant={client.status === "active" ? "success" : "danger"}>
                        {client.status}
                      </Badge>
                    </TableCell>
                    <TableCell className="font-mono text-xs text-[var(--muted)] max-sm:block max-sm:py-1">
                      {client.apiKeyPrefix}
                    </TableCell>
                    <TableCell className="text-right max-sm:block max-sm:py-1 max-sm:text-left">
                      <div className="flex flex-wrap justify-end gap-2 max-sm:justify-start">
                        <Button
                          size="sm"
                          variant="secondary"
                          aria-label={`Download bundle for ${client.name}`}
                          onClick={() => handleDownloadBundle(client)}
                        >
                          Download bundle
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          onClick={() => {
                            setEditingClientId(client.id);
                            setDraftGroups(permissionsToGroups(client.permissions));
                          }}
                        >
                          Edit
                        </Button>
                        <Button size="sm" variant="secondary" onClick={() => onRotate(client.id)}>
                          Rotate
                        </Button>
                        <Button
                          size="sm"
                          variant="danger"
                          onClick={() => {
                            if (confirm(`Delete token "${client.name}"? This cannot be undone.`)) {
                              onDelete(client.id);
                            }
                          }}
                        >
                          Delete
                        </Button>
                      </div>
                      {bundleErrorClientId === client.id ? (
                        <p className="mt-2 text-xs text-[var(--danger)]">
                          Could not create the placeholder bundle. Try again from this token row.
                        </p>
                      ) : null}
                    </TableCell>
                  </TableRow>
                  {editingClientId === client.id ? (
                    <TableRow className="max-sm:block">
                      <TableCell colSpan={5} className="max-sm:block">
                        <div className="space-y-4 rounded-lg border border-[var(--border)] bg-[var(--surface-muted)] p-4">
                          <DomainPermissionEditor
                            groups={draftGroups}
                            onChange={setDraftGroups}
                            entities={entities}
                            services={services}
                          />
                          <div className="flex flex-wrap justify-end gap-2">
                            <Button
                              variant="ghost"
                              onClick={() => {
                                setEditingClientId(null);
                                setDraftGroups([]);
                              }}
                            >
                              Cancel
                            </Button>
                            <Button
                              disabled={
                                groupsToPermissions(draftGroups).length === 0 ||
                                !groupsAreComplete(draftGroups)
                              }
                              onClick={() => {
                                onSavePermissions(client.id, groupsToPermissions(draftGroups));
                                setEditingClientId(null);
                                setDraftGroups([]);
                              }}
                            >
                              Save permissions
                            </Button>
                          </div>
                        </div>
                      </TableCell>
                    </TableRow>
                  ) : null}
                </Fragment>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}
