import { useState } from "react";
import { refresh, rescanCli, type Snapshot } from "../api";
import { formatMs } from "../format";
import type { Translate } from "../i18n";

interface Props {
  t: Translate;
  snapshot: Snapshot | null;
}

export default function Diagnostics({ t, snapshot }: Props) {
  const [copied, setCopied] = useState(false);
  const run = snapshot?.lastRun ?? null;

  const copy = async () => {
    if (!snapshot) return;
    const lines = [
      `${t("diag.cli.path")}: ${snapshot.cliPath ?? t("diag.cli.missing")}`,
      `${t("diag.cli.version")}: ${snapshot.cliVersion ?? "-"}`,
      `${t("diag.fixture.dir")}: ${snapshot.fixtureDir ?? t("diag.fixture.none")}`,
      `${t("diag.last.command")}: ${run?.command ?? t("diag.last.none")}`,
      `${t("diag.exit.code")}: ${run?.exitCode ?? "-"}`,
      `${t("diag.duration")}: ${run ? formatMs(run.durationMs) : "-"}`,
      "",
      `--- ${t("diag.stdout")} ---`,
      run?.stdout ?? "",
      `--- ${t("diag.stderr")} ---`,
      run?.stderr ?? "",
    ];
    try {
      await navigator.clipboard.writeText(lines.join("\n"));
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch (e) {
      console.error("clipboard", e);
    }
  };

  return (
    <section className="page">
      <header className="page-head">
        <h1>{t("nav.diagnostics")}</h1>
      </header>
      <p className="muted">{t("diag.intro")}</p>

      <dl className="facts">
        <dt>{t("diag.cli.path")}</dt>
        <dd className="mono">{snapshot?.cliPath ?? t("diag.cli.missing")}</dd>
        <dt>{t("diag.cli.version")}</dt>
        <dd className="mono">{snapshot?.cliVersion ?? "-"}</dd>
        <dt>{t("diag.fixture.dir")}</dt>
        <dd className="mono">{snapshot?.fixtureDir ?? t("diag.fixture.none")}</dd>
        <dt>{t("diag.last.command")}</dt>
        <dd className="mono">{run?.command || t("diag.last.none")}</dd>
        <dt>{t("diag.exit.code")}</dt>
        <dd className="mono">{run?.exitCode ?? "-"}</dd>
        <dt>{t("diag.duration")}</dt>
        <dd className="mono">{run ? formatMs(run.durationMs) : "-"}</dd>
      </dl>

      <div className="actions">
        <button type="button" className="btn" onClick={() => refresh()}>
          {t("diag.refetch")}
        </button>
        <button type="button" className="btn" onClick={() => rescanCli()}>
          {t("diag.rescan")}
        </button>
        <button type="button" className="btn" onClick={copy} disabled={!snapshot}>
          {copied ? t("diag.copy.ok") : t("diag.copy")}
        </button>
      </div>

      <h2>{t("diag.stdout")}</h2>
      <pre className="output">{run?.stdout ?? ""}</pre>
      <h2>{t("diag.stderr")}</h2>
      <pre className="output">{run?.stderr ?? ""}</pre>
    </section>
  );
}
