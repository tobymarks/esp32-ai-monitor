import { useEffect, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  configurePlugin, inspectPlugin, installPlugin, removePlugin,
  pluginText, type PluginInfo, type PluginPreview,
} from "../api";
import { pluginError, type Translate } from "../i18n";
import ClaudeCodeCard from "./ClaudeCodeCard";

interface Props {
  t: Translate;
  locale: string;
  plugins: PluginInfo[];
  /** Für das verbundene (sonst zuletzt bekannte) Display ist ein Standort hinterlegt. */
  hasLocation: boolean;
  onRefresh: () => void;
}

function PluginSettings({ t, locale, plugin, hasLocation, onRefresh }: { t: Translate; locale: string; plugin: PluginInfo; hasLocation: boolean; onRefresh: () => void }) {
  const [values, setValues] = useState(plugin.settings);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const savedSettings = JSON.stringify(plugin.settings);
  useEffect(() => setValues(plugin.settings), [plugin.id, savedSettings]);

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      await configurePlugin(plugin.id, values);
      onRefresh();
    } catch (e) {
      setError(pluginError(e, t));
    } finally { setBusy(false); }
  };
  const remove = async () => {
    if (!window.confirm(t("plugins.remove.confirm", { name: pluginText(plugin, locale, plugin.name) }))) return;
    setBusy(true);
    setError(null);
    try {
      await removePlugin(plugin.id);
      onRefresh();
    } catch (e) {
      setError(pluginError(e, t));
      setBusy(false);
    }
  };

  return (
    <article className="card plugin-card">
      <div className="plugin-card-head">
        <div><h3>{pluginText(plugin, locale, plugin.name)} <span className="muted">v{plugin.version}</span></h3>
          <p className="muted">{pluginText(plugin, locale, plugin.description)}</p></div>
        <button type="button" className="btn" disabled={busy} onClick={remove}>{t("plugins.remove")}</button>
      </div>
      <p className="muted small">{t("plugins.by", { author: plugin.author })} · {plugin.sourceOrigin} · {t("plugins.unsigned")}</p>
      {plugin.requiresLocation && (
        <p className="muted small">{t("plugins.location", { origin: plugin.sourceOrigin })}{!hasLocation && ` ${t("plugins.location.missing")}`}</p>
      )}
      {plugin.attribution && <p className="muted small">{pluginText(plugin, locale, plugin.attribution)}</p>}
      <div className="plugin-settings">
        {plugin.settingsSpec.map((spec) => (
          <label key={spec.key} className="field-row">
            <span className="field-label">{pluginText(plugin, locale, spec.label)}</span>
            <input className="input" type={spec.kind === "number" ? "number" : spec.kind === "url" ? "url" : "text"}
              style={spec.kind === "url" ? { flex: 1, minWidth: 0 } : undefined}
              maxLength={spec.kind === "url" ? 2048 : undefined}
              spellCheck={spec.kind === "url" ? false : undefined}
              min={spec.min ?? undefined} max={spec.max ?? undefined}
              step={spec.kind === "number" ? "any" : undefined}
              value={values[spec.key] ?? ""} disabled={busy}
              onChange={(event) => setValues((current) => ({
                ...current,
                [spec.key]: spec.kind === "number" ? Number(event.target.value) : event.target.value,
              }))} />
          </label>
        ))}
      </div>
      <div className="field-row">
        {plugin.settingsSpec.length > 0 && (
          <button type="button" className="btn btn-primary" onClick={save} disabled={busy}>{t("plugins.save")}</button>
        )}
        <span className="muted small">{plugin.lastError
          ? t("plugins.error", { message: plugin.lastError })
          : plugin.fetchedAt ? t("plugins.updated", { time: new Date(plugin.fetchedAt).toLocaleString() })
            : t("plugins.waiting")}</span>
      </div>
      {error && <p className="notice" role="alert">{error}</p>}
    </article>
  );
}

export default function Plugins({ t, locale, plugins, hasLocation, onRefresh }: Props) {
  const [source, setSource] = useState("");
  const [candidate, setCandidate] = useState<PluginPreview | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const chooseFile = async () => {
    try {
      const path = await open({ multiple: false, filters: [{ name: "AI Monitor plugin", extensions: ["aimplugin"] }] });
      if (typeof path === "string") { setSource(path); setCandidate(null); setError(null); }
    } catch (e) { setError(pluginError(e, t)); }
  };
  const inspect = async () => {
    setBusy(true);
    setError(null);
    setCandidate(null);
    try { setCandidate(await inspectPlugin(source.trim())); }
    catch (e) { setError(pluginError(e, t)); }
    finally { setBusy(false); }
  };
  const install = async () => {
    if (!candidate) return;
    setBusy(true);
    setError(null);
    try {
      await installPlugin(source.trim(), candidate.sha256);
      setCandidate(null);
      setSource("");
      onRefresh();
    } catch (e) { setError(pluginError(e, t)); }
    finally { setBusy(false); }
  };

  return (
    <section className="page">
      <header className="page-head"><h1>{t("nav.plugins")}</h1></header>
      <p className="muted">{t("plugins.intro")}</p>
      <ClaudeCodeCard t={t} />
      <div className="card">
        <h3>{t("plugins.add")}</h3>
        <p className="muted small">{t("plugins.add.hint")}</p>
        <div className="field-row">
          <input className="input plugin-source" value={source} disabled={busy}
            placeholder={t("plugins.source.placeholder")}
            onChange={(event) => { setSource(event.target.value); setCandidate(null); }} />
          <button type="button" className="btn" onClick={chooseFile} disabled={busy}>{t("plugins.choose")}</button>
          <button type="button" className="btn" onClick={inspect} disabled={busy || !source.trim()}>{t("plugins.inspect")}</button>
        </div>
        {candidate && (
          <div className="plugin-preview">
            <h4>{pluginText(candidate, locale, candidate.name)} · v{candidate.version}</h4>
            <p>{pluginText(candidate, locale, candidate.description)}</p>
            <p className="muted small">{t("plugins.by", { author: candidate.author })}</p>
            <p>{t("plugins.permission", { origin: candidate.sourceOrigin })}</p>
            {candidate.requiresLocation && <p>{t("plugins.location", { origin: candidate.sourceOrigin })}</p>}
            <p className="muted small">{t("plugins.unsigned")} · SHA-256 {candidate.sha256.slice(0, 16)}…</p>
            {candidate.attribution && <p className="muted small">{pluginText(candidate, locale, candidate.attribution)}</p>}
            <button type="button" className="btn btn-primary" onClick={install} disabled={busy}>{t("common.install")}</button>
          </div>
        )}
        {error && <p className="notice" role="alert">{error}</p>}
      </div>
      <h2>{t("plugins.installed")}</h2>
      {plugins.length === 0 && <p className="muted">{t("plugins.none")}</p>}
      {plugins.map((plugin) => <PluginSettings key={plugin.id} t={t} locale={locale} plugin={plugin} hasLocation={hasLocation} onRefresh={onRefresh} />)}
    </section>
  );
}
