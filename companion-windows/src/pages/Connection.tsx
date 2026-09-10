import { useEffect, useState } from "react";
import { listPorts, sendDiagnosticFrame, setManualPort, type ConnectionSnapshot, type PortCandidate } from "../api";
import { formatDuration } from "../format";
import type { Translate } from "../i18n";

interface Props {
  t: Translate;
  now: number;
  connection: ConnectionSnapshot | null;
}

function formatTime(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleTimeString();
}

function formatBytes(n: number | null): string {
  if (n === null) return "—";
  return n >= 1024 ? `${(n / 1024).toFixed(1)} KiB` : `${n} B`;
}

export default function Connection({ t, now, connection }: Props) {
  const [ports, setPorts] = useState<PortCandidate[]>([]);
  const [sent, setSent] = useState(false);

  const loadPorts = async () => {
    try {
      setPorts(await listPorts());
    } catch (e) {
      console.error("list_ports", e);
    }
  };

  // Ports beim Öffnen und bei jeder Zustandsänderung neu lesen (Hotplug).
  useEffect(() => {
    loadPorts();
  }, [connection?.state, connection?.port]);

  const state = connection?.state ?? "disconnected";
  const info = connection?.info ?? null;
  const receipt = connection?.lastReceipt ?? null;
  const manual = connection?.manualPort ?? "";
  // Der gespeicherte Port bleibt wählbar, auch wenn er gerade nicht steckt.
  const portOptions = manual && !ports.some((p) => p.name === manual) ? [...ports, { name: manual, chip: null } as PortCandidate] : ports;

  const choosePort = async (value: string) => {
    await setManualPort(value === "" ? null : value);
  };

  const sendTest = async () => {
    await sendDiagnosticFrame();
    setSent(true);
    window.setTimeout(() => setSent(false), 2500);
  };

  const receiptText = (() => {
    if (!receipt) return t("conn.frame.none");
    switch (receipt.kind) {
      case "ack":
        return t("conn.frame.ack", { rows: receipt.rows, bytes: receipt.bytes });
      case "error":
        return t("conn.frame.error", { message: receipt.message });
      case "timeout":
        return t("conn.frame.timeout");
    }
  })();

  return (
    <section className="page">
      <header className="page-head">
        <h1>{t("nav.connection")}</h1>
        <span className={`pill pill-conn-${state}`}>{t(`conn.state.${state}`)}</span>
      </header>

      <div className="field-row">
        <span className="field-label">{t("conn.port.label")}</span>
        <select className="select" value={manual} onChange={(e) => choosePort(e.target.value)} title={t("conn.port.tooltip")}>
          <option value="">{t("conn.port.auto")}</option>
          {portOptions.map((p) => (
            <option key={p.name} value={p.name}>
              {p.name}
              {p.chip ? ` · ${p.chip}` : ""}
            </option>
          ))}
        </select>
        <button type="button" className="btn" onClick={loadPorts} title={t("conn.port.refresh.tooltip")}>
          {t("conn.port.refresh")}
        </button>
      </div>
      {ports.length === 0 && <p className="muted">{t("conn.port.none")}</p>}
      {connection?.port && (
        <p className="muted">
          {t("conn.port.active")}: <span className="mono">{connection.port}</span>
        </p>
      )}

      <h2>{t("conn.device.title")}</h2>
      {state === "foreignFirmware" && <p className="notice-bad">{t("disp.fw.foreign.detail")}</p>}
      {info ? (
        <div className="table-wrap">
          <table className="table">
            <tbody>
              <tr>
                <th>{t("conn.device.name")}</th>
                <td>{connection?.profile?.friendlyName ?? "—"}</td>
              </tr>
              <tr>
                <th>{t("conn.device.mac")}</th>
                <td className="mono">{info.mac}</td>
              </tr>
              <tr>
                <th>{t("conn.device.firmware")}</th>
                <td className="mono">{info.version}</td>
              </tr>
              <tr>
                <th>{t("conn.device.variant")}</th>
                <td className="mono">{info.display ?? t("conn.device.variant.unknown")}</td>
              </tr>
              <tr>
                <th>{t("conn.device.transport")}</th>
                <td>
                  {info.serialTransport === "aim1" ? "AIM1" : t("conn.device.transport.lines")}
                  {info.maxFrameBytes ? ` · ${t("conn.device.maxframe", { bytes: info.maxFrameBytes })}` : ""}
                </td>
              </tr>
              <tr>
                <th>{t("conn.device.uptime")}</th>
                <td>{info.uptime !== null ? formatDuration(t, info.uptime) : "—"}</td>
              </tr>
              <tr>
                <th>{t("conn.device.heap")}</th>
                <td>{formatBytes(info.heap)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      ) : (
        <p className="muted">{state === "probing" ? t("disp.device.handshake") : t("esp32.none.info")}</p>
      )}

      <h2>{t("conn.frame.title")}</h2>
      <dl className="facts">
        <dt>{t("conn.frame.id")}</dt>
        <dd className="mono">{receipt ? receipt.frameId : "—"}</dd>
        <dt>{t("conn.frame.result")}</dt>
        <dd>{receiptText}</dd>
        <dt>{t("conn.frame.bytes")}</dt>
        <dd className="mono">{formatBytes(connection?.lastFrameBytes ?? null)}</dd>
        <dt>{t("conn.frame.at")}</dt>
        <dd className="mono">
          {formatTime(connection?.lastFrameAt ?? null)}
          {connection?.lastFrameAt ? ` (${formatDuration(t, (now - Date.parse(connection.lastFrameAt)) / 1000)})` : ""}
        </dd>
        <dt>{t("conn.counters")}</dt>
        <dd className="mono">
          {t("conn.counters.values", {
            sent: connection?.framesSent ?? 0,
            acked: connection?.framesAcked ?? 0,
            unacked: connection?.unackedCount ?? 0,
          })}
        </dd>
      </dl>

      <div className="actions">
        <button type="button" className="btn" onClick={sendTest} disabled={state !== "connected"} title={t("disp.test.tooltip")}>
          {sent ? t("diag.test.ok") : t("conn.testframe")}
        </button>
      </div>

      <h2>{t("conn.log.title")}</h2>
      <pre className="output log">{(connection?.log ?? []).join("\n")}</pre>
    </section>
  );
}
