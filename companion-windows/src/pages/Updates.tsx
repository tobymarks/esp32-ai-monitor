import { useEffect, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  checkUpdates,
  detectChip,
  flashFirmware,
  flashLocalFirmware,
  getUpdateStatus,
  installAppUpdate,
  onFirmwareDownload,
  onFlashProgress,
  onPanelCorrection,
  onUpdateProgress,
  onUpdates,
  openReleasePage,
  type ConnectionSnapshot,
  type DetectedChip,
  type DisplayVariant,
  type PanelCorrection,
  type DownloadProgress,
  type FlashOutcome,
  type FlashProgress,
  type Settings,
  type UpdateChannel,
  type UpdateStatus,
} from "../api";
import type { Translate } from "../i18n";

interface Props {
  t: Translate;
  connection: ConnectionSnapshot | null;
  settings: Settings | null;
  onSettings: (patch: Partial<Settings>) => void;
}

const CHANNELS: UpdateChannel[] = ["stable", "beta"];
const isWindows = /Windows/i.test(navigator.userAgent);

/// Backend-Fehler kommen als i18n-Schlüssel, teils mit Detail nach ": ".
function translateError(t: Translate, e: unknown): string {
  const text = String(e);
  const idx = text.indexOf(": ");
  if (idx < 0) return t(text);
  return `${t(text.slice(0, idx))} (${text.slice(idx + 2)})`;
}

function formatTime(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString();
}

function percentOf(p: DownloadProgress | null): number | null {
  if (!p || !p.total) return null;
  return Math.min(100, Math.round((p.received / p.total) * 100));
}

/// Gemeldetes Panel als CYD-Variante; `noreply`, S3 und Unbekanntes ergeben null.
function cydPanel(panel: string | null | undefined): DisplayVariant | null {
  return panel === "ili9341" || panel === "st7789" ? panel : null;
}

function variantKey(v: DisplayVariant): string {
  return v === "ili9341" ? "flashdlg.variant.standard" : v === "st7789" ? "flashdlg.variant.alt" : "flashdlg.variant.s3";
}

/// Kurze Rückfrage statt Variantenwahl, wenn die Variante feststeht:
/// vom Gerät gemeldet, per Chip eindeutig (S3) oder CYD mit Panel-Erkennung.
interface Confirm {
  variant: DisplayVariant;
  kind: "reported" | "chip" | "cyd";
}

/// Verlaufsanzeige für Download und Flash (Balken aus der Übersicht).
function Progress({ percent, indeterminate }: { percent: number | null; indeterminate?: boolean }) {
  return (
    <div className={indeterminate ? "bar bar-indeterminate" : "bar"} aria-hidden="true">
      <div className="bar-fill" style={{ width: `${indeterminate ? 30 : (percent ?? 0)}%` }} />
    </div>
  );
}

