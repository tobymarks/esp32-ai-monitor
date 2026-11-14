import { useEffect, useRef, useState } from "react";
import { standaloneAction, standalonePreview, type ConnectionSnapshot, type PluginInfo, type StandaloneExport, type StandaloneStatus } from "../api";
import type { Translate } from "../i18n";

export default function Standalone({ connection, plugins, t }: { connection: ConnectionSnapshot | null; plugins: PluginInfo[]; t: Translate }) {
  const message = (key: string) => {
    const translated = t(key);
    return translated === key && key.startsWith("standalone.")
      ? `${t("standalone.failed")} (${key.split(".").slice(2).join(".") || key})` : translated;
  };
  const mac = connection?.profile?.mac;
  const supported = connection?.state === "connected" && connection.info?.standaloneProtocol === 1;
  const [id, setId] = useState("");
  const [preview, setPreview] = useState<StandaloneExport | null>(null);
  const [status, setStatus] = useState<StandaloneStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [previewRequest, setPreviewRequest] = useState(0);
  const [systemDark, setSystemDark] = useState(() =>
    typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  const revision = useRef(0);
  const connectionRevision = useRef(0);
  const stateRequest = useRef(0);
  useEffect(() => {
    const appearance = window.matchMedia("(prefers-color-scheme: dark)");
    const changed = () => setSystemDark(appearance.matches);
    changed();
    appearance.addEventListener("change", changed);
    return () => appearance.removeEventListener("change", changed);
  }, []);
  // Every setting influencing the snapshot invalidates its preview; a response
  // for an old device or old settings must never unlock Install.
  const context = JSON.stringify([mac, connection?.state, connection?.profile?.theme,
    connection?.profile?.theme === "system" ? systemDark : null,
    connection?.profile?.orientation, connection?.profile?.language,
    connection?.profile?.location, plugins.map(p => [p.id, p.sha256, p.settings])]);
  useEffect(() => {
    const generation = ++revision.current;
    setPreview(null); setError(null);
    if (!mac || !id) return;
    standalonePreview(mac, id).then(value => { if (generation === revision.current) setPreview(value); })
      .catch(e => { if (generation === revision.current) setError(String(e)); });
    return () => { revision.current++; };
  }, [context, id, previewRequest]);
  useEffect(() => {
    connectionRevision.current += 1;
    const request = ++stateRequest.current;
    setStatus(null); setBusy(false);
    if (!supported || !mac) return;
    let active = true;
    standaloneAction(mac, "status").then(value => { if (active && request === stateRequest.current) setStatus(value); })
      .catch(e => { if (active && request === stateRequest.current) setError(String(e)); });
    return () => { active = false; };
  }, [mac, supported]);

  const act = async (action: string) => {
    if (!mac || !supported || busy) return;
    const generation = connectionRevision.current;
    stateRequest.current += 1;
    setBusy(true); setError(null);
    try {
      const value = await standaloneAction(mac, action, id || undefined, preview?.sha256);
      if (generation === connectionRevision.current) setStatus(value);
    } catch (e) {
      if (generation === connectionRevision.current) {
        setError(String(e));
        if (String(e) === "standalone.changed") {
          setPreview(null);
          setPreviewRequest(value => value + 1);
        }
      }
    }
    finally { if (generation === connectionRevision.current) setBusy(false); }
  };
  const stale = status?.digest && preview && status.profileId === preview.pluginId && status.digest !== preview.sha256;
  return <section aria-labelledby="standalone-heading">
    <h2 id="standalone-heading">{t("standalone.title")}</h2>
    <p className="muted">{t("standalone.intro")}</p>
    <p className="notice">{t("standalone.experimental")}</p>
    {!supported && <p className="muted">{t(connection?.state === "connected" ? "standalone.unsupported" : "standalone.connect")}</p>}
    <div className="field-row">
      <label className="field-label" htmlFor="standalone-plugin">{t("standalone.plugin")}</label>
      <select id="standalone-plugin" className="select" value={id} disabled={busy || !mac} onChange={e => setId(e.target.value)}>
        <option value="">{t("standalone.select")}</option>
        {plugins.map(p => <option value={p.id} key={p.id}>{p.name}</option>)}
      </select>
    </div>
    {preview && <p>{preview.name} · {preview.origin} · {t("standalone.interval", { seconds: preview.refreshSeconds })}<br />
      {t(preview.sendsLocation ? "standalone.location" : "standalone.noLocation")}</p>}
    {status && <p aria-live="polite">{t("standalone.device")}: {status.profileId || t("standalone.none")} {status.pluginVersion}
      {" · "}{t(status.enabled ? "standalone.enabled" : "standalone.disabled")}{" · "}{message(`standalone.state.${status.state}`)}
      {status.lastSuccessAgeSeconds != null && ` · ${t("standalone.age", { seconds: status.lastSuccessAgeSeconds })}`}
      {status.error && <><br />{message(`standalone.error.${status.error}`)}</>}
      {status.digest && <><br /><span className="mono small">SHA-256: {status.digest}</span></>}
    </p>}
    {stale && <p className="notice">{t("standalone.changed")}</p>}
    {status && !status.storageReady && <p className="notice">{t("standalone.setupHint")}</p>}
    <div className="field-row">
      {status && !status.storageReady && <button className="btn" disabled={busy || !supported} onClick={() => act("setup")}>{t("standalone.setup")}</button>}
      <button className="btn" disabled={busy || !supported || !preview || !status?.storageReady} onClick={() => act("install")}>{t("standalone.install")}</button>
      <button className="btn" disabled={busy || !supported} onClick={() => act("status")}>{t("standalone.refresh")}</button>
      <button className="btn" disabled={busy || !supported || !status?.profileId} onClick={() => act(status?.enabled ? "disable" : "enable")}>{t(status?.enabled ? "standalone.disable" : "standalone.enable")}</button>
      <button className="btn" disabled={busy || !supported || !status?.profileId} onClick={() => act("remove")}>{t("standalone.remove")}</button>
    </div>
    {error && <p className="notice-bad" role="alert">{message(error)}</p>}
  </section>;
}
