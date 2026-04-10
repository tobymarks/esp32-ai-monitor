/**
 * Async Web Server - Config Portal + REST API
 *
 * Serves a dark-themed config UI and provides JSON endpoints
 * for reading/writing config, OAuth token setup, and device status.
 */

#include "web_server.h"
#include "config.h"
#include "wifi_setup.h"
#include "ntp_time.h"
#include "api_manager.h"

#include <WiFi.h>
#include <ESPAsyncWebServer.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <time.h>

// ============================================================
// External references
// ============================================================
extern AppConfig g_config;
extern void config_save(const AppConfig &cfg);
extern void config_load(AppConfig &cfg);

// ============================================================
// Server instance
// ============================================================
static AsyncWebServer server(80);

// ============================================================
// Uptime string
// ============================================================
static String getUptime() {
    unsigned long sec = millis() / 1000;
    unsigned long d = sec / 86400; sec %= 86400;
    unsigned long h = sec / 3600;  sec %= 3600;
    unsigned long m = sec / 60;    sec %= 60;
    char buf[32];
    snprintf(buf, sizeof(buf), "%lud %luh %lum %lus", d, h, m, sec);
    return String(buf);
}

// ============================================================
// Token status helpers
// ============================================================
static String getTokenStatus() {
    if (strlen(g_config.access_token) == 0) return "missing";
    if (g_config.expires_at == 0) return "valid";  // no expiry info → assume valid
    uint32_t now_epoch = (uint32_t)(time(nullptr));
    if (now_epoch > 0 && now_epoch >= g_config.expires_at) return "expired";
    return "valid";
}

static String getTokenExpires() {
    if (g_config.expires_at == 0 || strlen(g_config.access_token) == 0) return "";
    time_t t = (time_t)g_config.expires_at;
    struct tm tm_info;
    gmtime_r(&t, &tm_info);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm_info);
    return String(buf);
}

