import { invoke } from "@tauri-apps/api/core";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  getConnection,
  getSettings,
  getSnapshot,
  listProviders,
  listPlugins,
  onConnection,
  onSnapshot,
  onSettingsChanged,
  onPlugins,
  refresh,
  setProvider,
  setSettings,
  type ConnectionSnapshot,
  type ProviderInfo,
  type ProviderKey,
  type PluginInfo,
  type Settings,
  type Snapshot,
} from "./api";
import { makeTranslate, resolveLocale } from "./i18n";
import Overview from "./pages/Overview";
import Connection from "./pages/Connection";
import Display from "./pages/Display";
import Diagnostics from "./pages/Diagnostics";
import Updates from "./pages/Updates";
import Plugins from "./pages/Plugins";

type Page = "overview" | "connection" | "display" | "plugins" | "updates" | "diagnostics";

const NAV: { id: Page; key: string }[] = [
  { id: "overview", key: "nav.overview" },
  { id: "connection", key: "nav.connection" },
  { id: "display", key: "nav.display" },
  { id: "plugins", key: "nav.plugins" },
  { id: "updates", key: "nav.updates" },
  { id: "diagnostics", key: "nav.diagnostics" },
];

export default function App() {
  const [page, setPage] = useState<Page>("overview");
  // Entwicklung: Startseite per Umgebungsvariable, siehe get_initial_page.
  useEffect(() => {
    invoke<string>("get_initial_page").then((p) => {
      if (NAV.some((n) => n.id === p)) setPage(p as Page);
    }).catch(() => {});
  }, []);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [connection, setConnection] = useState<ConnectionSnapshot | null>(null);
  const [settings, setSettingsState] = useState<Settings | null>(null);
  const settingsRef = useRef<Settings | null>(null);
  const settingsWriteQueue = useRef<Promise<void>>(Promise.resolve());
  const setLocalSettings = useCallback((value: Settings) => {
    settingsRef.current = value;
    setSettingsState(value);
  }, []);
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [plugins, setPlugins] = useState<PluginInfo[]>([]);
  const [now, setNow] = useState(() => Date.now());

  // Initialzustand laden und Live-Updates abonnieren.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let unlistenConn: (() => void) | undefined;
    let unlistenSettings: (() => void) | undefined;
    let unlistenPlugins: (() => void) | undefined;
    let cancelled = false;
    (async () => {
      unlisten = await onSnapshot((snap) => setSnapshot(snap));
      unlistenConn = await onConnection((conn) => setConnection(conn));
      unlistenSettings = await onSettingsChanged(setLocalSettings);
      unlistenPlugins = await onPlugins((list) => setPlugins(list));
      const [snap, cfg, list, conn, installed] = await Promise.all([
        getSnapshot(), getSettings(), listProviders(), getConnection(), listPlugins(),
      ]);
      if (cancelled) return;
      setSnapshot(snap);
      setLocalSettings(cfg);
      setProviders(list);
      setConnection(conn);
      setPlugins(installed);
    })().catch((e) => console.error("init", e));
    return () => {
      cancelled = true;
      unlisten?.();
      unlistenConn?.();
      unlistenSettings?.();
      unlistenPlugins?.();
    };
  }, [setLocalSettings]);

  // Sekundenzeiger für Countdown und "aktualisiert vor".
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 15_000);
    return () => window.clearInterval(id);
  }, []);

  const locale = resolveLocale(settings?.language ?? "system");
  const t = useMemo(() => makeTranslate(locale), [locale]);
  useEffect(() => {
    document.documentElement.lang = locale;
  }, [locale]);

  const updateSettings = useCallback(
    async (patch: Partial<Settings>) => {
      const current = settingsRef.current;
      if (!current) return;
      const next = { ...current, ...patch };
      setLocalSettings(next);
      // Jede Änderung enthält den aktuellen Gesamtstand. Serielles Speichern
      // verhindert, dass eine ältere Antwort die nächste Fensterwahl zurücksetzt.
      settingsWriteQueue.current = settingsWriteQueue.current.then(async () => {
        try {
          const saved = await setSettings(next);
          if (settingsRef.current === next) setLocalSettings(saved);
        } catch (e) {
          // Backend meldet z. B. einen Autostart-Fehler und liefert den alten Wert zurück.
          console.error("set_settings", e);
          try {
            const saved = await getSettings();
            if (settingsRef.current === next) setLocalSettings(saved);
          } catch (readError) {
            console.error("get_settings", readError);
          }
        }
      });
      await settingsWriteQueue.current;
    },
    [setLocalSettings],
  );

  // Nach Änderungen, die das Backend selbst speichert (Zeitzone, Port).
  const reloadSettings = useCallback(() => {
    getSettings().then(setLocalSettings).catch((e) => console.error("get_settings", e));
  }, [setLocalSettings]);

  const chooseProvider = useCallback(
    async (key: ProviderKey) => {
      if (settings) setLocalSettings({ ...settings, provider: key });
      await setProvider(key);
    },
    [settings, setLocalSettings],
  );

  return (
    <div className="app">
      <nav className="sidebar" aria-label="Bereiche">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span>AI Monitor</span>
        </div>
        <ul>
          {NAV.map((item) => (
            <li key={item.id}>
              <button
                type="button"
                className={page === item.id ? "nav-item is-active" : "nav-item"}
                onClick={() => setPage(item.id)}
              >
                {t(item.key)}
              </button>
            </li>
          ))}
        </ul>
      </nav>
      <main className="content">
        {page === "overview" && (
          <Overview
            t={t}
            now={now}
            snapshot={snapshot}
            settings={settings}
            providers={providers}
            plugins={plugins}
            onProvider={chooseProvider}
            onRefresh={() => refresh()}
            onSettings={updateSettings}
          />
        )}
        {page === "connection" && <Connection t={t} now={now} connection={connection} />}
        {page === "display" && <Display t={t} connection={connection} settings={settings} providers={providers} plugins={plugins} onSettings={updateSettings} onSettingsChanged={reloadSettings} />}
        {page === "plugins" && <Plugins t={t} plugins={plugins} onRefresh={() => listPlugins().then(setPlugins).catch(console.error)} />}
        {page === "updates" && <Updates t={t} connection={connection} settings={settings} onSettings={updateSettings} />}
        {page === "diagnostics" && <Diagnostics t={t} snapshot={snapshot} />}
      </main>
    </div>
  );
}
