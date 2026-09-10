import { invoke } from "@tauri-apps/api/core";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  getConnection,
  getSettings,
  getSnapshot,
  listProviders,
  onConnection,
  onSnapshot,
  refresh,
  setProvider,
  setSettings,
  type ConnectionSnapshot,
  type ProviderInfo,
  type ProviderKey,
  type Settings,
  type Snapshot,
} from "./api";
import { makeTranslate, resolveLocale } from "./i18n";
import Overview from "./pages/Overview";
import Connection from "./pages/Connection";
import Display from "./pages/Display";
import Diagnostics from "./pages/Diagnostics";
import Placeholder from "./pages/Placeholder";

type Page = "overview" | "connection" | "display" | "updates" | "diagnostics";

const NAV: { id: Page; key: string }[] = [
  { id: "overview", key: "nav.overview" },
  { id: "connection", key: "nav.connection" },
  { id: "display", key: "nav.display" },
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
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [now, setNow] = useState(() => Date.now());

  // Initialzustand laden und Live-Updates abonnieren.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let unlistenConn: (() => void) | undefined;
    let cancelled = false;
    (async () => {
      unlisten = await onSnapshot((snap) => setSnapshot(snap));
      unlistenConn = await onConnection((conn) => setConnection(conn));
      const [snap, cfg, list, conn] = await Promise.all([getSnapshot(), getSettings(), listProviders(), getConnection()]);
      if (cancelled) return;
      setSnapshot(snap);
      setSettingsState(cfg);
      setProviders(list);
      setConnection(conn);
    })().catch((e) => console.error("init", e));
    return () => {
      cancelled = true;
      unlisten?.();
      unlistenConn?.();
    };
  }, []);

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
      if (!settings) return;
      const next = { ...settings, ...patch };
      setSettingsState(next);
      try {
        const saved = await setSettings(next);
        setSettingsState(saved);
      } catch (e) {
        // Backend meldet z. B. einen Autostart-Fehler und liefert den alten Wert zurück.
        console.error("set_settings", e);
        setSettingsState(await getSettings());
      }
    },
    [settings],
  );

  // Nach Änderungen, die das Backend selbst speichert (Zeitzone, Port).
  const reloadSettings = useCallback(() => {
    getSettings().then(setSettingsState).catch((e) => console.error("get_settings", e));
  }, []);

  const chooseProvider = useCallback(
    async (key: ProviderKey) => {
      if (settings) setSettingsState({ ...settings, provider: key });
      await setProvider(key);
    },
    [settings],
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
            onProvider={chooseProvider}
            onRefresh={() => refresh()}
            onSettings={updateSettings}
          />
        )}
        {page === "connection" && <Connection t={t} now={now} connection={connection} />}
        {page === "display" && <Display t={t} connection={connection} settings={settings} onSettingsChanged={reloadSettings} />}
        {page === "updates" && <Placeholder title={t("nav.updates")} text={t("ph.updates")} />}
        {page === "diagnostics" && <Diagnostics t={t} snapshot={snapshot} />}
      </main>
    </div>
  );
}