// ============================================================
// Embedded HTML/CSS/JS - Config Portal UI
// ============================================================
static const char INDEX_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI Monitor Config</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',system-ui,-apple-system,sans-serif;background:#171717;color:#e5e5e5;min-height:100vh;display:flex;justify-content:center;padding:20px 16px 40px}
.container{width:100%;max-width:500px}
.header{text-align:center;margin-bottom:24px;padding-top:8px}
.header h1{font-size:1.35em;font-weight:700;color:#fff;letter-spacing:-.02em;margin-bottom:4px}
.header p{color:#737373;font-size:.85em}
.status-bar{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:20px}
.stat{background:#1c1c1c;border:1px solid #2a2a2a;border-radius:10px;padding:12px 14px}
.stat .lbl{color:#525252;font-size:.7em;text-transform:uppercase;letter-spacing:.05em;margin-bottom:3px}
.stat .val{color:#e5e5e5;font-size:.9em;font-weight:600}
.card{background:#1c1c1c;border:1px solid #2a2a2a;border-radius:12px;padding:18px;margin-bottom:12px}
.card-title{font-size:.8em;font-weight:600;color:#737373;text-transform:uppercase;letter-spacing:.06em;margin-bottom:14px}
.field{margin-bottom:12px}
.field:last-child{margin-bottom:0}
.field label{display:block;font-size:.8em;color:#a3a3a3;margin-bottom:5px;font-weight:500}
.field input,.field select{width:100%;padding:9px 12px;background:#111;border:1px solid #2a2a2a;border-radius:8px;color:#e5e5e5;font-size:.9em;font-family:inherit;outline:none;transition:border-color .15s}
.field input:focus,.field select:focus{border-color:#525252}
.field .hint{font-size:.72em;color:#525252;margin-top:4px}
/* Provider radio */
.radio-group{display:flex;gap:8px}
.radio-opt{flex:1;position:relative}
.radio-opt input[type=radio]{position:absolute;opacity:0;width:0;height:0}
.radio-opt label{display:flex;align-items:center;justify-content:center;gap:7px;padding:9px;background:#111;border:1px solid #2a2a2a;border-radius:8px;cursor:pointer;font-size:.88em;font-weight:500;color:#a3a3a3;transition:all .15s;user-select:none}
.radio-opt input[type=radio]:checked + label{background:#1a1a1a;border-color:#525252;color:#fff}
.radio-opt label .dot{width:8px;height:8px;border-radius:50%;background:#525252;transition:background .15s}
.radio-opt input[type=radio]:checked + label .dot{background:#22c55e}
/* Token status */
.token-status{display:flex;align-items:center;gap:8px;padding:10px 12px;background:#111;border:1px solid #2a2a2a;border-radius:8px;margin-bottom:12px}
.status-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.status-dot.valid{background:#22c55e}
.status-dot.expired{background:#ef4444}
.status-dot.missing{background:#525252}
.status-text{font-size:.83em;color:#a3a3a3;flex:1}
.status-text strong{color:#e5e5e5;font-weight:500}
/* Code block */
.code-section{margin-top:12px}
.code-label{font-size:.75em;color:#737373;margin-bottom:6px;font-weight:500}
.code-wrap{position:relative;background:#111;border:1px solid #2a2a2a;border-radius:8px;overflow:hidden}
.code-wrap code{display:block;padding:10px 42px 10px 12px;font-family:'SF Mono',ui-monospace,monospace;font-size:.7em;color:#a3a3a3;line-height:1.5;word-break:break-all;white-space:pre-wrap}
.copy-btn{position:absolute;top:7px;right:7px;background:#2a2a2a;border:none;border-radius:5px;padding:4px 8px;color:#737373;font-size:.7em;cursor:pointer;transition:all .15s;font-family:inherit}
.copy-btn:hover{background:#333;color:#e5e5e5}
.copy-btn.copied{background:#166534;color:#86efac}
.tabs{display:flex;gap:4px;margin-bottom:8px}
.tab{padding:4px 10px;border-radius:5px;font-size:.72em;font-weight:500;cursor:pointer;color:#737373;background:transparent;border:1px solid transparent;transition:all .15s;font-family:inherit}
.tab.active{background:#1c1c1c;border-color:#2a2a2a;color:#e5e5e5}
.tab-content{display:none}
.tab-content.active{display:block}
/* Usage bars */
.usage-row{display:flex;align-items:center;gap:10px;margin-bottom:8px}
.usage-row:last-child{margin-bottom:0}
.usage-lbl{font-size:.78em;color:#737373;width:90px;flex-shrink:0;font-weight:500}
.usage-bar-wrap{flex:1;background:#111;border-radius:4px;height:6px;overflow:hidden}
.usage-bar{height:100%;border-radius:4px;background:#22c55e;transition:width .4s ease}
.usage-pct{font-size:.78em;color:#a3a3a3;width:36px;text-align:right;flex-shrink:0}
.usage-reset{font-size:.7em;color:#525252;margin-top:2px}
/* Actions */
.actions{display:flex;gap:10px;margin-top:16px}
.btn{flex:1;padding:11px;border:none;border-radius:8px;font-size:.9em;font-weight:600;cursor:pointer;transition:all .15s;font-family:inherit}
.btn-save{background:#fff;color:#000}
.btn-save:hover{background:#e5e5e5}
.btn-save.success{background:#166534;color:#86efac}
.btn-restart{background:#1c1c1c;color:#e5e5e5;border:1px solid #2a2a2a}
.btn-restart:hover{background:#2a2a2a}
.msg{text-align:center;padding:8px 12px;margin-top:10px;border-radius:8px;font-size:.82em;display:none}
.msg.show{display:block}
.msg.ok{background:#14532d33;color:#86efac;border:1px solid #166534}
.msg.err{background:#7f1d1d33;color:#fca5a5;border:1px solid #7f1d1d}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>AI Usage Monitor</h1>
    <p>Konfigurationsportal · ai-monitor.local</p>
  </div>

  <!-- Status Bar -->
  <div class="status-bar">
    <div class="stat"><div class="lbl">IP</div><div class="val" id="s-ip">--</div></div>
    <div class="stat"><div class="lbl">RSSI</div><div class="val" id="s-rssi">--</div></div>
    <div class="stat"><div class="lbl">Heap</div><div class="val" id="s-heap">--</div></div>
    <div class="stat"><div class="lbl">Uptime</div><div class="val" id="s-uptime">--</div></div>
  </div>

  <!-- Usage -->
  <div class="card" id="usage-card">
    <div class="card-title">Live Usage</div>
    <div class="usage-row">
      <div class="usage-lbl">Session</div>
      <div class="usage-bar-wrap"><div class="usage-bar" id="bar-session" style="width:0%"></div></div>
      <div class="usage-pct" id="pct-session">--</div>
    </div>
    <div class="usage-reset" id="reset-session"></div>
    <div class="usage-row" style="margin-top:10px">
      <div class="usage-lbl">Wöchentlich</div>
      <div class="usage-bar-wrap"><div class="usage-bar" id="bar-weekly" style="width:0%;background:#3b82f6"></div></div>
      <div class="usage-pct" id="pct-weekly">--</div>
    </div>
    <div class="usage-reset" id="reset-weekly"></div>
  </div>

  <form id="configForm">
    <!-- Provider -->
    <div class="card">
      <div class="card-title">Provider</div>
      <div class="radio-group">
        <div class="radio-opt">
          <input type="radio" id="p-claude" name="provider" value="0" checked>
          <label for="p-claude"><span class="dot"></span>Claude</label>
        </div>
        <div class="radio-opt">
          <input type="radio" id="p-openai" name="provider" value="1">
          <label for="p-openai"><span class="dot"></span>OpenAI</label>
        </div>
      </div>
    </div>

    <!-- Token Setup -->
    <div class="card">
      <div class="card-title">OAuth Token</div>

      <div class="token-status">
        <div class="status-dot missing" id="token-dot"></div>
        <div class="status-text" id="token-text">Lade...</div>
      </div>

      <div class="code-section">
        <div class="code-label">Token übertragen – Terminal-Befehl:</div>
        <div class="tabs">
          <button type="button" class="tab active" onclick="switchTab(this,'tab-file')">~/.credentials.json</button>
          <button type="button" class="tab" onclick="switchTab(this,'tab-keychain')">macOS Keychain</button>
        </div>
        <div class="tab-content active" id="tab-file">
          <div class="code-wrap">
            <code id="cmd-file">jq -c '{access_token:.claudeAiOauth.accessToken,refresh_token:.claudeAiOauth.refreshToken,expires_at:.claudeAiOauth.expiresAt}' ~/.claude/.credentials.json | curl -s -X POST -H 'Content-Type: application/json' -d @- http://ai-monitor.local/api/token</code>
            <button type="button" class="copy-btn" onclick="copyCode('cmd-file',this)">Kopieren</button>
          </div>
        </div>
        <div class="tab-content" id="tab-keychain">
          <div class="code-wrap">
            <code id="cmd-keychain">security find-generic-password -s 'Claude Code-credentials' -w | jq -c '{access_token:.claudeAiOauth.accessToken,refresh_token:.claudeAiOauth.refreshToken,expires_at:.claudeAiOauth.expiresAt}' | curl -s -X POST -H 'Content-Type: application/json' -d @- http://ai-monitor.local/api/token</code>
            <button type="button" class="copy-btn" onclick="copyCode('cmd-keychain',this)">Kopieren</button>
          </div>
        </div>
      </div>
    </div>

    <!-- Settings -->
    <div class="card">
      <div class="card-title">Einstellungen</div>
      <div class="field">
        <label>Poll-Intervall (Sekunden)</label>
        <input type="number" id="poll_interval" name="poll_interval" min="10" max="86400" value="120">
        <div class="hint">Wie oft die API abgefragt wird. Empfohlen: 60–300.</div>
      </div>
      <div class="field">
        <label>Display-Ausrichtung</label>
        <select id="orientation" name="orientation">
          <option value="0">Portrait (USB unten)</option>
          <option value="1">Landscape (USB links)</option>
        </select>
        <div class="hint">Erfordert Neustart.</div>
      </div>
    </div>

    <div class="actions">
      <button type="submit" class="btn btn-save" id="saveBtn">Speichern</button>
      <button type="button" class="btn btn-restart" onclick="doRestart()">Neustart</button>
    </div>
    <div class="msg" id="msg"></div>
  </form>
</div>

<script>
// ---- Tabs ----
function switchTab(btn, tabId) {
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
  btn.classList.add('active');
  document.getElementById(tabId).classList.add('active');
}

// ---- Copy ----
async function copyCode(id, btn) {
  const text = document.getElementById(id).textContent.trim();
  try {
    await navigator.clipboard.writeText(text);
    btn.textContent = 'Kopiert!';
    btn.classList.add('copied');
    setTimeout(() => { btn.textContent = 'Kopieren'; btn.classList.remove('copied'); }, 2000);
  } catch(e) {
    // Fallback
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    btn.textContent = 'Kopiert!';
    btn.classList.add('copied');
    setTimeout(() => { btn.textContent = 'Kopieren'; btn.classList.remove('copied'); }, 2000);
  }
}

// ---- Message ----
function showMsg(text, ok) {
  const m = document.getElementById('msg');
  m.textContent = text;
  m.className = 'msg show ' + (ok ? 'ok' : 'err');
  setTimeout(() => m.classList.remove('show'), 3500);
}

// ---- Status ----
async function loadStatus() {
  try {
    const d = await fetch('/api/status').then(r => r.json());
    document.getElementById('s-ip').textContent = d.ip || '--';
    document.getElementById('s-rssi').textContent = (d.rssi || '--') + ' dBm';
    document.getElementById('s-heap').textContent = Math.round((d.free_heap || 0) / 1024) + ' KB';
    document.getElementById('s-uptime').textContent = d.uptime || '--';
  } catch(e) {}
}

// ---- Config ----
async function loadConfig() {
  try {
    const d = await fetch('/api/config').then(r => r.json());

    // Provider
    const prov = d.provider || 0;
    document.querySelector(`input[name=provider][value="${prov}"]`).checked = true;

    // Poll & orientation
    document.getElementById('poll_interval').value = d.poll_interval || 120;
    document.getElementById('orientation').value = d.orientation || 0;

    // Token status
    const dot = document.getElementById('token-dot');
    const txt = document.getElementById('token-text');
    dot.className = 'status-dot ' + (d.token_status || 'missing');
    if (d.token_status === 'valid') {
      txt.innerHTML = '<strong>Token: Gültig</strong>' + (d.token_expires ? ' · Läuft ab: ' + d.token_expires : '');
    } else if (d.token_status === 'expired') {
      txt.innerHTML = '<strong>Token: Abgelaufen</strong> · Bitte neu übertragen';
    } else {
      txt.innerHTML = '<strong>Kein Token konfiguriert</strong> · Befehl unten ausführen';
    }
  } catch(e) {}
}

// ---- Usage ----
async function loadUsage() {
  try {
    const d = await fetch('/api/usage').then(r => r.json());
    const sp = Math.min(Math.round((d.session_pct || 0) * 100), 100);
    const wp = Math.min(Math.round((d.weekly_pct || 0) * 100), 100);
    document.getElementById('bar-session').style.width = sp + '%';
    document.getElementById('pct-session').textContent = sp + '%';
    document.getElementById('bar-weekly').style.width = wp + '%';
    document.getElementById('pct-weekly').textContent = wp + '%';
    if (d.session_reset) document.getElementById('reset-session').textContent = 'Reset: ' + d.session_reset;
    if (d.weekly_reset) document.getElementById('reset-weekly').textContent = 'Reset: ' + d.weekly_reset;
  } catch(e) {}
}

// ---- Save ----
document.getElementById('configForm').addEventListener('submit', async function(e) {
  e.preventDefault();
  const btn = document.getElementById('saveBtn');
  const data = {
    poll_interval: parseInt(document.getElementById('poll_interval').value) || 120,
    orientation:   parseInt(document.getElementById('orientation').value) || 0,
    provider:      parseInt(document.querySelector('input[name=provider]:checked').value) || 0
  };
  try {
    const r = await fetch('/api/config', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(data)
    });
    if (r.ok) {
      const resp = await r.json();
      btn.classList.add('success');
      btn.textContent = 'Gespeichert!';
      setTimeout(() => { btn.classList.remove('success'); btn.textContent = 'Speichern'; }, 2000);
      const hint = resp.restart_hint ? ' ' + resp.restart_hint : '';
      showMsg('Konfiguration gespeichert.' + hint, true);
      loadConfig();
    } else {
      showMsg('Fehler beim Speichern.', false);
    }
  } catch(e) { showMsg('Fehler: ' + e.message, false); }
});

// ---- Restart ----
async function doRestart() {
  if (!confirm('Gerät neu starten?')) return;
  try { await fetch('/api/restart', {method: 'POST'}); } catch(e) {}
  showMsg('Neustart wird durchgeführt...', true);
}

// ---- Init ----
loadStatus();
loadConfig();
loadUsage();
setInterval(loadStatus, 5000);
setInterval(loadUsage, 30000);
</script>
</body>
</html>
)rawliteral";

// ============================================================
// Init Web Server
// ============================================================
void webserver_init() {
    // Serve config page
    server.on("/", HTTP_GET, [](AsyncWebServerRequest *request) {
        request->send_P(200, "text/html; charset=utf-8", INDEX_HTML);
    });

    // --------------------------------------------------------
    // GET /api/config — return config (tokens NEVER returned)
    // --------------------------------------------------------
    server.on("/api/config", HTTP_GET, [](AsyncWebServerRequest *request) {
        JsonDocument doc;
        doc["provider"]      = g_config.provider;
        doc["poll_interval"] = g_config.poll_interval_sec;
        doc["orientation"]   = g_config.orientation;
        doc["token_status"]  = getTokenStatus();
        doc["token_expires"] = getTokenExpires();

        String json;
        serializeJson(doc, json);
        request->send(200, "application/json", json);
    });

    // --------------------------------------------------------
    // POST /api/config — save settings (no token changes here)
    // --------------------------------------------------------
    server.on("/api/config", HTTP_POST,
        [](AsyncWebServerRequest *request) {},
        nullptr,
        [](AsyncWebServerRequest *request, uint8_t *data, size_t len, size_t index, size_t total) {
            if (index == 0 && len == total) {
                JsonDocument doc;
                DeserializationError err = deserializeJson(doc, data, len);
                if (err) {
                    request->send(400, "application/json", "{\"error\":\"Invalid JSON\"}");
                    return;
                }

                bool orientation_changed = false;

                if (doc["poll_interval"].is<unsigned int>()) {
                    uint32_t val = doc["poll_interval"];
                    if (val >= 10 && val <= 86400) g_config.poll_interval_sec = (uint16_t)val;
                }
                if (doc["orientation"].is<unsigned int>()) {
                    uint8_t val = doc["orientation"];
                    if (val <= 1 && val != g_config.orientation) {
                        g_config.orientation = val;
                        orientation_changed = true;
                    }
                }
                if (doc["provider"].is<unsigned int>()) {
                    uint8_t val = doc["provider"];
                    if (val <= 1) g_config.provider = val;
                }

                config_save(g_config);
                Serial.println("[Web] Config updated via /api/config");

                if (orientation_changed) {
                    request->send(200, "application/json",
                        "{\"status\":\"ok\",\"restart_hint\":\"Ausrichtung geändert – Neustart erforderlich.\"}");
                } else {
                    request->send(200, "application/json", "{\"status\":\"ok\"}");
                }
            }
        }
    );

    // --------------------------------------------------------
    // POST /api/token — receive OAuth token from terminal
    // Body: { "access_token": "...", "refresh_token": "...", "expires_at": 1234567890 }
    // --------------------------------------------------------
    server.on("/api/token", HTTP_POST,
        [](AsyncWebServerRequest *request) {},
        nullptr,
        [](AsyncWebServerRequest *request, uint8_t *data, size_t len, size_t index, size_t total) {
            if (index == 0 && len == total) {
                JsonDocument doc;
                DeserializationError err = deserializeJson(doc, data, len);
                if (err) {
                    request->send(400, "application/json", "{\"error\":\"Invalid JSON\"}");
                    return;
                }

                if (!doc["access_token"].is<const char*>()) {
                    request->send(400, "application/json", "{\"error\":\"access_token required\"}");
                    return;
                }

                strlcpy(g_config.access_token,
                        doc["access_token"].as<const char*>(),
                        sizeof(g_config.access_token));

                if (doc["refresh_token"].is<const char*>()) {
                    strlcpy(g_config.refresh_token,
                            doc["refresh_token"].as<const char*>(),
                            sizeof(g_config.refresh_token));
                }

                if (doc["expires_at"].is<unsigned long>()) {
                    g_config.expires_at = (uint32_t)doc["expires_at"].as<unsigned long>();
                }

                config_save(g_config);
                Serial.println("[Web] OAuth token updated via /api/token");
                request->send(200, "application/json", "{\"status\":\"ok\"}");
            }
        }
    );

    // --------------------------------------------------------
    // GET /api/status
    // --------------------------------------------------------
    server.on("/api/status", HTTP_GET, [](AsyncWebServerRequest *request) {
        JsonDocument doc;
        doc["ip"]         = wifi_get_ip();
        doc["ssid"]       = wifi_get_ssid();
        doc["rssi"]       = wifi_get_rssi();
        doc["free_heap"]  = ESP.getFreeHeap();
        doc["min_heap"]   = ESP.getMinFreeHeap();
        doc["uptime"]     = getUptime();
        doc["time"]       = ntp_get_datetime();
        doc["time_synced"] = ntp_is_synced();

        String json;
        serializeJson(doc, json);
        request->send(200, "application/json", json);
    });

    // --------------------------------------------------------
    // GET /api/usage — current MonitorState as JSON
    // --------------------------------------------------------
    server.on("/api/usage", HTTP_GET, [](AsyncWebServerRequest *request) {
        const MonitorState &s = api_manager_get_state();
        JsonDocument doc;

        doc["status"]        = s.status;
        doc["is_fetching"]   = s.is_fetching;
        doc["token_valid"]   = s.token_valid;
        doc["session_pct"]   = s.usage.five_hour_utilization;
        doc["session_reset"] = s.usage.five_hour_resets_at;
        doc["weekly_pct"]    = s.usage.seven_day_utilization;
        doc["weekly_reset"]  = s.usage.seven_day_resets_at;
        doc["valid"]         = s.usage.valid;
        doc["last_fetch"]    = s.usage.last_fetch;
        doc["error"]         = s.usage.error;

        String json;
        serializeJson(doc, json);
        request->send(200, "application/json", json);
    });

    // --------------------------------------------------------
    // POST /api/restart
    // --------------------------------------------------------
    server.on("/api/restart", HTTP_POST, [](AsyncWebServerRequest *request) {
        request->send(200, "application/json", "{\"status\":\"restarting\"}");
        delay(500);
        ESP.restart();
    });

    // Start server
    server.begin();
    Serial.println("[Web] AsyncWebServer started on port 80");
}

// ============================================================
// Get URL for QR code
// ============================================================
String webserver_get_url() {
    return "http://" + wifi_get_ip() + "/";
}
