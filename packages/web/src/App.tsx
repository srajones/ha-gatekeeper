import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type ApiError, type QuickSetupResult, type TokenPermission } from "./api";
import { AppShell, type Tab } from "./components/AppShell";
import { LoginCard, TwoFactorCard } from "./components/LoginCard";
import { ActivityPage } from "./pages/ActivityPage";
import { QuickStartPage } from "./pages/QuickStartPage";
import { SecurityPage } from "./pages/SecurityPage";
import { SettingsPage } from "./pages/SettingsPage";
import { TokensPage } from "./pages/TokensPage";

export default function App() {
  const queryClient = useQueryClient();
  const [tab, setTab] = useState<Tab>("Quick Start");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
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
    // Needed on every page: the header must not say "connected" while the live link is reconnecting.
    enabled: authenticated,
    refetchInterval: tab === "Settings" ? 5000 : 20000
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

  const loginMutation = useMutation<{ needs2fa?: boolean }, ApiError, string>({
    mutationFn: (pwd: string) => api.login(pwd),
    onSuccess: () => {
      setPassword("");
      queryClient.invalidateQueries({ queryKey: ["me"] });
    }
  });

  // Second step, when two-factor login is on and the password was already accepted.
  const twoFactorMutation = useMutation<{}, ApiError, string>({
    mutationFn: (value: string) => api.login2fa(value),
    onSuccess: () => {
      setCode("");
      queryClient.invalidateQueries({ queryKey: ["me"] });
    },
    onError: (error) => {
      // the half-finished login is gone on the server: go back to the password
      if (error.code === "too_many_attempts" || error.code === "login_expired") {
        setCode("");
        queryClient.invalidateQueries({ queryKey: ["me"] });
      }
    }
  });

  const logoutMutation = useMutation({
    mutationFn: () => api.logout(),
    onSuccess: () => {
      setQuickSetupResult(null);
      setIssuedKey(null);
      setCode("");
      loginMutation.reset();
      twoFactorMutation.reset();
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

  if (!authenticated && (meQuery.data?.twoFactorPending ?? false)) {
    return (
      <div className="min-h-screen bg-[var(--background)] px-6 py-16 text-[var(--foreground)]">
        <div className="mx-auto max-w-md">
          <TwoFactorCard
            code={code}
            onCodeChange={setCode}
            onSubmit={() => twoFactorMutation.mutate(code.trim())}
            onCancel={() => logoutMutation.mutate()}
            isSubmitting={twoFactorMutation.isPending}
            error={twoFactorMutation.error}
          />
        </div>
      </div>
    );
  }

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

  const live = connectionQuery.data?.live;
  const liveLink: "ok" | "reconnecting" =
    connectionQuery.data?.settings.stateSource === "subscription" && live && live.running && !live.connected && live.subscribed > 0
      ? "reconnecting"
      : "ok";

  return (
    <AppShell
      activeTab={tab}
      onTabChange={setTab}
      onLogout={() => logoutMutation.mutate()}
      haStatus={haStatus}
      liveLink={liveLink}
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
          facts={settingsQuery.data?.facts ?? null}
          recommendations={settingsQuery.data?.recommendations ?? []}
          connection={connectionQuery.data ?? null}
          isLoading={settingsQuery.isLoading}
          hasError={settingsQuery.isError}
          isSaving={saveSettingsMutation.isPending || resetSettingsMutation.isPending}
          saveError={saveSettingsMutation.error ?? resetSettingsMutation.error}
          onSave={(patch) => saveSettingsMutation.mutate(patch)}
          onReset={() => resetSettingsMutation.mutate()}
        />
      ) : null}

      {tab === "Security" ? <SecurityPage /> : null}
    </AppShell>
  );
}
