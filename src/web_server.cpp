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
#include "api_claude.h"

#include <WiFi.h>
#include <ESPAsyncWebServer.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <Update.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
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
// GitHub OTA — runs in a separate FreeRTOS task to avoid
// blocking the async web server during the ~30s download.
// ============================================================
static void githubOtaTask(void *param) {
    Serial.println("[OTA-GitHub] Task started — downloading firmware...");

    WiFiClientSecure client;
    client.setInsecure();

    HTTPClient http;
    http.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
    http.setTimeout(30000);

    if (!http.begin(client, "https://tobymarks.github.io/esp32-ai-monitor/bin/firmware-ota.bin")) {
        Serial.println("[OTA-GitHub] HTTP begin failed");
        vTaskDelete(NULL);
        return;
    }

    int httpCode = http.GET();
    if (httpCode != HTTP_CODE_OK) {
        Serial.printf("[OTA-GitHub] HTTP GET failed: %d\n", httpCode);
        http.end();
        vTaskDelete(NULL);
        return;
    }

    int contentLength = http.getSize();
    if (contentLength <= 0) {
        Serial.println("[OTA-GitHub] Invalid content length");
        http.end();
        vTaskDelete(NULL);
        return;
    }

    Serial.printf("[OTA-GitHub] Firmware size: %d bytes\n", contentLength);

    if (!Update.begin(contentLength)) {
        Serial.println("[OTA-GitHub] Update.begin() failed");
        Update.printError(Serial);
        http.end();
        vTaskDelete(NULL);
        return;
    }

    WiFiClient *stream = http.getStreamPtr();
    uint8_t buf[1024];
    int written = 0;

    while (http.connected() && written < contentLength) {
        size_t available = stream->available();
        if (available) {
            int toRead = (available > sizeof(buf)) ? sizeof(buf) : available;
            int bytesRead = stream->readBytes(buf, toRead);
            if (bytesRead > 0) {
                size_t w = Update.write(buf, bytesRead);
                if (w != (size_t)bytesRead) {
                    Serial.println("[OTA-GitHub] Update.write() mismatch");
                    Update.printError(Serial);
                    Update.abort();
                    http.end();
                    vTaskDelete(NULL);
                    return;
                }
                written += bytesRead;
            }
        }
        delay(1);
    }

    http.end();

    if (written != contentLength) {
        Serial.printf("[OTA-GitHub] Incomplete: %d/%d\n", written, contentLength);
        Update.abort();
        vTaskDelete(NULL);
        return;
    }

    if (!Update.end(true)) {
        Serial.println("[OTA-GitHub] Update.end() failed");
        Update.printError(Serial);
        vTaskDelete(NULL);
        return;
    }

    Serial.printf("[OTA-GitHub] Success: %d bytes flashed. Restarting...\n", written);
    delay(500);
    ESP.restart();
}

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

      <div class="field">
        <div class="hint" style="color:#a3a3a3;font-size:.8em;line-height:1.5;margin-bottom:8px">
          <strong style="color:#e5e5e5">Voraussetzung:</strong> <a href="https://claude.ai/download" target="_blank" rel="noopener" style="color:#3b82f6">Claude Code CLI</a> muss installiert und eingeloggt sein. Token wird automatisch im macOS Keychain gespeichert.
        </div>
      </div>

      <div class="code-section">
        <div class="code-label">Token übertragen – Terminal-Befehl:</div>
        <div class="tabs">
          <button type="button" class="tab active" onclick="switchTab(this,'tab-keychain')">macOS Keychain</button>
          <button type="button" class="tab" onclick="switchTab(this,'tab-file')">~/.credentials.json</button>
        </div>
        <div class="tab-content active" id="tab-keychain">
          <div class="code-wrap">
            <code id="cmd-keychain">security find-generic-password -s 'Claude Code-credentials' -w | jq -c '{access_token:.claudeAiOauth.accessToken,refresh_token:.claudeAiOauth.refreshToken,expires_at:.claudeAiOauth.expiresAt}' | curl -s -X POST -H 'Content-Type: application/json' -d @- http://ai-monitor.local/api/token</code>
            <button type="button" class="copy-btn" onclick="copyCode('cmd-keychain',this)">Kopieren</button>
          </div>
        </div>
        <div class="tab-content" id="tab-file">
          <div class="code-wrap">
            <code id="cmd-file">jq -c '{access_token:.claudeAiOauth.accessToken,refresh_token:.claudeAiOauth.refreshToken,expires_at:.claudeAiOauth.expiresAt}' ~/.claude/.credentials.json | curl -s -X POST -H 'Content-Type: application/json' -d @- http://ai-monitor.local/api/token</code>
            <button type="button" class="copy-btn" onclick="copyCode('cmd-file',this)">Kopieren</button>
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

  <!-- Firmware Update Link -->
  <div class="card" style="margin-top:12px;text-align:center">
    <a href="/update" style="color:#737373;text-decoration:none;font-size:.82em;transition:color .15s">
      Firmware Update (OTA) &rarr;
    </a>
  </div>
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
// Embedded HTML - OTA Firmware Upload Page
// ============================================================
static const char OTA_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Firmware Update</title>
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
.back{display:inline-block;color:#737373;text-decoration:none;font-size:.85em;margin-bottom:16px;transition:color .15s}
.back:hover{color:#e5e5e5}
.card{background:#1c1c1c;border:1px solid #2a2a2a;border-radius:12px;padding:18px;margin-bottom:12px}
.card-title{font-size:.8em;font-weight:600;color:#737373;text-transform:uppercase;letter-spacing:.06em;margin-bottom:14px}
.version-info{display:flex;justify-content:space-between;align-items:center;padding:10px 12px;background:#111;border:1px solid #2a2a2a;border-radius:8px;margin-bottom:14px}
.version-info .lbl{color:#737373;font-size:.8em}
.version-info .val{color:#e5e5e5;font-size:.9em;font-weight:600}
.drop-zone{border:2px dashed #2a2a2a;border-radius:10px;padding:40px 20px;text-align:center;cursor:pointer;transition:all .2s;margin-bottom:14px}
.drop-zone:hover,.drop-zone.dragover{border-color:#525252;background:#1a1a1a}
.drop-zone .icon{font-size:2em;margin-bottom:8px;color:#525252}
.drop-zone .text{color:#737373;font-size:.85em}
.drop-zone .text strong{color:#a3a3a3}
.file-info{display:none;align-items:center;gap:10px;padding:10px 12px;background:#111;border:1px solid #2a2a2a;border-radius:8px;margin-bottom:14px}
.file-info.show{display:flex}
.file-info .name{flex:1;font-size:.85em;color:#e5e5e5;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.file-info .size{font-size:.78em;color:#737373;flex-shrink:0}
.file-info .remove{background:none;border:none;color:#525252;cursor:pointer;font-size:1.1em;padding:2px 6px;transition:color .15s}
.file-info .remove:hover{color:#ef4444}
.progress-wrap{display:none;margin-bottom:14px}
.progress-wrap.show{display:block}
.progress-bar-bg{background:#111;border-radius:4px;height:8px;overflow:hidden;margin-bottom:6px}
.progress-bar{height:100%;border-radius:4px;background:#22c55e;width:0%;transition:width .3s ease}
.progress-text{font-size:.78em;color:#737373;text-align:center}
.btn-upload{width:100%;padding:12px;border:none;border-radius:8px;font-size:.9em;font-weight:600;cursor:pointer;transition:all .15s;font-family:inherit;background:#fff;color:#000}
.btn-upload:hover{background:#e5e5e5}
.btn-upload:disabled{background:#2a2a2a;color:#525252;cursor:not-allowed}
.hint{font-size:.72em;color:#525252;margin-top:10px;text-align:center;line-height:1.5}
.btn-github{width:100%;padding:12px;border:none;border-radius:8px;font-size:.9em;font-weight:600;cursor:pointer;transition:all .15s;font-family:inherit;background:#238636;color:#fff;margin-bottom:14px}
.btn-github:hover{background:#2ea043}
.btn-github:disabled{background:#2a2a2a;color:#525252;cursor:not-allowed}
.gh-status{display:none;padding:10px 12px;background:#111;border:1px solid #2a2a2a;border-radius:8px;margin-bottom:14px;font-size:.85em;color:#a3a3a3;text-align:center}
.gh-status.show{display:block}
.gh-status.error{border-color:#7f1d1d;color:#fca5a5}
.gh-status.success{border-color:#166534;color:#86efac}
.separator{display:flex;align-items:center;gap:12px;margin:18px 0 14px;color:#525252;font-size:.75em;text-transform:uppercase;letter-spacing:.06em}
.separator::before,.separator::after{content:'';flex:1;height:1px;background:#2a2a2a}
</style>
</head>
<body>
<div class="container">
  <a href="/" class="back">&larr; Zurück zur Konfiguration</a>
  <div class="header">
    <h1>Firmware Update</h1>
    <p>OTA Upload · ai-monitor.local</p>
  </div>

  <div class="card">
    <div class="card-title">Firmware</div>
    <div class="version-info">
      <span class="lbl">Aktuelle Version</span>
      <span class="val" id="cur-version">--</span>
    </div>

    <button type="button" class="btn-github" id="ghBtn" onclick="doGithubUpdate()">Von GitHub aktualisieren</button>
    <div class="gh-status" id="ghStatus"></div>

    <div class="separator">oder manuell hochladen</div>

    <form id="uploadForm" method="POST" action="/update" enctype="multipart/form-data">
      <div class="drop-zone" id="dropZone">
        <div class="icon">&#8682;</div>
        <div class="text"><strong>.bin Datei</strong> hierher ziehen oder klicken</div>
      </div>
      <input type="file" id="fileInput" name="update" accept=".bin" style="display:none">

      <div class="file-info" id="fileInfo">
        <span class="name" id="fileName"></span>
        <span class="size" id="fileSize"></span>
        <button type="button" class="remove" id="fileRemove">&times;</button>
      </div>

      <div class="progress-wrap" id="progressWrap">
        <div class="progress-bar-bg"><div class="progress-bar" id="progressBar"></div></div>
        <div class="progress-text" id="progressText">0%</div>
      </div>

      <button type="submit" class="btn-upload" id="uploadBtn" disabled>Firmware hochladen</button>
    </form>

    <div class="hint">
      Erstelle die .bin Datei mit: <code style="background:#111;padding:2px 6px;border-radius:4px">pio run</code><br>
      Datei liegt unter <code style="background:#111;padding:2px 6px;border-radius:4px">.pio/build/esp32dev/firmware.bin</code><br>
      NVS (WiFi + Token) bleibt bei OTA erhalten.
    </div>
  </div>
</div>

<script>
const dropZone = document.getElementById('dropZone');
const fileInput = document.getElementById('fileInput');
const fileInfo = document.getElementById('fileInfo');
const fileName = document.getElementById('fileName');
const fileSize = document.getElementById('fileSize');
const fileRemove = document.getElementById('fileRemove');
const uploadBtn = document.getElementById('uploadBtn');
const uploadForm = document.getElementById('uploadForm');
const progressWrap = document.getElementById('progressWrap');
const progressBar = document.getElementById('progressBar');
const progressText = document.getElementById('progressText');

// Load current version
fetch('/api/status').then(r=>r.json()).then(d=>{
  // Version comes from config.h APP_VERSION — exposed via status endpoint if available
}).catch(()=>{});

let selectedFile = null;

dropZone.addEventListener('click', () => fileInput.click());
dropZone.addEventListener('dragover', (e) => { e.preventDefault(); dropZone.classList.add('dragover'); });
dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
dropZone.addEventListener('drop', (e) => {
  e.preventDefault();
  dropZone.classList.remove('dragover');
  if (e.dataTransfer.files.length) selectFile(e.dataTransfer.files[0]);
});

fileInput.addEventListener('change', () => {
  if (fileInput.files.length) selectFile(fileInput.files[0]);
});

fileRemove.addEventListener('click', () => {
  selectedFile = null;
  fileInput.value = '';
  fileInfo.classList.remove('show');
  dropZone.style.display = '';
  uploadBtn.disabled = true;
});

function selectFile(file) {
  if (!file.name.endsWith('.bin')) {
    alert('Bitte eine .bin Datei auswählen.');
    return;
  }
  selectedFile = file;
  fileName.textContent = file.name;
  fileSize.textContent = (file.size / 1024).toFixed(1) + ' KB';
  fileInfo.classList.add('show');
  dropZone.style.display = 'none';
  uploadBtn.disabled = false;
}

uploadForm.addEventListener('submit', function(e) {
  e.preventDefault();
  if (!selectedFile) return;

  const formData = new FormData();
  formData.append('update', selectedFile);

  const xhr = new XMLHttpRequest();
  xhr.open('POST', '/update', true);

  progressWrap.classList.add('show');
  uploadBtn.disabled = true;
  uploadBtn.textContent = 'Uploading...';

  xhr.upload.addEventListener('progress', (e) => {
    if (e.lengthComputable) {
      const pct = Math.round((e.loaded / e.total) * 100);
      progressBar.style.width = pct + '%';
      progressText.textContent = pct + '%';
    }
  });

  xhr.onload = function() {
    if (xhr.status === 200) {
      progressBar.style.width = '100%';
      progressBar.style.background = '#22c55e';
      progressText.textContent = 'Fertig! Neustart...';
      uploadBtn.textContent = 'Neustart...';
      setTimeout(() => { window.location.href = '/'; }, 5000);
    } else {
      progressBar.style.background = '#ef4444';
      progressText.textContent = 'Fehler!';
      uploadBtn.textContent = 'Fehlgeschlagen';
      uploadBtn.disabled = false;
    }
  };

  xhr.onerror = function() {
    progressBar.style.background = '#ef4444';
    progressText.textContent = 'Verbindungsfehler';
    uploadBtn.textContent = 'Fehlgeschlagen';
    uploadBtn.disabled = false;
  };

  xhr.send(formData);
});

// Show current version
fetch('/api/status').then(r=>r.json()).then(d=>{
  document.getElementById('cur-version').textContent = d.version || '--';
}).catch(()=>{});

// GitHub OTA Update
async function doGithubUpdate() {
  const btn = document.getElementById('ghBtn');
  const status = document.getElementById('ghStatus');
  btn.disabled = true;
  btn.textContent = 'Downloading...';
  status.className = 'gh-status show';
  status.textContent = 'Firmware wird von GitHub heruntergeladen und geflasht...';

  try {
    const r = await fetch('/api/ota-github', {method:'POST', signal:AbortSignal.timeout(10000)});
    const d = await r.json();
    if (d.status === 'started') {
      status.className = 'gh-status show';
      status.textContent = 'Download + Flash laeuft im Hintergrund...';
      btn.textContent = 'Bitte warten...';
      // Poll until device restarts with new firmware
      setTimeout(() => { tryReconnect(); }, 15000);
    } else {
      status.className = 'gh-status show error';
      status.textContent = 'Fehler: ' + (d.error || 'Unbekannt');
      btn.disabled = false;
      btn.textContent = 'Von GitHub aktualisieren';
    }
  } catch(e) {
    // Connection lost likely means ESP is restarting (success case)
    status.className = 'gh-status show';
    status.textContent = 'Verbindung unterbrochen — warte auf Neustart...';
    btn.textContent = 'Neustart...';
    setTimeout(() => { tryReconnect(); }, 5000);
  }
}

function tryReconnect() {
  const status = document.getElementById('ghStatus');
  let attempts = 0;
  const iv = setInterval(async () => {
    attempts++;
    status.textContent = 'Warte auf Neustart... (' + attempts + ')';
    try {
      const r = await fetch('/api/status', {signal:AbortSignal.timeout(3000)});
      if (r.ok) {
        clearInterval(iv);
        status.className = 'gh-status show success';
        status.textContent = 'Neustart erfolgreich!';
        setTimeout(() => { window.location.reload(); }, 1000);
      }
    } catch(e) {}
    if (attempts > 20) {
      clearInterval(iv);
      status.className = 'gh-status show error';
      status.textContent = 'Timeout — bitte manuell pruefen.';
    }
  }, 3000);
}
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

                // Immediately refresh to establish independent token chain
                bool refreshed = claude_refresh_token();
                if (refreshed) {
                    config_save(g_config);
                    Serial.println("[Web] Token chain established — ESP32 has independent tokens");
                    request->send(200, "application/json",
                        "{\"status\":\"ok\",\"token_chain\":\"independent\"}");
                } else {
                    Serial.println("[Web] WARNING: Refresh failed — using original token");
                    request->send(200, "application/json",
                        "{\"status\":\"ok\",\"token_chain\":\"shared\","
                        "\"warning\":\"Refresh failed — token may expire\"}");
                }
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
        doc["version"]     = APP_VERSION;

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

    // --------------------------------------------------------
    // POST /api/ota-github — Spawn background task for GitHub OTA
    // --------------------------------------------------------
    server.on("/api/ota-github", HTTP_POST, [](AsyncWebServerRequest *request) {
        Serial.println("[OTA-GitHub] Request received — spawning download task...");
        // 8KB stack is enough for HTTPClient + Update streaming
        BaseType_t ok = xTaskCreate(githubOtaTask, "ota_gh", 8192, NULL, 1, NULL);
        if (ok == pdPASS) {
            request->send(200, "application/json", "{\"status\":\"started\"}");
        } else {
            request->send(500, "application/json", "{\"status\":\"error\",\"error\":\"Could not start OTA task\"}");
        }
    });

    // --------------------------------------------------------
    // GET /update — Firmware Upload Page
    // --------------------------------------------------------
    server.on("/update", HTTP_GET, [](AsyncWebServerRequest *request) {
        request->send_P(200, "text/html; charset=utf-8", OTA_HTML);
    });

    // --------------------------------------------------------
    // POST /update — Receive firmware binary and flash
    // --------------------------------------------------------
    server.on("/update", HTTP_POST,
        // Response handler (called after upload completes)
        [](AsyncWebServerRequest *request) {
            bool success = !Update.hasError();
            AsyncWebServerResponse *response = request->beginResponse(200, "text/html; charset=utf-8",
                success
                    ? "<html><body style='background:#171717;color:#e5e5e5;font-family:Inter,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0'>"
                      "<div style='text-align:center'><h2 style='color:#22c55e'>Update erfolgreich!</h2><p>Neustart in 3 Sekunden...</p></div></body></html>"
                    : "<html><body style='background:#171717;color:#e5e5e5;font-family:Inter,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0'>"
                      "<div style='text-align:center'><h2 style='color:#ef4444'>Update fehlgeschlagen!</h2><p><a href='/update' style='color:#3b82f6'>Erneut versuchen</a></p></div></body></html>"
            );
            response->addHeader("Connection", "close");
            request->send(response);
            if (success) {
                delay(1000);
                ESP.restart();
            }
        },
        // Upload handler (called per chunk)
        [](AsyncWebServerRequest *request, const String& filename, size_t index, uint8_t *data, size_t len, bool final) {
            if (index == 0) {
                Serial.printf("[OTA-Web] Upload start: %s\n", filename.c_str());
                if (!Update.begin(UPDATE_SIZE_UNKNOWN)) {
                    Update.printError(Serial);
                }
            }
            if (Update.isRunning()) {
                if (Update.write(data, len) != len) {
                    Update.printError(Serial);
                }
            }
            if (final) {
                if (Update.end(true)) {
                    Serial.printf("[OTA-Web] Upload complete: %u bytes\n", index + len);
                } else {
                    Update.printError(Serial);
                }
            }
        }
    );

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
