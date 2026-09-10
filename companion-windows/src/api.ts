// Typen und Aufrufe gegen das Rust-Backend. Die Typen spiegeln die
// serde-Ausgabe von aimonitor-core (camelCase) und die Settings-Struktur.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type ProviderKey = "claude" | "codex" | "antigravity" | "gemini" | "copilot" | "cursor";
export type PercentMode = "used" | "remaining";
export type Language = "system" | "de" | "en";

export type Status =
  | { kind: "ok" }
  | { kind: "notYet" }
  | { kind: "cliMissing" }
  | { kind: "providerUnavailable"; message: string }
  | { kind: "cliFailed"; message: string }
  | { kind: "stale"; ageSeconds: number }
  | { kind: "parseError"; message: string };

export interface Row {
  id: string;
  title: string;
  usedPercent: number;
  resetsAt: string | null;
  windowMinutes: number;
}

export interface RawRun {
  command: string;
  stdout: string;
  stderr: string;
  exitCode: number | null;
  durationMs: number;
  fromFixture: boolean;
}

export interface Snapshot {
  provider: ProviderKey;
  providerLabel: string;
  loginLabel: string;
  status: Status;
  rows: Row[];
  source: string | null;
  updatedAt: string | null;
  fetchedAt: string | null;
  fetching: boolean;
  percentMode: PercentMode;
  cliPath: string | null;
  cliVersion: string | null;
  fixtureDir: string | null;
  lastRun: RawRun | null;
}

export interface Settings {
  provider: ProviderKey;
  percentMode: PercentMode;
  language: Language;
  autostart: boolean;
}

export interface ProviderInfo {
  key: ProviderKey;
  label: string;
  loginLabel: string;
}

export const getSnapshot = () => invoke<Snapshot>("get_snapshot");
export const setProvider = (provider: ProviderKey) => invoke<void>("set_provider", { provider });
export const refresh = () => invoke<void>("refresh");
export const getSettings = () => invoke<Settings>("get_settings");
export const setSettings = (settings: Settings) => invoke<Settings>("set_settings", { settings });
export const listProviders = () => invoke<ProviderInfo[]>("list_providers");
export const rescanCli = () => invoke<void>("rescan_cli");

export function onSnapshot(handler: (snapshot: Snapshot) => void): Promise<UnlistenFn> {
  return listen<Snapshot>("snapshot-changed", (event) => handler(event.payload));
}
