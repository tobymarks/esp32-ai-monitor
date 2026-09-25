import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { ProviderInfo, Settings, ViewContent } from "../api";
import type { Translate } from "../i18n";

interface Props {
  t: Translate;
  settings: Settings;
  providers: ProviderInfo[];
  onSettings: (patch: Partial<Settings>) => void;
}

const MAX_VIEWS = 8;
const CLOCK: ViewContent = { kind: "clock" };
const GLYPHS: Record<string, string> = {
  clock: "◷", claude: "✳", codex: "◎", antigravity: "✦",
  gemini: "✧", copilot: "◆", cursor: "⬡",
};

export default function ViewManager({ t, settings, providers, onSettings }: Props) {
  const [selected, setSelected] = useState(0);
  const [dragging, setDragging] = useState(false);
  const [dragPoint, setDragPoint] = useState<{ x: number; y: number } | null>(null);
  const [dragContent, setDragContent] = useState<ViewContent | null>(null);
  const [dropIndex, setDropIndex] = useState<number | null>(null);
  const suppressClick = useRef(false);
  const [draftInterval, setDraftInterval] = useState(String(settings.viewIntervalSeconds));
  const views = settings.views;

  useEffect(() => setSelected((index) => Math.min(index, views.length - 1)), [views.length]);
  useEffect(() => setDraftInterval(String(settings.viewIntervalSeconds)), [settings.viewIntervalSeconds]);

  const commitInterval = () => {
    const value = Math.min(3600, Math.max(2, Number(draftInterval) || 10));
    setDraftInterval(String(value));
    if (value !== settings.viewIntervalSeconds) onSettings({ viewIntervalSeconds: value });
  };

  const label = (content: ViewContent) => content.kind === "clock"
    ? t("views.clock")
    : providers.find((p) => p.key === content.provider)?.label ?? content.provider;
  const glyph = (content: ViewContent) => GLYPHS[content.kind === "clock" ? "clock" : content.provider];

  const assign = (index: number, content: ViewContent) => {
    onSettings({
      views: views.map((view, i) => i === index ? content : view),
      ...(settings.viewMode === "manual" && settings.activeView === index && content.kind === "provider"
        ? { provider: content.provider } : {}),
    });
    setSelected(index);
  };

  // Pointer-basiert, damit das Ablegen auch im nativen Windows-WebView
  // zuverlässig funktioniert. Klick und Tastatur bleiben als Alternative.
  const startDrag = (event: ReactPointerEvent, content: ViewContent) => {
    if (event.button !== 0) return;
    const startX = event.clientX;
    const startY = event.clientY;
    let moved = false;
    const targetIndex = (x: number, y: number) => {
      const element = document.elementFromPoint(x, y)?.closest<HTMLElement>("[data-view-index]");
      return element ? Number(element.dataset.viewIndex) : null;
    };
    const onMove = (move: PointerEvent) => {
      if (!moved && Math.hypot(move.clientX - startX, move.clientY - startY) < 8) return;
      moved = true;
      setDragging(true);
      setDragContent(content);
      setDragPoint({ x: move.clientX, y: move.clientY });
      setDropIndex(targetIndex(move.clientX, move.clientY));
    };
    const onUp = (up: PointerEvent) => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      if (moved) {
        const index = targetIndex(up.clientX, up.clientY);
        if (index !== null && index >= 0 && index < views.length) assign(index, content);
        suppressClick.current = true;
        window.setTimeout(() => { suppressClick.current = false; }, 0);
      }
      setDragging(false);
      setDragPoint(null);
      setDragContent(null);
      setDropIndex(null);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  };

  const remove = (index: number) => {
    if (index === 0) return;
    const next = views.filter((_, i) => i !== index);
    const activeView = settings.activeView === index ? 0
      : settings.activeView > index ? settings.activeView - 1 : settings.activeView;
    const activeContent = next[activeView];
    onSettings({ views: next, activeView,
      ...(settings.viewMode === "manual" && activeContent.kind === "provider"
        ? { provider: activeContent.provider } : {}) });
    setSelected(Math.min(index - 1, next.length - 1));
  };

  const chooseManual = () => {
    const activeContent = views[settings.activeView];
    onSettings({ viewMode: "manual",
      ...(activeContent.kind === "provider" ? { provider: activeContent.provider } : {}) });
  };

  return (
    <section className="view-manager" aria-label={t("views.title")}>
      <h2>{t("views.title")}</h2>
      <p className="muted">{t("views.intro")}</p>
      <div className="view-layout">
        <div className="view-workspace">
          <div className="view-list">
            {views.map((content, index) => (
              <div key={index} className="view-item">
                <button type="button" data-view-index={index}
                  className={`view-tile${selected === index ? " is-selected" : ""}${dropIndex === index ? " is-drop-target" : ""}`}
                  onClick={() => setSelected(index)} aria-pressed={selected === index}
                  aria-label={`${t("views.window", { number: index + 1 })}: ${label(content)}`}>
                  <span className="view-tile-content">{glyph(content)}<strong>{label(content)}</strong></span>
                  <span className="view-tile-caption">{t("views.window", { number: index + 1 })}</span>
                </button>
                {index === 0 ? <span className="view-fixed">{t("views.fixed")}</span>
                  : <button type="button" className="view-remove" onClick={() => remove(index)}
                      aria-label={t("views.remove", { number: index + 1 })}>×</button>}
              </div>
            ))}
            <button type="button" className="view-add" disabled={views.length >= MAX_VIEWS}
              onClick={() => { onSettings({ views: [...views, CLOCK] }); setSelected(views.length); }}>
              <span aria-hidden="true">＋</span>{t("views.add")}
            </button>
          </div>
          <div className={`view-editor${dragging ? " is-dragging" : ""}`} data-view-index={selected}>
            <h3>{t("views.edit", { number: selected + 1 })}</h3>
            <div className="view-preview">
              <span className="view-preview-icon">{views[selected] ? glyph(views[selected]) : ""}</span>
              <strong>{views[selected] ? label(views[selected]) : ""}</strong>
              <small>{views[selected]?.kind === "clock" ? new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : t("views.preview.source")}</small>
            </div>
            <p className="muted small">{t("views.drop.hint")}</p>
          </div>
          <div className="view-switch">
            <h3>{t("views.switch")}</h3>
            <label className="radio-row"><input type="radio" name="view-mode" checked={settings.viewMode === "automatic"}
              onChange={() => onSettings({ viewMode: "automatic" })} />{t("views.automatic")}</label>
            {settings.viewMode === "automatic" && <label className="view-interval">{t("views.interval")}
              <input className="input" type="number" min={2} max={3600} value={draftInterval}
                onChange={(e) => setDraftInterval(e.target.value)} onBlur={commitInterval}
                onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />{t("views.seconds")}</label>}
            <label className="radio-row"><input type="radio" name="view-mode" checked={settings.viewMode === "manual"}
              onChange={chooseManual} />{t("views.manual")}</label>
            <p className="muted small">{t("views.manual.hint")}</p>
          </div>
        </div>
        <aside className="view-palette">
          <h3>{t("views.blocks")}</h3>
          <p className="muted">{t("views.blocks.hint")}</p>
          {[CLOCK, ...providers.map((p): ViewContent => ({ kind: "provider", provider: p.key }))].map((content) => (
            <button key={content.kind === "clock" ? "clock" : content.provider} type="button"
              onPointerDown={(e) => startDrag(e, content)}
              onClick={() => { if (!suppressClick.current) assign(selected, content); }} className="view-block">
              <span aria-hidden="true">{glyph(content)}</span>{label(content)}<span className="view-grip" aria-hidden="true">⋮⋮</span>
            </button>
          ))}
        </aside>
      </div>
      {dragPoint && dragContent && <div className="view-drag-ghost" style={{ left: dragPoint.x + 12, top: dragPoint.y + 12 }}>
        {glyph(dragContent)} {label(dragContent)}
      </div>}
    </section>
  );
}
