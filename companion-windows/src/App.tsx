import { useCallback, useEffect, useMemo, useState } from "react";
import {
  getSettings,
  getSnapshot,
  listProviders,
  onSnapshot,
  refresh,
  setProvider,
  setSettings,
  type ProviderInfo,
  type ProviderKey,
  type Settings,
  type Snapshot,
} from "./api";
import { makeTranslate, resolveLocale } from "./i18n";
import Overview from "./pages/Overview";
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
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [settings, setSettingsState] = useState<Settings | null>(null);
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [now, setNow] = useState(() => Date.now());

  // Initialzustand laden und Live-Updates abonnieren.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    (async () => {
      unlisten = await onSnapshot((snap) => setSnapshot(snap));
      const [snap, cfg, list] = await Promise.all([getSnapshot(), getSettings(), listProviders()]);
      if (cancelled) return;
      setSnapshot(snap);
      setSettingsState(cfg);
      setProviders(list);
    })().catch((e) => console.error("init", e));
    return () => {
      cancelled = true;
      unlisten?.();
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
        {page === "connection" && <Placeholder title={t("nav.connection")} text={t("ph.connection")} />}
        {page === "display" && <Placeholder title={t("nav.display")} text={t("ph.display")} />}
        {page === "updates" && <Placeholder title={t("nav.updates")} text={t("ph.updates")} />}
        {page === "diagnostics" && <Diagnostics t={t} snapshot={snapshot} />}
      </main>
    </div>
  );
}