export default function Updates({ t, connection, settings, onSettings }: Props) {
  const [status, setStatus] = useState<UpdateStatus | null>(null);
  const [checking, setChecking] = useState(false);

  const [installing, setInstalling] = useState(false);
  const [installProgress, setInstallProgress] = useState<DownloadProgress | null>(null);
  const [installMessage, setInstallMessage] = useState<string | null>(null);
  const [installError, setInstallError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [localPath, setLocalPath] = useState<string | null>(null);
  const [chooseError, setChooseError] = useState<string | null>(null);
  const [variant, setVariant] = useState<DisplayVariant>("ili9341");
  const [flashing, setFlashing] = useState(false);
  const [flash, setFlash] = useState<FlashProgress | null>(null);
  const [download, setDownload] = useState<DownloadProgress | null>(null);
  const [outcome, setOutcome] = useState<FlashOutcome | null>(null);
  const [flashError, setFlashError] = useState<{ summary: string; detail: string | null; message: string | null } | null>(null);
  const [confirm, setConfirm] = useState<Confirm | null>(null);
  const [detecting, setDetecting] = useState(false);
  const [detectedChip, setDetectedChip] = useState<DetectedChip | null>(null);
  /// Die App flasht von selbst nach, weil das Panel nicht zur Firmware passt.
  const [correcting, setCorrecting] = useState<PanelCorrection | null>(null);

  // Status laden und alle Live-Events abonnieren.
  useEffect(() => {
    const unlisteners: (() => void)[] = [];
    let cancelled = false;
    (async () => {
      unlisteners.push(await onUpdates((s) => setStatus(s)));
      unlisteners.push(await onFirmwareDownload((p) => setDownload(p)));
      unlisteners.push(await onUpdateProgress((p) => setInstallProgress(p)));
      unlisteners.push(
        await onPanelCorrection((v) => {
          setCorrecting(v);
          setConfirm(null);
          setLocalPath(null);
          setFlash(null);
          setOutcome(null);
          setFlashError(null);
          setDialogOpen(true);
        }),
      );
      unlisteners.push(
        await onFlashProgress((p) => {
          setFlash(p);
          if (p.phase === "failed") {
            setFlashError({ summary: p.summary ?? "flash.err.incomplete", detail: p.detail, message: p.message });
          }
        }),
      );
      const s = await getUpdateStatus();
      if (!cancelled) setStatus(s);
    })().catch((e) => console.error("updates init", e));
    return () => {
      cancelled = true;
      unlisteners.forEach((u) => u());
    };
  }, []);

  // Vorauswahl der Variante aus dem Geräteprofil, sonst Standard.
  useEffect(() => {
    if (!flashing && status?.firmware.deviceVariant) setVariant(status.firmware.deviceVariant);
  }, [status?.firmware.deviceVariant, flashing]);

  const runCheck = async () => {
    setChecking(true);
    try {
      setStatus(await checkUpdates(true));
    } catch (e) {
      console.error("check_updates", e);
    } finally {
      setChecking(false);
    }
  };

  const chooseChannel = (channel: UpdateChannel) => {
    if (settings && settings.updateChannel !== channel) onSettings({ updateChannel: channel });
  };

  const runInstall = async () => {
    setInstalling(true);
    setInstallError(null);
    setInstallMessage(null);
    setInstallProgress(null);
    try {
      const result = await installAppUpdate();
      setInstallMessage(result === "installerStarted" ? t("upd.install.started") : t("upd.install.browser"));
    } catch (e) {
      setInstallError(translateError(t, e));
    } finally {
      setInstalling(false);
    }
  };

  const runFlash = async (chosen: DisplayVariant, autoPicked = false) => {
    setConfirm(null);
    setVariant(chosen);
    setFlashing(true);
    setFlash({ phase: localPath ? "connecting" : "downloading", variant: chosen, percent: null, message: null, summary: null, detail: null });
    setDownload(null);
    setOutcome(null);
    setFlashError(null);
    try {
      setOutcome(localPath
        ? await flashLocalFirmware(chosen, localPath)
        : await flashFirmware(chosen, autoPicked));
    } catch (e) {
      // Das Detail kam schon über das failed-Event; sonst den Text selbst zeigen.
      setFlashError((prev) => prev ?? { summary: String(e), detail: null, message: null });
    } finally {
      setFlashing(false);
    }
  };

  /// „Firmware flashen": Variante möglichst ohne Nachfrage bestimmen. Läuft
  /// AI-Monitor-Firmware, gilt das ausgelesene Panel, sonst die gemeldete
  /// Variante. Sonst den Chip auslesen: S3 eindeutig, ESP32 ist ein CYD.
  const startFlash = async () => {
    setLocalPath(null);
    setDetectedChip(null);
    setConfirm(null);
    setCorrecting(null);
    setFlash(null);
    setOutcome(null);
    setFlashError(null);
    const releaseReady = !!port && !(connection?.paused ?? false) && filesComplete;
    const reported = connection?.state === "connected"
      ? cydPanel(connection.info?.panel) ?? connection.info?.display ?? fw?.deviceVariant ?? null
      : null;
    if (reported && releaseReady && (reported !== "st7701" || fw?.s3Available)) {
      setVariant(reported);
      setConfirm({ variant: reported, kind: "reported" });
      setDialogOpen(true);
      return;
    }
    let chip: DetectedChip | null = null;
    if (port) {
      setDetecting(true);
      try {
        chip = await detectChip();
      } catch (e) {
        console.error("detect_chip", e);
      } finally {
        setDetecting(false);
      }
    }
    if (chip === "esp32s3" && fw?.s3Available && releaseReady) {
      setVariant("st7701");
      setConfirm({ variant: "st7701", kind: "chip" });
    } else if (chip === "esp32" && fw?.panelDetection && releaseReady) {
      setVariant("ili9341");
      setConfirm({ variant: "ili9341", kind: "cyd" });
    } else {
      setDetectedChip(chip);
      if (chip === "esp32s3") setVariant("st7701");
      else if (chip === "esp32" && variant === "st7701") setVariant("ili9341");
    }
    setDialogOpen(true);
  };

  const chooseLocalFirmware = async () => {
    setChooseError(null);
    try {
      const path = await open({ multiple: false, directory: false, filters: [{ name: "Firmware", extensions: ["bin"] }] });
      if (typeof path === "string") {
        setLocalPath(path);
        setConfirm(null);
        setDetectedChip(null);
        setDialogOpen(true);
      }
    } catch (e) {
      setChooseError(translateError(t, e));
    }
  };

  const closeDialog = () => {
    if (flashBusy) return;
    setDialogOpen(false);
    setConfirm(null);
    setDetectedChip(null);
    setCorrecting(null);
    setLocalPath(null);
    setFlash(null);
    setOutcome(null);
    setFlashError(null);
  };

  // -- App-Box ----------------------------------------------------------

  const app = status?.app ?? null;
  const busy = checking || (status?.checking ?? false);
  const resultText = (() => {
    if (busy) return t("upd.checking");
    if (!status) return t("upd.never");
    if (status.error) return t("upd.result.error", { error: status.error });
    if (!app?.latestVersion) return t("upd.result.norelease");
    if (app.hasUpdate) return t("upd.result.available", { version: app.latestVersion });
    return t("upd.result.current", { version: app.currentVersion });
  })();
  const installPercent = percentOf(installProgress);

  // -- Firmware-Box -----------------------------------------------------

  const fw = status?.firmware ?? null;
  const port = connection?.port ?? null;
  const releaseLoaded = !!fw?.latestTag;
  const filesComplete = releaseLoaded && (fw?.missingAssets.length ?? 0) === 0;
  // Ein Nachflashen läuft im Backend; `flashing` kennt nur eigene Aufrufe.
  const correctionBusy = !!correcting && (!flash || (flash.phase !== "done" && flash.phase !== "failed"));
  const correctionDone = !!correcting && flash?.phase === "done";
  const flashBusy = flashing || correctionBusy;
  const s3WithoutImage = detectedChip === "esp32s3" && !localPath && !fw?.s3Available;
  const ready = !!port && !flashBusy && !(connection?.paused ?? false) && (!!localPath || filesComplete) && !s3WithoutImage;
  // Firmware-Variante und ausgelesenes Panel passen nicht zusammen.
  const panelVariant = connection?.state === "connected" ? cydPanel(connection.info?.panel) : null;
  const runningVariant = connection?.info?.display ?? null;
  const panelMismatch = !!panelVariant && !!runningVariant && runningVariant !== "st7701"
    && panelVariant !== runningVariant && !flashBusy && !(connection?.paused ?? false);
  const deviceName = connection?.profile?.friendlyName ?? "ESP32";
  const shortPort = port ? port.replace(/^\/dev\//, "") : "";

  const phaseText = (() => {
    if (!flash) return "";
    switch (flash.phase) {
      case "downloading": {
        const p = percentOf(download);
        return p === null ? t("flash.step.download") : `${t("flash.step.download")} ${p} %`;
      }
      case "connecting":
        return t("flash.step.connect");
      case "connected":
        return t("flash.step.connected", { chip: flash.message ?? "ESP32" });
      case "erasing":
        return t("flash.step.erase");
      case "writing":
        return t("flash.step.write", { percent: flash.percent ?? 0 });
      case "verifying":
        return t("flash.step.verify");
      case "rebooting":
        return t("flash.step.reboot");
      case "done":
        return t("flash.step.done");
      case "failed":
        return t("flash.failed.title");
    }
  })();
  const flashPercent = (() => {
    if (!flash) return null;
    switch (flash.phase) {
      case "downloading":
        return percentOf(download);
      case "writing":
        return flash.percent;
      case "verifying":
      case "rebooting":
      case "done":
        return 100;
      default:
        return null;
    }
  })();

  return (
    <section className="page">
      <header className="page-head">
        <h1>{t("nav.updates")}</h1>
        {busy && <span className="spinner" role="status" aria-label={t("upd.checking")} />}
      </header>

      <h2>{t("upd.app.title")}</h2>
      <div className="field-row">
        <span className="field-label">{t("upd.app.current")}</span>
        <span className="mono">{app?.currentVersion ?? "—"}</span>
      </div>
      <div className="field-row">
        <span className="field-label">{t("upd.channel.label")}</span>
        <div className="segmented" role="group" aria-label={t("upd.channel.label")} title={t("upd.channel.tooltip")}>
          {CHANNELS.map((c) => (
            <button
              key={c}
              type="button"
              className={(settings?.updateChannel ?? "stable") === c ? "is-active" : undefined}
              aria-pressed={(settings?.updateChannel ?? "stable") === c}
              onClick={() => chooseChannel(c)}
            >
              {t(`upd.channel.${c}`)}
            </button>
          ))}
        </div>
      </div>
      <p className="muted">{t("upd.channel.intro")}</p>
      <div className="actions">
        <button type="button" className="btn" onClick={runCheck} disabled={busy} title={t("upd.check.tooltip")}>
          {t("upd.check")}
        </button>
        {app?.hasUpdate &&
          (isWindows && app.assetAvailable ? (
            <button type="button" className="btn btn-primary" onClick={runInstall} disabled={installing}>
              {t("upd.install")}
            </button>
          ) : (
            <button type="button" className="btn" onClick={() => openReleasePage().catch((e) => setInstallError(translateError(t, e)))}>
              {t("common.open_browser")}
            </button>
          ))}
      </div>
      <p className={status?.error ? "error-text error-text-plain" : "muted"}>{resultText}</p>
      <p className="muted small">{status?.checkedAt ? t("upd.last", { time: formatTime(status.checkedAt) }) : t("upd.never")}</p>
      {installing && (
        <div className="progress-block">
          <Progress percent={installPercent} indeterminate={installPercent === null} />
          <span className="muted mono">{t("upd.install.progress", { percent: installPercent ?? 0 })}</span>
        </div>
      )}
      {installMessage && <p className="notice">{installMessage}</p>}
      {installError && <p className="notice-bad">{installError}</p>}

      <h2>{t("fw.title")}</h2>
      <p>{fw?.deviceVersion ? t("fw.installed", { version: fw.deviceVersion }) : t("fw.installed.unknown")}</p>
      <p className="muted">{t("fw.variant", { variant: fw?.deviceVariant ?? t("conn.device.variant.unknown") })}</p>
      {fw?.latestVersion ? (
        fw.hasUpdate ? (
          <p className="notice">
            <strong>{t("fw.update.line", { version: fw.latestVersion })}</strong>
            <br />
            {t("fw.update.device", { name: deviceName, device: fw.deviceVersion ?? "—", latest: fw.latestVersion })}
          </p>
        ) : (
          <p className="muted">
            {fw.deviceVersion ? t("fw.current") : t("fw.latest", { version: fw.latestVersion })}
          </p>
        )
      ) : (
        <p className="muted">{status ? t("release.none.info") : t("upd.never")}</p>
      )}
      {panelMismatch && !dialogOpen && (
        <div className="notice-warn">
          <strong>{t("panel.mismatch.title")}</strong>
          <br />
          {t("panel.mismatch.detail", { panel: t(variantKey(panelVariant!)), firmware: t(variantKey(runningVariant!)) })}
          <div className="actions">
            <button type="button" className="btn" onClick={() => { setDialogOpen(true); runFlash(panelVariant!); }} disabled={!port}>
              {t("panel.mismatch.action")}
            </button>
          </div>
        </div>
      )}
      {!dialogOpen && (
        <div className="actions">
          <button type="button" className="btn" onClick={startFlash} disabled={flashBusy || detecting} title={t("upd.flash.tooltip")}>
            {t("flash.action.short")}
          </button>
          <button type="button" className="btn" onClick={chooseLocalFirmware} disabled={flashBusy || detecting}>
            {t("flash.local.choose")}
          </button>
        </div>
      )}
      {detecting && <p className="muted">{t("flash.detecting")}</p>}
      {chooseError && <p className="notice-bad">{chooseError}</p>}

      {dialogOpen && (
        <div className="card" role="dialog" aria-label={t("flashdlg.title")}>
          <h3>{confirm && !flash ? t("flash.confirm.title", { version: fw?.latestVersion ?? "?" }) : t("flashdlg.title")}</h3>
          {correcting && (
            <p className="notice">
              <strong>{t(correctionDone ? "panel.fix.done.title" : "panel.fix.running.title")}</strong>
              <br />
              {t(correctionDone ? "panel.fix.done.detail" : "panel.fix.running.detail", { from: t(variantKey(correcting.from)), to: t(variantKey(correcting.to)) })}
            </p>
          )}
          <p className="muted">{localPath ? `${localPath.split(/[\\/]/).pop()} · ${t("flash.local.format")}` : t("flashdlg.info", { port: shortPort || "—", version: fw?.latestVersion ?? fw?.deviceVersion ?? "?" })}</p>
          {!flash ? <p className="notice-warn">{t("flash.hint.reset")}</p> : null}

          {!flash && confirm && (
            <>
              <p>
                {confirm.kind === "cyd"
                  ? t("flash.confirm.cyd")
                  : t(confirm.kind === "chip" ? "flash.confirm.chip" : "flash.confirm.reported", { variant: t(variantKey(confirm.variant)) })}
              </p>
              <div className="actions">
                <button type="button" className="btn" onClick={closeDialog}>
                  {t("common.cancel")}
                </button>
                {confirm.variant !== "st7701" && (
                  <button
                    type="button"
                    className="btn"
                    onClick={() => {
                      setDetectedChip(confirm.kind === "reported" ? null : "esp32");
                      setConfirm(null);
                    }}
                  >
                    {t("flash.confirm.other")}
                  </button>
                )}
                <button type="button" className="btn btn-primary" onClick={() => runFlash(confirm.variant, confirm.kind === "cyd")} disabled={!ready}>
                  {t("flash.confirm.start")}
                </button>
              </div>
            </>
          )}

          {!flash && !confirm && (
            <>
              <h4>{t("flashdlg.preflight")}</h4>
              <ul className={ready ? "preflight" : "preflight preflight-warn"}>
                <li>{port ? t("flash.pre.usb.ok", { port: shortPort }) : t("flash.pre.usb.missing")}</li>
                {!localPath && <li>
                  {!releaseLoaded
                    ? t("flash.pre.release.none")
                    : filesComplete
                      ? t("flash.pre.files.ok")
                      : t("flash.pre.files.missing", { names: fw?.missingAssets.join(", ") ?? "" })}
                </li>}
                <li>{t("flash.pre.tool.ok")}</li>
                <li>{t("flash.hint.cable")}</li>
              </ul>
              {!ready && <p className="notice-warn">{t("flash.hint.ready")}</p>}

              <h4>{t("flashdlg.variant")}</h4>
              <div className="radio-group" role="radiogroup" aria-label={t("flashdlg.variant")}>
                {(["ili9341", "st7789", "st7701"] as DisplayVariant[]).map((v) => {
                  // Das S3-Image gibt es erst ab Firmware 2.19.0; eine lokale Datei geht immer.
                  const s3Missing = v === "st7701" && !localPath && !fw?.s3Available;
                  // Der ausgelesene Chip schließt die Varianten des anderen Boards aus.
                  const wrongChip = detectedChip === "esp32s3" ? v !== "st7701" : detectedChip === "esp32" ? v === "st7701" : false;
                  const unavailable = s3Missing || wrongChip;
                  return (
                    <label key={v} className="radio-row">
                      <input type="radio" name="variant" value={v} checked={variant === v} disabled={unavailable} onChange={() => setVariant(v)} />
                      <span>{t(v === "st7701" && s3Missing ? "flashdlg.variant.s3.missing" : variantKey(v))}</span>
                    </label>
                  );
                })}
              </div>
              <p className="muted small">{t(detectedChip === "esp32" ? "flashdlg.variant.hint.cyd" : detectedChip === "esp32s3" ? "flashdlg.variant.hint.s3" : "flashdlg.variant.hint")}</p>

              <div className="actions">
                <button type="button" className="btn" onClick={closeDialog}>
                  {t("common.cancel")}
                </button>
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() => runFlash(variant)}
                  disabled={!ready}
                  title={ready ? t("flashdlg.start.tooltip") : t("flashdlg.blocked")}
                >
                  {t("flashdlg.start")}
                </button>
              </div>
            </>
          )}

          {flash && (
            <>
              <div className="progress-block">
                <Progress percent={flashPercent} indeterminate={flashBusy && flashPercent === null} />
                <span className={flash.phase === "failed" ? "error-text error-text-plain mono" : "muted mono"}>{phaseText}</span>
              </div>

              {outcome && (
                <p className="notice">
                  <strong>{t("flash.ok.info")}</strong> {outcome.tag === "local" ? t("flash.local.version") : outcome.version} · {outcome.variant} · {outcome.seconds.toFixed(1)} s
                  <br />
                  {t("flash.ok.detail")}
                </p>
              )}
              {flashError && (
                <div className="notice-bad">
                  <strong>{t(flashError.summary)}</strong>
                  {flashError.detail && (
                    <>
                      <br />
                      {t(flashError.detail)}
                    </>
                  )}
                  {flashError.message && (
                    <>
                      <br />
                      <span className="mono">{flashError.message}</span>
                    </>
                  )}
                  <br />
                  {t(localPath ? "flash.local.recovery" : "flash.recovery")}
                </div>
              )}

              {!flashBusy && (
                <div className="actions">
                  {flashError && (
                    <>
                      <button type="button" className="btn" onClick={() => runFlash(variant)} disabled={!port}>
                        {t("flash.retry")}
                      </button>
                      {!localPath && variant !== "st7701" && <button
                        type="button"
                        className="btn"
                        onClick={() => runFlash(variant === "ili9341" ? "st7789" : "ili9341")}
                        disabled={!port}
                      >
                        {t("flash.othervariant.short")}
                      </button>}
                    </>
                  )}
                  <button type="button" className="btn" onClick={closeDialog}>
                    {t("flash.close")}
                  </button>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </section>
  );
}
