import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type ApiError, type QuickSetupResult, type TokenPermission } from "./api";
import { AppShell, type Tab } from "./components/AppShell";
import { LoginCard } from "./components/LoginCard";
import { ActivityPage } from "./pages/ActivityPage";
import { QuickStartPage } from "./pages/QuickStartPage";
import { SettingsPage } from "./pages/SettingsPage";
import { TokensPage } from "./pages/TokensPage";

export default function App() {
  const queryClient = useQueryClient();
  const [tab, setTab] = useState<Tab>("Quick Start");
  const [password, setPassword] = useState("");
  const [quickSetupResult, setQuickSetupResult] = useState<QuickSetupResult | null>(null);
  const [issuedKey, setIssuedKey] = useState<string | null>(null);

  const meQuery = useQuery({
    queryKey: ["me"],
    queryFn: api.me,
    staleTime: 1000 * 30
  });

  const authenticated = meQuery.data?.authenticated ?? false;

  const clientsQuery = useQuery({
    queryKey: ["clients"],
    queryFn: api.clients,
    enabled: authenticated
  });

  const auditQuery = useQuery({
    queryKey: ["audit"],
    queryFn: api.auditLogs,
    enabled: authenticated,
    refetchInterval: 15000
  });

  const servicesQuery = useQuery({
    queryKey: ["ha-services"],
    queryFn: api.haServices,
    enabled: authenticated
  });

  const entitiesQuery = useQuery({
    queryKey: ["ha-entities"],
    queryFn: () => api.haEntities(),
    enabled: authenticated
  });

  const settingsQuery = useQuery({
    queryKey: ["settings"],
    queryFn: api.settings,
    enabled: authenticated && tab === "Settings"
  });

  const connectionQuery = useQuery({
    queryKey: ["connection"],
    queryFn: api.connection,
    enabled: authenticated && tab === "Settings",
    refetchInterval: 5000
  });

  const saveSettingsMutation = useMutation({
    mutationFn: api.saveSettings,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["settings"] });
      queryClient.invalidateQueries({ queryKey: ["connection"] });
    }
  });

  const resetSettingsMutation = useMutation({
    mutationFn: api.resetSettings,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["settings"] });
      queryClient.invalidateQueries({ queryKey: ["connection"] });
    }
  });

  const loginMutation = useMutation<{}, ApiError, string>({
    mutationFn: (pwd: string) => api.login(pwd),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["me"] })
  });

  const logoutMutation = useMutation({
    mutationFn: () => api.logout(),
    onSuccess: () => {
      setQuickSetupResult(null);
      setIssuedKey(null);
      queryClient.invalidateQueries({ queryKey: ["me"] });
    }
  });

  const quickSetupMutation = useMutation({
    mutationFn: api.quickSetup,
    onSuccess: (data) => {
      setQuickSetupResult(data);
      queryClient.invalidateQueries({ queryKey: ["clients"] });
    }
  });

  const rotateKeyMutation = useMutation({
    mutationFn: api.rotateClientKey,
    onSuccess: (data) => {
      setIssuedKey(data.apiKey);
      queryClient.invalidateQueries({ queryKey: ["clients"] });
    }
  });

  const deleteClientMutation = useMutation({
    mutationFn: api.deleteClient,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
    }
  });

  const updatePermissionsMutation = useMutation({
    mutationFn: ({
      clientId,
      permissions
    }: {
      clientId: string;
      permissions: TokenPermission[];
    }) => api.updateClientPermissions(clientId, permissions),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
    }
  });

  if (!authenticated) {
    return (
      <div className="min-h-screen bg-[var(--background)] px-6 py-16 text-[var(--foreground)]">
        <div className="mx-auto max-w-md">
          <LoginCard
            password={password}
            onPasswordChange={setPassword}
            onSubmit={() => loginMutation.mutate(password)}
            isSubmitting={loginMutation.isPending}
            error={loginMutation.error}
          />
        </div>
      </div>
    );
  }

  const haStatus =
    entitiesQuery.isError || servicesQuery.isError
      ? "error"
      : entitiesQuery.isLoading || servicesQuery.isLoading
        ? "loading"
        : "connected";

  return (
    <AppShell
      activeTab={tab}
      onTabChange={setTab}
      onLogout={() => logoutMutation.mutate()}
      haStatus={haStatus}
    >
      {tab === "Quick Start" ? (
        <QuickStartPage
          entities={entitiesQuery.data?.entities ?? []}
          services={servicesQuery.data?.services ?? []}
          isLoadingEntities={entitiesQuery.isLoading || servicesQuery.isLoading}
          hasEntityError={entitiesQuery.isError || servicesQuery.isError}
          onRetryEntities={() => {
            entitiesQuery.refetch();
            servicesQuery.refetch();
          }}
          onCreate={(payload) => quickSetupMutation.mutate(payload)}
          result={quickSetupResult}
          onClearResult={() => setQuickSetupResult(null)}
          isSubmitting={quickSetupMutation.isPending}
        />
      ) : null}

      {tab === "Tokens" ? (
        <TokensPage
          clients={clientsQuery.data?.clients ?? []}
          entities={entitiesQuery.data?.entities ?? []}
          services={servicesQuery.data?.services ?? []}
          issuedKey={issuedKey}
          onRotate={(clientId) => rotateKeyMutation.mutate(clientId)}
          onDelete={(clientId) => deleteClientMutation.mutate(clientId)}
          onSavePermissions={(clientId, permissions) =>
            updatePermissionsMutation.mutate({ clientId, permissions })
          }
        />
      ) : null}

      {tab === "Activity" ? <ActivityPage logs={auditQuery.data?.logs ?? []} /> : null}

      {tab === "Settings" ? (
        <SettingsPage
          settings={settingsQuery.data?.settings ?? null}
          defaults={settingsQuery.data?.defaults ?? null}
          help={settingsQuery.data?.help ?? []}
          connection={connectionQuery.data ?? null}
          isLoading={settingsQuery.isLoading}
          hasError={settingsQuery.isError}
          isSaving={saveSettingsMutation.isPending || resetSettingsMutation.isPending}
          saveError={saveSettingsMutation.error ?? resetSettingsMutation.error}
          onSave={(patch) => saveSettingsMutation.mutate(patch)}
          onReset={() => resetSettingsMutation.mutate()}
        />
      ) : null}
    </AppShell>
  );
}
