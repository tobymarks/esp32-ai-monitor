import { useEffect, useRef, useState } from "react";
import {
  getTimezones,
  renameDevice,
  setBrightness,
  setTimezone,
  updateProfile,
  type ConnectionSnapshot,
  type DisplayLanguage,
  type Orientation,
  type Settings,
  type ThemeSetting,
  type TimeZoneOption,
} from "../api";
import type { Translate } from "../i18n";

interface Props {
  t: Translate;
  connection: ConnectionSnapshot | null;
  settings: Settings | null;
  onSettingsChanged: () => void;
}

/// Ruhe nach dem letzten Slider-Schritt, bevor persist:true geht (Spec 6.3).
const BRIGHTNESS_PERSIST_MS = 450;

const ORIENTATIONS: Orientation[] = ["portrait", "landscape_left", "landscape_right"];
const THEMES: ThemeSetting[] = ["system", "dark", "light"];
const LANGUAGES: DisplayLanguage[] = ["de", "en"];

export default function Display({ t, connection, settings, onSettingsChanged }: Props) {
  const profile = connection?.profile ?? null;
  const connected = connection?.state === "connected";
  const [name, setName] = useState(profile?.friendlyName ?? "");
  const [nameError, setNameError] = useState<string | null>(null);
  const [brightness, setBrightnessValue] = useState(profile?.brightness ?? 80);
  const [timezones, setTimezones] = useState<TimeZoneOption[]>([]);
  const persistTimer = useRef<number | null>(null);
  const dragging = useRef(false);

  // Profilwerte übernehmen, sobald ein anderes Gerät kommt oder das Backend
  // sie ändert; nicht mitten im Ziehen des Sliders.
  useEffect(() => {
    setName(profile?.friendlyName ?? "");
    setNameError(null);
  }, [profile?.mac, profile?.friendlyName]);
  useEffect(() => {
    if (!dragging.current && profile) setBrightnessValue(profile.brightness);
  }, [profile?.mac, profile?.brightness]);

  useEffect(() => {
    getTimezones().then(setTimezones).catch((e) => console.error("get_timezones", e));
  }, [settings?.timezone]);

  const commitName = async () => {
    if (!profile || name.trim() === profile.friendlyName) return;
    try {
      await renameDevice(profile.mac, name);
      setNameError(null);
    } catch (e) {
      setNameError(t(String(e)));
    }
  };

  const applyProfile = async (patch: { theme?: ThemeSetting; orientation?: Orientation; language?: DisplayLanguage }) => {
    if (!profile) return;
    try {
      await updateProfile(
        profile.mac,
        patch.theme ?? profile.theme,
        patch.orientation ?? profile.orientation,
        patch.language ?? profile.language,
      );
    } catch (e) {
      console.error("update_profile", e);
    }
  };

  const onBrightness = (value: number) => {
    dragging.current = true;
    setBrightnessValue(value);
    setBrightness(value, false).catch((e) => console.error("set_brightness", e));
    if (persistTimer.current) window.clearTimeout(persistTimer.current);
    persistTimer.current = window.setTimeout(() => {
      dragging.current = false;
      setBrightness(value, true).catch((e) => console.error("set_brightness", e));
    }, BRIGHTNESS_PERSIST_MS);
  };

  const chooseTimezone = async (id: string) => {
    try {
      await setTimezone(id);
      onSettingsChanged();
    } catch (e) {
      console.error("set_timezone", e);
    }
  };

  const disabled = !connected || !profile;

  return (
    <section className="page">
      <header className="page-head">
        <h1>{t("nav.display")}</h1>
        {connection && <span className={`pill pill-conn-${connection.state}`}>{t(`conn.state.${connection.state}`)}</span>}
      </header>
      <p className="muted">{t("disp.intro")}</p>

      {!connected && (
        <p className="notice">
          {connection?.state === "foreignFirmware"
            ? t("disp.fw.foreign")
            : profile
              ? t("disp.offline.lastknown", { name: profile.friendlyName })
              : t("esp32.none.info")}
        </p>
      )}

      <h2>{t("disp.step.pick")}</h2>
      <div className="field-row">
        <label className="field-label" htmlFor="device-name">
          {t("disp.name.label")}
        </label>
        <input
          id="device-name"
          className="input"
          type="text"
          maxLength={30}
          value={name}
          disabled={!profile}
          onChange={(e) => setName(e.target.value)}
          onBlur={commitName}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.target as HTMLInputElement).blur();
          }}
          title={t("disp.name.edit.tooltip")}
        />
        {profile && <span className="mono muted">{profile.mac}</span>}
      </div>
      {nameError && <p className="error-text">{nameError}</p>}
      {profile && (
        <p className="muted">
          {t("disp.profile.meta", {
            firmware: profile.firmwareVersion ?? "—",
            variant: profile.displayVariant ?? t("conn.device.variant.unknown"),
          })}
        </p>
      )}

      <h2>{t("disp.step.look")}</h2>
      <div className="field-row">
        <span className="field-label">{t("disp.orient.label")}</span>
        <div className="segmented" role="group" aria-label={t("disp.orient.label")} title={t("disp.orient.tooltip")}>
          {ORIENTATIONS.map((o) => (
            <button
              key={o}
              type="button"
              disabled={disabled}
              className={profile?.orientation === o ? "is-active" : undefined}
              aria-pressed={profile?.orientation === o}
              onClick={() => applyProfile({ orientation: o })}
            >
              {t(`disp.orient.${o}`)}
            </button>
          ))}
        </div>
      </div>
      <div className="field-row">
        <span className="field-label">{t("disp.theme.label")}</span>
        <div className="segmented" role="group" aria-label={t("disp.theme.label")} title={t("disp.theme.tooltip")}>
          {THEMES.map((th) => (
            <button
              key={th}
              type="button"
              disabled={disabled}
              className={profile?.theme === th ? "is-active" : undefined}
              aria-pressed={profile?.theme === th}
              onClick={() => applyProfile({ theme: th })}
            >
              {t(`disp.theme.${th}`)}
            </button>
          ))}
        </div>
      </div>
      <div className="field-row">
        <span className="field-label">{t("disp.lang.label")}</span>
        <div className="segmented" role="group" aria-label={t("disp.lang.label")} title={t("disp.lang.tooltip")}>
          {LANGUAGES.map((l) => (
            <button
              key={l}
              type="button"
              disabled={disabled}
              className={profile?.language === l ? "is-active" : undefined}
              aria-pressed={profile?.language === l}
              onClick={() => applyProfile({ language: l })}
            >
              {t(`disp.lang.${l}`)}
            </button>
          ))}
        </div>
      </div>
      <div className="field-row">
        <label className="field-label" htmlFor="brightness">
          {t("disp.bright.label")}
        </label>
        <input
          id="brightness"
          className="slider"
          type="range"
          min={5}
          max={100}
          step={1}
          value={brightness}
          disabled={disabled}
          onChange={(e) => onBrightness(Number(e.target.value))}
          title={t("disp.bright.tooltip")}
        />
        <span className="mono slider-value">{brightness} %</span>
      </div>
      <div className="field-row">
        <label className="field-label" htmlFor="timezone">
          {t("disp.tz.label")}
        </label>
        <select
          id="timezone"
          className="select"
          value={settings?.timezone ?? "auto"}
          onChange={(e) => chooseTimezone(e.target.value)}
          title={t("disp.tz.tooltip")}
        >
          {timezones.map((tz) => (
            <option key={tz.id} value={tz.id}>
              {tz.id === "auto" ? t("disp.tz.auto", { offset: tz.label }) : tz.label}
            </option>
          ))}
        </select>
      </div>
      <p className="muted">{t("disp.tz.intro")}</p>
      <p className="muted">{t("disp.test.hint")}</p>
    </section>
  );
}
