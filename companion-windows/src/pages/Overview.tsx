import type { Language, PercentMode, ProviderInfo, ProviderKey, Settings, Snapshot, Status, ViewContent } from "../api";
import { formatAgo, formatCountdown } from "../format";
import type { Translate } from "../i18n";

interface Props {
  t: Translate;
  now: number;
  snapshot: Snapshot | null;
  settings: Settings | null;
  providers: ProviderInfo[];
  onProvider: (key: ProviderKey) => void;
  onRefresh: () => void;
  onSettings: (patch: Partial<Settings>) => void;
}

function statusText(t: Translate, status: Status): { label: string; message: string | null } {
  switch (status.kind) {
    case "stale":
      return { label: t("status.kind.stale", { minutes: Math.floor(status.ageSeconds / 60) }), message: null };
    case "providerUnavailable":
    case "cliFailed":
    case "parseError":
      return { label: t(`status.kind.${status.kind}`), message: status.message };
    default:
      return { label: t(`status.kind.${status.kind}`), message: null };
  }
}

export default function Overview({ t, now, snapshot, settings, providers, onProvider, onRefresh, onSettings }: Props) {
  const status = snapshot ? statusText(t, snapshot.status) : null;
  const fetching = snapshot?.fetching ?? false;
  const activeProvider = settings?.provider ?? snapshot?.provider;
  const manualViews = settings?.viewMode === "manual";
  const clockActive = manualViews && settings.views[settings.activeView]?.kind === "clock";
  const viewLabel = (view: ViewContent) => view.kind === "clock"
    ? t("views.clock")
    : providers.find((provider) => provider.key === view.provider)?.label ?? view.provider;

  return (
    <section className="page">
      <header className="page-head">
        <h1>{t("nav.overview")}</h1>
        {fetching && <span className="spinner" role="status" aria-label={t("ov.fetching")} />}
        <button type="button" className="btn" onClick={onRefresh} disabled={fetching}>
          {t("ov.refresh")}
        </button>
      </header>

      {manualViews && (
        <div className="field-row">
          <span className="field-label">{t("views.manual.choose")}</span>
          <div className="segmented window-selector" role="group" aria-label={t("views.manual.choose")}>
            {settings.views.map((view, index) => (
              <button key={index} type="button" className={index === settings.activeView ? "is-active" : undefined}
                aria-pressed={index === settings.activeView}
                onClick={() => onSettings({ activeView: index, ...(view.kind === "provider" ? { provider: view.provider } : {}) })}>
                <span>{t("views.window", { number: index + 1 })}</span>
                <span className="window-selector-content">{viewLabel(view)}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {!manualViews && <div className="field-row">
        <span className="field-label">{t("ov.source")}</span>
        <div className="segmented" role="group" aria-label={t("ov.source")}>
          {providers.map((p) => (
            <button
              key={p.key}
              type="button"
              className={p.key === activeProvider ? "is-active" : undefined}
              aria-pressed={p.key === activeProvider}
              onClick={() => onProvider(p.key)}
            >
              {p.label}
            </button>
          ))}
        </div>
      </div>}

      {clockActive && <p className="notice">{t("views.clock.active")}</p>}

      {!clockActive && snapshot && status && (
        <>
          <div className="status-line">
            <span className={`pill pill-${snapshot.status.kind}`}>{status.label}</span>
            {status.message && <span className="muted status-message">{status.message}</span>}
          </div>

          {snapshot.rows.length === 0 ? (
            <p className="muted">{t("ov.rows.empty")}</p>
          ) : (
            <ul className="rows">
              {snapshot.rows.map((row) => (
                <li key={row.id} className="row">
                  <div className="row-head">
                    <span className="row-title">{row.title}</span>
                    <span className="row-percent">{row.usedPercent} %</span>
                  </div>
                  <div className="bar" aria-hidden="true">
                    <div className="bar-fill" style={{ width: `${Math.min(100, Math.max(0, row.usedPercent))}%` }} />
                  </div>
                  <div className="row-meta muted">{formatCountdown(t, row.resetsAt, now)}</div>
                </li>
              ))}
            </ul>
          )}

          <p className="meta-line muted">
            {snapshot.source && (
              <span>
                {t("ov.source.label")}: {snapshot.source}
              </span>
            )}
            <span>{formatAgo(t, snapshot.updatedAt, now)}</span>
            <span>
              {t("ov.login.label")}: {snapshot.loginLabel}
            </span>
          </p>
        </>
      )}

      {settings && (
        <>
          <h2>{t("ov.settings.title")}</h2>
          <div className="field-row">
            <span className="field-label">{t("ov.percent.label")}</span>
            <div className="segmented" role="group" aria-label={t("ov.percent.label")}>
              {(["used", "remaining"] as PercentMode[]).map((mode) => (
                <button
                  key={mode}
                  type="button"
                  className={settings.percentMode === mode ? "is-active" : undefined}
                  aria-pressed={settings.percentMode === mode}
                  onClick={() => onSettings({ percentMode: mode })}
                >
                  {t(`ov.percent.${mode}`)}
                </button>
              ))}
            </div>
          </div>
          <div className="field-row">
            <span className="field-label">{t("ov.language.label")}</span>
            <div className="segmented" role="group" aria-label={t("ov.language.label")}>
              {(["system", "de", "en"] as Language[]).map((lang) => (
                <button
                  key={lang}
                  type="button"
                  className={settings.language === lang ? "is-active" : undefined}
                  aria-pressed={settings.language === lang}
                  onClick={() => onSettings({ language: lang })}
                >
                  {t(`ov.language.${lang}`)}
                </button>
              ))}
            </div>
          </div>
          <label className="check-row">
            <input
              type="checkbox"
              checked={settings.autostart}
              onChange={(e) => onSettings({ autostart: e.target.checked })}
            />
            <span>
              <span className="check-title">{t("ov.autostart.label")}</span>
              <span className="muted check-detail">{t("ov.autostart.detail")}</span>
            </span>
          </label>
        </>
      )}
    </section>
  );
}
