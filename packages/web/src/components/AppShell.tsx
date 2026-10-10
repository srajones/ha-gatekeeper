import type { ReactNode } from "react";
import { useTheme } from "../lib/theme";
import { Button } from "./ui/button";
import { Badge } from "./ui/badge";

export const tabs = ["Quick Start", "Tokens", "Activity", "Settings"] as const;
export type Tab = (typeof tabs)[number];

type AppShellProps = {
  activeTab: Tab;
  onTabChange: (tab: Tab) => void;
  onLogout: () => void;
  haStatus: "loading" | "connected" | "error";
  children: ReactNode;
};

function statusLabel(status: AppShellProps["haStatus"]): string {
  if (status === "connected") return "Home Assistant connected";
  if (status === "error") return "Home Assistant unavailable";
  return "Checking Home Assistant";
}

function statusVariant(status: AppShellProps["haStatus"]): "success" | "danger" | "warning" {
  if (status === "connected") return "success";
  if (status === "error") return "danger";
  return "warning";
}

export function AppShell({ activeTab, onTabChange, onLogout, haStatus, children }: AppShellProps) {
  const { theme, toggleTheme } = useTheme();

  return (
    <div className="min-h-screen bg-[var(--background)] px-4 py-5 text-[var(--foreground)] sm:px-6 lg:px-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <header className="rounded-lg border border-[var(--border)] bg-[var(--surface)] px-4 py-3 shadow-sm">
          <div className="flex flex-wrap items-center gap-3">
            <div className="mr-2">
              <h1 className="text-lg font-semibold tracking-normal text-[var(--foreground)]">
                ha-gatekeeper
              </h1>
              <p className="text-xs text-[var(--muted)]">Home Assistant access console</p>
            </div>

            <nav className="flex flex-wrap gap-2" aria-label="Primary navigation">
              {tabs.map((tab) => (
                <Button
                  key={tab}
                  size="sm"
                  variant={activeTab === tab ? "default" : "ghost"}
                  onClick={() => onTabChange(tab)}
                >
                  {tab}
                </Button>
              ))}
            </nav>

            <div className="ml-auto flex flex-wrap items-center gap-2">
              <Badge variant={statusVariant(haStatus)}>{statusLabel(haStatus)}</Badge>
              <Button size="sm" variant="secondary" onClick={toggleTheme}>
                {theme === "light" ? "Dark mode" : "Light mode"}
              </Button>
              <Button size="sm" variant="secondary" onClick={onLogout}>
                Log out
              </Button>
            </div>
          </div>
        </header>

        <main>{children}</main>
      </div>
    </div>
  );
}
