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
  /** Fest gewählter Port; null heißt automatisch. */
  manualPort: string | null;
  /** "auto" oder IANA-Name. */
  timezone: string;
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

// ---------------------------------------------------------------------------
// Verbindung und Display (Phase 2). Typen spiegeln aimonitor_core::protocol,
// aimonitor_core::device, aimonitor_serial und serial_service.rs.
// ---------------------------------------------------------------------------

export type ConnectionState = "disconnected" | "probing" | "connected" | "foreignFirmware";
export type Orientation = "portrait" | "landscape_left" | "landscape_right";
export type ThemeSetting = "system" | "dark" | "light";
export type DisplayLanguage = "de" | "en";
export type DisplayVariant = "ili9341" | "st7789";

export interface DeviceInfo {
  version: string;
  mac: string;
  display: DisplayVariant | null;
  orientation: Orientation | null;
  theme: "dark" | "light" | null;
  language: DisplayLanguage | null;
  brightness: number | null;
  serialTransport: string | null;
  maxFrameBytes: number | null;
  wifiConfigured: boolean | null;
  wifiConnected: boolean | null;
  timeSynced: boolean | null;
  uptime: number | null;
  heap: number | null;
}

export interface DeviceProfile {
  mac: string;
  friendlyName: string;
  theme: ThemeSetting;
  orientation: Orientation;
  language: DisplayLanguage;
  brightness: number;
  displayVariant: DisplayVariant | null;
  lastSeenAt: string | null;
  firmwareVersion: string | null;
}

/** Felder bleiben snake_case, so serialisiert aimonitor_serial::FrameReceipt. */
export type FrameReceipt =
  | { kind: "ack"; frameId: number; bytes: number; rows: number; provider: string }
  | { kind: "error"; frameId: number; message: string }
  | { kind: "timeout"; frameId: number };

export interface ConnectionSnapshot {
  state: ConnectionState;
  port: string | null;
  manualPort: string | null;
  info: DeviceInfo | null;
  profile: DeviceProfile | null;
  lastReceipt: FrameReceipt | null;
  lastFrameBytes: number | null;
  lastFrameAt: string | null;
  unackedCount: number;
  framesSent: number;
  framesAcked: number;
  log: string[];
}

export interface PortCandidate {
  name: string;
  vid: number | null;
  pid: number | null;
  serialNumber: string | null;
  product: string | null;
  chip: string | null;
}

export interface TimeZoneOption {
  id: string;
  label: string;
  offsetMinutes: number;
}

export const getConnection = () => invoke<ConnectionSnapshot>("get_connection");
export const listPorts = () => invoke<PortCandidate[]>("list_ports");
export const setManualPort = (port: string | null) => invoke<void>("set_manual_port", { port });
export const getDevices = () => invoke<DeviceProfile[]>("get_devices");
export const renameDevice = (mac: string, name: string) => invoke<DeviceProfile>("rename_device", { mac, name });
export const updateProfile = (mac: string, theme: ThemeSetting, orientation: Orientation, language: DisplayLanguage) =>
  invoke<DeviceProfile>("update_profile", { mac, theme, orientation, language });
export const setBrightness = (value: number, persist: boolean) => invoke<void>("set_brightness", { value, persist });
export const getTimezones = () => invoke<TimeZoneOption[]>("get_timezones");
export const setTimezone = (timezone: string) => invoke<void>("set_timezone", { timezone });
export const sendDiagnosticFrame = () => invoke<void>("send_diagnostic_frame");

export function onConnection(handler: (snapshot: ConnectionSnapshot) => void): Promise<UnlistenFn> {
  return listen<ConnectionSnapshot>("connection-changed", (event) => handler(event.payload));
}
