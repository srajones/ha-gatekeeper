export type ServicePermission = {
  id?: string;
  kind: "service";
  domain: string;
  services: string[];
  entityIds: string[];
  allowNoEntity?: boolean;
};

export type StatePermission = {
  id?: string;
  kind: "state";
  entityIds: string[];
};

export type TokenPermission = ServicePermission | StatePermission;

export type Client = {
  id: string;
  name: string;
  status: "active" | "disabled";
  apiKeyPrefix: string;
  createdAt: string;
  permissions: TokenPermission[];
};

export type AuditLog = {
  id: string;
  timestamp: string;
  success: boolean;
  error?: string | null;
  ip?: string | null;
  clientId?: string | null;
  clientName?: string | null;
  permissionId?: string | null;
  permission?: TokenPermission | null;
  actionIdRaw: string;
};

export type HaServiceCatalog = {
  domain: string;
  services: string[];
};

export type HaEntity = {
  entityId: string;
  domain: string;
  name: string;
};

export type QuickSetupPayload = {
  name?: string;
  permissions: TokenPermission[];
};

export type QuickSetupResult = {
  client: Client;
  apiKey: string;
};

export type GatewaySettings = {
  stateSource: "subscription" | "cache" | "direct";
  cacheMs: number;
  maxConcurrency: number;
  onLinkDown: "live-then-last-known" | "last-known" | "error";
  rateLimitPerMinute: number;
};

export type SettingHelp = {
  key: keyof GatewaySettings;
  label: string;
  summary: string;
  detail: string;
  choices?: Array<{ value: string; label: string; description: string }>;
  unit?: string;
  min?: number;
  max?: number;
};

export type ConnectionStatus = {
  settings: GatewaySettings;
  live: {
    running: boolean;
    connected: boolean;
    subscribed: number;
    cached: number;
    newestChangeAgeSeconds: number | null;
    lastEventAt: string | null;
    connectedSince: string | null;
    reconnects: number;
    lastError: string | null;
  };
  requests: { inFlight: number; waiting: number };
};

type ApiResponse<T> = {
  ok: boolean;
} & T;

export class ApiError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string) {
    super(`request_failed:${status}:${code}`);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

export function resolveApiPath(path: string, pathname = getCurrentPathname()): string {
  if (!path.startsWith("/")) {
    return path;
  }

  if (!pathname || pathname === "/") {
    return path;
  }

  const basePath = pathname.endsWith("/") ? pathname.slice(0, -1) : pathname;
  return `${basePath}${path}`;
}

async function apiFetch<T>(path: string, options?: RequestInit): Promise<ApiResponse<T>> {
  const hasBody = options?.body !== undefined;
  const res = await fetch(resolveApiPath(path), {
    credentials: "include",
    headers: {
      ...(hasBody ? { "Content-Type": "application/json" } : {}),
      ...(options?.headers ?? {})
    },
    ...options
  });

  if (!res.ok) {
    const body: unknown = await res.json().catch(() => null);
    const code =
      body && typeof body === "object" && "error" in body && typeof body.error === "string"
        ? body.error
        : "unknown_error";
    throw new ApiError(res.status, code);
  }

  return res.json();
}

export const api = {
  login: (password: string) =>
    apiFetch<{}>("/admin/login", {
      method: "POST",
      body: JSON.stringify({ password })
    }),
  logout: () => apiFetch<{}>("/admin/logout", { method: "POST" }),
  me: () => apiFetch<{ authenticated: boolean }>("/admin/me"),
  clients: () => apiFetch<{ clients: Client[] }>("/admin/clients"),
  createClient: (payload: {
    name: string;
    status: "active" | "disabled";
    permissions: TokenPermission[];
  }) =>
    apiFetch<{ client: Client; apiKey: string }>("/admin/clients", {
      method: "POST",
      body: JSON.stringify(payload)
    }),
  quickSetup: (payload: QuickSetupPayload) =>
    apiFetch<QuickSetupResult>("/admin/quick-setup", {
      method: "POST",
      body: JSON.stringify(payload)
    }),
  updateClient: (clientId: string, payload: { name?: string; status?: "active" | "disabled" }) =>
    apiFetch<{ client: Client }>(`/admin/clients/${clientId}`, {
      method: "PATCH",
      body: JSON.stringify(payload)
    }),
  updateClientPermissions: (clientId: string, permissions: TokenPermission[]) =>
    apiFetch<{ client: Client }>(`/admin/clients/${clientId}/permissions`, {
      method: "PATCH",
      body: JSON.stringify({ permissions })
    }),
  rotateClientKey: (clientId: string) =>
    apiFetch<{ client: Client; apiKey: string }>(`/admin/clients/${clientId}/rotate-key`, {
      method: "POST"
    }),
  deleteClient: (clientId: string) =>
    apiFetch<{}>(`/admin/clients/${clientId}`, {
      method: "DELETE"
    }),
  settings: () =>
    apiFetch<{ settings: GatewaySettings; defaults: GatewaySettings; help: SettingHelp[] }>("/admin/settings"),
  saveSettings: (patch: Partial<GatewaySettings>) =>
    apiFetch<{ settings: GatewaySettings }>("/admin/settings", {
      method: "PUT",
      body: JSON.stringify(patch)
    }),
  resetSettings: () => apiFetch<{ settings: GatewaySettings }>("/admin/settings/reset", { method: "POST" }),
  connection: () => apiFetch<ConnectionStatus>("/admin/connection"),
  auditLogs: () => apiFetch<{ logs: AuditLog[] }>("/admin/audit-logs"),
  haServices: () => apiFetch<{ services: HaServiceCatalog[]; cached?: boolean }>(
    "/admin/ha/services"
  ),
  haEntities: (domain?: string) =>
    apiFetch<{ entities: HaEntity[]; cached?: boolean }>(
      domain ? `/admin/ha/entities?domain=${encodeURIComponent(domain)}` : "/admin/ha/entities"
    )
};

function getCurrentPathname(): string {
  if (typeof window === "undefined") {
    return "/";
  }

  return window.location.pathname || "/";
}
